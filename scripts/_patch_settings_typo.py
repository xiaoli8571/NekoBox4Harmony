#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""2026-10-27 设置页排版统一(用户反馈:行距有的大有的小、右侧框体大小不一、
字号大小不一、文字颜色深浅不一):
  1) 排版度量单源(ROW_TITLE_SIZE / ROW_DESC_SIZE / GROUP_LABEL_SIZE / ROW_HEIGHT /
     CONTROL_HEIGHT / SELECT_WIDTH),所有行构件与 Geo 块全部改用常量
  2) 所有一行式行固定 ROW_HEIGHT(48) ⇒ 行距完全一致;控件统一 CONTROL_HEIGHT(34)
  3) 颜色归一:标题一律 text_1,说明/提示/备注一律 text_2(去掉 text_primary/text_secondary/text_3 混用)
  4) 搜索框、搜索结果面板、待应用横幅同步统一
幂等:以 `SETTINGS_TYPO_V4` 标记判断。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARK = 'SETTINGS_TYPO_V4'


def rd(rel):
    with io.open(os.path.join(ROOT, rel), encoding='utf-8') as f:
        return f.read()


def wr(rel, text):
    with io.open(os.path.join(ROOT, rel), 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)


sp = rd('entry/src/main/ets/pages/SettingsPage.ets')
if MARK in sp:
    print('已应用过,退出(幂等)')
    sys.exit(0)

# ---------------------------------------------------------------- 1) 排版度量常量
const_anchor = "const IPV6_MODE_LABELS: Array<Resource> = [$r('app.string.ipv6_mode_disable'), $r('app.string.ipv6_mode_enable'), $r('app.string.ipv6_mode_prefer'), $r('app.string.ipv6_mode_only')];"
assert const_anchor in sp, 'IPV6 常量锚点不匹配'
constants = const_anchor + '''

/* SETTINGS_TYPO_V4 2026-10-27:全页排版度量单源(用户反馈行距/框体/字号/颜色不齐)。
   改这里即可整页缩放,不要在构件里再写魔法数字。 */
const ROW_TITLE_SIZE: number = 14;    // 行标题
const ROW_DESC_SIZE: number = 11;     // 行说明 / 提示 / 备注
const GROUP_LABEL_SIZE: number = 12;  // 分区内分组小标题
const CONTROL_LABEL_SIZE: number = 12; // 小按钮文字(Geo 更新/删除/导入)
const ROW_HEIGHT: number = 48;        // 一行式行高:所有行一致,行距才齐
const CONTROL_HEIGHT: number = 34;    // 右侧控件(输入框/按钮/分段)统一高度
const SELECT_WIDTH: number = 150;     // 下拉统一宽度'''
sp = sp.replace(const_anchor, constants, 1)

# ---------------------------------------------------------------- 2) 行构件统一
h_start = sp.index("  /* ---- SETTINGS_ROWS_V3 2026-10-26")
h_end = sp.index("  build() {\n    Stack({ alignContent: Alignment.Bottom }) {")
helpers = '''  /* ---- SETTINGS_TYPO_V4 2026-10-27:统一"标题在左、控件在右"的一行式行构件 ---- */

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

'''
sp = sp[:h_start] + helpers + sp[h_end:]

# ---------------------------------------------------------------- 3) 分区体重排(统一度量)
start = sp.index("          // 通用(只留在手机上手调有意义的项;专家项收进「高级」)")
end_marker = "        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 12 })"
end = sp.index(end_marker, start)

body = '''          // 通用(只留在手机上手调有意义的项;专家项收进「高级」)
          this.sectionHeader($r('sys.symbol.gearshape'), $r('app.string.settings_general'), this.generalExpanded, () => { this.generalExpanded = !this.generalExpanded; }, '')
          if (this.generalExpanded) {
            this.rowSwitch($r('app.string.settings_auto_connect'), $r('app.string.settings_auto_connect_desc'), this.s.autoConnect,
              (v: boolean) => {
                this.s.autoConnect = v;
                this.markDirty();
              })
            this.rowSwitch($r('app.string.settings_auto_start_boot'), $r('app.string.settings_auto_start_boot_desc'), this.s.autoStartOnBoot,
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
            this.rowSwitch($r('app.string.network_change_reset_connections'), $r('app.string.network_change_reset_connections_sum'), this.s.networkChangeResetConnections,
              (v: boolean) => {
                this.s.networkChangeResetConnections = v;
                this.markDirty();
              })
            this.rowSwitch($r('app.string.wake_reset_connections'), $r('app.string.wake_reset_connections_sum'), this.s.wakeResetConnections,
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
'''
sp = sp[:start] + body + sp[end:]

# ---------------------------------------------------------------- 4) 颜色/字号归一(全页)
sp = sp.replace("$r('app.color.text_secondary')", "$r('app.color.text_2')")
sp = sp.replace("$r('app.color.text_primary')", "$r('app.color.text_1')")
sp = sp.replace("$r('app.color.text_3')", "$r('app.color.text_2')")

# 搜索框:图标/输入框/清除按钮统一
sp = sp.replace("""      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(14)
        .fontColor([$r('app.color.text_2')])""",
                """      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(ROW_TITLE_SIZE)
        .fontColor([$r('app.color.text_2')])""")
sp = sp.replace("""      TextInput({ text: this.settingsQuery, placeholder: $r('app.string.settings_search_hint') })
        .height(36)
        .layoutWeight(1)
        .backgroundColor(Color.Transparent)
        .fontSize(13)""",
                """      TextInput({ text: this.settingsQuery, placeholder: $r('app.string.settings_search_hint') })
        .height(CONTROL_HEIGHT)
        .layoutWeight(1)
        .backgroundColor(Color.Transparent)
        .fontSize(ROW_TITLE_SIZE)""")
sp = sp.replace("""        Text($r('app.string.settings_clear_search'))
          .fontSize(12)
          .fontColor($r('app.color.primary'))""",
                """        Text($r('app.string.settings_clear_search'))
          .fontSize(GROUP_LABEL_SIZE)
          .fontColor($r('app.color.primary'))""")

# 搜索结果面板:标题 14 / 副行 11 / 值 11,行距与分区行一致
sp = sp.replace("""            Text(this.settingLabelOf(def.labelToken))
              .fontSize(13)
              .fontColor($r('app.color.text_1'))""",
                """            Text(this.settingLabelOf(def.labelToken))
              .fontSize(ROW_TITLE_SIZE)
              .fontColor($r('app.color.text_1'))""")
sp = sp.replace("""            Text(`${this.resText(this.sectionLabelOf(def.section))} · ${def.key}`)
              .fontSize(10)
              .fontColor($r('app.color.text_2'))""",
                """            Text(`${this.resText(this.sectionLabelOf(def.section))} · ${def.key}`)
              .fontSize(ROW_DESC_SIZE)
              .fontColor($r('app.color.text_2'))""")
sp = sp.replace("""          Text(this.displayValue(this.draftValueOf(def.key)))
            .fontSize(11)
            .fontColor($r('app.color.text_2'))""",
                """          Text(this.displayValue(this.draftValueOf(def.key)))
            .fontSize(ROW_DESC_SIZE)
            .fontColor($r('app.color.text_2'))""")
sp = sp.replace("""        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          this.jumpToSchemaSection(def.section);""",
                """        .padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .onClick(() => {
          this.jumpToSchemaSection(def.section);""")

wr('entry/src/main/ets/pages/SettingsPage.ets', sp)

# ---------------------------------------------------------------- 5) 待应用横幅同步
idx = rd('entry/src/main/ets/pages/Index.ets')
idx = idx.replace("""        Text(this.applyBannerTitle())
          .fontSize(13)
          .fontWeight(700)""",
                  """        Text(this.applyBannerTitle())
          .fontSize(14)
          .fontWeight(700)""")
idx = idx.replace("""        Text(this.applyBannerSubtitle())
          .fontSize(11)
          .fontColor($r('app.color.text_3'))""",
                  """        Text(this.applyBannerSubtitle())
          .fontSize(11)
          .fontColor($r('app.color.text_2'))""")
idx = idx.replace("""        Button('应用')
          .height(30)
          .fontSize(12)""",
                  """        Button('应用')
          .height(34)
          .fontSize(12)""")
idx = idx.replace("""        Button('稍后')
          .height(30)
          .fontSize(12)""",
                  """        Button('稍后')
          .height(34)
          .fontSize(12)""")
wr('entry/src/main/ets/pages/Index.ets', idx)
print('排版统一完成')
