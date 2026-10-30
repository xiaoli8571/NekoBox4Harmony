// SubscriptionPage.ets — 订阅页(REDESIGN-PLAN-2026-10-23.md §3.1/§3.3/§11.1-2/§4.5)
//
// 本文件是**独立页面组件**,由 Index 壳层作为新 tab 1 渲染(perapp 负责接线,不要动 Index.ets)。
// 页面只渲染 + 交互:**不做网络/存储副作用**——数据经 @Prop 由 Index 传入,
// 动作(添加/导入/更新单个/更新全部/删除)全部走 Index 注入的回调,避免与既有订阅逻辑重复。
// 行点击 → 详情:router.pushUrl('pages/SubDetailPage', params:{url}),参数键与
// SubDetailPage.ets:103-104 / Index.ets:1335 一致。
// 危险操作(删除订阅)用 AlertDialog 二次确认(Index.ets:798 同款)。
//
// 文案(P6/W21 i18n 收口):模型(model/SubscriptionList)只产 token+param,本页映射 $r;
// 对话框 message 需要 string 的,经 resourceManager.getStringSync 现取(resText/resFormat,
// 与 VpnExtAbility 通知同手法)。$r 键名编译期校验,不能动态拼键。
//
// ForEach 的 key 必须包含**所有被渲染字段**(Index.ets:87-90 的坑:只按 id 作 key 时,
// 原地改字段不会重跑构建器,真机上表现为行内容不刷新)。
// 无障碍(§13.3):行内 28 高的小按钮用 responseRegion 扩到 44×44 热区;顶栏动作名称由壳层给。

import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { UiSpec } from '../common/UiSpec';
import { SubInfo } from '../core/Subscriptions';
import {
  SubscriptionRowView, SubscriptionNodeCount, UpdateBatchSummary, PerSubOutcome,
  SummaryPart, buildRows, sortSubs, nodeCountMap, summaryParts,
  ROW_STATE_FAILED, ROW_STATE_UPDATING, ROW_STATE_EXPIRED, ROW_STATE_NEVER,
  EXPIRY_NEAR, EXPIRY_EXPIRED,
  LAST_UPDATED_JUST_NOW, LAST_UPDATED_MINUTES, LAST_UPDATED_HOURS, LAST_UPDATED_DAYS,
  AUTO_UPDATE_OFF, AUTO_UPDATE_EVERY_MINUTES, AUTO_UPDATE_DAILY, AUTO_UPDATE_EVERY_DAYS,
  AUTO_UPDATE_HOURLY, AUTO_UPDATE_EVERY_HOURS,
  EXPIRY_TOKEN_UNKNOWN, EXPIRY_TOKEN_EXPIRED_DAYS, EXPIRY_TOKEN_JUST_EXPIRED,
  EXPIRY_TOKEN_IN_DAYS, EXPIRY_TOKEN_DATE
} from '../model/SubscriptionList';

@Component
export struct SubscriptionPage {
  @State litKey: string = '';
  /** 订阅列表(Index.subscriptions 深拷贝传入,页面只读;§11.1 SubInfo) */
  @Prop subscriptions: Array<SubInfo> = [];
  /** 每个订阅的节点数(Index 用 SubscriptionList.nodeCountsFromSubUrls(profiles.map(subUrl)) 生成) */
  @Prop nodeCounts: Array<SubscriptionNodeCount> = [];
  /** 正在更新的订阅 url('' = 无):该行状态 updating、右侧按钮转圈禁用 */
  @Prop updatingUrl: string = '';
  /** 批量更新进行中:头部「更新全部」禁用并显示进度(§3.3 ACTION_UPDATE_ALL) */
  @Prop updatingAll: boolean = false;
  /** 网络可用(空态引导 §4.5;Index 传连接状态,默认按可用) */
  @Prop networkAvailable: boolean = true;
  /** 批量更新摘要计数(P6 起传结构化 UpdateBatchSummary,反馈条本页渲染) */
  @Prop batchSummaryModel: UpdateBatchSummary = new UpdateBatchSummary();
  /** 「更新全部」逐订阅结果行(§11.3:一个失败不覆盖其他) */
  @Prop batchOutcomes: Array<PerSubOutcome> = [];
  /** 反馈条是否可见(壳层在有摘要或失败时置真;dismiss 由页面记) */
  @Prop batchVisible: boolean = false;
  /** 批量更新失败原文(反馈条错误区**原样展示**,不吞错误;§11.3) */
  @Prop batchFailedMessages: Array<string> = [];

  // ---- 动作回调(Index 注入;页面自身不做 I/O) ----
  /** 添加/导入订阅(顶栏 ACTION_ADD + 空态主按钮) */
  onAdd: () => void = () => {};
  /** 从文件导入(空态) */
  onImport: () => void = () => {};
  /** 扫码添加(空态) */
  onScan: () => void = () => {};
  /** 手动添加(空态;Index 可接到导入/新增流程) */
  onManual: () => void = () => {};
  /** 更新单个订阅(Index 负责串行化 + markSub*,页面只回调) */
  onUpdateOne: (url: string) => void = (url: string) => {};
  /** 更新全部订阅 */
  onUpdateAll: () => void = () => {};
  /**
   * 行点击详情的**通知钩子**(Index 可记录/埋点/切状态)。
   * ⚠️ 跳转由本页负责(router.pushUrl)，Index 不要再次 push，否则会双跳。
   */
  onOpenDetail: (url: string) => void = (url: string) => {};
  /** 删除订阅(已过二次确认;Index 执行 removeSub + purge + refresh) */
  onDelete: (url: string) => void = (url: string) => {};
  /** 清空该订阅的节点(保留订阅记录;W18 危险操作,页面二次确认后回调) */
  onClearNodes: (url: string) => void = (url: string) => {};
  /** 反馈条快捷动作:查看节点(Index 切到节点页) */
  onViewNodes: () => void = () => {};
  /** 反馈条快捷动作:检测可用性(Index 触发全量测速;不强制连接) */
  onProbeAll: () => void = () => {};

  /** 错误展开状态(不吞错误:展开后原样显示 lastError) */
  @State expandedUrls: Array<string> = [];
  /** 行内「更多」展开(订阅详情/删除) */
  @State moreUrls: Array<string> = [];
  /** 反馈条手动关闭 */
  @State batchDismissed: boolean = false;
  /** 排序方式:'name' | 'recent'(模型 sortSubs);Index 可从订阅页 ⋮ 驱动(P4/W16),页面内点击同样回调 onSort */
  @Prop sortMode: string = 'name';
  /** 排序变更回调:Index 存 NavMemory 并回写 sortMode(P4: ⋮ 菜单「排序：名称/最近更新」) */
  onSort: (mode: string) => void = (mode: string) => {};
  /** 行选中回调(长按选中;Index 用于订阅页 ⋮ 的「更新选中/删除选中」) */
  onSelect: (url: string) => void = (url: string) => {};
  /** 当前选中的订阅(高亮;空串 = 未选中) */
  @Prop selectedUrl: string = '';
  /** 首页要显示哪些订阅(复选框选中项);空数组 = 全部订阅都显示 */
  @Prop homeUrls: Array<string> = [];
  /** 勾选/取消某个订阅 */
  onToggleHome: (url: string) => void = (url: string) => {};
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  private rows(): Array<SubscriptionRowView> {
    const raw = buildRows(this.subscriptions, nodeCountMap(this.nodeCounts), Date.now(),
      this.updatingUrls());
    return sortSubs(raw, this.sortMode);
  }

  private updatingUrls(): Set<string> {
    const set = new Set<string>();
    if (this.updatingUrl.length > 0) {
      set.add(this.updatingUrl);
    }
    return set;
  }

  private isExpanded(url: string): boolean {
    return this.expandedUrls.indexOf(url) >= 0;
  }

  private toggleExpanded(url: string): void {
    const idx = this.expandedUrls.indexOf(url);
    if (idx >= 0) {
      this.expandedUrls.splice(idx, 1);
    } else {
      this.expandedUrls.push(url);
    }
  }

  private isMoreOpen(url: string): boolean {
    return this.moreUrls.indexOf(url) >= 0;
  }

  private toggleMore(url: string): void {
    const idx = this.moreUrls.indexOf(url);
    if (idx >= 0) {
      this.moreUrls.splice(idx, 1);
    } else {
      this.moreUrls.push(url);
    }
  }

  /** ResourceStr → string(AlertDialog message 需要 string;无参场景) */
  private resText(r: ResourceStr): string {
    if (typeof r === 'string') {
      return r;
    }
    return this.context.resourceManager.getStringSync(r as Resource);
  }

  /** 带参资源 → string(getStringSync 不展开 %n$s/%n$d,手动替换;只支持顺序占位符) */
  private resFormat(res: Resource, ...args: Array<string | number>): string {
    let text = this.context.resourceManager.getStringSync(res);
    for (let i = 0; i < args.length; i++) {
      const sToken = `%${i + 1}$s`;
      const dToken = `%${i + 1}$d`;
      text = text.split(sToken).join(`${args[i]}`);
      text = text.split(dToken).join(`${args[i]}`);
    }
    return text;
  }

  /** 头部禁用文案(§3.3:不可用必须给原因;空 = 无提示) */
  private updateAllHint(): ResourceStr {
    if (this.updatingAll) {
      return $r('app.string.subscription_updating_all', this.subscriptions.length);
    }
    if (!this.networkAvailable && this.subscriptions.length > 0) {
      return $r('app.string.subscription_offline_hint');
    }
    return '';
  }

  /** lastUpdated token → $r */
  private lastUpdatedText(row: SubscriptionRowView): ResourceStr {
    if (row.lastUpdatedToken === LAST_UPDATED_JUST_NOW) {
      return $r('app.string.sub_last_updated_just_now');
    }
    if (row.lastUpdatedToken === LAST_UPDATED_MINUTES) {
      return $r('app.string.sub_last_updated_minutes_ago', row.lastUpdatedParam);
    }
    if (row.lastUpdatedToken === LAST_UPDATED_HOURS) {
      return $r('app.string.sub_last_updated_hours_ago', row.lastUpdatedParam);
    }
    if (row.lastUpdatedToken === LAST_UPDATED_DAYS) {
      return $r('app.string.sub_last_updated_days_ago', row.lastUpdatedParam);
    }
    return $r('app.string.sub_last_updated_never');
  }

  /** autoUpdate token → $r */
  private autoUpdateText(row: SubscriptionRowView): ResourceStr {
    if (row.autoUpdateToken === AUTO_UPDATE_EVERY_MINUTES) {
      return $r('app.string.sub_auto_update_every_minutes', row.autoUpdateParam);
    }
    if (row.autoUpdateToken === AUTO_UPDATE_DAILY) {
      return $r('app.string.sub_auto_update_daily');
    }
    if (row.autoUpdateToken === AUTO_UPDATE_EVERY_DAYS) {
      return $r('app.string.sub_auto_update_every_days', row.autoUpdateParam);
    }
    if (row.autoUpdateToken === AUTO_UPDATE_HOURLY) {
      return $r('app.string.sub_auto_update_hourly');
    }
    if (row.autoUpdateToken === AUTO_UPDATE_EVERY_HOURS) {
      return $r('app.string.sub_auto_update_every_hours', row.autoUpdateParam);
    }
    return $r('app.string.sub_auto_update_off');
  }

  /** 流量:总量未知用专门键(§11.1),已知则数字串拼接(单位不本地化) */
  private trafficText(row: SubscriptionRowView): ResourceStr {
    if (row.trafficTotalText.length === 0) {
      return $r('app.string.sub_traffic_total_unknown', row.trafficUsedText);
    }
    return `${row.trafficUsedText} / ${row.trafficTotalText}`;
  }

  /** 到期 token → $r */
  private expiryText(row: SubscriptionRowView): ResourceStr {
    if (row.expiryToken === EXPIRY_TOKEN_EXPIRED_DAYS) {
      return $r('app.string.sub_expiry_expired_days', row.expiryParam);
    }
    if (row.expiryToken === EXPIRY_TOKEN_JUST_EXPIRED) {
      return $r('app.string.sub_expiry_just_expired');
    }
    if (row.expiryToken === EXPIRY_TOKEN_IN_DAYS) {
      return $r('app.string.sub_expiry_in_days', row.expiryParam);
    }
    if (row.expiryToken === EXPIRY_TOKEN_DATE) {
      return $r('app.string.sub_expiry_on_date', row.expiryDateText);
    }
    return $r('app.string.sub_expiry_unknown');
  }

  /** 行状态徽标文案:state → sub_state_<state>(状态集合封闭,页面映射安全) */
  private statusText(row: SubscriptionRowView): ResourceStr {
    if (row.state === ROW_STATE_NEVER) {
      return $r('app.string.sub_state_never');
    }
    if (row.state === ROW_STATE_FAILED) {
      return $r('app.string.sub_state_failed');
    }
    if (row.state === ROW_STATE_UPDATING) {
      return $r('app.string.sub_state_updating');
    }
    if (row.state === ROW_STATE_EXPIRED) {
      return $r('app.string.sub_state_expired');
    }
    return $r('app.string.sub_state_ok');
  }

  /** 摘要段 → $r(kind 集合封闭) */
  private summaryPartText(part: SummaryPart): ResourceStr {
    if (part.kind === 'added') {
      return $r('app.string.sub_summary_added', part.value);
    }
    if (part.kind === 'removed') {
      return $r('app.string.sub_summary_removed', part.value);
    }
    if (part.kind === 'not_modified') {
      return $r('app.string.sub_summary_not_modified', part.value);
    }
    if (part.kind === 'skipped') {
      return $r('app.string.sub_summary_skipped', part.value);
    }
    if (part.kind === 'failed') {
      return $r('app.string.sub_summary_failed', part.value);
    }
    return $r('app.string.sub_summary_updated', part.value);
  }

  /** 逐订阅结果行 → ResourceStr(§11.3:成功/304/失败互不覆盖;失败原文经 %2$s 原样展示) */
  private outcomeLineOf(o: PerSubOutcome): ResourceStr {
    if (!o.ok) {
      return $r('app.string.sub_outcome_failed', o.name, o.error);
    }
    if (o.notModified) {
      return $r('app.string.sub_outcome_not_modified', o.name);
    }
    if (o.skipped > 0) {
      const skipText = this.resText($r('app.string.sub_summary_skipped', o.skipped));
      return this.resFormat($r('app.string.sub_outcome_changed'), o.name,
        `+${o.added} ~${o.updated} -${o.removed} ${skipText}`);
    }
    return this.resFormat($r('app.string.sub_outcome_changed'), o.name,
      `+${o.added} ~${o.updated} -${o.removed}`);
  }

  private openDetail(url: string): void {
    this.onOpenDetail(url);
    router.pushUrl({ url: 'pages/SubDetailPage', params: { url: url } });
  }

  private confirmDelete(row: SubscriptionRowView): void {
    AlertDialog.show({
      title: this.resText($r('app.string.subscription_delete_confirm_title')),
      message: this.resFormat($r('app.string.subscription_delete_confirm_body'), row.name, row.nodeCount),
      autoCancel: true,
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.subscription_row_delete'),
        fontColor: $r('app.color.error'),
        action: () => {
          this.toggleMore(row.url);
          this.onDelete(row.url);
        }
      }
    });
  }

  /** 清空节点二次确认(危险操作与更新分离,§11.1) */
  private confirmClearNodes(row: SubscriptionRowView): void {
    AlertDialog.show({
      title: this.resText($r('app.string.subscription_clear_nodes_confirm_title')),
      message: this.resFormat($r('app.string.subscription_clear_nodes_confirm_body'), row.name, row.nodeCount),
      autoCancel: true,
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.subscription_row_clear_nodes'),
        fontColor: $r('app.color.error'),
        action: () => {
          this.toggleMore(row.url);
          this.onClearNodes(row.url);
        }
      }
    });
  }

  private stateColor(row: SubscriptionRowView): Resource {
    if (row.state === ROW_STATE_FAILED || row.state === ROW_STATE_EXPIRED) {
      return $r('app.color.error');
    }
    if (row.state === ROW_STATE_UPDATING) {
      return $r('app.color.primary');
    }
    if (row.state === ROW_STATE_NEVER) {
      return $r('app.color.text_3');
    }
    return $r('app.color.success');
  }

  private expiryColor(row: SubscriptionRowView): Resource {
    if (row.expiryState === EXPIRY_EXPIRED) {
      return $r('app.color.error');
    }
    if (row.expiryState === EXPIRY_NEAR) {
      return $r('app.color.warning');
    }
    return $r('app.color.text_3');
  }

  private rowKey(row: SubscriptionRowView): string {
    // key 覆盖全部被渲染字段:任一变化都强制重跑行构建器(见文件头注释的 ArkUI 复用坑)
    return `${row.url}|${row.state}|${row.lastUpdatedToken}:${row.lastUpdatedParam}|` +
      `${row.trafficUsedText}/${row.trafficTotalText}|${row.autoUpdateToken}:${row.autoUpdateParam}|` +
      `${row.expiryToken}:${row.expiryParam}:${row.expiryDateText}|${row.nodeCount}|` +
      `${row.expandableError ? 1 : 0}|${this.isExpanded(row.url) ? 1 : 0}|${this.isMoreOpen(row.url) ? 1 : 0}`;
  }

  build() {
    Column() {
      // ---- 头部:订阅数 + 排序 + 更新全部(§3.1/§3.3;顶栏由壳层画,这里只是内容头) ----
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Text($r('app.string.subscription_page_title_count', this.subscriptions.length))
            .fontSize(16).fontWeight(800).fontColor($r('app.color.text_1'))
            .maxLines(1)
          if (this.updateAllHint() !== '') {
            Text(this.updateAllHint())
              .fontSize(11).fontColor($r('app.color.text_3'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.sortMode === 'name' ? $r('app.string.subscription_sort_name') : $r('app.string.subscription_sort_recent'))
          .fontSize(12).fontColor($r('app.color.primary'))
          .accessibilityText(this.sortMode === 'name'
            ? $r('app.string.subscription_sort_name') : $r('app.string.subscription_sort_recent'))
          .onClick(() => {
            this.onSort(this.sortMode === 'name' ? 'recent' : 'name');
          })

        if (this.updatingAll) {
          LoadingProgress().width(20).height(20).color($r('app.color.primary'))
        } else {
          Button($r('app.string.subscription_update_all'))
            .height(UiSpec.BTN_HEIGHT)
            .backgroundColor(this.litKey === 'pb:SubscriptionPage:1' ? $r('app.color.primary') : $r('app.color.surface'))
            .fontColor(this.litKey === 'pb:SubscriptionPage:1' ? $r('app.color.surface') : $r('app.color.text_1'))
            .enabled(this.subscriptions.length > 0 && this.networkAvailable && !this.updatingAll)
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
                this.litKey = 'pb:SubscriptionPage:1';
              } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                this.litKey = '';
              }
            })
            .onClick(() => this.onUpdateAll())
        }
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 4 })

      // ---- 批量更新反馈条(§11.3;失败原文原样展示) ----
      if (!this.batchDismissed && this.batchVisible &&
        (summaryParts(this.batchSummaryModel).length > 0 || this.batchFailedMessages.length > 0)) {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Row({ space: 10 }) {
              ForEach(summaryParts(this.batchSummaryModel), (part: SummaryPart, idx: number) => {
                Text(this.summaryPartText(part))
                  .fontSize(12.5)
                  .fontColor(part.kind === 'failed' ? $r('app.color.error') : $r('app.color.text_1'))
              }, (part: SummaryPart) => `${part.kind}:${part.value}`)
            }
            .layoutWeight(1)

            Text($r('app.string.subscription_batch_dismiss'))
              .fontSize(12).fontColor($r('app.color.primary'))
              .height(44)
              .accessibilityText($r('app.string.subscription_batch_dismiss'))
              .onClick(() => {
                this.batchDismissed = true;
              })
          }.width('100%')
          ForEach(this.batchOutcomes, (o: PerSubOutcome, idx: number) => {
            Text(this.outcomeLineOf(o))
              .fontSize(11.5)
              .fontColor(o.ok ? $r('app.color.text_2') : $r('app.color.error'))
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }, (o: PerSubOutcome) => `${o.name}:${o.ok}:${o.error}:${o.added}:${o.updated}:${o.removed}:${o.skipped}`)
          ForEach(this.batchFailedMessages, (msg: string, idx: number) => {
            Text(msg)
              .fontSize(11.5).fontColor($r('app.color.error'))
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }, (msg: string, idx: number) => `${idx}:${msg}`)
          /* §11.2:导入/更新成功后提供「查看节点 / 检测可用性」,不强制立即连接 */
          Row({ space: 16 }) {
            Text($r('app.string.subscription_action_view_nodes'))
              .fontSize(12.5).fontWeight(600).fontColor($r('app.color.primary'))
              .height(44)
              .accessibilityText($r('app.string.subscription_action_view_nodes'))
              .onClick(() => this.onViewNodes())
            Text($r('app.string.subscription_action_probe'))
              .fontSize(12.5).fontWeight(600).fontColor($r('app.color.primary'))
              .height(44)
              .accessibilityText($r('app.string.subscription_action_probe'))
              .onClick(() => this.onProbeAll())
          }.width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 8, bottom: 8 })
      }

      // ---- 空态引导(§4.5) ----
      if (this.subscriptions.length === 0) {
        Column({ space: 10 }) {
          Text(this.emptyTitle())
            .fontSize(16).fontWeight(700).fontColor($r('app.color.text_1'))
          Text(this.emptyBody())
            .fontSize(13).fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
          Button($r('app.string.subscription_empty_add'))
            .width('60%').height(UiSpec.BTN_HEIGHT)
            .backgroundColor($r('app.color.primary')).fontColor($r('app.color.surface'))
            .onClick(() => this.onAdd())
          Button($r('app.string.subscription_empty_scan'))
            .width('60%').height(36)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
            .onClick(() => this.onScan())
          Button($r('app.string.subscription_empty_import'))
            .width('60%').height(36)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
            .onClick(() => this.onImport())
          Button($r('app.string.subscription_empty_manual'))
            .width('60%').height(36)
            .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
            .onClick(() => this.onManual())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // ---- 订阅列表(§3.1 订阅页职责) ----
        List() {
          ForEach(this.rows(), (row: SubscriptionRowView) => {
            ListItem() {
              /* 2026-10-24 真机用户反馈:订阅行距过大 ⇒ 行内 space 与上下 padding 收紧 */
              Column({ space: 4 }) {
                Row({ space: 8 }) {
                  /* 首页显示开关:勾上就在首页显示这个订阅的分组与节点(全不勾 = 全部显示) */
                  Checkbox({ name: row.url, group: 'home_subs' })
                    .select(this.homeUrls.indexOf(row.url) >= 0)
                    .selectedColor($r('app.color.primary'))
                    .width(20).height(20)
                    .accessibilityText(this.homeUrls.indexOf(row.url) >= 0
                      ? $r('app.string.sub_home_check_on')
                      : $r('app.string.sub_home_check_off'))
                    .onChange((checked: boolean) => {
                      const shown: boolean = this.homeUrls.indexOf(row.url) >= 0;
                      if (checked !== shown) {
                        this.onToggleHome(row.url);
                      }
                    })
                  Column({ space: 1 }) {
                    /* ⚠️ 名字 Text 不能带 layoutWeight —— 它在内层 Column 里会被解释成
                       纵向权重,把整行撑到上千像素高(真机 P5 遗留 bug,2026-10-24 修复);
                       横向约束由外层 Column 的 layoutWeight(1) 承担 */
                    Text(row.name)
                      .fontSize(15).fontWeight(700).fontColor($r('app.color.text_1'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(row.url)
                      .fontSize(10).fontColor($r('app.color.text_3'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Text(this.statusText(row))
                    .fontSize(11).fontWeight(600).fontColor(this.stateColor(row))
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .borderRadius(10)
                    .border({ width: 1, color: this.stateColor(row) })
                }
                .width('100%')
                .onClick(() => this.openDetail(row.url))

                Row({ space: 8 }) {
                  Text($r('app.string.subscription_row_node_count', row.nodeCount))
                    .fontSize(11).fontColor($r('app.color.text_3'))
                  Text(this.lastUpdatedText(row))
                    .fontSize(11).fontColor($r('app.color.text_3'))
                  Text(this.trafficText(row))
                    .fontSize(11).fontWeight(600).fontColor($r('app.color.mono'))
                    .fontFamily('monospace')
                  Text(this.expiryText(row))
                    .fontSize(11).fontColor(this.expiryColor(row))
                }
                .width('100%')
                .onClick(() => this.openDetail(row.url))

                Row({ space: 10 }) {
                  Text(this.autoUpdateText(row))
                    .fontSize(11)
                    .fontColor(row.autoUpdateEnabled ? $r('app.color.text_3') : $r('app.color.text_disabled'))
                  Blank()
                  if (row.expandableError) {
                    Text(this.isExpanded(row.url) ? $r('app.string.subscription_error_collapse')
                      : $r('app.string.subscription_error_expand'))
                      .fontSize(11).fontColor($r('app.color.error'))
                      .height(44)
                      .accessibilityText(this.isExpanded(row.url)
                        ? $r('app.string.subscription_error_collapse')
                        : $r('app.string.subscription_error_expand'))
                      .onClick(() => this.toggleExpanded(row.url))
                  }
                  if (this.updatingUrl === row.url) {
                    LoadingProgress().width(16).height(16).color($r('app.color.primary'))
                  } else {
                    Button($r('app.string.subscription_row_update'))
                      .height(24)
                      .backgroundColor($r('app.color.surface'))
                      .fontColor($r('app.color.primary'))
                      .enabled(!this.updatingAll && this.networkAvailable)
                      /* §13.3:视觉 28 高,热区扩到 44×44(responseRegion 不改观感) */
                      .responseRegion({ x: -8, y: -8, width: 44, height: 44 })
                      .accessibilityText($r('app.string.subscription_row_update'))
                      .accessibilityDescription(!this.networkAvailable
                        ? this.resText($r('app.string.subscription_offline_hint')) : '')
                      .onClick(() => this.onUpdateOne(row.url))
                  }
                  Button($r('app.string.subscription_row_more'))
                    .height(24)
                    .backgroundColor($r('app.color.surface'))
                    .fontColor($r('app.color.text_2'))
                    .responseRegion({ x: -10, y: -10, width: 44, height: 44 })
                    .accessibilityText($r('app.string.subscription_row_more'))
                    .onClick(() => this.toggleMore(row.url))
                }
                .width('100%')

                if (row.expandableError && this.isExpanded(row.url)) {
                  // lastError 原样展示(§11.1:不吞错误)
                  Text(row.errorText)
                    .fontSize(11.5).fontColor($r('app.color.error'))
                    .width('100%')
                    .padding(6)
                    .borderRadius(UiSpec.CARD_RADIUS / 2)
                    .backgroundColor($r('app.color.surface'))
                }

                if (this.isMoreOpen(row.url)) {
                  Column({ space: 8 }) {
                    Row({ space: 8 }) {
                      Button($r('app.string.subscription_row_detail'))
                        .height(24).layoutWeight(1)
                        .backgroundColor($r('app.color.surface'))
                        .fontColor($r('app.color.text_primary'))
                        .accessibilityText($r('app.string.subscription_row_detail'))
                        .onClick(() => {
                          this.toggleMore(row.url);
                          this.openDetail(row.url);
                        })
                      Button($r('app.string.subscription_row_clear_nodes'))
                        .height(24).layoutWeight(1)
                        .backgroundColor($r('app.color.surface'))
                        .fontColor($r('app.color.error'))
                        .accessibilityText($r('app.string.subscription_row_clear_nodes'))
                        .onClick(() => this.confirmClearNodes(row))
                      Button($r('app.string.subscription_row_delete'))
                        .height(24).layoutWeight(1)
                        .backgroundColor($r('app.color.surface'))
                        .fontColor($r('app.color.error'))
                        .accessibilityText($r('app.string.subscription_row_delete'))
                        .onClick(() => this.confirmDelete(row))
                    }.width('100%')
                  }.width('100%')
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
              /* 长按选中(P4: 订阅页 ⋮ 的「更新选中/删除选中」需要当前选中项);选中态用浅底提示 */
              .backgroundColor(this.selectedUrl === row.url ? $r('app.color.surface') : Color.Transparent)
              .gesture(LongPressGesture({ repeat: false, duration: 400 })
                .onAction(() => this.onSelect(row.url)))
            }
          }, (row: SubscriptionRowView) => this.rowKey(row))
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 12 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
  }

  private emptyTitle(): ResourceStr {
    if (!this.networkAvailable) {
      return $r('app.string.sub_empty_offline_title');
    }
    return $r('app.string.sub_empty_no_subs_title');
  }

  private emptyBody(): ResourceStr {
    if (!this.networkAvailable) {
      return $r('app.string.sub_empty_offline_body');
    }
    return $r('app.string.sub_empty_no_subs_body');
  }
}
