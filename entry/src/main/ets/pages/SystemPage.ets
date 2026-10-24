import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';
import { ToolsPage } from './ToolsPage';
import { AboutPage } from './AboutPage';

/**
 * 「系统」页(2026-10-24 用户指示:工具 + 关于 合并为一个页面)。
 *
 * 两段内容用顶部 chips 切换(实用工具 / 关于),各自复用原组件整体:
 * ToolsPage/AboutPage 自带独立滚动,不嵌套双 Scroll 抢手势。
 * 抽屉里只有一个「系统」入口(legacy tab 5/6 都映射到这里,见 core/Navigation)。
 */
@Component
export struct SystemPage {
  /** 0 = 实用工具;1 = 关于 */
  @State segment: number = 0;
  onOpenDrawer: () => void = () => {};
  /** HDS 点按光效光源 key */
  @State litKey: string = '';

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('实用工具')
          .fontSize(13)
          .fontWeight(this.segment === 0 ? 700 : 400)
          .fontColor(this.segment === 0 ? $r('app.color.primary') : $r('app.color.text_secondary'))
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .height(44)
          .borderRadius(18)
          .backgroundColor(this.segment === 0 ? $r('app.color.surface') : Color.Transparent)
          .accessibilityText('实用工具')
          .onClick(() => {
            this.segment = 0;
          })
        Text('关于')
          .fontSize(13)
          .fontWeight(this.segment === 1 ? 700 : 400)
          .fontColor(this.segment === 1 ? $r('app.color.primary') : $r('app.color.text_secondary'))
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .height(44)
          .borderRadius(18)
          .backgroundColor(this.segment === 1 ? $r('app.color.surface') : Color.Transparent)
          .accessibilityText('关于')
          .onClick(() => {
            this.segment = 1;
          })
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 4, bottom: 4 })

      if (this.segment === 0) {
        ToolsPage({
          onOpenDrawer: () => {
            this.onOpenDrawer();
          }
        })
      } else {
        AboutPage({
          onOpenDrawer: () => {
            this.onOpenDrawer();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
