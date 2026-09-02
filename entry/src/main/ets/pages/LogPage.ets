import emitter from '@ohos.events.emitter';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import util from '@ohos.util';
import { LogStore, LOG_EVENT_ID } from '../model/Store';
import { CoreManager } from '../core/CoreManager';
import { setClipboardText } from '../utils/ClipboardHelper';

@Entry
@Component
struct LogPage {
  @State lines: Array<string> = [];
  @State searchText: string = '';
  @State levelFilter: string = 'ALL';
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
      promptAction.showToast({ message: '没有可导出的日志' });
      return;
    }
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [`nekobox-${Date.now()}.log`];
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
      promptAction.showToast({ message: '日志已导出' });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `导出失败: ${message}` });
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
        Text('←').fontSize(22).fontColor('#E8E8E8').onClick(() => router.back()).padding(8)
        Text('日志').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#E8E8E8').layoutWeight(1)
        Text('导出').fontSize(14).fontColor('#64B5F6').padding(8)
          .onClick(() => this.exportLogs())
        Text('清空').fontSize(14).fontColor('#64B5F6').padding(8)
          .onClick(() => {
            LogStore.clear();
            this.lines = [];
            this.fileOffset = 0;
          })
      }
      .width('100%').padding(12)

      TextInput({ text: this.searchText, placeholder: '搜索日志' })
        .fontColor('#E8E8E8')
        .placeholderColor('#888888')
        .backgroundColor('#222222')
        .margin({ left: 12, right: 12, bottom: 8 })
        .onChange((value: string) => { this.searchText = value; })

      Row({ space: 8 }) {
        ForEach(['ALL', 'ERROR', 'WARN', 'INFO', 'DEBUG'], (level: string) => {
          Button(level)
            .fontSize(12)
            .backgroundColor(this.levelFilter === level ? '#1E88E5' : '#333333')
            .fontColor('#E8E8E8')
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
