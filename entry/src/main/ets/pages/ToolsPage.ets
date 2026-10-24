import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import pasteboard from '@ohos.pasteboard';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';
import { initStore, resetAllData, LogStore } from '../model/Store';
import { exportBackup, importBackup, BackupRestoreResult } from '../core/Backup';
import { VpnService } from '../core/VpnService';
import { getClipboardText } from '../utils/ClipboardHelper';
import { stunTest, StunResult } from '../utils/StunTester';
import bundleManager from '@ohos.bundle.bundleManager';
import deviceInfo from '@ohos.deviceInfo';
import { setClipboardText } from '../utils/ClipboardHelper';
import { DiagnosticsInput, buildDiagnosticsPackage } from '../core/Diagnostics';
import { ConfigRepository } from '../core/ConfigRepository';
import { RuleSetRepository } from '../core/RuleSetRepository';
import { listSubs, SubInfo } from '../core/Subscriptions';
import { loadProfiles } from '../model/Store';

/**
 * 工具页(对齐 NekoBoxForAndroid ToolsFragment):
 * NAT 行为发现(STUN 测试)+ 恢复出厂设置。
 */
@Component
export struct ToolsPage {
  @State stunServer: string = 'stun.cloudflare.com:3478';
  @State stunTesting: boolean = false;
  @State stunResult: StunResult | null = null;
  @State resetting: boolean = false;
  @State backupFileBusy: boolean = false;
  /** 当前被按下的元素 key(测速 / 备份恢复四颗 / 恢复出厂):"按下才亮"靠它逐颗判断 */
  @State litKey: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onOpenDrawer: () => void = () => {};

  private backupFileName(): string {
    const date = new Date();
    const pad = (value: number): string => value < 10 ? `0${value}` : `${value}`;
    return `nekobox-backup-${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}.json`;
  }

  private restoreSummary(result: BackupRestoreResult): ResourceStr {
    return result.stoppedVpn
      ? $r('app.string.backup_restore_summary_stopped', result.profiles, result.groups,
        result.subscriptions, result.routeRules, result.remoteRuleSets)
      : $r('app.string.backup_restore_summary', result.profiles, result.groups,
        result.subscriptions, result.routeRules, result.remoteRuleSets);
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
    if (msg === 'backup_restore_busy') {
      return $r('app.string.backup_restore_busy');
    }
    if (msg === 'backup_vpn_disconnect_timeout') {
      return $r('app.string.backup_vpn_disconnect_timeout');
    }
    if (msg === 'backup_restore_rolled_back') {
      return $r('app.string.backup_restore_rolled_back');
    }
    if (msg.startsWith('backup_rollback_failed:')) {
      return $r('app.string.backup_rollback_failed', msg.substring('backup_rollback_failed:'.length));
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

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
  }

  private async prepareForRestore(): Promise<boolean> {
    const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
    const status: string = AppStorage.get<string>('vpnStatus') ?? 'disconnected';
    const active = running || status === 'connecting' || status === 'switching'
      || status === 'disconnecting' || status.startsWith('connected:');
    if (!active) {
      return false;
    }
    await VpnService.disconnect(this.context);
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const currentRunning: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      const currentStatus: string = AppStorage.get<string>('vpnStatus') ?? '';
      if (!currentRunning && currentStatus === 'disconnected') {
        return true;
      }
      await this.sleep(100);
    }
    throw new Error('backup_vpn_disconnect_timeout');
  }

  private async restoreText(text: string): Promise<BackupRestoreResult> {
    const stoppedVpn = await this.prepareForRestore();
    const result = await importBackup(this.context, text.trim());
    result.stoppedVpn = stoppedVpn;
    return result;
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
      const result = await this.restoreText(text);
      promptAction.showToast({ message: this.restoreSummary(result) });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: this.backupErrorText(message) });
    } finally {
      this.backupFileBusy = false;
    }
  }

  async runStun(): Promise<void> {
    if (this.stunTesting) {
      return;
    }
    if (this.stunServer.trim().length === 0) {
      promptAction.showToast({ message: $r('app.string.stun_server_required') });
      return;
    }
    this.stunTesting = true;
    this.stunResult = null;
    try {
      this.stunResult = await stunTest(this.stunServer);
    } finally {
      this.stunTesting = false;
    }
  }

  private requestReset(): void {
    AlertDialog.show({
      message: $r('app.string.reset_confirm'),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.reset_action'),
        fontColor: $r('app.color.error'),
        action: () => {
          AlertDialog.show({
            message: $r('app.string.reset_confirm_final'),
            primaryButton: { value: $r('app.string.cancel'), action: () => {} },
            secondaryButton: {
              value: $r('app.string.reset_action'),
              fontColor: $r('app.color.error'),
              action: () => this.doReset()
            }
          });
        }
      }
    });
  }

  private async doReset(): Promise<void> {
    if (this.resetting) {
      return;
    }
    this.resetting = true;
    try {
      await initStore(this.context);
      await resetAllData();
      LogStore.addLog('[app] 已恢复出厂设置');
      promptAction.showToast({ message: $r('app.string.reset_done') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.reset_failed', e instanceof Error ? e.message : `${e}`) });
    } finally {
      this.resetting = false;
    }
  }

  /** W20(§10.5):收集诊断信息 → 预览 → 用户选择复制(不自动上传)。 */
  private async generateDiagnostics(): Promise<void> {
    try {
      const input = new DiagnosticsInput();
      try {
        const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
        input.appVersion = info.versionName;
        input.versionCode = info.versionCode;
      } catch (e) {
        // 版本读取失败:保持「未知」
      }
      input.sdkApiLevel = deviceInfo.sdkApiVersion ?? 0;
      input.kernelVersion = 'sing-box 1.14.0 (OHOS c-shared)';
      input.kernelCapability = RuleSetRepository.describeCapability();
      input.savedRevision = ConfigRepository.getActiveRevision();
      input.runningRevision = AppStorage.get<number>('vpnAppliedRevision') ?? 0;
      input.applyState = `saved=${input.savedRevision} running=${input.runningRevision}`;
      input.errorCategory = '未知';
      try {
        const subs = await listSubs();
        input.subscriptionCount = subs.length;
        const lastFailed = subs.find((x: SubInfo) => x.lastError.length > 0);
        if (lastFailed !== undefined) {
          input.errorCategory = 'subscription';
        }
      } catch (e) {
        // 计数失败保持 0
      }
      try {
        const profiles = await loadProfiles();
        input.profileCount = profiles.length;
      } catch (e) {
        // 同上
      }
      input.probeParams = `url=${this.diagnosticProbeUrl()} timeout/test concurrency 由设置提供`;
      input.probeSummary = '见日志尾部检测记录';
      const lines = LogStore.getLines();
      const tailText = lines.slice(Math.max(0, lines.length - 80)).join(String.fromCharCode(10));
      input.logTail = tailText;
      const text = buildDiagnosticsPackage(input, Date.now());
      const previewText = `${text.substring(0, 400)}${String.fromCharCode(10)}…(共 ${text.length} 字符,已脱敏)`;
      AlertDialog.show({
        title: '诊断包已生成',
        message: previewText,
        autoCancel: true,
        primaryButton: { value: '取消', action: () => {} },
        secondaryButton: {
          value: '复制',
          action: () => {
            void setClipboardText(text);
            promptAction.showToast({ message: '诊断包已复制(脱敏)' });
          }
        }
      });
    } catch (e) {
      promptAction.showToast({ message: `生成诊断包失败: ${e instanceof Error ? e.message : `${e}`}` });
    }
  }

  private diagnosticProbeUrl(): string {
    return 'http://cp.cloudflare.com/';
  }

  build() {
    Column() {
      /* 标题与抽屉入口都在壳层的 HDS 顶栏里(Index.shellTitleBar),这里不再自带页头 */

      Scroll() {
        Column({ space: 14 }) {
          // NAT 行为发现(STUN)
          Column({ space: 10 }) {
            Text($r('app.string.stun_title'))
              .fontSize(14.5).fontWeight(700).fontColor($r('app.color.text_1')).width('100%')
            Text($r('app.string.stun_desc'))
              .fontSize(11.5).fontColor($r('app.color.text_secondary')).width('100%')
            Row({ space: 8 }) {
              TextInput({ text: this.stunServer, placeholder: 'stun.cloudflare.com:3478' })
                .layoutWeight(1).height(40)
                .onChange((v: string) => { this.stunServer = v; })
              Button(this.stunTesting ? $r('app.string.stun_testing') : $r('app.string.stun_test'))
                .height(40)
                .enabled(!this.stunTesting)
                .backgroundColor(this.stunTesting ? $r('app.color.control_disabled') : $r('app.color.primary'))
                .fontColor($r('app.color.surface'))
                /* 卡片在 Scroll 里(会跟滚动跑位)⇒ 只"按下才亮",不挂常亮光源、不加 scale */
                .visualEffect(pressLightEffect(this.litKey === 'tools:stun', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'tools:stun';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
                .onClick(() => this.runStun())
            }.width('100%')

            if (this.stunResult !== null) {
              Column({ space: 4 }) {
                if (this.stunResult.ok) {
                  Row({ space: 8 }) {
                    Text($r('app.string.stun_public_endpoint')).fontSize(12.5).fontColor($r('app.color.text_2'))
                    Text(this.stunResult.publicEndpoint)
                      .fontSize(12.5).fontWeight(700).fontColor($r('app.color.success'))
                      .fontFamily('monospace')
                      .copyOption(CopyOptions.LocalDevice)
                  }.width('100%')
                  Text($r('app.string.stun_latency', this.stunResult.latencyMs))
                    .fontSize(11.5).fontColor($r('app.color.text_3')).width('100%')
                  Text(this.stunResult.mappingStable
                    ? $r('app.string.stun_nat_cone') : $r('app.string.stun_nat_symmetric'))
                    .fontSize(11.5).fontColor($r('app.color.text_2')).width('100%')
                } else {
                  Text($r('app.string.stun_failed', this.stunResult.detail))
                    .fontSize(12).fontColor($r('app.color.error')).width('100%')
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))

          // 备份与恢复(对齐安卓 Tools 页 Backup Tab)
          Column({ space: 10 }) {
            Text($r('app.string.backup_restore'))
              .fontSize(14.5).fontWeight(700).fontColor($r('app.color.text_1')).width('100%')
            Text($r('app.string.settings_backup_desc'))
              .fontSize(11.5).fontColor($r('app.color.text_secondary')).width('100%')
            Row({ space: 8 }) {
              Button(this.backupFileBusy ? $r('app.string.processing') : $r('app.string.export_backup_file'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .enabled(!this.backupFileBusy)
                .backgroundColor($r('app.color.primary'))
                .fontColor($r('app.color.surface'))
                .visualEffect(pressLightEffect(this.litKey === 'tools:backup:export', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'tools:backup:export';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
                .onClick(() => this.exportBackupFile())
              Button($r('app.string.restore_from_file'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .enabled(!this.backupFileBusy)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .visualEffect(pressLightEffect(this.litKey === 'tools:backup:import', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'tools:backup:import';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
                .onClick(() => this.importBackupFile())
            }.width('100%')
            Row({ space: 8 }) {
              Button($r('app.string.backup_to_clipboard'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .visualEffect(pressLightEffect(this.litKey === 'tools:clipboard:export', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'tools:clipboard:export';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
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
                .visualEffect(pressLightEffect(this.litKey === 'tools:clipboard:import', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'tools:clipboard:import';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
                .onClick(async () => {
                  try {
                    const text = await getClipboardText();
                    if (text.trim().length === 0) {
                      promptAction.showToast({ message: $r('app.string.settings_clipboard_empty') });
                      return;
                    }
                    const result = await this.restoreText(text);
                    promptAction.showToast({ message: this.restoreSummary(result) });
                  } catch (e) {
                    promptAction.showToast({ message: this.backupErrorText(e instanceof Error ? e.message : `${e}`) });
                  }
                })
            }.width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))

          // W20:诊断包(版本/内核能力/revision/错误类别/脱敏日志;不自动上传)
          Column({ space: 10 }) {
            Text('诊断包')
              .fontSize(14.5).fontWeight(700).fontColor($r('app.color.text_1')).width('100%')
            Text('生成含版本、内核能力、配置修订与脱敏日志的诊断文本;不包含节点密钥与订阅地址,生成后由你选择复制或取消,不会自动上传。')
              .fontSize(11.5).fontColor($r('app.color.text_secondary')).width('100%')
            Button('生成诊断包')
              .height(UiSpec.BTN_HEIGHT)
              .backgroundColor($r('app.color.primary'))
              .fontColor($r('app.color.surface'))
              .visualEffect(pressLightEffect(this.litKey === 'tools:diag', true))
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.litKey = 'tools:diag';
                } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                  this.litKey = '';
                }
              })
              .onClick(() => {
                void this.generateDiagnostics();
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))

          // 恢复出厂
          Column({ space: 10 }) {
            Text($r('app.string.reset_title'))
              .fontSize(14.5).fontWeight(700).fontColor($r('app.color.text_1')).width('100%')
            Text($r('app.string.reset_desc'))
              .fontSize(11.5).fontColor($r('app.color.text_secondary')).width('100%')
            Button($r('app.string.reset_action'))
              .height(UiSpec.BTN_HEIGHT)
              .backgroundColor($r('app.color.error'))
              .fontColor($r('app.color.surface'))
              .visualEffect(pressLightEffect(this.litKey === 'tools:reset', true))
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
        this.litKey = 'tools:reset';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
              })
              .onClick(() => this.requestReset())
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))
        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 8, bottom: 20 })
      }
        .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }
}
