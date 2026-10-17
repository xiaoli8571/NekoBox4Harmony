import { hdsEffect } from '@kit.UIDesignKit';

/**
 * HDS 点按光效(点光源 + 按压阴影)—— 与 RzdSchool 的 CommonUi.ets 同一套写法。
 *
 * 官方口径(本机 SDK `@hms.hds.hdsBaseComponent.d.ets`,全部 `@since 6.0.0(20)`,本工程 API 24 可用):
 *  · `pointLight` 的**宿主白名单**:Button / Toggle / Row / Column / Image / Flex / Stack / Select /
 *    Menu / MenuItem —— **没有 `Text`**。所以原来那批用 `Text('≡')` 当图标的按钮,
 *    不仅要换成 `SymbolGlyph`,宿主本身也要从 `Text` 换成一个 `Button`(或 Row/Column),否则配了也不亮。
 *  · `pressShadow` **仅在 Button 上生效**。
 *  · `sourceType` 的优先级高于 `options`:两个都写时 `options` 被吃掉(看起来像"常亮"或"毫无变化")。
 *    这里只用 `sourceType` 预设:没按 = NONE、按下 = BRIGHT。
 *  · `sourceType` = 自己**发光**并照亮**周围**声明了受光的组件;
 *    `illuminatedType` = 自己**受光**(等着被照亮)。两个语义别混。
 *  · 官方明确"光源位置初始化为组件正中心、**不会跟着组件的位移变化**,
 *    因此**不建议在滚动组件中使用点光源效果**" ⇒ 本工程只在**按下那一瞬间**发光(内容此刻是静止的),
 *    不给任何组件挂常亮光源。
 *  · 受光组件若设置了 border 的颜色和宽度,会覆盖掉点光源效果 ⇒ 受光宿主不要加 border。
 *
 * @param pressed  当前是否处于按下态(由调用方按 key 判断"被按的是不是我")
 * @param isButton 宿主是不是 Button(pressShadow 只认 Button;Row/Column 传 false)
 */
export function pressLightEffect(pressed: boolean, isButton: boolean): VisualEffect {
  return new hdsEffect.HdsEffectBuilder()
    .pressShadow(pressed && isButton
      ? hdsEffect.PressShadowType.BLEND_GRADIENT
      : hdsEffect.PressShadowType.NONE)
    .pointLight({
      sourceType: pressed
        ? hdsEffect.PointLightSourceType.BRIGHT
        : hdsEffect.PointLightSourceType.NONE,
      illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
    })
    .buildEffect();
}

/**
 * 只受光不发光:给它挂上以后,**旁边**某个按下的点光源会把它一起照亮。
 * 用于"固定件"(工具栏按钮、底栏、抽屉项、FAB 周边)这类不会跟着滚动跑位的宿主。
 * ⚠️ 宿主不要同时设置 border(会覆盖受光效果)。
 */
export function illuminatedEffect(): VisualEffect {
  return new hdsEffect.HdsEffectBuilder()
    .pointLight({
      illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
    })
    .buildEffect();
}

/** 点按反馈的兜底(与 HDS 视效无关的纯 ArkUI 属性):万一某台设备上点光源不出画面,
 *  被按下的那颗仍会有轻微缩放,用户一眼能区分"光效没生效"和"点击没响应"。 */
export const PRESS_SCALE: number = 0.96;
export const PRESS_SCALE_NONE: number = 1.0;
