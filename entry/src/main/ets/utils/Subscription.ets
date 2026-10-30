import http from '@ohos.net.http';
import { Profile, ProfileType } from '../model/Profile';
import { parseYaml, hasTopLevelKey, YamlNode } from './ClashYaml';

/**
 * 订阅链接支持:
 *  - 下载订阅(UA 伪装 clash.meta:绝大多数机场返回 Clash YAML;v2rayNG UA 会被部分机场
 *    拒绝并返回"你的客户端不支持本站协议"文本)
 *  - 服务商返回 Clash YAML(proxies:)时用 ClashYaml 子集解析器提取节点
 *  - 服务商/订阅转换返回 sing-box JSON 配置(outbounds/endpoints)时直接映射节点
 *  - 其余按 base64 分享链接列表解析
 *  - HTTP 强制 1.1:规避 Cloudflare 前置在 HTTP/2 连接复用下的 421 Misdirected Request
 *  - 带 ETag/Last-Modified 的订阅走条件请求,服务端回 304 时不重复下载正文
 */

/**
 * 默认 User-Agent — 逐字对齐 Android `ktx/Nets.kt:66`:
 *   `USER_AGENT = "NekoBox/Android/" + BuildConfig.VERSION_NAME + " (Prefer ClashMeta Format)"`
 * nb4a 1.4.2 的 VERSION_NAME=1.4.2(nb4a.properties:2),故字面值为下方字符串。
 *
 * 这是**刻意逐字一致**而非笔误:机场按 UA 决定返回哪种订阅格式
 * (Clash YAML / base64 / sing-box JSON),UA 不同 → 正文不同 → 解析结果天然不同。
 * 用户自定义 UA(`subscription.customUserAgent`)仍然覆盖默认值(RawUpdater.kt:70)。
 */
export const SUB_UA = 'NekoBox/Android/1.4.2 (Prefer ClashMeta Format)';

/**
 * 解析不出节点时依次尝试的备用 User-Agent。
 *
 * 不少机场按 UA 分流返回不同格式:只认 clash.meta 的返回 Clash YAML,
 * 只认 v2rayN / sing-box 的返回 base64 分享链接或 JSON,只认 Stash 的又是另一套 YAML。
 * 单一 UA 命中不对就表现为「解析不到节点」,而用户只能去订阅设置里手工试错。
 * 顺序按国内机场的常见覆盖面排,总重试次数由调用方限制。
 */
export const SUB_UA_FALLBACKS: Array<string> = [
  'v2rayN/7.0',
  'sing-box 1.15.0',
  'ClashforWindows/0.20.39',
  'Stash/2.6.0 Clash/1.10.0'
];

export interface SubFetchResult {
  content: string;
  userinfo: string;
  etag: string;
  lastModified: string;
  // content-disposition 原始值:Android RawUpdater.kt:79-87 仅在组名以
  // "Subscription #" 开头时用它(经 Util.decodeFilename)改名
  contentDisposition: string;
  // true = 服务端回 304,content 为空,调用方应保留既有节点
  notModified: boolean;
}

export interface SubUserInfo {
  upload: number;
  download: number;
  total: number;
  expire: number;
}

export interface UnwrappedSubscriptionLink {
  url: string;
  name: string;
}

/**
 * 节点类型 -> Android bean 的 `javaClass.toString()` 字面量。
 *
 * Android `Protocols.Deduplication.hash()`(Protocols.kt:20-39)是:
 *   if (bean is ConfigBean) return bean.config
 *   return bean.serverAddress + bean.serverPort + type
 * 其中 `type` 由调用侧传入 `_proxy.javaClass.toString()`(RawUpdater.kt:114),
 * 形如 "class io.nekohasekai.sagernet.fmt.shadowsocks.ShadowsocksBean"。
 * 这里直接给出同一批字面量,使去重键字符串与 Android 完全一致。
 *
 * 注意两个 Android 原样怪癖(逐字复刻,已列入偏差清单):
 *  1. vmess 与 vless 在 Android 共用一个 VMessBean(alterId=-1 表 VLESS),
 *     所以两者 type 相同 —— 同 server+port 的 vmess/vless 会被判成重复;
 *  2. 拼接**不带任何分隔符**,因此 "a:23" + "1" 与 "a:2" + "31" 会撞键。
 */
function dedupTypeToken(type: string): string {
  if (type === ProfileType.SHADOWSOCKS) {
    return 'class io.nekohasekai.sagernet.fmt.shadowsocks.ShadowsocksBean';
  }
  if (type === ProfileType.VMESS || type === ProfileType.VLESS) {
    // Android: vless 也是 VMessBean(RawUpdater.kt:310-313)
    return 'class io.nekohasekai.sagernet.fmt.v2ray.VMessBean';
  }
  if (type === ProfileType.TROJAN) {
    return 'class io.nekohasekai.sagernet.fmt.trojan.TrojanBean';
  }
  if (type === ProfileType.HTTP) {
    return 'class io.nekohasekai.sagernet.fmt.http.HttpBean';
  }
  if (type === ProfileType.SOCKS) {
    return 'class io.nekohasekai.sagernet.fmt.socks.SOCKSBean';
  }
  if (type === ProfileType.HYSTERIA || type === ProfileType.HYSTERIA2) {
    // Android 两代 hysteria 同为 HysteriaBean(protocolVersion 区分)
    return 'class io.nekohasekai.sagernet.fmt.hysteria.HysteriaBean';
  }
  if (type === ProfileType.TUIC) {
    return 'class io.nekohasekai.sagernet.fmt.tuic.TuicBean';
  }
  if (type === ProfileType.WIREGUARD) {
    return 'class io.nekohasekai.sagernet.fmt.wireguard.WireGuardBean';
  }
  if (type === ProfileType.SSH) {
    return 'class io.nekohasekai.sagernet.fmt.ssh.SSHBean';
  }
  if (type === ProfileType.ANYTLS) {
    return 'class moe.matsuri.nb4a.proxy.anytls.AnyTLSBean';
  }
  // snell / shadowtls / chain 在 Android 1.4.2 的订阅链路里没有对应 bean,
  // 用 ProfileType 自身作 token(不影响与 Android 共同支持的协议)
  return type;
}

/**
 * 订阅去重键 — 逐字对齐安卓 Protocols.Deduplication.hash(Protocols.kt:20-39):
 * 自定义出站(Android ConfigBean)用整份 config 字符串;其余用
 * `serverAddress + serverPort + type` 直接相加(无分隔符、此顺序)。
 */
export function dedupKeyOf(p: Profile): string {
  if (p.type === ProfileType.CUSTOM) {
    // Android ConfigBean.hash() 返回 bean.config(整份 JSON)
    return p.customOutbound;
  }
  return `${p.server}${p.serverPort}${dedupTypeToken(p.type)}`;
}

const CLASH_CONTAINER_PREFIX = 'clash://install-config?';

/**
 * 订阅容器 Scheme 解包(对齐安卓 MainActivity.importSubscription)。
 * clash://install-config?url=<订阅地址>&name=<名称> 由 Clash 系客户端分享订阅时使用,
 * 真实订阅地址与名称在查询参数中;解包后交由普通订阅流程下载。
 * 仅处理明文查询格式。sn://subscription 为 SagerNet 私有 Kryo 序列化容器,
 * 鸿蒙端无对应序列化能力,由 isSagerNetSubscriptionContainer 单独识别并明确提示。
 */
export function unwrapSubscriptionLink(text: string): UnwrappedSubscriptionLink | null {
  const trimmed = text === undefined || text === null ? '' : text.trim();
  if (!trimmed.toLowerCase().startsWith(CLASH_CONTAINER_PREFIX)) {
    return null;
  }
  const params = parseContainerQuery(trimmed.substring(CLASH_CONTAINER_PREFIX.length));
  const url = params['url'] !== undefined ? params['url'] : '';
  if (url.length === 0) {
    return null;
  }
  return { url: url, name: params['name'] !== undefined ? params['name'] : '' };
}

/** sn:// 前缀均为 SagerNet/NekoBox 私有 Kryo 序列化(universal link / subscription 容器),无法在鸿蒙端解包。 */
export function isSagerNetSubscriptionContainer(text: string): boolean {
  const trimmed = text === undefined || text === null ? '' : text.trim();
  return trimmed.toLowerCase().startsWith('sn://');
}

/**
 * content-disposition 里的 RFC 5987 文件名解码 — 逐字对齐 Android `Util.decodeFilename`
 * (Util.kt:194-199):用正则 `filename\*=[^']*''(.+)` 取编码串,再 URLDecoder(UTF-8)。
 * 取不到/解码失败 → 空串(Android 同样回落空串,调用方据此不改名)。
 */
export function decodeFilename(headerValue: string): string {
  const match = /filename\*=[^']*''(.+)/.exec(headerValue);
  const encoded = match !== null && match.length > 1 ? match[1] : '';
  if (encoded.length === 0) {
    return '';
  }
  try {
    return decodeURIComponent(encoded);
  } catch (e) {
    return '';
  }
}

function parseContainerQuery(query: string): Record<string, string> {
  const out: Record<string, string> = {};
  const parts = query.split('&');
  for (const part of parts) {
    if (part.length === 0) {
      continue;
    }
    const i = part.indexOf('=');
    if (i < 0) {
      continue;
    }
    const key = part.substring(0, i).toLowerCase();
    // 与 LinkParser.parseQuery 一致:'+' 按 RFC 3986 是字面字符,不做空格替换。
    // 订阅地址里带 '+' 的 token 很常见,替换成空格会让地址直接失效。
    const val = part.substring(i + 1);
    out[key] = percentDecodeSafe(val);
  }
  return out;
}

/** decodeURIComponent 的安全版:非法编码时保留原文,而不是抛异常 */
function percentDecodeSafe(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch (e) {
    // 保留原始值,避免非法编码导致整个链接不可用
    return s;
  }
}

export async function fetchSubscriptionWithInfo(url: string, allowInsecure: boolean = false, userAgent: string = ''): Promise<SubFetchResult> {
  return await doFetchSubscription(url, true, allowInsecure, userAgent, '', '');
}

/**
 * 条件请求:带上订阅上次响应里的 ETag / Last-Modified。
 * 服务端回 304 时不重下正文 —— 此前每次更新都全量拉取,机场侧同样会限流。
 * 两个校验器都没有时行为与 fetchSubscriptionWithInfo 一致。
 */
export async function fetchSubscriptionConditional(url: string, allowInsecure: boolean,
  userAgent: string, etag: string, lastModified: string): Promise<SubFetchResult> {
  return await doFetchSubscription(url, true, allowInsecure, userAgent, etag, lastModified);
}

export async function fetchSubscription(url: string, allowInsecure: boolean = false, userAgent: string = ''): Promise<string> {
  const r = await doFetchSubscription(url, false, allowInsecure, userAgent, '', '');
  return r.content;
}

function headerOf(respHeaders: Record<string, string> | undefined, name: string): string {
  if (respHeaders === undefined || respHeaders === null) {
    return '';
  }
  const keys = Object.keys(respHeaders);
  const lower = name.toLowerCase();
  for (const hk of keys) {
    if (hk.toLowerCase() === lower) {
      return respHeaders[hk];
    }
  }
  return '';
}

async function doFetchSubscription(url: string, withInfo: boolean, allowInsecure: boolean,
  userAgent: string, etag: string, lastModified: string): Promise<SubFetchResult> {
  const normalizedUrl = url.trim();
  if (!normalizedUrl.startsWith('https://') && !normalizedUrl.startsWith('http://')) {
    throw new Error('订阅地址必须使用 HTTP 或 HTTPS 协议');
  }
  const client = http.createHttp();
  try {
    const ua = userAgent.trim().length > 0 ? userAgent.trim() : SUB_UA;
    // 不要手动声明 Accept-Encoding。@ohos.net.http 的解压行为由平台自行协商,
    // 手动写死 gzip/deflate 等于要求平台按它未必支持的方式返回正文:实测会把
    // 压缩字节当 UTF-8 字符串解码,订阅正文变成乱码 → 解析出 0 个节点。
    // 平台默认就会协商压缩且能正确解压,所以这里一个编码头都不加。
    const headers: Record<string, string> = {
      'User-Agent': ua
    };
    if (etag.trim().length > 0) {
      headers['If-None-Match'] = etag.trim();
    }
    if (lastModified.trim().length > 0) {
      headers['If-Modified-Since'] = lastModified.trim();
    }
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.STRING,
      usingProtocol: http.HttpProtocol.HTTP1_1,
      connectTimeout: 15000,
      readTimeout: 30000
    };
    // 订阅请求放行不安全 TLS(对齐安卓 allowInsecureOnRequest;API 18+)
    if (allowInsecure) {
      opts.remoteValidation = 'skip';
    }
    const resp = await client.request(normalizedUrl, opts);
    const respHeaders = resp.header as Record<string, string>;
    if (resp.responseCode === 304) {
      // 内容未变更:调用方保留既有节点,只推进更新时刻
      const res304: SubFetchResult = {
        content: '',
        userinfo: withInfo ? headerOf(respHeaders, 'subscription-userinfo') : '',
        etag: headerOf(respHeaders, 'etag'),
        lastModified: headerOf(respHeaders, 'last-modified'),
        contentDisposition: withInfo ? headerOf(respHeaders, 'content-disposition') : '',
        notModified: true
      };
      return res304;
    }
    // 逐字对齐 Android libcore/http.go:219-226:Execute() 只在 StatusCode == 200 时
    // 返回正文,其余(含 204/206/3xx/4xx/5xx)一律当错误抛出,绝不把错误页当正文解析。
    if (resp.responseCode !== 200) {
      let snippet = '';
      const rb = resp.result;
      if (typeof rb === 'string' && rb.length > 0) {
        snippet = rb.replace(/\s+/g, ' ').trim().substring(0, 120);
      }
      throw new Error(`订阅服务器返回 HTTP ${resp.responseCode}${snippet.length > 0 ? ': ' + snippet : ''}`);
    }
    // 每次请求只读取自身响应头，避免多个订阅之间串用到期信息。
    const responseUserinfo = withInfo ? headerOf(respHeaders, 'subscription-userinfo') : '';
    const body: string | Object | ArrayBuffer = resp.result;
    const result: SubFetchResult = {
      content: typeof body === 'string' ? body : `${body}`,
      userinfo: responseUserinfo,
      etag: headerOf(respHeaders, 'etag'),
      lastModified: headerOf(respHeaders, 'last-modified'),
      contentDisposition: withInfo ? headerOf(respHeaders, 'content-disposition') : '',
      notModified: false
    };
    return result;
  } finally {
    client.destroy();
  }
}

/**
 * 拉取一个远程文本(供 proxy-providers 的远程节点集用)。
 * 复用订阅的 UA 与不安全 TLS 策略;provider 节点集通常与主订阅同源,
 * 因此不参与 ETag/304 语义(每次导入全量取,provider 条目数量级很小)。
 * 非 2xx 时抛出含状态码与正文片段的错误,便于 provider 失败时定位。
 */
export async function fetchTextUrl(url: string, allowInsecure: boolean, userAgent: string): Promise<string> {
  const r = await doFetchSubscription(url, false, allowInsecure, userAgent, '', '');
  return r.content;
}

export function parseSubUserInfo(header: string): SubUserInfo | null {
  const out: SubUserInfo = { upload: 0, download: 0, total: 0, expire: 0 };
  const parts = header.split(';');
  for (const p of parts) {
    const i = p.indexOf('=');
    if (i <= 0) {
      continue;
    }
    const k = p.substring(0, i).trim().toLowerCase();
    const v = Number(p.substring(i + 1).trim());
    if (isNaN(v)) {
      continue;
    }
    if (k === 'upload') {
      out.upload = v;
    } else if (k === 'download') {
      out.download = v;
    } else if (k === 'total') {
      out.total = v;
    } else if (k === 'expire') {
      out.expire = v;
    }
  }
  if (out.total <= 0 && out.expire <= 0) {
    return null;
  }
  return out;
}

export interface ClashParseResult {
  profiles: Array<Profile>;
  skipped: number;
  // 被跳过的节点名称。解析器能算出 skipped 计数,但此前调用方直接丢弃,
  // 用户只看到"少了一批节点"却无从查证。这里把名字带出来给 UI 提示。
  skippedNames: Array<string>;
  // 整体性说明(非空即表示订阅整体不可用或需要提示),例如只带 proxy-providers。
  note: string;
}

export function emptyClashParseResult(): ClashParseResult {
  return { profiles: [], skipped: 0, skippedNames: [], note: '' };
}

export function looksLikeClashYaml(text: string): boolean {
  return hasTopLevelKey(text, 'proxies') || hasTopLevelKey(text, 'proxy-providers');
}

// ---------------------------------------------------------------- Clash YAML

export function parseClashProxies(yaml: string): ClashParseResult {
  const result: ClashParseResult = emptyClashParseResult();
  let root: YamlNode;
  try {
    root = parseYaml(yaml);
  } catch (e) {
    result.note = 'clash_yaml_parse_failed';
    return result;
  }
  // Android RawUpdater.kt:241 读取 global-client-fingerprint:REALITY 节点未显式
  // 指纹时回退到它(仍为空再回退 chrome)。
  const globalFp = yStr(root, 'global-client-fingerprint');
  const proxies = root.get('proxies');
  if (proxies === null || !proxies.isSeq()) {
    result.note = root.get('proxy-providers') !== null
      ? 'clash_provider_only'
      : 'clash_no_proxies_key';
    return result;
  }
  for (const item of proxies.items) {
    const p = profileFromClash(item, globalFp);
    if (p === null) {
      result.skipped++;
      const nm = item.isMap() ? yStr(item, 'name', '') : '';
      if (nm.length > 0 && result.skippedNames.length < 20) {
        result.skippedNames.push(nm);
      }
    } else {
      result.profiles.push(p);
    }
  }
  return result;
}

// ---- YamlNode 取值助手 --------------------------------------------------
// 标量一律按字符串读,类型转换交给本层:这样不必在解析器里区分
// int/float/bool/null,也不会让 "443" 这类端口号在流转中丢精度。

function yNode(m: YamlNode | null, key: string): YamlNode | null {
  if (m === null || !m.isMap()) {
    return null;
  }
  return m.get(key);
}

function yStrOf(n: YamlNode | null, dflt: string = ''): string {
  if (n === null || !n.isScalar()) {
    return dflt;
  }
  return n.scalar;
}

function yStr(m: YamlNode | null, key: string, dflt: string = ''): string {
  return yStrOf(yNode(m, key), dflt);
}

function yStrAny(m: YamlNode | null, keys: Array<string>, dflt: string = ''): string {
  for (const k of keys) {
    const v = yStrOf(yNode(m, k), '');
    if (v.length > 0) {
      return v;
    }
  }
  return dflt;
}

function yNumOf(n: YamlNode | null): number {
  const s = yStrOf(n, '');
  if (s.length === 0) {
    return 0;
  }
  const x = Number(s);
  return isNaN(x) ? 0 : x;
}

function yNum(m: YamlNode | null, key: string): number {
  return yNumOf(yNode(m, key));
}

function yNumAny(m: YamlNode | null, keys: Array<string>): number {
  for (const k of keys) {
    const v = yNumOf(yNode(m, k));
    if (v > 0) {
      return v;
    }
  }
  return 0;
}

function yBoolOf(n: YamlNode | null): boolean {
  const s = yStrOf(n, '').toLowerCase();
  return s === 'true' || s === 'yes' || s === '1' || s === 'on';
}

function yBool(m: YamlNode | null, key: string): boolean {
  return yBoolOf(yNode(m, key));
}

/** 缺键时返回 dflt(Android 用 `?: dflt`,与"取到 0"必须区分)。 */
function yNumOr(n: YamlNode | null, dflt: number): number {
  const s = yStrOf(n, '');
  if (s.length === 0) {
    return dflt;
  }
  const x = Number(s);
  return isNaN(x) ? dflt : x;
}

/**
 * Android 的 `opt.key.replace("_", "-")` 归一化(RawUpdater.kt:498/525/578/611):
 * 先按原键取,再按下划线→连字符取,最后按连字符→下划线兜底。
 */
function yNorm(m: YamlNode | null, key: string): YamlNode | null {
  const direct = yNode(m, key);
  if (direct !== null) {
    return direct;
  }
  const dashed = yNode(m, key.split('_').join('-'));
  if (dashed !== null) {
    return dashed;
  }
  return yNode(m, key.split('-').join('_'));
}

function yStrNorm(m: YamlNode | null, key: string, dflt: string = ''): string {
  return yStrOf(yNorm(m, key), dflt);
}

/**
 * Android `String.isIpAddress()`(ktx/Nets.kt:27-29,NGUtil.isIpv4Address||isIpv6Address)。
 * 用于 "Fix ent" 的 SNI 回填与 tuic ip 分支。
 */
export function isIpLiteral(host: string): boolean {
  const h = host.trim();
  if (h.length === 0) {
    return false;
  }
  if (h.indexOf(':') >= 0) {
    return true; // IPv6 字面量
  }
  const parts = h.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) {
      return false;
    }
    const n = parseInt(part, 10);
    if (n < 0 || n > 255) {
      return false;
    }
  }
  return true;
}

/** 列表值:既接受 YAML 序列 [a, b],也接受逗号分隔字符串 "a,b"。 */
function yList(m: YamlNode | null, key: string): Array<string> {
  const n = yNode(m, key);
  if (n === null) {
    return [];
  }
  const out: Array<string> = [];
  if (n.isSeq()) {
    for (const it of n.items) {
      const s = yStrOf(it, '');
      if (s.length > 0) {
        out.push(s);
      }
    }
    return out;
  }
  if (n.isScalar() && n.scalar.length > 0) {
    for (const part of n.scalar.split(',')) {
      const t = part.trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
  }
  return out;
}

/** headers 里的 Host 可能是标量,也可能是单元素序列。 */
function yHeader(oo: YamlNode | null, keys: Array<string>): string {
  const h = yNode(oo, 'headers');
  if (h === null || !h.isMap()) {
    return '';
  }
  for (const k of keys) {
    const v = h.get(k);
    if (v === null) {
      continue;
    }
    if (v.isSeq()) {
      for (const it of v.items) {
        const s = yStrOf(it, '');
        if (s.length > 0) {
          return s;
        }
      }
      continue;
    }
    const s = yStrOf(v, '');
    if (s.length > 0) {
      return s;
    }
  }
  return '';
}

/**
 * Clash 传输层 -> Profile 字段。
 * 逐字对齐 Android RawUpdater.kt:386-464:
 *  - `network`:只有 h2/http 映射为 http、ws/grpc 原样;其它取值(含 tcp/none/未知)
 *    一律保持默认(Android 的 VMessBean.type 默认 "tcp",不认识的取值不写回);
 *  - ws-opts / h2-opts / http-opts / grpc-opts 各自独立生效,与 network 取值无关;
 *  - List 型字段用 "\n" join(Android joinToString("\n"))。
 */
function joinLines(n: YamlNode | null): string {
  if (n === null) {
    return '';
  }
  if (n.isSeq()) {
    const parts: Array<string> = [];
    for (const it of n.items) {
      parts.push(yStrOf(it, ''));
    }
    return parts.join('\n');
  }
  return yStrOf(n, '');
}

function applyClashTransport(p: Profile, m: YamlNode): void {
  const net = yStr(m, 'network');
  // Android: "h2","http" -> "http"; "ws","grpc" -> 原值; 其余不动
  if (net === 'h2' || net === 'http') {
    p.transport = 'http';
  } else if (net === 'ws' || net === 'grpc') {
    p.transport = net;
  }
  const ws = yNode(m, 'ws-opts');
  if (ws !== null && ws.isMap()) {
    p.path = yStr(ws, 'path');
    p.host = yHeader(ws, ['Host', 'host']);
    p.wsEarlyData = yNum(ws, 'max-early-data');
    p.wsEarlyDataHeaderName = yStr(ws, 'early-data-header-name');
    // Android 不清理已写入的 early-data(v2ray-http-upgrade 只改 type)
    if (yBool(ws, 'v2ray-http-upgrade')) {
      p.transport = 'httpupgrade';
    }
  }
  const h2 = yNode(m, 'h2-opts');
  if (h2 !== null && h2.isMap()) {
    p.path = yStr(h2, 'path');
    p.host = joinLines(yNode(h2, 'host'));
  }
  const httpOpts = yNode(m, 'http-opts');
  if (httpOpts !== null && httpOpts.isMap()) {
    p.path = joinLines(yNode(httpOpts, 'path'));
    p.host = joinLines(yHeaderNode(httpOpts, ['Host', 'host']));
  }
  const grpc = yNode(m, 'grpc-opts');
  if (grpc !== null && grpc.isMap()) {
    // Android: grpc-service-name -> bean.path(鸿蒙用独立的 serviceName 字段承载,
    // 字段映射差异,生成配置时语义等价)
    p.serviceName = yStr(grpc, 'grpc-service-name');
  }
}

/** headers.<key> 取出节点本身(供 "\n" join 的 List 形态)。 */
function yHeaderNode(oo: YamlNode, keys: Array<string>): YamlNode | null {
  const h = yNode(oo, 'headers');
  if (h === null || !h.isMap()) {
    return null;
  }
  for (const k of keys) {
    const v = h.get(k);
    if (v !== null) {
      return v;
    }
  }
  return null;
}

function applyClashReality(p: Profile, m: YamlNode, globalFp: string = ''): void {
  const r = yNode(m, 'reality-opts');
  if (r === null || !r.isMap()) {
    return;
  }
  p.realityPublicKey = yStrAny(r, ['public-key', 'publicKey']);
  p.realityShortId = yStr(r, 'short-id');
  // Android: reality-opts 的每个子键都会把 security 置为 "tls"(RawUpdater.kt:372-384)
  p.tls = true;
  // 对齐安卓 RawUpdater.kt:669-672:REALITY 节点**有 pubkey** 且无显式指纹时,
  // 先回退 global-client-fingerprint,仍为空再回退 chrome。
  if (p.realityPublicKey.length > 0 && p.fingerprint.length === 0) {
    p.fingerprint = globalFp.length > 0 ? globalFp : 'chrome';
  }
}

/**
 * Android RawUpdater.kt:660-674 "Fix ent" 第 1 条(仅 StandardV2RayBean:vmess/vless/trojan):
 * `isTLS() && sni.isNullOrBlank() && host 非空 && host 不是 IP` → `sni = host`。
 * (第 2 条 REALITY 指纹回退在 applyClashReality 内,同样逐字。)
 */
function applyClashFixEnt(p: Profile): void {
  if (p.tls && p.sni.trim().length === 0 && p.host.trim().length > 0 && !isIpLiteral(p.host)) {
    p.sni = p.host;
  }
}

/**
 * Clash smux -> multiplex 字段。
 * 逐字对齐 Android RawUpdater.kt:466-479:三个子键各自独立生效,
 * `enabled` 直接把开关**写成**其字面值(给 false 就是关),`max-streams` 用 toInt。
 */
function applyClashMux(p: Profile, m: YamlNode): void {
  const mu = yNode(m, 'smux');
  if (mu === null || !mu.isMap()) {
    return;
  }
  const enabled = yNode(mu, 'enabled');
  if (enabled !== null) {
    p.mux = yStrOf(enabled) === 'true';
  }
  const streams = yNode(mu, 'max-streams');
  if (streams !== null) {
    const n = Number(yStrOf(streams));
    if (!isNaN(n)) {
      p.muxMaxStreams = n;
    }
  }
  const padding = yNode(mu, 'padding');
  if (padding !== null) {
    p.muxPadding = yStrOf(padding) === 'true';
  }
}

/** Clash ech-opts.enable -> ECH 开关(Android RawUpdater.kt:481-488)。 */
function applyClashEch(p: Profile, m: YamlNode): void {
  const eo = yNode(m, 'ech-opts');
  if (eo === null || !eo.isMap()) {
    return;
  }
  const enable = yNode(eo, 'enable');
  if (enable !== null) {
    p.ech = yStrOf(enable) === 'true';
  }
}

/** Clash 的带宽字段可能是 "30" 或 "30 Mbps"(Android: substringBefore(" ").toIntOrNull()) */
function parseBandwidth(raw: string): number {
  const n = parseInt(raw.trim());
  return isNaN(n) ? 0 : n;
}

/** 同上,但取不到/解析失败时返回 dflt(Android 的 `?: dflt`)。 */
function yBandwidthOr(n: YamlNode | null, dflt: number): number {
  const s = yStrOf(n, '');
  if (s.length === 0) {
    return dflt;
  }
  const spaced = s.trim().indexOf(' ');
  const token = spaced >= 0 ? s.trim().substring(0, spaced) : s.trim();
  const x = parseInt(token);
  return isNaN(x) ? dflt : x;
}

function profileFromClash(m: YamlNode | null, globalFp: string = ''): Profile | null {
  if (m === null || !m.isMap()) {
    return null;
  }
  const type = yStr(m, 'type').toLowerCase();
  const p = new Profile();
  p.name = yStr(m, 'name');
  p.server = yStr(m, 'server');
  p.serverPort = yNum(m, 'port');
  if (p.server.length === 0 || p.serverPort <= 0) {
    return null;
  }
  // uTLS 指纹(vless/hysteria2/tuic 均可携带;reality 出站内核强制要求 uTLS)
  const clientFp = yStr(m, 'client-fingerprint');
  if (clientFp.length > 0) {
    p.fingerprint = clientFp;
  }
  // 以下几项此前只对个别协议读取,这里提升为全类型通用
  p.allowInsecure = yBool(m, 'skip-cert-verify');
  p.sni = yStrAny(m, ['servername', 'sni']);
  const alpn = yList(m, 'alpn');
  if (alpn.length > 0) {
    p.alpn = alpn.join(',');
  }
  // dialer-proxy:本节点的出站先经该节点转发(对齐 sing-box detour)
  p.dialerProxyName = yStr(m, 'dialer-proxy');
  switch (type) {
    case 'ss':
      p.type = ProfileType.SHADOWSOCKS;
      p.method = yStr(m, 'cipher', yStr(m, 'method'));
      p.password = yStr(m, 'password');
      {
        // 对齐安卓 RawUpdater.kt:272-305:Clash 的 ss 节点可携带
        // plugin/plugin-opts(obfs / v2ray-plugin)。此前整段丢弃,
        // 带插件的 ss 节点导入后必然握手失败。
        const pluginNode = yNode(m, 'plugin');
        if (pluginNode !== null && pluginNode.isScalar() && yStrOf(pluginNode, '').length > 0) {
          const oo = yNode(m, 'plugin-opts');
          const parts: Array<string> = [];
          if (yStrOf(pluginNode, '') === 'obfs') {
            // Android RawUpdater.kt:277-283
            parts.push('obfs-local');
            parts.push('obfs=' + (oo !== null && oo.isMap() ? yStr(oo, 'mode') : ''));
            parts.push('obfs-host=' + (oo !== null && oo.isMap() ? yStr(oo, 'host') : ''));
          } else if (yStrOf(pluginNode, '') === 'v2ray-plugin') {
            // 逐字复刻安卓 RawUpdater.kt:285-294(含其上游怪癖:
            // tls 只在 mode 字面等于 "true" 时追加,与 opts.tls 无关)。
            const optsMode = oo !== null && oo.isMap() ? yStr(oo, 'mode') : '';
            const optsMux = oo !== null && oo.isMap() ? yStr(oo, 'mux') : '';
            parts.push('v2ray-plugin');
            parts.push('mode=' + optsMode);
            if (optsMode === 'true') {
              parts.push('tls');
            }
            parts.push('host=' + (oo !== null && oo.isMap() ? yStr(oo, 'host') : ''));
            parts.push('path=' + (oo !== null && oo.isMap() ? yStr(oo, 'path') : ''));
            if (optsMux === 'true') {
              parts.push('mux=8');
            }
          }
          if (parts.length > 0) {
            p.ssPlugin = parts[0];
            if (parts.length > 1) {
              p.ssPluginOpts = parts.slice(1).join(';');
            }
          }
        }
      }
      break;
    case 'vmess':
      p.type = ProfileType.VMESS;
      p.uuid = yStr(m, 'uuid');
      // Android: alterId -> toIntOrNull();取不到时保持 bean 默认
      p.alterId = yNumOr(yNode(m, 'alterId'), p.alterId);
      // Android: cipher -> encryption(仅非 VLESS)
      p.security = yStr(m, 'cipher', 'auto');
      // Android: tls 键 -> security = "tls"/""
      p.tls = yBool(m, 'tls');
      p.packetEncoding = yStr(m, 'packet-encoding');
      applyClashMux(p, m);
      applyClashTransport(p, m);
      applyClashEch(p, m);
      applyClashFixEnt(p);
      break;
    case 'vless':
      p.type = ProfileType.VLESS;
      // Android: alterId = -1 表 VLESS(RawUpdater.kt:310-313)
      p.alterId = -1;
      p.uuid = yStr(m, 'uuid');
      // Android RawUpdater.kt:340-346:flow 只有含 "xtls-rprx-vision" 才写 encryption
      if (yStrNorm(m, 'flow').indexOf('xtls-rprx-vision') >= 0) {
        p.flow = 'xtls-rprx-vision';
      }
      // Android: packet-encoding 分支对 VMessBean 全族生效(含 VLESS)
      p.packetEncoding = yStr(m, 'packet-encoding');
      p.tls = yBool(m, 'tls');
      applyClashReality(p, m, globalFp);
      applyClashMux(p, m);
      applyClashTransport(p, m);
      applyClashEch(p, m);
      applyClashFixEnt(p);
      break;
    case 'trojan':
      p.type = ProfileType.TROJAN;
      p.password = yStr(m, 'password');
      // Android: TrojanBean 构造时 security="tls";但 tls 键会覆盖它(RawUpdater.kt:356-359)
      p.tls = yNode(m, 'tls') !== null ? yBool(m, 'tls') : true;
      applyClashReality(p, m, globalFp);
      applyClashMux(p, m);
      applyClashTransport(p, m);
      applyClashEch(p, m);
      applyClashFixEnt(p);
      break;
    case 'hysteria':
      p.type = ProfileType.HYSTERIA;
      // Android RawUpdater.kt:533-536:只有 auth-str 才把 authPayloadType 设为 STRING;
      // auth 键(1.x 的 base64 档)在 Profile 里同样落到 password。
      p.password = yStrNorm(m, 'auth-str');
      if (p.password.length === 0) {
        p.password = yStrNorm(m, 'auth');
      }
      // Android: up/down = value.substringBefore(" ").toIntOrNull() ?: 100;
      // 键缺失时不赋值,交给 HysteriaBean.initializeDefaultValues(protocolVersion=1 → 10/50)。
      {
        const upNode = yNorm(m, 'up');
        const downNode = yNorm(m, 'down');
        p.upMbps = upNode === null ? 10 : yBandwidthOr(upNode, 100);
        p.downMbps = downNode === null ? 50 : yBandwidthOr(downNode, 100);
      }
      p.obfs = yStrNorm(m, 'obfs');
      p.tls = true;
      // Android: alpn 仅在键存在时处理(List join "\n",非 List 则 "h3");缺键保持默认 ""
      {
        const h1Alpn = yNode(m, 'alpn');
        if (h1Alpn === null) {
          p.alpn = '';
        } else if (h1Alpn.isSeq()) {
          p.alpn = joinLines(h1Alpn).split('\n').join(',');
        } else {
          p.alpn = 'h3';
        }
      }
      // 对齐安卓 RawUpdater.kt:528-529,566-568:hysteria1 的 port 字段直接进
      // serverPorts(可带 "443" 单值),ports 键(端口跳跃列表)覆盖之。
      // (Profile 内部以 '-' 表示区间,ConfigBuilder.normalizeServerPorts 再还原成 ':'。)
      {
        const p1Port = yStr(m, 'port');
        const p1Hop = yStr(m, 'ports');
        if (p1Hop.length > 0) {
          p.serverPorts = p1Hop.replace(/:/g, '-');
        } else if (p1Port.length > 0) {
          p.serverPorts = p1Port.replace(/:/g, '-');
        }
      }
      break;
    case 'hysteria2':
    case 'hy2':
      p.type = ProfileType.HYSTERIA2;
      p.password = yStrNorm(m, 'password');
      p.tls = true;
      p.obfs = yStrNorm(m, 'obfs-password');
      // Android: hysteria2 的 up/down 兜底是 0(RawUpdater.kt:593-597),
      // 与 hysteria1 的 100 不同。
      p.upMbps = yBandwidthOr(yNorm(m, 'up'), 0);
      p.downMbps = yBandwidthOr(yNorm(m, 'down'), 0);
      // Android 的 hysteria2 分支不处理 alpn(RawUpdater.kt:572-604)
      p.alpn = '';
      // 端口跳跃:Clash 的 ports 既可能是标量("1000-2000"),也可能是 YAML 序列
      // ([1000-2000, 3000])。序列形态是鸿蒙超集(Android toString() 会得到
      // "[1000-2000, 3000]" 这种不可用字符串),已列入偏差清单。
      {
        const portsNode = yNode(m, 'ports');
        if (portsNode !== null && portsNode.isSeq()) {
          const parts: Array<string> = [];
          for (const it of portsNode.items) {
            const seg = yStrOf(it, '').trim().replace(/:/g, '-');
            if (seg.length > 0) {
              parts.push(seg);
            }
          }
          p.serverPorts = parts.join(',');
        } else {
          p.serverPorts = yStr(m, 'ports').replace(/:/g, '-');
        }
      }
      // Android 不处理 hop-interval(鸿蒙超集,见偏差清单)
      {
        const hop = yNum(m, 'hop-interval');
        if (hop > 0) {
          p.hopInterval = hop;
        }
      }
      break;
    case 'tuic':
      p.type = ProfileType.TUIC;
      p.uuid = yStr(m, 'uuid');
      // Android RawUpdater.kt:617-624:token 键把 protocolVersion 置 4 并写 token;
      // password 键写的是 token 字段(Profile 无 token 字段,统一落 password)。
      {
        const tuicToken = yStrNorm(m, 'token');
        const tuicPass = yStrNorm(m, 'password');
        p.password = tuicToken.length > 0 ? tuicToken : tuicPass;
      }
      p.tls = true;
      // Android: TuicBean.initializeDefaultValues 的 congestionController 默认是 "cubic"(非 bbr)
      p.congestionControl = yStrNorm(m, 'congestion-controller', 'cubic');
      p.udpRelayMode = yStrNorm(m, 'udp-relay-mode', 'native');
      p.reduceRtt = yBool(m, 'reduce-rtt');
      p.disableSni = yBool(m, 'disable-sni');
      // Android tuic 的 alpn:键存在才处理(List join "\n"),缺键保持默认 ""
      {
        const tAlpn = yNode(m, 'alpn');
        p.alpn = (tAlpn !== null && tAlpn.isSeq()) ? joinLines(tAlpn).split('\n').join(',') : '';
      }
      // Android RawUpdater.kt:649-654 **字面复刻**(含其上游 bug):
      //   serverAddress 先被覆盖成 ip,随后判断的是 `!serverAddress.isIpAddress()`,
      //   由于 ip 本身就是 IP 字面量,该条件永假 → **实际上不会回填 SNI**。
      //   鸿蒙此前用「原域名」回填 sni(修复意图),为 1:1 已删除。
      {
        const tuicIp = yStr(m, 'ip');
        if (tuicIp.length > 0) {
          p.server = tuicIp;
          if (p.sni.trim().length === 0 && !isIpLiteral(p.server)) {
            p.sni = p.server;
          }
        }
      }
      break;
    case 'anytls':
      p.type = ProfileType.ANYTLS;
      // Android RawUpdater.kt:494-517:逐键 `replace("_","-")` 归一化
      p.password = yStrNorm(m, 'password');
      {
        const anytlsFp = yStrNorm(m, 'client-fingerprint');
        if (anytlsFp.length > 0) {
          p.fingerprint = anytlsFp;
        }
        if (yBoolOf(yNorm(m, 'skip-cert-verify'))) {
          p.allowInsecure = true;
        }
        const anytlsAlpn = yNode(m, 'alpn');
        if (anytlsAlpn !== null && anytlsAlpn.isSeq()) {
          p.alpn = joinLines(anytlsAlpn).split('\n').join(',');
        }
      }
      p.tls = true;
      break;
    case 'snell': {
      p.type = ProfileType.SNELL;
      p.password = yStrAny(m, ['psk', 'password']);
      p.obfs = yStr(m, 'obfs');
      p.host = yStr(m, 'obfs-host');
      // Clash 的 snell 默认 v3(带 TLS);v1/v2 才是明文
      const ver = yNum(m, 'version');
      p.tls = !(ver === 1 || ver === 2);
      break;
    }
    // 以下类型此前整批落到 default 被丢弃,但 Profile 模型与分享链接解析器
    // 本来就支持 —— 走 Clash YAML 反而导入不了,属能力倒挂。
    case 'http':
      p.type = ProfileType.HTTP;
      p.username = yStr(m, 'username');
      p.password = yStr(m, 'password');
      p.tls = yBool(m, 'tls');
      break;
    // Clash 的 SOCKS 代理 type 惯例写法是 socks5(不是 socks),两种写法都收
    case 'socks':
    case 'socks5':
      p.type = ProfileType.SOCKS;
      p.username = yStr(m, 'username');
      p.password = yStr(m, 'password');
      p.tls = yBool(m, 'tls');
      break;
    case 'ssh':
      p.type = ProfileType.SSH;
      p.username = yStr(m, 'username');
      p.password = yStr(m, 'password');
      p.privateKey = yStrAny(m, ['private-key', 'privateKey']);
      p.privateKeyPassphrase = yStrAny(m, ['private-key-passphrase', 'passphrase']);
      p.sshAuthType = p.privateKey.length > 0 ? 'private_key'
        : (p.password.length > 0 ? 'password' : 'none');
      p.tls = false;
      break;
    case 'wireguard':
      p.type = ProfileType.WIREGUARD;
      p.privateKey = yStrAny(m, ['private-key', 'privateKey']);
      p.peerPublicKey = yStrAny(m, ['public-key', 'publicKey']);
      p.preSharedKey = yStr(m, 'pre-shared-key');
      const wgIp = yStr(m, 'ip');
      const wgIpv6 = yStr(m, 'ipv6');
      if (wgIpv6.length > 0) {
        p.localAddress = wgIpv6;
      } else if (wgIp.length > 0) {
        p.localAddress = wgIp;
      }
      const wgMtu = yNum(m, 'mtu');
      p.wgMtu = wgMtu > 0 ? wgMtu : 1420;
      p.reserved = yStr(m, 'reserved');
      break;
    case 'shadowtls':
      p.type = ProfileType.SHADOWTLS;
      p.shadowtlsVersion = yNum(m, 'version') === 2 ? 2 : 3;
      p.password = yStr(m, 'password');
      p.tls = true;
      break;
    default:
      // ssr / hysteria3 / juicity / mieru / tailscale / naive 等内核不支持的类型跳过
      return null;
  }
  return p;
}

// ---------------------------------------------------------------- sing-box JSON

export function looksLikeSingBoxJson(text: string): boolean {
  const t = text.trim();
  if (!t.startsWith('{')) {
    return false;
  }
  // 结构化判定而非子串匹配:既补上 endpoints-only 的配置(WireGuard 端点),
  // 也避免正文任意位置出现 "outbounds" 子串就被误判成 sing-box JSON。
  try {
    const o = JSON.parse(t) as Record<string, Object>;
    return Array.isArray(o['outbounds']) || Array.isArray(o['endpoints']);
  } catch (e) {
    return false;
  }
}

/** 统一订阅链路错误文本(裸对象不再显示 [object Object]) */
export function subErrorText(e: Object): string {
  if (e instanceof Error) {
    return e.message;
  }
  if (typeof e === 'object' && e !== null) {
    const m = (e as Record<string, Object>)['message'];
    if (m !== undefined && m !== null && `${m}`.length > 0) {
      return `${m}`;
    }
    try {
      const s = JSON.stringify(e);
      if (s !== undefined && s !== null && s.length > 0 && s !== '{}') {
        return s.length > 160 ? s.substring(0, 160) : s;
      }
    } catch (err) {
      // ignore
    }
  }
  return `${e}`;
}

function sbStr(o: Record<string, Object>, k: string, dflt: string = ''): string {
  const v = o[k];
  if (v === undefined || v === null) {
    return dflt;
  }
  return `${v}`;
}

function sbNum(o: Record<string, Object>, k: string): number {
  const v = o[k];
  if (typeof v === 'number') {
    return v;
  }
  const x = Number(`${v}`);
  return isNaN(x) ? 0 : x;
}

function sbBool(o: Record<string, Object>, k: string): boolean {
  return o[k] === true || `${o[k]}` === 'true';
}

/** 依次尝试多个键,取第一个非空标量(对齐 Clash 侧的 yStrAny) */
function sbStrAny(o: Record<string, Object>, keys: Array<string>, dflt: string = ''): string {
  for (const k of keys) {
    const v = sbStr(o, k);
    if (v.length > 0) {
      return v;
    }
  }
  return dflt;
}

/**
 * sing-box 出站的 transport / multiplex / packet_encoding -> Profile 字段。
 * 与 Clash 分支的 applyClashTransport 语义对齐;同时兼容 legacy 1.8 平铺字段。
 */
function sbApplyTransport(p: Profile, o: Record<string, Object>): void {
  const transport = o['transport'];
  if (transport !== undefined && transport !== null) {
    const t = transport as Record<string, Object>;
    p.transport = sbStr(t, 'type');
    if (p.transport === 'httpupgrade' || p.transport === 'ws') {
      p.path = sbStr(t, 'path');
      const h = t['headers'];
      if (h !== undefined && h !== null) {
        const hm = h as Record<string, Object>;
        p.host = sbStr(hm, 'Host', sbStr(hm, 'host'));
      }
    } else if (p.transport === 'grpc') {
      p.serviceName = sbStr(t, 'service_name');
    } else {
      p.path = sbStr(t, 'path');
    }
  } else {
    // legacy 1.8:network / ws_path / grpc_service_name 平铺在出站顶层
    p.transport = sbStr(o, 'network');
    p.path = sbStrAny(o, ['path', 'ws_path', 'grpc_service_name', 'service_name']);
    p.host = sbStr(o, 'host');
    if (p.transport === 'grpc' && p.path.length > 0) {
      p.serviceName = p.path;
      p.path = '';
    }
  }
  const mux = o['multiplex'];
  if (mux !== undefined && mux !== null) {
    const m = mux as Record<string, Object>;
    if (sbBool(m, 'enabled')) {
      p.mux = true;
      p.muxProtocol = sbStr(m, 'protocol', 'h2mux');
      const max = sbNum(m, 'max_streams');
      p.muxMaxStreams = max > 0 ? max : 8;
    }
  }
  p.packetEncoding = sbStr(o, 'packet_encoding');
}

function sbApplyTls(p: Profile, tlsObj: Object): void {
  const tls = tlsObj as Record<string, Object>;
  p.tls = tls['enabled'] !== false;
  p.sni = sbStr(tls, 'server_name');
  p.allowInsecure = sbBool(tls, 'insecure');
  const alpnRaw = tls['alpn'];
  if (alpnRaw !== undefined && alpnRaw !== null) {
    const parts: Array<string> = [];
    for (const a of alpnRaw as Array<string>) {
      parts.push(`${a}`);
    }
    p.alpn = parts.join(',');
  }
  const utls = tls['utls'];
  if (utls !== undefined && utls !== null) {
    p.fingerprint = sbStr(utls as Record<string, Object>, 'fingerprint');
  }
  const reality = tls['reality'];
  if (reality !== undefined && reality !== null) {
    const r = reality as Record<string, Object>;
    p.realityPublicKey = sbStr(r, 'public_key');
    p.realityShortId = sbStr(r, 'short_id');
    p.tls = true;
  }
}

function profileFromSingBoxOutbound(o: Record<string, Object>): Profile | null {
  const type = sbStr(o, 'type');
  const p = new Profile();
  p.name = sbStr(o, 'tag');
  p.server = sbStr(o, 'server');
  p.serverPort = sbNum(o, 'server_port');
  switch (type) {
    case 'shadowsocks':
      p.type = ProfileType.SHADOWSOCKS;
      p.method = sbStr(o, 'method');
      p.password = sbStr(o, 'password');
      break;
    case 'vmess':
      p.type = ProfileType.VMESS;
      p.uuid = sbStr(o, 'uuid');
      p.alterId = sbNum(o, 'alter_id');
      p.security = sbStr(o, 'security', 'auto');
      break;
    case 'vless':
      p.type = ProfileType.VLESS;
      p.uuid = sbStr(o, 'uuid');
      p.flow = sbStr(o, 'flow');
      break;
    case 'trojan':
      p.type = ProfileType.TROJAN;
      p.password = sbStr(o, 'password');
      p.tls = true;
      break;
    case 'hysteria':
      p.type = ProfileType.HYSTERIA;
      p.password = sbStr(o, 'password', sbStr(o, 'auth'));
      p.upMbps = sbNum(o, 'up_mbps');
      p.downMbps = sbNum(o, 'down_mbps');
      p.obfs = sbStr(o, 'obfs');
      p.tls = true;
      break;
    case 'hysteria2': {
      p.type = ProfileType.HYSTERIA2;
      p.password = sbStr(o, 'password');
      const obfs = o['obfs'];
      if (obfs !== undefined && obfs !== null) {
        if (typeof obfs === 'string') {
          p.obfs = `${obfs}`;
        } else {
          p.obfs = sbStr(obfs as Record<string, Object>, 'password');
        }
      }
      p.serverPorts = sbStr(o, 'server_ports').replace(/:/g, '-');
      p.tls = true;
      break;
    }
    case 'tuic':
      p.type = ProfileType.TUIC;
      p.uuid = sbStr(o, 'uuid');
      p.password = sbStr(o, 'password');
      p.congestionControl = sbStr(o, 'congestion_control', 'bbr');
      p.udpRelayMode = sbStr(o, 'udp_relay_mode', 'native');
      p.tls = true;
      break;
    case 'http':
      p.type = ProfileType.HTTP;
      p.username = sbStr(o, 'username');
      p.password = sbStr(o, 'password');
      break;
    case 'socks':
      p.type = ProfileType.SOCKS;
      p.username = sbStr(o, 'username');
      p.password = sbStr(o, 'password');
      break;
    case 'ssh': {
      p.type = ProfileType.SSH;
      p.username = sbStr(o, 'user');
      p.password = sbStr(o, 'password');
      p.privateKey = sbStr(o, 'private_key');
      p.privateKeyPassphrase = sbStr(o, 'private_key_passphrase');
      p.sshAuthType = p.privateKey.length > 0 ? 'private_key'
        : (p.password.length > 0 ? 'password' : 'none');
      const hk = o['host_key'];
      if (hk !== undefined && hk !== null) {
        const parts: Array<string> = [];
        for (const k of hk as Array<string>) {
          parts.push(`${k}`);
        }
        p.hostKey = parts.join(',');
      }
      break;
    }
    case 'shadowtls':
      p.type = ProfileType.SHADOWTLS;
      p.shadowtlsVersion = sbNum(o, 'version') === 2 ? 2 : 3;
      p.password = sbStr(o, 'password');
      p.tls = true;
      break;
    case 'anytls':
      p.type = ProfileType.ANYTLS;
      p.password = sbStr(o, 'password');
      p.tls = true;
      break;
    case 'snell':
      p.type = ProfileType.SNELL;
      p.password = sbStr(o, 'psk');
      p.obfs = sbStr(o, 'obfs_mode');
      p.host = sbStr(o, 'name');
      break;
    default: {
      // 对齐安卓 RawUpdater.parseJSON:除 selector/urltest/direct/block/dns 外的
      // 出站一律按 ConfigBean(自定义出站)原样保留整份 JSON,而不是跳过。
      // 已知类型仍映射为结构化节点,但原始出站 JSON 存入 extra,
      // buildOutbound 的深合并会把内核支持而模型未覆盖的字段原样带回。
      // 与 Android RawUpdater.kt:772-776 的过滤名单逐字一致:
      // 只跳过 空 type / dns / block / direct / selector / urltest。
      // **group 与 wireguard 不跳过**(降级协议与 WG 出站都按 ConfigBean 原样保留)。
      const skipTypes: Array<string> = ['dns', 'block', 'direct', 'selector', 'urltest'];
      if (skipTypes.indexOf(type) >= 0) {
        return null;
      }
      if (Object.keys(o).length === 0) {
        return null;
      }
      p.type = ProfileType.CUSTOM;
      p.customOutbound = JSON.stringify(o);
      return p;
    }
  }
  // 已知协议分支仍要求 server/port 有效(CUSTOM 分支已提前 return)
  if (p.server.length === 0 || p.serverPort <= 0) {
    return null;
  }
  const tlsObj = o['tls'];
  if (tlsObj !== undefined && tlsObj !== null) {
    sbApplyTls(p, tlsObj);
  }
  // D1: sing-box JSON 的 transport / multiplex / packet_encoding 之前整个丢弃,
  // 使转换站导出的节点全部退化为裸 TCP + 默认 TLS(“节点存在但一个连不上”)。
  sbApplyTransport(p, o);
  // sing-box 的 detour 引用另一个出站的 tag,与 Clash dialer-proxy 语义一致。
  // 这里记原始 tag,由 Subscriptions.updateSubscription 解析成 dialerProxyId。
  const detour = sbStr(o, 'detour');
  if (detour.length > 0) {
    p.dialerProxyName = detour;
  }
  // 对齐安卓 ConfigBean 语义:原始出站 JSON 存入 extra,buildOutbound 深合并时
  // 内核支持而 Profile 模型未覆盖的字段(如 tcp_fast_open、domain_strategy 等)
  // 原样保留。tag/detour 由出站图管理,buildProfileGraph 在合并后会覆写。
  p.extra = JSON.stringify(o);
  return p;
}

function profileFromSingBoxEndpoint(ep: Record<string, Object>): Profile | null {
  if (sbStr(ep, 'type') !== 'wireguard') {
    return null;
  }
  const p = new Profile();
  p.type = ProfileType.WIREGUARD;
  p.name = sbStr(ep, 'tag');
  p.server = sbStr(ep, 'server');
  p.serverPort = sbNum(ep, 'server_port');
  if (p.server.length === 0 || p.serverPort <= 0) {
    return null;
  }
  p.privateKey = sbStr(ep, 'private_key');
  p.wgMtu = sbNum(ep, 'mtu') > 0 ? sbNum(ep, 'mtu') : 1420;
  const la = ep['local_address'];
  if (la !== undefined && la !== null) {
    const parts: Array<string> = [];
    for (const a of la as Array<string>) {
      parts.push(`${a}`);
    }
    p.localAddress = parts.join(',');
  }
  const peers = ep['peers'];
  if (peers !== undefined && peers !== null) {
    const list = peers as Array<Record<string, Object>>;
    if (list.length > 0) {
      const peer = list[0];
      p.peerPublicKey = sbStr(peer, 'public_key');
      p.preSharedKey = sbStr(peer, 'pre_shared_key');
      const res = peer['reserved'];
      if (res !== undefined && res !== null) {
        if (typeof res === 'string') {
          p.reserved = `${res}`;
        } else {
          const parts: Array<string> = [];
          for (const n of res as Array<number>) {
            parts.push(`${n}`);
          }
          p.reserved = parts.join(',');
        }
      }
    }
  }
  return p;
}

/** Android `JSONObject.has(k)`:键存在即为真(值可为空/非字符串)。 */
function hasKey(o: Record<string, Object>, k: string): boolean {
  return o[k] !== undefined;
}

/**
 * Android `ktx/Formats.kt:51-64 isJsonObjectValid`:
 * 对象/数组直接为真;字符串尝试按 JSON 解析(解析出对象/数组即为真)。
 */
function isJsonObjectValid(j: Object): boolean {
  if (j === null || j === undefined) {
    return false;
  }
  if (typeof j === 'object') {
    return true;
  }
  if (typeof j === 'string') {
    try {
      const parsed = JSON.parse(j as string) as Object;
      return parsed !== null && typeof parsed === 'object';
    } catch (e) {
      return false;
    }
  }
  return false;
}

interface JsonParseOutcome {
  matched: boolean;
  profiles: Array<Profile>;
  skipped: number;
}

function emptyJsonOutcome(): JsonParseOutcome {
  return { matched: false, profiles: [], skipped: 0 };
}

/**
 * 逐字对齐 Android `RawUpdater.parseJSON`(RawUpdater.kt:751-808):
 *  - JSONObject 走 `when {...}` —— **只命中第一个分支**;
 *  - JSONArray 逐元素 `isJsonObjectValid` 后递归;
 *  - 出站过滤:type 为空 或 dns/block/direct/selector/urltest → 丢弃,
 *    其余(含 group / wireguard)**全部保留**(Android 用 ConfigBean 原样存整份 JSON)。
 */
function parseJsonValue(json: Object): JsonParseOutcome {
  const out: JsonParseOutcome = emptyJsonOutcome();
  if (json === null || json === undefined) {
    return out;
  }
  if (Array.isArray(json)) {
    // Android RawUpdater.kt:797-804
    for (const item of json as Array<Object>) {
      if (!isJsonObjectValid(item)) {
        out.skipped++;
        continue;
      }
      let child: Object = item;
      if (typeof item === 'string') {
        try {
          child = JSON.parse(item as string) as Object;
        } catch (e) {
          out.skipped++;
          continue;
        }
      }
      const sub = parseJsonValue(child);
      for (const p of sub.profiles) {
        out.profiles.push(p);
      }
      out.skipped += sub.skipped;
      if (sub.matched) {
        out.matched = true;
      }
    }
    return out;
  }
  if (typeof json !== 'object') {
    return out;
  }
  const o = json as Record<string, Object>;
  // 1) server + up/up_mbps → hysteria1(RawUpdater.kt:756-758)
  if (hasKey(o, 'server') && (hasKey(o, 'up') || hasKey(o, 'up_mbps'))) {
    out.matched = true;
    const h1 = profileFromHysteria1Json(o);
    if (h1 === null) {
      out.skipped++;
    } else {
      out.profiles.push(h1);
    }
    return out;
  }
  // 2) method → shadowsocks(RawUpdater.kt:760-762)
  if (hasKey(o, 'method')) {
    out.matched = true;
    const ss = profileFromShadowsocksJson(o);
    if (ss === null) {
      out.skipped++;
    } else {
      out.profiles.push(ss);
    }
    return out;
  }
  // 3) remote_addr → trojan-go(RawUpdater.kt:764-766)
  if (hasKey(o, 'remote_addr')) {
    out.matched = true;
    const tg = profileFromTrojanGoJson(o);
    if (tg === null) {
      out.skipped++;
    } else {
      out.profiles.push(tg);
    }
    return out;
  }
  // 4) outbounds → 逐出站(RawUpdater.kt:768-788)
  if (hasKey(o, 'outbounds')) {
    out.matched = true;
    const list = o['outbounds'];
    if (!Array.isArray(list)) {
      out.skipped++;
      return out;
    }
    for (const item of list as Array<Object>) {
      // Android: filterIsInstance<JSONObject>() —— 非对象元素直接忽略
      if (item === null || typeof item !== 'object' || Array.isArray(item)) {
        continue;
      }
      const ob = item as Record<string, Object>;
      const ty = sbStr(ob, 'type');
      if (ty.length === 0 || ty === 'dns' || ty === 'block' || ty === 'direct'
        || ty === 'selector' || ty === 'urltest') {
        out.skipped++;
        continue;
      }
      const p = profileFromSingBoxOutbound(ob);
      if (p === null) {
        out.skipped++;
      } else {
        out.profiles.push(p);
      }
    }
    return out;
  }
  // 5) server + server_port → 单个自定义出站(RawUpdater.kt:790-795)
  if (hasKey(o, 'server') && hasKey(o, 'server_port')) {
    out.matched = true;
    const p = new Profile();
    p.type = ProfileType.CUSTOM;
    p.name = sbStr(o, 'tag', sbStr(o, 'remarks', ''));
    p.server = sbStr(o, 'server');
    p.serverPort = sbNum(o, 'server_port');
    // Android ConfigBean.config = it.toStringPretty()(整份 JSON,gson 两空格缩进)
    p.customOutbound = o === undefined ? '' : JSON.stringify(o, null, 2);
    out.profiles.push(p);
    return out;
  }
  return out;
}

export function parseSingBoxConfig(text: string): ClashParseResult {
  const result: ClashParseResult = emptyClashParseResult();
  let obj: Object;
  try {
    obj = JSON.parse(text) as Object;
  } catch (e) {
    return result;
  }
  const outcome = parseJsonValue(obj);
  for (const p of outcome.profiles) {
    result.profiles.push(p);
  }
  result.skipped += outcome.skipped;
  // 鸿蒙超集:sing-box 1.11+ 的 endpoints(WireGuard 端点)。
  // Android 1.4.2 只认 outbounds;为不改变「有 outbounds 时的结果」,
  // 仅在 Android 的五个分支都没命中时才处理 endpoints(见偏差清单)。
  if (!outcome.matched && obj !== null && typeof obj === 'object' && !Array.isArray(obj)) {
    const root = obj as Record<string, Object>;
    const endpoints = root['endpoints'];
    if (endpoints !== undefined && endpoints !== null && Array.isArray(endpoints)) {
      for (const ep of endpoints as Array<Record<string, Object>>) {
        const p = profileFromSingBoxEndpoint(ep);
        if (p === null) {
          result.skipped++;
        } else {
          result.profiles.push(p);
        }
      }
    }
  }
  return result;
}

/** 裸 shadowsocks JSON(Android `JSONObject.parseShadowsocks`,ShadowsocksFmt.kt:95-108)。 */
function profileFromShadowsocksJson(o: Record<string, Object>): Profile | null {
  const server = sbStr(o, 'server');
  if (server.length === 0) {
    return null;
  }
  const p = new Profile();
  p.type = ProfileType.SHADOWSOCKS;
  p.server = server;
  p.serverPort = sbNum(o, 'server_port');
  p.password = sbStr(o, 'password');
  p.method = sbStr(o, 'method');
  // Android: name = optString("remarks", "") —— 缺键时为空串(不回落 tag)
  p.name = sbStr(o, 'remarks');
  // Android: plugin = plugin + ";" + plugin_opts(仅 plugin 非空时)
  const pluginId = sbStr(o, 'plugin');
  if (pluginId.length > 0) {
    const opts = sbStr(o, 'plugin_opts');
    p.ssPlugin = pluginId;
    p.ssPluginOpts = opts;
  }
  return p;
}

/**
 * trojan-go JSON(Android `JSONObject.parseTrojanGo`,TrojanGoFmt.kt:134-162)。
 *
 * 逐字复刻的一个要点:Android 用 `optJSONArray("ssl")` / `optJSONArray("websocket")` /
 * `optJSONArray("shadowsocks")` 去取**对象**字段 —— org.json 的 optJSONArray 对
 * JSONObject 返回 null,所以那三段是死代码。实际生效的只有
 * remote_addr / remote_port / password 三项(已写入"已知怪癖")。
 *
 * 模型限制:Profile 没有 trojan-go 类型(sing-box 无 trojan-go 出站),
 * 这里映射为 trojan 节点并置 tls(见偏差清单)。
 */
function profileFromTrojanGoJson(o: Record<string, Object>): Profile | null {
  const addr = sbStr(o, 'remote_addr');
  if (addr.length === 0) {
    return null;
  }
  const p = new Profile();
  p.type = ProfileType.TROJAN;
  p.server = addr;
  p.serverPort = sbNum(o, 'remote_port') > 0 ? sbNum(o, 'remote_port') : 443;
  const pass = o['password'];
  if (typeof pass === 'string') {
    p.password = pass;
  } else if (Array.isArray(pass) && (pass as Array<Object>).length > 0) {
    p.password = `${(pass as Array<Object>)[0]}`;
  }
  p.tls = true;
  return p;
}

/**
 * 裸 hysteria1 JSON — 逐字对齐 Android `JSONObject.parseHysteria1Json`
 * (HysteriaFmt.kt:167-203):
 *  - `server` 是 "host:port" 一体串,用 substringBeforeLast/AfterLast(":") 拆;
 *  - `up_mbps`/`down_mbps` 取不到时保留 HysteriaBean 默认(protocolVersion=1 → 10/50);
 *  - `auth` → BASE64 档、`auth_str` → STRING 档,后者覆盖前者;
 *  - `alpn` 只认字符串(getStr 对 List 返回 null);
 *  - recv_window_conn / recv_window / disable_mtu_discovery 在 Profile 无对应字段
 *    (见偏差清单)。
 */
function profileFromHysteria1Json(o: Record<string, Object>): Profile | null {
  const server = sbStr(o, 'server');
  if (server.length === 0) {
    return null;
  }
  const p = new Profile();
  p.type = ProfileType.HYSTERIA;
  // HysteriaFmt.kt:171-172 字面 split(无冒号时两段都等于整串)
  const colon = server.lastIndexOf(':');
  if (colon >= 0) {
    p.server = server.substring(0, colon);
    p.serverPorts = server.substring(colon + 1);
  } else {
    p.server = server;
    p.serverPorts = server;
  }
  const pn = Number(p.serverPorts);
  p.serverPort = !isNaN(pn) && pn > 0 ? pn : 443;
  p.name = sbStr(o, 'tag', sbStr(o, 'remarks', ''));
  // getIntNya ?: bean 默认(protocolVersion=1 → up=10/down=50)
  p.upMbps = hasKey(o, 'up_mbps') ? sbNum(o, 'up_mbps') : 10;
  p.downMbps = hasKey(o, 'down_mbps') ? sbNum(o, 'down_mbps') : 50;
  p.obfs = sbStr(o, 'obfs');
  const authStr = sbStr(o, 'auth_str');
  p.password = authStr.length > 0 ? authStr : sbStr(o, 'auth');
  p.sni = sbStr(o, 'server_name');
  p.alpn = sbStr(o, 'alpn');
  p.allowInsecure = sbBool(o, 'insecure');
  return p;
}

/**
 * 单个出站 JSON 解析(对齐安卓 RawUpdater.parseJSON 的裸出站分支):
 * 已是完整配置时直接走 parseSingBoxConfig;否则把该对象包成 {outbounds:[obj]} 再解析。
 */
export function parseSingleOutboundJson(text: string): ClashParseResult {
  let obj: Record<string, Object>;
  try {
    obj = JSON.parse(text) as Record<string, Object>;
  } catch (e) {
    return emptyClashParseResult();
  }
  if (obj['outbounds'] !== undefined || obj['endpoints'] !== undefined) {
    return parseSingBoxConfig(text);
  }
  const wrapped: Record<string, Object> = {};
  wrapped['outbounds'] = [obj as Object];
  return parseSingBoxConfig(JSON.stringify(wrapped));
}


/**
 * 把解析器的 note 键翻译成用户能据此行动的文案。
 * skippedNames 非空时追加「跳过了哪些行」——用户报「解析不到节点」时,
 * 最需要的就是这个:到底是格式没认出来,还是全是内核不支持的协议。
 */
export function subFailureText(note: string, content: string, skipped: number = 0,
  skippedNames: Array<string> = []): string {
  const base = subFailureBaseText(note, content);
  if (skippedNames.length === 0) {
    return base;
  }
  const shown = skippedNames.slice(0, 3).join('、');
  const more = skipped > skippedNames.length ? ` 等 ${skipped} 条` : '';
  return `${base}(已跳过不支持的条目:${shown}${more})`;
}

export function subFailureBaseText(note: string, content: string): string {
  if (note === 'clash_provider_only') {
    return '该 Clash 订阅只提供 proxy-providers(远程节点集),不含内联 proxies,本客户端暂不支持这种格式';
  }
  if (note === 'clash_provider_all_failed') {
    return 'Clash 订阅的 proxy-providers 全部下载失败,请检查网络或稍后重试';
  }
  if (note === 'clash_provider_fetch_failed') {
    return '部分 proxy-providers 下载失败,已导入其余节点';
  }
  if (note === 'clash_provider_empty') {
    return 'Clash 订阅的 proxy-providers 已下载但内容为空,请向机场确认订阅是否有效';
  }
  if (note === 'clash_yaml_parse_failed') {
    return 'Clash YAML 解析失败,订阅内容可能已损坏';
  }
  if (note === 'clash_no_proxies_key') {
    return 'Clash 配置里没有 proxies 节点列表';
  }
  if (content.trim().length === 0) {
    return '订阅内容为空';
  }
  // 形如机场的「你的客户端不支持本站协议」纯文本提示:直接点破比说「没有可用节点」有用。
  if (content.indexOf('不支持本站协议') >= 0 || content.indexOf('不支持您的客户端') >= 0) {
    return '机场拒绝了当前客户端(返回「不支持本站协议」提示),可在订阅设置里改用其他 User-Agent 后重试';
  }
  if (/^\s*</.test(content)) {
    return '订阅返回的是网页(HTML)而不是节点列表,地址可能不正确或需要鉴权';
  }
  return '订阅内容中没有可用节点';
}
