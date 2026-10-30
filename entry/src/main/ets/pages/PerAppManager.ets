import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';
import { AppSettings } from '../model/Profile';
import {
  PerAppEntry, parseEntries, serializeEntries, effectivePackages, invalidBundleNames, isValidBundleName,
  entriesFromInput, entriesFromClipboardPayload, mergeEntries, removeEntry, toggleEntry,
  isPresetBundleName
} from '../model/PerApp';
import { loadSettings, saveSettings, LogStore } from '../model/Store';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { InstalledApp, InstalledAppResult, listInstalledApps, filterInstalledApps } from '../utils/InstalledApps';

/**
 * 分应用代理管理(2026-10-24 用户指示:从设置页整体迁到分流页,本组件即完整名单管理)。
 *
 * 自包含:自己 loadSettings/saveSettings;保存成功后回调 onApplyNow 走应用事务
 * (Index.commitAndApplySettings:提交快照 → 运行中发 apply 由扩展串行重连一次)。
 * 权威状态是 perAppEntries;s.perAppList 由勾选项派生(Store 落盘时再规范化一次)。
 * UI 从 SettingsPage 原样迁来(模式三档/搜索/条目勾选/添加对话框/剪贴板导入导出)。
 */
@Component
export struct PerAppManager {
  /** 保存成功后触发应用事务(父级接 Index 的提交+apply) */
  onApplyNow: () => void = () => {};
  @State s: AppSettings = new AppSettings();
  @State perAppEntries: Array<PerAppEntry> = [];
  @State appSearch: string = '';
  @State perAppDialogLabel: string = '';
  @State perAppDialogPackages: string = '';
  @State perAppDialogError: ResourceStr = '';
  @State litKey: string = '';
  // 已安装应用枚举(对齐 OwnBox AppListActivity):懒加载一次,失败保留手动输入通道
  @State installedApps: Array<InstalledApp> = [];
  @State installedLoading: boolean = false;
  @State installedError: string = '';
  @State installedIncludeSystem: boolean = false;
  private installedLoaded: boolean = false;
  private perAppDialog: CustomDialogController = new CustomDialogController({
    builder: PerAppAddDialog({
      label: $perAppDialogLabel,
      packages: $perAppDialogPackages,
      errorText: $perAppDialogError,
      onConfirm: () => { this.confirmPerAppDialog(); }
    }),
    autoCancel: true
  });

  async aboutToAppear(): Promise<void> {
    this.s = await loadSettings();
    this.perAppEntries = parseEntries(this.s.perAppEntries);
    if (this.s.perAppMode !== 'off') {
      await this.loadInstalledApps(false);
    }
  }

  private async saveQuiet(): Promise<boolean> {
    try {
      await saveSettings(this.s);
      this.onApplyNow();
      return true;
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.save_failed_reason', e instanceof Error ? e.message : `${e}`) });
      return false;
    }
  }

  /** 把条目同步进设置对象并持久化;保存成功即走应用事务(不直连 switchTo)。 */
  private async persistPerApp(reason: string): Promise<void> {
    this.s.perAppEntries = serializeEntries(this.perAppEntries);
    this.s.perAppList = effectivePackages(this.perAppEntries).join(',');
    if (!await this.saveQuiet()) {
      return;
    }
    // 存完立刻回读一次:Store 会做规范化(去重/过滤非法包名),让界面与磁盘一致
    this.s = await loadSettings();
    this.perAppEntries = parseEntries(this.s.perAppEntries);
    this.reportInvalidPackages();
    LogStore.addLog(`[routing] ${reason}(生效走应用事务)`);
  }

  private reportInvalidPackages(): void {
    const bad = invalidBundleNames(this.perAppEntries);
    if (bad.length > 0) {
      LogStore.addLog(`[routing] 分应用: ${bad.length} 个包名格式非法,已忽略: ${bad.join(', ')}`);
    }
  }

  private perAppFilteredEntries(): Array<PerAppEntry> {
    const query = this.appSearch.trim().toLowerCase();
    if (query.length === 0) {
      return this.perAppEntries;
    }
    return this.perAppEntries.filter((entry: PerAppEntry) =>
      entry.label.toLowerCase().includes(query) || entry.bundleName.toLowerCase().includes(query));
  }

  // ---------------- 已安装应用(对齐 OwnBox AppListActivity) ----------------

  private async loadInstalledApps(force: boolean): Promise<void> {
    if (this.installedLoading) {
      return;
    }
    if (this.installedLoaded && !force) {
      return;
    }
    this.installedLoading = true;
    this.installedError = '';
    try {
      const self: string = getContext(this).applicationInfo.name;
      const res: InstalledAppResult = await listInstalledApps(self, this.installedIncludeSystem);
      this.installedApps = res.apps;
      this.installedError = res.error;
      this.installedLoaded = res.error.length === 0;
      if (res.error.length > 0) {
        LogStore.addLog(`[routing] 已安装应用枚举失败: ${res.error}`);
      }
    } catch (e) {
      this.installedError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.installedLoading = false;
    }
  }

  private installedVisible(): Array<InstalledApp> {
    return filterInstalledApps(this.installedApps, this.appSearch);
  }

  private isAppSelected(bundleName: string): boolean {
    const hit: PerAppEntry | undefined =
      this.perAppEntries.find((entry: PerAppEntry) => entry.bundleName === bundleName);
    return hit !== undefined && hit.enabled;
  }

  private async onInstalledToggle(bundleName: string, label: string, on: boolean): Promise<void> {
    const exists: boolean =
      this.perAppEntries.some((entry: PerAppEntry) => entry.bundleName === bundleName);
    if (exists) {
      this.perAppEntries = toggleEntry(this.perAppEntries, bundleName, on);
    } else if (on) {
      this.perAppEntries = mergeEntries(this.perAppEntries, [new PerAppEntry(bundleName, label, true)]);
    }
    await this.persistPerApp(on ? '勾选已安装应用' : '取消勾选已安装应用');
  }

  private avatarText(label: string): string {
    const trimmed: string = label.trim();
    return trimmed.length === 0 ? '?' : trimmed.substring(0, 1).toUpperCase();
  }

  private async togglePerAppEntry(bundleName: string, selected: boolean): Promise<void> {
    this.perAppEntries = toggleEntry(this.perAppEntries, bundleName, selected);
    await this.persistPerApp(selected ? '勾选应用' : '取消勾选应用');
  }

  private async removePerAppEntry(bundleName: string, label: string): Promise<void> {
    AlertDialog.show({
      message: $r('app.string.per_app_remove_confirm', label),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.per_app_remove_entry'),
        fontColor: $r('app.color.error'),
        action: () => {
          this.perAppEntries = removeEntry(this.perAppEntries, bundleName);
          void this.persistPerApp('移除应用条目');
        }
      }
    });
  }

  /** 清除全部已选应用:只取消勾选,保留条目。 */
  private async clearAppSelections(): Promise<void> {
    if (effectivePackages(this.perAppEntries).length === 0) {
      return;
    }
    this.perAppEntries = this.perAppEntries.map((entry: PerAppEntry) =>
      new PerAppEntry(entry.bundleName, entry.label, false));
    await this.persistPerApp('清除应用选择');
  }

  private openPerAppDialog(): void {
    this.perAppDialogLabel = '';
    this.perAppDialogPackages = '';
    this.perAppDialogError = '';
    this.perAppDialog.open();
  }

  private confirmPerAppDialog(): void {
    const incoming = entriesFromInput(this.perAppDialogPackages, this.perAppDialogLabel);
    if (incoming.length === 0) {
      this.perAppDialogError = $r('app.string.per_app_dialog_need_package');
      return;
    }
    const bad = invalidBundleNames(incoming);
    const validCount = incoming.length - bad.length;
    if (validCount === 0) {
      this.perAppDialogError = $r('app.string.per_app_dialog_all_invalid', bad[0]);
      return;
    }
    this.perAppEntries = mergeEntries(this.perAppEntries, incoming);
    this.perAppDialog.close();
    promptAction.showToast({
      message: bad.length > 0
        ? $r('app.string.per_app_added_with_invalid', validCount, bad.length)
        : $r('app.string.per_app_added_count', validCount)
    });
    void this.persistPerApp('添加应用条目');
  }

  /** 从剪贴板导入("false\n<包名列表>");合并,不清空。 */
  private async importAppListFromClipboard(): Promise<void> {
    const clip = await getClipboardText();
    const incoming = entriesFromClipboardPayload(clip);
    if (incoming.length === 0) {
      promptAction.showToast({ message: $r('app.string.action_import_err') });
      return;
    }
    this.perAppEntries = mergeEntries(this.perAppEntries, incoming);
    await this.persistPerApp('从剪贴板导入应用列表');
    promptAction.showToast({ message: $r('app.string.action_import_msg') });
  }

  /** 导出已选应用到剪贴板("false\n<包名,逗号分隔>")。 */
  private async exportAppListToClipboard(): Promise<void> {
    const payload = `false\n${effectivePackages(this.perAppEntries).join(',')}`;
    try {
      await setClipboardText(payload);
      promptAction.showToast({ message: $r('app.string.action_export_msg') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.action_export_err') });
    }
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        ForEach(APP_MODES, (m: string, idx: number) => {
          Button(APP_MODE_LABELS[idx])
            .layoutWeight(1)
            .backgroundColor(this.s.perAppMode === m ? $r('app.color.primary') : $r('app.color.surface'))
            .fontColor(this.s.perAppMode === m ? $r('app.color.surface') : $r('app.color.text_primary'))
            .visualEffect(pressLightEffect(this.litKey === `perapp:${m}`, true))
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.litKey = `perapp:${m}`;
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.litKey = '';
              }
            })
            .onClick(async () => {
              this.s.perAppMode = m;
              if (m !== 'off') {
                void this.loadInstalledApps(false);
              }
              /* 保存即走应用事务(不直连 switchTo) */
              await this.persistPerApp(m === 'off' ? '关闭分应用' : `切换分应用模式 ${m}`);
            })
        }, (m: string) => m)
      }.width('100%')
      if (this.s.perAppMode !== 'off') {
        Text(this.s.perAppMode === 'exclude'
          ? $r('app.string.per_app_hint_exclude')
          : $r('app.string.per_app_hint_include'))
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')

        Row({ space: 8 }) {
          Text($r('app.string.per_app_installed_title'))
            .fontSize(12.5)
            .fontColor($r('app.color.text_secondary'))
          Text(`${this.installedApps.length}`)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          Blank()
          Text($r('app.string.per_app_installed_include_system'))
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
          Toggle({ type: ToggleType.Checkbox, isOn: this.installedIncludeSystem })
            .selectedColor($r('app.color.primary'))
            .onChange((on: boolean) => {
              this.installedIncludeSystem = on;
              void this.loadInstalledApps(true);
            })
          Button($r('app.string.per_app_installed_refresh'))
            .height(28)
            .fontSize(11)
            .padding({ left: 8, right: 8 })
            .backgroundColor($r('app.color.surface'))
            .fontColor($r('app.color.primary'))
            .onClick(() => { void this.loadInstalledApps(true); })
        }.width('100%')

        if (this.installedLoading) {
          Row({ space: 8 }) {
            LoadingProgress().width(18).height(18)
            Text($r('app.string.per_app_installed_loading'))
              .fontSize(11).fontColor($r('app.color.text_secondary'))
          }.width('100%').height(40)
        } else if (this.installedVisible().length === 0) {
          Text($r('app.string.per_app_installed_empty'))
            .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
        } else {
          List({ space: 2 }) {
            ForEach(this.installedVisible(), (app: InstalledApp) => {
              ListItem() {
                Row({ space: 10 }) {
                  Text(this.avatarText(app.label))
                    .width(32).height(32)
                    .borderRadius(9)
                    .textAlign(TextAlign.Center)
                    .fontSize(14)
                    .fontColor($r('app.color.primary'))
                    .backgroundColor($r('app.color.app_background'))
                  Column({ space: 2 }) {
                    Row({ space: 6 }) {
                      Text(app.label)
                        .fontSize(13.5)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      if (app.systemApp) {
                        Text($r('app.string.per_app_system_tag'))
                          .fontSize(9)
                          .fontColor($r('app.color.text_secondary'))
                          .backgroundColor($r('app.color.app_background'))
                          .borderRadius(4)
                          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      }
                    }.width('100%')
                    Text(app.bundleName)
                      .fontSize(10.5)
                      .fontColor($r('app.color.text_secondary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Toggle({ type: ToggleType.Checkbox, isOn: this.isAppSelected(app.bundleName) })
                    .selectedColor($r('app.color.primary'))
                    .onChange((on: boolean) => {
                      void this.onInstalledToggle(app.bundleName, app.label, on);
                    })
                }.width('100%').height(46)
              }
            }, (app: InstalledApp) => `${app.bundleName}_${this.isAppSelected(app.bundleName)}`)
          }.width('100%').height(220)
        }

        Text($r('app.string.per_app_entries_title'))
          .fontSize(12.5)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ top: 2, bottom: 2 })

        if (this.perAppFilteredEntries().length === 0) {
          Text(this.perAppEntries.length === 0
            ? $r('app.string.per_app_empty')
            : $r('app.string.per_app_search_empty'))
            .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            .padding({ top: 4, bottom: 4 })
        } else {
          List({ space: 4 }) {
            ForEach(this.perAppFilteredEntries(), (entry: PerAppEntry) => {
              ListItem() {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Row({ space: 6 }) {
                      Text(entry.label)
                        .fontSize(14)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      if (isPresetBundleName(entry.bundleName)) {
                        Text($r('app.string.per_app_preset_tag'))
                          .fontSize(9)
                          .fontColor($r('app.color.text_secondary'))
                          .backgroundColor($r('app.color.app_background'))
                          .borderRadius(4)
                          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      }
                    }.width('100%')
                    Text(entry.bundleName)
                      .fontSize(11)
                      .fontColor(isValidBundleName(entry.bundleName)
                        ? $r('app.color.text_secondary') : $r('app.color.error'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text($r('app.string.per_app_remove_entry'))
                      .fontSize(11)
                      .fontColor($r('app.color.primary'))
                      .height(44)
                      .onClick(() => { void this.removePerAppEntry(entry.bundleName, entry.label); })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Toggle({ type: ToggleType.Checkbox, isOn: entry.enabled })
                    .selectedColor($r('app.color.primary'))
                    .onChange((selected: boolean) => {
                      void this.togglePerAppEntry(entry.bundleName, selected);
                    })
                }.width('100%').padding({ top: 6, bottom: 6 })
              }
            }, (entry: PerAppEntry) => `${entry.bundleName}_${entry.enabled}_${entry.label}`)
          }.width('100%').height(260)

          Text($r('app.string.per_app_effective_count', effectivePackages(this.perAppEntries).length))
            .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')

          Row({ space: 8 }) {
            Button($r('app.string.clear_selections'))
              .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
              .enabled(effectivePackages(this.perAppEntries).length > 0)
              .backgroundColor($r('app.color.surface'))
              .fontColor($r('app.color.text_primary'))
              .visualEffect(pressLightEffect(this.litKey === 'perapp:clear', true))
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.litKey = 'perapp:clear';
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.litKey = '';
                }
              })
              .onClick(() => { void this.clearAppSelections(); })
            Button($r('app.string.per_app_add_import'))
              .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
              .backgroundColor(this.litKey === 'perapp:add' ? $r('app.color.primary') : $r('app.color.surface'))
              .fontColor(this.litKey === 'perapp:add' ? $r('app.color.surface') : $r('app.color.text_1'))
              .visualEffect(pressLightEffect(this.litKey === 'perapp:add', true))
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.litKey = 'perapp:add';
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.litKey = '';
                }
              })
              .onClick(() => this.openPerAppDialog())
          }.width('100%')

          Row({ space: 8 }) {
            Button($r('app.string.import_selections_clipboard'))
              .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
              .backgroundColor($r('app.color.surface'))
              .fontColor($r('app.color.text_primary'))
              .visualEffect(pressLightEffect(this.litKey === 'perapp:import', true))
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.litKey = 'perapp:import';
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.litKey = '';
                }
              })
              .onClick(() => { void this.importAppListFromClipboard(); })
            Button($r('app.string.export_selections_clipboard'))
              .layoutWeight(1).height(UiSpec.BTN_HEIGHT)
              .enabled(effectivePackages(this.perAppEntries).length > 0)
              .backgroundColor($r('app.color.surface'))
              .fontColor($r('app.color.text_primary'))
              .visualEffect(pressLightEffect(this.litKey === 'perapp:export', true))
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.litKey = 'perapp:export';
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.litKey = '';
                }
              })
              .onClick(() => { void this.exportAppListToClipboard(); })
          }.width('100%')
        }
        Text($r('app.string.per_app_note'))
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}

const APP_MODES: Array<string> = ['off', 'exclude', 'include'];
const APP_MODE_LABELS: Array<Resource> = [$r('app.string.per_app_off'), $r('app.string.per_app_exclude'), $r('app.string.per_app_include')];

/**
 * 「添加 / 批量导入」对话框(自 SettingsPage 原样迁来):
 *   名称备注(可选,只用于单个包名) + 每行一个鸿蒙应用包名。
 */
@CustomDialog
struct PerAppAddDialog {
  @State litKey: string = '';
  controller?: CustomDialogController;
  @Link label: string;
  @Link packages: string;
  @Link errorText: ResourceStr;
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.per_app_dialog_title'))
        .fontSize(17)
        .fontWeight(700)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      Text($r('app.string.per_app_dialog_hint'))
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ text: this.label, placeholder: $r('app.string.per_app_dialog_label_placeholder') })
        .height(40)
        .maxLength(40)
        .onChange((v: string) => { this.label = v; })
      TextArea({
        text: this.packages,
        placeholder: $r('app.string.per_app_dialog_packages_placeholder')
      })
        .height(150)
        .onChange((v: string) => {
          this.packages = v;
          this.errorText = '';
        })
      if (`${this.errorText}`.length > 0) {
        Text(this.errorText)
          .fontSize(11)
          .fontColor($r('app.color.error'))
          .width('100%')
      }
      Row({ space: 10 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button($r('app.string.per_app_dialog_confirm'))
          .layoutWeight(1)
          .backgroundColor(this.litKey === 'perapp:export' ? $r('app.color.primary') : $r('app.color.surface'))
          .fontColor(this.litKey === 'perapp:export' ? $r('app.color.surface') : $r('app.color.text_1'))
          .onClick(() => this.onConfirm())
      }.width('100%')
    }
    .padding(20)
    .width('100%')
  }
}
