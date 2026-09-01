import util from '@ohos.util';
import { Profile, ProfileType } from '../model/Profile';

/**
 * 分享链接 / 订阅解析 — 对齐 NekoBoxForAndroid 支持的常见格式:
 *   ss://  (SIP002 + 旧版整段 base64)
 *   vmess:// (base64 JSON)
 *   vless:// trojan:// hysteria:// tuic:// http(s):// socks://
 * 整段 base64 的订阅内容也会被自动识别并逐行解析。
 */

export function parseShareText(text: string): Array<Profile> {
  const result: Array<Profile> = [];
  if (text === undefined || text === null) {
    return result;
  }
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    return result;
  }
  let content = trimmed;
  if (!content.includes('://')) {
    try {
      const decoded = base64Decode(content);
      if (decoded.includes('://')) {
        content = decoded;
      }
    } catch (e) {
      // not base64
    }
  }
  const lines = content.split(/[\r\n]+/);
  for (const line of lines) {
    const t = line.trim();
    if (t.length === 0) {
      continue;
    }
    try {
      const p = parseOne(t);
      if (p !== null) {
        result.push(p);
      }
    } catch (e) {
      // skip unparseable line
    }
  }
  return result;
}

function parseOne(line: string): Profile | null {
  if (line.startsWith('ss://')) {
    return parseShadowsocks(line);
  }
  if (line.startsWith('vmess://')) {
    return parseVmess(line);
  }
  if (line.startsWith('vless://')) {
    return parseUserinfoLink(line, ProfileType.VLESS);
  }
  if (line.startsWith('trojan://')) {
    return parseUserinfoLink(line, ProfileType.TROJAN);
  }
  if (line.startsWith('hysteria://')) {
    return parseUserinfoLink(line, ProfileType.HYSTERIA);
  }
  if (line.startsWith('hysteria2://') || line.startsWith('hy2://')) {
    return parseHysteria2(line);
  }
  if (line.startsWith('tuic://')) {
    return parseUserinfoLink(line, ProfileType.TUIC);
  }
  if (line.startsWith('http://') || line.startsWith('https://')) {
    return parseUserinfoLink(line, ProfileType.HTTP);
  }
  if (line.startsWith('socks://') || line.startsWith('socks5://')) {
    return parseUserinfoLink(line, ProfileType.SOCKS);
  }
  if (line.startsWith('wireguard://') || line.startsWith('wg://')) {
    return parseWireguard(line);
  }
  return null;
}

function base64Decode(input: string): string {
  let s = input.replace(/-/g, '+').replace(/_/g, '/').trim();
  while (s.length % 4 !== 0) {
    s += '=';
  }
  const arr: Uint8Array = new util.Base64Helper().decodeSync(s);
  return util.TextDecoder.create('utf-8').decodeToString(arr);
}

function base64Encode(input: string): string {
  const encoder = new util.TextEncoder();
  const bytes: Uint8Array = encoder.encodeInto(input);
  return new util.Base64Helper().encodeToStringSync(bytes);
}

function newName(name: string, fallback: string): string {
  return name.length > 0 ? name : fallback;
}

function splitFragment(rest: string): [string, string] {
  const i = rest.indexOf('#');
  if (i < 0) {
    return [rest, ''];
  }
  let name = rest.substring(i + 1);
  try {
    name = decodeURIComponent(name.replace(/\+/g, '%20'));
  } catch (e) {
    // keep raw
  }
  return [rest.substring(0, i), name];
}

function parseQuery(q: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (q.startsWith('?')) {
    q = q.substring(1);
  }
  const parts = q.split('&');
  for (const p of parts) {
    if (p.length === 0) {
      continue;
    }
    const i = p.indexOf('=');
    if (i < 0) {
      out[p] = '';
    } else {
      const key = p.substring(0, i);
      let val = p.substring(i + 1);
      try {
        val = decodeURIComponent(val.replace(/\+/g, '%20'));
      } catch (e) {
        // keep raw
      }
      out[key] = val;
    }
  }
  return out;
}

function qstr(q: Record<string, string>, key: string, dflt: string = ''): string {
  const v = q[key];
  return v === undefined ? dflt : v;
}

function qbool(q: Record<string, string>, key: string): boolean {
  const v = q[key];
  if (v === undefined) {
    return false;
  }
  return v === '1' || v === 'true';
}

function hostPortOf(netloc: string, dfltPort: number): [string, number] {
  // 处理 [IPv6]:port
  let host = netloc;
  let port = dfltPort;
  if (netloc.startsWith('[')) {
    const end = netloc.indexOf(']');
    if (end > 0) {
      host = netloc.substring(1, end);
      const rest = netloc.substring(end + 1);
      if (rest.startsWith(':')) {
        port = parseInt(rest.substring(1));
      }
    }
  } else {
    const i = netloc.lastIndexOf(':');
    if (i > 0) {
      host = netloc.substring(0, i);
      const ps = netloc.substring(i + 1);
      const pn = parseInt(ps);
      if (!isNaN(pn)) {
        port = pn;
      }
    }
  }
  return [host, port];
}

/**
 * 严格解析 HTTP(S)/SOCKS authority。
 *
 * 订阅地址和 HTTP 代理分享链接使用相同的 scheme；如果把 authority
 * 中的路径、空 host 或坏端口静默当成节点，就会阻止导入入口回退到
 * 订阅下载。因此这两类链接使用独立的严格解析器，旧协议继续沿用
 * hostPortOf 的兼容行为。
 */
class StrictAuthority {
  host: string = '';
  port: number = 0;
  explicitPort: boolean = false;

  constructor(host: string, port: number, explicitPort: boolean) {
    this.host = host;
    this.port = port;
    this.explicitPort = explicitPort;
  }
}

function allDigits(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code < 48 || code > 57) {
      return false;
    }
  }
  return true;
}

function validPort(text: string): boolean {
  if (!allDigits(text)) {
    return false;
  }
  const value = Number(text);
  return !isNaN(value) && value !== Infinity && value !== -Infinity
    && Math.floor(value) === value && value >= 1 && value <= 65535;
}

function validHost(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    // Authority 内的控制字符/空格和未配对的 URL 分隔符都不是可连接
    // 的 host；其余字符（含 Unicode 域名和 IPv6 zone id）交给
    // sing-box/DNS 继续处理。
    if (code <= 32 || code === 127 || code === 47 || code === 63 || code === 35
      || code === 64 || code === 91 || code === 92 || code === 93) {
      return false;
    }
  }
  // Percent-encoded separators must not turn a URL path or userinfo into a
  // seemingly valid authority (for example host%2Fsubscription). Decode only
  // the authority delimiter bytes here; normal percent-encoded DNS labels are
  // left to the downstream parser.
  for (let i = 0; i < text.length; i++) {
    if (text.charAt(i) !== '%') {
      continue;
    }
    if (i + 2 >= text.length) {
      return false;
    }
    const h = text.substring(i + 1, i + 3);
    if (!/^[0-9a-fA-F]{2}$/.test(h)) {
      return false;
    }
    const decoded = parseInt(h, 16);
    if (decoded <= 32 || decoded === 127 || decoded === 35 || decoded === 47
      || decoded === 63 || decoded === 64 || decoded === 91 || decoded === 92
      || decoded === 93) {
      return false;
    }
    i += 2;
  }
  return true;
}

function strictAuthorityOf(netloc: string, dfltPort: number): StrictAuthority | null {
  if (netloc.length === 0 || netloc.includes('/')) {
    return null;
  }
  let host = '';
  let port = dfltPort;
  let explicitPort = false;
  if (netloc.startsWith('[')) {
    const end = netloc.indexOf(']');
    if (end <= 1) {
      return null;
    }
    host = netloc.substring(1, end);
    const tail = netloc.substring(end + 1);
    if (tail.length > 0) {
      if (!tail.startsWith(':') || !validPort(tail.substring(1))) {
        return null;
      }
      port = Number(tail.substring(1));
      explicitPort = true;
    }
  } else {
    const firstColon = netloc.indexOf(':');
    const lastColon = netloc.lastIndexOf(':');
    if (firstColon < 0) {
      host = netloc;
    } else {
      // 未加方括号的 IPv6 authority 不符合 URL 语法，避免把其中一段
      // 错当成端口；合法 IPv6 应写成 [2001:db8::1]:port。
      if (firstColon !== lastColon) {
        return null;
      }
      host = netloc.substring(0, firstColon);
      const portText = netloc.substring(firstColon + 1);
      if (!validPort(portText)) {
        return null;
      }
      port = Number(portText);
      explicitPort = true;
    }
  }
  if (!validHost(host)) {
    return null;
  }
  return new StrictAuthority(host, port, explicitPort);
}

function applyQueryTls(p: Profile, q: Record<string, string>): void {
  const security = qstr(q, 'security', qstr(q, 'tls', ''));
  if (security === 'tls' || security === 'reality' || security === '1' || security === 'true') {
    p.tls = true;
  }
  if (security === 'reality') {
    p.tls = true;
    p.realityPublicKey = qstr(q, 'pbk');
    p.realityShortId = qstr(q, 'sid');
  }
  p.sni = qstr(q, 'sni', qstr(q, 'peer', qstr(q, 'host')));
  p.allowInsecure = qbool(q, 'allowInsecure') || qbool(q, 'insecure');
  p.alpn = qstr(q, 'alpn');
  p.fingerprint = qstr(q, 'fp');
  p.flow = qstr(q, 'flow');
}

function applyTransport(p: Profile, q: Record<string, string>): void {
  const net = qstr(q, 'type', qstr(q, 'network', ''));
  p.transport = net;
  p.path = qstr(q, 'path');
  p.host = qstr(q, 'host', qstr(q, 'authority'));
  p.serviceName = qstr(q, 'serviceName');
  if (net === 'grpc' && p.serviceName === '') {
    p.serviceName = qstr(q, 'path');
  }
}

// ---------------------------------------------------------------- ss://
function parseShadowsocks(link: string): Profile | null {
  const rest = splitFragment(link.substring(5))[0];
  let name = splitFragment(link.substring(5))[1];
  const p = new Profile();
  p.type = ProfileType.SHADOWSOCKS;

  const at = rest.lastIndexOf('@');
  if (at > 0) {
    // SIP002: ss://base64(method:password)@host:port?plugin=...
    let userinfo = rest.substring(0, at);
    const qi = rest.indexOf('?', at);
    const netloc = qi < 0 ? rest.substring(at + 1) : rest.substring(at + 1, qi);
    const q = parseQuery(qi < 0 ? '' : rest.substring(qi));
    let plainUserinfo = false;
    try {
      userinfo = base64Decode(userinfo);
    } catch (e) {
      // SIP002 也允许明文 userinfo；明文分段后需要 URI decode。
      plainUserinfo = true;
    }
    const ci = userinfo.indexOf(':');
    if (ci < 0) {
      return null;
    }
    if (plainUserinfo) {
      p.method = decodeURIComponentSafe(userinfo.substring(0, ci));
      p.password = decodeURIComponentSafe(userinfo.substring(ci + 1));
    } else {
      p.method = userinfo.substring(0, ci);
      p.password = userinfo.substring(ci + 1);
    }
    const hp = hostPortOf(netloc, 443);
    p.server = hp[0];
    p.serverPort = hp[1];
    if (qstr(q, 'plugin').length > 0) {
      // 插件(simple-obfs/v2ray-plugin)暂不支持
      return null;
    }
  } else {
    // 旧版: ss://base64(method:password@host:port)
    const decoded = base64Decode(rest);
    const ci = decoded.indexOf(':');
    const at2 = decoded.lastIndexOf('@');
    if (ci < 0 || at2 < 0) {
      return null;
    }
    p.method = decoded.substring(0, ci);
    p.password = decoded.substring(ci + 1, at2);
    const hp = hostPortOf(decoded.substring(at2 + 1), 443);
    p.server = hp[0];
    p.serverPort = hp[1];
  }
  p.name = newName(name, `${p.server}:${p.serverPort}`);
  return p;
}

// ---------------------------------------------------------------- vmess://
function parseVmess(link: string): Profile | null {
  const body = splitFragment(link.substring(8))[0];
  const name = splitFragment(link.substring(8))[1];
  const json = JSON.parse(base64Decode(body)) as Record<string, Object>;
  const p = new Profile();
  p.type = ProfileType.VMESS;
  p.name = newName(strField(json, 'ps'), name.length > 0 ? name : strField(json, 'add'));
  p.server = strField(json, 'add');
  p.serverPort = numField(json, 'port');
  p.uuid = strField(json, 'id');
  p.alterId = numField(json, 'aid');
  p.security = strField(json, 'scy', 'auto');
  const net = strField(json, 'net', 'tcp');
  p.transport = net === 'tcp' ? '' : net;
  p.path = strField(json, 'path');
  p.host = strField(json, 'host');
  const tls = strField(json, 'tls');
  p.tls = tls === 'tls' || tls === 'reality';
  if (p.tls) {
    p.sni = strField(json, 'sni', p.host);
  }
  p.allowInsecure = strField(json, 'allowInsecure') === '1' || strField(json, 'verify_cert') === 'false';
  if (p.server.length === 0 || p.uuid.length === 0) {
    return null;
  }
  return p;
}

function strField(o: Record<string, Object>, key: string, dflt: string = ''): string {
  const v = o[key];
  if (v === undefined || v === null) {
    return dflt;
  }
  return `${v}`.length > 0 ? `${v}` : dflt;
}

function numField(o: Record<string, Object>, key: string): number {
  const v = o[key];
  if (v === undefined || v === null) {
    return 0;
  }
  const n = Number(`${v}`);
  return isNaN(n) ? 0 : n;
}

// ---------------------------------------------------------------- uuid@host 类
function parseHysteria2(link: string): Profile | null {
  const noScheme = link.substring(link.indexOf('://') + 3);
  const frag = splitFragment(noScheme);
  const name = frag[1];
  const qi = frag[0].indexOf('?');
  const netlocPart = qi < 0 ? frag[0] : frag[0].substring(0, qi);
  const q = parseQuery(qi < 0 ? '' : frag[0].substring(qi));
  let password = '';
  let netloc = netlocPart;
  const at = netlocPart.lastIndexOf('@');
  if (at >= 0) {
    password = decodeURIComponentSafe(netlocPart.substring(0, at));
    netloc = netlocPart.substring(at + 1);
  }
  const hp = hostPortOf(netloc, 443);
  const p = new Profile();
  p.type = ProfileType.HYSTERIA2;
  p.server = hp[0];
  p.serverPort = hp[1];
  p.name = newName(name, `${p.server}:${p.serverPort}`);
  p.password = password;
  p.tls = true;
  p.sni = qstr(q, 'sni');
  p.allowInsecure = qbool(q, 'insecure') || qbool(q, 'allowInsecure');
  p.obfs = qstr(q, 'obfs-password', qstr(q, 'obfspwd'));
  const up = qstr(q, 'upmbps', qstr(q, 'up', ''));
  const down = qstr(q, 'downmbps', qstr(q, 'down', ''));
  p.upMbps = up.length > 0 ? parseInt(up) : 0;
  p.downMbps = down.length > 0 ? parseInt(down) : 0;
  if (p.server.length === 0) {
    return null;
  }
  return p;
}

function parseUserinfoLink(link: string, type: string): Profile | null {
  const noScheme = link.substring(link.indexOf('://') + 3);
  const frag = splitFragment(noScheme);
  const name = frag[1];
  const qi = frag[0].indexOf('?');
  const netlocPart = qi < 0 ? frag[0] : frag[0].substring(0, qi);
  const q = parseQuery(qi < 0 ? '' : frag[0].substring(qi));

  // 这里的 authority 包含 userinfo；userinfo 中出现未编码的 '/' 同样
  // 表示这是普通 URL 路径而非代理分享链接。URL 的根路径 `/` 是合法
  // 的 authority 后缀（例如 http://proxy:8080/），去掉这一枚后再做
  // 严格解析；多段路径仍然拒绝并交给订阅下载回退。
  let authorityPart = netlocPart;
  if ((type === ProfileType.HTTP || type === ProfileType.SOCKS) && authorityPart.endsWith('/')) {
    authorityPart = authorityPart.substring(0, authorityPart.length - 1);
  }
  if ((type === ProfileType.HTTP || type === ProfileType.SOCKS) && authorityPart.includes('/')) {
    return null;
  }

  let userinfo = '';
  let netloc = authorityPart;
  const at = authorityPart.lastIndexOf('@');
  if (at >= 0) {
    userinfo = authorityPart.substring(0, at);
    netloc = authorityPart.substring(at + 1);
  }

  // HTTP/SOCKS 分享链接不能把路径、空 host 或坏端口静默当成节点。
  // 尤其是 https://host/subscription，必须返回 null 让导入入口回退到
  // 订阅下载流程。
  let hp: [string, number] = ['', 443];
  if (type === ProfileType.HTTP || type === ProfileType.SOCKS) {
    // HTTP(S)/SOCKS 节点分享没有可消费的 query 字段；query-only URL
    // 通常是带 token 的订阅地址，必须交给导入入口走下载回退。
    if (qi >= 0) {
      return null;
    }
    const scheme = link.substring(0, link.indexOf('://')).toLowerCase();
    const defaultPort = type === ProfileType.SOCKS ? 1080 : (scheme === 'http' ? 80 : 443);
    const strict = strictAuthorityOf(netloc, defaultPort);
    if (strict === null) {
      return null;
    }
    hp = [strict.host, strict.port];
  } else {
    hp = hostPortOf(netloc, 443);
  }
  const p = new Profile();
  p.type = type;
  p.server = hp[0];
  p.serverPort = hp[1];
  p.name = newName(name, `${p.server}:${p.serverPort}`);

  switch (type) {
    case ProfileType.VLESS:
      p.uuid = userinfo;
      p.security = qstr(q, 'encryption', 'auto');
      applyTransport(p, q);
      applyQueryTls(p, q);
      break;
    case ProfileType.TROJAN:
      p.password = decodeURIComponentSafe(userinfo);
      applyTransport(p, q);
      applyQueryTls(p, q);
      break;
    case ProfileType.HYSTERIA:
      p.password = qstr(q, 'auth', decodeURIComponentSafe(userinfo));
      p.upMbps = parseInt(qstr(q, 'upmbps', '100'));
      p.downMbps = parseInt(qstr(q, 'downmbps', '100'));
      p.obfs = qstr(q, 'obfs');
      p.tls = true;
      p.sni = qstr(q, 'peer', qstr(q, 'sni'));
      p.alpn = qstr(q, 'alpn', 'h3');
      p.allowInsecure = qbool(q, 'insecure');
      break;
    case ProfileType.TUIC: {
      const ci = userinfo.indexOf(':');
      if (ci > 0) {
        p.uuid = decodeURIComponentSafe(userinfo.substring(0, ci));
        p.password = decodeURIComponentSafe(userinfo.substring(ci + 1));
      } else {
        p.uuid = decodeURIComponentSafe(userinfo);
      }
      p.congestionControl = qstr(q, 'congestion_control', 'bbr');
      p.udpRelayMode = qstr(q, 'udp_relay_mode', 'native');
      p.tls = true;
      p.sni = qstr(q, 'sni');
      p.alpn = qstr(q, 'alpn', 'h3');
      p.allowInsecure = qbool(q, 'allow_insecure') || qbool(q, 'insecure');
      break;
    }
    case ProfileType.HTTP:
    case ProfileType.SOCKS: {
      const ci = userinfo.indexOf(':');
      if (ci > 0) {
        p.username = decodeURIComponentSafe(userinfo.substring(0, ci));
        p.password = decodeURIComponentSafe(userinfo.substring(ci + 1));
      }
      p.tls = link.startsWith('https://');
      break;
    }
    default:
      break;
  }
  if (p.server.length === 0) {
    return null;
  }
  return p;
}

// ---------------------------------------------------------------- wireguard:// (NekoBox 导出格式)
function parseWireguard(link: string): Profile | null {
  const noScheme = link.substring(link.indexOf('://') + 3);
  const frag = splitFragment(noScheme);
  const name = frag[1];
  const qi = frag[0].indexOf('?');
  const netlocPart = qi < 0 ? frag[0] : frag[0].substring(0, qi);
  const q = parseQuery(qi < 0 ? '' : frag[0].substring(qi));
  const at = netlocPart.lastIndexOf('@');
  if (at <= 0) {
    return null;
  }
  const privateKey = decodeURIComponentSafe(netlocPart.substring(0, at));
  const hp = hostPortOf(netlocPart.substring(at + 1), 51820);
  const p = new Profile();
  p.type = ProfileType.WIREGUARD;
  p.privateKey = privateKey;
  p.server = hp[0];
  p.serverPort = hp[1];
  p.peerPublicKey = qstr(q, 'public_key', qstr(q, 'peer_public_key'));
  p.preSharedKey = qstr(q, 'pre_shared_key', qstr(q, 'preshared_key'));
  p.localAddress = qstr(q, 'local_address', qstr(q, 'address', p.localAddress));
  p.name = newName(name, `${p.server}:${p.serverPort}`);
  if (p.server.length === 0 || p.privateKey.length === 0 || p.peerPublicKey.length === 0) {
    return null;
  }
  return p;
}

function decodeURIComponentSafe(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch (e) {
    return s;
  }
}

/** 供编辑页「粘贴节点链接」使用的单条链接解析。 */
export function parseSingleLink(link: string): Profile | null {
  return parseOne(link);
}

/**
 * 区分 HTTP(S) 代理分享链接与订阅 URL。
 *
 * 两者共用 http(s) scheme，不能只看前缀：带账号或节点名 fragment 的
 * 链接才有足够强的“单节点”信号；仅有 host:port 的根 URL 仍可能是订阅，
 * 交给导入入口先下载，下载失败再回退到单节点解析。
 */
export function looksLikeHttpProxyLink(link: string): boolean {
  const text = link.trim();
  if (!text.startsWith('http://') && !text.startsWith('https://')) {
    return false;
  }
  const rest = text.substring(text.indexOf('://') + 3);
  const cutSlash = rest.indexOf('/');
  const cutQuery = rest.indexOf('?');
  const cutFragment = rest.indexOf('#');
  // 只有 query/fragment 之前的 '/' 才是 authority 后面的路径；
  // fragment 内容本身可以包含 '/'，不能因此误判订阅 URL。
  let boundary = rest.length;
  if (cutQuery >= 0 && cutQuery < boundary) {
    boundary = cutQuery;
  }
  if (cutFragment >= 0 && cutFragment < boundary) {
    boundary = cutFragment;
  }
  if (cutSlash >= 0 && cutSlash < boundary) {
    return false;
  }
  // authority 后只有 query（例如 https://host:443?token=...）时，
  // 与订阅 URL 的歧义无法可靠消除；按订阅处理，避免静默保存错误节点。
  if (cutQuery >= 0 && (cutFragment < 0 || cutQuery < cutFragment)) {
    return false;
  }
  const authority = rest.substring(0, boundary);
  const at = authority.lastIndexOf('@');
  const hostAuthority = at >= 0 ? authority.substring(at + 1) : authority;
  const strict = strictAuthorityOf(hostAuthority, 443);
  if (strict === null) {
    return false;
  }
  // userinfo（user:pass@host）或显式节点名 fragment 是单节点分享的
  // 可靠信号。host:port 本身故意视为歧义地址，由调用方做下载回退。
  return at >= 0 || cutFragment >= 0;
}

export { base64Decode, base64Encode };
