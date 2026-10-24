import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { AppSettings } from '../model/Profile';
import { initStore, loadSettings, saveSettings, LogStore } from '../model/Store';
import { geoReady, downloadGeoAssets, importGeoAssetFromFile, geoAssetInfos, downloadGeoAsset, deleteGeoAsset, GeoAssetInfo } from '../utils/GeoAssets';
import { formatBytes } from '../utils/TrafficStats';
import { pressLightEffect } from '../common/Effects';
import window from '@ohos.window';
/* P4/W16-A:设置 Schema + 待应用差异模型(纯模型,无 I/O;§12.1/§12.2/§12.4) */
import {
  APPLY_IMMEDIATE, APPLY_NEXT_TASK, APPLY_RECONNECT, SettingDef, SettingsDiff, SettingsDiffItem,
  settingDefs, settingDefOf, sectionDefs, SectionDef,
  diffSettings, ImpactPart, impactParts, searchSettings, sectionDefaults, defaultsForAll
} from '../model/SettingsSchema';
import { ConfigRepository } from '../core/ConfigRepository';
import { ApplyCoordinator, ApplyState } from '../core/ApplyCoordinator';
import { SnapshotContent } from '../model/ConfigSnapshot';
import { VpnCommand, publishVpnCommand } from '../core/VpnIpc';

/** SettingDef.labelToken → 本地化文案(54 项 = SettingsSchema registry 全量,§24.2-6/§12.1;
 *  tests/i18n-keys.cjs 断言映射与 registry 逐键对齐,加设置字段漏登记这里会红)。Map 用 $r 静态登记,不能动态拼键。 */
const SETTING_LABELS: Map<string, ResourceStr> = new Map<string, ResourceStr>([
  ['settings_mode', $r('app.string.settings_mode')],
  ['settings_direct_domains', $r('app.string.settings_direct_domains')],
  ['settings_direct_ip', $r('app.string.settings_direct_ip')],
  ['settings_resolve_destination', $r('app.string.settings_resolve_destination')],
  ['settings_sniff_mode', $r('app.string.settings_sniff_mode')],
  ['settings_bypass_lan', $r('app.string.settings_bypass_lan')],
  ['settings_remote_dns', $r('app.string.settings_remote_dns')],
  ['settings_direct_dns', $r('app.string.settings_direct_dns')],
  ['settings_remote_dns_strategy', $r('app.string.settings_remote_dns_strategy')],
  ['settings_direct_dns_strategy', $r('app.string.settings_direct_dns_strategy')],
  ['settings_server_dns_strategy', $r('app.string.settings_server_dns_strategy')],
  ['settings_dns_routing', $r('app.string.settings_dns_routing')],
  ['settings_fake_dns', $r('app.string.settings_fake_dns')],
  ['settings_ipv6', $r('app.string.settings_ipv6')],
  ['settings_ipv6_mode', $r('app.string.settings_ipv6_mode')],
  ['settings_mixed_port', $r('app.string.settings_mixed_port')],
  ['settings_allow_access', $r('app.string.settings_allow_access')],
  ['settings_per_app_mode', $r('app.string.settings_per_app_mode')],
  ['settings_per_app_list', $r('app.string.settings_per_app_list')],
  ['settings_per_app_entries', $r('app.string.settings_per_app_entries')],
  ['settings_test_url', $r('app.string.settings_test_url')],
  ['settings_test_concurrent', $r('app.string.settings_test_concurrent')],
  ['settings_latency_test_mode', $r('app.string.settings_latency_test_mode')],
  ['settings_test_timeout', $r('app.string.settings_test_timeout')],
  ['settings_test_retries', $r('app.string.settings_test_retries')],
  ['settings_test_samples', $r('app.string.settings_test_samples')],
  ['settings_test_expect_status', $r('app.string.settings_test_expect_status')],
  ['settings_test_bypass_tunnel', $r('app.string.settings_test_bypass_tunnel')],
  ['settings_latency_stale', $r('app.string.settings_latency_stale')],
  ['settings_auto_update_subs', $r('app.string.settings_auto_update_subs')],
  ['settings_sub_update_interval', $r('app.string.settings_sub_update_interval')],
  ['settings_appearance', $r('app.string.settings_appearance')],
  ['settings_haptic', $r('app.string.settings_haptic')],
  ['settings_liquid_glass', $r('app.string.settings_liquid_glass')],
  ['settings_always_show_address', $r('app.string.settings_always_show_address')],
  ['settings_notification_group', $r('app.string.settings_notification_group')],
  ['settings_show_bottom_bar', $r('app.string.settings_show_bottom_bar')],
  ['settings_nav_layout', $r('app.string.settings_nav_layout')],
  ['settings_profile_sort', $r('app.string.settings_profile_sort')],
  ['settings_speed_interval', $r('app.string.settings_speed_interval')],
  ['settings_auto_connect', $r('app.string.settings_auto_connect')],
  ['settings_network_reset', $r('app.string.settings_network_reset')],
  ['settings_wake_reset', $r('app.string.settings_wake_reset')],
  ['settings_profile_traffic', $r('app.string.settings_profile_traffic')],
  ['settings_mtu', $r('app.string.settings_mtu')],
  ['settings_stack', $r('app.string.settings_stack')],
  ['settings_log_level', $r('app.string.settings_log_level')],
  ['settings_allow_insecure', $r('app.string.settings_allow_insecure')],
  ['settings_sub_allow_insecure', $r('app.string.settings_sub_allow_insecure')],
  ['settings_clash_api', $r('app.string.settings_clash_api')],
  ['settings_clash_port', $r('app.string.settings_clash_port')],
  ['settings_clash_secret', $r('app.string.settings_clash_secret')],
  ['settings_global_custom', $r('app.string.settings_global_custom')],
  ['settings_coexist_fix', $r('app.string.settings_coexist_fix')]
]);

/** SectionDef.labelToken → 本地化(9 分区;与 SETTING_LABELS 同口径,tests/i18n-keys.cjs 守键存在) */
const SECTION_LABELS: Map<string, ResourceStr> = new Map<string, ResourceStr>([
  ['settings_section_appearance', $r('app.string.settings_section_appearance')],
  ['settings_section_startup', $r('app.string.settings_section_startup')],
  ['settings_section_probe', $r('app.string.settings_section_probe')],
  ['settings_section_dns', $r('app.string.settings_section_dns')],
  ['settings_section_ipv6', $r('app.string.settings_section_ipv6')],
  ['settings_section_inbound', $r('app.string.settings_section_inbound')],
  ['settings_section_mode', $r('app.string.settings_section_mode')],
  ['settings_section_perapp', $r('app.string.settings_section_perapp')],
  ['settings_section_advanced', $r('app.string.settings_section_advanced')]
]);

/** 草稿 AppSettings → Record(快照 settings 的 JSON 口径,与 Index.settingsToRecord 一致) */
function draftToRecord(s: AppSettings): Record<string, Object> {
  return JSON.parse(JSON.stringify(s)) as Record<string, Object>;
}

const STACKS: Array<string> = ['system'];
const MODES: Array<string> = ['rule', 'global', 'direct'];
const MODE_LABELS: Array<Resource> = [$r('app.string.mode_rule'), $r('app.string.mode_global'), $r('app.string.mode_direct')];
const MODE_SWITCH_TOASTS: Array<Resource> = [$r('app.string.settings_mode_switched_rule'), $r('app.string.settings_mode_switched_global'), $r('app.string.settings_mode_switched_direct')];
const LOG_LEVELS: Array<string> = ['trace', 'debug', 'info', 'warn', 'error'];
const SNIFF_MODES: Array<string> = ['off', 'route', 'override'];
const LATENCY_TEST_VALUES: Array<string> = ['url', 'tcp'];
const LATENCY_TEST_LABELS: Array<Resource> = [$r('app.string.latency_test_url'), $r('app.string.latency_test_tcp')];
const SNIFF_LABELS: Array<Resource> = [$r('app.string.sniff_off'), $r('app.string.sniff_route'), $r('app.string.sniff_override')];
const STRATEGIES: Array<string> = ['', 'auto', 'prefer_ipv4', 'prefer_ipv6', 'ipv4_only', 'ipv6_only'];
const STRATEGY_LABELS: Array<Resource> = [$r('app.string.strategy_default'), $r('app.string.strategy_auto'), $r('app.string.strategy_prefer_ipv4'), $r('app.string.strategy_prefer_ipv6'), $r('app.string.strategy_ipv4_only'), $r('app.string.strategy_ipv6_only')];
// Android IPv6Mode 四档(values/arrays.xml ipv6_mode)
const IPV6_MODES: Array<string> = ['disable', 'enable', 'prefer', 'only'];
const IPV6_MODE_LABELS: Array<Resource> = [$r('app.string.ipv6_mode_disable'), $r('app.string.ipv6_mode_enable'), $r('app.string.ipv6_mode_prefer'), $r('app.string.ipv6_mode_only')];

@Component
export struct SettingsPage {
  @State s: AppSettings = new AppSettings();
  @State geoOk: boolean = false;
  @State geoLoading: boolean = false;
  @State geoInfos: Array<GeoAssetInfo> = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State appSearch: string = '';
  @State dirty: boolean = false;
  /* ---- P4/W16-A 待应用条 / 变更列表 / 搜索 ---- */
  /** 待应用条重渲染版本号(diff 由纯函数算出,不进 @State,靠 rev 触发重渲染) */
  @State applyBarRev: number = 0;
  /** 设置搜索词(空 = 常规分区视图;非空 = 搜索结果视图) */
  @State settingsQuery: string = '';
  /** 应用进行中(等扩展回执期间禁用应用按钮) */
  @State applying: boolean = false;
  @State proxyExpanded: boolean = false;
  @State generalExpanded: boolean = false;
  @State networkExpanded: boolean = false;
  @State dnsExpanded: boolean = false;
  @State inboundExpanded: boolean = false;
  @State appearanceExpanded: boolean = false;
  @State apiExpanded: boolean = false;
  /**
   * HDS 点按光效的"当前光源 key":同一时刻只有一个宿主处于按下态。
   * 口径与 Index.ets 的 `litKey` 一致(按下写 key、抬起/取消清空),不挂常亮光源
   * —— 官方明确"点光源位置不跟组件位移变化,不建议在滚动组件里常亮"。
   */
  @State litKey: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  onSettingsChanged: (settings: AppSettings) => void = (_settings: AppSettings) => {};
  onOpenDrawer: () => void = () => {};
  /** P4/W16-A:待应用条「应用」→ 壳层提交快照 + 发布 apply(事务状态机在 Index,页面只发起) */
  onApplyDraft: () => void = () => {};

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      await initStore(this.context);
      this.s = await loadSettings();
      this.dirty = false;
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  private refreshGeoInfos(): void {
    this.geoInfos = geoAssetInfos(this.context);
  }

  async downloadGeo(): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    promptAction.showToast({ message: $r('app.string.geo_downloading') });
    try {
      await downloadGeoAssets(this.context);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({ message: $r('app.string.geo_download_complete') });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.download_failed_reason', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  /** 单库更新(对齐安卓资产列表点击单库更新) */
  async downloadSingleGeo(kind: string): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    try {
      await downloadGeoAsset(this.context, kind);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({
        message: $r('app.string.settings_geo_updated', kind === 'site' ? 'geosite-cn.db' : 'geoip-cn.db')
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.download_failed_reason', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  /** 删除单库(对齐安卓资产左滑删除;二次确认) */
  confirmDeleteGeo(info: GeoAssetInfo): void {
    AlertDialog.show({
      message: $r('app.string.settings_geo_delete_confirm', info.fileName),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: () => {
          try {
            deleteGeoAsset(this.context, info.kind);
            this.geoOk = geoReady(this.context);
            this.refreshGeoInfos();
            promptAction.showToast({ message: $r('app.string.settings_geo_deleted', info.fileName) });
          } catch (e) {
            const msg = e instanceof Error ? e.message : `${e}`;
            promptAction.showToast({ message: $r('app.string.settings_geo_delete_failed', msg) });
          }
        }
      }
    });
  }

  /** 导入用户自选的 geo .db(对齐安卓 AssetsActivity 的 action_import_file) */
  async importGeo(): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    try {
      const path = await importGeoAssetFromFile(this.context);
      if (path === null) {
        // 用户取消选择,不报错
        return;
      }
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({ message: $r('app.string.geo_import_complete', path) });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.geo_import_failed', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  modeIndex(): number {
    const i = MODES.indexOf(this.s.mode);
    return i < 0 ? 0 : i;
  }

  private colorToString(color: number): string {
    return `#${(color >>> 0).toString(16).padStart(8, '0').toUpperCase()}`;
  }

  private async applyAppearance(): Promise<void> {
    try {
      await saveSettings(this.s);
      this.dirty = false;
      const colorMode = this.s.appearance === 'dark'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : (this.s.appearance === 'light'
          ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      this.context.setColorMode(colorMode);
      /* 窗口底色与系统栏颜色**不要在这里写**（真机 2026-10-17：切换深浅色时状态栏不实时变深）。
         原来这里 setColorMode 后立刻 getColorSync 读资源 —— 色彩模式是异步生效的，那一刻读到的
         还是旧模式的颜色，把过时的浅色写回状态栏，且落在 EntryAbility.onConfigurationUpdate →
         syncWindowAppearance 的正确写入**之后**（竞态，过时写入赢）⇒ 状态栏保持白色，直到切走
         应用再回来（onForeground 重跑一次）才变深。
         现在只下发 setColorMode，窗口/系统栏统一由 onConfigurationUpdate → syncWindowAppearance
         实时收敛（深色下状态栏直接用主题底色实色，见 EntryAbility 的注释）。 */
      this.onSettingsChanged(this.s);
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 即时应用主题失败: ${message}`);
      promptAction.showToast({ message: $r('app.string.save_failed_reason', message) });
    }
  }

  private markDirty(): void {
    this.dirty = true;
  }

  async save(quiet: boolean = false): Promise<boolean> {
    try {
      await saveSettings(this.s);
      this.dirty = false;
      this.onSettingsChanged(this.s);
      if (!quiet) {
        promptAction.showToast({ message: $r('app.string.saved_reconnect_vpn') });
      }
      /* 2026-10-24 真机用户反馈:设置页撤掉 应用/稍后/放弃 待应用条 ⇒ 保存即自动走
       * 同一条应用事务(提交快照 → 运行中发 apply 由扩展串行重连一次;未运行则下次连接生效) */
      this.requestApply();
      return true;
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.save_failed_reason', e instanceof Error ? e.message : `${e}`) });
      return false;
    }
  }

  private async switchMode(mode: string, toast: Resource): Promise<void> {
    if (this.s.mode === mode) {
      return;
    }
    this.s.mode = mode;
    try {
      await saveSettings(this.s);
      this.dirty = false;
      this.onSettingsChanged(this.s);
      promptAction.showToast({ message: toast });
      /* P4/W16-B(§12.2):模式切换是高频操作 —— 界面立即切换 + 立即反馈,
         随后走**同一条应用事务**(提交快照 → 发布 apply,由扩展串行重连一次),
         不再在页面里直接 VpnService.switchTo(那会与事务管线各重连一次)。 */
      this.requestApply();
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.save_failed_reason', message) });
    }
  }


  // ------------------------------------------------ P4/W16-A 待应用差异(§12.1/§12.2/§12.4)

  /**
   * 已应用设置 = 活动快照的 content.settings。
   * ⚠️ 无活动快照(迁移未完成)时用 registry 默认值兜底 —— 传空 Record 会让 diff 把 54 项全部算成"已修改";
   * 设置项已是默认值的情况也因此**不会**误报。
   */
  private appliedSettingsRecord(): Record<string, Object> {
    const active = ConfigRepository.getActive();
    if (active === null) {
      return defaultsForAll();
    }
    const rec: Record<string, Object> = active.content.settings;
    return Object.keys(rec).length === 0 ? defaultsForAll() : rec;
  }

  /** 草稿(AppSettings) vs 已应用 的差异(纯函数,渲染期只读现算) */
  private currentDiff(): SettingsDiff {
    /* 读一下 applyBarRev:让调用方所在的渲染作用域依赖它(diff 本身是纯函数结果,不进 @State) */
    if (this.applyBarRev < 0) {
      return new SettingsDiff();
    }
    return diffSettings(draftToRecord(this.s), this.appliedSettingsRecord());
  }

  /** diff 是纯函数结果、不进 @State ⇒ 用版本号触发重渲染 */
  private bumpApplyBar(): void {
    this.applyBarRev = this.applyBarRev + 1;
  }

  /** 分区标题(9 个注册分区;未知分区回落 id 原文) */
  private sectionLabelOf(sectionId: string): ResourceStr {
    const token = `settings_section_${sectionId}`;
    const label = SECTION_LABELS.get(token);
    return label === undefined ? sectionId : label;
  }

  /** 差异项标题:labelToken → 本地化;registry 54 项全量映射,未知 token 回落原文(不拼动态资源键) */
  private settingLabelOf(token: string): ResourceStr {
    const label = SETTING_LABELS.get(token);
    return label === undefined ? token : label;
  }

  /** 值展示:JSON 文本 → 人类可读(bool 开/关、数字、字符串、枚举原文);
   *  开/关取本地化资源(变更列表是 string 拼接场景,经 resourceManager 现取,与 VpnExtAbility 通知同手法) */
  private displayValue(json: string): string {
    if (json.length === 0) {
      return '—';
    }
    try {
      const v: Object = JSON.parse(json) as Object;
      if (v === null || v === undefined) {
        return '—';
      }
      if (typeof v === 'boolean') {
        const res = this.context.resourceManager;
        if (v as boolean) {
          return res.getStringSync($r('app.string.settings_value_on'));
        }
        return res.getStringSync($r('app.string.settings_value_off'));
      }
      const text = `${v}`;
      return text.length === 0 ? '—' : text;
    } catch (e) {
      return json;
    }
  }

  private applyClassLabel(cls: string): ResourceStr {
    if (cls === APPLY_IMMEDIATE) {
      return $r('app.string.settings_apply_immediate');
    }
    if (cls === APPLY_NEXT_TASK) {
      return $r('app.string.settings_apply_next_task');
    }
    return $r('app.string.settings_apply_reconnect');
  }

  private applyClassColor(cls: string): ResourceColor {
    if (cls === APPLY_IMMEDIATE) {
      return $r('app.color.mono');
    }
    if (cls === APPLY_NEXT_TASK) {
      return $r('app.color.text_3');
    }
    return $r('app.color.warning');
  }

  /** 应用草稿:交给壳层(Index)提交快照并发布 apply —— 页面只负责发起与展示 */
  private requestApply(): void {
    const diff = this.currentDiff();
    if (diff.total === 0) {
      return;
    }
    this.applying = true;
    this.onApplyDraft();
    /* 回执由壳层消化(协调器决定横幅文案);12s 后解禁按钮并重算差异:失败则差异仍在,条不会消失 */
    setTimeout(() => {
      this.applying = false;
      this.bumpApplyBar();
    }, 12000);
  }

  /** ResourceStr → 当前语言 string(对话框/Toast 的 message 是 string,不能塞 Resource;
   *  与 VpnExtAbility 通知文案同手法:resourceManager.getStringSync) */
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


  /** 恢复本分区默认值(§12.4):写回**草稿**并保存,仍走待应用条(不直接应用) */
  private applySectionDefaults(sectionId: string): void {
    const defaults = sectionDefaults(sectionId);
    const merged = draftToRecord(this.s);
    Object.keys(defaults).forEach((key: string) => {
      merged[key] = defaults[key];
    });
    this.s = JSON.parse(JSON.stringify(merged)) as AppSettings;
    this.markDirty();
    void saveSettings(this.s).then(() => {
      this.onSettingsChanged(this.s);
      /* 保存即自动走应用事务(2026-10-24 用户反馈撤待应用条) */
      this.requestApply();
    });
    promptAction.showToast({ message: $r('app.string.settings_section_defaults_toast') });
  }

  private restoreSectionDefaults(sectionId: string): void {
    const defaults = sectionDefaults(sectionId);
    const draft = draftToRecord(this.s);
    const changed: Array<string> = [];
    Object.keys(defaults).forEach((key: string) => {
      if (JSON.stringify(draft[key]) !== JSON.stringify(defaults[key])) {
        changed.push(key);
      }
    });
    if (changed.length === 0) {
      promptAction.showToast({ message: $r('app.string.settings_section_already_default') });
      return;
    }
    const names: Array<string> = [];
    for (let i = 0; i < changed.length; i++) {
      const def = settingDefOf(changed[i]);
      names.push(def === null ? changed[i] : this.resText(this.settingLabelOf(def.labelToken)));
    }
    AlertDialog.show({
      title: this.resFormat($r('app.string.settings_restore_confirm_title'), this.resText(this.sectionLabelOf(sectionId))),
      message: this.resFormat($r('app.string.settings_restore_confirm_body'), changed.length, names.join('、')),
      autoCancel: true,
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.settings_restore_defaults'),
        fontColor: $r('app.color.primary'),
        action: () => {
          this.applySectionDefaults(sectionId);
        }
      }
    });
  }



  /** 设置分区跳转(搜索结果点击用):展开承载该 schema 分区的页内折叠区 */
  private jumpToSchemaSection(sectionId: string): void {
    if (sectionId === 'appearance') {
      this.appearanceExpanded = true;
    } else if (sectionId === 'dns' || sectionId === 'ipv6') {
      this.dnsExpanded = true;
    } else if (sectionId === 'inbound') {
      this.inboundExpanded = true;
    } else if (sectionId === 'mode') {
      this.networkExpanded = true;
    } else {
      /* startup / probe / advanced:字段落在「通用」区 */
      this.generalExpanded = true;
    }
  }

  /** 当前草稿里某 key 的值(搜索结果行显示用) */
  private draftValueOf(key: string): string {
    const rec = draftToRecord(this.s);
    return JSON.stringify(rec[key]);
  }


  /** 设置搜索框(§12.1):searchSettings(query) 驱动结果面板 */
  @Builder
  private settingsSearchRow() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(14)
        .fontColor([$r('app.color.text_3')])
      TextInput({ text: this.settingsQuery, placeholder: $r('app.string.settings_search_hint') })
        .height(36)
        .layoutWeight(1)
        .backgroundColor(Color.Transparent)
        .fontSize(13)
        .onChange((v: string) => {
          this.settingsQuery = v;
        })
      if (this.settingsQuery.length > 0) {
        Text($r('app.string.settings_clear_search'))
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .onClick(() => {
            this.settingsQuery = '';
          })
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .margin({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 4 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(10)
  }

  /** 搜索结果(§12.1):列出命中的设置项,点击跳到承载该分区的折叠区 */
  @Builder
  private searchResultsPanel() {
    Column({ space: 2 }) {
      ForEach(searchSettings(this.settingsQuery).filter((d: SettingDef): boolean => d.section !== 'perapp').slice(0, 20), (def: SettingDef) => {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(this.settingLabelOf(def.labelToken))
              .fontSize(13)
              .fontColor($r('app.color.text_1'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${this.resText(this.sectionLabelOf(def.section))} · ${def.key}`)
              .fontSize(10)
              .fontColor($r('app.color.text_3'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.displayValue(this.draftValueOf(def.key)))
            .fontSize(11)
            .fontColor($r('app.color.text_2'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '40%' })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          this.jumpToSchemaSection(def.section);
          this.settingsQuery = '';
          promptAction.showToast({ message: this.resFormat($r('app.string.settings_jump_toast'), this.resText(this.sectionLabelOf(def.section))) });
        })
      }, (def: SettingDef) => def.key)
    }
    .width('100%')
    .margin({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 6 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
  }


  /**
   * FlClash 式可折叠分组章节头:图标 + 小标题 + 展开状态 + 下缘 hairline。
   * sectionId 非空时右侧带「恢复默认」(§12.4):只写回草稿并保存,仍走待应用条。
   * 点击区拆成两个兄弟节点(标题块 / 恢复默认),避免嵌套点击互相触发。
   */
  @Builder
  private sectionHeader(icon: Resource, title: ResourceStr, expanded: boolean, onToggle: () => void,
    sectionId: string) {
    Row({ space: 6 }) {
      Row({ space: 10 }) {
        /* 字符图标换成系统符号:SymbolGlyph 没有 textAlign,靠固定 width(24) 与标题左边距对齐 */
        SymbolGlyph(icon)
          .fontSize(17)
          .fontColor([$r('app.color.mono')])
          .width(24)
        Text(title)
          .fontSize(12)
          .fontWeight(700)
          .fontColor($r('app.color.text_3'))
          .letterSpacing(2)
          .layoutWeight(1)
        SymbolGlyph(expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([$r('app.color.text_3')])
      }
      .layoutWeight(1)
      .padding({ top: 14, bottom: 6 })
      /* HDS 点按光效:这一块本来就可点(onClick(onToggle)),只补"按下那一刻发光"。
         光源宿主白名单里有 Row、没有 Text —— 所以宿主保持 Row(图标 Text 已换成 SymbolGlyph)。
         key 用 icon.id(Resource.id 是必填 number,每个章节的符号资源 id 唯一)。 */
      .visualEffect(pressLightEffect(this.litKey === `sec:${icon.id}`, false))
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.litKey = `sec:${icon.id}`;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.litKey = '';
        }
      })
      .onClick(onToggle)
      if (sectionId.length > 0) {
        Text($r('app.string.settings_restore_defaults'))
          .fontSize(11)
          .fontColor($r('app.color.primary'))
          .padding({ top: 14, bottom: 6, left: 4, right: 2 })
          .onClick(() => {
            this.restoreSectionDefaults(sectionId);
          })
      }
    }
    .width('100%')
    .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
    Column() {
      Row() {
        /* 标题与抽屉入口都在壳层的 HDS 顶栏里;这里只保留本页自己的动作(保存) */
        Blank()
          .layoutWeight(1)
        Button($r('app.string.save'))
          .height(34)
          .enabled(this.dirty)
          .backgroundColor(this.dirty ? $r('app.color.primary') : $r('app.color.control_disabled'))
          .fontColor($r('app.color.surface'))
          /* HDS 点按光效:页头固定件(不跟滚动跑位) ⇒ 发光 + 按压阴影 + 兜底缩放 */
          .visualEffect(pressLightEffect(this.litKey === 'save', true))
          .scale({ x: this.litKey === 'save' ? 0.94 : 1.0, y: this.litKey === 'save' ? 0.94 : 1.0 })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
        this.litKey = 'save';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
          })
          .onClick(() => this.save())
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 6, bottom: 8 })
      /* 搜索(仅加载成功时显示;§12.1)。2026-10-24 真机用户反馈:应用/稍后/放弃待应用条已撤,
         保存(右上按钮)即保存并自动走应用事务 */
      if (!this.loading && this.loadError.length === 0) {
        this.settingsSearchRow()
        if (this.settingsQuery.trim().length > 0) {
          Scroll() {
            this.searchResultsPanel()
          }
          .constraintSize({ maxHeight: 280 })
          .align(Alignment.Top)
        }
      }
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.primary'))
          Text($r('app.string.loading_settings'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      } else if (this.loadError.length > 0) {
        Column({ space: 8 }) {
          Text($r('app.string.settings_load_failed'))
            .fontSize(16)
            .fontWeight(500)
            .fontColor($r('app.color.text_primary'))
          Text(this.loadError)
            .fontSize(13)
            .fontColor($r('app.color.error'))
          Button($r('app.string.reload'))
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .visualEffect(pressLightEffect(this.litKey === 'reload', true))
            .onTouch((event: TouchEvent) => {
              if (event.type === TouchType.Down) {
        this.litKey = 'reload';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
            })
            .onClick(() => this.load())
        }
        .width('100%')
        .padding({ top: 28, bottom: 20 })
      }

      Scroll() {
        Column({ space: 14 }) {
          // 常规(对齐 Android General 组)
          this.sectionHeader($r('sys.symbol.gearshape'), $r('app.string.settings_general'), this.generalExpanded, () => { this.generalExpanded = !this.generalExpanded; }, '')
          if (this.generalExpanded) {
          Column({ space: 8 }) {
            Row() {
              Column() {
                Text($r('app.string.settings_auto_connect')).fontSize(14)
                Text($r('app.string.settings_auto_connect_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.autoConnect })
                .onChange((v: boolean) => {
                  this.s.autoConnect = v;
                  this.markDirty();
                })
            }.width('100%')

            Column() {
              Text($r('app.string.settings_log_level')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(LOG_LEVELS.map((t: string) => ({ value: t } as SelectOption)))
                .selected(LOG_LEVELS.indexOf(this.s.logLevel) < 0 ? 2 : LOG_LEVELS.indexOf(this.s.logLevel))
                .value(this.s.logLevel)
                .onSelect((index: number) => {
                  this.s.logLevel = LOG_LEVELS[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.latency_test_mode')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(LATENCY_TEST_LABELS.map((t: Resource, i: number) => ({ value: t } as SelectOption)))
                .selected(LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode) < 0 ? 0 : LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode))
                .value(LATENCY_TEST_LABELS[LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode) < 0 ? 0 : LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode)])
                .onSelect((index: number) => {
                  this.s.latencyTestMode = LATENCY_TEST_VALUES[index];
                  this.markDirty();
                })
              Text($r('app.string.latency_test_mode_desc'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_test_url')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.testUrl })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.testUrl = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_test_url_desc'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_test_concurrent')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: `${this.s.testConcurrent}` })
                .type(InputType.Number).width('100%').height(40)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  // 默认 5 对齐 Android DataStore.connectionTestConcurrent(DataStore.kt:159,
                  // Android 无此设置 UI,这里是鸿蒙超集);钳制 1..32 防呆
                  this.s.testConcurrent = isNaN(n) ? 5 : Math.max(1, Math.min(32, n));
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_global_custom_config')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextArea({ text: this.s.globalCustomConfig, placeholder: '{"log":{"level":"info"}}' })
                .height(90)
                .fontSize(12)
                .fontFamily('monospace')
                .width('100%')
                .onChange((v: string) => {
                  this.s.globalCustomConfig = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_global_custom_config_desc'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Row() {
              Text($r('app.string.settings_always_show_address')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.alwaysShowAddress })
                .onChange((v: boolean) => {
                  this.s.alwaysShowAddress = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Text($r('app.string.show_bottom_bar')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.showBottomBar })
                .onChange((v: boolean) => {
                  this.s.showBottomBar = v;
                  this.markDirty();
                })
            }.width('100%')

            /* 「通知显示分组名」开关已移除(2026-10-23 用户要求通知栏只显示速率+运行时长,
               不再出现节点/分组名)—— AppSettings.notificationGroup 字段保留仅为旧备份兼容 */
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.settings_speed_interval')).fontSize(14).width('100%')
                Text($r('app.string.settings_speed_interval_sum'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              TextInput({ text: `${this.s.speedIntervalMs}`, placeholder: '1000' })
                .type(InputType.Number).width(110).height(36)
                .onChange((v: string) => {
                  const n = parseInt(v, 10);
                  this.s.speedIntervalMs = isNaN(n) ? 1000 : n;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_insecure_tls')).fontSize(14)
                Text($r('app.string.settings_insecure_tls_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.allowInsecureAll })
                .onChange((v: boolean) => {
                  this.s.allowInsecureAll = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_sub_allow_insecure')).fontSize(14)
                Text($r('app.string.settings_sub_allow_insecure_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.subAllowInsecure })
                .onChange((v: boolean) => {
                  this.s.subAllowInsecure = v;
                  this.markDirty();
                })
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // 路由
          this.sectionHeader($r('sys.symbol.arrow_up_left_and_arrow_down_right'), $r('app.string.settings_route'), this.networkExpanded, () => { this.networkExpanded = !this.networkExpanded; }, 'mode')
          if (this.networkExpanded) {
          if (this.s.mode === 'rule') {
            Column() {
              Text($r('app.string.settings_direct_domain_suffix')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.directDomains, placeholder: 'baidu.com,qq.com,163.com' })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.directDomains = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_direct_cidr')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
                .margin({ top: 6 })
              TextInput({ text: this.s.directIpCidrs, placeholder: '114.114.114.114/32' })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.directIpCidrs = v;
                  this.markDirty();
                })
              Row({ space: 8 }) {
                Text(this.geoOk ? $r('app.string.settings_geo_ready')
                  : $r('app.string.settings_geo_missing'))
                  .fontSize(12).fontColor(this.geoOk ? $r('app.color.success') : $r('app.color.text_secondary')).layoutWeight(1)
                Button(this.geoLoading ? $r('app.string.settings_geo_downloading') : (this.geoOk ? $r('app.string.settings_geo_redownload') : $r('app.string.settings_geo_download')))
                  .height(30)
                  .backgroundColor(this.geoLoading ? $r('app.color.control_disabled') : $r('app.color.primary'))
                  .visualEffect(pressLightEffect(this.litKey === 'geo:download', true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
        this.litKey = 'geo:download';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                  })
                  .onClick(() => this.downloadGeo())
              }.width('100%').margin({ top: 6 })
              Row({ space: 8 }) {
                Text($r('app.string.settings_geo_import_hint'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                Button($r('app.string.settings_geo_import'))
                  .height(30)
                  .backgroundColor($r('app.color.surface'))
                  .fontColor($r('app.color.text_primary'))
                  .enabled(!this.geoLoading)
                  .visualEffect(pressLightEffect(this.litKey === 'geo:import', true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
        this.litKey = 'geo:import';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                  })
                  .onClick(() => { void this.importGeo(); })
              }.width('100%').margin({ top: 4 })

              // 资产列表(对齐安卓 AssetsActivity:每库名称/大小/版本 + 单库更新/删除)
              ForEach(this.geoInfos, (info: GeoAssetInfo) => {
                Row({ space: 8 }) {
                  Text(info.kind === 'site' ? $r('app.string.settings_geo_site') : $r('app.string.settings_geo_ip'))
                    .fontSize(12).fontColor($r('app.color.text_primary'))
                  Text(info.size > 0
                    ? $r('app.string.geo_asset_status', formatBytes(info.size), info.version)
                    : $r('app.string.geo_asset_absent'))
                    .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                  Button(this.geoLoading ? $r('app.string.settings_geo_downloading') : $r('app.string.settings_geo_update_one'))
                    .height(28)
                    .fontSize(12)
                    .backgroundColor(this.geoLoading ? $r('app.color.control_disabled') : $r('app.color.primary'))
                    .enabled(!this.geoLoading)
                    .visualEffect(pressLightEffect(this.litKey === `geo:update:${info.kind}`, true))
                    .onTouch((event: TouchEvent) => {
                      if (event.type === TouchType.Down) {
                        this.litKey = `geo:update:${info.kind}`;
                      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                        this.litKey = '';
                      }
                    })
                    .onClick(() => { void this.downloadSingleGeo(info.kind); })
                  if (info.size > 0) {
                    Button($r('app.string.settings_geo_delete'))
                      .height(28)
                      .fontSize(12)
                      .backgroundColor($r('app.color.surface'))
                      .fontColor($r('app.color.error'))
                      .enabled(!this.geoLoading)
                      .visualEffect(pressLightEffect(this.litKey === `geo:delete:${info.kind}`, true))
                      .onTouch((event: TouchEvent) => {
                        if (event.type === TouchType.Down) {
                          this.litKey = `geo:delete:${info.kind}`;
                        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                          this.litKey = '';
                        }
                      })
                      .onClick(() => this.confirmDeleteGeo(info))
                  }
                }.width('100%').margin({ top: 4 })
              }, (info: GeoAssetInfo) => `${info.kind}_${info.size}_${info.version}`)
            }.alignItems(HorizontalAlign.Start).width('100%')
          }

          Blank().height(2)

          Column() {
            Text($r('app.string.settings_tun_mtu')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: `${this.s.mtu}`, placeholder: '9000' })
              .type(InputType.Number).width('100%').height(40)
              .onChange((v: string) => {
                const n = parseInt(v);
                this.s.mtu = isNaN(n) ? 9000 : n;
                this.markDirty();
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text($r('app.string.settings_tun_stack')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Select(STACKS.map((t: string) => ({ value: t } as SelectOption)))
              .selected(STACKS.indexOf(this.s.stack) < 0 ? 0 : STACKS.indexOf(this.s.stack))
              .value(this.s.stack)
              .onSelect((index: number) => {
                this.s.stack = STACKS[index];
                this.markDirty();
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text($r('app.string.settings_enable_ipv6')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Select(IPV6_MODES.map((t: string, i: number) => ({ value: IPV6_MODE_LABELS[i] } as SelectOption)))
              .selected(IPV6_MODES.indexOf(this.s.ipv6Mode) < 0 ? (this.s.ipv6 ? 1 : 0) : IPV6_MODES.indexOf(this.s.ipv6Mode))
              .value(IPV6_MODE_LABELS[(IPV6_MODES.indexOf(this.s.ipv6Mode) < 0 ? (this.s.ipv6 ? 1 : 0) : IPV6_MODES.indexOf(this.s.ipv6Mode))])
              .onSelect((index: number) => {
                this.s.ipv6Mode = IPV6_MODES[index];
                this.markDirty();
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Row() {
            Column() {
              Text($r('app.string.settings_bypass_lan')).fontSize(14)
              Text($r('app.string.settings_bypass_lan_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.bypassLan })
              .onChange((v: boolean) => {
                this.s.bypassLan = v;
                this.markDirty();
              })
          }.width('100%')

          Column() {
            Text($r('app.string.settings_sniff')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Row({ space: 8 }) {
              ForEach(SNIFF_MODES, (m: string, idx: number) => {
                Button(SNIFF_LABELS[idx])
                  .layoutWeight(1)
                  .height(34)
                  .backgroundColor(this.s.sniffMode === m ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.sniffMode === m ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === `sniff:${m}`, true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.litKey = `sniff:${m}`;
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.litKey = '';
                    }
                  })
                  .onClick(() => {
                    this.s.sniffMode = m;
                    this.markDirty();
                  })
              }, (m: string) => m)
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Row() {
            Column() {
              Text($r('app.string.settings_resolve_destination')).fontSize(14)
              Text($r('app.string.settings_resolve_destination_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.resolveDestination })
              .onChange((v: boolean) => {
                this.s.resolveDestination = v;
                this.markDirty();
              })
          }.width('100%')

          Blank().height(2)

          }

          // DNS(对齐 Android DNS 组)
          this.sectionHeader($r('sys.symbol.cloud'), $r('app.string.settings_dns'), this.dnsExpanded, () => { this.dnsExpanded = !this.dnsExpanded; }, 'dns')
          if (this.dnsExpanded) {
          Column({ space: 8 }) {
            Column() {
              Text($r('app.string.settings_remote_dns')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.remoteDns })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.remoteDns = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_remote_dns_hint'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_remote_dns_strategy')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)))
                .selected(STRATEGIES.indexOf(this.s.remoteDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.remoteDnsStrategy))
                .value(STRATEGY_LABELS[STRATEGIES.indexOf(this.s.remoteDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.remoteDnsStrategy)])
                .onSelect((index: number) => {
                  this.s.remoteDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_direct_dns')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.directDns })
                .width('100%').height(40)
                .onChange((v: string) => {
                  this.s.directDns = v;
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_direct_dns_strategy')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)))
                .selected(STRATEGIES.indexOf(this.s.directDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.directDnsStrategy))
                .value(STRATEGY_LABELS[STRATEGIES.indexOf(this.s.directDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.directDnsStrategy)])
                .onSelect((index: number) => {
                  this.s.directDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Column() {
              Text($r('app.string.settings_server_dns_strategy')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              Select(STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)))
                .selected(STRATEGIES.indexOf(this.s.serverDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.serverDnsStrategy))
                .value(STRATEGY_LABELS[STRATEGIES.indexOf(this.s.serverDnsStrategy) < 0 ? 0 : STRATEGIES.indexOf(this.s.serverDnsStrategy)])
                .onSelect((index: number) => {
                  this.s.serverDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
              Text($r('app.string.settings_server_dns_strategy_hint'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_dns_routing')).fontSize(14)
                Text($r('app.string.settings_dns_routing_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.dnsRouting })
                .onChange((v: boolean) => {
                  this.s.dnsRouting = v;
                  this.markDirty();
                })
            }.width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_fakedns')).fontSize(14)
                Text($r('app.string.settings_fakedns_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.fakeDns })
                .onChange((v: boolean) => {
                  this.s.fakeDns = v;
                  this.markDirty();
                })
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // 入站(对齐 Android Inbound 组)
          this.sectionHeader($r('sys.symbol.square_and_arrow_down'), $r('app.string.settings_inbound'), this.inboundExpanded, () => { this.inboundExpanded = !this.inboundExpanded; }, 'inbound')
          if (this.inboundExpanded) {
          Column({ space: 8 }) {
            Column() {
              Text($r('app.string.settings_mixed_port')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: `${this.s.mixedPort > 0 ? this.s.mixedPort : ''}`, placeholder: $r('app.string.settings_mixed_port_hint') })
                .type(InputType.Number).width('100%').height(40)
                .onChange((v: string) => {
                  const n = parseInt(v);
                  this.s.mixedPort = isNaN(n) ? 0 : Math.max(0, Math.min(65535, n));
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')

            Row() {
              Column() {
                Text($r('app.string.settings_allow_access')).fontSize(14)
                Text($r('app.string.settings_allow_access_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.allowAccess })
                .onChange((v: boolean) => {
                  this.s.allowAccess = v;
                  this.markDirty();
                })
            }.width('100%')
            Text($r('app.string.settings_reconnect_note'))
              .fontSize(12).fontColor($r('app.color.error')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // 外观与交互
          this.sectionHeader($r('sys.symbol.brightness'), $r('app.string.appearance_and_interaction'), this.appearanceExpanded, () => { this.appearanceExpanded = !this.appearanceExpanded; }, 'appearance')
          if (this.appearanceExpanded) {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              ForEach(['system', 'light', 'dark'], (mode: string) => {
                Button(mode === 'system' ? $r('app.string.appearance_follow_system') : (mode === 'light' ? $r('app.string.appearance_light') : $r('app.string.appearance_dark')))
                  .layoutWeight(1)
                  .backgroundColor(this.s.appearance === mode ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.appearance === mode ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === `appearance:${mode}`, true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.litKey = `appearance:${mode}`;
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.litKey = '';
                    }
                  })
                  .onClick(() => {
                    this.s.appearance = mode;
                    this.applyAppearance();
                    this.markDirty();
                  })
              }, (mode: string) => mode)
            }.width('100%')
            Text($r('app.string.profile_sort_mode')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            Row({ space: 8 }) {
              ForEach(['manual', 'latency', 'name'], (mode: string) => {
                Button(mode === 'manual' ? $r('app.string.sort_manual') : (mode === 'latency' ? $r('app.string.sort_latency') : $r('app.string.sort_name')))
                  .layoutWeight(1)
                  .backgroundColor(this.s.profileSortMode === mode ? $r('app.color.primary') : $r('app.color.surface'))
                  .fontColor(this.s.profileSortMode === mode ? $r('app.color.surface') : $r('app.color.text_primary'))
                  .visualEffect(pressLightEffect(this.litKey === `sort:${mode}`, true))
                  .onTouch((event: TouchEvent) => {
                    if (event.type === TouchType.Down) {
                      this.litKey = `sort:${mode}`;
                    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                      this.litKey = '';
                    }
                  })
                  .onClick(() => {
                    this.s.profileSortMode = mode;
                    this.markDirty();
                  })
              }, (mode: string) => mode)
            }.width('100%')
            Row() {
              Text($r('app.string.haptic_feedback')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.hapticFeedback })
                .onChange((v: boolean) => {
                  this.s.hapticFeedback = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Text($r('app.string.liquid_glass')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.liquidGlass })
                .onChange((v: boolean) => {
                  this.s.liquidGlass = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.network_change_reset_connections')).fontSize(14).width('100%')
                Text($r('app.string.network_change_reset_connections_sum'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.networkChangeResetConnections })
                .onChange((v: boolean) => {
                  this.s.networkChangeResetConnections = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.wake_reset_connections')).fontSize(14).width('100%')
                Text($r('app.string.wake_reset_connections_sum'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.wakeResetConnections })
                .onChange((v: boolean) => {
                  this.s.wakeResetConnections = v;
                  this.markDirty();
                })
            }.width('100%')
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.profile_traffic_statistics')).fontSize(14).width('100%')
                Text($r('app.string.profile_traffic_statistics_sum'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.profileTrafficStatistics })
                .onChange((v: boolean) => {
                  this.s.profileTrafficStatistics = v;
                  this.markDirty();
                })
            }.width('100%')
            Text($r('app.string.settings_theme_note'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }

          // Clash API 连接统计
          this.sectionHeader($r('sys.symbol.arrow_2_circlepath'), $r('app.string.clash_api_settings'), this.apiExpanded, () => { this.apiExpanded = !this.apiExpanded; }, 'advanced')
          if (this.apiExpanded) {
          Column({ space: 8 }) {
            Row() {
              Text($r('app.string.clash_api_enabled')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.clashApiEnabled })
                .onChange((value: boolean) => {
                  this.s.clashApiEnabled = value;
                  this.markDirty();
                })
            }.width('100%')
            Column() {
              Text($r('app.string.clash_api_port')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: `${this.s.clashApiPort}` })
                .width('100%')
                .height(40)
                .type(InputType.Number)
                .onChange((value: string) => {
                  const port = parseInt(value);
                  if (!isNaN(port)) {
                    this.s.clashApiPort = Math.max(1024, Math.min(65535, port));
                    this.markDirty();
                  }
                })
            }.alignItems(HorizontalAlign.Start).width('100%')
            Column() {
              Text($r('app.string.clash_api_secret')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              TextInput({ text: this.s.clashApiSecret })
                .width('100%')
                .height(40)
                .type(InputType.Password)
                .onChange((value: string) => {
                  this.s.clashApiSecret = value;
                  this.markDirty();
                })
            }.alignItems(HorizontalAlign.Start).width('100%')
            Text($r('app.string.clash_api_reconnect_hint'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          }


        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 12 })
      }
        .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
      /* P4/W16-A:变更列表(底部 sheet 覆盖层;§12.2) */
    }
    .width('100%')
    .height('100%')
  }
}

