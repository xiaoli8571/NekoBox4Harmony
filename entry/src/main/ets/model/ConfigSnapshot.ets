/**
 * 版本化不可变配置快照 —— REDESIGN-PLAN-2026-10-23.md §14.2/§14.3 的 ConfigSnapshot 实体与序列化。
 *
 * 设计要点：
 *  - 快照内容(content) = 现有 Preferences 六个业务键的 JSON 原样聚合(settings/profiles/
 *    profile_groups/subscriptions/route_rules/remote_rule_sets) + 新增 user_overrides(先空置，
 *    P5 订阅覆盖与 P2 检测结果有各自独立存储，不放这里)。
 *  - 未知未来键进 reserved 原样保留：旧代码提交新快照时不丢新版本字段(前向兼容)。
 *  - checksum 只覆盖 content 的规范化 JSON：元数据(createdAt 等)变化不改变内容指纹；
 *    写盘后必须重读并复核 checksum(§14.3-1/3)。
 *  - 本文件是纯函数/纯数据，不做任何 I/O，便于主机测试(tests/config-repository.cjs)。
 */

/** v5:首个快照 schema 版本。备份 schema(Backup.ets=4)与应用快照 schema 相互独立。 */
export const CONFIG_SCHEMA_VERSION: number = 5;

/** 支持读取的快照 schema 版本上限：未来未知版本必须明确拒绝，不得静默解析。 */
export const SUPPORTED_SCHEMA_MAX: number = CONFIG_SCHEMA_VERSION;

const KEY_SETTINGS: string = 'settings';
const KEY_PROFILES: string = 'profiles';
const KEY_GROUPS: string = 'profile_groups';
const KEY_SUBSCRIPTIONS: string = 'subscriptions';
const KEY_ROUTE_RULES: string = 'route_rules';
const KEY_REMOTE_RULE_SETS: string = 'remote_rule_sets';
const KEY_USER_OVERRIDES: string = 'user_overrides';

/** 快照内容：键名对齐 Preferences 既有键，值保持解析后的 JSON 结构。 */
export class SnapshotContent {
  settings: Record<string, Object> = {};
  profiles: Array<Record<string, Object>> = [];
  groups: Array<Record<string, Object>> = [];
  subscriptions: Array<Record<string, Object>> = [];
  routeRules: Array<Record<string, Object>> = [];
  remoteRuleSets: Array<Record<string, Object>> = [];
  userOverrides: Array<Record<string, Object>> = [];
  /** 本版本不认识的键：提交时原样回写(前向兼容，§14.3「读取者不混读」)。 */
  reserved: Record<string, Object> = {};
}

/** 一份不可变配置快照。 */
export class ConfigSnapshot {
  schemaVersion: number = CONFIG_SCHEMA_VERSION;
  revision: number = 0;
  parentRevision: number = -1;
  createdAt: number = 0;
  checksum: string = '';
  resourceManifestId: string = '';
  content: SnapshotContent = new SnapshotContent();
}

/** parseSnapshot 的结果：ok=false 时 error 带机器可读原因。 */
export class SnapshotParseResult {
  ok: boolean = false;
  error: string = '';
  snapshot: ConfigSnapshot | null = null;
}

function isRecord(value: Object | undefined): boolean {
  return value !== null && value !== undefined && typeof value === 'object' &&
    !Array.isArray(value);
}

function asRecordArray(value: Object | undefined): Array<Record<string, Object>> {
  const out: Array<Record<string, Object>> = [];
  if (value === undefined || value === null || !Array.isArray(value)) {
    return out;
  }
  const arr = value as Array<Object | undefined>;
  for (let i = 0; i < arr.length; i++) {
    const item: Object | undefined = arr[i];
    if (isRecord(item)) {
      out.push(item as Record<string, Object>);
    }
  }
  return out;
}

function asRecord(value: Object | undefined): Record<string, Object> {
  if (isRecord(value)) {
    return value as Record<string, Object>;
  }
  return {};
}

function isKnownContentKey(key: string): boolean {
  return key === KEY_SETTINGS || key === KEY_PROFILES || key === KEY_GROUPS ||
    key === KEY_SUBSCRIPTIONS || key === KEY_ROUTE_RULES || key === KEY_REMOTE_RULE_SETS ||
    key === KEY_USER_OVERRIDES;
}

/**
 * FNV-1a(32bit) 内容指纹。用途=损坏检测(MIG-02)，不是安全哈希；
 * 字符串按 UTF-16 code unit 计算保证跨平台确定性。
 */
export function computeChecksum(text: string): string {
  let hash: number = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash = (hash ^ text.charCodeAt(i)) >>> 0;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  let hex = hash.toString(16);
  while (hex.length < 8) {
    hex = `0${hex}`;
  }
  return `fnv1a-${hex}`;
}

/** 深拷贝内容(JSON 往返)。提交变更时基于副本改写，绝不原地改活动快照。 */
export function cloneContent(content: SnapshotContent): SnapshotContent {
  const json = contentToJson(content);
  return parseContent(JSON.parse(json) as Record<string, Object>);
}

/** 把内容对象序列化为**键序固定**的规范化 JSON(checksum 的输入)。 */
export function contentToJson(content: SnapshotContent): string {
  const parts: Array<string> = [];
  parts.push(`${JSON.stringify(KEY_SETTINGS)}:${JSON.stringify(content.settings)}`);
  parts.push(`${JSON.stringify(KEY_PROFILES)}:${JSON.stringify(content.profiles)}`);
  parts.push(`${JSON.stringify(KEY_GROUPS)}:${JSON.stringify(content.groups)}`);
  parts.push(`${JSON.stringify(KEY_SUBSCRIPTIONS)}:${JSON.stringify(content.subscriptions)}`);
  parts.push(`${JSON.stringify(KEY_ROUTE_RULES)}:${JSON.stringify(content.routeRules)}`);
  parts.push(`${JSON.stringify(KEY_REMOTE_RULE_SETS)}:${JSON.stringify(content.remoteRuleSets)}`);
  parts.push(`${JSON.stringify(KEY_USER_OVERRIDES)}:${JSON.stringify(content.userOverrides)}`);
  // reserved 键按插入顺序回写；与已知键同名则忽略(防覆盖已知结构)
  const keys: Array<string> = Object.keys(content.reserved);
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    if (isKnownContentKey(k)) {
      continue;
    }
    parts.push(`${JSON.stringify(k)}:${JSON.stringify(content.reserved[k])}`);
  }
  return `{${parts.join(',')}}`;
}

export function parseContent(raw: Record<string, Object>): SnapshotContent {
  const content = new SnapshotContent();
  content.settings = asRecord(raw[KEY_SETTINGS]);
  content.profiles = asRecordArray(raw[KEY_PROFILES]);
  content.groups = asRecordArray(raw[KEY_GROUPS]);
  content.subscriptions = asRecordArray(raw[KEY_SUBSCRIPTIONS]);
  content.routeRules = asRecordArray(raw[KEY_ROUTE_RULES]);
  content.remoteRuleSets = asRecordArray(raw[KEY_REMOTE_RULE_SETS]);
  content.userOverrides = asRecordArray(raw[KEY_USER_OVERRIDES]);
  const keys: Array<string> = Object.keys(raw);
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    if (!isKnownContentKey(k)) {
      content.reserved[k] = raw[k];
    }
  }
  return content;
}

export function buildSnapshot(revision: number, parentRevision: number,
  content: SnapshotContent, resourceManifestId: string = ''): ConfigSnapshot {
  const snap = new ConfigSnapshot();
  snap.revision = revision;
  snap.parentRevision = parentRevision;
  snap.createdAt = Date.now();
  snap.resourceManifestId = resourceManifestId;
  snap.content = content;
  snap.checksum = computeChecksum(contentToJson(content));
  return snap;
}

/** 序列化完整快照文件文本(元数据键序固定 + content 规范化 JSON)。 */
export function serializeSnapshot(snap: ConfigSnapshot): string {
  const metaParts: Array<string> = [];
  metaParts.push(`"schemaVersion":${snap.schemaVersion}`);
  metaParts.push(`"revision":${snap.revision}`);
  metaParts.push(`"parentRevision":${snap.parentRevision}`);
  metaParts.push(`"createdAt":${snap.createdAt}`);
  metaParts.push(`"checksum":${JSON.stringify(snap.checksum)}`);
  metaParts.push(`"resourceManifestId":${JSON.stringify(snap.resourceManifestId)}`);
  return `{${metaParts.join(',')},"content":${contentToJson(snap.content)}}`;
}

/**
 * 解析快照文件文本。任何失败(截断/格式错误/checksum 不符/未来版本)都返回 ok=false，
 * 由调用方决定回退策略；本函数不读文件、不抛异常。
 */
export function parseSnapshot(text: string): SnapshotParseResult {
  const result = new SnapshotParseResult();
  let parsed: Record<string, Object>;
  try {
    const value: Object = JSON.parse(text);
    if (!isRecord(value)) {
      result.error = 'snapshot_not_object';
      return result;
    }
    parsed = value as Record<string, Object>;
  } catch (e) {
    result.error = 'snapshot_json_invalid';
    return result;
  }
  const schemaVersion = Number(parsed['schemaVersion']);
  if (!(schemaVersion >= 1) || !Number.isFinite(schemaVersion)) {
    result.error = 'snapshot_schema_missing';
    return result;
  }
  if (schemaVersion > SUPPORTED_SCHEMA_MAX) {
    result.error = 'snapshot_schema_unsupported';
    return result;
  }
  const revision = Number(parsed['revision']);
  if (!(revision >= 1)) {
    result.error = 'snapshot_revision_missing';
    return result;
  }
  const rawContent = parsed['content'];
  if (!isRecord(rawContent)) {
    result.error = 'snapshot_content_missing';
    return result;
  }
  const content = parseContent(rawContent as Record<string, Object>);
  const checksum = computeChecksum(contentToJson(content));
  const declared = `${parsed['checksum']}`;
  if (declared.length > 0 && declared !== checksum) {
    result.error = 'snapshot_checksum_mismatch';
    return result;
  }
  const snap = new ConfigSnapshot();
  snap.schemaVersion = schemaVersion;
  snap.revision = revision;
  snap.parentRevision = Number(parsed['parentRevision'] ?? -1);
  snap.createdAt = Number(parsed['createdAt'] ?? 0);
  snap.checksum = declared.length > 0 ? declared : checksum;
  snap.resourceManifestId = `${parsed['resourceManifestId'] ?? ''}`;
  snap.content = content;
  result.ok = true;
  result.snapshot = snap;
  return result;
}
