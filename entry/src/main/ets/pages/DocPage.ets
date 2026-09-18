import web_webview from '@ohos.web.webview';
import router from '@ohos.router';
import { UiSpec } from '../common/UiSpec';

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
        Text('←')
          .fontSize(20).fontColor($r('app.color.text_primary')).width(36).height(36).textAlign(TextAlign.Center)
          .onClick(() => router.back())
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
  }
}
