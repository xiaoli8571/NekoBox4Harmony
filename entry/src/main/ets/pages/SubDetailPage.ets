import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import image from '@ohos.multimedia.image';
import { generateBarcode, scanCore } from '@kit.ScanKit';
import { UiSpec } from '../common/UiSpec';
import { initStore, loadProfiles, saveProfiles, loadGroups, ensureGroupByName, LogStore } from '../model/Store';
import { ProfileGroup } from '../model/Profile';
import { SubInfo, listSubs, saveSubs, removeSub, updateSubscription, markSubSuccess, markSubFailure, saveSubSettings } from '../core/Subscriptions';
import { subErrorText } from '../utils/Subscription';
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
  @State shareQr: image.PixelMap | null = null;
  @State groupDraft: string = '';
  @State intervalDraft: string = '';
  @State allGroups: Array<ProfileGroup> = [];
  private groupDialog: CustomDialogController = new CustomDialogController({
    builder: SubGroupDialog({
      draft: $groupDraft,
      groups: $allGroups,
      onApply: (name: string) => {
        void this.applySubGroup(name);
      }
    }),
    autoCancel: true
  });
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private shareDialog: CustomDialogController = new CustomDialogController({
    builder: SubscriptionShareDialog({
      text: $shareText,
      qrPixelMap: $shareQr,
      onCopy: async (text: string) => {
        await setClipboardText(text);
        promptAction.showToast({ message: $r('app.string.share_link_copied') });
      }
    }),
    autoCancel: true
  });

  /** 保存单项订阅设置(立即落盘;对齐安卓 GroupSettingsActivity 即时持久化) */
  async saveSubSetting(field: string, value: Object): Promise<void> {
    if (this.sub.url.length === 0) {
      return;
    }
    try {
      const changes: Record<string, Object> = {};
      changes[field] = value;
      const updated = await saveSubSettings(this.sub.url, changes);
      if (updated !== null) {
        this.sub = updated;
      }
      promptAction.showToast({ message: $r('app.string.subscription_setting_saved') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.save_failed_reason', e instanceof Error ? e.message : `${e}`) });
    }
  }

  async openSubscriptionShare(): Promise<void> {
    if (this.sub.url.length === 0) {
      return;
    }
    this.shareText = this.sub.url;
    this.shareQr = null;
    try {
      const options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        width: 440,
        height: 440
      };
      this.shareQr = await generateBarcode.createBarcode(this.sub.url, options);
    } catch (e) {
      LogStore.addLog(`[sub] 订阅二维码生成失败,降级为文本分享: ${e}`);
    }
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
      this.intervalDraft = `${found.updateIntervalHours}`;
      const profiles = await loadProfiles();
      this.profileCount = profiles.filter(p => p.subUrl === url).length;
      this.allGroups = await loadGroups();
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  /** 修改订阅分组:更新 SubInfo.group,并把该订阅全部节点移入目标分组(组不存在自动创建;留空=未分组) */
  async applySubGroup(name: string): Promise<void> {
    const trimmed = name.trim();
    try {
      await initStore(this.context);
      const subs = await listSubs();
      for (const s of subs) {
        if (s.url === this.sub.url) {
          s.group = trimmed;
        }
      }
      await saveSubs(subs);
      const gid = await ensureGroupByName(trimmed);
      const profiles = await loadProfiles();
      for (const p of profiles) {
        if (p.subUrl === this.sub.url) {
          p.groupId = gid;
        }
      }
      await saveProfiles(profiles);
      this.sub.group = trimmed;
      if (this.groupDialog !== undefined) {
        this.groupDialog.close();
      }
      promptAction.showToast({
        message: trimmed.length > 0
          ? $r('app.string.sub_group_applied', trimmed)
          : $r('app.string.sub_group_applied_none')
      });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.save_failed_reason', message) });
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
      const message = subErrorText(e as Object);
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
          Column({ space: UiSpec.GAP_MD }) {
            // 订阅信息卡
            Column({ space: UiSpec.GAP_SM }) {
              Text(this.sub.name.length > 0 ? this.sub.name : $r('app.string.unnamed_subscription'))
                .fontSize(18).fontWeight(FontWeight.Bold).width('100%')
              Text(this.sub.url)
                .fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
              if (this.sub.group !== '') {
                Text($r('app.string.sub_group_value', this.sub.group))
                  .fontSize(12).fontColor($r('app.color.primary')).width('100%')
              }
              Text($r('app.string.profile_count_value', this.profileCount))
                .fontSize(13).width('100%')
              Text($r('app.string.used_traffic_value', formatBytes(this.sub.upload + this.sub.download)))
                .fontSize(13).width('100%')
              Text(this.sub.total > 0 ? $r('app.string.total_traffic_value', formatBytes(this.sub.total)) : $r('app.string.total_traffic_unknown'))
                .fontSize(13).width('100%')
              Text($r('app.string.consecutive_failures_value', Number(this.sub.failCount)))
                .fontSize(13)
                .fontColor(Number(this.sub.failCount) >= 3 ? $r('app.color.error') : $r('app.color.text_secondary')).width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(UiSpec.GAP_MD)
            .borderRadius(UiSpec.CARD_RADIUS)
            .backgroundColor($r('app.color.surface'))

            // 操作按钮:主 / 次 / 危险
            Button(this.updating ? $r('app.string.updating') : $r('app.string.update_now'))
              .width('100%').height(UiSpec.BTN_HEIGHT)
              .backgroundColor($r('app.color.primary')).fontColor($r('app.color.surface'))
              .enabled(!this.updating).onClick(() => this.updateNow())
            Button($r('app.string.share_subscription'))
              .width('100%').height(UiSpec.BTN_HEIGHT)
              .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
              .onClick(() => this.openSubscriptionShare())
            Button($r('app.string.sub_group_edit'))
              .width('100%').height(UiSpec.BTN_HEIGHT)
              .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
              .onClick(() => {
                this.groupDraft = this.sub.group;
                this.groupDialog.open();
              })
            Button($r('app.string.delete_subscription_profiles'))
              .width('100%').height(UiSpec.BTN_HEIGHT)
              .backgroundColor($r('app.color.surface')).fontColor($r('app.color.error'))
              .onClick(() => this.confirmDelete())

            // 订阅设置(对齐安卓 group_preferences.xml 的 subscriptionUpdate 分类)
            Column({ space: UiSpec.GAP_SM }) {
              Text($r('app.string.subscription_settings'))
                .fontSize(13).fontWeight(700).fontColor($r('app.color.text_2')).width('100%')

              Row() {
                Text($r('app.string.auto_update'))
                  .fontSize(13.5).fontColor($r('app.color.text_primary')).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.sub.autoUpdate })
                  .onChange((on: boolean) => this.saveSubSetting('autoUpdate', on))
              }.width('100%')

              if (this.sub.autoUpdate) {
                Row() {
                  Text($r('app.string.auto_update_delay'))
                    .fontSize(13.5).fontColor($r('app.color.text_primary')).layoutWeight(1)
                  TextInput({ text: `${this.sub.updateIntervalHours}` })
                    .type(InputType.Number)
                    .width(90).height(UiSpec.ROW_HEIGHT)
                    .backgroundColor($r('app.color.app_background'))
                    .borderRadius(8)
                    .onChange((v: string) => { this.intervalDraft = v; })
                    .onSubmit(() => { void this.saveSubSetting('updateIntervalHours', this.intervalDraft); })
                }.width('100%')

                Row() {
                  Column({ space: 2 }) {
                    Text($r('app.string.update_when_connected_only'))
                      .fontSize(13.5).fontColor($r('app.color.text_primary')).width('100%')
                    Text($r('app.string.update_when_connected_only_sum'))
                      .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.sub.updateWhenConnectedOnly })
                    .onChange((on: boolean) => this.saveSubSetting('updateWhenConnectedOnly', on))
                }.width('100%')

                Row() {
                  Column({ space: 2 }) {
                    Text($r('app.string.deduplication'))
                      .fontSize(13.5).fontColor($r('app.color.text_primary')).width('100%')
                    Text($r('app.string.deduplication_sum'))
                      .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.sub.deduplication })
                    .onChange((on: boolean) => this.saveSubSetting('deduplication', on))
                }.width('100%')

                Row() {
                  Column({ space: 2 }) {
                    Text($r('app.string.force_resolve'))
                      .fontSize(13.5).fontColor($r('app.color.text_primary')).width('100%')
                    Text($r('app.string.force_resolve_sum'))
                      .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.sub.forceResolve })
                    .onChange((on: boolean) => this.saveSubSetting('forceResolve', on))
                }.width('100%')
              }

              Column({ space: 4 }) {
                Text($r('app.string.subscription_user_agent'))
                  .fontSize(13.5).fontColor($r('app.color.text_primary')).width('100%')
                TextInput({ text: this.sub.userAgent, placeholder: $r('app.string.subscription_user_agent_hint') })
                  .width('100%').height(UiSpec.ROW_HEIGHT)
                  .backgroundColor($r('app.color.app_background'))
                  .borderRadius(8)
                  .onChange((v: string) => { this.sub.userAgent = v; })
                  .onSubmit(() => { void this.saveSubSetting('userAgent', this.sub.userAgent); })
              }.alignItems(HorizontalAlign.Start).width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(UiSpec.GAP_MD)
            .borderRadius(UiSpec.CARD_RADIUS)
            .backgroundColor($r('app.color.surface'))
          }
          .width('100%')
          .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: UiSpec.GAP_MD, bottom: UiSpec.GAP_MD })
          .alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%')
          .edgeEffect(EdgeEffect.Spring)
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

/** 订阅分组弹窗:输入组名或点选已有分组,保存后移动该订阅全部节点 */
@CustomDialog
struct SubGroupDialog {
  controller?: CustomDialogController;
  @Link draft: string;
  @Link groups: Array<ProfileGroup>;
  onApply: (name: string) => void = (name: string) => {};

  build() {
    Column({ space: 10 }) {
      Text($r('app.string.sub_group_dialog_title'))
        .fontSize(16).fontWeight(FontWeight.Bold).width('100%')
      TextInput({ text: this.draft, placeholder: $r('app.string.sub_group_hint') })
        .height(40).width('100%')
        .onChange((v: string) => { this.draft = v; })
      if (this.groups.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.groups, (g: ProfileGroup) => {
            Text(g.name)
              .fontSize(12)
              .fontColor($r('app.color.text_primary'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(14)
              .backgroundColor($r('app.color.surface_selected'))
              .margin({ right: 6, bottom: 6 })
              .onClick(() => { this.draft = g.name; })
          }, (g: ProfileGroup) => g.id)
        }
        .width('100%')
      }
      Text($r('app.string.sub_group_apply_hint'))
        .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface')).fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button($r('app.string.save'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.primary')).fontColor($r('app.color.surface'))
          .onClick(() => {
            const name = this.draft;
            this.onApply(name);
          })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}

/** 订阅分享弹窗：展示二维码(对齐安卓 GroupFragment.action_universal_qr)+ 链接文本与复制。 */
@CustomDialog
struct SubscriptionShareDialog {
  controller?: CustomDialogController;
  @Link text: string;
  @Link qrPixelMap: image.PixelMap | null;
  onCopy: (text: string) => void = (text: string) => {};

  build() {
    Column({ space: 12 }) {
      Text($r('app.string.share_subscription_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .width('100%')
      if (this.qrPixelMap !== null) {
        Image(this.qrPixelMap)
          .width(220)
          .height(220)
          .margin({ top: 4, bottom: 4 })
          .interpolation(ImageInterpolation.None)
      }
      Text(this.text)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .copyOption(CopyOptions.LocalDevice)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
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
