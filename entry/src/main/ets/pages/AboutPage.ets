import common from '@ohos.app.ability.common';
import bundleManager from '@ohos.bundle.bundleManager';
import promptAction from '@ohos.promptAction';
import http from '@ohos.net.http';
import { UiSpec } from '../common/UiSpec';

const CORE_VERSION = 'sing-box 1.11.9 (OHOS c-shared)';
const GITHUB_URL = 'https://github.com/xiaoli8571/NekoBox4Harmony';
const RELEASES_API = 'https://api.github.com/repos/xiaoli8571/NekoBox4Harmony/releases/latest';

/**
 * 关于页(对齐 NekoBoxForAndroid AboutFragment):
 * 版本、内核版本、检查更新、项目主页、开源许可。
 */
@Component
export struct AboutPage {
  @State appVersion: string = '';
  @State checking: boolean = false;
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
    try {
      this.context.openLink(GITHUB_URL);
    } catch (e) {
      promptAction.showToast({ message: GITHUB_URL });
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
      Text($r('app.string.nav_about'))
        .fontSize(16).fontWeight(800).fontColor($r('app.color.text_1'))
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 26, bottom: 8 })

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
                .onClick(() => this.checkUpdate())
              Button($r('app.string.about_github'))
                .layoutWeight(1)
                .height(UiSpec.BTN_HEIGHT)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => this.openGitHub())
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
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 20 })
      }
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
