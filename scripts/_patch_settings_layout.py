#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""设置页重排(2026-10-26 用户要求:该隐藏的隐藏、该合并的合并、看起来更整齐)。

目标结构(4 个折叠区,顺序与默认展开态):
  1) 通用   (默认展开)  自动连接 / 开机自启 / 显示底栏 / 始终显示地址
  2) 外观与交互 (默认展开) 深浅色 / 节点排序 / 触感 / 液态玻璃 / 网络变化重置 / 唤醒重置 / 流量统计
  3) 网络   (默认折叠)  路由直连 + Geo 资产 + MTU/栈/IPv6/旁路/嗅探 + DNS 全部
  4) 高级   (默认折叠)  日志/测速四项/刷新间隔/全局自定义/不安全 TLS/入站/Clash API

做法:按 sectionHeader 锚点切块 → 复用原 item 文本(不改一行控件代码)→ 按新结构拼回。
幂等:文件里已存在 `this.advancedExpanded` 则直接退出。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE = os.path.join(ROOT, 'entry/src/main/ets/pages/SettingsPage.ets')

with io.open(PAGE, encoding='utf-8') as f:
    src = f.read()

if 'this.advancedExpanded' in src:
    print('已重排过,退出(幂等)')
    sys.exit(0)

SECTION_TAIL = "\n\n          Blank().height(2)\n\n          }\n"
WRAP_OPEN = '          Column({ space: 8 }) {'
WRAP_CLOSE = "          }.alignItems(HorizontalAlign.Start).width('100%')"

ANCHORS = [
    ('general', '          // 常规(对齐 Android General 组)\n'),
    ('route', '          // 路由\n'),
    ('dns', '          // DNS(对齐 Android DNS 组)\n'),
    ('inbound', '          // 入站(对齐 Android Inbound 组)\n'),
    ('appearance', '          // 外观与交互\n'),
    ('api', '          // Clash API 连接统计\n'),
]

region_start = src.index(ANCHORS[0][1])
region_end = src.index("\n\n        }\n        .width('100%')\n        .padding({ left: UiSpec.PAGE_PADDING")
region = src[region_start:region_end]

positions = []
for key, anchor in ANCHORS:
    idx = region.find(anchor)
    assert idx >= 0, '锚点缺失: %s' % key
    positions.append((key, idx))
positions.sort(key=lambda x: x[1])

chunks = {}
for i, (key, idx) in enumerate(positions):
    end = positions[i + 1][1] if i + 1 < len(positions) else len(region)
    chunks[key] = region[idx:end]

INFO = {}
for key, chunk in chunks.items():
    m = re.search(r'(?m)^          this\.sectionHeader\((.+)\)$', chunk)
    assert m, 'sectionHeader 缺失: %s' % key
    header_args = m.group(1)
    if_m = re.search(r'(?m)^          if \(this\.[A-Za-z]+\) \{$', chunk[m.end():])
    assert if_m, 'if 展开判断缺失: %s' % key
    body_start = m.end() + if_m.end() + 1
    tail_idx = chunk.rindex(SECTION_TAIL)
    body = chunk[body_start:tail_idx]
    if WRAP_OPEN in body:
        oi = body.index(WRAP_OPEN) + len(WRAP_OPEN)
        ci = body.rindex(WRAP_CLOSE)
        inner = body[oi:ci]
    else:
        # 路由区没有外层 Column:item 直接在 10 空格缩进,补两格对齐新包装
        inner = '\n'.join(('  ' + l if l.strip() else l) for l in body.split('\n'))
    # 去掉首尾空白行,统一留一个换行
    inner = inner.strip('\n')
    INFO[key] = {'header': header_args, 'body': inner}


def items_of(body):
    starts = [m.start() for m in re.finditer(r'(?m)^            (?=(?:Row|Column)\(|/\*)', body)]
    out = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else len(body)
        text = body[s:e].rstrip('\n')
        m = re.search(r'app\.string\.([a-z0-9_]+)', text)
        out.append((m.group(1) if m else '?', text))
    return out


general_items = items_of(INFO['general']['body'])
print('通用区原有 items:', [t for t, _ in general_items])
by_token = {}
for token, text in general_items:
    by_token.setdefault(token, text)

COMMON = ['settings_auto_connect', 'settings_auto_start_boot', 'settings_always_show_address', 'show_bottom_bar']
EXPERT = ['settings_log_level', 'latency_test_mode', 'settings_test_url', 'settings_test_concurrent',
          'settings_speed_interval', 'settings_global_custom_config', 'settings_insecure_tls',
          'settings_sub_allow_insecure']
for t in COMMON + EXPERT:
    assert t in by_token, '通用区找不到 item: %s' % t
print('保留常用:', COMMON)
print('移入高级:', EXPERT)


def join_items(tokens):
    return '\n'.join(by_token[t] for t in tokens)


def section(comment, header_args, expanded_name, body):
    return (
        '          %s\n'
        '          this.sectionHeader(%s)\n'
        '          if (this.%s) {\n'
        '          Column({ space: 8 }) {\n'
        '%s\n'
        "          }.alignItems(HorizontalAlign.Start).width('100%%')\n"
        '\n'
        '          Blank().height(2)\n'
        '\n'
        '          }\n'
        '\n'
    ) % (comment, header_args, expanded_name, body.rstrip('\n'))


def with_id(header_args, new_id):
    head, _, _ = header_args.rpartition(", '")
    return head + ", '" + new_id + "'"


GENERAL_HEADER = with_id(INFO['general']['header'], '')
APPEARANCE_HEADER = with_id(INFO['appearance']['header'], 'appearance')
NETWORK_HEADER = with_id(INFO['route']['header'], 'mode')
ADVANCED_HEADER = ("$r('sys.symbol.line_3_horizontal'), $r('app.string.settings_advanced'), "
                   "this.advancedExpanded, () => { this.advancedExpanded = !this.advancedExpanded; }, 'advanced'")

network_body = INFO['route']['body'].rstrip('\n') + '\n\n' + INFO['dns']['body'].rstrip('\n')
advanced_body = (join_items(EXPERT) + '\n'
                 + INFO['inbound']['body'].rstrip('\n') + '\n'
                 + INFO['api']['body'].rstrip('\n'))

new_region = (
    section('// 通用(只留在手机上手调有意义的项;专家项收进「高级」)',
            GENERAL_HEADER, 'generalExpanded', join_items(COMMON))
    + section('// 外观与交互', APPEARANCE_HEADER, 'appearanceExpanded', INFO['appearance']['body'])
    + section('// 网络(含 DNS:两块本来就是一个问题的两面)', NETWORK_HEADER, 'networkExpanded', network_body)
    + section('// 高级(默认收起:日志/测速参数/自定义配置/不安全开关/入站/Clash API)',
              ADVANCED_HEADER, 'advancedExpanded', advanced_body)
)

src = src[:region_start] + new_region + src[region_end:]

src = src.replace("""  @State generalExpanded: boolean = false;
  @State networkExpanded: boolean = false;
  @State dnsExpanded: boolean = false;
  @State inboundExpanded: boolean = false;
  @State appearanceExpanded: boolean = false;
  @State apiExpanded: boolean = false;""",
"""  /* 2026-10-26 设置页重排:常用两区默认展开,网络/高级默认收起(用户要求"整洁、别一屏都是开关") */
  @State generalExpanded: boolean = true;
  @State appearanceExpanded: boolean = true;
  @State networkExpanded: boolean = false;
  @State advancedExpanded: boolean = false;""", 1)
assert 'advancedExpanded: boolean = false' in src, '状态变量替换失败'

src = src.replace("""  private jumpToSchemaSection(sectionId: string): void {
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
  }""",
"""  private jumpToSchemaSection(sectionId: string): void {
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
  }""", 1)
assert '只有四个折叠区' in src, '跳转映射替换失败'

with io.open(PAGE, 'w', encoding='utf-8', newline='\n') as f:
    f.write(src)
print('设置页重排完成')
