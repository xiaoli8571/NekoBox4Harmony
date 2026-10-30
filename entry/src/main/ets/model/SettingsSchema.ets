/**
 * SettingsSchema —— 设置 Schema 与"待应用差异"模型（P4/W16，REDESIGN-PLAN-2026-10-23.md §12.1/§12.2/§12.4）。
 *
 * 事实来源：`model/Profile.ets` 的 `AppSettings`（每个字段都必须登记；默认值与类字段初值逐字一致，
 * 表达式如 `6*3600*1000` 算成 21600000；防漂移断言由 tests/settings-schema.cjs 抽源码正则强制）。
 *
 * 口径（perapp 接线约定）：
 *  - 草稿 = 当前 AppSettings；已应用 = ConfigRepository.getActive().content.settings
 *    （Record<string, Object>，由 JSON.parse(JSON.stringify(AppSettings)) 而来）；
 *  - 差异按这个口径算，本模型不另造副本存储；
 *  - applied 缺键（旧快照没有新字段）用 registry 默认值兜底，不误报"已修改"；
 *  - draft 或 applied 中出现 registry 未覆盖的键 → 忽略（不进 diff）。
 *
 * applyClass 判定规则（§12.1）：
 *  - immediate：只影响显示/交互，不写内核配置、不重连；
 *  - nextTask：只影响"下一次检测/下一次订阅任务"的参数；
 *  - reconnect：写入 sing-box 配置或平台 VPN 参数；拿不准的一律 reconnect（宁多重连一次也不假装即时生效）。
 *
 * 纯模型：无 I/O、无 @ohos 依赖。
 */

/** 即时效：外观/浏览/显示，不重连 */
export const APPLY_IMMEDIATE: string = 'immediate';
/** 下次任务：检测 URL/并发/超时/重试/采样/判据/订阅更新偏好 */
export const APPLY_NEXT_TASK: string = 'nextTask';
/** 运行配置：DNS/IPv6/嗅探/模式/应用名单/MTU/入站/Clash API/规则 */
export const APPLY_RECONNECT: string = 'reconnect';

/** 设置项定义（key 唯一；defaultValue 是 JSON 文本，与 AppSettings 初值逐字一致）。 */
export class SettingDef {
  key: string = '';
  section: string = '';
  applyClass: string = APPLY_RECONNECT;
  /** 'bool' | 'number' | 'string' | 'enum' */
  kind: string = 'string';
  /** JSON 文本，如 'true' / '1400' / '"rule"' */
  defaultValue: string = '';
  /** 是否高级项（P3 高级折叠区；普通区仍显示） */
  advanced: boolean = false;
  /** i18n token，页面映射文案 */
  labelToken: string = '';
  /** 搜索关键词（空格分隔，含中英文），匹配大小写不敏感 */
  keywords: string = '';
}

/** 设置分区定义（§12.4「恢复本分区默认值」的作用域）。 */
export class SectionDef {
  id: string = '';
  labelToken: string = '';
  /** 排序权重（小在前） */
  order: number = 0;
  /** 仅高级区可见 */
  advancedOnly: boolean = false;
}

/** 单项差异（值统一 JSON 字符串比较口径，页面可直接展示原文）。 */
export class SettingsDiffItem {
  key: string = '';
  section: string = '';
  applyClass: string = APPLY_RECONNECT;
  /** JSON 字符串（applied 缺键时=registry 默认值） */
  appliedValue: string = '';
  /** JSON 字符串（draft 值） */
  draftValue: string = '';
  labelToken: string = '';
}

/** 待应用差异汇总（§12.2 待应用条数据源）。 */
export class SettingsDiff {
  items: Array<SettingsDiffItem> = [];
  reconnectCount: number = 0;
  nextTaskCount: number = 0;
  immediateCount: number = 0;
  total: number = 0;
}

// ============================================================ 分区

const SECTIONS: Array<SectionDef> = [
  mkSection('appearance', 'settings_section_appearance', 10, false),   // 外观与交互
  mkSection('startup', 'settings_section_startup', 20, false),         // 启动与行为
  mkSection('probe', 'settings_section_probe', 30, false),             // 检测
  mkSection('dns', 'settings_section_dns', 40, false),                 // DNS
  mkSection('ipv6', 'settings_section_ipv6', 50, false),               // IPv6
  mkSection('inbound', 'settings_section_inbound', 60, false),         // 入站
  mkSection('mode', 'settings_section_mode', 70, false),               // 分流模式
  mkSection('perapp', 'settings_section_perapp', 80, false),           // 应用名单
  mkSection('advanced', 'settings_section_advanced', 90, true)         // 高级
];

function mkSection(id: string, labelToken: string, order: number, advancedOnly: boolean): SectionDef {
  const s = new SectionDef();
  s.id = id;
  s.labelToken = labelToken;
  s.order = order;
  s.advancedOnly = advancedOnly;
  return s;
}

export function sectionDefs(): Array<SectionDef> {
  return SECTIONS.slice();
}

// ============================================================ registry

function def(key: string, section: string, applyClass: string, kind: string, defaultValue: string,
  labelToken: string, keywords: string, advanced: boolean = false): SettingDef {
  const d = new SettingDef();
  d.key = key;
  d.section = section;
  d.applyClass = applyClass;
  d.kind = kind;
  d.defaultValue = defaultValue;
  d.labelToken = labelToken;
  d.keywords = keywords;
  d.advanced = advanced;
  return d;
}

/**
 * registry：覆盖 AppSettings 全部字段（顺序按 Profile.ets 声明序，便于 review 对齐）。
 * applyClass 分配表（按分区）：
 *  - appearance(immediate)：appearance/hapticFeedback/liquidGlass/alwaysShowAddress/notificationGroup/showBottomBar/navLayout/profileSortMode
 *  - startup：speedIntervalMs(reconnect,通知轮询间隔在 startVpn 时定下) / profileTrafficStatistics(reconnect,扩展在 teardown 用启动时缓存的 settings) / autoConnect、networkChangeResetConnections、wakeResetConnections(immediate,均为事件发生时现读 loadSettings 或纯 UI)
 *    （由扩展进程在回调里消费，值改动需带进下一次会话；保守归 reconnect）
 *  - probe(nextTask)：testUrl/testConcurrent/latencyTestMode/testTimeoutMs/testRetries/testSamples/testExpectStatus/
 *    testBypassTunnel/latencyStaleMs/alwaysShowAddress 归显示的除外/autoUpdateSubs/subscriptionUpdateIntervalHours
 *  - dns/reconnect：remoteDns/directDns/remoteDnsStrategy/directDnsStrategy/serverDnsStrategy/dnsRouting/fakeDns
 *  - ipv6/reconnect：ipv6/ipv6Mode
 *  - inbound/reconnect：mixedPort/allowAccess
 *  - mode/reconnect：mode/directDomains/directIpCidrs/resolveDestination/sniffMode/bypassLan
 *  - perapp/reconnect：perAppMode/perAppList/perAppEntries
 *  - advanced/reconnect：mtu/stack/logLevel/allowInsecureAll/subAllowInsecure/globalCustomConfig；
 *    coexistFix202609Applied 是内部迁移标记（用户不可改），kind=bool 保守登记但页面不应渲染。
 */
function buildDefs(): Array<SettingDef> {
  const out: Array<SettingDef> = [];
  // ---- mode（分流模式，reconnect）
  out.push(def('mode', 'mode', APPLY_RECONNECT, 'enum', '"rule"',
    'settings_mode', '分流 模式 mode rule global direct 全局 直连 规则'));
  out.push(def('directDomains', 'mode', APPLY_RECONNECT, 'string', '""',
    'settings_direct_domains', '直连 域名 direct domains 后缀'));
  out.push(def('directIpCidrs', 'mode', APPLY_RECONNECT, 'string', '""',
    'settings_direct_ip', '直连 IP 段 cidr direct'));
  out.push(def('resolveDestination', 'mode', APPLY_RECONNECT, 'bool', 'false',
    'settings_resolve_destination', '解析 目标 resolve destination 存档'));
  out.push(def('sniffMode', 'mode', APPLY_RECONNECT, 'enum', '"route"',
    'settings_sniff_mode', '嗅探 sniff route override 覆盖 off'));
  out.push(def('bypassLan', 'mode', APPLY_RECONNECT, 'bool', 'true',
    'settings_bypass_lan', '绕过 局域网 bypass lan 局域网地址'));
  // ---- dns（reconnect）
  out.push(def('remoteDns', 'dns', APPLY_RECONNECT, 'string', '"tcp://8.8.8.8"',
    'settings_remote_dns', '远程 DNS remote dns 代理 泄漏'));
  out.push(def('directDns', 'dns', APPLY_RECONNECT, 'string', '"223.5.5.5"',
    'settings_direct_dns', '直连 DNS direct dns 服务器域名'));
  out.push(def('remoteDnsStrategy', 'dns', APPLY_RECONNECT, 'enum', '""',
    'settings_remote_dns_strategy', '远程 DNS 策略 strategy auto prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only'));
  out.push(def('directDnsStrategy', 'dns', APPLY_RECONNECT, 'enum', '""',
    'settings_direct_dns_strategy', '直连 DNS 策略 strategy'));
  out.push(def('serverDnsStrategy', 'dns', APPLY_RECONNECT, 'enum', '""',
    'settings_server_dns_strategy', '服务器 DNS 策略 domain_strategy_for_server 代理服务器域名'));
  out.push(def('dnsRouting', 'dns', APPLY_RECONNECT, 'bool', 'true',
    'settings_dns_routing', 'DNS 路由 分流 routing CN 域名'));
  out.push(def('fakeDns', 'dns', APPLY_RECONNECT, 'bool', 'false',
    'settings_fake_dns', 'FakeDNS 假 DNS fakedns 防泄漏'));
  // ---- ipv6（reconnect）
  out.push(def('ipv6', 'ipv6', APPLY_RECONNECT, 'bool', 'false',
    'settings_ipv6', 'IPv6 开关'));
  out.push(def('ipv6Mode', 'ipv6', APPLY_RECONNECT, 'enum', '""',
    'settings_ipv6_mode', 'IPv6 模式 disable enable prefer only legacy'));
  // ---- inbound（reconnect）
  out.push(def('mixedPort', 'inbound', APPLY_RECONNECT, 'number', '2080',
    'settings_mixed_port', '混合端口 端口 mixed port 本地 代理端口 0=关闭'));
  out.push(def('allowAccess', 'inbound', APPLY_RECONNECT, 'bool', 'false',
    'settings_allow_access', '允许 局域网连接 access lan share 分享'));
  // ---- perapp（reconnect）
  out.push(def('perAppMode', 'perapp', APPLY_RECONNECT, 'enum', '"off"',
    'settings_per_app_mode', '分应用 模式 per app exclude include 排除 仅这些 off'));
  out.push(def('perAppList', 'perapp', APPLY_RECONNECT, 'string', '""',
    'settings_per_app_list', '应用 包名 名单 packages per app list'));
  out.push(def('perAppEntries', 'perapp', APPLY_RECONNECT, 'string', '""',
    'settings_per_app_entries', '应用 条目 权威 entries bundleName label'));
  // ---- probe（nextTask）
  out.push(def('testUrl', 'probe', APPLY_NEXT_TASK, 'string', '"http://cp.cloudflare.com/"',
    'settings_test_url', '测试 网址 URL 检测 target cloudflare cp'));
  out.push(def('testConcurrent', 'probe', APPLY_NEXT_TASK, 'number', '5',
    'settings_test_concurrent', '并发 数 concurrent 并发数'));
  out.push(def('latencyTestMode', 'probe', APPLY_NEXT_TASK, 'enum', '"url"',
    'settings_latency_test_mode', '测试 方式 url tcp tcping 握手'));
  out.push(def('testTimeoutMs', 'probe', APPLY_NEXT_TASK, 'number', '5000',
    'settings_test_timeout', '超时 timeout 毫秒'));
  out.push(def('testRetries', 'probe', APPLY_NEXT_TASK, 'number', '0',
    'settings_test_retries', '重试 retry 次数'));
  out.push(def('testSamples', 'probe', APPLY_NEXT_TASK, 'number', '1',
    'settings_test_samples', '取样 采样 samples 平均'));
  out.push(def('testExpectStatus', 'probe', APPLY_NEXT_TASK, 'enum', '"any"',
    'settings_test_expect_status', '期望 状态 判据 expect 2xx any 403 500'));
  out.push(def('testBypassTunnel', 'probe', APPLY_NEXT_TASK, 'bool', 'true',
    'settings_test_bypass_tunnel', '绕过 隧道 bypass tunnel 绑定 物理网卡'));
  out.push(def('latencyStaleMs', 'probe', APPLY_NEXT_TASK, 'number', '21600000',
    'settings_latency_stale', '陈旧 新鲜 stale 过期 时长 灰色'));
  out.push(def('autoUpdateSubs', 'probe', APPLY_NEXT_TASK, 'bool', 'true',
    'settings_auto_update_subs', '自动 更新 订阅 auto update'));
  out.push(def('subscriptionUpdateIntervalHours', 'probe', APPLY_NEXT_TASK, 'number', '12',
    'settings_sub_update_interval', '订阅 更新 间隔 小时 interval hours'));
  // ---- appearance（immediate）
  out.push(def('appearance', 'appearance', APPLY_IMMEDIATE, 'enum', '"system"',
    'settings_appearance', '外观 深色 浅色 system light dark 主题'));
  out.push(def('hapticFeedback', 'appearance', APPLY_IMMEDIATE, 'bool', 'true',
    'settings_haptic', '触感 反馈 振动 haptic'));
  out.push(def('liquidGlass', 'appearance', APPLY_IMMEDIATE, 'bool', 'true',
    'settings_liquid_glass', '液态 玻璃 liquid glass 毛玻璃'));
  out.push(def('alwaysShowAddress', 'appearance', APPLY_IMMEDIATE, 'bool', 'false',
    'settings_always_show_address', '地址 显示 节点卡 always address'));
  out.push(def('notificationGroup', 'appearance', APPLY_IMMEDIATE, 'bool', 'false',
    'settings_notification_group', '通知 分组名 notification group'));
  out.push(def('notificationShowProfile', 'appearance', APPLY_IMMEDIATE, 'bool', 'true',
    'settings_notification_profile', '通知 节点名 节点 profile notification'));
  out.push(def('showBottomBar', 'appearance', APPLY_IMMEDIATE, 'bool', 'false',
    'settings_show_bottom_bar', '底部 速率条 FAB 显示 bottom bar'));
  out.push(def('navLayout', 'appearance', APPLY_IMMEDIATE, 'enum', '"bottom"',
    'settings_nav_layout', '导航 布局 bottom side 侧栏'));
  out.push(def('profileSortMode', 'appearance', APPLY_IMMEDIATE, 'enum', '"manual"',
    'settings_profile_sort', '排序 sort manual latency name'));
  // ---- startup（reconnect：扩展进程在回调中消费，改值需带进下一次会话；保守归 reconnect）
  out.push(def('speedIntervalMs', 'startup', APPLY_RECONNECT, 'number', '1000',
    'settings_speed_interval', '速率 刷新 间隔 speed interval 通知'));
  // 裁决(2026-10-24 lead)：autoConnect 只被 UI(Index.autoConnect) 读取，改值不需要内核重启。
  out.push(def('autoConnect', 'startup', APPLY_IMMEDIATE, 'bool', 'false',
    'settings_auto_connect', '启动 自动 连接 auto connect'));
  // 裁决：扩展在每次网络变化回调里 loadSettings() 现读(VpnExtAbility:230)，即时效。
  out.push(def('networkChangeResetConnections', 'startup', APPLY_IMMEDIATE, 'bool', 'false',
    'settings_network_reset', '网络 变化 重置 切换 network reset'));
  // 裁决：扩展在每次回到前台时 loadSettings() 现读(VpnExtAbility:327)，即时效。
  out.push(def('wakeResetConnections', 'startup', APPLY_IMMEDIATE, 'bool', 'false',
    'settings_wake_reset', '唤醒 前台 重置 wake reset'));
  out.push(def('profileTrafficStatistics', 'startup', APPLY_RECONNECT, 'bool', 'true',
    'settings_profile_traffic', '流量 统计 每节点 traffic statistics'));
  // ---- advanced（reconnect）
  out.push(def('mtu', 'advanced', APPLY_RECONNECT, 'number', '1400',
    'settings_mtu', 'MTU 大包分包 tun'));
  /* 2026-10-26:协议栈无 UI(固定 gvisor),字段保留以免旧备份导入报错 */
  out.push(def('stack', 'advanced', APPLY_RECONNECT, 'enum', '"gvisor"',
    'settings_stack', '协议栈 栈 stack gvisor'));
  out.push(def('logLevel', 'advanced', APPLY_RECONNECT, 'enum', '"info"',
    'settings_log_level', '日志 级别 log level trace debug info warn error'));
  out.push(def('allowInsecureAll', 'advanced', APPLY_RECONNECT, 'bool', 'false',
    'settings_allow_insecure', '不安全 TLS 全局 insecure 放行'));
  out.push(def('subAllowInsecure', 'advanced', APPLY_NEXT_TASK, 'bool', 'false',
    'settings_sub_allow_insecure', '订阅 不安全 TLS insecure 下载'));
  out.push(def('clashApiEnabled', 'advanced', APPLY_RECONNECT, 'bool', 'true',
    'settings_clash_api', 'Clash API 控制器 external controller'));
  out.push(def('clashApiPort', 'advanced', APPLY_RECONNECT, 'number', '19290',
    'settings_clash_port', 'Clash API 端口 19290'));
  out.push(def('clashApiSecret', 'advanced', APPLY_RECONNECT, 'string', '""',
    'settings_clash_secret', 'Clash API 密钥 secret'));
  out.push(def('globalCustomConfig', 'advanced', APPLY_RECONNECT, 'string', '""',
    'settings_global_custom', '全局 自定义 配置 JSON custom config'));
  out.push(def('coexistFix202609Applied', 'advanced', APPLY_RECONNECT, 'bool', 'false',
    'settings_coexist_fix', '迁移标记 内部 coexist 202609'));
  // ---- 开机自启 / 局域网共享鉴权 / 主题色 / 首页编排(对齐 OwnBox 对应功能) ----
  out.push(def('autoStartOnBoot', 'startup', APPLY_NEXT_TASK, 'bool', 'false',
    'settings_auto_start_boot', '开机 自启 启动 autostart boot'));
  out.push(def('lanAuthUser', 'inbound', APPLY_RECONNECT, 'string', '""',
    'settings_lan_auth_user', '局域网 共享 用户名 lan auth username'));
  out.push(def('lanAuthPass', 'inbound', APPLY_RECONNECT, 'string', '""',
    'settings_lan_auth_pass', '局域网 共享 密码 lan auth password'));
  out.push(def('themeAccent', 'appearance', APPLY_NEXT_TASK, 'enum', '"blue"',
    'settings_theme_accent', '主题 强调色 颜色 accent theme'));
  out.push(def('homeHiddenSections', 'appearance', APPLY_NEXT_TASK, 'string', '""',
    'settings_home_sections', '首页 布局 卡片 编排 home sections'));
  return out;
}

const REGISTRY: Array<SettingDef> = buildDefs();
const REGISTRY_BY_KEY: Map<string, SettingDef> = new Map();
for (let i = 0; i < REGISTRY.length; i++) {
  REGISTRY_BY_KEY.set(REGISTRY[i].key, REGISTRY[i]);
}

/** 全部设置定义（按 Profile.ets 声明序）。 */
export function settingDefs(): Array<SettingDef> {
  return REGISTRY.slice();
}

/** 按键取定义；未登记键返回 null。 */
export function settingDefOf(key: string): SettingDef | null {
  const d = REGISTRY_BY_KEY.get(key);
  return d === undefined ? null : d;
}

// ============================================================ 搜索

/** 设置搜索（§12.1）：匹配 labelToken/keywords/key，大小写不敏感，空查询返回全部（保持声明序）。 */
export function searchSettings(query: string): Array<SettingDef> {
  const q = query.trim().toLowerCase();
  if (q.length === 0) {
    return REGISTRY.slice();
  }
  const out: Array<SettingDef> = [];
  for (let i = 0; i < REGISTRY.length; i++) {
    const d = REGISTRY[i];
    if (d.key.toLowerCase().indexOf(q) >= 0
      || d.labelToken.toLowerCase().indexOf(q) >= 0
      || d.keywords.toLowerCase().indexOf(q) >= 0) {
      out.push(d);
    }
  }
  return out;
}

// ============================================================ 默认值

/** enum 也按字符串默认值还原；JSON 文本 → 运行时值。 */
function jsonToValue(def: SettingDef): Object {
  const v: Object = JSON.parse(def.defaultValue) as Object;
  if (def.kind === 'number') {
    return (v as number);
  }
  if (def.kind === 'bool') {
    return (v as boolean);
  }
  return v;
}

/** 全部默认值（Record，键=字段名，值=类型还原后的默认值）。 */
export function defaultsForAll(): Record<string, Object> {
  const out: Record<string, Object> = {};
  for (let i = 0; i < REGISTRY.length; i++) {
    const d = REGISTRY[i];
    out[d.key] = jsonToValue(d);
  }
  return out;
}

/** 某分区默认值（来自 SettingDef.defaultValue，类型还原）；未知分区返回空 Record。 */
export function sectionDefaults(sectionId: string): Record<string, Object> {
  const out: Record<string, Object> = {};
  for (let i = 0; i < REGISTRY.length; i++) {
    const d = REGISTRY[i];
    if (d.section === sectionId) {
      out[d.key] = jsonToValue(d);
    }
  }
  return out;
}

/**
 * 值是否等于默认值（§12.4 边界）：
 *  - undefined（缺失）按等于默认值（旧数据未写入新字段即视为默认，不误导出"恢复默认"）；
 *  - number 按数值比较（1400 与 1400.0 等价）；bool 按布尔；string/enum 按原样（不 trim）。
 */
export function isDefaultValue(def: SettingDef, value: Object | undefined): boolean {
  if (value === undefined) {
    return true;
  }
  const dflt = jsonToValue(def);
  return valuesEqual(dflt, value, def.kind);
}

// ============================================================ 差异

/** 布尔值语义：boolean 原样；字符串 'true'/'1' 等按真值解析（防 JSON 往返把 bool 变成字符串的误报）。 */
function boolOf(v: Object): boolean {
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  if (typeof v === 'string') {
    const s = (v as string).toLowerCase();
    return s === 'true' || s === '1';
  }
  if (typeof v === 'number') {
    return (v as number) !== 0;
  }
  return false;
}

/** 类型感知相等：number 按数值（1400==1400.0），bool 按布尔，string/enum 按原样不 trim。 */
function valuesEqual(a: Object, b: Object, kind: string): boolean {
  if (kind === 'number') {
    const na = a as number;
    const nb = b as number;
    if (typeof na !== 'number' || typeof nb !== 'number' || isNaN(na) || isNaN(nb)) {
      return JSON.stringify(a) === JSON.stringify(b);
    }
    return na === nb;
  }
  if (kind === 'bool') {
    return boolOf(a) === boolOf(b);
  }
  return JSON.stringify(a) === JSON.stringify(b);
}

/** 草稿中某键的值（ArkTS 严格：Record 缺键读出 undefined，先判 hasOwnProperty 语义再取值）。 */
function recordValue(rec: Record<string, Object>, key: string): Object | undefined {
  // ArkTS 禁 Function.call / prototype 赋值(arkts-no-func-apply-call/arkts-no-prototype-assignment)：
  // 用 Object.keys 判存在性（值来自 JSON，不会出现"存在但为 undefined"）。
  if (Object.keys(rec).indexOf(key) < 0) {
    return undefined;
  }
  return rec[key];
}

/**
 * 待应用差异（§12.2）：
 *  - 只比较 registry 登记过的键；draft/applied 中 registry 未覆盖的键忽略；
 *  - applied 缺键用 registry 默认值兜底（旧快照没有新字段时不误报"已修改"）；
 *  - draft 缺键视为与 applied 相同（草稿对象来自 AppSettings 实例序列化，理论不缺键；缺了就别报）；
 *  - 值统一 JSON 字符串口径进 SettingsDiffItem（页面展示/接线用）；
 *  - 输出按 registry 声明序稳定排序。
 */
export function diffSettings(draft: Record<string, Object>, applied: Record<string, Object>): SettingsDiff {
  const out = new SettingsDiff();
  for (let i = 0; i < REGISTRY.length; i++) {
    const d = REGISTRY[i];
    const dv = recordValue(draft, d.key);
    if (dv === undefined) {
      continue;
    }
    let av = recordValue(applied, d.key);
    if (av === undefined) {
      av = jsonToValue(d);
    }
    if (valuesEqual(dv, av, d.kind)) {
      continue;
    }
    const item = new SettingsDiffItem();
    item.key = d.key;
    item.section = d.section;
    item.applyClass = d.applyClass;
    item.appliedValue = JSON.stringify(av);
    item.draftValue = JSON.stringify(dv);
    item.labelToken = d.labelToken;
    out.items.push(item);
    if (d.applyClass === APPLY_RECONNECT) {
      out.reconnectCount += 1;
    } else if (d.applyClass === APPLY_NEXT_TASK) {
      out.nextTaskCount += 1;
    } else {
      out.immediateCount += 1;
    }
  }
  out.total = out.items.length;
  return out;
}

/**
 * 待应用条摘要 token(P6/W21 i18n 收口):total=0 返回 '';否则返回 'pending_changes',
 * 页面用 `$r('app.string.settings_pending_summary', diff.total)` 渲染。
 */
export const SUMMARY_PENDING_CHANGES: string = 'pending_changes';

export function summaryText(diff: SettingsDiff): string {
  if (diff.total === 0) {
    return '';
  }
  return SUMMARY_PENDING_CHANGES;
}

/** 待应用条影响行的结构化形态:kind ∈ APPLY_IMMEDIATE/APPLY_NEXT_TASK/APPLY_RECONNECT,页面映射 $r。 */
export class ImpactPart {
  kind: string = '';
  count: number = 0;
}

/**
 * 待应用条影响行结构(只列非零;顺序固定 reconnect → nextTask → immediate;全零返回 [])。
 * 页面映射:reconnect→settings_impact_reconnect、nextTask→settings_impact_next_task、
 * immediate→settings_impact_immediate(均带 %1$d)。kind 取值与 APPLY_* 常量一致。
 */
export function impactParts(diff: SettingsDiff): Array<ImpactPart> {
  const out: Array<ImpactPart> = [];
  if (diff.reconnectCount > 0) {
    const p = new ImpactPart();
    p.kind = APPLY_RECONNECT;
    p.count = diff.reconnectCount;
    out.push(p);
  }
  if (diff.nextTaskCount > 0) {
    const p = new ImpactPart();
    p.kind = APPLY_NEXT_TASK;
    p.count = diff.nextTaskCount;
    out.push(p);
  }
  if (diff.immediateCount > 0) {
    const p = new ImpactPart();
    p.kind = APPLY_IMMEDIATE;
    p.count = diff.immediateCount;
    out.push(p);
  }
  return out;
}
