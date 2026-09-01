import { Profile, AppSettings, ProfileType, supportsTransport, needsTlsByDefault } from '../model/Profile';
import { CLASH_API_PORT } from '../utils/TrafficStats';
import { RouteProfile, RouteRule, routeRuleToSingBox } from '../common/model/RouteProfile';

/**
 * sing-box 1.11 配置生成器。
 *
 * 关键设计(与鸿蒙 VPN 框架配合):
 *  - tun 入站 auto_route=false:路由由 @ohos.net.vpnExtension 建立;
 *    TUN fd 由 NAPI 子进程通过 SING_BOX_TUN_FD 注入(见 core/patches)。
 *  - dns: 代理服务器域名用直连 DNS 解析(directDns);其余一律走
 *    "remote"(经代理的 DNS,防 DNS 泄漏)。
 *  - 引导解析:节点出站/endpoint 的 domain_resolver 与
 *    route.default_domain_resolver 都显式指向 "local"。sing-box 1.12+
 *    已废弃 outbound DNS 规则项,服务器域名解析不再保证经过 DNS 规则
 *    匹配,缺省时会落到 final=remote(经本节点建连),产生
 *    "DNS query loopback in transport[remote]" 全局断网。
 *  - route.default_interface:绑定启动时探测到的物理网卡。
 */

const TUN_ADDR_V4 = '172.19.0.1/30';
const TUN_ADDR_V6 = 'fdfe:dcba:9876::1/126';
// Keep this literal instead of Number.MAX_SAFE_INTEGER: the ArkTS standard
// library exposed by older API 24 SDKs does not declare that ES constant.
const MAX_SAFE_INTEGER_VALUE = 9007199254740991;
// time.Duration is a signed int64 measured in nanoseconds.  Use the exclusive
// 2^63 boundary as a conservative range check (the negative endpoint is valid
// in Go, while the positive endpoint is one nanosecond smaller).
const MAX_DURATION_NANOS = 9.223372036854776e18;

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

function supportsOutboundTls(type: string): boolean {
  return type === ProfileType.VMESS || type === ProfileType.VLESS
    || type === ProfileType.TROJAN || type === ProfileType.HYSTERIA
    || type === ProfileType.HYSTERIA2 || type === ProfileType.TUIC
    || type === ProfileType.HTTP;
}

function hasTlsMetadata(p: Profile): boolean {
  return p.tls || p.sni.length > 0 || p.allowInsecure || p.alpn.length > 0
    || p.fingerprint.length > 0 || p.realityPublicKey.length > 0
    || p.realityShortId.length > 0;
}

function buildTls(p: Profile, s: AppSettings): Object | undefined {
  // Shadowsocks, SOCKS and legacy WireGuard outbounds do not embed
  // OutboundTLSOptions in sing-box 1.11. Never emit a tls object for them:
  // an imported/old profile carrying TLS metadata must be rejected by the
  // caller instead of poisoning the whole strict-schema configuration.
  if (!supportsOutboundTls(p.type)) {
    return undefined;
  }
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
  // 内核 reality 客户端强制要求 uTLS(reality_client.go: UTLS==nil||!Enabled → 启动失败)
  // 非 reality 出站仅在用户指定指纹时启用
  if (hasReality || p.fingerprint.length > 0) {
    const utls: Record<string, Object> = { 'enabled': true };
    utls['fingerprint'] = p.fingerprint.length > 0 ? p.fingerprint : 'chrome';
    tls['utls'] = utls;
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

export function profileOutboundTag(profileId: string): string {
  return `node_${profileId}`;
}

/**
 * sing-box 1.11 对出站对象使用严格 JSON 解码。高级 JSON 仍保留为兼容
 * 扩展入口，但只允许当前协议在 1.11 schema 中声明过的顶层字段；否则
 * 该节点会在这里被标记为无效并由 buildCoreConfig 跳过，而不是把未知
 * 字段带进整个配置导致所有节点都无法启动。
 */
function extraKeysFor(type: string): Array<string> {
  const keys: Array<string> = [
    // DialerOptions
    'detour', 'bind_interface', 'inet4_bind_address', 'inet6_bind_address',
    'protect_path', 'routing_mark', 'reuse_addr', 'connect_timeout',
    'tcp_fast_open', 'tcp_multi_path', 'udp_fragment', 'domain_strategy',
    'network_strategy', 'network_type', 'fallback_network_type', 'fallback_delay'
  ];
  switch (type) {
    case ProfileType.SHADOWSOCKS:
      // SIP003 remains a valid 1.11 Shadowsocks outbound extension.
      keys.push('plugin', 'plugin_opts', 'network', 'udp_over_tcp');
      break;
    case ProfileType.VMESS:
      keys.push('global_padding', 'authenticated_length', 'network', 'packet_encoding');
      break;
    case ProfileType.VLESS:
      keys.push('network');
      break;
    case ProfileType.TROJAN:
      keys.push('network');
      break;
    case ProfileType.HYSTERIA:
      keys.push('up', 'down', 'auth', 'recv_window_conn', 'recv_window',
        'disable_mtu_discovery', 'network');
      break;
    case ProfileType.HYSTERIA2:
      keys.push('server_ports', 'hop_interval', 'network', 'brutal_debug');
      break;
    case ProfileType.TUIC:
      keys.push('udp_over_stream', 'zero_rtt_handshake', 'heartbeat', 'network');
      break;
    case ProfileType.WIREGUARD:
      keys.push('system_interface', 'gso', 'interface_name', 'reserved', 'workers', 'mtu', 'network');
      break;
    case ProfileType.HTTP:
      keys.push('path', 'headers');
      break;
    case ProfileType.SOCKS:
      keys.push('version', 'network', 'udp_over_tcp');
      break;
    default:
      break;
  }
  return keys;
}

function protectedOutboundKeys(type: string): Array<string> {
  // These values are emitted from the typed Profile and must not be replaced
  // by an arbitrary JSON fragment (especially server_port, which must remain
  // a JSON number for the strict uint16 decoder).
  const keys: Array<string> = ['type', 'tag', 'server', 'server_port'];
  switch (type) {
    case ProfileType.SHADOWSOCKS:
      keys.push('method', 'password');
      break;
    case ProfileType.VMESS:
      keys.push('uuid', 'security', 'alter_id');
      break;
    case ProfileType.VLESS:
      keys.push('uuid', 'flow', 'packet_encoding');
      break;
    case ProfileType.TROJAN:
      keys.push('password');
      break;
    case ProfileType.HYSTERIA:
      keys.push('up_mbps', 'down_mbps', 'obfs', 'auth_str');
      break;
    case ProfileType.HYSTERIA2:
      keys.push('up_mbps', 'down_mbps', 'obfs', 'password');
      break;
    case ProfileType.TUIC:
      keys.push('uuid', 'password', 'congestion_control', 'udp_relay_mode');
      break;
    case ProfileType.WIREGUARD:
      keys.push('local_address', 'private_key', 'peers', 'peer_public_key', 'pre_shared_key');
      break;
    case ProfileType.HTTP:
    case ProfileType.SOCKS:
      keys.push('username', 'password');
      break;
    default:
      break;
  }
  // The model owns these nested objects. Rejecting an override prevents a
  // malformed extra fragment from replacing a valid generated TLS/transport.
  keys.push('tls', 'transport', 'multiplex');
  return keys;
}

function isPlainObject(value: Object): boolean {
  return value !== null && !Array.isArray(value) && typeof value === 'object';
}

function isFiniteNumberValue(value: Object): boolean {
  if (typeof value !== 'number') {
    return false;
  }
  const numberValue: number = value as number;
  return !isNaN(numberValue) && numberValue !== Infinity && numberValue !== -Infinity;
}

function isIntegerValue(value: Object): boolean {
  return isFiniteNumberValue(value) && Math.floor(value as number) === (value as number);
}

function isUnsignedIntegerValue(value: Object, max: number): boolean {
  return isIntegerValue(value) && (value as number) >= 0 && (value as number) <= max;
}

function isStringArrayValue(value: Object): boolean {
  if (!Array.isArray(value)) {
    return false;
  }
  const values: Array<Object> = value as Array<Object>;
  for (const item of values) {
    if (typeof item !== 'string') {
      return false;
    }
  }
  return true;
}

/** Listable[T] accepts either one T or an array of T in sing-box JSON. */
function isStringListableValue(value: Object): boolean {
  return typeof value === 'string' || isStringArrayValue(value);
}

function isDomainStrategyValue(value: Object): boolean {
  if (typeof value !== 'string') {
    return false;
  }
  return value === '' || value === 'as_is' || value === 'prefer_ipv4'
    || value === 'prefer_ipv6' || value === 'ipv4_only' || value === 'ipv6_only';
}

function isNetworkStrategyValue(value: Object): boolean {
  return typeof value === 'string'
    && (value === 'default' || value === 'fallback' || value === 'hybrid');
}

function isInterfaceTypeValue(value: Object): boolean {
  return typeof value === 'string'
    && (value === 'wifi' || value === 'cellular' || value === 'ethernet' || value === 'other');
}

function isInterfaceTypeListableValue(value: Object): boolean {
  if (isInterfaceTypeValue(value)) {
    return true;
  }
  if (!Array.isArray(value)) {
    return false;
  }
  const values: Array<Object> = value as Array<Object>;
  for (const item of values) {
    if (!isInterfaceTypeValue(item)) {
      return false;
    }
  }
  return true;
}

function isNetworkListValue(value: Object): boolean {
  if (typeof value === 'string') {
    return value === 'tcp' || value === 'udp';
  }
  if (!isStringArrayValue(value)) {
    return false;
  }
  const values: Array<Object> = value as Array<Object>;
  for (const item of values) {
    if (item !== 'tcp' && item !== 'udp') {
      return false;
    }
  }
  return true;
}

function isDurationValue(value: Object): boolean {
  // Keep this equivalent to Go's time.ParseDuration grammar.  Letting an
  // arbitrary non-empty string through would defer the error until box.New(),
  // where one malformed non-current node could poison the whole configuration.
  if (typeof value !== 'string') {
    return false;
  }
  const text = value as string;
  if (text.length === 0 || text.trim() !== text) {
    return false;
  }
  // ParseDuration has one special unit-less zero form (after an optional sign).
  if (text === '0' || text === '+0' || text === '-0') {
    return true;
  }
  let index = 0;
  if (text.charAt(0) === '+' || text.charAt(0) === '-') {
    index = 1;
  }
  if (index >= text.length) {
    return false;
  }
  let components = 0;
  let totalNanos = 0;
  while (index < text.length) {
    const numberStart = index;
    let integerDigits = 0;
    while (index < text.length && isAsciiDigit(text.charAt(index))) {
      index++;
      integerDigits++;
    }
    let fractionDigits = 0;
    if (index < text.length && text.charAt(index) === '.') {
      index++;
      while (index < text.length && isAsciiDigit(text.charAt(index))) {
        index++;
        fractionDigits++;
      }
    }
    if (integerDigits === 0 && fractionDigits === 0) {
      return false;
    }
    // Reject values which cannot be represented as a finite duration number;
    // this is a cheap overflow guard before the native parser is reached.
    const numberText = text.substring(numberStart, index);
    const numberValue = Number(numberText);
    if (isNaN(numberValue) || numberValue === Infinity || numberValue === -Infinity) {
      return false;
    }
    const unitStart = index;
    let unitNanos = 0;
    const unitPair = text.substring(index, index + 2);
    if (unitPair === 'ns') {
      unitNanos = 1;
      index += 2;
    } else if (unitPair === 'us' || unitPair === 'µs' || unitPair === 'μs') {
      unitNanos = 1000;
      index += 2;
    } else if (unitPair === 'ms') {
      unitNanos = 1000000;
      index += 2;
    } else if (text.charAt(index) === 's') {
      unitNanos = 1000000000;
      index++;
    } else if (text.charAt(index) === 'm') {
      unitNanos = 60000000000;
      index++;
    } else if (text.charAt(index) === 'h') {
      unitNanos = 3600000000000;
      index++;
    } else if (text.charAt(index) === 'd') {
      unitNanos = 86400000000000;
      index++;
    } else {
      return false;
    }
    if (index <= unitStart) {
      return false;
    }
    const componentNanos = numberValue * unitNanos;
    if (componentNanos < 0 || componentNanos >= MAX_DURATION_NANOS
      || totalNanos >= MAX_DURATION_NANOS - componentNanos) {
      return false;
    }
    totalNanos += componentNanos;
    components++;
  }
  return components > 0;
}

function isAsciiDigit(value: string): boolean {
  if (value.length !== 1) {
    return false;
  }
  const code = value.charCodeAt(0);
  return code >= 48 && code <= 57;
}

function parseUint32Base0(text: string): number | null {
  if (text.length === 0 || text.trim() !== text) {
    return null;
  }
  let valueText = text;
  if (valueText.charAt(0) === '+') {
    valueText = valueText.substring(1);
  }
  if (valueText.length === 0 || valueText.charAt(0) === '-') {
    return null;
  }
  let base = 10;
  let digits = valueText;
  if (valueText.length > 2 && valueText.substring(0, 2).toLowerCase() === '0x') {
    base = 16;
    digits = valueText.substring(2);
  } else if (valueText.length > 2 && valueText.substring(0, 2).toLowerCase() === '0b') {
    base = 2;
    digits = valueText.substring(2);
  } else if (valueText.length > 2 && valueText.substring(0, 2).toLowerCase() === '0o') {
    base = 8;
    digits = valueText.substring(2);
  } else if (valueText.length > 1 && valueText.charAt(0) === '0') {
    // strconv.ParseUint(..., 0, 32) treats a leading zero as octal.
    base = 8;
  }
  if (digits.length === 0) {
    return null;
  }
  let result = 0;
  for (let i = 0; i < digits.length; i++) {
    const code = digits.charCodeAt(i);
    let digit = -1;
    if (code >= 48 && code <= 57) {
      digit = code - 48;
    } else if (code >= 65 && code <= 70) {
      digit = code - 65 + 10;
    } else if (code >= 97 && code <= 102) {
      digit = code - 97 + 10;
    }
    if (digit < 0 || digit >= base) {
      return null;
    }
    result = result * base + digit;
    if (result > 4294967295) {
      return null;
    }
  }
  return result;
}

function isIpv4Literal(text: string): boolean {
  const parts = text.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const part of parts) {
    if (part.length === 0 || (part.length > 1 && part.charAt(0) === '0')) {
      return false;
    }
    for (let i = 0; i < part.length; i++) {
      if (!isAsciiDigit(part.charAt(i))) {
        return false;
      }
    }
    const octet = Number(part);
    if (isNaN(octet) || octet < 0 || octet > 255 || Math.floor(octet) !== octet) {
      return false;
    }
  }
  return true;
}

function isIpv6Group(value: string): boolean {
  if (value.length < 1 || value.length > 4) {
    return false;
  }
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    const isDigit = code >= 48 && code <= 57;
    const isLowerHex = code >= 97 && code <= 102;
    const isUpperHex = code >= 65 && code <= 70;
    if (!isDigit && !isLowerHex && !isUpperHex) {
      return false;
    }
  }
  return true;
}

function isIpv6Literal(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  let address = text;
  const zoneIndex = address.indexOf('%');
  if (zoneIndex >= 0) {
    // netip allows a zone only on IPv6 addresses. Keep the accepted zone
    // alphabet conservative so control/space characters cannot pass through.
    if (zoneIndex === 0 || zoneIndex === address.length - 1
      || address.indexOf('%', zoneIndex + 1) >= 0) {
      return false;
    }
    const zone = address.substring(zoneIndex + 1);
    for (let i = 0; i < zone.length; i++) {
      const code = zone.charCodeAt(i);
      const ok = (code >= 48 && code <= 57) || (code >= 65 && code <= 90)
        || (code >= 97 && code <= 122) || code === 46 || code === 45 || code === 95;
      if (!ok) {
        return false;
      }
    }
    address = address.substring(0, zoneIndex);
  }
  if (address.length === 0) {
    return false;
  }

  // An IPv4 tail occupies two IPv6 groups.
  let ipv4Tail = false;
  if (address.includes('.')) {
    const lastColon = address.lastIndexOf(':');
    if (lastColon < 0 || !isIpv4Literal(address.substring(lastColon + 1))) {
      return false;
    }
    ipv4Tail = true;
    address = address.substring(0, lastColon) + ':v4';
  }

  const compression = address.indexOf('::');
  if (compression >= 0) {
    if (address.indexOf('::', compression + 2) >= 0) {
      return false;
    }
    const left = address.substring(0, compression);
    const right = address.substring(compression + 2);
    const leftParts = left.length === 0 ? [] : left.split(':');
    const rightParts = right.length === 0 ? [] : right.split(':');
    let groups = 0;
    for (const part of leftParts) {
      if (part === 'v4') {
        if (!ipv4Tail) {
          return false;
        }
        groups += 2;
      } else if (isIpv6Group(part)) {
        groups++;
      } else {
        return false;
      }
    }
    for (const part of rightParts) {
      if (part === 'v4') {
        if (!ipv4Tail) {
          return false;
        }
        groups += 2;
      } else if (isIpv6Group(part)) {
        groups++;
      } else {
        return false;
      }
    }
    // "::" must compress at least one group.
    return groups < 8;
  }

  const parts = address.split(':');
  let groups = 0;
  for (const part of parts) {
    if (part === 'v4') {
      if (!ipv4Tail) {
        return false;
      }
      groups += 2;
    } else if (isIpv6Group(part)) {
      groups++;
    } else {
      return false;
    }
  }
  return groups === 8;
}

function isBindAddressLiteral(key: string, value: Object): boolean {
  if (typeof value !== 'string') {
    return false;
  }
  const text = value as string;
  if (key === 'inet4_bind_address') {
    return isIpv4Literal(text);
  }
  return isIpv6Literal(text);
}

function isByteArrayValue(value: Object): boolean {
  if (!Array.isArray(value)) {
    return false;
  }
  const values: Array<Object> = value as Array<Object>;
  for (const item of values) {
    if (!isUnsignedIntegerValue(item, 255)) {
      return false;
    }
  }
  return true;
}

/** Go []byte accepts either a base64 JSON string or an array of octets. */
function isHysteriaAuthValue(value: Object): boolean {
  return typeof value === 'string' || isByteArrayValue(value);
}

function isUdpOverTcpValue(value: Object): boolean {
  if (typeof value === 'boolean') {
    return true;
  }
  if (!isPlainObject(value)) {
    return false;
  }
  const objectValue: Record<string, Object> = value as Record<string, Object>;
  for (const key of Object.keys(objectValue)) {
    if (key !== 'enabled' && key !== 'version') {
      return false;
    }
    if (key === 'enabled' && typeof objectValue[key] !== 'boolean') {
      return false;
    }
    if (key === 'version' && !isUnsignedIntegerValue(objectValue[key], 255)) {
      return false;
    }
  }
  return true;
}

function validateHeadersObject(headers: Object): void {
  if (!isPlainObject(headers)) {
    throw new Error('附加 JSON 字段 headers 必须是对象');
  }
  const headerObject: Record<string, Object> = headers as Record<string, Object>;
  for (const key of Object.keys(headerObject)) {
    const value = headerObject[key];
    if (typeof value === 'string') {
      continue;
    }
    if (Array.isArray(value)) {
      const values: Array<Object> = value as Array<Object>;
      let allStrings = true;
      for (const item of values) {
        if (typeof item !== 'string') {
          allStrings = false;
          break;
        }
      }
      if (allStrings) {
        continue;
      }
    }
    throw new Error(`附加 JSON 字段 headers.${key} 必须是字符串或字符串数组`);
  }
}

function validateExtraValue(type: string, key: string, value: Object): void {
  if (value === null) {
    throw new Error(`附加 JSON 字段 ${key} 不能为 null`);
  }

  // Nested and Listable values must be handled before scalar checks. These
  // shapes are explicitly part of the sing-box 1.11 schema.
  if (key === 'headers') {
    validateHeadersObject(value);
    return;
  }
  if (key === 'udp_over_tcp') {
    if (!isUdpOverTcpValue(value)) {
      throw new Error('附加 JSON 字段 udp_over_tcp 必须是布尔值或 {enabled,version} 对象');
    }
    return;
  }
  if (key === 'network') {
    if (!isNetworkListValue(value)) {
      throw new Error('附加 JSON 字段 network 必须是 tcp/udp 字符串或字符串数组');
    }
    return;
  }
  if (key === 'network_type' || key === 'fallback_network_type') {
    if (!isInterfaceTypeListableValue(value)) {
      throw new Error(`附加 JSON 字段 ${key} 必须是 wifi/cellular/ethernet/other 字符串或数组`);
    }
    return;
  }
  if (key === 'connect_timeout' || key === 'fallback_delay'
    || key === 'hop_interval' || key === 'heartbeat') {
    if (!isDurationValue(value)) {
      throw new Error(`附加 JSON 字段 ${key} 必须是 duration 字符串`);
    }
    return;
  }
  if (key === 'inet4_bind_address' || key === 'inet6_bind_address') {
    if (!isBindAddressLiteral(key, value)) {
      throw new Error(`附加 JSON 字段 ${key} 必须是有效的${key === 'inet4_bind_address' ? ' IPv4' : ' IPv6'}字面量`);
    }
    return;
  }
  if (key === 'detour' || key === 'bind_interface' || key === 'protect_path'
    || key === 'domain_strategy') {
    if (typeof value !== 'string') {
      throw new Error(`附加 JSON 字段 ${key} 必须是字符串`);
    }
    if (key === 'domain_strategy' && !isDomainStrategyValue(value)) {
      throw new Error('附加 JSON 字段 domain_strategy 值无效');
    }
    return;
  }
  if (key === 'network_strategy') {
    if (!isNetworkStrategyValue(value)) {
      throw new Error('附加 JSON 字段 network_strategy 必须是 default/fallback/hybrid');
    }
    return;
  }
  if (key === 'reuse_addr' || key === 'tcp_fast_open' || key === 'tcp_multi_path'
    || key === 'udp_fragment') {
    if (typeof value !== 'boolean') {
      throw new Error(`附加 JSON 字段 ${key} 必须是布尔值`);
    }
    return;
  }
  if (key === 'routing_mark') {
    const validNumber = isUnsignedIntegerValue(value, 4294967295);
    const validString = typeof value === 'string' && parseUint32Base0(value as string) !== null;
    if (!validNumber && !validString) {
      throw new Error('附加 JSON 字段 routing_mark 必须是 uint32 数字或 base-0 字符串');
    }
    return;
  }

  switch (type) {
    case ProfileType.SHADOWSOCKS:
      if (key === 'plugin' || key === 'plugin_opts') {
        if (typeof value !== 'string') {
          throw new Error(`附加 JSON 字段 ${key} 必须是字符串`);
        }
      }
      break;
    case ProfileType.VMESS:
      if (key === 'global_padding' || key === 'authenticated_length') {
        if (typeof value !== 'boolean') {
          throw new Error(`附加 JSON 字段 ${key} 必须是布尔值`);
        }
      } else if (key === 'packet_encoding') {
        if (typeof value !== 'string'
          || (value !== '' && value !== 'packetaddr' && value !== 'xudp')) {
          throw new Error('附加 JSON 字段 packet_encoding 必须是 ""、packetaddr 或 xudp');
        }
      }
      break;
    case ProfileType.VLESS:
    case ProfileType.TROJAN:
      break;
    case ProfileType.HYSTERIA:
      if (key === 'up' || key === 'down') {
        if (typeof value !== 'string') {
          throw new Error(`附加 JSON 字段 ${key} 必须是字符串`);
        }
      } else if (key === 'auth') {
        if (!isHysteriaAuthValue(value)) {
          throw new Error('附加 JSON 字段 auth 必须是 base64 字符串或 0-255 整数数组');
        }
      } else if (key === 'recv_window_conn' || key === 'recv_window') {
        if (!isUnsignedIntegerValue(value, MAX_SAFE_INTEGER_VALUE)) {
          throw new Error(`附加 JSON 字段 ${key} 必须是无符号整数`);
        }
      } else if (key === 'disable_mtu_discovery') {
        if (typeof value !== 'boolean') {
          throw new Error('附加 JSON 字段 disable_mtu_discovery 必须是布尔值');
        }
      }
      break;
    case ProfileType.HYSTERIA2:
      if (key === 'server_ports') {
        if (!isStringListableValue(value)) {
          throw new Error('附加 JSON 字段 server_ports 必须是字符串或字符串数组');
        }
      } else if (key === 'brutal_debug') {
        if (typeof value !== 'boolean') {
          throw new Error('附加 JSON 字段 brutal_debug 必须是布尔值');
        }
      }
      break;
    case ProfileType.TUIC:
      if (key === 'udp_over_stream' || key === 'zero_rtt_handshake') {
        if (typeof value !== 'boolean') {
          throw new Error(`附加 JSON 字段 ${key} 必须是布尔值`);
        }
      } else if (key === 'uuid' || key === 'password') {
        if (typeof value !== 'string') {
          throw new Error(`附加 JSON 字段 ${key} 必须是字符串`);
        }
      }
      break;
    case ProfileType.WIREGUARD:
      if (key === 'system_interface' || key === 'gso') {
        if (typeof value !== 'boolean') {
          throw new Error(`附加 JSON 字段 ${key} 必须是布尔值`);
        }
      } else if (key === 'interface_name') {
        if (typeof value !== 'string') {
          throw new Error('附加 JSON 字段 interface_name 必须是字符串');
        }
      } else if (key === 'mtu' || key === 'workers') {
        const max = key === 'mtu' ? 4294967295 : 2147483647;
        if (!isUnsignedIntegerValue(value, max)) {
          throw new Error(`附加 JSON 字段 ${key} 必须是无符号整数`);
        }
      } else if (key === 'reserved') {
        if (!isByteArrayValue(value)) {
          throw new Error('附加 JSON 字段 reserved 必须是 0-255 整数数组');
        }
      }
      break;
    case ProfileType.HTTP:
    case ProfileType.SOCKS:
      if (key === 'version') {
        if (typeof value !== 'string') {
          throw new Error('附加 JSON 字段 version 必须是字符串');
        }
      } else if (key === 'path' && typeof value !== 'string') {
        throw new Error('附加 JSON 字段 path 必须是字符串');
      }
      break;
    default:
      break;
  }
}

function parseExtra(p: Profile): Record<string, Object> {
  if (p.extra.trim().length === 0) {
    return {};
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(p.extra) as Object;
  } catch (e) {
    throw new Error('附加 JSON 格式无效');
  }
  if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
    throw new Error('附加 JSON 必须是对象');
  }
  const extra = parsed as Record<string, Object>;
  const allowed = extraKeysFor(p.type);
  const protectedKeys = protectedOutboundKeys(p.type);
  for (const key of Object.keys(extra)) {
    if (protectedKeys.includes(key)) {
      throw new Error(`附加 JSON 不得覆盖 ${key}`);
    }
    if (!allowed.includes(key)) {
      throw new Error(`附加 JSON 包含 sing-box 1.11 未知字段: ${key}`);
    }
    validateExtraValue(p.type, key, extra[key]);
  }
  return extra;
}

/**
 * 在加入 selector 前做不会触发网络的字段校验。
 * sing-box 会在 box.New() 阶段创建每一个出站；若把明显无效的节点
 * 原样放进数组，非当前节点也会让整个 VPN 启动失败。因此这些节点由
 * buildCoreConfig 的逐项 try/catch 跳过，保留至少一个可启动出站。
 */
function validateOutboundProfile(p: Profile): void {
  if (p.server.trim().length === 0) {
    throw new Error('服务器地址为空');
  }
  const port = Number(p.serverPort);
  if (isNaN(port) || port < 1 || port > 65535 || Math.floor(port) !== port) {
    throw new Error('服务器端口无效');
  }
  switch (p.type) {
    case ProfileType.SHADOWSOCKS:
      if (p.method.trim().length === 0 || p.password.length === 0) {
        throw new Error('Shadowsocks 缺少加密方式或密码');
      }
      break;
    case ProfileType.VMESS:
    case ProfileType.VLESS:
      if (p.uuid.trim().length === 0) {
        throw new Error(`${p.type} 缺少 UUID`);
      }
      break;
    case ProfileType.TUIC:
      if (p.uuid.trim().length === 0) {
        throw new Error('TUIC 缺少 UUID');
      }
      break;
    case ProfileType.WIREGUARD:
      if (p.privateKey.trim().length === 0 || p.peerPublicKey.trim().length === 0) {
        throw new Error('WireGuard 缺少密钥');
      }
      break;
    case ProfileType.TROJAN:
    case ProfileType.HYSTERIA:
    case ProfileType.HYSTERIA2:
    case ProfileType.HTTP:
    case ProfileType.SOCKS:
      break;
    default:
      throw new Error(`不支持的协议: ${p.type}`);
  }
  if (!supportsOutboundTls(p.type) && hasTlsMetadata(p)) {
    throw new Error(`${p.type} 出站不支持 TLS 字段`);
  }
  parseExtra(p);
}

function buildOutbound(p: Profile, s: AppSettings, tag: string): Record<string, Object> {
  validateOutboundProfile(p);
  const o: Record<string, Object> = {};
  o['type'] = p.type;
  o['tag'] = tag;
  o['server'] = p.server;
  // Store.fillFrom() intentionally accepts old JSON values, so normalize the
  // port before serializing. sing-box's strict schema expects uint16, not a
  // string that merely happens to contain digits.
  o['server_port'] = Number(p.serverPort);

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
    case ProfileType.HYSTERIA2:
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
      // sing-box 1.11 still registers the legacy WireGuard outbound. Its
      // fallback peer is built from the top-level ServerOptions and
      // peer_public_key fields; putting a peer object here without its own
      // server/server_port would create an endpoint with an empty address.
      o['peer_public_key'] = p.peerPublicKey;
      if (p.preSharedKey.length > 0) {
        o['pre_shared_key'] = p.preSharedKey;
      }
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
  const extra = parseExtra(p);
  for (const k of Object.keys(extra)) {
    o[k] = extra[k];
  }
  // 节点 tag 属于运行时拓扑，不能被高级 JSON 覆盖。
  o['tag'] = tag;
  return o;
}

// sing-box 1.13 removed the legacy WireGuard outbound.  Represent it as a
// WireGuard endpoint; endpoints implement the outbound interface and can be
// selected by the same selector tag used for all other profiles.
function buildWireGuardEndpoint(p: Profile, s: AppSettings, tag: string): Record<string, Object> {
  validateOutboundProfile(p);
  const endpoint: Record<string, Object> = {};
  endpoint['type'] = 'wireguard';
  endpoint['tag'] = tag;
  endpoint['address'] = p.localAddress.length > 0 ? splitCsv(p.localAddress) : ['10.0.0.2/32'];
  endpoint['private_key'] = p.privateKey;
  const peer: Record<string, Object> = {};
  peer['address'] = p.server;
  peer['port'] = Number(p.serverPort);
  peer['public_key'] = p.peerPublicKey;
  if (p.preSharedKey.length > 0) {
    peer['pre_shared_key'] = p.preSharedKey;
  }
  peer['allowed_ips'] = ['0.0.0.0/0', '::/0'];
  endpoint['peers'] = [peer];
  return endpoint;
}

export function buildCoreConfig(p: Profile, profiles: Array<Profile>, s: AppSettings, physicalIfname: string,
  logPath: string = '', geositePath: string = '', geoIpPath: string = '',
  routeProfile: RouteProfile | null = null): string {
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
  tun['sniff'] = true;
  if (s.ipv6) {
    tun['address'] = [TUN_ADDR_V4, TUN_ADDR_V6];
  } else {
    tun['address'] = [TUN_ADDR_V4];
  }
  tun['mtu'] = s.mtu;
  tun['auto_route'] = false;   // 路由由鸿蒙 VPN 框架管理
  tun['strict_route'] = false;
  tun['stack'] = s.stack;
  // 注意:inbound 级 sniff 字段在 sing-box 1.13 已移除(解析直接 FATAL),
  // 嗅探迁移为 route 规则动作,见下方 routeRules 首条。
  const inbounds: Array<Object> = [tun];

  // ---- outbounds ----
  const nodeOutbounds: Array<Object> = [];
  const nodeEndpoints: Array<Object> = [];
  const nodeTags: Array<string> = [];
  const seen: Record<string, boolean> = {};
  const ordered: Array<Profile> = [p];
  for (const candidate of profiles) {
    if (candidate.id !== p.id) {
      ordered.push(candidate);
    }
  }
  for (const candidate of ordered) {
    const tag = profileOutboundTag(candidate.id);
    if (candidate.id.length === 0 || seen[tag] === true) {
      continue;
    }
    try {
      if (candidate.type === ProfileType.WIREGUARD) {
        nodeEndpoints.push(buildWireGuardEndpoint(candidate, s, tag));
      } else {
        const outbound = buildOutbound(candidate, s, tag);
        nodeOutbounds.push(outbound);
      }
      nodeTags.push(tag);
      seen[tag] = true;
    } catch (e) {
      // 单个无效节点只从运行时出站组跳过，不影响其他节点及 VPN 启动。
      if (candidate.id === p.id) {
        const msg = e instanceof Error ? e.message : `${e}`;
        throw new Error(`当前节点配置无效: ${msg}`);
      }
    }
  }
  const currentTag = profileOutboundTag(p.id);
  if (seen[currentTag] !== true || nodeTags.length === 0) {
    throw new Error('当前节点无法生成出站配置');
  }
  const proxy: Record<string, Object> = {
    'type': 'selector',
    'tag': 'proxy',
    'outbounds': nodeTags,
    'default': currentTag
  };
  const direct: Record<string, Object> = { 'type': 'direct', 'tag': 'direct' };
  // 1.11: block/dns 特殊 outbound 已移除,分流用 rule action(hijack-dns / reject)
  const outbounds: Array<Object> = [];
  for (const outbound of nodeOutbounds) {
    outbounds.push(outbound);
  }
  outbounds.push(proxy);
  outbounds.push(direct);

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
  // 每个实际节点出站都可能需要先解析其 server 域名。仅匹配 selector
  // "proxy" 不足以覆盖 selector 选中的具体 node_* 出站；若该查询落到
  // final=remote，而 remote 又经 proxy 建连，就会产生
  // "DNS query loopback in transport[remote]"，导致 TUN 接管后全局断网。
  // 注意:主防回环机制是 outbound 的 domain_resolver + route.default_domain_resolver
  // (sing-box 1.12+ 已废弃 outbound DNS 规则项,这里仅作为次级保险保留)。
  // 节点服务器域名只用于代理引导，使用 local/direct DNS；普通业务域名
  // 仍按 final=remote 经代理解析，保持防 DNS 泄漏策略。
  for (const nodeTag of nodeTags) {
    const nodeDnsRule: Record<string, Object> = {};
    nodeDnsRule['outbound'] = nodeTag;
    nodeDnsRule['server'] = 'local';
    dnsRules.push(nodeDnsRule);
  }
  const dns: Record<string, Object> = {};
  dns['servers'] = dnsServers;
  dns['rules'] = dnsRules;
  dns['final'] = 'remote';

  // ---- route ----
  const dnsRule: Record<string, Object> = {};
  dnsRule['protocol'] = 'dns';
  dnsRule['action'] = 'hijack-dns';
  // 1.13 嗅探必须用规则动作(inbound sniff 字段已移除)。放首位:先嗅探出
  // 协议/域名,后续 hijack-dns(需识别 dns 协议)与域名分流规则才有依据。
  const sniffRule: Record<string, Object> = {};
  sniffRule['inbound'] = ['tun-in'];
  sniffRule['action'] = 'sniff';
  // 私网网段直连(等价新版 ip_is_private)
  const privateRule: Record<string, Object> = {};
  privateRule['ip_cidr'] = [
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8',
    '169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', '255.255.255.255/32',
    '::1/128', 'fe80::/10', 'fc00::/7', 'ff00::/8'
  ];
  privateRule['outbound'] = 'direct';
  const routeRules: Array<Object> = [sniffRule, dnsRule, privateRule];

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
  // 独立路由配置(2.0)：调用方可传入 RouteProfile 覆盖模式默认值。
  // 每项规则独立校验，异常项跳过；不触碰 default_interface/DNS bootstrap。
  if (routeProfile !== null) {
    // 保留前三条基础规则(sniff 动作、dns 劫持、私网直连),丢弃模式默认分流。
    routeRules.splice(3, routeRules.length - 3);
    finalOutbound = routeProfile.preset === 'direct' ? 'direct' : 'proxy';
    if (routeProfile.preset === 'bypass-cn') {
      if (geositePath.length > 0) {
        const cnSite: Record<string, Object> = {};
        cnSite['geosite'] = ['cn'];
        cnSite['outbound'] = 'direct';
        routeRules.push(cnSite);
      }
      if (geoIpPath.length > 0) {
        const cnIp: Record<string, Object> = {};
        cnIp['geoip'] = ['cn'];
        cnIp['outbound'] = 'direct';
        routeRules.push(cnIp);
      }
    } else if (routeProfile.preset === 'adblock') {
      const adblock: Record<string, Object> = {};
      adblock['domain_suffix'] = ['doubleclick.net', 'googlesyndication.com', 'googleadservices.com', 'adnxs.com'];
      adblock['action'] = 'reject';
      routeRules.push(adblock);
    }
    for (const item of routeProfile.rules) {
      const generated = routeRuleToSingBox(item as RouteRule, 'proxy');
      if (generated !== null) routeRules.push(generated);
    }
  }
  if (physicalIfname.trim().length === 0) {
    throw new Error('缺少物理网卡,无法设置 route.default_interface');
  }
  const route: Record<string, Object> = {};
  route['rules'] = routeRules;
  route['final'] = finalOutbound;
  route['auto_detect_interface'] = false;
  route['default_interface'] = physicalIfname;
  // 全局兜底:任何 dial 字段的域名地址(含域名形态的 DNS 服务器、WireGuard
  // endpoint、未来协议)缺省解析器都指向直连 DNS,引导解析不依赖代理本身。
  if (routeProfile !== null && routeProfile.ruleSets.length > 0) {
    const ruleSetOptions: Array<Object> = [];
    for (const metadata of routeProfile.ruleSets) {
      const tag = metadata.tag.trim();
      const path = metadata.path.trim();
      if (tag.length === 0 || path.length === 0 || !path.endsWith('.srs')) continue;
      const item: Record<string, Object> = {};
      item['type'] = 'local';
      item['tag'] = tag;
      item['format'] = 'binary';
      item['path'] = path;
      ruleSetOptions.push(item);
    }
    if (ruleSetOptions.length > 0) route['rule_set'] = ruleSetOptions;
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
  if (nodeEndpoints.length > 0) {
    config['endpoints'] = nodeEndpoints;
  }
  config['outbounds'] = outbounds;
  config['route'] = route;
  config['experimental'] = experimental;
  return JSON.stringify(config, null, 2);
}
