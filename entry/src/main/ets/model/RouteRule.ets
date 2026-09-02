import { readPrefString, writePrefString } from './Store';

/** 自定义路由规则(对齐 Android NekoBox 的路由规则列表)。
 *  顺序即优先级:排在越前的规则越先生效。 */

export class RouteRule {
  type: string = 'domain_suffix'; // domain | domain_suffix | domain_keyword | ip_cidr | port
  value: string = '';             // 匹配值(多条用英文逗号分隔)
  outbound: string = 'proxy';     // proxy | direct | reject
  enabled: boolean = true;
  remark: string = '';
}

const KEY_RULES = 'route_rules';

export function parseRuleType(r: RouteRule): string {
  switch (r.type) {
    case 'domain': return 'domain';
    case 'domain_suffix': return 'domain_suffix';
    case 'domain_keyword': return 'domain_keyword';
    case 'ip_cidr': return 'ip_cidr';
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
