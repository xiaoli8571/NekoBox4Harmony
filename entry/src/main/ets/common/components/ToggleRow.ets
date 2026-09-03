@Component
export struct ToggleRow {
  title: ResourceStr = '';
  description: ResourceStr = '';
  checked: boolean = false;
  controlEnabled: boolean = true;
  onChange: (checked: boolean) => void = (checked: boolean) => {};

  build() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
        Text(this.description)
          .fontSize(11.5)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.checked })
        .enabled(this.controlEnabled)
        .onChange((checked: boolean) => this.onChange(checked))
    }
    .width('100%')
    .padding({ left: 15, right: 15, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
  }
}
