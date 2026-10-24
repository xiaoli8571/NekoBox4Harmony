/**
 * RuleEditor —— 规则编辑器纯模型（P4/W14，REDESIGN-PLAN-2026-10-23.md §7.2/§7.3/§7.4、§8.5）。
 *
 * 定位：页面只渲染、不重算；表单状态、逐项校验、目标选择、摘要/条件计数、排序、旧包名规则处理
 * 与 AND/OR 组合全部在这里，页面（P5/W17）直接消费。
 *
 * 与 RoutingRules 的分工：
 *  - RoutingRules 是**持久化/编译**模型（RoutingRule + legacyRow + manifest + validateRules）；
 *  - 本模型是**编辑态**模型（RuleForm），formToRule/formFromRule 负责两者互转；
 *  - 高级条件（目的端口/源地址/源端口/网络/协议/自定义 JSON）在 RoutingRule 上没有独立字段，
 *    统一存进 legacyRow 的旧键位（port/source/sourcePort/network/protocol/config）——
 *    这正是 RoutingRules.toRawRows / compileManifest 读取 AND 条件的位置，保证条件不丢、
 *    且内核侧「同一规则对象内不同字段 = AND」的语义与旧行完全一致。
 *
 * 纯模型：无 I/O、无 @ohos 依赖。
 */
import { Profile, ProfileGroup } from './Profile';
import {
  RoutingRule, RULE_DOMAIN, RULE_DOMAIN_SUFFIX, RULE_DOMAIN_KEYWORD, RULE_DOMAIN_REGEX,
  RULE_GEOSITE, RULE_IP_CIDR, RULE_GEOIP, RULE_PORT, RULE_PORT_RANGE, RULE_NETWORK, RULE_PROCESS,
  LEGACY_PACKAGE_TYPE, LEGACY_ADVANCED_TYPE,
  RULE_OUT_DIRECT, RULE_OUT_PROXY, RULE_OUT_BLOCK,
  ISSUE_EMPTY_PAYLOAD, ISSUE_INVALID_CIDR, ISSUE_INVALID_PORT, ISSUE_INVALID_REGEX, ISSUE_GEOSITE_MISSING,
  normalizePayload, newRuleId, legacyHandlingOptions
} from './RoutingRules';

// ---------------------------------------------------------------------------
// 校验码（与 RoutingRules.ISSUE_* 同名项直接复用，新增项只在本文件定义）
// ---------------------------------------------------------------------------

export const FIELD_ERROR_INVALID_DOMAIN: string = 'invalid_domain';
export const FIELD_ERROR_INVALID_JSON: string = 'invalid_json';
export const FIELD_ERROR_INVALID_NETWORK: string = 'invalid_network';
export const FIELD_ERROR_INVALID_OUTBOUND: string = 'invalid_outbound';
export const FIELD_ERROR_TARGET_MISSING: string = 'target_missing';
export const FIELD_ERROR_INVALID_TYPE: string = 'invalid_type';
export const FIELD_ERROR_INVALID_MATCH_MODE: string = 'invalid_match_mode';
export const FIELD_WARN_AND_SINGLE: string = 'and_needs_two_conditions';
export const SEVERITY_ERROR: string = 'error';
export const SEVERITY_WARNING: string = 'warning';

// 旧行条件键（RoutingRules.parseRowConditions 的词汇表）
const LEG_PORT: string = 'port';
const LEG_SOURCE: string = 'source';
const LEG_SOURCE_PORT: string = 'sourcePort';
const LEG_NETWORK: string = 'network';
const LEG_PROTOCOL: string = 'protocol';
const LEG_CONFIG: string = 'config';
const LEG_PACKAGES: string = 'packages';
const LEG_PACKAGES_ENABLED: string = 'packagesEnabled';
const LEG_DOMAINS: string = 'domains';
const LEG_IP: string = 'ip';

/** 摘要/条件计数时遍历的旧行条件键（顺序=展示优先级）。 */
const CONDITION_KEYS: Array<string> = [
  LEG_IP, LEG_PORT, LEG_SOURCE, LEG_SOURCE_PORT, LEG_NETWORK, LEG_PROTOCOL, LEG_PACKAGES, LEG_CONFIG
];

// ---------------------------------------------------------------------------
// 表单状态
// ---------------------------------------------------------------------------

/** 编辑器表单状态（纯数据；页面直接双向绑定）。 */
export class RuleForm {
  /** 仅供 UI 展示的标题（RoutingRule 不存名字） */
  name: string = '';
  type: string = RULE_DOMAIN_SUFFIX;
  payload: string = '';
  outbound: string = RULE_OUT_PROXY;
  enabled: boolean = true;
  /** 高级条件区是否展开 */
  advancedOpen: boolean = false;
  destPort: string = '';
  sourceIpCidr: string = '';
  sourcePort: string = '';
  network: string = '';
  protocol: string = '';
  customJson: string = '';
  /** 同一规则内不同字段的组合方式：'and'=同时满足（sing-box 单规则多字段语义）；'or'=平铺（同字段多值 OR） */
  matchMode: string = 'or';
}

/** 逐项校验结果（field 定位到表单字段；severity=error 阻断保存，warning 仅提示）。 */
export class FieldError {
  field: string = '';
  code: string = '';
  detail: string = '';
  severity: string = SEVERITY_ERROR;
}

/** 出站目标（direct/proxy/reject 固定项 + 指定节点/分组）。 */
export class RuleTarget {
  /** 'direct' | 'proxy' | 'reject' | 'profile' | 'group' */
  kind: string = 'proxy';
  /** 写入 RoutingRule.outbound 的值：direct/proxy/block/profile:<id>/group:<id> */
  id: string = RULE_OUT_PROXY;
  label: string = '';
  available: boolean = true;
}

/** 旧包名/平台不支持规则的处理视图（§8.5）。 */
export class LegacyRuleView {
  rule: RoutingRule = new RoutingRule();
  summary: string = '';
  /** 'pause' | 'convert' | 'delete'（来自 RoutingRules.legacyHandlingOptions） */
  actionOptions: Array<string> = [];
}

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------

/** 与 ConfigBuilder.splitRuleList / RoutingRules.splitList 同口径：逗号/换行分隔、trim、去空。 */
function splitItems(text: string): Array<string> {
  const parts = text.split(/[,\r\n]/);
  const out: Array<string> = [];
  for (let i = 0; i < parts.length; i++) {
    const t = parts[i].trim();
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}

function strOf(row: Record<string, Object>, key: string): string {
  const v = row[key];
  if (typeof v === 'string') {
    return v as string;
  }
  if (v === undefined || v === null) {
    return '';
  }
  return `${v}`;
}

function boolOf(row: Record<string, Object>, key: string, dflt: boolean): boolean {
  const v = row[key];
  return typeof v === 'boolean' ? (v as boolean) : dflt;
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

function cloneRule(r: RoutingRule): RoutingRule {
  const out = new RoutingRule();
  out.id = r.id;
  out.type = r.type;
  out.payload = r.payload;
  out.outbound = r.outbound;
  out.enabled = r.enabled;
  out.order = r.order;
  out.source = r.source;
  out.unsupportedOnPlatform = r.unsupportedOnPlatform;
  out.unsupportedReason = r.unsupportedReason;
  out.legacyRow = cloneRow(r.legacyRow);
  return out;
}

function makeError(field: string, code: string, detail: string, severity: string): FieldError {
  const e = new FieldError();
  e.field = field;
  e.code = code;
  e.detail = detail;
  e.severity = severity;
  return e;
}

function makeTarget(kind: string, id: string, label: string, available: boolean): RuleTarget {
  const t = new RuleTarget();
  t.kind = kind;
  t.id = id;
  t.label = label;
  t.available = available;
  return t;
}

function isFormType(type: string): boolean {
  return type === RULE_DOMAIN || type === RULE_DOMAIN_SUFFIX || type === RULE_DOMAIN_KEYWORD ||
    type === RULE_DOMAIN_REGEX || type === RULE_GEOSITE || type === RULE_IP_CIDR ||
    type === RULE_GEOIP || type === RULE_PORT || type === RULE_PORT_RANGE ||
    type === RULE_NETWORK || type === RULE_PROCESS;
}

// ---------------------------------------------------------------------------
// 表单 ↔ 规则
// ---------------------------------------------------------------------------

/** 空白表单（新建规则的初始状态）。 */
export function emptyForm(): RuleForm {
  const f = new RuleForm();
  f.type = RULE_DOMAIN_SUFFIX;
  f.outbound = RULE_OUT_PROXY;
  f.enabled = true;
  f.matchMode = 'or';
  return f;
}

/**
 * 规则 → 表单：
 *  - 主条件（type/payload）直接映射；
 *  - legacyRow 里的高级条件填进 destPort/sourceIpCidr/sourcePort/network/protocol/customJson；
 *  - matchMode：条件数 ≥2（不同字段 AND）→ 'and'，否则 'or'（同字段多值 OR）；
 *  - advancedOpen 跟随 matchMode，方便用户看到被折叠的条件。
 */
export function formFromRule(r: RoutingRule): RuleForm {
  const f = new RuleForm();
  f.type = r.type;
  f.payload = r.payload;
  f.outbound = r.outbound;
  f.enabled = r.enabled;
  f.destPort = strOf(r.legacyRow, LEG_PORT);
  f.sourceIpCidr = strOf(r.legacyRow, LEG_SOURCE);
  f.sourcePort = strOf(r.legacyRow, LEG_SOURCE_PORT);
  f.network = strOf(r.legacyRow, LEG_NETWORK);
  f.protocol = strOf(r.legacyRow, LEG_PROTOCOL);
  const cfg = r.legacyRow[LEG_CONFIG];
  if (typeof cfg === 'string') {
    f.customJson = cfg as string;
  } else if (cfg === undefined || cfg === null) {
    f.customJson = '';
  } else {
    f.customJson = JSON.stringify(cfg);
  }
  f.matchMode = conditionCount(r) >= 2 ? 'and' : 'or';
  f.advancedOpen = f.matchMode === 'and';
  return f;
}

/**
 * 把旧行键写成表单文本：空值=删除该条件（清空高级条件必须真的移除，不能留空串）。
 * ArkTS 禁止 `delete`(arkts-no-delete) ⇒ 改为「返回新行」的纯函数：返回不带该键的行(键存在时)
 * 或原行(键不存在/要写入时原样返回,写入由调用方接着做)。
 */
function rowWithoutKey(row: Record<string, Object>, key: string): Record<string, Object> {
  if (row[key] === undefined) {
    return row;
  }
  const out: Record<string, Object> = {};
  const keys = Object.keys(row);
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] !== key) {
      out[keys[i]] = row[keys[i]];
    }
  }
  return out;
}

function applyLegacyText(row: Record<string, Object>, which: string, text: string): Record<string, Object> {
  const t = text.trim();
  const key = which === LEG_PORT ? 'port'
    : which === LEG_SOURCE ? 'source'
      : which === LEG_SOURCE_PORT ? 'sourcePort'
        : which === LEG_NETWORK ? 'network'
          : which === LEG_PROTOCOL ? 'protocol' : 'config';
  if (t.length === 0) {
    return rowWithoutKey(row, key); // 空值=删除该条件(必须真的移除,不能留空串)
  }
  row[key] = t;
  return row;
}

/**
 * 表单 → 规则：
 *  - id/order/source/unsupportedOnPlatform/unsupportedReason 一律沿用 base（新建时生成 id、order=0、source=user）；
 *  - payload 按类型 normalize（正则保留原文，域名小写，端口去前导零）；
 *  - 高级条件写进 legacyRow 旧键位（RoutingRules 的读侧口径），空条件删除键。
 */
export function formToRule(f: RuleForm, base: RoutingRule | null): RoutingRule {
  let rule: RoutingRule;
  if (base === null) {
    rule = new RoutingRule();
    rule.id = newRuleId(f.type);
    rule.order = 0;
    rule.source = 'user';
  } else {
    rule = cloneRule(base);
  }
  rule.type = f.type;
  rule.payload = normalizePayload(f.type, f.payload);
  rule.outbound = f.outbound;
  rule.enabled = f.enabled;
  let legacy = cloneRow(rule.legacyRow);
  legacy = applyLegacyText(legacy, LEG_PORT, f.destPort);
  legacy = applyLegacyText(legacy, LEG_SOURCE, f.sourceIpCidr);
  legacy = applyLegacyText(legacy, LEG_SOURCE_PORT, f.sourcePort);
  legacy = applyLegacyText(legacy, LEG_NETWORK, f.network);
  legacy = applyLegacyText(legacy, LEG_PROTOCOL, f.protocol);
  legacy = applyLegacyText(legacy, LEG_CONFIG, f.customJson);
  rule.legacyRow = legacy;
  return rule;
}

// ---------------------------------------------------------------------------
// 校验（逐项定位，§7.3）
// ---------------------------------------------------------------------------

function isAsciiAlnum(code: number): boolean {
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

/** 域名 label：首尾必须字母/数字/非 ASCII，中间允许连字符。 */
function isValidDomainLabel(label: string): boolean {
  if (label.length === 0 || label.length > 63) {
    return false;
  }
  for (let i = 0; i < label.length; i++) {
    const code = label.charCodeAt(i);
    const alnum = isAsciiAlnum(code) || code >= 128;
    if (i === 0 || i === label.length - 1) {
      if (!alnum) {
        return false;
      }
    } else if (!alnum && label.charAt(i) !== '-') {
      return false;
    }
  }
  return true;
}

/** 完整域名（domain 全匹配）：label 合法、无通配符。 */
function isValidDomainName(name: string): boolean {
  if (name.length === 0 || name.length > 253) {
    return false;
  }
  if (name.indexOf('*') >= 0) {
    return false;
  }
  const labels = name.split('.');
  for (let i = 0; i < labels.length; i++) {
    if (!isValidDomainLabel(labels[i])) {
      return false;
    }
  }
  return true;
}

function isIpv4Text(text: string): boolean {
  const parts = text.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (let i = 0; i < parts.length; i++) {
    if (!/^\d{1,3}$/.test(parts[i])) {
      return false;
    }
    const n = Number(parts[i]);
    if (n < 0 || n > 255) {
      return false;
    }
  }
  return true;
}

function isIpv6Text(text: string): boolean {
  const lower = text.toLowerCase();
  if (lower.indexOf(':') < 0) {
    return false;
  }
  const firstDouble = lower.indexOf('::');
  if (firstDouble >= 0 && lower.indexOf('::', firstDouble + 2) >= 0) {
    return false;
  }
  const parts = lower.split(':');
  let filled = 0;
  let compressed = false;
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    if (part.length === 0) {
      compressed = true;
      continue;
    }
    if (part.indexOf('.') >= 0) {
      if (!isIpv4Text(part)) {
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
  return compressed ? filled <= 7 : filled === 8;
}

/** CIDR：IPv4 0-32 / IPv6 0-128，裸地址也接受（= /32、/128）。 */
function isValidCidrText(item: string): boolean {
  const slash = item.indexOf('/');
  if (slash < 0) {
    return isIpv4Text(item) || isIpv6Text(item);
  }
  const addr = item.substring(0, slash);
  const prefixText = item.substring(slash + 1);
  if (prefixText.length === 0 || !/^\d{1,3}$/.test(prefixText)) {
    return false;
  }
  const prefix = Number(prefixText);
  if (isIpv4Text(addr)) {
    return prefix >= 0 && prefix <= 32;
  }
  if (isIpv6Text(addr)) {
    return prefix >= 0 && prefix <= 128;
  }
  return false;
}

/** 单端口 / 开区间（:1000、1000:、1000:2000）；单端口 1-65535。 */
function isValidPortToken(token: string): boolean {
  if (/^\d+$/.test(token)) {
    const n = Number(token);
    return n >= 1 && n <= 65535;
  }
  const parts = token.split(':');
  if (parts.length !== 2) {
    return false;
  }
  const startText = parts[0];
  const endText = parts[1];
  if (startText.length === 0 && endText.length === 0) {
    return false;
  }
  if (startText.length > 0 && !/^\d+$/.test(startText)) {
    return false;
  }
  if (endText.length > 0 && !/^\d+$/.test(endText)) {
    return false;
  }
  if (startText.length > 0) {
    const s = Number(startText);
    if (s < 1 || s > 65535) {
      return false;
    }
  }
  if (endText.length > 0) {
    const e = Number(endText);
    if (e < 1 || e > 65535) {
      return false;
    }
  }
  if (startText.length > 0 && endText.length > 0 && Number(startText) > Number(endText)) {
    return false;
  }
  return true;
}

/** 正则编译检查；返回 '' 表示可编译，否则返回原文错误消息（保留正则本身不动）。 */
function regexErrorOf(pattern: string): string {
  try {
    const re = new RegExp(pattern);
    if (re.source.length === 0) {
      return '';
    }
    return '';
  } catch (e) {
    return (e as Error).message;
  }
}

/** JSON 文本必须是对象；返回 '' 或错误消息。 */
function jsonErrorOf(text: string): string {
  try {
    const parsed = JSON.parse(text) as Object;
    if (!isRecordObject(parsed)) {
      return 'JSON 必须是对象（不能是数组、字符串或 null）';
    }
    return '';
  } catch (e) {
    return `JSON 语法错误：${(e as Error).message}`;
  }
}

function parseJsonObject(text: string): Record<string, Object> | null {
  try {
    const parsed = JSON.parse(text) as Object;
    if (!isRecordObject(parsed)) {
      return null;
    }
    return parsed as Record<string, Object>;
  } catch (e) {
    return null;
  }
}

function hasPortText(text: string): boolean {
  return text.trim().length > 0;
}

function outboundIssue(outbound: string, targets: Array<RuleTarget>): string {
  if (outbound === RULE_OUT_DIRECT || outbound === RULE_OUT_PROXY ||
    outbound === RULE_OUT_BLOCK || outbound === 'reject') {
    return '';
  }
  if (outbound.startsWith('profile:')) {
    const id = outbound.substring('profile:'.length);
    return findUsableTarget(targets, 'profile', id) ? '' : FIELD_ERROR_TARGET_MISSING;
  }
  if (outbound.startsWith('group:')) {
    const id = outbound.substring('group:'.length);
    return findUsableTarget(targets, 'group', id) ? '' : FIELD_ERROR_TARGET_MISSING;
  }
  return FIELD_ERROR_TARGET_MISSING;
}

function findUsableTarget(targets: Array<RuleTarget>, kind: string, id: string): boolean {
  for (let i = 0; i < targets.length; i++) {
    const t = targets[i];
    if (t.kind === kind && t.id === id && t.available) {
      return true;
    }
  }
  return false;
}

/** 表单条件个数（主匹配值 + 每个高级字段各算 1）。 */
function conditionCountForm(f: RuleForm): number {
  let n = 0;
  if (splitItems(f.payload).length > 0) {
    n++;
  }
  if (hasPortText(f.destPort)) {
    n++;
  }
  if (f.sourceIpCidr.trim().length > 0) {
    n++;
  }
  if (hasPortText(f.sourcePort)) {
    n++;
  }
  if (f.network.trim().length > 0) {
    n++;
  }
  if (f.protocol.trim().length > 0) {
    n++;
  }
  if (f.customJson.trim().length > 0) {
    n++;
  }
  return n;
}

function isTcpUdp(text: string): boolean {
  return text === 'tcp' || text === 'udp';
}

/**
 * 逐项校验（§7.3）：
 *  - payload：非空；按类型校验域名 label/全匹配、CIDR（v4+v6）、端口与开区间、
 *    正则可编译（返回原文错误消息）、规则集引用存在；
 *  - 高级字段：目的/源端口、源 CIDR、network、自定义 JSON（必须是对象）；
 *  - outbound：固定项或 profile:/group: 引用必须在 targets 里且可用；
 *  - matchMode==='and' 且条件 <2 → warning（severity=warning，不阻断保存）。
 * 返回顺序：payload → destPort → sourceIpCidr → sourcePort → network → customJson → outbound → matchMode。
 */
export function validateForm(f: RuleForm, knownRuleSetIds: Array<string>, targets: Array<RuleTarget>): Array<FieldError> {
  const out: Array<FieldError> = [];
  const items = splitItems(f.payload);
  if (!isFormType(f.type)) {
    out.push(makeError('type', FIELD_ERROR_INVALID_TYPE,
      `未知规则类型：${f.type}（旧包名/高级规则请先转换）`, SEVERITY_ERROR));
  }
  if (items.length === 0) {
    out.push(makeError('payload', ISSUE_EMPTY_PAYLOAD, '匹配值为空，至少填一项', SEVERITY_ERROR));
  } else {
    if (f.type === RULE_DOMAIN) {
      for (let i = 0; i < items.length; i++) {
        if (!isValidDomainName(items[i])) {
          out.push(makeError('payload', FIELD_ERROR_INVALID_DOMAIN,
            `无效域名：${items[i]}（必须为完整域名，label 不能以连字符开头/结尾）`, SEVERITY_ERROR));
        }
      }
    } else if (f.type === RULE_DOMAIN_SUFFIX) {
      for (let i = 0; i < items.length; i++) {
        let name = items[i];
        if (name.startsWith('.')) {
          name = name.substring(1);
        }
        if (name.length > 0 && name.charAt(name.length - 1) === '.') {
          name = name.substring(0, name.length - 1);
        }
        if (!isValidDomainName(name)) {
          out.push(makeError('payload', FIELD_ERROR_INVALID_DOMAIN,
            `无效域名后缀：${items[i]}（不支持通配符，label 不能以连字符开头/结尾）`, SEVERITY_ERROR));
        }
      }
    } else if (f.type === RULE_DOMAIN_REGEX) {
      for (let i = 0; i < items.length; i++) {
        const msg = regexErrorOf(items[i]);
        if (msg.length > 0) {
          out.push(makeError('payload', ISSUE_INVALID_REGEX,
            `正则无法编译：${items[i]}（${msg}）`, SEVERITY_ERROR));
        }
      }
    } else if (f.type === RULE_IP_CIDR) {
      for (let i = 0; i < items.length; i++) {
        if (!isValidCidrText(items[i])) {
          out.push(makeError('payload', ISSUE_INVALID_CIDR,
            `无效 IP 段：${items[i]}（IPv4 前缀 0-32，IPv6 前缀 0-128）`, SEVERITY_ERROR));
        }
      }
    } else if (f.type === RULE_PORT || f.type === RULE_PORT_RANGE) {
      for (let i = 0; i < items.length; i++) {
        if (!isValidPortToken(items[i])) {
          out.push(makeError('payload', ISSUE_INVALID_PORT,
            `无效端口：${items[i]}（单端口 1-65535，区间如 1000:2000 / :1000 / 1000:）`, SEVERITY_ERROR));
        }
      }
    } else if (f.type === RULE_NETWORK) {
      for (let i = 0; i < items.length; i++) {
        if (!isTcpUdp(items[i].toLowerCase())) {
          out.push(makeError('payload', FIELD_ERROR_INVALID_NETWORK,
            `无效网络类型：${items[i]}（只能是 tcp 或 udp）`, SEVERITY_ERROR));
        }
      }
    } else if (f.type === RULE_GEOSITE) {
      const known: Set<string> = new Set();
      for (let i = 0; i < knownRuleSetIds.length; i++) {
        known.add(knownRuleSetIds[i].toLowerCase());
      }
      for (let i = 0; i < items.length; i++) {
        if (!known.has(items[i].toLowerCase())) {
          out.push(makeError('payload', ISSUE_GEOSITE_MISSING,
            `规则集不存在：${items[i]}`, SEVERITY_ERROR));
        }
      }
    }
  }
  // 高级字段
  if (hasPortText(f.destPort)) {
    const tokens = splitItems(f.destPort);
    for (let i = 0; i < tokens.length; i++) {
      if (!isValidPortToken(tokens[i])) {
        out.push(makeError('destPort', ISSUE_INVALID_PORT,
          `无效目的端口：${tokens[i]}（单端口 1-65535，区间如 1000:2000）`, SEVERITY_ERROR));
      }
    }
  }
  if (f.sourceIpCidr.trim().length > 0) {
    const tokens = splitItems(f.sourceIpCidr);
    for (let i = 0; i < tokens.length; i++) {
      if (!isValidCidrText(tokens[i])) {
        out.push(makeError('sourceIpCidr', ISSUE_INVALID_CIDR,
          `无效源地址段：${tokens[i]}（IPv4/IPv6 CIDR）`, SEVERITY_ERROR));
      }
    }
  }
  if (hasPortText(f.sourcePort)) {
    const tokens = splitItems(f.sourcePort);
    for (let i = 0; i < tokens.length; i++) {
      if (!isValidPortToken(tokens[i])) {
        out.push(makeError('sourcePort', ISSUE_INVALID_PORT,
          `无效源端口：${tokens[i]}（单端口 1-65535，区间如 1000:2000）`, SEVERITY_ERROR));
      }
    }
  }
  if (f.network.trim().length > 0 && !isTcpUdp(f.network.trim())) {
    out.push(makeError('network', FIELD_ERROR_INVALID_NETWORK,
      `无效网络类型：${f.network}（只能是 tcp 或 udp）`, SEVERITY_ERROR));
  }
  if (f.customJson.trim().length > 0) {
    const msg = jsonErrorOf(f.customJson);
    if (msg.length > 0) {
      out.push(makeError('customJson', FIELD_ERROR_INVALID_JSON, msg, SEVERITY_ERROR));
    }
  }
  // 出站引用
  if (f.outbound.trim().length === 0) {
    out.push(makeError('outbound', FIELD_ERROR_INVALID_OUTBOUND, '请选择出站目标', SEVERITY_ERROR));
  } else {
    const issue = outboundIssue(f.outbound, targets);
    if (issue.length > 0) {
      out.push(makeError('outbound', issue,
        `出站目标不存在或不可用：${f.outbound}（已删除的节点/分组不会被自动替换）`, SEVERITY_ERROR));
    }
  }
  // 组合方式
  if (f.matchMode !== 'and' && f.matchMode !== 'or') {
    out.push(makeError('matchMode', FIELD_ERROR_INVALID_MATCH_MODE,
      `无效组合方式：${f.matchMode}（只能是 and 或 or）`, SEVERITY_ERROR));
  } else if (f.matchMode === 'and' && conditionCountForm(f) < 2) {
    out.push(makeError('matchMode', FIELD_WARN_AND_SINGLE,
      '「同时满足」至少需要 2 个条件，当前设置等同于单条件', SEVERITY_WARNING));
  }
  return out;
}

// ---------------------------------------------------------------------------
// 目标选择（§7.3 末段）
// ---------------------------------------------------------------------------

/**
 * 可选出站目标：固定 direct/proxy/reject 在前，随后是节点与分组。
 * runningGroupTags = 当前正在运行的分组 id（或分组名/tag）——指向它会形成出站自引用，标为不可用。
 */
export function availableTargets(profiles: Array<Profile>, groups: Array<ProfileGroup>,
  runningGroupTags: Array<string> = []): Array<RuleTarget> {
  const out: Array<RuleTarget> = [];
  out.push(makeTarget('direct', RULE_OUT_DIRECT, '直连', true));
  out.push(makeTarget('proxy', RULE_OUT_PROXY, '代理', true));
  out.push(makeTarget('reject', RULE_OUT_BLOCK, '拒绝', true));
  for (let i = 0; i < profiles.length; i++) {
    const p = profiles[i];
    const label = p.name.length > 0 ? p.name : p.server;
    out.push(makeTarget('profile', p.id, label, true));
  }
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i];
    const running = runningGroupTags.indexOf(g.id) >= 0 || runningGroupTags.indexOf(g.name) >= 0;
    out.push(makeTarget('group', g.id, g.name, !running));
  }
  return out;
}

/** 出站引用问题：'' 正常；'target_missing' 指定的节点/分组已删除或不可用（绝不自动改成 proxy/direct）。 */
export function resolveTargetIssue(rule: RoutingRule, targets: Array<RuleTarget>): string {
  return outboundIssue(rule.outbound, targets);
}

/** 同类型第一个可用目标（仅用于 UI 提示；调用方不得自动写回规则）。 */
export function suggestReplacement(targets: Array<RuleTarget>, kind: string): RuleTarget | null {
  for (let i = 0; i < targets.length; i++) {
    const t = targets[i];
    if (t.kind === kind && t.available) {
      return t;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 摘要与条件计数（§7.2/§7.3）
// ---------------------------------------------------------------------------

/** 主条件对应的旧行条件组（用于避免同一个条件被重复计数）。 */
function primaryGroupOf(type: string): string {
  if (type === RULE_DOMAIN || type === RULE_DOMAIN_SUFFIX || type === RULE_DOMAIN_KEYWORD ||
    type === RULE_DOMAIN_REGEX || type === RULE_GEOSITE) {
    return LEG_DOMAINS;
  }
  if (type === RULE_IP_CIDR || type === RULE_GEOIP) {
    return LEG_IP;
  }
  if (type === RULE_PORT || type === RULE_PORT_RANGE) {
    return LEG_PORT;
  }
  if (type === RULE_NETWORK) {
    return LEG_NETWORK;
  }
  if (type === RULE_PROCESS || type === LEGACY_PACKAGE_TYPE) {
    return LEG_PACKAGES;
  }
  return '';
}

/**
 * 条件数 = 主条件(1) + legacyRow 里其余条件组，按字段分组计数（同字段多值算 1 个条件）。
 * 主条件所在的组不重复计数（例如端口规则的主条件就是 port）。
 */
export function conditionCount(r: RoutingRule): number {
  const primary = primaryGroupOf(r.type);
  let n = splitItems(r.payload).length > 0 ? 1 : 0;
  for (let i = 0; i < CONDITION_KEYS.length; i++) {
    const key = CONDITION_KEYS[i];
    if (key === primary) {
      continue;
    }
    if (strOf(r.legacyRow, key).trim().length === 0) {
      continue;
    }
    if (key === LEG_PACKAGES && !boolOf(r.legacyRow, LEG_PACKAGES_ENABLED, true)) {
      continue;
    }
    n++;
  }
  return n;
}

function typeLabelOf(type: string): string {
  if (type === RULE_DOMAIN) {
    return '域名';
  }
  if (type === RULE_DOMAIN_SUFFIX) {
    return '域名后缀';
  }
  if (type === RULE_DOMAIN_KEYWORD) {
    return '域名关键词';
  }
  if (type === RULE_DOMAIN_REGEX) {
    return '域名正则';
  }
  if (type === RULE_GEOSITE) {
    return '规则集';
  }
  if (type === RULE_IP_CIDR) {
    return 'IP 段';
  }
  if (type === RULE_GEOIP) {
    return 'IP 归属';
  }
  if (type === RULE_PORT) {
    return '端口';
  }
  if (type === RULE_PORT_RANGE) {
    return '端口段';
  }
  if (type === RULE_NETWORK) {
    return '网络';
  }
  if (type === RULE_PROCESS) {
    return '进程名';
  }
  if (type === LEGACY_PACKAGE_TYPE) {
    return '应用包名';
  }
  if (type === LEGACY_ADVANCED_TYPE) {
    return '高级条件';
  }
  return '规则';
}

/** 多条件摘要用的泛化主条件名（与用户视角一致：域名/IP/端口…）。 */
function genericTypeLabelOf(type: string): string {
  if (type === RULE_DOMAIN || type === RULE_DOMAIN_SUFFIX || type === RULE_DOMAIN_KEYWORD ||
    type === RULE_DOMAIN_REGEX || type === RULE_GEOSITE) {
    return '域名';
  }
  if (type === RULE_IP_CIDR || type === RULE_GEOIP) {
    return 'IP';
  }
  if (type === RULE_PORT || type === RULE_PORT_RANGE) {
    return '端口';
  }
  if (type === RULE_NETWORK) {
    return '网络';
  }
  if (type === RULE_PROCESS || type === LEGACY_PACKAGE_TYPE) {
    return '应用包名';
  }
  return '规则';
}

function conditionLabelOf(key: string): string {
  if (key === LEG_IP) {
    return 'IP';
  }
  if (key === LEG_PORT) {
    return '端口';
  }
  if (key === LEG_SOURCE) {
    return '源地址';
  }
  if (key === LEG_SOURCE_PORT) {
    return '源端口';
  }
  if (key === LEG_NETWORK) {
    return '网络';
  }
  if (key === LEG_PROTOCOL) {
    return '协议';
  }
  if (key === LEG_PACKAGES) {
    return '应用包名';
  }
  return '自定义配置';
}

/** 第二个条件（除主条件外、按展示优先级第一个存在的组）；没有则返回 ''。 */
function secondConditionLabel(r: RoutingRule): string {
  const primary = primaryGroupOf(r.type);
  for (let i = 0; i < CONDITION_KEYS.length; i++) {
    const key = CONDITION_KEYS[i];
    if (key === primary) {
      continue;
    }
    if (strOf(r.legacyRow, key).trim().length === 0) {
      continue;
    }
    if (key === LEG_PACKAGES && !boolOf(r.legacyRow, LEG_PACKAGES_ENABLED, true)) {
      continue;
    }
    return conditionLabelOf(key);
  }
  return '';
}

/**
 * 列表行摘要：
 *  - 单条件：`域名后缀 example.com` / `IP 段 10.0.0.0/8`（多值追加 `等 N 项`）；
 *  - 多条件：`域名 + 端口等 3 个条件（同时满足）`。
 */
export function ruleSummary(r: RoutingRule): string {
  const items = splitItems(r.payload);
  const count = conditionCount(r);
  if (count >= 2) {
    const second = secondConditionLabel(r);
    const tails = second.length > 0 ? ` + ${second}` : '';
    return `${genericTypeLabelOf(r.type)}${tails}等 ${count} 个条件（同时满足）`;
  }
  const label = typeLabelOf(r.type);
  if (items.length > 1) {
    return `${label} ${items[0]} 等 ${items.length} 项`;
  }
  if (items.length === 1) {
    return `${label} ${items[0]}`;
  }
  return label;
}

/**
 * 组合语义描述：不同字段 = AND（sing-box 同一规则对象内多字段同时满足）；
 * 同字段多值 = OR（内核按列表 OR）。条件数 ≥2 → 'and'，否则 'or'。
 */
export function matchDescription(r: RoutingRule): string {
  return conditionCount(r) >= 2 ? 'and' : 'or';
}

// ---------------------------------------------------------------------------
// 排序（§7.2）
// ---------------------------------------------------------------------------

/** 上/下移；返回新数组且 order 重排为 0..n-1；越界或 id 不存在时内容不变（仍返回副本）。 */
export function moveRule(rules: Array<RoutingRule>, id: string, delta: number): Array<RoutingRule> {
  const out: Array<RoutingRule> = [];
  for (let i = 0; i < rules.length; i++) {
    out.push(cloneRule(rules[i]));
  }
  let index = -1;
  for (let i = 0; i < out.length; i++) {
    if (out[i].id === id) {
      index = i;
      break;
    }
  }
  if (index >= 0 && delta !== 0) {
    let target = index + delta;
    if (target < 0) {
      target = 0;
    }
    if (target > out.length - 1) {
      target = out.length - 1;
    }
    if (target !== index) {
      const moved = out.splice(index, 1)[0];
      out.splice(target, 0, moved);
    }
  }
  for (let i = 0; i < out.length; i++) {
    out[i].order = i;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 旧包名规则（§8.5）
// ---------------------------------------------------------------------------

function isLegacyRule(r: RoutingRule): boolean {
  return r.unsupportedOnPlatform || r.type === LEGACY_PACKAGE_TYPE || r.type === LEGACY_ADVANCED_TYPE;
}

function legacySummaryOf(r: RoutingRule): string {
  const base = ruleSummary(r);
  const reason = r.unsupportedReason.trim();
  return reason.length > 0 ? `${base}（${reason}）` : base;
}

/** 需处理的旧规则视图（平台不支持 / 旧 package / 旧 advanced），其它规则不出现。 */
export function legacyViews(rules: Array<RoutingRule>): Array<LegacyRuleView> {
  const out: Array<LegacyRuleView> = [];
  for (let i = 0; i < rules.length; i++) {
    const r = rules[i];
    if (!isLegacyRule(r)) {
      continue;
    }
    const v = new LegacyRuleView();
    v.rule = cloneRule(r);
    v.summary = legacySummaryOf(r);
    v.actionOptions = legacyHandlingOptions();
    out.push(v);
  }
  return out;
}

/**
 * 旧规则动作（§8.5，绝不自动转换）：
 *  - pause：保留原文、仅禁用 → 返回禁用副本；
 *  - convert：必须由调用方提供**用户明确改写的** form（type 必须是可编译类型且有 payload），
 *    否则返回 null；转换后清掉平台不支持标记与旧的 packages 条件；
 *  - delete：返回 null（调用方从数组移除）。
 * 未知 action 一律 null。
 */
export function applyLegacyAction(rule: RoutingRule, action: string, form: RuleForm | null = null): RoutingRule | null {
  if (action === 'pause') {
    const paused = cloneRule(rule);
    paused.enabled = false;
    return paused;
  }
  if (action === 'convert') {
    if (form === null) {
      return null;
    }
    if (form.type === LEGACY_PACKAGE_TYPE || form.type === LEGACY_ADVANCED_TYPE) {
      return null;
    }
    if (!isFormType(form.type) || splitItems(form.payload).length === 0) {
      return null;
    }
    const converted = formToRule(form, rule);
    converted.unsupportedOnPlatform = false;
    converted.unsupportedReason = '';
    // ArkTS 禁止 delete:去掉 packages/packagesEnabled 键的等价实现
    converted.legacyRow = rowWithoutKey(
      rowWithoutKey(converted.legacyRow, 'packages'), 'packagesEnabled');
    return converted;
  }
  if (action === 'delete') {
    return null;
  }
  return null;
}

// ---------------------------------------------------------------------------
// AND/OR 组合（§7.3）
// ---------------------------------------------------------------------------

/** 单端口写 base，区间写 base_range（与 ConfigBuilder.setRulePorts 口径一致）。 */
function setPortFields(target: Record<string, Object>, base: string, text: string): void {
  const numbers: Array<number> = [];
  const ranges: Array<string> = [];
  const tokens = splitItems(text);
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (/^\d+$/.test(token)) {
      const n = Number(token);
      if (numbers.indexOf(n) < 0) {
        numbers.push(n);
      }
    } else if (token.indexOf(':') >= 0) {
      if (ranges.indexOf(token) < 0) {
        ranges.push(token);
      }
    }
  }
  if (numbers.length > 0) {
    target[base] = numbers;
  }
  if (ranges.length > 0) {
    target[`${base}_range`] = ranges;
  }
}

/** 主匹配条件 → 内核字段对象（字段名与 ConfigBuilder.buildCustomRule 输出一致）。 */
function payloadCondition(f: RuleForm): Record<string, Object> | null {
  const items = splitItems(f.payload);
  if (items.length === 0) {
    return null;
  }
  const cond: Record<string, Object> = {};
  if (f.type === RULE_DOMAIN) {
    cond['domain'] = items;
    return cond;
  }
  if (f.type === RULE_DOMAIN_SUFFIX) {
    cond['domain_suffix'] = items;
    return cond;
  }
  if (f.type === RULE_DOMAIN_KEYWORD) {
    cond['domain_keyword'] = items;
    return cond;
  }
  if (f.type === RULE_DOMAIN_REGEX) {
    // 正则保留原文（大小写敏感）
    cond['domain_regex'] = items;
    return cond;
  }
  if (f.type === RULE_GEOSITE) {
    cond['rule_set'] = items;
    return cond;
  }
  if (f.type === RULE_IP_CIDR) {
    cond['ip_cidr'] = items;
    return cond;
  }
  if (f.type === RULE_GEOIP) {
    const refs: Array<string> = [];
    let isPrivate = false;
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (it === 'private' || it === 'geoip:private') {
        isPrivate = true;
      } else {
        refs.push(it.startsWith('geoip:') ? it : `geoip:${it}`);
      }
    }
    if (isPrivate) {
      cond['ip_is_private'] = true;
    }
    if (refs.length > 0) {
      cond['rule_set'] = refs;
    }
    return cond;
  }
  if (f.type === RULE_PORT || f.type === RULE_PORT_RANGE) {
    setPortFields(cond, 'port', items.join(','));
    return cond;
  }
  if (f.type === RULE_NETWORK) {
    cond['network'] = items[0].toLowerCase();
    return cond;
  }
  if (f.type === RULE_PROCESS) {
    cond['process_name'] = items;
    return cond;
  }
  return null;
}

/**
 * AND 组合 → sing-box 逻辑规则 `{type:'logical', mode:'and', rules:[...]}`（§7.3）：
 * 每个条件一个子规则对象，字段名与 ConfigBuilder 输出一致（domain_suffix/ip_cidr/port/
 * port_range/source_ip_cidr/source_port/network/protocol/process_name/rule_set）。
 * matchMode==='or' 或条件 <2 时返回 null（平铺规则由内核「同字段 OR」语义承担）。
 */
export function toLogicalExpression(f: RuleForm): Record<string, Object> | null {
  if (f.matchMode !== 'and') {
    return null;
  }
  const rules: Array<Record<string, Object>> = [];
  const primary = payloadCondition(f);
  if (primary !== null) {
    rules.push(primary);
  }
  if (hasPortText(f.destPort)) {
    const cond: Record<string, Object> = {};
    setPortFields(cond, 'port', f.destPort);
    if (Object.keys(cond).length > 0) {
      rules.push(cond);
    }
  }
  if (f.sourceIpCidr.trim().length > 0) {
    const cond: Record<string, Object> = {};
    cond['source_ip_cidr'] = splitItems(f.sourceIpCidr);
    rules.push(cond);
  }
  if (hasPortText(f.sourcePort)) {
    const cond: Record<string, Object> = {};
    setPortFields(cond, 'source_port', f.sourcePort);
    if (Object.keys(cond).length > 0) {
      rules.push(cond);
    }
  }
  if (isTcpUdp(f.network.trim())) {
    const cond: Record<string, Object> = {};
    cond['network'] = f.network.trim();
    rules.push(cond);
  }
  if (f.protocol.trim().length > 0) {
    const cond: Record<string, Object> = {};
    cond['protocol'] = splitItems(f.protocol);
    rules.push(cond);
  }
  if (f.customJson.trim().length > 0) {
    const custom = parseJsonObject(f.customJson);
    if (custom !== null && Object.keys(custom).length > 0) {
      rules.push(custom);
    }
  }
  if (rules.length < 2) {
    return null;
  }
  const out: Record<string, Object> = {};
  out['type'] = 'logical';
  out['mode'] = 'and';
  out['rules'] = rules;
  return out;
}
