import { pressLightEffect } from '../Effects';

/**
 * 图标按钮(HDS 点按光效版):把原来那些 `Text('≡')` / `Text('⋮')` 的字符图标
 * 统一换成系统符号(SymbolGlyph)+ HDS 点光源。
 *
 * 为什么要包一层 `Button`:官方点光源的宿主白名单里**没有 `Text`**
 * (见 Effects.ets 顶部注释),字符图标 + pointLight 配了也不会亮。
 * `stateEffect: false` 关掉 Button 自带的按压态,免得盖掉 HDS 按压光效(照 RzdVideo HomePage 的成熟写法)。
 * `buttonShape: ButtonType.Normal` + 透明底,外观与原来的字符按钮一致(仍是 36~40vp 的方形热区)。
 */
@ComponentV2
export struct GlowIconButton {
  @Param symbol: Resource = $r('sys.symbol.hamburgers');
  @Param iconSize: number = 20;
  @Param boxSize: number = 44;
  @Param iconColor: ResourceColor = $r('app.color.text_1');
  @Param radius: number = 12;
  @Param tapEnabled: boolean = true;
  @Event onTap: () => void = (): void => {
  };
  @Local pressed: boolean = false;

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      SymbolGlyph(this.symbol)
        .fontSize(this.iconSize)
        .fontColor([this.iconColor])
    }
    .width(this.boxSize)
    .height(this.boxSize)
    .borderRadius(this.radius)
    .backgroundColor(Color.Transparent)
    .enabled(this.tapEnabled)
    .visualEffect(pressLightEffect(this.pressed, true))
    .scale({ x: this.pressed ? 0.94 : 1.0, y: this.pressed ? 0.94 : 1.0 })
    /* ⚠️ 触发走 `onTouch` 的 Up,不用 `.onClick`:
       顶栏 `stackBuilder` 里 Button 的**点击手势会被 HDS 顶栏吃掉**(onTouch 正常、onClick 不回调),
       这就是"顶栏按钮点下去会亮但动作不执行"的真因(真机实测)。 */
    .onTouch((event: TouchEvent) => {
      if (!this.tapEnabled) {
        return;
      }
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up) {
        this.pressed = false;
        this.onTap();
      } else if (event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}
