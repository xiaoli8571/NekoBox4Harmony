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
import { UiSpec } from '../common/UiSpec';
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
  @State collapsedGroupIds: Array<string> = [];   // 首页分组折叠状态(持久化,'|' 分隔,空串=未分组)
  private collapseLoaded: boolean = false;
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
    this.refresh();
    this.autoUpdateSubs();
    this.autoConnect();
    if (this.isRunning) {
      this.startSpeedPoller();
      this.startUptimeTimer();
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

  aboutToDisappear(): void {
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
      if (!this.collapseLoaded) {
        const raw = await readPrefString('home_collapsed_groups', '\u0000');
        if (raw === '\u0000') {
          // 首次使用:全部折叠,当前选中节点所在分组默认展开
          const sel = this.profiles.find((profile: Profile) => profile.id === this.selectedId);
          const selGroup = sel === undefined ? '' : sel.groupId;
          this.collapsedGroupIds = this.sortedGroupIds().filter((g: string) => g !== selGroup);
        } else {
          this.collapsedGroupIds = raw.length === 0 ? [] : raw.split('|');
        }
        this.collapseLoaded = true;
      }
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

  async runSpeedTest(): Promise<void> {
    if (this.testing || this.profiles.length === 0) {
      return;
    }
    this.latencies = {};
    promptAction.showToast({ message: $r('app.string.index_testing_count', this.profiles.length) });
    await this.runProfilesTest(this.profiles.slice());
  }

  async runGroupSpeedTest(groupId: string): Promise<void> {
    if (groupId === '__all__') {
      await this.runSpeedTest();
      return;
    }
    const profiles = this.profiles.filter((item: Profile) => item.groupId === groupId);
    if (this.testing || profiles.length === 0) {
      return;
    }
    promptAction.showToast({ message: $r('app.string.index_testing_count', profiles.length) });
    await this.runProfilesTest(profiles);
  }

  private async runProfilesTest(snapshot: Array<Profile>): Promise<void> {
    this.testing = true;
    try {
      const onOne = (id: string, ms: number): void => {
        const next: Record<string, number> = {};
        const keys = Object.keys(this.latencies);
        for (const k of keys) {
          next[k] = this.latencies[k];
        }
        next[id] = ms;
        this.latencies = next;
        const profile = this.profiles.find((item: Profile) => item.id === id);
        if (profile !== undefined) {
          profile.latencyMs = ms;
          profile.latencyTestedAt = Date.now();
          const runningProfileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
          if (this.isRunning && runningProfileId === id) {
            publishVpnLatency(id, profile.name, ms);
          }
        }
      };
      if (this.settings.latencyTestMode === 'tcp') {
        await testProfiles(snapshot, onOne, this.settings.testConcurrent);
      } else {
        await urlTestProfiles(snapshot, this.profiles, this.settings, this.context,
          onOne, this.settings.testConcurrent, 5000, this.groups);
      }
      await saveProfiles(this.profiles);
      this.profiles = this.profiles.slice();
      promptAction.showToast({ message: $r('app.string.speed_test_complete') });
    } finally {
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

  private isGroupCollapsed(groupId: string): boolean {
    if (this.nodeSearch.trim().length > 0) {
      return false; // 搜索时自动展开,直接呈现匹配结果
    }
    return this.collapsedGroupIds.indexOf(groupId) >= 0;
  }

  async toggleGroupCollapse(groupId: string): Promise<void> {
    const next = this.collapsedGroupIds.slice();
    const i = next.indexOf(groupId);
    if (i >= 0) {
      next.splice(i, 1);
    } else {
      next.push(groupId);
    }
    this.collapsedGroupIds = next;
    await writePrefString('home_collapsed_groups', next.join('|'));
  }

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

  // ---------------------------------------------------------------- 抽屉导航(对齐安卓 Drawer)

  private drawerItems(): Array<[ResourceStr, string, string]> {
    // [文案, 项标识, 图标字形]
    const items: Array<[ResourceStr, string, string]> = [
      [$r('app.string.nav_config'), 'config', '▤'],
      [$r('app.string.nav_groups'), 'groups', '⧉'],
      [$r('app.string.nav_route'), 'route', '⇄'],
      [$r('app.string.settings_title'), 'settings', '⚙'],
      [$r('app.string.logs'), 'logs', '≣'],
      [$r('app.string.nav_docs'), 'docs', '✎'],
      [$r('app.string.nav_tools'), 'tools', '✦'],
      [$r('app.string.nav_about'), 'about', 'ⓘ']
    ];
    return items;
  }

  private drawerItemActive(id: string): boolean {
    if (id === 'config') {
      return this.activeTab === 0;
    }
    if (id === 'groups') {
      return this.activeTab === 1;
    }
    if (id === 'route') {
      return this.activeTab === 2;
    }
    if (id === 'settings') {
      return this.activeTab === 3;
    }
    if (id === 'logs') {
      return this.activeTab === 4;
    }
    if (id === 'tools') {
      return this.activeTab === 5;
    }
    if (id === 'about') {
      return this.activeTab === 6;
    }
    return false;
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
    } else if (id === 'docs') {
      // 对齐安卓 nav_faq:打开项目文档(应用内 Web 视图)
      router.pushUrl({ url: 'pages/DocPage' });
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
      .padding({ left: 20, right: 16, top: 30, bottom: 16 })

      Divider().color($r('app.color.hairline')).strokeWidth(UiSpec.HAIRLINE_WIDTH)

      Column() {
        ForEach(this.drawerItems(), (item: [ResourceStr, string, string]) => {
          Row({ space: 14 }) {
            Text(item[2])
              .fontSize(15)
              .fontColor(this.drawerItemActive(item[1]) ? $r('app.color.primary') : $r('app.color.text_3'))
              .width(24)
              .textAlign(TextAlign.Center)
            Text(item[0])
              .fontSize(14.5)
              .fontWeight(this.drawerItemActive(item[1]) ? 700 : 400)
              .fontColor(this.drawerItemActive(item[1]) ? $r('app.color.primary') : $r('app.color.text_2'))
          }
          .width('100%')
          .height(46)
          .borderRadius(10)
          .backgroundColor(this.drawerItemActive(item[1]) ? $r('app.color.surface_selected') : Color.Transparent)
          .onClick(() => this.onDrawerSelect(item[1]))
        }, (item: [ResourceStr, string, string]) => item[1])
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8 })

      Blank()

      Text($r('app.string.drawer_footer'))
        .fontSize(10.5).fontColor($r('app.color.text_3'))
        .width('100%')
        .padding({ left: 20, bottom: 16 })
    }
    .width('78%')
    .constraintSize({ maxWidth: 320 })
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      // 吞掉点击事件,防止点面板空白处触发遮罩关闭
    })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.25)', offsetY: 0 })
  }

  @Builder
  private drawerOverlay() {
    if (this.drawerOpen) {
      Row() {
        this.drawerPanel()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.35)')
      .onClick(() => {
        this.drawerOpen = false;
      })
    }
  }

  // ---------------------------------------------------------------- 配置页(对齐安卓 ConfigurationFragment)

  @Builder
  private configToolbar() {
    Row({ space: 10 }) {
      Text('≡')
        .fontSize(20).fontColor($r('app.color.text_1'))
        .width(36).height(36).textAlign(TextAlign.Center)
        .onClick(() => { this.drawerOpen = true; })
      if (this.searchVisible) {
        TextInput({ text: this.nodeSearch, placeholder: $r('app.string.search_nodes') })
          .layoutWeight(1).height(36)
          .backgroundColor(Color.Transparent)
          .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
          .onChange((v: string) => { this.nodeSearch = v; })
        Text($r('app.string.cancel'))
          .fontSize(13).fontColor($r('app.color.text_2')).padding(6)
          .onClick(() => {
            this.nodeSearch = '';
            this.searchVisible = false;
          })
      } else {
        Text($r('app.string.brand_name'))
          .fontSize(16).fontWeight(800).fontColor($r('app.color.text_1')).layoutWeight(1)
        Text('⇅')
          .fontSize(17).fontColor($r('app.color.text_2'))
          .width(36).height(36).textAlign(TextAlign.Center)
          .onClick(() => router.pushUrl({ url: 'pages/ConnectionsPage' }))
        Text('⌕')
          .fontSize(19).fontColor($r('app.color.text_2'))
          .width(36).height(36).textAlign(TextAlign.Center)
          .onClick(() => { this.searchVisible = true; })
        Text('＋')
          .fontSize(19).fontColor($r('app.color.text_1'))
          .width(36).height(36).textAlign(TextAlign.Center)
          .onClick(() => this.addEntryDialog.open())
        Text('⋮')
          .fontSize(19).fontColor($r('app.color.text_1'))
          .width(36).height(36).textAlign(TextAlign.Center)
          .bindMenu(this.configOverflowMenu())
      }
    }
    .width('100%')
    .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING - 10, top: 20 })
  }

  private configOverflowMenu(): Array<MenuElement> {
    const items: Array<MenuElement> = [
      {
        value: $r('app.string.update_current_subscription') as ResourceStr,
        action: () => {
          this.updateCurrentSubscription();
        }
      },
      {
        value: $r('app.string.clear_traffic_statistics') as ResourceStr,
        action: () => {
          this.clearTrafficStatistics();
        }
      },
      {
        value: $r('app.string.test_all_nodes') as ResourceStr,
        action: () => {
          this.runSpeedTest();
        }
      },
      {
        value: $r('app.string.clear_test_results') as ResourceStr,
        action: () => {
          this.clearTestResults('__all__');
        }
      },
      {
        value: $r('app.string.dedup_action') as ResourceStr,
        action: () => {
          this.dedupGroup('__all__');
        }
      },
      {
        value: $r('app.string.delete_unavailable') as ResourceStr,
        action: () => {
          this.deleteUnavailable('__all__');
        }
      },
      {
        value: $r('app.string.sort_manual') as ResourceStr,
        action: () => {
          this.setSortMode('manual');
        }
      },
      {
        value: $r('app.string.sort_latency') as ResourceStr,
        action: () => {
          this.setSortMode('latency');
        }
      },
      {
        value: $r('app.string.sort_name') as ResourceStr,
        action: () => {
          this.setSortMode('name');
        }
      }
    ];
    return items;
  }

  @Builder
  private modeSwitchRow() {
    Row({ space: 8 }) {
      ForEach(OUTBOUND_MODES, (mode: string, index: number) => {
        Button(OUTBOUND_MODE_LABELS[index])
          .layoutWeight(1)
          .height(32)
          .fontSize(12.5)
          .backgroundColor(Color.Transparent)
          .fontColor(this.settings.mode === mode ? $r('app.color.mono') : $r('app.color.text_3'))
          .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: this.settings.mode === mode ? $r('app.color.mono') : $r('app.color.hairline') })
          .onClick(() => { void this.switchOutboundMode(mode); })
      }, (mode: string) => mode)
    }
    .width('100%')
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 6 })
  }

  @Builder
  private groupHeader(groupId: string) {
    // 分组头:组名 + 节点数 + 组内最优延迟徽标 + 展开箭头;点击折叠/展开,长按出组操作菜单
    Row({ space: 8 }) {
      Text(this.groupName(groupId))
        .fontSize(14)
        .fontWeight(700)
        .fontColor($r('app.color.text_1'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text($r('app.string.group_node_count', this.visibleProfiles(groupId).length))
        .fontSize(11.5)
        .fontColor($r('app.color.text_3'))
      Blank()
      if (this.groupMinLatency(groupId) >= 0) {
        Text($r('app.string.group_latency_minimum', this.groupMinLatency(groupId)))
          .fontSize(11.5)
          .fontColor(this.latencyColorOfMs(this.groupMinLatency(groupId)))
      }
      Text(this.isGroupCollapsed(groupId) ? '⌄' : '⌃')
        .fontSize(14)
        .fontColor($r('app.color.text_3'))
        .width(18)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 10, bottom: 4 })
    .onClick(() => {
      void this.toggleGroupCollapse(groupId);
    })
    .bindContextMenu(this.groupContextMenu(groupId), ResponseType.LongPress)
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
          Text('📌').fontSize(10)
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
    .onClick(() => this.onNodeTap(p))
    .bindContextMenu(this.profileContextMenu(p), ResponseType.LongPress)
  }

  @Builder
  private configFragment() {
    Column() {
      this.configToolbar()
      this.modeSwitchRow()

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
        // 对齐安卓:单列表按分组折叠展示,组头可点按展开/收起
        List({ space: 8 }) {
          ForEach(this.displayGroupIds(), (groupId: string) => {
            ListItem() {
              this.groupHeader(groupId)
            }
            if (!this.isGroupCollapsed(groupId)) {
              ForEach(this.visibleProfiles(groupId), (profile: Profile) => {
                ListItem() {
                  this.nodeCard(profile)
                }
              }, (profile: Profile) => profile.id)
            }
          }, (groupId: string) => groupId)
        }
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 14, right: 14, top: 6, bottom: 12 })
      }
    }
    .width('100%')
    .height('100%')
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
    .onClick(() => {
      const target = this.selectedProfile();
      if (target !== undefined && this.isRunning) {
        this.runUrlTest(target);
      }
    })
  }

  @Builder
  private fabButton() {
    Stack() {
      if (this.statusText === 'connecting' || this.statusText === 'switching') {
        LoadingProgress()
          .width(26).height(26).color($r('app.color.surface'))
      } else {
        Text(this.isRunning ? '■' : '▶')
          .fontSize(this.isRunning ? 22 : 20)
          .fontColor($r('app.color.surface'))
      }
    }
    .width(64)
    .height(64)
    .borderRadius(32)
    .backgroundColor(this.isRunning ? $r('app.color.fab_running') : $r('app.color.fab_bg'))
    .clip(true)
    .shadow({ radius: 14, color: 'rgba(0,0,0,0.25)', offsetY: 4 })
    .margin({ right: 20, bottom: 54 })
    .onClick(() => this.toggleVpn())
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
          this.drawerOpen = true;
        }
      })
    } else if (this.activeTab === 2) {
      RouteRulesPanel({
        onOpenDrawer: () => {
          this.drawerOpen = true;
        }
      })
    } else if (this.activeTab === 3) {
      SettingsPage({
        onSettingsChanged: (settings: AppSettings) => {
          this.settings = settings;
        },
        onOpenDrawer: () => {
          this.drawerOpen = true;
        }
      })
    } else if (this.activeTab === 4) {
      LogPanel({
        onOpenDrawer: () => {
          this.drawerOpen = true;
        }
      })
    } else if (this.activeTab === 5) {
      ToolsPage({
        onOpenDrawer: () => {
          this.drawerOpen = true;
        }
      })
    } else {
      AboutPage({
        onOpenDrawer: () => {
          this.drawerOpen = true;
        }
      })
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        Column() {
          this.activeContent()
        }        .width('100%')
        .layoutWeight(1)
        if (this.isRunning && (this.activeTab === 0 || this.settings.showBottomBar)) {
          this.statsBar()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      if (this.activeTab === 0 || this.settings.showBottomBar) {
        this.fabButton()
      }

      this.drawerOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
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
