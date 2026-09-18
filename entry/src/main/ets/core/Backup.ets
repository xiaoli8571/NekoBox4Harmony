import common from '@ohos.app.ability.common';
import { Profile, ProfileGroup, AppSettings } from '../model/Profile';
import { RouteRule, RemoteRuleSet, loadRouteRules, saveRouteRules, loadRemoteRuleSets, saveRemoteRuleSets } from '../model/RouteRule';
import { SubInfo, listSubs, saveSubs } from './Subscriptions';
import { initStore, loadProfiles, saveProfiles, loadGroups, saveGroups, loadSettings, saveSettings, LogStore } from '../model/Store';

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

interface BackupSnapshot {
  settings: AppSettings;
  profiles: Array<Profile>;
  groups: Array<ProfileGroup>;
  subscriptions: Array<SubInfo>;
  routeRules: Array<RouteRule>;
  remoteRuleSets: Array<RemoteRuleSet>;
}

export interface BackupRestoreResult {
  profiles: number;
  groups: number;
  subscriptions: number;
  routeRules: number;
  remoteRuleSets: number;
  stoppedVpn: boolean;
}

let restoreInProgress: boolean = false;

function isRecord(value: Object | undefined): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

function requireString(value: Object, field: string): void {
  const record = value as Record<string, Object>;
  if (typeof record[field] !== 'string') {
    throw new Error('backup_bad_format');
  }
}

function requireNumber(value: Object, field: string): void {
  const record = value as Record<string, Object>;
  if (typeof record[field] !== 'number' || !Number.isFinite(record[field] as number)) {
    throw new Error('backup_bad_format');
  }
}

function requireBoolean(value: Object, field: string): void {
  const record = value as Record<string, Object>;
  if (typeof record[field] !== 'boolean') {
    throw new Error('backup_bad_format');
  }
}

function validateOptionalFields(value: Object, stringFields: Array<string>, numberFields: Array<string>,
  booleanFields: Array<string>): void {
  const record = value as Record<string, Object>;
  for (const field of stringFields) {
    if (record[field] !== undefined) {
      requireString(value, field);
    }
  }
  for (const field of numberFields) {
    if (record[field] !== undefined) {
      requireNumber(value, field);
    }
  }
  for (const field of booleanFields) {
    if (record[field] !== undefined) {
      requireBoolean(value, field);
    }
  }
}

function validateSettings(value: Object): void {
  if (!isRecord(value)) {
    throw new Error('backup_bad_format');
  }
  validateOptionalFields(value,
    ['stack', 'mode', 'directDomains', 'directIpCidrs', 'remoteDns', 'directDns', 'remoteDnsStrategy',
      'directDnsStrategy', 'serverDnsStrategy', 'sniffMode', 'logLevel', 'testUrl', 'latencyTestMode', 'appearance',
      'profileSortMode', 'navLayout', 'clashApiSecret', 'perAppMode', 'perAppList', 'globalCustomConfig', 'ipv6Mode'],
    ['mtu', 'mixedPort', 'testConcurrent', 'subscriptionUpdateIntervalHours', 'clashApiPort', 'speedIntervalMs'],
    ['dnsRouting', 'fakeDns', 'ipv6', 'bypassLan', 'resolveDestination', 'allowAccess', 'allowInsecureAll',
      'subAllowInsecure', 'alwaysShowAddress', 'notificationGroup', 'autoUpdateSubs', 'autoConnect',
      'hapticFeedback', 'clashApiEnabled', 'liquidGlass', 'networkChangeResetConnections', 'wakeResetConnections',
      'profileTrafficStatistics', 'showBottomBar']);
}

function validateProfile(value: Object): void {
  if (!isRecord(value)) {
    throw new Error('backup_bad_format');
  }
  requireString(value, 'id');
  requireString(value, 'name');
  requireString(value, 'type');
  requireString(value, 'server');
  requireNumber(value, 'serverPort');
  validateOptionalFields(value,
    ['method', 'password', 'ssPlugin', 'ssPluginOpts', 'username', 'uuid', 'security', 'flow',
      'packetEncoding', 'transport', 'path', 'host', 'serviceName', 'wsEarlyDataHeaderName', 'sni', 'alpn',
      'fingerprint', 'realityPublicKey', 'realityShortId', 'certificates', 'echConfig', 'obfs', 'serverPorts',
      'congestionControl', 'udpRelayMode', 'localAddress', 'privateKey', 'peerPublicKey', 'preSharedKey',
      'reserved', 'sshAuthType', 'privateKeyPassphrase', 'hostKey', 'muxProtocol', 'extra', 'customOutbound',
      'chainIds', 'subUrl', 'groupId'],
    ['alterId', 'wsEarlyData', 'upMbps', 'downMbps', 'hopInterval', 'wgMtu', 'shadowtlsVersion',
      'muxMaxStreams', 'sortOrder', 'latencyMs', 'latencyTestedAt', 'updatedAt'],
    ['tls', 'allowInsecure', 'ech', 'reduceRtt', 'disableSni', 'mux', 'muxPadding', 'pinned']);
}

function validateGroup(value: Object): void {
  if (!isRecord(value)) {
    throw new Error('backup_bad_format');
  }
  requireString(value, 'id');
  requireString(value, 'name');
  validateOptionalFields(value, ['frontProxy', 'landingProxy'], ['sortOrder', 'createdAt', 'updatedAt'], ['collapsed', 'isSelector']);
}

function validateSubscription(value: Object): void {
  if (!isRecord(value)) {
    throw new Error('backup_bad_format');
  }
  requireString(value, 'url');
  validateOptionalFields(value, ['name', 'group', 'lastError'],
    ['lastUpdate', 'upload', 'download', 'total', 'expire', 'updateIntervalHours', 'nextUpdateAt',
      'lastAttemptAt', 'failCount'], []);
}

function validateRouteRule(value: Object): void {
  if (!isRecord(value)) {
    throw new Error('backup_bad_format');
  }
  requireString(value, 'type');
  requireString(value, 'value');
  requireString(value, 'outbound');
  validateOptionalFields(value, ['remark'], [], ['enabled']);
}

function validateRemoteRuleSet(value: Object): void {
  if (!isRecord(value)) {
    throw new Error('backup_bad_format');
  }
  requireString(value, 'id');
  requireString(value, 'name');
  requireString(value, 'url');
  requireString(value, 'type');
  requireString(value, 'outbound');
  validateOptionalFields(value, ['lastError'], ['updatedAt'], ['enabled']);
}

function validateArray(value: Object | undefined, required: boolean, validator: (item: Object) => void): void {
  if (value === undefined) {
    if (required) {
      throw new Error('backup_bad_format');
    }
    return;
  }
  if (!Array.isArray(value)) {
    throw new Error('backup_bad_format');
  }
  const items: Array<Object> = value as Array<Object>;
  for (const item of items) {
    validator(item);
  }
}

function validatePayload(obj: BackupPayload): void {
  if (obj === null || typeof obj !== 'object' || obj.profiles === undefined || obj.settings === undefined) {
    throw new Error('backup_bad_format');
  }
  const schemaVersion = obj.schemaVersion ?? obj.version ?? 1;
  if (!Number.isInteger(schemaVersion) || schemaVersion < 1) {
    throw new Error('backup_bad_format');
  }
  if (schemaVersion > CURRENT_SCHEMA_VERSION) {
    throw new Error(`backup_unsupported_version:${schemaVersion}`);
  }
  validateSettings(obj.settings);
  validateArray(obj.profiles, true, validateProfile);
  validateArray(obj.groups, false, validateGroup);
  validateArray(obj.subscriptions, false, validateSubscription);
  validateArray(obj.routeRules, false, validateRouteRule);
  validateArray(obj.remoteRuleSets, false, validateRemoteRuleSet);
}

async function captureSnapshot(): Promise<BackupSnapshot> {
  return {
    settings: await loadSettings(),
    profiles: await loadProfiles(),
    groups: await loadGroups(),
    subscriptions: await listSubs(),
    routeRules: await loadRouteRules(),
    remoteRuleSets: await loadRemoteRuleSets()
  };
}

async function writePayload(payload: BackupPayload): Promise<void> {
  await saveSettings(payload.settings);
  await saveProfiles(payload.profiles);
  await saveGroups(payload.groups ?? []);
  await saveSubs(payload.subscriptions ?? []);
  await saveRouteRules(payload.routeRules ?? []);
  await saveRemoteRuleSets(payload.remoteRuleSets ?? []);
}

async function restoreSnapshot(snapshot: BackupSnapshot): Promise<Array<string>> {
  const failures: Array<string> = [];
  try { await saveSettings(snapshot.settings); } catch (e) { failures.push(`settings=${e}`); }
  try { await saveProfiles(snapshot.profiles); } catch (e) { failures.push(`profiles=${e}`); }
  try { await saveGroups(snapshot.groups); } catch (e) { failures.push(`groups=${e}`); }
  try { await saveSubs(snapshot.subscriptions); } catch (e) { failures.push(`subscriptions=${e}`); }
  try { await saveRouteRules(snapshot.routeRules); } catch (e) { failures.push(`routeRules=${e}`); }
  try { await saveRemoteRuleSets(snapshot.remoteRuleSets); } catch (e) { failures.push(`remoteRuleSets=${e}`); }
  return failures;
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

/** Validate first, then restore transactionally with a complete pre-write snapshot. */
export async function importBackup(context: common.Context, text: string): Promise<BackupRestoreResult> {
  if (restoreInProgress) {
    throw new Error('backup_restore_busy');
  }
  restoreInProgress = true;
  try {
    await initStore(context);
    let obj: BackupPayload;
    try {
      obj = JSON.parse(text) as BackupPayload;
    } catch (e) {
      throw new Error('backup_invalid_json');
    }
    validatePayload(obj);

    const snapshot = await captureSnapshot();
    try {
      await writePayload(obj);
    } catch (e) {
      const writeMessage = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[backup] 恢复写入失败，开始全量回滚: ${writeMessage}`);
      const rollbackFailures = await restoreSnapshot(snapshot);
      if (rollbackFailures.length > 0) {
        const detail = rollbackFailures.join('; ');
        LogStore.addLog(`[backup] 全量回滚存在失败: ${detail}`);
        throw new Error(`backup_rollback_failed:${detail}`);
      }
      LogStore.addLog('[backup] 恢复失败后的全量回滚已完成');
      throw new Error('backup_restore_rolled_back');
    }

    const result: BackupRestoreResult = {
      profiles: obj.profiles.length,
      groups: obj.groups?.length ?? 0,
      subscriptions: obj.subscriptions?.length ?? 0,
      routeRules: obj.routeRules?.length ?? 0,
      remoteRuleSets: obj.remoteRuleSets?.length ?? 0,
      stoppedVpn: false
    };
    LogStore.addLog(`[backup] 恢复成功: 节点 ${result.profiles}, 分组 ${result.groups}, 订阅 ${result.subscriptions}, 路由 ${result.routeRules}, 远程规则集 ${result.remoteRuleSets}`);
    return result;
  } finally {
    restoreInProgress = false;
  }
}
