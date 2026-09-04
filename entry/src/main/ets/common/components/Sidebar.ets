import { UiSpec } from '../UiSpec';

export type SidebarDestination = 'home' | 'proxy' | 'subscriptions' | 'rules' | 'settings';

@Component
export struct Sidebar {
  @Prop panelWidth: number = 150;
  @Prop active: SidebarDestination = 'home';
  onSelect: (destination: SidebarDestination) => void = (destination: SidebarDestination) => {};

  @Builder
  private destination(id: SidebarDestination, icon: string, label: ResourceStr) {
    Row({ space: UiSpec.GAP_SM }) {
      Text(icon)
        .fontSize(17)
        .fontColor(this.active === id ? $r('app.color.primary') : $r('app.color.text_secondary'))
        .width(24)
        .textAlign(TextAlign.Center)
      Text(label)
        .fontSize(12.5)
        .fontWeight(this.active === id ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.active === id ? $r('app.color.primary') : $r('app.color.text_secondary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(44)
    .padding({ left: UiSpec.GAP_SM, right: UiSpec.GAP_SM })
    .borderRadius(11)
    .backgroundColor(this.active === id ? $r('app.color.surface_selected') : $r('app.color.bg_glass_solid'))
    .hoverEffect(HoverEffect.Scale)
    .onClick(() => this.onSelect(id))
  }

  build() {
    Column({ space: UiSpec.GAP_SM }) {
      Text('NekoBox')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .margin({ bottom: UiSpec.GAP_MD })

      this.destination('home', '⌂', $r('app.string.app_name'))
      this.destination('proxy', '◈', $r('app.string.proxy'))
      this.destination('subscriptions', '◎', $r('app.string.subscriptions'))
      this.destination('rules', '◇', $r('app.string.route_rules_title'))
      this.destination('settings', '⚙', $r('app.string.settings_title'))
      Blank()
    }
    .width(this.panelWidth)
    .height('100%')
    .padding(UiSpec.PAGE_PADDING)
    .backgroundColor($r('app.color.bg_glass'))
    .border({
      width: { right: UiSpec.GLASS_BORDER_WIDTH },
      color: $r('app.color.border_glass')
    })
  }
}
