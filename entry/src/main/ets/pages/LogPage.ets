import emitter from '@ohos.events.emitter';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import util from '@ohos.util';
import { LogStore, LOG_EVENT_ID } from '../model/Store';
import { CoreManager } from '../core/CoreManager';
import { setClipboardText } from '../utils/ClipboardHelper';

/** 日志面板(抽屉内嵌页签,对齐安卓 LogcatFragment;跟随全局主题保持与其他页面一致) */
@Component
export struct LogPanel {
  @State lines: Array<string> = [];
  @State searchText: string = '';
  @State levelFilter: string = 'ALL';
  onOpenDrawer: () => void = () => {};
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
    const next = this.lines.slice();
    next.push(line);
    if (next.length > 2000) {
      next.splice(0, next.length - 2000);
    }
    this.lines = next;
    this.scroller.scrollEdge(Edge.Bottom);
  }

  private filteredLines(): Array<string> {
    const keyword = this.searchText.trim().toLowerCase();
    return this.lines.filter((line: string) => {
      const upper = line.toUpperCase();
      const levelMatches = this.levelFilter === 'ALL' || upper.includes(this.levelFilter);
      const keywordMatches = keyword.length === 0 || line.toLowerCase().includes(keyword);
      return levelMatches && keywordMatches;
    });
  }

  private async exportLogs(): Promise<void> {
    const content = this.filteredLines().join('\n');
    if (content.length === 0) {
      promptAction.showToast({ message: $r('app.string.log_export_empty') });
      return;
    }
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [`NekoBox-${Date.now()}.log`];
      const uris = await documentPicker.save(options);
      if (uris.length === 0) {
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
      promptAction.showToast({ message: $r('app.string.log_exported') });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.export_failed_generic', message) });
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
        const t = line.trim();
        if (t.length > 0) {
          this.appendLine(t);
        }
      }
    } catch (e) {
      // 文件可能尚未创建,下个周期重试
    }
  }

  build() {
    Column() {
      Row() {
        Text('≡').fontSize(20).fontColor($r('app.color.text_primary')).width(36).height(36).textAlign(TextAlign.Center)
          .onClick(() => this.onOpenDrawer())
        Text($r('app.string.logs')).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text($r('app.string.log_export')).fontSize(14).fontColor($r('app.color.primary')).padding(8)
          .onClick(() => this.exportLogs())
        Text($r('app.string.log_clear')).fontSize(14).fontColor($r('app.color.primary')).padding(8)
          .onClick(() => {
            LogStore.clear();
            this.lines = [];
            this.fileOffset = 0;
          })
      }
      .width('100%').padding(12)

      TextInput({ text: this.searchText, placeholder: $r('app.string.log_search_hint') })
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.surface'))
        .margin({ left: 12, right: 12, bottom: 8 })
        .onChange((value: string) => { this.searchText = value; })

      Row({ space: 8 }) {
        ForEach(['ALL', 'ERROR', 'WARN', 'INFO', 'DEBUG'], (level: string) => {
          Button(level)
            .fontSize(12)
            .backgroundColor(this.levelFilter === level ? $r('app.color.primary') : $r('app.color.surface'))
            .fontColor(this.levelFilter === level ? $r('app.color.surface') : $r('app.color.text_primary'))
            .onClick(() => { this.levelFilter = level; })
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 8 })

      List({ scroller: this.scroller, space: 2 }) {
        ForEach(this.filteredLines(), (line: string, idx: number) => {
          ListItem() {
            Text(line)
              .fontSize(11)
              .fontFamily('monospace')
              .fontColor(line.includes('ERROR') ? $r('app.color.error')
                : line.includes('WARN') ? $r('app.color.warning')
                  : line.includes('DEBUG') ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
              .width('100%')
              .padding({ left: 8, right: 8, top: 1, bottom: 1 })
          }
        }, (line: string, idx: number) => `${idx}_${line}`)
      }
        .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
      .width('100%')
      .backgroundColor($r('app.color.app_background'))
      .scrollBar(BarState.On)
    }
    .width('100%').height('100%').backgroundColor($r('app.color.app_background'))
  }
}
