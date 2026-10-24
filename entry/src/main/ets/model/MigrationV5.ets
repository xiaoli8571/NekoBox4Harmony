import common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';
import { readPrefString, writePrefString, normalizedPerAppMode, LogStore } from './Store';
import { isValidBundleName, normalizeBundleName } from './PerApp';
import { SnapshotContent, ConfigSnapshot, computeChecksum } from './ConfigSnapshot';
import { ConfigRepository } from '../core/ConfigRepository';
import { SnapshotStore } from '../core/SnapshotStore';

/**
 * v4→v5 配置迁移 —— REDESIGN-PLAN-2026-10-23.md §14.4/§14.5(P1/W04)。
 *
 * 职责边界：
 *  - 幂等入口 ensureMigrated(context)：活动快照已存在 → 直接返回(重复启动安全,§14.4-11)；
 *  - 迁移**只读**旧 Preferences 六键原文，不改写任何旧数据(兼容读层继续工作)；
 *  - 升级恢复点 = filesDir/config/migration/pre-v5-backup-<ts>.json(6 键原文 + hash,只写一次)；
 *  - 稳定 ID 分配(§14.4-3)与映射表 filesDir/config/migration/id-map.json；
 *  - 旧数据风险标记(§14.4-7/8、§8.2、§8.5)只记录不改数据：packages 规则加
 *    `unsupportedOnPlatform: true` 保留原文与启用状态；include 空名单只记录；
 *  - 任何整体格式错误(键缺失形态/JSON 解析失败/顶层类型不符)→ 不提交、不覆盖，报告+标记后返回失败。
 *
 * 本文件不做 Preferences 写入(除 config_migration_v5 完成标记)与任何实体语义改写；
 * 快照提交一律走 ConfigRepository.commitInitial(单写者/幂等)。
 */

/** 迁移完成标记的 Preferences 键(值=结果 JSON)。 */
export const MIGRATION_MARKER_KEY: string = 'config_migration_v5';
const MIGRATION_DIR_NAME: string = 'migration';
const BACKUP_PREFIX: string = 'pre-v5-backup-';
const BACKUP_SUFFIX: string = '.json';
const ID_MAP_FILE: string = 'id-map.json';
const REPORT_FILE: string = 'migration-v5-report.json';

/** 分应用名单上限(PerApp.PER_APP_MAX_ENTRIES 语义):apiLevel<23 → 64,否则 256;取不到按 23。 */
export function perAppLimitFor(apiLevel: number): number {
  const level = apiLevel > 0 ? Math.floor(apiLevel) : 23;
  return level >= 23 ? 256 : 64;
}

/** 迁移后的实体数量统计。 */
export class MigrationCounts {
  profiles: number = 0;
  groups: number = 0;
  subscriptions: number = 0;
  routeRules: number = 0;
  remoteRuleSets: number = 0;
}

/** 一条风险/冲突/校验问题记录(报告与标记共用)。 */
export class MigrationIssue {
  /** 机器可读类型,如 per_app_include_empty / legacy_packages_rule / duplicate_profile_id */
  type: string = '';
  /** 人类可读摘要 */
  message: string = '';
  /** 归属的实体键名(profiles/route_rules/…,可空) */
  key: string = '';
  /** 数组下标(可=-1 表示不适用) */
  index: number = -1;
  /** 重复次数(冲突记录用) */
  count: number = 0;
  /** 附加明细(冲突样本/数量对比等) */
  detail: string = '';
}

/** ensureMigrated 的返回值(不抛异常,失败走 ok=false)。 */
export class MigrationResult {
  ok: boolean = false;
  /** hasActive() 短路返回时为 true(重复启动安全)。 */
  skipped: boolean = false;
  revision: number = 0;
  sourceHash: string = '';
  backupPath: string = '';
  idMapPath: string = '';
  reportPath: string = '';
  counts: MigrationCounts = new MigrationCounts();
  /** 冲突(重复 id/url 等,数据未改,列出供用户决策,§14.4-2)。 */
  conflicts: Array<MigrationIssue> = [];
  /** 旧数据风险标记(§14.4-7/8,只记录不改数据)。 */
  risks: Array<MigrationIssue> = [];
  error: string = '';
}

class SubscriptionIdMapping {
  oldUrl: string = '';
  newId: string = '';
  /** 与前序条目 URL 重复(同一来源身份,共用同一 newId)。 */
  duplicate: boolean = false;
}

class RuleIdMapping {
  index: number = 0;
  id: string = '';
}

class RemoteRuleSetIdMapping {
  oldUrl: string = '';
  id: string = '';
}

class IdConflictBucket {
  conflicts: Array<MigrationIssue> = [];
}

/** 稳定 ID 映射表(filesDir/config/migration/id-map.json)。 */
class IdMapFile {
  schemaVersion: number = 5;
  createdAt: number = 0;
  sourceHash: string = '';
  subscriptions: Array<SubscriptionIdMapping> = [];
  routeRules: Array<RuleIdMapping> = [];
  remoteRuleSets: Array<RemoteRuleSetIdMapping> = [];
  profiles: IdConflictBucket = new IdConflictBucket();
  groups: IdConflictBucket = new IdConflictBucket();
}

/** 六个旧 Preferences 键的原文(未解析,保证恢复点逐字节可回放)。 */
class LegacySources {
  settings: string = '{}';
  profiles: string = '[]';
  groups: string = '[]';
  subscriptions: string = '[]';
  routeRules: string = '[]';
  remoteRuleSets: string = '[]';
}

function strField(rec: Record<string, Object>, key: string): string {
  const v: Object | undefined = rec[key];
  if (v === undefined || v === null) {
    return '';
  }
  return `${v}`;
}

function boolField(rec: Record<string, Object>, key: string, dflt: boolean): boolean {
  const v: Object | undefined = rec[key];
  if (v === true) {
    return true;
  }
  if (v === false) {
    return false;
  }
  return dflt;
}

function isRecordValue(value: Object | undefined | null): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** 解析单个 JSON 对象;整体格式错误返回 null(调用方中止迁移)。 */
function parseRecord(raw: string): Record<string, Object> | null {
  try {
    const v: Object = JSON.parse(raw);
    if (isRecordValue(v)) {
      return v as Record<string, Object>;
    }
  } catch (e) {
    // fallthrough
  }
  return null;
}

/** 解析 JSON 数组;顶层必须是数组(整体格式错误返回 null)。非对象元素由调用方隔离。 */
function parseRecordArray(raw: string): Array<Object> | null {
  try {
    const v: Object = JSON.parse(raw);
    if (Array.isArray(v)) {
      return v as Array<Object>;
    }
  } catch (e) {
    // fallthrough
  }
  return null;
}

function asRecordArray(items: Array<Object>, key: string, risks: Array<MigrationIssue>): Array<Record<string, Object>> {
  const out: Array<Record<string, Object>> = [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (isRecordValue(item)) {
      out.push(item as Record<string, Object>);
    } else {
      const issue = new MigrationIssue();
      issue.type = 'dropped_non_object_item';
      issue.key = key;
      issue.index = i;
      issue.message = `不可用记录已隔离: ${key}[${i}] 不是对象`;
      risks.push(issue);
    }
  }
  return out;
}

/** FNV-1a 8 位十六进制(复用快照 checksum 的实现,截去 'fnv1a-' 前缀)。 */
function fnv8(text: string): string {
  return computeChecksum(text).substring('fnv1a-'.length);
}

/** 在 used 集合内取唯一 id:碰撞时追加 _2/_3…(确定性)。 */
function uniqueId(base: string, used: Set<string>): string {
  if (!used.has(base)) {
    used.add(base);
    return base;
  }
  let n = 2;
  let candidate = `${base}_${n}`;
  while (used.has(candidate)) {
    n++;
    candidate = `${base}_${n}`;
  }
  used.add(candidate);
  return candidate;
}

/**
 * 迁移中间产物(ID 分配/风险标记后的六份记录 + 映射表)。
 * 记录来自 JSON.parse 的新副本,改写不影响 Preferences。
 */
class PreparedContent {
  settings: Record<string, Object> = {};
  profiles: Array<Record<string, Object>> = [];
  groups: Array<Record<string, Object>> = [];
  subscriptions: Array<Record<string, Object>> = [];
  routeRules: Array<Record<string, Object>> = [];
  remoteRuleSets: Array<Record<string, Object>> = [];
  idMap: IdMapFile = new IdMapFile();
  riskSummary: string = '';
}

export class MigrationV5 {
  /**
   * 幂等迁移入口。任何路径都不抛异常、不清数据;失败返回 ok=false,
   * 旧 Preferences 数据原样保留(兼容读层继续工作)。
   * @param apiLevelOverride 测试/工具可显式传入 apiLevel(0=自动读取 deviceInfo,取不到按 23)
   */
  static async ensureMigrated(context: common.Context, apiLevelOverride: number = 0): Promise<MigrationResult> {
    const result = new MigrationResult();
    try {
      // (a) 已有活动快照 → 直接返回(§14.4-11 重复启动安全)
      if (ConfigRepository.hasActive()) {
        result.ok = true;
        result.skipped = true;
        result.revision = ConfigRepository.getActiveRevision();
        MigrationV5.fillCounts(result, ConfigRepository.getActive());
        LogStore.addLog(`[migration] v5 已迁移过(active r${result.revision}),跳过`);
        return result;
      }
      if (!ConfigRepository.isInitialized()) {
        // 兜底:调用方遗漏 init 时自行初始化(幂等,init 重复调用安全)
        await ConfigRepository.init(context);
      }
      const apiLevel = MigrationV5.resolveApiLevel(apiLevelOverride);
      // (b) 采集旧配置源快照(6 键原文) + 总 hash
      const sources = await MigrationV5.readSources();
      result.sourceHash = MigrationV5.hashSources(sources);
      LogStore.addLog(`[migration] 开始 v5 迁移: 源 hash=${result.sourceHash}`);
      // (c) 升级恢复点(只写一次,已有备份则复用)
      result.backupPath = MigrationV5.writeBackupOnce(context, sources, result.sourceHash);
      LogStore.addLog(`[migration] 升级恢复点: ${result.backupPath}`);
      // (d)+(e) 逐实体校验、稳定 ID、风险标记(全部基于解析后的副本,不改旧 Preferences)
      const prepared = MigrationV5.prepareContent(sources, result, apiLevel);
      if (prepared === null) {
        return await MigrationV5.failWith(context, result,
          result.error.length > 0 ? result.error : 'legacy_invalid');
      }
      // (f) 提交初始快照(commitInitial 幂等:已有活动快照时不重写)
      const content = new SnapshotContent();
      content.settings = prepared.settings;
      content.profiles = prepared.profiles;
      content.groups = prepared.groups;
      content.subscriptions = prepared.subscriptions;
      content.routeRules = prepared.routeRules;
      content.remoteRuleSets = prepared.remoteRuleSets;
      content.userOverrides = [];
      const idMap = prepared.idMap;
      idMap.createdAt = Date.now();
      idMap.sourceHash = result.sourceHash;
      result.idMapPath = MigrationV5.writeIdMap(context, idMap);
      const snap = await ConfigRepository.commitInitial(content);
      result.revision = snap.revision;
      // (g) 重读活动快照核对数量/引用,全部通过才算迁移完成
      const verifyIssue = MigrationV5.verifyCommitted(snap.revision, prepared);
      if (verifyIssue.length > 0) {
        return await MigrationV5.failWith(context, result, verifyIssue);
      }
      MigrationV5.fillCounts(result, snap);
      result.ok = true;
      MigrationV5.logSummary(result, prepared.riskSummary);
      await MigrationV5.persistDiagnostics(context, result, apiLevel);
      return result;
    } catch (e) {
      result.ok = false;
      result.error = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[migration] v5 迁移失败: ${result.error}`);
      try {
        await MigrationV5.persistDiagnostics(context, result, MigrationV5.resolveApiLevel(apiLevelOverride));
      } catch (inner) {
        // 诊断写入失败不能掩盖原始错误
      }
      return result;
    }
  }

  // ---- (b) 采集 ----

  private static async readSources(): Promise<LegacySources> {
    const s = new LegacySources();
    s.settings = await readPrefString('settings', '{}');
    s.profiles = await readPrefString('profiles', '[]');
    s.groups = await readPrefString('profile_groups', '[]');
    s.subscriptions = await readPrefString('subscriptions', '[]');
    s.routeRules = await readPrefString('route_rules', '[]');
    s.remoteRuleSets = await readPrefString('remote_rule_sets', '[]');
    return s;
  }

  private static hashSources(s: LegacySources): string {
    const joined = ['settings', s.settings, 'profiles', s.profiles, 'profile_groups', s.groups,
      'subscriptions', s.subscriptions, 'route_rules', s.routeRules,
      'remote_rule_sets', s.remoteRuleSets].join('\u0000');
    return computeChecksum(joined);
  }

  // ---- (c) 恢复点 ----

  /** 已有备份则复用(最早一个);否则写 pre-v5-backup-<ts>.json(6 键原文 + hash)。 */
  private static writeBackupOnce(context: common.Context, sources: LegacySources, hash: string): string {
    const dir = `${SnapshotStore.configDir(context)}/${MIGRATION_DIR_NAME}`;
    SnapshotStore.ensureDir(dir);
    const existing = SnapshotStore.listFiles(dir, BACKUP_PREFIX)
      .filter((n: string): boolean => n.endsWith(BACKUP_SUFFIX))
      .sort();
    if (existing.length > 0) {
      return `${dir}/${existing[0]}`;
    }
    const entries: Record<string, Object> = {};
    entries['settings'] = sources.settings;
    entries['profiles'] = sources.profiles;
    entries['profile_groups'] = sources.groups;
    entries['subscriptions'] = sources.subscriptions;
    entries['route_rules'] = sources.routeRules;
    entries['remote_rule_sets'] = sources.remoteRuleSets;
    const payload: Record<string, Object> = {};
    payload['schemaVersion'] = 4;
    payload['exportedAt'] = Date.now();
    payload['hash'] = hash;
    payload['source'] = 'preferences:nekobox_store';
    payload['entries'] = entries;
    const path = `${dir}/${BACKUP_PREFIX}${Date.now()}${BACKUP_SUFFIX}`;
    SnapshotStore.writeTextAtomic(path, JSON.stringify(payload));
    return path;
  }

  // ---- (d)(e) 校验/ID/风险 ----

  private static resolveApiLevel(override: number): number {
    if (override > 0) {
      return Math.floor(override);
    }
    try {
      const v: number = deviceInfo.sdkApiVersion;
      if (typeof v === 'number' && v > 0) {
        return Math.floor(v);
      }
    } catch (e) {
      // 取不到按 23(perAppLimitFor 兜底)
    }
    return 0;
  }

  private static prepareContent(sources: LegacySources, result: MigrationResult,
    apiLevel: number): PreparedContent | null {
    const settingsRec = parseRecord(sources.settings);
    if (settingsRec === null) {
      result.error = 'legacy_invalid:settings';
      return null;
    }
    const profilesArr = MigrationV5.parseArrayKey(sources.profiles, 'profiles', result);
    const groupsArr = MigrationV5.parseArrayKey(sources.groups, 'profile_groups', result);
    const subsArr = MigrationV5.parseArrayKey(sources.subscriptions, 'subscriptions', result);
    const rulesArr = MigrationV5.parseArrayKey(sources.routeRules, 'route_rules', result);
    const rsetsArr = MigrationV5.parseArrayKey(sources.remoteRuleSets, 'remote_rule_sets', result);
    if (profilesArr === null || groupsArr === null || subsArr === null || rulesArr === null || rsetsArr === null) {
      // result.error 已由 parseArrayKey 写明首个失败键
      return null;
    }
    const prepared = new PreparedContent();
    prepared.settings = settingsRec;
    prepared.profiles = profilesArr;
    prepared.groups = groupsArr;
    prepared.subscriptions = subsArr;
    prepared.routeRules = rulesArr;
    prepared.remoteRuleSets = rsetsArr;
    prepared.idMap = new IdMapFile();
    MigrationV5.assignProfileIds(prepared.profiles, result, prepared.idMap);
    MigrationV5.assignGroupIds(prepared.groups, result, prepared.idMap);
    MigrationV5.assignSubscriptionIds(prepared.subscriptions, prepared.idMap, result);
    MigrationV5.assignRuleIds(prepared.routeRules, prepared.idMap, result);
    MigrationV5.assignRemoteRuleSetIds(prepared.remoteRuleSets, prepared.idMap, result);
    MigrationV5.auditReferences(prepared, result);
    MigrationV5.analyzePerApp(settingsRec, perAppLimitFor(apiLevel), result);
    MigrationV5.markLegacyPackageRules(prepared.routeRules, result);
    prepared.riskSummary = MigrationV5.riskTypes(result.risks);
    return prepared;
  }

  /** 解析数组键:顶层非数组/JSON 失败 = 整体格式错误(中止,不覆盖不提交)。 */
  private static parseArrayKey(raw: string, key: string, result: MigrationResult): Array<Record<string, Object>> | null {
    const items = parseRecordArray(raw);
    if (items === null) {
      result.error = `legacy_invalid:${key}`;
      const issue = new MigrationIssue();
      issue.type = 'legacy_key_invalid';
      issue.key = key;
      issue.message = `旧数据键 ${key} 不是合法 JSON 数组,迁移中止(旧数据未改写)`;
      result.conflicts.push(issue);
      return null;
    }
    return asRecordArray(items, key, result.risks);
  }

  private static assignProfileIds(profiles: Array<Record<string, Object>>,
    result: MigrationResult, idMap: IdMapFile): void {
    const used = new Set<string>();
    const counts = new Map<string, number>();
    const namesById = new Map<string, Array<string>>();
    for (let i = 0; i < profiles.length; i++) {
      const id = strField(profiles[i], 'id');
      if (id.length === 0) {
        continue;
      }
      used.add(id);
      const seen = counts.get(id) ?? 0;
      counts.set(id, seen + 1);
      const name = strField(profiles[i], 'name');
      const bucket = namesById.get(id) ?? [];
      bucket.push(name);
      namesById.set(id, bucket);
    }
    for (let i = 0; i < profiles.length; i++) {
      const p = profiles[i];
      if (strField(p, 'id').length === 0) {
        // §14.4-3:空 id 生成确定性稳定 ID;内容指纹含全部身份字段,同内容碰撞时加序号
        const identity = ['p', strField(p, 'type'), strField(p, 'server'), strField(p, 'serverPort'),
          strField(p, 'uuid'), strField(p, 'name'), strField(p, 'transport'), strField(p, 'path'),
          strField(p, 'host'), strField(p, 'serviceName'), strField(p, 'sni'),
          strField(p, 'subUrl')].join('\u001f');
        p['id'] = uniqueId(`p_${fnv8(identity)}`, used);
      }
    }
    counts.forEach((count: number, id: string) => {
      if (count > 1) {
        // 既有 id 重复:保留原值不改写(§14.4-3「既有 ID 保留」),只记录冲突供用户处理
        const issue = new MigrationIssue();
        issue.type = 'duplicate_profile_id';
        issue.key = id;
        issue.index = -1;
        issue.count = count;
        issue.message = `既有节点 id 重复(保留原值未覆盖): ${id} ×${count}`;
        const names = namesById.get(id) ?? [];
        issue.detail = names.slice(0, 5).join(', ');
        result.conflicts.push(issue);
        idMap.profiles.conflicts.push(issue);
      }
    });
    // 同名节点信息标记(§19.3 同名节点;安卓按名称合并更新,属已知语义)
    const nameCounts = new Map<string, number>();
    for (let i = 0; i < profiles.length; i++) {
      const name = strField(profiles[i], 'name');
      if (name.length === 0) {
        continue;
      }
      nameCounts.set(name, (nameCounts.get(name) ?? 0) + 1);
    }
    nameCounts.forEach((count: number, name: string) => {
      if (count > 1) {
        const issue = new MigrationIssue();
        issue.type = 'duplicate_profile_name';
        issue.key = name;
        issue.message = `同名节点 ×${count}: ${name}(订阅更新按名称合并,保留原样)`;
        result.risks.push(issue);
      }
    });
  }

  private static assignGroupIds(groups: Array<Record<string, Object>>,
    result: MigrationResult, idMap: IdMapFile): void {
    const used = new Set<string>();
    const counts = new Map<string, number>();
    for (let i = 0; i < groups.length; i++) {
      const id = strField(groups[i], 'id');
      if (id.length === 0) {
        continue;
      }
      used.add(id);
      counts.set(id, (counts.get(id) ?? 0) + 1);
    }
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      if (strField(g, 'id').length === 0) {
        const identity = `grp\u001f${strField(g, 'name')}\u001f${i}`;
        g['id'] = uniqueId(`grp_${fnv8(identity)}`, used);
      }
    }
    counts.forEach((count: number, id: string) => {
      if (count > 1) {
        const issue = new MigrationIssue();
        issue.type = 'duplicate_group_id';
        issue.key = id;
        issue.message = `既有分组 id 重复(保留原值未覆盖): ${id} ×${count}`;
        result.conflicts.push(issue);
        idMap.groups.conflicts.push(issue);
      }
    });
    // 组身份=name(ensureGroupByName 语义):同名组会共享,记录供用户知晓
    const nameCounts = new Map<string, number>();
    for (let i = 0; i < groups.length; i++) {
      const name = strField(groups[i], 'name');
      if (name.length === 0) {
        continue;
      }
      nameCounts.set(name, (nameCounts.get(name) ?? 0) + 1);
    }
    nameCounts.forEach((count: number, name: string) => {
      if (count > 1) {
        const issue = new MigrationIssue();
        issue.type = 'duplicate_group_name';
        issue.key = name;
        issue.message = `同名分组 ×${count}: ${name}(既有语义按名称复用,保留原样)`;
        result.risks.push(issue);
      }
    });
  }

  private static assignSubscriptionIds(subs: Array<Record<string, Object>>, idMap: IdMapFile,
    result: MigrationResult): void {
    const urlCounts = new Map<string, number>();
    for (let i = 0; i < subs.length; i++) {
      const url = strField(subs[i], 'url');
      urlCounts.set(url, (urlCounts.get(url) ?? 0) + 1);
    }
    for (let i = 0; i < subs.length; i++) {
      const sub = subs[i];
      const url = strField(sub, 'url');
      // 身份=url(§14.2):同一 URL 的重复订阅共用同一来源 id;缺 url 用序号兜底保持可用
      const identity = url.length > 0 ? url : `__missing_url_${i}`;
      sub['id'] = `sub_${fnv8(identity)}`;
      const mapping = new SubscriptionIdMapping();
      mapping.oldUrl = url;
      mapping.newId = `${sub['id']}`;
      mapping.duplicate = (urlCounts.get(url) ?? 0) > 1;
      idMap.subscriptions.push(mapping);
      if (mapping.duplicate && result.conflicts.every((c: MigrationIssue): boolean =>
        !(c.type === 'duplicate_subscription_url' && c.key === url))) {
        const issue = new MigrationIssue();
        issue.type = 'duplicate_subscription_url';
        issue.key = url;
        issue.message = `重复订阅 URL ×${urlCounts.get(url) ?? 0}(同一来源身份,共用 id): ${url}`;
        result.conflicts.push(issue);
      }
      if (url.length === 0) {
        const issue = new MigrationIssue();
        issue.type = 'subscription_missing_url';
        issue.key = 'subscriptions';
        issue.index = i;
        issue.message = `订阅[${i}] 缺少 url,已用序号生成兜底 id`;
        result.risks.push(issue);
      }
    }
  }

  private static assignRuleIds(rules: Array<Record<string, Object>>, idMap: IdMapFile,
    result: MigrationResult): void {
    // 先收集既有非空 id,再为空 id 生成(避免生成值与后处理到的既有 id 撞名)
    const used = new Set<string>();
    for (let i = 0; i < rules.length; i++) {
      const id = strField(rules[i], 'id');
      if (id.length > 0) {
        used.add(id);
      }
    }
    for (let i = 0; i < rules.length; i++) {
      const rule = rules[i];
      if (strField(rule, 'id').length === 0) {
        // 确定性 id=index+内容指纹(§14.4-3 规则实体)
        const candidate = `rule_${i}_${fnv8(JSON.stringify(rule))}`;
        rule['id'] = uniqueId(candidate, used);
      }
      const mapping = new RuleIdMapping();
      mapping.index = i;
      mapping.id = strField(rule, 'id');
      idMap.routeRules.push(mapping);
    }
  }

  private static assignRemoteRuleSetIds(sets: Array<Record<string, Object>>, idMap: IdMapFile,
    result: MigrationResult): void {
    const used = new Set<string>();
    const urlCounts = new Map<string, number>();
    for (let i = 0; i < sets.length; i++) {
      const url = strField(sets[i], 'url');
      urlCounts.set(url, (urlCounts.get(url) ?? 0) + 1);
      const id = strField(sets[i], 'id');
      if (id.length > 0) {
        used.add(id);
      }
    }
    for (let i = 0; i < sets.length; i++) {
      const item = sets[i];
      if (strField(item, 'id').length === 0) {
        const url = strField(item, 'url');
        item['id'] = uniqueId(`rset_${fnv8(url)}`, used);
      }
      const mapping = new RemoteRuleSetIdMapping();
      mapping.oldUrl = strField(item, 'url');
      mapping.id = strField(item, 'id');
      idMap.remoteRuleSets.push(mapping);
      if ((urlCounts.get(mapping.oldUrl) ?? 0) > 1) {
        const issue = new MigrationIssue();
        issue.type = 'duplicate_ruleset_url';
        issue.key = mapping.oldUrl;
        issue.message = `重复规则集 URL ×${urlCounts.get(mapping.oldUrl) ?? 0}: ${mapping.oldUrl}`;
        result.conflicts.push(issue);
      }
    }
  }

  /** §8.5/§14.4-8:历史含 packages 的规则保留全部原文与启用状态,仅加 unsupportedOnPlatform 标记。 */
  private static markLegacyPackageRules(rules: Array<Record<string, Object>>, result: MigrationResult): void {
    for (let i = 0; i < rules.length; i++) {
      const rule = rules[i];
      const packages = strField(rule, 'packages');
      if (packages.length === 0) {
        continue;
      }
      rule['unsupportedOnPlatform'] = true;
      const issue = new MigrationIssue();
      issue.type = 'legacy_packages_rule';
      issue.key = 'route_rules';
      issue.index = i;
      issue.message = `规则[${i}] 含历史包名条件(保留原文,平台暂不生效): ${packages}`;
      issue.detail = `packagesEnabled=${boolField(rule, 'packagesEnabled', false)}, enabled=${boolField(rule, 'enabled', true)}`;
      result.risks.push(issue);
    }
  }

  /** 引用审计(只记录不改写):profile:<id> 出站/链/前置/分组归属是否可解析。 */
  private static auditReferences(prepared: PreparedContent, result: MigrationResult): void {
    const profileIds = new Set<string>();
    for (let i = 0; i < prepared.profiles.length; i++) {
      profileIds.add(strField(prepared.profiles[i], 'id'));
    }
    const groupIds = new Set<string>();
    for (let i = 0; i < prepared.groups.length; i++) {
      groupIds.add(strField(prepared.groups[i], 'id'));
    }
    const checkProfileRef = (ref: string, type: string, key: string, index: number): void => {
      if (ref.length === 0 || profileIds.has(ref)) {
        return;
      }
      const issue = new MigrationIssue();
      issue.type = type;
      issue.key = key;
      issue.index = index;
      issue.message = `引用的节点 id 不存在(保留原样): ${ref}`;
      result.risks.push(issue);
    };
    for (let i = 0; i < prepared.routeRules.length; i++) {
      const outbound = strField(prepared.routeRules[i], 'outbound');
      if (outbound.startsWith('profile:')) {
        checkProfileRef(outbound.substring('profile:'.length), 'dangling_profile_ref', 'route_rules', i);
      }
    }
    for (let i = 0; i < prepared.groups.length; i++) {
      const g = prepared.groups[i];
      checkProfileRef(strField(g, 'frontProxy'), 'dangling_group_proxy_ref', 'profile_groups', i);
      checkProfileRef(strField(g, 'landingProxy'), 'dangling_group_proxy_ref', 'profile_groups', i);
    }
    for (let i = 0; i < prepared.profiles.length; i++) {
      const p = prepared.profiles[i];
      const groupId = strField(p, 'groupId');
      if (groupId.length > 0 && !groupIds.has(groupId)) {
        const issue = new MigrationIssue();
        issue.type = 'dangling_group_ref';
        issue.key = 'profiles';
        issue.index = i;
        issue.message = `节点归属的分组 id 不存在(保留原样): ${groupId}`;
        result.risks.push(issue);
      }
      checkProfileRef(strField(p, 'dialerProxyId'), 'dangling_profile_ref', 'profiles', i);
      const chainIds = strField(p, 'chainIds');
      if (chainIds.length > 0) {
        const parts = chainIds.split(',');
        for (let j = 0; j < parts.length; j++) {
          checkProfileRef(parts[j].trim(), 'dangling_chain_ref', 'profiles', i);
        }
      }
    }
  }

  /** §8.2/§8.5/§14.4-7:分应用名单风险(只记录,不改设置)。 */
  private static analyzePerApp(settings: Record<string, Object>, limit: number, result: MigrationResult): void {
    const mode = normalizedPerAppMode(strField(settings, 'perAppMode'));
    const entriesRaw = strField(settings, 'perAppEntries');
    const legacyList = strField(settings, 'perAppList');
    const analyzed: Array<Record<string, Object>> = [];
    if (entriesRaw.trim().length > 0) {
      const items = parseRecordArray(entriesRaw);
      if (items === null) {
        const issue = new MigrationIssue();
        issue.type = 'per_app_entries_invalid';
        issue.key = 'settings.perAppEntries';
        issue.message = 'perAppEntries 不是合法 JSON 数组(首次读取时将由 Store 重新初始化,旧数据未改写)';
        result.risks.push(issue);
      } else {
        const recs = asRecordArray(items, 'settings.perAppEntries', result.risks);
        for (let i = 0; i < recs.length; i++) {
          analyzed.push(recs[i]);
        }
      }
    } else if (legacyList.trim().length > 0) {
      // 未初始化条目:与 Store.loadSettings 的旧 CSV 迁移口径一致(默认勾选)
      const parts = legacyList.split(/[\s,;]+/);
      for (let i = 0; i < parts.length; i++) {
        const name = normalizeBundleName(parts[i]);
        if (name.length === 0) {
          continue;
        }
        const entry: Record<string, Object> = {};
        entry['bundleName'] = name;
        entry['enabled'] = true;
        analyzed.push(entry);
      }
      const issue = new MigrationIssue();
      issue.type = 'per_app_entries_uninitialized';
      issue.key = 'settings.perAppEntries';
      issue.message = `perAppEntries 未初始化,名单来自旧 perAppList(${analyzed.length} 项);首次读取时将生成条目`;
      result.risks.push(issue);
    }
    const seen = new Set<string>();
    const duplicates: Array<string> = [];
    const illegal: Array<string> = [];
    let validEnabled = 0;
    for (let i = 0; i < analyzed.length; i++) {
      const entry = analyzed[i];
      const name = normalizeBundleName(strField(entry, 'bundleName'));
      if (name.length === 0) {
        continue;
      }
      if (seen.has(name)) {
        if (duplicates.indexOf(name) < 0) {
          duplicates.push(name);
        }
      } else {
        seen.add(name);
      }
      if (!isValidBundleName(name)) {
        if (illegal.indexOf(name) < 0) {
          illegal.push(name);
        }
        continue;
      }
      if (boolField(entry, 'enabled', true)) {
        validEnabled++;
      }
    }
    if (duplicates.length > 0) {
      const issue = new MigrationIssue();
      issue.type = 'per_app_duplicate_bundle';
      issue.key = 'settings.perAppEntries';
      issue.message = `分应用名单含重复包名 ×${duplicates.length}: ${duplicates.slice(0, 5).join(', ')}`;
      result.risks.push(issue);
    }
    if (illegal.length > 0) {
      const issue = new MigrationIssue();
      issue.type = 'per_app_invalid_bundle';
      issue.key = 'settings.perAppEntries';
      issue.message = `分应用名单含非法包名 ×${illegal.length}: ${illegal.slice(0, 5).join(', ')}`;
      result.risks.push(issue);
    }
    if (validEnabled > limit) {
      const issue = new MigrationIssue();
      issue.type = 'per_app_over_limit';
      issue.key = 'settings.perAppEntries';
      issue.message = `分应用生效名单 ${validEnabled} 超出平台上限 ${limit}(apiLevel ${limit === 256 ? '>=23' : '<23'})`;
      result.risks.push(issue);
    }
    if (mode === 'include' && validEnabled === 0) {
      const issue = new MigrationIssue();
      issue.type = 'per_app_include_empty';
      issue.key = 'settings.perAppMode';
      issue.message = '分应用为 include(仅这些应用走代理)但生效名单为空(§8.2:不改设置,仅记录待处理)';
      result.risks.push(issue);
    }
  }

  // ---- (f)(g) 提交与核对 ----

  /** 重读磁盘快照:数量一致、实体 id 全非空且(生成范围内)唯一才算成功。 */
  private static verifyCommitted(revision: number, prepared: PreparedContent): string {
    const reloaded = ConfigRepository.loadSnapshot(revision);
    if (reloaded === null) {
      return `verify_failed: snapshot r${revision} unreadable`;
    }
    const content = reloaded.content;
    if (content.profiles.length !== prepared.profiles.length ||
      content.groups.length !== prepared.groups.length ||
      content.subscriptions.length !== prepared.subscriptions.length ||
      content.routeRules.length !== prepared.routeRules.length ||
      content.remoteRuleSets.length !== prepared.remoteRuleSets.length) {
      return 'verify_failed: entity count mismatch after read-back';
    }
    const ids = new Set<string>();
    for (let i = 0; i < content.profiles.length; i++) {
      const id = strField(content.profiles[i], 'id');
      if (id.length === 0) {
        return `verify_failed: profile[${i}] empty id`;
      }
      if (ids.has(id)) {
        return `verify_failed: generated profile id duplicated: ${id}`;
      }
      ids.add(id);
    }
    const groupIds = new Set<string>();
    for (let i = 0; i < content.groups.length; i++) {
      const id = strField(content.groups[i], 'id');
      if (id.length === 0) {
        return `verify_failed: group[${i}] empty id`;
      }
      if (groupIds.has(id)) {
        return `verify_failed: generated group id duplicated: ${id}`;
      }
      groupIds.add(id);
    }
    for (let i = 0; i < content.subscriptions.length; i++) {
      if (strField(content.subscriptions[i], 'id').length === 0) {
        return `verify_failed: subscription[${i}] empty id`;
      }
    }
    for (let i = 0; i < content.routeRules.length; i++) {
      if (strField(content.routeRules[i], 'id').length === 0) {
        return `verify_failed: routeRule[${i}] empty id`;
      }
    }
    for (let i = 0; i < content.remoteRuleSets.length; i++) {
      if (strField(content.remoteRuleSets[i], 'id').length === 0) {
        return `verify_failed: remoteRuleSet[${i}] empty id`;
      }
    }
    return '';
  }

  private static fillCounts(result: MigrationResult, snapshot: ConfigSnapshot | null): void {
    if (snapshot === null) {
      return;
    }
    result.counts.profiles = snapshot.content.profiles.length;
    result.counts.groups = snapshot.content.groups.length;
    result.counts.subscriptions = snapshot.content.subscriptions.length;
    result.counts.routeRules = snapshot.content.routeRules.length;
    result.counts.remoteRuleSets = snapshot.content.remoteRuleSets.length;
  }

  private static riskTypes(risks: Array<MigrationIssue>): string {
    const types: Array<string> = [];
    for (let i = 0; i < risks.length; i++) {
      if (types.indexOf(risks[i].type) < 0) {
        types.push(risks[i].type);
      }
    }
    return types.join(',');
  }

  private static logSummary(result: MigrationResult, riskSummary: string): void {
    LogStore.addLog(`[migration] v5 迁移完成: r${result.revision}, 节点=${result.counts.profiles}, ` +
      `分组=${result.counts.groups}, 订阅=${result.counts.subscriptions}, 规则=${result.counts.routeRules}, ` +
      `规则集=${result.counts.remoteRuleSets}, 冲突=${result.conflicts.length}, 风险=${result.risks.length}` +
      (riskSummary.length > 0 ? ` [${riskSummary}]` : ''));
  }

  // ---- 诊断落盘(报告 + 完成标记),尽力而为 ----

  private static migrationDir(context: common.Context): string {
    return `${SnapshotStore.configDir(context)}/${MIGRATION_DIR_NAME}`;
  }

  private static writeIdMap(context: common.Context, idMap: IdMapFile): string {
    const dir = MigrationV5.migrationDir(context);
    SnapshotStore.ensureDir(dir);
    const path = `${dir}/${ID_MAP_FILE}`;
    SnapshotStore.writeTextAtomic(path, JSON.stringify(idMap));
    return path;
  }

  private static async persistDiagnostics(context: common.Context, result: MigrationResult,
    apiLevel: number): Promise<void> {
    const dir = MigrationV5.migrationDir(context);
    SnapshotStore.ensureDir(dir);
    const reportPath = `${dir}/${REPORT_FILE}`;
    const report: Record<string, Object> = {};
    report['schemaVersion'] = 5;
    report['createdAt'] = Date.now();
    report['ok'] = result.ok;
    report['skipped'] = result.skipped;
    report['revision'] = result.revision;
    report['error'] = result.error;
    report['sourceHash'] = result.sourceHash;
    report['backupPath'] = result.backupPath;
    report['idMapPath'] = result.idMapPath;
    report['apiLevelUsed'] = apiLevel;
    report['perAppLimit'] = perAppLimitFor(apiLevel);
    report['counts'] = result.counts;
    report['risks'] = result.risks;
    report['conflicts'] = result.conflicts;
    SnapshotStore.writeTextAtomic(reportPath, JSON.stringify(report));
    result.reportPath = reportPath;
    const marker: Record<string, Object> = {};
    marker['ok'] = result.ok;
    marker['skipped'] = result.skipped;
    marker['at'] = Date.now();
    marker['revision'] = result.revision;
    marker['sourceHash'] = result.sourceHash;
    marker['error'] = result.error;
    marker['backupPath'] = result.backupPath;
    marker['reportPath'] = result.reportPath;
    marker['idMapPath'] = result.idMapPath;
    marker['counts'] = result.counts;
    marker['conflictCount'] = result.conflicts.length;
    marker['riskCount'] = result.risks.length;
    await writePrefString(MIGRATION_MARKER_KEY, JSON.stringify(marker));
  }

  private static async failWith(context: common.Context, result: MigrationResult,
    code: string): Promise<MigrationResult> {
    result.ok = false;
    result.error = code;
    LogStore.addLog(`[migration] v5 迁移中止: ${code}(旧数据未改写,未提交快照)`);
    try {
      await MigrationV5.persistDiagnostics(context, result, 0);
    } catch (e) {
      // 诊断写入失败不能掩盖原始错误
    }
    return result;
  }
}
