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
    .borderRadius(UiSpec.GLASS_RADIUS)
    .backgroundColor($r('app.color.bg_glass'))
    .border({
      width: UiSpec.GLASS_BORDER_WIDTH,
      color: $r('app.color.border_glass')
    })
    .shadow({
      radius: UiSpec.GLASS_SHADOW_RADIUS,
      color: $r('app.color.sel_glow'),
      offsetX: 0,
      offsetY: UiSpec.GLASS_SHADOW_OFFSET
    })
  }
}
