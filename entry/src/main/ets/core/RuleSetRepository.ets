import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import common from '@ohos.app.ability.common';
import { SnapshotStore } from './SnapshotStore';
import { LogStore } from '../model/Store';
import { errText } from '../utils/ErrText';
import {
  ResourceValidator, ResourceValidation,
  ENGINE_KERNEL, ENGINE_UNSUPPORTED, ENGINE_FORMAT_ONLY,
  FORMAT_BINARY_SRS, FORMAT_SOURCE_JSON,
  MAX_RESOURCE_BYTES, looksLikeBinarySrs, declaredFormatFromUrl, versionFileExtension, sha256Hex
} from './ResourceValidator';

/**
 * 规则集资源仓库 —— REDESIGN-PLAN-2026-10-23.md §7.5(下载与缓存)、§14.2 RuleSetResource、
 * §14.3-3/8(版本化 + GC 引用保护)、§16.3 K1(能力不可用不标「已验证」)。
 *
 * 磁盘布局(应用私有目录，与 :vpn 扩展共享 filesDir)：
 *   <filesDir>/config/resources/
 *     manifest.json                ← 清单，用 SnapshotStore.writeTextAtomic 写 + 读回校验
 *     <id>/<hash>.srs              ← 版本化不可变内容(content-addressed)
 *     <id>/download-<ts>.tmp       ← 下载临时文件(任何失败都删除)
 *
 * 下载流程(严格顺序，任何一步失败都不替换旧缓存)：
 *   URL 校验 → 下载到 <id>/download-<ts>.tmp → HTTP 2xx → 声明/实际大小(≤32MiB)
 *   → 格式校验 → 内核验证(K1，可注入) → SHA-256 → 移入版本目录 → 提交清单(原子写+读回) → GC
 *
 * 失败策略(§7.5 表格)：
 *   - 首次失败且无缓存       → available=false，调用方阻止新配置应用(默认 failurePolicy='block')
 *   - 更新失败但有已验证缓存 → available=true/fromCache=true，暴露缓存时间与错误文本
 *   - 200 但内容损坏         → 不替换缓存、记验证失败
 *   - 缓存丢失/清单损坏     → 按无缓存处理，重新下载(绝不信任没有清单记录的文件)
 *   - 用户暂停规则集         → 是本实体 enabled/策略变更，**不在下载失败时自动暂停**
 *
 * 能力不可用(当前冻结 .so 没有 CGoValidateSRSFileV1)时：资源可以作为候选落盘，
 * 但 validatedAt 恒为 0、verified=false、state='unverified'；默认策略下 available=false，
 * 只有用户显式把 failurePolicy 改成 'allow-unverified' 才允许调用方引用未验证候选(§16.3)。
 *
 * 未接线(留给后续工作包，见各方法注释)：NAPI/CoreManager 的 SRS 验证桥接(W05)、
 * 页面/ConfigBuilder 消费本仓库(P4/P1)。本文件不引用 CoreManager，以便主机测试注入。
 */

const RESOURCES_DIR_NAME: string = 'resources';
const MANIFEST_FILE_NAME: string = 'manifest.json';
const MANIFEST_SCHEMA_VERSION: number = 1;

/** §7.5 规划初值：连接 10s / 读取 30s / 单文件 32MiB / 总缓存 256MiB。 */
const CONNECT_TIMEOUT_MS: number = 10000;
const READ_TIMEOUT_MS: number = 30000;
const MAX_TOTAL_BYTES: number = 256 * 1024 * 1024;
/** 每个资源保留 current + previous 两个版本(§7.5「按 hash 保留最近两个已验证版本」)。 */
const KEEP_VERSIONS: number = 2;
const MAX_URL_LENGTH: number = 2048;
const MAX_ID_LENGTH: number = 64;

export const FAILURE_POLICY_BLOCK: string = 'block';
export const FAILURE_POLICY_ALLOW_UNVERIFIED: string = 'allow-unverified';

export const REASON_DOWNLOADED: string = 'downloaded-verified';
export const REASON_CACHE_HIT: string = 'cache-hit';
export const REASON_UPDATE_FAILED: string = 'update-failed-using-cache';
export const REASON_NO_CACHE: string = 'no-cache';
export const REASON_CACHE_MISSING: string = 'cache-missing';
export const REASON_MANIFEST_CORRUPT: string = 'manifest-corrupt';
export const REASON_UNVERIFIED_CANDIDATE: string = 'unverified-candidate';

export const STATE_READY: string = 'ready';
export const STATE_UNVERIFIED: string = 'unverified';
export const STATE_UNAVAILABLE: string = 'unavailable';

/** 一个已落盘的资源版本。validatedAt=0 表示「未经内核验证」(候选)。 */
export class ResourceVersion {
  hash: string = '';
  /** 版本目录内的文件名(<hash>.srs / <hash>.json)。 */
  file: string = '';
  sizeBytes: number = 0;
  /** 内核验证通过的时间；0 = 未验证(不标「已验证」)。 */
  validatedAt: number = 0;
  downloadedAt: number = 0;
  /** 验证来源：'kernel-k1' | 'unsupported' | 'format-only' | 'failed'(§16.3 范围说明)。 */
  engine: string = '';
}

/** §14.2 RuleSetResource 的投影。 */
export class RuleSetResource {
  id: string = '';
  sourceUrl: string = '';
  /** 'binary-srs' | 'source-json' */
  format: string = FORMAT_BINARY_SRS;
  currentHash: string = '';
  versions: Array<ResourceVersion> = [];
  lastAttemptAt: number = 0;
  lastSuccessfulDownloadAt: number = 0;
  /** 当前版本的验证时间；0 = 未验证。 */
  validatedAt: number = 0;
  lastError: string = '';
  /** 'block'(默认) | 'allow-unverified'；用户显式修改才变，下载失败不自动改。 */
  failurePolicy: string = FAILURE_POLICY_BLOCK;
}

/** 资源清单(resources/manifest.json)。 */
export class RuleSetManifest {
  schemaVersion: number = MANIFEST_SCHEMA_VERSION;
  updatedAt: number = 0;
  resources: Record<string, RuleSetResource> = {};
}

/** 下载请求。fetcher 负责把响应体写到 targetPath —— 仓库只做边界检查与提交。 */
export class DownloadRequest {
  url: string = '';
  targetPath: string = '';
  maxBytes: number = MAX_RESOURCE_BYTES;
  connectTimeoutMs: number = CONNECT_TIMEOUT_MS;
  readTimeoutMs: number = READ_TIMEOUT_MS;
  /** 调用方声明的目标格式，便于 fetcher 侧提前拒绝明显类型不符。 */
  expectedFormat: string = FORMAT_BINARY_SRS;
}

/** 下载结果。error 非空 = 传输层失败；statusCode 非 2xx 也按失败处理。 */
export class DownloadResult {
  ok: boolean = false;
  statusCode: number = 0;
  /** Content-Length；-1 = 未知。 */
  declaredBytes: number = -1;
  /** 实际写入 targetPath 的字节数。 */
  bytesWritten: number = 0;
  error: string = '';
}

/**
 * 下载器注入点。默认实现直接报错(未接线)，生产用 HttpResourceFetcher(下方)；
 * 主机测试注入内存桩，永远不联网。
 */
export class ResourceFetcher {
  async fetch(request: DownloadRequest): Promise<DownloadResult> {
    const out = new DownloadResult();
    out.error = '未配置资源下载器(RuleSetRepository.setFetcher 未调用)';
    return out;
  }
}

/**
 * 生产下载器：@ohos.net.http GET → 写临时文件。超时/大小上限来自 DownloadRequest(§7.5 有界)。
 * 不在本层做格式/验证判断(那是仓库的职责)，但会在超限时**不写盘**直接失败。
 */
export class HttpResourceFetcher extends ResourceFetcher {
  async fetch(request: DownloadRequest): Promise<DownloadResult> {
    const out = new DownloadResult();
    const client = http.createHttp();
    try {
      const response = await client.request(request.url, {
        method: http.RequestMethod.GET,
        connectTimeout: request.connectTimeoutMs,
        readTimeout: request.readTimeoutMs,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      out.statusCode = response.responseCode;
      let declared = -1;
      try {
        const header = response.header as Record<string, Object>;
        if (header !== undefined && header !== null) {
          const raw = header['content-length'];
          if (raw !== undefined && raw !== null) {
            declared = Number(raw);
          }
        }
      } catch (e) {
        declared = -1;
      }
      out.declaredBytes = Number.isFinite(declared) ? declared : -1;
      if (out.statusCode < 200 || out.statusCode >= 300) {
        out.error = '';
        return out;
      }
      const data = response.result as ArrayBuffer;
      if (data === undefined || data === null) {
        out.error = '下载响应体为空';
        return out;
      }
      out.bytesWritten = data.byteLength;
      if (data.byteLength > request.maxBytes) {
        out.error = `响应体超过单文件上限(${data.byteLength} > ${request.maxBytes} 字节)`;
        return out;
      }
      const file = fs.openSync(request.targetPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, data);
      } finally {
        fs.closeSync(file);
      }
      out.ok = true;
      return out;
    } catch (e) {
      out.error = `下载失败: ${errText(e)}`;
      return out;
    } finally {
      client.destroy();
    }
  }
}

/**
 * 可用性结论(§7.5 表格的机器可读投影)。调用方不要再自行推断：
 *  - available = 现在能否把这个资源交给配置编译器(策略感知)；
 *  - verified  = 是否经内核 K1 完整校验(唯一可以标「已验证」的依据)；
 *  - reason / rejected / error 分别回答「为何可用/不可用」「被哪一步拒绝」「原始错误文本」。
 */
export class ResourceAvailability {
  available: boolean = false;
  fromCache: boolean = false;
  verified: boolean = false;
  /** 'ready' | 'unverified' | 'unavailable' */
  state: string = STATE_UNAVAILABLE;
  currentHash: string = '';
  /** 当前版本下载成功时间(用于界面显示「缓存时间」)。 */
  cachedAt: number = 0;
  error: string = '';
  reason: string = REASON_NO_CACHE;
  /** '' | invalid-id | invalid-url | no-fetcher | http-status | too-large | empty |
   *  truncated | format-mismatch | validation-failed | cache-limit | commit-failed | io-error */
  rejected: string = '';
  failurePolicy: string = FAILURE_POLICY_BLOCK;
}

// ---- 纯工具函数 ----

function isRecord(value: Object): boolean {
  return value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value);
}

/** 8 位 hex 的 FNV-1a：只用于把含非法字符的资源 ID 映射成稳定目录名。 */
function fnv1aHex(text: string): string {
  let hash: number = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    hash = (hash ^ text.charCodeAt(i)) >>> 0;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  let hex = hash.toString(16);
  while (hex.length < 8) {
    hex = `0${hex}`;
  }
  return hex;
}

/**
 * 资源 ID → 目录名。**安全边界**：ID 来自用户导入/订阅,绝不能直接拼路径。
 * 合法([A-Za-z0-9] 开头，仅 A-Za-z0-9._-)时原样使用；否则替换非法字符并追加 ID 指纹，
 * 保证「不含 / 与 ..、长度有界、不同原始 ID 不碰撞」。空/全非法 → ''(调用方拒绝)。
 */
export function sanitizeResourceId(raw: string): string {
  const id = raw === null || raw === undefined ? '' : `${raw}`.trim();
  if (id.length === 0) {
    return '';
  }
  const safe = id.length <= MAX_ID_LENGTH && /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id);
  if (safe) {
    return id;
  }
  let out = '';
  const limit = id.length < 36 ? id.length : 36;
  for (let i = 0; i < limit; i++) {
    const ch = id.charAt(i);
    // 非法 ID 一律只保留 [A-Za-z0-9_-]：连 '.' 也替换掉，保证结果里不可能出现 '..' 或前导 '.'
    out += /[A-Za-z0-9_-]/.test(ch) ? ch : '_';
  }
  if (out.length === 0) {
    out = '_';
  }
  return `${out}-${fnv1aHex(id)}`;
}

/** 失败策略只接受两个显式值；未知值不静默接受(策略字段是用户意图记录)。 */
export function isValidFailurePolicy(policy: string): boolean {
  return policy === FAILURE_POLICY_BLOCK || policy === FAILURE_POLICY_ALLOW_UNVERIFIED;
}

// ---- 清单解析(容错：损坏/未来版本都不得让进程崩) ----

function parseVersion(raw: Object): ResourceVersion | null {
  if (!isRecord(raw)) {
    return null;
  }
  const rec = raw as Record<string, Object>;
  const hash = `${rec['hash'] ?? ''}`;
  const file = `${rec['file'] ?? ''}`;
  if (hash.length === 0 || file.length === 0 || file.indexOf('/') >= 0 || file.indexOf('..') >= 0) {
    return null;
  }
  const version = new ResourceVersion();
  version.hash = hash;
  version.file = file;
  version.sizeBytes = Number(rec['sizeBytes'] ?? 0);
  version.validatedAt = Number(rec['validatedAt'] ?? 0);
  version.downloadedAt = Number(rec['downloadedAt'] ?? 0);
  version.engine = `${rec['engine'] ?? ''}`;
  return version;
}

function parseResource(id: string, raw: Object): RuleSetResource | null {
  if (!isRecord(raw) || id.length === 0) {
    return null;
  }
  const rec = raw as Record<string, Object>;
  const entity = new RuleSetResource();
  entity.id = id;
  entity.sourceUrl = `${rec['sourceUrl'] ?? ''}`;
  const format = `${rec['format'] ?? ''}`;
  entity.format = format === FORMAT_SOURCE_JSON ? FORMAT_SOURCE_JSON : FORMAT_BINARY_SRS;
  entity.currentHash = `${rec['currentHash'] ?? ''}`;
  entity.lastAttemptAt = Number(rec['lastAttemptAt'] ?? 0);
  entity.lastSuccessfulDownloadAt = Number(rec['lastSuccessfulDownloadAt'] ?? 0);
  entity.validatedAt = Number(rec['validatedAt'] ?? 0);
  entity.lastError = `${rec['lastError'] ?? ''}`;
  const policy = `${rec['failurePolicy'] ?? ''}`;
  entity.failurePolicy = isValidFailurePolicy(policy) ? policy : FAILURE_POLICY_BLOCK;
  const rawVersions = rec['versions'];
  if (rawVersions !== undefined && rawVersions !== null && Array.isArray(rawVersions)) {
    const list = rawVersions as Array<Object>;
    for (let i = 0; i < list.length; i++) {
      const version = parseVersion(list[i]);
      if (version !== null) {
        entity.versions.push(version);
      }
    }
  }
  return entity;
}

export function parseManifest(text: string): RuleSetManifest | null {
  if (text === null || text === undefined || text.length === 0) {
    return null;
  }
  let parsed: Record<string, Object>;
  try {
    const value: Object = JSON.parse(text) as Object;
    if (!isRecord(value)) {
      return null;
    }
    parsed = value as Record<string, Object>;
  } catch (e) {
    return null;
  }
  const schemaVersion = Number(parsed['schemaVersion'] ?? 0);
  if (!(schemaVersion >= 1) || schemaVersion > MANIFEST_SCHEMA_VERSION) {
    // 未来版本拒绝解析：宁可当作无缓存重新下载，也不静默改写未知结构
    return null;
  }
  const manifest = new RuleSetManifest();
  manifest.schemaVersion = schemaVersion;
  manifest.updatedAt = Number(parsed['updatedAt'] ?? 0);
  const rawResources = parsed['resources'];
  if (isRecord(rawResources)) {
    const record = rawResources as Record<string, Object>;
    const keys = Object.keys(record);
    for (let i = 0; i < keys.length; i++) {
      const entity = parseResource(keys[i], record[keys[i]]);
      if (entity !== null) {
        manifest.resources[keys[i]] = entity;
      }
    }
  }
  return manifest;
}

/** 清单加载结果：corrupt=true 表示文件存在但不可解析(必须按无缓存处理)。 */
class ManifestLoad {
  manifest: RuleSetManifest = new RuleSetManifest();
  corrupt: boolean = false;
  error: string = '';
}

export function serializeManifest(manifest: RuleSetManifest): string {
  return JSON.stringify(manifest, null, 2);
}

/**
 * 规则集资源仓库(单写者)。所有变更经 enqueue 串行，避免同一资源的清单互相覆盖。
 */
export class RuleSetRepository {
  private static writerQueue: Promise<void> = Promise.resolve();
  /** 同一毫秒内多次下载时保证临时文件名不碰撞(进程内单调递增)。 */
  private static tempSequence: number = 0;
  private static dir: string = '';
  private static fetcher: ResourceFetcher = new ResourceFetcher();
  private static validator: ResourceValidator = ResourceValidator.unsupported();

  /** 初始化资源根目录(幂等)。不改变已注入的 fetcher/validator。 */
  static init(context: common.Context): void {
    RuleSetRepository.dir = `${SnapshotStore.configDir(context)}/${RESOURCES_DIR_NAME}`;
    SnapshotStore.ensureDir(RuleSetRepository.dir);
    LogStore.addLog(`[ruleset] 资源目录: ${RuleSetRepository.dir}`);
  }

  static isInitialized(): boolean {
    return RuleSetRepository.dir.length > 0;
  }

  static resourcesDir(): string {
    return RuleSetRepository.dir;
  }

  /** 注入下载器(生产 HttpResourceFetcher；测试内存桩)。 */
  static setFetcher(fetcher: ResourceFetcher): void {
    RuleSetRepository.fetcher = fetcher;
  }

  /** 注入 SRS 验证器(生产见 ResourceValidator.fromKernelBridge + CoreManager.validateSrs)。 */
  static setValidator(validator: ResourceValidator): void {
    RuleSetRepository.validator = validator;
  }

  static getValidator(): ResourceValidator {
    return RuleSetRepository.validator;
  }

  /** 当前内核 SRS 验证能力：'kernel-k1' | 'unsupported' | 'unknown'(§16.3 能力查询)。 */
  static describeCapability(): string {
    return RuleSetRepository.validator.getCapability();
  }

  /** URL 校验(§7.5 第一步)。返回 '' 表示可下载，否则是机器可读原因。 */
  static validateUrl(url: string): string {
    const text = url === null || url === undefined ? '' : `${url}`;
    if (text.length === 0) {
      return 'URL 为空';
    }
    if (text.length > MAX_URL_LENGTH) {
      return `URL 过长(${text.length} > ${MAX_URL_LENGTH})`;
    }
    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i);
      if (code <= 0x20 || code === 0x7f) {
        return 'URL 含空白或控制字符';
      }
    }
    const lower = text.toLowerCase();
    const isHttp = lower.startsWith('http://');
    const isHttps = lower.startsWith('https://');
    if (!isHttp && !isHttps) {
      return '仅支持 http/https 下载源';
    }
    const prefixLength = isHttps ? 8 : 7;
    if (text.length <= prefixLength) {
      return 'URL 缺少主机名';
    }
    if (text.indexOf('://', prefixLength) >= 0) {
      return 'URL 含重复协议前缀';
    }
    return '';
  }

  static get(id: string): RuleSetResource | null {
    const sid = sanitizeResourceId(id);
    if (sid.length === 0) {
      return null;
    }
    const loaded = RuleSetRepository.loadManifest();
    const entity = loaded.manifest.resources[sid];
    return entity === undefined ? null : entity;
  }

  static list(): Array<RuleSetResource> {
    const loaded = RuleSetRepository.loadManifest();
    const keys = Object.keys(loaded.manifest.resources);
    const out: Array<RuleSetResource> = [];
    for (let i = 0; i < keys.length; i++) {
      out.push(loaded.manifest.resources[keys[i]]);
    }
    return out;
  }

  /** 只读查询：当前可用性(不联网、不改盘)。 */
  static getAvailability(id: string): ResourceAvailability {
    const sid = sanitizeResourceId(id);
    const out = new ResourceAvailability();
    if (sid.length === 0) {
      out.rejected = 'invalid-id';
      out.error = '资源 ID 非法';
      return out;
    }
    const loaded = RuleSetRepository.loadManifest();
    if (loaded.corrupt) {
      out.reason = REASON_MANIFEST_CORRUPT;
      out.rejected = 'io-error';
      out.error = loaded.error;
      return out;
    }
    const entity = loaded.manifest.resources[sid];
    if (entity === undefined) {
      return out;
    }
    return RuleSetRepository.describe(sid, entity, false);
  }

  /**
   * 当前版本文件路径(供配置编译器引用，§7.5「编译时引用已验证的本地 rule_set 路径」)。
   * 受 failurePolicy 约束：不可用的资源返回 ''，避免调用方误引用被阻止的候选。
   */
  static cachedFilePath(id: string): string {
    const availability = RuleSetRepository.getAvailability(id);
    if (!availability.available) {
      return '';
    }
    const sid = sanitizeResourceId(id);
    const entity = RuleSetRepository.get(sid);
    if (entity === null) {
      return '';
    }
    const version = findVersion(entity, entity.currentHash);
    if (version === null) {
      return '';
    }
    const path = RuleSetRepository.versionPath(sid, version.file);
    return SnapshotStore.exists(path) ? path : '';
  }

  /** 不做策略过滤的原始路径(诊断/展示用)；文件不存在时返回 ''。 */
  static currentFilePath(id: string): string {
    const sid = sanitizeResourceId(id);
    if (sid.length === 0) {
      return '';
    }
    const entity = RuleSetRepository.get(sid);
    if (entity === null) {
      return '';
    }
    const version = findVersion(entity, entity.currentHash);
    if (version === null) {
      return '';
    }
    const path = RuleSetRepository.versionPath(sid, version.file);
    return SnapshotStore.exists(path) ? path : '';
  }

  /**
   * 下载 → 校验 → 落盘 → 提交清单。串行执行(单写者)。
   * failurePolicy 传 '' 表示沿用已有策略/默认 block；传显式值等于用户策略修改。
   */
  static ensureResource(id: string, sourceUrl: string, format: string = '',
    failurePolicy: string = ''): Promise<ResourceAvailability> {
    return RuleSetRepository.enqueue(async (): Promise<ResourceAvailability> => {
      return RuleSetRepository.downloadAndCommit(id, sourceUrl, format, failurePolicy);
    });
  }

  /** 记录用户显式失败策略(§7.5「用户明确暂停是策略修改，不是下载失败的自动结果」)。 */
  static setFailurePolicy(id: string, policy: string): Promise<boolean> {
    return RuleSetRepository.enqueue(async (): Promise<boolean> => {
      const sid = sanitizeResourceId(id);
      if (sid.length === 0 || !isValidFailurePolicy(policy)) {
        return false;
      }
      const loaded = RuleSetRepository.loadManifest();
      if (loaded.corrupt) {
        return false;
      }
      const entity = loaded.manifest.resources[sid];
      if (entity === undefined) {
        return false;
      }
      entity.failurePolicy = policy;
      try {
        RuleSetRepository.saveManifest(loaded.manifest);
      } catch (e) {
        LogStore.addLog(`[ruleset] 失败策略写入失败: ${errText(e)}`);
        return false;
      }
      LogStore.addLog(`[ruleset] ${sid} 失败策略改为 ${policy}`);
      return true;
    });
  }

  /** 删除一个资源(用户显式删除)：版本文件 + 清单条目一起清。 */
  static removeResource(id: string): Promise<boolean> {
    return RuleSetRepository.enqueue(async (): Promise<boolean> => {
      const sid = sanitizeResourceId(id);
      if (sid.length === 0) {
        return false;
      }
      const loaded = RuleSetRepository.loadManifest();
      if (loaded.corrupt) {
        return false;
      }
      const existed = loaded.manifest.resources[sid] !== undefined;
      if (existed) {
        // arkts-no-delete:重建不含该键的 resources 对象(delete 运算符在 ArkTS 严格模式禁用)
        const next: Record<string, RuleSetResource> = {};
        const keys = Object.keys(loaded.manifest.resources);
        for (let i = 0; i < keys.length; i++) {
          if (keys[i] !== sid) {
            next[keys[i]] = loaded.manifest.resources[keys[i]];
          }
        }
        loaded.manifest.resources = next;
      }
      if (existed) {
        try {
          RuleSetRepository.saveManifest(loaded.manifest);
        } catch (e) {
          return false;
        }
      }
      RuleSetRepository.deleteResourceFiles(sid);
      LogStore.addLog(`[ruleset] 已删除资源 ${sid}(存在=${existed})`);
      return existed;
    });
  }

  /** 资源树总占用(不含 .tmp 残留)。 */
  static totalCacheBytes(): number {
    const dirs = RuleSetRepository.listResourceDirs();
    let total = 0;
    for (let i = 0; i < dirs.length; i++) {
      const names = RuleSetRepository.listFileNames(dirs[i]);
      for (let j = 0; j < names.length; j++) {
        if (names[j].endsWith('.tmp')) {
          continue;
        }
        total += RuleSetRepository.fileSize(`${dirs[i]}/${names[j]}`);
      }
    }
    return total;
  }

  /**
   * GC(§14.3-8)：只保留清单记录的当前与上一版本；删除未引用文件与 .tmp 残留。
   * 清单损坏时无法判断引用关系 —— 只清 .tmp，不动任何版本文件(宁可不删)。
   * 返回删除的文件数。
   */
  static collectGarbage(): number {
    const loaded = RuleSetRepository.loadManifest();
    const dirs = RuleSetRepository.listResourceDirs();
    let deleted = 0;
    for (let i = 0; i < dirs.length; i++) {
      const dir = dirs[i];
      const sid = RuleSetRepository.idFromDirName(dir);
      const entity = loaded.manifest.resources[sid];
      const names = RuleSetRepository.listFileNames(dir);
      if (entity === undefined || loaded.corrupt) {
        // 清单里没有这个资源：只清临时文件(版本文件宁可留着等人工/后续迁移)
        for (let j = 0; j < names.length; j++) {
          if (names[j].endsWith('.tmp')) {
            SnapshotStore.removeFile(`${dir}/${names[j]}`);
            deleted++;
          }
        }
        continue;
      }
      const referenced: Array<string> = [];
      const kept = RuleSetRepository.keptVersions(entity);
      for (let j = 0; j < kept.length; j++) {
        if (referenced.indexOf(kept[j].file) < 0) {
          referenced.push(kept[j].file);
        }
      }
      for (let j = 0; j < names.length; j++) {
        const name = names[j];
        if (referenced.indexOf(name) >= 0) {
          continue;
        }
        SnapshotStore.removeFile(`${dir}/${name}`);
        deleted++;
      }
    }
    if (deleted > 0) {
      LogStore.addLog(`[ruleset] GC 清理 ${deleted} 个文件`);
    }
    return deleted;
  }

  // ---- 内部实现 ----

  private static enqueue<T>(task: () => Promise<T>): Promise<T> {
    const previous = RuleSetRepository.writerQueue;
    let release: () => void = () => {};
    RuleSetRepository.writerQueue = new Promise<void>((resolve: () => void) => {
      release = resolve;
    });
    const run = async (): Promise<T> => {
      try {
        await previous;
      } catch (e) {
        // 前一次失败不阻断后一次
      }
      try {
        return await task();
      } finally {
        release();
      }
    };
    return run();
  }

  private static resourcesRoot(): string {
    return RuleSetRepository.dir;
  }

  private static manifestPath(): string {
    return `${RuleSetRepository.dir}/${MANIFEST_FILE_NAME}`;
  }

  private static resourceDir(sid: string): string {
    return `${RuleSetRepository.dir}/${sid}`;
  }

  private static versionPath(sid: string, fileName: string): string {
    return `${RuleSetRepository.resourceDir(sid)}/${fileName}`;
  }

  private static loadManifest(): ManifestLoad {
    const loaded = new ManifestLoad();
    const path = RuleSetRepository.manifestPath();
    if (!SnapshotStore.exists(path)) {
      return loaded;
    }
    try {
      const text = SnapshotStore.readText(path);
      const parsed = parseManifest(text);
      if (parsed === null) {
        loaded.corrupt = true;
        loaded.error = '资源清单无法解析(已按无缓存处理)';
        return loaded;
      }
      loaded.manifest = parsed;
      return loaded;
    } catch (e) {
      loaded.corrupt = true;
      loaded.error = `资源清单读取失败: ${errText(e)}`;
      return loaded;
    }
  }

  /** 原子写 + 读回校验(§14.3-1/3)；校验不过抛错，磁盘上的旧清单保持不变。 */
  private static saveManifest(manifest: RuleSetManifest): void {
    manifest.schemaVersion = MANIFEST_SCHEMA_VERSION;
    manifest.updatedAt = Date.now();
    SnapshotStore.ensureDir(RuleSetRepository.dir);
    const path = RuleSetRepository.manifestPath();
    SnapshotStore.writeTextAtomic(path, serializeManifest(manifest));
    const backText = SnapshotStore.readText(path);
    const back = parseManifest(backText);
    if (back === null) {
      throw new Error('资源清单读回校验失败(无法解析)');
    }
    const ids = Object.keys(manifest.resources);
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      const expected = manifest.resources[id];
      const actual = back.resources[id];
      if (actual === undefined) {
        throw new Error(`资源清单读回校验失败(缺少 ${id})`);
      }
      if (actual.currentHash !== expected.currentHash) {
        throw new Error(`资源清单读回校验失败(${id} currentHash 不一致)`);
      }
      if (actual.versions.length !== expected.versions.length) {
        throw new Error(`资源清单读回校验失败(${id} 版本数不一致)`);
      }
    }
  }

  private static fileSize(path: string): number {
    try {
      const stat = fs.statSync(path);
      return stat.isDirectory() ? 0 : Number(stat.size);
    } catch (e) {
      return 0;
    }
  }

  private static listFileNames(dir: string): Array<string> {
    try {
      const names: Array<string> = fs.listFileSync(dir);
      return names === null || names === undefined ? [] : names;
    } catch (e) {
      return [];
    }
  }

  private static listResourceDirs(): Array<string> {
    const root = RuleSetRepository.resourcesRoot();
    if (root.length === 0 || !SnapshotStore.exists(root)) {
      return [];
    }
    const out: Array<string> = [];
    const names = RuleSetRepository.listFileNames(root);
    for (let i = 0; i < names.length; i++) {
      const path = `${root}/${names[i]}`;
      try {
        if (fs.statSync(path).isDirectory()) {
          out.push(path);
        }
      } catch (e) {
        // 忽略不可 stat 的条目
      }
    }
    return out;
  }

  private static idFromDirName(dir: string): string {
    const slash = dir.lastIndexOf('/');
    return slash >= 0 ? dir.substring(slash + 1) : dir;
  }

  /** current + 上一版本。current 不在 versions 里(旧清单/手工编辑)时也保留它的文件。 */
  private static keptVersions(entity: RuleSetResource): Array<ResourceVersion> {
    const out: Array<ResourceVersion> = [];
    const current = findVersion(entity, entity.currentHash);
    if (current !== null) {
      out.push(current);
    }
    for (let i = entity.versions.length - 1; i >= 0 && out.length < KEEP_VERSIONS; i--) {
      const version = entity.versions[i];
      if (version.hash === entity.currentHash) {
        continue;
      }
      out.push(version);
    }
    return out;
  }

  private static deleteResourceFiles(sid: string): void {
    const dir = RuleSetRepository.resourceDir(sid);
    const names = RuleSetRepository.listFileNames(dir);
    for (let i = 0; i < names.length; i++) {
      SnapshotStore.removeFile(`${dir}/${names[i]}`);
    }
  }

  private static removeTemp(path: string): void {
    if (path.length === 0) {
      return;
    }
    SnapshotStore.removeFile(path);
  }

  private static readBytes(path: string, maxBytes: number): Uint8Array {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(path);
      const size = Number(stat.size);
      const capacity = size > maxBytes ? maxBytes : size;
      const buffer = new ArrayBuffer(capacity);
      const read = fs.readSync(file.fd, buffer, { length: capacity });
      return new Uint8Array(buffer, 0, read);
    } finally {
      fs.closeSync(file);
    }
  }

  /** 由实体与磁盘事实计算可用性。不修改任何状态。 */
  private static describe(sid: string, entity: RuleSetResource,
    fromDownload: boolean): ResourceAvailability {
    const out = new ResourceAvailability();
    out.failurePolicy = entity.failurePolicy;
    out.error = entity.lastError;
    out.currentHash = entity.currentHash;
    out.cachedAt = entity.lastSuccessfulDownloadAt;
    out.state = STATE_UNAVAILABLE;
    out.reason = REASON_NO_CACHE;
    const version = findVersion(entity, entity.currentHash);
    if (version === null) {
      return out;
    }
    const path = RuleSetRepository.versionPath(sid, version.file);
    if (!SnapshotStore.exists(path)) {
      // 缓存丢失(用户清理/迁移失败)：按无可用缓存处理，下次走重新下载
      out.reason = REASON_CACHE_MISSING;
      return out;
    }
    out.fromCache = !fromDownload;
    out.verified = version.validatedAt > 0 && version.engine === ENGINE_KERNEL;
    if (out.verified) {
      out.available = true;
      out.state = STATE_READY;
      out.reason = fromDownload ? REASON_DOWNLOADED : REASON_CACHE_HIT;
      return out;
    }
    // 未验证：候选文件在场，但按 §16.3 默认不得标「已验证」；是否可用由策略决定
    out.state = STATE_UNVERIFIED;
    out.reason = REASON_UNVERIFIED_CANDIDATE;
    out.available = entity.failurePolicy === FAILURE_POLICY_ALLOW_UNVERIFIED;
    return out;
  }

  /**
   * 失败收尾：删临时文件、记 lastAttemptAt/lastError、保留 currentHash 与版本文件。
   * 清单写入是尽力而为(即使元数据写不下去，旧缓存仍然有效)。
   */
  private static reject(manifest: RuleSetManifest, sid: string, entity: RuleSetResource,
    tempPath: string, error: string, rejected: string): ResourceAvailability {
    RuleSetRepository.removeTemp(tempPath);
    entity.lastAttemptAt = Date.now();
    entity.lastError = error;
    try {
      RuleSetRepository.saveManifest(manifest);
    } catch (e) {
      LogStore.addLog(`[ruleset] 失败原因写入清单失败: ${errText(e)}`);
    }
    const out = RuleSetRepository.describe(sid, entity, false);
    out.rejected = rejected;
    out.error = error;
    if (out.available) {
      out.fromCache = true;
      out.reason = REASON_UPDATE_FAILED;
    }
    LogStore.addLog(`[ruleset] ${sid} 资源不可用或沿用旧缓存: ${rejected} ${error}`);
    return out;
  }

  private static async downloadAndCommit(id: string, sourceUrl: string, format: string,
    failurePolicy: string): Promise<ResourceAvailability> {
    const sid = sanitizeResourceId(id);
    const empty = new ResourceAvailability();
    if (sid.length === 0) {
      empty.rejected = 'invalid-id';
      empty.error = '资源 ID 非法(空或无法映射为安全目录名)';
      return empty;
    }
    if (failurePolicy.length > 0 && !isValidFailurePolicy(failurePolicy)) {
      const bad = RuleSetRepository.getAvailability(sid);
      bad.rejected = 'invalid-id';
      bad.error = `未知失败策略: ${failurePolicy}`;
      return bad;
    }
    const loaded = RuleSetRepository.loadManifest();
    let entity = loaded.manifest.resources[sid];
    if (entity === undefined) {
      entity = new RuleSetResource();
      entity.id = sid;
      loaded.manifest.resources[sid] = entity;
    }
    if (failurePolicy.length > 0) {
      entity.failurePolicy = failurePolicy;
    }
    if (!isValidFailurePolicy(entity.failurePolicy)) {
      entity.failurePolicy = FAILURE_POLICY_BLOCK;
    }
    const declared = format.length > 0 ? format : declaredFormatFromUrl(sourceUrl);
    entity.format = declared === FORMAT_SOURCE_JSON ? FORMAT_SOURCE_JSON : FORMAT_BINARY_SRS;
    entity.sourceUrl = sourceUrl === null || sourceUrl === undefined ? '' : `${sourceUrl}`;

    const urlError = RuleSetRepository.validateUrl(sourceUrl);
    if (urlError.length > 0) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, '', `URL 非法: ${urlError}`,
        'invalid-url');
    }
    if (RuleSetRepository.dir.length === 0) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, '',
        '资源仓库未初始化(RuleSetRepository.init 未调用)', 'io-error');
    }

    SnapshotStore.ensureDir(RuleSetRepository.resourceDir(sid));
    const tempPath = `${RuleSetRepository.resourceDir(sid)}/download-${Date.now()}-${RuleSetRepository.tempSequence}.tmp`;
    RuleSetRepository.tempSequence++;
    const request = new DownloadRequest();
    request.url = entity.sourceUrl;
    request.targetPath = tempPath;
    request.maxBytes = MAX_RESOURCE_BYTES;
    request.connectTimeoutMs = CONNECT_TIMEOUT_MS;
    request.readTimeoutMs = READ_TIMEOUT_MS;
    request.expectedFormat = entity.format;

    let result = new DownloadResult();
    try {
      result = await RuleSetRepository.fetcher.fetch(request);
    } catch (e) {
      result = new DownloadResult();
      result.error = `下载异常: ${errText(e)}`;
    }
    if (result.error.length > 0) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath, result.error,
        'io-error');
    }
    if (result.statusCode < 200 || result.statusCode >= 300) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
        `HTTP ${result.statusCode}`, 'http-status');
    }
    if (result.declaredBytes > MAX_RESOURCE_BYTES) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
        `响应声明大小 ${result.declaredBytes} 字节超过单文件上限 ${MAX_RESOURCE_BYTES}`, 'too-large');
    }
    if (result.bytesWritten > MAX_RESOURCE_BYTES) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
        `实际写入 ${result.bytesWritten} 字节超过单文件上限 ${MAX_RESOURCE_BYTES}`, 'too-large');
    }
    if (result.bytesWritten <= 0) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
        '下载内容为空(0 字节)', 'empty');
    }
    if (result.declaredBytes >= 0 && result.declaredBytes !== result.bytesWritten) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
        `下载不完整(声明 ${result.declaredBytes}，实际 ${result.bytesWritten})`, 'truncated');
    }

    let bytes: Uint8Array;
    try {
      bytes = RuleSetRepository.readBytes(tempPath, MAX_RESOURCE_BYTES);
    } catch (e) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
        `读取临时文件失败: ${errText(e)}`, 'io-error');
    }
    if (bytes.length > MAX_RESOURCE_BYTES) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
        `文件超过单文件上限 ${MAX_RESOURCE_BYTES}`, 'too-large');
    }

    // 格式校验(§7.5：只有 SR 魔数不够，但格式门槛仍必须先过；全文校验在下一段)
    let validation = new ResourceValidation();
    if (entity.format === FORMAT_BINARY_SRS) {
      if (!looksLikeBinarySrs(bytes)) {
        return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
          '内容不是 sing-box 二进制 SRS(前 3 字节不是 SRS 或体积小于 4KB)', 'format-mismatch');
      }
      validation = await RuleSetRepository.validator.validateSrsFile(tempPath);
    } else {
      let text = '';
      try {
        text = SnapshotStore.readText(tempPath);
      } catch (e) {
        return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
          `读取 source JSON 失败: ${errText(e)}`, 'io-error');
      }
      validation = RuleSetRepository.validator.validateSourceJson(text);
    }
    const unverified = validation.engine === ENGINE_UNSUPPORTED;
    if (!validation.ok && !unverified) {
      return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
        `验证失败: ${validation.error}`, 'validation-failed');
    }
    const verified = validation.ok && validation.engine === ENGINE_KERNEL;

    // 内容 hash(验证通过后再算，与 §7.5 顺序一致)
    const hash = sha256Hex(bytes);
    const fileName = `${hash}${versionFileExtension(entity.format)}`;
    const versionPath = RuleSetRepository.versionPath(sid, fileName);
    const alreadyStored = SnapshotStore.exists(versionPath);
    if (!alreadyStored) {
      const total = RuleSetRepository.totalCacheBytes();
      let projected = total + bytes.length;
      if (projected > MAX_TOTAL_BYTES) {
        RuleSetRepository.collectGarbage();
        projected = RuleSetRepository.totalCacheBytes() + bytes.length;
      }
      if (projected > MAX_TOTAL_BYTES) {
        return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
          `总缓存放不下(当前 ${total} + 新增 ${bytes.length} > ${MAX_TOTAL_BYTES} 字节)`, 'cache-limit');
      }
      try {
        fs.renameSync(tempPath, versionPath);
      } catch (e) {
        return RuleSetRepository.reject(loaded.manifest, sid, entity, tempPath,
          `移入版本目录失败: ${errText(e)}`, 'io-error');
      }
    } else {
      // 同 hash 已存在(重复下载/回滚到旧版本)：内容寻址，无需重写
      RuleSetRepository.removeTemp(tempPath);
    }

    const now = Date.now();
    const existing = findVersion(entity, hash);
    if (existing !== null) {
      // 同 hash 重复下载(内容寻址):只刷新时间戳并挪到末尾，不能产生重复版本条目
      const index = entity.versions.indexOf(existing);
      existing.sizeBytes = bytes.length;
      existing.downloadedAt = now;
      existing.validatedAt = verified ? now : 0;
      existing.engine = validation.engine;
      entity.versions.splice(index, 1);
      entity.versions.push(existing);
    } else {
      const version = new ResourceVersion();
      version.hash = hash;
      version.file = fileName;
      version.sizeBytes = bytes.length;
      version.downloadedAt = now;
      version.validatedAt = verified ? now : 0;
      version.engine = validation.engine;
      entity.versions.push(version);
    }
    entity.currentHash = hash;
    entity.lastAttemptAt = now;
    entity.lastSuccessfulDownloadAt = now;
    entity.validatedAt = verified ? now : 0;
    // 未验证时把校验范围/能力错误留在 lastError(§16.3 必须可见)，验证通过才清空
    entity.lastError = verified ? '' : validation.error;
    const dropped = RuleSetRepository.trimVersions(entity);
    try {
      RuleSetRepository.saveManifest(loaded.manifest);
    } catch (e) {
      // 文件已落盘但清单未提交：磁盘清单仍是旧的，旧缓存继续有效(候选文件留给 GC)
      const disk = RuleSetRepository.loadManifest();
      const diskEntity = disk.manifest.resources[sid];
      const out = diskEntity === undefined
        ? new ResourceAvailability()
        : RuleSetRepository.describe(sid, diskEntity, false);
      out.rejected = 'commit-failed';
      out.error = `资源文件已落盘但清单提交失败: ${errText(e)}`;
      LogStore.addLog(`[ruleset] ${sid} ${out.error}`);
      return out;
    }
    for (let i = 0; i < dropped.length; i++) {
      SnapshotStore.removeFile(RuleSetRepository.versionPath(sid, dropped[i].file));
    }
    RuleSetRepository.collectGarbage();
    LogStore.addLog(`[ruleset] ${sid} 资源已更新: hash=${hash}, ` +
      `engine=${validation.engine}, verified=${verified}, ${bytes.length} 字节`);
    return RuleSetRepository.describe(sid, entity, true);
  }

  /** 版本数组裁剪到 KEEP_VERSIONS，返回被裁掉的条目(调用方负责删文件)。 */
  private static trimVersions(entity: RuleSetResource): Array<ResourceVersion> {
    const dropped: Array<ResourceVersion> = [];
    if (entity.versions.length <= KEEP_VERSIONS) {
      return dropped;
    }
    const removeCount = entity.versions.length - KEEP_VERSIONS;
    for (let i = 0; i < removeCount; i++) {
      dropped.push(entity.versions[i]);
    }
    entity.versions.splice(0, removeCount);
    return dropped;
  }
}

/** 在实体的 versions 里按 hash 找版本(找不到返回 null)。 */
function findVersion(entity: RuleSetResource, hash: string): ResourceVersion | null {
  if (hash.length === 0) {
    return null;
  }
  for (let i = 0; i < entity.versions.length; i++) {
    if (entity.versions[i].hash === hash) {
      return entity.versions[i];
    }
  }
  return null;
}
