/**
 * 桌面状态卡片 UI(ArkTS 卡)。
 *
 * 卡片进程里没有 store/preferences 上下文,所以这里只画静态内容 + 一个 router 动作:
 * 点击卡片直接进「流量与测速」页(用户看卡片最常见的目的就是瞄一眼速率)。
 */
@Entry
@Component
struct StatusCard {
  build() {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text('NekoBox')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('›')
          .fontSize(16)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      Text($r('app.string.form_status_hint'))
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Blank()

      Row() {
        Text($r('app.string.form_status_open'))
          .fontSize(12)
          .fontColor($r('app.color.primary'))
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor($r('app.color.surface'))
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { shortcut: 'traffic' }
      });
    })
  }
}
