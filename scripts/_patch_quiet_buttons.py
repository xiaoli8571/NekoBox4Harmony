#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
2026-10-30 用户要求:常亮蓝底按钮改成「默认不明显,按下才变蓝」。

规则:
  默认态:背景 = surface(与卡片同色,不突出),文字 = primary(或 error)
  按下态:背景 = primary(或 error),文字 = surface

实现用既有的按下态状态机 `litKey`(全应用统一模式),不引入新的状态库:
  .backgroundColor(this.litKey === 'K' ? $r('app.color.primary') : $r('app.color.surface'))
  .fontColor(this.litKey === 'K' ? $r('app.color.surface') : $r('app.color.primary'))
没有现成 key 的按钮,自动补一个 `.onTouch` 按下/抬起切换 litKey。

幂等:已经改成条件表达式的按钮直接跳过。
"""
import glob
import io
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
MARK = 'this.litKey === '

SKIP_FILES = {
    os.path.join('entry', 'src', 'main', 'ets', 'common', 'components', 'FlowMenu.ets'),
}

ONTOUCH_TPL = """{ind}.onTouch((event: TouchEvent) => {{
{ind}  if (event.type === TouchType.Down) {{
{ind}    this.litKey = '{key}';
{ind}  }} else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {{
{ind}    this.litKey = '';
{ind}  }}
{ind}}})
"""


def chain_bounds(lines, idx):
    """返回 (start, end):包含 idx 行的 Button 链的首行与末行下标(含)。"""
    start = idx
    while start > 0:
        s = lines[start].lstrip()
        if s.startswith('Button(') or s.startswith('Button(('):
            break
        start -= 1
    end = idx
    while end + 1 < len(lines):
        nxt = lines[end + 1].lstrip()
        if nxt.startswith('.'):
            end += 1
            # onClick(...) / onTouch(...) 常常跨多行,继续把闭合部分吃进来
            if nxt.startswith('.onClick(') or nxt.startswith('.onTouch('):
                depth = lines[end].count('{') - lines[end].count('}')
                while depth > 0 and end + 1 < len(lines):
                    end += 1
                    depth += lines[end].count('{') - lines[end].count('}')
                break
        else:
            break
    return start, end


def find_key(lines, start, idx):
    # pressLightEffect 可能写在 backgroundColor 之后(链式顺序不固定)⇒ 前后都看
    lo = max(0, start - 80)
    hi = min(len(lines) - 1, idx + 80)
    for j in range(hi, lo - 1, -1):
        m = re.search(r"pressLightEffect\(this\.litKey === '([^']+)'", lines[j])
        if m:
            return m.group(1)
    return None


def has_onclick(lines, start, end):
    # 链里可能先有 onTouch 再有 onClick ⇒ 向后多扫一段
    for j in range(end, min(len(lines), end + 80)):
        if lines[j].lstrip().startswith('.onClick('):
            return j
    return -1


def patch_file(path, report):
    with io.open(path, encoding='utf-8') as f:
        src = f.read()
    lines = src.split('\n')
    changed = False
    i = 0
    counter = 0
    base = os.path.basename(path).replace('.ets', '')
    while i < len(lines):
        line = lines[i]
        m_bg = re.search(r"^(\s*)\.backgroundColor\(\$r\('app\.color\.(primary|error)'\)\)\s*$", line)
        if not m_bg:
            i += 1
            continue
        indent = m_bg.group(1)
        color = m_bg.group(2)
        start, end = chain_bounds(lines, i)
        if start == i:
            # 不是 Button 链(可能是 Column/Row 卡片底色),跳过
            i += 1
            continue
        key = find_key(lines, start, i)
        counter += 1
        if key is None:
            key = 'pb:%s:%d' % (base, counter)
            oc = has_onclick(lines, start, end)
            if oc < 0:
                report.append('%s:%d 无 onClick,跳过(需人工)' % (path, i + 1))
                i += 1
                continue
            lines.insert(oc, ONTOUCH_TPL.format(ind=indent, key=key).rstrip('\n'))
            end += 1
        # 背景:按下才上色
        lines[i] = "%s.backgroundColor(this.litKey === '%s' ? $r('app.color.%s') : $r('app.color.surface'))" % (
            indent, key, color)
        # 文字:默认用主色/危险色,按下反白
        for j in range(i + 1, min(end + 1, len(lines))):
            if lines[j].strip() == ".fontColor($r('app.color.surface'))":
                lines[j] = "%s.fontColor(this.litKey === '%s' ? $r('app.color.surface') : $r('app.color.%s'))" % (
                    indent, key, color)
                break
        changed = True
        i = end + 1
    if changed:
        out = '\n'.join(lines)
        if 'litKey: string' not in out:
            out = re.sub(r'(@Component\s*\n(?:export )?struct \w+ \{\n)',
                         r"\1  @State litKey: string = '';\n", out, count=1)
        with io.open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(out)
    return changed


def main():
    report = []
    touched = []
    for path in sorted(glob.glob(os.path.join(ROOT, 'entry', 'src', 'main', 'ets', '**', '*.ets'), recursive=True)):
        rel = os.path.relpath(path, ROOT)
        if rel in SKIP_FILES:
            continue
        if patch_file(path, report):
            touched.append(rel)
    for t in touched:
        print('patched', t)
    for r in report:
        print('NOTE', r)
    if not touched:
        print('nothing to patch')


if __name__ == '__main__':
    main()
