/**
 * ProbeFilters —— 检测结果视图模型（P2/W10，REDESIGN-PLAN-2026-10-23.md §6.2/§6.6、§4.2）。
 *
 * 职责边界：纯函数视图模型，供 P3 页面（节点行/检测视图/状态卡解耦，§4.2）消费；
 * 无 I/O、无平台依赖、无定时任务；所有输入数组不改原数组（内部先复制），
 * 结果对象只读不改写。不 import core/ProbeStore（并行开发中）——只依赖 ProbeResult 字段。
 *
 * 语义要点（§6.6）：
 *  - "仅看可用""最快节点"基于同方法、同目标、同判据、同路径、新鲜结果（isComparableFresh）；
 *  - 不同方法/路径/判据的结果分别显示，不强行共用同一数值；
 *  - 旧结果（method=unknown / path=legacyUnknown）可查看但不参与可用性比较，不伪造 HTTP 通过；
 *  - 用户判据为 any 时显示口径是"HTTP 有响应"（http_any_response），不得把 403/500 描述为正常访问；
 *  - 取消不是失败：取消未执行节点保留原结果（mergeLiveWithStored.preservedStored）。
 */

import {
  ProbeResult,
  PROBE_STATE_QUEUED, PROBE_STATE_RUNNING, PROBE_STATE_SUCCESS, PROBE_STATE_FAILED,
  PROBE_STATE_NOT_APPLICABLE, PROBE_STATE_CANCELLED, PROBE_STATE_UNSAVED,
  PROBE_METHOD_HTTP, PROBE_METHOD_TCPING, PROBE_METHOD_UNKNOWN,
  PROBE_PATH_DIRECT_BOUND, PROBE_PATH_CURRENT_TUNNEL, PROBE_PATH_UNBOUND_UNKNOWN, PROBE_PATH_LEGACY_UNKNOWN,
  PROBE_EXPECT_2XX, PROBE_EXPECT_ANY,
  isComparableFresh
} from './ProbeResult';

/** 分组显示顺序（确定性输出）：方法 http→tcping→unknown；路径直连→当前隧道→未知。 */
const METHOD_ORDER: Array<string> = [PROBE_METHOD_HTTP, PROBE_METHOD_TCPING, PROBE_METHOD_UNKNOWN];
const PATH_ORDER: Array<string> = [
  PROBE_PATH_DIRECT_BOUND, PROBE_PATH_CURRENT_TUNNEL,
  PROBE_PATH_UNBOUND_UNKNOWN, PROBE_PATH_LEGACY_UNKNOWN
];

/**
 * (methodActual, path) 分组（§6.6：不同方式/路径分列，不共用同一数值）。
 * criteria 记录组内出现过的判据（去重）；当 criteria.length > 1 时，页面不得把
 * 不同判据的延迟合并成一个数值，必须按判据分列或显示"混合判据"标记。
 */
export interface ProbeGroup {
  /** 分组键：`${methodActual}|${path}`，与 probeKeyOf 的 method/path 段一致 */
  key: string;
  method: string;
  path: string;
  /** 显示口径 token：如 `http_directBound`、`tcping_currentTunnel`、`unknown_legacyUnknown` */
  labelToken: string;
  count: number;
  /** 可参与可用性比较的结果数（成功且非 legacy；不含时间维度，时间维度归 filterUsable） */
  usableCount: number;
  /** 组内判据去重（如 ['2xx'] / ['2xx','any']）；>1 时页面禁止合并数值（§6.6） */
  criteria: Array<string>;
}

/** mergeLiveWithStored 输出：每 profileId 一条合并结果。 */
export interface ProbeMerge {
  result: ProbeResult;
  /** 该值不能作为"当前可用"展示：历史值或已过期（nowMs/staleMs 缺省时=fromHistory） */
  isStale: boolean;
  /** 胜出来自存储（历史），而非本次会话 */
  fromHistory: boolean;
  /** 取消的 live 未覆盖 stored 成功结果（§6.3 取消未执行节点保留原结果） */
  preservedStored: boolean;
}

/** 轻量计数（状态卡/检测视图头部，§4.2 与节点行解耦）。 */
export class ProbeSummaryLite {
  total: number = 0;
  success: number = 0;
  failed: number = 0;
  cancelled: number = 0;
  notApplicable: number = 0;
  unsaved: number = 0;
  /** queued + running（本轮进行中，未出结果） */
  unfinished: number = 0;
}

// ---------------------------------------------------------------- 1. 仅看可用

/**
 * "仅看可用"（§6.6）：state=success 且 isComparableFresh（同方法/同目标/同判据/同路径可比较、新鲜、非 legacy）。
 * 返回新数组；输入数组与结果对象均不被修改。
 */
export function filterUsable(results: Array<ProbeResult>, nowMs: number, staleMs: number): Array<ProbeResult> {
  const out: Array<ProbeResult> = [];
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    if (r.state === PROBE_STATE_SUCCESS && isComparableFresh(r, nowMs, staleMs)) {
      out.push(r);
    }
  }
  return out;
}

// ---------------------------------------------------------------- 2. 最快节点排序

/** 排序桶：0=有有效延迟（success 且 latencyMs>=0，0ms 合法排最前）；1=无有效延迟（一律排最后）。 */
function latencyRank(r: ProbeResult): number {
  if (r.state === PROBE_STATE_SUCCESS && r.latencyMs >= 0) {
    return 0;
  }
  return 1;
}

/**
 * "最快节点"排序：success 按 latencyMs 升序；非 success（含 failed/取消/未测）排最后；
 * 0ms 是合法数值排最前；latencyMs=-1 不当 0 参与排序（防御：success 携带 -1 也进尾部桶）；
 * 稳定排序——同延迟/同桶保持输入顺序。返回新数组，不改输入。
 */
export function sortByLatency(results: Array<ProbeResult>): Array<ProbeResult> {
  const idx: Array<number> = [];
  for (let i = 0; i < results.length; i++) {
    idx.push(i);
  }
  idx.sort((a: number, b: number): number => {
    const ra = latencyRank(results[a]);
    const rb = latencyRank(results[b]);
    if (ra !== rb) {
      return ra - rb;
    }
    if (ra === 0 && results[a].latencyMs !== results[b].latencyMs) {
      return results[a].latencyMs - results[b].latencyMs;
    }
    return a - b;
  });
  const out: Array<ProbeResult> = [];
  for (let i = 0; i < idx.length; i++) {
    out.push(results[idx[i]]);
  }
  return out;
}

// ---------------------------------------------------------------- 3. 每 profile 取最新

/** 内部助手：profileId → 最新一条（不含输出排序）。 */
function freshestMap(results: Array<ProbeResult>): Map<string, ProbeResult> {
  const latest: Map<string, ProbeResult> = new Map();
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    const prev = latest.get(r.profileId);
    if (prev === undefined || r.completedAt >= prev.completedAt) {
      latest.set(r.profileId, r);
    }
  }
  return latest;
}

/**
 * 每 profileId 取 completedAt 最新一条（不同轮次去重）。
 * 语义决策：
 *  - 比较因子只有 completedAt——方法/路径不作为比较因子，不偏向 HTTP：
 *    较新的 TCPing 结果不会被较旧的 HTTP 结果盖掉（§6.6 方式分列由 groupByMethodPath 负责，
 *    本函数只做"每 profile 一条"的去重，供节点行/mergeLiveWithStored 复用）；
 *  - completedAt 平局取数组中较后出现的一条（输入按观测时间追加，后观测视为更新；
 *    同一结果落库回读时两者内容一致，任取其一等价）。
 */
export function pickFreshestPerProfile(results: Array<ProbeResult>): Array<ProbeResult> {
  const latest = freshestMap(results);
  const out: Array<ProbeResult> = [];
  latest.forEach((v: ProbeResult) => {
    out.push(v);
  });
  return out;
}

// ---------------------------------------------------------------- 4. 方式×路径分组

/** 组内"可用计数"口径（无时间维度）：成功且 method/path 可知（非 legacy）。 */
function isUsableCapable(r: ProbeResult): boolean {
  return r.state === PROBE_STATE_SUCCESS
    && r.methodActual !== PROBE_METHOD_UNKNOWN
    && r.path !== PROBE_PATH_LEGACY_UNKNOWN;
}

function groupRank(g: ProbeGroup): number {
  const mi = METHOD_ORDER.indexOf(g.method);
  const pi = PATH_ORDER.indexOf(g.path);
  const m = mi < 0 ? METHOD_ORDER.length : mi;
  const p = pi < 0 ? PATH_ORDER.length : pi;
  return m * 100 + p;
}

/**
 * 按 (methodActual, path) 分组（§6.6）：HTTP 与 TCPing、直连与隧道分列显示，
 * 不强行共用同一数值。key=`method|path`；labelToken=`method_path`（如
 * `http_directBound`、`tcping_currentTunnel`、`unknown_legacyUnknown`），与 key 一一对应故全局唯一。
 * usableCount 排除 failed 与 legacy（无时间维度，时间维度归 filterUsable）。
 * 组内判据差异记录在 criteria；criteria.length>1 时页面必须分列显示，不得合并数值。
 * 组序确定性：方法 http→tcping→unknown，路径 directBound→currentTunnel→未知段，再按 key。
 */
export function groupByMethodPath(results: Array<ProbeResult>): Array<ProbeGroup> {
  const byKey: Map<string, ProbeGroup> = new Map();
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    const key = `${r.methodActual}|${r.path}`;
    let g = byKey.get(key);
    if (g === undefined) {
      const fresh: ProbeGroup = {
        key: key, method: r.methodActual, path: r.path,
        labelToken: `${r.methodActual}_${r.path}`,
        count: 0, usableCount: 0, criteria: []
      };
      byKey.set(key, fresh);
      g = fresh;
    }
    g.count += 1;
    if (isUsableCapable(r)) {
      g.usableCount += 1;
    }
    if (g.criteria.indexOf(r.expectedStatus) < 0) {
      g.criteria.push(r.expectedStatus);
    }
  }
  const groups: Array<ProbeGroup> = [];
  byKey.forEach((g: ProbeGroup) => {
    groups.push(g);
  });
  groups.sort((a: ProbeGroup, b: ProbeGroup): number => {
    const d = groupRank(a) - groupRank(b);
    if (d !== 0) {
      return d;
    }
    return a.key.localeCompare(b.key);
  });
  return groups;
}

// ---------------------------------------------------------------- 5. live 与存储合并

/** 无时间参数时 isStale=fromHistory（历史值保守视为不可比）；有时间参数时按 isComparableFresh 判。 */
function computeIsStale(r: ProbeResult, nowMs: number, staleMs: number, fromHistory: boolean): boolean {
  if (nowMs > 0 && staleMs > 0) {
    return !isComparableFresh(r, nowMs, staleMs);
  }
  return fromHistory;
}

function mergeOne(live: ProbeResult | undefined, stored: ProbeResult | undefined,
  nowMs: number, staleMs: number): ProbeMerge {
  const m: ProbeMerge = {
    result: new ProbeResult(), isStale: false, fromHistory: false, preservedStored: false
  };
  if (live === undefined) {
    if (stored === undefined) {
      return m;
    }
    m.result = stored;
    m.fromHistory = true;
  } else if (stored === undefined) {
    m.result = live;
    m.fromHistory = false;
  } else {
    if (live.state === PROBE_STATE_CANCELLED && stored.state === PROBE_STATE_SUCCESS) {
      // §6.3：取消未执行节点保留原结果——cancelled 的 live 不得覆盖 stored 成功结果
      m.result = stored;
      m.fromHistory = true;
      m.preservedStored = true;
    } else if (live.completedAt >= stored.completedAt) {
      // live 更新（含平局：stored 常是同一 live 结果的落库回读，平局取 live 才不会误标历史）
      m.result = live;
      m.fromHistory = false;
    } else {
      m.result = stored;
      m.fromHistory = true;
    }
  }
  m.isStale = computeIsStale(m.result, nowMs, staleMs, m.fromHistory);
  return m;
}

/**
 * live（本次会话）与 stored（历史持久化）逐 profileId 合并：每 profileId 一条。
 * 规则：live 比 stored 新则 live，否则 stored（completedAt 平局取 live——stored 往往是
 * 同一 live 结果的落库回读，取 live 才不会把当前会话结果误标为历史）；
 * cancelled 的 live 不覆盖 stored 成功结果，改输出 stored 并标 preservedStored:true（§6.3）；
 * 仅 live / 仅 stored 的 profileId 也各输出一条（fromHistory 相应取值）。
 * 输入两数组均不改；输出顺序确定：先按 live 首次出现序，再按 stored 独有条目出现序。
 * nowMs/staleMs 可选（P2 契约保持 2 参可用）：提供时 isStale 按 isComparableFresh 判，
 * 缺省时 isStale=fromHistory（历史值保守视为不可比）。
 */
export function mergeLiveWithStored(live: Array<ProbeResult>, stored: Array<ProbeResult>,
  nowMs: number = 0, staleMs: number = 0): Array<ProbeMerge> {
  const liveBy = freshestMap(live);
  const storedBy = freshestMap(stored);
  const out: Array<ProbeMerge> = [];
  const seen: Map<string, boolean> = new Map();
  liveBy.forEach((l: ProbeResult) => {
    seen.set(l.profileId, true);
    out.push(mergeOne(l, storedBy.get(l.profileId), nowMs, staleMs));
  });
  storedBy.forEach((s: ProbeResult) => {
    if (seen.get(s.profileId) !== true) {
      out.push(mergeOne(undefined, s, nowMs, staleMs));
    }
  });
  return out;
}

// ---------------------------------------------------------------- 6. 计数

/** 状态卡/检测视图轻量计数（§4.2）：unfinished = queued + running。空数组返回全 0。 */
export function summarize(results: Array<ProbeResult>): ProbeSummaryLite {
  const s = new ProbeSummaryLite();
  s.total = results.length;
  for (let i = 0; i < results.length; i++) {
    const st = results[i].state;
    if (st === PROBE_STATE_SUCCESS) {
      s.success += 1;
    } else if (st === PROBE_STATE_FAILED) {
      s.failed += 1;
    } else if (st === PROBE_STATE_CANCELLED) {
      s.cancelled += 1;
    } else if (st === PROBE_STATE_NOT_APPLICABLE) {
      s.notApplicable += 1;
    } else if (st === PROBE_STATE_UNSAVED) {
      s.unsaved += 1;
    } else if (st === PROBE_STATE_QUEUED || st === PROBE_STATE_RUNNING) {
      s.unfinished += 1;
    }
  }
  return s;
}

// ---------------------------------------------------------------- 7. 历史

/**
 * 某节点的检测历史：按 completedAt 倒序，最多 limit 条（limit<=0 返回空）。
 * 旧结果（fromLegacy：method=unknown/path=legacyUnknown）可查看——其 isComparableFresh
 * 自然为 false（§6.2 不伪造 HTTP 通过），由页面按"历史/来源未知"展示。
 * completedAt 平局保持输入顺序（稳定）。输入数组不改。
 */
export function historyFor(profileId: string, results: Array<ProbeResult>, limit: number = 20): Array<ProbeResult> {
  if (limit <= 0) {
    return [];
  }
  const mine: Array<ProbeResult> = [];
  for (let i = 0; i < results.length; i++) {
    if (results[i].profileId === profileId) {
      mine.push(results[i]);
    }
  }
  const idx: Array<number> = [];
  for (let i = 0; i < mine.length; i++) {
    idx.push(i);
  }
  idx.sort((a: number, b: number): number => {
    if (mine[b].completedAt !== mine[a].completedAt) {
      return mine[b].completedAt - mine[a].completedAt;
    }
    return a - b;
  });
  const out: Array<ProbeResult> = [];
  const n = Math.min(limit, idx.length);
  for (let i = 0; i < n; i++) {
    out.push(mine[idx[i]]);
  }
  return out;
}

// ---------------------------------------------------------------- 8. 重测入口判断

/**
 * "重测失败"入口判断（§6.5）：失败/未保存/不适用/取消占比>0（即任一存在）时 true。
 * queued/running 不计入（进行中不是失败）。空数组 false。
 */
export function shouldShowRetest(results: Array<ProbeResult>): boolean {
  let bad = 0;
  for (let i = 0; i < results.length; i++) {
    const st = results[i].state;
    if (st === PROBE_STATE_FAILED || st === PROBE_STATE_UNSAVED
      || st === PROBE_STATE_NOT_APPLICABLE || st === PROBE_STATE_CANCELLED) {
      bad += 1;
    }
  }
  return results.length > 0 && bad > 0;
}

// ---------------------------------------------------------------- 9. 方式显示口径

/**
 * 显示口径 token（§6.2/§6.6）：页面按 token 映射文案，不得在页面里散落分支。
 * - HTTP 2xx 判据 → `http_2xx`（页面文案"满足 2xx 判据"，桥接不回传状态码时不凭空显示"204"）；
 * - HTTP any 判据 → `http_any_response`（措辞"HTTP 有响应"，不得把 403/500 说成正常访问）；
 * - TCPing → `tcping`；未知方式（legacy）→ `unknown`；
 * - methodActual !== methodRequested → `http_degraded_tcping`（HTTP 回退 TCPing，不得当 HTTP 展示）。
 */
export function methodLabelToken(r: ProbeResult): string {
  if (r.methodActual === PROBE_METHOD_UNKNOWN) {
    return 'unknown';
  }
  if (r.methodActual !== PROBE_METHOD_HTTP && r.methodActual !== PROBE_METHOD_TCPING) {
    // 未识别的实际方式：如实标 unknown，不得伪装成"HTTP 降级 TCPing"（§6.2 不伪造语义）
    return 'unknown';
  }
  if (r.methodActual !== r.methodRequested) {
    return 'http_degraded_tcping';
  }
  if (r.methodActual === PROBE_METHOD_HTTP) {
    if (r.expectedStatus === PROBE_EXPECT_2XX) {
      return 'http_2xx';
    }
    if (r.expectedStatus === PROBE_EXPECT_ANY) {
      return 'http_any_response';
    }
    return `http_${r.expectedStatus}`;
  }
  if (r.methodActual === PROBE_METHOD_TCPING) {
    return 'tcping';
  }
  return 'unknown';
}

// ---------------------------------------------------------------- 10. 新鲜度口径

/**
 * 新鲜度 token：`fresh`（可比较且未过期）/ `stale`（过期或 legacy）/ `untested`
 * （latencyMs<0 且非 failed——未测出延迟；0ms 是合法数值不算 untested）。
 * failed 结果不判 untested：当前这一轮的失败是"新鲜的失败"，仍可查看原文（§6.6 取消不是失败、失败可查看原文）。
 */
export function freshnessToken(r: ProbeResult, nowMs: number, staleMs: number): string {
  if (r.latencyMs < 0 && r.state !== PROBE_STATE_FAILED) {
    return 'untested';
  }
  if (isComparableFresh(r, nowMs, staleMs)) {
    return 'fresh';
  }
  return 'stale';
}
