#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""2026-10-30 真机反馈两项修复:
  A) 行尾选择框显示为空:旧版 Select 同时设了 .selected() 与 .value(),第三轮行构件
     只保留了 .selected() ⇒ 文本框为空。补回 .value()(取当前选中项标签)。
  B) 功能下方简介"能去掉的去掉,能精简的精简":
     - 去掉 4 条纯重复标题语义的说明(自动连接/开机自启/网络变化重置/唤醒重置)
     - 其余说明与提示统一改短(双语锁步)
幂等:以 `SETTINGS_TYPO_V5` 标记判断。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARK = 'SETTINGS_TYPO_V5'


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

# ---------------------------------------------------- A) Select 回填 .value()
old_select = """      Select(options)
        .selected(selected < 0 ? 0 : selected)
        .width(SELECT_WIDTH)"""
new_select = """      Select(options)
        .selected(selected < 0 ? 0 : selected)
        /* SETTINGS_TYPO_V5:只设 selected 不设 value ⇒ 文本框显示为空(真机反馈),
           必须回填当前选中项标签才能显示默认值 */
        .value(selected < 0 || selected >= options.length ? '' : options[selected].value)
        .width(SELECT_WIDTH)"""
assert old_select in sp, 'rowSelect 锚点不匹配'
sp = sp.replace(old_select, new_select, 1)

# ---------------------------------------------------- B1) 去掉 4 条重复说明
pairs = [
    # (旧调用, 新调用)
    ("""            this.rowSwitch($r('app.string.settings_auto_connect'), $r('app.string.settings_auto_connect_desc'), this.s.autoConnect,""",
     """            this.rowSwitchPlain($r('app.string.settings_auto_connect'), this.s.autoConnect,"""),
    ("""            this.rowSwitch($r('app.string.settings_auto_start_boot'), $r('app.string.settings_auto_start_boot_desc'), this.s.autoStartOnBoot,""",
     """            this.rowSwitchPlain($r('app.string.settings_auto_start_boot'), this.s.autoStartOnBoot,"""),
    ("""            this.rowSwitch($r('app.string.network_change_reset_connections'), $r('app.string.network_change_reset_connections_sum'), this.s.networkChangeResetConnections,""",
     """            this.rowSwitchPlain($r('app.string.network_change_reset_connections'), this.s.networkChangeResetConnections,"""),
    ("""            this.rowSwitch($r('app.string.wake_reset_connections'), $r('app.string.wake_reset_connections_sum'), this.s.wakeResetConnections,""",
     """            this.rowSwitchPlain($r('app.string.wake_reset_connections'), this.s.wakeResetConnections,"""),
]
for old, new in pairs:
    assert old in sp, '待删说明行不匹配: %s' % old[:60]
    sp = sp.replace(old, new, 1)

# ---------------------------------------------------- B2) 说明/提示统一改短(双语)
SHORT = {
    'settings_resolve_destination_desc': ('先解析域名,让 IP 类规则可匹配', 'Resolve domains before matching IP rules'),
    'settings_fakedns_desc': ('用假 IP 加速域名分流', 'Speed up domain routing with fake IPs'),
    'settings_theme_note': ('主题选项保存为应用偏好,部分页面需重新进入后刷新',
                            'Theme options are saved; some pages refresh after re-entering'),
    'settings_test_url_desc': ('URL Test 经节点访问此网址;HTTPS 网址会额外计入 TLS 握手,数值偏高',
                               'URL Test fetches this URL through the node; HTTPS adds the TLS handshake, so it reads higher'),
    'latency_test_mode_desc': ('URL Test 全链路可用才计绿;TCPing 仅测端口握手,失效节点也可能显示绿色',
                               'URL Test counts green only when the whole chain works; TCPing only tests the port handshake'),
    'settings_global_custom_config_desc': ('与生成的配置浅合并,非法 JSON 会被忽略',
                                           'Shallow-merged into the generated config; invalid JSON is ignored'),
    'settings_server_dns_strategy_hint': ('解析代理服务器自身域名时的 IP 优先级',
                                          'IP preference when resolving the proxy server domain'),
    'settings_geo_import_hint': ('从文件导入 geoip.db / geosite.db', 'Import geoip.db / geosite.db from a file'),
}
for rel, idx in (('entry/src/main/resources/base/element/string.json', 0),
                 ('entry/src/main/resources/en_US/element/string.json', 1)):
    data = json.loads(rd(rel))
    names = {i['name']: i for i in data['string']}
    for k, (zh, en) in SHORT.items():
        assert k in names, '%s 缺少键 %s' % (rel, k)
        names[k]['value'] = zh if idx == 0 else en
    wr(rel, json.dumps(data, ensure_ascii=False, indent=2) + '\n')

sp = sp.replace('const ROW_HEIGHT: number = 48;', 'const ROW_HEIGHT: number = 48; /* SETTINGS_TYPO_V5 */', 1)
wr('entry/src/main/ets/pages/SettingsPage.ets', sp)
print('Select 回填 + 简介精简完成')
