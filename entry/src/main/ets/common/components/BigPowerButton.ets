import { UiSpec } from '../UiSpec';

@Component
export struct BigPowerButton {
  running: boolean = false;
  connecting: boolean = false;
  onToggle: () => void = () => {};
  @State private pressed: boolean = false;

  build() {
    Button({ type: ButtonType.Circle }) {
      Text(this.connecting ? '…' : '⏻')
        .fontSize(UiSpec.POWER_ICON_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.power_icon'))
    }
    .width(UiSpec.POWER_BUTTON_SIZE)
    .height(UiSpec.POWER_BUTTON_SIZE)
    .borderRadius(UiSpec.POWER_BUTTON_RADIUS)
    .backgroundColor($r('app.color.primary'))
    .border({
      width: this.running ? UiSpec.POWER_RING_WIDTH : 0,
      color: $r('app.color.btn_ring')
    })
    .shadow({
      radius: this.running ? UiSpec.POWER_GLOW_RADIUS : UiSpec.POWER_SHADOW_RADIUS,
      color: this.running ? $r('app.color.btn_glow') : $r('app.color.shadow_color'),
      offsetX: 0,
      offsetY: this.running ? UiSpec.POWER_GLOW_OFFSET : UiSpec.POWER_SHADOW_OFFSET
    })
    .scale({ x: this.pressed ? UiSpec.POWER_PRESSED_SCALE : 1, y: this.pressed ? UiSpec.POWER_PRESSED_SCALE : 1 })
    .hoverEffect(HoverEffect.Scale)
    .onTouch((event: TouchEvent) => {
      const nextPressed = event.type === TouchType.Down;
      animateTo({ duration: UiSpec.POWER_ANIMATION_DURATION, curve: Curve.EaseOut }, () => {
        this.pressed = nextPressed;
      });
    })
    .onClick(() => this.onToggle())
  }
}
