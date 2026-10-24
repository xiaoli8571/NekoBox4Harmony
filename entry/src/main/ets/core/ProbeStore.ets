import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { SnapshotStore } from './SnapshotStore';
import { LogStore } from '../model/Store';

/**
 * 检测结果持久化存储 —— REDESIGN-PLAN-2026-10-23.md §6.2(结果模型)、§6.3(运行与取消)、
 * §14.2(ProbeResult / ProbeRun 是与节点配置独立的检测事实)、§14.3-7(检测结果独立记录，
 * 不每秒重写配置快照)。
 *
 * 职责与边界：
 *  - 只负责「检测事实」的落盘与查询：`ProbeResult` 与节点配置完全独立，不写回 Profile/订阅，
 *    不改写 config/ 快照目录(避免被 §14.3 的快照 GC 当成孤儿清理)。
 *  - 结果刷新与存储写入解耦：`saveRun` 是批量提交入口(一轮一次原子写)，读取方走
 *    `latestFor/latestAll/loadRuns`，二者之间没有回调、没有全局重建。
 *  - 写失败如实返回 false，并把该轮留在内存里(可读、可 `markUnsaved`)，**绝不假装已保存**
 *    (`persistedAt` 只在原子写+读回校验通过后才有值)。
 *  - 突然终止可恢复已保存部分：每轮一次原子提交(tmp→fsync→rename+读回校验)，不存在半写文件。
 *
 * 文件布局(刻意放在 probe/ 而不是 config/)：
 *   <filesDir>/probe/probe-results-v1.json
 *
 * 数据模型说明(与 model/ProbeResult.ets 的对齐方式)：
 *  本文件里的 `ProbeResultRecord` / `ProbeRunSnapshot` 是**持久化 DTO**，字段名与 §6.2 表
 *  逐一对应；ArkTS 没有结构化类型，业务模型落地后由调用方逐字段投影到 DTO(或反之)，
 *  存储层不依赖业务模型，P2 可以先独立完成与测试。
 *  - `latencyMs`：0ms 是合法数值；**未测填 -1**，不用 0 冒充未测。
 *  - `methodRequested` 与 `methodActual` 分开存，HTTP 请求与 TCP 回退不可混淆；
 *    复合键用 `methodActual`(没有实际方法时回退 requested)，因此 HTTP 与 TCP 结果互不覆盖。
 *  - `stateBeforeUnsaved` 是**存储层补充字段**(不在 §6.2 表内)：markUnsaved 会把 state 覆盖成
 *    `unsaved`，保留被覆盖前的状态，界面才能区分「成功但没存下去」与「本来就失败」。
 *
 * 未接线(交给 lead 集成)：
 *  - LatencyTester 批量结束/取消收尾时调用 `saveRun`(§6.3「批量持久化并更新已保存计数」)；
 *  - 写失败时调用 `markUnsaved(runId)`；
 *  - 节点列表/详情页用 `latestFor` / `latestAll` 做「仅看可用 / 最快节点 / 新鲜度」筛选。
 */

export const PROBE_SCHEMA_VERSION: number = 1;
/** 历史保留轮数(§6.3 只要求最近若干轮；20 轮足够覆盖一次大订阅的多次重测)。 */
export const DEFAULT_MAX_RUNS: number = 20;

const PROBE_DIR_NAME: string = 'probe';
const PROBE_FILE_NAME: string = 'probe-results-v1.json';

export const STATE_QUEUED: string = 'queued';
export const STATE_RUNNING: string = 'running';
export const STATE_SUCCESS: string = 'success';
export const STATE_FAILED: string = 'failed';
export const STATE_NOT_APPLICABLE: string = 'notApplicable';
export const STATE_CANCELLED: string = 'cancelled';
export const STATE_UNSAVED: string = 'unsaved';

export const PATH_DIRECT_BOUND: string = 'directBound';
export const PATH_CURRENT_TUNNEL: string = 'currentTunnel';
export const PATH_UNBOUND_UNKNOWN: string = 'unboundUnknown';
export const PATH_LEGACY_UNKNOWN: string = 'legacyUnknown';

/** 一轮检测的完成摘要(§6.3)。 */
export class ProbeRunSummary {
  success: number = 0;
  failed: number = 0;
  notApplicable: number = 0;
  cancelled: number = 0;
  unsaved: number = 0;
}

/** §6.2 ProbeResult 的持久化投影(字段名与方案表 1:1)。 */
export class ProbeResultRecord {
  runId: string = '';
  profileId: string = '';
  configRevision: number = 0;
  profileConfigHash: string = '';
  methodRequested: string = '';
  methodActual: string = '';
  /** queued | running | success | failed | notApplicable | cancelled | unsaved */
  state: string = STATE_FAILED;
  /** 0 合法；-1 = 未测(不得用 0 冒充未测)。 */
  latencyMs: number = -1;
  samples: number = 0;
  /** 聚合口径，如 'min' / 'median' / 'single'。 */
  aggregation: string = '';
  target: string = '';
  timeoutMs: number = 0;
  expectedStatus: string = '';
  startedAt: number = 0;
  completedAt: number = 0;
  /** 0 = 尚未真正落盘(写失败/markUnsaved)。 */
  persistedAt: number = 0;
  /** directBound | currentTunnel | unboundUnknown | legacyUnknown */
  path: string = PATH_UNBOUND_UNKNOWN;
  errorCode: string = '';
  errorDetail: string = '';
  degradedReason: string = '';
  coreCapability: string = '';
  source: string = '';
  /** 存储层补充字段：markUnsaved 覆盖前的 state(见文件头说明)。 */
  stateBeforeUnsaved: string = '';
}

/** 一轮不可变目标快照 + 结果集合(§6.3)。 */
export class ProbeRunSnapshot {
  runId: string = '';
  generation: number = 0;
  createdAt: number = 0;
  completedAt: number = 0;
  summary: ProbeRunSummary = new ProbeRunSummary();
  results: Array<ProbeResultRecord> = [];
}

/** `latestFor/latestAll` 的返回类型：结果字段 + 所属轮次信息(用于新鲜度展示)。 */
export class StoredProbe extends ProbeResultRecord {
  generation: number = 0;
  runCreatedAt: number = 0;
}

/** `stats()` 的返回类型(ArkTS 不允许匿名对象字面量类型，故用具名类)。 */
export class ProbeStoreStats {
  runs: number = 0;
  results: number = 0;
  latest: number = 0;
  bytes: number = 0;
}

/** 落盘文件的内存形态。 */
class ProbeState {
  schemaVersion: number = PROBE_SCHEMA_VERSION;
  updatedAt: number = 0;
  runs: Array<ProbeRunSnapshot> = [];
}

/** 加载结论。futureSchema=true 时**只读**：保留原文件、拒绝一切写入。 */
class ProbeLoadOutcome {
  ok: boolean = false;
  missing: boolean = false;
  futureSchema: boolean = false;
  corrupt: boolean = false;
  error: string = '';
  state: ProbeState = new ProbeState();
}

// ---- 纯工具函数 ----

function isRecord(value: Object | undefined): boolean {
  return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value);
}

function asString(value: Object | undefined, fallback: string): string {
  if (value === undefined || value === null) {
    return fallback;
  }
  return `${value}`;
}

function asNumber(value: Object | undefined, fallback: number): number {
  if (value === undefined || value === null) {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

/** 复合键片段：不含 '|'，避免拼接歧义(键本身是用户/配置数据，不能假设无分隔符)。 */
function keyPart(value: string): string {
  return value.split('|').join('%7C').trim();
}

/**
 * §6.2 复合键：profileId|profileConfigHash|method|target|policy|path。
 * method/policy/path 大小写归一(methodActual 是枚举)；target 是 URL/host，保持原样大小写。
 * `policy` 在结果里没有独立字段，取自 `expectedStatus`(判据) —— 判据不同结果不可比较。
 */
export function probeKey(profileId: string, configHash: string, method: string, target: string,
  policy: string, path: string): string {
  return [
    keyPart(profileId), keyPart(configHash), keyPart(method.toLowerCase()),
    keyPart(target), keyPart(policy.toLowerCase()), keyPart(path.toLowerCase())
  ].join('|');
}

/** 由一条存储结果推导复合键(用 methodActual，缺省回退 methodRequested)。 */
export function probeKeyOf(result: ProbeResultRecord): string {
  const method = result.methodActual.length > 0 ? result.methodActual : result.methodRequested;
  return probeKey(result.profileId, result.profileConfigHash, method, result.target,
    result.expectedStatus, result.path);
}

/** queued/running 不是最终结果：不进 latest 映射，也不参与「仅看可用」。 */
export function isFinalState(state: string): boolean {
  return state !== STATE_QUEUED && state !== STATE_RUNNING;
}

/** 把 summary 的一个计数减一(不低于 0)。 */
function decrementBucket(summary: ProbeRunSummary, state: string): void {
  if (state === STATE_SUCCESS && summary.success > 0) {
    summary.success--;
  } else if (state === STATE_FAILED && summary.failed > 0) {
    summary.failed--;
  } else if (state === STATE_NOT_APPLICABLE && summary.notApplicable > 0) {
    summary.notApplicable--;
  } else if (state === STATE_CANCELLED && summary.cancelled > 0) {
    summary.cancelled--;
  }
}

function copyResultFields(target: ProbeResultRecord, source: ProbeResultRecord): void {
  target.runId = source.runId;
  target.profileId = source.profileId;
  target.configRevision = source.configRevision;
  target.profileConfigHash = source.profileConfigHash;
  target.methodRequested = source.methodRequested;
  target.methodActual = source.methodActual;
  target.state = source.state;
  target.latencyMs = source.latencyMs;
  target.samples = source.samples;
  target.aggregation = source.aggregation;
  target.target = source.target;
  target.timeoutMs = source.timeoutMs;
  target.expectedStatus = source.expectedStatus;
  target.startedAt = source.startedAt;
  target.completedAt = source.completedAt;
  target.persistedAt = source.persistedAt;
  target.path = source.path;
  target.errorCode = source.errorCode;
  target.errorDetail = source.errorDetail;
  target.degradedReason = source.degradedReason;
  target.coreCapability = source.coreCapability;
  target.source = source.source;
  target.stateBeforeUnsaved = source.stateBeforeUnsaved;
}

function cloneResult(source: ProbeResultRecord): ProbeResultRecord {
  const out = new ProbeResultRecord();
  copyResultFields(out, source);
  return out;
}

function toStored(source: ProbeResultRecord, run: ProbeRunSnapshot): StoredProbe {
  const out = new StoredProbe();
  copyResultFields(out, source);
  out.generation = run.generation;
  out.runCreatedAt = run.createdAt;
  return out;
}

function parseSummary(raw: Object | undefined): ProbeRunSummary {
  const out = new ProbeRunSummary();
  if (!isRecord(raw)) {
    return out;
  }
  const rec = raw as Record<string, Object>;
  out.success = asNumber(rec['success'], 0);
  out.failed = asNumber(rec['failed'], 0);
  out.notApplicable = asNumber(rec['notApplicable'], 0);
  out.cancelled = asNumber(rec['cancelled'], 0);
  out.unsaved = asNumber(rec['unsaved'], 0);
  return out;
}

function parseResult(raw: Object): ProbeResultRecord | null {
  if (!isRecord(raw)) {
    return null;
  }
  const rec = raw as Record<string, Object>;
  const out = new ProbeResultRecord();
  out.runId = asString(rec['runId'], '');
  out.profileId = asString(rec['profileId'], '');
  out.configRevision = asNumber(rec['configRevision'], 0);
  out.profileConfigHash = asString(rec['profileConfigHash'], '');
  out.methodRequested = asString(rec['methodRequested'], '');
  out.methodActual = asString(rec['methodActual'], '');
  out.state = asString(rec['state'], '');
  if (out.state.length === 0) {
    // 只有损坏数据会缺 state：按失败展示，绝不伪造成成功
    out.state = STATE_FAILED;
  }
  out.latencyMs = asNumber(rec['latencyMs'], -1);
  out.samples = asNumber(rec['samples'], 0);
  out.aggregation = asString(rec['aggregation'], '');
  out.target = asString(rec['target'], '');
  out.timeoutMs = asNumber(rec['timeoutMs'], 0);
  out.expectedStatus = asString(rec['expectedStatus'], '');
  out.startedAt = asNumber(rec['startedAt'], 0);
  out.completedAt = asNumber(rec['completedAt'], 0);
  out.persistedAt = asNumber(rec['persistedAt'], 0);
  out.path = asString(rec['path'], PATH_UNBOUND_UNKNOWN);
  out.errorCode = asString(rec['errorCode'], '');
  out.errorDetail = asString(rec['errorDetail'], '');
  out.degradedReason = asString(rec['degradedReason'], '');
  out.coreCapability = asString(rec['coreCapability'], '');
  out.source = asString(rec['source'], '');
  out.stateBeforeUnsaved = asString(rec['stateBeforeUnsaved'], '');
  return out;
}

function parseRun(raw: Object): ProbeRunSnapshot | null {
  if (!isRecord(raw)) {
    return null;
  }
  const rec = raw as Record<string, Object>;
  const runId = asString(rec['runId'], '');
  if (runId.length === 0) {
    return null;
  }
  const run = new ProbeRunSnapshot();
  run.runId = runId;
  run.generation = asNumber(rec['generation'], 0);
  run.createdAt = asNumber(rec['createdAt'], 0);
  run.completedAt = asNumber(rec['completedAt'], 0);
  run.summary = parseSummary(rec['summary']);
  const rawResults = rec['results'];
  if (rawResults !== undefined && rawResults !== null && Array.isArray(rawResults)) {
    const list = rawResults as Array<Object>;
    for (let i = 0; i < list.length; i++) {
      const result = parseResult(list[i]);
      if (result !== null) {
        run.results.push(result);
      }
    }
  }
  return run;
}

function cloneRun(run: ProbeRunSnapshot): ProbeRunSnapshot {
  const out = new ProbeRunSnapshot();
  out.runId = run.runId;
  out.generation = run.generation;
  out.createdAt = run.createdAt;
  out.completedAt = run.completedAt;
  out.summary = parseSummary(run.summary as Object);
  for (let i = 0; i < run.results.length; i++) {
    out.results.push(cloneResult(run.results[i]));
  }
  return out;
}

function serializeState(state: ProbeState): string {
  return JSON.stringify(state);
}

/** 解析落盘文件。任何异常都返回 ok=false(调用方决定是否 best-effort 写回)。 */
function parseProbeState(text: string): ProbeLoadOutcome {
  const outcome = new ProbeLoadOutcome();
  if (text === null || text === undefined || text.length === 0) {
    outcome.corrupt = true;
    outcome.error = '检测结果文件为空';
    return outcome;
  }
  let parsed: Record<string, Object>;
  try {
    const value: Object = JSON.parse(text) as Object;
    if (!isRecord(value)) {
      outcome.corrupt = true;
      outcome.error = '检测结果文件顶层不是对象';
      return outcome;
    }
    parsed = value as Record<string, Object>;
  } catch (e) {
    outcome.corrupt = true;
    outcome.error = '检测结果文件解析失败(JSON 损坏)';
    return outcome;
  }
  const schemaVersion = asNumber(parsed['schemaVersion'], 0);
  if (!(schemaVersion >= 1)) {
    outcome.corrupt = true;
    outcome.error = '检测结果文件缺少 schemaVersion';
    return outcome;
  }
  if (schemaVersion > PROBE_SCHEMA_VERSION) {
    // 未来版本：拒绝加载，绝不能覆盖(否则降级写会丢新版本数据)
    outcome.futureSchema = true;
    outcome.error = `检测结果文件版本过新(schema=${schemaVersion} > ${PROBE_SCHEMA_VERSION})，已拒绝加载`;
    return outcome;
  }
  const state = new ProbeState();
  state.schemaVersion = schemaVersion;
  state.updatedAt = asNumber(parsed['updatedAt'], 0);
  const rawRuns = parsed['runs'];
  if (rawRuns !== undefined && rawRuns !== null && Array.isArray(rawRuns)) {
    const list = rawRuns as Array<Object>;
    for (let i = 0; i < list.length; i++) {
      const run = parseRun(list[i]);
      if (run !== null) {
        state.runs.push(run);
      }
    }
  }
  outcome.ok = true;
  outcome.state = state;
  return outcome;
}

/** 从「最新在前」的 runs 重建 latest 映射(保证 prune 之后不再指向已删除结果)。 */
function buildLatest(runs: Array<ProbeRunSnapshot>): Record<string, StoredProbe> {
  const out: Record<string, StoredProbe> = {};
  for (let i = 0; i < runs.length; i++) {
    const run = runs[i];
    for (let j = 0; j < run.results.length; j++) {
      const result = run.results[j];
      if (!isFinalState(result.state)) {
        continue;
      }
      const key = probeKeyOf(result);
      if (out[key] !== undefined) {
        continue;
      }
      out[key] = toStored(result, run);
    }
  }
  return out;
}

function cloneState(state: ProbeState): ProbeState {
  const out = new ProbeState();
  out.schemaVersion = state.schemaVersion;
  out.updatedAt = state.updatedAt;
  for (let i = 0; i < state.runs.length; i++) {
    out.runs.push(cloneRun(state.runs[i]));
  }
  return out;
}

/** 只保留最新 maxRuns 轮(runs 已按最新在前排列)。 */
function trimRuns(state: ProbeState, maxRuns: number): number {
  const limit = maxRuns >= 1 ? maxRuns : 1;
  let removed = 0;
  while (state.runs.length > limit) {
    state.runs.pop();
    removed++;
  }
  return removed;
}

/**
 * 检测结果存储(单写者)。
 *
 * 读取永远走内存(内存是「最近一次尝试」的权威)；落盘是独立的原子提交。
 * 写失败时内存保留该轮并返回 false —— 调用方据此显示「未保存」，重启后只恢复上次成功提交的部分。
 */
export class ProbeStore {
  private static queue: Promise<void> = Promise.resolve();
  private static dir: string = '';
  private static filePath: string = '';
  private static state: ProbeState = new ProbeState();
  private static latestMap: Record<string, StoredProbe> = {};
  private static initialized: boolean = false;
  private static futureSchemaBlocked: boolean = false;
  private static loadError: string = '';

  /** 初始化(幂等)：建目录 + 从磁盘恢复上次成功提交的轮次。 */
  static init(context: common.Context): void {
    ProbeStore.dir = `${context.filesDir}/${PROBE_DIR_NAME}`;
    ProbeStore.filePath = `${ProbeStore.dir}/${PROBE_FILE_NAME}`;
    SnapshotStore.ensureDir(ProbeStore.dir);
    const outcome = ProbeStore.loadFromDisk();
    ProbeStore.state = outcome.state;
    ProbeStore.latestMap = buildLatest(outcome.state.runs);
    ProbeStore.futureSchemaBlocked = outcome.futureSchema;
    ProbeStore.loadError = outcome.error;
    ProbeStore.initialized = true;
    if (outcome.futureSchema) {
      LogStore.addLog(`[probe] ${outcome.error}；本次运行不写入检测结果`);
      return;
    }
    if (outcome.corrupt) {
      LogStore.addLog(`[probe] ${outcome.error}；按空数据继续，并将 best-effort 写回`);
      // 损坏文件无法恢复：best-effort 用空状态覆盖，避免每次启动都重复报错
      ProbeStore.writeState(new ProbeState());
    } else if (outcome.missing) {
      LogStore.addLog('[probe] 未发现检测结果文件(首次启动或已被清理)');
    } else {
      LogStore.addLog(`[probe] 已恢复 ${outcome.state.runs.length} 轮检测结果`);
    }
  }

  static isInitialized(): boolean {
    return ProbeStore.initialized;
  }

  /** 最近一次加载的错误文本('' = 正常)。供界面说明「为什么读不到/不能写」。 */
  static getLoadError(): string {
    return ProbeStore.loadError;
  }

  /** 文件来自更高的 schema 版本时，存储进入只读(保留原文件，绝不覆盖)。 */
  static isFutureSchemaBlocked(): boolean {
    return ProbeStore.futureSchemaBlocked;
  }

  /**
   * 提交一轮检测结果：原子写 + 读回校验。
   * 返回 true 只有一种情况：文件真的写成功且能读回同一内容。
   * 返回 false 时本轮仍保留在内存中(可读、可 markUnsaved)，且 `persistedAt` 保持 0。
   */
  static saveRun(run: ProbeRunSnapshot): Promise<boolean> {
    return ProbeStore.enqueue(async (): Promise<boolean> => {
      if (!ProbeStore.initialized) {
        LogStore.addLog('[probe] saveRun 失败: 未 init');
        return false;
      }
      if (ProbeStore.futureSchemaBlocked) {
        LogStore.addLog('[probe] saveRun 被拒绝: 磁盘文件版本过新，只读保护');
        return false;
      }
      const draft = cloneRun(run);
      if (draft.runId.length === 0) {
        LogStore.addLog('[probe] saveRun 失败: runId 为空');
        return false;
      }
      for (let i = 0; i < draft.results.length; i++) {
        if (draft.results[i].runId.length === 0) {
          draft.results[i].runId = draft.runId;
        }
      }
      const next = cloneState(ProbeStore.state);
      ProbeStore.mergeRun(next, draft);
      next.updatedAt = Date.now();
      trimRuns(next, DEFAULT_MAX_RUNS);
      // 先写「已持久化」版本；写成功后内存与磁盘一致
      const toWrite = cloneState(next);
      const now = Date.now();
      for (let i = 0; i < toWrite.runs.length; i++) {
        if (toWrite.runs[i].runId !== draft.runId) {
          continue;
        }
        for (let j = 0; j < toWrite.runs[i].results.length; j++) {
          toWrite.runs[i].results[j].persistedAt = now;
        }
      }
      if (ProbeStore.writeState(toWrite)) {
        ProbeStore.state = toWrite;
        ProbeStore.latestMap = buildLatest(toWrite.runs);
        return true;
      }
      // 写失败：内存保留本轮(不含 persistedAt)，如实告诉调用方没存下去
      ProbeStore.state = next;
      ProbeStore.latestMap = buildLatest(next.runs);
      return false;
    });
  }

  /** 只读查询：复合键 → 最近一次最终结果(不走磁盘)。 */
  static latestFor(profileId: string, configHash: string, method: string, target: string,
    policy: string, path: string): StoredProbe | null {
    const key = probeKey(profileId, configHash, method, target, policy, path);
    const found = ProbeStore.latestMap[key];
    if (found === undefined) {
      return null;
    }
    const out = new StoredProbe();
    copyResultFields(out, found);
    out.generation = found.generation;
    out.runCreatedAt = found.runCreatedAt;
    return out;
  }

  /** 最新结果集合(每复合键一条)，供「仅看可用 / 最快节点 / 新鲜度」筛选排序。 */
  static latestAll(): Array<StoredProbe> {
    const keys = Object.keys(ProbeStore.latestMap);
    const out: Array<StoredProbe> = [];
    for (let i = 0; i < keys.length; i++) {
      const found = ProbeStore.latestMap[keys[i]];
      const item = new StoredProbe();
      copyResultFields(item, found);
      item.generation = found.generation;
      item.runCreatedAt = found.runCreatedAt;
      out.push(item);
    }
    return out;
  }

  /** 历史轮次(最新在前)，深拷贝返回，调用方改不坏存储。 */
  static loadRuns(): Array<ProbeRunSnapshot> {
    const clone = cloneState(ProbeStore.state);
    return clone.runs;
  }

  /**
   * 写失败后把该轮结果标为 unsaved(§6.2 state 之一)：不冒充已保存。
   * 只改「最终结果」，queued/running 不参与；尽力尝试一次写入(失败也只影响持久性，不影响内存事实)。
   */
  static markUnsaved(runId: string): Promise<void> {
    return ProbeStore.enqueue(async (): Promise<void> => {
      if (!ProbeStore.initialized || ProbeStore.futureSchemaBlocked || runId.length === 0) {
        return;
      }
      const run = ProbeStore.findRun(runId);
      if (run === null) {
        return;
      }
      let changed = 0;
      for (let i = 0; i < run.results.length; i++) {
        const result = run.results[i];
        if (result.state === STATE_UNSAVED || !isFinalState(result.state)) {
          continue;
        }
        decrementBucket(run.summary, result.state);
        result.stateBeforeUnsaved = result.state;
        result.state = STATE_UNSAVED;
        result.persistedAt = 0;
        changed++;
      }
      if (changed === 0) {
        return;
      }
      run.summary.unsaved += changed;
      ProbeStore.latestMap = buildLatest(ProbeStore.state.runs);
      ProbeStore.writeState(ProbeStore.state); // 尽力而为：失败也不抛出
      LogStore.addLog(`[probe] ${runId} 的 ${changed} 条结果标记为未保存`);
    });
  }

  /** 只保留最近 maxRuns 轮，返回删除轮数；latest 随之重建(不会指向已删除结果)。 */
  static prune(maxRuns: number = DEFAULT_MAX_RUNS): Promise<number> {
    return ProbeStore.enqueue(async (): Promise<number> => {
      if (!ProbeStore.initialized || ProbeStore.futureSchemaBlocked) {
        return 0;
      }
      const next = cloneState(ProbeStore.state);
      const removed = trimRuns(next, maxRuns);
      if (removed === 0) {
        return 0;
      }
      next.updatedAt = Date.now();
      ProbeStore.state = next;
      ProbeStore.latestMap = buildLatest(next.runs);
      ProbeStore.writeState(next); // 尽力而为：内存已裁剪，磁盘失败下次启动会回来
      LogStore.addLog(`[probe] 已裁剪 ${removed} 轮历史(保留 ${next.runs.length} 轮)`);
      return removed;
    });
  }

  /** 清空(用户显式操作)：内存 + 文件一起清，并解除「未来版本只读」。 */
  static clear(): Promise<void> {
    return ProbeStore.enqueue(async (): Promise<void> => {
      ProbeStore.state = new ProbeState();
      ProbeStore.latestMap = {};
      ProbeStore.futureSchemaBlocked = false;
      ProbeStore.loadError = '';
      SnapshotStore.removeFile(ProbeStore.filePath);
      SnapshotStore.removeFile(`${ProbeStore.filePath}.tmp`);
      LogStore.addLog('[probe] 检测结果已清空');
    });
  }

  static stats(): ProbeStoreStats {
    const out = new ProbeStoreStats();
    out.runs = ProbeStore.state.runs.length;
    for (let i = 0; i < ProbeStore.state.runs.length; i++) {
      out.results += ProbeStore.state.runs[i].results.length;
    }
    out.latest = Object.keys(ProbeStore.latestMap).length;
    out.bytes = ProbeStore.fileSize();
    return out;
  }

  // ---- 内部实现 ----

  private static enqueue<T>(task: () => Promise<T>): Promise<T> {
    const previous = ProbeStore.queue;
    let release: () => void = () => {};
    ProbeStore.queue = new Promise<void>((resolve: () => void) => {
      release = resolve;
    });
    const run = async (): Promise<T> => {
      try {
        await previous;
      } catch (e) {
        // 前一次失败不阻断后一次
      }
      try {
        return await task();
      } finally {
        release();
      }
    };
    return run();
  }

  private static loadFromDisk(): ProbeLoadOutcome {
    if (ProbeStore.filePath.length === 0) {
      const outcome = new ProbeLoadOutcome();
      outcome.missing = true;
      return outcome;
    }
    if (!SnapshotStore.exists(ProbeStore.filePath)) {
      const outcome = new ProbeLoadOutcome();
      outcome.missing = true;
      return outcome;
    }
    let text = '';
    try {
      text = SnapshotStore.readText(ProbeStore.filePath);
    } catch (e) {
      const outcome = new ProbeLoadOutcome();
      outcome.corrupt = true;
      outcome.error = '检测结果文件读取失败';
      return outcome;
    }
    return parseProbeState(text);
  }

  /** 原子写 + 读回校验：读回内容必须与写入内容完全一致(规范化序列化)。 */
  private static writeState(state: ProbeState): boolean {
    if (ProbeStore.filePath.length === 0) {
      return false;
    }
    const text = serializeState(state);
    try {
      SnapshotStore.ensureDir(ProbeStore.dir);
      SnapshotStore.writeTextAtomic(ProbeStore.filePath, text);
      const back = SnapshotStore.readText(ProbeStore.filePath);
      if (back !== text) {
        // 内容不一致(半写/被截断/字段丢失)：按写失败处理，不能假装成功
        ProbeStore.cleanupTemp();
        LogStore.addLog('[probe] 检测结果读回校验失败(内容不一致)');
        return false;
      }
      return true;
    } catch (e) {
      ProbeStore.cleanupTemp();
      LogStore.addLog('[probe] 检测结果写入失败');
      return false;
    }
  }

  private static cleanupTemp(): void {
    SnapshotStore.removeFile(`${ProbeStore.filePath}.tmp`);
  }

  private static fileSize(): number {
    if (ProbeStore.filePath.length === 0 || !SnapshotStore.exists(ProbeStore.filePath)) {
      return 0;
    }
    try {
      const stat = fs.statSync(ProbeStore.filePath);
      return stat.isDirectory() ? 0 : Number(stat.size);
    } catch (e) {
      return 0;
    }
  }

  private static findRun(runId: string): ProbeRunSnapshot | null {
    for (let i = 0; i < ProbeStore.state.runs.length; i++) {
      if (ProbeStore.state.runs[i].runId === runId) {
        return ProbeStore.state.runs[i];
      }
    }
    return null;
  }

  /**
   * 同 runId 视为同一轮(重试/批量分块提交)：按结果复合键 upsert，绝不整轮覆盖丢结果；
   * 新 runId 插到最前(最新在前)。summary 以带入者为准(调用方持有整轮摘要)。
   */
  private static mergeRun(state: ProbeState, run: ProbeRunSnapshot): void {
    let existing: ProbeRunSnapshot | null = null;
    for (let i = 0; i < state.runs.length; i++) {
      if (state.runs[i].runId === run.runId) {
        existing = state.runs[i];
        break;
      }
    }
    if (existing === null) {
      state.runs.unshift(run);
      return;
    }
    for (let i = 0; i < run.results.length; i++) {
      const incoming = run.results[i];
      const key = probeKeyOf(incoming);
      let replaced = false;
      for (let j = 0; j < existing.results.length; j++) {
        if (probeKeyOf(existing.results[j]) === key) {
          existing.results[j] = incoming;
          replaced = true;
          break;
        }
      }
      if (!replaced) {
        existing.results.push(incoming);
      }
    }
    if (run.generation !== 0) {
      existing.generation = run.generation;
    }
    if (existing.createdAt === 0) {
      existing.createdAt = run.createdAt;
    }
    if (run.completedAt > existing.completedAt) {
      existing.completedAt = run.completedAt;
    }
    if (run.results.length > 0) {
      existing.summary = run.summary;
    }
  }
}
