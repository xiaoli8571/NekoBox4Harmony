import emitter from '@ohos.events.emitter';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import picker from '@ohos.file.picker';
import { BusinessError } from '@ohos.base';
import promptAction from '@ohos.promptAction';
import { LogStore, LOG_EVENT_ID } from '../model/Store';
import { CoreManager } from '../core/CoreManager';
import { setClipboardText } from '../utils/ClipboardHelper';
import { t } from '../utils/I18n';
import { APP_VERSION_LABEL } from '../common/AppVersion';

/** 导出的内核日志最大保留尾部 8MB,避免长期运行后导出文件过大。 */
const KERNEL_EXPORT_LIMIT_BYTES: number = 8 * 1024 * 1024;

@Entry
@Component
struct LogPage {
  @State lines: Array<string> = [];
  @State searchText: string = '';
  @State level: string = 'ALL';
  private scroller: Scroller = new Scroller();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private fileOffset: number = 0;
  private fileTimer: number = -1;

  aboutToAppear(): void {
    this.lines = LogStore.getLines().slice();
    const event: emitter.InnerEvent = { eventId: LOG_EVENT_ID };
    emitter.on(event, (data: emitter.EventData) => {
      const payload = data.data as Record<string, Object>;
      const line = payload !== undefined && payload['line'] !== undefined ? `${payload['line']}` : '';
      if (line.length > 0) {
        this.appendLine(line);
      }
    });
    // 内核(sing-box)日志直接读它写的 log.output 文件 —— 两个进程共享同一沙箱文件
    this.tailCoreLog();
    this.fileTimer = setInterval(() => {
      this.tailCoreLog();
    }, 1000);
  }

  aboutToDisappear(): void {
    emitter.off(LOG_EVENT_ID);
    if (this.fileTimer >= 0) {
      clearInterval(this.fileTimer);
      this.fileTimer = -1;
    }
  }

  private appendLine(line: string): void {
    this.lines.push(line);
    if (this.lines.length > 2000) {
      this.lines.splice(0, this.lines.length - 2000);
    }
    this.scroller.scrollEdge(Edge.Bottom);
  }

  private visibleLines(): Array<string> {
    const query = this.searchText.trim().toLowerCase();
    const wanted = this.level;
    return this.lines.filter((line: string) => {
      if (query.length > 0 && !line.toLowerCase().includes(query)) {
        return false;
      }
      const upper = line.toUpperCase();
      if (wanted === 'ERROR') {
        return upper.includes('ERROR');
      }
      if (wanted === 'WARNING') {
        return upper.includes('WARN') || upper.includes('WARNING');
      }
      if (wanted === 'INFO') {
        return upper.includes('INFO') || (!upper.includes('ERROR') && !upper.includes('WARN')
          && !upper.includes('WARNING') && !upper.includes('DEBUG'));
      }
      return true;
    });
  }

  /** yyyyMMdd-HHmmss,用于导出文件名 */
  private fileStamp(now: Date): string {
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}-${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
  }

  /** 读取内核日志(singbox.log),超限时仅保留尾部 */
  private readKernelLogSection(): string {
    const path = CoreManager.logFilePath(this.context);
    try {
      if (!fs.accessSync(path)) {
        return '(内核日志为空 / kernel log is empty)';
      }
      const stat = fs.statSync(path);
      if (stat.size <= 0) {
        return '(内核日志为空 / kernel log is empty)';
      }
      let offset = 0;
      let truncated = false;
      if (stat.size > KERNEL_EXPORT_LIMIT_BYTES) {
        offset = stat.size - KERNEL_EXPORT_LIMIT_BYTES;
        truncated = true;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      let content: string;
      try {
        const buf = new ArrayBuffer(stat.size - offset);
        const readLen = fs.readSync(file.fd, buf, { offset: offset });
        content = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, readLen));
      } finally {
        fs.closeSync(file);
      }
      if (truncated) {
        return `…(内核日志共 ${stat.size} 字节,仅保留最后 ${KERNEL_EXPORT_LIMIT_BYTES} 字节)…\n${content}`;
      }
      return content;
    } catch (e) {
      return `(读取内核日志失败 / failed to read kernel log: ${e})`;
    }
  }

  private buildExportContent(): string {
    const appLines = LogStore.getLines();
    const query = this.searchText.trim();
    const parts: Array<string> = [];
    parts.push('==== NekoBox for Harmony log export ====');
    parts.push(`version: ${APP_VERSION_LABEL}`);
    parts.push(`exported at: ${new Date().toLocaleString()}`);
    parts.push(`page filter: level=${this.level} search=${query.length > 0 ? query : '-'} (导出内容不受筛选影响,含完整内核日志)`);
    parts.push('');
    parts.push(`==== app log (${appLines.length} lines) ====`);
    if (appLines.length > 0) {
      for (const line of appLines) {
        parts.push(line);
      }
    } else {
      parts.push('(应用日志为空 / app log is empty)');
    }
    parts.push('');
    parts.push('==== kernel log (sing-box) ====');
    parts.push(this.readKernelLogSection());
    return parts.join('\n');
  }

  private isCancelError(e: Object): boolean {
    const err = e as BusinessError;
    if (err !== undefined && err.code === 13900042) {
      return true;
    }
    return `${e}`.toLowerCase().includes('cancel');
  }

  /** 导出日志:用户选择保存位置写入文件;保存失败时降级为复制筛选日志 */
  private async exportLogs(): Promise<void> {
    try {
      const content = this.buildExportContent();
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = [`nekobox-log-${this.fileStamp(new Date())}.log`];
      const docPicker = new picker.DocumentViewPicker();
      const uris: Array<string> = await docPicker.save(saveOptions);
      if (uris === undefined || uris.length === 0) {
        return; // 用户取消,静默返回
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      const name = uris[0].substring(uris[0].lastIndexOf('/') + 1);
      promptAction.showToast({ message: `${t('exportSuccess')}: ${name}` });
    } catch (e) {
      if (this.isCancelError(e)) {
        return;
      }
      try {
        await setClipboardText(this.visibleLines().join('\n'));
        promptAction.showToast({ message: t('exportFallbackCopied') });
      } catch (e2) {
        promptAction.showToast({ message: t('exportFailed') });
      }
    }
  }

  /** 增量读取内核日志文件(按完整行推进字节偏移) */
  private tailCoreLog(): void {
    try {
      const path = CoreManager.logFilePath(this.context);
      if (!fs.accessSync(path)) {
        this.fileOffset = 0;
        return;
      }
      const stat = fs.statSync(path);
      if (stat.size < this.fileOffset) {
        this.fileOffset = 0; // 文件被截断(重新连接)
      }
      if (stat.size === this.fileOffset) {
        return;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size - this.fileOffset);
      const readLen = fs.readSync(file.fd, buf, { offset: this.fileOffset });
      fs.closeSync(file);
      const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, readLen));
      const nl = text.lastIndexOf('\n');
      if (nl < 0) {
        return; // 没有完整行,等下个周期
      }
      const complete = text.substring(0, nl);
      const completeBytes = new util.TextEncoder().encodeInto(complete + '\n').length;
      this.fileOffset += completeBytes;
      const parts = complete.split('\n');
      for (const line of parts) {
        const trimmed = line.trim();
        if (trimmed.length > 0) {
          this.appendLine(trimmed);
        }
      }
    } catch (e) {
      // 文件可能尚未创建,下个周期重试
    }
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).fontColor('#E8E8E8').onClick(() => router.back()).padding(8)
        Text(t('logs')).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#E8E8E8').layoutWeight(1)
        Text(t('export')).fontSize(14).fontColor('#64B5F6').padding(8)
          .onClick(() => {
            this.exportLogs();
          })
        Text(t('clear')).fontSize(14).fontColor('#64B5F6').padding(8)
          .onClick(() => {
            LogStore.clear();
            this.lines = [];
            this.fileOffset = 0;
          })
      }
      .width('100%').padding(12)

      List({ scroller: this.scroller, space: 2 }) {
        ForEach(this.lines, (line: string, idx: number) => {
          ListItem() {
            Text(line)
              .fontSize(11)
              .fontFamily('monospace')
              // 固定终端配色:深底浅字,不跟随系统主题;ERROR/WARN 行高亮
              .fontColor(line.includes('ERROR') ? '#EF5350'
                : line.includes('WARN') ? '#FFB74D'
                  : line.includes('DEBUG') ? '#9E9E9E' : '#E8E8E8')
              .width('100%')
              .padding({ left: 8, right: 8, top: 1, bottom: 1 })
          }
        }, (line: string, idx: number) => `${idx}_${line}`)
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#111111')
      .scrollBar(BarState.On)
    }
    .width('100%').height('100%').backgroundColor('#111111')
  }
}
