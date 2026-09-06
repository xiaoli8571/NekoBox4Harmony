import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { DrawerButton } from '../common/components/DrawerButton';
import { initStore, resetAllData, LogStore } from '../model/Store';
import { stunTest, StunResult } from '../utils/StunTester';

/**
 * 工具页(对齐 NekoBoxForAndroid ToolsFragment):
 * NAT 行为发现(STUN 测试)+ 恢复出厂设置。
 */
@Component
export struct ToolsPage {
  @State stunServer: string = 'stun.cloudflare.com:3478';
  @State stunTesting: boolean = false;
  @State stunResult: StunResult | null = null;
  @State resetting: boolean = false;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onOpenDrawer: () => void = () => {};

  async runStun(): Promise<void> {
    if (this.stunTesting) {
      return;
    }
    if (this.stunServer.trim().length === 0) {
      promptAction.showToast({ message: $r('app.string.stun_server_required') });
      return;
    }
    this.stunTesting = true;
    this.stunResult = null;
    try {
      this.stunResult = await stunTest(this.stunServer);
    } finally {
      this.stunTesting = false;
    }
  }

  private requestReset(): void {
    AlertDialog.show({
      message: $r('app.string.reset_confirm'),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.reset_action'),
        fontColor: $r('app.color.error'),
        action: () => {
          AlertDialog.show({
            message: $r('app.string.reset_confirm_final'),
            primaryButton: { value: $r('app.string.cancel'), action: () => {} },
            secondaryButton: {
              value: $r('app.string.reset_action'),
              fontColor: $r('app.color.error'),
              action: () => this.doReset()
            }
          });
        }
      }
    });
  }

  private async doReset(): Promise<void> {
    if (this.resetting) {
      return;
    }
    this.resetting = true;
    try {
      await initStore(this.context);
      await resetAllData();
      LogStore.addLog('[app] 已恢复出厂设置');
      promptAction.showToast({ message: $r('app.string.reset_done') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.reset_failed', e instanceof Error ? e.message : `${e}`) });
    } finally {
      this.resetting = false;
    }
  }

  build() {
    Column() {
      Row() {
        DrawerButton({ onOpen: () => this.onOpenDrawer() })
        Text($r('app.string.nav_tools'))
          .fontSize(16).fontWeight(800).fontColor($r('app.color.text_1')).layoutWeight(1)
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING, top: 26, bottom: 8 })

      Scroll() {
        Column({ space: 14 }) {
          // NAT 行为发现(STUN)
          Column({ space: 10 }) {
            Text($r('app.string.stun_title'))
              .fontSize(14.5).fontWeight(700).fontColor($r('app.color.text_1')).width('100%')
            Text($r('app.string.stun_desc'))
              .fontSize(11.5).fontColor($r('app.color.text_secondary')).width('100%')
            Row({ space: 8 }) {
              TextInput({ text: this.stunServer, placeholder: 'stun.cloudflare.com:3478' })
                .layoutWeight(1).height(40)
                .onChange((v: string) => { this.stunServer = v; })
              Button(this.stunTesting ? $r('app.string.stun_testing') : $r('app.string.stun_test'))
                .height(40)
                .enabled(!this.stunTesting)
                .backgroundColor(this.stunTesting ? $r('app.color.control_disabled') : $r('app.color.primary'))
                .fontColor($r('app.color.surface'))
                .onClick(() => this.runStun())
            }.width('100%')

            if (this.stunResult !== null) {
              Column({ space: 4 }) {
                if (this.stunResult.ok) {
                  Row({ space: 8 }) {
                    Text($r('app.string.stun_public_endpoint')).fontSize(12.5).fontColor($r('app.color.text_2'))
                    Text(this.stunResult.publicEndpoint)
                      .fontSize(12.5).fontWeight(700).fontColor($r('app.color.success'))
                      .fontFamily('monospace')
                      .copyOption(CopyOptions.LocalDevice)
                  }.width('100%')
                  Text($r('app.string.stun_latency', this.stunResult.latencyMs))
                    .fontSize(11.5).fontColor($r('app.color.text_3')).width('100%')
                  Text(this.stunResult.mappingStable
                    ? $r('app.string.stun_nat_cone') : $r('app.string.stun_nat_symmetric'))
                    .fontSize(11.5).fontColor($r('app.color.text_2')).width('100%')
                } else {
                  Text($r('app.string.stun_failed', this.stunResult.detail))
                    .fontSize(12).fontColor($r('app.color.error')).width('100%')
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(UiSpec.GAP_MD)
          .borderRadius(UiSpec.CARD_RADIUS)
          .backgroundColor($r('app.color.surface'))

          // 恢复出厂
          Column({ space: 10 }) {
            Text($r('app.string.reset_title'))
              .fontSize(14.5).fontWeight(700).fontColor($r('app.color.text_1')).width('100%')
            Text($r('app.string.reset_desc'))
              .fontSize(11.5).fontColor($r('app.color.text_secondary')).width('100%')
            Button($r('app.string.reset_action'))
              .height(UiSpec.BTN_HEIGHT)
              .backgroundColor($r('app.color.error'))
              .fontColor($r('app.color.surface'))
              .onClick(() => this.requestReset())
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
}
