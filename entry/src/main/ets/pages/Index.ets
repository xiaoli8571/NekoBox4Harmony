import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { BigPowerButton } from '../common/components/BigPowerButton';
import { StatsRow } from '../common/components/StatsRow';
import { BottomNavText } from '../common/components/BottomNavText';
import { SettingsPage } from './SettingsPage';

import { Profile, ProfileGroup, AppSettings, profileTypeLabel } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, saveGroups, loadSettings, saveSettings, readPrefString, writePrefString, LogStore } from '../model/Store';
import { VpnService } from '../core/VpnService';
import { parseShareText } from '../utils/LinkParser';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { fetchSubscriptionWithInfo, fetchSubscription, looksLikeClashYaml, parseClashProxies, ClashParseResult } from '../utils/Subscription';
import { testProfiles, tcpPing } from '../utils/LatencyTester';
import { SubInfo, listSubs, saveSubs, removeSub, upsertSub, needAutoUpdate, updateSubscription, setAppContext, subNameOf, markSubSuccess, markSubFailure } from '../core/Subscriptions';
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
  @State subscriptions: Array<SubInfo> = [];
  @State activeConfigUrl: string = '';
  @State activeTab: number = 0;
  @State uiUptime: number = 0;
  @State nodeSearch: string = '';
  @State subNameDraft: string = '';
  @State subGroupDraft: string = '';
  @StorageLink('uiBreakpoint') uiBreakpoint: string = 'compact';
  @StorageLink('vpnRunning') @Watch('onRunningChange') isRunning: boolean = false;
  @StorageLink('vpnStatus') statusText: string = 'disconnected';
  @StorageLink('vpnUpSpeed') upSpeed: number = 0;
  @StorageLink('vpnDownSpeed') downSpeed: number = 0;
  @StorageLink('vpnTotalUp') totalUp: number = 0;
  @StorageLink('vpnTotalDown') totalDown: number = 0;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  private usesSidebar(): boolean {
    return this.settings.navLayout === 'side';
  }
  private switching: boolean = false;
  private speedTimer: number = -1;
  private speedPollGeneration: number = 0;
  private lastUp: number = 0;
  private lastDown: number = 0;
  private lastTrafficAt: number = 0;
  private uptimeTimer: number = -1;
  private subEditUrl: string = '';
  private subEditDialog: CustomDialogController = new CustomDialogController({
    builder: SubscriptionGroupDialog({
      name: $subNameDraft,
      group: $subGroupDraft,
      onSaved: (name: string, group: string) => { void this.saveSubscriptionGroup(name, group); }
    }),
    autoCancel: true
  });

  aboutToAppear(): void {
    setAppContext(this.context);
    this.refresh();
    this.autoUpdateSubs();
    if (this.isRunning) {
      this.startSpeedPoller();
      this.startUptimeTimer();
    }
  }

  private subscriptionExpiryText(sub: SubInfo): ResourceStr {
    if (sub.expire <= 0) {
      return $r('app.string.subscription_no_expiry');
    }
    const days = Math.max(0, Math.ceil((sub.expire * 1000 - Date.now()) / 86400000));
    return $r('app.string.subscription_days_remaining', days);
  }

  private async selectSubscription(sub: SubInfo): Promise<void> {
    this.activeConfigUrl = sub.url;
    const firstProfile = this.profiles.find((profile: Profile) => profile.subUrl === sub.url);
    if (firstProfile !== undefined) {
      this.selectedId = firstProfile.id;
    }
    await writePrefString('active_config_url', sub.url);
  }

  async updateOneSubscription(sub: SubInfo): Promise<void> {
    if (this.testing) {
      return;
    }
    this.testing = true;
    try {
      const result = await updateSubscription(sub.url);
      await markSubSuccess(sub.url);
      this.subscriptions = await listSubs();
      this.profiles = await loadProfiles();
      promptAction.showToast({ message: $r('app.string.sub_update_result', result.added, result.removed) });
    } catch (e) {
      await markSubFailure(sub.url);
      this.subscriptions = await listSubs();
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.update_failed_reason', message) });
    } finally {
      this.testing = false;
    }
  }

  async openSubscriptionGroup(sub: SubInfo): Promise<void> {
    this.subEditUrl = sub.url;
    this.subNameDraft = sub.name;
    this.subGroupDraft = sub.group.length > 0
      ? sub.group
      : await readPrefString('recent_subscription_group', '');
    this.subEditDialog.open();
  }

  async saveSubscriptionGroup(name: string, group: string): Promise<void> {
    const index = this.subscriptions.findIndex((item: SubInfo) => item.url === this.subEditUrl);
    if (index < 0) {
      return;
    }
    const next = this.subscriptions.slice();
    next[index].name = name.trim().length > 0 ? name.trim() : subNameOf(next[index].url);
    next[index].group = group.trim();
    await saveSubs(next);
    if (next[index].group.length > 0) {
      await writePrefString('recent_subscription_group', next[index].group);
    }
    this.subscriptions = next;
    this.subEditUrl = '';
  }
  deleteSubscription(sub: SubInfo): void {
    const count = this.profiles.filter((profile: Profile) => profile.subUrl === sub.url).length;
    AlertDialog.show({
      message: $r('app.string.confirm_delete_sub_name', sub.name, count),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          await removeSub(sub.url);
          this.profiles = this.profiles.filter((profile: Profile) => profile.subUrl !== sub.url);
          await saveProfiles(this.profiles);
          this.subscriptions = this.subscriptions.filter((item: SubInfo) => item.url !== sub.url);
        }
      }
    });
  }






  @Builder
  private subscriptionsTab() {
    Column() {
      Row() {
        Text($r('app.string.subscription_management'))
          .fontSize(16)
          .fontWeight(800)
          .fontColor($r('app.color.text_1'))
          .layoutWeight(1)
        Text($r('app.string.add_entry'))
          .fontSize(13.5)
          .fontWeight(600)
          .fontColor($r('app.color.mono'))
          .padding(8)
          .onClick(() => this.addEntryDialog.open())
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 26 })

      TextInput({ text: this.nodeSearch, placeholder: $r('app.string.search_nodes') })
        .fontSize(14.5)
        .fontColor($r('app.color.text_1'))
        .placeholderColor($r('app.color.text_3'))
        .backgroundColor(Color.Transparent)
        .height(UiSpec.ROW_HEIGHT)
        .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
        .margin({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
        .onChange((value: string) => { this.nodeSearch = value; })
      Row() {
        Text($r('app.string.settings_auto_update_subs'))
          .fontSize(13.5)
          .fontColor($r('app.color.text_2'))
          .layoutWeight(1)
        Text(this.testing ? $r('app.string.speed_testing') : $r('app.string.speed_test'))
          .fontSize(13.5)
          .fontWeight(600)
          .fontColor($r('app.color.mono'))
          .padding(8)
          .onClick(() => this.runSpeedTest())
        Toggle({ type: ToggleType.Switch, isOn: this.settings.autoUpdateSubs })
          .onChange((value: boolean) => {
            this.settings.autoUpdateSubs = value;
            saveSettings(this.settings);
          })
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })

      List() {
        if (this.subscriptions.length === 0) {
          ListItem() {
            Text($r('app.string.settings_subs_empty'))
              .fontSize(13)
              .fontColor($r('app.color.text_3'))
              .width('100%')
              .padding({ top: 30, bottom: 30 })
          }
        }
        ForEach(this.subscriptions, (sub: SubInfo) => {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text(sub.name)
                  .fontSize(14.5)
                  .fontWeight(this.activeConfigUrl === sub.url ? 800 : 600)
                  .fontColor(this.activeConfigUrl === sub.url ? $r('app.color.mono') : $r('app.color.text_1'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(sub.url)
                  .fontSize(11)
                  .fontColor($r('app.color.text_3'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(this.subscriptionExpiryText(sub))
                  .fontSize(11)
                  .fontColor($r('app.color.text_2'))
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .onClick(() => { void this.selectSubscription(sub); })
              if (this.activeConfigUrl === sub.url) {
                Text('✓')
                  .fontSize(15)
                  .fontWeight(800)
                  .fontColor($r('app.color.success'))
              }
              Text($r('app.string.sub_group_edit'))
                .fontSize(12.5)
                .fontWeight(600)
                .fontColor($r('app.color.text_2'))
                .padding({ left: 8, top: 12, bottom: 12 })
                .onClick(() => this.openSubscriptionGroup(sub))

              Text(this.testing ? $r('app.string.updating') : $r('app.string.update_action'))
                .fontSize(12.5)
                .fontWeight(600)
                .fontColor($r('app.color.mono'))
                .padding({ left: 8, top: 12, bottom: 12 })
                .onClick(() => this.updateOneSubscription(sub))
              Text($r('app.string.delete'))
                .fontSize(12.5)
                .fontWeight(600)
                .fontColor($r('app.color.error'))
                .padding({ left: 8, top: 12, bottom: 12 })
                .onClick(() => this.deleteSubscription(sub))

            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
          }
        }, (sub: SubInfo) => sub.url)
        ForEach(this.sortedGroupIds(), (groupId: string) => {
          ListItem() {
            Column() {
              Row() {
                Text(this.groupName(groupId))
                  .fontSize(11)
                  .fontWeight(700)
                  .fontColor($r('app.color.text_3'))
                  .letterSpacing(2)
                  .layoutWeight(1)
                Text(this.groupLatencyText(groupId))
                  .fontSize(11)
                  .fontColor($r('app.color.text_3'))
                Text(this.testing ? $r('app.string.speed_testing') : $r('app.string.test_group'))
                  .fontSize(11)
                  .fontColor($r('app.color.mono'))
                  .padding({ left: 10, top: 8, bottom: 8 })
                  .onClick(() => this.runGroupSpeedTest(groupId))
              }
              .width('100%')
              .padding({ top: 14, bottom: 4 })
              .onClick(() => {
                if (groupId.length > 0) {
                  const group = this.groups.find((item: ProfileGroup) => item.id === groupId);
                  if (group !== undefined) {
                    void this.toggleGroupCollapsed(group);
                  }
                }
              })


              if (!this.isGroupCollapsed(groupId)) {
                ForEach(this.visibleProfiles(groupId), (profile: Profile) => {
                Row({ space: 10 }) {
                  Text('●')
                    .fontSize(9)
                    .fontColor($r('app.color.text_3'))
                  Text(profile.name)
                    .fontSize(14.5)
                    .fontWeight(this.selectedId === profile.id ? 800 : 600)
                    .fontColor($r('app.color.text_1'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(this.latencyText(profile).toString().length === 0 ? '—' : this.latencyText(profile))
                    .fontSize(12.5)
                    .fontColor($r('app.color.text_2'))
                  if (this.selectedId === profile.id) {
                    Text('✓')
                      .fontSize(15)
                      .fontWeight(800)
                      .fontColor($r('app.color.success'))
                  }
                }
                .width('100%')
                .height(UiSpec.ROW_HEIGHT)
                .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
                .onClick(() => this.onNodeTap(profile))
                .bindContextMenu(this.profileContextMenu(profile), ResponseType.LongPress)
                }, (profile: Profile) => profile.id)
              }
            }
            .width('100%')
          }
        }, (groupId: string) => groupId)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
    }
    .width('100%')
    .height('100%')
  }

  private uptimeText(): string {
    const hours = Math.floor(this.uiUptime / 3600);
    const minutes = Math.floor((this.uiUptime % 3600) / 60);
    const seconds = this.uiUptime % 60;
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `${pad(hours)}:${pad(minutes)}:${pad(seconds)}`;
  }

  private selectedProfile(): Profile | undefined {
    return this.profiles.find((profile: Profile) => profile.id === this.selectedId);
  }

  private visibleProfiles(groupId: string): Array<Profile> {
    const query = this.nodeSearch.trim().toLowerCase();
    const profiles = this.profilesInGroup(groupId).filter((profile: Profile) =>
      this.activeConfigUrl.length === 0 || profile.subUrl === this.activeConfigUrl);
    if (query.length === 0) {
      return profiles;
    }
    return profiles.filter((profile: Profile) =>
      profile.name.toLowerCase().includes(query)
      || profile.server.toLowerCase().includes(query));
  }

  @Builder
  private bottomNavigation() {
    if (!this.usesSidebar()) {
    Row() {
      BottomNavText({
        label: $r('app.string.home'),
        selected: this.activeTab === 0,
        onSelect: () => { this.activeTab = 0; }
      })
      BottomNavText({
        label: $r('app.string.subscription_management'),
        selected: this.activeTab === 1,
        onSelect: () => { this.activeTab = 1; }
      })
      BottomNavText({
        label: $r('app.string.settings_title'),
        selected: this.activeTab === 2,
        onSelect: () => { this.activeTab = 2; }
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    }
  }

  @Builder
  private wideNavigation() {
    Column({ space: 24 }) {
      Text($r('app.string.brand_name'))
        .fontSize(12)
        .fontWeight(800)
        .fontColor($r('app.color.text_1'))
        .letterSpacing(3)
        .width('100%')
      Text($r('app.string.home'))
        .fontSize(14)
        .fontWeight(this.activeTab === 0 ? 800 : 400)
        .fontColor(this.activeTab === 0 ? $r('app.color.mono') : $r('app.color.text_3'))
        .width('100%')
        .onClick(() => { this.activeTab = 0; })
      Text($r('app.string.subscription_management'))
        .fontSize(14)
        .fontWeight(this.activeTab === 1 ? 800 : 400)
        .fontColor(this.activeTab === 1 ? $r('app.color.mono') : $r('app.color.text_3'))
        .width('100%')
        .onClick(() => { this.activeTab = 1; })
      Text($r('app.string.settings_title'))
        .fontSize(14)
        .fontWeight(this.activeTab === 2 ? 800 : 400)
        .fontColor(this.activeTab === 2 ? $r('app.color.mono') : $r('app.color.text_3'))
        .width('100%')
        .onClick(() => { this.activeTab = 2; })
      Blank()
    }
    .width(this.uiBreakpoint === 'large' ? UiSpec.SIDEBAR_WIDTH_LARGE : UiSpec.SIDEBAR_WIDTH_MEDIUM)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 24, right: 18, top: 30, bottom: 24 })
    .border({ width: { right: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
  }

  @Builder
  private activeContent() {
    if (this.activeTab === 0) {
      this.homeTab()
    } else if (this.activeTab === 1) {
      this.subscriptionsTab()
    } else {
      SettingsPage({
        onSettingsChanged: (settings: AppSettings) => {
          this.settings = settings;
          AppStorage.setOrCreate('uiNavLayout', settings.navLayout);
        }
      })
    }
  }

  @Builder
  private homeTab() {
    Column() {
      Row() {
        Text($r('app.string.brand_name'))
          .fontSize(12)
          .fontWeight(800)
          .fontColor($r('app.color.text_1'))
          .letterSpacing(3)
          .layoutWeight(1)
        Text($r('app.string.connect'))
          .fontSize(13.5)
          .fontWeight(600)
          .fontColor($r('app.color.text_3'))
          .padding(8)
          .onClick(() => router.pushUrl({ url: 'pages/ConnectionsPage' }))
        Text($r('app.string.logs'))
          .fontSize(13.5)
          .fontWeight(600)
          .fontColor($r('app.color.text_3'))
          .padding(8)
          .onClick(() => router.pushUrl({ url: 'pages/LogPage' }))
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 26 })

      Text(this.isRunning ? this.uptimeText() : '00:00:00')
        .fontSize(UiSpec.CLOCK_SIZE)
        .fontWeight(300)
        .fontColor($r('app.color.text_1'))
        .fontFamily('monospace')
        .letterSpacing(2)
        .margin({ top: 44 })

      Row({ space: 8 }) {
        Circle()
          .width(8)
          .height(8)
          .fill(this.isRunning ? $r('app.color.dot_live') : $r('app.color.text_3'))
        Text(this.statusDisplay())
          .fontSize(13.5)
          .fontColor($r('app.color.text_2'))
        Text('·')
          .fontSize(13.5)
          .fontColor($r('app.color.text_3'))
        Text(this.modeLabel())
          .fontSize(13.5)
          .fontColor($r('app.color.text_2'))
      }
      .margin({ top: 10 })

      BigPowerButton({
        running: this.isRunning,
        connecting: this.statusText === 'connecting' || this.statusText === 'switching',
        breakpoint: this.uiBreakpoint,
        onToggle: () => {
          if (this.isRunning) {
            this.disconnect();
            return;
          }
          const target = this.selectedProfile();
          if (target === undefined) {
            promptAction.showToast({ message: $r('app.string.select_or_create_profile') });
            return;
          }
          this.connectTo(target);
        }
      })
        .margin({ top: 38 })

      if (this.selectedProfile() !== undefined) {
        Row({ space: 6 }) {
          Text('●')
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
          Text(this.selectedProfile()?.name ?? '')
            .fontSize(13.5)
            .fontWeight(600)
            .fontColor($r('app.color.text_1'))
          Text(this.latencyText(this.selectedProfile() as Profile))
            .fontSize(13.5)
            .fontColor($r('app.color.text_2'))
        }
        .margin({ top: 34 })
        .onClick(() => { this.activeTab = 1; })
      }

      Blank()

      StatsRow({
        upload: this.isRunning ? formatSpeed(this.upSpeed) : '—',
        download: this.isRunning ? formatSpeed(this.downSpeed) : '—',
        traffic: this.isRunning ? formatBytes(this.totalUp + this.totalDown) : '—'
      })
        .margin({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
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
      AppStorage.setOrCreate('uiNavLayout', this.settings.navLayout);
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

  /** 点击节点:未运行则选中;运行中点其他节点 = 自动断开重连切换 */
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
        this.activeConfigUrl = subUrl;
        await writePrefString('active_config_url', subUrl);
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
      MenuItem({ content: $r('app.string.profile_edit_title') })
        .onClick(() => {
          AppStorage.setOrCreate('editProfileId', p.id);
          router.pushUrl({ url: 'pages/ProfileEdit' });
        })
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
      if (!this.usesSidebar()) {
        Column() {
          this.activeContent()
        }
        .width('100%')
        .layoutWeight(1)
        this.bottomNavigation()
      } else {
        Row() {
          this.wideNavigation()
          Column() {
            this.activeContent()
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}

/** 分享降级弹窗:SDK 未提供 generateBarcode 时展示 URI 并支持复制。 */

@CustomDialog
struct SubscriptionGroupDialog {
  controller?: CustomDialogController;
  @Link name: string;
  @Link group: string;
  onSaved: (name: string, group: string) => void = (_name: string, _group: string) => {};

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.sub_group_dialog_title'))
        .fontSize(16)
        .fontWeight(600)
        .width('100%')
      TextInput({ text: this.name, placeholder: $r('app.string.subscription_name_optional') })
        .width('100%')
        .onChange((value: string) => { this.name = value; })
      TextInput({ text: this.group, placeholder: $r('app.string.sub_group_hint') })
        .width('100%')
        .onChange((value: string) => { this.group = value; })
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button($r('app.string.save'))
          .layoutWeight(1)
          .onClick(() => {
            this.onSaved(this.name, this.group);
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')
    }
    .padding(UiSpec.PAGE_PADDING)
    .width('100%')
  }
}
@CustomDialog
struct ShareTextDialog {
  controller?: CustomDialogController;
  @Link text: string;
  onCopy: (text: string) => void = (text: string) => {};

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.share_link_title'))
        .fontSize(16)
        .fontWeight(700)
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
