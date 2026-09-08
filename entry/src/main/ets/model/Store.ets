import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import emitter from '@ohos.events.emitter';
import { Profile, ProfileGroup, AppSettings } from './Profile';

/** 持久化(Preferences) + 全局日志缓冲。 */

const PREF_NAME = 'nekobox_store';
const KEY_PROFILES = 'profiles';
const KEY_GROUPS = 'profile_groups';
const KEY_SETTINGS = 'settings';
const KEY_PENDING = 'pending_profile_id';
export const LOG_EVENT_ID: number = 1001;

let prefInstance: dataPreferences.Preferences | null = null;
let profileWriteQueue: Promise<void> = Promise.resolve();

/** 串行执行节点读改写，避免订阅更新、编辑和删除操作互相覆盖。 */
export async function mutateProfiles(
  mutation: (profiles: Array<Profile>) => Array<Profile>
): Promise<Array<Profile>> {
  const previous = profileWriteQueue;
  let release: () => void = () => {};
  profileWriteQueue = new Promise<void>((resolve: () => void) => {
    release = resolve;
  });
  await previous;
  try {
    const profiles = await loadProfiles();
    const updated = mutation(profiles);
    await saveProfiles(updated);
    return updated;
  } finally {
    release();
  }
}

export async function initStore(context: common.Context): Promise<void> {
  prefInstance = await dataPreferences.getPreferences(context, PREF_NAME);
}

async function requirePref(): Promise<dataPreferences.Preferences> {
  if (prefInstance === null) {
    throw new Error('store not initialized');
  }
  return prefInstance;
}

export async function loadProfiles(): Promise<Array<Profile>> {
  const pref = await requirePref();
  const raw: string = (await pref.get(KEY_PROFILES, '[]')) as string;
  try {
    const parsed: Array<Profile> = JSON.parse(raw) as Array<Profile>;
    const result: Array<Profile> = [];
    for (let i = 0; i < parsed.length; i++) {
      const p = new Profile();
      fillFrom(p, parsed[i]);
      result.push(p);
    }
    return result;
  } catch (e) {
    return [];
  }
}

export async function saveProfiles(list: Array<Profile>): Promise<void> {
  const pref = await requirePref();
  await pref.put(KEY_PROFILES, JSON.stringify(list));
  await pref.flush();
}

export async function loadGroups(): Promise<Array<ProfileGroup>> {
  const pref = await requirePref();
  const raw: string = (await pref.get(KEY_GROUPS, '[]')) as string;
  try {
    const parsed: Array<ProfileGroup> = JSON.parse(raw) as Array<ProfileGroup>;
    const result: Array<ProfileGroup> = [];
    for (let i = 0; i < parsed.length; i++) {
      const group = new ProfileGroup();
      fillFrom(group, parsed[i]);
      result.push(group);
    }
    return result.sort((a: ProfileGroup, b: ProfileGroup) => a.sortOrder - b.sortOrder);
  } catch (e) {
    return [];
  }
}

export async function saveGroups(list: Array<ProfileGroup>): Promise<void> {
  const pref = await requirePref();
  await pref.put(KEY_GROUPS, JSON.stringify(list));
  await pref.flush();
}

export async function loadSettings(): Promise<AppSettings> {
  const pref = await requirePref();
  const raw: string = (await pref.get(KEY_SETTINGS, '{}')) as string;
  const s = new AppSettings();
  try {
    fillFrom(s, JSON.parse(raw) as AppSettings);
  } catch (e) {
    // keep defaults
  }
  s.mtu = Math.max(1280, Math.min(1500, s.mtu));
  if (s.profileSortMode !== 'manual' && s.profileSortMode !== 'latency' && s.profileSortMode !== 'name') {
    s.profileSortMode = 'manual';
  }
  if (s.navLayout !== 'side') {
    s.navLayout = 'bottom';
  }
  s.clashApiPort = Math.max(1024, Math.min(65535, s.clashApiPort));
  // 新设置项校验(非法值回退默认,防止脏数据破坏配置生成)
  const LOG_LEVELS: Array<string> = ['trace', 'debug', 'info', 'warn', 'error'];
  if (LOG_LEVELS.indexOf(s.logLevel) < 0) {
    s.logLevel = 'info';
  }
  const SNIFF_MODES: Array<string> = ['off', 'route', 'override'];
  if (SNIFF_MODES.indexOf(s.sniffMode) < 0) {
    s.sniffMode = 'route';
  }
  const STRATEGIES: Array<string> = ['', 'auto', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'];
  if (STRATEGIES.indexOf(s.remoteDnsStrategy) < 0) {
    s.remoteDnsStrategy = '';
  }
  if (STRATEGIES.indexOf(s.directDnsStrategy) < 0) {
    s.directDnsStrategy = '';
  }
  if (s.mixedPort !== 0) {
    s.mixedPort = Math.max(1024, Math.min(65535, s.mixedPort));
  }
  if (s.testConcurrent < 1 || s.testConcurrent > 20) {
    s.testConcurrent = 5;
  }
  if (s.testUrl.trim().length === 0) {
    s.testUrl = 'https://www.gstatic.com/generate_204';
  }
  // 迁移历史默认测试网址(cp.cloudflare.com 在部分网络下经代理也不通,易误红)
  if (s.testUrl.trim() === 'http://cp.cloudflare.com/' || s.testUrl.trim() === 'https://cp.cloudflare.com/') {
    s.testUrl = 'https://www.gstatic.com/generate_204';
  }
  const TEST_MODES: Array<string> = ['url', 'tcp'];
  if (TEST_MODES.indexOf(s.latencyTestMode) < 0) {
    s.latencyTestMode = 'url';
  }
  if (s.clashApiSecret.length === 0) {
    s.clashApiSecret = `${Date.now().toString(36)}${Math.floor(Math.random() * Number.MAX_SAFE_INTEGER).toString(36)}`;
    await pref.put(KEY_SETTINGS, JSON.stringify(s));
    await pref.flush();
  }
  // 迁移旧版默认 DNS；仅迁移历史默认值，不覆盖用户自定义地址。
  if (s.remoteDns === 'https://8.8.8.8/dns-query' || s.remoteDns === 'udp://8.8.8.8') {
    s.remoteDns = 'tcp://8.8.8.8';
  }
  return s;
}

export async function saveSettings(s: AppSettings): Promise<void> {
  const pref = await requirePref();
  await pref.put(KEY_SETTINGS, JSON.stringify(s));
  await pref.flush();
}

/** 恢复出厂:清空全部配置存储(节点/分组/设置/订阅/规则) */
export async function resetAllData(): Promise<void> {
  const pref = await requirePref();
  await pref.clear();
  await pref.flush();
}

export async function setPendingProfileId(id: string): Promise<void> {
  const pref = await requirePref();
  await pref.put(KEY_PENDING, id);
  await pref.flush();
}

export async function setRunningProfileId(id: string): Promise<void> {
  const pref = await requirePref();
  await pref.put('running_profile_id', id);
  await pref.flush();
}

export async function getRunningProfileId(): Promise<string> {
  const pref = await requirePref();
  return (await pref.get('running_profile_id', '')) as string;
}

export async function readPrefString(key: string, dflt: string): Promise<string> {
  const pref = await requirePref();
  return (await pref.get(key, dflt)) as string;
}

export async function writePrefString(key: string, value: string): Promise<void> {
  const pref = await requirePref();
  await pref.put(key, value);
  await pref.flush();
}

export async function getPendingProfileId(): Promise<string> {
  const pref = await requirePref();
  return (await pref.get(KEY_PENDING, '')) as string;
}

export async function clearPendingProfileId(): Promise<void> {
  await setPendingProfileId('');
}

/** 把解析出的 JSON 对象中已有值的字段填充到带默认值的类实例上。 */
function fillFrom(target: Object, source: Object): void {
  if (source === undefined || source === null) {
    return;
  }
  const keys: Array<string> = Object.keys(source);
  const rec: Record<string, Object> = target as Record<string, Object>;
  for (const k of keys) {
    const v: Object = (source as Record<string, Object>)[k];
    if (v === undefined || v === null) {
      continue;
    }
    rec[k] = v;
  }
}

/** 进程内日志缓冲,UI 通过 emitter(LOG_EVENT_ID) 增量刷新。
 *  扩展进程(:vpn)可注入 publisher 把日志转发到 UI 进程(VpnIpc)。 */
export class LogStore {
  private static lines: Array<string> = [];
  private static publisher: ((line: string) => void) | null = null;
  private static readonly MAX_LINES = 2000;

  static setPublisher(fn: (line: string) => void): void {
    LogStore.publisher = fn;
  }

  static addLog(line: string): void {
    LogStore.lines.push(line);
    if (LogStore.lines.length > LogStore.MAX_LINES) {
      LogStore.lines.splice(0, LogStore.lines.length - LogStore.MAX_LINES);
    }
    console.info(`[NB] ${line}`);
    const event: emitter.InnerEvent = { eventId: LOG_EVENT_ID, priority: emitter.EventPriority.LOW };
    const payload: Record<string, Object> = { 'line': line };
    const data: emitter.EventData = { data: payload };
    emitter.emit(event, data);
    if (LogStore.publisher !== null) {
      LogStore.publisher(line);
    }
  }

  /** UI 进程接收来自 :vpn 进程的日志(只入本地缓冲,不再转发) */
  static appendRemote(line: string): void {
    LogStore.lines.push(line);
    if (LogStore.lines.length > LogStore.MAX_LINES) {
      LogStore.lines.splice(0, LogStore.lines.length - LogStore.MAX_LINES);
    }
    const event: emitter.InnerEvent = { eventId: LOG_EVENT_ID, priority: emitter.EventPriority.LOW };
    const payload: Record<string, Object> = { 'line': line };
    const data: emitter.EventData = { data: payload };
    emitter.emit(event, data);
  }

  static addLogMulti(chunk: string): void {
    const parts = chunk.split('\n');
    for (const p of parts) {
      if (p.length > 0) {
        LogStore.addLog(p);
      }
    }
  }

  static getLines(): Array<string> {
    return LogStore.lines;
  }

  static clear(): void {
    LogStore.lines = [];
  }
}
