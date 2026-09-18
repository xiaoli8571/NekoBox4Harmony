import common from '@ohos.app.ability.common';
import connection from '@ohos.net.connection';
import { Profile } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, mutateProfiles, loadSettings, readPrefString, writePrefString, ensureGroupByName, LogStore } from '../model/Store';
import { fetchSubscriptionWithInfo, parseSubUserInfo, looksLikeClashYaml, parseClashProxies, looksLikeSingBoxJson, parseSingBoxConfig } from '../utils/Subscription';
import { parseShareText } from '../utils/LinkParser';

/** 订阅管理:记录订阅来源、更新节点(按 subUrl 原子替换)。 */

const KEY_SUBS = 'subscriptions';
const AUTO_UPDATE_INTERVAL = 12 * 3600 * 1000; // 12h

export class SubInfo {
  url: string = '';
  name: string = '';
  group: string = '';
  lastUpdate: number = 0;
  upload: number = 0;
  download: number = 0;
  total: number = 0;
  expire: number = 0;
  updateIntervalHours: number = 12;
  nextUpdateAt: number = 0;
  lastAttemptAt: number = 0;
  lastError: string = '';
  // 连续更新失败次数(成功一次即清零);≥3 次跳过自动更新,由手动更新复位
  failCount: number = 0;
  // 订阅级设置(对齐安卓 group_preferences.xml)
  userAgent: string = '';                    // 自定义 User-Agent,空 = 默认
  autoUpdate: boolean = true;                // 本订阅是否参与自动更新
  updateWhenConnectedOnly: boolean = false;  // 仅 VPN 已连接时自动更新
  deduplication: boolean = false;            // 更新时按 类型+服务器+端口+UUID 去重(对齐安卓,默认关闭)
  forceResolve: boolean = false;             // 更新时把节点服务器域名解析为 IP(对齐安卓 subscriptionForceResolve)
}

export interface SubUpdateResult {
  added: number;
  removed: number;
  total: number;
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
      const rawHours = Number(source.updateIntervalHours);
      item.updateIntervalHours = !(rawHours > 0) ? 12 : Math.max(1, Math.min(720, Math.floor(rawHours)));
      item.nextUpdateAt = Number(source.nextUpdateAt)
        || item.lastUpdate + item.updateIntervalHours * 3600 * 1000;
      item.lastAttemptAt = Number(source.lastAttemptAt) || 0;
      item.lastError = source.lastError ?? '';
      item.failCount = Number(source.failCount) || 0;
      item.userAgent = source.userAgent ?? '';
      item.autoUpdate = source.autoUpdate !== false;
      item.updateWhenConnectedOnly = source.updateWhenConnectedOnly === true;
      item.deduplication = source.deduplication === true;
      item.forceResolve = source.forceResolve === true;
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

async function touchSub(url: string): Promise<void> {
  const list = await listSubs();
  for (const s of list) {
    if (s.url === url) {
      s.lastUpdate = Date.now();
      s.nextUpdateAt = s.lastUpdate + Math.max(1, s.updateIntervalHours) * 3600 * 1000;
    }
  }
  await saveSubs(list);
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
    && now >= (s.nextUpdateAt || s.lastUpdate + Math.max(1, s.updateIntervalHours) * 3600 * 1000)
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
    if (changes['updateIntervalHours'] !== undefined) {
      // 非正数/非数字一律视为非法,回落默认 12(与 listSubs 同一规则)
      const raw = Number(changes['updateIntervalHours']);
      const hours = !(raw > 0) ? 12 : Math.min(720, Math.floor(raw));
      s.updateIntervalHours = Math.max(1, hours);
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

function stableProfileId(p: Profile, url: string): string {
  const value = profileIdentity(p, url);
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return `sub_${(hash >>> 0).toString(16)}`;
}

function isIpAddress(host: string): boolean {
  if (host.length === 0) {
    return true;
  }
  if (host.indexOf(':') >= 0) {
    return true; // IPv6 字面量
  }
  const parts = host.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) {
      return false;
    }
    const n = parseInt(part, 10);
    if (n < 0 || n > 255) {
      return false;
    }
  }
  return true;
}

/** 解析单个节点服务器域名并改写为 IP(对齐安卓 rewriteAddress);失败保留原域名 */
async function resolveOneProfile(p: Profile): Promise<void> {
  const host = p.server.trim();
  if (isIpAddress(host)) {
    return;
  }
  try {
    const addrs = await connection.getAddressesByName(host);
    let v4 = '';
    let v6 = '';
    for (const a of addrs) {
      const addr = a.address;
      if (addr.indexOf(':') < 0) {
        if (v4.length === 0) {
          v4 = addr;
        }
      } else if (v6.length === 0) {
        v6 = addr;
      }
    }
    const chosen = v4.length > 0 ? v4 : v6;
    if (chosen.length === 0) {
      return;
    }
    if (p.tls && p.sni.trim().length === 0) {
      p.sni = host; // 保留原域名作 TLS SNI
    }
    p.server = chosen;
  } catch (e) {
    LogStore.addLog(`[sub] 强制解析 ${host} 失败,保留域名: ${e}`);
  }
}

/** 批量强制解析(对齐安卓 forceResolve 的 5 并发查询池) */
async function applyForceResolve(list: Array<Profile>): Promise<void> {
  const BATCH = 5;
  for (let i = 0; i < list.length; i += BATCH) {
    const batch = list.slice(i, i + BATCH);
    await Promise.all(batch.map((p: Profile): Promise<void> => resolveOneProfile(p)));
  }
}

/** 更新单个订阅:下载 → 解析 → 原子替换该订阅的节点(保留运行中节点);同时记录流量/到期 */
export async function updateSubscription(url: string): Promise<SubUpdateResult> {
  const settings = await loadSettings();
  const subsForGroup = await listSubs();
  const subForGroup = subsForGroup.find((item: SubInfo) => item.url === url);
  const customUA = subForGroup !== undefined ? subForGroup.userAgent : '';
  // 去重开关(对齐安卓 subscriptionDeduplication,默认关闭:保留订阅返回的全部节点)
  const dedupEnabled = subForGroup !== undefined && subForGroup.deduplication;
  const fetched = await fetchSubscriptionWithInfo(url, settings.subAllowInsecure, customUA);
  const content = fetched.content;
  let parsed: Array<Profile> = [];
  if (looksLikeClashYaml(content)) {
    parsed = parseClashProxies(content).profiles;
  } else if (looksLikeSingBoxJson(content)) {
    parsed = parseSingBoxConfig(content).profiles;
  } else {
    parsed = parseShareText(content);
  }
  if (parsed.length === 0) {
    throw new Error('订阅内容中没有可用节点');
  }
  // 强制解析(对齐安卓 subscriptionForceResolve):把节点服务器域名解析为 IP,
  // 原域名保留到 sni,避免服务器换 IP 后 TLS/SNI 断裂
  if (subForGroup !== undefined && subForGroup.forceResolve) {
    await applyForceResolve(parsed);
  }
  await initStore(globalContext());
  const profiles = await loadProfiles();
  // 一订阅一分组:新节点自动归入订阅对应分组(优先订阅分组名,其次订阅名,再次域名)
  let groupName = subNameOf(url);
  if (subForGroup !== undefined) {
    if (subForGroup.group.trim().length > 0) {
      groupName = subForGroup.group.trim();
    } else if (subForGroup.name.trim().length > 0) {
      groupName = subForGroup.name.trim();
    }
  }
  const subGroupId = await ensureGroupByName(groupName);
  const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
  const selectedId = await readPrefString('selected_profile_id', '');
  const selectedProfile = profiles.find((item: Profile) => item.id === selectedId);
  const selectedIdentity = selectedProfile !== undefined && selectedProfile.subUrl === url
    ? profileIdentity(selectedProfile, url) : '';
  let migratedSelectedId = '';

  const kept: Array<Profile> = [];
  let removed = 0;
  for (const p of profiles) {
    if (p.subUrl === url && p.id !== runningId) {
      removed++;
      continue;
    }
    // 升级迁移:该订阅遗留的未分组节点归入订阅分组(用户手动分过组的不动)
    if (p.subUrl === url && p.groupId.length === 0) {
      p.groupId = subGroupId;
    }
    kept.push(p);
  }
  let added = 0;
  for (const p of parsed) {
    // 开启去重时:类型+服务器+端口+UUID 相同视为重复,跳过(对齐安卓)
    if (dedupEnabled) {
      const dup = kept.find(x => x.type === p.type && x.server === p.server
        && x.serverPort === p.serverPort && x.uuid === p.uuid);
      if (dup !== undefined) {
        continue;
      }
    }
    p.subUrl = url;
    p.groupId = subGroupId;
    p.id = stableProfileId(p, url);
    if (kept.some((item: Profile) => item.id === p.id)) {
      p.id = `${p.id}_${added}`;
    }
    p.updatedAt = Date.now();
    kept.push(p);
    if (selectedIdentity.length > 0 && profileIdentity(p, url) === selectedIdentity) {
      migratedSelectedId = p.id;
    }
    added++;
  }
  await saveProfiles(kept);
  if (migratedSelectedId.length > 0 && migratedSelectedId !== selectedId) {
    await writePrefString('selected_profile_id', migratedSelectedId);
  } else if (selectedProfile !== undefined && selectedProfile.subUrl === url
    && !kept.some((item: Profile) => item.id === selectedId)) {
    const replacement = kept.find((item: Profile) => item.subUrl === url);
    await writePrefString('selected_profile_id', replacement === undefined ? '' : replacement.id);
  }
  await touchSub(url);
  // 记录订阅流量/到期信息(响应头 subscription-userinfo)
  if (fetched.userinfo.length > 0) {
    const info = parseSubUserInfo(fetched.userinfo);
    if (info !== null) {
      const subs = await listSubs();
      for (const s of subs) {
        if (s.url === url) {
          s.upload = info.upload;
          s.download = info.download;
          s.total = info.total;
          s.expire = info.expire;
        }
      }
      await saveSubs(subs);
    }
  }
  const result: SubUpdateResult = { added: added, removed: removed, total: kept.length };
  return result;
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
