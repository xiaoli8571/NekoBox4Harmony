import http from '@ohos.net.http';
import { Profile, ProfileType } from '../model/Profile';

/**
 * 订阅链接支持:
 *  - 下载订阅(UA 伪装 clash.meta:绝大多数机场返回 Clash YAML;v2rayNG UA 会被部分机场
 *    拒绝并返回"你的客户端不支持本站协议"文本)
 *  - 服务商返回 Clash YAML(proxies:)时用内置轻量解析器提取节点
 *  - 服务商/订阅转换返回 sing-box JSON 配置(outbounds/endpoints)时直接映射节点
 *  - 其余按 base64 分享链接列表解析
 *  - HTTP 强制 1.1:规避 Cloudflare 前置在 HTTP/2 连接复用下的 421 Misdirected Request
 */

const SUB_UA = 'clash.meta/1.19.0';

export interface SubFetchResult {
  content: string;
  userinfo: string;
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
    let val = part.substring(i + 1);
    try {
      val = decodeURIComponent(val.replace(/\+/g, '%20'));
    } catch (e) {
      // 保留原始值,避免非法编码导致整个链接不可用
    }
    out[key] = val;
  }
  return out;
}

export async function fetchSubscriptionWithInfo(url: string, allowInsecure: boolean = false, userAgent: string = ''): Promise<SubFetchResult> {
  return await doFetchSubscription(url, true, allowInsecure, userAgent);
}

async function fetchSubscriptionRaw(url: string, withInfo: boolean): Promise<string> {
  const r = await doFetchSubscription(url, withInfo, false, '');
  return r.content;
}

export async function fetchSubscription(url: string, allowInsecure: boolean = false, userAgent: string = ''): Promise<string> {
  const r = await doFetchSubscription(url, false, allowInsecure, userAgent);
  return r.content;
}

async function doFetchSubscription(url: string, withInfo: boolean, allowInsecure: boolean, userAgent: string): Promise<SubFetchResult> {
  const normalizedUrl = url.trim();
  if (!normalizedUrl.startsWith('https://') && !normalizedUrl.startsWith('http://')) {
    throw new Error('订阅地址必须使用 HTTP 或 HTTPS 协议');
  }
  const client = http.createHttp();
  try {
    const ua = userAgent.trim().length > 0 ? userAgent.trim() : SUB_UA;
    const headers: Record<string, string> = { 'User-Agent': ua };
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
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      let snippet = '';
      const rb = resp.result;
      if (typeof rb === 'string' && rb.length > 0) {
        snippet = rb.replace(/\s+/g, ' ').trim().substring(0, 120);
      }
      throw new Error(`订阅服务器返回 HTTP ${resp.responseCode}${snippet.length > 0 ? ': ' + snippet : ''}`);
    }
    let responseUserinfo = '';
    if (withInfo) {
      // 每次请求只读取自身响应头，避免多个订阅之间串用到期信息。
      const respHeaders = resp.header as Record<string, string>;
      if (respHeaders !== undefined && respHeaders !== null) {
        const headerKeys = Object.keys(respHeaders);
        for (const hk of headerKeys) {
          if (hk.toLowerCase() === 'subscription-userinfo') {
            responseUserinfo = respHeaders[hk];
            break;
          }
        }
      }
    }
    const body: string | Object | ArrayBuffer = resp.result;
    const result: SubFetchResult = {
      content: typeof body === 'string' ? body : `${body}`,
      userinfo: responseUserinfo
    };
    return result;
  } finally {
    client.destroy();
  }
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
}

export function looksLikeClashYaml(text: string): boolean {
  return /(^|\n)\s*proxies\s*:/.test(text);
}

// ---------------------------------------------------------------- Clash YAML

export function parseClashProxies(yaml: string): ClashParseResult {
  const result: ClashParseResult = { profiles: [], skipped: 0 };
  const lines = yaml.split(/\r?\n/);
  let inProxies = false;
  let current: Array<string> | null = null;
  const items: Array<Array<string>> = [];
  for (const line of lines) {
    if (!inProxies) {
      if (/^proxies\s*:/.test(line)) {
        inProxies = true;
      }
      continue;
    }
    if (/^\S/.test(line)) {
      break; // 下一个顶层 key,列表结束
    }
    if (/^\s*-\s+/.test(line)) {
      if (current !== null) {
        items.push(current);
      }
      const l: Array<string> = [line.replace(/^\s*-\s+/, '')];
      current = l;
    } else if (current !== null && line.trim().length > 0) {
      current.push(line.trim());
    }
  }
  if (current !== null) {
    items.push(current);
  }
  for (const item of items) {
    const p = profileFromClash(parseClashItem(item));
    if (p === null) {
      result.skipped++;
    } else {
      result.profiles.push(p);
    }
  }
  return result;
}

function parseClashItem(rawLines: Array<string>): Record<string, Object> {
  const first = rawLines[0].trim();
  if (first.startsWith('{')) {
    const joined = rawLines.join('');
    const m = parseFlowMap(joined.trim());
    if (m !== null) {
      return m;
    }
  }
  return parseBlockItem(rawLines);
}

function indentOf(l: string): number {
  let n = 0;
  while (n < l.length && (l.charAt(n) === ' ' || l.charAt(n) === '\t')) {
    n++;
  }
  return n;
}

function parseBlockItem(rawLines: Array<string>): Record<string, Object> {
  const out: Record<string, Object> = {};
  const maps: Array<Record<string, Object>> = [out];
  const indents: Array<number> = [-1];
  for (const l of rawLines) {
    const ind = indentOf(l);
    const t = l.trim();
    const i = t.indexOf(':');
    if (i <= 0) {
      continue;
    }
    while (indents.length > 1 && ind <= indents[indents.length - 1]) {
      indents.pop();
      maps.pop();
    }
    const current = maps[maps.length - 1];
    const k = t.substring(0, i).trim();
    const v = t.substring(i + 1).trim();
    if (v.length === 0) {
      const child: Record<string, Object> = {};
      current[k] = child;
      maps.push(child);
      indents.push(ind);
    } else {
      current[k] = parseScalar(v);
    }
  }
  return out;
}

function parseScalar(raw: string): Object {
  const v = raw.trim();
  if (v.startsWith('{')) {
    const m = parseFlowMap(v);
    if (m !== null) {
      return m;
    }
  }
  if (v.startsWith('[') && v.endsWith(']')) {
    const inner = v.substring(1, v.length - 1);
    const parts = splitTopLevel(inner, ',');
    const arr: Array<Object> = [];
    for (const p of parts) {
      if (p.trim().length > 0) {
        arr.push(parseScalar(p));
      }
    }
    return arr;
  }
  if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
    return v.substring(1, v.length - 1);
  }
  if (v === 'true') {
    return true;
  }
  if (v === 'false') {
    return false;
  }
  if (v.length > 0) {
    const n = Number(v);
    if (!isNaN(n)) {
      return n;
    }
  }
  return v;
}

function splitTopLevel(s: string, sep: string): Array<string> {
  const parts: Array<string> = [];
  let depth = 0;
  let quote = '';
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i);
    if (quote !== '') {
      if (c === quote) {
        quote = '';
      }
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
    } else if (c === '{' || c === '[') {
      depth++;
    } else if (c === '}' || c === ']') {
      depth--;
    } else if (c === sep && depth === 0) {
      parts.push(s.substring(start, i));
      start = i + 1;
    }
  }
  parts.push(s.substring(start));
  return parts;
}

function parseFlowMap(s: string): Record<string, Object> | null {
  const v = s.trim();
  if (!v.startsWith('{') || !v.endsWith('}')) {
    return null;
  }
  const inner = v.substring(1, v.length - 1);
  const out: Record<string, Object> = {};
  for (const part of splitTopLevel(inner, ',')) {
    const t = part.trim();
    if (t.length === 0) {
      continue;
    }
    const i = t.indexOf(':');
    if (i <= 0) {
      continue;
    }
    const key = parseScalar(t.substring(0, i)) as string;
    out[key] = parseScalar(t.substring(i + 1));
  }
  return out;
}

function mStr(m: Record<string, Object>, k: string, dflt: string = ''): string {
  const v = m[k];
  if (v === undefined || v === null) {
    return dflt;
  }
  return `${v}`;
}

function mNum(m: Record<string, Object>, k: string): number {
  const v = m[k];
  if (typeof v === 'number') {
    return v;
  }
  const x = Number(`${v}`);
  return isNaN(x) ? 0 : x;
}

function mBool(m: Record<string, Object>, k: string): boolean {
  const v = m[k];
  return v === true || `${v}` === 'true';
}

function applyClashTransport(p: Profile, m: Record<string, Object>): void {
  const net = mStr(m, 'network');
  // Clash 的 h2 对应 sing-box 的 http 传输
  p.transport = (net === 'tcp' || net === 'none') ? '' : (net === 'h2' ? 'http' : net);
  const wsKey = `${net}-opts`;
  const oo = m[wsKey];
  if (oo === undefined || oo === null) {
    return;
  }
  const w = oo as Record<string, Object>;
  if (net === 'ws') {
    p.path = mStr(w, 'path');
    const hh = w['headers'];
    if (hh !== undefined && hh !== null) {
      const h = hh as Record<string, Object>;
      p.host = mStr(h, 'Host');
    }
    p.wsEarlyData = mNum(w, 'max-early-data');
    p.wsEarlyDataHeaderName = mStr(w, 'early-data-header-name');
  } else if (net === 'grpc') {
    // Clash 键名为 grpc-service-name(兼容部分订阅的 serviceName)
    p.serviceName = mStr(w, 'grpc-service-name', mStr(w, 'serviceName', mStr(m, 'service-name')));
  } else if (net === 'h2' || net === 'http') {
    p.path = mStr(w, 'path');
    const hh = w['headers'];
    if (hh !== undefined && hh !== null) {
      const h = hh as Record<string, Object>;
      p.host = mStr(h, 'host', mStr(h, 'Host'));
    }
  }
}

/** Clash 的带宽字段可能是 "30" 或 "30 Mbps" */
function parseBandwidth(raw: string): number {
  const n = parseInt(raw.trim());
  return isNaN(n) ? 0 : n;
}

function profileFromClash(m: Record<string, Object> | null): Profile | null {
  if (m === null) {
    return null;
  }
  const type = mStr(m, 'type');
  const p = new Profile();
  p.name = mStr(m, 'name');
  p.server = mStr(m, 'server');
  p.serverPort = mNum(m, 'port');
  if (p.server.length === 0 || p.serverPort <= 0) {
    return null;
  }
  // uTLS 指纹(vless/hysteria2/tuic 均可携带;reality 出站内核强制要求 uTLS)
  const clientFp = mStr(m, 'client-fingerprint');
  if (clientFp.length > 0) {
    p.fingerprint = clientFp;
  }
  switch (type) {
    case 'ss':
      p.type = ProfileType.SHADOWSOCKS;
      p.method = mStr(m, 'cipher');
      p.password = mStr(m, 'password');
      break;
    case 'vmess':
      p.type = ProfileType.VMESS;
      p.uuid = mStr(m, 'uuid');
      p.alterId = mNum(m, 'alterId');
      p.security = mStr(m, 'cipher', 'auto');
      p.tls = mBool(m, 'tls');
      p.sni = mStr(m, 'servername');
      applyClashTransport(p, m);
      break;
    case 'vless':
      p.type = ProfileType.VLESS;
      p.uuid = mStr(m, 'uuid');
      p.flow = mStr(m, 'flow');
      p.tls = mBool(m, 'tls') || mStr(m, 'servername').length > 0;
      p.sni = mStr(m, 'servername');
      p.allowInsecure = mBool(m, 'skip-cert-verify');
      const reality = m['reality-opts'];
      if (reality !== undefined && reality !== null) {
        const r = reality as Record<string, Object>;
        p.realityPublicKey = mStr(r, 'public-key');
        p.realityShortId = mStr(r, 'short-id');
        p.tls = true;
      }
      applyClashTransport(p, m);
      break;
    case 'trojan':
      p.type = ProfileType.TROJAN;
      p.password = mStr(m, 'password');
      p.sni = mStr(m, 'servername');
      p.allowInsecure = mBool(m, 'skip-cert-verify');
      applyClashTransport(p, m);
      break;
    case 'hysteria':
      p.type = ProfileType.HYSTERIA;
      p.password = mStr(m, 'auth-str', mStr(m, 'auth_str'));
      p.upMbps = mNum(m, 'up');
      p.downMbps = mNum(m, 'down');
      p.obfs = mStr(m, 'obfs');
      p.sni = mStr(m, 'sni');
      p.tls = true;
      break;
    case 'hysteria2':
    case 'hy2':
      p.type = ProfileType.HYSTERIA2;
      p.password = mStr(m, 'password', mStr(m, 'auth'));
      p.sni = mStr(m, 'sni', mStr(m, 'servername'));
      p.tls = true;
      p.allowInsecure = mBool(m, 'skip-cert-verify');
      p.obfs = mStr(m, 'obfs-password', mStr(m, 'obfs'));
      p.upMbps = parseBandwidth(mStr(m, 'up'));
      p.downMbps = parseBandwidth(mStr(m, 'down'));
      p.serverPorts = mStr(m, 'ports');
      break;
    case 'tuic':
      p.type = ProfileType.TUIC;
      p.uuid = mStr(m, 'uuid');
      p.password = mStr(m, 'password', mStr(m, 'token'));
      p.sni = mStr(m, 'sni', mStr(m, 'servername'));
      p.tls = true;
      p.allowInsecure = mBool(m, 'skip-cert-verify');
      p.congestionControl = mStr(m, 'congestion-controller', mStr(m, 'congestion-control', 'bbr'));
      p.udpRelayMode = mStr(m, 'udp-relay-mode', 'native');
      p.reduceRtt = mBool(m, 'reduce-rtt');
      p.disableSni = mBool(m, 'disable-sni');
      p.alpn = mStr(m, 'alpn');
      break;
    case 'anytls':
      p.type = ProfileType.ANYTLS;
      p.password = mStr(m, 'password');
      p.sni = mStr(m, 'sni', mStr(m, 'servername'));
      p.tls = true;
      p.allowInsecure = mBool(m, 'skip-cert-verify');
      break;
    case 'snell':
      p.type = ProfileType.SNELL;
      p.password = mStr(m, 'psk', mStr(m, 'password'));
      p.obfs = mStr(m, 'obfs');
      p.host = mStr(m, 'obfs-host');
      p.tls = false;
      break;
    default:
      // ssr 等内核不支持的类型跳过
      return null;
  }
  return p;
}

// ---------------------------------------------------------------- sing-box JSON

export function looksLikeSingBoxJson(text: string): boolean {
  const t = text.trim();
  return t.startsWith('{') && t.includes('"outbounds"');
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
      break;
    case 'hysteria':
      p.type = ProfileType.HYSTERIA;
      p.password = sbStr(o, 'password', sbStr(o, 'auth'));
      p.upMbps = sbNum(o, 'up_mbps');
      p.downMbps = sbNum(o, 'down_mbps');
      p.obfs = sbStr(o, 'obfs');
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
      break;
    }
    case 'tuic':
      p.type = ProfileType.TUIC;
      p.uuid = sbStr(o, 'uuid');
      p.password = sbStr(o, 'password');
      p.congestionControl = sbStr(o, 'congestion_control', 'bbr');
      p.udpRelayMode = sbStr(o, 'udp_relay_mode', 'native');
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
      break;
    case 'anytls':
      p.type = ProfileType.ANYTLS;
      p.password = sbStr(o, 'password');
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
  const result: ClashParseResult = { profiles: [], skipped: 0 };
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
    return { profiles: [], skipped: 0 };
  }
  if (obj['outbounds'] !== undefined || obj['endpoints'] !== undefined) {
    return parseSingBoxConfig(text);
  }
  const wrapped: Record<string, Object> = {};
  wrapped['outbounds'] = [obj as Object];
  return parseSingBoxConfig(JSON.stringify(wrapped));
}
