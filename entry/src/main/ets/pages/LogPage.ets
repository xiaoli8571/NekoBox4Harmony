import emitter from '@ohos.events.emitter';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { LogStore, LOG_EVENT_ID } from '../model/Store';
import { CoreManager } from '../core/CoreManager';

@Entry
@Component
struct LogPage {
  @State lines: Array<string> = [];
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
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text('日志').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text('清空').fontSize(14).fontColor('#1E88E5').padding(8)
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
