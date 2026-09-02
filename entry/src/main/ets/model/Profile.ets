/**
 * 数据模型 — 参考 NekoBoxForAndroid 的 Profile 概念。
 * 一个 Profile 对应一个 sing-box 1.4 出站(outbound)。
 */

export class ProfileType {
  static readonly SHADOWSOCKS: string = 'shadowsocks';
  static readonly VMESS: string = 'vmess';
  static readonly VLESS: string = 'vless';
  static readonly TROJAN: string = 'trojan';
  static readonly HYSTERIA: string = 'hysteria';
  static readonly HYSTERIA2: string = 'hysteria2';
  static readonly TUIC: string = 'tuic';
  static readonly WIREGUARD: string = 'wireguard';
  static readonly HTTP: string = 'http';
  static readonly SOCKS: string = 'socks';
}

export class Profile {
  id: string = '';
  name: string = '';
  type: string = ProfileType.SHADOWSOCKS;
  server: string = '';
  serverPort: number = 443;

  // shadowsocks
  method: string = 'aes-128-gcm';
  password: string = '';

  // http / socks
  username: string = '';

  // vmess / vless / tuic
  uuid: string = '';
  alterId: number = 0;
  security: string = 'auto'; // vmess 加密方式
  flow: string = '';         // vless flow (xtls-rprx-vision)

  // 传输层 (ws / grpc / http / httpupgrade / quic)
  transport: string = '';
  path: string = '';
  host: string = '';
  serviceName: string = '';

  // TLS / REALITY
  tls: boolean = false;
  sni: string = '';
  allowInsecure: boolean = false;
  alpn: string = '';
  fingerprint: string = '';  // uTLS 指纹(chrome/firefox/safari…);reality 必须启用 uTLS
  realityPublicKey: string = '';
  realityShortId: string = '';

  // hysteria
  upMbps: number = 100;
  downMbps: number = 100;
  obfs: string = '';

  // tuic
  congestionControl: string = 'bbr';
  udpRelayMode: string = 'native';

  // wireguard
  localAddress: string = '172.16.0.2/32';
  privateKey: string = '';
  peerPublicKey: string = '';
  preSharedKey: string = '';

  // multiplex
  mux: boolean = false;

  // 附加 sing-box JSON(与出站对象浅合并,用于高级场景)
  extra: string = '';

  // 统一分组标识。旧数据缺少该字段时，由分组加载流程根据 subUrl 迁移。
  groupId: string = '';

  // 来源订阅 URL，保留用于兼容旧数据和订阅更新定位。
  subUrl: string = '';

  updatedAt: number = 0;

  // 组内稳定排序序号。
  sortOrder: number = 0;

  // 置顶属于本地元数据，订阅更新时必须保留。
  pinned: boolean = false;
}

export class AppSettings {
  mtu: number = 1400;
  stack: string = 'system';            // 1.4 内核 go1.24 构建不含 gvisor,使用 system 栈
  mode: string = 'rule';               // rule(规则)/ global(全局)/ direct(直连)
  directDomains: string = '';          // 规则模式:直连域名后缀,逗号分隔
  directIpCidrs: string = '';          // 规则模式:直连 IP 段,逗号分隔
  remoteDns: string = 'udp://8.8.8.8'; // 经代理,防泄漏(绕开 DoH task-succeed 缺陷)
  directDns: string = '223.5.5.5';     // 直连,用于解析代理服务器域名
  ipv6: boolean = false;
  allowInsecureAll: boolean = false;   // 全局放行不安全 TLS
  autoUpdateSubs: boolean = true;      // 启动时自动更新超过 12h 的订阅
  perAppMode: string = 'off';          // off / exclude(排除这些应用) / include(仅这些应用走代理)
  perAppList: string = '';             // 应用包名,逗号分隔(如 com.huawei.hmos.browser)
  tactileInteraction: boolean = true;  // 主要交互启用按压反馈与轻量缩放
  liquidGlass: boolean = true;         // 主页卡片、按钮和弹窗启用液态玻璃外观
}

export function profileTypeLabel(type: string): string {
  switch (type) {
    case ProfileType.SHADOWSOCKS: return 'Shadowsocks';
    case ProfileType.VMESS: return 'VMess';
    case ProfileType.VLESS: return 'VLESS';
    case ProfileType.TROJAN: return 'Trojan';
    case ProfileType.HYSTERIA: return 'Hysteria';
    case ProfileType.HYSTERIA2: return 'Hysteria2';
    case ProfileType.TUIC: return 'TUIC';
    case ProfileType.WIREGUARD: return 'WireGuard';
    case ProfileType.HTTP: return 'HTTP';
    case ProfileType.SOCKS: return 'Socks';
    default: return type;
  }
}

export function needsTlsByDefault(type: string): boolean {
  return type === ProfileType.TROJAN || type === ProfileType.HYSTERIA
    || type === ProfileType.HYSTERIA2
    || type === ProfileType.TUIC;
}

export function supportsTransport(type: string): boolean {
  return type === ProfileType.VMESS || type === ProfileType.VLESS
    || type === ProfileType.TROJAN;
}
