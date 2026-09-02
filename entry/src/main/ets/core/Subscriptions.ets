import common from '@ohos.app.ability.common';
import { Profile } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, readPrefString, writePrefString } from '../model/Store';
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
    return JSON.parse(raw) as Array<SubInfo>;
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
  // 连续失败 ≥3 次的订阅跳过自动更新(手动更新成功后由 markSubSuccess 清零恢复)
  return subs.filter(s => now - s.lastUpdate > AUTO_UPDATE_INTERVAL && !(Number(s.failCount) >= 3));
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

function genId(): string {
  return `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
}

/** 更新单个订阅:下载 → 解析 → 原子替换该订阅的节点(保留运行中节点);同时记录流量/到期 */
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
  const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';

  const kept: Array<Profile> = [];
  let removed = 0;
  for (const p of profiles) {
    if (p.subUrl === url && p.id !== runningId) {
      removed++;
      continue;
    }
    kept.push(p);
  }
  let added = 0;
  for (const p of parsed) {
    const dup = kept.find(x => x.type === p.type && x.server === p.server
      && x.serverPort === p.serverPort && x.uuid === p.uuid);
    if (dup !== undefined) {
      continue;
    }
    p.id = `${genId()}_${added}`;
    p.subUrl = url;
    p.updatedAt = Date.now();
    kept.push(p);
    added++;
  }
  await saveProfiles(kept);
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
