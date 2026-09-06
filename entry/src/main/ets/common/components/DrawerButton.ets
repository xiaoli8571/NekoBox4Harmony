/** 抽屉按钮:所有驻留页头部共用的 ≡ 入口,点击打开全局抽屉。 */
@Component
export struct DrawerButton {
  onOpen: () => void = () => {};

  build() {
    Text('≡')
      .fontSize(20)
      .fontColor($r('app.color.text_1'))
      .width(36)
      .height(36)
      .textAlign(TextAlign.Center)
      .onClick(() => this.onOpen())
  }
}
