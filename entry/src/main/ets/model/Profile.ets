/**
 * 数据模型 — 参考 NekoBoxForAndroid 的 Profile 概念。
 * 一个 Profile 对应一个 sing-box 出站(outbound)。
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
  static readonly SSH: string = 'ssh';
  static readonly SHADOWTLS: string = 'shadowtls';
  static readonly CUSTOM: string = 'custom';
  static readonly CHAIN: string = 'chain';
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
  ssPlugin: string = '';       // obfs-local / v2ray-plugin(空 = 不用插件)
  ssPluginOpts: string = '';   // 插件配置串,如 obfs=http;obfs-host=xxx

  // http / socks
  username: string = '';

  // vmess / vless / tuic
  uuid: string = '';
  alterId: number = 0;
  security: string = 'auto'; // vmess 加密方式
  flow: string = '';         // vless flow (xtls-rprx-vision)
  packetEncoding: string = ''; // ''(内核默认) / packetaddr / xudp

  // 传输层 (ws / grpc / http / httpupgrade / quic)
  transport: string = '';
  path: string = '';
  host: string = '';
  serviceName: string = '';
  wsEarlyData: number = 0;          // ws 最大早期数据字节
  wsEarlyDataHeaderName: string = '';

  // TLS / REALITY / ECH
  tls: boolean = false;
  sni: string = '';
  allowInsecure: boolean = false;
  alpn: string = '';
  fingerprint: string = '';  // uTLS 指纹(chrome/firefox/safari…);reality 必须启用 uTLS
  realityPublicKey: string = '';
  realityShortId: string = '';
  certificates: string = ''; // PEM 证书,多证书用 \n\n 分隔
  ech: boolean = false;      // 启用 ECH
  echConfig: string = '';    // ECH 配置(base64)

  // hysteria
  upMbps: number = 100;
  downMbps: number = 100;
  obfs: string = '';

  // hysteria2 端口跳跃
  serverPorts: string = '';  // 如 20000-30000,多个逗号分隔(冒号/横线均可)
  hopInterval: number = 30;  // 端口跳跃间隔(秒)

  // tuic
  congestionControl: string = 'bbr';
  udpRelayMode: string = 'native';
  reduceRtt: boolean = false;
  disableSni: boolean = false;

  // wireguard(privateKey 与 ssh 私钥共用字段)
  localAddress: string = '172.16.0.2/32';
  privateKey: string = '';
  peerPublicKey: string = '';
  preSharedKey: string = '';
  wgMtu: number = 1420;
  reserved: string = '';     // 逗号分隔 3 个数字

  // ssh
  sshAuthType: string = 'password'; // none / password / private_key
  privateKeyPassphrase: string = '';
  hostKey: string = '';      // 服务器公钥(base64),多值逗号分隔

  // shadowtls
  shadowtlsVersion: number = 3;

  // multiplex
  mux: boolean = false;
  muxProtocol: string = 'h2mux'; // h2mux / smux / yamux
  muxMaxStreams: number = 8;
  muxPadding: boolean = true;

  // 附加 sing-box JSON(与出站对象浅合并,用于高级场景)
  extra: string = '';

  // 自定义配置(type=custom):完整的出站 JSON,tag 强制为 proxy
  customOutbound: string = '';

  // 链式代理(type=chain):前置→落地顺序的节点 id,逗号分隔
  chainIds: string = '';

  // 来源订阅(自动更新用)
  subUrl: string = '';

  // 节点分组与组内顺序。空 groupId 表示未分组。
  groupId: string = '';
  sortOrder: number = 0;

  // 最近一次延迟测试结果。-1 表示失败，0 表示尚未测试。
  latencyMs: number = 0;
  latencyTestedAt: number = 0;

  updatedAt: number = 0;

  // 置顶(节点列表排序时置顶节点恒排在前)
  pinned: boolean = false;
}

export class ProfileGroup {
  id: string = '';
  name: string = '';
  sortOrder: number = 0;
  collapsed: boolean = false;
  createdAt: number = 0;
  updatedAt: number = 0;
}

export class AppSettings {
  mtu: number = 1400;
  stack: string = 'system';            // 内核 go1.24 构建不含 gvisor,仅 system 栈
  mode: string = 'rule';               // rule(规则)/ global(全局)/ direct(直连)
  directDomains: string = '';          // 规则模式:直连域名后缀,逗号分隔
  directIpCidrs: string = '';          // 规则模式:直连 IP 段,逗号分隔
  remoteDns: string = 'tcp://8.8.8.8'; // 经代理,防泄漏(使用 TCP DNS)
  directDns: string = '223.5.5.5';     // 直连,用于解析代理服务器域名
  remoteDnsStrategy: string = '';      // auto/prefer_ipv4/prefer_ipv6/ipv4_only/ipv6_only,空=内核默认
  directDnsStrategy: string = '';
  dnsRouting: boolean = true;          // DNS 路由:CN 域名用直连 DNS 解析
  fakeDns: boolean = false;            // FakeDNS(真机验证项)
  ipv6: boolean = false;
  bypassLan: boolean = true;           // 绕过局域网
  sniffMode: string = 'route';         // off / route(仅用于路由) / override(嗅探并覆盖目标)
  resolveDestination: boolean = false; // 解析目标地址(存档项,配置暂不消费)
  mixedPort: number = 0;               // 混合代理端口,0=关闭
  allowAccess: boolean = false;        // 允许来自局域网的连接
  allowInsecureAll: boolean = false;   // 全局放行不安全 TLS
  subAllowInsecure: boolean = false;   // 订阅请求放行不安全 TLS
  logLevel: string = 'info';           // trace/debug/info/warn/error
  testUrl: string = 'https://www.gstatic.com/generate_204';
  testConcurrent: number = 5;          // 测速并发数
  latencyTestMode: string = 'url';     // url(真连接测试,经内核 URLTest) / tcp(TCPing 握手计时)
  alwaysShowAddress: boolean = false;  // 节点卡始终显示服务器地址
  notificationGroup: boolean = false;  // 通知中显示分组名
  autoUpdateSubs: boolean = true;      // 启动时自动更新到期的订阅
  subscriptionUpdateIntervalHours: number = 12;
  hapticFeedback: boolean = true;
  appearance: string = 'system';       // system / light / dark
  profileSortMode: string = 'manual';  // manual / latency / name
  navLayout: string = 'bottom';        // bottom / side
  clashApiEnabled: boolean = true;
  clashApiPort: number = 9090;
  clashApiSecret: string = '';
  liquidGlass: boolean = true;
  perAppMode: string = 'off';          // off / exclude(排除这些应用) / include(仅这些应用走代理)
  perAppList: string = '';             // 应用包名,逗号分隔(如 com.huawei.hmos.browser)
  globalCustomConfig: string = '';     // 全局自定义配置 JSON(与根对象浅合并)
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
    case ProfileType.SSH: return 'SSH';
    case ProfileType.SHADOWTLS: return 'ShadowTLS';
    case ProfileType.CUSTOM: return 'Custom';
    case ProfileType.CHAIN: return 'Chain';
    default: return type;
  }
}

export function needsTlsByDefault(type: string): boolean {
  return type === ProfileType.TROJAN || type === ProfileType.HYSTERIA
    || type === ProfileType.HYSTERIA2
    || type === ProfileType.TUIC
    || type === ProfileType.SHADOWTLS;
}

export function supportsTransport(type: string): boolean {
  return type === ProfileType.VMESS || type === ProfileType.VLESS
    || type === ProfileType.TROJAN;
}
