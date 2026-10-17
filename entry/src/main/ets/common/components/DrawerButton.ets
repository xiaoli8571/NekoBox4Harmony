import { pressLightEffect } from '../Effects';

/**
 * 抽屉按钮:所有驻留页头部共用的入口,点击打开全局抽屉。
 * 图标从字符 `≡` 换成系统符号 `hamburgers`,宿主从 `Text` 换成 `Button`
 * (官方点光源宿主白名单不含 Text,字符图标配了也不会亮,见 Effects.ets)。
 */
@ComponentV2
export struct DrawerButton {
  @Event onOpen: () => void = (): void => {
  };
  @Local pressed: boolean = false;

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      SymbolGlyph($r('sys.symbol.hamburgers'))
        .fontSize(22)
        .fontColor([$r('app.color.text_1')])
    }
    .width(48)
    .height(48)
    .borderRadius(14)
    .backgroundColor(Color.Transparent)
    .visualEffect(pressLightEffect(this.pressed, true))
    .scale({ x: this.pressed ? 0.94 : 1.0, y: this.pressed ? 0.94 : 1.0 })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => this.onOpen())
  }
}
