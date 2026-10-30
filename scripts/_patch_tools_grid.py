#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
工具页排版整理(2026-10-30 用户要求「一行可以放 2-3 个功能按钮,现在一行一个特别乱」)。

改动:
  1. 六个「整行大卡片」入口 → 两列磁贴(图标 + 标题 + 一行说明),空间省一半以上;
  2. 诊断包 / 恢复出厂 两张整行卡片 → 一行两列;
  3. 备份与恢复、STUN 保留整行(有输入框/四个按钮,压窄会难用)。

幂等 + fail-closed:锚点找不到或内容已被替换过就直接退出,不猜。
"""
import io
import os
import sys

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                    'entry', 'src', 'main', 'ets', 'pages', 'ToolsPage.ets')

MARK_NEW = '// ---- 功能入口:两列磁贴'

TILE_BUILDER = '''  /**
   * 功能入口磁贴(两列):图标 + 标题 + 一行说明。
   * 2026-10-30 用户反馈「一行一个功能显示特别乱」——六个入口原来各占一张整行卡片,
   * 手机上要滚半天;改两列后同一屏就能看全。
   */
  @Builder
  toolTile(symbol: Resource, title: ResourceStr, desc: ResourceStr, url: string, key: string) {
    Column({ space: 5 }) {
      SymbolGlyph(symbol)
        .fontSize(20)
        .fontColor([$r('app.color.primary')])
      Text(title)
        .fontSize(13).fontWeight(700).fontColor($r('app.color.text_1'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(desc)
        .fontSize(10.5).fontColor($r('app.color.text_2')).lineHeight(14)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('48.4%')
    .height(92)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .padding(12)
    .borderRadius(14)
    .backgroundColor($r('app.color.surface'))
    .margin({ bottom: 12 })
    .visualEffect(pressLightEffect(this.litKey === key, true))
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.litKey = key;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
    })
    .onClick(() => {
      void router.pushUrl({ url: url });
    })
  }

  build() {'''

GRID = '''          // ---- 功能入口:两列磁贴(一屏看全,不再一行一个) ----
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
            this.toolTile($r('sys.symbol.checkmark'), $r('app.string.tools_diag_title'),
              $r('app.string.tools_diag_desc'), 'pages/DiagnosticsPage', 'tile:diag')
            this.toolTile($r('sys.symbol.bolt'), $r('app.string.tools_traffic_title'),
              $r('app.string.tools_traffic_desc'), 'pages/TrafficPage', 'tile:traffic')
            this.toolTile($r('sys.symbol.cloud'), $r('app.string.tools_webui_title'),
              $r('app.string.tools_webui_desc'), 'pages/WebUiPage', 'tile:webui')
            this.toolTile($r('sys.symbol.arrow_up_left_and_arrow_down_right'), $r('app.string.lan_title'),
              $r('app.string.tools_lan_desc'), 'pages/LanSharingPage', 'tile:lan')
            this.toolTile($r('sys.symbol.doc_text'), $r('app.string.cfg_edit_title'),
              $r('app.string.tools_cfg_edit_desc'), 'pages/ConfigEditPage', 'tile:cfg')
            this.toolTile($r('sys.symbol.list_square'), $r('app.string.messages_title'),
              $r('app.string.tools_messages_desc'), 'pages/MessagesPage', 'tile:msg')
          }
          .width('100%')
'''

MAINT = '''          // ---- 维护:诊断包 / 恢复出厂(一行两列;危险操作仍要两次确认) ----
          Row({ space: 12 }) {
            Column({ space: 8 }) {
              Text('诊断包')
                .fontSize(13).fontWeight(700).fontColor($r('app.color.text_1'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('版本/内核能力/修订号 + 脱敏日志,不会自动上传')
                .fontSize(10.5).fontColor($r('app.color.text_2')).lineHeight(14)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              Button('生成')
                .height(34).fontSize(12.5)
                .backgroundColor($r('app.color.primary'))
                .fontColor($r('app.color.surface'))
                .visualEffect(pressLightEffect(this.litKey === 'tools:diag', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.litKey = 'tools:diag';
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.litKey = '';
                  }
                })
                .onClick(() => {
                  void this.generateDiagnostics();
                })
            }
            .layoutWeight(1)
            .height(132)
            .alignItems(HorizontalAlign.Start)
            .padding(12)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface'))

            Column({ space: 8 }) {
              Text($r('app.string.reset_title'))
                .fontSize(13).fontWeight(700).fontColor($r('app.color.text_1'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text($r('app.string.reset_desc'))
                .fontSize(10.5).fontColor($r('app.color.text_2')).lineHeight(14)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              Button($r('app.string.reset_action'))
                .height(34).fontSize(12.5)
                .backgroundColor($r('app.color.error'))
                .fontColor($r('app.color.surface'))
                .visualEffect(pressLightEffect(this.litKey === 'tools:reset', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
                    this.litKey = 'tools:reset';
                  } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
                    this.litKey = '';
                  }
                })
                .onClick(() => this.requestReset())
            }
            .layoutWeight(1)
            .height(132)
            .alignItems(HorizontalAlign.Start)
            .padding(12)
            .borderRadius(14)
            .backgroundColor($r('app.color.surface'))
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
'''


def fail(msg: str) -> None:
    sys.stderr.write('FAIL: %s\n' % msg)
    sys.exit(1)


def main() -> None:
    with io.open(PATH, encoding='utf-8') as f:
        src = f.read()

    if MARK_NEW in src:
        print('already patched, nothing to do')
        return

    # ---- 1) 六张整行卡片 → 两列磁贴 ----
    start = src.find('          // 服务可用性诊断(对齐 OwnBox:13 项服务 + 落地 IP)\n')
    if start < 0:
        fail('grid anchor (start) not found')
    end = src.find('          // NAT 行为发现(STUN)\n', start)
    if end < 0:
        fail('grid anchor (end) not found')
    src = src[:start] + GRID + '\n' + src[end:]

    # ---- 2) 诊断包 + 恢复出厂 → 一行两列 ----
    m_start = src.find('          // W20:诊断包(版本/内核能力/revision/错误类别/脱敏日志;不自动上传)\n')
    if m_start < 0:
        fail('maintenance anchor (start) not found')
    tail_anchor = "        }\n        .width('100%')\n        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 8, bottom: 20 })"
    m_end = src.find(tail_anchor, m_start)
    if m_end < 0:
        fail('maintenance anchor (end) not found')
    src = src[:m_start] + MAINT + src[m_end:]

    # ---- 3) 插入 toolTile 构建器 ----
    if '\n  build() {' not in src:
        fail('build() anchor not found')
    src = src.replace('\n  build() {', '\n' + TILE_BUILDER, 1)

    with io.open(PATH, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched ToolsPage.ets: 2-column tiles + maintenance row')


if __name__ == '__main__':
    main()
