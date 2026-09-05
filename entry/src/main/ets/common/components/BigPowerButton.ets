import { UiSpec } from '../UiSpec';

@Component
export struct BigPowerButton {
  running: boolean = false;
  connecting: boolean = false;
  onToggle: () => void = () => {};
  breakpoint: string = 'compact';
  @State private pressed: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.running) {
        Circle()
          .width(UiSpec.POWER_LIVE_RING_SIZE)
          .height(UiSpec.POWER_LIVE_RING_SIZE)
          .fill(Color.Transparent)
          .stroke($r('app.color.ring_live'))
          .strokeWidth(UiSpec.POWER_LIVE_RING_WIDTH)
      }
      Circle()
        .width(UiSpec.POWER_BUTTON_SIZE)
        .height(UiSpec.POWER_BUTTON_SIZE)
        .fill(Color.Transparent)
        .stroke($r('app.color.mono'))
        .strokeWidth(UiSpec.POWER_RING_WIDTH)
      Button({ type: ButtonType.Circle }) {
        if (this.connecting) {
          LoadingProgress()
            .width(30)
            .height(30)
            .color($r('app.color.power_icon'))
        } else {
          Text('⏻')
            .fontSize(UiSpec.POWER_ICON_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.power_icon'))
        }
      }
      .width(UiSpec.POWER_CORE_SIZE)
      .height(UiSpec.POWER_CORE_SIZE)
      .backgroundColor($r('app.color.mono'))
      .opacity(this.connecting ? 0.85 : 1)
      .onClick(() => this.onToggle())
    }
    .width(UiSpec.POWER_LIVE_RING_SIZE)
    .height(UiSpec.POWER_LIVE_RING_SIZE)
    .scale({ x: this.pressed ? UiSpec.POWER_PRESSED_SCALE : 1, y: this.pressed ? UiSpec.POWER_PRESSED_SCALE : 1 })
    .onTouch((event: TouchEvent) => {
      const nextPressed = event.type === TouchType.Down;
      animateTo({ duration: UiSpec.POWER_ANIMATION_DURATION, curve: Curve.EaseOut }, () => {
        this.pressed = nextPressed;
      });
    })
  }
}
