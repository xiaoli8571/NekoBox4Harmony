import common from '@ohos.app.ability.common';
import bundleManager from '@ohos.bundle.bundleManager';
import promptAction from '@ohos.promptAction';
import http from '@ohos.net.http';
import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';

const CORE_VERSION = 'sing-box 1.14.0 (OHOS c-shared)';
const GITHUB_URL = 'https://github.com/xiaoli8571/NekoBox4Harmony';
const TELEGRAM_URL = 'https://t.me/+x9D290Stp9NhYWU9';
const RELEASES_API = 'https://api.github.com/repos/xiaoli8571/NekoBox4Harmony/releases/latest';

/**
 * 关于页(对齐 NekoBoxForAndroid AboutFragment):
 * 版本、内核版本、检查更新、项目主页、开源许可。
 */
@Component
export struct AboutPage {
  @State appVersion: string = '';
  @State checking: boolean = false;
  /** 当前被按下的元素 key(检查更新 / 项目主页 / Telegram):"按下才亮"靠它逐颗判断 */
  @State litKey: string = '';
  onOpenDrawer: () => void = () => {};
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = info.versionName;
    } catch (e) {
      this.appVersion = '';
    }
  }

  private openGitHub(): void {
    this.openLink(GITHUB_URL);
  }

  private openTelegram(): void {
    this.openLink(TELEGRAM_URL);
  }

  private openLink(url: string): void {
    try {
      this.context.openLink(url);
    } catch (e) {
      // 无可用处理器时把链接展示给用户手动复制
      promptAction.showToast({ message: url });
    }
  }

  async checkUpdate(): Promise<void> {
    if (this.checking) {
      return;
    }
    this.checking = true;
    try {
      const client = http.createHttp();
      let latest = '';
      try {
        const resp = await client.request(RELEASES_API, {
          method: http.RequestMethod.GET,
          connectTimeout: 10000,
          readTimeout: 15000,
          header: { 'User-Agent': 'NekoBox4Harmony' } as Record<string, string>,
          expectDataType: http.HttpDataType.STRING
        });
        if (resp.responseCode === 200) {
          const json = JSON.parse(`${resp.result}`) as Record<string, Object>;
          latest = `${json['tag_name'] ?? ''}`.replace(/^v/, '');
        }
      } finally {
        client.destroy();
      }
      if (latest.length === 0) {
        promptAction.showToast({ message: $r('app.string.check_update_failed') });
        return;
      }
      if (this.appVersion.length > 0 && latest === this.appVersion) {
        promptAction.showToast({ message: $r('app.string.check_update_latest') });
      } else {
        promptAction.showToast({ message: $r('app.string.check_update_new', latest) });
        this.openGitHub();
      }
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.check_update_failed') });
    } finally {
      this.checking = false;
    }
  }

  build() {
    Column() {
      /* 标题与抽屉入口都在壳层的 HDS 顶栏里(Index.shellTitleBar),这里不再自带页头 */

      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 10 }) {
            Text($r('app.string.brand_name'))
              .fontSize(20).fontWeight(800).fontColor($r('app.color.text_1')).width('100%')
            this.InfoRow($r('app.string.settings_about_version'), this.appVersion.length > 0 ? this.appVersion : '—')
            this.InfoRow($r('app.string.about_core_version'), CORE_VERSION)
            Row() {
              Button(this.checking ? $r('app.string.checking_update') : $r('app.string.check_update'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.primary'))
                .fontColor($r('app.color.surface'))
                /* 卡片在 Scroll 里(会跟滚动跑位)⇒ 只"按下才亮",不挂常亮光源、不加 scale */
                .visualEffect(pressLightEffect(this.litKey === 'about:check', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'about:check';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
                .onClick(() => this.checkUpdate())
              Button($r('app.string.about_github'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .visualEffect(pressLightEffect(this.litKey === 'about:github', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'about:github';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
                .onClick(() => this.openGitHub())
              Button($r('app.string.about_telegram'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .visualEffect(pressLightEffect(this.litKey === 'about:telegram', true))
                .onTouch((event: TouchEvent) => {
                  if (event.type === TouchType.Down) {
        this.litKey = 'about:telegram';
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.litKey = '';
      }
                })
                .onClick(() => this.openTelegram())
            }.width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))

          Column({ space: 6 }) {
            Text($r('app.string.about_license_title'))
              .fontSize(13).fontWeight(700).fontColor($r('app.color.text_2')).width('100%')
            Text($r('app.string.about_license_body'))
              .fontSize(11.5).fontColor($r('app.color.text_secondary')).width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))
        }
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 8, bottom: 20 })
      }
        .edgeEffect(EdgeEffect.Spring)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  InfoRow(label: ResourceStr, value: string) {
    Row() {
      Text(label).fontSize(12.5).fontColor($r('app.color.text_2')).layoutWeight(1)
      Text(value)
        .fontSize(12.5).fontWeight(600).fontColor($r('app.color.text_1'))
        .fontFamily('monospace')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%')
  }
}
