import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { statusBarTopVp } from '../common/PageTopInset';
import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';
import { initStore } from '../model/Store';
import { AppMessage, listMessages, markAllRead, clearMessages } from '../model/MessageStore';

/**
 * 消息中心(对齐 OwnBox MessageStore + 消息页)。
 * 记录:订阅更新结果、批量测速完成等「用户错过就不知道」的事件。
 */
@Entry
@Component
struct MessagesPage {
  @State topPadVp: number = 44;
  @State loading: boolean = true;
  @State messages: Array<AppMessage> = [];
  @State litKey: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    this.topPadVp = await statusBarTopVp(this.context, 44);
    await initStore(this.context);
    this.messages = await listMessages();
    this.loading = false;
  }

  private async readAll(): Promise<void> {
    await markAllRead();
    this.messages = await listMessages();
  }

  private async clearAll(): Promise<void> {
    await clearMessages();
    this.messages = [];
  }

  private timeText(at: number): string {
    if (at <= 0) {
      return '';
    }
    const d = new Date(at);
    const mm = d.getMonth() + 1;
    const dd = d.getDate();
    const hh = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
    const mi = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
    return `${mm}-${dd} ${hh}:${mi}`;
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

        Text($r('app.string.messages_title'))
          .fontSize(17).fontWeight(700).fontColor($r('app.color.text_1')).layoutWeight(1)

        Text($r('app.string.messages_read_all'))
          .fontSize(12).fontColor($r('app.color.primary'))
          .padding({ right: 10 })
          .onClick(() => { void this.readAll(); })
        Text($r('app.string.messages_clear'))
          .fontSize(12).fontColor($r('app.color.error'))
          .onClick(() => { void this.clearAll(); })
      }
      .width('100%')
      .height(52)
      .padding({ left: 4, right: UiSpec.PAGE_PADDING })

      if (this.loading) {
        Column() {
          LoadingProgress().width(28).height(28).color($r('app.color.primary'))
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.messages.length === 0) {
        Column({ space: 8 }) {
          Text($r('app.string.messages_empty'))
            .fontSize(13).fontColor($r('app.color.text_2'))
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.messages, (m: AppMessage) => {
            ListItem() {
              Column({ space: 4 }) {
                Row({ space: 6 }) {
                  if (!m.read) {
                    Circle({ width: 6, height: 6 }).fill($r('app.color.primary'))
                  }
                  Text(m.title)
                    .fontSize(13.5).fontWeight(m.read ? 500 : 700)
                    .fontColor($r('app.color.text_1')).layoutWeight(1)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.timeText(m.at))
                    .fontSize(10.5).fontColor($r('app.color.text_3'))
                }.width('100%')
                if (m.body.length > 0) {
                  Text(m.body)
                    .fontSize(11.5).fontColor($r('app.color.text_2'))
                    .width('100%')
                }
              }
              .width('100%')
              .padding(12)
              .alignItems(HorizontalAlign.Start)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(12)
            }
          }, (m: AppMessage) => m.id)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 16 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topPadVp })
    .backgroundColor($r('app.color.app_background'))
  }
}
