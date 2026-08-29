import common from '@ohos.app.ability.common';
import { Profile } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, readPrefString, writePrefString } from '../model/Store';
import { fetchSubscription, looksLikeClashYaml, parseClashProxies } from '../utils/Subscription';
import { parseShareText } from '../utils/LinkParser';

/** 订阅管理:记录订阅来源、更新节点(按 subUrl 原子替换)。 */

const KEY_SUBS = 'subscriptions';
const AUTO_UPDATE_INTERVAL = 12 * 3600 * 1000; // 12h

export class SubInfo {
  url: string = '';
  name: string = '';
  lastUpdate: number = 0;
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

export async function upsertSub(url: string): Promise<void> {
  const list = await listSubs();
  if (list.find(x => x.url === url) !== undefined) {
    return;
  }
  const info = new SubInfo();
  info.url = url;
  info.name = subNameOf(url);
  info.lastUpdate = Date.now();
  list.push(info);
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
  return subs.filter(s => now - s.lastUpdate > AUTO_UPDATE_INTERVAL);
}

function genId(): string {
  return `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
}

/** 更新单个订阅:下载 → 解析 → 原子替换该订阅的节点(保留运行中节点) */
export async function updateSubscription(url: string): Promise<SubUpdateResult> {
  const content = await fetchSubscription(url);
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
