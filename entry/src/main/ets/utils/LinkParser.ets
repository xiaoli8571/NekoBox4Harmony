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

function parseOne(line: string): Profile | null {  if (line.startsWith('ss://')) {
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
    throw new Error('hysteria2 需要 sing-box 1.6+,本内核(1.4)不支持');
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
    try {
      userinfo = base64Decode(userinfo);
    } catch (e) {
      // 可能是明文 (SIP002 也允许明文)
    }
    const ci = userinfo.indexOf(':');
    if (ci < 0) {
      return null;
    }
    p.method = userinfo.substring(0, ci);
    p.password = userinfo.substring(ci + 1);
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
function parseUserinfoLink(link: string, type: string): Profile | null {
  const noScheme = link.substring(link.indexOf('://') + 3);
  const frag = splitFragment(noScheme);
  const name = frag[1];
  const qi = frag[0].indexOf('?');
  const netlocPart = qi < 0 ? frag[0] : frag[0].substring(0, qi);
  const q = parseQuery(qi < 0 ? '' : frag[0].substring(qi));

  let userinfo = '';
  let netloc = netlocPart;
  const at = netlocPart.lastIndexOf('@');
  if (at >= 0) {
    userinfo = netlocPart.substring(0, at);
    netloc = netlocPart.substring(at + 1);
  }

  const hp = hostPortOf(netloc, 443);
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

export { base64Decode, base64Encode };
