import web_webview from '@ohos.web.webview';
import router from '@ohos.router';
import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';

/**
 * 使用文档页(对齐安卓 nav_faq 的 launchCustomTab):
 * 应用内 Web 视图打开项目文档,无需系统浏览器。
 */
const DOC_URL = 'https://github.com/xiaoli8571/NekoBox4Harmony';

@Entry
@Component
struct DocPage {
  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  @State loading: boolean = true;
  /** HDS 点按光效:记录"当前被按下的那一个"的 key,松手/取消即清空(按下那一刻才亮) */
  @State litKey: string = '';

  aboutToAppear(): void {
    try {
      this.controller.loadUrl(DOC_URL);
    } catch (e) {
      // 加载失败时保留 loading 态,页面内展示重试入口
    }
  }

  build() {
    Column() {
      Row() {
        /* 返回:字符图标 → 系统符号(chevron_left);宿主从 Text 换成 Row
           —— 官方点光源宿主白名单里没有 Text,字符图标配了也不会亮(见 common/Effects.ets) */
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([$r('app.color.text_1')])
        }
        .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
        .visualEffect(pressLightEffect(this.litKey === 'back', false))
        .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) {
        this.litKey = 'back';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      } })
        .onClick(() => { router.back(); })
        Text($r('app.string.nav_docs'))
          .fontSize(16).fontWeight(800).fontColor($r('app.color.text_primary')).layoutWeight(1)
        if (this.loading) {
          LoadingProgress()
            .width(20).height(20)
            .color($r('app.color.primary'))
            .margin({ right: 10 })
        }
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING - 10, top: 20, bottom: 8 })

      Web({ src: DOC_URL, controller: this.controller })
        .domStorageAccess(true)
        .width('100%')
        .layoutWeight(1)
        .onPageBegin(() => { this.loading = true; })
        .onPageEnd(() => { this.loading = false; })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    /* 窗口为 layout-full-screen(内容要钻进状态栏)⇒ 本页自己让出状态栏高度 */
    .padding({ top: 44 })
  }
}
