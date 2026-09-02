import { Profile, ProfileType } from '../model/Profile';
import { base64Encode } from './LinkParser';

/**
 * Profile → 分享链接,与 utils/LinkParser.ets 的解析逻辑互逆:
 *   vless(含 reality pbk/sid/fp) / vmess(base64 JSON) / ss(SIP002) /
 *   trojan / hysteria(hysteria://) / hysteria2(hysteria2://) / tuic /
 *   http(s) / socks;WireGuard 无法用链接完整表达,返回空串。
 */

function enc(s: string): string {
  return encodeURIComponent(s);
}

function addQuery(q: Array<string>, key: string, value: string): void {
  if (value.length > 0) {
    q.push(`${key}=${enc(value)}`);
  }
}

function addQueryIf(q: Array<string>, key: string, value: string, dflt: string): void {
  // 仅当与解析端默认值不同时才写出,保持往返紧凑
  if (value.length > 0 && value !== dflt) {
    q.push(`${key}=${enc(value)}`);
  }
}

function addQueryBool(q: Array<string>, key: string, v: boolean): void {
  if (v) {
    q.push(`${key}=1`);
  }
}

function fragment(name: string): string {
  return name.length > 0 ? `#${enc(name)}` : '';
}

/** 纯净的传输层参数(type/path/host/serviceName),供 vless/trojan 共用 */
function addTransportQuery(q: Array<string>, p: Profile): void {
  if (p.transport.length > 0) {
    q.push(`type=${enc(p.transport)}`);
  }
  addQuery(q, 'path', p.path);
  addQuery(q, 'host', p.host);
  addQuery(q, 'serviceName', p.serviceName);
}

/** TLS/REALITY 参数(security/sni/fp/pbk/sid/alpn/allowInsecure/flow) */
function addTlsQuery(q: Array<string>, p: Profile, includeFlow: boolean): void {
  if (p.realityPublicKey.length > 0) {
    q.push('security=reality');
    addQuery(q, 'pbk', p.realityPublicKey);
    addQuery(q, 'sid', p.realityShortId);
  } else if (p.tls) {
    q.push('security=tls');
  }
  addQuery(q, 'sni', p.sni);
  addQuery(q, 'fp', p.fingerprint);
  addQuery(q, 'alpn', p.alpn);
  addQueryBool(q, 'allowInsecure', p.allowInsecure);
  if (includeFlow && p.flow.length > 0) {
    q.push(`flow=${enc(p.flow)}`);
  }
}

function hostPort(p: Profile): string {
  const host = p.server.includes(':') ? `[${p.server}]` : p.server;
  return `${host}:${p.serverPort}`;
}

// ---------------------------------------------------------------- vless
function exportVless(p: Profile): string {
  const q: Array<string> = [];
  addQueryIf(q, 'encryption', p.security, 'auto');
  addTransportQuery(q, p);
  addTlsQuery(q, p, true);
  const query = q.length > 0 ? `?${q.join('&')}` : '';
  return `vless://${enc(p.uuid)}@${hostPort(p)}${query}${fragment(p.name)}`;
}

// ---------------------------------------------------------------- vmess
function exportVmess(p: Profile): string {
  const json: Record<string, Object> = {};
  json['v'] = '2';
  json['ps'] = p.name;
  json['add'] = p.server;
  json['port'] = p.serverPort;
  json['id'] = p.uuid;
  json['aid'] = p.alterId;
  json['scy'] = p.security.length > 0 ? p.security : 'auto';
  json['net'] = p.transport.length > 0 ? p.transport : 'tcp';
  json['host'] = p.host;
  json['path'] = p.path;
  json['tls'] = p.tls ? 'tls' : '';
  json['sni'] = p.sni;
  json['allowInsecure'] = p.allowInsecure ? '1' : '0';
  return `vmess://${base64Encode(JSON.stringify(json))}`;
}

// ---------------------------------------------------------------- ss (SIP002)
function exportShadowsocks(p: Profile): string {
  const userinfo = base64Encode(`${p.method}:${p.password}`);
  return `ss://${userinfo}@${hostPort(p)}${fragment(p.name)}`;
}

// ---------------------------------------------------------------- trojan
function exportTrojan(p: Profile): string {
  const q: Array<string> = [];
  addTransportQuery(q, p);
  addTlsQuery(q, p, true);
  const query = q.length > 0 ? `?${q.join('&')}` : '';
  return `trojan://${enc(p.password)}@${hostPort(p)}${query}${fragment(p.name)}`;
}

// ---------------------------------------------------------------- hysteria
function exportHysteria(p: Profile): string {
  const q: Array<string> = [];
  addQuery(q, 'auth', p.password);
  q.push(`upmbps=${p.upMbps > 0 ? p.upMbps : 100}`);
  q.push(`downmbps=${p.downMbps > 0 ? p.downMbps : 100}`);
  addQuery(q, 'obfs', p.obfs);
  addQuery(q, 'peer', p.sni);
  addQueryIf(q, 'alpn', p.alpn, 'h3');
  addQueryBool(q, 'insecure', p.allowInsecure);
  return `hysteria://${hostPort(p)}?${q.join('&')}${fragment(p.name)}`;
}

// ---------------------------------------------------------------- hysteria2
function exportHysteria2(p: Profile): string {
  const q: Array<string> = [];
  addQuery(q, 'sni', p.sni);
  if (p.upMbps > 0) {
    q.push(`upmbps=${p.upMbps}`);
  }
  if (p.downMbps > 0) {
    q.push(`downmbps=${p.downMbps}`);
  }
  addQuery(q, 'obfs-password', p.obfs);
  addQueryBool(q, 'insecure', p.allowInsecure);
  const query = q.length > 0 ? `?${q.join('&')}` : '';
  return `hysteria2://${enc(p.password)}@${hostPort(p)}${query}${fragment(p.name)}`;
}

// ---------------------------------------------------------------- tuic
function exportTuic(p: Profile): string {
  const q: Array<string> = [];
  addQueryIf(q, 'congestion_control', p.congestionControl, 'bbr');
  addQueryIf(q, 'udp_relay_mode', p.udpRelayMode, 'native');
  addQuery(q, 'sni', p.sni);
  addQueryIf(q, 'alpn', p.alpn, 'h3');
  addQueryBool(q, 'allow_insecure', p.allowInsecure);
  const userinfo = p.password.length > 0 ? `${enc(p.uuid)}:${enc(p.password)}` : enc(p.uuid);
  return `tuic://${userinfo}@${hostPort(p)}?${q.join('&')}${fragment(p.name)}`;
}

// ---------------------------------------------------------------- http / socks
function exportUserinfoHttp(p: Profile, scheme: string): string {
  let userinfo = '';
  if (p.username.length > 0) {
    userinfo = p.password.length > 0
      ? `${enc(p.username)}:${enc(p.password)}@`
      : `${enc(p.username)}@`;
  }
  return `${scheme}://${userinfo}${hostPort(p)}${fragment(p.name)}`;
}

/** 导出单条分享链接;不支持的协议(WireGuard)返回空串 */
export function exportProfileLink(p: Profile): string {
  switch (p.type) {
    case ProfileType.VLESS:
      return exportVless(p);
    case ProfileType.VMESS:
      return exportVmess(p);
    case ProfileType.SHADOWSOCKS:
      return exportShadowsocks(p);
    case ProfileType.TROJAN:
      return exportTrojan(p);
    case ProfileType.HYSTERIA:
      return exportHysteria(p);
    case ProfileType.HYSTERIA2:
      return exportHysteria2(p);
    case ProfileType.TUIC:
      return exportTuic(p);
    case ProfileType.HTTP:
      return exportUserinfoHttp(p, p.tls ? 'https' : 'http');
    case ProfileType.SOCKS:
      return exportUserinfoHttp(p, 'socks');
    default:
      return '';
  }
}
