/**
 * ProbeResult 统一检测结果模型 —— REDESIGN-PLAN-2026-10-23.md §6.2/§6.6。
 *
 * 与节点配置独立存储，以 profileId＋profileConfigHash＋method＋target＋policy＋path
 * 识别可比较结果(§6.2)。旧 status/ping/error/latencyMs 继续作为兼容投影，不作为
 * 新结果的完整事实来源。纯模型，无平台依赖，便于主机测试。
 */

/** 结果状态(§6.2 state) */
export const PROBE_STATE_QUEUED: string = 'queued';
export const PROBE_STATE_RUNNING: string = 'running';
export const PROBE_STATE_SUCCESS: string = 'success';
export const PROBE_STATE_FAILED: string = 'failed';
export const PROBE_STATE_NOT_APPLICABLE: string = 'notApplicable';
export const PROBE_STATE_CANCELLED: string = 'cancelled';
export const PROBE_STATE_UNSAVED: string = 'unsaved';

/** 检测方式：请求方式与实际方式分开(HTTP 回退 TCP 不可混淆) */
export const PROBE_METHOD_HTTP: string = 'http';
export const PROBE_METHOD_TCPING: string = 'tcping';
/** 旧结果迁移用：method/path 未知，不得伪造为 HTTP 通过(§6.2) */
export const PROBE_METHOD_UNKNOWN: string = 'unknown';

/** 检测路径(§6.2 path)：未知路径不假装直出 */
export const PROBE_PATH_DIRECT_BOUND: string = 'directBound';
export const PROBE_PATH_CURRENT_TUNNEL: string = 'currentTunnel';
export const PROBE_PATH_UNBOUND_UNKNOWN: string = 'unboundUnknown';
export const PROBE_PATH_LEGACY_UNKNOWN: string = 'legacyUnknown';

/** 结果来源(§6.2 source) */
export const PROBE_SOURCE_MANUAL: string = 'manual';
export const PROBE_SOURCE_AUTO_GROUP: string = 'autoGroup';
export const PROBE_SOURCE_RUN_INSTANCE: string = 'runInstance';
export const PROBE_SOURCE_LEGACY: string = 'legacy';

/** 内核能力(§6.2 coreCapability)：桥接不回传状态码时不得凭空显示"204" */
export const PROBE_CAP_NATIVE_V3: string = 'native-v3';
export const PROBE_CAP_NATIVE_V2: string = 'native-v2';
export const PROBE_CAP_LEGACY: string = 'legacy';
export const PROBE_CAP_UNAVAILABLE: string = 'unavailable';

/** HTTP 判据：现有桥接不回传状态码，显示"满足 2xx 判据"即可(§6.1) */
export const PROBE_EXPECT_2XX: string = '2xx';
/** 旧装保留判据："收到 HTTP 响应即通过"，措辞用"HTTP 有响应"(§6.1/§6.6) */
export const PROBE_EXPECT_ANY: string = 'any';

/** 聚合口径 */
export const PROBE_AGG_SINGLE: string = 'single';
export const PROBE_AGG_MEDIAN: string = 'median';
export const PROBE_AGG_AVG: string = 'avg';

/** 参与状态标记：取消尚未执行的节点保留原结果并标明未参与(§6.3) */
export const PROBE_PARTICIPATED_YES: string = 'yes';
export const PROBE_PARTICIPATED_NO: string = 'no';

/** 计算 profile 传输配置 hash：仅改名称/分组/缓存延迟不使 hash 失效(§6.2)。 */
export const PROFILE_HASH_EXCLUDED_KEYS: Array<string> = [
  'name', 'groupId', 'groupOrder', 'favorite', 'pinned',
  'latencyMs', 'latencyTestedAt', 'latencySource'
];

/** FNV-1a 32 位(ConfigSnapshot 同款实现，保证跨模块一致)。 */
export function fnv1a32(text: string): string {
  let hash = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}

/**
 * 由 profile JSON 计算传输配置 hash：键排序 + 排除 UI 专属字段，
 * 保证"仅改名称/收藏"不产生新 hash、传输字段任何变化都产生新 hash(§6.2)。
 */
export function computeProfileConfigHash(profileJson: string): string {
  let stable = '';
  try {
    const obj = JSON.parse(profileJson) as Record<string, Object>;
    const keys = Object.keys(obj).sort();
    const parts: Array<string> = [];
    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      let excluded = false;
      for (let j = 0; j < PROFILE_HASH_EXCLUDED_KEYS.length; j++) {
        if (PROFILE_HASH_EXCLUDED_KEYS[j] === k) {
          excluded = true;
          break;
        }
      }
      if (excluded) {
        continue;
      }
      parts.push(`${k}=${obj[k] === undefined ? '' : JSON.stringify(obj[k])}`);
    }
    stable = parts.join('\u0001');
  } catch (e) {
    // 非法 JSON：hash 覆盖原文，调用方按未知配置处理
    stable = profileJson;
  }
  return `pf-${fnv1a32(stable)}`;
}

/** 一次检测结果(§6.2 字段表)。latencyMs：0 合法，-1 = 未测。 */
export class ProbeResult {
  runId: string = '';
  profileId: string = '';
  configRevision: number = 0;
  profileConfigHash: string = '';
  methodRequested: string = PROBE_METHOD_HTTP;
  methodActual: string = PROBE_METHOD_HTTP;
  state: string = PROBE_STATE_QUEUED;
  /** 0ms 是合法数值；-1 = 未测出延迟 */
  latencyMs: number = -1;
  samples: number = 1;
  aggregation: string = PROBE_AGG_SINGLE;
  target: string = '';
  timeoutMs: number = 5000;
  expectedStatus: string = PROBE_EXPECT_2XX;
  startedAt: number = 0;
  completedAt: number = 0;
  persistedAt: number = 0;
  path: string = PROBE_PATH_UNBOUND_UNKNOWN;
  errorCode: string = '';
  errorDetail: string = '';
  degradedReason: string = '';
  coreCapability: string = PROBE_CAP_UNAVAILABLE;
  source: string = PROBE_SOURCE_MANUAL;
  /** 取消/预算耗尽等场景：该节点是否实际参与了本轮(§6.3 未参与保留原结果) */
  participated: string = PROBE_PARTICIPATED_YES;

  /** 旧结果(status/ping/error)迁移：method=unknown、path=legacyUnknown，不伪造 HTTP 通过(§6.2)。 */
  static fromLegacy(profileId: string, status: number, ping: number, error: string): ProbeResult {
    const r = new ProbeResult();
    r.profileId = profileId;
    r.methodRequested = PROBE_METHOD_UNKNOWN;
    r.methodActual = PROBE_METHOD_UNKNOWN;
    r.path = PROBE_PATH_LEGACY_UNKNOWN;
    r.source = PROBE_SOURCE_LEGACY;
    r.coreCapability = PROBE_CAP_LEGACY;
    // 旧语义:status 1/2=成功(绿/可用),3=失败;latency 0 表示未测 → 这里转 -1
    if (error.length > 0) {
      r.state = PROBE_STATE_FAILED;
      r.errorDetail = error;
      r.latencyMs = -1;
    } else if (status === 1 || status === 2) {
      r.state = PROBE_STATE_SUCCESS;
      r.latencyMs = ping;
    } else {
      r.state = PROBE_STATE_FAILED;
      r.errorDetail = `legacy status=${status}`;
      r.latencyMs = ping > 0 ? ping : -1;
    }
    return r;
  }

  /** 兼容投影：旧 UI/status 字段继续可用，但不是完整事实来源(§6.2)。 */
  toLegacyStatus(): number {
    if (this.state === PROBE_STATE_SUCCESS) {
      return 1;
    }
    if (this.state === PROBE_STATE_FAILED) {
      return 3;
    }
    return 0;
  }

  toLegacyPing(): number {
    return this.latencyMs > 0 ? this.latencyMs : 0;
  }
}

/** 可比较结果的身份键(§6.2：profileId＋profileConfigHash＋method＋target＋policy＋path)。 */
export function probeKeyOf(r: ProbeResult): string {
  return [r.profileId, r.profileConfigHash, r.methodActual, r.target, r.expectedStatus, r.path].join('|');
}

/** 结果是否可参与"当前可用"过滤：同方法同目标同判据同路径且新鲜(§6.6)。 */
export function isComparableFresh(r: ProbeResult, nowMs: number, staleMs: number): boolean {
  if (r.state !== PROBE_STATE_SUCCESS && r.state !== PROBE_STATE_FAILED) {
    return false;
  }
  if (r.completedAt <= 0 || nowMs - r.completedAt > staleMs) {
    return false;
  }
  return r.methodActual !== PROBE_METHOD_UNKNOWN && r.path !== PROBE_PATH_LEGACY_UNKNOWN;
}
