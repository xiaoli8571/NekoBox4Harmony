import { UiSpec } from '../UiSpec';
import { pressLightEffect } from '../Effects';

/**
 * 大号电源键(带外圈圆环)。
 * ⚠️ 本组件目前**零引用**(Index 用的是自己的 FAB)——保留但一并对齐本轮口径:
 * 图标从字符 `⏻` 换成系统符号 `sys.symbol.power`(名字已在 SDK
 * `ets-loader\sysResource.js` 的 `sys.symbol` 表里核实),并挂 HDS 点按光效。
 */
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
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        if (this.connecting) {
          LoadingProgress()
            .width(30)
            .height(30)
            .color($r('app.color.power_icon'))
        } else {
          SymbolGlyph($r('sys.symbol.power'))
            .fontSize(UiSpec.POWER_ICON_SIZE)
            .fontColor([$r('app.color.power_icon')])
        }
      }
      .width(UiSpec.POWER_CORE_SIZE)
      .height(UiSpec.POWER_CORE_SIZE)
      .backgroundColor($r('app.color.mono'))
      .opacity(this.connecting ? 0.85 : 1)
      .visualEffect(pressLightEffect(this.pressed, true))
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
