import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import { statusBarTopVp } from '../common/PageTopInset';
import { UiSpec } from '../common/UiSpec';
import { initStore } from '../model/Store';
import {
  CAT_ALL, CAT_AI, CAT_STREAMING, CAT_COMMON, STATE_IDLE, STATE_TESTING, STATE_AVAILABLE,
  STATE_RESTRICTED, STATE_UNAVAILABLE, ProbeResult, ServiceDef, ServiceOutcome, DiagnosticsSummary,
  probeUrlsFor, classify, countryFlag, summarize, servicesOfCategory
} from '../core/ServiceDiagnostics';
import { httpGet, ProbeResponse, PROBE_UA } from '../utils/HttpProbe';
import { LandingIpInfo, queryLandingIp, cachedLandingIp } from '../utils/LandingIp';

/** 单次探测超时对齐 OwnBox withTimeoutOrNull(5000ms) */
const PROBE_TIMEOUT_MS: number = 5000;
/** 并发上限对齐 OwnBox Semaphore(6);手机小核跑 6 个 TLS 握手会互相拖慢,取 4 更稳 */
const PROBE_CONCURRENCY: number = 4;
/** 正文截断:诊断只看特征串,不需要整页 HTML */
const PROBE_MAX_BODY: number = 65536;

@Entry
@Component
struct DiagnosticsPage {
  /** 顶部让位:与其它二级页一致,不吃状态栏 */
  @State topPadVp: number = 44;
  @State category: string = CAT_ALL;
  @State records: Array<DiagRecord> = [];
  @State running: boolean = false;
  @State vpnRunning: boolean = false;
  @State landing: LandingIpInfo | null = null;
  @State landingLoading: boolean = false;
  @State landingError: string = '';
  @State summary: DiagnosticsSummary = new DiagnosticsSummary();
  @State litKey: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    await initStore(this.context);
    try {
      this.topPadVp = await statusBarTopVp(this.context, 44);
    } catch (e) {
      this.topPadVp = 44;
    }
    this.vpnRunning = AppStorage.get<boolean>('vpnRunning') ?? false;
    this.rebuildRecords();
    const cached = cachedLandingIp();
    if (cached !== null) {
      this.landing = cached;
    }
    // 已连接:进来就自动跑一轮(与 OwnBox 打开诊断页即自检的体验一致);
    // 未连接:只查一次出口 IP(直连 IP 也有参考价值),服务检测等用户手动点。
    if (this.vpnRunning) {
      void this.refreshLanding(true);
      void this.runAll();
    } else {
      void this.refreshLanding(false);
    }
  }

  /** 按当前分类重建列表(保留已测结果) */
  private rebuildRecords(): void {
    const defs: Array<ServiceDef> = servicesOfCategory(this.category);
    const old = this.records;
    const next: Array<DiagRecord> = [];
    for (let i = 0; i < defs.length; i++) {
      const def = defs[i];
      const prev = old.find((r: DiagRecord) => r.id === def.id);
      const rec = new DiagRecord();
      rec.id = def.id;
      rec.name = def.name;
      rec.category = def.category;
      if (prev !== undefined) {
        rec.state = prev.state;
        rec.region = prev.region;
        rec.latencyMs = prev.latencyMs;
        rec.reason = prev.reason;
        rec.atText = prev.atText;
      }
      next.push(rec);
    }
    this.records = next;
    this.refreshSummary();
  }

  private refreshSummary(): void {
    const states: Array<string> = this.records.map((r: DiagRecord) => r.state);
    this.summary = summarize(states);
  }

  private updateRecord(id: string, state: string, region: string, latencyMs: number,
    reason: string, atText: string): void {
    const idx = this.records.findIndex((r: DiagRecord) => r.id === id);
    if (idx < 0) {
      return;
    }
    const rec = this.records[idx];
    rec.state = state;
    rec.region = region;
    rec.latencyMs = latencyMs;
    rec.reason = reason;
    if (atText.length > 0) {
      rec.atText = atText;
    }
    this.records = this.records.slice();
    this.refreshSummary();
  }

  private clockText(): string {
    const d = new Date();
    const pad = (v: number): string => v < 10 ? `0${v}` : `${v}`;
    return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  /** 单服务探测:按 probeUrlsFor 的顺序发请求,再交给纯模型判定 */
  private async probeService(id: string): Promise<void> {
    this.updateRecord(id, STATE_TESTING, '', 0, '', '');
    const urls: Array<string> = probeUrlsFor(id);
    const probes: Array<ProbeResult> = [];
    const started = Date.now();
    for (let i = 0; i < urls.length; i++) {
      const url = urls[i];
      if (url.length === 0) {
        continue;
      }
      const resp: ProbeResponse = await httpGet(url, PROBE_TIMEOUT_MS, PROBE_UA, PROBE_MAX_BODY);
      probes.push(ProbeResult.of(url, resp.ok, resp.status, resp.body, resp.error));
      // 主请求失败就没必要再打后续接口(Netflix 例外:三个 title 任一可达即算可用)
      if (!resp.ok && id !== 'netflix') {
        break;
      }
      // B 站只在「-10403 地区限制」时才需要走港澳线路复测
      if (id === 'bilibili' && i === 0 && resp.body.indexOf('-10403') < 0) {
        break;
      }
    }
    const cost = Date.now() - started;
    const outcome: ServiceOutcome = classify(id, probes, cost);
    this.updateRecord(id, outcome.state, outcome.region, cost, outcome.reason, this.clockText());
  }

  private async runAll(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    const ids: Array<string> = this.records.map((r: DiagRecord) => r.id);
    for (let i = 0; i < ids.length; i++) {
      this.updateRecord(ids[i], STATE_TESTING, '', 0, '', '');
    }
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < ids.length) {
        const id = ids[cursor];
        cursor++;
        await this.probeService(id);
      }
    };
    const workers: Array<Promise<void>> = [];
    for (let i = 0; i < PROBE_CONCURRENCY; i++) {
      workers.push(worker());
    }
    await Promise.all(workers);
    this.running = false;
    this.refreshSummary();
  }

  private async refreshLanding(force: boolean): Promise<void> {
    if (this.landingLoading) {
      return;
    }
    this.landingLoading = true;
    this.landingError = '';
    try {
      const info = await queryLandingIp(force, PROBE_TIMEOUT_MS + 2000);
      if (info.ip.length > 0) {
        this.landing = info;
        this.landingError = '';
      } else {
        this.landingError = 'landing_ip_failed';
      }
    } catch (e) {
      this.landingError = 'landing_ip_failed';
    } finally {
      this.landingLoading = false;
    }
  }

  private stateColor(state: string): ResourceColor {
    if (state === STATE_AVAILABLE) {
      return $r('app.color.success');
    }
    if (state === STATE_RESTRICTED) {
      return $r('app.color.warning');
    }
    if (state === STATE_UNAVAILABLE) {
      return $r('app.color.error');
    }
    return $r('app.color.text_secondary');
  }

  private stateText(state: string): ResourceStr {
    if (state === STATE_TESTING) {
      return $r('app.string.diag_state_testing');
    }
    if (state === STATE_AVAILABLE) {
      return $r('app.string.diag_state_available');
    }
    if (state === STATE_RESTRICTED) {
      return $r('app.string.diag_state_restricted');
    }
    if (state === STATE_UNAVAILABLE) {
      return $r('app.string.diag_state_unavailable');
    }
    return $r('app.string.diag_state_idle');
  }

  private landingLine(): string {
    const info = this.landing;
    if (info === null) {
      return '';
    }
    const parts: Array<string> = [];
    if (info.country.length > 0) {
      parts.push(info.country);
    }
    if (info.city.length > 0 && info.city !== info.country) {
      parts.push(info.city);
    }
    if (info.isp.length > 0) {
      parts.push(info.isp);
    }
    return parts.join(' · ');
  }

  private categoryLabel(cat: string): ResourceStr {
    if (cat === CAT_AI) {
      return $r('app.string.diag_cat_ai');
    }
    if (cat === CAT_STREAMING) {
      return $r('app.string.diag_cat_streaming');
    }
    if (cat === CAT_COMMON) {
      return $r('app.string.diag_cat_common');
    }
    return $r('app.string.diag_cat_all');
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
        Text($r('app.string.diag_title'))
          .fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text($r('app.string.diag_subtitle'))
          .fontSize(11).fontColor($r('app.color.text_secondary'))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      Button($r('app.string.diag_test_all'))
        .height(32).fontSize(12)
        .enabled(!this.running)
        .backgroundColor(this.running ? $r('app.color.control_disabled') : $r('app.color.primary'))
        .onClick(() => { void this.runAll(); })
    }
    .width('100%')
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
  }

  @Builder
  landingCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text($r('app.string.diag_landing_ip'))
          .fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
        Text(this.vpnRunning ? $r('app.string.diag_mode_tunnel')
          : $r('app.string.diag_mode_direct'))
          .fontSize(10.5)
          .fontColor(this.vpnRunning ? $r('app.color.success') : $r('app.color.warning'))
        Text($r('app.string.diag_refresh'))
          .fontSize(11).fontColor($r('app.color.primary'))
          .onClick(() => { void this.refreshLanding(true); })
      }.width('100%')

      if (this.landingLoading && this.landing === null) {
        Text($r('app.string.diag_landing_loading'))
          .fontSize(13).fontColor($r('app.color.text_secondary'))
      } else if (this.landing !== null) {
        Row({ space: 8 }) {
          Text(this.landing.flag()).fontSize(24)
          Column({ space: 2 }) {
            Text(this.landing.ip)
              .fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary')).fontFamily('monospace')
            Text(this.landingLine())
              .fontSize(11).fontColor($r('app.color.text_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Column({ space: 2 }) {
            Text(`${this.landing.durationMs} ms`)
              .fontSize(12).fontColor($r('app.color.text_primary'))
            Text(this.landing.countryCode.length > 0 ? this.landing.countryCode : '--')
              .fontSize(11).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.End)
        }.width('100%')
      } else {
        Text(this.landingError.length > 0 ? $r('app.string.diag_landing_failed')
          : $r('app.string.diag_landing_idle'))
          .fontSize(13).fontColor($r('app.color.warning'))
      }

      if (!this.vpnRunning) {
        Text($r('app.string.diag_direct_hint'))
          .fontSize(10.5).fontColor($r('app.color.text_secondary')).width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(UiSpec.CARD_RADIUS)
  }

  @Builder
  chips() {
    Row({ space: 8 }) {
      ForEach([CAT_ALL, CAT_AI, CAT_STREAMING, CAT_COMMON], (cat: string) => {
        Text(this.categoryLabel(cat))
          .fontSize(12)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.category === cat ? $r('app.color.primary') : $r('app.color.surface'))
          .fontColor(this.category === cat ? $r('app.color.surface') : $r('app.color.text_primary'))
          .borderRadius(14)
          .onClick(() => {
            this.category = cat;
            this.rebuildRecords();
          })
      }, (cat: string) => cat)
    }.width('100%')
  }

  @Builder
  summaryLine() {
    Row({ space: 10 }) {
      if (this.summary.available > 0) {
        Text(`✓ ${this.summary.available}`).fontSize(11.5).fontColor($r('app.color.success'))
      }
      if (this.summary.restricted > 0) {
        Text(`! ${this.summary.restricted}`).fontSize(11.5).fontColor($r('app.color.warning'))
      }
      if (this.summary.unavailable > 0) {
        Text(`✕ ${this.summary.unavailable}`).fontSize(11.5).fontColor($r('app.color.error'))
      }
      if (this.summary.testing > 0) {
        Text($r('app.string.diag_state_testing')).fontSize(11.5).fontColor($r('app.color.text_secondary'))
      }
      Blank()
      Text(this.running ? $r('app.string.diag_running_hint') : '')
        .fontSize(10.5).fontColor($r('app.color.text_secondary'))
    }.width('100%')
  }

  @Builder
  serviceRow(rec: DiagRecord) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(rec.name)
            .fontSize(13.5).fontColor($r('app.color.text_primary'))
          if (rec.region.length > 0) {
            Text(`${countryFlag(rec.region)} ${rec.region}`)
              .fontSize(10.5).fontColor($r('app.color.text_secondary'))
          }
        }.width('100%')
        Text(rec.atText.length > 0
          ? `${rec.atText}${rec.latencyMs > 0 ? ` · ${rec.latencyMs} ms` : ''}`
          : (rec.state === STATE_IDLE ? $r('app.string.diag_state_idle') : ''))
          .fontSize(10.5).fontColor($r('app.color.text_secondary')).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      Text(this.stateText(rec.state))
        .fontSize(10.5)
        .fontColor(this.stateColor(rec.state))
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(9)
        .backgroundColor($r('app.color.app_background'))
    }
    .width('100%')
    .padding({ top: 9, bottom: 9, left: 14, right: 14 })
    .backgroundColor(this.litKey === rec.id ? $r('app.color.surface_selected') : $r('app.color.surface'))
    .borderRadius(10)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = rec.id;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => {
      if (this.running || rec.state === STATE_TESTING) {
        return;
      }
      void this.probeService(rec.id);
    })
  }

  build() {
    Column() {
      this.header()
      Scroll() {
        Column({ space: 12 }) {
          this.landingCard()
          this.chips()
          this.summaryLine()
          Column({ space: 6 }) {
            ForEach(this.records, (rec: DiagRecord) => {
              this.serviceRow(rec)
            }, (rec: DiagRecord) => `${rec.id}_${rec.state}_${rec.atText}`)
          }.width('100%')
          Text($r('app.string.diag_footer_note'))
            .fontSize(10.5).fontColor($r('app.color.text_secondary'))
            .width('100%').padding({ top: 4, bottom: 20 })
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

/** 服务行的可变视图模型(ArkUI 通过整体替换数组触发刷新) */
class DiagRecord {
  id: string = '';
  name: string = '';
  category: string = '';
  state: string = STATE_IDLE;
  region: string = '';
  latencyMs: number = 0;
  reason: string = '';
  atText: string = '';
}
