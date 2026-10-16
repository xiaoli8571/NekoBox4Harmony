import { UiSpec } from '../UiSpec';

@Component
export struct BigPowerButton {
  @Prop running: boolean = false;
  @Prop connecting: boolean = false;
  onToggle: () => void = () => {};
  @Prop breakpoint: string = 'compact';
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
        .stroke(this.running ? $r('app.color.success') : $r('app.color.mono'))
        .strokeWidth(UiSpec.POWER_RING_WIDTH)
      Button({ type: ButtonType.Circle }) {
        if (this.connecting) {
          LoadingProgress()
            .width(30)
            .height(30)
            .color($r('app.color.power_icon'))
        } else {
          // 自绘电源符号:270° 圆弧(顶部留缺口)+ 居中圆角竖杆,替代 Unicode 字形 ⏻
          // (字形在不同字体/字号下基线不稳、边缘发虚;矢量绘制任意尺寸下边缘锐利)
          Stack({ alignContent: Alignment.Center }) {
            Path()
              .commands('M 14.5 18.5 A 12 12 0 1 1 29.5 18.5')
              .width(44)
              .height(44)
              .fillOpacity(0)
              .stroke($r('app.color.power_icon'))
              .strokeWidth(4)
              .strokeLineCap(LineCapStyle.Round)
              .antialias(true)
            Rect({ width: 4, height: 20 })
              .radius(2)
              .fill($r('app.color.power_icon'))
              .translate({ y: -3 })
          }
          .width(44)
          .height(44)
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
