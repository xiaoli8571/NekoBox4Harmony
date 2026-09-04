import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { BigPowerButton } from '../common/components/BigPowerButton';
import { MiniStatCard } from '../common/components/MiniStatCard';
import { UiBreakpoint } from '../common/Breakpoint';
import { Profile, ProfileGroup, AppSettings, profileTypeLabel } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, loadSettings, saveSettings, readPrefString, writePrefString, LogStore } from '../model/Store';
import { VpnService } from '../core/VpnService';
import { parseShareText } from '../utils/LinkParser';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { fetchSubscriptionWithInfo, looksLikeClashYaml, parseClashProxies, ClashParseResult } from '../utils/Subscription';
import { testProfiles } from '../utils/LatencyTester';
import { SubInfo, upsertSub, needAutoUpdate, updateSubscription, setAppContext, subNameOf, markSubSuccess, markSubFailure, listSubs, saveSubs, removeSub } from '../core/Subscriptions';
import { fetchTrafficTotals, formatSpeed, formatBytes } from '../utils/TrafficStats';
import { fetchCurrentProxyDelay } from '../utils/ClashApi';
import { exportProfileLink } from '../utils/LinkExporter';
import { publishVpnLatency } from '../core/VpnIpc';
import { SettingsView } from '../views/SettingsView';

type MainDestination = 'home' | 'proxy' | 'subscriptions' | 'mine';

/** 底部导航 Tab 描述(id 与页面一对一)。 */
class NavItem {
  id: MainDestination;
  icon: string;
  label: ResourceStr;

  constructor(id: MainDestination, icon: string, label: ResourceStr) {
    this.id = id;
    this.icon = icon;
    this.label = label;
  }
}

/** 订阅配置页分组桶:按 SubInfo.group 分节(空组 = 未分组)。 */
class SubGroupBucket {
  name: string;
  items: Array<SubInfo>;

  constructor(name: string) {
    this.name = name;
    this.items = [];
  }
}

@Entry
@Component
struct Index {
  @State profiles: Array<Profile> = [];
  @State groups: Array<ProfileGroup> = [];
  @State selectedId: string = '';
  @State latencies: Record<string, number> = {};
  @State testing: boolean = false;
  @State settings: AppSettings = new AppSettings();
  @State activeDestination: MainDestination = 'home';
  @State subs: Array<SubInfo> = [];
  @State activeConfigUrl: string = '';
  @State updatingSubUrl: string = '';
  @State connectedAt: number = 0;
  @State protectedNow: number = 0;
  @State subGroupDraft: string = '';
  @StorageLink('uiBreakpoint') uiBreakpoint: UiBreakpoint = 'compact';
  @StorageLink('uiFxLevel') uiFxLevel: string = 'full';
  @StorageProp('statusBarHeightVp') statusBarVp: number = 0;
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
  private subGroupEditUrl: string = '';

  // ---- 分享弹窗：当前 SDK 未发现 ScanKit generateBarcode，使用纯文本与复制降级路径 ----
  @State shareText: string = '';
  private shareDialog: CustomDialogController = new CustomDialogController({
    builder: ShareTextDialog({
      text: $shareText,
      onCopy: async (text: string) => {
        await setClipboardText(text);
        promptAction.showToast({ message: $r('app.string.share_link_copied') });
      }
    }),
    autoCancel: true
  });

  // ---- 导入弹窗(手动粘贴,不依赖剪贴板权限)----
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

  // ---- 订阅改组弹窗(配置页溢出操作)----
  private subGroupDialog: CustomDialogController = new CustomDialogController({
    builder: SubGroupInputDialog({
      draft: $subGroupDraft,
      onSave: (name: string) => {
        this.saveSubGroup(name);
      }
    }),
    autoCancel: true
  });

  aboutToAppear(): void {
    setAppContext(this.context);
    AppStorage.setOrCreate('uiFxLevel', this.uiFxLevel);
    this.refresh();
    this.autoUpdateSubs();
  }

  // 从编辑页/设置页 router.back() 回来时刷新(节点/订阅/设置都可能变化)
  onPageShow(): void {
    this.refresh();
  }

  aboutToDisappear(): void {
    this.stopSpeedPoller();
  }

  onRunningChange(): void {
    if (this.isRunning) {
      this.connectedAt = Date.now();
      this.startSpeedPoller();
    } else {
      this.stopSpeedPoller();
    }
    this.refresh();
  }

  private startSpeedPoller(): void {
    this.stopSpeedPoller();
    this.lastUp = 0;
    this.lastDown = 0;
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
    this.speedTimer = setInterval(async () => {
      this.protectedNow = Date.now();
      const t = await fetchTrafficTotals(this.settings.clashApiPort, this.settings.clashApiSecret);
      if (t === null) {
        return;
      }
      if (this.lastUp === 0 && this.lastDown === 0) {
        this.lastUp = t.up;
        this.lastDown = t.down;
      }
      AppStorage.setOrCreate('vpnUpSpeed', Math.max(0, t.up - this.lastUp));
      AppStorage.setOrCreate('vpnDownSpeed', Math.max(0, t.down - this.lastDown));
      this.lastUp = t.up;
      this.lastDown = t.down;
      AppStorage.setOrCreate('vpnTotalUp', t.up);
      AppStorage.setOrCreate('vpnTotalDown', t.down);
    }, 1000);
  }

  private stopSpeedPoller(): void {
    if (this.speedTimer >= 0) {
      clearInterval(this.speedTimer);
      this.speedTimer = -1;
    }
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
  }

  modeLabel(): Resource {
    if (this.settings.mode === 'direct') {
      return $r('app.string.mode_direct');
    }
    if (this.settings.mode === 'global') {
      return $r('app.string.mode_global');
    }
    return $r('app.string.mode_rule');
  }

  protectedSinceText(): string {
    if (this.connectedAt <= 0) {
      return '00:00:00';
    }
    const now = this.protectedNow > 0 ? this.protectedNow : Date.now();
    const totalSec = Math.floor(Math.max(0, now - this.connectedAt) / 1000);
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const s = totalSec % 60;
    const pad = (v: number): string => v < 10 ? `0${v}` : `${v}`;
    return `${pad(h)}:${pad(m)}:${pad(s)}`;
  }

  async refresh(): Promise<void> {
    try {
      await initStore(this.context);
      this.profiles = await loadProfiles();
      this.groups = await loadGroups();
      this.settings = await loadSettings();
      this.subs = await listSubs();
      const storedActiveUrl = await readPrefString('active_config_url', '');
      const storedExists = this.subs.some((sub: SubInfo) => sub.url === storedActiveUrl);
      this.activeConfigUrl = storedExists ? storedActiveUrl : (this.subs.length > 0 ? this.subs[0].url : '');
      if (this.activeConfigUrl !== storedActiveUrl) {
        await writePrefString('active_config_url', this.activeConfigUrl);
      }
      const activeProfiles = this.profiles.filter((profile: Profile) => profile.subUrl === this.activeConfigUrl);
      const selectedExists = activeProfiles.some((profile: Profile) => profile.id === this.selectedId);
      if (!selectedExists) {
        this.selectedId = activeProfiles.length > 0 ? activeProfiles[0].id : (this.profiles.length > 0 ? this.profiles[0].id : '');
      }
    } catch (e) {
      LogStore.addLog(`[ui] 加载节点失败: ${e}`);
    }
  }

  /** 启动时自动更新超过 12 小时的订阅 */
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
          LogStore.addLog(`[app] 订阅 ${sub.name} 自动更新失败: ${e}`);
        }
      }
    } catch (e) {
      // ignore
    }
  }

  /** 真连接延迟测试(TCP 握手计时):测全部节点 */
  async runSpeedTest(): Promise<void> {
    if (this.testing || this.profiles.length === 0) {
      return;
    }
    this.latencies = {};
    promptAction.showToast({ message: $r('app.string.index_testing_count', this.profiles.length) });
    await this.runProfilesTest(this.profiles.slice());
  }

  /** 代理页 FAB:只测当前所选配置(订阅/本地)下的节点 */
  async runProxySpeedTest(): Promise<void> {
    const list = this.proxyProfiles();
    if (this.testing || list.length === 0) {
      return;
    }
    this.latencies = {};
    promptAction.showToast({ message: $r('app.string.index_testing_count', list.length) });
    await this.runProfilesTest(list);
  }

  private async runProfilesTest(snapshot: Array<Profile>): Promise<void> {
    this.testing = true;
    try {
      await testProfiles(snapshot, (id: string, ms: number) => {
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
      });
      await saveProfiles(this.profiles);
      this.profiles = this.profiles.slice();
      promptAction.showToast({ message: $r('app.string.speed_test_complete') });
    } finally {
      this.testing = false;
    }
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

  latencyText(p: Profile): ResourceStr {
    const ms = this.latencies[p.id];
    if (this.testing && ms === undefined) {
      return '…';
    }
    if (ms === undefined) {
      return '';
    }
    return ms < 0 ? $r('app.string.timeout') : `${ms}ms`;
  }

  latencyColor(p: Profile): ResourceColor {
    const ms = this.latencies[p.id];
    if (ms === undefined || ms < 0) {
      return ms === -1 ? $r('app.color.error') : $r('app.color.text_secondary');
    }
    if (ms < 150) {
      return $r('app.color.success');
    }
    if (ms < 400) {
      return $r('app.color.warning');
    }
    return $r('app.color.error');
  }

  latencyBarWidth(p: Profile): number {
    const ms = this.latencies[p.id];
    if (ms === undefined || ms < 0) {
      return 0;
    }
    return Math.max(4, Math.min(64, Math.round(ms / 250 * 64)));
  }

  /** 当前可见集合中最优(最低)延迟;无有效值返回 -1。 */
  bestLatencyIn(list: Array<Profile>): number {
    let best = -1;
    for (const p of list) {
      const ms = this.latencies[p.id];
      if (ms !== undefined && ms >= 0 && (best < 0 || ms < best)) {
        best = ms;
      }
    }
    return best;
  }

  /** 延迟数字颜色:最优节点为青色,其余沿用既有语义色。 */
  latencyTextColor(p: Profile, best: number): ResourceColor {
    const ms = this.latencies[p.id];
    if (ms !== undefined && ms >= 0 && best >= 0 && ms === best) {
      return $r('app.color.neon_cyan');
    }
    return this.latencyColor(p);
  }

  /** 延迟能量条渐变:<200ms 青蓝,>=200ms 橙红。 */
  latencyBarColors(ms: number): Array<[ResourceColor, number]> {
    if (ms < 200) {
      return [[$r('app.color.neon_cyan'), 0.0], [$r('app.color.neon_indigo'), 1.0]];
    }
    return [[$r('app.color.warning'), 0.0], [$r('app.color.error'), 1.0]];
  }

  async connectTo(p: Profile): Promise<void> {
    if (this.isRunning) {
      promptAction.showToast({ message: $r('app.string.disconnect_first') });
      return;
    }
    this.selectedId = p.id;
    try {
      await VpnService.connect(this.context, p.id);
    } catch (e) {
      // 状态已在 VpnService 中更新
    }
  }

  async disconnect(): Promise<void> {
    await VpnService.disconnect(this.context);
  }

  /** 点击节点:未运行则选中;运行中点其他节点 = 自动断开重连切换 */
  async onNodeTap(p: Profile): Promise<void> {
    this.selectedId = p.id;
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

  openProfileShare(p: Profile): void {
    const link = exportProfileLink(p);
    if (link.length === 0) {
      promptAction.showToast({ message: $r('app.string.protocol_export_unsupported') });
      return;
    }
    this.shareText = link;
    this.shareDialog.open();
  }

  async openImportDialog(): Promise<void> {
    this.importText = '';
    await initStore(this.context);
    this.importName = await readPrefString('recent_subscription_group', '');
    this.importDialog.open();
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
      let parsed: Array<Profile> = [];
      let subUrl = '';
      let subUserinfo = '';
      if (firstLine.startsWith('http://') || firstLine.startsWith('https://')) {
        // 订阅链接:下载内容后解析(服务商返回 Clash YAML 时自动切换解析器)
        promptAction.showToast({ message: $r('app.string.fetching_subscription') });
        subUrl = firstLine;
        const fetched = await fetchSubscriptionWithInfo(firstLine);
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
        } else {
          parsed = parseShareText(content);
        }
      } else {
        parsed = parseShareText(text);
      }
      if (parsed.length === 0) {
        promptAction.showToast({ message: $r('app.string.no_recognizable_profiles') });
        return;
      }
      await initStore(this.context);
      const profiles = await loadProfiles();
      for (const p of parsed) {
        p.id = this.genId();
        p.subUrl = subUrl;
        p.updatedAt = Date.now();
        profiles.push(p);
      }
      await saveProfiles(profiles);
      this.profiles = profiles;
      if (subUrl.length > 0) {
        // 命名导入:upsertSub 已把名称写入 SubInfo.name 与 SubInfo.group
        await upsertSub(subUrl, subUserinfo, requestedName);
        const normalizedName = requestedName.trim();
        if (normalizedName.length > 0) {
          await writePrefString('recent_subscription_group', normalizedName);
        }
        const displayName = normalizedName.length > 0 ? normalizedName : subNameOf(subUrl);
        promptAction.showToast({ message: $r('app.string.imported_from_sub', parsed.length, displayName) });
      } else {
        promptAction.showToast({ message: $r('app.string.imported_count', parsed.length) });
      }
      // 导入完成后立即刷新配置页与代理页数据(命名订阅即时归入 SubInfo.group 分组)
      await this.refresh();
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 导入失败: ${msg}`);
      promptAction.showToast({ message: $r('app.string.import_failed_reason', msg) });
    }
  }

  private genId(): string {
    return `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
  }

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
        const aLatency = this.latencies[a.id];
        const bLatency = this.latencies[b.id];
        const aValue = aLatency === undefined || aLatency < 0 ? Number.MAX_SAFE_INTEGER : aLatency;
        const bValue = bLatency === undefined || bLatency < 0 ? Number.MAX_SAFE_INTEGER : bLatency;
        return aValue - bValue;
      }
      if (a.sortOrder !== b.sortOrder) {
        return a.sortOrder - b.sortOrder;
      }
      const aLatency = this.latencies[a.id];
      const bLatency = this.latencies[b.id];
      const aValue = aLatency === undefined || aLatency < 0 ? Number.MAX_SAFE_INTEGER : aLatency;
      const bValue = bLatency === undefined || bLatency < 0 ? Number.MAX_SAFE_INTEGER : bLatency;
      return aValue - bValue;
    });
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

  profilesInGroup(groupId: string): Array<Profile> {
    return this.sortedProfiles().filter((p: Profile) => p.groupId === groupId);
  }

  groupName(groupId: string): ResourceStr {
    if (groupId.length === 0) {
      return $r('app.string.ungrouped');
    }
    const group = this.groups.find((item: ProfileGroup) => item.id === groupId);
    return group === undefined ? $r('app.string.ungrouped') : group.name;
  }

  async moveProfileToGroup(p: Profile, groupId: string): Promise<void> {
    p.groupId = groupId;
    p.sortOrder = this.profilesInGroup(groupId).length;
    p.updatedAt = Date.now();
    await saveProfiles(this.profiles);
    this.profiles = this.profiles.slice();
  }

  async togglePinned(p: Profile): Promise<void> {
    p.pinned = !p.pinned;
    await saveProfiles(this.profiles);
    this.profiles = this.profiles.slice();
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
      const delay = await fetchCurrentProxyDelay();
      const next: Record<string, number> = {};
      for (const key of Object.keys(this.latencies)) {
        next[key] = this.latencies[key];
      }
      next[p.id] = delay;
      this.latencies = next;
      promptAction.showToast({ message: `URL Test: ${delay}ms` });
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

  // ---- 当前配置(订阅)派生数据 ----

  /** 当前选中节点;运行中优先取运行节点。 */
  currentProfile(): Profile | undefined {
    const runningId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    const targetId = this.isRunning && runningId.length > 0 ? runningId : this.selectedId;
    return this.profiles.find((p: Profile) => p.id === targetId);
  }

  /** 代理页数据源：当前持久化配置对应的节点。 */
  proxyProfiles(): Array<Profile> {
    return this.sortedProfiles().filter((p: Profile) => p.subUrl === this.activeConfigUrl);
  }

  /** 节点名前缀地区字标(如 "HK 香港-01" → HK);无前缀返回空串。 */
  regionPrefixOf(name: string): string {
    const m = name.match(/^([A-Za-z]{2,4})(?![A-Za-z])/);
    return m === null ? '' : m[1].toUpperCase();
  }

  /** 代理页只显示订阅页当前选中订阅的节点；无订阅配置时保留全部手动节点。 */
  visibleProxyProfiles(): Array<Profile> {
    if (this.activeConfigUrl.length === 0) {
      return this.sortedProfiles();
    }
    return this.sortedProfiles().filter((p: Profile) => p.subUrl === this.activeConfigUrl);
  }

  async selectActiveConfig(sub: SubInfo): Promise<void> {
    this.activeConfigUrl = sub.url;
    await writePrefString('active_config_url', sub.url);
    const profiles = this.profiles.filter((profile: Profile) => profile.subUrl === sub.url);
    if (!profiles.some((profile: Profile) => profile.id === this.selectedId)) {
      this.selectedId = profiles.length > 0 ? profiles[0].id : '';
    }
  }

  // ---- 配置页(订阅源管理):按 SubInfo.group 分节 ----

  subscriptionBuckets(): Array<SubGroupBucket> {
    const buckets: Array<SubGroupBucket> = [];
    const indexOf: Map<string, number> = new Map();
    for (const sub of this.subs) {
      const name = sub.group.trim();
      if (!indexOf.has(name)) {
        indexOf.set(name, buckets.length);
        buckets.push(new SubGroupBucket(name));
      }
      const at = indexOf.get(name) as number;
      buckets[at].items.push(sub);
    }
    buckets.sort((a: SubGroupBucket, b: SubGroupBucket) => {
      if (a.name === '') {
        return -1;
      }
      if (b.name === '') {
        return 1;
      }
      return a.name.localeCompare(b.name);
    });
    return buckets;
  }

  async updateOneSub(sub: SubInfo): Promise<void> {
    if (this.updatingSubUrl.length > 0) {
      return;
    }
    this.updatingSubUrl = sub.url;
    promptAction.showToast({ message: $r('app.string.updating_subscription') });
    try {
      const r = await updateSubscription(sub.url);
      await markSubSuccess(sub.url);
      promptAction.showToast({ message: $r('app.string.sub_update_result', r.added, r.removed) });
      await this.refresh();
    } catch (e) {
      await markSubFailure(sub.url);
      await this.refresh();
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.update_failed_reason', msg) });
    } finally {
      this.updatingSubUrl = '';
    }
  }

  deleteSub(sub: SubInfo): void {
    const subUrl = sub.url;
    const count = this.profiles.filter((p: Profile) => p.subUrl === subUrl).length;
    AlertDialog.show({
      message: $r('app.string.confirm_delete_sub_name', sub.name, count),
      primaryButton: {
        value: $r('app.string.cancel'), action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.delete'), fontColor: $r('app.color.error'), action: async () => {
          const profiles = await loadProfiles();
          await saveProfiles(profiles.filter((p: Profile) => p.subUrl !== subUrl));
          await removeSub(subUrl);
          if (this.activeConfigUrl === subUrl) {
            const remainingSubs = this.subs.filter((item: SubInfo) => item.url !== subUrl);
            this.activeConfigUrl = remainingSubs.length > 0 ? remainingSubs[0].url : '';
            await writePrefString('active_config_url', this.activeConfigUrl);
          }
              await this.refresh();
        }
      }
    });
  }

  async shareSub(sub: SubInfo): Promise<void> {
    if (sub.url.length === 0) {
      return;
    }
    await setClipboardText(sub.url);
    promptAction.showToast({ message: $r('app.string.share_link_copied') });
  }

  openSubGroupDialog(sub: SubInfo): void {
    this.subGroupEditUrl = sub.url;
    this.subGroupDraft = sub.group;
    this.subGroupDialog.open();
  }

  async saveSubGroup(name: string): Promise<void> {
    const idx = this.subs.findIndex((x: SubInfo) => x.url === this.subGroupEditUrl);
    if (idx < 0) {
      return;
    }
    const trimmed = name.trim();
    const updated = this.subs.slice();
    updated[idx].group = trimmed;
    await saveSubs(updated);
    if (trimmed.length > 0) {
      await writePrefString('recent_subscription_group', trimmed);
    }
    this.subGroupEditUrl = '';
    this.subs = updated;
  }

  // ---- 模式 chips(首页):持久化 + 运行中自动重启 ----

  async switchMode(mode: string): Promise<void> {
    if (this.settings.mode === mode) {
      return;
    }
    this.settings.mode = mode;
    const toast = mode === 'global' ? $r('app.string.settings_mode_switched_global')
      : (mode === 'direct' ? $r('app.string.settings_mode_switched_direct') : $r('app.string.settings_mode_switched_rule'));
    try {
      await saveSettings(this.settings);
      promptAction.showToast({ message: toast });
      const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
      if (running && profileId.length > 0) {
        AppStorage.setOrCreate('vpnStatus', 'switching');
        LogStore.addLog(`[ui] 出站模式切换为 ${mode}，自动重启 VPN`);
        await VpnService.switchTo(this.context, profileId);
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.save_failed_reason', message) });
    }
  }

  // ---- 底部导航 ----

  navItems(): Array<NavItem> {
    return [
      new NavItem('home', '⌂', $r('app.string.tab_home')),
      new NavItem('proxy', '◈', $r('app.string.proxy')),
      new NavItem('subscriptions', '◎', $r('app.string.subscriptions')),
      new NavItem('mine', '⚙', $r('app.string.tab_mine'))
    ];
  }

  onNavTap(id: MainDestination): void {
    this.activeDestination = id;
  }

  /** 玻璃底:液态玻璃偏好开且 full 效果时用半透明玻璃,否则实底(lite 防残影)。 */
  glassBg(): ResourceColor {
    const full = this.settings.liquidGlass && this.uiFxLevel === 'full';
    return full ? $r('app.color.bg_glass') : $r('app.color.bg_glass_solid');
  }

  @Builder
  latencyMeter(p: Profile, best: number) {
    Column({ space: 4 }) {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width(64)
          .height(5)
          .borderRadius(3)
          .backgroundColor($r('app.color.border_glass'))
        Row()
          .width(this.latencyBarWidth(p))
          .height(5)
          .borderRadius(3)
          .linearGradient({
            angle: 90,
            colors: this.latencyBarColors(this.latencies[p.id] ?? 0)
          })
      }
      .width(64)
      .height(5)
      Text(this.latencyText(p))
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.latencyTextColor(p, best))
    }
    .alignItems(HorizontalAlign.End)
    .margin({ right: 4 })
  }

  @Builder
  homeTopBar() {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text('NekoBox')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.modeLabel())
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button(this.testing ? $r('app.string.speed_testing') : $r('app.string.speed_test'))
        .height(30)
        .fontSize(11)
        .padding({ left: 10, right: 10 })
        .fontColor($r('app.color.primary'))
        .backgroundColor($r('app.color.surface_selected'))
        .onClick(() => this.runSpeedTest())
      Button($r('app.string.connect'))
        .height(30)
        .fontSize(11)
        .padding({ left: 10, right: 10 })
        .fontColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.surface'))
        .onClick(() => {
          router.pushUrl({ url: 'pages/ConnectionsPage' });
        })
      Button($r('app.string.logs'))
        .height(30)
        .fontSize(11)
        .padding({ left: 10, right: 10 })
        .fontColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.surface'))
        .onClick(() => {
          router.pushUrl({ url: 'pages/LogPage' });
        })
      Button('⚙')
        .height(30)
        .width(34)
        .fontSize(15)
        .fontColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.surface'))
        .onClick(() => {
          router.pushUrl({ url: 'pages/SettingsPage' });
        })
    }
    .width('100%')
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 8 })
  }

  @Builder
  homeHero() {
    Column({ space: UiSpec.GAP_LG }) {
      Row({ space: UiSpec.GAP_SM }) {
        Text(this.isRunning ? '●' : '○')
          .fontSize(16)
          .fontColor(this.isRunning ? $r('app.color.success') : $r('app.color.text_disabled'))
        Text(this.statusDisplay())
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isRunning ? $r('app.color.success') : $r('app.color.text_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.modeLabel())
          .fontSize(11)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.surface_selected'))
          .borderRadius(10)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      }
      .width('100%')

      if (this.isRunning) {
        Text($r('app.string.hero_protected_line', this.modeLabel(), this.protectedSinceText()))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      BigPowerButton({
        running: this.isRunning,
        connecting: this.statusText === 'connecting' || this.statusText === 'switching',
        orbSize: this.uiBreakpoint === 'compact' ? UiSpec.ORB_BUTTON_SIZE : 64,
        onToggle: () => {
          if (this.isRunning) {
            this.disconnect();
            return;
          }
          const target = this.profiles.find((profile: Profile) => profile.id === this.selectedId);
          if (target === undefined) {
            promptAction.showToast({ message: $r('app.string.select_or_create_profile') });
            return;
          }
          this.connectTo(target);
        }
      })

      // 统计卡 2×2:两行两列,避免四卡横排在平板上溢出屏幕右缘
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          MiniStatCard({
            label: $r('app.string.upload'),
            value: this.isRunning ? formatSpeed(this.upSpeed) : '—'
          })
            .layoutWeight(1)
          MiniStatCard({
            label: $r('app.string.download'),
            value: this.isRunning ? formatSpeed(this.downSpeed) : '—'
          })
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 10 }) {
          MiniStatCard({
            label: $r('app.string.traffic'),
            value: this.isRunning ? formatBytes(this.totalUp + this.totalDown) : '—'
          })
            .layoutWeight(1)
          MiniStatCard({
            label: $r('app.string.proxy'),
            value: `${this.profiles.length}`
          })
            .layoutWeight(1)
        }
        .width('100%')
      }
      .width('100%')

      // 模式 chips:规则 / 全局 / 直连
      Row({ space: UiSpec.GAP_SM }) {
        ForEach(['rule', 'global', 'direct'], (m: string) => {
          Button(m === 'rule' ? $r('app.string.mode_rule')
            : (m === 'global' ? $r('app.string.mode_global') : $r('app.string.mode_direct')))
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .borderRadius(UiSpec.CHIP_RADIUS)
            .backgroundColor(this.settings.mode === m ? $r('app.color.chip_on_bg_a') : $r('app.color.bg_glass_solid'))
            .fontColor(this.settings.mode === m ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
            .border({
              width: UiSpec.GLASS_BORDER_WIDTH,
              color: this.settings.mode === m ? $r('app.color.chip_on_border') : $r('app.color.border_glass')
            })
            .onClick(() => this.switchMode(m))
        }, (m: string) => m)
      }
      .width('100%')
    }
    .width('100%')
    .padding(20)
    .borderRadius(UiSpec.GLASS_RADIUS)
    .backgroundColor(this.glassBg())
    .border({
      width: UiSpec.GLASS_BORDER_WIDTH,
      color: $r('app.color.border_glass')
    })
    .shadow({
      radius: UiSpec.GLASS_SHADOW_RADIUS,
      color: $r('app.color.sel_glow'),
      offsetX: 0,
      offsetY: UiSpec.GLASS_SHADOW_OFFSET
    })
  }

  @Builder
  homeNodeCard() {
    Column({ space: 6 }) {
      Text($r('app.string.current_node'))
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      if (this.currentProfile() !== undefined) {
        Row({ space: 10 }) {
          Text(this.regionPrefixOf((this.currentProfile() as Profile).name).length > 0
            ? this.regionPrefixOf((this.currentProfile() as Profile).name) : '🌐')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.primary'))
            .width(30)
            .textAlign(TextAlign.Center)
          Column({ space: 2 }) {
            Text((this.currentProfile() as Profile).name)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text($r('app.string.node_group_selected', this.groupName((this.currentProfile() as Profile).groupId)))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          if (this.latencies[(this.currentProfile() as Profile).id] !== undefined || this.testing) {
            this.latencyMeter(this.currentProfile() as Profile,
              this.bestLatencyIn(this.profiles))
          }
        }
        .width('100%')
      } else {
        Text($r('app.string.select_or_create_profile'))
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 14 })
    .borderRadius(UiSpec.CARD_RADIUS)
    .backgroundColor($r('app.color.bg_glass_solid'))
    .border({
      width: UiSpec.GLASS_BORDER_WIDTH,
      color: $r('app.color.border_glass')
    })
    .hoverEffect(HoverEffect.Scale)
    .onClick(() => {
      // 当前节点卡点击 → 代理页
      this.activeDestination = 'proxy';
    })
  }

  @Builder
  homePage() {
    Column() {
      this.homeTopBar()
      Scroll() {
        Column({ space: UiSpec.GAP_MD }) {
          this.homeHero()
          this.homeNodeCard()
        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 88 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  proxyPage() {
    Column() {
      Row({ space: 8 }) {
        Text($r('app.string.proxy'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Button($r('app.string.profile_new_title'))
          .height(30)
          .fontSize(11)
          .padding({ left: 10, right: 10 })
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.surface_selected'))
          .onClick(() => {
            AppStorage.setOrCreate('editProfileId', '');
            router.pushUrl({ url: 'pages/ProfileEdit' });
          })
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 4 })

      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() {
          if (this.visibleProxyProfiles().length === 0) {
            Text($r('app.string.proxy_empty'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ top: 48 })
          }
        List({ space: 8 }) {
          ForEach(this.visibleProxyProfiles(), (p: Profile) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(this.regionPrefixOf(p.name).length > 0 ? this.regionPrefixOf(p.name) : '🌐')
                  .fontSize(13)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.primary'))
                  .width(30)
                  .textAlign(TextAlign.Center)
                Column({ space: 2 }) {
                  Text(p.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(p.subUrl.length > 0 ? $r('app.string.node_source_auto') : $r('app.string.node_source_manual'))
                    .fontSize(11)
                    .fontColor($r('app.color.text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('✏')
                  .fontSize(16)
                  .padding(6)
                  .onClick(() => {
                    AppStorage.setOrCreate('editProfileId', p.id);
                    router.pushUrl({ url: 'pages/ProfileEdit' });
                  })
                if (this.latencies[p.id] !== undefined || this.testing) {
                  this.latencyMeter(p, this.bestLatencyIn(this.visibleProxyProfiles()))
                }
              }
              .width('100%')
              .padding(12)
              .borderRadius(UiSpec.CARD_RADIUS)
              .backgroundColor($r('app.color.bg_glass_solid'))
              .border({
                width: UiSpec.GLASS_BORDER_WIDTH,
                color: this.selectedId === p.id ? $r('app.color.sel_border') : $r('app.color.border_glass')
              })
              .shadow({
                radius: this.selectedId === p.id ? UiSpec.GLASS_SHADOW_RADIUS : 0,
                color: $r('app.color.sel_glow'),
                offsetX: 0,
                offsetY: 0
              })
              .hoverEffect(HoverEffect.Scale)
              .bindContextMenu(this.profileContextMenu(p), ResponseType.LongPress)
              .onClick(() => this.onNodeTap(p))
            }
          }, (p: Profile) => p.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 4, bottom: 146 })
        }
        .width('100%')
        .height('100%')

        // FAB:延迟测试(只测当前配置);bottom 94 = 悬浮底部导航顶(高 66 + 边距 12)+ 16,
        // right 32 = 列表卡片右缘(屏内 PAGE_PADDING)+ 16,滚动时随 Stack 定位不动
        Button(this.testing ? '…' : '⚡')
          .type(ButtonType.Circle)
          .width(52)
          .height(52)
          .fontSize(22)
          .fontColor($r('app.color.surface'))
          .backgroundColor($r('app.color.primary'))
          .shadow({
            radius: UiSpec.GLASS_SHADOW_RADIUS,
            color: $r('app.color.shadow_color'),
            offsetX: 0,
            offsetY: 6
          })
          .margin({ right: UiSpec.PAGE_PADDING + 16, bottom: 94 })
          .hoverEffect(HoverEffect.Scale)
          .onClick(() => this.runProxySpeedTest())
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  subCard(sub: SubInfo) {
    Column({ space: UiSpec.GAP_SM }) {
      Column({ space: 4 }) {
        Row() {
          Text(sub.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.activeConfigUrl.length > 0 && this.activeConfigUrl === sub.url) {
            Text($r('app.string.sub_in_use'))
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.neon_cyan'))
              .backgroundColor($r('app.color.chip_on_bg_a'))
              .borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ left: 6 })
          }
        }
        .width('100%')
        Text(sub.lastUpdate === 0 ? $r('app.string.settings_sub_never_updated')
          : $r('app.string.settings_sub_updated_at', new Date(sub.lastUpdate).toLocaleString()))
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        if (sub.total > 0) {
          // 流量进度条:已用 / 总量
          Row() {
            Row()
              .width(`${Math.min(100, Math.round((sub.upload + sub.download) * 100 / sub.total))}%`)
              .height(6)
              .borderRadius(3)
              .backgroundColor(sub.upload + sub.download > sub.total ? $r('app.color.error') : $r('app.color.success'))
          }
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.border_glass'))
          Text($r('app.string.settings_sub_traffic', formatBytes(sub.upload + sub.download), formatBytes(sub.total)))
            .fontSize(11)
            .fontColor(sub.upload + sub.download > sub.total ? $r('app.color.error') : $r('app.color.success'))
            .width('100%')
        }
        if (sub.expire > 0) {
          Text($r('app.string.settings_sub_expire', new Date(sub.expire * 1000).toLocaleDateString()))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .onClick(() => this.selectActiveConfig(sub))

      Row({ space: UiSpec.GAP_SM }) {
        Button(this.updatingSubUrl === sub.url ? $r('app.string.updating') : $r('app.string.update_action'))
          .layoutWeight(1)
          .height(34)
          .fontSize(11)
          .backgroundColor(this.updatingSubUrl === sub.url ? $r('app.color.control_disabled') : $r('app.color.primary'))
          .fontColor($r('app.color.surface'))
          .onClick(() => this.updateOneSub(sub))
        Button($r('app.string.share'))
          .layoutWeight(1)
          .height(34)
          .fontSize(11)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.shareSub(sub))
        Button($r('app.string.sub_group_edit'))
          .layoutWeight(1)
          .height(34)
          .fontSize(11)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.openSubGroupDialog(sub))
        Button($r('app.string.delete'))
          .layoutWeight(1)
          .height(34)
          .fontSize(11)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.error'))
          .onClick(() => this.deleteSub(sub))
      }
      .width('100%')
    }
    .width('100%')
    .padding(UiSpec.GAP_MD)
    .borderRadius(UiSpec.GLASS_RADIUS)
    .backgroundColor($r('app.color.bg_glass_solid'))
    .border({
      width: UiSpec.GLASS_BORDER_WIDTH,
      color: this.activeConfigUrl.length > 0 && this.activeConfigUrl === sub.url
        ? $r('app.color.sel_border') : $r('app.color.border_glass')
    })
    .shadow({
      radius: this.activeConfigUrl.length > 0 && this.activeConfigUrl === sub.url ? UiSpec.GLASS_SHADOW_RADIUS : 0,
      color: $r('app.color.sel_glow'),
      offsetX: 0,
      offsetY: 0
    })
  }

  @Builder
  subscriptionsPage() {
    Column() {
      Row() {
        Text($r('app.string.subscriptions'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Text($r('app.string.add_config'))
          .fontSize(13)
          .fontColor($r('app.color.primary'))
          .onClick(() => this.openImportDialog())
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 4 })

      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() {
        Scroll() {
          Column({ space: UiSpec.GAP_MD }) {
            if (this.subs.length === 0) {
              Text($r('app.string.settings_subs_empty'))
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .padding({ top: 40 })
            }
            ForEach(this.subscriptionBuckets(), (bucket: SubGroupBucket) => {
              Column({ space: UiSpec.GAP_SM }) {
                Text(bucket.name === ''
                  ? $r('app.string.sub_group_none_count', bucket.items.length)
                  : `${bucket.name} · ${bucket.items.length}`)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.primary'))
                  .width('100%')
                ForEach(bucket.items, (sub: SubInfo) => {
                  this.subCard(sub)
                }, (sub: SubInfo) => sub.url)
              }
              .width('100%')
            }, (bucket: SubGroupBucket) => bucket.name === '' ? '__none__' : bucket.name)
          }
          .width('100%')
          .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 146 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        }
        .width('100%')
        .height('100%')

        // FAB:添加配置(打开导入弹窗,含订阅名称输入)
        Button('+')
          .type(ButtonType.Circle)
          .width(52)
          .height(52)
          .fontSize(24)
          .fontColor($r('app.color.surface'))
          .backgroundColor($r('app.color.primary'))
          .shadow({
            radius: UiSpec.GLASS_SHADOW_RADIUS,
            color: $r('app.color.shadow_color'),
            offsetX: 0,
            offsetY: 6
          })
          .margin({ right: UiSpec.PAGE_PADDING + 8, bottom: 86 })
          .hoverEffect(HoverEffect.Scale)
          .onClick(() => this.openImportDialog())
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  navTab(item: NavItem) {
    Column({ space: 2 }) {
      Text(item.icon)
        .fontSize(18)
        .fontColor(this.activeDestination === item.id ? $r('app.color.primary') : $r('app.color.text_secondary'))
      Text(item.label)
        .fontSize(10.5)
        .fontWeight(this.activeDestination === item.id ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.activeDestination === item.id ? $r('app.color.primary') : $r('app.color.text_secondary'))
    }
    .layoutWeight(1)
    .height(54)
    .justifyContent(FlexAlign.Center)
    .borderRadius(18)
    .backgroundColor(this.activeDestination === item.id ? $r('app.color.surface_selected') : $r('app.color.bg_glass_solid'))
    .hoverEffect(HoverEffect.Scale)
    .onClick(() => this.onNavTap(item.id))
  }

  @Builder
  bottomNav() {
    Row() {
      ForEach(this.navItems(), (item: NavItem) => {
        this.navTab(item)
      }, (item: NavItem) => item.id)
    }
    .width('100%')
    .padding(6)
    .borderRadius(24)
    .backgroundColor(this.glassBg())
    .border({
      width: UiSpec.GLASS_BORDER_WIDTH,
      color: $r('app.color.border_glass')
    })
    .shadow({
      radius: UiSpec.GLASS_SHADOW_RADIUS,
      color: $r('app.color.shadow_color'),
      offsetX: 0,
      offsetY: 4
    })
    .margin({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 12 })
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
      MenuItem({ content: 'URL Test' })
        .onClick(() => this.runUrlTest(p))
      MenuItem({ content: $r('app.string.copy_share_link') })
        .onClick(() => this.copyProfileLink(p))
      MenuItem({ content: $r('app.string.share_profile') })
        .onClick(() => this.openProfileShare(p))
      if (p.subUrl.length > 0) {
        MenuItem({ content: $r('app.string.view_subscription') })
          .onClick(() => router.pushUrl({ url: 'pages/SubDetailPage', params: { url: p.subUrl } }))
      }
      MenuItem({ content: $r('app.string.delete'), labelInfo: $r('app.string.irreversible') })
        .onClick(() => this.deleteProfile(p))
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        if (this.activeDestination === 'home') {
          this.homePage()
        } else if (this.activeDestination === 'proxy') {
          this.proxyPage()
        } else if (this.activeDestination === 'subscriptions') {
          this.subscriptionsPage()
        } else {
          SettingsView({ embedded: true })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.statusBarVp })

      this.bottomNav()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}

/** 分享降级弹窗:SDK 未提供 generateBarcode 时展示 URI 并支持复制。 */
@CustomDialog
struct ShareTextDialog {
  controller?: CustomDialogController;
  @Link text: string;
  onCopy: (text: string) => void = (text: string) => {};

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.share_link_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Text(this.text)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .copyOption(CopyOptions.LocalDevice)
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

/** 导入弹窗:手动粘贴订阅链接 / 节点链接 / base64 订阅内容(含订阅名称输入) */
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
    Column({ space: 12 }) {
      Text($r('app.string.import_link_subscription'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      TextInput({
        text: this.name,
        placeholder: $r('app.string.subscription_name_optional')
      })
        .width('100%')
        .height(UiSpec.BTN_HEIGHT)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.form_bg'))
        .border({ width: UiSpec.GLASS_BORDER_WIDTH, color: $r('app.color.border_glass') })
        .borderRadius(UiSpec.CHIP_RADIUS)
        .onChange((v: string) => {
          this.name = v;
        })
      TextArea({
        text: this.text,
        placeholder: $r('app.string.import_content_placeholder')
      })
        .width('100%')
        .height(120)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.form_bg'))
        .border({ width: UiSpec.GLASS_BORDER_WIDTH, color: $r('app.color.border_glass') })
        .borderRadius(UiSpec.CHIP_RADIUS)
        .onChange((v: string) => {
          this.text = v;
        })
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.bg_glass_solid'))
          .fontColor($r('app.color.text_2'))
          .border({ width: UiSpec.GLASS_BORDER_WIDTH, color: $r('app.color.border_glass') })
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button($r('app.string.read_from_clipboard'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.bg_glass_solid'))
          .fontColor($r('app.color.text_2'))
          .border({ width: UiSpec.GLASS_BORDER_WIDTH, color: $r('app.color.border_glass') })
          .onClick(() => this.onPickClipboard())
        Button($r('app.string.import_action'))
          .layoutWeight(1)
          .fontColor($r('app.color.power_icon'))
          .linearGradient({
            angle: 90,
            colors: [[$r('app.color.grad_neon_a'), 0.0], [$r('app.color.grad_neon_b'), 1.0]]
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
    .padding(20)
    .width('100%')
    .backgroundColor($r('app.color.bg_glass_solid'))
    .border({ width: UiSpec.GLASS_BORDER_WIDTH, color: $r('app.color.border_glass') })
    .borderRadius(22)
  }
}

/** 订阅改组弹窗:空值 = 未分组 */
@CustomDialog
struct SubGroupInputDialog {
  controller?: CustomDialogController;
  @Link draft: string;
  onSave: (name: string) => void = (name: string) => {};

  build() {
    Column({ space: 10 }) {
      Text($r('app.string.sub_group_dialog_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      TextInput({
        text: this.draft,
        placeholder: $r('app.string.sub_group_hint')
      })
        .height(UiSpec.BTN_HEIGHT)
        .onChange((v: string) => {
          this.draft = v;
        })
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
        Button($r('app.string.save'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.surface'))
          .onClick(() => {
            const v = this.draft;
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onSave(v);
          })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}
