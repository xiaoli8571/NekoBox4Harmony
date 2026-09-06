import web_webview from '@ohos.web.webview';
import common from '@ohos.app.ability.common';
import { initStore, loadSettings, LogStore } from '../model/Store';

/**
 * sing-box Dashboard(对齐 NekoBoxForAndroid WebviewFragment):
 * 内嵌 yacd 面板,经 clash_api external_ui 提供,仅 VPN 运行期间可用。
 */
@Component
export struct DashboardPage {
  @State url: string = '';
  @State clashEnabled: boolean = true;
  controller: web_webview.WebviewController = new web_webview.WebviewController();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    initStore(this.context).then(async () => {
      try {
        const s = await loadSettings();
        this.clashEnabled = s.clashApiEnabled;
        if (s.clashApiEnabled) {
          this.url = `http://127.0.0.1:${s.clashApiPort}/ui`;
        }
      } catch (e) {
        LogStore.addLog(`[ui] Dashboard 加载设置失败: ${e instanceof Error ? e.message : `${e}`}`);
      }
    });
  }

  build() {
    Column() {
      if (!this.clashEnabled) {
        Column({ space: 10 }) {
          Text($r('app.string.dashboard_disabled_title'))
            .fontSize(15).fontWeight(700).fontColor($r('app.color.text_1'))
          Text($r('app.string.dashboard_disabled_desc'))
            .fontSize(12).fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Web({ src: this.url, controller: this.controller })
          .width('100%')
          .layoutWeight(1)
          .javaScriptAccess(true)
          .domStorageAccess(true)
      }
      Text($r('app.string.dashboard_hint'))
        .fontSize(10.5).fontColor($r('app.color.text_3'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 4, bottom: 6 })
    }
    .width('100%')
    .height('100%')
  }
}
