import { Profile, ProfileGroup, AppSettings, ProfileType, supportsTransport, needsTlsByDefault } from '../model/Profile';
import { CLASH_API_PORT } from '../utils/TrafficStats';
import { RouteRule, RemoteRuleSet } from '../model/RouteRule';

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

/**
 * 精简内核(libsingbox.so)注册的自定义出站类型白名单。
 * Custom 配置仅接受这些 type;WireGuard 必须使用原生节点类型(生成 endpoint)。
 * 与 core/libsingbox14/lean_context.go 的 OutboundRegistry 保持一致。
 */
export const CUSTOM_SUPPORTED_OUTBOUND_TYPES: Array<string> = [
  'direct', 'shadowsocks', 'vmess', 'vless', 'trojan',
  'hysteria', 'hysteria2', 'tuic', 'http', 'socks', 'ssh', 'shadowtls', 'anytls', 'snell'
];

export function isCustomOutboundTypeSupported(type: string): boolean {
  return CUSTOM_SUPPORTED_OUTBOUND_TYPES.indexOf(type) >= 0;
}

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

/** 导出供主机测试直接断言 extra 深合并结果(纯函数,无副作用)。 */
export function buildOutbound(p: Profile, s: AppSettings, tag: string = 'proxy'): Record<string, Object> {
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
    case ProfileType.WIREGUARD:
      throw new Error('WireGuard 必须使用 sing-box 1.14 endpoint 配置生成路径');
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
    case ProfileType.ANYTLS:
      setIf(o, 'password', p.password);
      break;
    case ProfileType.SNELL:
      // Snell v4:sing-box 字段为 version=4 + psk;obfs_mode 可选 http/tls,
      // http 混淆的伪装主机复用 transport host 字段(p.host)。
      o['version'] = 4;
      setIf(o, 'psk', p.password);
      if (p.obfs === 'http' || p.obfs === 'tls') {
        o['obfs_mode'] = p.obfs;
        setIf(o, 'name', p.host);
      }
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
    const extra = parseUserJson(p.extra);
    if (extra !== null) {
      deepMerge(o, extra);
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

/** sing-box 1.14 WireGuard 已从 outbound 迁移为顶层 endpoint。 */
function buildWireGuardEndpoint(p: Profile, tag: string = 'proxy'): Record<string, Object> {
  const endpoint: Record<string, Object> = {};
  endpoint['type'] = ProfileType.WIREGUARD;
  endpoint['tag'] = tag;
  const addresses = splitCsv(p.localAddress);
  if (addresses.length === 0) {
    throw new Error('WireGuard 本地地址不能为空');
  }
  endpoint['address'] = addresses;
  endpoint['private_key'] = p.privateKey;
  if (p.wgMtu > 0) {
    endpoint['mtu'] = p.wgMtu;
  }
  const peer: Record<string, Object> = {};
  peer['address'] = p.server;
  peer['port'] = p.serverPort;
  peer['public_key'] = p.peerPublicKey;
  if (p.preSharedKey.length > 0) {
    peer['pre_shared_key'] = p.preSharedKey;
  }
  peer['allowed_ips'] = ['0.0.0.0/0', '::/0'];
  const reserved = parseReserved(p.reserved);
  if (reserved.length === 3) {
    peer['reserved'] = reserved;
  }
  endpoint['peers'] = [peer];
  return endpoint;
}

/** 把自定义路由规则生成 sing-box 1.11 rule 对象(reject 出站改用 rule action) */
/**
 * 多字段 AND 规则生成(对齐安卓 RuleEntity + SingBoxOptionsUtil.makeSingBoxRule)。
 * 域名前缀:geosite:→rule_set, full:→domain, domain:→domain_suffix,
 * regexp:→domain_regex, keyword:→domain_keyword, 裸值→domain_suffix。
 * IP 前缀:geoip:private→ip_is_private, geoip:x→rule_set, 其他→ip_cidr。
 * 至少一个匹配字段才输出,否则返回 null。
 * geosite:/geoip: 引用标签会登记到引用集合(与安卓 generateRuleSet 同契约),
 * 由 buildCoreConfig 为每个引用生成同名 local rule_set 定义,否则内核
 * 启动即报 rule-set not found(内核 route/rule/rule_item_rule_set.go)。
 * collectReferencedTags:true 时登记引用(清空后首遍),false 时只生成规则。
 */
const referencedRuleSetTags: Array<string> = [];

export function collectReferencedRuleSets(): Array<string> {
  return referencedRuleSetTags;
}

function resetReferencedRuleSets(): void {
  referencedRuleSetTags.length = 0;
}

/**
 * Android Util.kt:129-158 mergeMap 语义:
 *  - 双方同键都为对象 → 递归深合并;
 *  - 值为数组且键以 + 开头 → 前插(src + dst);键以 + 结尾 → 后插(dst + src);
 *  - 其余 → src 覆盖 dst。
 * 注意 src 键的 + 前后缀只在数组值时解释,普通对象键原样写入。
 */
function isPlainObject(v: Object | null | undefined): boolean {
  return v !== null && v !== undefined && typeof v === 'object' && !Array.isArray(v);
}

export function deepMerge(dst: Record<string, Object>, src: Record<string, Object>): Record<string, Object> {
  const keys = Object.keys(src);
  for (const k of keys) {
    const v = src[k];
    if (isPlainObject(v) && isPlainObject(dst[k])) {
      const merged: Record<string, Object> = JSON.parse(JSON.stringify(dst[k])) as Record<string, Object>;
      dst[k] = deepMerge(merged, v as Record<string, Object>);
    } else if (Array.isArray(v)) {
      if (k.startsWith('+')) {
        const dstKey = k.substring(1);
        const current = Array.isArray(dst[dstKey]) ? (dst[dstKey] as Array<Object>) : [];
        dst[dstKey] = (v as Array<Object>).concat(current);
      } else if (k.endsWith('+') && k.length > 1) {
        const dstKey = k.substring(0, k.length - 1);
        const current = Array.isArray(dst[dstKey]) ? (dst[dstKey] as Array<Object>) : [];
        dst[dstKey] = current.concat(v as Array<Object>);
      } else {
        dst[k] = v;
      }
    } else {
      dst[k] = v;
    }
  }
  return dst;
}

/** 解析用户自定义 JSON;非法输入返回 null 由调用方忽略(单条坏配置不炸主配置)。 */
function parseUserJson(text: string): Record<string, Object> | null {
  if (text.trim().length === 0) {
    return null;
  }
  try {
    const parsed: Object | null = JSON.parse(text) as Object | null;
    return isPlainObject(parsed) ? parsed as Record<string, Object> : null;
  } catch (e) {
    return null;
  }
}

export function buildCustomRule(r: RouteRule, collectRefs: boolean = true): Record<string, Object> | null {
  const rule: Record<string, Object> = {};
  let matched = false;
  // sing-box 1.14: site/ip 规则集统一用 rule_set,域名和 IP 两段合并写入
  const ruleSetAcc: Array<string> = [];

  // 域名
  if (r.domains.trim().length > 0) {
    const domains: Array<string> = [];
    const suffixes: Array<string> = [];
    const regexes: Array<string> = [];
    const keywords: Array<string> = [];
    for (const raw of splitCsv(r.domains)) {
      const it = raw.toLowerCase();
      if (it.startsWith('geosite:')) {
        ruleSetAcc.push(it);
        if (collectRefs && referencedRuleSetTags.indexOf(it) < 0) {
          referencedRuleSetTags.push(it);
        }
      } else if (it.startsWith('full:')) {
        domains.push(it.substring('full:'.length));
      } else if (it.startsWith('domain:')) {
        suffixes.push(it.substring('domain:'.length));
      } else if (it.startsWith('regexp:')) {
        regexes.push(it.substring('regexp:'.length));
      } else if (it.startsWith('keyword:')) {
        keywords.push(it.substring('keyword:'.length));
      } else {
        suffixes.push(it);
      }
    }
    setIfList(rule, 'domain', domains);
    setIfList(rule, 'domain_suffix', suffixes);
    setIfList(rule, 'domain_regex', regexes);
    setIfList(rule, 'domain_keyword', keywords);
    if (domains.length > 0 || suffixes.length > 0 || regexes.length > 0 ||
      keywords.length > 0 || ruleSetAcc.length > 0) {
      matched = true;
    }
  }

  // 目的 IP
  if (r.ip.trim().length > 0) {
    const cidrs: Array<string> = [];
    for (const it of splitCsv(r.ip)) {
      if (it === 'geoip:private') {
        rule['ip_is_private'] = true;
        matched = true;
      } else if (it.startsWith('geoip:')) {
        ruleSetAcc.push(it);
        matched = true;
        if (collectRefs && referencedRuleSetTags.indexOf(it) < 0) {
          referencedRuleSetTags.push(it);
        }
      } else {
        cidrs.push(it);
      }
    }
    setIfList(rule, 'ip_cidr', cidrs);
    if (cidrs.length > 0) {
      matched = true;
    }
  }
  setIfList(rule, 'rule_set', ruleSetAcc);

  // 目的端口
  if (setRulePorts(rule, 'port', r.port)) {
    matched = true;
  }
  // 源 IP
  const sourceCidrs = splitCsv(r.source);
  if (sourceCidrs.length > 0) {
    rule['source_ip_cidr'] = sourceCidrs;
    matched = true;
  }
  // 源端口
  if (setRulePorts(rule, 'source_port', r.sourcePort)) {
    matched = true;
  }
  // 网络
  if (r.network === 'tcp' || r.network === 'udp') {
    rule['network'] = r.network;
    matched = true;
  }
  // Android ConfigBuilder.kt:543-544: listByLineOrComma, OR within protocol
  // while retaining AND with other fields of this same rule.
  const protocols = splitRuleList(r.protocol);
  if (protocols.length > 0) {
    rule['protocol'] = protocols;
    matched = true;
  }
  // 应用包名(进程名匹配)
  const packages = splitCsv(r.packages);
  if (packages.length > 0) {
    rule['process_name'] = packages;
    matched = true;
  }
  // 自定义配置 JSON(深合并,Android Util.kt:129-158 语义;非法 JSON 忽略)
  const ruleCustom = parseUserJson(r.config);
  if (ruleCustom !== null) {
    deepMerge(rule, ruleCustom);
    matched = true;
  }
  if (!matched) {
    return null;
  }
  if (r.outbound === 'reject') {
    rule['action'] = 'reject';
  } else {
    rule['outbound'] = r.outbound;
  }
  return rule;
}

/** Android listByLineOrComma: rule fields accept both separators. */
function splitRuleList(text: string): Array<string> {
  return text.split(/[,\r\n]/).map((part: string): string => part.trim())
    .filter((part: string): boolean => part.length > 0);
}

/** Preserve ranges as ranges, never silently turn 1000:2000 into port 1000. */
function setRulePorts(rule: Record<string, Object>, key: string, text: string): boolean {
  const ports: Array<number> = [];
  const ranges: Array<string> = [];
  for (const token of splitRuleList(text)) {
    if (/^\d+$/.test(token)) {
      const port = Number(token);
      if (port >= 0 && port <= 65535 && ports.indexOf(port) < 0) {
        ports.push(port);
      }
    } else if (/^\d*:\d*$/.test(token)) {
      const ends = token.split(':');
      const start = ends[0].length === 0 ? 0 : Number(ends[0]);
      const end = ends[1].length === 0 ? 65535 : Number(ends[1]);
      if (start <= end && end <= 65535 && ranges.indexOf(token) < 0) {
        ranges.push(token);
      }
    }
  }
  if (ports.length > 0) {
    rule[key] = ports;
  }
  setIfList(rule, `${key}_range`, ranges);
  return ports.length > 0 || ranges.length > 0;
}

/** Android autoDnsDomainStrategy: derive from IPv6Mode when unset. */
function modeDnsStrategy(mode: string): string {
  if (mode === 'prefer') {
    return 'prefer_ipv6';
  }
  if (mode === 'only') {
    return 'ipv6_only';
  }
  if (mode === 'enable') {
    return 'prefer_ipv4';
  }
  return 'ipv4_only';
}

/** Normalize Android's UI value before passing it to sing-box 1.14. */
function dnsStrategy(value: string, s: AppSettings, forServer: boolean = false): string {
  if (value.length > 0 && value !== 'auto') {
    return value;
  }
  if (forServer) {
    // Android SingBoxOptionsUtil: server auto → prefer_ipv4.
    return 'prefer_ipv4';
  }
  return modeDnsStrategy(effectiveIpv6Mode(s));
}

/** Resolve the effective IPv6 mode: ''(legacy) derives from the boolean. */
export function effectiveIpv6Mode(s: AppSettings): string {
  if (s.ipv6Mode === 'enable' || s.ipv6Mode === 'prefer' || s.ipv6Mode === 'only' || s.ipv6Mode === 'disable') {
    return s.ipv6Mode;
  }
  return s.ipv6 ? 'enable' : 'disable';
}

/** 非空数组才写入字段 */
function setIfList(o: Record<string, Object>, key: string, list: Array<string>): void {
  if (list.length > 0) {
    o[key] = list;
  }
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

/** Physical entrance-to-exit order. Only the root's group wraps a chain. */
function expandChain(p: Profile, profiles: Array<Profile>, ancestors: Array<string> = []): Array<Profile> {
  if (p.type !== ProfileType.CHAIN) {
    return [p];
  }
  if (ancestors.indexOf(p.id) >= 0) {
    throw new Error(`链式代理循环: ${p.id}`);
  }
  const next = ancestors.concat([p.id]);
  const hops: Array<Profile> = [];
  for (const id of splitCsv(p.chainIds)) {
    const member = profiles.find(x => x.id === id);
    if (member === undefined) {
      throw new Error(`链式代理节点不存在: ${id}`);
    }
    hops.push(...expandChain(member, profiles, next));
  }
  if (hops.length === 0) {
    throw new Error(`链式代理为空: ${p.id}`);
  }
  return hops;
}

export class ProfileGraph {
  outbounds: Array<Record<string, Object>> = [];
  endpoints: Array<Record<string, Object>> = [];
}

/** Build transactionally: a failed graph never leaves orphan hops in the caller. */
export function buildProfileGraph(p: Profile, profiles: Array<Profile>, groups: Array<ProfileGroup>,
  s: AppSettings, rootTag: string): ProfileGraph {
  const hops = expandChain(p, profiles);
  const group = groups.find(g => g.id === p.groupId);
  if (group !== undefined) {
    const front = profiles.find(x => x.id === group.frontProxy);
    const landing = profiles.find(x => x.id === group.landingProxy);
    // Android resolves the root chain first, then inserts raw group wrappers.
    // A CHAIN wrapper is not a supported raw outbound: reject rather than truncate.
    if (front !== undefined) {
      hops.unshift(front);
    }
    if (landing !== undefined) {
      hops.push(landing);
    }
  }
  const graph = new ProfileGraph();
  for (let i = 0; i < hops.length; i++) {
    const tag = i === hops.length - 1 ? rootTag : `${rootTag}@hop${i}`;
    const node = hops[i].type === ProfileType.WIREGUARD ?
      buildWireGuardEndpoint(hops[i], tag) : buildOutbound(hops[i], s, tag);
    // Tags and detours belong to this graph, not to user-supplied extra JSON.
    node['tag'] = tag;
    if (i > 0) {
      node['detour'] = `${rootTag}@hop${i - 1}`;
    }
    if (hops[i].type === ProfileType.WIREGUARD) {
      graph.endpoints.push(node);
    } else {
      graph.outbounds.push(node);
    }
  }
  return graph;
}

function profileRootTag(id: string): string {
  return `profile-${encodeURIComponent(id)}`;
}

export function buildCoreConfig(p: Profile, s: AppSettings, physicalIfname: string,
  logPath: string = '', geositePath: string = '', geoIpPath: string = '',
  customRules: Array<RouteRule> = [], remoteRuleSets: Array<RemoteRuleSet> = [],
  cachePath: string = '', allProfiles: Array<Profile> = [], groups: Array<ProfileGroup> = []): string {
  if (p.type !== ProfileType.CUSTOM && p.type !== ProfileType.CHAIN && p.server.length === 0) {
    throw new Error('服务器地址为空');
  }
  if (s.mtu < 1280) {
    throw new Error('MTU 过小');
  }

  // ---- inbounds ----
  // Single source of truth: ''(legacy) derives from the boolean; no in-place
  // mutation of the caller's settings object.
  const ipv6Mode = effectiveIpv6Mode(s);
  const tun: Record<string, Object> = {};
  tun['type'] = 'tun';
  tun['tag'] = 'tun-in';
  // Android IPv6Mode: DISABLE=v4 only, ONLY=v6 only, ENABLE/PREFER=dual stack.
  if (ipv6Mode === 'only') {
    tun['address'] = [TUN_ADDR_V6];
  } else if (ipv6Mode === 'disable') {
    tun['address'] = [TUN_ADDR_V4];
  } else {
    tun['address'] = [TUN_ADDR_V4, TUN_ADDR_V6];
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

  // ---- endpoints / outbounds ----
  // sing-box 1.14 将 WireGuard 从 outbound 迁移为顶层 endpoint；endpoint tag 仍可作为路由目标。
  const endpoints: Array<Object> = [];
  const outbounds: Array<Object> = [];
  const profileTags = new Map<string, string>();
  const profiles = allProfiles.filter(x => x.id !== p.id).concat([p]);
  const selectedGroup = groups.find(g => g.id === p.groupId);
  if (selectedGroup !== undefined && selectedGroup.isSelector) {
    const members = profiles.filter(x => x.groupId === p.groupId);
    const memberTags: Array<string> = [];
    for (const member of members) {
      const tag = profileRootTag(member.id);
      const graph = buildProfileGraph(member, profiles, groups, s, tag);
      outbounds.push(...graph.outbounds);
      endpoints.push(...graph.endpoints);
      profileTags.set(member.id, tag);
      memberTags.push(tag);
    }
    const selector: Record<string, Object> = {
      'type': 'selector', 'tag': 'proxy', 'outbounds': memberTags,
      'default': profileRootTag(p.id)
    };
    outbounds.unshift(selector);
  } else {
    const graph = buildProfileGraph(p, profiles, groups, s, 'proxy');
    outbounds.push(...graph.outbounds);
    endpoints.push(...graph.endpoints);
  }
  // Android aliases a rule referencing the active ID to proxy (also for selector).
  profileTags.set(p.id, 'proxy');
  for (const r of customRules) {
    if (!r.enabled || !r.outbound.startsWith('profile:')) {
      continue;
    }
    const id = r.outbound.substring('profile:'.length);
    if (profileTags.has(id)) {
      continue;
    }
    const target = profiles.find(x => x.id === id);
    if (target === undefined) {
      console.warn(`[NB] 路由引用节点不存在,跳过: ${id}`);
      continue;
    }
    const tag = profileRootTag(id);
    const graph = buildProfileGraph(target, profiles, groups, s, tag);
    outbounds.push(...graph.outbounds);
    endpoints.push(...graph.endpoints);
    profileTags.set(id, tag);
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
  // 1.14 无 rcode DNS server,block 语义用 predefined 动作 + rcode 表达
  // (内核 option/rule_action.go: DNSRouteActionPredefined + RuleActionTypeReject)。
  if (s.fakeDns) {
    const fakeServer: Record<string, Object> = {};
    fakeServer['type'] = 'fakeip';
    fakeServer['tag'] = 'fake';
    // 安卓 ConfigBuilder.kt:710-724 无条件同时写 inet4_range/inet6_range,
    // 与 ipv6Mode 无关(旧代码只按 legacy ipv6 布尔加 v6 段,四档下自相矛盾)。
    fakeServer['inet4_range'] = FAKEIP_RANGE_V4;
    fakeServer['inet6_range'] = FAKEIP_RANGE_V6;
    // 1.14 typed server 不接受 strategy；策略放在选择 fake 的 DNS 规则上。
    // 仍使用 1.14 兼容规则模式，不能混入 query_type/ip_version 新模式条件。
    // 后续 1.16 迁移另行处理，不把 legacy 字段拒绝误判成无法实现。
    dnsServers.push(fakeServer);
  }
  const dnsRules: Array<Object> = [];
  // 用户规则参与 DNS 分流(对齐安卓 userDNSRuleList + enableDnsRouting):
  // direct → local;proxy → remote(reject 语义 = predefined 空应答);FakeIP
  // 兜底只挂 tun-in(对齐安卓 inbound: [tun-in]),mixed 入站不拿假地址。
  if (s.mode === 'rule' && s.dnsRouting) {
    for (const r of customRules) {
      if (!r.enabled || r.domains.trim().length === 0) {
        continue;
      }
      // 仅复用域名前缀解析逻辑;geosite:/geoip: 引用只在资产可用时保留,
      // 其余丢弃而非生成悬空定义(内核启动会拒绝 rule-set not found)。
      const dnsRule: Record<string, Object> = {};
      const domains: Array<string> = [];
      const suffixes: Array<string> = [];
      const regexes: Array<string> = [];
      const keywords: Array<string> = [];
      const ruleSets: Array<string> = [];
      for (const raw of splitRuleList(r.domains)) {
        const it = raw.toLowerCase();
        if (it.startsWith('geosite:')) {
          if (it === 'geosite:cn' && geositePath.length > 0) {
            ruleSets.push(it);
          }
        } else if (it.startsWith('full:')) {
          domains.push(it.substring('full:'.length));
        } else if (it.startsWith('domain:')) {
          suffixes.push(it.substring('domain:'.length));
        } else if (it.startsWith('regexp:')) {
          regexes.push(it.substring('regexp:'.length));
        } else if (it.startsWith('keyword:')) {
          keywords.push(it.substring('keyword:'.length));
        } else {
          suffixes.push(it);
        }
      }
      if (r.ip.trim().length > 0) {
        for (const it of splitCsv(r.ip)) {
          if (it === 'geoip:private') {
            dnsRule['ip_is_private'] = true;
          } else if (it === 'geoip:cn' && geoIpPath.length > 0) {
            ruleSets.push(it);
          }
        }
      }
      setIfList(dnsRule, 'domain', domains);
      setIfList(dnsRule, 'domain_suffix', suffixes);
      setIfList(dnsRule, 'domain_regex', regexes);
      setIfList(dnsRule, 'domain_keyword', keywords);
      if (ruleSets.length > 0) {
        dnsRule['rule_set'] = ruleSets;
      }
      // 仅当规则真的有匹配条件才进入 DNS 规则列表(对齐安卓 checkEmpty)
      const hasMatch = domains.length > 0 || suffixes.length > 0 || regexes.length > 0 ||
        keywords.length > 0 || ruleSets.length > 0 || dnsRule['ip_is_private'] === true;
      if (!hasMatch) {
        continue;
      }
      if (r.outbound === 'direct') {
        dnsRule['server'] = 'local';
        setIf(dnsRule, 'strategy', dnsStrategy(s.directDnsStrategy, s));
        dnsRules.push(dnsRule);
      } else if (r.outbound === 'reject') {
        // 1.14 无 rcode server;reject 语义 = predefined 动作返回 NXDOMAIN。
        // predefined 变体只接受 rcode/answer/ns/extra(内核 rule_action.go:340),
        // disable_cache 属于 route 动作,写这里会被 strict schema 拒绝。
        dnsRule['action'] = 'predefined';
        dnsRule['rcode'] = 3;
        dnsRules.push(dnsRule);
      } else if (r.outbound === 'proxy') {
        if (s.fakeDns) {
          const fakeUserRule: Record<string, Object> = JSON.parse(JSON.stringify(dnsRule)) as Record<string, Object>;
          fakeUserRule['server'] = 'fake';
          fakeUserRule['inbound'] = ['tun-in'];
          fakeUserRule['strategy'] = 'ipv4_only';
          fakeUserRule['disable_cache'] = true;
          dnsRules.push(fakeUserRule);
        }
        dnsRule['server'] = 'remote';
        setIf(dnsRule, 'strategy', dnsStrategy(s.remoteDnsStrategy, s));
        dnsRules.push(dnsRule);
      }
    }
  }
  if (s.fakeDns) {
    // FakeIP 兜底:仅 TUN 入站(对齐安卓 dns.rules.add(inbound=tun-in, server=dns-fake)),
    // 且排在用户/内置规则之后(dns.rules 顺序匹配,先到先得)。
    const fakeRule: Record<string, Object> = {};
    fakeRule['inbound'] = ['tun-in'];
    // query_type 会将整组 DNS 规则切换到新模式，与其他规则 strategy 冲突。
    // Android 原兜底只限定 inbound，不含 query_type；兼容策略迁移到选择规则。
    fakeRule['server'] = 'fake';
    fakeRule['strategy'] = 'ipv4_only';
    // 安卓 ConfigBuilder.kt:724 同时置 disable_cache=true(1.14 内核接受该字段)
    fakeRule['disable_cache'] = true;
    dnsRules.push(fakeRule);
  }
  // 规则模式 + DNS 路由开启 + geosite 数据就绪:CN 域名用直连 DNS 解析(CDN 友好)
  // 1.14:rule 级 geosite 字段已移除,改为引用本地 rule_set
  if (s.mode === 'rule' && s.dnsRouting && geositePath.length > 0) {
    const cnDnsRule: Record<string, Object> = {};
    cnDnsRule['rule_set'] = ['geosite_cn'];
    cnDnsRule['server'] = 'local';
    setIf(cnDnsRule, 'strategy', dnsStrategy(s.directDnsStrategy, s));
    dnsRules.push(cnDnsRule);
  }
  // 1.14:legacy outbound DNS rule 已弃用,改用 route.default_domain_resolver
  // (出站服务器域名一律经 local 直连 DNS 解析,语义等价且防泄漏不变)
  const dns: Record<string, Object> = {};
  dns['servers'] = dnsServers;
  dns['rules'] = dnsRules;
  dns['final'] = 'remote';
  setIf(dns, 'strategy', dnsStrategy(s.remoteDnsStrategy, s));

  // ---- route ----
  // ---- route ----
  const routeRules: Array<Object> = [];
  // 嗅探(对齐安卓 needSniff/needSniffOverride,作用于 tun 与 mixed 两个 inbound):
  // route 档只嗅探(用于规则分流);override 档嗅探成功后覆写目的域名
  // (内核 OHOS 补丁 CORE-04 恢复了 override_destination JSON 旋钮)。
  if (s.sniffMode !== 'off') {
    const sniffRule: Record<string, Object> = {};
    sniffRule['inbound'] = ['tun-in'];
    if (s.mixedPort > 0) {
      sniffRule['inbound'] = ['tun-in', 'mixed-in'];
    }
    sniffRule['action'] = 'sniff';
    if (s.sniffMode === 'override') {
      sniffRule['override_destination'] = true;
    }
    routeRules.push(sniffRule);
  }
  // DNS 劫持:终端 53 报文交给内核 DNS 栈处理(TUN 模式必须)
  const dnsHijackRule: Record<string, Object> = {};
  dnsHijackRule['protocol'] = 'dns';
  dnsHijackRule['action'] = 'hijack-dns';
  routeRules.push(dnsHijackRule);
  // Resolve before destination-IP matching: route actions do not retry earlier rules.
  // 策略只由 IPv6Mode 推导(安卓 genDomainStrategy,ConfigBuilder.kt:148-155),
  // 与用户设置的 remote DNS 策略无关;此前误用 remoteDnsStrategy。
  if (s.resolveDestination) {
    const resolveRule: Record<string, Object> = {};
    resolveRule['action'] = 'resolve';
    resolveRule['strategy'] = modeDnsStrategy(effectiveIpv6Mode(s));
    routeRules.push(resolveRule);
  }
  const ruleSetDefinitions: Array<Object> = [];

  // 模式:direct(全部直连)/ rule(规则分流)/ global(除 DNS 劫持外全部走代理)
  let finalOutbound = 'proxy';
  // 内置路由规则(安卓 ConfigBuilder.kt:697-708,无模式限定):
  // 私网绕过按设置(内核自带 ip_is_private 判定),组播拒绝独立于开关。
  // 两者都在用户/geo/远程规则之后追加(route.rules 顺序匹配,先到先得)。
  const builtinRules: Array<Record<string, Object>> = [];
  if (s.bypassLan) {
    const privateRule: Record<string, Object> = {};
    privateRule['ip_is_private'] = true;
    privateRule['outbound'] = 'direct';
    builtinRules.push(privateRule);
  }
  // block mcast:独立于 bypassLan 开关,目的/源命中组播段即拒绝
  const mcastRule: Record<string, Object> = {};
  mcastRule['ip_cidr'] = ['224.0.0.0/3', 'ff00::/8'];
  mcastRule['source_ip_cidr'] = ['224.0.0.0/3', 'ff00::/8'];
  mcastRule['action'] = 'reject';
  builtinRules.push(mcastRule);

  if (s.mode === 'direct') {
    finalOutbound = 'direct';
  } else if (s.mode === 'rule') {
    // 用户规则先入(安卓 ConfigBuilder.kt:600),内置私网/组播在其后追加
    // 先清空上一次构建遗留的引用登记,再重建(buildCoreConfig 可能被多次调用,
    // 且首遍生成的 rule 对象已写入 routeRules,这里只做引用收集)。
    referencedRuleSetTags.length = 0;
    for (const r of customRules) {
      if (!r.enabled) {
        continue;
      }
      let targetTag = r.outbound;
      if (r.outbound.startsWith('profile:')) {
        const resolved = profileTags.get(r.outbound.substring('profile:'.length));
        if (resolved === undefined) {
          continue;
        }
        targetTag = resolved;
      }
      const rule = buildCustomRule(r);
      if (rule !== null) {
        if (r.outbound !== 'reject') {
          rule['outbound'] = targetTag;
        }
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

    // 自定义 geosite:/geoip: 引用必须有同名定义(内核启动校验,
    // 见 route/rule/rule_item_rule_set.go:31-38;对齐安卓 generateRuleSet)。
    // 本项目资产为 cn 专属库,仅 geosite:cn/geoip:cn 有对应本地文件;
    // 其他引用标记为非法,宁可跳过该规则也不能生成会让内核拒绝整份配置的悬空定义。
    const pendingDefs: Array<Record<string, Object>> = [];
    const cnTags: Array<string> = [];
    for (const tag of referencedRuleSetTags) {
      if (tag === 'geosite:cn' && geositePath.length > 0) {
        cnTags.push(tag);
        pendingDefs.push(buildGeoRuleSet(tag, geositePath));
      } else if (tag === 'geoip:cn' && geoIpPath.length > 0) {
        cnTags.push(tag);
        pendingDefs.push(buildGeoRuleSet(tag, geoIpPath));
      }
    }
    for (const tag of referencedRuleSetTags) {
      if (cnTags.indexOf(tag) < 0) {
        throw new Error(`未支持的规则集引用: ${tag}(当前 geo 库仅含 cn 分类)`);
      }
    }
    for (const def of pendingDefs) {
      ruleSetDefinitions.push(def);
    }
  }
  for (const builtin of builtinRules) {
    routeRules.push(builtin);
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
  // server auto 固定 prefer_ipv4:SingBoxOptionsUtil.domainStrategy("server") 不回退到
  // autoDnsDomainStrategy,ConfigBuilder.kt:270,399-400 直接用该值,与 remote/direct 不同。
  const domainResolver: Record<string, Object> = {};
  domainResolver['server'] = 'local';
  setIf(domainResolver, 'strategy', dnsStrategy(s.serverDnsStrategy, s, true));
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
  if (endpoints.length > 0) {
    config['endpoints'] = endpoints;
  }
  config['outbounds'] = outbounds;
  config['route'] = route;
  config['experimental'] = experimental;
  // 全局自定义配置:与根对象深合并(Android Util.kt mergeJSON 语义;非法 JSON 忽略)
  const globalCustom = parseUserJson(s.globalCustomConfig);
  if (globalCustom !== null) {
    deepMerge(config, globalCustom);
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
  s: AppSettings, logPath: string, groups: Array<ProfileGroup> = []): LatencyTestConfig {
  const result = new LatencyTestConfig();
  const endpoints: Array<Object> = [];
  const outbounds: Array<Object> = [];
  for (let i = 0; i < targets.length; i++) {
    const p = targets[i];
    const tag = `t${i}`;
    try {
      // Group wrappers apply to latency tests in Android (only the selector
      // and rule targets are excluded); a member root keeps its own wrapper.
      const graph = buildProfileGraph(p, allProfiles, groups, s, tag);
      outbounds.push(...graph.outbounds);
      endpoints.push(...graph.endpoints);
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
  if (endpoints.length > 0) {
    cfg['endpoints'] = endpoints;
  }
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
