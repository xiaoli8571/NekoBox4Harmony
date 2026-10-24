/**
 * 首页分组折叠与订阅视图的纯逻辑(便于单元测试;UI 层 Index.ets 只做绑定)。
 * - 折叠状态自 2.1.5 起以 JSON 数组持久化(键 home_collapsed_groups),
 *   旧版 '|' 分隔格式仍可解析;空串条目是「未分组」分组的合法 id,必须保留。
 * - 首页底部订阅选择器(键 home_selected_sub):'' 表示手动节点视图。
 */

import {
  ProbeResult, PROBE_STATE_SUCCESS, PROBE_STATE_FAILED, PROBE_STATE_QUEUED,
  PROBE_STATE_RUNNING, PROBE_STATE_NOT_APPLICABLE, isComparableFresh
} from './ProbeResult';
import { filterUsable, methodLabelToken, freshnessToken } from './ProbeFilters';
import { Profile } from './Profile';

/** 解析折叠状态:JSON 数组优先,兼容旧版 '|' 分隔;空串→空列表 */
export function parseCollapsedIds(raw: string): Array<string> {
  if (raw.length === 0) {
    return [];
  }
  if (raw.startsWith('[')) {
    try {
      const parsed = JSON.parse(raw) as Array<object>;
      if (Array.isArray(parsed)) {
        const ids: Array<string> = [];
        for (const item of parsed) {
          if (typeof item === 'string') {
            ids.push(item);
          }
        }
        return ids;
      }
    } catch (e) {
      // 非 JSON,按旧格式处理
    }
  }
  return raw.split('|');
}

/** 序列化折叠状态(JSON 数组;保留空串=未分组条目) */
export function serializeCollapsedIds(ids: Array<string>): string {
  return JSON.stringify(ids);
}

/** 折叠/展开一个分组(返回新数组,不修改入参) */
export function toggleCollapsed(ids: Array<string>, groupId: string): Array<string> {
  const next = ids.slice();
  const i = next.indexOf(groupId);
  if (i >= 0) {
    next.splice(i, 1);
  } else {
    next.push(groupId);
  }
  return next;
}

/**
 * 解析首页底部选中的订阅:
 * 持久化值仍有效→用之;否则激活订阅(运行中)→用之;否则第一个订阅;无订阅→手动视图('')
 */
export function resolveSelectedSub(savedSub: string, activeSubUrl: string, subUrls: Array<string>): string {
  if (savedSub.length > 0 && subUrls.indexOf(savedSub) >= 0) {
    return savedSub;
  }
  if (activeSubUrl.length > 0 && subUrls.indexOf(activeSubUrl) >= 0) {
    return activeSubUrl;
  }
  if (subUrls.length > 0) {
    return subUrls[0];
  }
  return '';
}

/** 节点是否属于当前首页视图:''=手动视图只显示非订阅节点 */
export function inSubView(subUrl: string, selectedSubUrl: string): boolean {
  return subUrl === selectedSubUrl;
}

// ============================================================ P3/W12 节点首页视图模型（§4）

/**
 * W12：节点首页与连接状态的纯视图模型。核心约束（§4.2）：**会话状态与连通性两套状态严格独立**
 * ——连通性探测失败不得改变会话状态或主按钮；未知状态不得冒充已连接（§4.3-2 不发起重连循环）。
 * 纯函数无 I/O；result 参数吃 Array<ProbeResult>（StoredProbe 字段同名，按字段读），
 * 不 import core/ProbeStore。延迟分档阈值与 pages/Index.ets latencyColorOfMs 一致
 * （<150 fast / <400 medium / ≥400 slow；负数无值）。
 */

// ---------------------------------------------------------------- 1. 会话视图

/** VPN 会话状态 token：disconnected/awaiting_auth/connecting/connected/switching/disconnecting/connect_failed/unknown（状态待确认） */
export class VpnSessionView {
  state: string = 'unknown';
  titleToken: string = 'unknown';
  /** connect_failed 时的内核错误原文（'connect_failed:' 前缀之后的部分）；其余状态为 ''，不编造 */
  detail: string = '';
  runningProfileName: string = '';
  /** 状态尚未确认（switching / unknown / 运行标记与状态矛盾） */
  confirmPending: boolean = false;
}

/**
 * 由 vpnStatus（AppStorage 'vpnStatus'，词表同 pages/Index.ets：connecting/connected/
 * disconnected/disconnecting/switching/awaiting_auth/connect_failed:<msg>）推导会话视图。
 * 决策：
 *  - 状态词即 token；未识别/空串 → 'unknown'（不冒充 connected，§4.3-2）；
 *  - vpnRunning=true 而状态 disconnected/未知 → 'unknown'+confirmPending（数据矛盾，待确认）；
 *  - 'connect_failed:<msg>' → state 'connect_failed'，detail=冒号后内核原文；
 *  - confirmPending = switching || unknown（切换中未确认，节点行不得标"正在使用"）。
 */
export function vpnSessionView(vpnStatus: string, running: boolean, runningProfileId: string,
  profileName: string): VpnSessionView {
  const v = new VpnSessionView();
  let base = 'unknown';
  if (vpnStatus === 'disconnected' || vpnStatus === 'awaiting_auth' || vpnStatus === 'connecting'
    || vpnStatus === 'connected' || vpnStatus === 'switching' || vpnStatus === 'disconnecting') {
    base = vpnStatus;
  } else if (vpnStatus.startsWith('connect_failed:')) {
    base = 'connect_failed';
    v.detail = vpnStatus.substring('connect_failed:'.length);
  } else if (vpnStatus === 'connect_failed') {
    base = 'connect_failed';
  } else {
    // 未识别/空状态：不冒充 connected（§4.3-2）
    base = 'unknown';
  }
  if (running && (base === 'disconnected' || base === 'unknown')) {
    base = 'unknown';
  }
  v.state = base;
  v.titleToken = base;
  v.runningProfileName = profileName;
  v.confirmPending = base === 'switching' || base === 'unknown';
  return v;
}

// ---------------------------------------------------------------- 2. 连通性视图

/** 连通性 token：untested/probing/reachable/failed/stale/restricted（方式或环境受限） */
export class ConnectivityView {
  state: string = 'untested';
  titleToken: string = 'untested';
  methodToken: string = 'unknown';
  latencyMs: number = -1;
  ageText: string = '';
  target: string = '';
}

/** 相对时间文案：刚刚 / N 分钟前 / N 小时前 / N 天前 */
function ageTextOf(completedAt: number, nowMs: number): string {
  if (completedAt <= 0 || nowMs <= 0) {
    return '';
  }
  const diff = nowMs - completedAt;
  if (diff <= 0 || diff < 60000) {
    return '刚刚';
  }
  if (diff < 3600000) {
    return `${Math.floor(diff / 60000)} 分钟前`;
  }
  if (diff < 86400000) {
    return `${Math.floor(diff / 3600000)} 小时前`;
  }
  return `${Math.floor(diff / 86400000)} 天前`;
}

/**
 * 当前会话路径的连通性（来自最近一次探测结果；§6.2/§6.6）。
 * 决策：
 *  - result null / cancelled / unsaved → 'untested'（本轮无值）；running/queued → 'probing'；
 *  - success + method unknown（legacy）或 http_degraded_tcping → 'restricted'
 *    （TCP 成功只证明握手可达；旧结果不伪造 HTTP 通过，§6.2/§6.6）；
 *  - success + 判据正常但过期 → 'stale'；success + 新鲜 → 'reachable'；
 *  - failed → 'failed'；notApplicable（方式不支持）→ 'restricted'。
 * 本视图绝不反向写回会话状态（§4.2 两套状态独立）。
 */
export function connectivityView(result: ProbeResult | null, nowMs: number, staleMs: number): ConnectivityView {
  const v = new ConnectivityView();
  if (result === null) {
    return v;
  }
  v.methodToken = methodLabelToken(result);
  v.latencyMs = result.latencyMs;
  v.target = result.target;
  v.ageText = ageTextOf(result.completedAt, nowMs);
  let state = 'untested';
  if (result.state === PROBE_STATE_RUNNING || result.state === PROBE_STATE_QUEUED) {
    state = 'probing';
  } else if (result.state === PROBE_STATE_SUCCESS) {
    if (v.methodToken === 'unknown' || v.methodToken === 'http_degraded_tcping') {
      state = 'restricted';
    } else if (!isComparableFresh(result, nowMs, staleMs)) {
      state = 'stale';
    } else {
      state = 'reachable';
    }
  } else if (result.state === PROBE_STATE_FAILED) {
    state = 'failed';
  } else if (result.state === PROBE_STATE_NOT_APPLICABLE) {
    state = 'restricted';
  } else {
    state = 'untested';
  }
  v.state = state;
  v.titleToken = state;
  return v;
}

// ---------------------------------------------------------------- 3. 状态卡

/** 状态卡（§4.2：会话区 + 连通性区解耦渲染）。 */
export class StatusCardView {
  session: VpnSessionView = new VpnSessionView();
  connectivity: ConnectivityView = new ConnectivityView();
  primaryAction: string = 'unknown';
  /** §4.1 固定含 checkConnectivity、connectionDetails */
  secondaryActions: Array<string> = [];
  /** 折叠摘要：`${session.titleToken} · ${connectivity.titleToken}`（P3 映射 i18n） */
  collapsedSummary: string = '';
}

/**
 * 主按钮按会话状态（§4.1）：disconnected→connect；connected→disconnect；
 * connecting/switching/disconnecting/awaiting_auth→cancel；connect_failed→retry；
 * unknown→unknown（状态未确认时不得提供断开）。connectivity 失败不影响任何字段。
 */
export function statusCardView(session: VpnSessionView, connectivity: ConnectivityView): StatusCardView {
  const v = new StatusCardView();
  v.session = session;
  v.connectivity = connectivity;
  let action = 'unknown';
  if (session.state === 'disconnected') {
    action = 'connect';
  } else if (session.state === 'connected') {
    action = 'disconnect';
  } else if (session.state === 'connecting' || session.state === 'switching'
    || session.state === 'disconnecting' || session.state === 'awaiting_auth') {
    action = 'cancel';
  } else if (session.state === 'connect_failed') {
    action = 'retry';
  } else {
    action = 'unknown';
  }
  v.primaryAction = action;
  v.secondaryActions = ['checkConnectivity', 'connectionDetails'];
  v.collapsedSummary = `${session.titleToken} · ${connectivity.titleToken}`;
  return v;
}

// ---------------------------------------------------------------- 4. 节点行

/** 节点行上下文（页面注入的浏览状态）。 */
export class NodeRowContext {
  nowMs: number = 0;
  staleMs: number = 0;
  selectedProfileId: string = '';
  runningProfileId: string = '';
  runningConfirmed: boolean = false;
}

/**
 * 节点行（§4.1/§6.6）。三态区分（§3.2/§4.4）：
 *  - selected：当前选中（点击=连接/切换）；
 *  - running：正在使用（需 ctx.runningConfirmed 确认，-runningProfileId 匹配且已确认）；
 *  - confirmPending：切换中未确认 → 显示"正在确认"，**不得**标"正在使用"。
 * latencyToken：`N ms` / 失败 / —（未测）/ 检测中（探测中）；latencyBucket：fast/medium/slow/none。
 */
export class NodeRowView {
  profileId: string = '';
  primary: string = '';
  secondary: string = '';
  latencyToken: string = '—';
  latencyBucket: string = 'none';
  methodToken: string = 'unknown';
  freshnessToken: string = 'untested';
  ageText: string = '';
  failed: boolean = false;
  primaryAction: string = 'connect';
  selected: boolean = false;
  running: boolean = false;
  confirmPending: boolean = false;
  /** 失败且带内核原文（可展开查看，§6.6 失败可查看原文） */
  expandableError: boolean = false;
}

/** 延迟分档（与 pages/Index.ets latencyColorOfMs 同阈值：<150 fast / <400 medium / ≥400 slow）。 */
function latencyBucketOf(ms: number): string {
  if (ms < 0) {
    return 'none';
  }
  if (ms < 150) {
    return 'fast';
  }
  if (ms < 400) {
    return 'medium';
  }
  return 'slow';
}

/** 由 profile + 最近一次探测结果 + 浏览上下文构建节点行视图。 */
export function nodeRowView(profile: Profile, result: ProbeResult | null, ctx: NodeRowContext): NodeRowView {
  const v = new NodeRowView();
  v.profileId = profile.id;
  v.primary = profile.name.length > 0 ? profile.name : profile.server;
  v.secondary = `${profile.server}:${profile.serverPort}`;
  v.selected = ctx.selectedProfileId === profile.id;
  v.running = ctx.runningProfileId === profile.id && ctx.runningConfirmed;
  v.confirmPending = ctx.runningProfileId === profile.id && !ctx.runningConfirmed;
  if (result !== null) {
    v.methodToken = methodLabelToken(result);
    v.freshnessToken = freshnessToken(result, ctx.nowMs, ctx.staleMs);
    v.ageText = ageTextOf(result.completedAt, ctx.nowMs);
    v.failed = result.state === PROBE_STATE_FAILED;
    v.expandableError = v.failed && result.errorDetail.length > 0;
    const probing = result.state === PROBE_STATE_RUNNING || result.state === PROBE_STATE_QUEUED;
    if (probing) {
      v.latencyToken = '检测中';
      v.latencyBucket = 'none';
    } else if (v.failed) {
      v.latencyToken = '失败';
      v.latencyBucket = 'none';
    } else if (result.state === PROBE_STATE_SUCCESS && result.latencyMs >= 0) {
      v.latencyToken = `${result.latencyMs} ms`;
      v.latencyBucket = latencyBucketOf(result.latencyMs);
    } else {
      v.latencyToken = '—';
      v.latencyBucket = 'none';
    }
  }
  if (v.running) {
    v.primaryAction = 'inUse';
  } else if (v.confirmPending) {
    v.primaryAction = 'confirming';
  } else {
    v.primaryAction = 'connect';
  }
  return v;
}

// ---------------------------------------------------------------- 5. 筛选/排序

/**
 * 工具条筛选（§4.1）：搜索（name/server，大小写不敏感，去首尾空白）＋收藏＋仅看可用。
 * 收藏口径：注入 isFavorite 优先；缺省回退 Profile.pinned（本仓库的置顶/收藏字段）。
 * 仅看可用：results 中存在 success 且 isComparableFresh 的该 profileId（复用 filterUsable）。
 * 返回新数组（保持输入顺序），不改输入。
 */
export function filterNodes(nodes: Array<Profile>, query: string, onlyFavorites: boolean,
  onlyUsable: boolean, results: Array<ProbeResult>, nowMs: number, staleMs: number,
  isFavorite?: (profileId: string) => boolean): Array<Profile> {
  const q = query.trim().toLowerCase();
  const usableIds: Map<string, boolean> = new Map();
  if (onlyUsable) {
    const usable = filterUsable(results, nowMs, staleMs);
    for (let i = 0; i < usable.length; i++) {
      usableIds.set(usable[i].profileId, true);
    }
  }
  const out: Array<Profile> = [];
  for (let i = 0; i < nodes.length; i++) {
    const p = nodes[i];
    if (q.length > 0) {
      const name = p.name.toLowerCase();
      const server = p.server.toLowerCase();
      if (name.indexOf(q) < 0 && server.indexOf(q) < 0) {
        continue;
      }
    }
    if (onlyFavorites) {
      let fav = false;
      if (isFavorite !== undefined) {
        fav = isFavorite(p.id);
      } else {
        fav = p.pinned;
      }
      if (!fav) {
        continue;
      }
    }
    if (onlyUsable && !usableIds.has(p.id)) {
      continue;
    }
    out.push(p);
  }
  return out;
}

/**
 * 工具条排序（§4.1），mode：manual（保持原顺序）/ latency / name（localeCompare 中文友好）。
 * latency 桶序：success（按 latencyMs 升序，0ms 最前，-1 不当 0）→ failed（次后）→ 未测/其他（最后）；
 * 同桶/同延迟保持输入顺序（稳定）。results 每 profileId 取 completedAt 最新一条参与排序。
 * 返回新数组，不改输入。
 */
export function sortNodes(nodes: Array<Profile>, mode: string, results: Array<ProbeResult>): Array<Profile> {
  const out = nodes.slice();
  if (mode === 'name') {
    const idx: Array<number> = [];
    for (let i = 0; i < out.length; i++) {
      idx.push(i);
    }
    idx.sort((a: number, b: number): number => {
      const d = out[a].name.localeCompare(out[b].name, 'zh');
      if (d !== 0) {
        return d;
      }
      return a - b;
    });
    const ordered: Array<Profile> = [];
    for (let i = 0; i < idx.length; i++) {
      ordered.push(out[idx[i]]);
    }
    return ordered;
  }
  if (mode === 'latency') {
    const latest: Map<string, ProbeResult> = new Map();
    for (let i = 0; i < results.length; i++) {
      const r = results[i];
      const prev = latest.get(r.profileId);
      if (prev === undefined || r.completedAt >= prev.completedAt) {
        latest.set(r.profileId, r);
      }
    }
    const idx: Array<number> = [];
    for (let i = 0; i < out.length; i++) {
      idx.push(i);
    }
    idx.sort((a: number, b: number): number => {
      const ra = latencySortRank(latest.get(out[a].id));
      const rb = latencySortRank(latest.get(out[b].id));
      if (ra !== rb) {
        return ra - rb;
      }
      if (ra === 0) {
        const la = latest.get(out[a].id);
        const lb = latest.get(out[b].id);
        if (la !== undefined && lb !== undefined && la.latencyMs !== lb.latencyMs) {
          return la.latencyMs - lb.latencyMs;
        }
      }
      return a - b;
    });
    const ordered: Array<Profile> = [];
    for (let i = 0; i < idx.length; i++) {
      ordered.push(out[idx[i]]);
    }
    return ordered;
  }
  return out;
}

/** latency 排序桶：0=success 有有效延迟（0ms 合法）；1=failed；2=未测/其他（最后）。 */
function latencySortRank(r: ProbeResult | undefined): number {
  if (r === undefined) {
    return 2;
  }
  if (r.state === PROBE_STATE_SUCCESS && r.latencyMs >= 0) {
    return 0;
  }
  if (r.state === PROBE_STATE_FAILED) {
    return 1;
  }
  return 2;
}

// ---------------------------------------------------------------- 6. 空态

/** 空态上下文（§4.5）。 */
export class EmptyContext {
  nodeCount: number = 0;
  networkAvailable: boolean = true;
  firstAuthorizationDenied: boolean = false;
  importJustCompleted: boolean = false;
  importedCount: number = 0;
  skippedTypes: Array<string> = [];
}

/** 空态视图（§4.5）。importedCount/skippedTypes 为 P3 渲染计数的附加字段。 */
export class EmptyState {
  titleToken: string = '';
  bodyToken: string = '';
  primaryAction: string = '';
  secondaryActions: Array<string> = [];
  showConnectButton: boolean = false;
  importedCount: number = 0;
  skippedTypes: Array<string> = [];
}

/**
 * 空态四类（§4.5）+ showConnectButton 规则：nodeCount===0 恒 false（不得显示必然失败的连接按钮）；
 * 导入完成/授权被拒/无网络三类空态也一律 false。仅当 nodeCount>0 且网络可用、无授权问题、
 * 非导入完成引导态时才可能为 true（P3 不应在该组合下调用本函数）。
 * 优先级：导入完成引导 → 授权被拒 → 无网络 → 无节点。
 */
export function emptyStateFor(ctx: EmptyContext): EmptyState {
  const v = new EmptyState();
  if (ctx.importJustCompleted && ctx.nodeCount > 0) {
    v.titleToken = 'import_done';
    v.bodyToken = ctx.skippedTypes.length > 0 ? 'import_done_with_skipped' : 'import_done_simple';
    v.primaryAction = 'check_availability';
    v.secondaryActions = ['choose_and_connect'];
    v.importedCount = ctx.importedCount;
    v.skippedTypes = ctx.skippedTypes.slice();
  } else if (ctx.firstAuthorizationDenied) {
    v.titleToken = 'auth_denied';
    v.bodyToken = 'auth_denied_body';
    v.primaryAction = 'open_settings';
    v.secondaryActions = ['retry'];
  } else if (!ctx.networkAvailable) {
    v.titleToken = 'offline';
    v.bodyToken = 'offline_body';
    v.primaryAction = 'open_network_settings';
    v.secondaryActions = ['retry'];
  } else {
    v.titleToken = 'no_nodes';
    v.bodyToken = 'no_nodes_body';
    v.primaryAction = 'import_subscription';
    v.secondaryActions = ['import_file', 'open_guide'];
  }
  v.showConnectButton = ctx.nodeCount > 0 && ctx.networkAvailable
    && !ctx.firstAuthorizationDenied && !ctx.importJustCompleted;
  return v;
}

// ---------------------------------------------------------------- 7. 动作可用原因

/** 动作可用性 + 机器可读原因 token（§3.3）。 */
export class ActionReason {
  enabled: boolean = false;
  reason: string = '';
}

/**
 * 连接动作可用性（§3.3）：无节点→no_profile；配置不合法→config_invalid（停在当前页给修复入口，
 * 不发起重连循环 §4.3-2）；切换进行中→applying；否则 enabled（reason='ok'）。
 * 原因优先级：no_profile > config_invalid > applying。
 */
export function connectActionEnabled(profileCount: number, configValid: boolean, applying: boolean): ActionReason {
  const v = new ActionReason();
  if (profileCount <= 0) {
    v.enabled = false;
    v.reason = 'no_profile';
    return v;
  }
  if (!configValid) {
    v.enabled = false;
    v.reason = 'config_invalid';
    return v;
  }
  if (applying) {
    v.enabled = false;
    v.reason = 'applying';
    return v;
  }
  v.enabled = true;
  v.reason = 'ok';
  return v;
}
