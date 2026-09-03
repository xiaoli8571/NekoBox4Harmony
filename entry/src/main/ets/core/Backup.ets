import common from '@ohos.app.ability.common';
import { Profile, ProfileGroup, AppSettings } from '../model/Profile';
import { RouteRule, loadRouteRules, saveRouteRules } from '../model/RouteRule';
import { SubInfo, listSubs, saveSubs } from './Subscriptions';
import { initStore, loadProfiles, saveProfiles, loadGroups, saveGroups, loadSettings, saveSettings } from '../model/Store';

/** NekoBox 配置备份/恢复，包含节点、设置、订阅和自定义路由规则。 */

const CURRENT_SCHEMA_VERSION: number = 3;

interface BackupPayload {
  schemaVersion?: number;
  version?: number;
  exportedAt: number;
  settings: AppSettings;
  profiles: Array<Profile>;
  groups?: Array<ProfileGroup>;
  subscriptions?: Array<SubInfo>;
  routeRules?: Array<RouteRule>;
}

export async function exportBackup(context: common.Context): Promise<string> {
  await initStore(context);
  const payload: BackupPayload = {
    schemaVersion: CURRENT_SCHEMA_VERSION,
    version: CURRENT_SCHEMA_VERSION,
    exportedAt: Date.now(),
    settings: await loadSettings(),
    profiles: await loadProfiles(),
    groups: await loadGroups(),
    subscriptions: await listSubs(),
    routeRules: await loadRouteRules()
  };
  return JSON.stringify(payload);
}

export async function importBackup(context: common.Context, text: string): Promise<string> {
  await initStore(context);
  const obj = JSON.parse(text) as BackupPayload;
  if (obj === null || obj.profiles === undefined || obj.settings === undefined) {
    throw new Error('备份内容格式不正确');
  }
  const schemaVersion = obj.schemaVersion ?? obj.version ?? 1;
  if (schemaVersion > CURRENT_SCHEMA_VERSION) {
    throw new Error(`不支持的备份版本: ${schemaVersion}`);
  }
  await saveSettings(obj.settings);
  await saveProfiles(obj.profiles);
  await saveGroups(obj.groups ?? []);
  await saveSubs(obj.subscriptions ?? []);
  await saveRouteRules(obj.routeRules ?? []);
  return `已恢复 ${obj.profiles.length} 个节点、${obj.groups?.length ?? 0} 个分组、全部设置、${obj.subscriptions?.length ?? 0} 个订阅和 ${obj.routeRules?.length ?? 0} 条路由规则`;
}
