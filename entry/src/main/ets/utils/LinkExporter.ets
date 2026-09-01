import util from '@ohos.util';
import { Profile, ProfileType } from '../model/Profile';

function base64Encode(input: string): string {
  const bytes = new util.TextEncoder().encodeInto(input);
  return new util.Base64Helper().encodeToStringSync(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function hostPort(p: Profile): string {
  const host = p.server.includes(':') && !p.server.startsWith('[') ? `[${p.server}]` : p.server;
  return `${host}:${p.serverPort}`;
}

function addQuery(parts: Array<string>, key: string, value: string): void {
  if (value.length > 0) {
    parts.push(`${key}=${encodeURIComponent(value)}`);
  }
}

function tlsQuery(p: Profile, parts: Array<string>): void {
  if (p.realityPublicKey.length > 0) {
    parts.push('security=reality');
    addQuery(parts, 'pbk', p.realityPublicKey);
    addQuery(parts, 'sid', p.realityShortId);
  } else if (p.tls) {
    parts.push('security=tls');
  }
  addQuery(parts, 'sni', p.sni);
  addQuery(parts, 'alpn', p.alpn);
  addQuery(parts, 'fp', p.fingerprint);
  if (p.allowInsecure) {
    parts.push('insecure=1');
  }
}

function transportQuery(p: Profile, parts: Array<string>): void {
  addQuery(parts, 'type', p.transport);
  addQuery(parts, 'path', p.path);
  addQuery(parts, 'host', p.host);
  addQuery(parts, 'serviceName', p.serviceName);
}

function finish(base: string, parts: Array<string>, name: string): string {
  const query = parts.length > 0 ? `?${parts.join('&')}` : '';
  return `${base}${query}#${encodeURIComponent(name)}`;
}

/** 把节点导出成常见客户端可识别的分享链接。 */
export function exportProfileLink(p: Profile): string {
  const hp = hostPort(p);
  const parts: Array<string> = [];
  switch (p.type) {
    case ProfileType.SHADOWSOCKS:
      return `ss://${base64Encode(`${p.method}:${p.password}`)}@${hp}#${encodeURIComponent(p.name)}`;
    case ProfileType.VMESS: {
      const vmess: Record<string, Object> = {
        'v': '2', 'ps': p.name, 'add': p.server, 'port': `${p.serverPort}`, 'id': p.uuid,
        'aid': `${p.alterId}`, 'scy': p.security, 'net': p.transport.length > 0 ? p.transport : 'tcp',
        'type': 'none', 'host': p.host, 'path': p.path, 'tls': p.tls ? 'tls' : '', 'sni': p.sni
      };
      return `vmess://${base64Encode(JSON.stringify(vmess))}`;
    }
    case ProfileType.VLESS:
      addQuery(parts, 'encryption', 'none');
      addQuery(parts, 'flow', p.flow);
      transportQuery(p, parts);
      tlsQuery(p, parts);
      return finish(`vless://${p.uuid}@${hp}`, parts, p.name);
    case ProfileType.TROJAN:
      transportQuery(p, parts);
      tlsQuery(p, parts);
      return finish(`trojan://${encodeURIComponent(p.password)}@${hp}`, parts, p.name);
    case ProfileType.HYSTERIA:
      addQuery(parts, 'auth', p.password);
      addQuery(parts, 'upmbps', `${p.upMbps}`);
      addQuery(parts, 'downmbps', `${p.downMbps}`);
      addQuery(parts, 'obfs', p.obfs);
      addQuery(parts, 'peer', p.sni);
      return finish(`hysteria://${hp}`, parts, p.name);
    case ProfileType.HYSTERIA2:
      addQuery(parts, 'sni', p.sni);
      addQuery(parts, 'obfs-password', p.obfs);
      if (p.allowInsecure) {
        parts.push('insecure=1');
      }
      return finish(`hysteria2://${encodeURIComponent(p.password)}@${hp}`, parts, p.name);
    case ProfileType.TUIC:
      addQuery(parts, 'congestion_control', p.congestionControl);
      addQuery(parts, 'udp_relay_mode', p.udpRelayMode);
      addQuery(parts, 'sni', p.sni);
      addQuery(parts, 'alpn', p.alpn);
      if (p.allowInsecure) {
        parts.push('allow_insecure=1');
      }
      return finish(`tuic://${p.uuid}:${encodeURIComponent(p.password)}@${hp}`, parts, p.name);
    case ProfileType.HTTP:
    case ProfileType.SOCKS: {
      const scheme = p.type === ProfileType.HTTP ? (p.tls ? 'https' : 'http') : 'socks5';
      const auth = p.username.length > 0 ? `${encodeURIComponent(p.username)}:${encodeURIComponent(p.password)}@` : '';
      return `${scheme}://${auth}${hp}#${encodeURIComponent(p.name)}`;
    }
    case ProfileType.WIREGUARD:
      addQuery(parts, 'public_key', p.peerPublicKey);
      addQuery(parts, 'pre_shared_key', p.preSharedKey);
      addQuery(parts, 'local_address', p.localAddress);
      return finish(`wireguard://${encodeURIComponent(p.privateKey)}@${hp}`, parts, p.name);
    default:
      throw new Error(`不支持导出协议: ${p.type}`);
  }
}
