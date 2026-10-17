import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import bundleManager from '@ohos.bundle.bundleManager';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import BusinessError from '@ohos.base';
import zlib from '@ohos.zlib';
import image from '@ohos.multimedia.image';
import { scanBarcode, scanCore, generateBarcode } from '@kit.ScanKit';
import window from '@ohos.window';
/* HDS 标题栏：自带"渐变模糊"(IMMERSIVE_GRADIENT_BLUR) 与沉浸光感材质 —— 不要自己画渐变) */
import {
  BlurStrategy,
  HdsNavigation,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import { UiSpec } from '../common/UiSpec';
import { illuminatedEffect, pressLightEffect } from '../common/Effects';
import { GlowIconButton } from '../common/components/GlowIconButton';
import { HdsMenu, MenuItemData } from '../common/components/FlowMenu';
import { HAND_SIDE_KEY, handedness } from '../common/Handedness';
import { SettingsPage } from './SettingsPage';
import { GroupPage } from './GroupPage';
import { ToolsPage } from './ToolsPage';
import { AboutPage } from './AboutPage';
import { RouteRulesPanel } from './RouteRulesPage';
import { LogPanel } from './LogPage';

import { Profile, ProfileGroup, AppSettings, profileTypeLabel } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, loadSettings, saveSettings, readPrefString, writePrefString, ensureGroupByName, LogStore } from '../model/Store';
import { VpnService } from '../core/VpnService';
import { parseShareText } from '../utils/LinkParser';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { fetchSubscriptionWithInfo, looksLikeClashYaml, parseClashProxies, looksLikeSingBoxJson, parseSingBoxConfig, ClashParseResult, subErrorText, unwrapSubscriptionLink, isSagerNetSubscriptionContainer } from '../utils/Subscription';
import { testProfiles, urlTestProfiles } from '../utils/LatencyTester';
import { SubInfo, listSubs, upsertSub, needAutoUpdate, updateSubscription, setAppContext, subNameOf, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { fetchTrafficTotals, formatSpeed, formatBytes } from '../utils/TrafficStats';
import { fetchCurrentProxyDelay } from '../utils/ClashApi';
import { exportProfileLink } from '../utils/LinkExporter';
import { buildOutboundJson } from '../core/ConfigBuilder';
import { publishVpnLatency } from '../core/VpnIpc';

const OUTBOUND_MODES: Array<string> = ['rule', 'global', 'direct'];
const OUTBOUND_MODE_LABELS: Array<Resource> = [$r('app.string.mode_rule'), $r('app.string.mode_global'), $r('app.string.mode_direct')];

/** 抽屉项(顺序固定;activeTab→抽屉下标的映射见 TAB_TO_DRAWER_INDEX):[标识, 文案, 系统符号]
 *  「使用文档」入口已移除(用户 2026-10-17):不进列表,DocPage 路由保留但不可达 */
const DRAWER_ITEM_IDS: Array<string> = ['config', 'groups', 'route', 'settings', 'logs', 'tools', 'about'];
const DRAWER_ITEM_LABELS: Array<Resource> = [
  $r('app.string.nav_config'),
  $r('app.string.nav_groups'),
  $r('app.string.nav_route'),
  $r('app.string.settings_title'),
  $r('app.string.logs'),
  $r('app.string.nav_tools'),
  $r('app.string.nav_about')
];
const DRAWER_ITEM_SYMBOLS: Array<Resource> = [
  $r('sys.symbol.list_square'),
  $r('sys.symbol.folder'),
  $r('sys.symbol.arrow_up_left_and_arrow_down_right'),
  $r('sys.symbol.gearshape'),
  $r('sys.symbol.doc_text'),
  $r('sys.symbol.wand_and_stars'),
  $r('sys.symbol.info_circle')
];
/** activeTab(0..6 = 配置/分组/路由/设置/日志/工具/关于) → 抽屉下标 */
const TAB_TO_DRAWER_INDEX: Array<number> = [0, 1, 2, 3, 4, 5, 6];
/** 顶栏 ⋮ 的菜单锚点 id(沉浸光感菜单靠它定位,必须在某个真实组件上用 .id() 挂上) */
const OVERFLOW_MENU_ANCHOR: string = 'nbOverflowAnchor';

@Entry
@Component
struct Index {
  @State profiles: Array<Profile> = [];
  @State groups: Array<ProfileGroup> = [];
  @State selectedId: string = '';
  @State latencies: Record<string, number> = {};
  @State testing: boolean = false;
  @State settings: AppSettings = new AppSettings();
  @State subscriptions: Array<SubInfo> = [];
  @State activeConfigUrl: string = '';
  @State activeTab: number = 0;          // 0 配置 / 1 分组 / 2 路由 / 3 设置 / 4 日志 / 5 工具 / 6 关于
  @State uiUptime: number = 0;
  @State nodeSearch: string = '';
  @State searchVisible: boolean = false;
  @State drawerOpen: boolean = false;
  /** 抽屉当前(最近一次)滑入的一侧:面板位置由 translate 决定,换手就是改它(带补间动画) */
  @State drawerEdge: string = 'right';
  /** 窗口宽度(vp):抽屉面板宽 + 左右位移都按它算(量不到时各函数里有兜底) */
  @State pageW: number = 0;
  /** 窗口高度(vp)：内容层铺满整窗时用 matchParent，这里留作尺度参考 */
  /** 智感握姿:当前交互手所在的一侧('right' | 'left',由 EntryAbility 里的 handedness 追踪器写入)。
   *  拿不到识别结果时恒为 'right' ⇒ 布局与改造前逐字一致。 */
  @StorageLink(HAND_SIDE_KEY) @Watch('onHandSideChanged') handSide: string = 'right';
  /** 当前被按下的元素 key(抽屉项 / 节点卡 / 模式按钮 / FAB):"按下才亮"靠它逐颗判断 */
  @State litKey: string = '';
  /** 配置页列表的滚动器(列表滚动位置复位 / 分组切换后回到顶部都靠它) */
  private configScroller: Scroller = new Scroller();
  /** 顶栏 ⋮ 的沉浸光感菜单(照 RzdSchool HdsMenu:openMenu + 自绘面板 + 模糊背板 + 自适应取色) */
  private overflowMenu: HdsMenu = new HdsMenu();
  /** HdsNavigation 的宿主栈（本工程二级页走 router，这里只当标题栏宿主用） */
  private pathStack: NavPathStack = new NavPathStack();
  @State safeTopVp: number = 38;
  /** 底部导航条/手势条高度(vp,运行时实测) —— 列表与 FAB 的底部让位用 */
  @State navBottomVp: number = 24;
  /** 内容区顶部让位(vp):运行时用探针量「顶栏底边 − 内容区原点」得到,不再靠猜常数 */
  @State contentTopInset: number = 96;
  /** 当前选中的分组(配置页顶部分类条;空串 = 未分组) */
  @State selectedGroupId: string = '';
  @State appVersion: string = '';
  @StorageLink('uiBreakpoint') uiBreakpoint: string = 'compact';
  @StorageLink('vpnRunning') @Watch('onRunningChange') isRunning: boolean = false;
  @StorageLink('vpnStatus') statusText: string = 'disconnected';
  @StorageLink('vpnUpSpeed') upSpeed: number = 0;
  @StorageLink('vpnDownSpeed') downSpeed: number = 0;
  @StorageLink('vpnTotalUp') totalUp: number = 0;
  @StorageLink('vpnTotalDown') totalDown: number = 0;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private switching: boolean = false;
  private speedTimer: number = -1;
  private speedPollGeneration: number = 0;
  private lastUp: number = 0;
  private lastDown: number = 0;
  private lastTrafficAt: number = 0;
  private uptimeTimer: number = -1;

  aboutToAppear(): void {
    setAppContext(this.context);
    /* 智感握姿:全进程只订阅一次(交互手/握持手),结果写 AppStorage 供各页面镜像布局。
       ⚠️ 放在这里而不是 EntryAbility.onCreate:motion 要走系统服务,放启动关键路径上
       一旦服务未就绪会卡死在开屏页(真机踩过)。Handler 内部还会再 defer 一次(setTimeout 0)。 */
    handedness.start();
    this.computeInsets();
    this.refresh();
    this.autoUpdateSubs();
    this.autoConnect();
    if (this.isRunning) {
      this.startSpeedPoller();
      this.startUptimeTimer();
    }
  }

  /** 运行时实测**底部**导航条/手势条高度(照 RzdVideo HomePage.computeSafeTop 的做法):
   *  列表与 FAB 的底部让位都用它,不写死 —— 写死就会在别的机型上留出死空白或被手势条压住。 */
  private computeInsets(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      window.getLastWindow(ctx).then((win: window.Window) => {
        const ui = this.getUIContext();
        const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        const bottomVp = ui.px2vp(nav.bottomRect.height);
        const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const topVp = ui.px2vp(sys.topRect.height);
        if (topVp > 0) {
          this.safeTopVp = topVp;
        }
        if (bottomVp > 0) {
          this.navBottomVp = bottomVp;
        }
        /* 窗口宽(vp):抽屉面板宽/位移按它算 —— 抽屉换边是 translate 平移,位移量必须是真实像素宽 */
        const prop = win.getWindowProperties();
        const wVp = ui.px2vp(prop.windowRect.width);
        if (wVp > 0) {
          this.pageW = wVp;
        }
      }).catch(() => {
      });
    } catch (e) {
    }
  }
  /**
   * 系统返回键(对齐安卓 onBackPressedDispatcher):
   * 抽屉打开 → 收抽屉;非配置页 → 回配置页;配置页 → 退到桌面(VPN 继续运行)。
   * 本 SDK 下该回调只对 @Entry 组件生效。
   */
  onBackPress(): boolean {
    if (this.drawerOpen) {
      this.drawerOpen = false;
      return true;
    }
    if (this.activeTab !== 0) {
      this.activeTab = 0;
      return true;
    }
    this.context.moveAbilityToBackground();
    return true;
  }

  /** 节点搜索输入防抖计时器(见 configFragment 里 TextInput 的 onChange) */
  private searchDebounceTimer: number = -1;

  private scheduleSearchFilter(v: string): void {
    this.cancelSearchFilterTimer();
    this.searchDebounceTimer = setTimeout(() => {
      this.searchDebounceTimer = -1;
      this.nodeSearch = v;
    }, 250);
  }

  private cancelSearchFilterTimer(): void {
    if (this.searchDebounceTimer >= 0) {
      clearTimeout(this.searchDebounceTimer);
      this.searchDebounceTimer = -1;
    }
  }

  /** 关闭节点搜索(「取消」按钮与再次点搜索图标共用):清未触发的防抖 + 清空关键词 */
  private closeNodeSearch(): void {
    this.cancelSearchFilterTimer();
    this.nodeSearch = '';
    this.searchVisible = false;
  }

  aboutToDisappear(): void {
    this.cancelSearchFilterTimer();
    this.stopSpeedPoller();
    if (this.uptimeTimer >= 0) {
      clearInterval(this.uptimeTimer);
      this.uptimeTimer = -1;
    }
  }

  // 从编辑页 router.back() 回来时刷新列表(否则新保存的节点不显示)
  onPageShow(): void {
    this.refresh();
    void this.reconcileVpnState();
  }

  /** 回到前台时核对 VPN 状态:UI 进程可能被系统回收重建而扩展进程实际已死。
   *  以 clash API 探测为准,无响应则把 UI 重置回断开态,避免按钮停在「运行中」。 */
  private async reconcileVpnState(): Promise<void> {
    const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
    const status: string = AppStorage.get<string>('vpnStatus') ?? '';
    if (!running || !status.startsWith('connected:') || !this.settings.clashApiEnabled) {
      return;
    }
    try {
      const totals = await fetchTrafficTotals(this.settings.clashApiPort, this.settings.clashApiSecret);
      if (totals === null) {
        LogStore.addLog('[ui] 前台探测:VPN 扩展无响应(clash API 不可达),重置为断开状态');
        AppStorage.setOrCreate('vpnRunning', false);
        AppStorage.setOrCreate('vpnRunningProfileId', '');
        AppStorage.setOrCreate('vpnStatus', 'disconnected');
      }
    } catch (e) {
      // 探测异常不改变 UI 状态
    }
  }

  onRunningChange(): void {
    if (this.isRunning) {
      this.startSpeedPoller();
      this.startUptimeTimer();
    } else {
      this.stopSpeedPoller();
      this.stopUptimeTimer();
    }
    this.refresh();
  }

  async refresh(): Promise<void> {
    try {
      await initStore(this.context);
      this.profiles = await loadProfiles();
      this.groups = await loadGroups();
      this.settings = await loadSettings();
      this.subscriptions = await listSubs();
      this.activeConfigUrl = await readPrefString('active_config_url', '');
      if (this.activeConfigUrl.length > 0 && !this.subscriptions.some((sub: SubInfo) => sub.url === this.activeConfigUrl)) {
        this.activeConfigUrl = '';
        await writePrefString('active_config_url', '');
      }
      const savedNodeId = await readPrefString('selected_profile_id', '');
      if (savedNodeId.length > 0 && this.profiles.some((profile: Profile) => profile.id === savedNodeId)) {
        this.selectedId = savedNodeId;
      } else if (this.selectedId.length === 0 && this.profiles.length > 0) {
        this.selectedId = this.profiles[0].id;
      }
      /* 分组分类条:分组/节点变化后校正选中项(被删/被合并时回落到第一个) */
      this.ensureSelectedGroup();
    } catch (e) {
      LogStore.addLog(`[ui] 加载节点失败: ${e}`);
    }
  }

  /** 启动时自动更新超过设定间隔的订阅 */
  async autoUpdateSubs(): Promise<void> {
    try {
      await initStore(this.context);
      if (!this.settings.autoUpdateSubs) {
        return;
      }
      const stale = await needAutoUpdate();
      for (const sub of stale) {
        try {
          const r = await updateSubscription(sub.url);
          await markSubSuccess(sub.url);
          LogStore.addLog(`[app] 订阅 ${sub.name} 自动更新:新增 ${r.added},移除 ${r.removed}`);
          this.refresh();
        } catch (e) {
          await markSubFailure(sub.url);
          LogStore.addLog(`[app] 订阅 ${sub.name} 自动更新失败: ${subErrorText(e as Object)}`);
        }
      }
    } catch (e) {
      // ignore
    }
  }

  /** 启动时自动连接已选中的节点(对齐安卓 isAutoConnect;默认关闭) */
  async autoConnect(): Promise<void> {
    try {
      if (!this.settings.autoConnect) {
        return;
      }
      if (this.isRunning) {
        return;
      }
      if (this.selectedId.length === 0) {
        return;
      }
      LogStore.addLog('[app] 自动连接已启用,正在启动 VPN…');
      await VpnService.connect(this.context, this.selectedId);
    } catch (e) {
      LogStore.addLog(`[app] 自动连接失败: ${subErrorText(e as Object)}`);
    }
  }

  // ---------------------------------------------------------------- 速度/计时轮询

  private startSpeedPoller(): void {
    this.stopSpeedPoller();
    if (!this.isRunning || !this.settings.clashApiEnabled) {
      return;
    }
    this.lastUp = 0;
    this.lastDown = 0;
    this.lastTrafficAt = 0;
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
    const generation = ++this.speedPollGeneration;
    const poll = async (): Promise<void> => {
      const startedAt = Date.now();
      const t = await fetchTrafficTotals(this.settings.clashApiPort, this.settings.clashApiSecret);
      if (generation !== this.speedPollGeneration || !this.isRunning || !this.settings.clashApiEnabled || t === null) {
        return;
      }
      if (this.lastTrafficAt <= 0) {
        this.lastUp = t.up;
        this.lastDown = t.down;
        this.lastTrafficAt = startedAt;
        AppStorage.setOrCreate('vpnUpSpeed', 0);
        AppStorage.setOrCreate('vpnDownSpeed', 0);
      } else {
        const elapsedSeconds = Math.max(0.001, (startedAt - this.lastTrafficAt) / 1000);
        AppStorage.setOrCreate('vpnUpSpeed', Math.max(0, Math.round((t.up - this.lastUp) / elapsedSeconds)));
        AppStorage.setOrCreate('vpnDownSpeed', Math.max(0, Math.round((t.down - this.lastDown) / elapsedSeconds)));
        this.lastUp = t.up;
        this.lastDown = t.down;
        this.lastTrafficAt = startedAt;
      }
      AppStorage.setOrCreate('vpnTotalUp', t.up);
      AppStorage.setOrCreate('vpnTotalDown', t.down);
    };
    void poll();
    this.speedTimer = setInterval(() => { void poll(); }, 1000);
  }

  private startUptimeTimer(): void {
    this.stopUptimeTimer();
    const stored: number = AppStorage.get<number>('uiUptimeStart') ?? 0;
    const startedAt = stored > 0 ? stored : Date.now();
    AppStorage.setOrCreate('uiUptimeStart', startedAt);
    this.uiUptime = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
    AppStorage.setOrCreate('uiUptime', this.uiUptime);
    this.uptimeTimer = setInterval(() => {
      this.uiUptime = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
      AppStorage.setOrCreate('uiUptime', this.uiUptime);
    }, 1000);
  }

  private stopUptimeTimer(): void {
    if (this.uptimeTimer >= 0) {
      clearInterval(this.uptimeTimer);
      this.uptimeTimer = -1;
    }
    this.uiUptime = 0;
    AppStorage.setOrCreate('uiUptime', 0);
    AppStorage.setOrCreate('uiUptimeStart', 0);
  }

  private stopSpeedPoller(): void {
    this.speedPollGeneration++;
    if (this.speedTimer >= 0) {
      clearInterval(this.speedTimer);
      this.speedTimer = -1;
    }
    this.lastUp = 0;
    this.lastDown = 0;
    this.lastTrafficAt = 0;
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
  }

  // ---------------------------------------------------------------- 连接控制

  private uptimeText(): string {
    const hours = Math.floor(this.uiUptime / 3600);
    const minutes = Math.floor((this.uiUptime % 3600) / 60);
    const seconds = this.uiUptime % 60;
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${pad(hours)}:${pad(minutes)}:${pad(seconds)}`;
  }

  statusDisplay(): ResourceStr {
    const s = this.statusText;
    if (s === 'connecting') {
      return $r('app.string.status_connecting');
    }
    if (s === 'disconnecting') {
      return $r('app.string.status_disconnecting');
    }
    if (s === 'disconnected') {
      return $r('app.string.status_disconnected');
    }
    if (s === 'switching') {
      return $r('app.string.status_switching');
    }
    if (s === 'start_timeout') {
      return $r('app.string.status_start_timeout');
    }
    if (s === 'awaiting_auth') {
      return $r('app.string.status_awaiting_auth');
    }
    if (s.startsWith('connected:')) {
      return $r('app.string.status_connected_node', s.substring('connected:'.length));
    }
    if (s.startsWith('start_failed:')) {
      return $r('app.string.status_start_failed', s.substring('start_failed:'.length));
    }
    if (s.startsWith('connect_failed:')) {
      return $r('app.string.status_connect_failed', s.substring('connect_failed:'.length));
    }
    return s;
  }

  async connectTo(p: Profile): Promise<void> {
    if (this.isRunning) {
      promptAction.showToast({ message: $r('app.string.disconnect_first') });
      return;
    }
    this.selectedId = p.id;
    await writePrefString('selected_profile_id', p.id);
    try {
      await VpnService.connect(this.context, p.id);
    } catch (e) {
      // 状态已在 VpnService 中更新
    }
  }

  async disconnect(): Promise<void> {
    await VpnService.disconnect(this.context);
  }

  private selectedProfile(): Profile | undefined {
    return this.profiles.find((profile: Profile) => profile.id === this.selectedId);
  }

  async toggleVpn(): Promise<void> {
    if (this.isRunning) {
      await this.disconnect();
      return;
    }
    const target = this.selectedProfile();
    if (target === undefined) {
      promptAction.showToast({ message: $r('app.string.select_or_create_profile') });
      return;
    }
    await this.connectTo(target);
  }

  /** 点击节点:未运行则选中;运行中点其他节点 = 热切换 */
  async onNodeTap(p: Profile): Promise<void> {
    this.selectedId = p.id;
    await writePrefString('selected_profile_id', p.id);
    if (!this.isRunning) {
      return;
    }
    if (this.switching) {
      promptAction.showToast({ message: $r('app.string.switching_wait') });
      return;
    }
    const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (runningId.length > 0 && runningId === p.id) {
      return;
    }
    this.switching = true;
    try {
      promptAction.showToast({ message: $r('app.string.switching_to_name', p.name) });
      await VpnService.switchTo(this.context, p.id);
    } finally {
      this.switching = false;
    }
  }

  async switchOutboundMode(mode: string): Promise<void> {
    if (!OUTBOUND_MODES.includes(mode) || this.settings.mode === mode) {
      return;
    }
    this.settings.mode = mode;
    await saveSettings(this.settings);
    if (this.isRunning) {
      const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? this.selectedId;
      if (profileId.length > 0) {
        await VpnService.connect(this.context, profileId, true);
      }
    }
  }

  // ---------------------------------------------------------------- 测速

  /** 测速一组节点(用户 2026-10-17:不再支持全量)。缺省 = 当前选中分组;
   *  分组条长按"测速本组"传被按的那个组 id。 */
  async runSpeedTest(groupId: string = this.selectedGroupId): Promise<void> {
    if (this.testing) {
      // 之前是静默 return:测速进行中再点测速毫无反馈,像"点了没反应"
      promptAction.showToast({ message: $r('app.string.index_test_in_progress') });
      return;
    }
    const targets = this.profiles.filter((item: Profile) => item.groupId === groupId);
    if (targets.length === 0) {
      promptAction.showToast({ message: $r('app.string.speed_test_group_empty') });
      return;
    }
    /* 只清掉本组节点的旧延迟显示(其它组的历史结果保留),让本组测速中显示"…" */
    const targetIds = new Set<string>(targets.map((item: Profile) => item.id));
    const kept: Record<string, number> = {};
    for (const k of Object.keys(this.latencies)) {
      if (!targetIds.has(k)) {
        kept[k] = this.latencies[k];
      }
    }
    this.latencies = kept;
    promptAction.showToast({ message: $r('app.string.index_testing_count', targets.length) });
    await this.runProfilesTest(targets);
  }

  async runGroupSpeedTest(groupId: string): Promise<void> {
    await this.runSpeedTest(groupId);
  }

  private async runProfilesTest(snapshot: Array<Profile>): Promise<void> {
    this.testing = true;
    /* 结果不能逐条写 @State:每张节点卡的延迟文本都依赖 latencies,逐条写会
       把主页整页重渲染 N 次,节点多时 UI 线程被刷爆 —— 表现为"测速中页面卡死、
       点搜索/点按钮都没反应"。结果先进缓冲,每 300ms 合并刷一次,测完补最后一次。 */
    let pending: Record<string, number> = {};
    let flushTimer = -1;
    const flushPending = (): void => {
      if (flushTimer >= 0) {
        clearTimeout(flushTimer);
        flushTimer = -1;
      }
      const keys = Object.keys(pending);
      if (keys.length === 0) {
        return;
      }
      const next: Record<string, number> = {};
      for (const k of Object.keys(this.latencies)) {
        next[k] = this.latencies[k];
      }
      for (const k of keys) {
        next[k] = pending[k];
      }
      this.latencies = next;
      pending = {};
    };
    const onOne = (id: string, ms: number): void => {
      pending[id] = ms;
      const profile = this.profiles.find((item: Profile) => item.id === id);
      if (profile !== undefined) {
        profile.latencyMs = ms;
        profile.latencyTestedAt = Date.now();
        const runningProfileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
        if (this.isRunning && runningProfileId === id) {
          publishVpnLatency(id, profile.name, ms);
        }
      }
      if (flushTimer < 0) {
        flushTimer = setTimeout(flushPending, 300);
      }
    };
    try {
      if (this.settings.latencyTestMode === 'tcp') {
        await testProfiles(snapshot, onOne, this.settings.testConcurrent);
      } else {
        /* 上游签名：urlTestProfiles(targets, allProfiles, settings, context, onResult, concurrency, groups)
           —— 超时由 settings.testTimeoutMs 决定（不再传 5000），返回 LatencyRunReport。 */
        const report = await urlTestProfiles(snapshot, this.profiles, this.settings, this.context,
          onOne, this.settings.testConcurrent, this.groups);
        if (report.degraded) {
          // 内核测速起不来而回退 TCPing 时,数值含义完全变了(只反映握手耗时),
          // 必须明示,否则用户拿着假数据对比 Clash
          promptAction.showToast({ message: $r('app.string.speed_test_degraded', report.degradeReason) });
        }
      }
      flushPending();
      await saveProfiles(this.profiles);
      this.profiles = this.profiles.slice();
      promptAction.showToast({ message: $r('app.string.speed_test_complete') });
    } finally {
      flushPending();
      this.testing = false;
    }
  }

  /** 清除当前分组测试结果 */
  async clearTestResults(groupId: string): Promise<void> {
    let changed = false;
    for (const p of this.profiles) {
      if ((groupId === '__all__' || p.groupId === groupId) && p.latencyMs !== 0) {
        p.latencyMs = 0;
        p.latencyTestedAt = 0;
        changed = true;
      }
    }
    const next: Record<string, number> = {};
    this.latencies = next;
    if (changed) {
      await saveProfiles(this.profiles);
      this.profiles = this.profiles.slice();
      promptAction.showToast({ message: $r('app.string.test_results_cleared') });
    }
  }

  /** 去重(当前分组,按 名称+类型+服务器+端口+凭据) */
  async dedupGroup(groupId: string): Promise<void> {
    const seen = new Set<string>();
    const kept: Array<Profile> = [];
    let removed = 0;
    for (const p of this.profiles) {
      if (groupId !== '__all__' && p.groupId !== groupId) {
        kept.push(p);
        continue;
      }
      const key = `${p.name}\u001f${p.type}\u001f${p.server}\u001f${p.serverPort}\u001f${p.uuid}\u001f${p.password}`;
      if (seen.has(key)) {
        removed++;
        continue;
      }
      seen.add(key);
      kept.push(p);
    }
    if (removed > 0) {
      this.profiles = kept;
      await saveProfiles(kept);
      promptAction.showToast({ message: $r('app.string.dedup_done', removed) });
    } else {
      promptAction.showToast({ message: $r('app.string.dedup_none') });
    }
  }

  /** 删除当前分组不可用节点(最近测速失败) */
  deleteUnavailable(groupId: string): void {
    const dead = this.profiles.filter((p: Profile) => (groupId === '__all__' || p.groupId === groupId) && p.latencyMs === -1);
    if (dead.length === 0) {
      promptAction.showToast({ message: $r('app.string.no_unavailable_nodes') });
      return;
    }
    AlertDialog.show({
      message: $r('app.string.confirm_delete_unavailable', dead.length),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          const deadIds = new Set<string>(dead.map((p: Profile) => p.id));
          this.profiles = this.profiles.filter((p: Profile) => !deadIds.has(p.id));
          await saveProfiles(this.profiles);
          promptAction.showToast({ message: $r('app.string.dedup_done', dead.length) });
        }
      }
    });
  }

  async setSortMode(mode: string): Promise<void> {
    this.settings.profileSortMode = mode;
    await saveSettings(this.settings);
    this.profiles = this.profiles.slice();
  }

  /** 更新当前选中节点所属的订阅(对齐安卓 action_update_subscription) */
  async updateCurrentSubscription(): Promise<void> {
    const selected = this.profiles.find((p: Profile) => p.id === this.selectedId);
    const url = selected !== undefined ? selected.subUrl : this.activeConfigUrl;
    if (url.length === 0) {
      promptAction.showToast({ message: $r('app.string.current_subscription_missing') });
      return;
    }
    promptAction.showToast({ message: $r('app.string.fetching_subscription') });
    try {
      const r = await updateSubscription(url);
      await this.refresh();
      promptAction.showToast({ message: $r('app.string.sub_update_result', r.added, r.removed) });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.update_failed_reason', subErrorText(e as Object)) });
    }
  }

  /** 清除累计流量统计(对齐安卓 action_clear_traffic_statistics) */
  clearTrafficStatistics(): void {
    this.lastUp = 0;
    this.lastDown = 0;
    this.lastTrafficAt = 0;
    AppStorage.setOrCreate('vpnTotalUp', 0);
    AppStorage.setOrCreate('vpnTotalDown', 0);
    promptAction.showToast({ message: $r('app.string.traffic_stats_cleared') });
  }

  // ---------------------------------------------------------------- 分组/节点数据

  sortedProfiles(): Array<Profile> {
    return this.profiles.slice().sort((a: Profile, b: Profile) => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      if (a.groupId !== b.groupId) {
        return 0;
      }
      if (this.settings.profileSortMode === 'name') {
        return a.name.localeCompare(b.name);
      }
      if (this.settings.profileSortMode === 'latency') {
        const aLatency = this.latencyValueOf(a);
        const bLatency = this.latencyValueOf(b);
        return aLatency - bLatency;
      }
      if (a.sortOrder !== b.sortOrder) {
        return a.sortOrder - b.sortOrder;
      }
      return this.latencyValueOf(a) - this.latencyValueOf(b);
    });
  }

  private latencyValueOf(p: Profile): number {
    const ms = this.latencies[p.id];
    if (ms !== undefined) {
      return ms < 0 ? Number.MAX_SAFE_INTEGER : ms;
    }
    if (p.latencyMs < 0) {
      return Number.MAX_SAFE_INTEGER;
    }
    return p.latencyMs === 0 ? Number.MAX_SAFE_INTEGER : p.latencyMs;
  }

  profilesInGroup(groupId: string): Array<Profile> {
    return this.sortedProfiles().filter((p: Profile) => p.groupId === groupId);
  }

  sortedGroupIds(): Array<string> {
    const ids: Array<string> = [];
    const sortedGroups = this.groups.slice().sort((a: ProfileGroup, b: ProfileGroup) => a.sortOrder - b.sortOrder);
    for (const group of sortedGroups) {
      if (this.profiles.some((profile: Profile) => profile.groupId === group.id)) {
        ids.push(group.id);
      }
    }
    if (this.profiles.some((profile: Profile) => profile.groupId.length === 0)) {
      ids.push('');
    }
    return ids;
  }

  private visibleProfiles(groupId: string): Array<Profile> {
    const query = this.nodeSearch.trim().toLowerCase();
    const profiles = this.profilesInGroup(groupId);
    if (query.length === 0) {
      return profiles;
    }
    return profiles.filter((profile: Profile) =>
      profile.name.toLowerCase().includes(query)
      || profile.server.toLowerCase().includes(query));
  }

  // ---------------------------------------------------------------- 分组折叠列表(对齐安卓分组展示)

  displayGroupIds(): Array<string> {
    const ids = this.sortedGroupIds();
    if (this.nodeSearch.trim().length === 0) {
      return ids;
    }
    return ids.filter((groupId: string) => this.visibleProfiles(groupId).length > 0);
  }

  /** 组内最优延迟(仅计成功值;无有效值返回 -1) */
  private groupMinLatency(groupId: string): number {
    let min = -1;
    for (const p of this.profilesInGroup(groupId)) {
      let ms = this.latencies[p.id];
      if (ms === undefined && p.latencyMs !== 0) {
        ms = p.latencyMs;
      }
      if (ms !== undefined && ms > 0 && (min < 0 || ms < min)) {
        min = ms;
      }
    }
    return min;
  }

  private latencyColorOfMs(ms: number): ResourceColor {
    if (ms < 0) {
      return $r('app.color.error');
    }
    if (ms < 150) {
      return $r('app.color.success');
    }
    if (ms < 400) {
      return $r('app.color.warning');
    }
    return $r('app.color.error');
  }

  groupName(groupId: string): ResourceStr {
    if (groupId.length === 0) {
      return $r('app.string.ungrouped');
    }
    const group = this.groups.find((item: ProfileGroup) => item.id === groupId);
    return group === undefined ? $r('app.string.ungrouped') : group.name;
  }

  async moveProfile(p: Profile, delta: number): Promise<void> {
    const peers = this.profilesInGroup(p.groupId).filter((item: Profile) => item.pinned === p.pinned);
    const index = peers.findIndex((item: Profile) => item.id === p.id);
    const targetIndex = index + delta;
    if (index < 0 || targetIndex < 0 || targetIndex >= peers.length) {
      return;
    }
    for (let i = 0; i < peers.length; i++) {
      peers[i].sortOrder = i;
    }
    const target = peers[targetIndex];
    const currentOrder = p.sortOrder;
    p.sortOrder = target.sortOrder;
    target.sortOrder = currentOrder;
    await saveProfiles(this.profiles);
    this.profiles = this.profiles.slice();
  }

  async togglePinned(p: Profile): Promise<void> {
    p.pinned = !p.pinned;
    await saveProfiles(this.profiles);
    this.profiles = this.profiles.slice();
  }

  /** 移动到分组(对齐安卓多选择"移动"/节点编辑分组选择) */
  private moveDialog: CustomDialogController | undefined = undefined;

  openMoveToGroup(p: Profile): void {
    this.moveDialog = new CustomDialogController({
      builder: MoveToGroupDialog({
        groups: this.groups,
        currentGroupId: p.groupId,
        profileName: p.name,
        onPick: async (groupId: string) => {
          if (this.moveDialog !== undefined) {
            this.moveDialog.close();
          }
          if (p.groupId === groupId) {
            return;
          }
          p.groupId = groupId;
          await saveProfiles(this.profiles);
          this.profiles = this.profiles.slice();
          promptAction.showToast({ message: $r('app.string.move_to_group_done') });
        }
      }),
      autoCancel: true
    });
    this.moveDialog.open();
  }

  latencyText(p: Profile): ResourceStr {
    let ms = this.latencies[p.id];
    if (ms === undefined && p.latencyMs !== 0) {
      ms = p.latencyMs;
    }
    if (this.testing && ms === undefined) {
      return '…';
    }
    if (ms === undefined) {
      return '';
    }
    return ms < 0 ? $r('app.string.timeout') : `${ms}ms`;
  }

  latencyColor(p: Profile): ResourceColor {
    let ms = this.latencies[p.id];
    if (ms === undefined && p.latencyMs !== 0) {
      ms = p.latencyMs;
    }
    if (ms === undefined) {
      return $r('app.color.text_3');
    }
    if (ms < 0) {
      return $r('app.color.error');
    }
    if (ms < 150) {
      return $r('app.color.success');
    }
    if (ms < 400) {
      return $r('app.color.warning');
    }
    return $r('app.color.error');
  }

  async runUrlTest(p: Profile): Promise<void> {
    if (!this.isRunning) {
      promptAction.showToast({ message: $r('app.string.url_test_requires_connection') });
      return;
    }
    const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (runningId !== p.id) {
      promptAction.showToast({ message: $r('app.string.url_test_current_profile_only') });
      return;
    }
    try {
      const delay = await fetchCurrentProxyDelay(5000, this.settings.clashApiPort, this.settings.testUrl);
      const next: Record<string, number> = {};
      for (const key of Object.keys(this.latencies)) {
        next[key] = this.latencies[key];
      }
      next[p.id] = delay;
      this.latencies = next;
      promptAction.showToast({ message: $r('app.string.url_test_result', delay) });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message });
    }
  }

  deleteProfile(p: Profile): void {
    AlertDialog.show({
      message: $r('app.string.confirm_delete_profile_name', p.name),
      primaryButton: {
        value: $r('app.string.cancel'), action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.delete'), fontColor: $r('app.color.error'), action: () => {
          this.profiles = this.profiles.filter(x => x.id !== p.id);
          saveProfiles(this.profiles);
        }
      }
    });
  }

  // ---------------------------------------------------------------- 分享/导出

  @State shareText: string = '';
  @State shareQr: image.PixelMap | null = null;
  private shareDialog: CustomDialogController = new CustomDialogController({
    builder: ShareTextDialog({
      text: $shareText,
      qrPixelMap: $shareQr,
      onCopy: async (text: string) => {
        await setClipboardText(text);
        promptAction.showToast({ message: $r('app.string.share_link_copied') });
      }
    }),
    autoCancel: true
  });

  async openProfileShare(p: Profile): Promise<void> {
    const link = exportProfileLink(p);
    if (link.length === 0) {
      promptAction.showToast({ message: $r('app.string.protocol_export_unsupported') });
      return;
    }
    this.shareText = link;
    // 生成二维码(对齐安卓分享界面展示二维码);失败时弹窗退化为纯文本+复制
    this.shareQr = null;
    try {
      const options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        width: 440,
        height: 440
      };
      this.shareQr = await generateBarcode.createBarcode(link, options);
    } catch (e) {
      LogStore.addLog(`[ui] 二维码生成失败,降级为文本分享: ${e}`);
    }
    this.shareDialog.open();
  }

  async copyProfileLink(p: Profile): Promise<void> {
    const link = exportProfileLink(p);
    if (link.length === 0) {
      promptAction.showToast({ message: $r('app.string.protocol_export_unsupported') });
      return;
    }
    await setClipboardText(link);
    promptAction.showToast({ message: $r('app.string.profile_link_copied') });
  }

  /** 导出节点为 sing-box 出站 JSON(对齐安卓「导出配置」) */
  async exportProfileConfig(p: Profile): Promise<void> {
    try {
      const json = buildOutboundJson(p, this.settings);
      await setClipboardText(json);
      promptAction.showToast({ message: $r('app.string.outbound_config_copied') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.export_failed_generic', e instanceof Error ? e.message : `${e}`) });
    }
  }

  /** 把节点 sing-box 出站 JSON 写入用户选择的文件(对齐安卓 action_config_export_file) */
  async exportProfileConfigFile(p: Profile): Promise<void> {
    try {
      const json = buildOutboundJson(p, this.settings);
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const fileName = `${p.name.length > 0 ? p.name : p.id}.json`;
      const uris = await documentPicker.save({
        newFileNames: [fileName],
        fileSuffixChoices: ['JSON|.json']
      });
      if (uris.length === 0) {
        promptAction.showToast({ message: $r('app.string.backup_export_cancelled') });
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, json);
      } finally {
        fs.closeSync(file);
      }
      promptAction.showToast({ message: $r('app.string.outbound_config_exported') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.export_failed_generic', e instanceof Error ? e.message : `${e}`) });
    }
  }

  @Builder
  profileContextMenu(p: Profile) {
    Column() {
      MenuItem({ content: p.pinned ? $r('app.string.unpin') : $r('app.string.pin') })
        .onClick(() => this.togglePinned(p))
      if (this.settings.profileSortMode === 'manual') {
        MenuItem({ content: $r('app.string.move_up') })
          .onClick(() => this.moveProfile(p, -1))
        MenuItem({ content: $r('app.string.move_down') })
          .onClick(() => this.moveProfile(p, 1))
      }
      MenuItem({ content: $r('app.string.url_test') })
        .onClick(() => this.runUrlTest(p))
      MenuItem({ content: $r('app.string.copy_share_link') })
        .onClick(() => this.copyProfileLink(p))
      MenuItem({ content: $r('app.string.share_profile') })
        .onClick(() => this.openProfileShare(p))
      MenuItem({ content: $r('app.string.export_outbound_config') })
        .onClick(() => this.exportProfileConfig(p))
      MenuItem({ content: $r('app.string.export_outbound_config_file') })
        .onClick(() => this.exportProfileConfigFile(p))
      MenuItem({ content: $r('app.string.profile_edit_title') })
        .onClick(() => {
          AppStorage.setOrCreate('editProfileId', p.id);
          router.pushUrl({ url: 'pages/ProfileEdit' });
        })
      MenuItem({ content: $r('app.string.move_to_group') })
        .onClick(() => this.openMoveToGroup(p))
      if (p.subUrl.length > 0) {
        MenuItem({ content: $r('app.string.view_subscription') })
          .onClick(() => router.pushUrl({ url: 'pages/SubDetailPage', params: { url: p.subUrl } }))
      }
      MenuItem({ content: $r('app.string.delete'), labelInfo: $r('app.string.irreversible') })
        .onClick(() => this.deleteProfile(p))
    }
  }

  // ---------------------------------------------------------------- 导入

  @State importText: string = '';
  @State importName: string = '';
  private importDialog: CustomDialogController = new CustomDialogController({
    builder: ImportDialog({
      text: $importText,
      name: $importName,
      onImport: (t: string, name: string) => {
        this.doImport(t, name);
      },
      onPickClipboard: () => {
        this.fillDialogFromClipboard();
      }
    }),
    autoCancel: true
  });

  private addEntryDialog: CustomDialogController = new CustomDialogController({
    builder: AddEntryDialog({
      onNewProfile: () => {
        AppStorage.setOrCreate('editProfileId', '');
        router.pushUrl({ url: 'pages/ProfileEdit' });
      },
      onImportSubscription: () => {
        this.openImportDialog();
      },
      onImportClipboard: () => {
        this.quickImportClipboard();
      },
      onScan: () => {
        this.scanImport();
      },
      onImportFile: () => {
        this.importFromFile();
      }
    }),
    autoCancel: true
  });

  /**
   * 扫码导入(对齐安卓 ScannerActivity):系统扫描 UI,无需相机权限声明。
   * 结果复用 doImport 管道(订阅容器/订阅链接/分享链接 + 导入确认对话框)。
   * 12900010 = 用户取消,静默返回。
   */
  async scanImport(): Promise<void> {
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      };
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(this.context, options);
      const value = result.originalValue.trim();
      if (value.length === 0) {
        promptAction.showToast({ message: $r('app.string.scan_no_content') });
        return;
      }
      LogStore.addLog(`[ui] 扫码导入: ${value.substring(0, 40)}…`);
      await this.doImport(value, '');
    } catch (e) {
      const err = e as BusinessError;
      // 1000500002 = 扫描服务取消;12900010 = 用户主动取消(部分版本)
      if (err !== undefined && (err.code === 1000500002 || err.code === 12900010)) {
        return;
      }
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 扫码失败: ${msg}`);
      promptAction.showToast({ message: $r('app.string.scan_failed_use_paste', msg) });
    }
  }

  /**
   * 从文件导入(对齐安卓 ConfigurationFragment.action_import_file → GetContent + parseRaw):
   * 普通文本文件(.txt/.json/.conf/订阅 base64)读取内容后复用 doImport 全管道;
   * .zip 按 WireGuard 导出包解析(对齐安卓 zip 分支,逐 entry 解析、entry 名作节点名)。
   */
  async importFromFile(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const uris: Array<string> = await documentPicker.select({ maxSelectNumber: 1 });
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const fileName = decodeURIComponent(uri.split('/').pop() ?? '');
      // 复制到缓存后用路径读取(picker URI 与 readTextSync 路径语义更稳)
      const cachePath = `${this.context.cacheDir}/import_${Date.now()}_${fileName}`;
      fs.copyFileSync(uri, cachePath);
      if (fileName.toLowerCase().endsWith('.zip')) {
        await this.importWireGuardZip(cachePath);
        try {
          fs.unlinkSync(cachePath);
        } catch (e) {
          // 清理失败不影响导入结果
        }
        return;
      }
      const text = fs.readTextSync(cachePath);
      try {
        fs.unlinkSync(cachePath);
      } catch (e) {
        // 同上
      }
      if (text.trim().length === 0) {
        promptAction.showToast({ message: $r('app.string.no_proxies_found_in_file') });
        return;
      }
      await this.doImport(text, '');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 文件导入失败: ${msg}`);
      promptAction.showToast({ message: $r('app.string.import_file_failed', msg) });
    }
  }

  /** 解析 WireGuard zip 导出包并批量导入(zlib 解压 → 逐文件 parseShareText → 单次确认) */
  async importWireGuardZip(zipPath: string): Promise<void> {
    const outDir = `${this.context.cacheDir}/wg_zip_${Date.now()}`;
    fs.mkdirSync(outDir, true);
    await zlib.decompressFile(zipPath, outDir);
    const collected: Array<Profile> = [];
    for (const name of fs.listFileSync(outDir)) {
      const entryPath = `${outDir}/${name}`;
      try {
        if (fs.statSync(entryPath).isDirectory()) {
          continue;
        }
      } catch (e) {
        continue;
      }
      let text = '';
      try {
        text = fs.readTextSync(entryPath);
      } catch (e) {
        // 二进制/无法按 UTF-8 读取的 entry 跳过(对齐安卓 parseRaw 返回 null)
        continue;
      }
      if (text.trim().length === 0) {
        continue;
      }
      const baseName = name.replace(/\.(conf|txt|json)$/i, '');
      for (const p of parseShareText(text)) {
        if (p.name.trim().length === 0) {
          p.name = baseName;
        }
        collected.push(p);
      }
    }
    try {
      fs.rmdirSync(outDir);
    } catch (e) {
      // 清理失败忽略
    }
    if (collected.length === 0) {
      promptAction.showToast({ message: $r('app.string.no_proxies_found_in_file') });
      return;
    }
    const confirmed: boolean = await new Promise<boolean>((resolve: (v: boolean) => void) => {
      AlertDialog.show({
        message: $r('app.string.import_file_message', collected.length),
        primaryButton: {
          value: $r('app.string.cancel'),
          action: () => {
            resolve(false);
          }
        },
        secondaryButton: {
          value: $r('app.string.import_confirm'),
          action: () => {
            resolve(true);
          }
        }
      });
    });
    if (!confirmed) {
      return;
    }
    await initStore(this.context);
    const profiles = await loadProfiles();
    for (const p of collected) {
      p.id = this.genId();
      p.updatedAt = Date.now();
      profiles.push(p);
    }
    await saveProfiles(profiles);
    this.profiles = profiles;
    promptAction.showToast({ message: $r('app.string.imported_count', collected.length) });
    this.refresh();
  }

  /**
   * 导入前确认(对齐安卓 importSubscription/importProfile 的 MaterialAlertDialog):
   * 订阅带安全提示(来源不可信会泄漏 IP),单节点仅确认名称。
   * 返回 true 表示用户同意导入。
   */
  confirmImport(isSubscription: boolean, name: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      const message = isSubscription
        ? $r('app.string.subscription_import_message', name)
        : $r('app.string.profile_import_message', name);
      AlertDialog.show({
        message: message,
        primaryButton: {
          value: $r('app.string.cancel'),
          action: () => { resolve(false); }
        },
        secondaryButton: {
          value: $r('app.string.import_confirm'),
          action: () => { resolve(true); }
        }
      });
    });
  }

  async openImportDialog(): Promise<void> {    this.importText = '';
    await initStore(this.context);
    this.importName = await readPrefString('recent_subscription_group', '');
    this.importDialog.open();
  }

  async quickImportClipboard(): Promise<void> {
    const t = await getClipboardText();
    if (t.trim().length === 0) {
      promptAction.showToast({ message: $r('app.string.clipboard_empty_paste_manually') });
      return;
    }
    await this.openImportDialog();
    this.importText = t;
  }

  async fillDialogFromClipboard(): Promise<void> {
    const t = await getClipboardText();
    this.importText = t;
    if (t.trim().length === 0) {
      promptAction.showToast({ message: $r('app.string.clipboard_empty_paste_manually') });
    }
  }

  async doImport(raw: string, requestedName: string): Promise<void> {
    try {
      const text = raw === undefined || raw === null ? '' : raw;
      if (text.trim().length === 0) {
        promptAction.showToast({ message: $r('app.string.paste_subscription_or_profile_link') });
        return;
      }
      const firstLine = text.trim().split(/[\r\n]+/)[0].trim();
      // 订阅容器 Scheme(对齐安卓 SubscriptionFoundException → importSubscription)
      if (isSagerNetSubscriptionContainer(firstLine)) {
        LogStore.addLog('[ui] 收到 sn://subscription 容器链接,该格式为 SagerNet 私有序列化,当前无法解包');
        promptAction.showToast({ message: $r('app.string.subscription_container_unsupported') });
        return;
      }
      const container = unwrapSubscriptionLink(firstLine);
      // clash://install-config 解包出的真实订阅地址;名称为空时沿用调用方传入的名称
      const importName = container !== null && container.name.length > 0 ? container.name : requestedName;
      const subscriptionUrl = container !== null ? container.url : firstLine;
      let parsed: Array<Profile> = [];
      let subUrl = '';
      let subUserinfo = '';
      if (subscriptionUrl.startsWith('http://') || subscriptionUrl.startsWith('https://')) {
        // 订阅链接:先弹确认(对齐安卓 subscription_import_message 的安全提示),再下载解析
        const confirmName = importName.trim().length > 0 ? importName.trim() : subNameOf(subscriptionUrl);
        const confirmed = await this.confirmImport(true, confirmName);
        if (!confirmed) {
          return;
        }
        promptAction.showToast({ message: $r('app.string.fetching_subscription') });
        subUrl = subscriptionUrl;
        const fetched = await fetchSubscriptionWithInfo(subscriptionUrl, this.settings.subAllowInsecure);
        const content = fetched.content;
        subUserinfo = fetched.userinfo;
        if (looksLikeClashYaml(content)) {
          const r: ClashParseResult = parseClashProxies(content);
          parsed = r.profiles;
          if (parsed.length === 0) {
            promptAction.showToast({
              message: $r('app.string.clash_skipped_count', r.skipped)
            });
            return;
          }
        } else if (looksLikeSingBoxJson(content)) {
          const r: ClashParseResult = parseSingBoxConfig(content);
          parsed = r.profiles;
          if (parsed.length === 0) {
            promptAction.showToast({
              message: $r('app.string.clash_skipped_count', r.skipped)
            });
            return;
          }
        } else {
          parsed = parseShareText(content);
        }
      } else {
        // 分享链接:解析后弹确认(对齐安卓 profile_import_message)
        parsed = parseShareText(text);
        if (parsed.length > 0) {
          const previewName = parsed.length === 1 ? parsed[0].name : '';
          const confirmed = await this.confirmImport(false, previewName);
          if (!confirmed) {
            return;
          }
        }
      }
      if (parsed.length === 0) {
        promptAction.showToast({ message: $r('app.string.no_recognizable_profiles') });
        return;
      }
      await initStore(this.context);
      const profiles = await loadProfiles();
      // 一订阅一分组:订阅导入的节点自动归入以订阅名命名的分组(不存在则创建)
      let subGroupId = '';
      if (subUrl.length > 0) {
        const nameForGroup = importName.trim().length > 0 ? importName.trim() : subNameOf(subUrl);
        subGroupId = await ensureGroupByName(nameForGroup);
      }
      for (const p of parsed) {
        p.id = this.genId();
        p.subUrl = subUrl;
        p.groupId = subGroupId;
        p.updatedAt = Date.now();
        profiles.push(p);
      }
      await saveProfiles(profiles);
      this.profiles = profiles;
      if (subUrl.length > 0) {
        await upsertSub(subUrl, subUserinfo, importName);
        this.activeConfigUrl = subUrl;
        await writePrefString('active_config_url', subUrl);
        const normalizedName = importName.trim();
        if (normalizedName.length > 0) {
          await writePrefString('recent_subscription_group', normalizedName);
        }
        const displayName = normalizedName.length > 0 ? normalizedName : subNameOf(subUrl);
        promptAction.showToast({ message: $r('app.string.imported_from_sub', parsed.length, displayName) });
      } else {
        promptAction.showToast({ message: $r('app.string.imported_count', parsed.length) });
      }
      this.refresh();
    } catch (e) {
      const msg = subErrorText(e as Object);
      LogStore.addLog(`[ui] 导入失败: ${msg}`);
      promptAction.showToast({ message: $r('app.string.import_failed_reason', msg) });
    }
  }

  private genId(): string {
    return `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
  }

  // ---------------------------------------------------------------- 抽屉导航(对齐安卓 Drawer;手搓列表,不用 HdsSideMenu)

  /** 抽屉列表项:[文案, 标识, 系统符号](顺序由模块级常量定义) */
  private drawerItems(): Array<[ResourceStr, string, Resource]> {
    const items: Array<[ResourceStr, string, Resource]> = [];
    for (let i = 0; i < DRAWER_ITEM_IDS.length; i++) {
      items.push([DRAWER_ITEM_LABELS[i], DRAWER_ITEM_IDS[i], DRAWER_ITEM_SYMBOLS[i]]);
    }
    return items;
  }

  /** 当前分区是否就是这一项(抽屉选中态) */
  private drawerItemActive(id: string): boolean {
    if (this.activeTab >= 0 && this.activeTab < TAB_TO_DRAWER_INDEX.length) {
      return DRAWER_ITEM_IDS[TAB_TO_DRAWER_INDEX[this.activeTab]] === id;
    }
    return id === 'config';
  }

  private onDrawerSelect(id: string): void {
    this.drawerOpen = false;
    if (id === 'config') {
      this.activeTab = 0;
    } else if (id === 'groups') {
      this.activeTab = 1;
    } else if (id === 'route') {
      this.activeTab = 2;
    } else if (id === 'settings') {
      this.activeTab = 3;
    } else if (id === 'logs') {
      this.activeTab = 4;
    } else if (id === 'tools') {
      this.activeTab = 5;
    } else if (id === 'about') {
      this.activeTab = 6;
    }
  }

  @Builder
  private drawerPanel() {
    Column() {
      // 头部:应用图标 + 名称 + 版本(对齐安卓 Drawer 头部)
      Row({ space: 12 }) {
        Image($r('app.media.icon'))
          .width(40)
          .height(40)
          .borderRadius(10)
          .alt($r('app.media.icon'))
        Column({ space: 2 }) {
          Text($r('app.string.brand_name'))
            .fontSize(16).fontWeight(800).fontColor($r('app.color.text_1'))
          Text(this.appVersion.length > 0 ? `v${this.appVersion}` : '')
            .fontSize(11).fontColor($r('app.color.text_3'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      /* 面板从 y=0 铺到屏底(遮罩要盖住状态栏),但**里面的内容必须躲开状态栏**:
         原来写死 30 ⇒ 图标/版本被状态栏压住(2.0.18 真机)。改成实测状态栏高度 + 12 呼吸位。 */
      .padding({ left: 20, right: 16, top: this.safeTopVp + 12, bottom: 16 })

      Divider().color($r('app.color.hairline')).strokeWidth(UiSpec.HAIRLINE_WIDTH)

      /* 抽屉列表:**手搓 Row 列表**(不用 HdsSideMenu —— 它要 SystemCapability.UIDesign.HDSPattern.Standard,
         本机设备上渲染不出来 ⇒ 抽屉"打不开"的根因,见项目记忆第六段)。图标是系统符号,按下带 HDS 点光。 */
      Column() {
        ForEach(this.drawerItems(), (item: [ResourceStr, string, Resource]) => {
          Row({ space: 14 }) {
            SymbolGlyph(item[2])
              .fontSize(19)
              .fontColor([this.drawerItemActive(item[1]) ? $r('app.color.primary') : $r('app.color.text_3')])
              .width(24)
            Text(item[0])
              .fontSize(14.5)
              .fontWeight(this.drawerItemActive(item[1]) ? 700 : 400)
              .fontColor(this.drawerItemActive(item[1]) ? $r('app.color.primary') : $r('app.color.text_2'))
              .layoutWeight(1)
          }
          .width('100%')
          .height(48)
          .padding({ left: 20, right: 14 })
          .borderRadius(12)
          .visualEffect(pressLightEffect(this.litKey === `drawer:${item[1]}`, false))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litKey = `drawer:${item[1]}`;
            } else if (event.type === TouchType.Up) {
              this.litKey = '';
              this.onDrawerSelect(item[1]);
            } else if (event.type === TouchType.Cancel) {
              this.litKey = '';
            }
          })
        }, (item: [ResourceStr, string, Resource]) => item[1])
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4 })
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text($r('app.string.drawer_footer'))
        .fontSize(10.5).fontColor($r('app.color.text_3'))
        .width('100%')
        .padding({ left: 20, bottom: this.navBottomVp + 12 })
    }
    /* 宽度显式给(不再写 '78%'):抽屉换边靠 **translate 平移**,位移量要按真实面板宽算 */
    .width(this.drawerPanelW())
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      // 吞掉点击事件,防止点面板空白处触发遮罩关闭
    })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.25)', offsetY: 0 })
    /* 面板本体也伸进上下系统栏区,否则日间模式底部会露出一条底色(用户实测) */
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    /* 开/关的进出动画:从**当前所在的边**滑入滑出(方向锁定在 drawerEdge,见 drawOverlay 的注释) */
    .transition(TransitionEffect.move(this.drawerEdge === 'left' ? TransitionEdge.START : TransitionEdge.END)
      .animation({ duration: 250, curve: Curve.Friction }))
  }

  /** 抽屉面板宽:窗口宽的 78%,上限 320vp(pageW 量不到时退回 300) */
  private drawerPanelW(): number {
    const w = this.pageW > 0 ? this.pageW : 384;
    return Math.min(w * 0.78, 320);
  }

  /** 抽屉的水平位移:左手 = 贴左(x=0),右手 = 推到右侧(窗口宽 − 面板宽) */
  private drawerOffsetX(): number {
    if (this.drawerEdge === 'left') {
      return 0;
    }
    const w = this.pageW > 0 ? this.pageW : 384;
    return Math.max(0, w - this.drawerPanelW());
  }

  /** 开抽屉:先定滑入方向(交互手那一侧),再挂载面板 ⇒ 从正确的一侧滑进来 */
  private openDrawer(): void {
    this.drawerEdge = this.handSide;
    this.drawerOpen = true;
  }

  /**
   * 智感握姿换手:抽屉**直接左右平移**过去(用户点名:不要"先收起再出现")。
   * 机制:遮罩 Row 恒为 `FlexAlign.Start` 对齐,面板位置全由 `translate(x)` 决定;
   *      `drawerEdge` 一变 ⇒ `translate` 变 ⇒ 外层那句 `.animation()` 自动补间 ⇒ 面板横着滑过去。
   * (原来用 justifyContent 换边,那是布局枚举、不可动画,才不得不"收起再滑入"。)
   */
  private onHandSideChanged(): void {
    if (!this.drawerOpen) {
      return;
    }
    this.drawerEdge = this.handSide;
  }

  @Builder
  private drawerOverlay() {
    if (this.drawerOpen) {
      Row() {
        /* 位移层:只负责左右平移(换手时动画)。里面那层面板自己负责开关的进出动画,两者不在同一节点上 ⇒ 不会互相覆盖 */
        Column() {
          this.drawerPanel()
        }
        .width(this.drawerPanelW())
        .height('100%')
        .translate({ x: this.drawerOffsetX() })
        .animation({ duration: 260, curve: Curve.EaseInOut })
      }
      .width('100%')
      .height('100%')
      /* ⚠️ 恒为 Start:换边是 translate 的事,这里不能跟着 handSide 变(布局枚举不可动画 ⇒ 会瞬移) */
      .justifyContent(FlexAlign.Start)
      .backgroundColor('rgba(0,0,0,0.35)')
      /* 抽屉在最外层 ⇒ 连同状态栏/手势条一起盖住 */
      .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onClick(() => {
        this.drawerOpen = false;
      })
    }
  }


  // ---------------------------------------------------------------- 配置页(对齐安卓 ConfigurationFragment)


  @Builder
  private modeSwitchRow() {
    Row({ space: 8 }) {
      ForEach(OUTBOUND_MODES, (mode: string, index: number) => {
        Button(OUTBOUND_MODE_LABELS[index])
          .layoutWeight(1)
          .height(28)
          .fontSize(12.5)
          /* 选中 = 品牌色实心胶囊 + 表面色文字(原来只有下缘一条细线,用户看不出选中) */
          .backgroundColor(this.settings.mode === mode ? $r('app.color.primary') : Color.Transparent)
          .fontColor(this.settings.mode === mode ? $r('app.color.surface') : $r('app.color.text_3'))
          .fontWeight(this.settings.mode === mode ? 700 : 400)
          .borderRadius(14)
          .visualEffect(pressLightEffect(this.litKey === `mode:${mode}`, true))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litKey = `mode:${mode}`;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litKey = '';
            }
          })
          .onClick(() => { void this.switchOutboundMode(mode); })
      }, (mode: string) => mode)
    }
    .width('100%')
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 0 })
    /* ⚠️ 这里**不要**挂 illuminatedEffect():点光的受光边框是**矩形**(不吃 borderRadius),
       整条模式行会被画成一个无圆角的方框(用户实测嫌难看) */
  }

  @Builder
  private groupContextMenu(groupId: string) {
    Column() {
      MenuItem({ content: $r('app.string.test_current_group') })
        .onClick(() => this.runGroupSpeedTest(groupId))
      MenuItem({ content: $r('app.string.clear_test_results') })
        .onClick(() => this.clearTestResults(groupId))
      MenuItem({ content: $r('app.string.dedup_action') })
        .onClick(() => this.dedupGroup(groupId))
      MenuItem({ content: $r('app.string.delete_unavailable') })
        .onClick(() => this.deleteUnavailable(groupId))
    }
  }

  @Builder
  private nodeCard(p: Profile) {
    // 对齐安卓 layout_profile:圆角卡片 + 选中描边 + 类型徽标 + 延迟着色
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        if (p.pinned) {
          /* 原来是 emoji 📌:emoji 的字形/配色由系统字体决定,深浅色与多设备下观感不可控 ⇒ 换系统符号 */
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(11)
            .fontColor([$r('app.color.warning')])
        }
        Text(p.name)
          .fontSize(14.5)
          .fontWeight(this.selectedId === p.id ? 800 : 600)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.latencyText(p).toString().length === 0 ? '—' : this.latencyText(p))
          .fontSize(12.5)
          .fontColor(this.latencyColor(p))
      }
      .width('100%')

      Row({ space: 6 }) {
        Text(profileTypeLabel(p.type))
          .fontSize(10)
          .fontWeight(600)
          .fontColor($r('app.color.mono'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor($r('app.color.surface_selected'))
        if (this.settings.alwaysShowAddress) {
          Text(p.server)
            .fontSize(10.5)
            .fontColor($r('app.color.text_3'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        } else {
          // 空白占位,保证徽标行与「始终显示地址」模式对齐
          Text('').layoutWeight(1)
        }
        if (this.settings.profileTrafficStatistics && (p.rx > 0 || p.tx > 0)) {
          // 历史累计流量(对齐安卓节点卡流量显示):↓接收 ↑发送
          Text(`↓${formatBytes(p.rx)} ↑${formatBytes(p.tx)}`)
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
            .maxLines(1)
        }
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(14)
    .border({ width: 1.5, color: this.selectedId === p.id ? $r('app.color.primary') : Color.Transparent })
    .shadow({ radius: 6, color: $r('app.color.shadow_color'), offsetY: 1 })
    /* 点按光效:节点卡在 List 里(会跟滚动跑位),按官方"不要在滚动组件里用常亮光源"的口径,
       只让它在**按下那一刻**成为光源(此刻内容是静止的),不挂常亮光源、也不挂受光(卡片自身有 border,
       受光会被 border 覆盖掉,配了也看不见)。 */
    .visualEffect(pressLightEffect(this.litKey === `node:${p.id}`, false))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = `node:${p.id}`;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => this.onNodeTap(p))
    .bindContextMenu(this.profileContextMenu(p), ResponseType.LongPress, {
          /* 光感背板：系统菜单窗口自己那层底太素(纯色板)，给它换成 HDS 同族的毛玻璃 */
          backgroundBlurStyle: BlurStyle.COMPONENT_THICK,
          backgroundBlurStyleOptions: {
            colorMode: ThemeColorMode.SYSTEM,
            adaptiveColor: AdaptiveColor.AVERAGE
          }
        })
  }

  /** 搜索态输入行:画在 HDS 顶栏 bottomBuilder 里,与分组条**同一条带互换**
   *  (用户点名位置:动作按钮行之下、模式行之上);总高 32,凑底部带恒 68 */
  @Builder
  private searchInputRow() {
    Row({ space: 2 }) {
      TextInput({ text: this.nodeSearch, placeholder: $r('app.string.search_nodes') })
        .id('nodeSearchInput')
        .layoutWeight(1).height(32)
        .padding({ top: 4, bottom: 4 })
        .backgroundColor(Color.Transparent)
        .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
        /* 输入防抖 250ms:每敲一个字就全量重筛 + 重建节点列表,大订阅会越打越卡 */
        .onChange((v: string) => { this.scheduleSearchFilter(v); })
      Text($r('app.string.cancel'))
        .fontSize(13).fontColor($r('app.color.text_2')).padding(6)
        .onClick(() => {
          this.closeNodeSearch();
        })
    }
    .width('100%')
    .height(32)
    .alignItems(VerticalAlign.Center)
    .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING - 10 })
  }

  @Builder
  private configFragment() {
    Column() {
      /* 原 configToolbar(连接/搜索/添加/更多)整排提进了 HDS 顶栏(stackBuilder 自绘 + ⋮ bindMenu)。
         搜索态输入行(用户点名放在动作按钮行与模式行之间)也画在顶栏 bottomBuilder 里,
         见 titleBottomBuilder()/searchInputRow();这里不再重复渲染。 */

      if (this.profiles.length === 0) {
        Column({ space: 10 }) {
          Text($r('app.string.no_profiles_title'))
            .fontSize(15).fontWeight(600).fontColor($r('app.color.text_2'))
          Text($r('app.string.no_profiles_hint'))
            .fontSize(12).fontColor($r('app.color.text_3'))
          Button($r('app.string.import_link_subscription'))
            .height(38)
            .backgroundColor($r('app.color.primary'))
            .fontColor($r('app.color.surface'))
            .onClick(() => this.openImportDialog())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8, scroller: this.configScroller }) {
          /* ★ 顶部占位项 = 顶栏高度(自校准值):列表的**框**铺满整屏(含状态栏),
             内容最前面垫一块占位 ⇒ 滚动时条目能**穿到顶栏后面**去(RzdMusic 那种沉浸感)。
             ⚠️ 不要用 List.contentStartOffset / 容器 padding:那两样会把内容**裁在**顶栏下方,永远滚不上去 */
          ListItem() {
            Row()
              .width('100%')
              /* space:8 已经贡献 8vp,这里减掉,避免首卡与顶栏之间多一条缝。
                 搜索态下顶栏 bottomBuilder 多了一行搜索框,探针量出的 contentTopInset
                 会自动变大,占位项跟着长高,列表首卡始终落在搜索行下方 */
              .height(Math.max(0, this.contentTopInset - 8))
          }
          .selectable(false)
          ForEach(this.visibleProfiles(this.selectedGroupId), (profile: Profile) => {
            ListItem() {
              this.nodeCard(profile)
            }
          }, (profile: Profile) => profile.id)
        }
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 14, right: 14, top: 0, bottom: 0 })
        /* 列表不裁剪自己的内容 ⇒ 条目能画到盒子顶边以外(状态栏那一段)。
           RzdVideo 首页的 `Scroll` / RzdMusic 首页的 `Scroll` 都是 `.clip(false)`(它们的内容才能顶到 y=0)。 */
        .clip(false)
        /* 探针（仅诊断用，无逻辑依赖）：hdc hilog 里可核对列表视口是否真的在窗口顶 */
        .id('nbListProbe')
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 分组分类条的显示顺序(订阅分组在前、未分组殿后),与原列表口径一致 */
  private groupTabIds(): Array<string> {
    return this.displayGroupIds();
  }

  /** 选中分组失效(被删/被合并/搜索无匹配)时回落到第一个 */
  private ensureSelectedGroup(): void {
    const ids = this.groupTabIds();
    if (ids.length === 0) {
      this.selectedGroupId = '';
      return;
    }
    if (!ids.includes(this.selectedGroupId)) {
      this.selectedGroupId = ids[0];
    }
  }

  /** 分组分类条:单独一行、横向左右切换;长按弹原分组的动作菜单(测速/清空/去重/删除失效) */
  @Builder
  private groupTabBar() {
    if (this.groupTabIds().length > 0) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.groupTabIds(), (groupId: string) => {
            /* 宿主用 Row(不是 Button):Button + .border() 会把 borderRadius 覆盖成 0(真机踩到,chip 变方框);
               Row 加 borderRadius 才真的圆角,而且**不加 border** —— 受光(点光 BORDER_CONTENT)才不被 border 覆盖 */
            Row({ space: 6 }) {
              Text(this.groupName(groupId))
                .fontSize(14)
                .fontWeight(this.selectedGroupId === groupId ? 700 : 400)
                .fontColor(this.selectedGroupId === groupId ? $r('app.color.primary') : $r('app.color.text_2'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 140 })
              Text($r('app.string.group_node_count', this.visibleProfiles(groupId).length))
                .fontSize(11.5)
                .fontColor($r('app.color.text_3'))
              if (this.groupMinLatency(groupId) >= 0) {
                Text($r('app.string.group_latency_minimum', this.groupMinLatency(groupId)))
                  .fontSize(11)
                  .fontColor(this.latencyColorOfMs(this.groupMinLatency(groupId)))
              }
            }
            .alignItems(VerticalAlign.Center)
            .height(32)
            .padding({ left: 14, right: 14 })
            .borderRadius(18)
            .backgroundColor(this.selectedGroupId === groupId
              ? $r('app.color.surface_selected')
              : $r('app.color.surface'))
            /* 按下发光 + 常挂受光(周围被点亮时它也会亮),无 border ⇒ 光效不被覆盖 */
            .visualEffect(pressLightEffect(this.litKey === `tab:${groupId}`, false))
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.litKey = `tab:${groupId}`;
              } else if (event.type === TouchType.Up) {
                this.litKey = '';
                this.selectedGroupId = groupId;
              } else if (event.type === TouchType.Cancel) {
                this.litKey = '';
              }
            })
            .bindContextMenu(this.groupContextMenu(groupId), ResponseType.LongPress, {
          backgroundBlurStyle: BlurStyle.COMPONENT_THICK,
          backgroundBlurStyleOptions: {
            colorMode: ThemeColorMode.SYSTEM,
            adaptiveColor: AdaptiveColor.AVERAGE
          }
        })
          }, (groupId: string) => groupId)
        }
        .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING - 10, top: 0, bottom: 0 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .align(Alignment.Start)
    }
  }

  // ---------------------------------------------------------------- 底部 StatsBar + FAB(对齐安卓)

  @Builder
  private statsBar() {
    Row({ space: 12 }) {
      Text(`↑ ${formatSpeed(this.upSpeed)}`)
        .fontSize(12).fontColor($r('app.color.text_2'))
        .fontFamily('monospace')
      Text(`↓ ${formatSpeed(this.downSpeed)}`)
        .fontSize(12).fontColor($r('app.color.text_2'))
        .fontFamily('monospace')
      Row({ space: 6 }) {
        Circle()
          .width(7).height(7)
          .fill(this.isRunning ? $r('app.color.dot_live') : $r('app.color.text_3'))
        Text(this.statusDisplay())
          .fontSize(12).fontColor($r('app.color.text_2'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height(44)
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
    .border({ width: { top: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
    /* 节点列表挂着 .clip(false),滚动时卡片会画到本条底部边界之外 ⇒ 无背景时
       速率文字和列表文字直接重叠。半透明底色 + 组件级毛玻璃:透出的是模糊光斑,
       文字不再互相干扰,且深浅色都由资源控制 */
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .backgroundColor($r('app.color.statsbar_bg'))
    .visualEffect(pressLightEffect(this.litKey === 'statsbar', false))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = 'statsbar';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => {
      const target = this.selectedProfile();
      if (target !== undefined && this.isRunning) {
        this.runUrlTest(target);
      }
    })
  }

  /**
   * 连接/断开大按钮(对齐安卓 FAB)。
   * 图标从字符 `■`/`▶` 换成系统符号;宿主换成 `Button`(点光源宿主白名单要 Button/Row/Column…,
   * 且 `pressShadow` 只在 Button 上生效),`stateEffect: false` 关掉自带按压态免得盖住 HDS 光效。
   */
  @Builder
  private fabButton(edge: TransitionEdge) {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      Stack() {
        if (this.statusText === 'connecting' || this.statusText === 'switching') {
          LoadingProgress()
            .width(26).height(26).color($r('app.color.surface'))
        } else {
          SymbolGlyph(this.isRunning ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(this.isRunning ? 26 : 24)
            .fontColor([$r('app.color.surface')])
        }
      }
    }
    .width(64)
    .height(64)
    .backgroundColor(this.isRunning ? $r('app.color.fab_running') : $r('app.color.fab_bg'))
    .shadow({ radius: 14, color: 'rgba(0,0,0,0.25)', offsetY: 4 })
    .visualEffect(pressLightEffect(this.litKey === 'fab', true))
    .scale({ x: this.litKey === 'fab' ? 0.93 : 1.0, y: this.litKey === 'fab' ? 0.93 : 1.0 })
    /* 换侧时按官方建议的 TransitionEffect.move 从那一侧滑入(与 RzdSchool 的握姿悬浮球同一手法) */
    .transition(TransitionEffect.move(edge).animation({ duration: 250, curve: Curve.Friction }))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = 'fab';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => this.toggleVpn())
  }

  /** 智感握姿:连接键跟着**交互手**走(识别不出时恒在右手侧,与改造前一致) */
  @Builder
  private fabLayer() {
    Row() {
      if (this.handSide === 'left') {
        this.fabButton(TransitionEdge.START)
      } else {
        this.fabButton(TransitionEdge.END)
      }
    }
    /* 与内容层同一套：matchParent + ignoreLayoutSafeArea ⇒ 盒子铺满整窗（真机已验证生效） */
    .width(LayoutPolicy.matchParent)
    .height(LayoutPolicy.matchParent)
    .justifyContent(this.handSide === 'left' ? FlexAlign.Start : FlexAlign.End)
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: 20, right: 20, bottom: this.navBottomVp + 20 })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  // ---------------------------------------------------------------- HDS 顶栏(对齐 HDS 设计系统)

  /** 顶栏主标题:跟随当前分区(与抽屉项同一批字符串资源) */
  private sectionTitle(): ResourceStr {
    if (this.activeTab === 1) {
      return $r('app.string.nav_groups');
    }
    if (this.activeTab === 2) {
      return $r('app.string.nav_route');
    }
    if (this.activeTab === 3) {
      return $r('app.string.settings_title');
    }
    if (this.activeTab === 4) {
      return $r('app.string.logs');
    }
    if (this.activeTab === 5) {
      return $r('app.string.nav_tools');
    }
    if (this.activeTab === 6) {
      return $r('app.string.nav_about');
    }
    return $r('app.string.nav_config');
  }


  /**
   * 顶栏内容（自绘）：抽屉入口(☰) + 分区标题 + 搜索/添加/连接/溢出 四个动作；**整行跟交互手镜像**。
   *
   * ★ 镜像方向的唯一判据：**☰ 必须待在手的那一侧**——和抽屉滑出侧、FAB 贴边侧保持一致。
   *   handSide==='left'  → 抽屉从左出(drawerOverlay FlexAlign.Start)、FAB 贴左 ⇒ ☰ 也在左；
   *   handSide==='right' → 全部镜像到右边。
   *   (2.0.19 真机:这里跟抽屉反了 —— 抽屉在左、☰ 却在右，用户指出"左右手搞反了"。)
   */
  @Builder
  private titleStackBuilder() {
    if (this.handSide === 'left') {
      /* 左手：☰ 贴左拇指，标题左对齐，动作按钮挪到右端 */
      Row({ space: 4 }) {
        this.titleDrawerButton()
        Text(this.sectionTitle())
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        this.titleActionCluster()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .transition(TransitionEffect.move(TransitionEdge.START).animation({ duration: 220, curve: Curve.Friction }))
    } else {
      /* 右手：动作按钮贴右拇指，标题右对齐，☰ 挪到左端 */
      Row({ space: 4 }) {
        this.titleActionCluster()
        Text(this.sectionTitle())
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.End)
        this.titleDrawerButton()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .transition(TransitionEffect.move(TransitionEdge.END).animation({ duration: 220, curve: Curve.Friction }))
    }
  }

  /** 抽屉入口（三条横线）；⚠️ 触发走 onTouch(Up)：stackBuilder 里 Button.onClick 不回调 */
  @Builder
  private titleDrawerButton() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      SymbolGlyph($r('sys.symbol.line_3_horizontal'))
        .fontSize(22)
        .fontColor([$r('app.color.text_1')])
    }
    .width(44)
    .height(44)
    .borderRadius(12)
    .backgroundColor(Color.Transparent)
    .id('nbTitleProbe')
    .visualEffect(pressLightEffect(this.litKey === 'tb:drawer', true))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = 'tb:drawer';
      } else if (event.type === TouchType.Up) {
        this.litKey = '';
        this.openDrawer();
      } else if (event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
  }

  /** 顶栏动作按钮组：搜索 / 添加 / 连接 / 溢出菜单 */
  @Builder
  private titleActionCluster() {
    Row({ space: 4 }) {
      GlowIconButton({
        symbol: $r('sys.symbol.magnifyingglass'),
        iconSize: 20,
        iconColor: $r('app.color.text_1'),
        onTap: () => {
          if (this.searchVisible) {
            /* 已在搜索态:再点一次搜索图标 = 关闭(用户 2026-10-17) */
            this.closeNodeSearch();
            return;
          }
          this.searchVisible = true;
          /* 打开即聚焦弹键盘;延后到输入框挂载完成,抢不到焦点也不影响手动点输入框 */
          setTimeout(() => {
            try {
              this.getUIContext().getFocusController().requestFocus('nodeSearchInput');
            } catch (e) {
              // 焦点不可用时保持旧行为(用户手动点输入框)
            }
          }, 120);
        }
      })
      GlowIconButton({
        symbol: $r('sys.symbol.plus'),
        iconSize: 22,
        iconColor: $r('app.color.text_1'),
        onTap: () => {
          this.addEntryDialog.open();
        }
      })
      GlowIconButton({
        symbol: $r('sys.symbol.link'),
        iconSize: 20,
        iconColor: $r('app.color.text_1'),
        onTap: () => {
          router.pushUrl({ url: 'pages/ConnectionsPage' });
        }
      })
      Button({ type: ButtonType.Normal, stateEffect: false }) {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor([$r('app.color.text_1')])
      }
      .id(OVERFLOW_MENU_ANCHOR)
      .width(44)
      .height(44)
      .borderRadius(12)
      .backgroundColor(Color.Transparent)
      .visualEffect(pressLightEffect(this.litKey === 'tb:more', true))
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.litKey = 'tb:more';
        } else if (event.type === TouchType.Up) {
          this.litKey = '';
          this.openOverflowMenu();
        } else if (event.type === TouchType.Cancel) {
          this.litKey = '';
        }
      })
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 溢出动作（顶栏 ⋮ 的沉浸光感菜单；与改造前同一批，一个不少；排序项带当前选中勾） */
  private overflowActions(): Array<MenuItemData> {
    const items: Array<MenuItemData> = [];
    const add = (label: ResourceStr, value: string, selected: boolean): void => {
      const it: MenuItemData = new MenuItemData();
      it.label = label;
      it.value = value;
      it.selected = selected;
      items.push(it);
    };
    add($r('app.string.update_current_subscription'), 'update_sub', false);
    add($r('app.string.clear_traffic_statistics'), 'clear_traffic', false);
    add($r('app.string.test_all_nodes'), 'test_all', false);
    add($r('app.string.clear_test_results'), 'clear_results', false);
    add($r('app.string.dedup_action'), 'dedup', false);
    add($r('app.string.delete_unavailable'), 'delete_unavailable', false);
    add($r('app.string.sort_manual'), 'sort_manual', this.settings.profileSortMode === 'manual');
    add($r('app.string.sort_latency'), 'sort_latency', this.settings.profileSortMode === 'latency');
    add($r('app.string.sort_name'), 'sort_name', this.settings.profileSortMode === 'name');
    return items;
  }

  /** 打开顶栏 ⋮ 的沉浸光感菜单（RzdSchool HdsMenu：系统菜单窗口 + 自绘面板 + 模糊背板 + 自适应取色） */
  private openOverflowMenu(): void {
    const items: Array<MenuItemData> = this.overflowActions();
    this.overflowMenu.open(this.getUIContext(), OVERFLOW_MENU_ANCHOR, items, (index: number): void => {
      if (index < 0 || index >= items.length) {
        return;
      }
      const value: string = items[index].value;
      if (value === 'update_sub') {
        this.updateCurrentSubscription();
      } else if (value === 'clear_traffic') {
        this.clearTrafficStatistics();
      } else if (value === 'test_all') {
        this.runSpeedTest();
      } else if (value === 'clear_results') {
        this.clearTestResults('__all__');
      } else if (value === 'dedup') {
        this.dedupGroup('__all__');
      } else if (value === 'delete_unavailable') {
        this.deleteUnavailable('__all__');
      } else if (value === 'sort_manual') {
        this.setSortMode('manual');
      } else if (value === 'sort_latency') {
        this.setSortMode('latency');
      } else if (value === 'sort_name') {
        this.setSortMode('name');
      }
    });
  }
  // ---------------------------------------------------------------- 内容切换 + 骨架

  @Builder
  private activeContent() {
    if (this.activeTab === 0) {
      this.configFragment()
    } else if (this.activeTab === 1) {
      GroupPage({
        onDataChanged: () => {
          this.refresh();
        },
        onOpenDrawer: () => {
          this.openDrawer();
        }
      })
    } else if (this.activeTab === 2) {
      RouteRulesPanel({
        onOpenDrawer: () => {
          this.openDrawer();
        }
      })
    } else if (this.activeTab === 3) {
      SettingsPage({
        onSettingsChanged: (settings: AppSettings) => {
          this.settings = settings;
        },
        onOpenDrawer: () => {
          this.openDrawer();
        }
      })
    } else if (this.activeTab === 4) {
      LogPanel({
        onOpenDrawer: () => {
          this.openDrawer();
        }
      })
    } else if (this.activeTab === 5) {
      ToolsPage({
        onOpenDrawer: () => {
          this.openDrawer();
        }
      })
    } else {
      AboutPage({
        onOpenDrawer: () => {
          this.openDrawer();
        }
      })
    }
  }

  @Builder
  private titleBottomBuilder() {
    /* 模式行 + 分组条只在首页显示(用户 2026-10-17):其它分区页顶部不再带订阅分组条。
       nbBarBottomProbe 也没了 ⇒ calibrateTopInset 回退到 nbTitleProbe(标题栏底边),让位照常。
       ⚠️ 搜索态(用户 2026-10-17):搜索行要与分组条**同一条带互换**,底部带总高恒定 ——
       高度一变 HDS 会整条重排标题栏(顶部按钮闪一下),且列表让位量来不及重算,
       分组条会压到节点卡上(真机截图确认过两个坑)。
       行距(用户 2026-10-17):搜索行↔模式行、模式行↔分组条一律 8vp,与节点卡间距一致;
       两个状态下内容总高都凑成 68(32+8+28 / 28+8+32),底部带高度才能恒定。 */
    if (this.activeTab === 0) {
      Column({ space: 8 }) {
        if (this.searchVisible) {
          this.searchInputRow()
        }
        this.modeSwitchRow()
        if (!this.searchVisible) {
          this.groupTabBar()
        }
      }
      .width('100%')
      .id('nbBarBottomProbe')
    }
  }

  /**
   * HDS 标题栏配置 —— **那层"渐变模糊"是 HDS 自带的，不要自己画**（用户 2026-10-17 明确要求）：
   *  · `blurStrategy: ENABLE` + `scrollEffectOpts: IMMERSIVE_GRADIENT_BLUR`
   *    ⇒ 官方"滚动渐变模糊背板"：滚动时顶栏从透明渐变到模糊；
   *  · `systemMaterialEffect: IMMERSIVE + EXQUISITE` ⇒ 沉浸光感材质（与 RzdSchool 设置页同档）；
   *  · `avoidLayoutSafeArea: **false**` ⇒ HDS 把**背景材质**铺进状态栏，而**标题内容**仍落在状态栏下方。
   *    （RzdMusic RecommendPage 的实测注释：设成 true 会把标题再退一个状态栏 ⇒ 38..94 → 76..132vp）
   *  · 内容自绘：标题行 `content.stackBuilder`，模式行 + 分组条 `content.bottomBuilder`。
   */
  private shellTitleBar(): HdsNavigationTitleBarOptions {
    return {
      /* ★ true：整条标题栏（材质 + 内容）**再退一个状态栏高度** ⇒ 落在时钟下方。
         RzdMusic 的注释里 false 时标题在 38..94vp，是因为它的外壳根节点本来就落在安全区里；
         本工程根 Stack 挂了 ignoreLayoutSafeArea 铺满整窗 ⇒ false 会把标题排到 y=0、与状态栏文字重叠。 */
      avoidLayoutSafeArea: true,
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        scrollEffectOpts: {
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        },
        originalStyle: {
          backgroundStyle: { backgroundColor: Color.Transparent },
          contentStyle: {
            titleStyle: { mainTitleColor: $r('app.color.text_1') },
            menuStyle: { iconColor: $r('app.color.text_1'), textColor: $r('app.color.text_1') }
          }
        },
        scrollEffectStyle: {
          contentStyle: {
            titleStyle: { mainTitleColor: $r('app.color.text_1') },
            menuStyle: { iconColor: $r('app.color.text_1'), textColor: $r('app.color.text_1') }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
        }
      },
      content: {
        /* ⚠️ 这里不要再自己补 padding.top：HDS 给标题行的是**固定高度的槽位**，
           自己加 44vp 会让内容溢出槽位、与 bottomBuilder 的模式行叠在一起（2.0.27 真机"上面错位"就是这个）。
           让位交给 HDS：avoidLayoutSafeArea:false 的语义 = 材质伸进状态栏、内容留在状态栏下方。 */
        stackBuilder: (): void => {
          this.titleStackBuilder();
        },
        bottomBuilder: {
          builder: (): void => {
            this.titleBottomBuilder();
          },
          /* 非首页不再有分组条:高度也要归零,否则留一条空带。
             底部带恒 68(两个搜索/常规态内容都是 32+8+28 / 28+8+32,见 titleBottomBuilder) */
          height: this.activeTab === 0 ? 68 : 0
        }
      }
    };
  }

  /** 列表顶部占位 = HDS 标题栏底边（窗口坐标）+ 8。纯几何，不打日志。
   *  +8(用户 2026-10-17):首卡与底部带(分组条)的间距 = 节点卡间距(List space 8),
   *  占位项公式是 inset-8 再加列表 space 8 ⇒ inset 必须是 probeBottom+8 才落出 8vp 缝。 */
  private calibrateTopInset(): void {
    try {
      const ui = this.getUIContext();
      const utils = ui.getComponentUtils();
      let bar = utils.getRectangleById('nbBarBottomProbe');
      let bottomPx = bar.windowOffset.y + bar.size.height;
      if (bottomPx <= 0) {
        bar = utils.getRectangleById('nbTitleProbe');
        bottomPx = bar.windowOffset.y + bar.size.height;
      }
      const inset = Math.round(ui.px2vp(bottomPx) + 8);
      if (inset > 0 && inset < 400 && Math.abs(inset - this.contentTopInset) >= 2) {
        this.contentTopInset = inset;
      }
    } catch (e) {
    }
  }

  build() {
    /* 外壳：**HdsNavigation 开着官方标题栏**（它自带渐变模糊 + 沉浸光感材质），
       内容走 matchParent + ignoreLayoutSafeArea 铺满整窗 ⇒ 列表能从标题栏后面滚过去；
       FAB 与抽屉是根 Stack 的兄弟（在 Navigation 之后）⇒ 抽屉能盖住标题栏。
       列表顶部垫一个"标题栏等高"的占位项（contentTopInset 由 nbBarBottomProbe 实测量出）。 */
    Stack({ alignContent: Alignment.TopStart }) {
      HdsNavigation(this.pathStack) {
        Column() {
          Column() {
            this.activeContent()
          }
          .width('100%')
          .layoutWeight(1)
          .id('nbBodyProbe')
          .onAreaChange((_oldArea: Area, _newArea: Area) => {
            this.calibrateTopInset();
          })
          /* 配置页列表自己用【占位项】让位(见 configFragment) ⇒ 容器不再留白;
             其它分区页还没接占位项，用 contentTopInset 让位 */
          .padding({ top: this.activeTab === 0 ? 0 : this.contentTopInset })
          if (this.isRunning && (this.activeTab === 0 || this.settings.showBottomBar)) {
            this.statsBar()
          }
        }
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .backgroundColor($r('app.color.bg_page'))
        .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .titleMode(HdsNavigationTitleMode.MINI)
      .mode(NavigationMode.Stack)
      .titleBar(this.shellTitleBar())
      /* 顶栏渐变模糊要跟着列表滚 ⇒ 必须把列表的 Scroller 交给它 */
      .bindToScrollable([this.configScroller])
      /* 左上角 HDS 自带的返回箭头没用（本页是根页面，栈里没有上一级）⇒ 关掉 */
      .hideBackButton(true)
      .hideToolBar(true)
      /* ⚠️ 这里**不再**挂 ignoreLayoutSafeArea：挂上整条标题栏会顶到 y=0，标题与状态栏文字重叠。
         现在 Navigation 的盒子落在安全区里 ⇒ 标题落在时钟下方；内容层自己有
         matchParent + ignoreLayoutSafeArea ⇒ 列表仍铺满整窗、能从标题栏后面滚过去。 */
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      if (this.activeTab === 0 || this.settings.showBottomBar) {
        this.fabLayer()
      }

      /* 抽屉(最后一个兄弟 ⇒ 盖住标题栏与状态栏) */
      this.drawerOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}

/** 分享弹窗:展示二维码(对齐安卓分享界面)+ URI 文本与复制降级入口。 */
@CustomDialog
struct ShareTextDialog {
  controller?: CustomDialogController;
  @Link text: string;
  @Link qrPixelMap: image.PixelMap | null;
  onCopy: (text: string) => void = (text: string) => {};

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.share_link_title'))
        .fontSize(16)
        .fontWeight(700)
        .width('100%')
      if (this.qrPixelMap !== null) {
        Image(this.qrPixelMap)
          .width(220)
          .height(220)
          .margin({ top: 4, bottom: 4 })
          .interpolation(ImageInterpolation.None)
      }
      Text(this.text)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .copyOption(CopyOptions.LocalDevice)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button($r('app.string.copy_share_link'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => this.onCopy(this.text))
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}

/** 导入弹窗:手动粘贴订阅链接 / 节点链接 / base64 订阅内容 */
@CustomDialog
struct ImportDialog {
  controller?: CustomDialogController;
  @Link text: string;
  @Link name: string;
  onImport: (t: string, name: string) => void = (t: string, name: string) => {
  };
  onPickClipboard: () => void = () => {
  };

  build() {
    Column({ space: 10 }) {
      Text($r('app.string.import_link_subscription'))
        .fontSize(16)
        .fontWeight(700)
      TextInput({
        text: this.name,
        placeholder: $r('app.string.subscription_name_optional')
      })
        .height(UiSpec.BTN_HEIGHT)
        .onChange((v: string) => {
          this.name = v;
        })
      TextArea({
        text: this.text,
        placeholder: $r('app.string.import_content_placeholder')
      })
        .height(120)
        .onChange((v: string) => {
          this.text = v;
        })
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Blank()
        Button($r('app.string.read_from_clipboard'))
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.onPickClipboard())
        Button($r('app.string.import_action'))
          .backgroundColor($r('app.color.primary'))
          .onClick(() => {
            const t = this.text;
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onImport(t, this.name);
          })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}

/** 统一添加入口弹窗:导入订阅 / 扫码添加 / 剪贴板导入 / 从文件导入 / 新建节点(顺序对齐安卓 add_profile_menu) */
@CustomDialog
struct AddEntryDialog {
  controller?: CustomDialogController;
  onNewProfile: () => void = () => {
  };
  onImportSubscription: () => void = () => {
  };
  onImportClipboard: () => void = () => {
  };
  onScan: () => void = () => {
  };
  onImportFile: () => void = () => {
  };

  build() {
    Column({ space: UiSpec.GAP_SM }) {
      Button($r('app.string.import_link_subscription'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.primary'))
        .fontColor($r('app.color.surface'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onImportSubscription();
        })
      Button($r('app.string.add_profile_methods_scan_qr_code'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onScan();
        })
      Button($r('app.string.import_from_clipboard'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onImportClipboard();
        })
      Button($r('app.string.action_import_file'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onImportFile();
        })
      Button($r('app.string.profile_new_title'))
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onNewProfile();
        })
    }
    .padding(UiSpec.PAGE_PADDING)
    .width('100%')
  }
}

/** 移动到分组弹窗:未分组 + 全部分组,当前分组高亮 */
@CustomDialog
struct MoveToGroupDialog {
  controller?: CustomDialogController;
  groups: Array<ProfileGroup> = [];
  currentGroupId: string = '';
  profileName: string = '';
  onPick: (groupId: string) => void = (groupId: string) => {};

  build() {
    Column({ space: 10 }) {
      Text($r('app.string.move_to_group_title'))
        .fontSize(16)
        .fontWeight(700)
        .width('100%')
      if (this.profileName.length > 0) {
        Text(this.profileName)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Scroll() {
        Column({ space: 6 }) {
          Text($r('app.string.ungrouped'))
            .fontSize(13.5)
            .padding(8)
            .borderRadius(8)
            .width('100%')
            .backgroundColor(this.currentGroupId.length === 0 ? $r('app.color.primary') : $r('app.color.surface_selected'))
            .fontColor(this.currentGroupId.length === 0 ? $r('app.color.surface') : $r('app.color.text_primary'))
            .onClick(() => this.onPick(''))
          ForEach(this.groups, (g: ProfileGroup) => {
            Text(g.name)
              .fontSize(13.5)
              .padding(8)
              .borderRadius(8)
              .width('100%')
              .backgroundColor(this.currentGroupId === g.id ? $r('app.color.primary') : $r('app.color.surface_selected'))
              .fontColor(this.currentGroupId === g.id ? $r('app.color.surface') : $r('app.color.text_primary'))
              .onClick(() => this.onPick(g.id))
          }, (g: ProfileGroup) => g.id)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 280 })
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}

