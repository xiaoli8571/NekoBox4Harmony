import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import connection from '@ohos.net.connection';
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import { statusBarTopVp } from '../common/PageTopInset';
import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';
import { initStore, loadSettings, saveSettings } from '../model/Store';
import { AppSettings } from '../model/Profile';

/**
 * 局域网共享页(对齐 OwnBox LanSharingActivity)。
 *
 * 能力边界:
 *  - 内核侧的 `mixed` 入站早就存在(ConfigBuilder: mixedPort + allowAccess),
 *    本页只把"对外地址 + 鉴权"这两件用户真正需要的信息摆到台面上;
 *  - 鉴权是新加的:lanAuthUser/lanAuthPass 非空时给 mixed 入站下发 users;
 *  - 端口/开关改动属于「重连生效」,页内明确标注,不做假热更。
 */
@Entry
@Component
struct LanSharingPage {
  @State topPadVp: number = 44;
  @State loading: boolean = true;
  @State ipv4: string = '';
  @State s: AppSettings = new AppSettings();
  @State litKey: string = '';

  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    this.topPadVp = await statusBarTopVp(this.context, 44);
    await initStore(this.context);
    try {
      this.s = await loadSettings();
    } catch (e) {
      // 设置读失败:保留默认值,页面仍可显示
    }
    this.ipv4 = await this.localIpv4();
    this.loading = false;
  }

  private async localIpv4(): Promise<string> {
    try {
      const net = await connection.getDefaultNet();
      if (net.netId === 0) {
        return '';
      }
      const props = await connection.getConnectionProperties(net);
      const links = props.linkAddresses;
      if (links !== undefined) {
        for (const link of links) {
          const addr = link.address.address;
          if (addr.indexOf('.') > 0) {
            return addr;
          }
        }
      }
    } catch (e) {
      // 无网络/无权限:返回空,页面显示 "--"
    }
    return '';
  }

  private async persist(): Promise<void> {
    try {
      await saveSettings(this.s);
      promptAction.showToast({ message: $r('app.string.lan_saved') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.save_failed') });
    }
  }

  private copyAddress(): void {
    const host = this.ipv4.length > 0 ? this.ipv4 : '127.0.0.1';
    const text = `socks5://${host}:${this.s.mixedPort}`;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: $r('app.string.lan_copied') });
      });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.lan_copy_failed') });
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

        Text($r('app.string.lan_title'))
          .fontSize(17).fontWeight(700).fontColor($r('app.color.text_1')).layoutWeight(1)

        Button($r('app.string.save'))
          .height(34).fontSize(12.5)
          .backgroundColor(this.litKey === 'back' ? $r('app.color.primary') : $r('app.color.surface'))
          .fontColor(this.litKey === 'back' ? $r('app.color.surface') : $r('app.color.text_1'))
          .onClick(() => { void this.persist(); })
      }
      .width('100%')
      .height(52)
      .padding({ left: 4, right: UiSpec.PAGE_PADDING })

      if (this.loading) {
        Column() {
          LoadingProgress().width(28).height(28).color($r('app.color.primary'))
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            // 共享状态卡
            Column({ space: 8 }) {
              Row() {
                Column({ space: 2 }) {
                  Text($r('app.string.lan_enable')).fontSize(14.5).fontWeight(700)
                    .fontColor($r('app.color.text_1'))
                  Text($r('app.string.lan_enable_desc')).fontSize(11.5)
                    .fontColor($r('app.color.text_2'))
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.s.allowAccess })
                  .onChange((v: boolean) => { this.s.allowAccess = v; })
              }.width('100%')

              Row({ space: 8 }) {
                Text($r('app.string.lan_address')).fontSize(12.5).fontColor($r('app.color.text_2'))
                  .width(96)
                Text(this.ipv4.length > 0 ? `${this.ipv4}:${this.s.mixedPort}` : '--')
                  .fontSize(12.5).fontFamily('monospace').fontColor($r('app.color.text_1'))
                  .layoutWeight(1)
                Text($r('app.string.lan_copy'))
                  .fontSize(12).fontColor($r('app.color.primary'))
                  .onClick(() => { this.copyAddress(); })
              }.width('100%')

              Row({ space: 8 }) {
                Text($r('app.string.lan_port')).fontSize(12.5).fontColor($r('app.color.text_2'))
                  .width(96)
                TextInput({ text: this.s.mixedPort > 0 ? `${this.s.mixedPort}` : '' })
                  .type(InputType.Number).height(36).layoutWeight(1)
                  .onChange((v: string) => {
                    const n = parseInt(v);
                    this.s.mixedPort = isNaN(n) ? 0 : Math.max(0, Math.min(65535, n));
                  })
              }.width('100%')

              Text($r('app.string.lan_reconnect_note'))
                .fontSize(11).fontColor($r('app.color.warning')).width('100%')
            }
            .width('100%').padding(14)
            .backgroundColor($r('app.color.surface')).borderRadius(14)
            .alignItems(HorizontalAlign.Start)

            // 鉴权
            Column({ space: 8 }) {
              Text($r('app.string.lan_auth_title')).fontSize(14).fontWeight(700)
                .fontColor($r('app.color.text_1')).width('100%')
              Text($r('app.string.lan_auth_desc')).fontSize(11.5)
                .fontColor($r('app.color.text_2')).width('100%')
              Text($r('app.string.lan_auth_user')).fontSize(12.5)
                .fontColor($r('app.color.text_2')).width('100%')
              TextInput({ text: this.s.lanAuthUser, placeholder: 'user' })
                .height(38).width('100%')
                .onChange((v: string) => { this.s.lanAuthUser = v; })
              Text($r('app.string.lan_auth_pass')).fontSize(12.5)
                .fontColor($r('app.color.text_2')).width('100%')
              TextInput({ text: this.s.lanAuthPass, placeholder: 'password' })
                .type(InputType.Password).height(38).width('100%')
                .onChange((v: string) => { this.s.lanAuthPass = v; })
            }
            .width('100%').padding(14)
            .backgroundColor($r('app.color.surface')).borderRadius(14)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%').padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 24 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topPadVp })
    .backgroundColor($r('app.color.app_background'))
  }
}
