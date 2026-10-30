#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""2026-10-26 设置页重排版(用户反馈"排得乱"):
  1) 标签与控件同行:所有「标签独占一行 + Select/TextInput 在下一行」改成 Row(标题左 / 控件右)
  2) 深浅色与节点排序两组分段按钮相邻(原先被液态玻璃/触感两个开关隔开)
  3) 节点流量统计开关连同功能一起下线(字段保留,旧备份仍可往返)
  4) 统一行构件(rowSwitch / rowSwitchPlain / rowSelect / rowInput / chipRow / subLabel)
幂等:以 `SETTINGS_ROWS_V3` 标记判断。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARK = 'SETTINGS_ROWS_V3'


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

# ---------------------------------------------------------------- 提取 Geo 块(原样复用)
geo_start = sp.index("            if (this.s.mode === 'rule') {")
geo_row = sp.index("                Row({ space: 8 }) {\n                  Text(this.geoOk ?", geo_start)
geo_end = sp.index("                }, (info: GeoAssetInfo) => `${info.kind}_${info.size}_${info.version}`)", geo_row)
geo_end = sp.index('\n', geo_end) + 1
geo_inner = sp[geo_row:geo_end]
assert geo_inner.rstrip().endswith(')'), 'Geo 块结尾异常'
geo_inner = geo_inner.rstrip('\n')

# ---------------------------------------------------------------- 定位替换区间
start = sp.index("          // 通用(只留在手机上手调有意义的项;专家项收进「高级」)")
end_marker = "        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 12, bottom: 12 })"
end = sp.index(end_marker, start)
assert end > start

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

          // 外观与交互(SETTINGS_ROWS_V3:深浅色与节点排序相邻,中间不再插开关)
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
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }

          Blank().height(18)

          // 网络(含 DNS:两块本来就是一个问题的两面)
          this.sectionHeader($r('sys.symbol.arrow_up_left_and_arrow_down_right'), $r('app.string.settings_route'), this.networkExpanded, () => { this.networkExpanded = !this.networkExpanded; }, 'mode')
          if (this.networkExpanded) {
            if (this.s.mode === 'rule') {
              Column({ space: 6 }) {
{GEO}
              }.alignItems(HorizontalAlign.Start).width('100%')
            }

            /* 以下全部一行式:标题在左,控件在右 */
            this.rowInput($r('app.string.settings_tun_mtu'), `${this.s.mtu}`, '9000', InputType.Number, 110,
              (v: string) => {
                const n = parseInt(v);
                this.s.mtu = isNaN(n) ? 9000 : n;
                this.markDirty();
              })
            this.rowSelect($r('app.string.settings_enable_ipv6'),
              IPV6_MODES.map((t: string, i: number) => ({{ value: IPV6_MODE_LABELS[i] }} as SelectOption)),
              this.ipv6Index(), (index: number) => {
                this.s.ipv6Mode = IPV6_MODES[index];
                this.markDirty();
              })
            this.rowSwitchPlain($r('app.string.settings_bypass_lan'), this.s.bypassLan,
              (v: boolean) => {
                this.s.bypassLan = v;
                this.markDirty();
              })
            Column({ space: 6 }) {
              Text($r('app.string.settings_sniff')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              this.chipRow(SNIFF_MODES, SNIFF_LABELS, this.s.sniffMode, 'sniff', (v: string) => {
                this.s.sniffMode = v;
                this.markDirty();
              })
            }.alignItems(HorizontalAlign.Start).width('100%')
            this.rowSwitch($r('app.string.settings_resolve_destination'), $r('app.string.settings_resolve_destination_desc'), this.s.resolveDestination,
              (v: boolean) => {
                this.s.resolveDestination = v;
                this.markDirty();
              })

            this.subLabel($r('app.string.settings_section_dns'))

            this.rowSelect($r('app.string.settings_remote_dns_strategy'),
              STRATEGIES.map((t: string, i: number) => ({{ value: STRATEGY_LABELS[i] }} as SelectOption)),
              this.strategyIndex(this.s.remoteDnsStrategy), (index: number) => {
                this.s.remoteDnsStrategy = STRATEGIES[index];
                this.markDirty();
              })
            this.rowInput($r('app.string.settings_direct_dns'), this.s.directDns, '', InputType.Normal, 170,
              (v: string) => {
                this.s.directDns = v;
                this.markDirty();
              })
            this.rowSelect($r('app.string.settings_direct_dns_strategy'),
              STRATEGIES.map((t: string, i: number) => ({{ value: STRATEGY_LABELS[i] }} as SelectOption)),
              this.strategyIndex(this.s.directDnsStrategy), (index: number) => {
                this.s.directDnsStrategy = STRATEGIES[index];
                this.markDirty();
              })
            Column({ space: 2 }) {
              this.rowSelect($r('app.string.settings_server_dns_strategy'),
                STRATEGIES.map((t: string, i: number) => ({{ value: STRATEGY_LABELS[i] }} as SelectOption)),
                this.strategyIndex(this.s.serverDnsStrategy), (index: number) => {
                  this.s.serverDnsStrategy = STRATEGIES[index];
                  this.markDirty();
                })
              Text($r('app.string.settings_server_dns_strategy_hint'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
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
              LOG_LEVELS.map((t: string) => ({{ value: t }} as SelectOption)),
              this.logLevelIndex(), (index: number) => {
                this.s.logLevel = LOG_LEVELS[index];
                this.markDirty();
              })
            this.rowSelect($r('app.string.latency_test_mode'),
              LATENCY_TEST_VALUES.map((t: string, i: number) => ({{ value: LATENCY_TEST_LABELS[i] }} as SelectOption)),
              this.latencyTestIndex(), (index: number) => {
                this.s.latencyTestMode = LATENCY_TEST_VALUES[index];
                this.markDirty();
              })
            Text($r('app.string.latency_test_mode_desc'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            this.rowInput($r('app.string.settings_test_url'), this.s.testUrl, '', InputType.Normal, 190,
              (v: string) => {
                this.s.testUrl = v;
                this.markDirty();
              })
            Text($r('app.string.settings_test_url_desc'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
            this.rowInput($r('app.string.settings_test_concurrent'), `${this.s.testConcurrent}`, '', InputType.Number, 80,
              (v: string) => {
                const n = parseInt(v);
                // 默认 5 对齐 Android DataStore.connectionTestConcurrent;钳制 1..32 防呆
                this.s.testConcurrent = isNaN(n) ? 5 : Math.max(1, Math.min(32, n));
                this.markDirty();
              })
            this.rowInput($r('app.string.settings_speed_interval'), `${this.s.speedIntervalMs}`, '1000', InputType.Number, 100,
              (v: string) => {
                const n = parseInt(v, 10);
                this.s.speedIntervalMs = isNaN(n) ? 1000 : n;
                this.markDirty();
              })
            Column({ space: 4 }) {
              Text($r('app.string.settings_global_custom_config')).fontSize(14).fontColor($r('app.color.text_1')).width('100%')
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

            this.rowInput($r('app.string.settings_mixed_port'), `${this.s.mixedPort > 0 ? this.s.mixedPort : ''}`, $r('app.string.settings_mixed_port_hint'), InputType.Number, 110,
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
            this.rowInput($r('app.string.lan_auth_user'), this.s.lanAuthUser, 'user', InputType.Normal, 170,
              (v: string) => {
                this.s.lanAuthUser = v;
                this.markDirty();
              })
            this.rowInput($r('app.string.lan_auth_pass'), this.s.lanAuthPass, 'password', InputType.Password, 170,
              (v: string) => {
                this.s.lanAuthPass = v;
                this.markDirty();
              })
            Text($r('app.string.settings_reconnect_note'))
              .fontSize(12).fontColor($r('app.color.error')).width('100%')

            this.subLabel($r('app.string.settings_clash_api'))

            this.rowSwitchPlain($r('app.string.clash_api_enabled'), this.s.clashApiEnabled,
              (v: boolean) => {
                this.s.clashApiEnabled = v;
                this.markDirty();
              })
            this.rowInput($r('app.string.clash_api_port'), `${this.s.clashApiPort}`, '', InputType.Number, 100,
              (v: string) => {
                const port = parseInt(v);
                if (!isNaN(port)) {
                  this.s.clashApiPort = Math.max(1024, Math.min(65535, port));
                  this.markDirty();
                }
              })
            this.rowInput($r('app.string.clash_api_secret'), this.s.clashApiSecret, '', InputType.Password, 190,
              (v: string) => {
                this.s.clashApiSecret = v;
                this.markDirty();
              })
            Text($r('app.string.clash_api_reconnect_hint'))
              .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          }

          Blank().height(18)

        }
'''.replace('{GEO}', geo_inner)

sp = sp[:start] + body + sp[end:]

# ---------------------------------------------------------------- 行构件 helpers
helpers = '''  /* ---- SETTINGS_ROWS_V3 2026-10-26:统一"标题在左、控件在右"的一行式行构件 ---- */

  /** 分区内的分组小标题(DNS / 入站 / Clash API) */
  @Builder
  private subLabel(text: ResourceStr) {
    Text(text)
      .fontSize(12)
      .fontWeight(600)
      .fontColor($r('app.color.text_2'))
      .width('100%')
      .margin({ top: 8, bottom: 2 })
  }

  /** 开关行(带说明文字) */
  @Builder
  private rowSwitch(title: ResourceStr, desc: ResourceStr, isOn: boolean, onChange: (v: boolean) => void) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title).fontSize(14).fontColor($r('app.color.text_1'))
        Text(desc).fontSize(11).fontColor($r('app.color.text_secondary'))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange(onChange)
    }.width('100%').alignItems(VerticalAlign.Center).padding({ top: 4, bottom: 4 })
  }

  /** 开关行(无说明文字) */
  @Builder
  private rowSwitchPlain(title: ResourceStr, isOn: boolean, onChange: (v: boolean) => void) {
    Row({ space: 10 }) {
      Text(title).fontSize(14).fontColor($r('app.color.text_1')).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange(onChange)
    }.width('100%').alignItems(VerticalAlign.Center).padding({ top: 6, bottom: 6 })
  }

  /** 下拉行:标题在左,Select 在右(占一行) */
  @Builder
  private rowSelect(title: ResourceStr, options: Array<SelectOption>, selected: number, onSelect: (index: number) => void) {
    Row({ space: 10 }) {
      Text(title).fontSize(14).fontColor($r('app.color.text_1')).layoutWeight(1)
      Select(options)
        .selected(selected < 0 ? 0 : selected)
        .fontSize(13)
        .width(150)
        .onSelect(onSelect)
    }.width('100%').alignItems(VerticalAlign.Center).padding({ top: 4, bottom: 4 })
  }

  /** 输入行:标题在左,TextInput 在右(占一行) */
  @Builder
  private rowInput(title: ResourceStr, value: string, placeholder: ResourceStr, inputType: InputType,
    width: number, onChange: (v: string) => void) {
    Row({ space: 10 }) {
      Text(title).fontSize(14).fontColor($r('app.color.text_1')).layoutWeight(1)
      TextInput({ text: value, placeholder: placeholder })
        .type(inputType)
        .width(width)
        .height(36)
        .fontSize(13)
        .onChange(onChange)
    }.width('100%').alignItems(VerticalAlign.Center).padding({ top: 4, bottom: 4 })
  }

  /** 分段按钮组(深浅色 / 节点排序 / 嗅探模式) */
  @Builder
  private chipRow(values: Array<string>, labels: Array<ResourceStr>, current: string, keyPrefix: string,
    onPick: (v: string) => void) {
    Row({ space: 8 }) {
      ForEach(values, (v: string, idx: number) => {
        Button(labels[idx])
          .layoutWeight(1)
          .fontSize(13)
          .backgroundColor(current === v ? $r('app.color.primary') : $r('app.color.surface'))
          .fontColor(current === v ? $r('app.color.surface') : $r('app.color.text_primary'))
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
    }.width('100%')
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

anchor = "  build() {\n    Stack({ alignContent: Alignment.Bottom }) {"
assert anchor in sp, 'build() 锚点不匹配'
sp = sp.replace(anchor, helpers + anchor, 1)
wr('entry/src/main/ets/pages/SettingsPage.ets', sp)

# ---------------------------------------------------------------- 节点流量统计:功能下线
idx = rd('entry/src/main/ets/pages/Index.ets')
block = """        if (this.settings.profileTrafficStatistics && (p.rx > 0 || p.tx > 0)) {
          // 历史累计流量(对齐安卓节点卡流量显示):↓接收 ↑发送
          Text(`↓${formatBytes(p.rx)} ↑${formatBytes(p.tx)}`)
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
            .maxLines(1)
        }
"""
if block in idx:
    idx = idx.replace(block, '', 1)
    wr('entry/src/main/ets/pages/Index.ets', idx)

vpn = rd('entry/src/main/ets/vpnext/VpnExtAbility.ets')
call = "    void this.persistSessionTraffic();\n"
if call in vpn:
    vpn = vpn.replace(call, '', 1)
m_start = vpn.index("  /**\n   * 把本次会话的上下行累计写入节点记录(对齐安卓 profileTrafficStatistics):")
m_end = vpn.index("  private formatNotificationSpeed(", m_start)
vpn = vpn[:m_start] + vpn[m_end:]
wr('entry/src/main/ets/vpnext/VpnExtAbility.ets', vpn)
print('设置页重排版完成')
