import common from '@ohos.app.ability.common';
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
import { SubInfo, listSubs, updateSubscription, removeSub, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { formatBytes } from '../utils/TrafficStats';
import { exportBackup, importBackup } from '../core/Backup';
import { getClipboardText } from '../utils/ClipboardHelper';
import { geoReady, downloadGeoAssets } from '../utils/GeoAssets';

const APP_MODES: Array<string> = ['off', 'exclude', 'include'];
const APP_MODE_LABELS: Array<Resource> = [$r('app.string.per_app_off'), $r('app.string.per_app_exclude'), $r('app.string.per_app_include')];

const STACKS: Array<string> = ['system'];
const MODES: Array<string> = ['rule', 'global', 'direct'];
const MODE_LABELS: Array<Resource> = [$r('app.string.mode_rule'), $r('app.string.mode_global'), $r('app.string.mode_direct')];
const MODE_SWITCH_TOASTS: Array<Resource> = [$r('app.string.settings_mode_switched_rule'), $r('app.string.settings_mode_switched_global'), $r('app.string.settings_mode_switched_direct')];

class InstalledAppItem {
  bundleName: string = '';
  label: string = '';

  constructor(bundleName: string, label: string) {
    this.bundleName = bundleName;
    this.label = label;
  }
}

@Entry
@Component
struct SettingsPage {
  @State s: AppSettings = new AppSettings();
  @State subs: Array<SubInfo> = [];
  @State updatingUrl: string = '';
  @State geoOk: boolean = false;
  @State geoLoading: boolean = false;
  @State loading: boolean = true;
  @State loadError: string = '';
  @State installedApps: Array<InstalledAppItem> = [];
  @State appSearch: string = '';
  @State appListLoading: boolean = false;
  @State appListError: ResourceStr = '';
  @State backupFileBusy: boolean = false;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      await initStore(this.context);
      this.s = await loadSettings();
      this.subs = await listSubs();
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

  private applyAppearance(): void {
    const colorMode = this.s.appearance === 'dark'
      ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      : (this.s.appearance === 'light'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    this.context.setColorMode(colorMode);
  }

  async save(quiet: boolean = false): Promise<void> {
    try {
      await saveSettings(this.s);
      if (!quiet) {
        promptAction.showToast({ message: $r('app.string.saved_reconnect_vpn') });
      }
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.save_failed_reason', e instanceof Error ? e.message : `${e}`) });
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
    this.save(true);
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
      this.subs = await listSubs();
      promptAction.showToast({ message: message });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.restore_failed', message) });
    } finally {
      this.backupFileBusy = false;
    }
  }

  async updateOne(sub: SubInfo): Promise<void> {
    if (this.updatingUrl.length > 0) {
      return;
    }
    this.updatingUrl = sub.url;
    promptAction.showToast({ message: $r('app.string.updating_subscription') });
    try {
      const r = await updateSubscription(sub.url);
      await markSubSuccess(sub.url);
      promptAction.showToast({ message: $r('app.string.sub_update_result', r.added, r.removed) });
      this.subs = await listSubs();
    } catch (e) {
      await markSubFailure(sub.url);
      this.subs = await listSubs();
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.update_failed_reason', msg) });
    } finally {
      this.updatingUrl = '';
    }
  }

  build() {
    Column() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => {
          this.save(true);
          router.back();
        }).padding(8)
        Text($r('app.string.settings_title')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button($r('app.string.save')).height(34).onClick(() => this.save())
      }
      .width('100%').padding(12)

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
            .fontWeight(FontWeight.Medium)
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
          // 出站模式
          Column() {
            Text($r('app.string.outbound_mode')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Row({ space: 8 }) {
              ForEach(MODES, (m: string, idx: number) => {
                Button(MODE_LABELS[idx])
                  .backgroundColor(this.s.mode === m ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.mode === m ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .onClick(() => {
                    this.s.mode = m;
                    this.save(true);
                    promptAction.showToast({ message: MODE_SWITCH_TOASTS[idx] });
                  })
              }, (m: string) => m)
            }.width('100%')
            Text(this.s.mode === 'direct' ? $r('app.string.settings_mode_desc_direct')
              : this.s.mode === 'global' ? $r('app.string.settings_mode_desc_global') : $r('app.string.settings_mode_desc_rule'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

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
                .onChange((v: string) => { this.s.directDomains = v; })
              Text($r('app.string.settings_direct_cidr')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
                .margin({ top: 6 })
              TextInput({ text: this.s.directIpCidrs, placeholder: '114.114.114.114/32' })
                .width('100%').height(40)
                .onChange((v: string) => { this.s.directIpCidrs = v; })
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

          // 订阅
          Column({ space: 8 }) {
            Text($r('app.string.subscriptions')).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            if (this.subs.length === 0) {
              Text($r('app.string.settings_subs_empty'))
                .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
            }
            ForEach(this.subs, (sub: SubInfo) => {
              Row() {
                Column() {
                  Text(sub.name).fontSize(14).maxLines(1)
                  Text(sub.lastUpdate === 0 ? $r('app.string.settings_sub_never_updated')
                    : $r('app.string.settings_sub_updated_at', new Date(sub.lastUpdate).toLocaleString()))
                    .fontSize(11).fontColor($r('app.color.text_secondary'))
                  if (sub.total > 0) {
                    Text($r('app.string.settings_sub_traffic', formatBytes(sub.upload + sub.download), formatBytes(sub.total)))
                      .fontSize(11).fontColor(sub.upload + sub.download > sub.total ? $r('app.color.error') : $r('app.color.success'))
                  }
                  if (sub.expire > 0) {
                    Text($r('app.string.settings_sub_expire', new Date(sub.expire * 1000).toLocaleDateString()))
                      .fontSize(11).fontColor($r('app.color.text_secondary'))
                  }
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)

                Button($r('app.string.update_action'))
                  .height(30)
                  .backgroundColor(this.updatingUrl === sub.url ? $r('app.color.control_disabled') : $r('app.color.primary'))
                  .onClick(() => this.updateOne(sub))
                Text($r('app.string.delete')).fontSize(13).fontColor($r('app.color.error')).padding(6)
                  .onClick(() => {
                    removeSub(sub.url);
                    this.subs = this.subs.filter(x => x.url !== sub.url);
                  })
              }.width('100%')
            }, (sub: SubInfo) => sub.url)

            Row() {
              Text($r('app.string.settings_auto_update_subs')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.autoUpdateSubs })
                .onChange((v: boolean) => {
                  this.s.autoUpdateSubs = v;
                  this.save(true);
                })
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          Column() {
            Text('TUN MTU').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: `${this.s.mtu}`, placeholder: '9000' })
              .type(InputType.Number).width('100%').height(40)
              .onChange((v: string) => {
                const n = parseInt(v);
                this.s.mtu = isNaN(n) ? 9000 : n;
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text($r('app.string.settings_tun_stack')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Select(STACKS.map((t: string) => ({ value: t } as SelectOption)))
              .selected(STACKS.indexOf(this.s.stack) < 0 ? 0 : STACKS.indexOf(this.s.stack))
              .value(this.s.stack)
              .onSelect((index: number) => { this.s.stack = STACKS[index]; })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text($r('app.string.settings_remote_dns')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: this.s.remoteDns })
              .width('100%').height(40)
              .onChange((v: string) => { this.s.remoteDns = v; })
            Text($r('app.string.settings_remote_dns_hint'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text($r('app.string.settings_direct_dns')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: this.s.directDns })
              .width('100%').height(40)
              .onChange((v: string) => { this.s.directDns = v; })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Row() {
            Text($r('app.string.settings_enable_ipv6')).fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.ipv6 })
              .onChange((v: boolean) => { this.s.ipv6 = v; })
          }.width('100%')

          Blank().height(2)

          // 外观与交互
          Column({ space: 8 }) {
            Text($r('app.string.appearance_and_interaction')).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            Row({ space: 8 }) {
              ForEach(['system', 'light', 'dark'], (mode: string) => {
                Button(mode === 'system' ? $r('app.string.appearance_follow_system') : (mode === 'light' ? $r('app.string.appearance_light') : $r('app.string.appearance_dark')))
                  .backgroundColor(this.s.appearance === mode ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.appearance === mode ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .onClick(() => {
                    this.s.appearance = mode;
                    this.applyAppearance();
                    this.save(true);
                  })
              }, (mode: string) => mode)
            }.width('100%')
            Row() {
              Text($r('app.string.haptic_feedback')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.hapticFeedback })
                .onChange((v: boolean) => {
                  this.s.hapticFeedback = v;
                  this.save(true);
                })
            }.width('100%')
            Row() {
              Text($r('app.string.liquid_glass')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.liquidGlass })
                .onChange((v: boolean) => {
                  this.s.liquidGlass = v;
                  this.save(true);
                })
            }.width('100%')
            Text($r('app.string.settings_theme_note'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          // 分应用代理
          Column({ space: 8 }) {
            Text($r('app.string.per_app_proxy')).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            Row({ space: 8 }) {
              ForEach(APP_MODES, (m: string, idx: number) => {
                Button(APP_MODE_LABELS[idx])
                  .backgroundColor(this.s.perAppMode === m ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.perAppMode === m ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .onClick(() => {
                    this.s.perAppMode = m;
                    this.save(true);
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
                .onChange((value: string) => { this.s.perAppList = value; })
              Text($r('app.string.settings_per_app_manual_note'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          // 备份与恢复
          Column({ space: 8 }) {
            Text($r('app.string.backup_restore')).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
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

          Row() {
            Column() {
              Text($r('app.string.settings_insecure_tls')).fontSize(14)
              Text($r('app.string.settings_insecure_tls_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.allowInsecureAll })
              .onChange((v: boolean) => { this.s.allowInsecureAll = v; })
          }.width('100%')

          Text($r('app.string.settings_reconnect_note'))
            .fontSize(12).fontColor($r('app.color.error')).width('100%')
        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 12 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .constraintSize({ maxWidth: UiSpec.CONTENT_MAX_WIDTH })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.app_background'))
    .width('100%').height('100%').backgroundColor($r('app.color.app_background'))
  }
}
