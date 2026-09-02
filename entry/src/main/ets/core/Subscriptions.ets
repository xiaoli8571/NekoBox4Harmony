import common from '@ohos.app.ability.common';
import { Profile } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, saveGroups, readPrefString, writePrefString } from '../model/Store';
import { subscriptionGroupId } from '../model/Group';
import { fetchSubscriptionWithInfo, parseSubUserInfo, looksLikeClashYaml, parseClashProxies } from '../utils/Subscription';
import { parseShareText } from '../utils/LinkParser';

/** 订阅管理:记录订阅来源、更新节点(按 subUrl 原子替换)。 */

const KEY_SUBS = 'subscriptions';
const AUTO_UPDATE_INTERVAL = 12 * 3600 * 1000; // 12h

export class SubInfo {
  url: string = '';
  name: string = '';
  lastUpdate: number = 0;
  upload: number = 0;
  download: number = 0;
  total: number = 0;
  expire: number = 0;
  // 每个订阅独立的自动更新周期，默认 12 小时；设为 0 时关闭该订阅自动更新。
  autoUpdateInterval: number = AUTO_UPDATE_INTERVAL;
  // 连续更新失败次数(成功一次即清零);≥3 次跳过自动更新,由手动更新复位
  failCount: number = 0;
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
    for (const item of parsed) {
      const info = new SubInfo();
      info.url = item.url ?? '';
      info.name = item.name ?? '';
      info.lastUpdate = Number(item.lastUpdate ?? 0);
      info.upload = Number(item.upload ?? 0);
      info.download = Number(item.download ?? 0);
      info.total = Number(item.total ?? 0);
      info.expire = Number(item.expire ?? 0);
      info.autoUpdateInterval = item.autoUpdateInterval === undefined
        ? AUTO_UPDATE_INTERVAL
        : Math.max(0, Number(item.autoUpdateInterval));
      info.failCount = Math.max(0, Number(item.failCount ?? 0));
      result.push(info);
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

export async function upsertSub(url: string, userinfo: string = ''): Promise<void> {
  const list = await listSubs();
  const target = list.find(x => x.url === url);
  if (target === undefined) {
    const info = new SubInfo();
    info.url = url;
    info.name = subNameOf(url);
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
  } else if (userinfo.length > 0) {
    const parsed = parseSubUserInfo(userinfo);
    if (parsed !== null) {
      target.upload = parsed.upload;
      target.download = parsed.download;
      target.total = parsed.total;
      target.expire = parsed.expire;
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
  // 连续失败 ≥3 次的订阅跳过自动更新；每个订阅使用独立周期，0 表示关闭自动更新。
  return subs.filter(s => {
    const configured = Number(s.autoUpdateInterval);
    const interval = isNaN(configured) ? AUTO_UPDATE_INTERVAL : configured;
    return interval > 0 && now - s.lastUpdate > interval && !(Number(s.failCount) >= 3);
  });
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

function stableNodeKey(profile: Profile): string {
  return [
    profile.type,
    profile.server,
    `${profile.serverPort}`,
    profile.uuid,
    profile.username,
    profile.method,
    profile.transport,
    profile.path,
    profile.host,
    profile.serviceName,
    profile.sni
  ].join('\n');
}

function copyLocalMetadata(target: Profile, source: Profile): void {
  target.id = source.id;
  target.pinned = source.pinned;
  target.sortOrder = source.sortOrder;
}

function genId(): string {
  return `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
}

/** 更新单个订阅:下载 → 解析 → 按稳定节点身份原子替换，并保留运行节点及本地元数据 */
export async function updateSubscription(url: string): Promise<SubUpdateResult> {
  const fetched = await fetchSubscriptionWithInfo(url);
  const content = fetched.content;
  let parsed: Array<Profile> = [];
  if (looksLikeClashYaml(content)) {
    parsed = parseClashProxies(content).profiles;
  } else {
    parsed = parseShareText(content);
  }
  if (parsed.length === 0) {
    throw new Error('订阅内容中没有可用节点');
  }
  await initStore(globalContext());
  const profiles = await loadProfiles();
  const groups = await loadGroups(profiles);
  const groupId = subscriptionGroupId(url);
  const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
  const oldNodes = profiles.filter(p => p.subUrl === url);
  const oldByKey: Record<string, Profile> = {};
  for (const oldNode of oldNodes) {
    oldByKey[stableNodeKey(oldNode)] = oldNode;
  }

  const replacements: Array<Profile> = [];
  let added = 0;
  for (let i = 0; i < parsed.length; i++) {
    const node = parsed[i];
    const oldNode = oldByKey[stableNodeKey(node)];
    if (oldNode !== undefined) {
      copyLocalMetadata(node, oldNode);
    } else {
      node.id = `${genId()}_${i}`;
      node.sortOrder = i;
      added++;
    }
    node.subUrl = url;
    node.groupId = groupId;
    node.updatedAt = Date.now();
    replacements.push(node);
  }

  const runningNode = oldNodes.find(p => p.id === runningId);
  if (runningNode !== undefined && replacements.find(p => p.id === runningId) === undefined) {
    replacements.push(runningNode);
  }
  const nextProfiles = profiles.filter(p => p.subUrl !== url).concat(replacements);
  const removed = oldNodes.filter(oldNode => replacements.find(node => node.id === oldNode.id) === undefined).length;
  await saveProfiles(nextProfiles);

  const group = groups.find(item => item.id === groupId);
  if (group !== undefined) {
    group.subscriptionUrl = url;
    group.updatedAt = Date.now();
    await saveGroups(groups);
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
  const result: SubUpdateResult = { added: added, removed: removed, total: replacements.length };
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
