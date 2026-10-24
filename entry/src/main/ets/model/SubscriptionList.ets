import { SubInfo, SubUpdateResult } from '../core/Subscriptions';

/**
 * 订阅页视图模型 —— REDESIGN-PLAN-2026-10-23.md §3.1(订阅页职责)/§3.3(顶栏动作)/
 * §11.1-2(订阅身份与源)/§4.5(空态)。
 *
 * 纯函数/纯数据：不做 I/O、不读 Preferences、不碰时间之外的平台能力。
 * 输入一律是既有实体(SubInfo/SubUpdateResult)与显式 nowMs，便于主机测试
 * (tests/subscription-list.cjs)与真机行为一致。
 *
 * 与既有语义的对齐(2026-10-24 核对 core/Subscriptions.ets：31-63)：
 *  - 自动更新间隔字段是 `updateIntervalMinutes`(默认 1440)，不是安卓的 autoUpdateDelay；
 *    旧字段 `updateIntervalHours` 只在 minutes<=0 时兜底(与 listSubs 的读时迁移同口径)；
 *  - `autoUpdate` 布尔决定该订阅是否参与自动更新 —— 为 false 时即使间隔有值也如实显示"已关闭"；
 *  - 到期时间 `expire` 为 unix **秒**(0=未知)，详见 GroupPage/SubDetailPage 的既有用法；
 *  - 失败以 **throw** 表达(Subscriptions.ets:630/680)，所以批量摘要额外接受调用方捕获到的
 *    失败原文(failureMessages)，不吞错误。
 */

/** 行主状态 token(用 string + 常量而不是字面量联合类型，符合本仓库 ArkTS 风格)。 */
export const ROW_STATE_OK: string = 'ok';
export const ROW_STATE_NEVER: string = 'never';
export const ROW_STATE_FAILED: string = 'failed';
export const ROW_STATE_UPDATING: string = 'updating';
export const ROW_STATE_EXPIRED: string = 'expired';

/** 到期子状态 token(§11.1 到期提示)。 */
export const EXPIRY_NONE: string = 'none';
export const EXPIRY_NEAR: string = 'nearExpiry';
export const EXPIRY_EXPIRED: string = 'expired';

/** 空态 token(§4.5)。 */
export const EMPTY_NONE: string = '';
export const EMPTY_NO_SUBS: string = 'no_subs';
export const EMPTY_OFFLINE: string = 'offline';

/* ---- P6/W21 i18n:行文本 token(模型不再产出用户语言,页面把 token+param 映射 $r) ---- */
/** lastUpdatedToken */
export const LAST_UPDATED_NEVER: string = 'never';
export const LAST_UPDATED_JUST_NOW: string = 'just_now';
export const LAST_UPDATED_MINUTES: string = 'minutes_ago';
export const LAST_UPDATED_HOURS: string = 'hours_ago';
export const LAST_UPDATED_DAYS: string = 'days_ago';
/** autoUpdateToken */
export const AUTO_UPDATE_OFF: string = 'off';
export const AUTO_UPDATE_EVERY_MINUTES: string = 'every_minutes';
export const AUTO_UPDATE_DAILY: string = 'daily';
export const AUTO_UPDATE_EVERY_DAYS: string = 'every_days';
export const AUTO_UPDATE_HOURLY: string = 'hourly';
export const AUTO_UPDATE_EVERY_HOURS: string = 'every_hours';
/** expiryToken */
export const EXPIRY_TOKEN_UNKNOWN: string = 'unknown';
export const EXPIRY_TOKEN_EXPIRED_DAYS: string = 'expired_days';
export const EXPIRY_TOKEN_JUST_EXPIRED: string = 'just_expired';
export const EXPIRY_TOKEN_IN_DAYS: string = 'in_days';
export const EXPIRY_TOKEN_DATE: string = 'date';

/** token + 参数的通用载体(param 供 %1$d,extraText 供 %1$s,如到期日期)。 */
export class TextToken {
  token: string = '';
  param: number = 0;
  extraText: string = '';
}

/** 空态动作 token(§4.5：primary 导入/添加，secondary 扫码/从文件/手动)。 */
export const EMPTY_ACTION_ADD: string = 'add';
export const EMPTY_ACTION_SCAN: string = 'scan';
export const EMPTY_ACTION_FROM_FILE: string = 'from_file';
export const EMPTY_ACTION_MANUAL: string = 'manual';

const DAY_MS: number = 86400000;
const HOUR_MS: number = 3600000;
const MINUTE_MS: number = 60000;
/** 临期阈值(§11.1：<7 天给 nearExpiry)。 */
const NEAR_EXPIRY_MS: number = 7 * DAY_MS;

/** 单个订阅的节点数(避免把 Map 直接塞进 ArkUI 状态；Index 用 nodeCountsFromSubUrls 生成)。 */
export class SubscriptionNodeCount {
  url: string = '';
  count: number = 0;
}

/** 订阅列表行视图(页面只渲染它，不做计算)。P6/W21:文本字段为 token+param,页面映射 $r。 */
export class SubscriptionRowView {
  url: string = '';
  name: string = '';
  group: string = '';
  nodeCount: number = 0;
  /** LAST_UPDATED_*(分钟/小时/天带 param) */
  lastUpdatedToken: string = LAST_UPDATED_NEVER;
  lastUpdatedParam: number = 0;
  /** AUTO_UPDATE_*(带间隔的形态带 param) */
  autoUpdateToken: string = AUTO_UPDATE_OFF;
  autoUpdateParam: number = 0;
  /** 已用字节数的紧凑文本(如 "1.2 GB",数字与单位不本地化) */
  trafficUsedText: string = '';
  /** 总量紧凑文本;空串 = 总量未知(页面用 sub_traffic_total_unknown) */
  trafficTotalText: string = '';
  /** EXPIRY_TOKEN_*(date 形态的日期文本在 expiryDateText) */
  expiryToken: string = EXPIRY_TOKEN_UNKNOWN;
  expiryParam: number = 0;
  /** YYYY-MM-DD(UTC);仅 token===EXPIRY_TOKEN_DATE 有值 */
  expiryDateText: string = '';
  /** ROW_STATE_*;状态文案页面映射 sub_state_<state> */
  state: string = ROW_STATE_OK;
  /** lastError 非空 → 可展开(不吞错误) */
  expandableError: boolean = false;
  /** lastError 原文(展开后原样显示) */
  errorText: string = '';
  /** 临期(<7 天)独立标记，供 UI 上色；与 state 正交 */
  nearExpiry: boolean = false;
  /** EXPIRY_NONE / EXPIRY_NEAR / EXPIRY_EXPIRED */
  expiryState: string = EXPIRY_NONE;
  /** 原始时间戳(秒/毫秒)，供页面显示细节或排序 */
  lastUpdate: number = 0;
  expire: number = 0;
  usedBytes: number = 0;
  totalBytes: number = 0;
  /** 自动更新是否开启(页面可显示小开关状态) */
  autoUpdateEnabled: boolean = false;
}

/** 批量更新摘要(页面反馈条)。 */
export class UpdateBatchSummary {
  /** 内容有变化的节点更新数(updatedNames 之和，不含新增/删除) */
  updated: number = 0;
  added: number = 0;
  removed: number = 0;
  /** 服务端 304 / 内容未变 */
  notModified: number = 0;
  /** 解析成功但被跳过的节点数 */
  skipped: number = 0;
  /** 失败订阅数(含 throw 捕获项) */
  failed: number = 0;
  /** 失败原文(不吞错误，按发生顺序) */
  failedMessages: Array<string> = [];
  /** 非失败类提示(如"无可解析节点"),原文 */
  notes: Array<string> = [];
}

/** 空态引导(§4.5)。文案 token → 页面 $r(sub_empty_<token>_title/_body)。 */
export class EmptyStateView {
  /** EMPTY_NONE / EMPTY_NO_SUBS / EMPTY_OFFLINE */
  token: string = EMPTY_NONE;
  /** 主按钮动作 token(EMPTY_ACTION_ADD) */
  primaryAction: string = '';
  /** 次要动作 token 列表(扫码/从文件/手动) */
  secondaryActions: Array<string> = [];
}

/** 字节数 → 紧凑可读文本(订阅流量行用；与 TrafficStats.formatBytes 口径不同，这里更短)。 */
function formatTrafficBytes(bytes: number): string {
  const n = bytes > 0 ? bytes : 0;
  if (n >= 1073741824) {
    return `${(n / 1073741824).toFixed(2)} GB`;
  }
  if (n >= 1048576) {
    return `${(n / 1048576).toFixed(1)} MB`;
  }
  if (n >= 1024) {
    return `${(n / 1024).toFixed(1)} KB`;
  }
  return `${Math.floor(n)} B`;
}

/** unix 秒 → UTC 日期(YYYY-MM-DD)。用 UTC 保证跨时区/主机测试确定性；近端日期走相对文案。 */
function formatUtcDate(unixSeconds: number): string {
  const d = new Date(unixSeconds * 1000);
  const y = d.getUTCFullYear();
  const m = d.getUTCMonth() + 1;
  const day = d.getUTCDate();
  const mm = m < 10 ? `0${m}` : `${m}`;
  const dd = day < 10 ? `0${day}` : `${day}`;
  return `${y}-${mm}-${dd}`;
}

/**
 * 自动更新间隔(分钟)：优先 updateIntervalMinutes；<=0 时用旧字段 updateIntervalHours 兜底
 * (与 Subscriptions.listSubs 的读时迁移同口径，§11.2)。
 */
function effectiveIntervalMinutes(sub: SubInfo): number {
  const minutes = Number(sub.updateIntervalMinutes);
  if (minutes > 0) {
    return Math.floor(minutes);
  }
  const hours = Number(sub.updateIntervalHours);
  if (hours > 0) {
    return Math.floor(hours) * 60;
  }
  return 0;
}

/** 自动更新间隔 token:不参与自动更新 / 间隔无效 → 如实显示关闭。 */
function autoUpdateOf(sub: SubInfo): TextToken {
  const out = new TextToken();
  out.token = AUTO_UPDATE_OFF;
  if (!sub.autoUpdate) {
    return out;
  }
  const minutes = effectiveIntervalMinutes(sub);
  if (minutes <= 0) {
    return out;
  }
  if (minutes < 60) {
    out.token = AUTO_UPDATE_EVERY_MINUTES;
    out.param = minutes;
    return out;
  }
  if (minutes % 1440 === 0) {
    const days = minutes / 1440;
    if (days === 1) {
      out.token = AUTO_UPDATE_DAILY;
      return out;
    }
    out.token = AUTO_UPDATE_EVERY_DAYS;
    out.param = days;
    return out;
  }
  if (minutes % 60 === 0) {
    const hours = minutes / 60;
    if (hours === 1) {
      out.token = AUTO_UPDATE_HOURLY;
      return out;
    }
    out.token = AUTO_UPDATE_EVERY_HOURS;
    out.param = hours;
    return out;
  }
  out.token = AUTO_UPDATE_EVERY_MINUTES;
  out.param = minutes;
  return out;
}

/** 上次更新 token(59s 内算刚刚，随后分钟/小时/天;含时间回拨按刚刚,不显示负数)。 */
function lastUpdatedOf(lastUpdate: number, nowMs: number): TextToken {
  const out = new TextToken();
  out.token = LAST_UPDATED_NEVER;
  if (!(lastUpdate > 0)) {
    return out;
  }
  const diff = nowMs - lastUpdate;
  if (diff < MINUTE_MS) {
    out.token = LAST_UPDATED_JUST_NOW;
    return out;
  }
  if (diff < HOUR_MS) {
    out.token = LAST_UPDATED_MINUTES;
    out.param = Math.floor(diff / MINUTE_MS);
    return out;
  }
  if (diff < DAY_MS) {
    out.token = LAST_UPDATED_HOURS;
    out.param = Math.floor(diff / HOUR_MS);
    return out;
  }
  out.token = LAST_UPDATED_DAYS;
  out.param = Math.floor(diff / DAY_MS);
  return out;
}

/** 到期 token + 参数/日期:<=0 未知；已过期/7 天内相对；更远给 UTC 日期。 */
function expiryOf(expireSeconds: number, nowMs: number): TextToken {
  const out = new TextToken();
  out.token = EXPIRY_TOKEN_UNKNOWN;
  if (!(expireSeconds > 0)) {
    return out;
  }
  const remain = expireSeconds * 1000 - nowMs;
  if (remain < 0) {
    const overdueDays = Math.floor(-remain / DAY_MS);
    if (overdueDays >= 1) {
      out.token = EXPIRY_TOKEN_EXPIRED_DAYS;
      out.param = overdueDays;
    } else {
      out.token = EXPIRY_TOKEN_JUST_EXPIRED;
    }
    return out;
  }
  if (remain < NEAR_EXPIRY_MS) {
    out.token = EXPIRY_TOKEN_IN_DAYS;
    out.param = Math.max(1, Math.ceil(remain / DAY_MS));
    return out;
  }
  out.token = EXPIRY_TOKEN_DATE;
  out.extraText = formatUtcDate(expireSeconds);
  return out;
}

/** 到期状态 token(与文案同源，避免 UI 再算一次)。 */
function expiryStateOf(expireSeconds: number, nowMs: number): string {
  if (!(expireSeconds > 0)) {
    return EXPIRY_NONE;
  }
  if (expireSeconds * 1000 < nowMs) {
    return EXPIRY_EXPIRED;
  }
  if (expireSeconds * 1000 - nowMs < NEAR_EXPIRY_MS) {
    return EXPIRY_NEAR;
  }
  return EXPIRY_NONE;
}

/**
 * 构建列表行。
 * @param updatingUrls 正在更新的订阅 url(可选；页面用 @Prop updatingUrl 转成单元素集合)
 * 状态优先级：updating > failed > expired > never > ok(更新中的行优先表达"正在进行")。
 * 状态文案 = row.state(页面映射 sub_state_<state>,P6/W21 起模型不产用户语言)。
 */
export function buildRows(subs: Array<SubInfo>, nodeCounts: Map<string, number>, nowMs: number,
  updatingUrls: Set<string> = new Set<string>()): Array<SubscriptionRowView> {
  const rows: Array<SubscriptionRowView> = [];
  for (let i = 0; i < subs.length; i++) {
    const sub = subs[i];
    const row = new SubscriptionRowView();
    row.url = sub.url;
    row.name = sub.name.length > 0 ? sub.name : sub.url;
    row.group = sub.group;
    row.nodeCount = nodeCounts.get(sub.url) ?? 0;
    row.lastUpdate = sub.lastUpdate;
    row.expire = sub.expire;
    row.usedBytes = Math.max(0, Number(sub.upload) + Number(sub.download));
    row.totalBytes = Math.max(0, Number(sub.total));
    const lastUpdated = lastUpdatedOf(sub.lastUpdate, nowMs);
    row.lastUpdatedToken = lastUpdated.token;
    row.lastUpdatedParam = lastUpdated.param;
    const autoUpdate = autoUpdateOf(sub);
    row.autoUpdateToken = autoUpdate.token;
    row.autoUpdateParam = autoUpdate.param;
    row.autoUpdateEnabled = sub.autoUpdate;
    row.trafficUsedText = formatTrafficBytes(row.usedBytes);
    row.trafficTotalText = row.totalBytes > 0 ? formatTrafficBytes(row.totalBytes) : '';
    const expiry = expiryOf(sub.expire, nowMs);
    row.expiryToken = expiry.token;
    row.expiryParam = expiry.param;
    row.expiryDateText = expiry.extraText;
    row.expiryState = expiryStateOf(sub.expire, nowMs);
    row.nearExpiry = row.expiryState === EXPIRY_NEAR;
    row.errorText = sub.lastError;
    row.expandableError = sub.lastError.trim().length > 0;
    if (updatingUrls.has(sub.url)) {
      row.state = ROW_STATE_UPDATING;
    } else if (row.expandableError) {
      row.state = ROW_STATE_FAILED;
    } else if (row.expiryState === EXPIRY_EXPIRED) {
      row.state = ROW_STATE_EXPIRED;
    } else if (!(sub.lastUpdate > 0)) {
      row.state = ROW_STATE_NEVER;
    } else {
      row.state = ROW_STATE_OK;
    }
    rows.push(row);
  }
  return rows;
}

/**
 * 批量更新摘要(§11.3 反馈)。
 * 失败有两种来源：① 结果内 note 非空(整体性说明键)；② 调用方 catch 到的异常原文。
 * @param failureMessages 调用方捕获的失败原文(原样保存，不吞错误)
 */
export function summarizeUpdate(results: Array<SubUpdateResult>,
  failureMessages: Array<string> = []): UpdateBatchSummary {
  const summary = new UpdateBatchSummary();
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    if (r.notModified) {
      summary.notModified++;
    } else {
      summary.updated += r.updatedNames.length;
      summary.added += Number(r.added);
      summary.removed += Number(r.removed);
    }
    summary.skipped += Number(r.skipped);
    const note = r.note.trim();
    if (note.length > 0) {
      summary.notes.push(note);
      if (!r.notModified) {
        summary.failed++;
        summary.failedMessages.push(note);
      }
    }
  }
  for (let i = 0; i < failureMessages.length; i++) {
    const msg = failureMessages[i].trim();
    if (msg.length > 0) {
      summary.failed++;
      summary.failedMessages.push(failureMessages[i]);
    }
  }
  return summary;
}

/** 批量摘要反馈行的结构化形态:kind ∈ {updated,added,removed,not_modified,skipped,failed},页面映射 $r。 */
export class SummaryPart {
  kind: string = '';
  value: number = 0;
}

/** 批量摘要 → 结构化反馈行(更新/新增/删除恒显;未变/跳过/失败只在非零时给,与旧拼接口径一致)。 */
export function summaryParts(summary: UpdateBatchSummary): Array<SummaryPart> {
  const out: Array<SummaryPart> = [];
  const add = (kind: string, value: number): void => {
    const p = new SummaryPart();
    p.kind = kind;
    p.value = value;
    out.push(p);
  };
  add('updated', summary.updated);
  add('added', summary.added);
  add('removed', summary.removed);
  if (summary.notModified > 0) {
    add('not_modified', summary.notModified);
  }
  if (summary.skipped > 0) {
    add('skipped', summary.skipped);
  }
  if (summary.failed > 0) {
    add('failed', summary.failed);
  }
  return out;
}

function compareName(a: SubscriptionRowView, b: SubscriptionRowView): number {
  const an = a.name.toLowerCase();
  const bn = b.name.toLowerCase();
  if (an < bn) {
    return -1;
  }
  if (an > bn) {
    return 1;
  }
  if (a.url < b.url) {
    return -1;
  }
  if (a.url > b.url) {
    return 1;
  }
  return 0;
}

/**
 * 排序(返回新数组，不改输入)。
 * 'name'：名称不区分大小写升序(按 UTF-16 码位，跨平台确定性；拼音排序需要 ICU，留给后续)，
 *         名称相同回退 URL；'recent'：lastUpdate 降序(从未更新排最后)，回退名称。
 */
export function sortSubs(rows: Array<SubscriptionRowView>, mode: string): Array<SubscriptionRowView> {
  const out: Array<SubscriptionRowView> = [];
  for (let i = 0; i < rows.length; i++) {
    out.push(rows[i]);
  }
  if (mode === 'recent') {
    out.sort((a: SubscriptionRowView, b: SubscriptionRowView): number => {
      if (a.lastUpdate !== b.lastUpdate) {
        return b.lastUpdate - a.lastUpdate;
      }
      return compareName(a, b);
    });
    return out;
  }
  out.sort((a: SubscriptionRowView, b: SubscriptionRowView): number => compareName(a, b));
  return out;
}

/** 过滤(名称/URL 子串，不区分大小写；空查询返回全量副本)。 */
export function filterSubs(rows: Array<SubscriptionRowView>, query: string): Array<SubscriptionRowView> {
  const q = query.trim().toLowerCase();
  const out: Array<SubscriptionRowView> = [];
  if (q.length === 0) {
    for (let i = 0; i < rows.length; i++) {
      out.push(rows[i]);
    }
    return out;
  }
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    if (row.name.toLowerCase().indexOf(q) >= 0 || row.url.toLowerCase().indexOf(q) >= 0) {
      out.push(row);
    }
  }
  return out;
}

/**
 * 空态引导(§4.5)：有订阅 → token 为空(不渲染空态)；无订阅时区分离线/在线。
 * 主按钮统一为"添加/导入"；次要动作为扫码/从文件/手动。
 */
export function emptyStateFor(subsCount: number, networkAvailable: boolean): EmptyStateView {
  const view = new EmptyStateView();
  if (subsCount > 0) {
    return view;
  }
  view.primaryAction = EMPTY_ACTION_ADD;
  view.secondaryActions = [EMPTY_ACTION_SCAN, EMPTY_ACTION_FROM_FILE, EMPTY_ACTION_MANUAL];
  if (!networkAvailable) {
    view.token = EMPTY_OFFLINE;
    return view;
  }
  view.token = EMPTY_NO_SUBS;
  return view;
}

/**
 * 别名:Index 若同时导入 `model/HomeView.ets` 的 `emptyStateFor(EmptyContext)`(节点首页空态)，
 * 用本名字避免重名(两者签名不同，语义也不同)。
 */
export function emptyStateForSubscriptions(subsCount: number, networkAvailable: boolean): EmptyStateView {
  return emptyStateFor(subsCount, networkAvailable);
}

/**
 * 由"每个节点的 subUrl 列表"生成订阅节点数(含重复 url 的计数)。
 * Index 接线：nodeCountsFromSubUrls(profiles.map((p) => p.subUrl))。
 */
export function nodeCountsFromSubUrls(subUrls: Array<string>): Array<SubscriptionNodeCount> {
  const counts = new Map<string, number>();
  for (let i = 0; i < subUrls.length; i++) {
    const url = subUrls[i];
    if (url.length === 0) {
      continue; // 未归属订阅的节点不计入任何订阅
    }
    counts.set(url, (counts.get(url) ?? 0) + 1);
  }
  const out: Array<SubscriptionNodeCount> = [];
  counts.forEach((count: number, url: string) => {
    const item = new SubscriptionNodeCount();
    item.url = url;
    item.count = count;
    out.push(item);
  });
  return out;
}

/** SubscriptionNodeCount[] → Map(页面内部用；buildRows 的入参形态)。 */
export function nodeCountMap(pairs: Array<SubscriptionNodeCount>): Map<string, number> {
  const map = new Map<string, number>();
  for (let i = 0; i < pairs.length; i++) {
    map.set(pairs[i].url, pairs[i].count);
  }
  return map;
}

// ---------------- P5/W18:逐订阅更新结果 + 导入识别结果 ----------------

/** 「更新全部」里单个订阅的结果行(§11.3:一个失败不覆盖其他结果)。 */
export class PerSubOutcome {
  name: string = '';
  ok: boolean = false;
  notModified: boolean = false;
  added: number = 0;
  updated: number = 0;
  removed: number = 0;
  skipped: number = 0;
  /** 失败原文(ok=false 时非空) */
  error: string = '';
}

/** 逐订阅结果行的结构化形态:kind ∈ {failed,not_modified,changed},页面映射 $r(§11.3)。 */
export class OutcomeLine {
  kind: string = '';
  /** 订阅显示名(资源 %1$s) */
  name: string = '';
  /** changed 行的 +N ~N -N 变更串(数字与符号,不本地化) */
  changesText: string = '';
  /** skipped>0 时给 sub_summary_skipped 的参数,0=不显示 */
  skipped: number = 0;
  /** 失败原文(kind=failed 时,资源 %2$s,原样不吞) */
  error: string = '';
}

/** 逐订阅结果 -> 结构化行(成功失败交错按发生顺序;页面逐行映射 $r)。 */
export function outcomeLines(outcomes: Array<PerSubOutcome>): Array<OutcomeLine> {
  const lines: Array<OutcomeLine> = [];
  for (let i = 0; i < outcomes.length; i++) {
    const o = outcomes[i];
    const line = new OutcomeLine();
    line.name = o.name;
    if (!o.ok) {
      line.kind = 'failed';
      line.error = o.error;
      lines.push(line);
      continue;
    }
    if (o.notModified) {
      line.kind = 'not_modified';
      lines.push(line);
      continue;
    }
    line.kind = 'changed';
    line.changesText = `+${o.added} ~${o.updated} -${o.removed}`;
    line.skipped = o.skipped;
    lines.push(line);
  }
  return lines;
}

/** 导入识别结果(§11.2:解析后展示将导入的节点/组数量、跳过数量与类型)。 */
export class ImportRecognitionView {
  /** 将导入的节点数 */
  nodeCount: number = 0;
  /** 将导入的分组数(Clash proxy-groups;分享链接导入为 0) */
  groupCount: number = 0;
  /** 解析成功但跳过的节点数 */
  skipped: number = 0;
  /** 跳过项的名称/类型样例(最多 3 个,原样展示) */
  skippedSamples: Array<string> = [];
  /** 无有效节点(不提交为空订阅覆盖旧数据) */
  empty: boolean = false;
}

export function buildImportRecognition(nodeCount: number, groupCount: number, skipped: number,
  skippedNames: Array<string>): ImportRecognitionView {
  const view = new ImportRecognitionView();
  view.nodeCount = Math.max(0, nodeCount);
  view.groupCount = Math.max(0, groupCount);
  view.skipped = Math.max(0, skipped);
  const samples: Array<string> = [];
  const sampleCap = Math.min(3, view.skipped);
  for (let i = 0; i < skippedNames.length && samples.length < sampleCap; i++) {
    const n = skippedNames[i].trim();
    if (n.length > 0) {
      samples.push(n);
    }
  }
  view.skippedSamples = samples;
  view.empty = view.nodeCount === 0;
  return view;
}

/** 导入识别的结构化反馈行:kind ∈ {none,nodes,groups,skipped},页面映射 $r(§11.2)。 */
export function importParts(view: ImportRecognitionView): Array<SummaryPart> {
  const out: Array<SummaryPart> = [];
  if (view.empty) {
    const p = new SummaryPart();
    p.kind = 'none';
    out.push(p);
    return out;
  }
  const add = (kind: string, value: number): void => {
    const p = new SummaryPart();
    p.kind = kind;
    p.value = value;
    out.push(p);
  };
  add('nodes', view.nodeCount);
  if (view.groupCount > 0) {
    add('groups', view.groupCount);
  }
  if (view.skipped > 0) {
    add('skipped', view.skipped);
  }
  return out;
}
