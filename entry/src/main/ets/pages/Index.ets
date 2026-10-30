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
import { notifyProbeDone } from '../utils/ProbeNotify';
import { addMessage } from '../model/MessageStore';
import { statusBarTopVp } from '../common/PageTopInset';
import { illuminatedEffect, pressLightEffect } from '../common/Effects';
import { GlowIconButton } from '../common/components/GlowIconButton';
import { HdsMenu, MenuItemData } from '../common/components/FlowMenu';
import { HAND_SIDE_KEY, handedness } from '../common/Handedness';
import { SettingsPage } from './SettingsPage';
import { ToolsPage } from './ToolsPage';
import { AboutPage } from './AboutPage';
import { RouteRulesPanel } from './RouteRulesPage';
import { LogPanel } from './LogPage';

import { Profile, ProfileGroup, AppSettings, profileTypeLabel } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, mutateProfiles, loadGroups, loadSettings, saveSettings, readPrefString, writePrefString, ensureGroupByName, LogStore } from '../model/Store';
import { VpnService } from '../core/VpnService';
import {
  ACTIVE_SUB_PREF, ACTIVE_SUBS_PREF, belongsToGroup, groupIdsForSubscriptions, inActiveSubs,
  normalizeActiveSubs, parseActiveSubs, serializeActiveSubs, toggleActiveSub
} from '../core/SubGroups';
/* P3①:配置校验闸(K1 纯解析导出,不调 box.New)。配置生成复用既有 buildCoreConfig,
   与扩展进程(VpnExtAbility.ets:650)同一套参数;扩展进程独有的 log/geo 由这里按 UI 侧可得的路径补齐 */
import { CoreManager } from '../core/CoreManager';
import { buildCoreConfig } from '../core/ConfigBuilder';
import { ResourceResolver } from '../core/ResourceResolver';
import { RouteRule, RemoteRuleSet, loadRouteRules, loadRemoteRuleSets } from '../model/RouteRule';
/* geo 资产路径不再在本页拼装:统一由 core/ResourceResolver 快照给出(与扩展进程同口径) */
/* P3②:网络可用性监听(与 VpnExtAbility.registerNetworkChange 同一套 NetConnection 回调) */
import { connection } from '@kit.NetworkKit';
/* P4/W16-B 应用事务管线:快照仓库(UI 进程唯一写者)+ 协调器(saved/applied 修订分离)+ 命令通道 */
import { ApplyCoordinator, ApplyState } from '../core/ApplyCoordinator';
import { ConfigRepository } from '../core/ConfigRepository';
import { SnapshotContent } from '../model/ConfigSnapshot';
import { VpnCommand, publishVpnCommand } from '../core/VpnIpc';
import { CrashGuard } from '../core/CrashGuard';
import { parseShareText } from '../utils/LinkParser';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { fetchSubscriptionWithInfo, looksLikeClashYaml, parseClashProxies, looksLikeSingBoxJson, parseSingBoxConfig, ClashParseResult, subErrorText, unwrapSubscriptionLink, isSagerNetSubscriptionContainer } from '../utils/Subscription';
import { testProfiles, urlTestProfiles, canTCPing, genFriendlyMsg, TestError, TestResult,
  CONNECTION_TEST_TIMEOUT_MS } from '../utils/LatencyTester';
import { SubscriptionRepository } from '../core/SubscriptionRepository';
import { TrafficBaseline, parseBaseline, baselineToJson, buildBaseline,
  displayTotals, baselineStale } from '../model/TrafficBaseline';
import { SubInfo, listSubs, upsertSub, needAutoUpdate, updateSubscription, setAppContext, subNameOf, markSubSuccess, markSubFailure,
  removeSub,
  SubUpdateResult, subUpdateHasChanges, needDirectUpdateConfirm } from '../core/Subscriptions';
import { fetchTrafficTotals, formatSpeed } from '../utils/TrafficStats';
import { fetchCurrentProxyDelay } from '../utils/ClashApi';
import { exportProfileLink } from '../utils/LinkExporter';
import { buildOutboundJson } from '../core/ConfigBuilder';
import { publishVpnLatency } from '../core/VpnIpc';
/* 导航壳层契约(方案 §3.1/§3.3/§3.4,纯模型在 core/Navigation.ets 里,页面只做渲染与接线):
   抽屉顺序/标题兜底/返回语义/顶栏动作可用性/各页浏览记忆都从那里取,
   页内仍沿用旧 activeTab 0..6 数值(§3.2:内部标识不变,只改显示名)。 */
import { PAGE_NODES, PAGE_SUBSCRIPTIONS, PAGE_SETTINGS, BACK_CLOSE_DRAWER, BACK_NODES, BACK_PARENT, BackContext,
  resolveBack, PageDef, pageDefs, pageByLegacyTab, pageById, drawerIndexOfPage, TopBarContext, ActionState,
  topBarActions, ACTION_SEARCH, ACTION_PROBE, ACTION_PROBE_PROGRESS, ACTION_PROBE_CANCEL, ACTION_ADD,
  ACTION_UPDATE_ALL, ACTION_MORE, ACTION_EXPORT, ACTION_REASON_NO_PROFILES, ACTION_REASON_NO_SUBSCRIPTIONS,
  ACTION_REASON_PROBE_UNSUPPORTED, ACTION_REASON_UPDATING, ACTION_REASON_NOT_RUNNING, NavMemory } from '../core/Navigation';
/* P3/W12 节点首页视图模型(纯函数,§4):会话/连通性/状态卡/节点行/筛选排序/空态/连接可用性 */
import {
  VpnSessionView, ConnectivityView, StatusCardView, NodeRowContext, NodeRowView, EmptyContext, EmptyState,
  ActionReason, vpnSessionView, connectivityView, statusCardView, nodeRowView, filterNodes, sortNodes,
  emptyStateFor, connectActionEnabled
} from '../model/HomeView';
/* P3/W11-2 检测结果模型与存储(DTO→业务模型逐字段投影,ArkTS 无结构类型,禁止 cast) */
import {
  ProbeResult, PROBE_STATE_QUEUED, PROBE_STATE_FAILED,
  PROBE_METHOD_UNKNOWN, PROBE_AGG_SINGLE, PROBE_EXPECT_2XX, PROBE_PATH_UNBOUND_UNKNOWN,
  PROBE_CAP_UNAVAILABLE, PROBE_SOURCE_MANUAL, PROBE_PARTICIPATED_YES
} from '../model/ProbeResult';
import { ProbeStore, StoredProbe } from '../core/ProbeStore';
import { ProbeMerge, mergeLiveWithStored } from '../model/ProbeFilters';
/* P3/B 订阅页(独立页面组件,数据经 @Prop 传入,动作走回调;页面自身不做 I/O) */
import {
  SubscriptionNodeCount, UpdateBatchSummary, nodeCountsFromSubUrls, summarizeUpdate,
  PerSubOutcome
} from '../model/SubscriptionList';
import { SubscriptionPage } from './SubscriptionPage';

const OUTBOUND_MODES: Array<string> = ['rule', 'global', 'direct'];
const OUTBOUND_MODE_LABELS: Array<Resource> = [$r('app.string.mode_rule'), $r('app.string.mode_global'), $r('app.string.mode_direct')];

/** AppSettings → 快照 settings 记录(快照里 settings 是 Record<string,Object>,按 Preferences 口径 JSON 原样聚合) */
function settingsToRecord(s: AppSettings): Record<string, Object> {
  return JSON.parse(JSON.stringify(s)) as Record<string, Object>;
}

/** 抽屉项图标(按 core/Navigation 的 drawerIndex 顺序取;文案/标识由 pageDefs() 给,不再本地维护):
 *  「使用文档」入口已移除(用户 2026-10-17):不进列表,DocPage 路由保留但不可达 */
const DRAWER_ITEM_SYMBOLS: Array<Resource> = [
  $r('sys.symbol.list_square'),
  $r('sys.symbol.folder'),
  $r('sys.symbol.arrow_up_left_and_arrow_down_right'),
  $r('sys.symbol.gearshape'),
  $r('sys.symbol.doc_text'),
  /* 系统(工具+关于合并,2026-10-24 用户指示;沿用原工具图标) */
  $r('sys.symbol.wand_and_stars'),
  /* 2026-10-30 用户要求拆出独立「关于」页 */
  $r('sys.symbol.info_circle')
];
/** 顶栏 ⋮ 的菜单锚点 id(沉浸光感菜单靠它定位,必须在某个真实组件上用 .id() 挂上) */
const OVERFLOW_MENU_ANCHOR: string = 'nbOverflowAnchor';

@Entry
@Component
struct Index {
  @State profiles: Array<Profile> = [];
  @State groups: Array<ProfileGroup> = [];
  @State selectedId: string = '';
  @State testing: boolean = false;
  /** 测速结果版本号:节点卡延迟文字/颜色元素依赖它(latencyText/latencyColor 首行读取)。
   *  原因:列表 ForEach 的 key 只有 profile.id,结果字段是**原对象就地改**,
   *  ArkUI 会复用旧条目而不重跑构建器 ⇒ 不清版本号的话"清除测试结果"必须重启才生效(真机 bug)。 */
  @State resultsRev: number = 0;
  /** 取消测速标志:置位后 worker 不再取新节点,已测结果仍会落库(对齐 Android :807-823) */
  private testCancelled: boolean = false;
  @State settings: AppSettings = new AppSettings();
  @State subscriptions: Array<SubInfo> = [];
  @State activeConfigUrl: string = '';
  /** 「首页只看一个订阅」:订阅页选中后写入(空 = 全部订阅混看)。只影响展示,不影响内核配置。 */
  /** 首页显示哪些订阅(订阅页复选框);空数组 = 全部订阅都显示 */
  @State activeSubUrls: Array<string> = [];
  @State activeTab: number = 0;          // 0 配置 / 1 分组 / 2 路由 / 3 设置 / 4 日志 / 5 工具 / 6 关于
  /**
   * 节点列表首屏渲染条目上限(大列表性能)。
   *
   * 这个 List 用的是 ForEach(非 LazyForEach),条目会**全部实例化**,上千节点时会明显拖慢
   * 首帧与滚动。拿不到可靠测量前不做虚拟化改造(那要同时替换 15+ 处列表刷新点),
   * 改用「先渲染 120 条 + 底部显示更多」:数据不变、探测/订阅仍按全量跑,
   * 只是渲染量分页,点击后再追加。
   */
  @State nodeRenderLimit: number = 120;
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
  /** 长按图标快捷方式 / 桌面卡片 router 动作的目标(EntryAbility.handleAction 写入) */
  @StorageLink('pendingShortcut') @Watch('onShortcutChanged') pendingShortcut: string = '';
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
  /* 仅 HDS 标题栏的高度(不含 tab0 的模式行/分组条底栏)——非节点页顶距用它,
     否则会多出整条底栏高度的空白带(2026-10-24 真机用户反馈「顶部按钮与内容间隔很大」) */
  @State titleOnlyInset: number = 96;
  /** 当前选中的分组(配置页顶部分类条;空串 = 未分组) */
  @State selectedGroupId: string = '';
  /** 各页浏览记忆(§3.4):搜索按页隔离 + 滚动位置 + 展示组 + 排序/筛选;切页与冷启动恢复都读它 */
  private navMemory: NavMemory = new NavMemory();
  /** 启动恢复只跑一次 resetRuntimeDependent()(§3.4:运行态要重新向扩展确认,不能每次切页都清) */
  private navMemoryRestored: boolean = false;
  /** 订阅页顶栏「更新全部订阅」进行中(§3.3:更新中动作禁用要给原因,不能静默) */
  @State updatingAllSubs: boolean = false;
  /** 订阅页单条更新进行中的订阅 url('' = 无);订阅页行状态与顶栏禁用原因都读它 */
  @State updatingSubUrl: string = '';
  /** 订阅页批量更新摘要计数(P6 起传结构化模型,反馈条文案由页面渲染) */
  @State batchSummaryModel: UpdateBatchSummary = new UpdateBatchSummary();
  /** 订阅页「更新全部」逐订阅结果行(§11.3) */
  @State batchOutcomes: Array<PerSubOutcome> = [];
  /** 反馈条可见(有摘要或失败时真) */
  @State batchVisible: boolean = false;
  /** 订阅页批量更新失败原文(不吞错误,原样给页面展示) */
  @State batchFailedMessages: Array<string> = Array<string>();
  /** P4/W16-C:订阅页排序方式('name' | 'recent'),与**节点排序**(NavMemory.sortMode)完全独立。
   *  ⚠️ Navigation.NavMemory 没有订阅排序的 key(该文件不在本任务可写范围),这里先用会话内 @State 记忆 */
  @State subscriptionSortMode: string = 'name';
  /** P4/W16-C:订阅页当前选中的订阅(行**长按**选中;⋮ 的「更新选中/删除选中/自动更新设置」作用对象) */
  @State selectedSubUrl: string = '';
  /** 节点页当前检测结果(StoredProbe→ProbeResult 逐字段投影后与 live 合并;P3/W12) */
  @State probeResults: Array<ProbeResult> = Array<ProbeResult>();
  /** 工具条(收藏/仅看可用)变更版本号:NavMemory 不是 @State,靠它触发列表重算 */
  @State filtersRev: number = 0;
  /** 本次会话内测速产生的 live 结果(未落盘的那部分,优先于 stored;§6.3) */
  private liveProbeResults: Array<ProbeResult> = Array<ProbeResult>();
  /** profileId → 最近结果(节点行/状态卡 O(1) 取;刷新时与 probeResults 一起更新) */
  private resultIndex: Map<string, ProbeResult> = new Map<string, ProbeResult>();
  /** live 结果合并节流计时器(见 scheduleLiveRefresh) */
  private liveFlushTimer: number = -1;
  /** P3①:最近一次配置校验失败的内核原文('' = 无/已通过;连接成功后清空,渲染路径不跑校验) */
  @State lastConfigCheckErr: string = '';
  /** P3①:配置校验进行中(防连点同时写 config.json / 并发调 checkConfig) */
  private configChecking: boolean = false;
  /** P3②:网络可用性(空态 offline 分支;订阅更新禁用原因也用它) */
  @State networkAvailable: boolean = true;
  /** P3②:网络监听句柄(aboutToDisappear 时注销) */
  private netWatch: connection.NetConnection | null = null;
  /** P3②:系统 VPN 授权被拒标记(命中一次即置位,本次进程不清) */
  @State firstAuthorizationDenied: boolean = false;
  /** P3②:刚导入完成引导(导入/更新 added>0 时置值,30s 自动清) */
  @State importJustCompleted: boolean = false;
  @State importedCount: number = 0;
  @State skippedTypes: Array<string> = Array<string>();
  private importStateTimer: number = -1;
  /** P4/W16-B:应用事务协调器(UI 侧单实例;saved/applied 修订分离)+ 触发重渲染的版本号 */
  private applyCoordinator: ApplyCoordinator = new ApplyCoordinator();
  @State applyBannerRev: number = 0;
  /* 横幅在 immersive 内容 Column 的 y=0 处渲染 ⇒ 必须自带状态栏顶垫,否则压住状态栏(2026-10-24 真机) */
  @State bannerTopVp: number = 44;
  /* 「稍后」= 本会话收起横幅(草稿保留);新保存会重新亮出 */
  @State applyBannerDismissed: boolean = false;
  /** 已保存但等"下次连接生效"(VPN 未运行时的应用路径) */
  @State pendingForNextConnect: boolean = false;
  @State applyTargetRevision: number = 0;
  private applyOperationId: string = '';
  private applyGeneration: number = 0;
  private applySessionId: string = '';
  private applyWatchdogTimer: number = -1;
  /** 本次 apply 发起时刻(用于「applying 自愈」:回执丢失时不能永远挂横条) */
  private applyStartedAtMs: number = 0;
  private modeApplyTimer: number = -1;
  /** 扩展回执(AppStorage 键由 EntryAbility.subscribeApplyResults 写入;@Watch 驱动,不轮询) */
  @StorageLink('vpnApplyOperationId') @Watch('onApplyResultWatch') applyResultOperationId: string = '';
  @State appVersion: string = '';
  @StorageLink('uiBreakpoint') uiBreakpoint: string = 'compact';
  /* 主题强调色(Theme.publishAccent 写入):鸿蒙资源色不能运行时替换,只覆盖「强调件」 */
  @StorageProp('themeAccentHex') accentHex: string = '';
  @StorageLink('vpnRunning') @Watch('onRunningChange') isRunning: boolean = false;
  @StorageLink('vpnStatus') @Watch('onVpnStatusWatch') statusText: string = 'disconnected';
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
  private trafficBaselineLoaded: boolean = false;
  /** W20:显示累计流量基准(重置时记录;显示=当前-基准,轮询不再写回旧值) */
  private trafficBaseline: TrafficBaseline | null = null;
  private rawTotalUp: number = 0;
  private rawTotalDown: number = 0;
  private lastTrafficAt: number = 0;
  private uptimeTimer: number = -1;

  aboutToAppear(): void {
    setAppContext(this.context);
    void statusBarTopVp(this.context).then((v: number): void => {
      this.bannerTopVp = v;
    });
    /* 智感握姿:全进程只订阅一次(交互手/握持手),结果写 AppStorage 供各页面镜像布局。
       ⚠️ 放在这里而不是 EntryAbility.onCreate:motion 要走系统服务,放启动关键路径上
       一旦服务未就绪会卡死在开屏页(真机踩过)。Handler 内部还会再 defer 一次(setTimeout 0)。 */
    handedness.start();
    this.computeInsets();
    this.refresh();
    /* 浏览记忆恢复(§3.4):冷启动/进程重建时恢复上次的搜索词与滚动位置;
       ⚠️ 只在启动这条路径清一次运行态筛选(resetRuntimeDependent),切页不要调 */
    this.restoreBrowsingMemory();
    /* 节点页检测结果:进页面先读一次落盘结果(ProbeStore 已在 EntryAbility 初始化) */
    void this.refreshProbeResults();
    /* P3②:网络可用性(空态 offline 分支)+ 授权拒绝标记的状态回传钩子已在 @Watch 上 */
    this.startNetworkWatch();
    this.autoUpdateSubs();
    this.autoConnect();
    this.maybeRecoverAfterKill();
    if (this.isRunning) {
      this.startSpeedPoller();
      this.startUptimeTimer();
    }
    /* 冷启动路径:@Watch 只在**变化**时触发,而快捷方式的 want 在 Index 挂载前就
       写进 AppStorage 了,这里主动消费一次(热启动靠 @Watch)。 */
    this.onShortcutChanged();
  }

  /**
   * 快捷方式/卡片入口消费(shortcuts_config.json → EntryAbility → AppStorage)。
   * 目标页只做跳转,不改任何业务状态;消费后立刻清空,避免重进首页时重复跳。
   */
  private onShortcutChanged(): void {
    const target: string = this.pendingShortcut;
    if (target.length === 0) {
      return;
    }
    this.pendingShortcut = '';
    AppStorage.setOrCreate<string>('pendingShortcut', '');
    if (target === 'nodes') {
      this.switchTab(0);
      return;
    }
    if (target === 'logs') {
      this.switchTab(4);
      return;
    }
    const url: string = target === 'traffic' ? 'pages/TrafficPage'
      : (target === 'diagnostics' ? 'pages/DiagnosticsPage' : '');
    if (url.length > 0) {
      router.pushUrl({ url: url }).catch((e: Error) => {
        LogStore.addLog(`[app] 快捷方式跳转失败: ${e.message}`);
      });
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
   * 系统返回键(§3.4,语义判据在 core/Navigation.resolveBack):
   * 抽屉打开 → 收抽屉;有二级页 → 回父页(二级页是独立 router 页,由系统自己弹栈,这里 hasParent=false);
   * 非节点页 → 回节点页;节点页 → 退到桌面(VPN 继续运行)。
   * 本 SDK 下该回调只对 @Entry 组件生效。
   */
  onBackPress(): boolean {
    const ctx = new BackContext();
    ctx.drawerOpen = this.drawerOpen;
    ctx.currentPage = this.currentPageId();
    ctx.hasParent = false;
    const action = resolveBack(ctx);
    if (action === BACK_CLOSE_DRAWER) {
      this.drawerOpen = false;
      return true;
    }
    if (action === BACK_PARENT) {
      /* 壳层自身无二级页栈(二级页走 router,各自的 onBackPress 自己处理) */
      return false;
    }
    if (action === BACK_NODES) {
      this.switchTab(drawerIndexOfPage(PAGE_NODES));
      return true;
    }
    this.context.moveAbilityToBackground();
    return true;
  }

  /** 列表渲染用的分页切片(只影响绘制;测速/操作仍用 visibleNodeList 全量) */
  private pagedNodeList(): Array<Profile> {
    const all = this.visibleNodeList();
    return all.length > this.nodeRenderLimit ? all.slice(0, this.nodeRenderLimit) : all;
  }

  /** 当前页面 id(§3.2:内部仍是旧 activeTab 0..6 数值,id 由契约映射,显示名/动作按 id 取) */
  private currentPageId(): string {
    return pageByLegacyTab(this.activeTab).id;
  }

  /**
   * 切页唯一入口(§3.4):把当前页的搜索词/滚动位置存进 NavMemory,再恢复目标页的。
   * activeTab 数值语义保持不变;抽屉选择与返回键都走这里,搜索词才不会串页。
   */
  private switchTab(tab: number): void {
    const from = this.currentPageId();
    this.navMemory.setSearch(from, this.nodeSearch);
    try {
      this.navMemory.setScroll(from, Math.max(0, Math.round(this.configScroller.currentOffset().yOffset)));
    } catch (e) {
      // 滚动器还没挂载(抽屉里直接切页)时记 0 即可
    }
    this.cancelSearchFilterTimer();
    this.searchVisible = false;
    this.nodeSearch = this.navMemory.getSearch(pageByLegacyTab(tab).id);
    this.activeTab = tab;
    this.logSkippedActions(pageByLegacyTab(tab).id);
    this.restoreScrollFor(pageByLegacyTab(tab).id);
    /* 检测结果按新页刷新(P3/W12:进节点页/检测结束后都要读一次最新落盘结果) */
    if (tab === drawerIndexOfPage(PAGE_NODES)) {
      void this.refreshProbeResults();
    }
  }

  /**
   * 冷启动/进程重建恢复(§3.4):搜索词与滚动位置从 NavMemory 拿回;
   * 运行态相关的筛选(仅看可用)只在这一条路径清掉(resetRuntimeDependent)。
   */
  private restoreBrowsingMemory(): void {
    if (!this.navMemoryRestored) {
      this.navMemoryRestored = true;
      this.navMemory.resetRuntimeDependent();
    }
    const pageId = this.currentPageId();
    const saved = this.navMemory.getSearch(pageId);
    if (saved.length > 0) {
      this.nodeSearch = saved;
    }
    this.restoreScrollFor(pageId);
  }

  /** 滚动位置恢复:延迟到目标页列表挂载完成后再滚(scrollTo 抢在挂载前是空操作) */
  private restoreScrollFor(pageId: string): void {
    const y = this.navMemory.getScroll(pageId);
    if (y <= 0) {
      return;
    }
    setTimeout(() => {
      try {
        this.configScroller.scrollTo({ xOffset: 0, yOffset: y, animation: false });
      } catch (e) {
        // 滚动器未挂载/不可用时跳过(浏览位置只丢一次,不影响功能)
      }
    }, 0);
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
    this.stopNetworkWatch();
    if (this.uptimeTimer >= 0) {
      clearInterval(this.uptimeTimer);
      this.uptimeTimer = -1;
    }
    if (this.importStateTimer >= 0) {
      clearTimeout(this.importStateTimer);
      this.importStateTimer = -1;
    }
    this.clearApplyWatchdog();
    if (this.modeApplyTimer >= 0) {
      clearTimeout(this.modeApplyTimer);
      this.modeApplyTimer = -1;
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
      // 被杀自愈:真实运行态落盘"活着"(进程被杀后 Preferences 仍在,下次启动据此恢复)
      CrashGuard.markVpnStarted(AppStorage.get<string>('vpnRunningProfileId') ?? '')
        .catch((e: Object) => {
          LogStore.addLog(`[app] 被杀标记写入异常(忽略): ${e}`);
        });
    } else {
      this.stopSpeedPoller();
      this.stopUptimeTimer();
      CrashGuard.markVpnStopped().catch((e: Object) => {
        LogStore.addLog(`[app] 干净退出标记写入异常(忽略): ${e}`);
      });
    }
    this.refresh();
  }

  /**
   * 被杀自愈(FlClash 同款,零权限):上次运行带着开着的 VPN 被系统/用户回收 →
   * 本次启动按"启动自动连接"设置直接重连或弹框询问。决策已在 CrashGuard.init 消费标记。
   */
  private async maybeRecoverAfterKill(): Promise<void> {
    try {
      await CrashGuard.ensureLoaded();
      const decision = CrashGuard.recoveryDecision(this.isRunning, this.settings.autoConnect);
      if (decision.action === 'none') {
        return;
      }
      if (decision.action === 'reconnect') {
        LogStore.addLog(`[app] 检测到上次运行被系统回收,自动恢复连接: ${decision.profileId}`);
        await VpnService.connect(this.context, decision.profileId);
        this.refresh();
        return;
      }
      AlertDialog.show({
        title: $r('app.string.crash_recovery_title'),
        message: $r('app.string.crash_recovery_prompt'),
        autoCancel: true,
        primaryButton: { value: $r('app.string.cancel'), action: () => {} },
        secondaryButton: {
          value: $r('app.string.crash_recovery_connect'),
          action: () => {
            VpnService.connect(this.context, decision.profileId).catch((e: Object) => {
              LogStore.addLog(`[app] 被杀恢复重连失败: ${e}`);
            });
          }
        }
      });
    } catch (e) {
      LogStore.addLog(`[app] 被杀自愈检查失败(忽略): ${e}`);
    }
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
      /* 多选键优先;只有"从没设置过"(空串)才回落旧的单选键,迁移后立刻落到新键 */
      const multiRaw: string = await readPrefString(ACTIVE_SUBS_PREF, '');
      let selected: Array<string> = parseActiveSubs(multiRaw.length > 0
        ? multiRaw
        : await readPrefString(ACTIVE_SUB_PREF, ''));
      selected = normalizeActiveSubs(selected, this.subscriptions);
      this.activeSubUrls = selected;
      const encoded: string = serializeActiveSubs(selected);
      if (multiRaw !== encoded) {
        await writePrefString(ACTIVE_SUBS_PREF, encoded);
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
      if (!this.trafficBaselineLoaded) {
        this.trafficBaselineLoaded = true;
        await this.loadTrafficBaseline();
      }
      this.rawTotalUp = t.up;
      this.rawTotalDown = t.down;
      if (baselineStale(t.up, t.down, this.trafficBaseline)) {
        /* 内核重启(计数器归零):基准过期,显示原始值 */
        this.trafficBaseline = null;
      }
      const shown = displayTotals(t.up, t.down, this.trafficBaseline);
      AppStorage.setOrCreate('vpnTotalUp', shown[0]);
      AppStorage.setOrCreate('vpnTotalDown', shown[1]);
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
    /* P3①:所有连接入口(状态卡主按钮 / FAB / 长按菜单)都汇到 connectTo,校验闸放在这里最省心 */
    const allowed = await this.preConnectConfigCheck(p);
    if (!allowed) {
      return;
    }
    this.selectedId = p.id;
    await writePrefString('selected_profile_id', p.id);
    try {
      await VpnService.connect(this.context, p.id);
      /* 连接已发起(后续成败由 vpnStatus 回传)→ 清掉上次的校验失败,下次连接重新校验 */
      this.lastConfigCheckErr = '';
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

  /**
   * 出站模式切换(§12.2「模式切换」高频操作):界面立即切换 + 立即反馈,
   * 然后**合并连续切换**后提交一次应用事务(300ms 去抖 → 一次 commit + 一次 apply),
   * 不再每次切换都直连重连 3 次。Preferences 仍即时保存(读取方迁移到快照前必须)。
   */
  async switchOutboundMode(mode: string): Promise<void> {
    if (!OUTBOUND_MODES.includes(mode) || this.settings.mode === mode) {
      return;
    }
    this.settings.mode = mode;
    await saveSettings(this.settings);
    this.scheduleModeApply();
  }

  /** 连续切换合并:300ms 内的多次切换只提交/应用最终目标一次 */
  private scheduleModeApply(): void {
    if (this.modeApplyTimer >= 0) {
      clearTimeout(this.modeApplyTimer);
    }
    this.modeApplyTimer = setTimeout(() => {
      this.modeApplyTimer = -1;
      void this.commitAndApplySettings('mode_switch');
    }, 300);
  }

  // ---------------------------------------------------------------- 测速

  /** URL Test 入口(对齐 Android 选项菜单「URL Test」→ `urlTest()`,ConfigurationFragment.kt:590)。
   *  **固定走 URL Test**,不再跟随 `latencyTestMode` 设置 —— 菜单里已经是两个独立入口,
   *  跟设置走会导致"点 URL Test 却在跑 TCPing"(设置仅用于分组菜单的「测速本组」快捷项)。
   *  缺省作用域 = 当前选中分组(Android `DataStore.currentGroup()` :843)。 */
  async runSpeedTest(groupId: string = this.selectedGroupId): Promise<void> {
    await this.runTestForGroup(groupId, 'url');
  }

  /** TCPing 入口(对齐 Android 选项菜单「TCPing」→ `pingTest(false)`,:586)。
   *  Android 在入口处按 `canTCPing()` 过滤协议(:702-713),这里同位置过滤。 */
  async runTcpTest(groupId: string = this.selectedGroupId): Promise<void> {
    await this.runTestForGroup(groupId, 'tcp');
  }

  async runGroupSpeedTest(groupId: string): Promise<void> {
    await this.runTestForGroup(groupId, this.settings.latencyTestMode);
  }

  private async runTestForGroup(groupId: string, mode: string): Promise<void> {
    if (this.testing) {
      // 之前是静默 return:测速进行中再点测速毫无反馈,像"点了没反应"
      promptAction.showToast({ message: $r('app.string.index_test_in_progress') });
      return;
    }
    const all = this.profiles.filter((item: Profile) => item.groupId === groupId);
    const targets = mode === 'tcp' ? all.filter((item: Profile) => canTCPing(item)) : all;
    if (targets.length === 0) {
      if (mode === 'tcp') {
        promptAction.showToast({ message: $r('app.string.connection_test_tcp_ping_unavailable') });
      } else {
        promptAction.showToast({ message: $r('app.string.speed_test_group_empty') });
      }
      return;
    }
    /* 只清掉本组节点的旧结果(其它组历史结果保留),让本组在测速中显示"测试中…" */
    for (const item of targets) {
      item.status = 0;
      item.ping = 0;
      item.error = '';
      item.latencyMs = 0;
    }
    this.profiles = this.profiles.slice();
    this.bumpResults();
    /* 新一轮检测:清掉上次会话的 live 结果(落盘/历史结果仍在,节点行不会空) */
    this.liveProbeResults = [];
    promptAction.showToast({ message: $r('app.string.index_testing_count', targets.length) });
    await this.runProfilesTest(targets, mode);
    void this.refreshProbeResults();
  }

  private async runProfilesTest(snapshot: Array<Profile>, mode: string): Promise<void> {
    this.testing = true;
    this.testCancelled = false;
    /* 结果不能逐条重建 @State:每张节点卡的延迟文本都依赖 profiles,逐条写会把主页
       整页重渲染 N 次,节点多时 UI 线程被刷爆 —— 表现为"测速中页面卡死、
       点搜索/点按钮都没反应"。结果先写到节点对象上,每 300ms 合并刷一次 @State,
       测完(含取消/异常路径 finally)补最后一次。 */
    let flushTimer = -1;
    let dirty = false;
    let reportedFallback = false;
    const completed = new Map<string, TestResult>();
    const flushPending = (): void => {
      if (flushTimer >= 0) {
        clearTimeout(flushTimer);
        flushTimer = -1;
      }
      if (!dirty) {
        return;
      }
      dirty = false;
      this.profiles = this.profiles.slice();
      this.bumpResults();
    };
    const onOne = (r: TestResult): void => {
      if (r.status !== 0) {
        completed.set(r.id, r);
      }
      const profile = this.profiles.find((item: Profile) => item.id === r.id);
      if (profile !== undefined) {
        profile.status = r.status;
        profile.ping = r.ping;
        profile.error = r.error;
        profile.latencyMs = r.status === 1 ? r.ping : (r.status === 0 ? 0 : -1);
        if (r.status !== 0) {
          profile.latencyTestedAt = Date.now();
        }
        const runningProfileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
        if (r.status === 1 && this.isRunning && runningProfileId === r.id) {
          publishVpnLatency(r.id, profile.name, r.ping);
        }
      }
      dirty = true;
      if (flushTimer < 0) {
        flushTimer = setTimeout(flushPending, 300);
      }
    };
    try {
      if (mode === 'tcp') {
        /* 第 7 参 onProbe:TCPing 每条 ProbeResult 也进"live 结果"通道(§6.3),
           与 URL Test 落盘的 stored 结果合并展示(P3/W12) */
        await testProfiles(snapshot, onOne, this.settings.testConcurrent,
          this.settings.testRetries, this.settings.testSamples, () => this.testCancelled,
          (probe: ProbeResult) => {
            this.upsertLiveProbe(probe);
          });
      } else {
        /* 上游签名：urlTestProfiles(targets, allProfiles, settings, context, onResult,
           concurrency, groups, isCancelled)。超时 = settings.testTimeoutMs(默认 5000,
           对齐 Android UrlTest.kt:9),不再在调用处硬编码。 */
        const report = await urlTestProfiles(snapshot, this.profiles, this.settings, this.context,
          onOne, this.settings.testConcurrent, this.groups, () => this.testCancelled);
        if (report.degraded) {
          // 内核测速起不来而回退 TCPing 时,数值含义完全变了(只反映握手耗时),
          // 必须明示,否则用户拿着假数据对比 Clash
          promptAction.showToast({ message: $r('app.string.speed_test_degraded', report.degradeReason) });
          reportedFallback = true;
        } else if (report.bindFallback) {
          promptAction.showToast({ message: $r('app.string.speed_test_bind_fallback') });
          reportedFallback = true;
        }
      }
      flushPending();
      if (!this.testCancelled && !reportedFallback) {
        promptAction.showToast({ message: $r('app.string.speed_test_complete') });
      }
      /* 后台完成才发通知(前台已有 toast;ForegroundFlag 由 EntryAbility 维护),
         对齐 OwnBox ConnectionTestNotification:用户切走后仍能知道测速跑完了 */
      let okCount = 0;
      completed.forEach((r: TestResult) => {
        if (r.status === 1) {
          okCount++;
        }
      });
      void notifyProbeDone(this.context, okCount, snapshot.length, this.testCancelled);
      /* 消息中心(对齐 OwnBox MessageStore):前台 toast 一闪而过,切走/回看时还能翻到结果 */
      this.messageSinkProbe(okCount, snapshot.length, this.testCancelled);
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[test] 测速失败: ${message}`);
      promptAction.showToast({ message: $r('app.string.connection_test_error', message) });
    } finally {
      flushPending();
      try {
        // 只合并已完成结果到最新节点列表,避免测速期间订阅更新/编辑/删除被旧快照覆盖。
        this.profiles = await mutateProfiles((profiles: Array<Profile>): Array<Profile> => {
          for (const profile of profiles) {
            const result = completed.get(profile.id);
            if (result !== undefined) {
              profile.status = result.status;
              profile.ping = result.ping;
              profile.error = result.error;
              profile.latencyMs = result.status === 1 ? result.ping : -1;
              profile.latencyTestedAt = Date.now();
            }
          }
          return profiles;
        });
        this.bumpResults();
      } catch (e) {
        const message = e instanceof Error ? e.message : `${e}`;
        LogStore.addLog(`[test] 测速结果保存失败: ${message}`);
        promptAction.showToast({ message: $r('app.string.save_failed_reason', message) });
      } finally {
        this.testing = false;
      }
    }
  }

  /** 取消进行中的测速(对齐 Android 对话框 Cancel:停止取新节点,已测结果照常落库)。 */
  cancelSpeedTest(): void {
    if (!this.testing) {
      return;
    }
    this.testCancelled = true;
  }

  /** 批量改动节点结果字段后调用:让节点卡延迟文字/颜色元素重渲染(见 resultsRev 注释)。 */
  private bumpResults(): void {
    this.resultsRev = this.resultsRev + 1;
  }

  /** 清除当前分组测试结果(对齐 Android :477-493:status!=0 → status=0/ping=0/error=null,
   *  有变化才批量落库;`__all__` 是鸿蒙自己的全组便利值) */
  async clearTestResults(groupId: string): Promise<void> {
    let changed = false;
    for (const p of this.profiles) {
      if ((groupId === '__all__' || p.groupId === groupId) && p.status !== 0) {
        p.status = 0;
        p.ping = 0;
        p.error = '';
        p.latencyMs = 0;
        p.latencyTestedAt = 0;
        changed = true;
      }
    }
    if (changed) {
      await saveProfiles(this.profiles);
      this.profiles = this.profiles.slice();
      this.bumpResults();
      promptAction.showToast({ message: $r('app.string.test_results_cleared') });
    }
  }

  /** 去重(对齐 Android ConfigurationFragment.kt:534-584「移除重复」):
   *  键 = `Protocols.Deduplication(bean, displayType())` → serverAddress+serverPort+displayType,
   *  **与更新期去重键不同**(RawUpdater.kt:114 用 javaClass.toString(),这里用 displayType);
   *  LinkedHashSet 语义 = 每个键保留首次出现、顺序即首次出现顺序;
   *  有重复时先弹确认框(列出前 20 个重复名,之后 "......"),确认后才删。 */
  async dedupGroup(groupId: string): Promise<void> {
    const seen = new Set<string>();
    const dupes: Array<Profile> = [];
    for (const p of this.profiles) {
      if (groupId !== '__all__' && p.groupId !== groupId) {
        continue;
      }
      const key = `${p.server}\u001f${p.serverPort}\u001f${p.type}`;
      if (seen.has(key)) {
        dupes.push(p);
        continue;
      }
      seen.add(key);
    }
    if (dupes.length === 0) {
      promptAction.showToast({ message: $r('app.string.dedup_none') });
      return;
    }
    // Android :548-558:delete_confirm_prompt + "\n" + 前 20 个重复名(第 21 个位置填 "......")
    const listed = dupes.map((item: Profile, index: number): string => {
      if (index < 20) {
        return item.name;
      }
      return index === 20 ? '......' : '';
    }).filter((line: string): boolean => line.length > 0).join('\n');
    AlertDialog.show({
      title: $r('app.string.confirm'),
      message: $r('app.string.dedup_confirm_body', listed),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          const dupIds = new Set<string>(dupes.map((p: Profile) => p.id));
          this.profiles = this.profiles.filter((p: Profile) => !dupIds.has(p.id));
          await saveProfiles(this.profiles);
          promptAction.showToast({ message: $r('app.string.dedup_done', dupes.length) });
        }
      }
    });
  }

  /** 删除当前分组不可用节点。对齐 Android :495-532 的判定:status!=0 && status!=1
   *  (即 2/3),先确认再删;`__all__` 是鸿蒙自己的全组便利值 */
  deleteUnavailable(groupId: string): void {
    const dead = this.profiles.filter((p: Profile) =>
      (groupId === '__all__' || p.groupId === groupId) && p.status !== 0 && p.status !== 1);
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
    this.navMemory.setSortMode(mode);
    await saveSettings(this.settings);
    this.profiles = this.profiles.slice();
  }

  /** 订阅更新结果反馈(对齐 Android GroupInterfaceAdapter.kt:29-82):
   *  - 无变化 → toast「%s:没有变化」(group_no_difference);
   *  - 有变化 → toast「%s:已更新 %d 个代理」(group_updated)+ 1 秒后弹「差异(%s)」对话框
   *    (Added / Updated / Deleted / Duplicate 四段,空段省略)。
   *  Android 用 snackbar + MaterialAlertDialog;鸿蒙等价物是 toast + 自定义对话框。 */
  private showSubUpdateFeedback(name: string, res: SubUpdateResult): void {
    if (!subUpdateHasChanges(res)) {
      promptAction.showToast({ message: $r('app.string.group_no_difference', name) });
      return;
    }
    promptAction.showToast({ message: $r('app.string.group_updated', name, res.changed) });
    /* 2026-10-26 明细对话框已下线:变化数量用这一条 toast 概述,逐项明细看消息中心。 */
  }

  /** 更新当前选中节点所属的订阅(对齐安卓 action_update_subscription) */
  async updateCurrentSubscription(): Promise<void> {
    const selected = this.profiles.find((p: Profile) => p.id === this.selectedId);
    const url = selected !== undefined ? selected.subUrl : this.activeConfigUrl;
    if (url.length === 0) {
      promptAction.showToast({ message: $r('app.string.current_subscription_missing') });
      return;
    }
    const subs = await listSubs();
    const hit = subs.find((item: SubInfo) => item.url === url);
    const sub: SubInfo | null = hit === undefined ? null : hit;
    const name = sub !== null ? sub.name : subNameOf(url);
    // Android GroupUpdater.kt:142-148:未连接且(http:// 明文 或 仅连接时更新)时先确认
    if (needDirectUpdateConfirm(url, sub, this.isRunning)) {
      AlertDialog.show({
        message: $r('app.string.update_subscription_warning'),
        primaryButton: { value: $r('app.string.cancel'), action: () => {} },
        secondaryButton: {
          value: $r('app.string.confirm'),
          action: () => {
            this.runSubscriptionUpdate(url, name);
          }
        }
      });
      return;
    }
    await this.runSubscriptionUpdate(url, name);
  }

  private async runSubscriptionUpdate(url: string, name: string): Promise<void> {
    promptAction.showToast({ message: $r('app.string.fetching_subscription') });
    try {
      const r = await updateSubscription(url);
      await this.refresh();
      this.showSubUpdateFeedback(name, r);
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.update_failed_reason', subErrorText(e as Object)) });
    }
  }

  // ---------------------------------------------------------------- P3/B 订阅页接线(tab 1)

  /** 每个订阅的节点数(订阅页 nodeCounts;节点归属按 Profile.subUrl) */
  private subscriptionNodeCounts(): Array<SubscriptionNodeCount> {
    const urls: Array<string> = [];
    for (let i = 0; i < this.profiles.length; i++) {
      urls.push(this.profiles[i].subUrl);
    }
    return nodeCountsFromSubUrls(urls);
  }

  private subNameOfUrl(url: string): string {
    const hit = this.subscriptions.find((item: SubInfo) => item.url === url);
    return hit === undefined ? subNameOf(url) : hit.name;
  }

  /** 更新单个订阅(订阅页行内「更新」):行内 updating 状态 + markSub* 记账,失败原文给 toast */
  private async updateOneSubscription(url: string, name: string): Promise<void> {
    if (this.updatingSubUrl.length > 0 || this.updatingAllSubs) {
      return;
    }
    this.updatingSubUrl = url;
    try {
      const r = await updateSubscription(url);
      await markSubSuccess(url);
      await this.refresh();
      this.showSubUpdateFeedback(name, r);
      /* P3②:本次更新新增了节点 ⇒ 视为"刚导入完成"(§4.5 import_done 数据源) */
      if (r.added > 0) {
        this.markImportCompleted(r.added, []);
      }
    } catch (e) {
      await markSubFailure(url);
      promptAction.showToast({ message: $r('app.string.update_failed_reason', subErrorText(e as Object)) });
      await this.refresh();
    } finally {
      this.updatingSubUrl = '';
    }
  }

  /**
   * 更新全部订阅(订阅页「更新全部」/ 顶栏 ACTION_UPDATE_ALL):
   * 串行更新 → markSubSuccess/markSubFailure 记账 → 聚合摘要(summarizeUpdate)+ 失败原文列表。
   * 与 GroupPage 的按钮同源 API,但由壳层触发,状态挂在 Index 上供顶栏动作可用性使用。
   */
  private async updateAllSubscriptions(): Promise<void> {
    if (this.updatingAllSubs || this.updatingSubUrl.length > 0) {
      return;
    }
    const subs: Array<SubInfo> = this.subscriptions.length > 0 ? this.subscriptions : await listSubs();
    if (subs.length === 0) {
      return;
    }
    this.updatingAllSubs = true;
    this.batchVisible = false;
    this.batchOutcomes = [];
    this.batchFailedMessages = [];
    const results: Array<SubUpdateResult> = [];
    const failures: Array<string> = [];
    const outcomes: Array<PerSubOutcome> = [];
    try {
      for (let i = 0; i < subs.length; i++) {
        const sub = subs[i];
        const outcome = new PerSubOutcome();
        outcome.name = sub.name.length > 0 ? sub.name : subNameOf(sub.url);
        try {
          const r = await updateSubscription(sub.url);
          await markSubSuccess(sub.url);
          results.push(r);
          outcome.ok = true;
          outcome.notModified = r.notModified;
          outcome.added = r.addedNames.length;
          outcome.updated = r.updatedNames.length;
          outcome.removed = r.deletedNames.length;
          outcome.skipped = r.skipped;
        } catch (e) {
          await markSubFailure(sub.url);
          const reason = subErrorText(e as Object);
          failures.push(`${sub.name}: ${reason}`);
          outcome.ok = false;
          outcome.error = reason;
        }
        outcomes.push(outcome);
      }
      await this.refresh();
      const summary: UpdateBatchSummary = summarizeUpdate(results, failures);
      /* W18(§11.3):逐订阅结果行 + 汇总(结构化传递,页面映射文案);一个失败不覆盖其他订阅的结果 */
      this.batchSummaryModel = summary;
      this.batchOutcomes = outcomes;
      this.batchFailedMessages = summary.failedMessages;
      this.batchVisible = true;
      /* 批量更新结果落一条消息(对齐 OwnBox 订阅更新通知) */
      void addMessage('subscription', this.locText($r('app.string.messages_sub_updated')),
        `${this.locText($r('app.string.messages_added'))} ${summary.added} / `
          + `${this.locText($r('app.string.messages_failed'))} ${summary.failed}`);
      if (summary.failed > 0) {
        LogStore.addLog(`[app] 更新全部订阅(顶栏):${summary.failed} 个失败`);
      }
      /* P3②:批量更新带来新节点 ⇒ 导入完成引导数据源 */
      if (summary.added > 0) {
        this.markImportCompleted(summary.added, []);
      }
    } finally {
      this.updatingAllSubs = false;
    }
  }

  /** 删除订阅(订阅页已在页面内二次确认) */
  private async deleteSubscription(url: string): Promise<void> {
    try {
      await removeSub(url);
      /* W17:订阅删除后清理原始层文件与覆盖层墓碑(经事务仓库串行提交) */
      await SubscriptionRepository.purgeSubscriptionArtifacts(url);
      await this.refresh();
      LogStore.addLog(`[app] 删除订阅: ${this.subNameOfUrl(url)}`);
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.operation_failed', subErrorText(e as Object)) });
    }
  }

  /** W20:从 Preferences 恢复显示流量基准(UI 与扩展通知共用同一份)。 */
  private async loadTrafficBaseline(): Promise<void> {
    try {
      const text = await readPrefString('traffic_display_baseline', '');
      this.trafficBaseline = text.length > 0 ? parseBaseline(text) : null;
    } catch (e) {
      this.trafficBaseline = null;
    }
  }

  /** W18:清空某订阅的全部节点(订阅记录保留;页面已二次确认) */
  private async clearSubscriptionNodes(url: string): Promise<void> {
    try {
      const removed = await SubscriptionRepository.clearSubscriptionNodes(url);
      promptAction.showToast({ message: `已清空 ${removed} 个节点,订阅保留` });
      await this.refresh();
      LogStore.addLog(`[ui] 清空订阅节点: ${this.subNameOfUrl(url)} 移除 ${removed} 个`);
    } catch (e) {
      promptAction.showToast({ message: `清空节点失败: ${subErrorText(e as Object)}` });
    }
  }

  /** 清除累计流量统计(对齐安卓 action_clear_traffic_statistics) */
  clearTrafficStatistics(): void {
    this.lastUp = 0;
    this.lastDown = 0;
    this.lastTrafficAt = 0;
    /* W20(§10.4):重置 = 记录基准偏移(含会话 epoch);UI 与通知从同一基准计算,
       轮询不再把旧显示值写回。节点历史流量(Profile.rx/tx)不受影响。 */
    if (this.isRunning && this.rawTotalUp >= 0 && this.rawTotalDown >= 0 &&
      (this.rawTotalUp > 0 || this.rawTotalDown > 0)) {
      const sessionId = AppStorage.get<string>('vpnSessionId') ?? '';
      this.trafficBaseline = buildBaseline(this.rawTotalUp, this.rawTotalDown, sessionId, Date.now());
      void writePrefString('traffic_display_baseline', baselineToJson(this.trafficBaseline));
      LogStore.addLog(`[ui] 重置显示累计流量: 基准 ↑${this.rawTotalUp} ↓${this.rawTotalDown}(会话 ${sessionId})`);
    } else {
      this.trafficBaseline = null;
      void writePrefString('traffic_display_baseline', '');
    }
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
    // 单一事实来源 = profile.status/ping(对齐 Android ProxyEntity),失败与未测都排到最后
    return p.status === 1 ? p.ping : Number.MAX_SAFE_INTEGER;
  }

  profilesInGroup(groupId: string): Array<Profile> {
    return this.sortedProfiles().filter((p: Profile) =>
      belongsToGroup(p, groupId) && inActiveSubs(p.subUrl, this.activeSubUrls));
  }

  sortedGroupIds(): Array<string> {
    /* 「只看一个订阅」:分组条只留这个订阅自带的策略组(含未分组),
       分组归属按 ProfileGroup.subUrl → 成员节点 subUrl 反推(见 core/SubGroups) */
    if (this.activeSubUrls.length > 0) {
      return groupIdsForSubscriptions(this.groups, this.profiles, this.activeSubUrls);
    }
    const ids: Array<string> = [];
    const sortedGroups = this.groups.slice().sort((a: ProfileGroup, b: ProfileGroup) => a.sortOrder - b.sortOrder);
    for (const group of sortedGroups) {
      if (this.profiles.some((profile: Profile) => profile.groupId === group.id)) {
        ids.push(group.id);
      }
    }
    if (this.profiles.some((profile: Profile) => profile.groupId.length === 0
      && (profile.subGroupIds ?? []).length === 0)) {
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
      (profile.name.toLowerCase().includes(query) || profile.alias.toLowerCase().includes(query))
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

  /** 组内最优延迟(仅计 status==1 的成功值;无有效值返回 -1)。鸿蒙 G2 超集,Android 无组头徽标。 */
  private groupMinLatency(groupId: string): number {
    // 同样依赖 resultsRev:分组标签上的"最低 xxms"也要在清除结果/测速后立即刷新
    if (this.resultsRev < 0) {
      return -1;
    }
    let min = -1;
    for (const p of this.profilesInGroup(groupId)) {
      if (p.status === 1 && (min < 0 || p.ping < min)) {
        min = p.ping;
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

  /** 节点卡延迟文本。语义 1:1 对齐 Android 列表项(ConfigurationFragment.kt:1565-1592):
   *  status 1 → `%dms`(任意成功值,不分档);status 2 → 对应失败文案;
   *  status 3 → genFriendlyMsg 映射,映射不上显示「不可用」;status 0 → 空(测试中显示"测试中…")。
   *
   *  ⚠️ 首行必须"触碰" resultsRev:节点列表 ForEach 的 key 只有 `profile.id`,测速结果与
   *  「清除测试结果」都是**在原 Profile 对象上改字段**,ArkUI 按 key 复用条目、不会重跑
   *  nodeCard 构建器 —— 依赖 id 的话延迟文字会一直停在旧值,必须退出重进才刷新(真机 bug)。
   *  这里读一次 @State,即把该 Text 元素注册为 resultsRev 的依赖:版本号一变,
   *  只重渲染这些文字/颜色元素,不动整表(比换 key 全表重建便宜,也不会打断滚动)。 */
  latencyText(p: Profile): ResourceStr {
    if (this.resultsRev < 0) {
      return '';
    }
    if (p.status === 1) {
      return `${p.ping}ms`;
    }
    if (p.status >= 2) {
      const label = this.errorLabel(p);
      return label === null ? $r('app.string.connection_test_unavailable') : label;
    }
    return this.testing ? $r('app.string.connection_test_testing') : '';
  }

  /** status 2 的 error 本身就是机器 token;status 3 先走 Android 的 genFriendlyMsg 规则 */
  private errorToken(p: Profile): string {
    if (p.status === 2) {
      return p.error;
    }
    if (p.status === 3) {
      const friendly = genFriendlyMsg(p.error);
      return friendly === null ? '' : friendly;
    }
    return '';
  }

  private errorLabel(p: Profile): Resource | null {
    const token = this.errorToken(p);
    if (token === TestError.TIMEOUT) {
      return $r('app.string.timeout');
    }
    if (token === TestError.REFUSED) {
      return $r('app.string.connection_test_refused');
    }
    if (token === TestError.UNREACHABLE) {
      return $r('app.string.connection_test_unreachable');
    }
    if (token === TestError.DOMAIN_NOT_FOUND) {
      return $r('app.string.connection_test_domain_not_found');
    }
    return null;
  }

  /** 节点卡延迟颜色。Android 只有两档:status 1 绿(material_green_500)、2/3 红;
   *  0/未测 次要色。旧的 150/400 三档阈值(无论改前哪个版本引入)已按 1:1 要求删除。 */
  latencyColor(p: Profile): ResourceColor {
    // 与 latencyText 同理:必须依赖 resultsRev,否则清除结果后颜色停在旧状态
    if (this.resultsRev < 0) {
      return $r('app.color.text_3');
    }
    if (p.status === 1) {
      // 2026-10-23 用户要求:按延迟区间分档上色(300ms/1000ms 不能都是绿)。
      // 阈值与分组标签的 latencyColorOfMs 一致(<150 绿 / <400 琥珀 / 其余红),
      // 保证"同一延迟在节点卡与分组标签上颜色相同"。
      return this.latencyColorOfMs(p.ping);
    }
    if (p.status >= 2) {
      return $r('app.color.error');
    }
    return $r('app.color.text_3');
  }

  /** status 3 点击延迟文字看内核原文(对齐 Android 列表项点击 error 弹原文 :1583-1589) */
  private showTestError(p: Profile): void {
    if (p.status !== 3 || p.error.length === 0) {
      return;
    }
    AlertDialog.show({
      title: $r('app.string.connection_test_error_detail'),
      message: p.error,
      primaryButton: { value: $r('app.string.ok'), action: () => {} },
      autoCancel: true
    });
  }

  // ---------------------------------------------------------------- P3/W12 检测结果 → 节点首页视图模型

  /** StoredProbe(持久化 DTO) → ProbeResult(业务模型):**逐字段复制**
   *  (ArkTS 没有结构类型,不能用 cast;DTO 缺字段时按"未知"兜底,不伪造 HTTP 通过 §6.2) */
  private toProbeResult(s: StoredProbe): ProbeResult {
    const r = new ProbeResult();
    r.runId = s.runId;
    r.profileId = s.profileId;
    r.configRevision = s.configRevision;
    r.profileConfigHash = s.profileConfigHash;
    r.methodRequested = s.methodRequested.length > 0 ? s.methodRequested : PROBE_METHOD_UNKNOWN;
    r.methodActual = s.methodActual.length > 0 ? s.methodActual : PROBE_METHOD_UNKNOWN;
    r.state = s.state.length > 0 ? s.state : PROBE_STATE_FAILED;
    r.latencyMs = s.latencyMs;
    r.samples = s.samples;
    r.aggregation = s.aggregation.length > 0 ? s.aggregation : PROBE_AGG_SINGLE;
    r.target = s.target;
    r.timeoutMs = s.timeoutMs;
    r.expectedStatus = s.expectedStatus.length > 0 ? s.expectedStatus : PROBE_EXPECT_2XX;
    r.startedAt = s.startedAt;
    r.completedAt = s.completedAt;
    r.persistedAt = s.persistedAt;
    r.path = s.path.length > 0 ? s.path : PROBE_PATH_UNBOUND_UNKNOWN;
    r.errorCode = s.errorCode;
    r.errorDetail = s.errorDetail;
    r.degradedReason = s.degradedReason;
    r.coreCapability = s.coreCapability.length > 0 ? s.coreCapability : PROBE_CAP_UNAVAILABLE;
    r.source = s.source.length > 0 ? s.source : PROBE_SOURCE_MANUAL;
    r.participated = PROBE_PARTICIPATED_YES;
    return r;
  }

  /**
   * 读一次落盘结果(ProbeStore.latestAll)并与本次会话 live 结果合并(§6.3):
   * live 更新则优先;取消未执行的节点保留历史成功值;仅历史值标「历史」不冒充当前可用。
   * 同时重建 profileId → 结果的索引(节点行/状态卡按 O(1) 取)。
   */
  async refreshProbeResults(): Promise<void> {
    let stored: Array<ProbeResult> = [];
    try {
      const raw: Array<StoredProbe> = ProbeStore.latestAll();
      for (let i = 0; i < raw.length; i++) {
        stored.push(this.toProbeResult(raw[i]));
      }
    } catch (e) {
      LogStore.addLog(`[probe] 读取检测结果失败: ${e}`);
      stored = [];
    }
    const merged: Array<ProbeMerge> = mergeLiveWithStored(this.liveProbeResults, stored,
      Date.now(), this.settings.latencyStaleMs);
    const out: Array<ProbeResult> = [];
    const index = new Map<string, ProbeResult>();
    for (let i = 0; i < merged.length; i++) {
      const r: ProbeResult = merged[i].result;
      out.push(r);
      index.set(r.profileId, r);
    }
    this.resultIndex = index;
    this.probeResults = out;
  }

  /** testProfiles 的 onProbe 回调:收集 live 结果(同 profileId 覆盖),节流 300ms 合并到界面 */
  private upsertLiveProbe(probe: ProbeResult): void {
    if (probe.state === PROBE_STATE_QUEUED) {
      return;
    }
    let replaced = false;
    for (let i = 0; i < this.liveProbeResults.length; i++) {
      if (this.liveProbeResults[i].profileId === probe.profileId) {
        this.liveProbeResults[i] = probe;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      this.liveProbeResults.push(probe);
    }
    this.scheduleLiveRefresh();
  }

  /** live 结果合并节流(与测速的 300ms 合并刷一口径,避免逐节点重渲染整页) */
  private scheduleLiveRefresh(): void {
    if (this.liveFlushTimer >= 0) {
      return;
    }
    this.liveFlushTimer = setTimeout(() => {
      this.liveFlushTimer = -1;
      void this.refreshProbeResults();
    }, 300);
  }

  /** profileId → 最近一次结果(null = 从未测过) */
  private probeResultOf(profileId: string): ProbeResult | null {
    /* 首行触碰 @State probeResults:节点行/状态卡里读它的那些元素要随结果刷新重渲染
       (与 latencyText 读 resultsRev 同一手法,避免 ForEach 按 id 复用后不重跑构建器) */
    if (this.probeResults.length < 0) {
      return null;
    }
    const r = this.resultIndex.get(profileId);
    return r === undefined ? null : r;
  }

  private runningProfileId(): string {
    return AppStorage.get<string>('vpnRunningProfileId') ?? '';
  }

  private runningProfileName(): string {
    const id = this.runningProfileId();
    const p = this.profiles.find((item: Profile) => item.id === id);
    return p === undefined ? '' : p.name;
  }

  /** vpnStatus 词表归一:start_failed:<msg> / start_timeout 按"连接失败"呈现(§4.3);
   *  'connected:<描述>'(VpnService.ets:160)压成裸 'connected' —— HomeView.vpnSessionView 只认裸词 */
  private normalizedVpnStatus(): string {
    const s = this.statusText;
    if (s.startsWith('start_failed:')) {
      return `connect_failed:${s.substring('start_failed:'.length)}`;
    }
    if (s === 'start_timeout') {
      return 'connect_failed:启动超时，VPN 扩展无响应';
    }
    if (s.startsWith('connected:')) {
      return 'connected';
    }
    return s;
  }

  /** 状态卡视图(§4.2:会话与连通性两套状态独立;连接结果绝不改会话状态) */
  private statusCard(): StatusCardView {
    const runningId = this.runningProfileId();
    const session: VpnSessionView = vpnSessionView(this.normalizedVpnStatus(), this.isRunning,
      runningId, this.runningProfileName());
    const targetId = runningId.length > 0 ? runningId : this.selectedId;
    const conn: ConnectivityView = connectivityView(this.probeResultOf(targetId), Date.now(),
      this.settings.latencyStaleMs);
    return statusCardView(session, conn);
  }

  private sessionTitleText(): string {
    const token = this.statusCard().session.titleToken;
    if (token === 'connected') {
      return '已连接';
    }
    if (token === 'connecting') {
      return '连接中…';
    }
    if (token === 'switching') {
      return '切换中…';
    }
    if (token === 'disconnecting') {
      return '断开中…';
    }
    if (token === 'awaiting_auth') {
      return '等待系统授权…';
    }
    if (token === 'connect_failed') {
      return '连接失败';
    }
    if (token === 'disconnected') {
      return '未连接';
    }
    return '正在确认状态…';
  }

  private sessionDotColor(): ResourceColor {
    const token = this.statusCard().session.titleToken;
    if (token === 'connected') {
      return $r('app.color.success');
    }
    if (token === 'connect_failed') {
      return $r('app.color.error');
    }
    if (token === 'connecting' || token === 'switching' || token === 'disconnecting'
      || token === 'awaiting_auth') {
      return $r('app.color.primary');
    }
    return $r('app.color.text_3');
  }

  /** 连通性文案(§6.1/§6.6:HTTP 有响应 ≠ 正常访问;TCP 回退只证明握手;旧结果标历史) */
  private connectivityText(): string {
    const card = this.statusCard();
    const token = card.connectivity.titleToken;
    const method = card.connectivity.methodToken;
    let base = '连通性未检测';
    if (token === 'probing') {
      base = '连通性检测中…';
    } else if (token === 'reachable') {
      base = `连通正常 · ${this.methodLabelText(method)}`;
    } else if (token === 'failed') {
      base = '连通性测试失败';
    } else if (token === 'stale') {
      base = '连通性结果已过期';
    } else if (token === 'restricted') {
      base = `连通性受限 · ${this.methodLabelText(method)}`;
    }
    if (card.connectivity.latencyMs >= 0 && (token === 'reachable' || token === 'stale')) {
      base = `${base} · ${card.connectivity.latencyMs} ms`;
    }
    if (token === 'reachable' && card.connectivity.ageText.length > 0) {
      base = `${base} · ${card.connectivity.ageText}`;
    }
    return base;
  }

  private methodLabelText(methodToken: string): string {
    if (methodToken === 'http_2xx') {
      return 'HTTP 2xx';
    }
    if (methodToken === 'http_any_response') {
      return 'HTTP 有响应';
    }
    if (methodToken === 'tcping') {
      return 'TCP 握手';
    }
    if (methodToken === 'http_degraded_tcping') {
      return 'TCP 回退';
    }
    return '方式未知';
  }

  private connectivityColor(): ResourceColor {
    const token = this.statusCard().connectivity.titleToken;
    if (token === 'reachable') {
      return $r('app.color.success');
    }
    if (token === 'failed') {
      return $r('app.color.error');
    }
    if (token === 'stale' || token === 'restricted') {
      return $r('app.color.warning');
    }
    return $r('app.color.text_3');
  }


  /** 连接动作可用性(§4.3-2):无节点不给必然失败的连接;切换中禁用;配置不合法停在本页给修复入口 */
  private connectGate(): ActionReason {
    /* 同步闸只判"有没有节点 / 是否切换中";真正的配置合法性要异步校验(K1 checkConfig 需读文件),
       在 connectTo() 的 preConnectConfigCheck() 里做 —— 无效时停留本页 + 修复入口,不进入重连循环(§4.3-2) */
    const configValid = this.profiles.length > 0;
    return connectActionEnabled(this.profiles.length, configValid, this.switching);
  }

  private toastConnectGate(reason: string): void {
    if (reason === 'no_profile') {
      promptAction.showToast({ message: '还没有节点，先导入订阅或新建节点' });
      return;
    }
    if (reason === 'config_invalid') {
      promptAction.showToast({ message: '当前配置无法连接，请检查订阅或节点设置' });
      return;
    }
    if (reason === 'applying') {
      promptAction.showToast({ message: $r('app.string.switching_wait') });
      return;
    }
    promptAction.showToast({ message: $r('app.string.connection_test_unavailable') });
  }

  // ------------------------------------------------ P3① 配置校验闸(K1,§4.3-2)

  /**
   * 用**既有** buildCoreConfig 生成一份与连接时同源的配置,写进 core/config.json(连接时本来就会重写),
   * 再交给 K1 的 `CoreManager.checkConfig`(纯解析,不调 box.New/不启动内核)校验 schema。
   * 返回:'ok' 通过 / 'unsupported' 旧 .so 无该导出 / 'invalid' 配置无效(原文见 lastConfigCheckErr)。
   * ⚠️ 只在"点连接"时调用,渲染路径永远不跑(§4.3-2:校验失败停在本页给修复入口,不进入重连循环)。
   */
  private async checkConfigBeforeConnect(node: Profile): Promise<string> {
    let json = '';
    try {
      let customRules: Array<RouteRule> = [];
      try {
        customRules = await loadRouteRules();
      } catch (e) {
        customRules = [];
      }
      let remoteRuleSets: Array<RemoteRuleSet> = [];
      try {
        remoteRuleSets = await loadRemoteRuleSets();
      } catch (e) {
        remoteRuleSets = [];
      }
      /* 与 VpnExtAbility 同口径:资源统一由 ResourceResolver 快照(只读、不联网、不落盘)。
         预校验只消费已缓存规则集,不会为了校验去下载;内核日志路径(logPath)由扩展进程生成,传 '' */
      const prepared = ResourceResolver.snapshot(remoteRuleSets, this.settings.mode === 'rule', this.context);
      json = buildCoreConfig(node, this.settings, '', '', prepared.geositePath, prepared.geoIpPath,
        customRules, prepared.ruleSets, '', this.profiles, this.groups, '');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      this.lastConfigCheckErr = msg;
      LogStore.addLog(`[check] 配置生成失败: ${msg}`);
      return 'invalid';
    }
    let res = '';
    try {
      const path = CoreManager.writeConfigFile(this.context, json);
      res = await CoreManager.checkConfig(path);
    } catch (e) {
      // 校验通道本身不可用(旧 .so 无导出 / 文件系统异常):不阻断连接,如实降级
      LogStore.addLog(`[check] 配置校验不可用,本次跳过: ${e}`);
      this.lastConfigCheckErr = '';
      return 'unsupported';
    }
    if (res === 'unsupported') {
      LogStore.addLog('[check] 内核无 checkConfig 导出(旧 .so),跳过配置校验(能力降级)');
      this.lastConfigCheckErr = '';
      return 'unsupported';
    }
    if (res.length === 0) {
      this.lastConfigCheckErr = '';
      return 'ok';
    }
    const detail = res.startsWith('err:') ? res.substring('err:'.length) : res;
    this.lastConfigCheckErr = detail;
    LogStore.addLog(`[check] 配置校验未通过: ${detail}`);
    return 'invalid';
  }

  /** 连接前闸门:通过返回 true;无效则弹原文 + 给修复入口并**不发起连接** */
  private async preConnectConfigCheck(node: Profile): Promise<boolean> {
    if (this.configChecking) {
      promptAction.showToast({ message: '正在校验配置，请稍候' });
      return false;
    }
    this.configChecking = true;
    try {
      const verdict = await this.checkConfigBeforeConnect(node);
      if (verdict === 'ok') {
        return true;
      }
      if (verdict === 'unsupported') {
        return true;
      }
      const err = this.lastConfigCheckErr.length > 0 ? this.lastConfigCheckErr : '配置不合法';
      promptAction.showToast({ message: '配置无效，已阻止连接' });
      AlertDialog.show({
        title: '配置无效',
        message: err,
        autoCancel: true,
        primaryButton: { value: $r('app.string.cancel'), action: () => {} },
        secondaryButton: {
          value: '去修复',
          fontColor: $r('app.color.primary'),
          action: () => {
            this.jumpToConfigFix(node);
          }
        }
      });
      return false;
    } finally {
      this.configChecking = false;
    }
  }

  /** 修复入口:订阅导入的节点 → 订阅页;手建节点 → 节点编辑页 */
  private jumpToConfigFix(node: Profile): void {
    if (node.subUrl.length > 0) {
      this.switchTab(drawerIndexOfPage(PAGE_SUBSCRIPTIONS));
      return;
    }
    router.pushUrl({ url: 'pages/ProfileEdit' });
  }

  // ------------------------------------------------ P3② 空态三态数据源

  /** 状态回传钩子:授权被拒标记 + 连接成功清校验失败/清"下次连接生效" */
  onVpnStatusWatch(): void {
    const s = this.statusText;
    this.markAuthorizationDenied(s);
    if (s.startsWith('connected:')) {
      /* 真正连接成功 → 上次的校验失败不再成立;"下次连接生效"的待应用状态也失效。
         连接即全量生效(扩展启动加载磁盘快照) ⇒ 待应用计数必须清账,
         否则连接后横幅冒出来谎称"点应用立即生效"(2026-10-24 真机)。 */
      this.lastConfigCheckErr = '';
      this.applyCoordinator.markAllAppliedOnConnect();
      if (this.pendingForNextConnect) {
        this.pendingForNextConnect = false;
        this.applyBannerRev = this.applyBannerRev + 1;
        LogStore.addLog('[apply] 连接成功:清除"下次连接生效"标记');
      }
    }
  }

  /**
   * 网络可用性:先查一次默认网络,再注册 NetConnection 监听
   * (与 VpnExtAbility.registerNetworkChange 用同一套回调,UI 侧只读不触发重连)。
   */
  private startNetworkWatch(): void {
    if (this.netWatch !== null) {
      return;
    }
    this.updateNetworkAvailable();
    try {
      const conn = connection.createNetConnection();
      conn.on('netAvailable', () => {
        this.networkAvailable = true;
      });
      conn.on('netLost', () => {
        this.updateNetworkAvailable();
      });
      conn.on('netCapabilitiesChange', () => {
        this.updateNetworkAvailable();
      });
      conn.register((err: BusinessError) => {
        if (err) {
          LogStore.addLog(`[nav] 注册网络可用性监听失败: ${err.message}`);
        }
      });
      this.netWatch = conn;
    } catch (e) {
      LogStore.addLog(`[nav] 创建网络监听对象失败: ${e}`);
    }
  }

  /** 查默认网络;查不到时按"可用"处理(监听失效不该挡用户操作) */
  private updateNetworkAvailable(): void {
    try {
      const net = connection.getDefaultNetSync();
      this.networkAvailable = net !== null && net.netId > 0;
    } catch (e) {
      this.networkAvailable = true;
    }
  }

  private stopNetworkWatch(): void {
    if (this.netWatch === null) {
      return;
    }
    try {
      this.netWatch.unregister((err: BusinessError) => {
        if (err) {
          LogStore.addLog(`[nav] 取消网络监听失败: ${err.message}`);
        }
      });
    } catch (e) {
      // 注销失败不影响功能,页面已在退出
    }
    this.netWatch = null;
  }

  /**
   * 授权拒绝标记(§4.5 auth_denied 分支):系统 VPN 授权被拒会沿既有失败路径回传
   * `connect_failed:<文案>`(VpnService/VpnExtAbility 都走这个词表),文案里带"授权"/permission 即置位。
   * ⚠️ 'awaiting_auth' 是"正在弹授权框",不是拒绝,不置位。
   */
  private markAuthorizationDenied(status: string): void {
    if (this.firstAuthorizationDenied || !status.startsWith('connect_failed:')) {
      return;
    }
    const msg = status.substring('connect_failed:'.length);
    const lower = msg.toLowerCase();
    if (msg.includes('授权') || lower.includes('permission') || lower.includes('auth')) {
      this.firstAuthorizationDenied = true;
      LogStore.addLog('[nav] 检测到系统 VPN 授权被拒,空态切换为授权引导');
    }
  }

  /** 导入完成标记(§4.5 import_done 分支):added>0 视为刚导入完成,30s 后自动清 */
  private markImportCompleted(imported: number, skippedTypes: Array<string>): void {
    this.importedCount = imported;
    this.skippedTypes = skippedTypes.slice();
    this.importJustCompleted = true;
    if (this.importStateTimer >= 0) {
      clearTimeout(this.importStateTimer);
    }
    this.importStateTimer = setTimeout(() => {
      this.importStateTimer = -1;
      this.importJustCompleted = false;
      this.skippedTypes = [];
    }, 30000);
  }

  // ------------------------------------------------ P4/W16-B 应用事务(§12.3/§14.3)

  /**
   * 提交一次设置变更并（必要时）应用:
   * ① `ConfigRepository.commit()` 把当前设置写进**新快照**(revision+1,不可变文件 + 双槽 manifest);
   * ② `ApplyCoordinator.markSaved()` 推进 savedRevision(**不推进 applied**,§14.3);
   * ③ VPN 运行中 → 发布 `apply` 命令(operationId/generation/revision/sessionId),
   *    phase 转 applying,等扩展回执;VPN 未运行 → 只保存,横幅转"下次连接生效"。
   * 提交失败:如实 toast + 保留待应用,不假装已生效。
   */
  private async commitAndApplySettings(source: string): Promise<void> {
    if (!ConfigRepository.hasActive()) {
      /* 快照还没建立(MigrationV5 未完成):只保存 Preferences,不伪造 savedRevision */
      LogStore.addLog(`[apply] ${source}: 配置快照未初始化,本次仅保存 Preferences`);
      return;
    }
    try {
      /* ⚠️ 提交的必须是**盘上最新**设置:PerAppManager 等组件直接落盘 Preferences,
         壳层 this.settings 若是旧副本,快照与扩展本地设置不一致 ⇒ settings_out_of_sync
         拒绝应用、待应用横幅永远挂着(2026-10-24 真机反馈根因)。 */
      const fresh = await loadSettings();
      this.settings = fresh;
      const snap = await ConfigRepository.commit((content: SnapshotContent): SnapshotContent => {
        content.settings = settingsToRecord(fresh);
        return content;
      });
      this.applyCoordinator.markSaved(snap.revision);
      this.applyTargetRevision = snap.revision;
      this.applyBannerDismissed = false;
      LogStore.addLog(`[apply] ${source}: 设置已提交快照 r${snap.revision}(savedRevision 前进,applied 未推进)`);
      this.applyBannerRev = this.applyBannerRev + 1;
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[apply] ${source}: 快照提交失败: ${msg}`);
      promptAction.showToast({ message: `配置保存失败: ${msg}` });
      this.applyBannerRev = this.applyBannerRev + 1;
      return;
    }
    await this.applyLatestSavedRevision(source);
  }

  /** 把**已保存**的最新 revision 应用到运行中的 VPN(横幅「应用」也走这里) */
  private async applyLatestSavedRevision(source: string): Promise<void> {
    const rev = this.applyTargetRevision > 0 ? this.applyTargetRevision : ConfigRepository.getActiveRevision();
    if (rev <= 0) {
      LogStore.addLog(`[apply] ${source}: 没有可应用的快照修订`);
      return;
    }
    if (!this.isRunning) {
      /* VPN 未运行:配置在下次连接时自然生效,不假装已应用 */
      this.pendingForNextConnect = true;
      this.applyBannerRev = this.applyBannerRev + 1;
      promptAction.showToast({ message: $r('app.string.saved_reconnect_vpn') });
      LogStore.addLog(`[apply] ${source}: VPN 未运行,已标记"下次连接生效" r${rev}`);
      return;
    }
    const opId = `apply-${Date.now().toString(16)}-${Math.floor(Math.random() * 0xffff).toString(16)}`;
    this.applyOperationId = opId;
    this.applyTargetRevision = rev;
    this.applyGeneration = this.applyGeneration + 1;
    this.applySessionId = AppStorage.get<string>('vpnSessionId') ?? '';
    if (!this.applyCoordinator.beginApply(opId, rev)) {
      LogStore.addLog(`[apply] ${source}: 同一操作已在进行(op=${opId}),忽略重复请求`);
      return;
    }
    const cmd = new VpnCommand();
    cmd.cmd = 'apply';
    cmd.operationId = opId;
    cmd.generation = this.applyGeneration;
    /* VpnCommand.revision = 目标快照修订(不是 appliedRevision) */
    cmd.revision = rev;
    cmd.sessionId = this.applySessionId;
    publishVpnCommand(cmd);
    /* 先武装看门狗再触发重渲染:横幅判断里要看 applyWatchdogTimer,顺序反了会把刚发起的 apply 当陈旧态 */
    this.applyStartedAtMs = Date.now();
    this.startApplyWatchdog(opId);
    this.applyBannerRev = this.applyBannerRev + 1;
    LogStore.addLog(`[apply] ${source}: 已请求应用 r${rev}(op=${opId},gen=${this.applyGeneration})`);
  }

  /**
   * 扩展回执(@Watch AppStorage 键,由 EntryAbility.subscribeApplyResults 写入):
   * 只有 operationId 与我们发出的这次一致才认;成功 → acceptAck 清待应用;失败 → onFailure 真实展示。
   */
  onApplyResultWatch(): void {
    const opId = AppStorage.get<string>('vpnApplyOperationId') ?? '';
    if (opId.length === 0 || this.applyOperationId.length === 0 || opId !== this.applyOperationId) {
      return;
    }
    const ok = AppStorage.get<boolean>('vpnApplyOk') ?? false;
    const err = AppStorage.get<string>('vpnApplyError') ?? '';
    const appliedRev = AppStorage.get<number>('vpnAppliedRevision') ?? 0;
    const sessionId = AppStorage.get<string>('vpnApplySessionId') ?? '';
    this.clearApplyWatchdog();
    if (ok) {
      const accepted = this.applyCoordinator.acceptAck(opId, this.applyGeneration, sessionId,
        appliedRev, this.applyGeneration, this.applySessionId);
      if (accepted) {
        this.pendingForNextConnect = false;
        LogStore.addLog(`[apply] 应用成功: appliedRevision=r${appliedRev}`);
      } else {
        /* 迟到/跨会话回执:不接受、不改状态(§12.3-6) */
        LogStore.addLog(`[apply] 回执被协调器拒绝(op=${opId}, session=${sessionId});保持现状`);
      }
    } else {
      const reason = err.length > 0 ? err : '应用失败(扩展未给出原因)';
      this.applyCoordinator.onFailure(opId, reason);
      LogStore.addLog(`[apply] 应用失败: ${reason}`);
      promptAction.showToast({ message: `应用失败: ${reason}` });
    }
    this.applyBannerRev = this.applyBannerRev + 1;
  }

  /** 放弃草稿:设置恢复为已应用值(活动快照的 settings;无快照则回落到 Preferences)+ 协调器清零 */
  private async discardSettingsDraft(): Promise<void> {
    try {
      const active = ConfigRepository.getActive();
      if (active !== null && Object.keys(active.content.settings).length > 0) {
        this.settings = JSON.parse(JSON.stringify(active.content.settings)) as AppSettings;
      } else {
        this.settings = await loadSettings();
      }
      await saveSettings(this.settings);
      this.applyCoordinator.discardDraft();
      this.applyBannerRev = this.applyBannerRev + 1;
      LogStore.addLog('[apply] 已放弃草稿:设置回到已应用值');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[apply] 放弃草稿失败: ${msg}`);
      promptAction.showToast({ message: `放弃草稿失败: ${msg}` });
    }
  }

  /** 60s 无回执兜底:如实失败(保留待应用,不无限重试;不回滚,回滚机会留给扩展失败路径) */
  private startApplyWatchdog(opId: string): void {
    this.clearApplyWatchdog();
    this.applyWatchdogTimer = setTimeout(() => {
      this.applyWatchdogTimer = -1;
      this.applyCoordinator.onFailure(opId, '应用回执超时(60s 未收到扩展回执)');
      this.applyBannerRev = this.applyBannerRev + 1;
      LogStore.addLog(`[apply] 应用回执超时: op=${opId}`);
    }, 60000);
  }

  private clearApplyWatchdog(): void {
    if (this.applyWatchdogTimer >= 0) {
      clearTimeout(this.applyWatchdogTimer);
      this.applyWatchdogTimer = -1;
    }
  }

  private applyStateSnapshot(): ApplyState {
    if (this.applyBannerRev < 0) {
      return new ApplyState();
    }
    const st = this.applyCoordinator.getSnapshot();
    /* 显示层自愈(2026-10-30 真机:分应用页顶部横条一直挂「正在应用配置修改…」):
       applying 只有在「VPN 运行中 + 本会话看门狗在计时 + 未超 75s」时才成立。
       扩展重启/命令丢失/回执被丢都会让 phase 永远停在 applying,
       这里把它降为 failed(只改展示副本,不动协调器),用户能看到可操作的失败态。 */
    if (st.phase === 'applying') {
      const stale: boolean = !this.isRunning
        || this.applyWatchdogTimer < 0
        || this.applyStartedAtMs <= 0
        || Date.now() - this.applyStartedAtMs > 75000;
      if (stale) {
        st.phase = 'failed';
        st.lastError = st.lastError.length > 0 ? st.lastError : '应用回执丢失(请重新连接或再次点应用)';
      }
    }
    return st;
  }

  /** §7.1 分流页首次默认「域名·IP 规则」:NavMemory 的旧默认值是 perApp,这里折算一次 */
  private routingInitialTab(): string {
    const t = this.navMemory.getRoutingTab();
    if (t.length === 0 || t === 'perApp') {
      return 'rules';
    }
    return t;
  }

  /**
   * 节点(0)/分流(2)两页显示壳层横幅(§12.2);**设置页(3)不显示** —— 设置页自己有内容更全的
   * 待应用条(摘要数/变更列表/应用/稍后/放弃,P4/W16-A),两处同时出现会重复。
   */
  private shouldShowApplyBanner(): boolean {
    if (this.activeTab !== 0 && this.activeTab !== 2) {
      return false;
    }
    if (this.applyBannerDismissed) {
      return false;
    }
    const st = this.applyStateSnapshot();
    /* VPN 未运行时不挂横幅:应用/稍后都是死按钮(下次连接本来就会用最新设置),
       2026-10-24 真机用户反馈「点应用没反应、提示一直在」
       2026-10-30 追加:applying 分支也必须要求运行中,否则回执丢失就一直挂着。 */
    if (!this.isRunning) {
      return false;
    }
    if (st.phase === 'applying') {
      return true;
    }
    return st.pendingChanges > 0;
  }

  private applyBannerTitle(): string {
    const st = this.applyStateSnapshot();
    if (st.phase === 'applying') {
      return '正在应用配置修改…';
    }
    /* SettingsSchema 已落地,这里应使用真实 diff.total 统计待应用项 */
    return '有未应用的配置修改';
  }

  private applyBannerSubtitle(): string {
    const st = this.applyStateSnapshot();
    if (st.phase === 'applying') {
      return `修订 r${st.requestedRevision} · 等待扩展回执`;
    }
    if (st.phase === 'failed') {
      return st.lastError.length > 0 ? `上次应用失败：${st.lastError}` : '上次应用失败';
    }
    if (this.pendingForNextConnect) {
      return `已保存修订 r${st.savedRevision} · 下次连接生效`;
    }
    return `已保存修订 r${st.savedRevision} · 点「应用」立即生效`;
  }

  private applyBannerAccent(): ResourceColor {
    const st = this.applyStateSnapshot();
    if (st.phase === 'failed') {
      return $r('app.color.error');
    }
    if (st.phase === 'applying') {
      return $r('app.color.primary');
    }
    return $r('app.color.warning');
  }

  /** 全局待应用横幅(§12.2;高度 52vp,紧凑,不与底部速率条重叠) */
  @Builder
  private pendingApplyBanner() {
    Row({ space: 10 }) {
      Circle()
        .width(8)
        .height(8)
        .fill(this.applyBannerAccent())
      Column({ space: 2 }) {
        Text(this.applyBannerTitle())
          .fontSize(14)
          .fontWeight(700)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.applyBannerSubtitle())
          .fontSize(11)
          .fontColor($r('app.color.text_2'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.applyStateSnapshot().phase === 'applying') {
        LoadingProgress()
          .width(18)
          .height(18)
          .color($r('app.color.primary'))
      } else {
        Button('应用')
          .height(34)
          .fontSize(12)
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.litKey === 'pb:Index:1' ? $r('app.color.primary') : $r('app.color.surface'))
          .fontColor(this.litKey === 'pb:Index:1' ? $r('app.color.surface') : $r('app.color.text_1'))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litKey = 'pb:Index:1';
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litKey = '';
            }
          })
          .onClick(() => {
            void this.applyLatestSavedRevision('banner');
          })
        Button('稍后')
          .height(34)
          .fontSize(12)
          .padding({ left: 10, right: 10 })
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.text_2'))
          .border({ width: 1, color: $r('app.color.hairline') })
          .onClick(() => {
            /* 收起横幅但保留待应用状态;设置已落盘,断开重连/下次连接自然生效 */
            this.applyBannerDismissed = true;
            this.applyBannerRev = this.applyBannerRev + 1;
            LogStore.addLog('[apply] 用户选择稍后(横幅收起,草稿保留)');
          })
      }
    }
    .width('100%')
    .height(52)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 14, right: 10 })
    .margin({ left: 12, right: 12, top: this.bannerTopVp, bottom: 4 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(14)
    .border({ width: 1, color: this.applyBannerAccent() })
  }

  /** 副动作「检查连接」:对当前节点跑一次单节点 URL Test(§4.1 固定次操作) */
  private async checkConnectivity(): Promise<void> {
    if (this.testing) {
      promptAction.showToast({ message: $r('app.string.index_test_in_progress') });
      return;
    }
    const runningId = this.runningProfileId();
    const targetId = runningId.length > 0 ? runningId : this.selectedId;
    const target = this.profiles.find((item: Profile) => item.id === targetId);
    if (target === undefined) {
      promptAction.showToast({ message: '没有可检测的节点' });
      return;
    }
    this.liveProbeResults = [];
    target.status = 0;
    target.ping = 0;
    target.error = '';
    target.latencyMs = 0;
    this.profiles = this.profiles.slice();
    this.bumpResults();
    promptAction.showToast({ message: $r('app.string.index_testing_count', 1) });
    await this.runProfilesTest([target], 'url');
    void this.refreshProbeResults();
  }

// 连接列表页已下线  /** 失败节点的内核原文(§6.6:可查看原文,不出现 [object Object]) */
  private showProbeError(r: ProbeResult): void {
    const detail = r.errorDetail.trim();
    if (detail.length === 0) {
      return;
    }
    AlertDialog.show({
      title: $r('app.string.connection_test_error_detail'),
      message: detail,
      primaryButton: { value: $r('app.string.ok'), action: () => {} },
      autoCancel: true
    });
  }

  // ---------------------------------------------------------------- P3/W12 节点工具条(筛选/排序)

  /** 工具条筛选后的可见节点:分组内 → filterNodes(搜索/收藏/仅看可用) → sortNodes(排序)。
   *  **页面不再自己算排序**(§4.1);NavMemory 不是 @State,靠 filtersRev 触发重渲染。 */
  visibleNodeList(): Array<Profile> {
    if (this.filtersRev < 0) {
      return [];
    }
    const base = this.profilesInGroup(this.selectedGroupId);
    const filtered = filterNodes(base, this.nodeSearch, this.navMemory.isOnlyFavorites(),
      this.navMemory.isOnlyUsable(), this.probeResults, Date.now(), this.settings.latencyStaleMs,
      (profileId: string) => this.isFavoriteNode(profileId));
    return sortNodes(filtered, this.settings.profileSortMode, this.probeResults);
  }

  private isFavoriteNode(profileId: string): boolean {
    const p = this.profiles.find((item: Profile) => item.id === profileId);
    return p !== undefined && p.pinned;
  }

  private bumpFilters(): void {
    this.filtersRev = this.filtersRev + 1;
  }

  private toggleOnlyFavorites(): void {
    this.navMemory.setOnlyFavorites(!this.navMemory.isOnlyFavorites());
    this.bumpFilters();
  }

  private toggleOnlyUsable(): void {
    this.navMemory.setOnlyUsable(!this.navMemory.isOnlyUsable());
    this.bumpFilters();
  }

  private sortModeLabel(): string {
    const mode = this.settings.profileSortMode;
    if (mode === 'latency') {
      return '延迟排序';
    }
    if (mode === 'name') {
      return '名称排序';
    }
    return '手动排序';
  }

  /** 排序三档循环(manual → latency → name),与 ⋮ 菜单里的三个排序项等价 */
  private cycleSortMode(): void {
    const mode = this.settings.profileSortMode;
    const next = mode === 'manual' ? 'latency' : (mode === 'latency' ? 'name' : 'manual');
    void this.setSortMode(next);
  }

  private latencyBucketColor(bucket: string): ResourceColor {
    if (bucket === 'fast') {
      return $r('app.color.success');
    }
    if (bucket === 'medium') {
      return $r('app.color.warning');
    }
    if (bucket === 'slow') {
      return $r('app.color.error');
    }
    return $r('app.color.text_3');
  }

  /**
   * 空态视图(§4.5):四个数据源全部接上 —— nodeCount / networkAvailable(NetConnection) /
   * firstAuthorizationDenied(连接失败文案里的授权拒绝)/ importJustCompleted(导入或订阅更新 added>0,30s 清)。
   * ⚠️ `import_done` 分支要求 nodeCount>0,而本壳层空态只在无节点时渲染 ⇒ 该分支当前**不可达**
   * (若要展示"导入完成引导",需要把横幅提到有节点时的位置,P4 再定)。
   */
  private emptyView(): EmptyState {
    const ctx = new EmptyContext();
    ctx.nodeCount = this.profiles.length;
    ctx.networkAvailable = this.networkAvailable;
    ctx.firstAuthorizationDenied = this.firstAuthorizationDenied;
    ctx.importJustCompleted = this.importJustCompleted;
    ctx.importedCount = this.importedCount;
    ctx.skippedTypes = this.skippedTypes;
    return emptyStateFor(ctx);
  }

  /** 连接中测当前节点。对齐 Android StatsBar.kt:128-142 → BaseService.kt:142-153:
   *  走运行中的实例(clash API 的激活出站 = 同一语义)、超时 **3000**、
   *  URL = 设置里的 connectionTestURL、异常走 genFriendlyMsg 映射。 */
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
      const delay = await fetchCurrentProxyDelay(CONNECTION_TEST_TIMEOUT_MS,
        this.settings.clashApiPort, this.settings.testUrl, this.settings.clashApiSecret);
      // 只是显示当前值,不落库:Android StatsBar 的这次测试同样不写 profile(只弹文本)
      p.status = 1;
      p.ping = delay;
      p.error = '';
      p.latencyMs = delay;
      p.latencyTestedAt = Date.now();
      this.profiles = this.profiles.slice();
      this.bumpResults();
      if (this.settings.testUrl.trim().startsWith('https://')) {
        promptAction.showToast({ message: $r('app.string.connection_test_available', delay) });
      } else {
        promptAction.showToast({ message: $r('app.string.connection_test_available_http', delay) });
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      const token = genFriendlyMsg(message);
      if (token === TestError.TIMEOUT) {
        promptAction.showToast({ message: $r('app.string.connection_test_error_timeout') });
      } else if (token === TestError.REFUSED) {
        promptAction.showToast({ message: $r('app.string.connection_test_error_refused') });
      } else if (token === TestError.UNREACHABLE) {
        promptAction.showToast({ message: $r('app.string.connection_test_error_unreachable') });
      } else {
        promptAction.showToast({ message: $r('app.string.connection_test_error', message) });
      }
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
      /* 2026-10-24 用户反馈「找不到收藏入口」:pinned 就是收藏字段(HomeView 收藏筛选
         读同一字段,排序上仍置顶),菜单文案与工具条「收藏」对齐 */
      MenuItem({ content: p.pinned ? $r('app.string.favorite_remove') : $r('app.string.favorite_add') })
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
      let fileName = '';
      try {
        fileName = decodeURIComponent((uri.split('/').pop() ?? '').split('?')[0]);
      } catch (e) {
        fileName = '';
      }
      if (fileName.length === 0) {
        fileName = 'import.json';
      }
      // 复制到缓存后用路径读取(picker URI 与 readTextSync 路径语义更稳)
      const cachePath = `${this.context.cacheDir}/import_${Date.now()}_${fileName}`;
      /* 2026-10-30 用户反馈「文件导入失败: No such file or directory」:
         DocumentViewPicker 返回的是 file://docs/... 这类 URI,部分机型上
         fs.copyFileSync(uri, path) 直接按路径解析会 ENOENT。改用 fd 复制
         (openSync 走 URI 解析),失败再回退到原来的直接 copy。 */
      let copied = false;
      try {
        fs.copyFileSync(uri, cachePath);
        copied = true;
      } catch (e) {
        copied = false;
      }
      if (!copied) {
        const srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        try {
          fs.copyFileSync(srcFile.fd, cachePath);
        } finally {
          fs.closeSync(srcFile);
        }
      }
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
        /* 2026-10-30 用户反馈「导入报错 / 不认 json 文件」:
           本地文件/粘贴的 sing-box 完整配置含有大量 https://(rule_set/DoH/http 出站),
           旧路径只会走 parseShareText 的链接分支 → 0 节点。这里先按结构化 JSON 认。 */
        if (looksLikeSingBoxJson(text)) {
          const r: ClashParseResult = parseSingBoxConfig(text);
          parsed = r.profiles;
          if (parsed.length === 0) {
            promptAction.showToast({
              message: $r('app.string.clash_skipped_count', r.skipped)
            });
            return;
          }
        } else {
          parsed = parseShareText(text);
        }
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
      /* P3②:导入完成引导数据源(added>0 视为刚导入完成,30s 自动清) */
      this.markImportCompleted(parsed.length, []);
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

  /** 抽屉列表项:[文案, 页面 id, 系统符号](顺序与文案由 core/Navigation.pageDefs() 给,§3.1) */
  private drawerItems(): Array<[string, string, Resource]> {
    const defs = pageDefs();
    const items: Array<[string, string, Resource]> = [];
    for (let i = 0; i < defs.length; i++) {
      const d: PageDef = defs[i];
      const symbol: Resource = d.drawerIndex < DRAWER_ITEM_SYMBOLS.length
        ? DRAWER_ITEM_SYMBOLS[d.drawerIndex] : $r('sys.symbol.info_circle');
      /* 文案用 titleFallback(中文兜底):资源键(app_page_*)由 lead 统一加,缺键不能白屏 */
      items.push([d.titleFallback, d.id, symbol]);
    }
    return items;
  }

  /** 当前分区是否就是这一项(抽屉选中态):经 pageByLegacyTab 映射,不依赖旧 'config' 等本地标识 */
  private drawerItemActive(id: string): boolean {
    return pageByLegacyTab(this.activeTab).id === id;
  }

  private onDrawerSelect(id: string): void {
    this.drawerOpen = false;
    const index = drawerIndexOfPage(id);
    if (index >= 0 && index !== this.activeTab) {
      this.switchTab(index);
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
      MenuItem({ content: $r('app.string.connection_test_tcp_ping') })
        .onClick(() => this.runTcpTest(groupId))
      MenuItem({ content: $r('app.string.connection_test_url_test') })
        .onClick(() => this.runSpeedTest(groupId))
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

  /** 节点行视图模型(§4.1/§6.6,纯函数在 model/HomeView.nodeRowView;页面只渲染) */
  private nodeRowOf(p: Profile): NodeRowView {
    const ctx = new NodeRowContext();
    ctx.nowMs = Date.now();
    ctx.staleMs = this.settings.latencyStaleMs;
    ctx.selectedProfileId = this.selectedId;
    ctx.runningProfileId = this.runningProfileId();
    /* AppStorage 的已连接词表是 'connected:<描述>'(VpnService.ets:160),不是裸 'connected' */
    ctx.runningConfirmed = this.statusText.startsWith('connected:');
    return nodeRowView(p, this.probeResultOf(p.id), ctx);
  }

  /** 节点行三态描边(§4.4:互斥优先级 confirmPending > running > selected) */
  private nodeRowStateColor(p: Profile): ResourceColor {
    const row = this.nodeRowOf(p);
    if (row.confirmPending) {
      return $r('app.color.warning');
    }
    if (row.running) {
      return $r('app.color.success');
    }
    if (this.selectedId === p.id) {
      return $r('app.color.primary');
    }
    return Color.Transparent;
  }

  /** 检测方式徽标(HTTP / TCP / TCP回退;unknown 不显示) */
  private rowMethodChip(p: Profile): string {
    const token = this.nodeRowOf(p).methodToken;
    if (token === 'http_2xx') {
      return 'HTTP';
    }
    if (token === 'http_any_response') {
      return 'HTTP有响应';
    }
    if (token === 'tcping') {
      return 'TCP';
    }
    if (token === 'http_degraded_tcping') {
      return 'TCP回退';
    }
    return '';
  }

  /** 点延迟文字:新模型优先(失败 + 内核原文),旧投影兜底(§6.6 不出现 [object Object]) */
  private showRowError(p: Profile): void {
    const r = this.probeResultOf(p.id);
    if (r !== null && r.state === PROBE_STATE_FAILED && r.errorDetail.length > 0) {
      this.showProbeError(r);
      return;
    }
    this.showTestError(p);
  }

  @Builder
  private nodeCard(p: Profile) {
    // P3/W12:节点行 = 模型 primary/secondary + latencyToken/latencyBucket 上色 + 方式/新鲜度口径 + 三态描边
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        if (p.pinned) {
          /* 原来是 emoji 📌:emoji 的字形/配色由系统字体决定,深浅色与多设备下观感不可控 ⇒ 换系统符号 */
          SymbolGlyph($r('sys.symbol.star_fill'))
            .fontSize(11)
            .fontColor([$r('app.color.warning')])
        }
        Text(this.nodeRowOf(p).primary)
          .fontSize(14.5)
          .fontWeight(this.selectedId === p.id ? 800 : 600)
          .fontColor($r('app.color.text_1'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.nodeRowOf(p).latencyToken)
          .fontSize(12.5)
          .fontFamily('monospace')
          .fontColor(this.latencyBucketColor(this.nodeRowOf(p).latencyBucket))
          /* Android 列表项点击 error 弹内核原文(:1583-1589):点延迟文字即弹 */
          .onClick(() => {
            this.showRowError(p);
          })
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
        Text(this.groupName(p.groupId))
          .fontSize(10.5)
          .fontColor($r('app.color.text_3'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.settings.alwaysShowAddress) {
          Text(this.nodeRowOf(p).secondary)
            .fontSize(10.5)
            .fontColor($r('app.color.mono'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')

      /* 口径行(§6.6):检测方式 + 新鲜度(历史) + 相对时间 + 运行/确认态,不占空间但把口径说清楚 */
      Row({ space: 6 }) {
        if (this.rowMethodChip(p).length > 0) {
          Text(this.rowMethodChip(p))
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(6)
            .backgroundColor($r('app.color.surface_selected'))
        }
        if (this.nodeRowOf(p).freshnessToken === 'stale') {
          Text('历史')
            .fontSize(10)
            .fontColor($r('app.color.warning'))
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .borderRadius(6)
            .backgroundColor($r('app.color.surface_selected'))
          Text(this.nodeRowOf(p).ageText)
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
        }
        if (this.nodeRowOf(p).confirmPending) {
          Text('正在确认…')
            .fontSize(10)
            .fontColor($r('app.color.warning'))
        } else if (this.nodeRowOf(p).running) {
          Text('正在使用')
            .fontSize(10)
            .fontColor($r('app.color.success'))
        }
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(14)
    .border({ width: 1.5, color: this.nodeRowStateColor(p) })
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

  // ---------------------------------------------------------------- P3/W12 状态卡 / 工具条 / 空态渲染

  /** 空态标题(§4.5;文案先中文兜底,资源键由 lead 统一加) */
  private emptyTitleText(): string {
    const token = this.emptyView().titleToken;
    if (token === 'import_done') {
      return '导入完成';
    }
    if (token === 'auth_denied') {
      return '需要系统 VPN 授权';
    }
    if (token === 'offline') {
      return '网络不可用';
    }
    return '还没有节点';
  }

  private emptyBodyText(): string {
    const token = this.emptyView().bodyToken;
    if (token === 'import_done_with_skipped') {
      return `已导入 ${this.emptyView().importedCount} 个节点，部分类型不受支持已跳过`;
    }
    if (token === 'import_done_simple') {
      return `已导入 ${this.emptyView().importedCount} 个节点`;
    }
    if (token === 'auth_denied_body') {
      return '首次连接需要授权 VPN 服务，授权后可重试';
    }
    if (token === 'offline_body') {
      return '恢复网络后重试，或先导入订阅';
    }
    return '导入订阅或新建节点开始使用';
  }

  private emptyPrimaryText(): string {
    const action = this.emptyView().primaryAction;
    if (action === 'check_availability') {
      return '检测可用性';
    }
    if (action === 'open_settings') {
      return '去授权';
    }
    if (action === 'open_network_settings') {
      return '网络设置';
    }
    return '导入订阅';
  }

  /** 空态主按钮:只有「导入订阅」已接线;其余引导动作如实提示未接入(不放假入口) */
  private onEmptyPrimary(): void {
    const action = this.emptyView().primaryAction;
    if (action === 'import_subscription') {
      this.openImportDialog();
      return;
    }
    LogStore.addLog(`[nav] 空态主动作 ${action} 尚未接入(P3)`);
    promptAction.showToast({ message: '该引导动作将在后续版本接入' });
  }

  @Builder
  private configFragment() {
    Column() {
      /* 原 configToolbar(连接/搜索/添加/更多)整排提进了 HDS 顶栏(stackBuilder 自绘 + ⋮ bindMenu)。
         搜索态输入行(用户点名放在动作按钮行与模式行之间)也画在顶栏 bottomBuilder 里,
         见 titleBottomBuilder()/searchInputRow();这里不再重复渲染。 */

      if (this.profiles.length === 0) {
        /* 空态(§4.5):nodeCount===0 ⇒ showConnectButton 恒 false,这里只给可执行引导,
           绝不显示必然失败的连接按钮(FAB 在 build() 里同时按节点数隐藏) */
        Column({ space: 10 }) {
          Text(this.emptyTitleText())
            .fontSize(15).fontWeight(600).fontColor($r('app.color.text_2'))
          Text(this.emptyBodyText())
            .fontSize(12).fontColor($r('app.color.text_3'))
            .textAlign(TextAlign.Center)
          Button(this.emptyPrimaryText())
            .height(38)
            .backgroundColor(this.litKey === 'pb:Index:2' ? $r('app.color.primary') : $r('app.color.surface'))
            .fontColor(this.litKey === 'pb:Index:2' ? $r('app.color.surface') : $r('app.color.text_1'))
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.litKey = 'pb:Index:2';
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.litKey = '';
              }
            })
            .onClick(() => this.onEmptyPrimary())
          Row({ space: 10 }) {
            if (this.emptyView().secondaryActions.includes('import_file')) {
              Button('从文件导入')
                .height(32).fontSize(12)
                .backgroundColor(Color.Transparent)
                .fontColor($r('app.color.text_2'))
                .border({ width: 1, color: $r('app.color.hairline') })
                .onClick(() => {
                  this.importFromFile();
                })
            }
            Button('扫码添加')
              .height(32).fontSize(12)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.text_2'))
              .border({ width: 1, color: $r('app.color.hairline') })
              .onClick(() => {
                void this.scanImport();
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        /* 2026-10-24 真机用户反馈:不要侧边节点详情栏(≥840 双栏已撤);
           列表+详情双栏与单列详情视图一并移除,节点信息回归列表行 + 编辑二级页 */
        if (this.sectionVisible('nodes')) {
          this.nodeListPane()
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 节点列表(单列/双栏左栏共用;原 configFragment 的 List 原样抽出,沉浸式占位逻辑不变) */
  @Builder
  private nodeListPane() {
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
          ForEach(this.pagedNodeList(), (profile: Profile) => {
            ListItem() {
              this.nodeCard(profile)
            }
          }, (profile: Profile) => profile.id)
          if (this.visibleNodeList().length > this.pagedNodeList().length) {
            ListItem() {
              Row() {
                Text($r('app.string.nodes_show_more', this.pagedNodeList().length,
                  this.visibleNodeList().length))
                  .fontSize(12).fontColor($r('app.color.primary'))
              }
              .width('100%').height(40)
              .justifyContent(FlexAlign.Center)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(12)
              .onClick(() => { this.nodeRenderLimit += 120; })
            }
          }
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



  /**
   * 「首页只看这个订阅」开关(订阅页按钮)。
   * 只改展示偏好:写 Preferences → 重算分组条/节点列表,不触发内核重建。
   */
  /** 订阅页复选框:切换某个订阅是否显示在首页(空集合 = 全部显示) */
  private async toggleSubScope(url: string): Promise<void> {
    const next: Array<string> = toggleActiveSub(this.activeSubUrls, url);
    this.activeSubUrls = next;
    this.selectedGroupId = '';
    this.ensureSelectedGroup();
    this.bumpFilters();
    await writePrefString(ACTIVE_SUBS_PREF, serializeActiveSubs(next));
    promptAction.showToast({
      message: next.length === 0
        ? $r('app.string.home_scope_all')
        : $r('app.string.home_scope_count', next.length),
      duration: 1500
    });
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
      /* 冷启动/进程恢复(§3.4):优先恢复上次浏览的展示组,其次第一个 */
      const remembered = this.navMemory.getSelectedGroupId();
      this.selectedGroupId = ids.includes(remembered) ? remembered : ids[0];
    }
    this.navMemory.setSelectedGroupId(this.selectedGroupId);
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
                /* 展示组选择记入浏览记忆(§3.4):切页/进程恢复后保持 */
                this.navMemory.setSelectedGroupId(groupId);
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
       速率文字和列表文字直接重叠。
       观感定稿(2026-10-23 用户反馈两轮):**要半透明,不要全透明也不要全不透明** ——
       ① 底色用资源控制的不透明度(#B8 ≈ 72%),深浅色各一份(base 白 / dark 深);
       ② 模糊改用 `backdropBlur()`(纯背景模糊、不叠材质底色);
          ⚠️ 不要用 `backgroundBlurStyle(BlurStyle.COMPONENT_THICK)`:COMPONENT_* 是"组件材质",
          自带一层近乎不透明的填充色,叠加后半透明底色被吃掉 ⇒ 实际观感"完全不透"(用户实测)。
       ③ 顶部 hairline 保留,给条状边界一个定义。 */
    .backdropBlur(20)
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
    .backgroundColor(this.isRunning
      ? $r('app.color.fab_running')
      : (this.accentHex.length > 0 ? this.accentHex : $r('app.color.fab_bg')))
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
    /* §4.5:没有节点时不显示连接按钮(点了也必然失败);空态页给「导入订阅」等可执行引导 */
    if (this.profiles.length > 0) {
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
  }

  // ---------------------------------------------------------------- HDS 顶栏(对齐 HDS 设计系统)

  /** 顶栏主标题:跟随当前页面(§3.2 只改显示名:配置→节点、分组→订阅、路由→分流;内部标识不动)。
   *  文案取 pageDef.titleFallback(资源键 app_page_* 由 lead 统一补,缺键时不会白屏)。 */
  /** 首页区块是否可见(设置页「首页区块编排」写入 homeHiddenSections) */
  /** 资源键 → 本地化字符串(消息中心存纯文本,不能存 Resource) */
  private messageSinkProbe(okCount: number, total: number, cancelled: boolean): void {
    const title = this.locText($r('app.string.probe_notify_title'));
    const body = cancelled
      ? this.locText($r('app.string.probe_notify_cancelled'))
      : this.locText($r('app.string.probe_notify_body'));
    void addMessage('probe', title, body);
  }

  private locText(res: Resource): string {
    try {
      return this.context.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private sectionVisible(id: string): boolean {
    /* 2026-10-26 首页区块编排已下线:区块恒定全显示(设置项不再暴露)。
       旧设置里的 homeHiddenSections 从此不生效,但仍随备份往返以兼容。 */
    return true;
  }

  private sectionTitle(): ResourceStr {
    return pageByLegacyTab(this.activeTab).titleFallback;
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

  // ---------------------------------------------------------------- 顶栏动作按页(§3.3)

  /** 动作可用性上下文:判据在 core/Navigation.topBarActions,这里只喂实时状态 */
  private topBarContext(): TopBarContext {
    const ctx = new TopBarContext();
    ctx.hasProfiles = this.profiles.length > 0;
    ctx.hasSubscriptions = this.subscriptions.length > 0;
    ctx.vpnRunning = this.isRunning;
    ctx.probing = this.testing;
    ctx.probeCancellable = this.testing;
    ctx.updating = this.updatingAllSubs || this.updatingSubUrl.length > 0;
    ctx.probeSupported = true;
    return ctx;
  }

  /**
   * 该页 ⋮ 菜单是否已由壳层实现(§3.3 通用化:按页取菜单项,空集就不显示 ⋮)。
   * 目前节点页/订阅页有壳层菜单;分流/设置/日志的「更多」由页面内部提供或待接入。
   */
  private hasOverflowMenu(pageId: string): boolean {
    return this.pageOverflowActions(pageId).length > 0;
  }

  /** 按页产出 ⋮ 菜单项(壳层菜单的唯一入口) */
  private pageOverflowActions(pageId: string): Array<MenuItemData> {
    if (pageId === PAGE_NODES) {
      return this.nodeOverflowActions();
    }
    if (pageId === PAGE_SUBSCRIPTIONS) {
      return this.subscriptionOverflowActions();
    }
    return [];
  }

  /** 动作 token 在当前页是否真的接线了(没接线的记日志并跳过,不放死按钮 §3.3) */
  private isActionWired(actionId: string, pageId: string): boolean {
    if (actionId === ACTION_SEARCH) {
      /* 只有节点页有可过滤的列表;日志页自身带搜索框,设置/分流的搜索待各页接入 */
      return pageId === PAGE_NODES;
    }
    if (actionId === ACTION_ADD) {
      return pageId === PAGE_NODES || pageId === PAGE_SUBSCRIPTIONS;
    }
    if (actionId === ACTION_PROBE || actionId === ACTION_PROBE_PROGRESS
      || actionId === ACTION_PROBE_CANCEL || actionId === ACTION_UPDATE_ALL) {
      return pageId === PAGE_NODES || pageId === PAGE_SUBSCRIPTIONS;
    }
    if (actionId === ACTION_EXPORT) {
      /* 日志页导出在 LogPage 内部(exportLogs),顶栏不重复放 */
      return false;
    }
    return false;
  }

  /** 当前页实际渲染的动作槽(= 契约给的 actions 过滤掉未接线项 + 已实现的 ⋮) */
  private visibleActions(): Array<ActionState> {
    const pageId = this.currentPageId();
    const all = topBarActions(pageId, this.topBarContext());
    const out: Array<ActionState> = [];
    for (let i = 0; i < all.length; i++) {
      if (this.isActionWired(all[i].id, pageId)) {
        out.push(all[i]);
      }
    }
    if (this.hasOverflowMenu(pageId)) {
      const more = new ActionState();
      more.id = ACTION_MORE;
      out.push(more);
    }
    return out;
  }

  /** 切页时把「契约有、壳层还没接」的动作记一条日志(每次切页一条,不刷屏) */
  private logSkippedActions(pageId: string): void {
    const all = topBarActions(pageId, this.topBarContext());
    for (let i = 0; i < all.length; i++) {
      if (!this.isActionWired(all[i].id, pageId)) {
        LogStore.addLog(`[nav] 顶栏动作 ${all[i].id} 在页面 ${pageId} 尚未接入,已跳过(§3.3)`);
      }
    }
    const def = pageById(pageId);
    if (def !== null && def.moreActions.length > 0 && !this.hasOverflowMenu(pageId)) {
      LogStore.addLog(`[nav] 页面 ${pageId} 的更多菜单尚未接入壳层(由页面内部提供),顶栏跳过(§3.3)`);
    }
  }

  /** 顶栏动作无障碍名称(§13.3;动作集合封闭,页面映射安全) */
  private actionA11yLabel(actionId: string): ResourceStr {
    if (actionId === ACTION_SEARCH) {
      return $r('app.string.nav_action_search');
    }
    if (actionId === ACTION_ADD) {
      return $r('app.string.nav_action_add');
    }
    if (actionId === ACTION_PROBE) {
      return $r('app.string.nav_action_probe');
    }
    if (actionId === ACTION_PROBE_CANCEL) {
      return $r('app.string.nav_action_cancel_probe');
    }
    if (actionId === ACTION_UPDATE_ALL) {
      return $r('app.string.nav_action_update_all');
    }
    return $r('app.string.nav_action_more');
  }

  /** 顶栏动作禁用原因(§3.3/§13.3;原因 token 来自 Navigation 契约) */
  private actionReasonLabel(reason: string): ResourceStr {
    if (reason === ACTION_REASON_NO_PROFILES) {
      return $r('app.string.nav_reason_no_profiles');
    }
    if (reason === ACTION_REASON_NO_SUBSCRIPTIONS) {
      return $r('app.string.nav_reason_no_subscriptions');
    }
    if (reason === ACTION_REASON_PROBE_UNSUPPORTED) {
      return $r('app.string.nav_reason_probe_unsupported');
    }
    if (reason === ACTION_REASON_UPDATING) {
      return $r('app.string.nav_reason_updating');
    }
    if (reason === ACTION_REASON_NOT_RUNNING) {
      return $r('app.string.nav_reason_not_running');
    }
    return '';
  }

  private actionSymbol(actionId: string): Resource {
    if (actionId === ACTION_SEARCH) {
      return $r('sys.symbol.magnifyingglass');
    }
    if (actionId === ACTION_PROBE) {
      return $r('sys.symbol.bolt');
    }
    if (actionId === ACTION_PROBE_CANCEL) {
      return $r('sys.symbol.xmark');
    }
    if (actionId === ACTION_ADD) {
      return $r('sys.symbol.plus');
    }
    if (actionId === ACTION_UPDATE_ALL) {
      return $r('sys.symbol.arrow_clockwise');
    }
    if (actionId === ACTION_EXPORT) {
      return $r('sys.symbol.square_and_arrow_down');
    }
    return $r('sys.symbol.more');
  }

  /** 顶栏动作点击:先看可用性(不可用必须给原因,§3.3),再按 token 分派 */
  private onTopBarAction(action: ActionState): void {
    if (!action.enabled) {
      this.toastActionReason(action);
      return;
    }
    if (action.id === ACTION_SEARCH) {
      this.openNodeSearch();
    } else if (action.id === ACTION_PROBE) {
      void this.probeVisibleNodes();
    } else if (action.id === ACTION_PROBE_CANCEL) {
      this.cancelSpeedTest();
    } else if (action.id === ACTION_ADD) {
      this.onAddAction();
    } else if (action.id === ACTION_UPDATE_ALL) {
      void this.updateAllSubscriptions();
    } else if (action.id === ACTION_EXPORT) {
      LogStore.addLog('[nav] 导出动作由日志页内部提供(LogPage.exportLogs),顶栏不重复渲染');
    }
  }

  /** 不可用原因(§3.3:不能静默无反应);文案先中文兜底,资源键由 lead 统一加 */
  private toastActionReason(action: ActionState): void {
    if (action.disabledReason === ACTION_REASON_NO_PROFILES) {
      promptAction.showToast({ message: '没有可检测的节点，先导入订阅或新建节点' });
      return;
    }
    if (action.disabledReason === ACTION_REASON_NO_SUBSCRIPTIONS) {
      promptAction.showToast({ message: '还没有订阅，先添加订阅' });
      return;
    }
    if (action.disabledReason === ACTION_REASON_UPDATING) {
      promptAction.showToast({ message: $r('app.string.updating') });
      return;
    }
    if (action.disabledReason === ACTION_REASON_PROBE_UNSUPPORTED) {
      promptAction.showToast({ message: '当前内核不支持检测，请改用 TCPing' });
      return;
    }
    promptAction.showToast({ message: $r('app.string.connection_test_unavailable') });
  }

  /** 搜索槽(仅节点页):打开/关闭顶栏搜索行并聚焦输入框 */
  private openNodeSearch(): void {
    if (this.searchVisible) {
      this.closeNodeSearch();
      return;
    }
    this.searchVisible = true;
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('nodeSearchInput');
      } catch (e) {
        // 焦点不可用时保持旧行为(用户手动点输入框)
      }
    }, 120);
  }

  /** 添加/导入:节点页=新建/导入入口,订阅页=导入订阅 */
  private onAddAction(): void {
    /* 2026-10-30 用户两次反馈「订阅页添加订阅只有 URL 一种方式」:
       旧实现在订阅页直接走 openImportDialog(只收 URL),与首页的多方式入口不一致。
       统一打开 AddEntryDialog(导入订阅/扫码/剪贴板/从文件/新建节点)。 */
    this.addEntryDialog.open();
  }

  /**
   * 检测槽(§3.3):作用域 = 当前筛选后的可见节点,走 URL Test(真连接);
   * 与 ⋮ 里的 TCPing / URL Test 两个显式入口共用同一套测速流程。
   */
  private async probeVisibleNodes(): Promise<void> {
    if (this.testing) {
      promptAction.showToast({ message: $r('app.string.index_test_in_progress') });
      return;
    }
    const targets = this.visibleNodeList();
    if (targets.length === 0) {
      promptAction.showToast({ message: '没有可检测的节点' });
      return;
    }
    for (const item of targets) {
      item.status = 0;
      item.ping = 0;
      item.error = '';
      item.latencyMs = 0;
    }
    this.profiles = this.profiles.slice();
    this.bumpResults();
    promptAction.showToast({ message: $r('app.string.index_testing_count', targets.length) });
    await this.runProfilesTest(targets, 'url');
    void this.refreshProbeResults();
  }

  /** 动作簇:按当前页 actions 渲染(§3.3);⋮ 保留原有按压光效与 44vp 命中区 */
  @Builder
  private titleActionCluster() {
    Row({ space: 4 }) {
      ForEach(this.visibleActions(), (action: ActionState) => {
        if (action.id === ACTION_MORE) {
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
          .accessibilityText($r('app.string.nav_action_more'))
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
        } else if (action.id === ACTION_PROBE_PROGRESS) {
          /* 检测进行中:原位换成进度(不可点;取消在它右边的 xmark 槽上,显式可点) */
          Row() {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('app.color.text_1'))
          }
          .width(44)
          .height(44)
          .justifyContent(FlexAlign.Center)
          .accessibilityText($r('app.string.nav_action_probing'))
        } else {
          GlowIconButton({
            symbol: this.actionSymbol(action.id),
            iconSize: action.id === ACTION_ADD ? 22 : 20,
            iconColor: action.enabled ? $r('app.color.text_1') : $r('app.color.text_3'),
            a11yText: this.actionA11yLabel(action.id),
            /* §13.3:禁用原因读屏可读(不放死按钮:可用性+原因都来自 Navigation 契约) */
            a11yReason: action.enabled ? '' : this.actionReasonLabel(action.disabledReason),
            onTap: () => {
              this.onTopBarAction(action);
            }
          })
        }
      }, (action: ActionState) => action.id)
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 节点页 ⋮(§3.3 节点页「更多」:添加节点/导入、排序筛选、批量管理、连接列表) */
  private nodeOverflowActions(): Array<MenuItemData> {
    const items: Array<MenuItemData> = [];
    const add = (label: ResourceStr, value: string, selected: boolean): void => {
      const it: MenuItemData = new MenuItemData();
      it.label = label;
      it.value = value;
      it.selected = selected;
      items.push(it);
    };
    /* §3.3:节点页顶栏只留 搜索/检测/⋮ ⇒ 原来顶栏的「+」和「连接」图标收进这里 */
    add($r('app.string.add_entry'), 'add', false);
    add($r('app.string.update_current_subscription'), 'update_sub', false);
    add($r('app.string.clear_traffic_statistics'), 'clear_traffic', false);
    add($r('app.string.dedup_action'), 'dedup', false);
    if (this.testing) {
      /* 测速中:两个测试入口换成「取消」,对齐 Android 测试对话框的 Cancel 按钮
         (取消后已测节点照常落库,:807-823) */
      add($r('app.string.cancel'), 'cancel_test', false);
    } else {
      /* 两个独立测试入口,对齐 Android 选项菜单的 TCPing / URL Test
         (res/menu/add_profile_menu.xml:99,102) */
      add($r('app.string.connection_test_tcp_ping'), 'test_tcp', false);
      add($r('app.string.connection_test_url_test'), 'test_url', false);
    }
    add($r('app.string.clear_test_results'), 'clear_results', false);
    add($r('app.string.delete_unavailable'), 'delete_unavailable', false);
    add($r('app.string.sort_manual'), 'sort_manual', this.settings.profileSortMode === 'manual');
    add($r('app.string.sort_latency'), 'sort_latency', this.settings.profileSortMode === 'latency');
    add($r('app.string.sort_name'), 'sort_name', this.settings.profileSortMode === 'name');
    return items;
  }

  /**
   * 订阅页 ⋮(§3.3 moreActions,P4/W16-C 收尾):排序/选中项操作/自动更新设置都在这里,
   * 数据全部来自壳层状态(selectedSubUrl / subscriptionSortMode),页面只负责回调上抛。
   * ⚠️ 仍不放"排序以外的格式/导入类"未实现项。
   */
  private subscriptionOverflowActions(): Array<MenuItemData> {
    const items: Array<MenuItemData> = [];
    const add = (label: ResourceStr, value: string, selected: boolean): void => {
      const it: MenuItemData = new MenuItemData();
      it.label = label;
      it.value = value;
      it.selected = selected;
      items.push(it);
    };
    add('排序：名称', 'sub_sort_name', this.subscriptionSortMode === 'name');
    add('排序：最近更新', 'sub_sort_recent', this.subscriptionSortMode === 'recent');
    add('更新全部订阅', 'sub_update_all', false);
    add('添加订阅 / 导入', 'sub_add', false);
    /* 选中项操作(行**长按**选中;没有选中项时不放,避免死菜单项) */
    if (this.selectedSubUrl.length > 0) {
      add('更新选中订阅', 'sub_update_selected', false);
      add('自动更新设置…', 'sub_auto_update', false);
      add('删除选中订阅', 'sub_delete_selected', false);
    }
    const failed = this.failedSubscriptionUrl();
    if (failed.length > 0) {
      add('查看更新失败的订阅', 'sub_open_failed', false);
    }
    return items;
  }

  /** ⋮「删除选中订阅」:壳层侧二次确认(行内的确认在 SubscriptionPage.confirmDelete) */
  private confirmDeleteSelectedSub(): void {
    const url = this.selectedSubUrl;
    if (url.length === 0) {
      return;
    }
    const name = this.subNameOfUrl(url);
    AlertDialog.show({
      title: '删除订阅',
      message: `删除订阅「${name}」？删除后需重新导入。`,
      autoCancel: true,
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: () => {
          this.selectedSubUrl = '';
          void this.deleteSubscription(url);
        }
      }
    });
  }

  /** ⋮ 的"最近一次更新失败"订阅(§3.3;lastError/failCount 命中) */
  private failedSubscriptionUrl(): string {
    for (let i = 0; i < this.subscriptions.length; i++) {
      const sub = this.subscriptions[i];
      if (sub.lastError.length > 0 || sub.failCount > 0) {
        return sub.url;
      }
    }
    return '';
  }

  /** 打开顶栏 ⋮ 的沉浸光感菜单（RzdSchool HdsMenu：系统菜单窗口 + 自绘面板 + 模糊背板 + 自适应取色；
   *  菜单项按当前页取,§3.3 通用化） */
  private openOverflowMenu(): void {
    const items: Array<MenuItemData> = this.pageOverflowActions(this.currentPageId());
    this.overflowMenu.open(this.getUIContext(), OVERFLOW_MENU_ANCHOR, items, (index: number): void => {
      if (index < 0 || index >= items.length) {
        return;
      }
      const value: string = items[index].value;
      if (value === 'add') {
        this.addEntryDialog.open();
      } else if (value === 'sub_update_all') {
        void this.updateAllSubscriptions();
      } else if (value === 'sub_add') {
        this.openImportDialog();
      } else if (value === 'sub_sort_name') {
        /* P4/W16-C:订阅排序走页面 onSort,与节点排序(NavMemory.sortMode)独立 */
        this.subscriptionSortMode = 'name';
      } else if (value === 'sub_sort_recent') {
        this.subscriptionSortMode = 'recent';
      } else if (value === 'sub_update_selected') {
        if (this.selectedSubUrl.length > 0) {
          void this.updateOneSubscription(this.selectedSubUrl, this.subNameOfUrl(this.selectedSubUrl));
        }
      } else if (value === 'sub_auto_update') {
        if (this.selectedSubUrl.length > 0) {
          router.pushUrl({ url: 'pages/SubDetailPage', params: { url: this.selectedSubUrl } });
        }
      } else if (value === 'sub_delete_selected') {
        this.confirmDeleteSelectedSub();
      } else if (value === 'sub_open_failed') {
        const url = this.failedSubscriptionUrl();
        if (url.length > 0) {
          router.pushUrl({ url: 'pages/SubDetailPage', params: { url: url } });
        }
      } else if (value === 'update_sub') {
        this.updateCurrentSubscription();
      } else if (value === 'clear_traffic') {
        this.clearTrafficStatistics();
      } else if (value === 'test_tcp') {
        this.runTcpTest(this.selectedGroupId);
      } else if (value === 'test_url') {
        this.runSpeedTest(this.selectedGroupId);
      } else if (value === 'cancel_test') {
        this.cancelSpeedTest();
      } else if (value === 'clear_results') {
        // Android 的清除/删除作用域是当前分组(DataStore.currentGroupId()),不是全部
        this.clearTestResults(this.selectedGroupId);
      } else if (value === 'dedup') {
        // 去重语义(更新期 javaClass 键 vs 手动 displayType 键)由 Lead 统一改,作用域暂不动
        this.dedupGroup('__all__');
      } else if (value === 'delete_unavailable') {
        this.deleteUnavailable(this.selectedGroupId);
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
      /* P3/B:tab 1 = 订阅页(独立组件,数据经 @Prop、动作走回调;页面自身不做 I/O)。
         GroupPage 的展示组管理并入节点页分组条,tab 1 不再渲染 GroupPage。 */
      SubscriptionPage({
        subscriptions: this.subscriptions,
        nodeCounts: this.subscriptionNodeCounts(),
        updatingUrl: this.updatingSubUrl,
        updatingAll: this.updatingAllSubs,
        networkAvailable: this.networkAvailable,
        batchSummaryModel: this.batchSummaryModel,
        batchOutcomes: this.batchOutcomes,
        batchVisible: this.batchVisible,
        batchFailedMessages: this.batchFailedMessages,
        /* P4/W16-C:排序/选中由壳层记忆(⋮ 菜单驱动;行内点击仍由页面自己回调上抛) */
        sortMode: this.subscriptionSortMode,
        selectedUrl: this.selectedSubUrl,
        homeUrls: this.activeSubUrls,
        onToggleHome: (url: string) => {
          void this.toggleSubScope(url);
        },
        onSort: (mode: string) => {
          this.subscriptionSortMode = mode;
        },
        onSelect: (url: string) => {
          this.selectedSubUrl = url;
          this.navMemory.setSelectedSubscriptionId(url);
        },
        onAdd: () => {
          /* 2026-10-30 用户反馈:订阅页「添加」只给 URL 一种方式,主页却有五种。
             统一改走 AddEntryDialog(导入订阅/扫码/剪贴板/从文件/新建节点)。 */
          this.addEntryDialog.open();
        },
        onImport: () => {
          this.importFromFile();
        },
        onScan: () => {
          void this.scanImport();
        },
        onManual: () => {
          this.addEntryDialog.open();
        },
        onUpdateOne: (url: string) => {
          void this.updateOneSubscription(url, this.subNameOfUrl(url));
        },
        onUpdateAll: () => {
          void this.updateAllSubscriptions();
        },
        onOpenDetail: (url: string) => {
          /* 跳转由页面自己做(router.pushUrl),这里只记日志,避免双跳 */
          LogStore.addLog(`[ui] 订阅详情: ${this.subNameOfUrl(url)}`);
        },
        onDelete: (url: string) => {
          void this.deleteSubscription(url);
        },
        /* W18:清空节点(事务仓库串行删,订阅记录保留);快捷动作切节点页/全量测速 */
        onClearNodes: (url: string) => {
          void this.clearSubscriptionNodes(url);
        },
        onViewNodes: () => {
          this.switchTab(drawerIndexOfPage(PAGE_NODES));
        },
        onProbeAll: () => {
          void this.runSpeedTest('');
        }
      })
    } else if (this.activeTab === 2) {
      RouteRulesPanel({
        /* P4/W14:与应用事务同口径(不另造第二套计数);修订号取 ConfigRepository */
        pendingChanges: this.applyCoordinator.getSnapshot().pendingChanges,
        savedRevision: this.applyCoordinator.getSnapshot().savedRevision,
        activeRevision: ConfigRepository.getActiveRevision(),
        initialTab: this.routingInitialTab(),
        onTabChange: (tab: string) => {
          this.navMemory.setRoutingTab(tab);
        },
        /* 2026-10-24:分应用迁入分流页,保存即走应用事务(不再跳设置页) */
        onApplyPerApp: () => {
          void this.commitAndApplySettings('perapp');
        },
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
        },
        /* 2026-10-24 真机用户反馈:设置页撤待应用条(应用/稍后/放弃),保存即自动应用 */
        onApplyDraft: () => {
          void this.commitAndApplySettings('settings_page');
        }
      })
    } else if (this.activeTab === 4) {
      LogPanel({
        onOpenDrawer: () => {
          this.openDrawer();
        }
      })
    } else if (this.activeTab === 5) {
      /* 2026-10-30 用户要求:工具与关于拆回两个独立页面 */
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
        if (!this.searchVisible && this.sectionVisible('groups')) {
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
      /* 仅标题栏高度:非 tab0 页面没有 bottomBuilder(搜索行/模式行/分组条)，
         用整栏 inset 会垫出一条 ~130px 空带;nbTitleProbe 是标题栏自身底边 */
      const titleBar = utils.getRectangleById('nbTitleProbe');
      const titleBottomPx = titleBar.windowOffset.y + titleBar.size.height;
      const titleInset = Math.round(ui.px2vp(titleBottomPx) + 8);
      if (titleInset > 0 && titleInset < 300 && Math.abs(titleInset - this.titleOnlyInset) >= 2) {
        this.titleOnlyInset = titleInset;
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
            /* P4/W16-B:全局待应用横幅(§12.2 节点/分流/设置三页统一);在内容区顶部、标题栏之下 */
            if (this.shouldShowApplyBanner()) {
              this.pendingApplyBanner()
            }
            Column() {
              this.activeContent()
            }
            .width('100%')
            .layoutWeight(1)
          }
          .width('100%')
          .layoutWeight(1)
          .id('nbBodyProbe')
          .onAreaChange((_oldArea: Area, _newArea: Area) => {
            this.calibrateTopInset();
          })
          /* 配置页列表自己用【占位项】让位(见 configFragment) ⇒ 容器不再留白;
             其它分区页用 titleOnlyInset(仅标题栏高)让位——tab0 的底栏(模式/分组条)
             只在节点页渲染,拿整栏 contentTopInset 垫会多出一条空带 */
          .padding({ top: this.activeTab === 0 ? 0 : this.titleOnlyInset })
          if (this.isRunning && this.sectionVisible('bottombar')
            && (this.activeTab === 0 || this.settings.showBottomBar)) {
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

      /* §4.5:无节点绝不显示必然失败的连接按钮(空态里有「导入订阅」等可执行引导);
         隐藏逻辑放在 fabLayer() 内部,保持 StatsBar/FAB 的既有条件不变 */
      if (this.sectionVisible('bottombar')
        && (this.activeTab === 0 || this.settings.showBottomBar)) {
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
  @State litKey: string = '';
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
          .backgroundColor(this.litKey === 'pb:Index:3' ? $r('app.color.primary') : $r('app.color.surface'))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litKey = 'pb:Index:3';
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litKey = '';
            }
          })
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
  @State litKey: string = '';
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
          .backgroundColor(this.litKey === 'pb:Index:4' ? $r('app.color.primary') : $r('app.color.surface'))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litKey = 'pb:Index:4';
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litKey = '';
            }
          })
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
  @State litKey: string = '';
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
        .backgroundColor(this.litKey === 'pb:Index:5' ? $r('app.color.primary') : $r('app.color.surface'))
        .fontColor(this.litKey === 'pb:Index:5' ? $r('app.color.surface') : $r('app.color.text_1'))
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.litKey = 'pb:Index:5';
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.litKey = '';
          }
        })
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

