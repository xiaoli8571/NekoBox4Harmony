import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import { statusBarTopVp } from '../common/PageTopInset';
import { UiSpec } from '../common/UiSpec';
import { initStore } from '../model/Store';
import { formatSpeed, formatBytes } from '../utils/TrafficStats';
import {
  TrafficSeries, TrafficTotals, niceMax, barHeight, formatMbps, speedVerdict,
  SPEED_SLOW, SPEED_FAIR, SPEED_GOOD, SPEED_FAST
} from '../core/TrafficChart';
import { SpeedResult, downloadTest, uploadTest } from '../utils/SpeedTest';

/** 采样窗口:60 × 1s = 最近 1 分钟(与 OwnBox 流量图默认窗口一致) */
const WINDOW_SECONDS: number = 60;
const SAMPLE_INTERVAL_MS: number = 1000;
const DOWN_BYTES: number = 10 * 1024 * 1024;
const UP_BYTES: number = 2 * 1024 * 1024;
const SPEED_TIMEOUT_MS: number = 20000;

@Entry
@Component
struct TrafficPage {
  @State topPadVp: number = 44;
  @State vpnRunning: boolean = false;
  @State paused: boolean = false;
  /** 归一化后的柱高像素(左→右 = 旧→新),直接驱动 ForEach 重绘 */
  @State downBars: Array<number> = [];
  @State upBars: Array<number> = [];
  @State curDown: number = 0;
  @State curUp: number = 0;
  @State maxDownText: string = '0 B/s';
  @State maxUpText: string = '0 B/s';
  @State totalDown: number = 0;
  @State totalUp: number = 0;
  @State peakDown: number = 0;
  @State peakUp: number = 0;
  @State downTesting: boolean = false;
  @State upTesting: boolean = false;
  @State downResult: SpeedResult | null = null;
  @State upResult: SpeedResult | null = null;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private downSeries: TrafficSeries = new TrafficSeries(WINDOW_SECONDS);
  private upSeries: TrafficSeries = new TrafficSeries(WINDOW_SECONDS);
  private totals: TrafficTotals = new TrafficTotals();
  private timerId: number = -1;
  private lastTickMs: number = 0;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  private async bootstrap(): Promise<void> {
    await initStore(this.context);
    try {
      this.topPadVp = await statusBarTopVp(this.context, 44);
    } catch (e) {
      this.topPadVp = 44;
    }
    this.vpnRunning = AppStorage.get<boolean>('vpnRunning') ?? false;
    this.render();
    this.startTimer();
  }

  private startTimer(): void {
    if (this.timerId >= 0) {
      return;
    }
    this.lastTickMs = Date.now();
    this.timerId = setInterval(() => {
      this.tick();
    }, SAMPLE_INTERVAL_MS);
  }

  private stopTimer(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /** 一次采样:读 AppStorage 的实时速率(字节/秒),推环、累计、重算柱高 */
  private tick(): void {
    if (this.paused) {
      return;
    }
    const now: number = Date.now();
    const gap: number = this.lastTickMs > 0 ? Math.round((now - this.lastTickMs) / SAMPLE_INTERVAL_MS) : 1;
    this.lastTickMs = now;
    // 定时器被系统挂起(后台/省电)时补齐:曲线保持等间隔,不会出现长缺口
    if (gap > 1) {
      this.downSeries.fill(gap - 1);
      this.upSeries.fill(gap - 1);
    }
    const down: number = AppStorage.get<number>('vpnDownSpeed') ?? 0;
    const up: number = AppStorage.get<number>('vpnUpSpeed') ?? 0;
    this.downSeries.push(down);
    this.upSeries.push(up);
    this.totals.add(up, down);
    this.vpnRunning = AppStorage.get<boolean>('vpnRunning') ?? false;
    this.render();
  }

  /** 把模型算好的柱高写进 @State(ArkUI 只认整体替换) */
  private render(): void {
    const downMax: number = niceMax(this.downSeries.max());
    const upMax: number = niceMax(this.upSeries.max());
    const paddedDown: Array<number> = this.downSeries.padded();
    const paddedUp: Array<number> = this.upSeries.padded();
    const track: number = 92;
    const db: Array<number> = [];
    const ub: Array<number> = [];
    for (let i = 0; i < paddedDown.length; i++) {
      db.push(barHeight(paddedDown[i], downMax, track));
      ub.push(barHeight(paddedUp[i], upMax, track));
    }
    this.downBars = db;
    this.upBars = ub;
    this.curDown = this.downSeries.latest();
    this.curUp = this.upSeries.latest();
    this.maxDownText = formatSpeed(downMax);
    this.maxUpText = formatSpeed(upMax);
    this.peakDown = this.totals.peakDown;
    this.peakUp = this.totals.peakUp;
    this.totalDown = this.totals.down;
    this.totalUp = this.totals.up;
  }

  private async runDownload(): Promise<void> {
    if (this.downTesting) {
      return;
    }
    this.downTesting = true;
    this.downResult = null;
    try {
      this.downResult = await downloadTest(DOWN_BYTES, SPEED_TIMEOUT_MS);
    } finally {
      this.downTesting = false;
    }
  }

  private async runUpload(): Promise<void> {
    if (this.upTesting) {
      return;
    }
    this.upTesting = true;
    this.upResult = null;
    try {
      this.upResult = await uploadTest(UP_BYTES, SPEED_TIMEOUT_MS);
    } finally {
      this.upTesting = false;
    }
  }

  private verdictColor(mbps: number): ResourceColor {
    const v: string = speedVerdict(mbps);
    if (v === SPEED_FAST || v === SPEED_GOOD) {
      return $r('app.color.success');
    }
    if (v === SPEED_FAIR) {
      return $r('app.color.warning');
    }
    if (v === SPEED_SLOW) {
      return $r('app.color.error');
    }
    return $r('app.color.text_secondary');
  }

  private verdictText(mbps: number): ResourceStr {
    const v: string = speedVerdict(mbps);
    if (v === SPEED_FAST) {
      return $r('app.string.speed_verdict_fast');
    }
    if (v === SPEED_GOOD) {
      return $r('app.string.speed_verdict_good');
    }
    if (v === SPEED_FAIR) {
      return $r('app.string.speed_verdict_fair');
    }
    return $r('app.string.speed_verdict_slow');
  }

  @Builder
  header() {
    Row({ space: 10 }) {
      Button() {
        Text('‹').fontSize(26).fontColor($r('app.color.text_primary'))
      }
      .width(36).height(36).backgroundColor(Color.Transparent)
      .onClick(() => { router.back(); })

      Column({ space: 1 }) {
        Text($r('app.string.traffic_title'))
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text($r('app.string.traffic_subtitle'))
          .fontSize(11).fontColor($r('app.color.text_secondary'))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      Text(this.paused ? $r('app.string.traffic_resume') : $r('app.string.traffic_pause'))
        .fontSize(12).fontColor($r('app.color.primary'))
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .onClick(() => {
          this.paused = !this.paused;
          this.lastTickMs = Date.now();
        })
    }
    .width('100%')
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
  }

  @Builder
  liveCard() {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text(this.vpnRunning ? $r('app.string.diag_mode_tunnel') : $r('app.string.diag_mode_direct'))
          .fontSize(10.5)
          .fontColor(this.vpnRunning ? $r('app.color.success') : $r('app.color.warning'))
        Blank()
        Text(this.paused ? $r('app.string.traffic_paused_hint') : $r('app.string.traffic_live_hint'))
          .fontSize(10.5).fontColor($r('app.color.text_secondary'))
      }.width('100%')

      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text($r('app.string.traffic_down')).fontSize(11).fontColor($r('app.color.text_secondary'))
          Text(formatSpeed(this.curDown))
            .fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(`${$r('app.string.traffic_peak')} ${formatSpeed(this.peakDown)}`)
            .fontSize(10).fontColor($r('app.color.text_secondary'))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column({ space: 2 }) {
          Text($r('app.string.traffic_up')).fontSize(11).fontColor($r('app.color.text_secondary'))
          Text(formatSpeed(this.curUp))
            .fontSize(19).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
          Text(`${$r('app.string.traffic_peak')} ${formatSpeed(this.peakUp)}`)
            .fontSize(10).fontColor($r('app.color.text_secondary'))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')

      Divider().color($r('app.color.hairline'))
      Row({ space: 8 }) {
        Text(`${$r('app.string.traffic_session')} ↓ ${formatBytes(this.totalDown)} · ↑ ${formatBytes(this.totalUp)}`)
          .fontSize(10.5).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Text($r('app.string.traffic_reset'))
          .fontSize(10.5).fontColor($r('app.color.primary'))
          .onClick(() => {
            this.downSeries.reset();
            this.upSeries.reset();
            this.totals.reset();
            this.render();
          })
      }.width('100%')
    }
    .width('100%').padding(14)
    .backgroundColor($r('app.color.surface')).borderRadius(UiSpec.CARD_RADIUS)
  }

  @Builder
  chart(label: ResourceStr, bars: Array<number>, color: ResourceColor, maxText: string,
    latest: number) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(label).fontSize(11.5).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Text(maxText).fontSize(10).fontColor($r('app.color.text_secondary'))
        Text(formatSpeed(latest)).fontSize(11.5).fontColor(color)
      }.width('100%')
      Row({ space: 1 }) {
        ForEach(bars, (h: number, idx: number) => {
          Column()
            .layoutWeight(1)
            .height(h > 0 ? h : 1)
            .backgroundColor(h > 0 ? color : $r('app.color.hairline'))
            .borderRadius(1)
        }, (h: number, idx: number) => `${idx}_${h.toFixed(1)}`)
      }
      .width('100%')
      .height(92)
      .alignItems(VerticalAlign.Bottom)
      .backgroundColor($r('app.color.app_background'))
      .borderRadius(8)
      .padding({ left: 4, right: 4, top: 4, bottom: 4 })
    }
    .width('100%').padding(14)
    .backgroundColor($r('app.color.surface')).borderRadius(UiSpec.CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  speedCard(title: ResourceStr, testing: boolean, result: SpeedResult | null,
    hint: ResourceStr, onRun: () => void, kind: string) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(title).fontSize(13).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Button(testing ? $r('app.string.speed_testing') : $r('app.string.speed_start'))
          .height(30).fontSize(11.5)
          .enabled(!testing)
          .backgroundColor(testing ? $r('app.color.control_disabled') : $r('app.color.primary'))
          .onClick(onRun)
      }.width('100%')

      if (result !== null && result.ok) {
        Row({ space: 8 }) {
          Text(formatMbps(result.mbps))
            .fontSize(24).fontWeight(FontWeight.Medium).fontColor(this.verdictColor(result.mbps))
          Text('Mbps').fontSize(11).fontColor($r('app.color.text_secondary'))
          Blank()
          Column({ space: 1 }) {
            Text(this.verdictText(result.mbps))
              .fontSize(10.5).fontColor(this.verdictColor(result.mbps))
            Text(`${formatBytes(result.bytes)} / ${(result.ms / 1000).toFixed(1)}s`)
              .fontSize(10).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.End)
        }.width('100%')
      } else if (result !== null) {
        Text($r('app.string.speed_failed', result.error))
          .fontSize(11).fontColor($r('app.color.error')).width('100%')
      } else {
        Text(hint).fontSize(10.5).fontColor($r('app.color.text_secondary')).width('100%')
      }
    }
    .width('100%').padding(14)
    .backgroundColor($r('app.color.surface')).borderRadius(UiSpec.CARD_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column({ space: 12 }) {
          this.liveCard()
          this.chart($r('app.string.traffic_down'), this.downBars, $r('app.color.primary'),
            this.maxDownText, this.curDown)
          this.chart($r('app.string.traffic_up'), this.upBars, $r('app.color.success'),
            this.maxUpText, this.curUp)
          this.speedCard($r('app.string.speed_down_title'), this.downTesting, this.downResult,
            $r('app.string.speed_down_hint'), () => { void this.runDownload(); }, 'down')
          this.speedCard($r('app.string.speed_up_title'), this.upTesting, this.upResult,
            $r('app.string.speed_up_hint'), () => { void this.runUpload(); }, 'up')
          Text($r('app.string.traffic_footer_note'))
            .fontSize(10.5).fontColor($r('app.color.text_secondary'))
            .width('100%').padding({ top: 2, bottom: 20 })
        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 8 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%').height('100%')
    .backgroundColor($r('app.color.app_background'))
    .padding({ top: this.topPadVp })
  }
}
