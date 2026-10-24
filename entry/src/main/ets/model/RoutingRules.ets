import { fnv1a32 } from './ProbeResult';

/**
 * 规则类型化模型 + 编译 manifest + 校验 —— REDESIGN-PLAN-2026-10-23.md §7.3(规则编辑器)/
 * §7.4(顺序与模式)/§8.5(按包名指定出站的历史数据)/§12.3-2(静态校验)/W13。
 *
 * 纯模型：无 I/O、无平台依赖，便于主机测试(tests/routing-rules.cjs)。
 *
 * ---- 与既有代码的对齐(2026-10-24 逐行核对，勿凭想象) ----
 * 1) 旧存储：`model/RouteRule.ets:10-29` 的 RouteRule 是**多字段 AND 行**：
 *    type/value(旧单类型) + domains/ip/port/source/sourcePort/network/protocol/packages/config。
 *    本模型把它解析成"一条规则一个主条件"的类型化视图，**其余高级条件原样保留在
 *    `RoutingRule.legacyRow` 里**，写回时合并回去——绝不因为类型化而丢条件(§8.5 明确禁止
 *    "只删 packages 后让其余条件扩大匹配范围")。
 * 2) 内核字段口径以 `core/ConfigBuilder.ets:456-568 buildCustomRule` 为准：
 *    full:→domain、domain:/裸值→domain_suffix、regexp:→domain_regex(保留大小写)、
 *    keyword:→domain_keyword、geosite:/geoip:→rule_set、geoip:private→ip_is_private、
 *    port→port(数字数组)+port_range(字符串数组)、source→source_ip_cidr、
 *    network→network、packages(且 packagesEnabled)→process_name、reject→action:'reject'。
 * 3) packages 历史规则：`model/MigrationV5.ets:626-643` 已对含 packages 的行写
 *    `unsupportedOnPlatform:true` 并保留原文/启用状态；本模型用 LEGACY_PACKAGE_TYPE 表示，
 *    只进"需处理的旧规则"（§8.5：保留暂停/改为域名IP条件/删除，**不得自动转换**）。
 * 4) 远程规则集：`core/RuleSetRepository.ets` 的规则集 id / `model/RouteRule.ets:32-41`
 *    RemoteRuleSet(id/url/type/outbound/enabled)；`rule_set` 类型规则引用这些 id。
 * 5) DNS 投影判定依据见 `validateDnsProjection` 上方注释(每条都对应 ConfigBuilder 行号)。
 */

// ---- 规则类型 token ----
export const RULE_DOMAIN: string = 'domain';
export const RULE_DOMAIN_SUFFIX: string = 'domain_suffix';
export const RULE_DOMAIN_KEYWORD: string = 'domain_keyword';
export const RULE_DOMAIN_REGEX: string = 'domain_regex';
export const RULE_GEOSITE: string = 'rule_set';
export const RULE_IP_CIDR: string = 'ip_cidr';
export const RULE_GEOIP: string = 'geoip';
export const RULE_PORT: string = 'port';
export const RULE_PORT_RANGE: string = 'port_range';
export const RULE_NETWORK: string = 'network';
export const RULE_PROCESS: string = 'process_name';
/** 旧"按包名指定出站"，平台上不支持(§8.5)：不进 manifest，只作为待处理旧规则展示。 */
export const LEGACY_PACKAGE_TYPE: string = 'package';
/**
 * 旧行里只剩高级条件(source/sourcePort/protocol/config)时的类型占位：
 * 主条件为空但高级条件仍有效，编译时由 legacyRow 投影进 manifest(不丢条件)。
 */
export const LEGACY_ADVANCED_TYPE: string = 'advanced';

// ---- 出站 token(与旧行 outbound 值一致：proxy/direct/reject) ----
export const RULE_OUT_DIRECT: string = 'direct';
export const RULE_OUT_PROXY: string = 'proxy';
export const RULE_OUT_BLOCK: string = 'block';

// ---- 校验码(RuleIssue.code) ----
export const ISSUE_EMPTY_PAYLOAD: string = 'empty_payload';
export const ISSUE_INVALID_CIDR: string = 'invalid_cidr';
export const ISSUE_INVALID_PORT: string = 'invalid_port';
export const ISSUE_INVALID_REGEX: string = 'invalid_regex';
export const ISSUE_DUP_RULE: string = 'dup_rule';
export const ISSUE_OVERLAP: string = 'overlap';
export const ISSUE_GEOSITE_MISSING: string = 'geosite_missing';
// DNS 投影(validateDnsProjection 专用；见该函数注释里的 ConfigBuilder 证据)
export const ISSUE_DNS_LOOP: string = 'dns_loop_risk';
export const ISSUE_DNS_PROJECTION_BROADER: string = 'dns_projection_broader';
export const ISSUE_DNS_PROJECTION_MISSING: string = 'dns_projection_missing';
export const ISSUE_DNS_ROUTING_OFF: string = 'dns_routing_off';

const DOMAIN_TYPES: Array<string> = [
  RULE_DOMAIN, RULE_DOMAIN_SUFFIX, RULE_DOMAIN_KEYWORD, RULE_DOMAIN_REGEX
];

/** 一条类型化路由规则。 */
export class RoutingRule {
  /** 稳定 ID：旧行已存的保留原值；没有的按行内容派生(见 parseRules) */
  id: string = '';
  type: string = RULE_DOMAIN_SUFFIX;
  payload: string = '';
  outbound: string = RULE_OUT_PROXY;
  enabled: boolean = true;
  /** 显式顺序(0 起)；旧行按数组下标 */
  order: number = 0;
  /** 'user' | 'preset'(旧行没有来源标记，默认 user；写回时存 ruleSource) */
  source: string = 'user';
  /** §8.5 平台不支持标记(迁移已写；本模型只读不改) */
  unsupportedOnPlatform: boolean = false;
  unsupportedReason: string = '';
  /**
   * 旧行的其余条件与元数据(原样深拷贝，不含本类已建模字段)：
   * toRawRows 合并回去，compileManifest 投影进 CompiledRule.extra，
   * 保证 AND 条件不因类型化而丢失/放宽(§8.5/§7.4)。
   */
  legacyRow: Record<string, Object> = {};
}

/** 校验问题(错误/警告共用；code 见 ISSUE_*)。 */
export class RuleIssue {
  ruleId: string = '';
  code: string = '';
  detail: string = '';
}

/** 校验结果。legacyCount = 需处理的旧规则数(packages 或已标 unsupportedOnPlatform)。 */
export class RuleValidation {
  errors: Array<RuleIssue> = [];
  warnings: Array<RuleIssue> = [];
  legacyCount: number = 0;
}

/** 编译后的一条规则(manifest 用)。 */
export class CompiledRule {
  ruleId: string = '';
  type: string = '';
  payload: string = '';
  outbound: string = '';
  /**
   * 旧行高级条件的**内核投影**(与 ConfigBuilder 同口径，见 projectRowConditions)：
   * 用来保证 toKernelItems 生成的规则不会因为只带主条件而扩大匹配范围(§7.4)。
   * 新规则为空对象。
   */
  extra: Record<string, Object> = {};
}

/** 编译 manifest(§7.4：规则解释与诊断基于同一份实际修订)。 */
export class RuleManifest {
  items: Array<CompiledRule> = [];
  generatedAt: number = 0;
  /** items 规范化内容的 fnv1a32(与 ConfigSnapshot/ProbeResult 同一实现) */
  hash: string = '';
}

/** DNS 投影校验输入(与 AppSettings 对应字段同名，W14 可直接传)。 */
export interface DnsProjectionSettings {
  dnsRouting: boolean;
  fakeDns: boolean;
  directDns: string;
  remoteDns: string;
}

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------

/** 与 ConfigBuilder.splitRuleList(:571-574) 同口径：逗号/换行分隔、trim、去空。 */
function splitList(text: string): Array<string> {
  const parts: Array<string> = text.split(/[,\r\n]/);
  const out: Array<string> = [];
  for (let i = 0; i < parts.length; i++) {
    const item = parts[i].trim();
    if (item.length > 0) {
      out.push(item);
    }
  }
  return out;
}

function pushUnique(out: Array<string>, value: string): void {
  for (let i = 0; i < out.length; i++) {
    if (out[i] === value) {
      return;
    }
  }
  out.push(value);
}

function strField(row: Record<string, Object>, key: string): string {
  const v = row[key];
  return typeof v === 'string' ? v : (v === undefined || v === null ? '' : `${v}`);
}

function boolField(row: Record<string, Object>, key: string, dflt: boolean): boolean {
  const v = row[key];
  return typeof v === 'boolean' ? v : dflt;
}

function isRecordObject(v: Object): boolean {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function cloneRow(row: Record<string, Object>): Record<string, Object> {
  try {
    return JSON.parse(JSON.stringify(row)) as Record<string, Object>;
  } catch (e) {
    return {};
  }
}

function isKnownType(t: string): boolean {
  return t === RULE_DOMAIN || t === RULE_DOMAIN_SUFFIX || t === RULE_DOMAIN_KEYWORD ||
    t === RULE_DOMAIN_REGEX || t === RULE_GEOSITE || t === RULE_IP_CIDR || t === RULE_GEOIP ||
    t === RULE_PORT || t === RULE_PORT_RANGE || t === RULE_NETWORK || t === RULE_PROCESS;
}

/** 旧 type 词表 → 类型化 token(旧 type 无 domain_regex/network 等，未命中返回 '')。 */
function typeFromLegacy(legacyType: string): string {
  if (legacyType === 'domain') {
    return RULE_DOMAIN;
  }
  if (legacyType === 'domain_suffix') {
    return RULE_DOMAIN_SUFFIX;
  }
  if (legacyType === 'domain_keyword') {
    return RULE_DOMAIN_KEYWORD;
  }
  if (legacyType === 'ip_cidr') {
    return RULE_IP_CIDR;
  }
  if (legacyType === 'geoip') {
    return RULE_GEOIP;
  }
  if (legacyType === 'geosite') {
    return RULE_GEOSITE;
  }
  if (legacyType === 'port') {
    return RULE_PORT;
  }
  return '';
}

/** 类型化 token → 旧行 type 字段(仅用于写回兼容；旧加载器不依赖它，新字段优先)。 */
function legacyTypeOf(type: string): string {
  if (type === RULE_DOMAIN) {
    return 'domain';
  }
  if (type === RULE_DOMAIN_SUFFIX) {
    return 'domain_suffix';
  }
  if (type === RULE_DOMAIN_KEYWORD) {
    return 'domain_keyword';
  }
  if (type === RULE_IP_CIDR) {
    return 'ip_cidr';
  }
  if (type === RULE_GEOIP) {
    return 'geoip';
  }
  if (type === RULE_GEOSITE) {
    return 'geosite';
  }
  if (type === RULE_PORT || type === RULE_PORT_RANGE) {
    return 'port';
  }
  return type;
}

// ---------------------------------------------------------------------------
// normalizePayload
// ---------------------------------------------------------------------------

function normalizePortText(text: string): string {
  const out: Array<string> = [];
  const tokens = splitList(text);
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (/^\d+$/.test(token)) {
      pushUnique(out, `${Number(token)}`);
    } else if (/^\d*:\d*$/.test(token)) {
      const ends = token.split(':');
      const start = ends[0].length === 0 ? '' : `${Number(ends[0])}`;
      const end = ends[1].length === 0 ? '' : `${Number(ends[1])}`;
      pushUnique(out, `${start}:${end}`);
    } else {
      pushUnique(out, token);
    }
  }
  return out.join(',');
}

/** 规范化 payload：trim/去空/去重；域名类小写(正则保留原文)，CIDR 去空格，端口去前导零。 */
export function normalizePayload(type: string, text: string): string {
  const items = splitList(text);
  const out: Array<string> = [];
  if (type === RULE_DOMAIN_REGEX) {
    // 正则大小写敏感：只 trim/去重，原样保留(§7.3「保留正则原文」)
    for (let i = 0; i < items.length; i++) {
      pushUnique(out, items[i]);
    }
    return out.join(',');
  }
  if (type === RULE_PORT || type === RULE_PORT_RANGE) {
    return normalizePortText(text);
  }
  if (type === RULE_IP_CIDR) {
    for (let i = 0; i < items.length; i++) {
      pushUnique(out, items[i].replace(/\s+/g, '').toLowerCase());
    }
    return out.join(',');
  }
  if (type === RULE_PROCESS) {
    for (let i = 0; i < items.length; i++) {
      pushUnique(out, items[i]);
    }
    return out.join(',');
  }
  // 域名类/network/rule_set：统一小写
  for (let i = 0; i < items.length; i++) {
    pushUnique(out, items[i].toLowerCase());
  }
  return out.join(',');
}

// ---------------------------------------------------------------------------
// IP / CIDR / 端口 / 正则 校验(纯函数，供 validateRules 与 overlap 复用)
// ---------------------------------------------------------------------------

class IpCheck {
  valid: boolean = false;
  v4: boolean = false;
  v6: boolean = false;
  text: string = '';
}

function checkIpv4(text: string): boolean {
  const parts = text.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (!/^\d{1,3}$/.test(part)) {
      return false;
    }
    const n = Number(part);
    if (n < 0 || n > 255) {
      return false;
    }
  }
  return true;
}

function checkIpv6(text: string): boolean {
  const lower = text.toLowerCase();
  if (lower.indexOf(':') < 0) {
    return false;
  }
  // 只允许一次 '::'
  const doubleIdx = lower.indexOf('::');
  if (doubleIdx >= 0 && lower.indexOf('::', doubleIdx + 1) >= 0) {
    return false;
  }
  const groupsText = lower;
  const parts = groupsText.split(':');
  let filled = 0;
  let hasCompressed = false;
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part.length === 0) {
      hasCompressed = true;
      continue;
    }
    if (part.indexOf('.') >= 0) {
      // 内嵌 IPv4(例如 ::ffff:1.2.3.4)，占 2 组
      if (!checkIpv4(part)) {
        return false;
      }
      filled += 2;
      continue;
    }
    if (!/^[0-9a-f]{1,4}$/.test(part)) {
      return false;
    }
    filled++;
  }
  if (hasCompressed) {
    return filled <= 7;
  }
  return filled === 8;
}

/** 判断 "地址[/前缀]"；type 0=非法 1=v4 2=v6。 */
function parseAddress(text: string): IpCheck {
  const out = new IpCheck();
  const trimmed = text.replace(/\s+/g, '');
  if (trimmed.length === 0) {
    return out;
  }
  const slash = trimmed.indexOf('/');
  const addr = slash >= 0 ? trimmed.substring(0, slash) : trimmed;
  const prefixText = slash >= 0 ? trimmed.substring(slash + 1) : '';
  if (slash >= 0 && !/^\d{1,3}$/.test(prefixText)) {
    return out;
  }
  if (checkIpv4(addr)) {
    if (slash >= 0) {
      const prefix = Number(prefixText);
      if (prefix > 32) {
        return out;
      }
    }
    out.valid = true;
    out.v4 = true;
    out.text = trimmed;
    return out;
  }
  if (checkIpv6(addr)) {
    if (slash >= 0) {
      const prefix = Number(prefixText);
      if (prefix > 128) {
        return out;
      }
    }
    out.valid = true;
    out.v6 = true;
    out.text = trimmed;
    return out;
  }
  return out;
}

/** IPv4 点分 → 无符号 32 位；非法返回 -1。 */
function ipv4ToNumber(text: string): number {
  if (!checkIpv4(text)) {
    return -1;
  }
  const parts = text.split('.');
  let value = 0;
  for (let i = 0; i < 4; i++) {
    value = value * 256 + Number(parts[i]);
  }
  return value;
}

class PortCheck {
  numbers: Array<number> = [];
  ranges: Array<string> = [];
  invalid: Array<string> = [];
}

/** 端口/区间校验(§7.3：端口 1-65535，支持开区间 a:b / a: / :b)。 */
function checkPorts(text: string): PortCheck {
  const out = new PortCheck();
  const tokens = splitList(text);
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (/^\d+$/.test(token)) {
      const port = Number(token);
      if (port >= 1 && port <= 65535) {
        if (out.numbers.indexOf(port) < 0) {
          out.numbers.push(port);
        }
      } else {
        out.invalid.push(token);
      }
      continue;
    }
    if (/^\d*:\d*$/.test(token)) {
      const ends = token.split(':');
      const hasStart = ends[0].length > 0;
      const hasEnd = ends[1].length > 0;
      const start = hasStart ? Number(ends[0]) : 1;
      const end = hasEnd ? Number(ends[1]) : 65535;
      const startOk = !hasStart || (start >= 1 && start <= 65535);
      const endOk = !hasEnd || (end >= 1 && end <= 65535);
      if (startOk && endOk && start <= end) {
        if (out.ranges.indexOf(token) < 0) {
          out.ranges.push(token);
        }
      } else {
        out.invalid.push(token);
      }
      continue;
    }
    out.invalid.push(token);
  }
  return out;
}

/** 正则可编译性(带异常捕获，错误原文进 detail)。 */
class RegexCheck {
  ok: boolean = true;
  message: string = '';
}

function checkRegex(pattern: string): RegexCheck {
  const out = new RegexCheck();
  try {
    // 仅编译不执行：语法错误会抛异常(空模式是合法的，由 empty_payload 管)
    new RegExp(pattern);
  } catch (e) {
    out.ok = false;
    out.message = e instanceof Error ? e.message : `${e}`;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 旧行条件解析(buildCustomRule 同口径)
// ---------------------------------------------------------------------------

class RowConditions {
  domains: Array<string> = [];
  suffixes: Array<string> = [];
  regexes: Array<string> = [];
  keywords: Array<string> = [];
  ruleSetRefs: Array<string> = [];      // 旧行 domains 里的 geosite: 引用
  extraRuleSetRefs: Array<string> = []; // 新字段 ruleSetRefs(远程规则集 id，旧内核不识别但也不能当域名)
  cidrs: Array<string> = [];
  ipPrivate: boolean = false;
  geoipRefs: Array<string> = [];
  ports: Array<number> = [];
  portRanges: Array<string> = [];
  sourceCidrs: Array<string> = [];
  sourcePorts: Array<number> = [];
  sourcePortRanges: Array<string> = [];
  network: string = '';
  protocols: Array<string> = [];
  packages: Array<string> = [];
  packagesEnabled: boolean = false;
  config: Record<string, Object> | null = null;
}

/** 解析旧行的条件字段(与 ConfigBuilder.buildCustomRule 的前缀语义一致)。 */
function parseRowConditions(row: Record<string, Object>): RowConditions {
  const out = new RowConditions();
  // 新字段 ruleSetRefs：远程规则集 id(逗号分隔)。旧内核不识别，但绝不能落回 domains
  // 被当成 domain_suffix(ConfigBuilder.buildCustomRule:483-486 会把裸值当后缀)。
  const extraRefsText = strField(row, 'ruleSetRefs');
  if (extraRefsText.trim().length > 0) {
    const refs = splitList(extraRefsText);
    for (let i = 0; i < refs.length; i++) {
      pushUnique(out.extraRuleSetRefs, refs[i].toLowerCase());
    }
  }
  const domainsText = strField(row, 'domains');
  if (domainsText.trim().length > 0) {
    const items = splitList(domainsText);
    for (let i = 0; i < items.length; i++) {
      const raw = items[i];
      const it = raw.toLowerCase();
      if (it.startsWith('geosite:')) {
        pushUnique(out.ruleSetRefs, it);
      } else if (it.startsWith('full:')) {
        pushUnique(out.domains, it.substring('full:'.length));
      } else if (it.startsWith('domain:')) {
        pushUnique(out.suffixes, it.substring('domain:'.length));
      } else if (it.startsWith('regexp:')) {
        pushUnique(out.regexes, raw.substring('regexp:'.length));
      } else if (it.startsWith('keyword:')) {
        pushUnique(out.keywords, it.substring('keyword:'.length));
      } else {
        pushUnique(out.suffixes, it);
      }
    }
  }
  const ipText = strField(row, 'ip');
  if (ipText.trim().length > 0) {
    const items = splitList(ipText);
    for (let i = 0; i < items.length; i++) {
      const it = items[i].toLowerCase();
      if (it === 'geoip:private') {
        out.ipPrivate = true;
      } else if (it.startsWith('geoip:')) {
        pushUnique(out.geoipRefs, it);
      } else {
        pushUnique(out.cidrs, it);
      }
    }
  }
  const ports = checkPorts(strField(row, 'port'));
  out.ports = ports.numbers;
  out.portRanges = ports.ranges;
  const sourcePorts = checkPorts(strField(row, 'sourcePort'));
  out.sourcePorts = sourcePorts.numbers;
  out.sourcePortRanges = sourcePorts.ranges;
  const source = splitList(strField(row, 'source'));
  for (let i = 0; i < source.length; i++) {
    pushUnique(out.sourceCidrs, source[i]);
  }
  const network = strField(row, 'network');
  if (network === 'tcp' || network === 'udp') {
    out.network = network;
  }
  const protocols = splitList(strField(row, 'protocol'));
  for (let i = 0; i < protocols.length; i++) {
    pushUnique(out.protocols, protocols[i]);
  }
  const packages = splitList(strField(row, 'packages'));
  for (let i = 0; i < packages.length; i++) {
    pushUnique(out.packages, packages[i]);
  }
  out.packagesEnabled = boolField(row, 'packagesEnabled', out.packages.length > 0);
  const configText = strField(row, 'config').trim();
  if (configText.length > 0) {
    try {
      const parsed = JSON.parse(configText) as Object;
      if (isRecordObject(parsed)) {
        out.config = parsed as Record<string, Object>;
      }
    } catch (e) {
      // 旧行自定义 JSON 非法：语法层忽略(ConfigBuilder.parseUserJson 同口径)，
      // 原文仍在 legacyRow 里，不在这里报错。
    }
  }
  return out;
}

class PrimaryCondition {
  type: string = RULE_DOMAIN_SUFFIX;
  payload: string = '';
  /** 该主条件对应的旧字段组(写回时用于替换/清理) */
  group: string = '';
}

/** 从旧行条件推导主条件(显式类型优先；顺序见注释)。 */
function derivePrimary(conds: RowConditions): PrimaryCondition {
  const out = new PrimaryCondition();
  // §8.5：含 packages 的行一律归"需处理的旧规则"，不拆条件、不放大匹配
  if (conds.packages.length > 0) {
    out.type = LEGACY_PACKAGE_TYPE;
    out.payload = conds.packages.join(',');
    out.group = 'packages';
    return out;
  }
  // 域名类优先级：后缀(最常见) > 精确 > keyword > regex > rule_set
  if (conds.suffixes.length > 0) {
    out.type = RULE_DOMAIN_SUFFIX;
    out.payload = conds.suffixes.join(',');
    out.group = 'suffixes';
    return out;
  }
  if (conds.domains.length > 0) {
    out.type = RULE_DOMAIN;
    out.payload = conds.domains.join(',');
    out.group = 'domains';
    return out;
  }
  if (conds.keywords.length > 0) {
    out.type = RULE_DOMAIN_KEYWORD;
    out.payload = conds.keywords.join(',');
    out.group = 'keywords';
    return out;
  }
  if (conds.regexes.length > 0) {
    out.type = RULE_DOMAIN_REGEX;
    out.payload = conds.regexes.join(',');
    out.group = 'regexes';
    return out;
  }
  if (conds.ruleSetRefs.length > 0 || conds.extraRuleSetRefs.length > 0) {
    out.type = RULE_GEOSITE;
    const allRefs: Array<string> = [];
    for (let i = 0; i < conds.ruleSetRefs.length; i++) {
      pushUnique(allRefs, conds.ruleSetRefs[i]);
    }
    for (let i = 0; i < conds.extraRuleSetRefs.length; i++) {
      pushUnique(allRefs, conds.extraRuleSetRefs[i]);
    }
    out.payload = allRefs.join(',');
    out.group = 'ruleSetRefs';
    return out;
  }
  if (conds.cidrs.length > 0) {
    out.type = RULE_IP_CIDR;
    out.payload = conds.cidrs.join(',');
    out.group = 'cidrs';
    return out;
  }
  if (conds.ipPrivate) {
    out.type = RULE_GEOIP;
    out.payload = 'private';
    out.group = 'ipPrivate';
    return out;
  }
  if (conds.geoipRefs.length > 0) {
    out.type = RULE_GEOIP;
    const refs: Array<string> = [];
    for (let i = 0; i < conds.geoipRefs.length; i++) {
      refs.push(conds.geoipRefs[i].substring('geoip:'.length));
    }
    out.payload = refs.join(',');
    out.group = 'geoipRefs';
    return out;
  }
  if (conds.ports.length > 0) {
    out.type = RULE_PORT;
    const nums: Array<string> = [];
    for (let i = 0; i < conds.ports.length; i++) {
      nums.push(`${conds.ports[i]}`);
    }
    out.payload = nums.join(',');
    out.group = 'ports';
    return out;
  }
  if (conds.portRanges.length > 0) {
    out.type = RULE_PORT_RANGE;
    out.payload = conds.portRanges.join(',');
    out.group = 'portRanges';
    return out;
  }
  if (conds.network.length > 0) {
    out.type = RULE_NETWORK;
    out.payload = conds.network;
    out.group = 'network';
    return out;
  }
  // 只剩高级条件(source/sourcePort/protocol/config)：保留为 advanced(编译时由 extra 投影)
  out.type = LEGACY_ADVANCED_TYPE;
  out.payload = '';
  out.group = 'advanced';
  return out;
}

// ---------------------------------------------------------------------------
// parseRules / toRawRows / newRuleId
// ---------------------------------------------------------------------------

let ruleIdSeq: number = 0;

/** 新建规则 id：'rule_<ts>_<seq><rand>'；同一进程内单调，避免同毫秒冲突。 */
export function newRuleId(type: string): string {
  ruleIdSeq++;
  const ts = Date.now().toString(36);
  const rand = Math.floor(Math.random() * 0x7fffff).toString(16);
  const token = type.length > 0 ? type.substring(0, 4) : 'rule';
  return `rule_${ts}_${ruleIdSeq.toString(36)}${rand}_${token}`;
}

/** 旧行内容的稳定键(id 派生用)：排序键后拼接，保证同内容同 id。 */
function stableRowKey(row: Record<string, Object>): string {
  const keys = Object.keys(row).sort();
  const parts: Array<string> = [];
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    if (k === 'id') {
      continue;
    }
    parts.push(`${k}=${JSON.stringify(row[k])}`);
  }
  return parts.join('\u0001');
}

export function parseRules(raw: Array<Record<string, Object>>): Array<RoutingRule> {
  const out: Array<RoutingRule> = [];
  const usedIds = new Set<string>();
  for (let i = 0; i < raw.length; i++) {
    const row = raw[i];
    const rule = new RoutingRule();
    rule.order = i;
    rule.enabled = boolField(row, 'enabled', true);
    const outboundRaw = strField(row, 'outbound');
    rule.outbound = outboundRaw === 'reject' ? RULE_OUT_BLOCK
      : (outboundRaw.length > 0 ? outboundRaw : RULE_OUT_PROXY);
    rule.unsupportedOnPlatform = boolField(row, 'unsupportedOnPlatform', false);
    rule.unsupportedReason = strField(row, 'unsupportedReason');
    const sourceRaw = strField(row, 'ruleSource');
    rule.source = sourceRaw.length > 0 ? sourceRaw : 'user';
    rule.legacyRow = cloneRow(row);

    const explicitType = strField(row, 'type');
    const isNewFormat = row['payload'] !== undefined;
    if (isNewFormat && (isKnownType(explicitType) || explicitType === LEGACY_PACKAGE_TYPE)) {
      // 新格式(未来路由库)：payload 直取，无旧行条件
      rule.type = explicitType;
      rule.payload = normalizePayload(explicitType, strField(row, 'payload'));
      rule.legacyRow = {};
    } else {
      const conds = parseRowConditions(row);
      const mapped = typeFromLegacy(explicitType);
      const hasNewFields = conds.domains.length > 0 || conds.suffixes.length > 0 ||
        conds.regexes.length > 0 || conds.keywords.length > 0 || conds.ruleSetRefs.length > 0 ||
        conds.extraRuleSetRefs.length > 0 ||
        conds.cidrs.length > 0 || conds.ipPrivate || conds.geoipRefs.length > 0 ||
        conds.ports.length > 0 || conds.portRanges.length > 0 || conds.network.length > 0 ||
        conds.packages.length > 0 || conds.sourceCidrs.length > 0 ||
        conds.sourcePorts.length > 0 || conds.protocols.length > 0 || conds.config !== null;
      if (!hasNewFields && mapped.length > 0) {
        // 纯旧单类型行：type/value
        rule.type = mapped;
        rule.payload = normalizePayload(mapped, strField(row, 'value'));
      } else {
        const primary = derivePrimary(conds);
        rule.type = primary.type;
        rule.payload = normalizePayload(primary.type, primary.payload);
      }
    }
    // 稳定 ID：已存在的保留；否则按行内容派生(重复内容追加序号，保证唯一)
    const rawId = strField(row, 'id').trim();
    let id = rawId;
    if (id.length === 0) {
      id = `rule_${fnv1a32(stableRowKey(row))}`;
    }
    let unique = id;
    let suffix = 2;
    while (usedIds.has(unique)) {
      unique = `${id}_${suffix}`;
      suffix++;
    }
    usedIds.add(unique);
    rule.id = unique;
    out.push(rule);
  }
  return out;
}

/** 拷贝记录但跳过指定键(ArkTS 禁止 delete 的等价实现;skin 为空的键不会出现在结果里)。 */
function rowWithoutKeys(row: Record<string, Object>, skip: Array<string>): Record<string, Object> {
  const out: Record<string, Object> = {};
  const keys = Object.keys(row);
  for (let i = 0; i < keys.length; i++) {
    if (skip.indexOf(keys[i]) < 0) {
      out[keys[i]] = row[keys[i]];
    }
  }
  return out;
}

export function toRawRows(rules: Array<RoutingRule>): Array<Record<string, Object>> {
  const out: Array<Record<string, Object>> = [];
  for (let i = 0; i < rules.length; i++) {
    const rule = rules[i];
    const values = splitList(rule.payload);
    const conds = parseRowConditions(rule.legacyRow); // 旧行条件(可能为空)
    const hasLegacy = Object.keys(rule.legacyRow).length > 0;
    const oldPrimary = hasLegacy ? derivePrimary(conds) : null;
    // 类型被改写：旧条件组一律丢弃(宁可收窄也不放宽，§8.5 精神)，只留元数据与用户 config
    const typeChanged = oldPrimary !== null && oldPrimary.group !== 'advanced' &&
      oldPrimary.type !== rule.type;
    /* ArkTS 不支持 `delete`(arkts-no-delete):用"白名单拷贝"等价替换原来的 19 处 delete。
       skip = 原 delete 的并集(typeChanged 时额外丢弃 source/sourcePort,即丢弃整组旧条件)。 */
    const skip: Array<string> = typeChanged
      ? ['domains', 'ip', 'port', 'source', 'sourcePort', 'network', 'protocol', 'packages',
        'packagesEnabled', 'value', 'legacyRow']
      : ['domains', 'ip', 'port', 'network', 'protocol', 'packages', 'packagesEnabled',
        'value', 'legacyRow'];
    let base: Record<string, Object> = rowWithoutKeys(rule.legacyRow, skip);
    // 域名类(其它组 + 主条件)
    const domainParts: Array<string> = [];
    const pushDomain = (prefix: string, list: Array<string>, skip: boolean): void => {
      if (skip) {
        return;
      }
      for (let k = 0; k < list.length; k++) {
        domainParts.push(`${prefix}${list[k]}`);
      }
    };
    pushDomain('', conds.suffixes, rule.type === RULE_DOMAIN_SUFFIX);
    pushDomain('full:', conds.domains, rule.type === RULE_DOMAIN);
    pushDomain('keyword:', conds.keywords, rule.type === RULE_DOMAIN_KEYWORD);
    pushDomain('regexp:', conds.regexes, rule.type === RULE_DOMAIN_REGEX);
    pushDomain('', conds.ruleSetRefs, rule.type === RULE_GEOSITE);
    if (rule.type === RULE_DOMAIN) {
      pushDomain('full:', values, false);
    } else if (rule.type === RULE_DOMAIN_SUFFIX) {
      pushDomain('', values, false);
    } else if (rule.type === RULE_DOMAIN_KEYWORD) {
      pushDomain('keyword:', values, false);
    } else if (rule.type === RULE_DOMAIN_REGEX) {
      pushDomain('regexp:', values, false);
    } else if (rule.type === RULE_GEOSITE) {
      // 旧内核只认 domains 里的 geosite:/geoip: 前缀(ConfigBuilder.buildCustomRule:468-486)；
      // 远程规则集 id 不能写进 domains(裸值会被当 domain_suffix，语义错误)，
      // 改写到新字段 ruleSetRefs，由 W14/ConfigBuilder 改造后消费。
      for (let k = 0; k < values.length; k++) {
        const v = values[k];
        if (v.startsWith('geosite:') || v.startsWith('geoip:')) {
          domainParts.push(v);
        }
      }
    }
    if (domainParts.length > 0) {
      base['domains'] = domainParts.join(',');
    }
    // 规则集引用(新字段)：远程 id 全量保留；旧 geosite: 引用继续留在 domains 保持兼容
    const refParts: Array<string> = [];
    if (rule.type === RULE_GEOSITE) {
      for (let k = 0; k < values.length; k++) {
        pushUnique(refParts, values[k]);
      }
    }
    for (let k = 0; k < conds.extraRuleSetRefs.length; k++) {
      pushUnique(refParts, conds.extraRuleSetRefs[k]);
    }
    if (refParts.length > 0) {
      base['ruleSetRefs'] = refParts.join(',');
    } else {
      base = rowWithoutKeys(base, ['ruleSetRefs']);
    }
    // IP 类(其它组 + 主条件)
    const ipParts: Array<string> = [];
    if (rule.type !== RULE_IP_CIDR) {
      for (let k = 0; k < conds.cidrs.length; k++) {
        ipParts.push(conds.cidrs[k]);
      }
    }
    if (rule.type !== RULE_GEOIP) {
      if (conds.ipPrivate) {
        ipParts.push('geoip:private');
      }
      for (let k = 0; k < conds.geoipRefs.length; k++) {
        ipParts.push(conds.geoipRefs[k]);
      }
    }
    if (rule.type === RULE_IP_CIDR) {
      for (let k = 0; k < values.length; k++) {
        ipParts.push(values[k]);
      }
    } else if (rule.type === RULE_GEOIP) {
      for (let k = 0; k < values.length; k++) {
        const v = values[k];
        ipParts.push(v === 'private' ? 'geoip:private' :
          (v.startsWith('geoip:') ? v : `geoip:${v}`));
      }
    }
    if (ipParts.length > 0) {
      base['ip'] = ipParts.join(',');
    }
    // 端口(数字/区间互补，与 setRulePorts 口径一致)
    const portParts: Array<string> = [];
    if (rule.type !== RULE_PORT) {
      for (let k = 0; k < conds.ports.length; k++) {
        portParts.push(`${conds.ports[k]}`);
      }
    }
    if (rule.type !== RULE_PORT_RANGE) {
      for (let k = 0; k < conds.portRanges.length; k++) {
        portParts.push(conds.portRanges[k]);
      }
    }
    if (rule.type === RULE_PORT || rule.type === RULE_PORT_RANGE) {
      for (let k = 0; k < values.length; k++) {
        portParts.push(values[k]);
      }
    }
    if (portParts.length > 0) {
      base['port'] = portParts.join(',');
    }
    // 网络/协议/包名(主条件优先，旧条件保留)
    if (rule.type === RULE_NETWORK) {
      base['network'] = rule.payload.trim().toLowerCase();
    } else if (conds.network.length > 0) {
      base['network'] = conds.network;
    }
    if (conds.protocols.length > 0) {
      base['protocol'] = conds.protocols.join(',');
    }
    if (rule.type === LEGACY_PACKAGE_TYPE || rule.type === RULE_PROCESS) {
      base['packages'] = values.join(',');
      base['packagesEnabled'] = true;
    } else if (conds.packages.length > 0) {
      base['packages'] = conds.packages.join(',');
      base['packagesEnabled'] = conds.packagesEnabled;
    }
    // 元数据(稳定 ID / 出站 / 启用 / 平台标记 / 来源)
    base['id'] = rule.id;
    base['type'] = legacyTypeOf(rule.type);
    base['outbound'] = rule.outbound === RULE_OUT_BLOCK ? 'reject' : rule.outbound;
    base['enabled'] = rule.enabled;
    base['unsupportedOnPlatform'] = rule.unsupportedOnPlatform;
    if (rule.unsupportedReason.length > 0) {
      base['unsupportedReason'] = rule.unsupportedReason;
    }
    if (rule.source !== 'user') {
      base['ruleSource'] = rule.source; // 旧 schema 的 source 是"源 IP"，不能混用
    }
    out.push(base);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 条件投影(旧行高级条件 → ConfigBuilder 同口径内核字段)
// ---------------------------------------------------------------------------

class RowProjection {
  fields: Record<string, Object> = {};
  /**
   * 除主条件外，"DNS 无法表达"的条件组个数(端口/端口区间/源地址/源端口/网络/协议/
   * 包名/自定义JSON/目的 IP 段)。DNS 投影只按域名匹配(ConfigBuilder.ets:938-1016)，
   * 计数 >0 表示 DNS 侧命中范围会大于路由规则(§7.4)。
   */
  nonDnsGroupCount: number = 0;
}

function setIfList(fields: Record<string, Object>, key: string, list: Array<string>): void {
  if (list.length > 0) {
    fields[key] = list;
  }
}

function setIfNumberList(fields: Record<string, Object>, key: string, list: Array<number>): void {
  if (list.length > 0) {
    fields[key] = list;
  }
}

function deepMergeInto(target: Record<string, Object>, source: Record<string, Object>): void {
  const keys = Object.keys(source);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const src = source[key];
    const dst = target[key];
    if (isRecordObject(src) && dst !== undefined && isRecordObject(dst)) {
      deepMergeInto(dst as Record<string, Object>, src as Record<string, Object>);
    } else {
      target[key] = src;
    }
  }
}

/**
 * 把旧行的非主条件投影成 ConfigBuilder 字段(AND 语义保留)。
 * 主条件组(excludeGroup)由 payload 负责，不在此重复。
 */
function projectRowConditions(row: Record<string, Object>, excludeGroup: string): RowProjection {
  const out = new RowProjection();
  const conds = parseRowConditions(row);
  const fields = out.fields;

  if (excludeGroup !== 'domains' && conds.domains.length > 0) {
    setIfList(fields, 'domain', conds.domains);
  }
  if (excludeGroup !== 'suffixes' && conds.suffixes.length > 0) {
    setIfList(fields, 'domain_suffix', conds.suffixes);
  }
  if (excludeGroup !== 'regexes' && conds.regexes.length > 0) {
    setIfList(fields, 'domain_regex', conds.regexes);
  }
  if (excludeGroup !== 'keywords' && conds.keywords.length > 0) {
    setIfList(fields, 'domain_keyword', conds.keywords);
  }
  const ruleSetRefs: Array<string> = [];
  if (excludeGroup !== 'ruleSetRefs') {
    for (let i = 0; i < conds.ruleSetRefs.length; i++) {
      ruleSetRefs.push(conds.ruleSetRefs[i]);
    }
  }
  for (let i = 0; i < conds.extraRuleSetRefs.length; i++) {
    if (ruleSetRefs.indexOf(conds.extraRuleSetRefs[i]) < 0) {
      ruleSetRefs.push(conds.extraRuleSetRefs[i]);
    }
  }
  for (let i = 0; i < conds.geoipRefs.length; i++) {
    ruleSetRefs.push(conds.geoipRefs[i]);
  }
  setIfList(fields, 'rule_set', ruleSetRefs);
  if (excludeGroup !== 'cidrs' && conds.cidrs.length > 0) {
    setIfList(fields, 'ip_cidr', conds.cidrs);
  }
  if (excludeGroup !== 'ipPrivate' && conds.ipPrivate) {
    fields['ip_is_private'] = true;
  }
  if (excludeGroup !== 'ports') {
    setIfNumberList(fields, 'port', conds.ports);
  }
  if (excludeGroup !== 'portRanges') {
    setIfList(fields, 'port_range', conds.portRanges);
  }
  setIfList(fields, 'source_ip_cidr', conds.sourceCidrs);
  setIfNumberList(fields, 'source_port', conds.sourcePorts);
  setIfList(fields, 'source_port_range', conds.sourcePortRanges);
  if (conds.network.length > 0 && excludeGroup !== 'network') {
    fields['network'] = conds.network;
  }
  setIfList(fields, 'protocol', conds.protocols);
  if (conds.packagesEnabled && conds.packages.length > 0) {
    setIfList(fields, 'process_name', conds.packages);
  }
  if (conds.config !== null) {
    deepMergeInto(fields, conds.config);
  }
  // DNS 无法表达的条件组计数(§7.4：仅可准确投影的规则参与 DNS 路由)
  let count = 0;
  if (excludeGroup !== 'cidrs' && conds.cidrs.length > 0) {
    count++;
  }
  if (excludeGroup !== 'ports' && conds.ports.length > 0) {
    count++;
  }
  if (excludeGroup !== 'portRanges' && conds.portRanges.length > 0) {
    count++;
  }
  if (conds.sourceCidrs.length > 0) {
    count++;
  }
  if (conds.sourcePorts.length > 0 || conds.sourcePortRanges.length > 0) {
    count++;
  }
  if (conds.network.length > 0 && excludeGroup !== 'network') {
    count++;
  }
  if (conds.protocols.length > 0) {
    count++;
  }
  if (conds.packagesEnabled && conds.packages.length > 0) {
    count++;
  }
  if (conds.config !== null) {
    count++;
  }
  out.nonDnsGroupCount = count;
  return out;
}

function hasProjectableCondition(rule: RoutingRule): boolean {
  if (rule.type === LEGACY_PACKAGE_TYPE) {
    return false;
  }
  if (rule.payload.trim().length > 0) {
    return true;
  }
  if (rule.type === LEGACY_ADVANCED_TYPE) {
    // 只有高级条件(source/sourcePort/protocol/config)时，看投影后是否真有内核字段
    return Object.keys(projectRowConditions(rule.legacyRow, 'advanced').fields).length > 0;
  }
  return false;
}

// ---------------------------------------------------------------------------
// compileManifest / toKernelItems
// ---------------------------------------------------------------------------

function primaryFields(type: string, payload: string): Record<string, Object> {
  const fields: Record<string, Object> = {};
  const values = splitList(payload);
  if (type === RULE_DOMAIN) {
    setIfList(fields, 'domain', values);
  } else if (type === RULE_DOMAIN_SUFFIX) {
    setIfList(fields, 'domain_suffix', values);
  } else if (type === RULE_DOMAIN_KEYWORD) {
    setIfList(fields, 'domain_keyword', values);
  } else if (type === RULE_DOMAIN_REGEX) {
    setIfList(fields, 'domain_regex', values);
  } else if (type === RULE_GEOSITE) {
    setIfList(fields, 'rule_set', values);
  } else if (type === RULE_IP_CIDR) {
    setIfList(fields, 'ip_cidr', values);
  } else if (type === RULE_GEOIP) {
    const refs: Array<string> = [];
    for (let i = 0; i < values.length; i++) {
      const v = values[i];
      if (v === 'private' || v === 'geoip:private') {
        fields['ip_is_private'] = true;
      } else {
        refs.push(v.startsWith('geoip:') ? v : `geoip:${v}`);
      }
    }
    setIfList(fields, 'rule_set', refs);
  } else if (type === RULE_PORT || type === RULE_PORT_RANGE) {
    const ports = checkPorts(payload);
    setIfNumberList(fields, 'port', ports.numbers);
    setIfList(fields, 'port_range', ports.ranges);
  } else if (type === RULE_NETWORK) {
    const net = payload.trim().toLowerCase();
    if (net === 'tcp' || net === 'udp') {
      fields['network'] = net;
    }
  } else if (type === RULE_PROCESS) {
    setIfList(fields, 'process_name', values);
  }
  return fields;
}

function canonicalExtra(extra: Record<string, Object>): string {
  const keys = Object.keys(extra).sort();
  const parts: Array<string> = [];
  for (let i = 0; i < keys.length; i++) {
    parts.push(`${keys[i]}=${JSON.stringify(extra[keys[i]])}`);
  }
  return parts.join(',');
}

export function compileManifest(rules: Array<RoutingRule>): RuleManifest {
  const manifest = new RuleManifest();
  manifest.generatedAt = Date.now();
  const ordered: Array<RoutingRule> = [];
  for (let i = 0; i < rules.length; i++) {
    ordered.push(rules[i]);
  }
  ordered.sort((a: RoutingRule, b: RoutingRule): number => {
    if (a.order !== b.order) {
      return a.order - b.order;
    }
    if (a.id === b.id) {
      return 0;
    }
    return a.id < b.id ? -1 : 1;
  });
  const items: Array<CompiledRule> = [];
  for (let i = 0; i < ordered.length; i++) {
    const rule = ordered[i];
    if (!rule.enabled || rule.unsupportedOnPlatform) {
      continue;
    }
    // 平台不支持的 packages 规则永远不编译(§8.5)；即使旧行漏标也不放行
    if (rule.type === LEGACY_PACKAGE_TYPE) {
      continue;
    }
    if (!hasProjectableCondition(rule)) {
      continue; // 与 buildCustomRule 返回 null 一致：没有匹配条件的内核规则无意义
    }
    const item = new CompiledRule();
    item.ruleId = rule.id;
    item.type = rule.type;
    item.payload = normalizePayload(rule.type, rule.payload);
    item.outbound = rule.outbound;
    const primary = derivePrimary(parseRowConditions(rule.legacyRow));
    const exclude = rule.type === LEGACY_ADVANCED_TYPE ? 'advanced' : primary.group;
    const projection = projectRowConditions(rule.legacyRow, exclude);
    item.extra = projection.fields;
    items.push(item);
  }
  manifest.items = items;
  const lines: Array<string> = [];
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    lines.push(`${it.ruleId}\u001f${it.type}\u001f${it.payload}\u001f${it.outbound}\u001f` +
      `${canonicalExtra(it.extra)}`);
  }
  manifest.hash = fnv1a32(lines.join('\u001e'));
  return manifest;
}

/**
 * 合并一个内核字段：数组做并集(去重)，对象做深合并，标量后写覆盖。
 * 主条件与旧行高级条件可能落在同一字段(例如 domain_suffix 与旧行其它后缀、
 * ip_cidr 与旧行其它网段)，不能直接覆盖，否则会丢条件。
 */
function mergeFieldValue(rule: Record<string, Object>, key: string, value: Object): void {
  const current = rule[key];
  if (current === undefined) {
    rule[key] = value;
    return;
  }
  if (Array.isArray(current) && Array.isArray(value)) {
    const merged: Array<Object> = [];
    const a = current as Array<Object>;
    const b = value as Array<Object>;
    for (let i = 0; i < a.length; i++) {
      merged.push(a[i]);
    }
    for (let j = 0; j < b.length; j++) {
      let exists = false;
      for (let k = 0; k < merged.length; k++) {
        if (JSON.stringify(merged[k]) === JSON.stringify(b[j])) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        merged.push(b[j]);
      }
    }
    rule[key] = merged;
    return;
  }
  if (isRecordObject(current) && isRecordObject(value)) {
    deepMergeInto(current as Record<string, Object>, value as Record<string, Object>);
    rule[key] = current;
    return;
  }
  rule[key] = value;
}

/** manifest → 可直接给 sing-box route.rules 的 JSON(字段名与 buildCustomRule 一致)。 */
export function toKernelItems(manifest: RuleManifest): Array<Record<string, Object>> {
  const out: Array<Record<string, Object>> = [];
  for (let i = 0; i < manifest.items.length; i++) {
    const item = manifest.items[i];
    const rule = primaryFields(item.type, item.payload);
    // 合并旧行高级条件(AND)：必须在出站字段之前，避免覆盖同名字段时语义漂移
    const extraKeys = Object.keys(item.extra);
    for (let k = 0; k < extraKeys.length; k++) {
      const key = extraKeys[k];
      if (key === 'outbound' || key === 'action') {
        continue; // 出站由 item.outbound 决定，不允许旧行覆盖
      }
      mergeFieldValue(rule, key, item.extra[key]);
    }
    if (item.outbound === RULE_OUT_BLOCK) {
      rule['action'] = 'reject';
    } else if (item.outbound.length > 0) {
      rule['outbound'] = item.outbound;
    }
    if (Object.keys(rule).length > 0) {
      out.push(rule);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 校验
// ---------------------------------------------------------------------------

/** 同类型重叠：domain_suffix 被完全包含 / domain_keyword 子串 / IPv4 CIDR 包含。 */
export function detectOverlap(rules: Array<RoutingRule>): Array<RuleIssue> {
  const issues: Array<RuleIssue> = [];
  const enabled: Array<RoutingRule> = [];
  for (let i = 0; i < rules.length; i++) {
    if (rules[i].enabled && rules[i].type !== LEGACY_PACKAGE_TYPE) {
      enabled.push(rules[i]);
    }
  }
  const reported = new Set<string>();
  for (let i = 0; i < enabled.length; i++) {
    for (let j = 0; j < enabled.length; j++) {
      if (i === j) {
        continue;
      }
      const a = enabled[i]; // 覆盖者(更宽)
      const b = enabled[j]; // 被覆盖者(更窄)
      if (a.type !== b.type) {
        continue;
      }
      if (a.type !== RULE_DOMAIN_SUFFIX && a.type !== RULE_DOMAIN_KEYWORD &&
        a.type !== RULE_IP_CIDR) {
        continue;
      }
      const detail = overlapDetail(a, b);
      if (detail.length === 0) {
        continue;
      }
      // 相同值的规则对会双向命中：同一对只报一次
      const pairKey = `${a.id}\u001f${b.id}`;
      const reverseKey = `${b.id}\u001f${a.id}`;
      if (reported.has(pairKey) || reported.has(reverseKey)) {
        continue;
      }
      reported.add(pairKey);
      const issue = new RuleIssue();
      issue.ruleId = b.id;
      issue.code = ISSUE_OVERLAP;
      issue.detail = detail;
      issues.push(issue);
    }
  }
  return issues;
}

/** 若 a 完全覆盖 b 的某个值，返回说明；否则空串。 */
function overlapDetail(a: RoutingRule, b: RoutingRule): string {
  const aValues = splitList(a.payload);
  const bValues = splitList(b.payload);
  for (let i = 0; i < bValues.length; i++) {
    const bv = bValues[i].toLowerCase();
    for (let j = 0; j < aValues.length; j++) {
      const av = aValues[j].toLowerCase();
      if (av === bv) {
        if (a.type === RULE_IP_CIDR) {
          // 完全相同不算"包含"(dup_rule 管这个)
          continue;
        }
        return `值 ${bv} 与规则 ${a.id} 重复`;
      }
      if (a.type === RULE_DOMAIN_SUFFIX && bv.endsWith(`.${av}`)) {
        return `后缀 ${bv} 已被规则 ${a.id} 的后缀 ${av} 覆盖`;
      }
      if (a.type === RULE_DOMAIN_KEYWORD && bv.indexOf(av) >= 0) {
        return `关键词 ${bv} 已包含规则 ${a.id} 的关键词 ${av}`;
      }
      if (a.type === RULE_IP_CIDR) {
        const detail = ipv4Containment(av, bv);
        if (detail.length > 0) {
          return `CIDR ${bv} 已被规则 ${a.id} 的 ${av} 覆盖`;
        }
      }
    }
  }
  return '';
}

/** IPv4 网段包含(IPv6 不做包含判断，避免错误的位运算；精确重复由 dup_rule 覆盖)。 */
function ipv4Containment(outer: string, inner: string): string {
  const a = parseAddress(outer);
  const b = parseAddress(inner);
  if (!a.valid || !b.valid || !a.v4 || !b.v4) {
    return '';
  }
  const aParts = outer.split('/');
  const bParts = inner.split('/');
  const aPrefix = aParts.length > 1 ? Number(aParts[1]) : 32;
  const bPrefix = bParts.length > 1 ? Number(bParts[1]) : 32;
  if (aPrefix > bPrefix) {
    return '';
  }
  const aIp = ipv4ToNumber(aParts[0]);
  const bIp = ipv4ToNumber(bParts[0]);
  if (aIp < 0 || bIp < 0) {
    return '';
  }
  const mask = aPrefix === 0 ? 0 : (0xffffffff << (32 - aPrefix)) >>> 0;
  if ((aIp & mask) === (bIp & mask)) {
    return 'contained';
  }
  return '';
}

/** 校验一条规则的值(主条件 + 旧行投影里的高级条件)。 */
function validateRuleValues(rule: RoutingRule, validation: RuleValidation): void {
  const add = (code: string, detail: string): void => {
    const issue = new RuleIssue();
    issue.ruleId = rule.id;
    issue.code = code;
    issue.detail = detail;
    validation.errors.push(issue);
  };
  const type = rule.type;
  if (type === LEGACY_PACKAGE_TYPE) {
    return; // 待处理旧规则：原文保留，不参与常规校验(§8.5)
  }
  const values = splitList(rule.payload);
  if (values.length === 0 && type !== LEGACY_ADVANCED_TYPE) {
    add(ISSUE_EMPTY_PAYLOAD, '匹配值为空：内核不会生成任何匹配条件');
  }
  if (type === RULE_IP_CIDR) {
    for (let i = 0; i < values.length; i++) {
      const check = parseAddress(values[i]);
      if (!check.valid) {
        add(ISSUE_INVALID_CIDR, `非法 IP/CIDR：${values[i]}`);
      }
    }
  }
  if (type === RULE_PORT || type === RULE_PORT_RANGE) {
    const ports = checkPorts(rule.payload);
    if (ports.invalid.length > 0) {
      add(ISSUE_INVALID_PORT, `非法端口/区间：${ports.invalid.join(',')}(端口范围 1-65535)`);
    }
  }
  if (type === RULE_DOMAIN_REGEX) {
    for (let i = 0; i < values.length; i++) {
      const check = checkRegex(values[i]);
      if (!check.ok) {
        add(ISSUE_INVALID_REGEX, `正则不可编译：${values[i]}(${check.message})`);
      }
    }
  }
  // 旧行高级条件：先按原文校验非法端口(parseRowConditions 会丢弃非法 token，
  // 只查投影结果会漏报)，再查投影出的 IP 段。
  const legacyPortText = strField(rule.legacyRow, 'port');
  if (legacyPortText.trim().length > 0) {
    const legacyPorts = checkPorts(legacyPortText);
    if (legacyPorts.invalid.length > 0) {
      add(ISSUE_INVALID_PORT, `旧行端口含非法值：${legacyPorts.invalid.join(',')}(端口范围 1-65535)`);
    }
  }
  const legacySourcePortText = strField(rule.legacyRow, 'sourcePort');
  if (legacySourcePortText.trim().length > 0) {
    const legacySourcePorts = checkPorts(legacySourcePortText);
    if (legacySourcePorts.invalid.length > 0) {
      add(ISSUE_INVALID_PORT, `旧行源端口含非法值：${legacySourcePorts.invalid.join(',')}`);
    }
  }
  const projection = projectRowConditions(rule.legacyRow, 'advanced');
  const extraCidrs: Array<string> = [];
  const extraIp = projection.fields['ip_cidr'];
  if (extraIp !== undefined) {
    const list = extraIp as Array<string>;
    for (let i = 0; i < list.length; i++) {
      extraCidrs.push(list[i]);
    }
  }
  const sourceCidr = projection.fields['source_ip_cidr'];
  if (sourceCidr !== undefined) {
    const list = sourceCidr as Array<string>;
    for (let i = 0; i < list.length; i++) {
      extraCidrs.push(list[i]);
    }
  }
  for (let i = 0; i < extraCidrs.length; i++) {
    if (!parseAddress(extraCidrs[i]).valid) {
      add(ISSUE_INVALID_CIDR, `旧行高级条件含非法 IP/CIDR：${extraCidrs[i]}`);
    }
  }
}

export function validateRules(rules: Array<RoutingRule>, knownRuleSetIds: Array<string>): RuleValidation {
  const validation = new RuleValidation();
  const known = new Set<string>();
  for (let i = 0; i < knownRuleSetIds.length; i++) {
    known.add(knownRuleSetIds[i]);
  }
  const dupKeys = new Map<string, string>(); // key → 首次出现的 ruleId
  for (let i = 0; i < rules.length; i++) {
    const rule = rules[i];
    if (rule.type === LEGACY_PACKAGE_TYPE || rule.unsupportedOnPlatform) {
      validation.legacyCount++;
      continue; // §8.5：旧规则单独处理，不阻塞其它规则校验
    }
    validateRuleValues(rule, validation);
    if (rule.type === RULE_GEOSITE || rule.type === RULE_GEOIP) {
      const refs = splitList(rule.payload);
      for (let r = 0; r < refs.length; r++) {
        const ref = refs[r];
        const expected = rule.type === RULE_GEOIP
          ? (ref === 'private' || ref === 'geoip:private' ? 'geoip:private'
            : (ref.startsWith('geoip:') ? ref : `geoip:${ref}`))
          : ref;
        if (expected === 'geoip:private') {
          continue; // ip_is_private 不需要规则集定义
        }
        const ok = known.has(expected) || (ref.startsWith('geosite:') && known.has(ref));
        if (!ok) {
          const issue = new RuleIssue();
          issue.ruleId = rule.id;
          issue.code = ISSUE_GEOSITE_MISSING;
          issue.detail = `引用的规则集不存在：${expected}(已知规则集 ${knownRuleSetIds.length} 个)`;
          validation.errors.push(issue);
        }
      }
    }
    if (rule.enabled) {
      const key = `${rule.type}\u001f${normalizePayload(rule.type, rule.payload)}\u001f${rule.outbound}`;
      const first = dupKeys.get(key);
      if (first === undefined) {
        dupKeys.set(key, rule.id);
      } else {
        const issue = new RuleIssue();
        issue.ruleId = rule.id;
        issue.code = ISSUE_DUP_RULE;
        issue.detail = `与规则 ${first} 的类型/匹配值/出站完全相同`;
        validation.errors.push(issue);
      }
    }
  }
  const overlaps = detectOverlap(rules);
  for (let i = 0; i < overlaps.length; i++) {
    validation.warnings.push(overlaps[i]);
  }
  return validation;
}

// ---------------------------------------------------------------------------
// DNS 投影校验(W13 明确要求)
// ---------------------------------------------------------------------------
//
// 判定依据(每条都对应 ConfigBuilder 现状，未虚构)：
// A. dns_loop_risk —— 直连 DNS 服务器用域名(DoH/DoT)时自举回环。
//    `buildDnsServer('local', s.directDns, '')`(ConfigBuilder.ets:917)把 directDns 作为
//    `local` 服务器；`route.default_domain_resolver` 指向 `local`(ConfigBuilder.ets:1223-1226)，
//    即"所有出站服务器域名一律经 local 解析"(注释见 :1040-1041)。若 directDns 自己是域名，
//    解析它又需要 local ⇒ 自举回环。ConfigBuilder 只在测速探针里规避过这个风险(注释 :1328-1342)，
//    主配置没有兜底。注意：代理服务器域名本来就统一走 local 解析(:1220-1226)，
//    因此"直连域名规则命中代理服务器域名"在当前实现里只是冗余、不构成回环，故不产出告警
//    (按 W13「宁可不出，也不虚构」)。
// B. dns_routing_off —— DNS 路由关闭时用户规则不参与 DNS。
//    用户 DNS 规则只在 `s.mode==='rule' && s.dnsRouting` 时生成(ConfigBuilder.ets:938)；
//    关闭后 `dns.final='remote'`(:1045)，直连规则里的域名仍由 remote 解析(拿不到就近 CDN IP)。
// C. dns_projection_broader —— 有不可投影条件时，DNS 规则比路由规则更宽(§7.4 禁止)。
//    DNS 用户规则只读 `r.domains`(ConfigBuilder.ets:940)，port/network/protocol/source/
//    packages 等条件被丢弃(:938-1016)，于是 DNS 侧命中范围大于路由侧。
// D. dns_projection_missing —— 纯 IP 条件规则没有 DNS 投影。
//    `r.domains.trim().length === 0` 直接跳过(:940)，ip_cidr 规则不产生 DNS 规则，
//    其 DNS 查询继续走 final=remote(:1045)。
// fakeDns 只影响 proxy 规则的服务器选择(:1004-1011)与 tun-in 兜底(:1021-1029)，
// 不改变上述判定，故不单独产出问题(避免虚构)。

/** 从 DNS 地址串取 host(scheme://host:port/path、裸 IP、[v6]:port)。 */
function hostOf(address: string): string {
  let text = address.trim();
  const schemeIdx = text.indexOf('://');
  if (schemeIdx >= 0) {
    text = text.substring(schemeIdx + 3);
  }
  const slash = text.indexOf('/');
  if (slash >= 0) {
    text = text.substring(0, slash);
  }
  if (text.startsWith('[')) {
    const end = text.indexOf(']');
    if (end > 0) {
      return text.substring(1, end);
    }
  }
  const colon = text.lastIndexOf(':');
  if (colon > 0 && text.indexOf(':') === colon) {
    return text.substring(0, colon); // host:port
  }
  return text;
}

/** host 是否为 IP 字面量(是 → 不需要自举解析)。 */
function isIpLiteralHost(host: string): boolean {
  if (host.length === 0) {
    return false;
  }
  if (checkIpv4(host)) {
    return true;
  }
  return checkIpv6(host);
}

function dnsIssue(ruleId: string, code: string, detail: string): RuleIssue {
  const issue = new RuleIssue();
  issue.ruleId = ruleId;
  issue.code = code;
  issue.detail = detail;
  return issue;
}

export function validateDnsProjection(rules: Array<RoutingRule>,
  settings: DnsProjectionSettings): Array<RuleIssue> {
  const issues: Array<RuleIssue> = [];
  // A. 直连 DNS 自身用域名 → 自举回环(与规则无关，是配置级风险；ruleId 置空)
  const directHost = hostOf(settings.directDns);
  if (directHost.length > 0 && !isIpLiteralHost(directHost)) {
    issues.push(dnsIssue('', ISSUE_DNS_LOOP,
      `直连 DNS 使用域名 ${directHost}：route.default_domain_resolver 指向 local(ConfigBuilder.ets:1223-1226)，` +
      `解析该域名本身又需要 local，形成自举回环；请改用 IP 形式(如 tls://223.5.5.5)`));
  }
  // 逐条规则
  for (let i = 0; i < rules.length; i++) {
    const rule = rules[i];
    if (!rule.enabled || rule.unsupportedOnPlatform ||
      rule.type === LEGACY_PACKAGE_TYPE || rule.type === LEGACY_ADVANCED_TYPE) {
      continue;
    }
    const isDomainType = DOMAIN_TYPES.indexOf(rule.type) >= 0;
    const isDirect = rule.outbound === RULE_OUT_DIRECT;
    if (isDomainType) {
      if (!settings.dnsRouting) {
        // B. DNS 路由关闭：直连 DNS 不参与 CN 分流(如实反映现状)
        if (isDirect) {
          issues.push(dnsIssue(rule.id, ISSUE_DNS_ROUTING_OFF,
            'DNS 路由已关闭：本直连规则的域名仍由 remote DNS 解析(ConfigBuilder.ets:938 门控、:1045 final)，' +
            '不会使用直连 DNS，可能拿到非就近 CDN 地址'));
        }
      } else {
        // C. 有不可投影条件 → DNS 规则比路由规则更宽
        const projection = projectRowConditions(rule.legacyRow, 'advanced');
        if (projection.nonDnsGroupCount > 0) {
          issues.push(dnsIssue(rule.id, ISSUE_DNS_PROJECTION_BROADER,
            '本规则含 DNS 无法表达的条件(端口/网络/协议/源地址/包名/目的IP段/自定义JSON)：' +
            'DNS 侧只按域名匹配(ConfigBuilder.ets:938-1016)，命中范围大于路由规则(§7.4)'));
        }
      }
    } else if (settings.dnsRouting && isDirect && !isDomainType) {
      // D. 纯 IP 条件没有 DNS 投影
      if (rule.type === RULE_IP_CIDR || rule.type === RULE_GEOIP || rule.type === RULE_PORT ||
        rule.type === RULE_PORT_RANGE || rule.type === RULE_NETWORK) {
        issues.push(dnsIssue(rule.id, ISSUE_DNS_PROJECTION_MISSING,
          '本规则没有域名条件：用户 DNS 规则要求 domains 非空(ConfigBuilder.ets:940)，' +
          '该规则不参与 DNS，查询仍走 remote(:1045)'));
      }
    }
  }
  return issues;
}

/** §8.5：旧包名规则的处理方式(UI 显式选择，绝不自动转换)。 */
export function legacyHandlingOptions(): Array<string> {
  return ['pause', 'convert', 'delete'];
}
