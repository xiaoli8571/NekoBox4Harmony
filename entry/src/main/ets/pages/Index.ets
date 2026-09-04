import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { BigPowerButton } from '../common/components/BigPowerButton';
import { MiniStatCard } from '../common/components/MiniStatCard';
import { Profile, ProfileGroup, AppSettings, profileTypeLabel } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, saveGroups, loadSettings, saveSettings, readPrefString, writePrefString, LogStore } from '../model/Store';
import { VpnService } from '../core/VpnService';
import { parseShareText } from '../utils/LinkParser';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { fetchSubscriptionWithInfo, fetchSubscription, looksLikeClashYaml, parseClashProxies, ClashParseResult } from '../utils/Subscription';
import { testProfiles, tcpPing } from '../utils/LatencyTester';
import { upsertSub, needAutoUpdate, updateSubscription, setAppContext, subNameOf, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { fetchTrafficTotals, formatSpeed, formatBytes } from '../utils/TrafficStats';
import { fetchCurrentProxyDelay } from '../utils/ClashApi';
import { exportProfileLink } from '../utils/LinkExporter';
import { publishVpnLatency } from '../core/VpnIpc';

@Entry
@Component
struct Index {
  @State profiles: Array<Profile> = [];
  @State groups: Array<ProfileGroup> = [];
  @State selectedId: string = '';
  @State latencies: Record<string, number> = {};
  @State testing: boolean = false;
  @State settings: AppSettings = new AppSettings();
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

  aboutToAppear(): void {
    setAppContext(this.context);
    this.refresh();
    this.autoUpdateSubs();
  }

  // 从编辑页 router.back() 回来时刷新列表(否则新保存的节点不显示)
  onPageShow(): void {
    this.refresh();
  }

  onRunningChange(): void {
    if (this.isRunning) {
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
      const t = await fetchTrafficTotals();
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

  async refresh(): Promise<void> {
    try {
      await initStore(this.context);
      this.profiles = await loadProfiles();
      this.groups = await loadGroups();
      this.settings = await loadSettings();
      if (this.selectedId.length === 0 && this.profiles.length > 0) {
        this.selectedId = this.profiles[0].id;
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

  /** 真连接延迟测试(TCP 握手计时) */
  async runSpeedTest(): Promise<void> {
    if (this.testing || this.profiles.length === 0) {
      return;
    }
    this.latencies = {};
    promptAction.showToast({ message: $r('app.string.index_testing_count', this.profiles.length) });
    await this.runProfilesTest(this.profiles.slice());
  }

  async runGroupSpeedTest(groupId: string): Promise<void> {
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

  groupLatencyText(groupId: string): ResourceStr {
    const profiles = this.profiles.filter((item: Profile) => item.groupId === groupId);
    let minimum = Number.MAX_SAFE_INTEGER;
    let untested = 0;
    let successful = 0;
    for (const profile of profiles) {
      const latency = this.latencies[profile.id];
      if (latency === undefined) {
        untested++;
      } else if (latency >= 0) {
        successful++;
        minimum = Math.min(minimum, latency);
      }
    }
    if (untested > 0) {
      return $r('app.string.group_latency_untested', untested);
    }
    if (successful === 0) {
      return $r('app.string.timeout');
    }
    return $r('app.string.group_latency_minimum', minimum);
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

  openProfileShare(p: Profile): void {
    const link = exportProfileLink(p);
    if (link.length === 0) {
      promptAction.showToast({ message: $r('app.string.protocol_export_unsupported') });
      return;
    }
    this.shareText = link;
    this.shareDialog.open();
  }

  // ---- 导入弹窗(手动粘贴,不依赖剪贴板权限) ----
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

  // ---- 统一添加入口:新建节点 / 导入订阅 ----
  private addEntryDialog: CustomDialogController = new CustomDialogController({
    builder: AddEntryDialog({
      onNewProfile: () => {
        AppStorage.setOrCreate('editProfileId', '');
        router.pushUrl({ url: 'pages/ProfileEdit' });
      },
      onImportSubscription: () => {
        this.openImportDialog();
      }
    }),
    autoCancel: true
  });

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

  isGroupCollapsed(groupId: string): boolean {
    if (groupId.length === 0) {
      return false;
    }
    const group = this.groups.find((item: ProfileGroup) => item.id === groupId);
    return group !== undefined && group.collapsed;
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

  async toggleGroupCollapsed(group: ProfileGroup): Promise<void> {
    group.collapsed = !group.collapsed;
    group.updatedAt = Date.now();
    await saveGroups(this.groups);
    this.groups = this.groups.slice();
  }

  sourceHost(p: Profile): ResourceStr {
    if (p.subUrl.length === 0) {
      return $r('app.string.local_profile');
    }
    try {
      const withoutScheme = p.subUrl.split('://').pop() ?? p.subUrl;
      return withoutScheme.split('/')[0];
    } catch (e) {
      return $r('app.string.subscription_profile');
    }
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
    Column() {
    Column() {
      // Android NekoBox 风格顶栏与快捷导航
      Row({ space: 4 }) {
        Column({ space: 2 }) {
          Text('NekoBox')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.modeLabel())
            .fontSize(12)
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              router.pushUrl({ url: 'pages/SettingsPage' });
            })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.testing ? $r('app.string.speed_testing') : $r('app.string.speed_test'))
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.surface_selected'))
          .onClick(() => this.runSpeedTest())
        Button($r('app.string.connect'))
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/ConnectionsPage' });
          })
        Button($r('app.string.logs'))
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/LogPage' });
          })
        Button($r('app.string.settings_title'))
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 8 })

      // 鸿蒙原生 Hero 卡片：状态、主连接按钮与实时统计共用现有 VPN 状态链路
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
          Text(this.modeLabel())
            .fontSize(11)
            .fontColor($r('app.color.primary'))
            .backgroundColor($r('app.color.surface_selected'))
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        }
        .width('100%')

        BigPowerButton({
          running: this.isRunning,
          connecting: this.statusText === 'connecting' || this.statusText === 'switching',
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
      .width('calc(100% - 32vp)')
      .margin({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 10 })
      .padding(20)
      .borderRadius(24)
      .backgroundColor($r('app.color.surface'))
      .shadow({ radius: 16, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 6 })

      // 按分组展示节点，分组头在折叠状态下仍显示测速汇总与操作
      List({ space: 8 }) {
        ForEach(this.sortedGroupIds(), (groupId: string) => {
          ListItem() {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Text(this.isGroupCollapsed(groupId) ? '▶' : '▼')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.groupName(groupId))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .layoutWeight(1)
                Text(this.groupLatencyText(groupId))
                  .fontSize(11)
                  .fontColor($r('app.color.primary'))
                  .backgroundColor($r('app.color.surface_selected'))
                  .borderRadius(10)
                  .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                Button(this.testing ? $r('app.string.speed_testing') : $r('app.string.test_group'))
                  .height(30)
                  .fontSize(11)
                  .backgroundColor($r('app.color.surface_selected'))
                  .fontColor($r('app.color.primary'))
                  .onClick(() => this.runGroupSpeedTest(groupId))
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 })
              .onClick(() => {
                if (groupId.length > 0) {
                  const group = this.groups.find((item: ProfileGroup) => item.id === groupId);
                  if (group !== undefined) {
                    this.toggleGroupCollapsed(group);
                  }
                }
              })

              if (!this.isGroupCollapsed(groupId)) {
                ForEach(this.profilesInGroup(groupId), (p: Profile) => {
                  Row() {
                    Radio({ value: p.id, group: 'profiles' })
                      .checked(this.selectedId === p.id)
                      .onChange((checked: boolean) => {
                        if (checked) {
                          this.onNodeTap(p);
                        }
                      })
                    Column() {
                      Text(p.name)
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${profileTypeLabel(p.type)} · ${p.server}:${p.serverPort}`)
                        .fontSize(12)
                        .fontColor($r('app.color.text_secondary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    .margin({ left: 4 })
                    .onClick(() => {
                      this.onNodeTap(p);
                    })

                    if (this.latencies[p.id] !== undefined || this.testing) {
                      Text(this.latencyText(p))
                        .fontSize(12)
                        .fontColor(this.latencyColor(p))
                        .margin({ right: 4 })
                    }

                    Text('✏')
                      .fontSize(18)
                      .padding(8)
                      .onClick(() => {
                        AppStorage.setOrCreate('editProfileId', p.id);
                        router.pushUrl({ url: 'pages/ProfileEdit' });
                      })
                  }
                  .width('100%')
                  .padding(12)
                  .borderRadius(UiSpec.CARD_RADIUS)
                  .backgroundColor(this.selectedId === p.id ? $r('app.color.surface_selected') : $r('app.color.surface'))
                  .hoverEffect(HoverEffect.Scale)
                  .bindContextMenu(this.profileContextMenu(p), ResponseType.LongPress)
                }, (p: Profile) => p.id)
              }
            }
            .width('100%')
            .padding(8)
            .borderRadius(UiSpec.CARD_RADIUS)
            .backgroundColor($r('app.color.surface'))
          }
        }, (groupId: string) => groupId)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })

      // 底部菜单栏:添加(导入订阅 / 新建节点)统一入口
      Row() {
        Button($r('app.string.add_entry'), { type: ButtonType.Capsule })
          .layoutWeight(1)
          .height(UiSpec.BTN_HEIGHT)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.surface'))
          .onClick(() => this.addEntryDialog.open())
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 10, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.app_background'))
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
        .fontWeight(FontWeight.Bold)
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

/** 统一添加入口弹窗:新建节点 / 导入订阅 */
@CustomDialog
struct AddEntryDialog {
  controller?: CustomDialogController;
  onNewProfile: () => void = () => {
  };
  onImportSubscription: () => void = () => {
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
