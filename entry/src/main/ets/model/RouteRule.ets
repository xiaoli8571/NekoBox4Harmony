import { readPrefString, writePrefString } from './Store';

/** 自定义路由规则(对齐 Android NekoBox 的路由规则列表)。
 *  顺序即优先级:排在越前的规则越先生效。 */

export class RouteRule {
  type: string = 'domain_suffix'; // domain | domain_suffix | domain_keyword | ip_cidr | geoip | geosite | port
  value: string = '';             // 匹配值(多条用英文逗号分隔)
  outbound: string = 'proxy';     // proxy | direct | reject
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

export async function loadRouteRules(): Promise<Array<RouteRule>> {
  try {
    const raw = await readPrefString(KEY_RULES, '[]');
    const parsed = JSON.parse(raw) as Array<RouteRule>;
    const result: Array<RouteRule> = [];
    for (const r of parsed) {
      const item = new RouteRule();
      item.type = r.type ?? 'domain_suffix';
      item.value = r.value ?? '';
      item.outbound = r.outbound ?? 'proxy';
      item.enabled = r.enabled ?? true;
      item.remark = r.remark ?? '';
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
