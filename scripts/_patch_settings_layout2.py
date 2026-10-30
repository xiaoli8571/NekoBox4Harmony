#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""设置页视觉二轮(2026-10-26 用户要求):
  1) 四个分区默认全部展开
  2) 分区内功能排序重排(外观区:主题 → 视觉 → 交互 → 诊断)
  3) 分区标题字体放大加粗(12/700 → 16/800,颜色 text_3 → text_1)
  4) 分区之间明显间隔(分区尾部 Blank 2 → 18),标题上下留白加大
幂等:以 `SETTINGS_HEADER_TYPO_V2` 标记是否存在判断。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE = os.path.join(ROOT, 'entry/src/main/ets/pages/SettingsPage.ets')
with io.open(PAGE, encoding='utf-8') as f:
    src = f.read()

if 'SETTINGS_HEADER_TYPO_V2' in src:
    print('已应用过,退出(幂等)')
    sys.exit(0)


def brace_end(text, start):
    """从 text[start] 的 '{' 起配平,返回匹配 '}' 之后的位置(跳过字符串/注释)。"""
    i, n, depth, begun = start, len(text), 0, False
    while i < n:
        c = text[i]
        if c == '/' and text[i + 1:i + 2] == '/':
            j = text.find('\n', i)
            i = n if j < 0 else j + 1
            continue
        if c == '/' and text[i + 1:i + 2] == '*':
            j = text.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        if c in '\'"`':
            q = c
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == q:
                    i += 1
                    break
                i += 1
            continue
        if c == '{':
            depth += 1
            begun = True
        elif c == '}':
            depth -= 1
            if begun and depth == 0:
                return i + 1
        i += 1
    raise ValueError('括号不配平 @%d' % start)


# ---------- 1) 默认全部展开 ----------
old_states = """  /* 2026-10-26 设置页重排:常用两区默认展开,网络/高级默认收起(用户要求"整洁、别一屏都是开关") */
  @State generalExpanded: boolean = true;
  @State appearanceExpanded: boolean = true;
  @State networkExpanded: boolean = false;
  @State advancedExpanded: boolean = false;"""
new_states = """  /* SETTINGS_HEADER_TYPO_V2 2026-10-26:用户要求默认全部展开(折叠只作为"收起长页面"的手段) */
  @State generalExpanded: boolean = true;
  @State appearanceExpanded: boolean = true;
  @State networkExpanded: boolean = true;
  @State advancedExpanded: boolean = true;"""
assert old_states in src, '展开状态变量锚点不匹配'
src = src.replace(old_states, new_states, 1)

# ---------- 3) 分区标题放大加粗 ----------
old_head = """        SymbolGlyph(icon)
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
      .padding({ top: 14, bottom: 6 })"""
new_head = """        /* SETTINGS_HEADER_TYPO_V2:分类名是页面骨架,12/700 太弱看不清 ⇒ 16/800 + 主文字色 */
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
      .padding({ top: 20, bottom: 12 })"""
assert old_head in src, 'sectionHeader 样式锚点不匹配'
src = src.replace(old_head, new_head, 1)

old_restore = """          .fontSize(11)
          .fontColor($r('app.color.primary'))
          .padding({ top: 14, bottom: 6, left: 4, right: 2 })"""
new_restore = """          .fontSize(12)
          .fontWeight(500)
          .fontColor($r('app.color.primary'))
          .padding({ top: 20, bottom: 12, left: 4, right: 2 })"""
assert old_restore in src, '恢复默认按钮锚点不匹配'
src = src.replace(old_restore, new_restore, 1)

# ---------- 4) 分区之间明显间隔 ----------
region_start = src.index('          // 通用(只留在手机上手调有意义的项')
region_end = src.index("\n\n        }\n        .width('100%')\n        .padding({ left: UiSpec.PAGE_PADDING")
region = src[region_start:region_end]
# 只改分区尾部那 4 个(路由区内部还有一个分组用 Blank(2),保持原样)
TAIL_OLD = "\n\n          Blank().height(2)\n\n          }\n"
TAIL_NEW = "\n\n          Blank().height(18)\n\n          }\n"
gaps = region.count(TAIL_OLD)
assert gaps == 4, '分区尾部间隔数量异常: %d' % gaps
region = region.replace(TAIL_OLD, TAIL_NEW)
src = src[:region_start] + region + src[region_end:]

# ---------- 2) 外观与交互内部排序 ----------
ap_start = src.index('          // 外观与交互')
ap_end = src.index('          // 网络(含 DNS')
ap = src[ap_start:ap_end]

starts = [m.start() for m in re.finditer(r'(?m)^            (?=(?:Row|Column)\(|/\*)', ap)]
assert starts, '外观区没有解析到 item'
items = []
for i, s in enumerate(starts):
    e = starts[i + 1] if i + 1 < len(starts) else len(ap)
    seg = ap[s:e]
    # 块起始 = 首行最后一个 '{'(首行还有 Row({ space: 8 }) 这种对象字面量)
    core_end = brace_end(seg, seg.rindex('{', 0, seg.index('\n')))
    token = re.search(r'app\.string\.([a-z0-9_]+)', seg).group(1)
    items.append((token, s, s + core_end))

ORDER = ['appearance_follow_system', 'liquid_glass', 'haptic_feedback', 'sort_manual',
         'network_change_reset_connections', 'wake_reset_connections', 'profile_traffic_statistics']
by_token = {token: ap[s:e] for token, s, e in items}
assert sorted(by_token) == sorted(ORDER), '外观区 item 集合变化: %s' % sorted(by_token)

head = ap[:starts[0]]
foot = ap[items[-1][2]:]
new_ap = head + '\n'.join(by_token[t].rstrip('\n') for t in ORDER) + '\n' + foot.lstrip('\n')
assert 'appearance_follow_system' in new_ap and 'profile_traffic_statistics' in new_ap
src = src[:ap_start] + new_ap + src[ap_end:]

with io.open(PAGE, 'w', encoding='utf-8', newline='\n') as f:
    f.write(src)
print('设置页视觉二轮完成')
