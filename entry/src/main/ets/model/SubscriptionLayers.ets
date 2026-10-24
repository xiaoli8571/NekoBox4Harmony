import { Profile } from './Profile';
import { computeChecksum } from './ConfigSnapshot';

/**
 * 订阅三层数据模型 —— REDESIGN-PLAN-2026-10-23.md §11.4(P5/W17)。
 *
 * 三层职责:
 *  - SubscriptionSourceSnapshot(原始层):某次更新从订阅源解析出的节点原始记录,
 *    不可变、逐次留存(core/SubscriptionSourceStore 文件存储),编辑器绝不直接覆盖;
 *  - UserOverride(用户覆盖层):别名/收藏/排序/展示分组/显式传输字段覆盖 + 远端删除
 *    节点的墓碑记录(可恢复/可转手动),持久化在 ConfigSnapshot.content.userOverrides,
 *    写入口只经 core/ConfigRepository.commit;
 *  - EffectiveProfile(有效视图):source + override 的合并结果,只读派生不落盘。
 *
 * 身份规则(§11.4):优先来源提供的稳定标识(当前解析器都不提供)→ 退化为
 * 「订阅 URL + 规范化传输特征」指纹;**显示名不参与身份** —— 远端改名但传输特征
 * 不变 = 同一节点(保留覆盖),远端参数变 = 更新原始层并标注冲突。
 * 重复且无法唯一对应时产生冲突项,不把一个覆盖随机套给另一个节点。
 *
 * 本文件纯函数/纯数据:不做 I/O、不读 Preferences、不碰时间之外的平台能力,
 * 主机测试见 tests/subscription-layers.cjs。
 */

/** 身份指纹覆盖的传输字段(白名单,与 Profile 字段同名;刻意排除 name 与运行期字段)。 */
const IDENTITY_FIELDS: Array<string> = [
  'type', 'server', 'serverPort', 'method', 'password', 'ssPlugin', 'ssPluginOpts',
  'username', 'uuid', 'alterId', 'security', 'flow', 'packetEncoding',
  'transport', 'path', 'host', 'serviceName', 'wsEarlyData', 'wsEarlyDataHeaderName',
  'tls', 'sni', 'allowInsecure', 'alpn', 'fingerprint',
  'realityPublicKey', 'realityShortId', 'certificates', 'ech', 'echConfig',
  'upMbps', 'downMbps', 'obfs', 'serverPorts', 'hopInterval',
  'congestionControl', 'udpRelayMode', 'reduceRtt', 'disableSni',
  'localAddress', 'privateKey', 'peerPublicKey', 'preSharedKey', 'wgMtu', 'reserved',
  'sshAuthType', 'privateKeyPassphrase', 'hostKey', 'shadowtlsVersion',
  'mux', 'muxProtocol', 'muxMaxStreams', 'muxPadding',
  'extra', 'customOutbound', 'chainIds', 'dialerProxyName'
];

// ---------------- Layer 1: 原始层 ----------------

/** 原始层里的单个节点:身份键 + 源名称 + 传输字段白名单快照。 */
export class SourceNodeRecord {
  identityKey: string = '';
  sourceName: string = '';
  fields: Record<string, Object> = {};
}

/** 一次成功获取的订阅原始快照(不可变)。 */
export class SubscriptionSourceSnapshot {
  url: string = '';
  fetchedAt: number = 0;
  /** clash-yaml / singbox-json / share-links / unknown */
  format: string = 'unknown';
  etag: string = '';
  lastModified: string = '';
  /** 原始正文的 fnv1a 指纹(内容比对用,不是安全哈希)。 */
  contentHash: string = '';
  nodeCount: number = 0;
  nodes: Array<SourceNodeRecord> = [];
}

// ---------------- Layer 2: 用户覆盖层 ----------------

/** 单个传输字段覆盖(显式允许的字段才可覆盖;value 为字符串化存储)。 */
export class FieldOverride {
  field: string = '';
  value: string = '';
}

/** 一个节点的用户覆盖;deletedAt>0 为墓碑(远端已删除,保留可恢复)。 */
export class UserOverride {
  subscriptionUrl: string = '';
  identityKey: string = '';
  /** 用户别名(空 = 跟随订阅源名称)。 */
  alias: string = '';
  pinned: boolean = false;
  sortOrder: number = 0;
  displayGroupId: string = '';
  transportOverrides: Array<FieldOverride> = [];
  /** >0 = 墓碑创建时间(远端删除);0 = 活跃。 */
  deletedAt: number = 0;
  updatedAt: number = 0;
}

// ---------------- Layer 3: 有效视图 ----------------

/** 有效视图中的单个节点(只读派生)。 */
export class EffectiveProfile {
  identityKey: string = '';
  sourceName: string = '';
  effectiveName: string = '';
  pinned: boolean = false;
  sortOrder: number = 0;
  displayGroupId: string = '';
  hasOverride: boolean = false;
  /** 用户有传输覆盖且与源当前值不一致(§11.4 远端参数变更 + 覆盖冲突)。 */
  transportConflict: boolean = false;
  /** 墓碑态:不在当前有效订阅中(仅出现在覆盖恢复列表)。 */
  deleted: boolean = false;
}

/** 冲突记录(不猜测归属,§11.4/§24.1「覆盖身份无法匹配」)。 */
export class OverrideConflict {
  identityKey: string = '';
  /** duplicate_identity / transport_override_conflict */
  kind: string = '';
  message: string = '';
}

/** mergeEffective 的结果。 */
export class MergeOutcome {
  effective: Array<EffectiveProfile> = [];
  conflicts: Array<OverrideConflict> = [];
  /** 墓碑覆盖(源里不存在且 deletedAt>0)。 */
  tombstones: Array<UserOverride> = [];
  /** 本次从墓碑复活的 identityKey。 */
  revived: Array<string> = [];
  /** 没有对应源节点且未标墓碑的覆盖(调用方在提交时转墓碑)。 */
  unmatchedOverrides: Array<UserOverride> = [];
}

/** 两次原始快照之间的变化分类(§11.3 更新事务的「差异」输入)。 */
export class UpdateClassification {
  added: Array<string> = [];
  removed: Array<string> = [];
  /** 身份相同、源名称变化(远端改名)。 */
  renamed: Array<string> = [];
  /** 身份相同、传输特征变化(远端参数变更)。 */
  transportChanged: Array<string> = [];
  unchanged: number = 0;
  /** 远端参数变更且用户有传输覆盖 → 冲突标注(不自动覆盖用户值)。 */
  overrideConflicts: Array<string> = [];
}

/** mergeParsedIntoOwned 的结果(仓库提交段直接消费)。 */
export class MergeApplyResult {
  /** 本订阅合并后的全部节点(保留旧 id/运行期字段的优先)。 */
  kept: Array<Profile> = [];
  addedNames: Array<string> = [];
  updatedNames: Array<string> = [];
  deletedNames: Array<string> = [];
  /** 本订阅的全量覆盖记录(含新墓碑/复活清零),写回 content.userOverrides。 */
  nextOverrides: Array<UserOverride> = [];
  conflicts: Array<OverrideConflict> = [];
  /** Android changed 口径 = deleted + added + updated。 */
  changed: number = 0;
}

// ---------------- 身份与序列化 ----------------

function profileRecordOf(p: Profile): Record<string, Object> {
  // JSON 往返获得 Record 视图(ArkTS 禁止把类实例直接当 Record);
  // 与 Store.saveProfiles 的序列化同源,字段默认值齐全。
  return JSON.parse(JSON.stringify(p)) as Record<string, Object>;
}

/** 规范化传输特征串(身份输入;排除显示名与运行期字段)。 */
export function transportIdentityOf(p: Profile): string {
  const rec = profileRecordOf(p);
  const parts: Array<string> = [];
  for (let i = 0; i < IDENTITY_FIELDS.length; i++) {
    const f = IDENTITY_FIELDS[i];
    const v = rec[f];
    parts.push(`${f}=${v === undefined || v === null ? '' : `${v}`}`);
  }
  return parts.join('\u001f');
}

/** 节点身份键:订阅 URL + 传输特征指纹(显示名不参与)。 */
export function identityKeyOf(subscriptionUrl: string, p: Profile): string {
  const identity = `${subscriptionUrl}\u001e${transportIdentityOf(p)}`;
  return `sid_${computeChecksum(identity).substring(6)}`;
}

/** 源快照文件的目录键(fnv1a hex,路径安全)。 */
export function urlKeyOf(subscriptionUrl: string): string {
  return computeChecksum(subscriptionUrl).substring(6);
}

/** 由传输字段白名单重建 Profile(墓碑「转为手动节点」/恢复用)。 */
export function profileFromSourceNode(node: SourceNodeRecord): Profile {
  const p = new Profile();
  p.name = node.sourceName;
  const rec = node.fields;
  const keys = Object.keys(rec);
  const target = profileRecordOf(p);
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    if (IDENTITY_FIELDS.indexOf(k) >= 0) {
      target[k] = rec[k];
    }
  }
  // 白名单拷贝后整体灌回(JSON 往返等价于 fillFrom 的既有语义)
  const restored = JSON.parse(JSON.stringify(target)) as Record<string, Object>;
  const merged = profileFromRecord(new Profile(), restored);
  return merged;
}

function profileFromRecord(target: Profile, rec: Record<string, Object>): Profile {
  const out = profileRecordOf(target);
  const keys = Object.keys(rec);
  for (let i = 0; i < keys.length; i++) {
    const v = rec[keys[i]];
    if (v !== undefined && v !== null) {
      out[keys[i]] = v;
    }
  }
  return JSON.parse(JSON.stringify(out)) as Profile;
}

/** 原始层节点记录(由解析出的 Profile 构建SourceNodeRecord)。 */
export function sourceNodeOf(p: Profile): SourceNodeRecord {
  const rec = sourceFieldsOf(p);
  const node = new SourceNodeRecord();
  node.sourceName = p.name;
  node.fields = rec;
  return node;
}

function sourceFieldsOf(p: Profile): Record<string, Object> {
  const rec = profileRecordOf(p);
  const out: Record<string, Object> = {};
  for (let i = 0; i < IDENTITY_FIELDS.length; i++) {
    const f = IDENTITY_FIELDS[i];
    const v = rec[f];
    out[f] = v === undefined || v === null ? '' : v;
  }
  return out;
}

// ---------------- 源快照 JSON ----------------

export function sourceSnapshotToJson(snap: SubscriptionSourceSnapshot): string {
  const parts: Array<string> = [];
  parts.push(`"url":${JSON.stringify(snap.url)}`);
  parts.push(`"fetchedAt":${snap.fetchedAt}`);
  parts.push(`"format":${JSON.stringify(snap.format)}`);
  parts.push(`"etag":${JSON.stringify(snap.etag)}`);
  parts.push(`"lastModified":${JSON.stringify(snap.lastModified)}`);
  parts.push(`"contentHash":${JSON.stringify(snap.contentHash)}`);
  parts.push(`"nodeCount":${snap.nodeCount}`);
  const nodes: Array<string> = [];
  for (let i = 0; i < snap.nodes.length; i++) {
    const n = snap.nodes[i];
    nodes.push(`{"identityKey":${JSON.stringify(n.identityKey)},` +
      `"sourceName":${JSON.stringify(n.sourceName)},` +
      `"fields":${JSON.stringify(n.fields)}}`);
  }
  parts.push(`"nodes":[${nodes.join(',')}]`);
  return `{${parts.join(',')}}`;
}

export function parseSourceSnapshot(text: string): SubscriptionSourceSnapshot | null {
  try {
    const raw = JSON.parse(text) as Record<string, Object>;
    const snap = new SubscriptionSourceSnapshot();
    snap.url = `${raw['url'] ?? ''}`;
    snap.fetchedAt = Number(raw['fetchedAt'] ?? 0);
    snap.format = `${raw['format'] ?? 'unknown'}`;
    snap.etag = `${raw['etag'] ?? ''}`;
    snap.lastModified = `${raw['lastModified'] ?? ''}`;
    snap.contentHash = `${raw['contentHash'] ?? ''}`;
    snap.nodeCount = Number(raw['nodeCount'] ?? 0);
    const nodes = raw['nodes'];
    if (Array.isArray(nodes)) {
      const arr = nodes as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i] as Record<string, Object>;
        const n = new SourceNodeRecord();
        n.identityKey = `${item['identityKey'] ?? ''}`;
        n.sourceName = `${item['sourceName'] ?? ''}`;
        const fields = item['fields'];
        if (fields !== undefined && fields !== null && typeof fields === 'object' &&
          !Array.isArray(fields)) {
          n.fields = fields as Record<string, Object>;
        }
        if (n.identityKey.length > 0) {
          snap.nodes.push(n);
        }
      }
    }
    snap.nodeCount = snap.nodes.length;
    if (snap.url.length === 0 || !(snap.fetchedAt > 0)) {
      return null;
    }
    return snap;
  } catch (e) {
    return null;
  }
}

// ---------------- 覆盖层 JSON(白名单,ArkTS 安全) ----------------

const OVERRIDE_KEYS: Array<string> = ['subscriptionUrl', 'identityKey', 'alias', 'pinned',
  'sortOrder', 'displayGroupId', 'deletedAt', 'updatedAt'];

export function overrideToRecord(o: UserOverride): Record<string, Object> {
  const out: Record<string, Object> = {};
  out['subscriptionUrl'] = o.subscriptionUrl;
  out['identityKey'] = o.identityKey;
  out['alias'] = o.alias;
  out['pinned'] = o.pinned;
  out['sortOrder'] = o.sortOrder;
  out['displayGroupId'] = o.displayGroupId;
  out['deletedAt'] = o.deletedAt;
  out['updatedAt'] = o.updatedAt;
  if (o.transportOverrides.length > 0) {
    const list: Array<Record<string, Object>> = [];
    for (let i = 0; i < o.transportOverrides.length; i++) {
      const fo: Record<string, Object> = {
        'field': o.transportOverrides[i].field, 'value': o.transportOverrides[i].value
      };
      list.push(fo);
    }
    out['transportOverrides'] = list;
  }
  return out;
}

export function parseOverrideRecord(rec: Record<string, Object>): UserOverride | null {
  const o = new UserOverride();
  o.subscriptionUrl = `${rec['subscriptionUrl'] ?? ''}`;
  o.identityKey = `${rec['identityKey'] ?? ''}`;
  o.alias = `${rec['alias'] ?? ''}`;
  o.pinned = rec['pinned'] === true;
  o.sortOrder = Number(rec['sortOrder'] ?? 0);
  o.displayGroupId = `${rec['displayGroupId'] ?? ''}`;
  o.deletedAt = Number(rec['deletedAt'] ?? 0);
  o.updatedAt = Number(rec['updatedAt'] ?? 0);
  const tovers = rec['transportOverrides'];
  if (Array.isArray(tovers)) {
    const arr = tovers as Array<Object>;
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i] as Record<string, Object>;
      const fo = new FieldOverride();
      fo.field = `${item['field'] ?? ''}`;
      fo.value = `${item['value'] ?? ''}`;
      if (fo.field.length > 0 && IDENTITY_FIELDS.indexOf(fo.field) >= 0) {
        o.transportOverrides.push(fo);
      }
    }
  }
  if (o.subscriptionUrl.length === 0 || o.identityKey.length === 0) {
    return null;
  }
  return o;
}

/** 保留未知键(前向兼容):快照 content.userOverrides 里的未来字段原样带回。 */
export function overrideReservedKeys(rec: Record<string, Object>): Record<string, Object> {
  const out: Record<string, Object> = {};
  const keys = Object.keys(rec);
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    if (k !== 'transportOverrides' && OVERRIDE_KEYS.indexOf(k) < 0) {
      out[k] = rec[k];
    }
  }
  return out;
}

// ---------------- 合并:source + override → effective ----------------

export function mergeEffective(nodes: Array<SourceNodeRecord>, allOverrides: Array<UserOverride>,
  subscriptionUrl: string): MergeOutcome {
  const outcome = new MergeOutcome();
  const overrideByKey = new Map<string, UserOverride>();
  for (let i = 0; i < allOverrides.length; i++) {
    const o = allOverrides[i];
    if (o.subscriptionUrl === subscriptionUrl) {
      overrideByKey.set(o.identityKey, o);
    }
  }
  const seenIdentities = new Set<string>();
  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i];
    if (seenIdentities.has(node.identityKey)) {
      const conflict = new OverrideConflict();
      conflict.identityKey = node.identityKey;
      conflict.kind = 'duplicate_identity';
      conflict.message = `源内重复身份: ${node.sourceName}`;
      outcome.conflicts.push(conflict);
      continue;
    }
    seenIdentities.add(node.identityKey);
    const view = new EffectiveProfile();
    view.identityKey = node.identityKey;
    view.sourceName = node.sourceName;
    const ov = overrideByKey.get(node.identityKey);
    if (ov !== undefined) {
      if (ov.deletedAt > 0) {
        outcome.revived.push(node.identityKey);
      }
      view.effectiveName = ov.alias.length > 0 ? ov.alias : node.sourceName;
      view.pinned = ov.pinned;
      view.sortOrder = ov.sortOrder;
      view.displayGroupId = ov.displayGroupId;
      view.hasOverride = ov.alias.length > 0 || ov.pinned || ov.sortOrder > 0 ||
        ov.displayGroupId.length > 0 || ov.transportOverrides.length > 0;
      if (ov.transportOverrides.length > 0) {
        for (let j = 0; j < ov.transportOverrides.length; j++) {
          const fo = ov.transportOverrides[j];
          const current = node.fields[fo.field];
          if (current === undefined || `${current}` !== fo.value) {
            view.transportConflict = true;
          }
        }
      }
    } else {
      view.effectiveName = node.sourceName;
    }
    outcome.effective.push(view);
    overrideByKey.delete(node.identityKey);
  }
  // 剩余覆盖:墓碑原样保留;活跃但无源节点 → unmatched(调用方提交时转墓碑)
  overrideByKey.forEach((ov: UserOverride, key: string) => {
    if (ov.deletedAt > 0) {
      outcome.tombstones.push(ov);
    } else {
      outcome.unmatchedOverrides.push(ov);
    }
  });
  return outcome;
}

// ---------------- 变化分类 ----------------

function fieldsFingerprint(node: SourceNodeRecord): string {
  return JSON.stringify(node.fields);
}

export function classifyUpdate(prev: SubscriptionSourceSnapshot | null,
  next: SubscriptionSourceSnapshot, allOverrides: Array<UserOverride>,
  subscriptionUrl: string): UpdateClassification {
  const c = new UpdateClassification();
  const overrideByKey = new Map<string, UserOverride>();
  for (let i = 0; i < allOverrides.length; i++) {
    const o = allOverrides[i];
    if (o.subscriptionUrl === subscriptionUrl) {
      overrideByKey.set(o.identityKey, o);
    }
  }
  const prevByKey = new Map<string, SourceNodeRecord>();
  if (prev !== null) {
    for (let i = 0; i < prev.nodes.length; i++) {
      if (!prevByKey.has(prev.nodes[i].identityKey)) {
        prevByKey.set(prev.nodes[i].identityKey, prev.nodes[i]);
      }
    }
  }
  const nextKeys = new Set<string>();
  const unmatchedNext: Array<SourceNodeRecord> = [];
  for (let i = 0; i < next.nodes.length; i++) {
    const n = next.nodes[i];
    if (nextKeys.has(n.identityKey)) {
      continue;
    }
    nextKeys.add(n.identityKey);
    const old = prevByKey.get(n.identityKey);
    if (old === undefined) {
      unmatchedNext.push(n);
      continue;
    }
    if (old.sourceName !== n.sourceName) {
      c.renamed.push(n.identityKey);
    } else {
      c.unchanged++;
    }
  }
  const unmatchedPrev = new Map<string, SourceNodeRecord>();
  prevByKey.forEach((node: SourceNodeRecord, key: string) => {
    if (!nextKeys.has(key)) {
      unmatchedPrev.set(key, node);
    }
  });
  // 次级匹配(名称锚点):身份变了但源名称唯一对应 → 视为「远端参数变更」,
  // 覆盖随身份迁移;用户有传输覆盖时标注冲突(不自动覆盖用户值,§11.4)。
  const consumedPrev = new Set<string>();
  for (let i = 0; i < unmatchedNext.length; i++) {
    const n = unmatchedNext[i];
    let hitKey = '';
    let hitCount = 0;
    unmatchedPrev.forEach((p: SourceNodeRecord, key: string) => {
      if (consumedPrev.has(key)) {
        return;
      }
      if (p.sourceName === n.sourceName) {
        hitKey = key;
        hitCount++;
      }
    });
    if (hitCount === 1) {
      consumedPrev.add(hitKey);
      c.transportChanged.push(n.identityKey);
      const ov = overrideByKey.get(hitKey);
      if (ov !== undefined && ov.transportOverrides.length > 0) {
        c.overrideConflicts.push(n.identityKey);
      }
      continue;
    }
    if (hitCount > 1) {
      // 同名多个旧节点:无法唯一对应,按冲突处理(不随机套覆盖)
      c.added.push(n.identityKey);
      continue;
    }
    c.added.push(n.identityKey);
  }
  unmatchedPrev.forEach((node: SourceNodeRecord, key: string) => {
    if (!consumedPrev.has(key)) {
      c.removed.push(key);
    }
  });
  return c;
}

// ---------------- 墓碑/复活 ----------------

export function toTombstone(o: UserOverride, nowMs: number): UserOverride {
  const t = new UserOverride();
  t.subscriptionUrl = o.subscriptionUrl;
  t.identityKey = o.identityKey;
  t.alias = o.alias;
  t.pinned = o.pinned;
  t.sortOrder = o.sortOrder;
  t.displayGroupId = o.displayGroupId;
  t.transportOverrides = o.transportOverrides.slice();
  t.deletedAt = nowMs;
  t.updatedAt = nowMs;
  return t;
}

export function reviveOverride(o: UserOverride, nowMs: number): UserOverride {
  const r = new UserOverride();
  r.subscriptionUrl = o.subscriptionUrl;
  r.identityKey = o.identityKey;
  r.alias = o.alias;
  r.pinned = o.pinned;
  r.sortOrder = o.sortOrder;
  r.displayGroupId = o.displayGroupId;
  r.transportOverrides = o.transportOverrides.slice();
  r.deletedAt = 0;
  r.updatedAt = nowMs;
  return r;
}

// ---------------- 更新提交合并(parsed + owned → kept + 覆盖) ----------------

function sameProfileIdentity(a: Profile, b: Profile): boolean {
  return transportIdentityOf(a) === transportIdentityOf(b);
}

/**
 * 把解析结果合并进该订阅的现有节点 —— 两级匹配(§11.4):
 *  1) **身份键优先**(订阅 URL + 传输特征,显示名不参与):身份相同 = 同一节点,
 *     远端改名保留 id/覆盖;身份不同的进入下一级;
 *  2) **名称次级锚点**:旧节点与新节点源名称唯一对应 → 视为「远端参数变更」,
 *     保留旧 id/用户态并把覆盖迁移到新身份(用户有传输覆盖时记冲突,不自动覆盖);
 *     同名多对一 → 冲突,按新增/删除处理(不随机套覆盖);
 *  3) 均不匹配:新节点分配存储 id;旧节点远端删除 → 覆盖转墓碑(可恢复/转手动)。
 * 返回 kept(本订阅合并后全量)+ 差异名单 + 下一次的全量覆盖记录。
 */
export function mergeParsedIntoOwned(parsed: Array<Profile>, owned: Array<Profile>,
  allOverrides: Array<UserOverride>, url: string, subGroupId: string,
  storageIdOf: (p: Profile, url: string) => string,
  nowMs: number): MergeApplyResult {
  const result = new MergeApplyResult();
  const overrideByKey = new Map<string, UserOverride>();
  for (let i = 0; i < allOverrides.length; i++) {
    const o = allOverrides[i];
    if (o.subscriptionUrl === url) {
      overrideByKey.set(o.identityKey, o);
    }
  }
  // owned 按身份索引(重复身份 → 冲突记录,取首个,不随机套)
  const ownedByKey = new Map<string, Profile>();
  for (let i = 0; i < owned.length; i++) {
    const key = identityKeyOf(url, owned[i]);
    if (ownedByKey.has(key)) {
      const conflict = new OverrideConflict();
      conflict.identityKey = key;
      conflict.kind = 'duplicate_identity';
      conflict.message = `本地重复身份(保留首个): ${owned[i].name}`;
      result.conflicts.push(conflict);
      continue;
    }
    ownedByKey.set(key, owned[i]);
  }
  const matchedOldIds = new Set<string>();
  const nextKeys = new Set<string>();
  const pendingParsed: Array<Profile> = [];
  let nextOrder = 1;
  // ---- 第一级:身份键匹配 ----
  for (let i = 0; i < parsed.length; i++) {
    const bean = parsed[i];
    const key = identityKeyOf(url, bean);
    if (nextKeys.has(key)) {
      const conflict = new OverrideConflict();
      conflict.identityKey = key;
      conflict.kind = 'duplicate_identity';
      conflict.message = `源内重复身份(取首个): ${bean.name}`;
      result.conflicts.push(conflict);
      continue;
    }
    nextKeys.add(key);
    const old = ownedByKey.get(key);
    if (old !== undefined) {
      matchedOldIds.add(old.id);
      applyMatched(bean, old, overrideByKey.get(key) ?? null, url, subGroupId,
        nextOrder, nowMs, false, result);
      result.kept.push(bean);
    } else {
      pendingParsed.push(bean);
    }
    nextOrder++;
  }
  // ---- 第二级:名称锚点(远端参数变更:身份变了但名称唯一对应) ----
  const unmatchedOld = new Map<string, Profile>();
  ownedByKey.forEach((old: Profile, key: string) => {
    if (!matchedOldIds.has(old.id) && !nextKeys.has(key)) {
      unmatchedOld.set(key, old);
    }
  });
  const consumedOldKeys = new Set<string>();
  for (let i = 0; i < pendingParsed.length; i++) {
    const bean = pendingParsed[i];
    const key = identityKeyOf(url, bean);
    let hitKey = '';
    let hitOld: Profile | null = null;
    let hitCount = 0;
    unmatchedOld.forEach((old: Profile, okey: string) => {
      if (consumedOldKeys.has(okey) || old.name !== bean.name) {
        return;
      }
      hitKey = okey;
      hitOld = old;
      hitCount++;
    });
    if (hitCount === 1 && hitOld !== null) {
      const old = hitOld as Profile;
      consumedOldKeys.add(hitKey);
      matchedOldIds.add(old.id);
      // 覆盖迁移:旧身份覆盖(别名/收藏/排序)跟到新身份;传输覆盖记冲突不自动套
      const oldOv = overrideByKey.get(hitKey);
      if (oldOv !== undefined) {
        overrideByKey.set(key, migrateOverride(oldOv, key, nowMs));
        overrideByKey.delete(hitKey);
      }
      applyMatched(bean, old, overrideByKey.get(key) ?? null, url, subGroupId,
        nextOrder, nowMs, true, result);
      result.kept.push(bean);
      if (oldOv !== undefined && oldOv.transportOverrides.length > 0) {
        const conflict = new OverrideConflict();
        conflict.identityKey = key;
        conflict.kind = 'transport_override_conflict';
        conflict.message = `远端参数变更且用户有传输覆盖: ${bean.name}(用户值保留待裁决)`;
        result.conflicts.push(conflict);
      }
    } else {
      if (hitCount > 1) {
        const conflict = new OverrideConflict();
        conflict.identityKey = key;
        conflict.kind = 'duplicate_identity';
        conflict.message = `同名多个旧节点,无法唯一对应(按新增处理): ${bean.name}`;
        result.conflicts.push(conflict);
      }
      bean.id = storageIdOf(bean, url);
      bean.subUrl = url;
      bean.groupId = subGroupId;
      // 既有覆盖(含墓碑复活)跟人走:别名/收藏/排序恢复,不让复活节点丢用户态
      const priorOv = overrideByKey.get(key);
      if (priorOv !== undefined) {
        bean.pinned = priorOv.pinned;
        bean.sortOrder = priorOv.sortOrder > 0 ? priorOv.sortOrder : nextOrder;
        if (priorOv.alias.length > 0) {
          bean.name = priorOv.alias;
        }
        if (priorOv.deletedAt > 0) {
          overrideByKey.set(key, reviveOverride(priorOv, nowMs));
        }
      } else {
        bean.pinned = false;
        bean.sortOrder = nextOrder;
      }
      bean.updatedAt = nowMs;
      result.kept.push(bean);
      result.addedNames.push(bean.name);
    }
    nextOrder++;
  }
  // ---- 远端删除:转墓碑(保留覆盖字段以便恢复/转手动) ----
  ownedByKey.forEach((old: Profile, key: string) => {
    if (matchedOldIds.has(old.id) || nextKeys.has(key)) {
      return;
    }
    result.deletedNames.push(old.name);
    const base = overrideByKey.get(key);
    const tombstone = new UserOverride();
    tombstone.subscriptionUrl = url;
    tombstone.identityKey = key;
    tombstone.alias = base !== undefined ? base.alias : '';
    tombstone.pinned = base !== undefined ? base.pinned : old.pinned;
    tombstone.sortOrder = base !== undefined ? base.sortOrder : old.sortOrder;
    tombstone.displayGroupId = base !== undefined && base.displayGroupId.length > 0
      ? base.displayGroupId : old.groupId;
    tombstone.transportOverrides = base !== undefined ? base.transportOverrides.slice() : [];
    tombstone.deletedAt = nowMs;
    tombstone.updatedAt = nowMs;
    overrideByKey.set(key, tombstone);
  });
  // ---- 生成本订阅下一次的全量覆盖(墓碑保留;活跃节点回填当前用户态) ----
  const nextOverrides: Array<UserOverride> = [];
  overrideByKey.forEach((ov: UserOverride, key: string) => {
    if (!nextKeys.has(key)) {
      nextOverrides.push(ov); // 墓碑(含旧身份迁移后的残迹,已在 migrate 时清理)
    }
  });
  for (let i = 0; i < result.kept.length; i++) {
    const p = result.kept[i];
    const key = identityKeyOf(url, p);
    const prev = overrideByKey.get(key);
    const next = new UserOverride();
    next.subscriptionUrl = url;
    next.identityKey = key;
    next.alias = prev !== undefined ? prev.alias : '';
    next.pinned = p.pinned;
    next.sortOrder = p.sortOrder;
    next.displayGroupId = prev !== undefined ? prev.displayGroupId : '';
    next.transportOverrides = prev !== undefined ? prev.transportOverrides.slice() : [];
    next.deletedAt = 0;
    next.updatedAt = nowMs;
    nextOverrides.push(next);
  }
  result.nextOverrides = nextOverrides;
  result.changed = result.deletedNames.length + result.addedNames.length + result.updatedNames.length;
  return result;
}

/** 单个「已匹配」节点的合并落地:保留旧 id/运行期字段,名称取 别名>源名。 */
function applyMatched(bean: Profile, old: Profile, ov: UserOverride | null, url: string,
  subGroupId: string, fallbackOrder: number, nowMs: number, viaNameAnchor: boolean,
  result: MergeApplyResult): void {
  // 解析侧继承既有自定义配置(customOutbound/extra 跟人走,与原按名合并一致)
  if (old.customOutbound.length > 0) {
    bean.customOutbound = old.customOutbound;
  }
  if (old.extra.length > 0) {
    bean.extra = old.extra;
  }
  const alias = ov !== null && ov.alias.length > 0 ? ov.alias : '';
  const finalName = alias.length > 0 ? alias : bean.name;
  const identitySame = sameProfileIdentity(bean, old);
  const nameChanged = old.name !== finalName;
  bean.id = old.id;
  bean.subUrl = url;
  bean.groupId = subGroupId.length > 0 ? subGroupId : old.groupId;
  bean.sortOrder = old.sortOrder > 0 ? old.sortOrder : fallbackOrder;
  bean.pinned = ov !== null ? ov.pinned : old.pinned;
  bean.rx = old.rx;
  bean.tx = old.tx;
  bean.latencyMs = old.latencyMs;
  bean.status = old.status;
  bean.ping = old.ping;
  bean.error = old.error;
  bean.latencyTestedAt = old.latencyTestedAt;
  bean.updatedAt = nowMs;
  bean.name = finalName;
  if (!identitySame || nameChanged) {
    result.updatedNames.push(bean.name);
  }
}

/** 覆盖迁移到新身份(远端参数变更):保留用户字段,传输覆盖迁走待裁决。 */
function migrateOverride(oldOv: UserOverride, newKey: string, nowMs: number): UserOverride {
  const next = new UserOverride();
  next.subscriptionUrl = oldOv.subscriptionUrl;
  next.identityKey = newKey;
  next.alias = oldOv.alias;
  next.pinned = oldOv.pinned;
  next.sortOrder = oldOv.sortOrder;
  next.displayGroupId = oldOv.displayGroupId;
  next.transportOverrides = oldOv.transportOverrides.slice();
  next.deletedAt = 0;
  next.updatedAt = nowMs;
  return next;
}
