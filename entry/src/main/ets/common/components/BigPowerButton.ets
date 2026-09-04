import { UiSpec } from '../UiSpec';

@Component
export struct BigPowerButton {
  running: boolean = false;
  connecting: boolean = false;
  orbSize: number = UiSpec.ORB_BUTTON_SIZE;
  onToggle: () => void = () => {};
  @State private pressed: boolean = false;

  build() {
    Button({ type: ButtonType.Circle }) {
      Text(this.connecting ? '…' : '⏻')
        .fontSize(UiSpec.POWER_ICON_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.power_icon'))
    }
    .width(this.orbSize)
    .height(this.orbSize)
    .borderRadius(this.orbSize / 2)
    .backgroundColor(this.running ? $r('app.color.neon_indigo') : $r('app.color.primary'))
    .border({
      width: this.running ? UiSpec.GLASS_BORDER_WIDTH : 0,
      color: $r('app.color.pulse_ring_a')
    })
    .shadow({
      radius: this.running ? UiSpec.POWER_GLOW_RADIUS : UiSpec.POWER_SHADOW_RADIUS,
      color: this.running ? $r('app.color.orb_glow_1') : $r('app.color.shadow_color'),
      offsetX: 0,
      offsetY: this.running ? 0 : UiSpec.POWER_SHADOW_OFFSET
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
