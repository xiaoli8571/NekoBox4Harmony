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

export const SUB_UA = 'clash.meta/1.19.0';

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
  'sing-box 1.14.0',
  'ClashforWindows/0.20.39',
  'Stash/2.6.0 Clash/1.10.0'
];

export interface SubFetchResult {
  content: string;
  userinfo: string;
  etag: string;
  lastModified: string;
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
        notModified: true
      };
      return res304;
    }
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
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
  const proxies = root.get('proxies');
  if (proxies === null || !proxies.isSeq()) {
    result.note = root.get('proxy-providers') !== null
      ? 'clash_provider_only'
      : 'clash_no_proxies_key';
    return result;
  }
  for (const item of proxies.items) {
    const p = profileFromClash(item);
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

function applyClashTransport(p: Profile, m: YamlNode): void {
  const net = yStr(m, 'network');
  // Clash 的 h2 对应 sing-box 的 http 传输
  p.transport = (net === '' || net === 'tcp' || net === 'none') ? '' : (net === 'h2' ? 'http' : net);
  const oo = yNode(m, `${net}-opts`);
  if (net === 'ws') {
    if (oo === null || !oo.isMap()) {
      return;
    }
    p.path = yStr(oo, 'path');
    p.host = yHeader(oo, ['Host', 'host']);
    p.wsEarlyData = yNum(oo, 'max-early-data');
    p.wsEarlyDataHeaderName = yStr(oo, 'early-data-header-name');
    // v2ray-http-upgrade = Clash 的 WS 分离模式,对应 sing-box 的 httpupgrade 传输。
    // 分离模式下早期数据走独立的 HTTP/1.1 请求,不再复用 ws 的 early data 字段。
    if (yBool(oo, 'v2ray-http-upgrade')) {
      p.transport = 'httpupgrade';
      p.wsEarlyData = 0;
      p.wsEarlyDataHeaderName = '';
    }
  } else if (net === 'grpc') {
    if (oo !== null && oo.isMap()) {
      // Clash 键名为 grpc-service-name(兼容部分订阅的 serviceName)
      p.serviceName = yStrAny(oo, ['grpc-service-name', 'serviceName']);
    }
    if (p.serviceName.length === 0) {
      p.serviceName = yStr(m, 'service-name');
    }
  } else if (net === 'h2' || net === 'http') {
    if (oo === null || !oo.isMap()) {
      return;
    }
    p.path = yStr(oo, 'path');
    p.host = yHeader(oo, ['host', 'Host']);
  }
}

function applyClashReality(p: Profile, m: YamlNode): void {
  const r = yNode(m, 'reality-opts');
  if (r === null || !r.isMap()) {
    return;
  }
  p.realityPublicKey = yStrAny(r, ['public-key', 'publicKey']);
  p.realityShortId = yStr(r, 'short-id');
  p.tls = true;
  if (p.fingerprint.length === 0) {
    p.fingerprint = yStr(m, 'client-fingerprint', 'chrome');
  }
}

function applyClashMux(p: Profile, m: YamlNode): void {
  const mu = yNode(m, 'smux');
  if (mu === null || !mu.isMap()) {
    return;
  }
  p.mux = true;
  p.muxProtocol = yStr(mu, 'protocol', yStr(mu, 'type', 'h2mux'));
  const streams = yNum(mu, 'max-streams');
  p.muxMaxStreams = streams > 0 ? streams : 8;
  p.muxPadding = mu.has('padding') ? yBool(mu, 'padding') : true;
}

/** Clash 的带宽字段可能是 "30" 或 "30 Mbps" */
function parseBandwidth(raw: string): number {
  const n = parseInt(raw.trim());
  return isNaN(n) ? 0 : n;
}

function profileFromClash(m: YamlNode | null): Profile | null {
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
      break;
    case 'vmess':
      p.type = ProfileType.VMESS;
      p.uuid = yStr(m, 'uuid');
      p.alterId = yNum(m, 'alterId');
      p.security = yStr(m, 'cipher', 'auto');
      p.tls = yBool(m, 'tls');
      p.packetEncoding = yStr(m, 'packet-encoding');
      applyClashMux(p, m);
      applyClashTransport(p, m);
      break;
    case 'vless':
      p.type = ProfileType.VLESS;
      p.uuid = yStr(m, 'uuid');
      p.flow = yStr(m, 'flow');
      p.tls = yBool(m, 'tls') || p.sni.length > 0 || yNode(m, 'reality-opts') !== null;
      p.packetEncoding = yStr(m, 'packet-encoding');
      applyClashReality(p, m);
      applyClashMux(p, m);
      applyClashTransport(p, m);
      break;
    case 'trojan':
      p.type = ProfileType.TROJAN;
      p.password = yStr(m, 'password');
      p.tls = true;
      applyClashReality(p, m);
      applyClashMux(p, m);
      applyClashTransport(p, m);
      break;
    case 'hysteria':
      p.type = ProfileType.HYSTERIA;
      p.password = yStrAny(m, ['auth-str', 'auth_str', 'auth']);
      // 带宽可能是 "30 Mbps" 这类带单位的值(yNumAny → Number("30 Mbps") = NaN → 0),
      // 与 hysteria2 分支一样走 parseBandwidth 剥单位。
      p.upMbps = parseBandwidth(yStrAny(m, ['up', 'upmbps']));
      p.downMbps = parseBandwidth(yStrAny(m, ['down', 'downmbps']));
      p.obfs = yStr(m, 'obfs');
      p.tls = true;
      if (p.alpn.length === 0) {
        p.alpn = 'h3';
      }
      break;
    case 'hysteria2':
    case 'hy2':
      p.type = ProfileType.HYSTERIA2;
      p.password = yStrAny(m, ['password', 'auth']);
      p.tls = true;
      p.obfs = yStrAny(m, ['obfs-password', 'obfspwd', 'obfs']);
      p.upMbps = parseBandwidth(yStrAny(m, ['up', 'upmbps']));
      p.downMbps = parseBandwidth(yStrAny(m, ['down', 'downmbps']));
      // 端口跳跃:Clash 的 ports 既可能是标量("1000-2000"),也可能是 YAML 序列
      // ([1000-2000, 3000])。此前用只读标量的 yStr,序列形态整段丢失 → 跳跃失效。
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
      const hop = yNum(m, 'hop-interval');
      if (hop > 0) {
        p.hopInterval = hop;
      }
      break;
    case 'tuic':
      p.type = ProfileType.TUIC;
      p.uuid = yStr(m, 'uuid');
      p.password = yStrAny(m, ['password', 'token']);
      p.tls = true;
      p.congestionControl = yStrAny(m, ['congestion-controller', 'congestion-control'], 'bbr');
      p.udpRelayMode = yStr(m, 'udp-relay-mode', 'native');
      p.reduceRtt = yBool(m, 'reduce-rtt');
      p.disableSni = yBool(m, 'disable-sni');
      if (p.alpn.length === 0) {
        p.alpn = 'h3';
      }
      break;
    case 'anytls':
      p.type = ProfileType.ANYTLS;
      p.password = yStr(m, 'password');
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
  if (p.server.length === 0 || p.serverPort <= 0) {
    return null;
  }
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
    default:
      // selector/urltest/direct/block/dns 等非节点出站跳过
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

export function parseSingBoxConfig(text: string): ClashParseResult {
  const result: ClashParseResult = emptyClashParseResult();
  let obj: Record<string, Object>;
  try {
    obj = JSON.parse(text) as Record<string, Object>;
  } catch (e) {
    return result;
  }
  const endpoints = obj['endpoints'];
  if (endpoints !== undefined && endpoints !== null) {
    for (const ep of endpoints as Array<Record<string, Object>>) {
      const p = profileFromSingBoxEndpoint(ep);
      if (p === null) {
        result.skipped++;
      } else {
        result.profiles.push(p);
      }
    }
  }
  const outbounds = obj['outbounds'];
  if (outbounds !== undefined && outbounds !== null) {
    for (const o of outbounds as Array<Record<string, Object>>) {
      const p = profileFromSingBoxOutbound(o);
      if (p === null) {
        result.skipped++;
      } else {
        result.profiles.push(p);
      }
    }
  }
  return result;
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
