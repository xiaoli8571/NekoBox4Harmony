import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { AppSettings } from '../model/Profile';
import { initStore, loadSettings, saveSettings, LogStore } from '../model/Store';
import { geoReady, downloadGeoAssets, importGeoAssetFromFile, geoAssetInfos, downloadGeoAsset, deleteGeoAsset, GeoAssetInfo } from '../utils/GeoAssets';
import { formatBytes } from '../utils/TrafficStats';
import { pressLightEffect } from '../common/Effects';
import { publishAccent } from '../common/Theme';
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
  ['settings_notification_profile', $r('app.string.settings_notification_profile')],
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
  ['settings_coexist_fix', $r('app.string.settings_coexist_fix')],
  ['settings_auto_start_boot', $r('app.string.settings_auto_start_boot')],
  ['settings_lan_auth_user', $r('app.string.settings_lan_auth_user')],
  ['settings_lan_auth_pass', $r('app.string.settings_lan_auth_pass')],
  ['settings_theme_accent', $r('app.string.settings_theme_accent')],
  ['settings_home_sections', $r('app.string.settings_home_sections')]
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

/* SETTINGS_TYPO_V4 2026-10-27:全页排版度量单源(用户反馈行距/框体/字号/颜色不齐)。
   改这里即可整页缩放,不要在构件里再写魔法数字。 */
const ROW_TITLE_SIZE: number = 14;    // 行标题
const ROW_DESC_SIZE: number = 11;     // 行说明 / 提示 / 备注
const GROUP_LABEL_SIZE: number = 12;  // 分区内分组小标题
const CONTROL_LABEL_SIZE: number = 12; // 小按钮文字(Geo 更新/删除/导入)
const ROW_HEIGHT: number = 48; /* SETTINGS_TYPO_V5 */        // 一行式行高:所有行一致,行距才齐
const CONTROL_HEIGHT: number = 34;    // 右侧控件(输入框/按钮/分段)统一高度
const SELECT_WIDTH: number = 150;     // 下拉统一宽度

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
  /* SETTINGS_HEADER_TYPO_V2 2026-10-26:用户要求默认全部展开(折叠只作为"收起长页面"的手段) */
  @State generalExpanded: boolean = true;
  @State appearanceExpanded: boolean = true;
  @State networkExpanded: boolean = true;
  @State advancedExpanded: boolean = true;
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
      publishAccent(this.s.themeAccent);
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
      return $r('app.color.text_2');
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
    /* 2026-10-26 重排后只有四个折叠区:通用 / 外观 / 网络(含 DNS) / 高级(含入站+Clash) */
    if (sectionId === 'appearance') {
      this.appearanceExpanded = true;
    } else if (sectionId === 'dns' || sectionId === 'ipv6' || sectionId === 'mode') {
      this.networkExpanded = true;
    } else if (sectionId === 'inbound' || sectionId === 'advanced') {
      this.advancedExpanded = true;
    } else {
      /* startup / probe:字段落在「通用」区 */
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
        .fontSize(ROW_TITLE_SIZE)
        .fontColor([$r('app.color.text_2')])
      TextInput({ text: this.settingsQuery, placeholder: $r('app.string.settings_search_hint') })
        .height(CONTROL_HEIGHT)
        .layoutWeight(1)
        .backgroundColor(Color.Transparent)
        .fontSize(ROW_TITLE_SIZE)
        .onChange((v: string) => {
          this.settingsQuery = v;
        })
      if (this.settingsQuery.length > 0) {
        Text($r('app.string.settings_clear_search'))
          .fontSize(GROUP_LABEL_SIZE)
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
              .fontSize(ROW_TITLE_SIZE)
              .fontColor($r('app.color.text_1'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${this.resText(this.sectionLabelOf(def.section))} · ${def.key}`)
              .fontSize(ROW_DESC_SIZE)
              .fontColor($r('app.color.text_2'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.displayValue(this.draftValueOf(def.key)))
            .fontSize(ROW_DESC_SIZE)
            .fontColor($r('app.color.text_2'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '40%' })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
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
        /* SETTINGS_HEADER_TYPO_V2:分类名是页面骨架,12/700 太弱看不清 ⇒ 16/800 + 主文字色 */
        SymbolGlyph(icon)
          .fontSize(20)
          .fontColor([$r('app.color.text_1')])
          .width(28)
        Text(title)
          .fontSize(16)
          .fontWeight(800)
          .fontColor($r('app.color.text_1'))
          .letterSpacing(0.5)
          .layoutWeight(1)
        SymbolGlyph(expanded ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(16)
          .fontColor([$r('app.color.text_2')])
      }
      .layoutWeight(1)
      .padding({ top: 20, bottom: 12 })
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
          .fontSize(12)
          .fontWeight(500)
          .fontColor($r('app.color.primary'))
          .padding({ top: 20, bottom: 12, left: 4, right: 2 })
          .onClick(() => {
            this.restoreSectionDefaults(sectionId);
          })
      }
    }
    .width('100%')
    .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
  }

  /* ---- SETTINGS_TYPO_V4 2026-10-27:统一"标题在左、控件在右"的一行式行构件 ---- */

  /** 分区内的分组小标题(DNS / 入站 / Clash API / 流量嗅探) */
  @Builder
  private subLabel(text: ResourceStr) {
    Text(text)
      .fontSize(GROUP_LABEL_SIZE)
      .fontWeight(600)
      .fontColor($r('app.color.text_1'))
      .width('100%')
      .margin({ top: 10, bottom: 2 })
  }

  /** 开关行(带说明文字) */
  @Builder
  private rowSwitch(title: ResourceStr, desc: ResourceStr, isOn: boolean, onChange: (v: boolean) => void) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title).fontSize(ROW_TITLE_SIZE).fontColor($r('app.color.text_1'))
        Text(desc).fontSize(ROW_DESC_SIZE).fontColor($r('app.color.text_2'))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange(onChange)
    }.width('100%').height(ROW_HEIGHT).alignItems(VerticalAlign.Center)
  }

  /** 开关行(无说明文字) */
  @Builder
  private rowSwitchPlain(title: ResourceStr, isOn: boolean, onChange: (v: boolean) => void) {
    Row({ space: 10 }) {
      Text(title).fontSize(ROW_TITLE_SIZE).fontColor($r('app.color.text_1')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange(onChange)
    }.width('100%').height(ROW_HEIGHT).alignItems(VerticalAlign.Center)
  }

  /** 下拉行:标题在左,Select 在右(占一行) */
  @Builder
  private rowSelect(title: ResourceStr, options: Array<SelectOption>, selected: number, onSelect: (index: number) => void) {
    Row({ space: 10 }) {
      Text(title).fontSize(ROW_TITLE_SIZE).fontColor($r('app.color.text_1')).layoutWeight(1)
      Select(options)
        .selected(selected < 0 ? 0 : selected)
        /* SETTINGS_TYPO_V5:只设 selected 不设 value ⇒ 文本框显示为空(真机反馈),
           必须回填当前选中项标签才能显示默认值 */
        .value(selected < 0 || selected >= options.length ? '' : options[selected].value)
        .width(SELECT_WIDTH)
        .height(CONTROL_HEIGHT)
        .onSelect(onSelect)
    }.width('100%').height(ROW_HEIGHT).alignItems(VerticalAlign.Center)
  }

  /** 输入行:标题在左,TextInput 在右(占一行) */
  @Builder
  private rowInput(title: ResourceStr, value: string, placeholder: ResourceStr, inputType: InputType,
    onChange: (v: string) => void) {
    Row({ space: 10 }) {
      Text(title).fontSize(ROW_TITLE_SIZE).fontColor($r('app.color.text_1')).layoutWeight(1)
      TextInput({ text: value, placeholder: placeholder })
        .type(inputType)
        .width(SELECT_WIDTH)
        .height(CONTROL_HEIGHT)
        .fontSize(ROW_DESC_SIZE)
        .onChange(onChange)
    }.width('100%').height(ROW_HEIGHT).alignItems(VerticalAlign.Center)
  }

  /** 分段按钮组(深浅色 / 节点排序 / 嗅探模式) */
  @Builder
  private chipRow(values: Array<string>, labels: Array<ResourceStr>, current: string, keyPrefix: string,
    onPick: (v: string) => void) {
    Row({ space: 8 }) {
      ForEach(values, (v: string, idx: number) => {
        Button(labels[idx])
          .layoutWeight(1)
          .height(CONTROL_HEIGHT)
          .fontSize(ROW_DESC_SIZE)
          .backgroundColor(current === v ? $r('app.color.primary') : $r('app.color.surface'))
          .fontColor(current === v ? $r('app.color.surface') : $r('app.color.text_1'))
          .visualEffect(pressLightEffect(this.litKey === `${keyPrefix}:${v}`, true))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litKey = `${keyPrefix}:${v}`;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litKey = '';
            }
          })
          .onClick(() => onPick(v))
      }, (v: string) => v)
    }.width('100%').height(ROW_HEIGHT).alignItems(VerticalAlign.Center)
  }

  /** Geo 小按钮(下载/更新/删除/导入):统一高度与字号 */
  @Builder
  private geoButton(text: ResourceStr, litId: string, danger: boolean, enabled: boolean, onTap: () => void) {
    Button(text)
      .height(CONTROL_HEIGHT)
      .fontSize(CONTROL_LABEL_SIZE)
      .backgroundColor(danger ? $r('app.color.surface') : $r('app.color.primary'))
      .fontColor(danger ? $r('app.color.error') : $r('app.color.surface'))
      .enabled(enabled)
      .visualEffect(pressLightEffect(this.litKey === litId, true))
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.litKey = litId;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.litKey = '';
        }
      })
      .onClick(() => onTap())
  }

  /** IPv6 模式索引(legacy boolean 兼容:无 mode 时按 ipv6 布尔回落) */
  private ipv6Index(): number {
    const i = IPV6_MODES.indexOf(this.s.ipv6Mode);
    return i < 0 ? (this.s.ipv6 ? 1 : 0) : i;
  }

  private strategyIndex(v: string): number {
    const i = STRATEGIES.indexOf(v);
    return i < 0 ? 0 : i;
  }

  private logLevelIndex(): number {
    const i = LOG_LEVELS.indexOf(this.s.logLevel);
    return i < 0 ? 2 : i;
  }

  private latencyTestIndex(): number {
    const i = LATENCY_TEST_VALUES.indexOf(this.s.latencyTestMode);
    return i < 0 ? 0 : i;
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
            .fontColor($r('app.color.text_2'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      } else if (this.loadError.length > 0) {
        Column({ space: 8 }) {
          Text($r('app.string.settings_load_failed'))
            .fontSize(16)
            .fontWeight(500)
            .fontColor($r('app.color.text_1'))
          Text(this.loadError)
            .fontSize(13)
            .fontColor($r('app.color.error'))
          Button($r('app.string.reload'))
            .height(36)
            .backgroundColor(this.litKey === 'reload' ? $r('app.color.primary') : $r('app.color.surface'))
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
          // 通用(只留在手机上手调有意义的项;专家项收进「高级」)
          this.sectionHeader($r('sys.symbol.gearshape'), $r('app.string.settings_general'), this.generalExpanded, () => { this.generalExpanded = !this.generalExpanded; }, '')
          if (this.generalExpanded) {
            this.rowSwitchPlain($r('app.string.settings_auto_connect'), this.s.autoConnect,
              (v: boolean) => {
                this.s.autoConnect = v;
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.settings_auto_start_boot'), this.s.autoStartOnBoot,
              (v: boolean) => {
                this.s.autoStartOnBoot = v;
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.settings_always_show_address'), this.s.alwaysShowAddress,
              (v: boolean) => {
                this.s.alwaysShowAddress = v;
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.show_bottom_bar'), this.s.showBottomBar,
              (v: boolean) => {
                this.s.showBottomBar = v;
                this.markDirty();
              })
          }

          Blank().height(18)

          // 外观与交互(深浅色与节点排序相邻,中间不再插开关)
          this.sectionHeader($r('sys.symbol.brightness'), $r('app.string.appearance_and_interaction'), this.appearanceExpanded, () => { this.appearanceExpanded = !this.appearanceExpanded; }, 'appearance')
          if (this.appearanceExpanded) {
            this.chipRow(['system', 'light', 'dark'],
              [$r('app.string.appearance_follow_system'), $r('app.string.appearance_light'), $r('app.string.appearance_dark')],
              this.s.appearance, 'appearance', (v: string) => {
                this.s.appearance = v;
                this.applyAppearance();
                this.markDirty();
              })
            this.chipRow(['manual', 'latency', 'name'],
              [$r('app.string.sort_manual'), $r('app.string.sort_latency'), $r('app.string.sort_name')],
              this.s.profileSortMode, 'sort', (v: string) => {
                this.s.profileSortMode = v;
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.liquid_glass'), this.s.liquidGlass,
              (v: boolean) => {
                this.s.liquidGlass = v;
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.haptic_feedback'), this.s.hapticFeedback,
              (v: boolean) => {
                this.s.hapticFeedback = v;
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.network_change_reset_connections'), this.s.networkChangeResetConnections,
              (v: boolean) => {
                this.s.networkChangeResetConnections = v;
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.wake_reset_connections'), this.s.wakeResetConnections,
              (v: boolean) => {
                this.s.wakeResetConnections = v;
                this.markDirty();
              })
            Text($r('app.string.settings_theme_note'))
              .fontSize(ROW_DESC_SIZE).fontColor($r('app.color.text_2')).width('100%')
          }

          Blank().height(18)

          // 网络(含 DNS:两块本来就是一个问题的两面)
          this.sectionHeader($r('sys.symbol.arrow_up_left_and_arrow_down_right'), $r('app.string.settings_route'), this.networkExpanded, () => { this.networkExpanded = !this.networkExpanded; }, 'mode')
          if (this.networkExpanded) {
            if (this.s.mode === 'rule') {
              Column({ space: 4 }) {
                Row({ space: 8 }) {
                  Text(this.geoOk ? $r('app.string.settings_geo_ready')
                    : $r('app.string.settings_geo_missing'))
                    .fontSize(ROW_TITLE_SIZE)
                    .fontColor(this.geoOk ? $r('app.color.success') : $r('app.color.text_2'))
                    .layoutWeight(1)
                    .maxLines(2)
                  this.geoButton(this.geoLoading ? $r('app.string.settings_geo_downloading')
                    : (this.geoOk ? $r('app.string.settings_geo_redownload') : $r('app.string.settings_geo_download')),
                    'geo:download', false, !this.geoLoading, () => this.downloadGeo())
                }.width('100%').height(ROW_HEIGHT).alignItems(VerticalAlign.Center)
                Row({ space: 8 }) {
                  Text($r('app.string.settings_geo_import_hint'))
                    .fontSize(ROW_DESC_SIZE).fontColor($r('app.color.text_2')).layoutWeight(1)
                  this.geoButton($r('app.string.settings_geo_import'), 'geo:import', false, !this.geoLoading,
                    () => { void this.importGeo(); })
                }.width('100%').height(ROW_HEIGHT).alignItems(VerticalAlign.Center)

                // 资产列表(对齐安卓 AssetsActivity:每库名称/大小/版本 + 单库更新/删除)
                ForEach(this.geoInfos, (info: GeoAssetInfo) => {
                  Row({ space: 8 }) {
                    Column({ space: 2 }) {
                      Text(info.kind === 'site' ? $r('app.string.settings_geo_site') : $r('app.string.settings_geo_ip'))
                        .fontSize(ROW_TITLE_SIZE).fontColor($r('app.color.text_1'))
                      Text(info.size > 0
                        ? $r('app.string.geo_asset_status', formatBytes(info.size), info.version)
                        : $r('app.string.geo_asset_absent'))
                        .fontSize(ROW_DESC_SIZE).fontColor($r('app.color.text_2'))
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    this.geoButton(this.geoLoading ? $r('app.string.settings_geo_downloading') : $r('app.string.settings_geo_update_one'),
                      `geo:update:${info.kind}`, false, !this.geoLoading, () => { void this.downloadSingleGeo(info.kind); })
                    if (info.size > 0) {
                      this.geoButton($r('app.string.settings_geo_delete'), `geo:delete:${info.kind}`, true, !this.geoLoading,
                        () => this.confirmDeleteGeo(info))
                    }
                  }.width('100%').height(ROW_HEIGHT).alignItems(VerticalAlign.Center)
                }, (info: GeoAssetInfo) => `${info.kind}_${info.size}_${info.version}`)
              }.alignItems(HorizontalAlign.Start).width('100%')
            }

            /* 以下全部一行式:标题在左,控件在右,行高统一 */
            this.rowInput($r('app.string.settings_tun_mtu'), `${this.s.mtu}`, '9000', InputType.Number,
              (v: string) => {
                const n = parseInt(v);
                this.s.mtu = isNaN(n) ? 9000 : n;
                this.markDirty();
              })
            this.rowSelect($r('app.string.settings_enable_ipv6'),
              IPV6_MODES.map((t: string, i: number) => ({ value: IPV6_MODE_LABELS[i] } as SelectOption)),
              this.ipv6Index(), (index: number) => {
                this.s.ipv6Mode = IPV6_MODES[index];
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.settings_bypass_lan'), this.s.bypassLan,
              (v: boolean) => {
                this.s.bypassLan = v;
                this.markDirty();
              })
            this.subLabel($r('app.string.settings_sniff'))
            this.chipRow(SNIFF_MODES, SNIFF_LABELS, this.s.sniffMode, 'sniff', (v: string) => {
              this.s.sniffMode = v;
              this.markDirty();
            })
            this.rowSwitch($r('app.string.settings_resolve_destination'), $r('app.string.settings_resolve_destination_desc'), this.s.resolveDestination,
              (v: boolean) => {
                this.s.resolveDestination = v;
                this.markDirty();
              })

            this.subLabel($r('app.string.settings_section_dns'))

            this.rowSelect($r('app.string.settings_remote_dns_strategy'),
              STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)),
              this.strategyIndex(this.s.remoteDnsStrategy), (index: number) => {
                this.s.remoteDnsStrategy = STRATEGIES[index];
                this.markDirty();
              })
            this.rowInput($r('app.string.settings_direct_dns'), this.s.directDns, '', InputType.Normal,
              (v: string) => {
                this.s.directDns = v;
                this.markDirty();
              })
            this.rowSelect($r('app.string.settings_direct_dns_strategy'),
              STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)),
              this.strategyIndex(this.s.directDnsStrategy), (index: number) => {
                this.s.directDnsStrategy = STRATEGIES[index];
                this.markDirty();
              })
            Column({ space: 2 }) {
              this.rowSelect($r('app.string.settings_server_dns_strategy'),
                STRATEGIES.map((t: string, i: number) => ({ value: STRATEGY_LABELS[i] } as SelectOption)),
                this.strategyIndex(this.s.serverDnsStrategy), (index: number) => {
                  this.s.serverDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
              Text($r('app.string.settings_server_dns_strategy_hint'))
                .fontSize(ROW_DESC_SIZE).fontColor($r('app.color.text_2')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')
            this.rowSwitch($r('app.string.settings_dns_routing'), $r('app.string.settings_dns_routing_desc'), this.s.dnsRouting,
              (v: boolean) => {
                this.s.dnsRouting = v;
                this.markDirty();
              })
            this.rowSwitch($r('app.string.settings_fakedns'), $r('app.string.settings_fakedns_desc'), this.s.fakeDns,
              (v: boolean) => {
                this.s.fakeDns = v;
                this.markDirty();
              })
          }

          Blank().height(18)

          // 高级(默认展开:折叠只作为"收起长页面"的手段)
          this.sectionHeader($r('sys.symbol.line_3_horizontal'), $r('app.string.settings_advanced'), this.advancedExpanded, () => { this.advancedExpanded = !this.advancedExpanded; }, 'advanced')
          if (this.advancedExpanded) {
            this.rowSelect($r('app.string.settings_log_level'),
              LOG_LEVELS.map((t: string) => ({ value: t } as SelectOption)),
              this.logLevelIndex(), (index: number) => {
                this.s.logLevel = LOG_LEVELS[index];
                this.markDirty();
              })
            this.rowSelect($r('app.string.latency_test_mode'),
              LATENCY_TEST_VALUES.map((t: string, i: number) => ({ value: LATENCY_TEST_LABELS[i] } as SelectOption)),
              this.latencyTestIndex(), (index: number) => {
                this.s.latencyTestMode = LATENCY_TEST_VALUES[index];
                this.markDirty();
              })
            Text($r('app.string.latency_test_mode_desc'))
              .fontSize(ROW_DESC_SIZE).fontColor($r('app.color.text_2')).width('100%')
            this.rowInput($r('app.string.settings_test_url'), this.s.testUrl, '', InputType.Normal,
              (v: string) => {
                this.s.testUrl = v;
                this.markDirty();
              })
            Text($r('app.string.settings_test_url_desc'))
              .fontSize(ROW_DESC_SIZE).fontColor($r('app.color.text_2')).width('100%')
            this.rowInput($r('app.string.settings_test_concurrent'), `${this.s.testConcurrent}`, '', InputType.Number,
              (v: string) => {
                const n = parseInt(v);
                // 默认 5 对齐 Android DataStore.connectionTestConcurrent;钳制 1..32 防呆
                this.s.testConcurrent = isNaN(n) ? 5 : Math.max(1, Math.min(32, n));
                this.markDirty();
              })
            this.rowInput($r('app.string.settings_speed_interval'), `${this.s.speedIntervalMs}`, '1000', InputType.Number,
              (v: string) => {
                const n = parseInt(v, 10);
                this.s.speedIntervalMs = isNaN(n) ? 1000 : n;
                this.markDirty();
              })
            Column({ space: 4 }) {
              Text($r('app.string.settings_global_custom_config'))
                .fontSize(ROW_TITLE_SIZE).fontColor($r('app.color.text_1')).width('100%')
              TextArea({ text: this.s.globalCustomConfig, placeholder: '{"log":{"level":"info"}}' })
                .height(90)
                .fontSize(ROW_DESC_SIZE)
                .fontFamily('monospace')
                .width('100%')
                .onChange((v: string) => {
                  this.s.globalCustomConfig = v;
                  this.markDirty();
                })
              Text($r('app.string.settings_global_custom_config_desc'))
                .fontSize(ROW_DESC_SIZE).fontColor($r('app.color.text_2')).width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%')
            this.rowSwitch($r('app.string.settings_insecure_tls'), $r('app.string.settings_insecure_tls_desc'), this.s.allowInsecureAll,
              (v: boolean) => {
                this.s.allowInsecureAll = v;
                this.markDirty();
              })
            this.rowSwitch($r('app.string.settings_sub_allow_insecure'), $r('app.string.settings_sub_allow_insecure_desc'), this.s.subAllowInsecure,
              (v: boolean) => {
                this.s.subAllowInsecure = v;
                this.markDirty();
              })

            this.subLabel($r('app.string.settings_section_inbound'))

            this.rowInput($r('app.string.settings_mixed_port'), `${this.s.mixedPort > 0 ? this.s.mixedPort : ''}`, $r('app.string.settings_mixed_port_hint'), InputType.Number,
              (v: string) => {
                const n = parseInt(v);
                this.s.mixedPort = isNaN(n) ? 0 : Math.max(0, Math.min(65535, n));
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.settings_allow_access'), this.s.allowAccess,
              (v: boolean) => {
                this.s.allowAccess = v;
                this.markDirty();
              })
            this.rowInput($r('app.string.lan_auth_user'), this.s.lanAuthUser, 'user', InputType.Normal,
              (v: string) => {
                this.s.lanAuthUser = v;
                this.markDirty();
              })
            this.rowInput($r('app.string.lan_auth_pass'), this.s.lanAuthPass, 'password', InputType.Password,
              (v: string) => {
                this.s.lanAuthPass = v;
                this.markDirty();
              })
            Text($r('app.string.settings_reconnect_note'))
              .fontSize(ROW_DESC_SIZE).fontColor($r('app.color.error')).width('100%')

            this.subLabel($r('app.string.settings_clash_api'))

            this.rowSwitchPlain($r('app.string.clash_api_enabled'), this.s.clashApiEnabled,
              (v: boolean) => {
                this.s.clashApiEnabled = v;
                this.markDirty();
              })
            this.rowInput($r('app.string.clash_api_port'), `${this.s.clashApiPort}`, '', InputType.Number,
              (v: string) => {
                const port = parseInt(v);
                if (!isNaN(port)) {
                  this.s.clashApiPort = Math.max(1024, Math.min(65535, port));
                  this.markDirty();
                }
              })
            this.rowInput($r('app.string.clash_api_secret'), this.s.clashApiSecret, '', InputType.Password,
              (v: string) => {
                this.s.clashApiSecret = v;
                this.markDirty();
              })
            Text($r('app.string.clash_api_reconnect_hint'))
              .fontSize(ROW_DESC_SIZE).fontColor($r('app.color.text_2')).width('100%')
          }

          Blank().height(18)

        }
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

