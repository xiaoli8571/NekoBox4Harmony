import { errText } from '../utils/ErrText';

/**
 * 规则集资源校验抽象 —— REDESIGN-PLAN-2026-10-23.md §7.5 / §14.2 RuleSetResource / §16.3 K1。
 *
 * 职责边界(与 RuleSetRepository 的分工):
 *  - 本文件只做**纯判断**:格式嗅探、source JSON 语法检查、SRS 全文校验的**结果归一化**、
 *    内容 hash(SHA-256)。不做任何 I/O、不写文件、不碰网络 —— 因此可在主机 VM 里直接测。
 *  - RuleSetRepository 负责目录/临时文件/清单提交/GC,并把 SRS 文件路径交给这里注入的验证函数。
 *
 * 能力模型(§16.3「能力不可用时不对资源标已验证」):
 *  - `kernel-k1`:内核 CGoValidateSRSFileV1 完整解析通过 = 唯一可以标「已验证」的来源。
 *  - `unsupported`:当前 .so 没有该导出(冻结库尚未重编),**不得**把资源标成已验证;
 *    资源仍可作为候选落盘，状态记 unverified，由调用方按 §16.3 决定是否允许应用。
 *  - `failed`:内核在场但文件内容不合法(含调用异常)。
 *  - `format-only`:source JSON 只做了语法/最小结构检查 —— 不构成内核验证，同样不计入 verified。
 *    (`format-only` 是 §16.3「校验结果必须注明范围」所需的第四个取值，仅用于 source-json。)
 */

export const ENGINE_KERNEL: string = 'kernel-k1';
export const ENGINE_UNSUPPORTED: string = 'unsupported';
export const ENGINE_FAILED: string = 'failed';
export const ENGINE_FORMAT_ONLY: string = 'format-only';

export const FORMAT_BINARY_SRS: string = 'binary-srs';
export const FORMAT_SOURCE_JSON: string = 'source-json';

/** .srs 合理下限(与 utils/GeoAssets.ets 的 GEO_MIN_BYTES 一致):挡掉 200+错误页。 */
export const MIN_BINARY_SRS_BYTES: number = 4 * 1024;
/** 单文件上限 32MiB(§7.5 规划初值)。超限给明确错误，禁止截断后当成功。 */
export const MAX_RESOURCE_BYTES: number = 32 * 1024 * 1024;

/** 一次资源校验的结论。error 为空且 ok=true 才允许标「已验证」(engine 还必须是 kernel-k1)。 */
export class ResourceValidation {
  ok: boolean = false;
  /** 'kernel-k1' | 'unsupported' | 'failed' | 'format-only' */
  engine: string = ENGINE_UNSUPPORTED;
  error: string = '';
  /** 校验范围说明(§16.3:结果必须注明「验证了什么」)。 */
  scope: string = '';
}

/**
 * SRS 验证器。注入形态是「函数」——与内核桥接的原始契约一致(见 core/CoreManager.ets):
 *   ''            → 通过
 *   'unsupported' → 当前 .so 无 CGoValidateSRSFileV1
 *   'err:...'     → 内核原文错误
 * 生产接线(留给 W05/NAPI，待 CGoValidateSRSFileV1 进入冻结 .so):
 *   RuleSetRepository.setValidator(ResourceValidator.fromKernelBridge(
 *     (path: string): Promise<string> => CoreManager.validateSrs(path)));
 * 在接线之前，RuleSetRepository 默认用 unsupported()，资源只会成为 unverified 候选。
 */
export class ResourceValidator {
  private fn: ((path: string) => Promise<string>) | null = null;
  private capability: string = ENGINE_UNSUPPORTED;

  constructor(fn: ((path: string) => Promise<string>) | null) {
    this.fn = fn;
  }

  /** 默认：没有任何内核验证能力(冻结 .so 现状)。 */
  static unsupported(): ResourceValidator {
    return new ResourceValidator(null);
  }

  /** 注入内核桥接函数(生产用 CoreManager.validateSrs；测试用内存桩)。 */
  static fromKernelBridge(fn: (path: string) => Promise<string>): ResourceValidator {
    return new ResourceValidator(fn);
  }

  /** 最近一次探测到的能力：'kernel-k1' | 'unsupported' | 'unknown'(尚未调用过)。 */
  getCapability(): string {
    return this.capability;
  }

  /**
   * 校验一个落盘的 .srs。**不**修改文件、不启动内核实例(依赖注入函数保持无副作用)。
   * 只有 engine=kernel-k1 且 ok=true 才算「已验证」。
   */
  async validateSrsFile(path: string): Promise<ResourceValidation> {
    const out = new ResourceValidation();
    out.scope = 'SRS 全文解析(内核 srs.Read，无副作用)';
    const fn = this.fn;
    if (fn === null) {
      out.engine = ENGINE_UNSUPPORTED;
      out.error = '当前内核不支持 SRS 验证(libsingbox.so 缺少 CGoValidateSRSFileV1)';
      return out;
    }
    let raw: string = '';
    try {
      raw = await fn(path);
    } catch (e) {
      out.engine = ENGINE_FAILED;
      out.error = `验证调用异常: ${errText(e)}`;
      return out;
    }
    const text = raw === null || raw === undefined ? '' : `${raw}`;
    if (text.length === 0) {
      out.ok = true;
      out.engine = ENGINE_KERNEL;
      this.capability = ENGINE_KERNEL;
      return out;
    }
    if (text === ENGINE_UNSUPPORTED) {
      out.engine = ENGINE_UNSUPPORTED;
      this.capability = ENGINE_UNSUPPORTED;
      out.error = '当前内核不支持 SRS 验证(libsingbox.so 缺少 CGoValidateSRSFileV1)';
      return out;
    }
    out.engine = ENGINE_FAILED;
    out.error = text.startsWith('err:') ? text.substring(4) : text;
    if (out.error.length === 0) {
      out.error = '内核验证失败(无错误文本)';
    }
    return out;
  }

  /**
   * source JSON 规则集的结构检查。sing-box source rule-set 的最小形状是
   * `{ "version": N, "rules": [...] }`；这里只验语法与 rules 数组，不解析规则语义
   * (规则语义要等 ConfigCompiler / 内核 schema 校验)。engine 记 format-only，
   * 因此**永远不**会被当成「已验证」。
   */
  validateSourceJson(text: string): ResourceValidation {
    const out = new ResourceValidation();
    out.scope = 'source JSON 语法 + rules 数组(仅语法级，不构成内核验证)';
    out.engine = ENGINE_FORMAT_ONLY;
    let value: Object;
    try {
      value = JSON.parse(text) as Object;
    } catch (e) {
      out.error = `source JSON 解析失败: ${errText(e)}`;
      return out;
    }
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      out.error = 'source JSON 顶层必须是对象';
      return out;
    }
    const rec = value as Record<string, Object>;
    const rules = rec['rules'];
    if (rules === undefined || rules === null || !Array.isArray(rules)) {
      out.error = 'source JSON 缺少 rules 数组';
      return out;
    }
    out.ok = true;
    return out;
  }
}

/** 二进制 SRS 嗅探：前 3 字节 "SRS" + 体积下限(只做格式门槛，全文校验交给内核)。 */
export function looksLikeBinarySrs(bytes: Uint8Array): boolean {
  if (bytes.length < MIN_BINARY_SRS_BYTES) {
    return false;
  }
  return bytes[0] === 0x53 && bytes[1] === 0x52 && bytes[2] === 0x53;
}

/**
 * 由 URL 后缀推断格式(§14.2「格式与分类不能混用」)：
 *   .srs  → binary-srs；.json → source-json；其它 → ''(由调用方显式给格式)。
 */
export function declaredFormatFromUrl(url: string): string {
  const lower = url.toLowerCase();
  const q = lower.indexOf('?');
  const hash = lower.indexOf('#');
  let cut = lower.length;
  if (q >= 0 && q < cut) {
    cut = q;
  }
  if (hash >= 0 && hash < cut) {
    cut = hash;
  }
  const path = lower.substring(0, cut);
  if (path.endsWith('.srs')) {
    return FORMAT_BINARY_SRS;
  }
  if (path.endsWith('.json')) {
    return FORMAT_SOURCE_JSON;
  }
  return '';
}

/** 版本目录里的文件扩展名(与 format 一一对应，避免同 hash 不同格式互相覆盖)。 */
export function versionFileExtension(format: string): string {
  return format === FORMAT_SOURCE_JSON ? '.json' : '.srs';
}

// ---- SHA-256(纯实现，避免引入 @ohos.security.cryptoFramework 的异步依赖) ----
//
// 为什么自己实现：资源 hash 是版本目录/content-addressed 名字的来源，必须在主机 VM 里
// 可确定复现(测试注入内存 FS 时没有平台 crypto)。实际资产 34–56KB，纯 JS 计算可忽略；
// 极端 32MiB 上限下耗时上升但仍在下载路径(非 UI 热路径)内。若真机实测仍需提速，
// 可只在生产侧换成 cryptoFramework.digest，接口不变。

const SHA256_K: Array<number> = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

function rotr32(value: number, bits: number): number {
  return ((value >>> bits) | (value << (32 - bits))) >>> 0;
}

function readU32BE(data: Uint8Array, offset: number): number {
  return (((data[offset] << 24) | (data[offset + 1] << 16) |
    (data[offset + 2] << 8) | data[offset + 3]) >>> 0);
}

function writeU32BE(data: Uint8Array, offset: number, value: number): void {
  data[offset] = (value >>> 24) & 0xff;
  data[offset + 1] = (value >>> 16) & 0xff;
  data[offset + 2] = (value >>> 8) & 0xff;
  data[offset + 3] = value & 0xff;
}

function hexU32(value: number): string {
  let hex = (value >>> 0).toString(16);
  while (hex.length < 8) {
    hex = `0${hex}`;
  }
  return hex;
}

/** SHA-256 → 64 位小写 hex。空输入返回 e3b0c442...b855。 */
export function sha256Hex(input: Uint8Array): string {
  const h: Array<number> = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  ];
  const length = input.length;
  // 0x80 + 0x00... + 64bit 大端长度，向上取整到 64 字节
  const paddedLength = Math.ceil((length + 9) / 64) * 64;
  const padded = new Uint8Array(paddedLength);
  padded.set(input);
  padded[length] = 0x80;
  // length*8 可能超过 2^32(>512MiB)，本实现按 32MiB 上限仍写完整 64bit，避免未来放宽后错
  writeU32BE(padded, paddedLength - 8, Math.floor(length / 536870912));
  writeU32BE(padded, paddedLength - 4, (length % 536870912) * 8);

  const w: Array<number> = [];
  for (let i = 0; i < 64; i++) {
    w.push(0);
  }
  for (let offset = 0; offset < paddedLength; offset += 64) {
    for (let i = 0; i < 16; i++) {
      w[i] = readU32BE(padded, offset + i * 4);
    }
    for (let i = 16; i < 64; i++) {
      const x = w[i - 15];
      const y = w[i - 2];
      const s0 = (rotr32(x, 7) ^ rotr32(x, 18) ^ (x >>> 3)) >>> 0;
      const s1 = (rotr32(y, 17) ^ rotr32(y, 19) ^ (y >>> 10)) >>> 0;
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let a = h[0];
    let b = h[1];
    let c = h[2];
    let d = h[3];
    let e = h[4];
    let f = h[5];
    let g = h[6];
    let hh = h[7];
    for (let i = 0; i < 64; i++) {
      const s1 = (rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)) >>> 0;
      const ch = ((e & f) ^ ((~e) & g)) >>> 0;
      const t1 = (hh + s1 + ch + SHA256_K[i] + w[i]) >>> 0;
      const s0 = (rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)) >>> 0;
      const maj = ((a & b) ^ (a & c) ^ (b & c)) >>> 0;
      const t2 = (s0 + maj) >>> 0;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) >>> 0;
    }
    h[0] = (h[0] + a) >>> 0;
    h[1] = (h[1] + b) >>> 0;
    h[2] = (h[2] + c) >>> 0;
    h[3] = (h[3] + d) >>> 0;
    h[4] = (h[4] + e) >>> 0;
    h[5] = (h[5] + f) >>> 0;
    h[6] = (h[6] + g) >>> 0;
    h[7] = (h[7] + hh) >>> 0;
  }
  let out = '';
  for (let i = 0; i < 8; i++) {
    out += hexU32(h[i]);
  }
  return out;
}
