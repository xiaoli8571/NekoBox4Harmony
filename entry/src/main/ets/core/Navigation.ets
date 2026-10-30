/**
 * 导航契约 —— REDESIGN-PLAN-2026-10-23.md §3(信息架构与导航)、§3.3(顶栏动作表)、§3.4(返回/恢复/上下文)。
 *
 * 纯模型(无 I/O、无平台依赖)：页面清单与顺序、抽屉下标映射、返回语义、
 * 顶栏动作可用性(不可用时必须给原因,§3.3)、各页浏览记忆(搜索/滚动/展示组/订阅/子页签)。
 *
 * 兼容口径(§3.2)：内部路由名/存储字段保留旧语义，只有显示名变更；
 * 旧下标 0..6(配置/分组/路由/设置/日志/工具/关于)按下表映射，避免改动大量既有 `activeTab` 逻辑。
 */

/** 一级页面 id(稳定路由名,不随显示名变化) */
export const PAGE_NODES: string = 'nodes';
export const PAGE_SUBSCRIPTIONS: string = 'subscriptions';
export const PAGE_ROUTING: string = 'routing';
export const PAGE_SETTINGS: string = 'settings';
export const PAGE_LOGS: string = 'logs';
/* 2026-10-24 曾合并为「系统」页;2026-10-30 用户要求拆回两个独立页面 */
export const PAGE_SYSTEM: string = 'system';
export const PAGE_ABOUT: string = 'about';

/** 返回语义(§3.4) */
export const BACK_CLOSE_DRAWER: string = 'closeDrawer';
export const BACK_PARENT: string = 'parent';
export const BACK_NODES: string = 'nodes';
export const BACK_EXIT: string = 'exit';

/** 顶栏动作 token(§3.3) */
export const ACTION_SEARCH: string = 'search';
export const ACTION_PROBE: string = 'probe';
export const ACTION_PROBE_PROGRESS: string = 'probeProgress';
export const ACTION_PROBE_CANCEL: string = 'probeCancel';
export const ACTION_ADD: string = 'add';
export const ACTION_UPDATE_ALL: string = 'updateAll';
export const ACTION_MORE: string = 'more';
export const ACTION_EXPORT: string = 'export';
export const ACTION_NONE: string = 'none';

/** 页面定义：id、显示名资源键(带兜底中文)、抽屉顺序、常驻动作与更多菜单。 */
export class PageDef {
  id: string = '';
  /** 显示名资源键(新文案)，实际渲染优先取资源，缺失时用 titleFallback */
  titleKey: string = '';
  titleFallback: string = '';
  drawerIndex: number = 0;
  /** §3.3 常驻动作 */
  actions: Array<string> = [];
  /** §3.3 更多菜单 */
  moreActions: Array<string> = [];
}

const PAGE_DEFS: Array<PageDef> = buildPageDefs();

function buildPageDefs(): Array<PageDef> {
  const list: Array<PageDef> = [];
  list.push(makePage(PAGE_NODES, 'app_page_nodes', '节点', 0,
    [ACTION_SEARCH, ACTION_PROBE], [ACTION_ADD, ACTION_MORE]));
  list.push(makePage(PAGE_SUBSCRIPTIONS, 'app_page_subscriptions', '订阅', 1,
    [ACTION_ADD, ACTION_UPDATE_ALL], [ACTION_MORE]));
  list.push(makePage(PAGE_ROUTING, 'app_page_routing', '分流', 2,
    [ACTION_SEARCH, ACTION_ADD], [ACTION_MORE]));
  list.push(makePage(PAGE_SETTINGS, 'app_page_settings', '设置', 3,
    [ACTION_SEARCH], [ACTION_MORE]));
  list.push(makePage(PAGE_LOGS, 'app_page_logs', '日志', 4,
    [ACTION_SEARCH, ACTION_EXPORT], [ACTION_MORE]));
  list.push(makePage(PAGE_SYSTEM, 'app_page_system', '工具', 5, [], []));
  list.push(makePage(PAGE_ABOUT, 'app_page_about', '关于', 6, [], []));
  return list;
}

function makePage(id: string, titleKey: string, fallback: string, drawerIndex: number,
  actions: Array<string>, more: Array<string>): PageDef {
  const p = new PageDef();
  p.id = id;
  p.titleKey = titleKey;
  p.titleFallback = fallback;
  p.drawerIndex = drawerIndex;
  p.actions = actions;
  p.moreActions = more;
  return p;
}

/** 抽屉顺序(7 项,§3.1)。返回副本，调用方不得改内部定义。 */
export function pageDefs(): Array<PageDef> {
  const out: Array<PageDef> = [];
  for (let i = 0; i < PAGE_DEFS.length; i++) {
    out.push(PAGE_DEFS[i]);
  }
  return out;
}

export function pageById(id: string): PageDef | null {
  for (let i = 0; i < PAGE_DEFS.length; i++) {
    if (PAGE_DEFS[i].id === id) {
      return PAGE_DEFS[i];
    }
  }
  return null;
}

/** 旧下标 → 新页面(兼容既有 activeTab 代码,§3.2 内部路由名不变)。 */
export function pageByLegacyTab(tab: number): PageDef {
  if (tab === 0) {
    return PAGE_DEFS[0];   // 旧"配置" → 节点
  }
  if (tab === 1) {
    return PAGE_DEFS[1];   // 旧"分组" → 订阅(展示组并入节点页,§3.1)
  }
  if (tab === 2) {
    return PAGE_DEFS[2];   // 旧"路由" → 分流
  }
  if (tab === 3) {
    return PAGE_DEFS[3];
  }
  if (tab === 4) {
    return PAGE_DEFS[4];
  }
  if (tab === 5) {
    return pageById(PAGE_SYSTEM) as PageDef;   // 工具页(独立)
  }
  if (tab === 6) {
    return pageById(PAGE_ABOUT) as PageDef;    // 关于页(独立)
  }
  return PAGE_DEFS[0];
}

export function drawerIndexOfPage(id: string): number {
  const def = pageById(id);
  return def === null ? 0 : def.drawerIndex;
}

/** 返回语义上下文(§3.4)：抽屉 → 父页 → 节点页 → 系统返回(退出桌面)。 */
export class BackContext {
  drawerOpen: boolean = false;
  currentPage: string = PAGE_NODES;
  hasParent: boolean = false;
}

export function resolveBack(ctx: BackContext): string {
  if (ctx.drawerOpen) {
    return BACK_CLOSE_DRAWER;
  }
  if (ctx.hasParent) {
    return BACK_PARENT;
  }
  if (ctx.currentPage !== PAGE_NODES) {
    return BACK_NODES;
  }
  return BACK_EXIT;
}

/** 顶栏动作可用性上下文(§3.3/§4.3)：依赖连接态的动作必须给原因，不能静默无反应。 */
export class TopBarContext {
  hasProfiles: boolean = false;
  hasSubscriptions: boolean = false;
  vpnRunning: boolean = false;
  probing: boolean = false;
  probeCancellable: boolean = false;
  updating: boolean = false;
  /** 检测方式能力是否可用(legacy 内核下仍可 TCPing，因此默认 true) */
  probeSupported: boolean = true;
}

/** 动作状态：labelToken + 是否可用 + 不可用原因 token(空串=可用)。 */
export class ActionState {
  id: string = '';
  enabled: boolean = true;
  disabledReason: string = '';
}

export const ACTION_REASON_NO_PROFILES: string = 'no_profiles';
export const ACTION_REASON_NO_SUBSCRIPTIONS: string = 'no_subscriptions';
export const ACTION_REASON_PROBE_UNSUPPORTED: string = 'probe_unsupported';
export const ACTION_REASON_UPDATING: string = 'updating';
export const ACTION_REASON_NOT_RUNNING: string = 'not_running';

/**
 * 计算某页顶栏动作(§3.3)：
 * - 检测进行中，"检测"位置变成 进度/取消(ACTION_PROBE_PROGRESS + ACTION_PROBE_CANCEL)；
 * - 无节点时"检测"不可用并给 no_profiles 原因；
 * - 订阅页"更新全部"在无订阅/更新中不可用并给原因。
 */
export function topBarActions(pageId: string, ctx: TopBarContext): Array<ActionState> {
  const def = pageById(pageId);
  const out: Array<ActionState> = [];
  if (def === null) {
    return out;
  }
  for (let i = 0; i < def.actions.length; i++) {
    const id = def.actions[i];
    if (id === ACTION_PROBE) {
      if (ctx.probing) {
        out.push(makeAction(ACTION_PROBE_PROGRESS, true, ''));
        if (ctx.probeCancellable) {
          out.push(makeAction(ACTION_PROBE_CANCEL, true, ''));
        }
        continue;
      }
      if (!ctx.probeSupported) {
        out.push(makeAction(ACTION_PROBE, false, ACTION_REASON_PROBE_UNSUPPORTED));
        continue;
      }
      out.push(makeAction(ACTION_PROBE, ctx.hasProfiles, ctx.hasProfiles ? '' : ACTION_REASON_NO_PROFILES));
      continue;
    }
    if (id === ACTION_UPDATE_ALL) {
      if (ctx.updating) {
        out.push(makeAction(ACTION_UPDATE_ALL, false, ACTION_REASON_UPDATING));
        continue;
      }
      out.push(makeAction(ACTION_UPDATE_ALL, ctx.hasSubscriptions,
        ctx.hasSubscriptions ? '' : ACTION_REASON_NO_SUBSCRIPTIONS));
      continue;
    }
    if (id === ACTION_ADD && pageId === PAGE_NODES) {
      out.push(makeAction(ACTION_ADD, true, ''));
      continue;
    }
    out.push(makeAction(id, true, ''));
  }
  return out;
}

function makeAction(id: string, enabled: boolean, reason: string): ActionState {
  const a = new ActionState();
  a.id = id;
  a.enabled = enabled;
  a.disabledReason = reason;
  return a;
}

/**
 * 各页浏览记忆(§3.4 "记住各页搜索、滚动、节点展示组、订阅选择、规则子页签")。
 * 进程恢复时只恢复浏览位置，运行态必须重新向扩展确认(resetRuntimeDependent)。
 */
export class NavMemory {
  private searchText: Map<string, string> = new Map<string, string>();
  private scrollOffset: Map<string, number> = new Map<string, number>();
  private selectedGroupId: string = '';
  /** 订阅页当前查看的订阅 id */
  private selectedSubscriptionId: string = '';
  /** 分流页当前子页签(perApp/rules/ruleSets/groups) */
  private routingTab: string = 'perApp';
  /** 用户是否显式选过子页签：false 时页面按"首次默认(域名·IP规则)"处理，不能用默认值冒充已记忆值 */
  private routingTabSet: boolean = false;
  /** 节点列表筛选：收藏 / 仅看可用 / 排序模式 */
  private onlyFavorites: boolean = false;
  private onlyUsable: boolean = false;
  private sortMode: string = 'manual';
  /** 展开的展示组(折叠态记忆) */
  private collapsedGroups: Array<string> = [];

  setSearch(pageId: string, text: string): void {
    this.searchText.set(pageId, text);
  }

  getSearch(pageId: string): string {
    const v = this.searchText.get(pageId);
    return v === undefined ? '' : v;
  }

  setScroll(pageId: string, offset: number): void {
    this.scrollOffset.set(pageId, offset);
  }

  getScroll(pageId: string): number {
    const v = this.scrollOffset.get(pageId);
    return v === undefined ? 0 : v;
  }

  getSelectedGroupId(): string {
    return this.selectedGroupId;
  }

  setSelectedGroupId(id: string): void {
    this.selectedGroupId = id;
  }

  getSelectedSubscriptionId(): string {
    return this.selectedSubscriptionId;
  }

  setSelectedSubscriptionId(id: string): void {
    this.selectedSubscriptionId = id;
  }

  getRoutingTab(): string {
    return this.routingTab;
  }

  setRoutingTab(tab: string): void {
    this.routingTab = tab;
    this.routingTabSet = true;
  }

  /** 是否已有"用户选过的子页签"(§7.1 返回保留最近子页签；未选过则用首次默认)。 */
  hasRoutingTab(): boolean {
    return this.routingTabSet;
  }

  isOnlyFavorites(): boolean {
    return this.onlyFavorites;
  }

  setOnlyFavorites(v: boolean): void {
    this.onlyFavorites = v;
  }

  isOnlyUsable(): boolean {
    return this.onlyUsable;
  }

  setOnlyUsable(v: boolean): void {
    this.onlyUsable = v;
  }

  getSortMode(): string {
    return this.sortMode;
  }

  setSortMode(mode: string): void {
    this.sortMode = mode;
  }

  getCollapsedGroups(): Array<string> {
    return this.collapsedGroups.slice(0);
  }

  toggleGroupCollapsed(groupId: string): void {
    const idx = this.collapsedGroups.indexOf(groupId);
    if (idx >= 0) {
      this.collapsedGroups.splice(idx, 1);
    } else {
      this.collapsedGroups.push(groupId);
    }
  }

  isGroupCollapsed(groupId: string): boolean {
    return this.collapsedGroups.indexOf(groupId) >= 0;
  }

  /**
   * 进程恢复/重新进入时调用：清掉与"运行态"绑定的记忆，
   * 浏览位置(搜索/滚动/展示组/子页签)保留(§3.4)。
   */
  resetRuntimeDependent(): void {
    this.onlyUsable = false;
  }
}

/** 跨页跳转携带的上下文(§3.4：日志/连接/规则解释携带 sessionId/connectionId/configRevision)。 */
export class NavParams {
  page: string = PAGE_NODES;
  sessionId: string = '';
  connectionId: string = '';
  configRevision: number = 0;
  /** 返回目标页(空串 = 默认父页规则) */
  returnPage: string = '';
}

export function navParamsTo(page: string): NavParams {
  const p = new NavParams();
  p.page = page;
  return p;
}
