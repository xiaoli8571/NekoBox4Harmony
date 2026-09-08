import { Profile, AppSettings, ProfileType, supportsTransport, needsTlsByDefault } from '../model/Profile';
import { CLASH_API_PORT } from '../utils/TrafficStats';
import { RouteRule, RemoteRuleSet, ruleValueList } from '../model/RouteRule';

/**
 * sing-box 1.14 配置生成器。
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
const FAKEIP_RANGE_V4 = '198.18.0.0/15';
const FAKEIP_RANGE_V6 = 'fc00::/18';

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
  const hasEch = p.ech;
  if (!p.tls && !forceTls && !hasReality && !hasEch) {
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
  if (p.certificates.trim().length > 0) {
    const certs: Array<string> = [];
    for (const c of p.certificates.split('\n\n')) {
      const t = c.trim();
      if (t.length > 0) {
        certs.push(t);
      }
    }
    if (certs.length > 0) {
      tls['certificate'] = certs;
    }
  }
  if (hasReality) {
    const reality: Record<string, Object> = { 'enabled': true };
    reality['public_key'] = p.realityPublicKey;
    if (p.realityShortId.length > 0) {
      reality['short_id'] = p.realityShortId;
    }
    tls['reality'] = reality;
  }
  // 内核 reality 客户端强制要求 uTLS(reality_client.go: UTLS==nil||!Enabled → 启动失败)
  // 非 reality 出站仅在用户指定指纹时启用
  if (hasReality || p.fingerprint.length > 0) {
    const utls: Record<string, Object> = { 'enabled': true };
    utls['fingerprint'] = p.fingerprint.length > 0 ? p.fingerprint : 'chrome';
    tls['utls'] = utls;
  }
  if (hasEch) {
    const ech: Record<string, Object> = { 'enabled': true };
    setIf(ech, 'config', p.echConfig.trim());
    tls['ech'] = ech;
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
      if (p.wsEarlyData > 0) {
        t['max_early_data'] = p.wsEarlyData;
      }
      if (p.wsEarlyDataHeaderName.length > 0) {
        t['early_data_header_name'] = p.wsEarlyDataHeaderName;
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

function buildOutbound(p: Profile, s: AppSettings, tag: string = 'proxy'): Record<string, Object> {
  const o: Record<string, Object> = {};
  o['tag'] = tag;

  if (p.type === ProfileType.CUSTOM) {
    const parsed = JSON.parse(p.customOutbound) as Record<string, Object>;
    if (parsed['type'] === undefined) {
      throw new Error('自定义出站 JSON 缺少 type 字段');
    }
    const keys = Object.keys(parsed);
    for (const k of keys) {
      o[k] = parsed[k];
    }
    o['tag'] = tag;
    return o;
  }

  o['type'] = p.type;
  o['server'] = p.server;
  o['server_port'] = p.serverPort;

  switch (p.type) {
    case ProfileType.SHADOWSOCKS:
      o['method'] = p.method;
      o['password'] = p.password;
      if (p.ssPlugin.length > 0) {
        o['plugin'] = p.ssPlugin;
        if (p.ssPluginOpts.length > 0) {
          o['plugin_opts'] = p.ssPluginOpts;
        }
      }
      break;
    case ProfileType.VMESS:
      o['uuid'] = p.uuid;
      o['security'] = p.security.length > 0 ? p.security : 'auto';
      if (p.alterId > 0) {
        o['alter_id'] = p.alterId;
      }
      if (p.packetEncoding.length > 0) {
        o['packet_encoding'] = p.packetEncoding;
      }
      break;
    case ProfileType.VLESS:
      o['uuid'] = p.uuid;
      setIf(o, 'flow', p.flow);
      o['packet_encoding'] = p.packetEncoding.length > 0 ? p.packetEncoding : 'xudp';
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
    case ProfileType.HYSTERIA2: {
      if (p.upMbps > 0) {
        o['up_mbps'] = p.upMbps;
      }
      if (p.downMbps > 0) {
        o['down_mbps'] = p.downMbps;
      }
      if (p.obfs.length > 0) {
        const obfs: Record<string, Object> = {};
        obfs['type'] = 'salamander';
        obfs['password'] = p.obfs;
        o['obfs'] = obfs;
      }
      o['password'] = p.password;
      const ports = normalizeServerPorts(p.serverPorts);
      if (ports.length > 0) {
        o['server_ports'] = ports;
        if (p.hopInterval > 0) {
          o['hop_interval'] = `${p.hopInterval}s`;
        }
      }
      break;
    }
    case ProfileType.TUIC:
      o['uuid'] = p.uuid;
      if (p.password.length > 0) {
        o['password'] = p.password;
      }
      setIf(o, 'congestion_control', p.congestionControl);
      setIf(o, 'udp_relay_mode', p.udpRelayMode);
      if (p.reduceRtt) {
        o['reduce_rtt'] = true;
      }
      if (p.disableSni) {
        o['disable_sni'] = true;
      }
      break;
    case ProfileType.WIREGUARD: {
      setIf(o, 'local_address', p.localAddress, false);
      o['private_key'] = p.privateKey;
      if (p.wgMtu > 0) {
        o['mtu'] = p.wgMtu;
      }
      const reserved = parseReserved(p.reserved);
      if (reserved.length === 3) {
        o['reserved'] = reserved;
      }
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
    case ProfileType.SSH:
      setIf(o, 'user', p.username);
      if (p.sshAuthType === 'password') {
        o['password'] = p.password;
      } else if (p.sshAuthType === 'private_key') {
        setIf(o, 'private_key', p.privateKey);
        setIf(o, 'private_key_passphrase', p.privateKeyPassphrase);
      }
      {
        const hostKeys = splitCsv(p.hostKey);
        if (hostKeys.length > 0) {
          const hk: Array<Object> = [];
          for (const k of hostKeys) {
            hk.push(k);
          }
          o['host_key'] = hk;
        }
      }
      break;
    case ProfileType.SHADOWTLS:
      o['version'] = p.shadowtlsVersion === 2 ? 2 : 3;
      setIf(o, 'password', p.password);
      break;
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
    mux['protocol'] = p.muxProtocol.length > 0 ? p.muxProtocol : 'h2mux';
    if (p.muxMaxStreams > 0) {
      mux['max_streams'] = p.muxMaxStreams;
    }
    if (!p.muxPadding) {
      mux['padding'] = false;
    }
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

/** hysteria2 server_ports 归一化:"2080-3000,4000" → ["2080:3000","4000"] */
function normalizeServerPorts(raw: string): Array<string> {
  const out: Array<string> = [];
  for (const part of raw.split(',')) {
    const t = part.trim().replace('-', ':');
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}

/** WireGuard reserved "1,2,3" → [1,2,3];非法输入返回空数组 */
function parseReserved(raw: string): Array<number> {
  const out: Array<number> = [];
  for (const part of raw.split(',')) {
    const n = parseInt(part.trim());
    if (isNaN(n) || n < 0 || n > 255) {
      return [];
    }
    out.push(n);
  }
  return out;
}

/** 链式代理:返回全部出站(前置→落地);默认最后一跳出站 tag=proxy。
 *  URL 测速复用本函数:finalTag/chainPrefix 传唯一前缀,避免多链在测试配置里撞 tag。 */
function buildChainOutbounds(chainProfile: Profile, s: AppSettings,
  allProfiles: Array<Profile>, finalTag: string = 'proxy',
  chainPrefix: string = 'chain_'): Array<Record<string, Object>> {
  const ids = splitCsv(chainProfile.chainIds);
  if (ids.length === 0) {
    throw new Error('链式代理未选择任何节点');
  }
  const hops: Array<Profile> = [];
  for (const id of ids) {
    const found = allProfiles.find(x => x.id === id);
    if (found !== undefined && found.type !== ProfileType.CHAIN) {
      hops.push(found);
    }
  }
  if (hops.length === 0) {
    throw new Error('链式代理引用的节点不存在');
  }
  const outbounds: Array<Record<string, Object>> = [];
  for (let i = 0; i < hops.length; i++) {
    const hopTag = i === hops.length - 1 ? finalTag : `${chainPrefix}${i}`;
    const hop = buildOutbound(hops[i], s, hopTag);
    if (i > 0) {
      hop['detour'] = `${chainPrefix}${i - 1}`;
    }
    outbounds.push(hop);
  }
  return outbounds;
}

/** 把自定义路由规则生成 sing-box 1.11 rule 对象(reject 出站改用 rule action) */
export function buildCustomRule(r: RouteRule): Record<string, Object> | null {
  const rule: Record<string, Object> = {};
  if (r.type === 'port') {
    const ports: Array<Object> = [];
    for (const v of ruleValueList(r)) {
      const n = parseInt(v);
      if (!isNaN(n)) {
        ports.push(n);
      }
    }
    if (ports.length === 0) {
      return null;
    }
    rule['port'] = ports;
  } else {
    const items: Array<string> = ruleValueList(r);
    if (items.length === 0) {
      return null;
    }
    rule[r.type] = items;
  }
  if (r.outbound === 'reject') {
    rule['action'] = 'reject';
  } else {
    rule['outbound'] = r.outbound;
  }
  return rule;
}

/**
 * sing-box 1.14 新 DNS server 格式:把旧式地址串(scheme://host[:port][/path] 或裸 IP)
 * 拆解为 {type, server, server_port, path, detour}。1.14 已移除 legacy address 格式。
 */
function buildDnsServer(tag: string, addr: string, detour: string): Record<string, Object> {
  const server: Record<string, Object> = {};
  server['tag'] = tag;
  let rest = addr.trim();
  let type = 'udp';
  const schemeEnd = rest.indexOf('://');
  let scheme = '';
  if (schemeEnd > 0) {
    scheme = rest.substring(0, schemeEnd).toLowerCase();
    rest = rest.substring(schemeEnd + 3);
  }
  if (scheme.length > 0) {
    if (scheme === 'dot') {
      type = 'tls';
    } else if (scheme === 'doq') {
      type = 'quic';
    } else {
      type = scheme;
    }
  }
  server['type'] = type;
  if (type === 'udp' || type === 'tcp' || type === 'tls' || type === 'https' || type === 'quic' || type === 'h3') {
    let hostPort = rest;
    let path = '';
    const slash = rest.indexOf('/');
    if (slash >= 0) {
      hostPort = rest.substring(0, slash);
      path = rest.substring(slash);
    }
    let host = hostPort;
    let portStr = '';
    if (hostPort.startsWith('[')) {
      const bracket = hostPort.lastIndexOf(']');
      const colon = hostPort.lastIndexOf(':');
      host = hostPort.substring(0, bracket + 1);
      if (colon > bracket) {
        portStr = hostPort.substring(colon + 1);
      }
    } else {
      const colon = hostPort.lastIndexOf(':');
      if (colon > 0) {
        host = hostPort.substring(0, colon);
        portStr = hostPort.substring(colon + 1);
      }
    }
    server['server'] = host;
    if (portStr.length > 0) {
      const pn = parseInt(portStr);
      if (!isNaN(pn) && pn > 0 && pn <= 65535) {
        server['server_port'] = pn;
      }
    }
    if (type === 'https' || type === 'h3') {
      server['path'] = path.length > 0 ? path : '/dns-query';
    }
  }
  if (detour.length > 0 && type !== 'local' && type !== 'hosts' && type !== 'fakeip' && type !== 'dhcp') {
    server['detour'] = detour;
  }
  return server;
}

/** 生成 geo 本地 rule-set 定义(sing-geo* rule-set 分支的 *.db 为编译二进制 rule set) */
function buildGeoRuleSet(tag: string, path: string): Record<string, Object> {
  const def: Record<string, Object> = {};
  def['tag'] = tag;
  def['type'] = 'local';
  def['format'] = 'binary';
  def['path'] = path;
  return def;
}

export function buildCoreConfig(p: Profile, s: AppSettings, physicalIfname: string,
  logPath: string = '', geositePath: string = '', geoIpPath: string = '',
  customRules: Array<RouteRule> = [], remoteRuleSets: Array<RemoteRuleSet> = [],
  cachePath: string = '', allProfiles: Array<Profile> = []): string {
  if (p.type !== ProfileType.CUSTOM && p.type !== ProfileType.CHAIN && p.server.length === 0) {
    throw new Error('服务器地址为空');
  }
  if (s.mtu < 1280) {
    throw new Error('MTU 过小');
  }

  // ---- inbounds ----
  const tun: Record<string, Object> = {};
  tun['type'] = 'tun';
  tun['tag'] = 'tun-in';
  if (s.ipv6) {
    tun['address'] = [TUN_ADDR_V4, TUN_ADDR_V6];
  } else {
    tun['address'] = [TUN_ADDR_V4];
  }
  tun['mtu'] = s.mtu;
  tun['auto_route'] = false;   // 路由由鸿蒙 VPN 框架管理
  tun['strict_route'] = false;
  tun['stack'] = s.stack;
  // 1.13+:inbound 级 sniff/sniff_override_destination 已移除,改为 route action:"sniff"
  // (新 sniff 动作嗅探成功即覆写目的域名,不再区分 keep/override)
  const inbounds: Array<Object> = [tun];
  if (s.mixedPort > 0) {
    const mixed: Record<string, Object> = {};
    mixed['type'] = 'mixed';
    mixed['tag'] = 'mixed-in';
    mixed['listen'] = s.allowAccess ? '0.0.0.0' : '127.0.0.1';
    mixed['listen_port'] = s.mixedPort;
    inbounds.push(mixed);
  }

  // ---- outbounds ----
  const outbounds: Array<Object> = [];
  if (p.type === ProfileType.CHAIN) {
    const chainOutbounds = buildChainOutbounds(p, s, allProfiles);
    for (const co of chainOutbounds) {
      outbounds.push(co);
    }
  } else {
    outbounds.push(buildOutbound(p, s));
  }
  const direct: Record<string, Object> = { 'type': 'direct', 'tag': 'direct' };
  // 1.11: block/dns 特殊 outbound 已移除,分流用 rule action(hijack-dns / reject)
  outbounds.push(direct);

  // ---- dns(sing-box 1.14 新 server 格式:type + server/server_port/path) ----
  // 1.14:DNS server 不写 detour 即默认直连(等价空 direct);
  // 显式 detour 到「空 direct outbound」会被内核判启动失败
  // (detour to an empty direct outbound makes no sense),故 local 服务器不带 detour。
  const dnsServers: Array<Object> = [
    buildDnsServer('remote', s.remoteDns, 'proxy'),
    buildDnsServer('local', s.directDns, '')
  ];
  if (s.fakeDns) {
    const fakeServer: Record<string, Object> = {};
    fakeServer['type'] = 'fakeip';
    fakeServer['tag'] = 'fake';
    fakeServer['inet4_range'] = FAKEIP_RANGE_V4;
    if (s.ipv6) {
      fakeServer['inet6_range'] = FAKEIP_RANGE_V6;
    }
    dnsServers.push(fakeServer);
  }
  const dnsRules: Array<Object> = [];
  if (s.fakeDns) {
    const fakeRule: Record<string, Object> = {};
    const queryTypes: Array<Object> = ['A', 'AAAA'];
    fakeRule['query_type'] = queryTypes;
    fakeRule['server'] = 'fake';
    dnsRules.push(fakeRule);
  }
  // 规则模式 + DNS 路由开启 + geosite 数据就绪:CN 域名用直连 DNS 解析(CDN 友好)
  // 1.14:rule 级 geosite 字段已移除,改为引用本地 rule_set
  if (s.mode === 'rule' && s.dnsRouting && geositePath.length > 0) {
    const cnDnsRule: Record<string, Object> = {};
    cnDnsRule['rule_set'] = ['geosite_cn'];
    cnDnsRule['server'] = 'local';
    setIf(cnDnsRule, 'strategy', s.directDnsStrategy);
    dnsRules.push(cnDnsRule);
  }
  // 1.14:legacy outbound DNS rule 已弃用,改用 route.default_domain_resolver
  // (出站服务器域名一律经 local 直连 DNS 解析,语义等价且防泄漏不变)
  const dns: Record<string, Object> = {};
  dns['servers'] = dnsServers;
  dns['rules'] = dnsRules;
  dns['final'] = 'remote';
  setIf(dns, 'strategy', s.remoteDnsStrategy);

  // ---- route ----
  // ---- route ----
  const routeRules: Array<Object> = [];
  // 1.13+:sniff 由 inbound 字段迁移为 rule action(嗅探成功即覆写目的域名)
  if (s.sniffMode !== 'off') {
    const sniffRule: Record<string, Object> = {};
    sniffRule['inbound'] = 'tun-in';
    sniffRule['action'] = 'sniff';
    routeRules.push(sniffRule);
  }
  // DNS 劫持:终端 53 报文交给内核 DNS 栈处理(TUN 模式必须)
  const dnsHijackRule: Record<string, Object> = {};
  dnsHijackRule['protocol'] = 'dns';
  dnsHijackRule['action'] = 'hijack-dns';
  routeRules.push(dnsHijackRule);
  const ruleSetDefinitions: Array<Object> = [];

  // 模式:direct(全部直连)/ rule(规则分流)/ global(除 DNS 劫持外全部走代理)
  let finalOutbound = 'proxy';
  if (s.mode === 'direct') {
    finalOutbound = 'direct';
  } else if (s.mode === 'rule') {
    // 私网、自定义、Geo 与远程规则只允许在规则模式参与分流。
    if (s.bypassLan) {
      const privateRule: Record<string, Object> = {};
      privateRule['ip_cidr'] = [
        '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8',
        '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', '255.255.255.255/32',
        '::1/128', 'fe80::/10', 'fc00::/7', 'ff00::/8'
      ];
      privateRule['outbound'] = 'direct';
      routeRules.push(privateRule);
    }

    for (const r of customRules) {
      if (!r.enabled) {
        continue;
      }
      const rule = buildCustomRule(r);
      if (rule !== null) {
        routeRules.push(rule);
      }
    }

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
    if (geositePath.length > 0) {
      const geositeRule: Record<string, Object> = {};
      geositeRule['rule_set'] = ['geosite_cn'];
      geositeRule['outbound'] = 'direct';
      routeRules.push(geositeRule);
    }
    if (geoIpPath.length > 0) {
      const geoipRule: Record<string, Object> = {};
      geoipRule['rule_set'] = ['geoip_cn'];
      geoipRule['outbound'] = 'direct';
      routeRules.push(geoipRule);
    }

    for (const item of remoteRuleSets) {
      if (!item.enabled || item.id.length === 0 || item.url.length === 0) {
        continue;
      }
      const definition: Record<string, Object> = {};
      definition['tag'] = `remote_${item.id}`;
      definition['type'] = 'remote';
      definition['format'] = 'binary';
      definition['url'] = item.url;
      definition['download_detour'] = 'direct';
      definition['update_interval'] = '24h';
      ruleSetDefinitions.push(definition);

      const reference: Record<string, Object> = {};
      reference['rule_set'] = [`remote_${item.id}`];
      reference['outbound'] = item.outbound;
      routeRules.push(reference);
    }

    if (s.resolveDestination) {
      // 兜底规则前先解析目标地址:IP 类规则得以匹配域名连接(对齐安卓解析目标地址)
      // 1.14:布尔 resolve 字段已移除改 action:"resolve";该动作不接受 outbound 选项,
      // 单独成条(非终止动作,位于直连/规则分流之后、final 之前,行为等价)
      const resolveRule: Record<string, Object> = {};
      resolveRule['action'] = 'resolve';
      routeRules.push(resolveRule);
    }
  }

  const route: Record<string, Object> = {};
  route['rules'] = routeRules;
  // 1.14:顶层 route.geoip/geosite 仅支持 legacy geo.db;本项目下载的是
  // sing-geo* rule-set 分支的编译二进制,改为 local rule_set 定义(geo 规则按 tag 引用)
  if (geositePath.length > 0) {
    ruleSetDefinitions.unshift(buildGeoRuleSet('geosite_cn', geositePath));
  }
  if (geoIpPath.length > 0) {
    ruleSetDefinitions.unshift(buildGeoRuleSet('geoip_cn', geoIpPath));
  }
  if (ruleSetDefinitions.length > 0) {
    route['rule_set'] = ruleSetDefinitions;
  }
  route['final'] = finalOutbound;
  route['auto_detect_interface'] = false;
  // 1.14:出站服务器域名统一经 local(直连 DNS)解析
  const domainResolver: Record<string, Object> = {};
  domainResolver['server'] = 'local';
  route['default_domain_resolver'] = domainResolver;
  if (physicalIfname.length > 0) {
    route['default_interface'] = physicalIfname;
  }

  // ---- experimental: clash API(实时速率/流量统计) + cache file ----
  const experimental: Record<string, Object> = {};
  if (s.clashApiEnabled) {
    const clashApi: Record<string, Object> = {};
    clashApi['external_controller'] = `127.0.0.1:${s.clashApiPort}`;
    clashApi['secret'] = s.clashApiSecret;
    experimental['clash_api'] = clashApi;
  }
  const cacheFile: Record<string, Object> = {};
  if (cachePath.length > 0) {
    // OHOS 沙箱内内核 CWD 不可写,必须给绝对路径,否则 open cache.db: permission denied
    cacheFile['enabled'] = true;
    cacheFile['path'] = cachePath;
  } else {
    cacheFile['enabled'] = false;
  }
  experimental['cache_file'] = cacheFile;

  // ---- log ----
  const log: Record<string, Object> = {};
  log['level'] = s.logLevel.length > 0 ? s.logLevel : 'info';
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
  // 全局自定义配置:与根对象浅合并(用户键优先,语法错误时忽略)
  if (s.globalCustomConfig.trim().length > 0) {
    try {
      const custom = JSON.parse(s.globalCustomConfig) as Record<string, Object>;
      const keys = Object.keys(custom);
      for (const k of keys) {
        config[k] = custom[k];
      }
    } catch (e) {
      // 忽略非法 JSON,保持主配置可用
    }
  }
  return JSON.stringify(config, null, 2);
}

/** 导出单节点 sing-box 出站 JSON(分享菜单「导出配置」用) */
export function buildOutboundJson(p: Profile, s: AppSettings): string {
  return JSON.stringify(buildOutbound(p, s), null, 2);
}

/** URL 测速配置:json + 每节点出站 tag(空串=该节点无法构建,调用方直接记 -1) */
export class LatencyTestConfig {
  json: string = '';
  tags: Array<string> = [];
}

/**
 * 生成真连接测速专用配置:每个待测节点一个出站(tag=t<i>;链节点展开为 c<i>_* + t<i>),
 * 无入站/无 TUN/无 clash/无 cache,仅一条直连 DNS 用于解析节点域名。
 * 内核侧(CGoTestStartSingBox)会再强制清空 inbounds/experimental 做双保险。
 */
export function buildLatencyTestConfig(targets: Array<Profile>, allProfiles: Array<Profile>,
  s: AppSettings, logPath: string): LatencyTestConfig {
  const result = new LatencyTestConfig();
  const outbounds: Array<Object> = [];
  for (let i = 0; i < targets.length; i++) {
    const p = targets[i];
    const tag = `t${i}`;
    try {
      if (p.type === ProfileType.CHAIN) {
        const hops = buildChainOutbounds(p, s, allProfiles, tag, `c${i}_`);
        for (const h of hops) {
          outbounds.push(h);
        }
      } else {
        outbounds.push(buildOutbound(p, s, tag));
      }
      result.tags.push(tag);
    } catch (e) {
      result.tags.push('');
    }
  }
  const direct: Record<string, Object> = { 'type': 'direct', 'tag': 'direct' };
  outbounds.push(direct);

  const cfg: Record<string, Object> = {};
  if (logPath.length > 0) {
    const log: Record<string, Object> = { 'level': 'warning', 'timestamp': true, 'output': logPath };
    cfg['log'] = log;
  }
  const dns: Record<string, Object> = {};
  const probeDns = s.directDns.trim().length > 0 ? s.directDns : '223.5.5.5';
  dns['servers'] = [buildDnsServer('probe', probeDns, '')];
  dns['final'] = 'probe';
  cfg['dns'] = dns;
  cfg['outbounds'] = outbounds;
  const route: Record<string, Object> = {};
  route['rules'] = [];
  route['final'] = 'direct';
  route['auto_detect_interface'] = false;
  const ddr: Record<string, Object> = { 'server': 'probe' };
  route['default_domain_resolver'] = ddr;
  cfg['route'] = route;
  result.json = JSON.stringify(cfg, null, 2);
  return result;
}
