import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { initStore, loadProfiles, saveProfiles } from '../model/Store';
import { SubInfo, listSubs, removeSub, updateSubscription, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { formatBytes } from '../utils/TrafficStats';
import { setClipboardText } from '../utils/ClipboardHelper';

@Entry
@Component
struct SubDetailPage {
  @State sub: SubInfo = new SubInfo();
  @State profileCount: number = 0;
  @State updating: boolean = false;
  @State loading: boolean = true;
  @State loadError: string = '';
  @State notFound: boolean = false;
  @State shareText: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private shareDialog: CustomDialogController = new CustomDialogController({
    builder: SubscriptionShareDialog({
      text: $shareText,
      onCopy: async (text: string) => {
        await setClipboardText(text);
        promptAction.showToast({ message: $r('app.string.share_link_copied') });
      }
    }),
    autoCancel: true
  });

  openSubscriptionShare(): void {
    if (this.sub.url.length === 0) {
      return;
    }
    this.shareText = this.sub.url;
    this.shareDialog.open();
  }

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    this.notFound = false;
    try {
      await initStore(this.context);
      const params = router.getParams() as Record<string, Object>;
      const url = params !== undefined && params['url'] !== undefined ? `${params['url']}` : '';
      if (url.length === 0) {
        this.notFound = true;
        return;
      }
      const subs = await listSubs();
      const found = subs.find((s: SubInfo) => s.url === url);
      if (found === undefined) {
        this.notFound = true;
        return;
      }
      this.sub = found;
      const profiles = await loadProfiles();
      this.profileCount = profiles.filter(p => p.subUrl === url).length;
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  async updateNow(): Promise<void> {
    if (this.updating || this.sub.url.length === 0) {
      return;
    }
    this.updating = true;
    try {
      const result = await updateSubscription(this.sub.url);
      await markSubSuccess(this.sub.url);
      promptAction.showToast({ message: $r('app.string.sub_update_result', result.added, result.removed) });
    } catch (e) {
      await markSubFailure(this.sub.url);
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.update_failed_reason', message) });
    } finally {
      this.updating = false;
      await this.load();
    }
  }

  confirmDelete(): void {
    AlertDialog.show({
      message: $r('app.string.confirm_delete_sub_name', this.sub.name, this.profileCount),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          const profiles = await loadProfiles();
          await saveProfiles(profiles.filter(p => p.subUrl !== this.sub.url));
          await removeSub(this.sub.url);
          router.back();
        }
      }
    });
  }

  build() {
    Column() {
    Column() {
      Row() {
        Text('←').fontSize(22).padding(8).onClick(() => router.back())
        Text($r('app.string.subscription_detail_title')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
      }.width('100%').padding(12)

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.primary'))
          Text($r('app.string.loading_subscription'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.loadError.length > 0) {
        Column({ space: 8 }) {
          Text($r('app.string.subscription_load_failed'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.loadError)
            .fontSize(13)
            .fontColor($r('app.color.error'))
          Button($r('app.string.reload'))
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => this.load())
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.notFound) {
        Column({ space: 8 }) {
          Text($r('app.string.subscription_not_found'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.subscription_missing_hint'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Button($r('app.string.back'))
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => router.back())
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            Text(this.sub.name.length > 0 ? this.sub.name : $r('app.string.unnamed_subscription'))
              .fontSize(20).fontWeight(FontWeight.Bold).width('100%')
            Text(this.sub.url).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
            Text($r('app.string.profile_count_value', this.profileCount)).width('100%')
            Text($r('app.string.used_traffic_value', formatBytes(this.sub.upload + this.sub.download))).width('100%')
            Text(this.sub.total > 0 ? $r('app.string.total_traffic_value', formatBytes(this.sub.total)) : $r('app.string.total_traffic_unknown')).width('100%')
            Text($r('app.string.consecutive_failures_value', Number(this.sub.failCount)))
              .fontColor(Number(this.sub.failCount) >= 3 ? $r('app.color.error') : $r('app.color.text_secondary')).width('100%')
            Button(this.updating ? $r('app.string.updating') : $r('app.string.update_now'))
              .width('100%').height(UiSpec.BTN_HEIGHT).enabled(!this.updating).onClick(() => this.updateNow())
            Button($r('app.string.share_subscription'))
              .width('100%').height(UiSpec.BTN_HEIGHT).onClick(() => this.openSubscriptionShare())
            Button($r('app.string.delete_subscription_profiles'))
              .width('100%').height(UiSpec.BTN_HEIGHT).backgroundColor($r('app.color.error')).onClick(() => this.confirmDelete())
          }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%')
      }
    }
    .width('100%')
    .height('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .width('100%').height('100%').backgroundColor($r('app.color.app_background'))
  }
}

/** 订阅分享降级弹窗：SDK 未提供 generateBarcode 时展示链接并支持复制。 */
@CustomDialog
struct SubscriptionShareDialog {
  controller?: CustomDialogController;
  @Link text: string;
  onCopy: (text: string) => void = (text: string) => {};

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.share_subscription_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      Text(this.text)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .copyOption(CopyOptions.LocalDevice)
        .width('100%')
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button($r('app.string.copy_share_link'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => this.onCopy(this.text))
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}
