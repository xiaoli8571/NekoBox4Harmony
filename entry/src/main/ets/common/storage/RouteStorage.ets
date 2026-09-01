import dataPreferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { RouteProfile, RouteRule, RuleSetMetadata, GeoMetadata } from '../model/RouteProfile';

const PREF_NAME = 'nekobox_routes';
const KEY_ROUTES = 'route_profiles';
const KEY_ACTIVE = 'active_route_id';
let pref: dataPreferences.Preferences | null = null;

export class RouteStorage {
  static async initialize(context: common.Context): Promise<void> {
    pref = await dataPreferences.getPreferences(context, PREF_NAME);
  }

  private static async require(): Promise<dataPreferences.Preferences> {
    if (pref === null) throw new Error('route storage not initialized');
    return pref;
  }

  static async list(): Promise<Array<RouteProfile>> {
    const p = await RouteStorage.require();
    const raw = `${await p.get(KEY_ROUTES, '[]')}`;
    const result: Array<RouteProfile> = [];
    try {
      const source = JSON.parse(raw) as Array<Object>;
      for (const item of source) {
        const route = new RouteProfile();
        RouteStorage.fill(route, item);
        route.rules = RouteStorage.rules(item);
        route.ruleSets = RouteStorage.ruleSets(item);
        const geoRaw = (item as Record<string, Object>)['geo'];
        if (geoRaw !== undefined && geoRaw !== null) {
          route.geo = new GeoMetadata();
          RouteStorage.fill(route.geo, geoRaw as Object);
        }
        result.push(route);
      }
    } catch (e) {
      return [];
    }
    return result;
  }

  static async save(routes: Array<RouteProfile>): Promise<void> {
    const p = await RouteStorage.require();
    await p.put(KEY_ROUTES, JSON.stringify(routes));
    await p.flush();
  }

  static async activeId(): Promise<string> {
    const p = await RouteStorage.require();
    return `${await p.get(KEY_ACTIVE, '')}`;
  }

  static async setActiveId(id: string): Promise<void> {
    const p = await RouteStorage.require();
    await p.put(KEY_ACTIVE, id);
    await p.flush();
  }

  static async active(): Promise<RouteProfile | null> {
    const id = await RouteStorage.activeId();
    const routes = await RouteStorage.list();
    for (const route of routes) if (route.id === id) return route;
    return routes.length > 0 ? routes[0] : null;
  }

  static async upsertRuleSet(routeId: string, metadata: RuleSetMetadata): Promise<void> {
    const routes = await RouteStorage.list();
    for (const route of routes) {
      if (route.id !== routeId) continue;
      let replaced = false;
      for (let i = 0; i < route.ruleSets.length; i++) {
        if (route.ruleSets[i].tag === metadata.tag) {
          route.ruleSets[i] = metadata;
          replaced = true;
          break;
        }
      }
      if (!replaced) route.ruleSets.push(metadata);
      route.updatedAt = Date.now();
      await RouteStorage.save(routes);
      return;
    }
    throw new Error('路由配置不存在');
  }

  static async removeRuleSet(routeId: string, tag: string): Promise<void> {
    const routes = await RouteStorage.list();
    for (const route of routes) {
      if (route.id !== routeId) continue;
      route.ruleSets = route.ruleSets.filter((item: RuleSetMetadata) => item.tag !== tag);
      route.updatedAt = Date.now();
      await RouteStorage.save(routes);
      return;
    }
  }

  private static rules(item: Object): Array<RouteRule> {
    const result: Array<RouteRule> = [];
    const raw = (item as Record<string, Object>)['rules'];
    if (!Array.isArray(raw)) return result;
    const values: Array<Object> = raw as Array<Object>;
    for (const value of values) {
      const rule = new RouteRule();
      RouteStorage.fill(rule, value as Object);
      result.push(rule);
    }
    return result;
  }

  private static ruleSets(item: Object): Array<RuleSetMetadata> {
    const result: Array<RuleSetMetadata> = [];
    const raw = (item as Record<string, Object>)['ruleSets'];
    if (!Array.isArray(raw)) return result;
    const values: Array<Object> = raw as Array<Object>;
    for (const value of values) {
      const metadata = new RuleSetMetadata();
      RouteStorage.fill(metadata, value as Object);
      result.push(metadata);
    }
    return result;
  }

  private static fill(target: Object, source: Object): void {
    if (source === undefined || source === null) return;
    const targetRecord = target as Record<string, Object>;
    for (const key of Object.keys(source)) {
      const value = (source as Record<string, Object>)[key];
      if (value !== undefined && value !== null) targetRecord[key] = value;
    }
  }
}
