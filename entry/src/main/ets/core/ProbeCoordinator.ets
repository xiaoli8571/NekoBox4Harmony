/**
 * ProbeCoordinator —— 检测编排状态机(纯逻辑，无 I/O/无平台依赖)。
 * 依据 REDESIGN-PLAN-2026-10-23.md §6.3(运行与取消)、§6.4(坏节点隔离)、§6.5(会话并发约束)。
 *
 * 职责边界：
 *   - 冻结目标快照、runId/generation 守卫(旧回调不得更新新一轮,§6.5)；
 *   - 分批隔离决策：批量启动失败 → 二分 → 递归到单节点；最坏启动次数 2N−1，超预算如实报未完成(§6.4-6)；
 *   - 环境级失败只报一次，不把所有节点标成坏节点(§6.4-1/§6.4-7)；
 *   - 取消：停止取新目标，处理中任务按取消上下文收尾；未执行节点保留原结果并标未参与(§6.3)；
 *   - 完成摘要：成功/失败/不适用/取消/未保存/未完成。
 * 真正的启动/探测/停止由 runner(utils/LatencyTester 集成)执行，本类只做决策与记账。
 */

import {
  ProbeResult, PROBE_STATE_QUEUED, PROBE_STATE_RUNNING, PROBE_STATE_SUCCESS,
  PROBE_STATE_FAILED, PROBE_STATE_NOT_APPLICABLE, PROBE_STATE_CANCELLED, PROBE_STATE_UNSAVED,
  PROBE_METHOD_HTTP, PROBE_METHOD_TCPING, PROBE_METHOD_UNKNOWN,
  PROBE_CAP_UNAVAILABLE, PROBE_AGG_SINGLE, PROBE_EXPECT_2XX, PROBE_PATH_UNBOUND_UNKNOWN,
  PROBE_SOURCE_MANUAL, PROBE_PARTICIPATED_YES, PROBE_PARTICIPATED_NO
} from '../model/ProbeResult';

/** 目标快照元素：本轮开始时冻结；运行中搜索/切页/订阅更新不改变(§6.3)。 */
export class ProbeTarget {
  profileId: string = '';
  profileName: string = '';
  profileConfigHash: string = '';
  /** 依赖链描述(前置代理/落地)，坏前置可让多个根节点得到相同依赖错误(§6.4-5) */
  chainKey: string = '';
}

/** 检测环境(本轮固定)。 */
export class ProbeEnv {
  method: string = PROBE_METHOD_HTTP;
  target: string = '';
  timeoutMs: number = 5000;
  concurrency: number = 5;
  samples: number = 1;
  retries: number = 0;
  expectedStatus: string = PROBE_EXPECT_2XX;
  bypassVpn: boolean = false;
  staleMs: number = 6 * 3600 * 1000;
}

export class ProbeSummary {
  total: number = 0;
  success: number = 0;
  failed: number = 0;
  notApplicable: number = 0;
  cancelled: number = 0;
  unsaved: number = 0;
  unfinished: number = 0;
}

/** 分批隔离决策结果(§6.4-4)：调用方据此串行尝试两组，递归拆分。 */
export class IsolationDecision {
  /** 'split' | 'isolated' | 'exhausted' */
  kind: string = 'split';
  /** split: 下一轮要尝试的两组(串行)；isolated: 单个坏节点 */
  groups: Array<Array<string>> = [];
  isolatedProfileId: string = '';
  reason: string = '';
}

/** 环境前提检查失败原因(机器可读,§6.4-1) */
export const ENV_REASON_CORE_UNSUPPORTED: string = 'core_unsupported';
export const ENV_REASON_TEST_DIR: string = 'test_dir_unwritable';
export const ENV_REASON_INVALID_TARGET: string = 'invalid_target';
export const ENV_REASON_METHOD_UNSUPPORTED: string = 'method_unsupported';

export const COORD_PHASE_IDLE: string = 'idle';
export const COORD_PHASE_RUNNING: string = 'running';
export const COORD_PHASE_CANCELLING: string = 'cancelling';
export const COORD_PHASE_DONE: string = 'done';
export const COORD_PHASE_FAILED: string = 'failed';

export class ProbeCoordinator {
  private phase: string = COORD_PHASE_IDLE;
  private runId: string = '';
  private generation: number = 0;
  private targets: Array<ProbeTarget> = [];
  private results: Map<string, ProbeResult> = new Map<string, ProbeResult>();
  private env: ProbeEnv = new ProbeEnv();
  private coreCapability: string = PROBE_CAP_UNAVAILABLE;
  private cancelled: boolean = false;
  private startedAt: number = 0;
  private finishedAt: number = 0;
  private attempts: number = 0;
  private maxAttempts: number = 0;
  private envError: string = '';
  private envErrorReported: boolean = false;

  /** 最坏启动次数上限 2N−1(§6.4-6)。 */
  static attemptsBudget(nodeCount: number): number {
    return nodeCount <= 0 ? 0 : nodeCount * 2 - 1;
  }

  /** 环境前提(整轮一次)：内核能力/测试目录可写/URL 合法性(§6.4-1)。 */
  static precheckEnv(capabilityOk: boolean, dirWritable: boolean, urlValid: boolean,
    methodSupported: boolean): string {
    if (!methodSupported) {
      return ENV_REASON_METHOD_UNSUPPORTED;
    }
    if (!capabilityOk) {
      return ENV_REASON_CORE_UNSUPPORTED;
    }
    if (!dirWritable) {
      return ENV_REASON_TEST_DIR;
    }
    if (!urlValid) {
      return ENV_REASON_INVALID_TARGET;
    }
    return '';
  }

  /** 开始新一轮：冻结目标快照、重置计数；同一时刻只允许一轮(§6.5)。 */
  begin(runId: string, targets: Array<ProbeTarget>, env: ProbeEnv, coreCapability: string, now: number): boolean {
    if (this.phase === COORD_PHASE_RUNNING || this.phase === COORD_PHASE_CANCELLING) {
      return false;
    }
    this.runId = runId;
    this.generation = this.generation + 1;
    this.targets = [];
    for (let i = 0; i < targets.length; i++) {
      const t = new ProbeTarget();
      t.profileId = targets[i].profileId;
      t.profileName = targets[i].profileName;
      t.profileConfigHash = targets[i].profileConfigHash;
      t.chainKey = targets[i].chainKey;
      this.targets.push(t);
    }
    this.results = new Map<string, ProbeResult>();
    this.env = env;
    this.coreCapability = coreCapability;
    this.cancelled = false;
    this.startedAt = now;
    this.finishedAt = 0;
    this.attempts = 0;
    this.maxAttempts = ProbeCoordinator.attemptsBudget(this.targets.length);
    this.envError = '';
    this.envErrorReported = false;
    // 每个目标先置 queued(不提前清除其持久化旧结果——旧结果在存储层，由调用方决定展示)
    for (let i = 0; i < this.targets.length; i++) {
      const r = new ProbeResult();
      r.runId = this.runId;
      r.profileId = this.targets[i].profileId;
      r.profileConfigHash = this.targets[i].profileConfigHash;
      r.methodRequested = env.method;
      r.methodActual = env.method;
      r.state = PROBE_STATE_QUEUED;
      r.target = env.target;
      r.timeoutMs = env.timeoutMs;
      r.expectedStatus = env.expectedStatus;
      r.path = PROBE_PATH_UNBOUND_UNKNOWN;
      r.coreCapability = coreCapability;
      r.source = PROBE_SOURCE_MANUAL;
      r.aggregation = PROBE_AGG_SINGLE;
      this.results.set(r.profileId, r);
    }
    this.phase = COORD_PHASE_RUNNING;
    return true;
  }

  isActive(): boolean {
    return this.phase === COORD_PHASE_RUNNING || this.phase === COORD_PHASE_CANCELLING;
  }

  getPhase(): string {
    return this.phase;
  }

  getGeneration(): number {
    return this.generation;
  }

  getRunId(): string {
    return this.runId;
  }

  getEnv(): ProbeEnv {
    return this.env;
  }

  getTargets(): Array<ProbeTarget> {
    return this.targets.slice(0);
  }

  getEnvError(): string {
    return this.envError;
  }

  /** 记录一次批量启动尝试；超预算返回 false(调用方报告未完成，不得偷偷改检测方式,§6.4-6)。 */
  noteAttempt(): boolean {
    if (this.attempts >= this.maxAttempts) {
      return false;
    }
    this.attempts = this.attempts + 1;
    return true;
  }

  getAttempts(): number {
    return this.attempts;
  }

  getMaxAttempts(): number {
    return this.maxAttempts;
  }

  /**
   * 批量启动失败 → 二分决策(§6.4-4/§6.4-5)。
   * - 长度 >1：拆成两组(前半/后半)，调用方串行尝试；
   * - 长度 =1：该节点被隔离为坏节点，返回 isolated(kind='isolated')；
   * - 预算耗尽：kind='exhausted'，调用方把未完成节点标 cancelled + errorCode(如实报未完成)。
   */
  onBatchStartFailed(batchProfileIds: Array<string>, reason: string): IsolationDecision {
    const d = new IsolationDecision();
    d.reason = reason;
    if (!this.noteAttempt()) {
      d.kind = 'exhausted';
      d.reason = reason.length > 0 ? reason : 'attempt_budget_exhausted';
      return d;
    }
    if (batchProfileIds.length <= 1) {
      d.kind = 'isolated';
      d.isolatedProfileId = batchProfileIds.length === 1 ? batchProfileIds[0] : '';
      return d;
    }
    const mid = Math.ceil(batchProfileIds.length / 2);
    const first: Array<string> = batchProfileIds.slice(0, mid);
    const second: Array<string> = batchProfileIds.slice(mid);
    d.kind = 'split';
    d.groups.push(first);
    d.groups.push(second);
    return d;
  }

  /** 环境级失败：只报一次；不把所有节点标成坏节点(§6.4-1/§6.4-7)。 */
  onEnvironmentFailure(reason: string, now: number): void {
    if (this.envErrorReported) {
      return;
    }
    this.envErrorReported = true;
    this.envError = reason;
    // 未开始的节点标记不适用(不是"坏节点")，正在进行的保持结果
    const ids = Array.from(this.results.keys());
    for (let i = 0; i < ids.length; i++) {
      const r = this.results.get(ids[i]);
      if (r !== undefined && r.state === PROBE_STATE_QUEUED) {
        r.state = PROBE_STATE_NOT_APPLICABLE;
        r.errorCode = reason;
        r.completedAt = now;
      }
    }
  }

  /**
   * 接受一个检测结果。runId 不匹配(上一轮/上一代)一律拒绝并返回 false(§6.5)。
   * latencyMs < 0 视为无效结果→failed(0ms 合法,§6.2)。
   */
  onNodeResult(result: ProbeResult): boolean {
    if (!this.isActive()) {
      return false;
    }
    if (result.runId !== this.runId) {
      return false;
    }
    const previous = this.results.get(result.profileId);
    if (previous === undefined) {
      return false;
    }
    if (previous.state !== PROBE_STATE_QUEUED && previous.state !== PROBE_STATE_RUNNING) {
      // 已终结的结果不接受再次覆盖(迟到回调)
      return false;
    }
    const next = result;
    if (next.state === PROBE_STATE_SUCCESS && next.latencyMs < 0) {
      next.state = PROBE_STATE_FAILED;
      next.errorCode = 'invalid_latency';
      next.errorDetail = 'success without latency';
    }
    if (next.methodActual === PROBE_METHOD_TCPING && next.methodRequested === PROBE_METHOD_HTTP &&
      next.degradedReason.length === 0) {
      // HTTP 回退 TCP 必须永久标明来源(§6.4-7)，不允许静默
      next.degradedReason = 'http_fallback_tcping';
    }
    if (next.methodActual === PROBE_METHOD_UNKNOWN) {
      // 未知方式不得声称成功可比较(§6.2)
      next.state = PROBE_STATE_NOT_APPLICABLE;
      next.errorCode = 'unknown_method';
    }
    this.results.set(next.profileId, next);
    return true;
  }

  /** 节点开始运行(UI 显示运行中，但不清除其持久化旧结果,§6.3)。 */
  markRunning(profileId: string, now: number): boolean {
    const r = this.results.get(profileId);
    if (r === undefined || r.state !== PROBE_STATE_QUEUED) {
      return false;
    }
    r.state = PROBE_STATE_RUNNING;
    r.startedAt = now;
    return true;
  }

  /** 取消：停止取新目标；处理中按取消上下文收尾；未执行节点标未参与并保留原结果(§6.3)。 */
  cancel(now: number): void {
    if (!this.isActive()) {
      return;
    }
    this.cancelled = true;
    this.phase = COORD_PHASE_CANCELLING;
    const ids = Array.from(this.results.keys());
    for (let i = 0; i < ids.length; i++) {
      const r = this.results.get(ids[i]);
      if (r !== undefined && r.state === PROBE_STATE_QUEUED) {
        r.state = PROBE_STATE_CANCELLED;
        r.participated = PROBE_PARTICIPATED_NO;
        r.completedAt = now;
      }
    }
  }

  isCancelled(): boolean {
    return this.cancelled;
  }

  /** 完成本轮(取消后也要完成)。返回摘要。 */
  finish(now: number): ProbeSummary {
    if (this.phase === COORD_PHASE_RUNNING || this.phase === COORD_PHASE_CANCELLING) {
      this.phase = this.cancelled ? COORD_PHASE_DONE : COORD_PHASE_DONE;
      this.finishedAt = now;
      const ids = Array.from(this.results.keys());
      for (let i = 0; i < ids.length; i++) {
        const r = this.results.get(ids[i]);
        if (r !== undefined && (r.state === PROBE_STATE_QUEUED || r.state === PROBE_STATE_RUNNING)) {
          r.state = PROBE_STATE_CANCELLED;
          r.participated = PROBE_PARTICIPATED_NO;
          r.completedAt = now;
        }
      }
    }
    return this.summary();
  }

  /** 预算耗尽时把未完成节点如实标 cancelled(§6.4-6)。 */
  markUnfinished(profileIds: Array<string>, now: number, reason: string): void {
    for (let i = 0; i < profileIds.length; i++) {
      const r = this.results.get(profileIds[i]);
      if (r !== undefined && (r.state === PROBE_STATE_QUEUED || r.state === PROBE_STATE_RUNNING)) {
        r.state = PROBE_STATE_CANCELLED;
        r.participated = PROBE_PARTICIPATED_NO;
        r.errorCode = reason;
        r.completedAt = now;
      }
    }
  }

  /** 写盘失败后由存储层回调：把该轮结果标 unsaved(不假装已保存,§6.3)。 */
  markUnsaved(): void {
    const ids = Array.from(this.results.keys());
    for (let i = 0; i < ids.length; i++) {
      const r = this.results.get(ids[i]);
      if (r !== undefined && r.persistedAt === 0) {
        r.state = PROBE_STATE_UNSAVED;
      }
    }
  }

  getResult(profileId: string): ProbeResult | null {
    const r = this.results.get(profileId);
    return r === undefined ? null : r;
  }

  getResults(): Array<ProbeResult> {
    const out: Array<ProbeResult> = [];
    const ids = Array.from(this.results.keys());
    for (let i = 0; i < ids.length; i++) {
      const r = this.results.get(ids[i]);
      if (r !== undefined) {
        out.push(r);
      }
    }
    return out;
  }

  summary(): ProbeSummary {
    const s = new ProbeSummary();
    const ids = Array.from(this.results.keys());
    s.total = ids.length;
    for (let i = 0; i < ids.length; i++) {
      const r = this.results.get(ids[i]);
      if (r === undefined) {
        continue;
      }
      if (r.state === PROBE_STATE_SUCCESS) {
        s.success = s.success + 1;
      } else if (r.state === PROBE_STATE_FAILED) {
        s.failed = s.failed + 1;
      } else if (r.state === PROBE_STATE_NOT_APPLICABLE) {
        s.notApplicable = s.notApplicable + 1;
      } else if (r.state === PROBE_STATE_CANCELLED) {
        s.cancelled = s.cancelled + 1;
      } else if (r.state === PROBE_STATE_UNSAVED) {
        s.unsaved = s.unsaved + 1;
      } else if (r.state === PROBE_STATE_QUEUED || r.state === PROBE_STATE_RUNNING) {
        s.unfinished = s.unfinished + 1;
      }
    }
    return s;
  }

  getStartedAt(): number {
    return this.startedAt;
  }

  getFinishedAt(): number {
    return this.finishedAt;
  }
}
