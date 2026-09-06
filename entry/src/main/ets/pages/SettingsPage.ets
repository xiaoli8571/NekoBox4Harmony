import common from '@ohos.app.ability.common';
import bundleManager from '@ohos.bundle.bundleManager';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import pasteboard from '@ohos.pasteboard';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import bundle from '@ohos.bundle';
import { AppSettings } from '../model/Profile';
import { initStore, loadSettings, saveSettings, LogStore } from '../model/Store';
import { exportBackup, importBackup } from '../core/Backup';
import { getClipboardText } from '../utils/ClipboardHelper';
import { geoReady, downloadGeoAssets } from '../utils/GeoAssets';
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
const SNIFF_LABELS: Array<Resource> = [$r('app.string.sniff_off'), $r('app.string.sniff_route'), $r('app.string.sniff_override')];
const STRATEGIES: Array<string> = ['', 'auto', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'];
const STRATEGY_LABELS: Array<Resource> = [$r('app.string.strategy_default'), $r('app.string.strategy_auto'), $r('app.string.strategy_prefer_ipv4'), $r('app.string.strategy_prefer_ipv6'), $r('app.string.strategy_ipv4_only'), $r('app.string.strategy_ipv6_only')];

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
  @State loading: boolean = true;
  @State loadError: string = '';
  @State installedApps: Array<InstalledAppItem> = [];
  @State appSearch: string = '';
  @State appListLoading: boolean = false;
  @State appListError: ResourceStr = '';
  @State backupFileBusy: boolean = false;
  @State appVersion: string = '';
  @State dirty: boolean = false;
  @State proxyExpanded: boolean = false;
  @State generalExpanded: boolean = false;
  @State networkExpanded: boolean = false;
  @State dnsExpanded: boolean = false;
  @State inboundExpanded: boolean = false;
  @State appearanceExpanded: boolean = false;
  @State apiExpanded: boolean = false;
  @State perAppExpanded: boolean = false;
  @State backupExpanded: boolean = false;
  @State otherExpanded: boolean = false;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onSettingsChanged: (settings: AppSettings) => void = (_settings: AppSettings) => {};

  aboutToAppear(): void {
    this.loadAppVersion();
    this.load();
  }

  private loadAppVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (e) {
      this.appVersion = '';
    }
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      await initStore(this.context);
      this.s = await loadSettings();
      this.dirty = false;
      this.geoOk = geoReady(this.context);
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
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
      promptAction.showToast({ message: $r('app.string.geo_download_complete') });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.download_failed_reason', msg) });
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

  private backupErrorText(msg: string): ResourceStr {
    if (msg === 'backup_invalid_json') {
      return $r('app.string.backup_invalid_json');
    }
    if (msg === 'backup_bad_format') {
      return $r('app.string.backup_bad_format');
    }
    if (msg.startsWith('backup_unsupported_version:')) {
      return $r('app.string.backup_unsupported_version', Number(msg.substring('backup_unsupported_version:'.length)) || 0);
    }
    if (msg === 'backup_file_empty') {
      return $r('app.string.backup_file_empty');
    }
    if (msg === 'backup_file_too_large') {
      return $r('app.string.backup_file_too_large');
    }
    if (msg === 'backup_file_incomplete') {
      return $r('app.string.backup_file_incomplete');
    }
    return $r('app.string.backup_op_failed', msg);
  }

  private backupFileName(): string {
    const date = new Date();
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `nekobox-backup-${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}.json`;
  }

  private writeTextFileUri(uri: string, content: string): void {
    const file = fs.openSync(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
  }

  private readTextFileUri(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const fileSize = fs.statSync(file.fd).size;
      if (fileSize <= 0) {
        throw new Error('backup_file_empty');
      }
      if (fileSize > 20 * 1024 * 1024) {
        throw new Error('backup_file_too_large');
      }
      const buffer = new ArrayBuffer(fileSize);
      const bytesRead = fs.readSync(file.fd, buffer, { length: fileSize });
      if (bytesRead !== fileSize) {
        throw new Error('backup_file_incomplete');
      }
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer, 0, bytesRead));
    } finally {
      fs.closeSync(file);
    }
  }

  async exportBackupFile(): Promise<void> {
    if (this.backupFileBusy) {
      return;
    }
    this.backupFileBusy = true;
    try {
      const text = await exportBackup(this.context);
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const uris = await documentPicker.save({
        newFileNames: [this.backupFileName()],
        fileSuffixChoices: ['JSON|.json']
      });
      if (uris.length === 0) {
        promptAction.showToast({ message: $r('app.string.backup_export_cancelled') });
        return;
      }
      this.writeTextFileUri(uris[0], text);
      promptAction.showToast({ message: $r('app.string.backup_file_exported') });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.export_failed', message) });
    } finally {
      this.backupFileBusy = false;
    }
  }

  async importBackupFile(): Promise<void> {
    if (this.backupFileBusy) {
      return;
    }
    this.backupFileBusy = true;
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const uris = await documentPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['JSON|.json']
      });
      if (uris.length === 0) {
        promptAction.showToast({ message: $r('app.string.backup_import_cancelled') });
        return;
      }
      const text = this.readTextFileUri(uris[0]).trim();
      const message = await importBackup(this.context, text);
      this.s = await loadSettings();
      promptAction.showToast({ message: message });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.restore_failed', message) });
    } finally {
      this.backupFileBusy = false;
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
              Text($r('app.string.settings_test_url')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.testUrl })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.testUrl = v;
                  this.markDirty();
                })
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

            Row() {
              Text($r('app.string.settings_always_show_address')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.alwaysShowAddress })
                .onChange((v: boolean) => {
                  this.s.alwaysShowAddress = v;
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
          Row() {
            Column() {
              Text($r('app.string.settings_custom_routes_title')).fontSize(14)
              Text($r('app.string.route_rules_description')).fontSize(11).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text($r('app.string.enter')).fontSize(14).fontColor($r('app.color.primary'))
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .onClick(() => router.pushUrl({ url: 'pages/RouteRulesPage' }))

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
            }.alignItems(HorizontalAlign.Start).width('100%')
          }

          Blank().height(2)

          Column() {
            Text('TUN MTU').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
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

          Row() {
            Text($r('app.string.settings_enable_ipv6')).fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.ipv6 })
              .onChange((v: boolean) => {
                this.s.ipv6 = v;
                this.markDirty();
              })
          }.width('100%')

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
                  .onClick(() => {
                    this.s.perAppMode = m;
                    this.markDirty();
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
              Text($r('app.string.settings_per_app_manual_note'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // 备份与恢复
          this.sectionHeader('✓', $r('app.string.backup_restore'), this.backupExpanded, () => { this.backupExpanded = !this.backupExpanded; })
          if (this.backupExpanded) {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              Button(this.backupFileBusy ? $r('app.string.processing') : $r('app.string.export_backup_file'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .enabled(!this.backupFileBusy)
                .backgroundColor($r('app.color.primary'))
                .fontColor($r('app.color.surface'))
                .onClick(() => this.exportBackupFile())
              Button($r('app.string.restore_from_file'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .enabled(!this.backupFileBusy)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => this.importBackupFile())
            }.width('100%')
            Row({ space: 8 }) {
              Button($r('app.string.backup_to_clipboard'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .onClick(async () => {
                  try {
                    const data = await exportBackup(this.context);
                    const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, data);
                    await pasteboard.getSystemPasteboard().setData(pasteData);
                    promptAction.showToast({ message: $r('app.string.settings_clipboard_backup_done') });
                  } catch (e) {
                    promptAction.showToast({ message: $r('app.string.settings_clipboard_backup_failed', e instanceof Error ? e.message : `${e}`) });
                  }
                })
              Button($r('app.string.restore_from_clipboard'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .onClick(async () => {
                  try {
                    const text = await getClipboardText();
                    if (text.trim().length === 0) {
                      promptAction.showToast({ message: $r('app.string.settings_clipboard_empty') });
                      return;
                    }
                    const msg = await importBackup(this.context, text.trim());
                    this.s = await loadSettings();
                    this.dirty = false;
                    this.onSettingsChanged(this.s);
                    promptAction.showToast({ message: msg });
                  } catch (e) {
                    promptAction.showToast({ message: this.backupErrorText(e instanceof Error ? e.message : `${e}`) });
                  }
                })
            }.width('100%')
            Text($r('app.string.settings_backup_desc'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          Text($r('app.string.settings_reconnect_note'))
            .fontSize(12).fontColor($r('app.color.error')).width('100%')

          }

          // 其他
          this.sectionHeader('ⓘ', $r('app.string.settings_about'), this.otherExpanded, () => { this.otherExpanded = !this.otherExpanded; })
          if (this.otherExpanded) {
          Row({ space: 10 }) {
            Text('ⓘ')
              .fontSize(15)
              .fontColor($r('app.color.mono'))
              .width(24)
              .textAlign(TextAlign.Center)
            Column({ space: 2 }) {
              Text($r('app.string.settings_about_version'))
                .fontSize(14.5)
                .fontWeight(600)
                .fontColor($r('app.color.text_1'))
              Text(this.appVersion.length > 0 ? this.appVersion : '—')
                .fontSize(11.5)
                .fontColor($r('app.color.text_3'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          }.width('100%')
          }
        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 12 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }
}
