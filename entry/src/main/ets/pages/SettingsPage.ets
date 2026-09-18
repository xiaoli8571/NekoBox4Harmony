import common from '@ohos.app.ability.common';
import bundle from '@ohos.bundle';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { DrawerButton } from '../common/components/DrawerButton';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { AppSettings } from '../model/Profile';
import { initStore, loadSettings, saveSettings, LogStore } from '../model/Store';
import { geoReady, downloadGeoAssets, importGeoAssetFromFile, geoAssetInfos, downloadGeoAsset, deleteGeoAsset, GeoAssetInfo } from '../utils/GeoAssets';
import { formatBytes } from '../utils/TrafficStats';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { VpnService } from '../core/VpnService';
import window from '@ohos.window';

const APP_MODES: Array<string> = ['off', 'exclude', 'include'];
const APP_MODE_LABELS: Array<Resource> = [$r('app.string.per_app_off'), $r('app.string.per_app_exclude'), $r('app.string.per_app_include')];

const STACKS: Array<string> = ['system'];
const MODES: Array<string> = ['rule', 'global', 'direct'];
const MODE_LABELS: Array<Resource> = [$r('app.string.mode_rule'), $r('app.string.mode_global'), $r('app.string.mode_direct')];
const MODE_SWITCH_TOASTS: Array<Resource> = [$r('app.string.settings_mode_switched_rule'), $r('app.string.settings_mode_switched_global'), $r('app.string.settings_mode_switched_direct')];
const LOG_LEVELS: Array<string> = ['trace', 'debug', 'info', 'warn', 'error'];
const SNIFF_MODES: Array<string> = ['off', 'route', 'override'];
const LATENCY_TEST_VALUES: Array<string> = ['url', 'tcp'];
const LATENCY_TEST_LABELS: Array<Resource> = [$r('app.string.latency_test_url'), $r('app.string.latency_test_tcp')];
const SNIFF_LABELS: Array<Resource> = [$r('app.string.sniff_off'), $r('app.string.sniff_route'), $r('app.string.sniff_override')];
const STRATEGIES: Array<string> = ['', 'auto', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'];
const STRATEGY_LABELS: Array<Resource> = [$r('app.string.strategy_default'), $r('app.string.strategy_auto'), $r('app.string.strategy_prefer_ipv4'), $r('app.string.strategy_prefer_ipv6'), $r('app.string.strategy_ipv4_only'), $r('app.string.strategy_ipv6_only')];
// Android IPv6Mode 四档(values/arrays.xml ipv6_mode)
const IPV6_MODES: Array<string> = ['disable', 'enable', 'prefer', 'only'];
const IPV6_MODE_LABELS: Array<Resource> = [$r('app.string.ipv6_mode_disable'), $r('app.string.ipv6_mode_enable'), $r('app.string.ipv6_mode_prefer'), $r('app.string.ipv6_mode_only')];

class InstalledAppItem {
  bundleName: string = '';
  label: string = '';

  constructor(bundleName: string, label: string) {
    this.bundleName = bundleName;
    this.label = label;
  }
}

@Component
export struct SettingsPage {
  @State s: AppSettings = new AppSettings();
  @State geoOk: boolean = false;
  @State geoLoading: boolean = false;
  @State geoInfos: Array<GeoAssetInfo> = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State installedApps: Array<InstalledAppItem> = [];
  @State appSearch: string = '';
  @State appListLoading: boolean = false;
  @State appListError: ResourceStr = '';
  @State dirty: boolean = false;
  @State proxyExpanded: boolean = false;
  @State generalExpanded: boolean = false;
  @State networkExpanded: boolean = false;
  @State dnsExpanded: boolean = false;
  @State inboundExpanded: boolean = false;
  @State appearanceExpanded: boolean = false;
  @State apiExpanded: boolean = false;
  @State perAppExpanded: boolean = false;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onSettingsChanged: (settings: AppSettings) => void = (_settings: AppSettings) => {};
  onOpenDrawer: () => void = () => {};

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      await initStore(this.context);
      this.s = await loadSettings();
      this.dirty = false;
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  private refreshGeoInfos(): void {
    this.geoInfos = geoAssetInfos(this.context);
  }

  async downloadGeo(): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    promptAction.showToast({ message: $r('app.string.geo_downloading') });
    try {
      await downloadGeoAssets(this.context);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({ message: $r('app.string.geo_download_complete') });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.download_failed_reason', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  /** 单库更新(对齐安卓资产列表点击单库更新) */
  async downloadSingleGeo(kind: string): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    try {
      await downloadGeoAsset(this.context, kind);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({
        message: $r('app.string.settings_geo_updated', kind === 'site' ? 'geosite-cn.db' : 'geoip-cn.db')
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.download_failed_reason', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  /** 删除单库(对齐安卓资产左滑删除;二次确认) */
  confirmDeleteGeo(info: GeoAssetInfo): void {
    AlertDialog.show({
      message: $r('app.string.settings_geo_delete_confirm', info.fileName),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: () => {
          try {
            deleteGeoAsset(this.context, info.kind);
            this.geoOk = geoReady(this.context);
            this.refreshGeoInfos();
            promptAction.showToast({ message: $r('app.string.settings_geo_deleted', info.fileName) });
          } catch (e) {
            const msg = e instanceof Error ? e.message : `${e}`;
            promptAction.showToast({ message: $r('app.string.settings_geo_delete_failed', msg) });
          }
        }
      }
    });
  }

  /** 导入用户自选的 geo .db(对齐安卓 AssetsActivity 的 action_import_file) */
  async importGeo(): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    try {
      const path = await importGeoAssetFromFile(this.context);
      if (path === null) {
        // 用户取消选择,不报错
        return;
      }
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({ message: $r('app.string.geo_import_complete', path) });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.geo_import_failed', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  modeIndex(): number {
    const i = MODES.indexOf(this.s.mode);
    return i < 0 ? 0 : i;
  }

  private colorToString(color: number): string {
    return `#${(color >>> 0).toString(16).padStart(8, '0').toUpperCase()}`;
  }

  private async applyAppearance(): Promise<void> {
    try {
      await saveSettings(this.s);
      this.dirty = false;
      const colorMode = this.s.appearance === 'dark'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : (this.s.appearance === 'light'
          ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      this.context.setColorMode(colorMode);

      const mainWindow = await window.getLastWindow(this.context);
      const background = this.context.resourceManager.getColorSync($r('app.color.app_background'));
      const red = (background >> 16) & 0xFF;
      const green = (background >> 8) & 0xFF;
      const blue = background & 0xFF;
      const darkBackground = (red * 299 + green * 587 + blue * 114) / 1000 < 128;
      const backgroundColor = this.colorToString(background);
      const contentColor = darkBackground
        ? UiSpec.STATUS_BAR_CONTENT_DARK_BG
        : UiSpec.STATUS_BAR_CONTENT_LIGHT_BG;
      mainWindow.setWindowBackgroundColor(backgroundColor);
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: backgroundColor,
        navigationBarColor: backgroundColor,
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
      this.onSettingsChanged(this.s);
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 即时应用主题失败: ${message}`);
      promptAction.showToast({ message: $r('app.string.save_failed_reason', message) });
    }
  }

  private markDirty(): void {
    this.dirty = true;
  }

  async save(quiet: boolean = false): Promise<void> {
    try {
      await saveSettings(this.s);
      this.dirty = false;
      this.onSettingsChanged(this.s);
      if (!quiet) {
        promptAction.showToast({ message: $r('app.string.saved_reconnect_vpn') });
      }
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.save_failed_reason', e instanceof Error ? e.message : `${e}`) });
    }
  }

  private async switchMode(mode: string, toast: Resource): Promise<void> {
    if (this.s.mode === mode) {
      return;
    }
    this.s.mode = mode;
    try {
      await saveSettings(this.s);
      this.dirty = false;
      this.onSettingsChanged(this.s);
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

  private selectedAppSet(): Set<string> {
    const result = new Set<string>();
    const parts = this.s.perAppList.split(',');
    for (const part of parts) {
      const bundleName = part.trim();
      if (bundleName.length > 0) {
        result.add(bundleName);
      }
    }
    return result;
  }

  private isAppSelected(bundleName: string): boolean {
    return this.selectedAppSet().has(bundleName);
  }

  private toggleInstalledApp(bundleName: string, selected: boolean): void {
    const chosen = this.selectedAppSet();
    if (selected) {
      chosen.add(bundleName);
    } else {
      chosen.delete(bundleName);
    }
    this.s.perAppList = Array.from(chosen).sort().join(',');
    this.markDirty();
  }

  private filteredInstalledApps(): Array<InstalledAppItem> {
    const query = this.appSearch.trim().toLowerCase();
    if (query.length === 0) {
      return this.installedApps;
    }
    return this.installedApps.filter((item: InstalledAppItem) =>
      item.label.toLowerCase().includes(query) || item.bundleName.toLowerCase().includes(query));
  }

  /** 反选已加载的应用(对齐安卓 action_invert_selections) */
  async invertAppSelections(): Promise<void> {
    const chosen = this.selectedAppSet();
    for (const item of this.installedApps) {
      if (chosen.has(item.bundleName)) {
        chosen.delete(item.bundleName);
      } else {
        chosen.add(item.bundleName);
      }
    }
    this.s.perAppList = Array.from(chosen).sort().join(',');
    await this.persistPerAppList('反选应用列表');
  }

  /** 清除全部已选应用(对齐安卓 action_clear_selections) */
  async clearAppSelections(): Promise<void> {
    if (this.s.perAppList.length === 0) {
      return;
    }
    this.s.perAppList = '';
    await this.persistPerAppList('清除应用列表');
  }

  /**
   * 导出已选应用列表到剪贴板(对齐安卓 AppListActivity.action_export_clipboard):
   * 格式为 "false\n<包名,逗号分隔>"(首行 false = 非 bypass 语义标记)。
   */
  async exportAppListToClipboard(): Promise<void> {
    const payload = `false\n${this.s.perAppList}`;
    try {
      await setClipboardText(payload);
      promptAction.showToast({ message: $r('app.string.action_export_msg') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.action_export_err') });
    }
  }

  /**
   * 从剪贴板导入应用列表(对齐安卓 action_import_clipboard):
   * 期望 "false\n<包名列表>" 格式;无换行则报错,有换行取首行之后全部。
   */
  async importAppListFromClipboard(): Promise<void> {
    const clip = await getClipboardText();
    const nl = clip.indexOf('\n');
    if (clip.trim().length === 0 || nl < 0) {
      promptAction.showToast({ message: $r('app.string.action_import_err') });
      return;
    }
    const apps = clip.substring(nl + 1).trim();
    this.s.perAppList = apps;
    await this.persistPerAppList('从剪贴板导入应用列表');
    promptAction.showToast({ message: $r('app.string.action_import_msg') });
  }

  private async persistPerAppList(reason: string): Promise<void> {
    this.markDirty();
    await this.save(true);
    const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
    const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (running && profileId.length > 0) {
      LogStore.addLog(`[ui] ${reason}，自动重启 VPN 使配置生效`);
      await VpnService.switchTo(this.context, profileId);
    }
  }

  async loadInstalledApps(): Promise<void> {
    if (this.appListLoading) {
      return;
    }
    this.appListLoading = true;
    this.appListError = '';
    try {
      const infos = await bundle.getAllBundleInfo(bundle.BundleFlag.GET_BUNDLE_DEFAULT);
      const apps: Array<InstalledAppItem> = [];
      for (const info of infos) {
        const bundleName: string = info.name;
        const label: string = info.appInfo === undefined || info.appInfo.label.length === 0
          ? bundleName : info.appInfo.label;
        apps.push(new InstalledAppItem(bundleName, label));
      }
      apps.sort((a: InstalledAppItem, b: InstalledAppItem) => a.label.localeCompare(b.label));
      this.installedApps = apps;
      if (apps.length === 0) {
        this.appListError = $r('app.string.no_installed_apps_manual');
      }
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      this.installedApps = [];
      this.appListError = $r('app.string.app_list_failed_reason', message);
      LogStore.addLog(`[ui] 枚举已安装应用失败，降级为手动输入: ${message}`);
    } finally {
      this.appListLoading = false;
    }
  }

  /** FlClash 式可折叠分组章节头:图标 + 小标题 + 展开状态 + 下缘 hairline */
  @Builder
  private sectionHeader(icon: string, title: ResourceStr, expanded: boolean, onToggle: () => void) {
    Row({ space: 10 }) {
      Text(icon)
        .fontSize(15)
        .fontColor($r('app.color.mono'))
        .width(24)
        .textAlign(TextAlign.Center)
      Text(title)
        .fontSize(12)
        .fontWeight(700)
        .fontColor($r('app.color.text_3'))
        .letterSpacing(2)
        .layoutWeight(1)
      Text(expanded ? '⌃' : '⌄')
        .fontSize(14)
        .fontColor($r('app.color.text_3'))
    }
    .width('100%')
    .padding({ top: 14, bottom: 6 })
    .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
    .onClick(onToggle)
  }

  build() {
    Column() {
      Row() {
        DrawerButton({ onOpen: () => this.onOpenDrawer() })
        Text($r('app.string.settings_title'))
          .fontSize(18)
          .fontWeight(700)
          .layoutWeight(1)
        Button($r('app.string.save'))
          .height(34)
          .enabled(this.dirty)
          .backgroundColor(this.dirty ? $r('app.color.primary') : $r('app.color.control_disabled'))
          .fontColor($r('app.color.surface'))
          .onClick(() => this.save())
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 24, bottom: 12 })
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.primary'))
          Text($r('app.string.loading_settings'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      } else if (this.loadError.length > 0) {
        Column({ space: 8 }) {
          Text($r('app.string.settings_load_failed'))
            .fontSize(16)
            .fontWeight(500)
            .fontColor($r('app.color.text_primary'))
          Text(this.loadError)
            .fontSize(13)
            .fontColor($r('app.color.error'))
          Button($r('app.string.reload'))
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => this.load())
        }
        .width('100%')
        .padding({ top: 28, bottom: 20 })
      }

      Scroll() {
        Column({ space: 14 }) {
          // 常规(对齐 Android General 组)
          this.sectionHeader('✦', $r('app.string.settings_general'), this.generalExpanded, () => { this.generalExpanded = !this.generalExpanded; })
          if (this.generalExpanded) {
          Column({ space: 8 }) {
            Row() {
              Column() {
                Text($r('app.string.settings_auto_connect')).fontSize(14)
                Text($r('app.string.settings_auto_connect_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.autoConnect })
                .onChange((v: boolean) => {
                  this.s.autoConnect = v;
                  this.markDirty();
                })
            }.width('100%')

            Column() {
              Text($r('app.string.settings_log_level')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(LOG_LEVELS.map((t: string) => ({ value: t } as SelectOption)))
                .selected(LOG_LEVELS.indexOf(this.s.logLevel) < 0 ? 2 : LOG_LEVELS.indexOf(this.s.logLevel))
                .value(this.s.logLevel)
                .onSelect((index: number) => {
                  this.s.logLevel = LOG_LEVELS[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.latency_test_mode')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(LATENCY_TEST_LABELS.map((t: Resource, i: number) => ({ value: t } as SelectOption)))
                .selected(LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode) < 0 ? 0 : LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode))
                .value(LATENCY_TEST_LABELS[LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode) < 0 ? 0 : LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode)])
                .onSelect((index: number) => {
                  this.s.latencyTestMode = LATENCY_TEST_VALUES[index];
                  this.markDirty();
                })
              Text($r('app.string.latency_test_mode_desc'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_test_url')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.testUrl })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.testUrl = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_test_url_desc'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_test_concurrent')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: `${this.s.testConcurrent}` })
                .type(InputType.Number).width('100%').height(40)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  this.s.testConcurrent = isNaN(n) ? 5 : Math.max(1, Math.min(20, n));
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_global_custom_config')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextArea({ text: this.s.globalCustomConfig, placeholder: '{"log":{"level":"info"}}' })
                .height(90)
                .fontSize(12)
                .fontFamily('monospace')
                .width('100%')
                .onChange((v: string) => {
                  this.s.globalCustomConfig = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_global_custom_config_desc'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Row() {
              Text($r('app.string.settings_always_show_address')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.alwaysShowAddress })
                .onChange((v: boolean) => {
                  this.s.alwaysShowAddress = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Text($r('app.string.show_bottom_bar')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.showBottomBar })
                .onChange((v: boolean) => {
                  this.s.showBottomBar = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Text($r('app.string.settings_notification_group')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.notificationGroup })
                .onChange((v: boolean) => {
                  this.s.notificationGroup = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.settings_speed_interval')).fontSize(14).width('100%')
                Text($r('app.string.settings_speed_interval_sum'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              TextInput({ text: `${this.s.speedIntervalMs}`, placeholder: '1000' })
                .type(InputType.Number).width(110).height(36)
                .onChange((v: string) => {
                  const n = parseInt(v, 10);
                  this.s.speedIntervalMs = isNaN(n) ? 1000 : n;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_insecure_tls')).fontSize(14)
                Text($r('app.string.settings_insecure_tls_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.allowInsecureAll })
                .onChange((v: boolean) => {
                  this.s.allowInsecureAll = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_sub_allow_insecure')).fontSize(14)
                Text($r('app.string.settings_sub_allow_insecure_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.subAllowInsecure })
                .onChange((v: boolean) => {
                  this.s.subAllowInsecure = v;
                  this.markDirty();
                })
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // 路由
          this.sectionHeader('▤', $r('app.string.settings_route'), this.networkExpanded, () => { this.networkExpanded = !this.networkExpanded; })
          if (this.networkExpanded) {
          if (this.s.mode === 'rule') {
            Column() {
              Text($r('app.string.settings_direct_domain_suffix')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.directDomains, placeholder: 'baidu.com,qq.com,163.com' })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.directDomains = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_direct_cidr')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
                .margin({ top: 6 })
              TextInput({ text: this.s.directIpCidrs, placeholder: '114.114.114.114/32' })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.directIpCidrs = v;
                  this.markDirty();
                })
              Row({ space: 8 }) {
                Text(this.geoOk ? $r('app.string.settings_geo_ready')
                  : $r('app.string.settings_geo_missing'))
                  .fontSize(12).fontColor(this.geoOk ? $r('app.color.success') : $r('app.color.text_secondary')).layoutWeight(1)
                Button(this.geoLoading ? $r('app.string.settings_geo_downloading') : (this.geoOk ? $r('app.string.settings_geo_redownload') : $r('app.string.settings_geo_download')))
                  .height(30)
                  .backgroundColor(this.geoLoading ? $r('app.color.control_disabled') : $r('app.color.primary'))
                  .onClick(() => this.downloadGeo())
              }.width('100%').margin({ top: 6 })
              Row({ space: 8 }) {
                Text($r('app.string.settings_geo_import_hint'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                Button($r('app.string.settings_geo_import'))
                  .height(30)
                  .backgroundColor($r('app.color.surface'))
                  .fontColor($r('app.color.text_primary'))
                  .enabled(!this.geoLoading)
                  .onClick(() => { void this.importGeo(); })
              }.width('100%').margin({ top: 4 })

              // 资产列表(对齐安卓 AssetsActivity:每库名称/大小/版本 + 单库更新/删除)
              ForEach(this.geoInfos, (info: GeoAssetInfo) => {
                Row({ space: 8 }) {
                  Text(info.kind === 'site' ? $r('app.string.settings_geo_site') : $r('app.string.settings_geo_ip'))
                    .fontSize(12).fontColor($r('app.color.text_primary'))
                  Text(info.size > 0
                    ? $r('app.string.geo_asset_status', formatBytes(info.size), info.version)
                    : $r('app.string.geo_asset_absent'))
                    .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                  Button(this.geoLoading ? $r('app.string.settings_geo_downloading') : $r('app.string.settings_geo_update_one'))
                    .height(28)
                    .fontSize(12)
                    .backgroundColor(this.geoLoading ? $r('app.color.control_disabled') : $r('app.color.primary'))
                    .enabled(!this.geoLoading)
                    .onClick(() => { void this.downloadSingleGeo(info.kind); })
                  if (info.size > 0) {
                    Button($r('app.string.settings_geo_delete'))
                      .height(28)
                      .fontSize(12)
                      .backgroundColor($r('app.color.surface'))
                      .fontColor($r('app.color.error'))
                      .enabled(!this.geoLoading)
                      .onClick(() => this.confirmDeleteGeo(info))
                  }
                }.width('100%').margin({ top: 4 })
              }, (info: GeoAssetInfo) => `${info.kind}_${info.size}_${info.version}`)
            }.alignItems(HorizontalAlign.Start).width('100%')
          }

          Blank().height(2)

          Column() {
            Text($r('app.string.settings_tun_mtu')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: `${this.s.mtu}`, placeholder: '9000' })
              .type(InputType.Number).width('100%').height(40)
              .onChange((v: string) => {
                const n = parseInt(v);
                this.s.mtu = isNaN(n) ? 9000 : n;
                this.markDirty();
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text($r('app.string.settings_tun_stack')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Select(STACKS.map((t: string) => ({ value: t } as SelectOption)))
              .selected(STACKS.indexOf(this.s.stack) < 0 ? 0 : STACKS.indexOf(this.s.stack))
              .value(this.s.stack)
              .onSelect((index: number) => {
                this.s.stack = STACKS[index];
                this.markDirty();
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text($r('app.string.settings_enable_ipv6')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Select(IPV6_MODES.map((t: string, i: number) => ({ value: IPV6_MODE_LABELS[i] } as SelectOption)))
              .selected(IPV6_MODES.indexOf(this.s.ipv6Mode) < 0 ? (this.s.ipv6 ? 1 : 0) : IPV6_MODES.indexOf(this.s.ipv6Mode))
              .value(IPV6_MODE_LABELS[(IPV6_MODES.indexOf(this.s.ipv6Mode) < 0 ? (this.s.ipv6 ? 1 : 0) : IPV6_MODES.indexOf(this.s.ipv6Mode))])
              .onSelect((index: number) => {
                this.s.ipv6Mode = IPV6_MODES[index];
                this.markDirty();
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Row() {
            Column() {
              Text($r('app.string.settings_bypass_lan')).fontSize(14)
              Text($r('app.string.settings_bypass_lan_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.bypassLan })
              .onChange((v: boolean) => {
                this.s.bypassLan = v;
                this.markDirty();
              })
          }.width('100%')

          Column() {
            Text($r('app.string.settings_sniff')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Row({ space: 8 }) {
              ForEach(SNIFF_MODES, (m: string, idx: number) => {
                Button(SNIFF_LABELS[idx])
                  .layoutWeight(1)
                  .height(34)
                  .backgroundColor(this.s.sniffMode === m ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.sniffMode === m ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .onClick(() => {
                    this.s.sniffMode = m;
                    this.markDirty();
                  })
              }, (m: string) => m)
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Row() {
            Column() {
              Text($r('app.string.settings_resolve_destination')).fontSize(14)
              Text($r('app.string.settings_resolve_destination_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.resolveDestination })
              .onChange((v: boolean) => {
                this.s.resolveDestination = v;
                this.markDirty();
              })
          }.width('100%')

          Blank().height(2)

          }

          // DNS(对齐 Android DNS 组)
          this.sectionHeader('◎', $r('app.string.settings_dns'), this.dnsExpanded, () => { this.dnsExpanded = !this.dnsExpanded; })
          if (this.dnsExpanded) {
          Column({ space: 8 }) {
            Column() {
              Text($r('app.string.settings_remote_dns')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.remoteDns })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.remoteDns = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_remote_dns_hint'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_remote_dns_strategy')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)))
                .selected(STRATEGIES.indexOf(this.s.remoteDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.remoteDnsStrategy))
                .value(STRATEGY_LABELS[STRATEGIES.indexOf(this.s.remoteDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.remoteDnsStrategy)])
                .onSelect((index: number) => {
                  this.s.remoteDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_direct_dns')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.directDns })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.directDns = v;
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_direct_dns_strategy')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)))
                .selected(STRATEGIES.indexOf(this.s.directDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.directDnsStrategy))
                .value(STRATEGY_LABELS[STRATEGIES.indexOf(this.s.directDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.directDnsStrategy)])
                .onSelect((index: number) => {
                  this.s.directDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_server_dns_strategy')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)))
                .selected(STRATEGIES.indexOf(this.s.serverDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.serverDnsStrategy))
                .value(STRATEGY_LABELS[STRATEGIES.indexOf(this.s.serverDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.serverDnsStrategy)])
                .onSelect((index: number) => {
                  this.s.serverDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
              Text($r('app.string.settings_server_dns_strategy_hint'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_dns_routing')).fontSize(14)
                Text($r('app.string.settings_dns_routing_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.dnsRouting })
                .onChange((v: boolean) => {
                  this.s.dnsRouting = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_fakedns')).fontSize(14)
                Text($r('app.string.settings_fakedns_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.fakeDns })
                .onChange((v: boolean) => {
                  this.s.fakeDns = v;
                  this.markDirty();
                })
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // 入站(对齐 Android Inbound 组)
          this.sectionHeader('⇄', $r('app.string.settings_inbound'), this.inboundExpanded, () => { this.inboundExpanded = !this.inboundExpanded; })
          if (this.inboundExpanded) {
          Column({ space: 8 }) {
            Column() {
              Text($r('app.string.settings_mixed_port')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: `${this.s.mixedPort > 0 ? this.s.mixedPort : ''}`, placeholder: $r('app.string.settings_mixed_port_hint') })
                .type(InputType.Number).width('100%').height(40)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  this.s.mixedPort = isNaN(n) ? 0 : Math.max(0, Math.min(65535, n));
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_allow_access')).fontSize(14)
                Text($r('app.string.settings_allow_access_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.allowAccess })
                .onChange((v: boolean) => {
                  this.s.allowAccess = v;
                  this.markDirty();
                })
            }.width('100%')
            Text($r('app.string.settings_reconnect_note'))
              .fontSize(12).fontColor($r('app.color.error')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // 外观与交互
          this.sectionHeader('◐', $r('app.string.appearance_and_interaction'), this.appearanceExpanded, () => { this.appearanceExpanded = !this.appearanceExpanded; })
          if (this.appearanceExpanded) {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              ForEach(['system', 'light', 'dark'], (mode: string) => {
                Button(mode === 'system' ? $r('app.string.appearance_follow_system') : (mode === 'light' ? $r('app.string.appearance_light') : $r('app.string.appearance_dark')))
                  .layoutWeight(1)
                  .backgroundColor(this.s.appearance === mode ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.appearance === mode ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .onClick(() => {
                    this.s.appearance = mode;
                    this.applyAppearance();
                    this.markDirty();
                  })
              }, (mode: string) => mode)
            }.width('100%')
            Text($r('app.string.profile_sort_mode')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Row({ space: 8 }) {
              ForEach(['manual', 'latency', 'name'], (mode: string) => {
                Button(mode === 'manual' ? $r('app.string.sort_manual') : (mode === 'latency' ? $r('app.string.sort_latency') : $r('app.string.sort_name')))
                  .layoutWeight(1)
                  .backgroundColor(this.s.profileSortMode === mode ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.profileSortMode === mode ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .onClick(() => {
                    this.s.profileSortMode = mode;
                    this.markDirty();
                  })
              }, (mode: string) => mode)
            }.width('100%')
            Row() {
              Text($r('app.string.haptic_feedback')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.hapticFeedback })
                .onChange((v: boolean) => {
                  this.s.hapticFeedback = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Text($r('app.string.liquid_glass')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.liquidGlass })
                .onChange((v: boolean) => {
                  this.s.liquidGlass = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.network_change_reset_connections')).fontSize(14).width('100%')
                Text($r('app.string.network_change_reset_connections_sum'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.networkChangeResetConnections })
                .onChange((v: boolean) => {
                  this.s.networkChangeResetConnections = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.wake_reset_connections')).fontSize(14).width('100%')
                Text($r('app.string.wake_reset_connections_sum'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.wakeResetConnections })
                .onChange((v: boolean) => {
                  this.s.wakeResetConnections = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.profile_traffic_statistics')).fontSize(14).width('100%')
                Text($r('app.string.profile_traffic_statistics_sum'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.profileTrafficStatistics })
                .onChange((v: boolean) => {
                  this.s.profileTrafficStatistics = v;
                  this.markDirty();
                })
            }.width('100%')
            Text($r('app.string.settings_theme_note'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // Clash API 连接统计
          this.sectionHeader('☰', $r('app.string.clash_api_settings'), this.apiExpanded, () => { this.apiExpanded = !this.apiExpanded; })
          if (this.apiExpanded) {
          Column({ space: 8 }) {
            Row() {
              Text($r('app.string.clash_api_enabled')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.clashApiEnabled })
                .onChange((value: boolean) => {
                  this.s.clashApiEnabled = value;
                  this.markDirty();
                })
            }.width('100%')
            Column() {
              Text($r('app.string.clash_api_port')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: `${this.s.clashApiPort}` })
                .width('100%')
                .height(40)
                .type(InputType.Number)
                .onChange((value: string) => {
                  const port = parseInt(value);
                  if (!isNaN(port)) {
                    this.s.clashApiPort = Math.max(1024, Math.min(65535, port));
                    this.markDirty();
                  }
                })
            }.alignItems(HorizontalAlign.Start).width('100%')
            Column() {
              Text($r('app.string.clash_api_secret')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.clashApiSecret })
                .width('100%')
                .height(40)
                .type(InputType.Password)
                .onChange((value: string) => {
                  this.s.clashApiSecret = value;
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')
            Text($r('app.string.clash_api_reconnect_hint'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // 分应用代理
          this.sectionHeader('▦', $r('app.string.per_app_proxy'), this.perAppExpanded, () => { this.perAppExpanded = !this.perAppExpanded; })
          if (this.perAppExpanded) {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              ForEach(APP_MODES, (m: string, idx: number) => {
                Button(APP_MODE_LABELS[idx])
                  .layoutWeight(1)
                  .backgroundColor(this.s.perAppMode === m ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.perAppMode === m ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .onClick(async () => {
                    this.s.perAppMode = m;
                    this.markDirty();
                    await this.save(true);
                    const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
                    const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
                    if (running && profileId.length > 0) {
                      LogStore.addLog('[ui] 分应用代理模式已变更，自动重启 VPN 使配置生效');
                      await VpnService.switchTo(this.context, profileId);
                    }
                  })
              }, (m: string) => m)
            }.width('100%')
            if (this.s.perAppMode !== 'off') {
              Row({ space: 8 }) {
                TextInput({ text: this.appSearch, placeholder: $r('app.string.search_apps') })
                  .layoutWeight(1).height(40)
                  .onChange((value: string) => { this.appSearch = value; })
                Button(this.appListLoading ? $r('app.string.reading_apps') : $r('app.string.read_apps'))
                  .enabled(!this.appListLoading)
                  .onClick(() => this.loadInstalledApps())
              }.width('100%')

              Row({ space: 8 }) {
                Button($r('app.string.invert_selections'))
                  .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
                  .enabled(this.installedApps.length > 0 && !this.appListLoading)
                  .backgroundColor($r('app.color.surface'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick(() => this.invertAppSelections())
                Button($r('app.string.clear_selections'))
                  .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
                  .enabled(this.s.perAppList.length > 0)
                  .backgroundColor($r('app.color.surface'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick(() => this.clearAppSelections())
              }.width('100%')

              // 包名列表剪贴板导出/导入(对齐安卓 per_app_proxy_menu 的 export/import clipboard)
              Row({ space: 8 }) {
                Button($r('app.string.export_selections_clipboard'))
                  .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
                  .enabled(this.s.perAppList.length > 0)
                  .backgroundColor($r('app.color.surface'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick(() => { void this.exportAppListToClipboard(); })
                Button($r('app.string.import_selections_clipboard'))
                  .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
                  .backgroundColor($r('app.color.surface'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick(() => { void this.importAppListFromClipboard(); })
              }.width('100%')

              if (this.appListError !== '') {
                Text(this.appListError)
                  .fontSize(11).fontColor($r('app.color.error')).width('100%')
              }

              if (this.installedApps.length > 0) {
                List({ space: 4 }) {
                  ForEach(this.filteredInstalledApps(), (item: InstalledAppItem) => {
                    ListItem() {
                      Row({ space: 8 }) {
                        Column({ space: 2 }) {
                          Text(item.label).fontSize(14).width('100%')
                          Text(item.bundleName)
                            .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
                        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                        Toggle({ type: ToggleType.Checkbox, isOn: this.isAppSelected(item.bundleName) })
                          .onChange((selected: boolean) => {
                            this.toggleInstalledApp(item.bundleName, selected);
                          })
                      }.width('100%').padding({ top: 6, bottom: 6 })
                    }
                  }, (item: InstalledAppItem) => item.bundleName)
                }.width('100%').height(240)
              }

              TextInput({
                text: this.s.perAppList,
                placeholder: this.s.perAppMode === 'exclude'
                  ? $r('app.string.settings_per_app_hint_exclude')
                  : $r('app.string.settings_per_app_hint_include')
              })
                .width('100%').height(40)
                .onChange((value: string) => {
                  this.s.perAppList = value;
                  this.markDirty();
                })
                .onSubmit(async () => {
                  await this.save(true);
                  const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
                  const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
                  if (running && profileId.length > 0) {
                    LogStore.addLog('[ui] 分应用代理列表已保存，自动重启 VPN 使配置生效');
                    await VpnService.switchTo(this.context, profileId);
                  }
                })
              Text($r('app.string.settings_per_app_manual_note'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 12 })
      }
        .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }
}
