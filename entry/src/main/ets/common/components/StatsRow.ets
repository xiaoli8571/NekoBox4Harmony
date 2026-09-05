import { UiSpec } from '../UiSpec';

@Component
export struct StatsRow {
  upload: ResourceStr = '—';
  download: ResourceStr = '—';
  traffic: ResourceStr = '—';

  @Builder
  private item(label: ResourceStr, value: ResourceStr) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_3'))
        .letterSpacing(1)
      Text(value)
        .fontSize(14)
        .fontWeight(800)
        .fontColor($r('app.color.text_1'))
        .fontFamily('monospace')
        .maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Row() {
      this.item($r('app.string.upload'), this.upload)
      this.item($r('app.string.download'), this.download)
      this.item($r('app.string.traffic'), this.traffic)
    }
    .width('100%')
    .padding({ top: 18 })
    .border({ width: { top: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline_2') })
  }
}
