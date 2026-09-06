import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import pasteboard from '@ohos.pasteboard';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { UiSpec } from '../common/UiSpec';
import { DrawerButton } from '../common/components/DrawerButton';
import { initStore, resetAllData, LogStore } from '../model/Store';
import { exportBackup, importBackup } from '../core/Backup';
import { getClipboardText } from '../utils/ClipboardHelper';
import { stunTest, StunResult } from '../utils/StunTester';

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
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onOpenDrawer: () => void = () => {};

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
      promptAction.showToast({ message: message });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.restore_failed', message) });
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

  build() {
    Column() {
      Row() {
        DrawerButton({ onOpen: () => this.onOpenDrawer() })
        Text($r('app.string.nav_tools'))
          .fontSize(16).fontWeight(800).fontColor($r('app.color.text_1')).layoutWeight(1)
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING, top: 26, bottom: 8 })

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
                    promptAction.showToast({ message: msg });
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
              .onClick(() => this.requestReset())
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))
        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 20 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }
}
