import {
  ProbeResult, PROBE_STATE_QUEUED, PROBE_STATE_RUNNING, PROBE_STATE_SUCCESS, PROBE_STATE_FAILED,
  PROBE_STATE_NOT_APPLICABLE, PROBE_STATE_CANCELLED, PROBE_STATE_UNSAVED,
  PROBE_METHOD_HTTP, PROBE_METHOD_TCPING,
  PROBE_AGG_SINGLE, PROBE_AGG_AVG,
  PROBE_EXPECT_ANY,
  PROBE_PATH_DIRECT_BOUND, PROBE_PATH_CURRENT_TUNNEL, PROBE_PATH_UNBOUND_UNKNOWN,
  PROBE_CAP_NATIVE_V3, PROBE_CAP_NATIVE_V2, PROBE_CAP_LEGACY, PROBE_CAP_UNAVAILABLE,
  PROBE_SOURCE_MANUAL
} from '../model/ProbeResult';
import {
  ProbeCoordinator, ProbeTarget, ProbeEnv, ProbeSummary,
  ENV_REASON_CORE_UNSUPPORTED, ENV_REASON_INVALID_TARGET, ENV_REASON_METHOD_UNSUPPORTED,
  ENV_REASON_TEST_DIR
} from './ProbeCoordinator';
import { ProbeRunSnapshot, ProbeResultRecord, ProbeRunSummary, ProbeStore } from './ProbeStore';

/**
 * ProbeRunner —— 检测运行器(P2/W09,REDESIGN-PLAN §6.3/§6.4/§6.5/§6.6)。
 *
 * 纯编排 + **可注入桥接**:本文件不 import CoreManager / @ohos.*,所有平台动作
 * (能力探测、会话启停、探测、配置写盘、TCPing 回退、结果落盘)都由 `ProbeRunnerDeps`
 * 注入,主机测试(tests/probe-runner.cjs)用 stub 桥接即可完整驱动,不联网不碰内核。
 * 生产接线在 utils/LatencyTester.ets。
 *
 * 三段关键时序(§6.5 会话与桥接并发约束):
 *
 * 1) 启动/隔离(§6.4-4/§6.4-6):
 *    初始一批=全部目标 → 构建只含本批 outbounds 的临时配置 → 启动测速会话。
 *    启动失败 → `ProbeCoordinator.onBatchStartFailed` 二分:串行尝试 [前半] 再 [后半],
 *    每组内部继续并发探测;长度=1 时该节点隔离为坏节点(failed + 内核原文);
 *    预算(启动次数 2N−1)耗尽 → `markUnfinished` 如实报未完成,不偷偷改检测方式。
 *    每次启动(无论成败)都算一次启动预算,避免"失败不计数"把最坏启动次数放大。
 *
 * 2) 探测/超时(§6.5):
 *    批内并发 = env.concurrency;单次探测桥接兜底超时 = bridgeTimeoutMs(默认 2×超时+5s)。
 *    **桥接超时 ≠ 原生已停**:超时只判该节点失败,绝不据此立刻开新会话 ——
 *    每批探测完必须 stop 确认(`testStopV3` 返回 ''),未确认时查 `testSessionInfoV3`,
 *    仍无法确认就结束本轮并把剩余节点记 `session_stop_unconfirmed`,不允许创建冲突实例。
 *
 * 3) 取消(§6.3):
 *    `cancel()` 转发 coordinator(queued → cancelled/未参与);正在飞行的探测**完成后照常接收**
 *    (coordinator 处于 cancelling 仍 isActive),随后停止取新目标、stop 一次并落盘已保存部分。
 *
 * 环境级失败(能力不支持/目录不可写/URL 非法,§6.4-1/§6.4-7):整轮不启动、只报一次,
 * 未执行节点记 notApplicable,`tcpingOption=true`(UI 提供"改用 TCPing 检测支持的节点"),
 * **绝不把环境问题标成坏节点**。
 */

// ---------------- 机器 token(便于测试与 i18n 映射) ----------------

/** 单个节点被隔离时的 errorCode(批量启动失败)。 */
export const PROBE_ERROR_BATCH_START_FAILED: string = 'batch_start_failed';
/** 探测失败(内核返回 err:...)。 */
export const PROBE_ERROR_PROBE_FAILED: string = 'probe_failed';
/** 探测超时类失败(i/o timeout / deadline / 桥接兜底超时)。 */
export const PROBE_ERROR_PROBE_TIMEOUT: string = 'probe_timeout';
/** 该节点出站构建失败(配置非法,tag 为空)。 */
export const PROBE_ERROR_OUTBOUND_BUILD: string = 'outbound_build_failed';
/** 预算耗尽(§6.4-6)。 */
export const PROBE_REASON_ATTEMPT_BUDGET: string = 'attempt_budget_exhausted';
/** 会话停止未确认:禁止开始下一批(§6.5)。 */
export const PROBE_REASON_SESSION_UNCONFIRMED: string = 'session_stop_unconfirmed';
/** 逐节点 HTTP→TCPing 回退的永久标记(§6.4-7)。 */
export const PROBE_DEGRADED_HTTP_FALLBACK_TCPING: string = 'http_fallback_tcping';
/** 已有检测在跑(并发拒绝,§6.5)。 */
export const PROBE_BUSY_ERROR: string = 'probe_busy';

const CAPS_TIMEOUT_MS: number = 10000;
const SESSION_INFO_TIMEOUT_MS: number = 5000;
const CLOSE_SESSION_TIMEOUT_MS: number = 10000;

// ---------------- 注入桥接 ----------------

/**
 * 内核测速桥接(生产实现 = CoreManager 的 V3/V2/legacy 导出)。
 * 语义与既有 V2 一致:proxy 返回延迟数字或 "err:...";start/stop 成功返回 ""。
 */
export interface ProbeBridge {
  /** 'v3' | 'v2' | 'legacy'(空串=内核未加载)。 */
  caps(): Promise<string>;
  startV3(sessionId: string, configPath: string, bindIfname: string): Promise<string>;
  proxyV3(sessionId: string, tag: string, url: string, timeoutMs: number, expectStatus: string): Promise<string>;
  stopV3(sessionId: string): Promise<string>;
  /** K2 会话快照 JSON(state=starting|active|stopping|closed)或 '' = 未知会话。 */
  sessionInfoV3(sessionId: string): Promise<string>;
  /** 当前 active 的 sessionId(逗号分隔);'' = 无。用于清理上一轮崩溃残留。 */
  activeSessions(): Promise<string>;
  /** 旧 V2 导出(无 sessionId,串行使用)。 */
  start(configPath: string, bindIfname: string): Promise<string>;
  proxy(tag: string, url: string, timeoutMs: number, expectStatus: string): Promise<string>;
  stop(): Promise<string>;
}

/** 一批目标的临时配置(只含本批 outbounds);tags 与 batch 顺序对齐,空串=该节点构建失败。 */
export class ProbeBatchConfig {
  json: string = '';
  tags: Array<string> = [];
}

/** 逐节点 TCP 回退结果(LatencyTester 的 tcpPingOnce 投影)。 */
export class ProbeTcpResult {
  ok: boolean = false;
  latencyMs: number = -1;
  error: string = '';
}

/** 测试目录可写性探针结论(§6.4-1):失败时带上原文,便于界面给出真实原因。 */
export class ProbeDirProbe {
  writable: boolean = true;
  error: string = '';
}

/** 运行器依赖:全部可注入,便于主机测试;生产由 LatencyTester 组装。 */
export class ProbeRunnerDeps {
  bridge: ProbeBridge | null = null;
  /** 本批配置构建(调用方闭包持有 allProfiles/settings/groups)。 */
  buildBatch: ((batch: Array<ProbeTarget>) => ProbeBatchConfig) | null = null;
  /** 配置写盘并返回路径;失败必须 throw(环境级失败)。 */
  writeConfig: ((json: string) => string) | null = null;
  /** 逐节点 TCPing(opts.allowTcpFallbackPerNode 时才调用)。 */
  tcpPing: ((profileId: string) => Promise<ProbeTcpResult>) | null = null;
  /** 结果落盘(默认 ProbeStore.saveRun)。 */
  saveRun: ((run: ProbeRunSnapshot) => Promise<boolean>) | null = null;
  /** 写盘失败后的存储层标记(默认 ProbeStore.markUnsaved)。 */
  markUnsaved: ((runId: string) => Promise<void>) | null = null;
  /** VPN 是否在运行(path 判定用,§6.2)。 */
  isVpnRunning: (() => boolean) | null = null;
  /** 测试目录可写性探针(不 fsync 目录;默认视为可写)。 */
  probeDir: (() => ProbeDirProbe) | null = null;
  now: (() => number) | null = null;
  log: ((line: string) => void) | null = null;
}

/** 单轮选项(env 之外、调用方语义层面的参数)。 */
export class ProbeRoundOptions {
  source: string = PROBE_SOURCE_MANUAL;
  configRevision: number = 0;
  /** 绑定物理网卡名(空串=不绑定;仅 V2/V3 生效,legacy 一律 unboundUnknown)。 */
  bindIfname: string = '';
  /** 逐节点 HTTP→TCPing 回退开关(§6.4-7:只有用户明确开启时)。 */
  allowTcpFallbackPerNode: boolean = false;
  startTimeoutMs: number = 30000;
  stopTimeoutMs: number = 15000;
  /** 单次探测桥接兜底超时;0 = 自动(timeout×2+5000)。 */
  bridgeTimeoutMs: number = 0;
  /**
   * 启动次数上限(§6.4-6 的"累计准备上限");0 = 默认 2N−1。
   * 调用方可用更小值收紧最坏耗时;达到上限一律如实报未完成,不改检测方式。
   */
  maxStarts: number = 0;
  /** 外部取消信号(UI 的「取消」按钮),工作线程每个节点前轮询。 */
  isCancelled: (() => boolean) | null = null;
  /** 单节点状态回调(running/final),LatencyTester 投影成旧 TestResult 供现有 UI 使用。 */
  onResult: ((r: ProbeResult) => void) | null = null;
}

/** 单轮结果(§6.3 完成摘要 + §6.4-7 环境级说明 + §6.6 产品语义)。 */
export class ProbeRoundOutcome {
  runId: string = '';
  generation: number = 0;
  /** native-v3 / native-v2 / legacy / unavailable */
  capability: string = PROBE_CAP_UNAVAILABLE;
  sessionId: string = '';
  /** directBound / currentTunnel / unboundUnknown(§6.2:未知路径不假装直出) */
  path: string = PROBE_PATH_UNBOUND_UNKNOWN;
  /** 实际参与探测的节点数(success + failed + unsaved) */
  tested: number = 0;
  /** 本轮是否至少有一次批量启动成功(未启动则不存在"绑定网卡导致全红"的可能) */
  sessionStarted: boolean = false;
  /** 本轮是否真的写盘成功(§6.3:写失败不假装已保存) */
  saved: boolean = false;
  /** 预算耗尽/会话未确认等未完成节点数(如实计数,不回退方法) */
  unfinished: number = 0;
  /** 环境级失败时 UI 提供"改用 TCPing 检测支持的节点"(§6.4-7) */
  tcpingOption: boolean = false;
  degraded: boolean = false;
  degradeReason: string = '';
  /** 环境级失败原因 token(core_unsupported/test_dir_unwritable/...),''=无 */
  envError: string = '';
  /** 并发拒绝时的错误 token(probe_busy);''=正常执行 */
  error: string = '';
  summary: ProbeSummary = new ProbeSummary();
  results: Array<ProbeResult> = [];
}

// ---------------- 内部类型 ----------------

/** 一次批量启动的结论。 */
class BatchAttempt {
  /** ok | start_failed | env_failed | stop_unconfirmed */
  kind: string = 'ok';
  error: string = '';
  envReason: string = '';
}

/** 一次桥接探测的结论。0ms 合法(§6.2)。 */
class ProbeAttempt {
  ok: boolean = false;
  latencyMs: number = -1;
  error: string = '';
  timedOut: boolean = false;
}

/** 单轮运行上下文(避免在方法间传十几个参数)。 */
class ProbeRunContext {
  bridge: ProbeBridge | null = null;
  targets: Array<ProbeTarget> = [];
  targetMap: Map<string, ProbeTarget> = new Map<string, ProbeTarget>();
  env: ProbeEnv = new ProbeEnv();
  opts: ProbeRoundOptions = new ProbeRoundOptions();
  out: ProbeRoundOutcome = new ProbeRoundOutcome();
  runId: string = '';
  sessionId: string = '';
  capability: string = PROBE_CAP_UNAVAILABLE;
  useV3: boolean = false;
  path: string = PROBE_PATH_UNBOUND_UNKNOWN;
  /** 启动次数预算(2N−1,§6.4-6),每次启动都计数。 */
  maxStarts: number = 0;
  startsUsed: number = 0;
}

// ---------------- 纯工具函数 ----------------

/** HTTP(S) 检测地址是否可用(§6.1:无效时给错误,不擅自替换)。 */
export function isValidProbeUrl(url: string): boolean {
  const trimmed = url.trim();
  if (trimmed.length === 0) {
    return false;
  }
  const lower = trimmed.toLowerCase();
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
    return false;
  }
  const rest = trimmed.substring(trimmed.indexOf('://') + 3);
  if (rest.length === 0 || rest.indexOf(' ') >= 0) {
    return false;
  }
  const pathStart = rest.indexOf('/');
  const authority = pathStart >= 0 ? rest.substring(0, pathStart) : rest;
  if (authority.length === 0) {
    return false;
  }
  // 去掉端口(IPv6 字面量以 '[' 开头,方括号后再看 ':' 端口)
  if (authority.startsWith('[')) {
    const bracket = authority.indexOf(']');
    return bracket > 1;
  }
  const colon = authority.indexOf(':');
  const host = colon >= 0 ? authority.substring(0, colon) : authority;
  return host.length > 0;
}

function averageOf(values: Array<number>): number {
  let sum = 0;
  for (let i = 0; i < values.length; i++) {
    sum += values[i];
  }
  return Math.round(sum / values.length);
}

/** 解析桥接返回:"ms"(含 0)/ "err:..." / 异常文本。 */
function parseProbeResponse(raw: string): ProbeAttempt {
  const out = new ProbeAttempt();
  const text = raw.trim();
  if (text.startsWith('err:') || text.startsWith('内核不支持')) {
    out.ok = false;
    out.error = text.startsWith('err:') ? text.substring(4).trim() : text;
    const lower = out.error.toLowerCase();
    out.timedOut = lower.indexOf('timeout') >= 0 || lower.indexOf('deadline') >= 0 ||
      lower.indexOf('超时') >= 0;
    return out;
  }
  const n = parseInt(text);
  if (isNaN(n) || n < 0) {
    out.ok = false;
    out.error = `unexpected probe result: ${raw}`;
    out.timedOut = false;
    return out;
  }
  out.ok = true;
  out.latencyMs = n; // 0ms 是合法数值(§6.2)
  return out;
}

// ---------------- 运行器 ----------------

export class ProbeRunner {
  private coord: ProbeCoordinator;
  private deps: ProbeRunnerDeps;

  constructor(coord: ProbeCoordinator, deps: ProbeRunnerDeps) {
    this.coord = coord;
    this.deps = deps;
  }

  getCoordinator(): ProbeCoordinator {
    return this.coord;
  }

  /** 取消(§6.3):转发 coordinator;正在飞行的探测完成后仍接收,未执行节点标未参与。 */
  cancel(): void {
    this.coord.cancel(this.now());
  }

  /**
   * 受 runId 守卫的结果入口(§6.5):迟到的上一轮/上一代回调一律拒绝返回 false,
   * 不会写入本轮。运行器内部所有最终结果都经这里进入 coordinator。
   */
  ingestResult(result: ProbeResult): boolean {
    return this.coord.onNodeResult(result);
  }

  /** 执行一轮检测。 */
  async runProbeRound(targets: Array<ProbeTarget>, env: ProbeEnv,
    opts: ProbeRoundOptions): Promise<ProbeRoundOutcome> {
    const out = new ProbeRoundOutcome();
    const startedAt = this.now();
    out.runId = this.newRunId(startedAt);
    out.sessionId = out.runId;
    const bridge = this.deps.bridge;
    if (bridge === null) {
      out.error = 'probe_bridge_missing';
      return out;
    }
    // 能力探测(如实写进 ProbeResult.coreCapability,§6.2)
    const capsRaw = await this.withTimeout<string>(bridge.caps(), CAPS_TIMEOUT_MS, '');
    out.capability = this.capabilityOf(capsRaw);
    if (!this.coord.begin(out.runId, targets, env, out.capability, startedAt)) {
      // 同一时刻只允许一轮(§6.5);并发请求明确拒绝,不排队、不覆盖
      out.error = PROBE_BUSY_ERROR;
      return out;
    }
    out.generation = this.coord.getGeneration();
    // 由 coordinator 记账的节点(取消/预算/环境失败)也要带上本轮元数据
    this.stageCoordinatorResults(out, opts);
    // 环境前提(整轮一次,§6.4-1):能力/目录可写/URL 合法/方式受支持
    const capabilityOk = out.capability === PROBE_CAP_NATIVE_V3 || out.capability === PROBE_CAP_NATIVE_V2;
    const methodSupported = env.method === PROBE_METHOD_HTTP;
    let dirWritable = true;
    let dirError = '';
    const dirProbe = this.deps.probeDir;
    if (dirProbe !== null) {
      const probed = dirProbe();
      dirWritable = probed.writable;
      dirError = probed.error;
    }
    const urlValid = isValidProbeUrl(env.target);
    const envReason = ProbeCoordinator.precheckEnv(capabilityOk, dirWritable, urlValid, methodSupported);
    if (envReason.length > 0) {
      this.endEnvironmentFailure(out, envReason,
        this.envFailureText(envReason, capsRaw, env.target, dirError), opts);
      await this.saveRound(out);
      return out;
    }
    out.path = this.resolvePath(env, opts, capabilityOk);
    const staged = this.coord.getResults();
    for (let i = 0; i < staged.length; i++) {
      staged[i].path = out.path;
    }
    const ctx = new ProbeRunContext();
    ctx.bridge = bridge;
    ctx.targets = targets.slice(0);
    for (let i = 0; i < targets.length; i++) {
      ctx.targetMap.set(targets[i].profileId, targets[i]);
    }
    ctx.env = env;
    ctx.opts = opts;
    ctx.out = out;
    ctx.runId = out.runId;
    ctx.sessionId = out.sessionId;
    ctx.capability = out.capability;
    ctx.useV3 = out.capability === PROBE_CAP_NATIVE_V3;
    ctx.path = out.path;
    ctx.maxStarts = opts.maxStarts > 0 ? opts.maxStarts : ProbeCoordinator.attemptsBudget(targets.length);
    if (ctx.useV3) {
      // 串行语义兜底:上一轮崩溃残留的其它会话必须清掉,否则 startV3 一直被拒
      await this.cleanupStaleSessions(ctx);
    }
    await this.runIsolationLoop(ctx);
    this.finishRound(out);
    await this.saveRound(out);
    return out;
  }

  // ------------------------------ 隔离主循环 ------------------------------

  private async runIsolationLoop(ctx: ProbeRunContext): Promise<void> {
    // 初始一批 = 全部目标(§6.4-3),之后按二分结果串行补跑
    const queue: Array<Array<string>> = [];
    const all: Array<string> = [];
    for (let i = 0; i < ctx.targets.length; i++) {
      all.push(ctx.targets[i].profileId);
    }
    queue.push(all);
    while (queue.length > 0) {
      if (ctx.out.error.length > 0) {
        return;
      }
      if (this.isCancelled(ctx)) {
        this.coord.cancel(this.now());
        return;
      }
      const batch = queue[0];
      queue.splice(0, 1);
      // 启动次数预算(§6.4-6):达到上限如实报未完成,不偷偷改检测方式
      if (ctx.startsUsed >= ctx.maxStarts) {
        this.markUnfinished(ctx, batch, queue, PROBE_REASON_ATTEMPT_BUDGET);
        return;
      }
      const attempt = await this.attemptBatch(ctx, batch);
      if (attempt.kind === 'env_failed') {
        this.endEnvironmentFailure(ctx.out, attempt.envReason, attempt.error, ctx.opts);
        return;
      }
      if (attempt.kind === 'stop_unconfirmed') {
        this.markUnfinished(ctx, batch, queue, PROBE_REASON_SESSION_UNCONFIRMED);
        return;
      }
      if (attempt.kind === 'start_failed') {
        const decision = this.coord.onBatchStartFailed(batch, attempt.error);
        if (decision.kind === 'split') {
          // §6.4-4:两组串行 —— 先第一组,再第二组
          if (decision.groups.length >= 2) {
            queue.unshift(decision.groups[1]);
            queue.unshift(decision.groups[0]);
          }
        } else if (decision.kind === 'isolated') {
          this.markIsolationFailure(ctx, decision.isolatedProfileId, attempt.error, queue);
        } else {
          // 预算耗尽(coordinator 侧)
          this.markUnfinished(ctx, batch, queue, PROBE_REASON_ATTEMPT_BUDGET);
          return;
        }
      }
      // attempt.kind === 'ok':继续下一批;取消时下一轮循环头会退出
    }
  }

  /** 尝试启动并探测一批;失败原因交由隔离循环决策。 */
  private async attemptBatch(ctx: ProbeRunContext, batch: Array<string>): Promise<BatchAttempt> {
    const attempt = new BatchAttempt();
    const bridge = ctx.bridge;
    if (bridge === null) {
      attempt.kind = 'env_failed';
      attempt.envReason = ENV_REASON_TEST_DIR;
      attempt.error = '检测桥接不可用';
      return attempt;
    }
    // 1. 构建只含本批 outbounds 的临时配置并写盘(写盘失败=环境级,§6.4-1)
    const batchTargets: Array<ProbeTarget> = [];
    for (let i = 0; i < batch.length; i++) {
      const t = ctx.targetMap.get(batch[i]);
      if (t !== undefined) {
        batchTargets.push(t);
      }
    }
    let cfg: ProbeBatchConfig;
    try {
      cfg = this.buildBatch(batchTargets);
    } catch (e) {
      attempt.kind = 'env_failed';
      attempt.envReason = ENV_REASON_TEST_DIR;
      attempt.error = `检测配置生成失败: ${this.errorText(e)}`;
      return attempt;
    }
    let configPath = '';
    try {
      configPath = this.writeConfig(cfg.json);
    } catch (e) {
      attempt.kind = 'env_failed';
      attempt.envReason = ENV_REASON_TEST_DIR;
      attempt.error = `检测配置写入失败: ${this.errorText(e)}`;
      return attempt;
    }
    // 2. V2 无会话隔离:每批开始前尽力清掉可能残留的旧会话(串行 + 代次守卫兜底)
    if (!ctx.useV3) {
      const preErr = await this.withTimeout<string>(bridge.stop(), ctx.opts.stopTimeoutMs,
        'err:test stop bridge timeout');
      if (preErr.length > 0) {
        this.log(`[probe] 开测前清理旧会话报错(忽略): ${preErr}`);
      }
    }
    // 3. 启动
    ctx.startsUsed = ctx.startsUsed + 1;
    const startPromise = ctx.useV3
      ? bridge.startV3(ctx.sessionId, configPath, ctx.opts.bindIfname)
      : bridge.start(configPath, ctx.opts.bindIfname);
    const startErr = await this.withTimeout<string>(startPromise, ctx.opts.startTimeoutMs,
      'err:test start bridge timeout');
    if (startErr.length > 0) {
      attempt.kind = 'start_failed';
      attempt.error = startErr.startsWith('err:') ? startErr.substring(4).trim() : startErr;
      // 4. 迟到创建成功的实例必须立即关闭,并确认,避免下一批复用到旧配置(§6.5)
      const closed = await this.stopAndConfirm(ctx);
      if (!closed) {
        attempt.kind = 'stop_unconfirmed';
        attempt.error = `${attempt.error}(会话停止未确认)`;
      }
      return attempt;
    }
    // 5. 探测批内节点(批内并发 = env.concurrency)
    await this.probeBatch(ctx, batch, cfg.tags);
    ctx.out.sessionStarted = true;
    // 6. stop 确认成功后才允许下一批(§6.5:超时≠已停止)
    const confirmed = await this.stopAndConfirm(ctx);
    if (!confirmed) {
      attempt.kind = 'stop_unconfirmed';
      attempt.error = '测速会话停止未确认';
      return attempt;
    }
    attempt.kind = 'ok';
    return attempt;
  }

  /** 批内探测:并发 worker 共享游标;取消时停止取新目标,在飞结果仍接收。 */
  private async probeBatch(ctx: ProbeRunContext, batch: Array<string>, tags: Array<string>): Promise<void> {
    let next = 0;
    const total = batch.length;
    const concurrency = ctx.env.concurrency > 0 ? ctx.env.concurrency : 1;
    const worker = async (): Promise<void> => {
      while (true) {
        if (this.isCancelled(ctx)) {
          this.coord.cancel(this.now());
          return;
        }
        const index = next;
        next++;
        if (index >= total) {
          return;
        }
        const profileId = batch[index];
        const target = ctx.targetMap.get(profileId);
        if (target === undefined) {
          continue;
        }
        const tag = index < tags.length ? tags[index] : '';
        await this.probeOne(ctx, target, tag);
      }
    };
    const workers: Array<Promise<void>> = [];
    const n = concurrency < total ? concurrency : total;
    for (let i = 0; i < n; i++) {
      workers.push(worker());
    }
    await Promise.all(workers);
  }

  /** 单节点:markRunning → 取样/重试探测 → 归一结果 → (可选)逐节点 TCP 回退 → 接收。 */
  private async probeOne(ctx: ProbeRunContext, target: ProbeTarget, tag: string): Promise<void> {
    const startedAt = this.now();
    this.coord.markRunning(target.profileId, startedAt);
    const running = this.buildResult(ctx, target);
    running.state = PROBE_STATE_RUNNING;
    running.startedAt = startedAt;
    this.emit(ctx, running);
    const round = ctx.env.samples > 0 ? ctx.env.samples : 1;
    const extra = ctx.env.retries > 0 ? ctx.env.retries : 0;
    const ok: Array<number> = [];
    let lastError = '';
    let lastTimedOut = false;
    let attempts = 0;
    if (tag.length === 0) {
      // 该节点出站构建失败(配置非法):只红这一个,不拖垮整批
      lastError = 'outbound build failed';
      attempts = 1;
    } else {
      for (let a = 0; a < round + extra; a++) {
        if (this.isCancelled(ctx)) {
          break;
        }
        const probe = await this.probeOnceBridge(ctx, tag);
        attempts++;
        if (probe.ok) {
          ok.push(probe.latencyMs);
        } else {
          lastError = probe.error;
          lastTimedOut = probe.timedOut;
        }
        // 超时失败不再重试:满等一次已足够判死(死节点 2×超时 → 1×超时)
        if (probe.timedOut) {
          break;
        }
        if (ok.length >= round) {
          break;
        }
      }
    }
    const result = this.buildResult(ctx, target);
    result.startedAt = startedAt;
    result.completedAt = this.now();
    result.samples = attempts > 0 ? attempts : 1;
    if (ok.length > 0) {
      result.state = PROBE_STATE_SUCCESS;
      result.latencyMs = averageOf(ok);
      result.aggregation = ok.length > 1 ? PROBE_AGG_AVG : PROBE_AGG_SINGLE;
    } else {
      result.state = PROBE_STATE_FAILED;
      result.latencyMs = -1;
      result.errorCode = tag.length === 0 ? PROBE_ERROR_OUTBOUND_BUILD
        : (lastTimedOut ? PROBE_ERROR_PROBE_TIMEOUT : PROBE_ERROR_PROBE_FAILED);
      result.errorDetail = lastError;
    }
    // 逐节点 HTTP→TCPing 回退(§6.4-7):只有调用方显式开启且该节点失败时,
    // 且只对失败节点;成功节点保持 methodActual='http'。回退来源永久标明。
    const tcpPingFn = this.deps.tcpPing;
    if (result.state === PROBE_STATE_FAILED && ctx.opts.allowTcpFallbackPerNode &&
      tcpPingFn !== null) {
      const tcp = await tcpPingFn(target.profileId);
      result.methodActual = PROBE_METHOD_TCPING;
      result.degradedReason = PROBE_DEGRADED_HTTP_FALLBACK_TCPING;
      if (tcp.ok) {
        result.state = PROBE_STATE_SUCCESS;
        result.latencyMs = tcp.latencyMs;
        result.errorCode = '';
        result.errorDetail = '';
      } else {
        result.errorDetail = tcp.error.length > 0 ? tcp.error : lastError;
      }
    }
    const accepted = this.ingestResult(result);
    if (accepted) {
      this.emit(ctx, result);
    }
  }

  private async probeOnceBridge(ctx: ProbeRunContext, tag: string): Promise<ProbeAttempt> {
    const bridge = ctx.bridge;
    if (bridge === null) {
      const missing = new ProbeAttempt();
      missing.error = 'probe bridge missing';
      return missing;
    }
    const timeoutMs = ctx.env.timeoutMs > 0 ? ctx.env.timeoutMs : 5000;
    const bridgeTimeout = ctx.opts.bridgeTimeoutMs > 0 ? ctx.opts.bridgeTimeoutMs : timeoutMs * 2 + 5000;
    const promise = ctx.useV3
      ? bridge.proxyV3(ctx.sessionId, tag, ctx.env.target, timeoutMs, ctx.env.expectedStatus)
      : bridge.proxy(tag, ctx.env.target, timeoutMs, ctx.env.expectedStatus);
    const raw = await this.withTimeout<string>(promise, bridgeTimeout, 'err:bridge timeout');
    return parseProbeResponse(raw);
  }

  // ------------------------------ 隔离/未完成记账 ------------------------------

  /**
   * 隔离坏节点(§6.4-5):该节点 failed + 内核原文(带 chainKey,保留依赖链位置);
   * 共享同一 chainKey 的其它根节点得到**相同**依赖错误,不谎称只有一行有问题。
   */
  private markIsolationFailure(ctx: ProbeRunContext, profileId: string,
    reason: string, queue: Array<Array<string>>): void {
    const isolated = ctx.targetMap.get(profileId);
    const chainKey = isolated !== undefined ? isolated.chainKey : '';
    const detail = chainKey.length > 0 ? `${reason} [chain=${chainKey}]` : reason;
    const affected: Array<string> = [];
    if (profileId.length > 0) {
      affected.push(profileId);
    }
    if (chainKey.length > 0) {
      for (let i = 0; i < ctx.targets.length; i++) {
        const t = ctx.targets[i];
        if (t.profileId !== profileId && t.chainKey === chainKey) {
          affected.push(t.profileId);
        }
      }
    }
    const nowMs = this.now();
    for (let i = 0; i < affected.length; i++) {
      const t = ctx.targetMap.get(affected[i]);
      if (t === undefined) {
        continue;
      }
      const current = this.coord.getResult(t.profileId);
      if (current === null ||
        (current.state !== PROBE_STATE_QUEUED && current.state !== PROBE_STATE_RUNNING)) {
        continue; // 已有结果(成功/已被隔离)不覆盖
      }
      const result = this.buildResult(ctx, t);
      result.state = PROBE_STATE_FAILED;
      result.completedAt = nowMs;
      result.latencyMs = -1;
      result.errorCode = PROBE_ERROR_BATCH_START_FAILED;
      result.errorDetail = detail;
      if (this.ingestResult(result)) {
        this.emit(ctx, result);
      }
    }
    this.removeFromQueue(queue, affected);
    this.log(`[probe] 批量启动失败,隔离节点 ${affected.join(', ')}(含共享依赖 ${chainKey})`);
  }

  /** 预算耗尽/停止未确认:未完成节点如实标 cancelled + reason,不回退检测方式。 */
  private markUnfinished(ctx: ProbeRunContext, batch: Array<string>,
    queue: Array<Array<string>>, reason: string): void {
    const ids: Array<string> = [];
    for (let i = 0; i < batch.length; i++) {
      ids.push(batch[i]);
    }
    for (let i = 0; i < queue.length; i++) {
      for (let j = 0; j < queue[i].length; j++) {
        ids.push(queue[i][j]);
      }
    }
    let count = 0;
    for (let i = 0; i < ids.length; i++) {
      const r = this.coord.getResult(ids[i]);
      if (r !== null && (r.state === PROBE_STATE_QUEUED || r.state === PROBE_STATE_RUNNING)) {
        count++;
      }
    }
    this.coord.markUnfinished(ids, this.now(), reason);
    ctx.out.unfinished = ctx.out.unfinished + count;
    queue.splice(0, queue.length);
    this.log(`[probe] 未完成 ${count} 个节点(${reason})`);
  }

  private removeFromQueue(queue: Array<Array<string>>, ids: Array<string>): void {
    for (let i = 0; i < queue.length; i++) {
      const kept: Array<string> = [];
      for (let j = 0; j < queue[i].length; j++) {
        if (ids.indexOf(queue[i][j]) < 0) {
          kept.push(queue[i][j]);
        }
      }
      queue[i] = kept;
    }
    for (let i = queue.length - 1; i >= 0; i--) {
      if (queue[i].length === 0) {
        queue.splice(i, 1);
      }
    }
  }

  // ------------------------------ 会话停止确认 ------------------------------

  /**
   * 停止当前批的测速会话并确认(§6.5):stop 返回 '' = 已确认;
   * 否则查 sessionInfoV3:'' = 已无该会话;其它 = 仍存在/不可确认 → false(禁止下一批)。
   * V2(无 sessionId)只有 stop 返回值可依据。
   */
  private async stopAndConfirm(ctx: ProbeRunContext): Promise<boolean> {
    const bridge = ctx.bridge;
    if (bridge === null) {
      return true;
    }
    if (!ctx.useV3) {
      const err = await this.withTimeout<string>(bridge.stop(), ctx.opts.stopTimeoutMs,
        'err:test stop bridge timeout');
      if (err.length === 0) {
        return true;
      }
      this.log(`[probe] 停止测速会话报错(未确认): ${err}`);
      return false;
    }
    const stopErr = await this.withTimeout<string>(bridge.stopV3(ctx.sessionId), ctx.opts.stopTimeoutMs,
      'err:test stop bridge timeout');
    if (stopErr.length === 0) {
      return true;
    }
    this.log(`[probe] stopV3 未确认(${stopErr}),查询会话状态…`);
    const info = await this.withTimeout<string>(bridge.sessionInfoV3(ctx.sessionId),
      SESSION_INFO_TIMEOUT_MS, 'err:session info timeout');
    if (info.length === 0) {
      return true; // 已无该会话
    }
    // K2 快照:state=closed 视为已确认;starting/active/stopping 或 'unsupported' 一律不可确认
    if (info.indexOf('"closed"') >= 0) {
      return true;
    }
    this.log(`[probe] 会话仍可能存在(${info}),禁止开始下一批(内核检测任务正在收尾)`);
    return false;
  }

  /**
   * 清理上一轮崩溃残留的其它测速会话(V3):testStartV3 是串行语义
   * ("another test session ... is active"),不清理会让本轮永远起不来。
   * 只停**其它** id,绝不触碰本轮自己的 sessionId。
   */
  private async cleanupStaleSessions(ctx: ProbeRunContext): Promise<void> {
    const bridge = ctx.bridge;
    if (bridge === null) {
      return;
    }
    const raw = await this.withTimeout<string>(bridge.activeSessions(), SESSION_INFO_TIMEOUT_MS, '');
    if (raw.length === 0) {
      return;
    }
    const ids = raw.split(',');
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i].trim();
      if (id.length === 0 || id === ctx.sessionId) {
        continue;
      }
      this.log(`[probe] 清理上一轮残留测速会话: ${id}`);
      await this.withTimeout<string>(bridge.stopV3(id), CLOSE_SESSION_TIMEOUT_MS, '');
    }
  }

  // ------------------------------ 轮次收尾 ------------------------------

  /** 环境级失败:只报一次;未执行节点 notApplicable(不标坏节点),提供 TCPing 选项。 */
  private endEnvironmentFailure(out: ProbeRoundOutcome, reason: string, detail: string,
    opts: ProbeRoundOptions): void {
    const nowMs = this.now();
    this.coord.onEnvironmentFailure(reason, nowMs);
    out.envError = reason;
    out.degraded = true;
    out.degradeReason = detail;
    out.tcpingOption = true;
    out.summary = this.coord.finish(nowMs);
    out.results = this.coord.getResults();
    out.tested = 0;
    this.log(`[probe] 环境级失败(${reason}): ${detail}；本轮不启动测速实例,可改用 TCPing`);
  }

  private finishRound(out: ProbeRoundOutcome): void {
    const nowMs = this.now();
    out.summary = this.coord.finish(nowMs);
    out.results = this.coord.getResults();
    out.tested = this.countTested(out.results);
    // 逐节点 TCP 回退的完成摘要必须永久标明来源(§6.4-7)
    if (!out.degraded) {
      for (let i = 0; i < out.results.length; i++) {
        const r = out.results[i];
        if (r.methodActual === PROBE_METHOD_TCPING && r.methodRequested === PROBE_METHOD_HTTP) {
          out.degraded = true;
          out.degradeReason = '部分节点已改用 TCPing 检测(只反映握手耗时,不代表真连接可用)';
          break;
        }
      }
    }
  }

  private countTested(results: Array<ProbeResult>): number {
    let tested = 0;
    for (let i = 0; i < results.length; i++) {
      const state = results[i].state;
      if (state === PROBE_STATE_SUCCESS || state === PROBE_STATE_FAILED || state === PROBE_STATE_UNSAVED) {
        tested++;
      }
    }
    return tested;
  }

  /** 落盘一轮结果(§6.3):false → coordinator + ProbeStore 都标 unsaved,outcome.saved=false。 */
  private async saveRound(out: ProbeRoundOutcome): Promise<void> {
    const snapshot = new ProbeRunSnapshot();
    snapshot.runId = out.runId;
    snapshot.generation = out.generation;
    snapshot.createdAt = this.coord.getStartedAt();
    snapshot.completedAt = this.now();
    snapshot.summary = copySummary(out.summary);
    for (let i = 0; i < out.results.length; i++) {
      snapshot.results.push(toResultRecord(out.results[i]));
    }
    const injected = this.deps.saveRun;
    let saved = false;
    try {
      saved = injected !== null ? await injected(snapshot) : await ProbeStore.saveRun(snapshot);
    } catch (e) {
      this.log(`[probe] saveRun 异常: ${this.errorText(e)}`);
      saved = false;
    }
    out.saved = saved;
    if (saved) {
      return;
    }
    // 不假装已保存:内存里也标 unsaved,并把标记同步给存储层
    this.coord.markUnsaved();
    out.results = this.coord.getResults();
    out.tested = this.countTested(out.results);
    const markFn = this.deps.markUnsaved;
    try {
      if (markFn !== null) {
        await markFn(out.runId);
      } else {
        await ProbeStore.markUnsaved(out.runId);
      }
    } catch (e) {
      this.log(`[probe] markUnsaved 异常(忽略): ${this.errorText(e)}`);
    }
    this.log(`[probe] 检测结果写盘失败,已标记未保存(${out.runId})`);
  }

  /** 由 coordinator 记账的节点(取消/预算/环境失败)补齐本轮元数据。 */
  private stageCoordinatorResults(out: ProbeRoundOutcome, opts: ProbeRoundOptions): void {
    const staged = this.coord.getResults();
    for (let i = 0; i < staged.length; i++) {
      staged[i].configRevision = opts.configRevision;
      staged[i].source = opts.source;
      staged[i].coreCapability = out.capability;
    }
  }

  // ------------------------------ 基础构造/判定 ------------------------------

  private buildResult(ctx: ProbeRunContext, target: ProbeTarget): ProbeResult {
    const r = new ProbeResult();
    r.runId = ctx.runId;
    r.profileId = target.profileId;
    r.configRevision = ctx.opts.configRevision;
    r.profileConfigHash = target.profileConfigHash;
    r.methodRequested = ctx.env.method;
    r.methodActual = ctx.env.method;
    r.state = PROBE_STATE_QUEUED;
    r.target = ctx.env.target;
    r.timeoutMs = ctx.env.timeoutMs;
    r.expectedStatus = ctx.env.expectedStatus;
    r.path = ctx.path;
    r.coreCapability = ctx.capability;
    r.source = ctx.opts.source;
    r.aggregation = PROBE_AGG_SINGLE;
    return r;
  }

  /** path 判定(§6.2):直出必须能确认绑定;未知路径绝不假装直出。 */
  private resolvePath(env: ProbeEnv, opts: ProbeRoundOptions, capabilityOk: boolean): string {
    if (env.bypassVpn && opts.bindIfname.length > 0 && capabilityOk) {
      return PROBE_PATH_DIRECT_BOUND;
    }
    const running = this.deps.isVpnRunning !== null ? this.deps.isVpnRunning() : false;
    if (!env.bypassVpn && running) {
      return PROBE_PATH_CURRENT_TUNNEL;
    }
    return PROBE_PATH_UNBOUND_UNKNOWN;
  }

  private capabilityOf(capsRaw: string): string {
    if (capsRaw === 'v3') {
      return PROBE_CAP_NATIVE_V3;
    }
    if (capsRaw === 'v2') {
      return PROBE_CAP_NATIVE_V2;
    }
    if (capsRaw === 'legacy') {
      return PROBE_CAP_LEGACY;
    }
    return PROBE_CAP_UNAVAILABLE;
  }

  private envFailureText(reason: string, capsRaw: string, target: string, dirError: string = ''): string {
    if (reason === ENV_REASON_CORE_UNSUPPORTED) {
      if (capsRaw.length === 0) {
        return '内核检测能力不可用(libsingbox.so 未加载),无法启动测速实例';
      }
      return '内核为旧版检测导出,不支持可用性检测(需重编 libsingbox.so 或改用 TCPing)';
    }
    if (reason === ENV_REASON_TEST_DIR) {
      const base = '检测目录不可写,无法创建临时测速配置';
      return dirError.length > 0 ? `${base}(${dirError})` : base;
    }
    if (reason === ENV_REASON_INVALID_TARGET) {
      return `检测地址无效: ${target}(请在设置里填写有效的 http(s) 地址)`;
    }
    if (reason === ENV_REASON_METHOD_UNSUPPORTED) {
      return '当前检测方式不受支持(HTTP 检测需要内核检测能力)';
    }
    return reason;
  }

  private newRunId(nowMs: number): string {
    const rand = Math.floor(Math.random() * 1000000);
    return `probe-${nowMs}-${rand}`;
  }

  private emit(ctx: ProbeRunContext, result: ProbeResult): void {
    const cb = ctx.opts.onResult;
    if (cb !== null) {
      cb(result);
    }
  }

  private isCancelled(ctx: ProbeRunContext): boolean {
    if (this.coord.isCancelled()) {
      return true;
    }
    const outer = ctx.opts.isCancelled;
    return outer !== null && outer();
  }

  private now(): number {
    return this.deps.now !== null ? this.deps.now() : Date.now();
  }

  private log(line: string): void {
    if (this.deps.log !== null) {
      this.deps.log(line);
    }
  }

  private errorText(e: Object | null | undefined): string {
    if (e === null || e === undefined) {
      return 'unknown error';
    }
    if (e instanceof Error) {
      return e.message;
    }
    return `${e}`;
  }

  private buildBatch(batch: Array<ProbeTarget>): ProbeBatchConfig {
    const fn = this.deps.buildBatch;
    if (fn === null) {
      throw new Error('buildBatch 未注入');
    }
    return fn(batch);
  }

  private writeConfig(json: string): string {
    const fn = this.deps.writeConfig;
    if (fn === null) {
      throw new Error('writeConfig 未注入');
    }
    return fn(json);
  }

  /** 桥接兜底超时:超时只代表 UI 等待超时,不代表原生已停止(§6.5)。 */
  private withTimeout<T>(p: Promise<T>, ms: number, fallbackValue: T): Promise<T> {
    return new Promise<T>((resolve: (v: T) => void) => {
      let settled = false;
      let timer = -1;
      const finish = (v: T): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        resolve(v);
      };
      timer = setTimeout(() => {
        this.log(`[probe] 内核桥接调用超过 ${ms}ms 无响应,按失败处理(不据此创建新会话)`);
        finish(fallbackValue);
      }, ms);
      p.then((v: T) => {
        finish(v);
      }).catch(() => {
        finish(fallbackValue);
      });
    });
  }
}

// ---------------- 持久化投影(ArkTS 无结构类型,逐字段复制) ----------------

/** ProbeResult → ProbeStore 的持久化 DTO(§6.2 字段 1:1,不整对象 cast)。 */
export function toResultRecord(r: ProbeResult): ProbeResultRecord {
  const rec = new ProbeResultRecord();
  rec.runId = r.runId;
  rec.profileId = r.profileId;
  rec.configRevision = r.configRevision;
  rec.profileConfigHash = r.profileConfigHash;
  rec.methodRequested = r.methodRequested;
  rec.methodActual = r.methodActual;
  rec.state = r.state;
  rec.latencyMs = r.latencyMs;
  rec.samples = r.samples;
  rec.aggregation = r.aggregation;
  rec.target = r.target;
  rec.timeoutMs = r.timeoutMs;
  rec.expectedStatus = r.expectedStatus;
  rec.startedAt = r.startedAt;
  rec.completedAt = r.completedAt;
  rec.persistedAt = r.persistedAt;
  rec.path = r.path;
  rec.errorCode = r.errorCode;
  rec.errorDetail = r.errorDetail;
  rec.degradedReason = r.degradedReason;
  rec.coreCapability = r.coreCapability;
  rec.source = r.source;
  return rec;
}

function copySummary(s: ProbeSummary): ProbeRunSummary {
  const out = new ProbeRunSummary();
  out.success = s.success;
  out.failed = s.failed;
  out.notApplicable = s.notApplicable;
  out.cancelled = s.cancelled;
  out.unsaved = s.unsaved;
  return out;
}
