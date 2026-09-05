@Component
export struct BottomNavText {
  label: ResourceStr = '';
  @Prop selected: boolean = false;
  onSelect: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(16)
      .fontWeight(this.selected ? 800 : FontWeight.Regular)
      .fontColor(this.selected ? $r('app.color.mono') : $r('app.color.text_3'))
      .letterSpacing(2)
      .padding({ left: 22, right: 22, top: 20, bottom: 30 })
      .onClick(() => this.onSelect())
  }
}
