import common from '@ohos.app.ability.common';
import connection from '@ohos.net.connection';
import { Profile, ProfileGroup, ProfileType } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, mutateProfiles, loadGroups, saveGroups, ensureGroupByName, readPrefString, writePrefString, LogStore } from '../model/Store';
import { parseSubUserInfo, looksLikeClashYaml, looksLikeSingBoxJson, parseSingBoxConfig, subFailureText, subFailureBaseText, dedupKeyOf, isIpLiteral, ClashParseResult } from '../utils/Subscription';
import { parseClashProxiesWithProviders, ClashGroupDef } from '../utils/ClashProviders';
import { parseShareText, ShareSkipReport } from '../utils/LinkParser';
import { SubscriptionRepository } from './SubscriptionRepository';

// 解析失败文案定义在 utils/Subscription.ets(与 note 常量同处,供手动导入路径复用);
// 从这里再导出一次,保持既有 import 点不变。
export { subFailureText, subFailureBaseText };

/** 订阅管理:记录订阅来源、更新节点(按 subUrl 原子替换)。 */

const KEY_SUBS = 'subscriptions';
/** Android SubscriptionBean.autoUpdateDelay 默认 1440(分钟 = 24h,SubscriptionBean.java:114) */
const DEFAULT_INTERVAL_MINUTES = 1440;
/** Android SubscriptionUpdater.kt:36 的下限钳制,无上限(W17 起订阅事务也用) */
export const MIN_INTERVAL_MINUTES = 15;
const AUTO_UPDATE_INTERVAL = 12 * 3600 * 1000; // 12h

/** 间隔归一化:非正数/非法 → 默认 1440;低于 15 分钟抬到 15(与 Android 一致,不设上限)。 */
function normalizeIntervalMinutes(raw: number): number {
  if (isNaN(raw) || !(raw > 0)) {
    return DEFAULT_INTERVAL_MINUTES;
  }
  const m = Math.floor(raw);
  return m < MIN_INTERVAL_MINUTES ? MIN_INTERVAL_MINUTES : m;
}

export class SubInfo {
  url: string = '';
  name: string = '';
  group: string = '';
  lastUpdate: number = 0;
  upload: number = 0;
  download: number = 0;
  total: number = 0;
  expire: number = 0;
  // 自动更新间隔 — 逐字对齐 Android SubscriptionBean.autoUpdateDelay:
  // 单位**分钟**、默认 **1440**(24h,group_preferences.xml default 1440;
  // SubscriptionUpdater.kt:43 以 TimeUnit.MINUTES 使用)。下限 15
  // (SubscriptionUpdater.kt:36 `if (minDelay < 15) minDelay = 15`),无上限。
  updateIntervalMinutes: number = 1440;
  // 旧版字段(小时粒度)只用于备份/升级兼容:listSubs 读不到分钟值时按 *60 迁移,
  // saveSubs 时同步写回,使旧备份仍可还原。
  updateIntervalHours: number = 24;
  nextUpdateAt: number = 0;
  lastAttemptAt: number = 0;
  lastError: string = '';
  // 连续更新失败次数(成功一次即清零);≥3 次跳过自动更新,由手动更新复位
  failCount: number = 0;
  // 订阅级设置(对齐安卓 group_preferences.xml)
  userAgent: string = '';                    // 自定义 User-Agent,空 = 默认
  // Android SubscriptionBean.autoUpdate 默认 **false**(SubscriptionBean.java:113)
  autoUpdate: boolean = false;               // 本订阅是否参与自动更新
  updateWhenConnectedOnly: boolean = false;  // 仅 VPN 已连接时自动更新
  deduplication: boolean = false;            // 更新时去重(对齐安卓 subscriptionDeduplication,默认关闭)
  forceResolve: boolean = false;             // 更新时把节点服务器域名解析为 IP(对齐安卓 subscriptionForceResolve)
  // 节点名过滤(对齐 OwnBox SubscriptionFilterMode + filterRegex,RawUpdater.kt:199-212)
  filterMode: string = 'off';                // off / include / exclude
  filterRegex: string = '';                  // 关键词或正则(忽略大小写;非法正则视为未启用)
  // 远端已删除但仍在用/测速可用/有流量的节点继续保留(对齐 OwnBox retainValidNodes)
  retainValidNodes: boolean = false;
  // HTTP 条件请求校验器:下次更新带上,服务端回 304 即跳过正文下载
  etag: string = '';
  lastModified: string = '';
}

export interface SubUpdateResult {
  added: number;
  removed: number;
  total: number;
  // 服务端回 304:节点未变,只推进了更新时刻
  notModified: boolean;
  // 解析成功但被跳过的节点数(内核不支持的类型等)与其中前若干个名称
  skipped: number;
  skippedNames: Array<string>;
  // 整体性说明键(非空表示订阅不可用或需提示),见 Subscription.ets 的 note 取值
  note: string;
  // ---- 对齐 Android GroupManager.Interface.onUpdateSuccess 的五个参数 ----
  // changed = deleted.size + added + updated(RawUpdater.kt:159,168,190)
  changed: number;
  addedNames: Array<string>;
  // name -> name(Android 里 key==value,UI 只在不等时打印 "old => new")
  updatedNames: Array<string>;
  deletedNames: Array<string>;
  duplicateNames: Array<string>;
}

export async function listSubs(): Promise<Array<SubInfo>> {
  try {
    const raw = await readPrefString(KEY_SUBS, '[]');
    const parsed = JSON.parse(raw) as Array<SubInfo>;
    const result: Array<SubInfo> = [];
    for (const source of parsed) {
      const item = new SubInfo();
      item.url = source.url ?? '';
      item.name = source.name ?? subNameOf(item.url);
      item.group = source.group ?? '';
      item.lastUpdate = Number(source.lastUpdate) || 0;
      item.upload = Number(source.upload) || 0;
      item.download = Number(source.download) || 0;
      item.total = Number(source.total) || 0;
      item.expire = Number(source.expire) || 0;
      // 间隔迁移:优先读分钟值;只有旧数据(小时)时 *60。
      const rawMinutes = Number(source.updateIntervalMinutes);
      let minutes = rawMinutes > 0 ? Math.floor(rawMinutes) : 0;
      if (minutes <= 0) {
        const legacyHours = Number(source.updateIntervalHours);
        if (legacyHours > 0) {
          minutes = Math.floor(legacyHours) * 60;
        }
      }
      item.updateIntervalMinutes = minutes > 0 ? minutes : DEFAULT_INTERVAL_MINUTES;
      item.updateIntervalHours = Math.round(item.updateIntervalMinutes / 60);
      item.nextUpdateAt = Number(source.nextUpdateAt)
        || item.lastUpdate + item.updateIntervalMinutes * 60 * 1000;
      item.lastAttemptAt = Number(source.lastAttemptAt) || 0;
      item.lastError = source.lastError ?? '';
      item.failCount = Number(source.failCount) || 0;
      item.userAgent = source.userAgent ?? '';
      item.autoUpdate = source.autoUpdate === true;
      item.updateWhenConnectedOnly = source.updateWhenConnectedOnly === true;
      item.deduplication = source.deduplication === true;
      item.forceResolve = source.forceResolve === true;
      const rawFilterMode: string = source.filterMode ?? 'off';
      item.filterMode = (rawFilterMode === 'include' || rawFilterMode === 'exclude') ? rawFilterMode : 'off';
      item.filterRegex = source.filterRegex ?? '';
      item.retainValidNodes = source.retainValidNodes === true;
      item.etag = source.etag ?? '';
      item.lastModified = source.lastModified ?? '';
      result.push(item);
    }
    return result;
  } catch (e) {
    return [];
  }
}

export async function saveSubs(list: Array<SubInfo>): Promise<void> {
  await writePrefString(KEY_SUBS, JSON.stringify(list));
}

export function subNameOf(url: string): string {
  let s = url;
  const scheme = s.indexOf('://');
  if (scheme >= 0) {
    s = s.substring(scheme + 3);
  }
  const path = s.indexOf('/');
  if (path >= 0) {
    s = s.substring(0, path);
  }
  return s;
}

export async function upsertSub(url: string, userinfo: string = '', requestedName: string = ''): Promise<void> {
  const list = await listSubs();
  const target = list.find(x => x.url === url);
  const normalizedName = requestedName.trim();
  if (target === undefined) {
    const info = new SubInfo();
    info.url = url;
    info.name = normalizedName.length > 0 ? normalizedName : subNameOf(url);
    info.group = normalizedName;
    info.lastUpdate = Date.now();
    if (userinfo.length > 0) {
      const parsed = parseSubUserInfo(userinfo);
      if (parsed !== null) {
        info.upload = parsed.upload;
        info.download = parsed.download;
        info.total = parsed.total;
        info.expire = parsed.expire;
      }
    }
    list.push(info);
  } else {
    if (normalizedName.length > 0) {
      target.name = normalizedName;
      target.group = normalizedName;
    }
    // 手动(重新)导入一律清掉校验器。带 ETag/Last-Modified 去请求,若机场侧
    // 对该 URL 回 304,就会走"内容未变更"分支拿到空正文 → 导入 0 个节点。
    // 用户主动点导入的语义是"我要全量重新拉一次"。
    target.etag = '';
    target.lastModified = '';
    if (userinfo.length > 0) {
      const parsed = parseSubUserInfo(userinfo);
      if (parsed !== null) {
        target.upload = parsed.upload;
        target.download = parsed.download;
        target.total = parsed.total;
        target.expire = parsed.expire;
      }
    }
  }
  await saveSubs(list);
}

export async function removeSub(url: string): Promise<void> {
  const list = await listSubs();
  await saveSubs(list.filter(x => x.url !== url));
}

/** W17:订阅事务(SubscriptionRepository)惰性初始化原始层存储用。 */
export function appContextOrNull(): common.Context | null {
  return appContext;
}

export async function needAutoUpdate(): Promise<Array<SubInfo>> {
  const subs = await listSubs();
  if (subs.length === 0) {
    return [];
  }
  const now = Date.now();
  // 仅连接时更新:VPN 未运行时跳过(对齐安卓 subscriptionUpdateWhenConnectedOnly)
  const connected: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
  // 连续失败 ≥3 次的订阅跳过自动更新(手动更新成功后由 markSubSuccess 清零恢复)
  return subs.filter(s => s.autoUpdate
    && !(s.updateWhenConnectedOnly && !connected)
    && now >= (s.nextUpdateAt || s.lastUpdate + Math.max(MIN_INTERVAL_MINUTES, s.updateIntervalMinutes) * 60 * 1000)
    && !(Number(s.failCount) >= 3));
}

/** 保存订阅级设置(对齐安卓 GroupSettingsActivity 的订阅分类) */
export async function saveSubSettings(url: string, changes: Record<string, Object>): Promise<SubInfo | null> {
  const list = await listSubs();
  let target: SubInfo | null = null;
  for (const s of list) {
    if (s.url !== url) {
      continue;
    }
    target = s;
    if (changes['name'] !== undefined) {
      s.name = `${changes['name']}`;
    }
    if (changes['group'] !== undefined) {
      s.group = `${changes['group']}`;
    }
    if (changes['userAgent'] !== undefined) {
      s.userAgent = `${changes['userAgent']}`;
    }
    if (changes['autoUpdate'] !== undefined) {
      s.autoUpdate = changes['autoUpdate'] === true;
    }
    if (changes['updateWhenConnectedOnly'] !== undefined) {
      s.updateWhenConnectedOnly = changes['updateWhenConnectedOnly'] === true;
    }
    if (changes['deduplication'] !== undefined) {
      s.deduplication = changes['deduplication'] === true;
    }
    if (changes['forceResolve'] !== undefined) {
      s.forceResolve = changes['forceResolve'] === true;
    }
    if (changes['filterMode'] !== undefined) {
      const mode: string = `${changes['filterMode']}`;
      s.filterMode = (mode === 'include' || mode === 'exclude') ? mode : 'off';
    }
    if (changes['filterRegex'] !== undefined) {
      s.filterRegex = `${changes['filterRegex']}`;
    }
    if (changes['retainValidNodes'] !== undefined) {
      s.retainValidNodes = changes['retainValidNodes'] === true;
    }
    if (changes['updateIntervalMinutes'] !== undefined) {
      s.updateIntervalMinutes = normalizeIntervalMinutes(Number(changes['updateIntervalMinutes']));
      s.updateIntervalHours = Math.round(s.updateIntervalMinutes / 60);
    } else if (changes['updateIntervalHours'] !== undefined) {
      // 旧调用点(小时):按 *60 迁移
      s.updateIntervalMinutes = normalizeIntervalMinutes(Number(changes['updateIntervalHours']) * 60);
      s.updateIntervalHours = Math.round(s.updateIntervalMinutes / 60);
    }
  }
  if (target !== null) {
    await saveSubs(list);
  }
  return target;
}

/** 记录订阅更新成功:失败计数清零,恢复自动更新资格 */
export async function markSubSuccess(url: string): Promise<void> {
  const list = await listSubs();
  let changed = false;
  for (const s of list) {
    if (s.url === url && Number(s.failCount) !== 0) {
      s.failCount = 0;
      changed = true;
    }
  }
  if (changed) {
    await saveSubs(list);
  }
}

/** 记录订阅更新失败:失败计数 +1(由调用方在 catch 中调用) */
export async function markSubFailure(url: string): Promise<void> {
  const list = await listSubs();
  for (const s of list) {
    if (s.url === url) {
      const cur = Number(s.failCount);
      s.failCount = (isNaN(cur) ? 0 : cur) + 1;
    }
  }
  await saveSubs(list);
}

function profileIdentity(p: Profile, url: string): string {
  return [url, p.type, p.server, `${p.serverPort}`, p.uuid, p.name, p.transport,
    p.path, p.host, p.serviceName, p.sni].join('\u001f');
}

export function stableProfileId(p: Profile, url: string): string {
  const value = profileIdentity(p, url);
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return `sub_${(hash >>> 0).toString(16)}`;
}

/**
 * 单个节点强制解析 + 地址改写 — 逐字对齐 Android `GroupUpdater.rewriteAddress`(:92-120):
 *  - 选中地址后**总是**把 serverAddress 换成 IP(所有类型都换);
 *  - SNI 回填按 bean 类型分支:Http 仅 isTLS() 时、V2Ray(vmess/vless)仅 security=="tls" 时、
 *    Trojan/TrojanGo/Hysteria 无条件;Tuic/AnyTLS/SOCKS/SSH 等**不回填**;
 *  - 失败只写日志、保留域名(GroupUpdater.kt:78-80)。
 */
async function resolveOneProfile(p: Profile, ipv6First: boolean): Promise<void> {
  const host = p.server.trim();
  if (host.length === 0 || isIpLiteral(host)) {
    return;
  }
  try {
    const addrs = await connection.getAddressesByName(host);
    const v4: Array<string> = [];
    const v6: Array<string> = [];
    for (const a of addrs) {
      const addr = a.address;
      if (addr.indexOf(':') < 0) {
        v4.push(addr);
      } else {
        v6.push(addr);
      }
    }
    applyRewriteAddress(p, v4.concat(v6), ipv6First);
  } catch (e) {
    LogStore.addLog(`[sub] 强制解析 ${host} 失败,保留域名: ${e}`);
  }
}

/**
 * 地址改写(纯函数,便于测试)— Android `GroupUpdater.rewriteAddress`(:92-120):
 * `addresses.sortedBy { (it is Inet4Address) xor ipv6First }[0].hostAddress`,
 * SNI 回填按类型(Http 仅 isTLS、V2Ray 仅 security=="tls"、Trojan/TrojanGo/Hysteria
 * 无条件、其余不回填),最后 serverAddress = address。
 */
export function applyRewriteAddress(p: Profile, addresses: Array<string>, ipv6First: boolean): void {
  if (addresses.length === 0) {
    return;
  }
  const v4: Array<string> = [];
  const v6: Array<string> = [];
  for (const a of addresses) {
    if (a.indexOf(':') < 0) {
      v4.push(a);
    } else {
      v6.push(a);
    }
  }
  // Android: sortedBy { (it is Inet4Address) xor ipv6First }[0]
  //  - ipv6First=false → v4 优先;true → v6 优先;选不到时保留原域名。
  let chosen = '';
  if (ipv6First) {
    chosen = v6.length > 0 ? v6[0] : (v4.length > 0 ? v4[0] : '');
  } else {
    chosen = v4.length > 0 ? v4[0] : (v6.length > 0 ? v6[0] : '');
  }
  if (chosen.length === 0) {
    return;
  }
  if (p.sni.trim().length === 0) {
    if (p.type === ProfileType.HTTP) {
      if (p.tls) {
        p.sni = p.server;
      }
    } else if (p.type === ProfileType.VMESS || p.type === ProfileType.VLESS) {
      // Android: security == "tls" 才回填(鸿蒙以 tls 布尔承载同一语义)
      if (p.tls) {
        p.sni = p.server;
      }
    } else if (p.type === ProfileType.TROJAN
      || p.type === ProfileType.HYSTERIA || p.type === ProfileType.HYSTERIA2) {
      p.sni = p.server;
    }
  }
  p.server = chosen;
}

/** 批量强制解析 — Android 用 5 线程 fixed pool(GroupUpdater.kt:43),这里用 5 并发分批等价。 */
export async function applyForceResolve(list: Array<Profile>, ipv6First: boolean): Promise<void> {
  const BATCH = 5;
  for (let i = 0; i < list.length; i += BATCH) {
    const batch = list.slice(i, i + BATCH);
    await Promise.all(batch.map((p: Profile): Promise<void> => resolveOneProfile(p, ipv6First)));
  }
}

/** 逐字对齐 Android RawUpdater.kt:90-103 的重名改名算法(纯函数,便于测试)。 */
export function renameCollisions(list: Array<Profile>): void {
  const usedNames = new Set<string>();
  for (const p of list) {
    let name = p.name;
    let idx = 0;
    while (usedNames.has(name)) {
      idx++;
      name = name.split(` (${idx - 1})`).join('');
      name = `${name} (${idx})`;
      p.name = name;
    }
    usedNames.add(p.name);
  }
}

interface DedupOutcome {
  profiles: Array<Profile>;
  duplicates: Array<string>;
}

/**
 * 去重 — 逐字对齐 Android RawUpdater.doUpdate:109-131 + Protocols.kt:20-39:
 *  - `LinkedHashSet<Deduplication>`:每个键**保留首次出现**、顺序即首次出现顺序;
 *  - 重复项按 `首次出现的名字去旧后缀 + " ($index)"` 记入 duplicate,
 *    同一键的原始名只记一次(`uniqueNames[proxy]=""` 之后不再记),
 *    随后再记重复项自身的 `displayName + " ($index)"`;
 *  - `retainAll(uniqueNames.keys)` 恒为 no-op(每个键都写入过 value)。
 */
export function dedupProfiles(list: Array<Profile>): DedupOutcome {
  const order: Array<Profile> = [];
  const names = new Map<string, string>();
  const keys: Array<string> = [];
  const duplicates: Array<string> = [];
  for (const proxy of list) {
    const key = dedupKeyOf(proxy);
    if (keys.indexOf(key) < 0) {
      keys.push(key);
      order.push(proxy);
      names.set(key, proxy.name);
      continue;
    }
    const index = keys.indexOf(key);
    const firstName = names.get(key) !== undefined ? names.get(key) as string : '';
    if (firstName.length > 0) {
      const base = firstName.split(` (${index})`).join('');
      if (base.length > 0) {
        duplicates.push(`${base} (${index})`);
        names.set(key, '');
      }
    }
    duplicates.push(`${proxy.name} (${index})`);
  }
  const outcome: DedupOutcome = { profiles: order, duplicates: duplicates };
  return outcome;
}

/**
 * Diff 正文的四段 — 对齐 Android `GroupInterfaceAdapter.kt:47-68`:
 *  - 每段正文 = 段内 `\n` join(段头与段间空行由 UI 的文案键与组件排版提供);
 *  - Updated 段:key 与 value 不同时打 `"old => new"`,相同时只打 key
 *    (RawUpdater 里 key 恒等于 value,所以现实中恒只打一次);
 *  - 空段正文为空串,UI 据此整段省略(「空段省略」)。
 */
export interface SubDiffBodies {
  added: string;
  updated: string;
  deleted: string;
  duplicate: string;
}

export function subUpdateDiffBodies(addedNames: Array<string>, updatedNames: Array<string>,
  deletedNames: Array<string>, duplicateNames: Array<string>): SubDiffBodies {
  const bodies: SubDiffBodies = {
    added: addedNames.join('\n'),
    updated: updatedNames.join('\n'),
    deleted: deletedNames.join('\n'),
    duplicate: duplicateNames.join('\n')
  };
  return bodies;
}

/**
 * 完整 Diff 正文(Android 字面英文段头,段间空行,末尾 trim)。
 * 用于日志与测试;界面用四个文案键 + `subUpdateDiffBodies` 分段渲染,
 * 避免把英文段头硬编码进 UI。
 */
export function subUpdateFeedbackText(res: SubUpdateResult): string {
  const bodies = subUpdateDiffBodies(res.addedNames, res.updatedNames, res.deletedNames, res.duplicateNames);
  const lines: Array<string> = [];
  lines.push(`Added:\n${bodies.added}\n\n`);
  lines.push(`Updated:\n${bodies.updated}\n\n`);
  lines.push(`Deleted:\n${bodies.deleted}\n\n`);
  lines.push(`Duplicate:\n${bodies.duplicate}\n\n`);
  return lines.join('').trim();
}

/**
 * 手动更新前的直连确认 — 逐字对齐 Android `GroupUpdater.kt:142-148`:
 * `byUser && (url.startsWith("http://") || subscription.updateWhenConnectedOnly) && !connected`
 * 时先弹确认框,取消则整次不更新。`byUser` 由调用方保证(只有手动更新才调用本函数)。
 */
export function needDirectUpdateConfirm(url: string, sub: SubInfo | null, connected: boolean): boolean {
  if (connected) {
    return false;
  }
  if (url.startsWith('http://')) {
    return true;
  }
  return sub !== null && sub.updateWhenConnectedOnly === true;
}

/**
 * 更新结果的提示种类 — 对齐 `GroupInterfaceAdapter.kt:38-45`:
 * `changed == 0 && duplicate 为空` → 「没有变化」;否则「已更新 N 个代理」。
 */
export function subUpdateHasChanges(res: SubUpdateResult): boolean {
  return res.changed !== 0 || res.duplicateNames.length > 0;
}

/**
 * 更新单个订阅 —— W17 起委托 `SubscriptionRepository.runUpdate`(三层模型事务:
 * 锁外下载解析、提交前基线 revision 比对、304 只推进成功检查时间、身份键合并保留
 * 用户覆盖)。本函数保留原签名,所有既有调用点不变。
 */
export async function updateSubscription(url: string): Promise<SubUpdateResult> {
  // 必须最先 initStore:listSubs/saveSubs 依赖 preferences,未初始化时
  // listSubs 会吞掉异常并返回空数组,导致 ETag 校验器永远存不下去。
  await initStore(globalContext());
  return await SubscriptionRepository.runUpdate(url);
}

/**
 * 把 Clash proxy-groups 落成 ProfileGroup,并把成员节点迁入对应分组。
 *
 * 语义映射(对齐 model/ProfileGroup 的既有字段):
 *   Clash select / selector -> isSelector = true(用户手动选)
 *   Clash url-test          -> autoSelect   = true(内核按 testUrl 自动选)
 *
 * 保守策略:只处理「本订阅节点 + 至少一个成员能按名字匹配上」的组。
 * 成员名匹配不到节点的组(引用了别的订阅或 provider 内部名)直接跳过,
 * 宁可少建组,也不要造出空组或把节点错误地搬走。
 */
/**
 * 给订阅导入创建/占用的分组打 fromSubscription 标记。
 * 已存在的组(老版本导入、没打过标记)在下次订阅更新走到这里时也会补上 —— 分组页的旧子分组随之消失。
 */
export async function markGroupFromSubscription(groupId: string): Promise<void> {
  if (groupId.length === 0) {
    return;
  }
  const groups = await loadGroups();
  const target = groups.find(g => g.id === groupId);
  if (target !== undefined && !target.fromSubscription) {
    target.fromSubscription = true;
    target.updatedAt = Date.now();
    await saveGroups(groups);
  }
}

/** 给分组打订阅归属标记(订阅主分组也会走这里) */
export async function markGroupSubUrl(groupId: string, subUrl: string): Promise<void> {
  if (groupId.length === 0 || subUrl.length === 0) {
    return;
  }
  const groups = await loadGroups();
  const target = groups.find(g => g.id === groupId);
  if (target === undefined || target.subUrl === subUrl) {
    return;
  }
  target.subUrl = subUrl;
  target.updatedAt = Date.now();
  await saveGroups(groups);
}

/** 订阅导入时要落到一个分组上的属性变更 */
interface GroupFlagChange {
  isSelector: boolean;
  autoSelect: boolean;
  subUrl: string;
  updatedAt: number;
}

export async function applyClashGroups(groups: Array<ClashGroupDef>, allProfiles: Array<Profile>,
  subUrl: string = ''): Promise<void> {
  if (groups.length === 0) {
    return;
  }
  /* ── 成员解析:Clash 的 proxy-groups 允许「组引用组」 ──────────────────────
     一个组里既可能有节点名,也可能有另一个组的名字(如「🔰 选择节点」里放的是
     「自动选择」「香港节点」)。以前只按节点名匹配,引用型成员全部落空,
     这类组装出来没有成员 → 首页分组条(只显示有节点的组)里就只剩「自动选择」。
     这里递归展开成叶子节点名(带环检测 + 深度上限)。 */
  const defByName = new Map<string, ClashGroupDef>();
  for (const def of groups) {
    defByName.set(def.name, def);
  }
  const resolveLeafNames = (groupName: string, seen: Array<string>, depth: number): Array<string> => {
    const out: Array<string> = [];
    const def = defByName.get(groupName);
    if (def === undefined || depth > 6 || seen.indexOf(groupName) >= 0) {
      return out;
    }
    const nextSeen: Array<string> = seen.concat([groupName]);
    for (const member of def.members) {
      if (defByName.has(member)) {
        for (const leaf of resolveLeafNames(member, nextSeen, depth + 1)) {
          out.push(leaf);
        }
      } else {
        out.push(member);
      }
    }
    return out;
  };

  /* ── 只认本订阅的节点 ────────────────────────────────────────────────
     以前按名字在**全部**节点里找,多订阅同名节点会被互相抢走:吹雪云的组里混进
     NexPanel 的节点,导致「只看一个订阅」也漏出别的订阅。 */
  const scoped: Array<Profile> = subUrl.length > 0
    ? allProfiles.filter((p: Profile) => p.subUrl === subUrl)
    : allProfiles;
  const byName = new Map<string, Profile>();
  for (const p of scoped) {
    if (!byName.has(p.name)) {
      byName.set(p.name, p);
    }
  }

  const groupsNow: Array<ProfileGroup> = await loadGroups();
  /** 待写回的分组属性(组对象可能来自不同批次的 loadGroups,统一收在表里再落盘) */
  const pending: Map<string, GroupFlagChange> = new Map<string, GroupFlagChange>();
  /** 节点 → 本次解析出的组 id 列表(多重归属,顺序 = 配置里的组顺序) */
  const membership = new Map<string, Array<string>>();

  for (const def of groups) {
    const leafNames: Array<string> = resolveLeafNames(def.name, [], 0);
    const memberIds: Array<string> = [];
    for (const name of leafNames) {
      const hit = byName.get(name);
      if (hit !== undefined && memberIds.indexOf(hit.id) < 0) {
        memberIds.push(hit.id);
      }
    }
    if (memberIds.length === 0) {
      continue; // 一个真节点都没有的组不建(避免全空组刷屏)
    }
    const groupId: string = await ensureGroupByName(def.name);
    if (groupId.length === 0) {
      continue;
    }
    await markGroupFromSubscription(groupId);
    /* 组类型 → ProfileGroup 的两个互斥开关:
       url-test/urltest 交给内核自动选;其它(select/fallback/load-balance/relay/未知)
       一律当手动组 —— 语义落不下的组至少成员可见、可手动选,不会消失。 */
    const isUrlTest: boolean = def.type === 'url-test' || def.type === 'urltest';
    pending.set(groupId, {
      isSelector: !isUrlTest,
      autoSelect: isUrlTest,
      subUrl: subUrl,
      updatedAt: Date.now()
    });
    for (const id of memberIds) {
      const list: Array<string> = membership.get(id) ?? [];
      if (list.indexOf(groupId) < 0) {
        list.push(groupId);
      }
      membership.set(id, list);
    }
  }

  if (pending.size > 0) {
    const latest: Array<ProfileGroup> = await loadGroups();
    let groupsChanged = false;
    for (const g of latest) {
      const change: GroupFlagChange | undefined = pending.get(g.id);
      if (change === undefined) {
        continue;
      }
      if (g.isSelector !== change.isSelector || g.autoSelect !== change.autoSelect) {
        g.isSelector = change.isSelector;
        g.autoSelect = change.autoSelect;
        groupsChanged = true;
      }
      if (change.subUrl.length > 0 && g.subUrl !== change.subUrl) {
        g.subUrl = change.subUrl;
        groupsChanged = true;
      }
      if (groupsChanged) {
        g.updatedAt = change.updatedAt;
      }
    }
    if (groupsChanged) {
      await saveGroups(latest);
    }
  }

  /* ── 写回多重归属 ──────────────────────────────────────────────────
     groupId 仍是唯一主分组(内核配置只认它):现有主分组若仍在新集合里就保留,
     否则取配置里的第一个组。subGroupIds 决定首页分组条里每个组显示哪些节点。 */
  let profilesChanged = false;
  for (const p of scoped) {
    const ids: Array<string> = membership.get(p.id) ?? [];
    if (ids.length === 0) {
      continue;
    }
    const sameLength: boolean = ids.length === p.subGroupIds.length
      && ids.every((id: string, i: number) => p.subGroupIds[i] === id);
    if (!sameLength) {
      p.subGroupIds = ids.slice();
      profilesChanged = true;
    }
    if (ids.indexOf(p.groupId) < 0) {
      p.groupId = ids[0];
      profilesChanged = true;
    }
  }
  if (profilesChanged) {
    await saveProfiles(allProfiles);
  }
}

/**
 * 按内容形态分派解析:Clash YAML(跟进 proxy-providers)/ sing-box JSON / 分享链接。
 * 抽成函数是为了让主流程的「首次解析」与「UA 回退重试」走完全相同的判定逻辑。
 */
export async function parseSubscriptionBody(content: string, allowInsecure: boolean,
  userAgent: string): Promise<ClashParseResult> {
  if (looksLikeClashYaml(content)) {
    // 跟进 proxy-providers 远程节点集(provider-only 的 Clash 订阅靠这条路径出节点)
    return await parseClashProxiesWithProviders(content, allowInsecure, userAgent);
  }
  if (looksLikeSingBoxJson(content)) {
    return parseSingBoxConfig(content);
  }
  // 裸 JSON 形态兜底(顶层数组 / 裸 ss / 裸 hysteria1 / server+server_port):
  // looksLikeSingBoxJson 只认 outbounds/endpoints 结构,Android RawUpdater.parseJSON
  // 对这些形态都能出节点,这里在分享链接分支之前先试一次,解析出节点即采用。
  const t = content.trim();
  if (t.startsWith('{') || t.startsWith('[')) {
    const bare = parseSingBoxConfig(content);
    if (bare.profiles.length > 0) {
      return bare;
    }
  }
  // 分享链接分支:上报跳过项,否则「整份订阅都是 ssr://」这类情况
  // 只会显示笼统的「没有可用节点」,用户无从判断原因。
  const report: ShareSkipReport = { skipped: 0, names: [] };
  const profiles = parseShareText(content, report);
  return { profiles, skipped: report.skipped, skippedNames: report.names, note: '' };
}

/** 把 Clash 的 dialer-proxy / sing-box detour 的"名称引用"解析成节点 id。 */
export function resolveDialerProxies(parsed: Array<Profile>, kept: Array<Profile>): void {
  for (const p of parsed) {
    if (p.dialerProxyName.trim().length === 0) {
      continue;
    }
    const target = kept.find(x => x.name === p.dialerProxyName);
    if (target === undefined) {
      // 名称对不上(通常是节点被过滤或改名):不写 id,节点按普通节点使用,
      // 免得配置生成阶段抛错导致整组连不上。
      LogStore.addLog(`[sub] 前置代理 "${p.dialerProxyName}" 未找到,节点 ${p.name} 按无前置处理`);
      p.dialerProxyName = '';
      continue;
    }
    if (target.id === p.id) {
      p.dialerProxyName = '';
      continue;
    }
    p.dialerProxyId = target.id;
  }
}

export async function applySubUserInfo(url: string, userinfo: string): Promise<void> {
  const info = parseSubUserInfo(userinfo);
  if (info === null) {
    return;
  }
  const subs = await listSubs();
  let changed = false;
  for (const s of subs) {
    if (s.url === url) {
      s.upload = info.upload;
      s.download = info.download;
      s.total = info.total;
      s.expire = info.expire;
      changed = true;
    }
  }
  if (changed) {
    await saveSubs(subs);
  }
}


// 简单的上下文注入(由 Index 在启动时设置,供 updateSubscription 内部 initStore 使用)
let appContext: common.Context | null = null;

export function setAppContext(ctx: common.Context): void {
  appContext = ctx;
}

function globalContext(): common.Context {
  if (appContext === null) {
    throw new Error('app context not initialized');
  }
  return appContext;
}
