import { readPrefString, writePrefString } from './Store';

/** 自定义路由规则(对齐 Android NekoBox 的 RuleEntity 多字段 AND 模型)。
 *  顺序即优先级:排在越前的规则越先生效。
 *  domains 支持前缀语法(与安卓一致):
 *    geosite:xxx → rule_set; full:xxx → 精确 domain; domain:xxx → domain_suffix;
 *    regexp:xxx → domain_regex; keyword:xxx → domain_keyword; 裸值 → domain_suffix
 *  ip 支持: geoip:private → ip_is_private; geoip:xxx → rule_set; 其他 → ip_cidr */

export class RouteRule {
  // 旧单类型规则的兼容字段(迁移后不再使用,保留以读旧数据)
  type: string = 'domain_suffix';
  value: string = '';
  // 多字段 AND 模型(对齐 Android RuleEntity)
  domains: string = '';        // 域名,逗号分隔
  ip: string = '';             // 目的 IP CIDR / geoip: 前缀
  port: string = '';           // 目的端口,逗号分隔
  source: string = '';         // 源 IP CIDR
  sourcePort: string = '';     // 源端口,逗号分隔
  network: string = '';        // '' / tcp / udp
  protocol: string = '';       // comma/newline-separated protocol names; empty = any
  packages: string = '';      // 应用包名,逗号分隔
  config: string = '';         // 自定义配置 JSON(浅合并到规则)
  outbound: string = 'proxy';  // proxy | direct | reject | profile:<persistent profile ID>
  enabled: boolean = true;
  remark: string = '';
}

/** 远程 sing-box SRS 规则集订阅。 */
export class RemoteRuleSet {
  id: string = '';
  name: string = '';
  url: string = '';
  type: string = 'site';          // site | ip
  outbound: string = 'direct';    // direct | proxy
  enabled: boolean = true;
  updatedAt: number = 0;
  lastError: string = '';
}

const KEY_RULES = 'route_rules';
const KEY_REMOTE_RULE_SETS = 'remote_rule_sets';

export function parseRuleType(r: RouteRule): string {
  switch (r.type) {
    case 'domain': return 'domain';
    case 'domain_suffix': return 'domain_suffix';
    case 'domain_keyword': return 'domain_keyword';
    case 'ip_cidr': return 'ip_cidr';
    case 'geoip': return 'geoip';
    case 'geosite': return 'geosite';
    case 'port': return 'port';
    default: return '';
  }
}

/** 解析规则值:按英文逗号拆分为数组(sing-box 的 match 项列表) */
export function ruleValueList(r: RouteRule): Array<string> {
  return r.value.split(',')
    .map((s: string) => s.trim())
    .filter((s: string) => s.length > 0);
}

/** 通用逗号拆分(空串返回空数组) */
export function splitCsv(text: string): Array<string> {
  return text.split(',')
    .map((s: string) => s.trim())
    .filter((s: string) => s.length > 0);
}

/**
 * 旧单类型规则迁移到多字段模型(仅在旧字段有值而新字段全空时执行)。
 *  domain → full: 前缀(旧 type=domain 是精确匹配)
 *  domain_suffix → 裸值(后缀匹配,默认语义)
 *  domain_keyword → keyword: 前缀
 *  ip_cidr → ip 字段裸值
 *  port → port 字段裸值
 *  geoip → ip 字段加 geoip: 前缀
 *  geosite → domains 字段加 geosite: 前缀
 */
export function migrateLegacyRule(r: RouteRule): void {
  const hasNew = r.domains.trim().length > 0 || r.ip.trim().length > 0 || r.port.trim().length > 0 ||
    r.source.trim().length > 0 || r.sourcePort.trim().length > 0 || r.network.trim().length > 0 ||
    r.protocol.trim().length > 0 || r.packages.trim().length > 0 || r.config.trim().length > 0;
  if (hasNew) {
    return;
  }
  const items = ruleValueList(r);
  if (items.length === 0) {
    return;
  }
  if (r.type === 'domain') {
    r.domains = items.map((s: string) => `full:${s}`).join(',');
  } else if (r.type === 'domain_suffix') {
    r.domains = items.join(',');
  } else if (r.type === 'domain_keyword') {
    r.domains = items.map((s: string) => `keyword:${s}`).join(',');
  } else if (r.type === 'ip_cidr') {
    r.ip = items.join(',');
  } else if (r.type === 'port') {
    r.port = items.join(',');
  } else if (r.type === 'geoip') {
    r.ip = items.map((s: string) => `geoip:${s}`).join(',');
  } else if (r.type === 'geosite') {
    r.domains = items.map((s: string) => `geosite:${s}`).join(',');
  }
}

export async function loadRouteRules(): Promise<Array<RouteRule>> {
  try {
    const raw = await readPrefString(KEY_RULES, '[]');
    const parsed = JSON.parse(raw) as Array<RouteRule>;
    const result: Array<RouteRule> = [];
    for (const r of parsed) {
      const item = new RouteRule();
      item.type = r.type ?? 'domain_suffix';
      item.value = r.value ?? '';
      item.domains = r.domains ?? '';
      item.ip = r.ip ?? '';
      item.port = r.port ?? '';
      item.source = r.source ?? '';
      item.sourcePort = r.sourcePort ?? '';
      item.network = r.network === 'tcp' || r.network === 'udp' ? r.network : '';
      item.protocol = typeof r.protocol === 'string' ? r.protocol : '';
      item.packages = r.packages ?? '';
      item.config = r.config ?? '';
      item.outbound = r.outbound ?? 'proxy';
      item.enabled = r.enabled ?? true;
      item.remark = r.remark ?? '';
      // 旧单类型规则自动迁移到多字段模型
      migrateLegacyRule(item);
      result.push(item);
    }
    return result;
  } catch (e) {
    return [];
  }
}

export async function saveRouteRules(list: Array<RouteRule>): Promise<void> {
  await writePrefString(KEY_RULES, JSON.stringify(list));
}

export async function loadRemoteRuleSets(): Promise<Array<RemoteRuleSet>> {
  try {
    const raw = await readPrefString(KEY_REMOTE_RULE_SETS, '[]');
    const parsed = JSON.parse(raw) as Array<RemoteRuleSet>;
    const result: Array<RemoteRuleSet> = [];
    for (const value of parsed) {
      const item = new RemoteRuleSet();
      item.id = value.id ?? '';
      item.name = value.name ?? '';
      item.url = value.url ?? '';
      item.type = value.type === 'ip' ? 'ip' : 'site';
      item.outbound = value.outbound === 'proxy' ? 'proxy' : 'direct';
      item.enabled = value.enabled ?? true;
      item.updatedAt = value.updatedAt ?? 0;
      item.lastError = value.lastError ?? '';
      result.push(item);
    }
    return result;
  } catch (e) {
    return [];
  }
}

export async function saveRemoteRuleSets(list: Array<RemoteRuleSet>): Promise<void> {
  await writePrefString(KEY_REMOTE_RULE_SETS, JSON.stringify(list));
}
