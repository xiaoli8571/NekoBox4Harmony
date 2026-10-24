import http from '@ohos.net.http';
import { statusBarTopVp } from '../common/PageTopInset';
import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';
import { formatBytes, formatSpeed } from '../utils/TrafficStats';
import { AppSettings } from '../model/Profile';
import { initStore, loadSettings } from '../model/Store';
import {
  ClashConnItem, RouteEvidence, parseConnections, classifyChain, filterConnections,
  buildRouteEvidence, evidenceSummaryLine,
  CHAIN_DIRECT, CHAIN_PROXY, CHAIN_REJECT
} from '../model/ConnectionView';

/**
 * 连接列表 —— REDESIGN-PLAN-2026-10-23.md §10.1/§10.2(P5/W19)。
 *
 * 只渲染真实连接证据(model/ConnectionView 解析内核 clash API 原文):
 * 空字段显示「未提供」,rulePayload 内核没给就不伪造;点击行弹出
 * 「为什么走这条线路」证据卡(目标→规则原文→策略组链→最终节点+运行revision+采集时间)。
 * 筛选只提供实际采集到的分类(direct/proxy/reject),不推测应用归属。
 */

interface ConnectionsResponse {
  uploadTotal: number;
  downloadTotal: number;
  connections: Array<Record<string, Object>>;
}

async function apiCall(settings: AppSettings, method: string, path: string): Promise<string> {
  const client = http.createHttp();
  try {
    const headers: Record<string, string> = {};
    if (settings.clashApiSecret.length > 0) {
      headers['Authorization'] = `Bearer ${settings.clashApiSecret}`;
    }
    const resp = await client.request(`http://127.0.0.1:${settings.clashApiPort}${path}`, {
      method: method === 'DELETE' ? http.RequestMethod.DELETE : http.RequestMethod.GET,
      header: headers,
      connectTimeout: 1500,
      readTimeout: 1500,
      expectDataType: http.HttpDataType.STRING
    });
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    return `${resp.result}`;
  } finally {
    client.destroy();
  }
}

@Entry
@Component
struct ConnectionsPage {
  @State conns: Array<ClashConnItem> = [];
  /** 顶部让位:运行时状态栏高度(2026-10-24 用户要求所有页面不得与状态栏重叠) */
  @State topPadVp: number = 44;
  @State lastError: ResourceStr = '';
  @State loading: boolean = true;
  @State uploadTotal: number = 0;
  @State downloadTotal: number = 0;
  @State uploadSpeed: number = 0;
  @State downloadSpeed: number = 0;
  @State settings: AppSettings = new AppSettings();
  /** W19:筛选(''=全部)与搜索(§10.1) */
  @State filterMode: string = '';
  @State searchText: string = '';
  /** 本批连接采集时间(证据卡用) */
  @State collectedAt: number = 0;
  /** 运行 revision(EntryAbility 写入的 vpnAppliedRevision;0=未知) */
  @StorageLink('vpnAppliedRevision') runningRevision: number = 0;
  /** HDS 点按光效:记录"当前被按下的那一个"的 key,松手/取消即清空(按下那一刻才亮) */
  @State litKey: string = '';
  @StorageLink('vpnRunning') @Watch('onRunningChange') isRunning: boolean = false;
  @StorageLink('vpnUpSpeed') fallbackUpSpeed: number = 0;
  @StorageLink('vpnDownSpeed') fallbackDownSpeed: number = 0;
  @StorageLink('vpnTotalUp') fallbackTotalUp: number = 0;
  @StorageLink('vpnTotalDown') fallbackTotalDown: number = 0;
  private timer: number = -1;
  private lastUpload: number = -1;
  private lastDownload: number = 0;

  async aboutToAppear(): Promise<void> {
    void statusBarTopVp(getContext(this) as common.UIAbilityContext).then((v: number): void => {
      this.topPadVp = v;
    });
    await initStore(getContext(this) as common.UIAbilityContext);
    this.settings = await loadSettings();
    this.updatePolling();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  onRunningChange(): void {
    this.updatePolling();
  }

  private updatePolling(): void {
    this.stopPolling();
    if (!this.isRunning || !this.settings.clashApiEnabled) {
      this.loading = false;
      this.conns = [];
      return;
    }
    this.loading = true;
    this.refresh();
    this.timer = setInterval(() => this.refresh(), 1000);
  }

  private stopPolling(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  async refresh(): Promise<void> {
    if (!this.isRunning || !this.settings.clashApiEnabled) {
      return;
    }
    try {
      const raw = await apiCall(this.settings, 'GET', '/connections');
      const response = JSON.parse(raw) as ConnectionsResponse;
      const upload = Number(response.uploadTotal);
      const download = Number(response.downloadTotal);
      this.uploadSpeed = this.lastUpload > 0 ? Math.max(0, upload - this.lastUpload) : 0;
      this.downloadSpeed = this.lastDownload > 0 ? Math.max(0, download - this.lastDownload) : 0;
      this.lastUpload = upload;
      this.lastDownload = download;
      this.uploadTotal = upload;
      this.downloadTotal = download;
      this.conns = parseConnections(raw);
      this.collectedAt = Date.now();
      this.lastError = '';
    } catch (e) {
      this.lastError = $r('app.string.connections_api_unavailable');
      this.uploadSpeed = this.fallbackUpSpeed;
      this.downloadSpeed = this.fallbackDownSpeed;
      this.uploadTotal = this.fallbackTotalUp;
      this.downloadTotal = this.fallbackTotalDown;
    } finally {
      this.loading = false;
    }
  }

  async closeConn(item: ClashConnItem): Promise<void> {
    try {
      await apiCall(this.settings, 'DELETE', `/connections/${encodeURIComponent(item.id)}`);
      promptAction.showToast({ message: $r('app.string.connection_closed') });
      this.refresh();
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.connection_close_failed', `${e}`) });
    }
  }

  /** 实际存在哪些分类(只给采集到的,§10.1) */
  private availableModes(): Array<string> {
    const modes: Array<string> = [];
    if (this.conns.some((c: ClashConnItem) => c.chainClass === CHAIN_PROXY)) {
      modes.push(CHAIN_PROXY);
    }
    if (this.conns.some((c: ClashConnItem) => c.chainClass === CHAIN_DIRECT)) {
      modes.push(CHAIN_DIRECT);
    }
    if (this.conns.some((c: ClashConnItem) => c.chainClass === CHAIN_REJECT)) {
      modes.push(CHAIN_REJECT);
    }
    return modes;
  }

  /** 筛选 chip 文案(P6:资源键;空 = 全部) */
  private modeLabel(mode: string): ResourceStr {
    if (mode === CHAIN_PROXY) {
      return $r('app.string.connection_chain_proxy');
    }
    if (mode === CHAIN_DIRECT) {
      return $r('app.string.connection_chain_direct');
    }
    if (mode === CHAIN_REJECT) {
      return $r('app.string.connection_chain_reject');
    }
    return $r('app.string.connection_filter_all');
  }

  /** ResourceStr → string(AlertDialog/Toast message 需要 string;无参场景) */
  private resText(r: ResourceStr): string {
    if (typeof r === 'string') {
      return r;
    }
    return (getContext(this) as common.UIAbilityContext).resourceManager.getStringSync(r as Resource);
  }

  /** 字段值:空 → 「未提供」(§10.2:不伪造);非空原样 */
  private fieldText(value: string): ResourceStr {
    return value.length > 0 ? value : $r('app.string.connection_not_provided');
  }

  /** 规则行:内核规则原文 + 策略链;两者都空 → 未提供(不伪造) */
  private ruleLine(c: ClashConnItem): ResourceStr {
    const chainText = c.chains.join(' → ');
    if (c.rule.length === 0 && chainText.length === 0) {
      return $r('app.string.connection_not_provided');
    }
    if (c.rule.length === 0) {
      return chainText;
    }
    if (chainText.length === 0) {
      return c.rule;
    }
    return `${c.rule}  ${chainText}`;
  }

  private chainBadge(item: ClashConnItem): ResourceStr {
    return this.modeLabel(item.chainClass);
  }

  private chainBadgeColor(item: ClashConnItem): Resource {
    if (item.chainClass === CHAIN_DIRECT) {
      return $r('app.color.success');
    }
    if (item.chainClass === CHAIN_REJECT) {
      return $r('app.color.error');
    }
    return $r('app.color.primary');
  }

  private startTimeText(item: ClashConnItem): string {
    if (!(item.start > 0)) {
      /* 返回值要进模板串拼接,必须给 string——Resource 进模板串会渲染成 [object Object] */
      return this.resText($r('app.string.connection_not_provided'));
    }
    const d = new Date(item.start);
    const hh = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
    const mm = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
    const ss = d.getSeconds() < 10 ? `0${d.getSeconds()}` : `${d.getSeconds()}`;
    return `${hh}:${mm}:${ss}`;
  }

  /** §10.2「为什么走这条线路」证据弹窗(message 是 string:标签经 getStringSync 现取,与通知同手法) */
  private showEvidence(item: ClashConnItem): void {
    const evidence: RouteEvidence = buildRouteEvidence(item, this.runningRevision, this.collectedAt);
    const collectedText = new Date(evidence.collectedAtMs).toLocaleString();
    const ctx = getContext(this) as common.UIAbilityContext;
    const res = ctx.resourceManager;
    const targetLabel = res.getStringSync($r('app.string.connection_evidence_target'));
    const networkLabel = res.getStringSync($r('app.string.connection_evidence_network'));
    const ruleLabel = res.getStringSync($r('app.string.connection_evidence_rule'));
    const payloadLabel = res.getStringSync($r('app.string.connection_evidence_rule_payload'));
    const chainsLabel = res.getStringSync($r('app.string.connection_evidence_chains'));
    const finalLabel = res.getStringSync($r('app.string.connection_evidence_final_node'));
    const revisionLabel = res.getStringSync($r('app.string.connection_evidence_revision'));
    const collectedLabel = res.getStringSync($r('app.string.connection_evidence_collected'));
    const notProvided = res.getStringSync($r('app.string.connection_not_provided'));
    const unknown = res.getStringSync($r('app.string.connection_evidence_unknown'));
    const payloadLine = evidence.rulePayloadProvided ? evidence.rulePayloadText : notProvided;
    AlertDialog.show({
      title: this.resText($r('app.string.connection_evidence_title')),
      message: `${targetLabel}: ${evidence.target.length > 0 ? evidence.target : notProvided}\n` +
        `${networkLabel}: ${evidence.network.length > 0 ? evidence.network : notProvided}\n` +
        `${ruleLabel}: ${evidence.ruleText.length > 0 ? evidence.ruleText : notProvided}\n` +
        `${payloadLabel}: ${payloadLine}\n` +
        `${chainsLabel}: ${evidence.chainList.length > 0 ? evidence.chainList.join(' → ') : notProvided}\n` +
        `${finalLabel}: ${evidence.finalNode.length > 0 ? evidence.finalNode : notProvided}\n` +
        `${revisionLabel}: ${evidence.runningRevision > 0 ? `r${evidence.runningRevision}` : unknown}\n` +
        `${collectedLabel}: ${collectedText}`,
      autoCancel: true,
      primaryButton: { value: $r('app.string.connection_evidence_close'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.notification_disconnect'),
        fontColor: $r('app.color.error'),
        action: () => this.closeConn(item)
      }
    });
  }

  build() {
    Column() {
      Column() {
        Row() {
          /* 返回:字符图标 → 系统符号(chevron_left);宿主从 Text 换成 Row
             —— 官方点光源宿主白名单里没有 Text,字符图标配了也不会亮(见 common/Effects.ets) */
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([$r('app.color.text_1')])
          }
          .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .visualEffect(pressLightEffect(this.litKey === 'back', false))
          .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) {
          this.litKey = 'back';
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.litKey = '';
        } })
          .onClick(() => { router.back(); })
          Text($r('app.string.connections_title_count',
            filterConnections(this.conns, this.filterMode, this.searchText).length))
            .fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button({ type: ButtonType.Normal, stateEffect: false }) {
            Text($r('app.string.refresh')).fontSize(14).fontColor($r('app.color.primary'))
          }
          .height(36).padding({ left: 10, right: 10 }).backgroundColor(Color.Transparent)
          .visualEffect(pressLightEffect(this.litKey === 'refresh', true))
          .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) {
          this.litKey = 'refresh';
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.litKey = '';
        } })
          .onClick(() => this.refresh())
        }
        .width('100%').padding(12)

        /* W19:搜索 + 分类筛选(仅实际采集到的分类) */
        TextInput({ text: this.searchText, placeholder: $r('app.string.connection_search_hint') })
          .fontSize(13)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface'))
          .margin({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 6 })
          .onChange((value: string) => { this.searchText = value; })
        Row({ space: 8 }) {
          Text($r('app.string.connection_filter_all'))
            .fontSize(12)
            .fontWeight(this.filterMode.length === 0 ? 700 : 400)
            .fontColor(this.filterMode.length === 0 ? $r('app.color.primary') : $r('app.color.text_secondary'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .height(44)
            .borderRadius(12)
            .backgroundColor(this.filterMode.length === 0 ? $r('app.color.surface') : Color.Transparent)
            .accessibilityText($r('app.string.connection_filter_all'))
            .onClick(() => { this.filterMode = ''; })
          ForEach(this.availableModes(), (mode: string) => {
            Text(this.modeLabel(mode))
              .fontSize(12)
              .fontWeight(this.filterMode === mode ? 700 : 400)
              .fontColor(this.filterMode === mode ? $r('app.color.primary') : $r('app.color.text_secondary'))
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .height(44)
              .borderRadius(12)
              .backgroundColor(this.filterMode === mode ? $r('app.color.surface') : Color.Transparent)
              .accessibilityText(this.resText(this.modeLabel(mode)))
              .onClick(() => { this.filterMode = mode; })
          }, (mode: string) => mode)
        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 8 })

        if (this.isRunning) {
          Text($r('app.string.traffic_speed_total', formatSpeed(this.uploadSpeed), formatSpeed(this.downloadSpeed), formatBytes(this.uploadTotal), formatBytes(this.downloadTotal)))
            .fontSize(12)
            .fontFamily('monospace')
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 10 })
        }

        if (this.loading) {
          Column({ space: 10 }) {
            LoadingProgress()
              .width(32)
              .height(32)
              .color($r('app.color.primary'))
            Text($r('app.string.connections_loading'))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 36, bottom: 20 })
        } else if (this.lastError !== '') {
          Column({ space: 8 }) {
            Text($r('app.string.connections_unavailable'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text(this.lastError)
              .fontSize(13)
              .fontColor($r('app.color.error'))
            Button($r('app.string.reload'))
              .height(36)
              .backgroundColor($r('app.color.primary'))
              .visualEffect(pressLightEffect(this.litKey === 'reload', true))
              .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) {
              this.litKey = 'reload';
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litKey = '';
            } })
              .onClick(() => {
                this.loading = true;
                this.refresh();
              })
          }
          .width('100%')
          .padding({ top: 28, bottom: 20 })
        }
      }
      .width('100%')

      List({ space: 6 }) {
        ForEach(filterConnections(this.conns, this.filterMode, this.searchText), (c: ClashConnItem) => {
          ListItem() {
            Column({ space: 2 }) {
              Row() {
                Text(this.fieldText(c.host))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(this.chainBadge(c))
                  .fontSize(10).fontWeight(600).fontColor(this.chainBadgeColor(c))
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .borderRadius(8)
                  .border({ width: 1, color: this.chainBadgeColor(c) })
                Text(this.fieldText(c.network))
                  .fontSize(11).fontColor($r('app.color.primary'))
              }.width('100%')

              Text(this.ruleLine(c))
                .fontSize(11).fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              Row() {
                Text(`↑ ${formatBytes(c.up)}  ↓ ${formatBytes(c.down)}  ${this.startTimeText(c)}`)
                  .fontSize(11).fontFamily('monospace')
                  .fontColor($r('app.color.text_secondary')).layoutWeight(1)
                /* 断开:滚动内容里的按钮只给点按光效,不加 .scale(缩放会让光源中心相对本行跑位) */
                Button({ type: ButtonType.Normal, stateEffect: false }) {
                  Text($r('app.string.notification_disconnect'))
                    .fontSize(12).fontColor($r('app.color.error'))
                }
                .height(28).padding({ left: 6, right: 6 }).backgroundColor(Color.Transparent)
                .visualEffect(pressLightEffect(this.litKey === `conn:${c.id}`, true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.litKey = `conn:${c.id}`;
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.litKey = '';
                  }
                })
                .onClick(() => this.closeConn(c))
              }.width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(UiSpec.GAP_MD)
            .borderRadius(UiSpec.CARD_RADIUS)
            .backgroundColor($r('app.color.surface'))
            .onClick(() => this.showEvidence(c))
          }
        }, (c: ClashConnItem) => `${c.id}:${c.up}:${c.down}`)
      }
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
        .scrollBar(BarState.On)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    /* 窗口为 layout-full-screen(内容要钻进状态栏)⇒ 本页自己让出状态栏高度 */
    .padding({ top: this.topPadVp })
    .backgroundColor($r('app.color.app_background'))
    .width('100%').height('100%').backgroundColor($r('app.color.app_background'))
  }
}
