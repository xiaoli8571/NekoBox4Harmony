import { Profile, ProfileGroup } from '../model/Profile';

/**
 * 「首页只看一个订阅」的纯逻辑(无 I/O、无 UI,可在 Node 直接测)。
 *
 * 背景:订阅的 Clash 配置里本来就有 `proxy-groups`(策略组),导入时已经落成 ProfileGroup
 * 并把成员节点迁了进去(见 core/Subscriptions.applyClashGroups)。但首页分组条是把**所有**
 * 订阅的分组混在一起显示的,多订阅用户没法按订阅看。
 *
 * 于是:
 *   1) 分组记录归属订阅(ProfileGroup.subUrl),新导入由 applyClashGroups/markGroupSubUrl 写;
 *   2) 历史分组没有 subUrl,用成员节点的 subUrl 反推(本文件 inferGroupSubUrl);
 *   3) 订阅页选中"主页显示" → 首页只显示该订阅的分组与节点。
 *
 * 没有归入任何分组的订阅节点,依然以 groupId='' 的"未分组"出现,不会凭空消失。
 */

/** 持久化键(Preferences,不属 AppSettings:它是浏览偏好,不进备份/不影响内核配置) */
export const ACTIVE_SUB_PREF: string = 'home_selected_sub';
/** 多选版键:JSON 数组;空数组 = 不筛(全部订阅都显示) */
export const ACTIVE_SUBS_PREF: string = 'home_selected_subs';

/** 订阅引用最小形状(避免把 core/Subscriptions 的依赖拖进纯模型) */
export interface SubUrlRef {
  url: string;
}

/**
 * 组的归属订阅:显式 subUrl 优先;否则按组内成员的 subUrl 多数票推断(历史分组)。
 * 空串 = 推不出来(手动分组/成员来自多个订阅)。
 */
export function inferGroupSubUrl(group: ProfileGroup, profiles: Array<Profile>): string {
  const explicit: string = group.subUrl.trim();
  if (explicit.length > 0) {
    return explicit;
  }
  const counts: Map<string, number> = new Map<string, number>();
  for (const profile of profiles) {
    if (!belongsToGroup(profile, group.id)) {
      continue;
    }
    const url: string = profile.subUrl.trim();
    if (url.length === 0) {
      continue;
    }
    const prev: number = counts.get(url) ?? 0;
    counts.set(url, prev + 1);
  }
  let best: string = '';
  let bestCount: number = 0;
  counts.forEach((count: number, url: string) => {
    /* 成员数相同时按 URL 字典序取小的,保证结果稳定(否则每次渲染顺序可能变) */
    if (count > bestCount || (count === bestCount && best.length > 0 && url < best)) {
      bestCount = count;
      best = url;
    }
  });
  return best;
}

/**
 * 节点是否属于某分组。
 * Clash 的 proxy-groups 是**多对多**:同一节点会同时出现在「自动选择」「香港」「流媒体」等组。
 * groupId 只是主分组(内核包装用),subGroupIds 才是订阅带来的完整归属
 * (写入见 core/Subscriptions.applyClashGroups)。只判 groupId 会让除主分组外的组全空。
 */
export function belongsToGroup(profile: Profile, groupId: string): boolean {
  if (profile.groupId === groupId) {
    return true;
  }
  const list: Array<string> = profile.subGroupIds ?? [];
  return list.indexOf(groupId) >= 0;
}

/** 该订阅自带的全部分组(按 sortOrder),subUrl 为空时返回空数组 */
export function groupsForSubscription(groups: Array<ProfileGroup>, profiles: Array<Profile>,
  subUrl: string): Array<ProfileGroup> {
  const target: string = subUrl.trim();
  if (target.length === 0) {
    return [];
  }
  const out: Array<ProfileGroup> = [];
  for (const group of groups) {
    if (inferGroupSubUrl(group, profiles) === target) {
      out.push(group);
    }
  }
  return out.sort((a: ProfileGroup, b: ProfileGroup) => a.sortOrder - b.sortOrder);
}

/** 该订阅的节点(含未分组的)。subUrl 为空 = 不过滤(全部节点) */
export function nodesOfSubscription(profiles: Array<Profile>, subUrl: string): Array<Profile> {
  const target: string = subUrl.trim();
  if (target.length === 0) {
    return profiles.slice();
  }
  return profiles.filter((profile: Profile) => profile.subUrl === target);
}

/**
 * 校正"主页订阅":选中的订阅被删掉/清空后必须回落到全部,
 * 否则首页会空着且用户找不到原因。
 */
export function normalizeActiveSub(activeUrl: string, subs: Array<SubUrlRef>): string {
  const target: string = activeUrl.trim();
  if (target.length === 0) {
    return '';
  }
  for (const sub of subs) {
    if (sub.url === target) {
      return target;
    }
  }
  return '';
}

/**
 * 首页分组条的组 id 顺序:activeSubUrl 非空时只给该订阅的分组,
 * 末尾补 '' (未分组)——前提是该订阅真有未分组节点。
 */
export function groupIdsForSubscription(groups: Array<ProfileGroup>, profiles: Array<Profile>,
  subUrl: string): Array<string> {
  const ids: Array<string> = [];
  const owned: Array<Profile> = nodesOfSubscription(profiles, subUrl);
  if (subUrl.trim().length === 0) {
    return ids;
  }
  for (const group of groupsForSubscription(groups, profiles, subUrl)) {
    if (owned.some((profile: Profile) => belongsToGroup(profile, group.id))) {
      ids.push(group.id);
    }
  }
  if (owned.some((profile: Profile) => profile.groupId.length === 0)) {
    ids.push('');
  }
  return ids;
}


// ============================================================ 多选(订阅页复选框)

/** 解析「主页显示哪些订阅」:JSON 数组优先,兼容旧的单值;去空白/去重/保序 */
export function parseActiveSubs(raw: string): Array<string> {
  const text: string = raw.trim();
  if (text.length === 0) {
    return [];
  }
  const out: Array<string> = [];
  const push = (value: string): void => {
    const url: string = value.trim();
    if (url.length > 0 && out.indexOf(url) < 0) {
      out.push(url);
    }
  };
  if (text.startsWith('[')) {
    try {
      const parsed = JSON.parse(text) as Array<object>;
      if (Array.isArray(parsed)) {
        for (const item of parsed) {
          if (typeof item === 'string') {
            push(item as string);
          }
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }
  /* 旧格式是单个 URL;不是 URL 的残值一律当"没设置过",免得脏数据把首页筛成空 */
  if (text.indexOf('://') > 0) {
    push(text);
  }
  return out;
}

/** 序列化(空数组也写成 '[]',和"没设置过"区分:后者才回落旧键) */
export function serializeActiveSubs(urls: Array<string>): string {
  return JSON.stringify(urls);
}

/** 勾选/取消一个订阅(返回新数组,不改入参) */
export function toggleActiveSub(urls: Array<string>, url: string): Array<string> {
  const target: string = url.trim();
  const next: Array<string> = urls.filter((u: string) => u !== target);
  if (next.length === urls.length) {
    next.push(target);
  }
  return next;
}

/** 去掉已经不存在的订阅;全没了返回空数组(= 不筛) */
export function normalizeActiveSubs(urls: Array<string>, subs: Array<SubUrlRef>): Array<string> {
  const out: Array<string> = [];
  for (const url of urls) {
    if (subs.some((sub: SubUrlRef) => sub.url === url) && out.indexOf(url) < 0) {
      out.push(url);
    }
  }
  return out;
}

/** 节点是否在筛选范围内(空数组 = 全选,不过滤) */
export function inActiveSubs(subUrl: string, activeUrls: Array<string>): boolean {
  if (activeUrls.length === 0) {
    return true;
  }
  return activeUrls.indexOf(subUrl) >= 0;
}

/** 多选范围下的分组(按 sortOrder;空数组返回空 = 由调用方走"全部分组") */
export function groupsForSubscriptions(groups: Array<ProfileGroup>, profiles: Array<Profile>,
  activeUrls: Array<string>): Array<ProfileGroup> {
  if (activeUrls.length === 0) {
    return [];
  }
  const out: Array<ProfileGroup> = [];
  for (const group of groups) {
    if (activeUrls.indexOf(inferGroupSubUrl(group, profiles)) >= 0) {
      out.push(group);
    }
  }
  return out.sort((a: ProfileGroup, b: ProfileGroup) => a.sortOrder - b.sortOrder);
}

/** 多选范围下的分组 id(只给有节点的组,末尾按需补 '' 未分组) */
export function groupIdsForSubscriptions(groups: Array<ProfileGroup>, profiles: Array<Profile>,
  activeUrls: Array<string>): Array<string> {
  const ids: Array<string> = [];
  if (activeUrls.length === 0) {
    return ids;
  }
  const owned: Array<Profile> = profiles.filter((p: Profile) => inActiveSubs(p.subUrl, activeUrls));
  for (const group of groupsForSubscriptions(groups, profiles, activeUrls)) {
    if (owned.some((profile: Profile) => belongsToGroup(profile, group.id))) {
      ids.push(group.id);
    }
  }
  if (owned.some((profile: Profile) => profile.groupId.length === 0
    && (profile.subGroupIds ?? []).length === 0)) {
    ids.push('');
  }
  return ids;
}
