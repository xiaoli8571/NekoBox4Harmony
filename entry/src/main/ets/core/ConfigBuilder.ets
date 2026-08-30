import { Profile, AppSettings, ProfileType, supportsTransport, needsTlsByDefault } from '../model/Profile';
import { CLASH_API_PORT } from '../utils/TrafficStats';

/**
 * sing-box 1.4 配置生成器。
 *
 * 关键设计(与鸿蒙 VPN 框架配合):
 *  - tun 入站 auto_route=false:路由由 @ohos.net.vpnExtension 建立;
 *    TUN fd 由 NAPI 子进程通过 SING_BOX_TUN_FD 注入(见 core/patches)。
 *  - dns: 代理服务器域名用直连 DNS 解析(directDns,其 IP 由 VPN 配置加
 *    排除路由,防止回环);其余一律走"remote"(经代理的 DoH,防 DNS 泄漏)。
 *  - route.default_interface:可选绑定物理网卡(实验性,见设置页)。
 */

const TUN_ADDR_V4 = '172.19.0.1/30';
const TUN_ADDR_V6 = 'fdfe:dcba:9876::1/126';

function setIf(o: Record<string, Object>, key: string, value: Object, skipEmpty: boolean = true): void {
  if (!skipEmpty || `${value}`.length > 0) {
    o[key] = value;
  }
}

function setIfTrue(o: Record<string, Object>, key: string, value: boolean): void {
  if (value) {
    o[key] = true;
  }
}

function splitCsv(s: string): Array<string> {
  const parts = s.split(',');
  const out: Array<string> = [];
  for (const p of parts) {
    const t = p.trim();
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}

function buildTls(p: Profile, s: AppSettings): Object | undefined {
  const forceTls = needsTlsByDefault(p.type);
  const hasReality = p.realityPublicKey.length > 0;
  if (!p.tls && !forceTls && !hasReality) {
    return undefined;
  }
  const tls: Record<string, Object> = { 'enabled': true };
  const serverName = p.sni.length > 0 ? p.sni : p.server;
  if (serverName.length > 0) {
    tls['server_name'] = serverName;
  }
  if (p.allowInsecure || s.allowInsecureAll) {
    tls['insecure'] = true;
  }
  const alpn = splitCsv(p.alpn);
  if (alpn.length > 0) {
    tls['alpn'] = alpn;
  }
  if (hasReality) {
    const reality: Record<string, Object> = { 'enabled': true };
    reality['public_key'] = p.realityPublicKey;
    if (p.realityShortId.length > 0) {
      reality['short_id'] = p.realityShortId;
    }
    tls['reality'] = reality;
  }
  return tls;
}

function buildTransport(p: Profile): Object | undefined {
  if (!supportsTransport(p.type) || p.transport.length === 0) {
    return undefined;
  }
  const t: Record<string, Object> = { 'type': p.transport };
  switch (p.transport) {
    case 'ws':
      setIf(t, 'path', p.path);
      if (p.host.length > 0) {
        const headers: Record<string, Object> = {};
        headers['Host'] = [p.host];
        t['headers'] = headers;
      }
      break;
    case 'http':
      setIf(t, 'path', p.path, false);
      if (p.host.length > 0) {
        t['host'] = [p.host];
      }
      break;
    case 'grpc':
      setIf(t, 'service_name', p.serviceName);
      break;
    case 'httpupgrade':
      setIf(t, 'path', p.path);
      setIf(t, 'host', p.host);
      break;
    case 'quic':
      break;
    default:
      return undefined;
  }
  return t;
}

function buildOutbound(p: Profile, s: AppSettings): Record<string, Object> {
  const o: Record<string, Object> = {};
  o['type'] = p.type;
  o['tag'] = 'proxy';
  o['server'] = p.server;
  o['server_port'] = p.serverPort;

  switch (p.type) {
    case ProfileType.SHADOWSOCKS:
      o['method'] = p.method;
      o['password'] = p.password;
      break;
    case ProfileType.VMESS:
      o['uuid'] = p.uuid;
      o['security'] = p.security.length > 0 ? p.security : 'auto';
      if (p.alterId > 0) {
        o['alter_id'] = p.alterId;
      }
      break;
    case ProfileType.VLESS:
      o['uuid'] = p.uuid;
      setIf(o, 'flow', p.flow);
      o['packet_encoding'] = 'xudp';
      break;
    case ProfileType.TROJAN:
      o['password'] = p.password;
      break;
    case ProfileType.HYSTERIA:
      if (p.upMbps > 0) {
        o['up_mbps'] = p.upMbps;
      }
      if (p.downMbps > 0) {
        o['down_mbps'] = p.downMbps;
      }
      if (p.obfs.length > 0) {
        o['obfs'] = p.obfs;
      }
      o['auth_str'] = p.password;
      break;
    case ProfileType.TUIC:
      o['uuid'] = p.uuid;
      if (p.password.length > 0) {
        o['password'] = p.password;
      }
      setIf(o, 'congestion_control', p.congestionControl);
      setIf(o, 'udp_relay_mode', p.udpRelayMode);
      break;
    case ProfileType.WIREGUARD: {
      setIf(o, 'local_address', p.localAddress, false);
      o['private_key'] = p.privateKey;
      const peer: Record<string, Object> = {};
      peer['public_key'] = p.peerPublicKey;
      if (p.preSharedKey.length > 0) {
        peer['pre_shared_key'] = p.preSharedKey;
      }
      peer['allowed_ips'] = ['0.0.0.0/0', '::/0'];
      const peers: Array<Object> = [peer];
      o['peers'] = peers;
      break;
    }
    case ProfileType.HTTP:
    case ProfileType.SOCKS:
      setIf(o, 'username', p.username);
      setIf(o, 'password', p.password);
      break;
    default:
      throw new Error(`不支持的协议: ${p.type}`);
  }

  const tls = buildTls(p, s);
  if (tls !== undefined) {
    o['tls'] = tls;
  }
  const transport = buildTransport(p);
  if (transport !== undefined) {
    o['transport'] = transport;
  }
  if (p.mux && supportsTransport(p.type) && p.transport !== 'quic') {
    const mux: Record<string, Object> = { 'enabled': true };
    mux['protocol'] = 'h2mux';
    mux['max_streams'] = 8;
    o['multiplex'] = mux;
  }
  if (p.extra.trim().length > 0) {
    const extra = JSON.parse(p.extra) as Record<string, Object>;
    const keys = Object.keys(extra);
    for (const k of keys) {
      o[k] = extra[k];
    }
  }
  return o;
}

export function buildCoreConfig(p: Profile, s: AppSettings, physicalIfname: string,
  logPath: string = '', geositePath: string = '', geoIpPath: string = ''): string {
  if (p.server.length === 0) {
    throw new Error('服务器地址为空');
  }
  if (s.mtu < 1280) {
    throw new Error('MTU 过小');
  }

  // ---- inbounds ----
  const tun: Record<string, Object> = {};
  tun['type'] = 'tun';
  tun['tag'] = 'tun-in';
  tun['inet4_address'] = [TUN_ADDR_V4];
  if (s.ipv6) {
    tun['inet6_address'] = [TUN_ADDR_V6];
  }
  tun['mtu'] = s.mtu;
  tun['auto_route'] = false;   // 路由由鸿蒙 VPN 框架管理
  tun['strict_route'] = false;
  tun['stack'] = s.stack;
  tun['sniff'] = true;
  const inbounds: Array<Object> = [tun];

  // ---- outbounds ----
  const proxy = buildOutbound(p, s);
  const direct: Record<string, Object> = { 'type': 'direct', 'tag': 'direct' };
  const block: Record<string, Object> = { 'type': 'block', 'tag': 'block' };
  const dnsOut: Record<string, Object> = { 'type': 'dns', 'tag': 'dns-out' };
  const outbounds: Array<Object> = [proxy, direct, block, dnsOut];

  // ---- dns ----
  const remoteServer: Record<string, Object> = {};
  remoteServer['tag'] = 'remote';
  remoteServer['address'] = s.remoteDns;
  remoteServer['detour'] = 'proxy';
  const localServer: Record<string, Object> = {};
  localServer['tag'] = 'local';
  localServer['address'] = s.directDns.includes('://') ? s.directDns : `udp://${s.directDns}`;
  localServer['detour'] = 'direct';
  const dnsServers: Array<Object> = [remoteServer, localServer];
  const dnsRules: Array<Object> = [];
  // 规则模式 + geosite 数据就绪:CN 域名用直连 DNS 解析(CDN 友好)
  if (s.mode === 'rule' && geositePath.length > 0) {
    const cnDnsRule: Record<string, Object> = {};
    cnDnsRule['geosite'] = ['cn'];
    cnDnsRule['server'] = 'local';
    dnsRules.push(cnDnsRule);
  }
  const resolveProxyRule: Record<string, Object> = {};
  resolveProxyRule['outbound'] = 'proxy';
  resolveProxyRule['server'] = 'local';
  dnsRules.push(resolveProxyRule);
  const dns: Record<string, Object> = {};
  dns['servers'] = dnsServers;
  dns['rules'] = dnsRules;
  dns['final'] = 'remote';

  // ---- route ----
  const dnsRule: Record<string, Object> = {};
  dnsRule['protocol'] = 'dns';
  dnsRule['outbound'] = 'dns-out';
  // 1.4 没有 ip_is_private 字段,用私网网段列表等价实现
  const privateRule: Record<string, Object> = {};
  privateRule['ip_cidr'] = [
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8',
    '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', '255.255.255.255/32',
    '::1/128', 'fe80::/10', 'fc00::/7', 'ff00::/8'
  ];
  privateRule['outbound'] = 'direct';
  const routeRules: Array<Object> = [dnsRule, privateRule];

  // 模式:direct(全部直连)/ rule(规则:私网+自定义直连+CN分流,其余走代理)/ global(全部走代理)
  let finalOutbound = 'proxy';
  if (s.mode === 'direct') {
    finalOutbound = 'direct';
  } else if (s.mode === 'rule') {
    const customDomains = splitCsv(s.directDomains);
    if (customDomains.length > 0) {
      const domainRule: Record<string, Object> = {};
      domainRule['domain_suffix'] = customDomains;
      domainRule['outbound'] = 'direct';
      routeRules.push(domainRule);
    }
    const customCidrs = splitCsv(s.directIpCidrs);
    if (customCidrs.length > 0) {
      const cidrRule: Record<string, Object> = {};
      cidrRule['ip_cidr'] = customCidrs;
      cidrRule['outbound'] = 'direct';
      routeRules.push(cidrRule);
    }
    // GeoIP/GeoSite 分流(数据文件就绪时启用)
    if (geositePath.length > 0) {
      const geositeRule: Record<string, Object> = {};
      geositeRule['geosite'] = ['cn'];
      geositeRule['outbound'] = 'direct';
      routeRules.push(geositeRule);
    }
    if (geoIpPath.length > 0) {
      const geoipRule: Record<string, Object> = {};
      geoipRule['geoip'] = ['cn'];
      geoipRule['outbound'] = 'direct';
      routeRules.push(geoipRule);
    }
  }
  const route: Record<string, Object> = {};
  route['rules'] = routeRules;
  route['final'] = finalOutbound;
  route['auto_detect_interface'] = false;
  if (physicalIfname.length > 0) {
    route['default_interface'] = physicalIfname;
  }
  if (geositePath.length > 0) {
    const geositeOpt: Record<string, Object> = {};
    geositeOpt['path'] = geositePath;
    route['geosite'] = geositeOpt;
  }
  if (geoIpPath.length > 0) {
    const geoipOpt: Record<string, Object> = {};
    geoipOpt['path'] = geoIpPath;
    route['geoip'] = geoipOpt;
  }

  // ---- experimental: clash API(实时速率/流量统计) ----
  const clashApi: Record<string, Object> = {};
  clashApi['external_controller'] = `127.0.0.1:${CLASH_API_PORT}`;
  const experimental: Record<string, Object> = {};
  experimental['clash_api'] = clashApi;

  // ---- log ----
  const log: Record<string, Object> = {};
  log['level'] = 'info';
  log['timestamp'] = true;
  if (logPath.length > 0) {
    log['output'] = logPath;
  }

  const config: Record<string, Object> = {};
  config['log'] = log;
  config['dns'] = dns;
  config['inbounds'] = inbounds;
  config['outbounds'] = outbounds;
  config['route'] = route;
  config['experimental'] = experimental;
  return JSON.stringify(config, null, 2);
}
