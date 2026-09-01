/** 独立路由配置模型，对齐 NekoBox 的预设/自定义规则概念。 */
export class RouteRule {
  id: string = '';
  kind: string = 'DOMAIN_SUFFIX';
  value: string = '';
  action: string = 'PROXY';
  enabled: boolean = true;
}

export class RuleSetMetadata {
  tag: string = '';
  path: string = '';
  sourceUrl: string = '';
  updatedAt: number = 0;
  size: number = 0;
  sha256: string = '';
  geo: string = '';
}

export class GeoMetadata {
  geositePath: string = '';
  geoipPath: string = '';
  geositeUpdatedAt: number = 0;
  geoipUpdatedAt: number = 0;
}

export class RouteProfile {
  id: string = '';
  name: string = '规则';
  preset: string = 'global';
  rules: Array<RouteRule> = [];
  ruleSets: Array<RuleSetMetadata> = [];
  geo: GeoMetadata = new GeoMetadata();
  updatedAt: number = 0;
}

export const ROUTE_PRESETS: Array<string> = ['global', 'bypass-cn', 'direct', 'adblock', 'custom'];
export const ROUTE_PRESET_LABELS: Array<string> = ['全局代理', '绕过中国', '全局直连', '广告拦截', '自定义'];
export const ROUTE_RULE_KINDS: Array<string> = ['DOMAIN', 'DOMAIN_SUFFIX', 'DOMAIN_KEYWORD', 'IP_CIDR', 'PORT', 'PROCESS', 'RULE_SET'];
export const ROUTE_RULE_ACTIONS: Array<string> = ['PROXY', 'DIRECT', 'REJECT'];

export function routePresetLabel(preset: string): string {
  const index = ROUTE_PRESETS.indexOf(preset);
  return index >= 0 ? ROUTE_PRESET_LABELS[index] : '自定义';
}

export function newRouteRule(kind: string = 'DOMAIN_SUFFIX', value: string = '', action: string = 'PROXY'): RouteRule {
  const rule = new RouteRule();
  rule.id = `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
  rule.kind = ROUTE_RULE_KINDS.includes(kind) ? kind : 'DOMAIN_SUFFIX';
  rule.value = value;
  rule.action = ROUTE_RULE_ACTIONS.includes(action) ? action : 'PROXY';
  return rule;
}

export function cloneRouteProfile(source: RouteProfile): RouteProfile {
  const result = new RouteProfile();
  result.id = source.id;
  result.name = source.name;
  result.preset = source.preset;
  result.updatedAt = source.updatedAt;
  result.geo = source.geo;
  result.rules = source.rules;
  result.ruleSets = source.ruleSets;
  return result;
}

/** 将模型规则转换为 sing-box 1.13 default rule 对象。无效项返回 null，由调用者跳过。 */
export function routeRuleToSingBox(rule: RouteRule, proxyTag: string): Record<string, Object> | null {
  if (!rule.enabled || rule.value.trim().length === 0) {
    return null;
  }
  const value = rule.value.trim();
  const result: Record<string, Object> = {};
  switch (rule.kind) {
    case 'DOMAIN':
    case 'DOMAIN_SUFFIX':
    case 'DOMAIN_KEYWORD':
      if (value.indexOf(' ') >= 0 || value.indexOf('\t') >= 0) return null;
      result[rule.kind === 'DOMAIN' ? 'domain' : rule.kind === 'DOMAIN_SUFFIX' ? 'domain_suffix' : 'domain_keyword'] = [value];
      break;
    case 'IP_CIDR': {
      const slash = value.lastIndexOf('/');
      const prefix = slash > 0 ? Number(value.substring(slash + 1)) : -1;
      if (slash <= 0 || !Number.isInteger(prefix) || prefix < 0 || prefix > 128) return null;
      result['ip_cidr'] = [value];
      break;
    }
    case 'PORT': {
      const range = value.indexOf('-');
      if (range > 0) {
        const start = Number(value.substring(0, range));
        const end = Number(value.substring(range + 1));
        if (!Number.isInteger(start) || !Number.isInteger(end) || start < 1 || end > 65535 || start > end) return null;
        result['port_range'] = [value];
      } else {
        const port = Number(value);
        if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
        result['port'] = [port];
      }
      break;
    }
    case 'PROCESS': result['process_name'] = [value]; break;
    case 'RULE_SET':
      if (!/^[A-Za-z0-9_.-]+$/.test(value)) return null;
      result['rule_set'] = [value];
      break;
    default: return null;
  }
  if (rule.action === 'REJECT') {
    result['action'] = 'reject';
  } else {
    result['outbound'] = rule.action === 'DIRECT' ? 'direct' : proxyTag;
  }
  return result;
}
