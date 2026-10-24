import emitter from '@ohos.events.emitter';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import util from '@ohos.util';
import { LogStore, LOG_EVENT_ID, readPrefString, writePrefString } from '../model/Store';
import { LogClearMarker, parseMarker, markerToJson, buildClearMarker, tailStartOffset,
  redactLogText, redactPreview } from '../model/LogView';
import { CoreManager } from '../core/CoreManager';
import { setClipboardText } from '../utils/ClipboardHelper';
import { pressLightEffect } from '../common/Effects';

/** 日志面板(抽屉内嵌页签,对齐安卓 LogcatFragment;跟随全局主题保持与其他页面一致) */
@Component
export struct LogPanel {
  @State lines: Array<string> = [];
  @State searchText: string = '';
  @State levelFilter: string = 'ALL';
  /** HDS 点按光效:记录"当前被按下的那一个"的 key,松手/取消即清空(按下那一刻才亮) */
  @State litKey: string = '';
  onOpenDrawer: () => void = () => {};
  private scroller: Scroller = new Scroller();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private fileOffset: number = 0;
  private fileTimer: number = -1;
  /** W20:清除标记(偏移+文件身份)—— 页面重建后旧日志不重现,新日志仍可见 */
  private clearMarker: LogClearMarker | null = null;

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
    // W20:恢复上次清除标记(Preferences 持久化;文件未轮转则从偏移继续,旧日志不重现)
    void this.restoreClearMarker().then((): void => this.applyClearMarkerToOffset());
    // 内核(sing-box)日志直接读它写的 log.output 文件 —— 两个进程共享同一沙箱文件
    this.applyClearMarkerToOffset();
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

  /**
   * W20:导出默认脱敏(URL 凭据/订阅 token/密码/密钥),导出前预览;
   * 「导出原文」是显式次要动作(红色,用户主动选择)。
   * P6/W21:文案资源化;message 需要 string,经 getStringSync 现取(占位符手动替换)。
   */
  private confirmExportLogs(): void {
    const content = this.filteredLines().join('\n');
    if (content.length === 0) {
      promptAction.showToast({ message: $r('app.string.log_export_empty') });
      return;
    }
    const res = this.context.resourceManager;
    const preview = redactPreview(content, 12);
    const previewText = preview.truncated
      ? `${preview.text}\n${res.getStringSync($r('app.string.log_redact_preview_tail'))
        .split('%1$d').join(`${preview.totalLines}`)}`
      : preview.text;
    AlertDialog.show({
      title: res.getStringSync($r('app.string.log_export_dialog_title')),
      message: `\n\n${previewText}\n\n${res.getStringSync($r('app.string.log_export_dialog_note'))}`,
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.log_export_redacted'),
        action: () => this.writeExportFile(redactLogText(content))
      },
      secondaryButton: {
        value: $r('app.string.log_export_raw'),
        fontColor: $r('app.color.error'),
        action: () => this.writeExportFile(content)
      }
    });
  }

  private async writeExportFile(content: string): Promise<void> {
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

  private async restoreClearMarker(): Promise<void> {
    try {
      const text = await readPrefString('log_clear_marker', '');
      this.clearMarker = text.length > 0 ? parseMarker(text) : null;
    } catch (e) {
      this.clearMarker = null;
    }
  }

  /** 有清除标记且文件未轮转 → 起始偏移 = 标记偏移(旧日志不重现);轮转 → 0。 */
  private applyClearMarkerToOffset(): void {
    if (this.clearMarker === null) {
      return;
    }
    try {
      const path = CoreManager.logFilePath(this.context);
      if (!fs.accessSync(path)) {
        return;
      }
      const stat = fs.statSync(path);
      this.fileOffset = tailStartOffset(this.clearMarker, path, stat.size, 0);
    } catch (e) {
      // 读取失败按无标记处理
    }
  }

  /** W20:清除 = 记录当前偏移与文件身份(新日志仍可见,旧日志不重现)。 */
  private recordClearMarker(): void {
    try {
      const path = CoreManager.logFilePath(this.context);
      let size = 0;
      let mtime = 0;
      if (fs.accessSync(path)) {
        const stat = fs.statSync(path);
        size = stat.size;
        mtime = stat.mtime ?? 0;
      }
      this.clearMarker = buildClearMarker(path, size, mtime, this.fileOffset, Date.now());
      void writePrefString('log_clear_marker', markerToJson(this.clearMarker));
    } catch (e) {
      this.clearMarker = null;
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
        /* 标题与抽屉入口都在壳层的 HDS 顶栏里;这里只保留本页自己的动作(导出/清空) */
        Blank()
          .layoutWeight(1)
        /* 导出/清空:文案不变,宿主从 Text 换成透明 Button —— 点光源宿主白名单里没有 Text */
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Text($r('app.string.log_export')).fontSize(14).fontColor($r('app.color.primary'))
        }
        .height(36).padding({ left: 10, right: 10 }).backgroundColor(Color.Transparent)
        .visualEffect(pressLightEffect(this.litKey === 'export', true))
        .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) {
        this.litKey = 'export';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      } })
        .onClick(() => this.confirmExportLogs())
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Text($r('app.string.log_clear')).fontSize(14).fontColor($r('app.color.primary'))
        }
        .height(36).padding({ left: 10, right: 10 }).backgroundColor(Color.Transparent)
        .visualEffect(pressLightEffect(this.litKey === 'clear', true))
        .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) {
        this.litKey = 'clear';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      } })
        .onClick(() => {
          LogStore.clear();
          this.lines = [];
          this.recordClearMarker(); // W20:记录偏移+身份,页面重建后旧日志不重现
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
            .visualEffect(pressLightEffect(this.litKey === `level:${level}`, true))
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.litKey = `level:${level}`;
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.litKey = '';
              }
            })
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
