#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""下线四项功能(2026-10-26 用户决定,对比 OwnBox 后精简):
  1) 主题强调色自定义 → 固定主色(与 OwnBox 一致,只跟随深浅色)
  2) 首页区块编排 → 区块恒定全显示
  3) 连接列表页 → 删除页面与入口(yacd 面板已有连接列表)
  4) 订阅更新反馈对话框 → 改为一条 toast(明细进消息中心)

幂等:重复执行不改动已改过的文件;所有替换 fail-closed(找不到锚点即抛错)。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(p):
    with io.open(os.path.join(ROOT, p), encoding='utf-8') as f:
        return f.read()


def write(p, s):
    with io.open(os.path.join(ROOT, p), 'w', encoding='utf-8', newline='\n') as f:
        f.write(s)


def drop(p, block, marker, label):
    """删除 block;marker 已存在于文件则跳过(幂等)。"""
    s = read(p)
    if marker in s:
        print('  skip(已处理) %s <- %s' % (label, p))
        return
    assert block in s, '锚点缺失: %s / %s' % (p, label)
    write(p, s.replace(block, '', 1))
    print('  ok %s <- %s' % (label, p))


def sub(p, old, new, label):
    s = read(p)
    if new in s and old not in s:
        print('  skip(已处理) %s <- %s' % (label, p))
        return
    assert old in s, '锚点缺失: %s / %s' % (p, label)
    write(p, s.replace(old, new, 1))
    print('  ok %s <- %s' % (label, p))


# ---------------------------------------------------------------- 1) 主题强调色
print('[1] 主题强调色 → 固定主色')
sub(
    'entry/src/main/ets/common/Theme.ets',
    """export function publishAccent(name: string): void {
  AppStorage.setOrCreate('themeAccent', normalizeAccent(name));
  AppStorage.setOrCreate('themeAccentHex', accentHexFor(name));
}""",
    """export function publishAccent(name: string): void {
  /* 2026-10-26 用户决定下线强调色自定义:与 OwnBox 一致,主色固定并只随深浅色变化。
     旧设置/旧备份里的 purple|orange|red 等值一律收敛到默认蓝,避免"没有入口却还在生效"。 */
  const fixed: string = ThemeAccents.BLUE;
  AppStorage.setOrCreate('themeAccent', normalizeAccent(fixed));
  AppStorage.setOrCreate('themeAccentHex', accentHexFor(fixed));
}""",
    'publishAccent 固定主色')

sub(
    'entry/src/main/ets/pages/SettingsPage.ets',
    "import { ThemeAccents, accentHexFor, publishAccent } from '../common/Theme';",
    "import { publishAccent } from '../common/Theme';",
    'SettingsPage import 收窄')

drop(
    'entry/src/main/ets/pages/SettingsPage.ets',
    """            /* 主题强调色(对齐 OwnBox ColorPickerPreference 预设色板):纯前端,保存后立即生效 */
            Text($r('app.string.settings_theme_accent')).fontSize(13)
              .fontColor($r('app.color.text_secondary')).width('100%')
            Row({ space: 12 }) {
              ForEach(ThemeAccents.OPTIONS, (name: string) => {
                Circle({ width: 28, height: 28 })
                  .fill(accentHexFor(name))
                  .stroke(this.s.themeAccent === name ? $r('app.color.text_1') : Color.Transparent)
                  .strokeWidth(2)
                  .onClick(() => {
                    this.s.themeAccent = name;
                    publishAccent(name);
                    this.markDirty();
                  })
              }, (name: string) => name)
            }.width('100%')
""",
    '// 强调色自定义已下线',
    '强调色选择器 UI')

# ---------------------------------------------------------------- 2) 首页区块编排
print('[2] 首页区块编排 → 恒定显示')
drop(
    'entry/src/main/ets/pages/SettingsPage.ets',
    """            /* 首页区块编排(对齐 OwnBox DashboardManager):关掉的区块主页不再渲染 */
            Text($r('app.string.settings_home_sections')).fontSize(13)
              .fontColor($r('app.color.text_secondary')).width('100%')
            Row() {
              Text($r('app.string.home_sec_groups')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.homeSectionOn('groups') })
                .onChange((v: boolean) => { this.toggleHomeSection('groups', v); })
            }.width('100%')
            Row() {
              Text($r('app.string.home_sec_nodes')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.homeSectionOn('nodes') })
                .onChange((v: boolean) => { this.toggleHomeSection('nodes', v); })
            }.width('100%')
            Row() {
              Text($r('app.string.home_sec_bottombar')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.homeSectionOn('bottombar') })
                .onChange((v: boolean) => { this.toggleHomeSection('bottombar', v); })
            }.width('100%')
""",
    '// 首页区块编排已下线',
    '首页区块开关 UI')

drop(
    'entry/src/main/ets/pages/SettingsPage.ets',
    """  /** 首页区块开关(homeHiddenSections = 逗号分隔的「隐藏」列表) */
  private homeSectionOn(id: string): boolean {
    return this.s.homeHiddenSections.split(',').indexOf(id) < 0;
  }

  private toggleHomeSection(id: string, on: boolean): void {
    const kept = this.s.homeHiddenSections.split(',')
      .filter((x: string): boolean => x.length > 0 && x !== id);
    if (!on) {
      kept.push(id);
    }
    this.s.homeHiddenSections = kept.join(',');
    this.markDirty();
  }

""",
    '// 区块编排 helper 已下线',
    'homeSection 助手方法')

sub(
    'entry/src/main/ets/pages/Index.ets',
    """  private sectionVisible(id: string): boolean {
    return this.settings.homeHiddenSections.split(',').indexOf(id) < 0;
  }""",
    """  private sectionVisible(id: string): boolean {
    /* 2026-10-26 首页区块编排已下线:区块恒定全显示(设置项不再暴露)。
       旧设置里的 homeHiddenSections 从此不生效,但仍随备份往返以兼容。 */
    return true;
  }""",
    'Index sectionVisible 恒定 true')

# ---------------------------------------------------------------- 3) 连接列表页
print('[3] 删除连接列表页')
idx = 'entry/src/main/ets/pages/Index.ets'
sub(
    idx,
    """  private openConnectionDetails(): void {
    router.pushUrl({ url: 'pages/ConnectionsPage' });
  }

""",
    '// 连接列表页已下线',
    'openConnectionDetails')
sub(
    idx,
    """      } else if (value === 'connections') {
        router.pushUrl({ url: 'pages/ConnectionsPage' });
""",
    '',
    '⋮ 菜单 connections 分支')
sub(
    idx,
    """    add($r('app.string.topbar_connections'), 'connections', false);
""",
    '',
    '⋮ 菜单 connections 条目')

sub(
    'entry/src/main/resources/base/profile/main_pages.json',
    '    "pages/ConnectionsPage",\n',
    '',
    'main_pages 注册')

conn_page = os.path.join(ROOT, 'entry/src/main/ets/pages/ConnectionsPage.ets')
if os.path.exists(conn_page):
    os.remove(conn_page)
    print('  rm entry/src/main/ets/pages/ConnectionsPage.ets')

# ---------------------------------------------------------------- 4) 订阅更新反馈
print('[4] 订阅更新反馈对话框 → toast')
DIFF_TAIL = """    setTimeout(() => {
      this.subDiffDialog = new CustomDialogController({
        builder: SubDiffDialog({ groupName: name, res: res }),
        autoCancel: true
      });
      this.subDiffDialog.open();
    }, 1000);
"""
DIFF_NOTE = """    /* 2026-10-26 明细对话框已下线:变化数量用这一条 toast 概述,逐项明细看消息中心。 */
"""
for p in ['entry/src/main/ets/pages/Index.ets',
          'entry/src/main/ets/pages/GroupPage.ets',
          'entry/src/main/ets/pages/SubDetailPage.ets']:
    sub(p, DIFF_TAIL, DIFF_NOTE, '去掉 Diff 对话框弹出')
    s = read(p)
    for decl in [
        """  /** Diff 对话框控制器(每次按当次结果新建,见 showSubUpdateFeedback) */
  private subDiffDialog: CustomDialogController | undefined = undefined;

""",
        """  /** Diff 对话框控制器(每次按当次结果新建) */
  private subDiffDialog: CustomDialogController | undefined = undefined;

""",
    ]:
        if decl in s:
            s = s.replace(decl, '', 1)
    if "import { SubDiffDialog } from './SubUpdateFeedback';\n" in s:
        s = s.replace("import { SubDiffDialog } from './SubUpdateFeedback';\n", '', 1)
    write(p, s)
    print('  ok 清理控制器/import <- %s' % p)

fb = os.path.join(ROOT, 'entry/src/main/ets/pages/SubUpdateFeedback.ets')
if os.path.exists(fb):
    os.remove(fb)
    print('  rm entry/src/main/ets/pages/SubUpdateFeedback.ets')

# ---------------------------------------------------------------- 5) 静态守卫测试同步
print('[5] 同步 p6-ui-static 守卫')
tp = 'tests/p6-ui-static.cjs'
sub(tp, "    'entry/src/main/ets/pages/ConnectionsPage.ets',\n", '', 'files 列表去 ConnectionsPage')
sub(tp, """  const conn = read('entry/src/main/ets/pages/ConnectionsPage.ets');
  assert.ok(/formatBytes\\(c\\.up\\)[\\s\\S]{0,200}monospace/.test(conn), '连接行速率/字节需等宽');
  assert.ok(/traffic_speed_total[\\s\\S]{0,300}monospace/.test(conn), '连接页汇总速率需等宽');
""", '', '等宽检查去连接页')
sub(tp, """  // P6 复审修过的回归点:startTimeText 的返回值进模板串拼接,必须声明 string
  // (Resource 进模板串会渲染成 [object Object],§24.2-6)
  const conn = read('entry/src/main/ets/pages/ConnectionsPage.ets');
  assert.ok(/private startTimeText\\(item: ClashConnItem\\): string/.test(conn),
    'ConnectionsPage.startTimeText 必须返回 string(其值进模板串)');
""", '', 'startTimeText 检查去连接页')

print('\nALL DONE')
