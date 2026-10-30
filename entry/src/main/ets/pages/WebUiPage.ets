import web_webview from '@ohos.web.webview';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { statusBarTopVp } from '../common/PageTopInset';
import { pressLightEffect } from '../common/Effects';
import { initStore, loadSettings } from '../model/Store';
import { AppSettings } from '../model/Profile';

/**
 * Web 面板页(对齐 OwnBox 的 DashboardManager / LocalYacdDashboard):
 * 内核 clash_api 自带静态资源服务,面板就是浏览器里的 yacd。
 * 这里用应用内 WebView 打开 127.0.0.1:<clashApiPort>/ui,免去外部浏览器。
 *
 * 前置条件:设置里「Clash API」开启且 VPN 正在运行,否则面板 404 —— 页面自己给提示,
 * 不让用户对着一片白屏猜。
 */
@Entry
@Component
struct WebUiPage {
  @State topPadVp: number = 44;
  @State loading: boolean = true;
  @State ready: boolean = false;
  @State hint: string = '';
  @State url: string = '';
  @State litKey: string = '';
  /** 'light' | 'dark' —— yacd 自己主题要跟着应用走,否则浅色主题下面板仍是深色 */
  @State themeMode: string = 'light';
  private themeReloaded: boolean = false;
  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private resolveTheme(settings: AppSettings | null): string {
    const pref: string = settings !== null ? settings.appearance : 'system';
    if (pref === 'dark' || pref === 'light') {
      return pref;
    }
    try {
      return this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 'dark' : 'light';
    } catch (e) {
      return 'light';
    }
  }

  /**
   * yacd 把主题存在 localStorage['yacd.metacubex.one'] 的 {app:{theme}} 里,
   * 并把结果写成 <html data-theme>。两处都写:yacd 启动时读 storage,启动后
   * 若 React 重渲染会按 storage 重新盖 data-theme。
   */
  private themeInjectScript(): string {
    const mode: string = this.themeMode;
    return `(function(){try{var k='yacd.metacubex.one';var s={};`
      + `try{s=JSON.parse(localStorage.getItem(k)||'{}')||{}}catch(e){s={};}`
      + `if(!s.app){s.app={};}s.app.theme='${mode}';`
      + `localStorage.setItem(k,JSON.stringify(s));`
      + `document.documentElement.setAttribute('data-theme','${mode}');}catch(e){}})();`;
  }

  /** 页面加载完成后校正一次;只有「实际主题不对」时才重载一次(避免每次都刷两遍) */
  private applyThemeAfterLoad(): void {
    if (!this.ready) {
      return;
    }
    const mode: string = this.themeMode;
    try {
      this.controller.runJavaScript(this.themeInjectScript());
      this.controller.runJavaScript(`document.documentElement.getAttribute('data-theme')||''`)
        .then((value: string) => {
          const cur: string = value === undefined || value === null ? '' : value.replace(/["]/g, '').trim();
          if (cur !== mode && !this.themeReloaded) {
            /* 注入晚于 yacd 启动:storage 现在已是目标值,重载一次即可收敛 */
            this.themeReloaded = true;
            try {
              this.controller.refresh();
            } catch (e) {
              // 刷新失败保留当前页
            }
          }
        });
    } catch (e) {
      // Web 未就绪时忽略(下次 onPageEnd 再来)
    }
  }

  private async bootstrap(): Promise<void> {
    this.topPadVp = await statusBarTopVp(this.context, 44);
    await initStore(this.context);
    let settings: AppSettings | null = null;
    try {
      settings = await loadSettings();
    } catch (e) {
      settings = null;
    }
    const running: boolean = AppStorage.get<boolean>('vpnRunning') === true;
    if (settings === null || !settings.clashApiEnabled) {
      this.hint = 'Clash API 未开启:请到 设置 → 高级 打开「Clash API」后再回来';
      return;
    }
    if (!running) {
      this.hint = 'VPN 未运行:面板由内核提供,请先连接再打开';
      return;
    }
    const port: number = settings.clashApiPort;
    const secret: string = settings.clashApiSecret;
    /* 浅色/深色跟随应用设置(用户反馈:浅色主题下面板还是深色) */
    this.themeMode = this.resolveTheme(settings);
    this.themeReloaded = false;
    /* yacd 支持从 query 拿 controller 地址与密钥,打开即连,不用手填 */
    this.url = `http://127.0.0.1:${port}/ui/?hostname=127.0.0.1&port=${port}`
      + (secret.length > 0 ? `&secret=${encodeURIComponent(secret)}` : '');
    this.ready = true;
    /* Web 组件在 build() 里无条件挂载,controller 已绑好 → 这里 loadUrl 才合法。
       旧写法把 Web 放在 if (this.ready) 里,而这里在 ready=true 的同一帧就 loadUrl,
       组件还没创建 → "Init error. The WebviewController must be associated with a Web
       component"(真机表现就是「面板加载失败」)。 */
    try {
      this.controller.loadUrl(this.url);
    } catch (e) {
      this.hint = `面板加载失败: ${e instanceof Error ? e.message : `${e}`}`;
    }
  }

  build() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([$r('app.color.text_1')])
        }
        .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
        .visualEffect(pressLightEffect(this.litKey === 'back', false))
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.litKey = 'back';
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.litKey = '';
          }
        })
        .onClick(() => { void router.back(); })
        .accessibilityText($r('app.string.web_ui_back'))

        Text($r('app.string.web_ui_title'))
          .fontSize(17).fontWeight(700).fontColor($r('app.color.text_1'))
          .layoutWeight(1)

        if (this.ready) {
          Row() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(19)
              .fontColor([$r('app.color.text_2')])
          }
          .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
          .visualEffect(pressLightEffect(this.litKey === 'reload', false))
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litKey = 'reload';
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litKey = '';
            }
          })
          .onClick(() => {
            try {
              this.controller.refresh();
            } catch (e) {
              // 刷新失败保留当前页
            }
          })
          .accessibilityText($r('app.string.web_ui_reload'))
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 4, right: 4 })

      Stack() {
        /* 必须无条件挂载:WebviewController 未关联 Web 组件时 loadUrl 会抛 Init error。 */
        Web({ src: this.url, controller: this.controller })
          .domStorageAccess(true)
          .javaScriptAccess(true)
          .fileAccess(false)
          .javaScriptOnDocumentStart([{ script: this.themeInjectScript(), scriptRules: ['*'] }])
          .width('100%')
          .height('100%')
          .onPageBegin(() => { this.loading = true; })
          .onPageEnd(() => {
            this.loading = false;
            this.applyThemeAfterLoad();
          })
          .onErrorReceive((event) => {
            /* 端口未监听 / yacd 未解压(404):给可读提示,别留白屏 */
            if (event !== undefined && event.request.isMainFrame()) {
              this.loading = false;
              this.hint = `面板加载失败: ${event.error.getErrorInfo()}`;
            }
          })
        if (this.hint.length > 0) {
          Column({ space: 10 }) {
            Text(this.hint)
              .fontSize(13).fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
            Button($r('app.string.web_ui_retry'))
              .height(36).width(140)
              .backgroundColor(this.litKey === 'reload' ? $r('app.color.primary') : $r('app.color.surface'))
              .fontColor(this.litKey === 'reload' ? $r('app.color.surface') : $r('app.color.text_1'))
              .onClick(() => {
                this.hint = '';
                this.ready = false;
                void this.bootstrap();
              })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .padding(24)
          .backgroundColor($r('app.color.app_background'))
        } else if (!this.ready || this.loading) {
          Column() {
            LoadingProgress().width(28).height(28).color($r('app.color.primary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.app_background'))
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topPadVp })
    .backgroundColor($r('app.color.app_background'))
  }
}
