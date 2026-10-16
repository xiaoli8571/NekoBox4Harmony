import { UiSpec } from '../UiSpec';

@Component
export struct MiniStatCard {
  label: ResourceStr = '';
  value: ResourceStr = '—';

  build() {
    Column({ space: UiSpec.GAP_SM }) {
      Text(this.label)
        .fontSize(11.5)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
      Text(this.value)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 15, right: 15, top: 13, bottom: 13 })
    .borderRadius(18)
    .backgroundColor($r('app.color.surface'))
    .shadow({ radius: 8, color: $r('app.color.shadow_color'), offsetX: 0, offsetY: 3 })
  }
}
