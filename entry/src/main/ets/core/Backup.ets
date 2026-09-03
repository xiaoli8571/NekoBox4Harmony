import common from '@ohos.app.ability.common';
import { Profile, ProfileGroup, AppSettings } from '../model/Profile';
import { RouteRule, RemoteRuleSet, loadRouteRules, saveRouteRules, loadRemoteRuleSets, saveRemoteRuleSets } from '../model/RouteRule';
import { SubInfo, listSubs, saveSubs } from './Subscriptions';
import { initStore, loadProfiles, saveProfiles, loadGroups, saveGroups, loadSettings, saveSettings } from '../model/Store';

/** NekoBox 配置备份/恢复，包含节点、设置、订阅和自定义路由规则。 */

const CURRENT_SCHEMA_VERSION: number = 4;

interface BackupPayload {
  schemaVersion?: number;
  version?: number;
  exportedAt: number;
  settings: AppSettings;
  profiles: Array<Profile>;
  groups?: Array<ProfileGroup>;
  subscriptions?: Array<SubInfo>;
  routeRules?: Array<RouteRule>;
  remoteRuleSets?: Array<RemoteRuleSet>;
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
    routeRules: await loadRouteRules(),
    remoteRuleSets: await loadRemoteRuleSets()
  };
  return JSON.stringify(payload);
}

export async function importBackup(context: common.Context, text: string): Promise<ResourceStr> {
  await initStore(context);
  let obj: BackupPayload;
  try {
    obj = JSON.parse(text) as BackupPayload;
  } catch (e) {
    throw new Error('backup_invalid_json');
  }
  if (obj === null || obj.profiles === undefined || obj.settings === undefined) {
    throw new Error('backup_bad_format');
  }
  const schemaVersion = obj.schemaVersion ?? obj.version ?? 1;
  if (schemaVersion > CURRENT_SCHEMA_VERSION) {
    throw new Error(`backup_unsupported_version:${schemaVersion}`);
  }
  await saveSettings(obj.settings);
  await saveProfiles(obj.profiles);
  await saveGroups(obj.groups ?? []);
  await saveSubs(obj.subscriptions ?? []);
  await saveRouteRules(obj.routeRules ?? []);
  await saveRemoteRuleSets(obj.remoteRuleSets ?? []);
  return $r('app.string.backup_restore_summary', obj.profiles.length, obj.groups?.length ?? 0,
    obj.subscriptions?.length ?? 0, obj.routeRules?.length ?? 0);
}
