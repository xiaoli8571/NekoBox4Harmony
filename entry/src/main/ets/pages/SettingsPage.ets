import { SettingsView } from '../views/SettingsView';

/** 设置页路由壳:仅承载 pages/SettingsPage 路由,完整设置逻辑在 views/SettingsView。 */
@Entry
@Component
struct SettingsPage {
  build() {
    Column() {
      SettingsView()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}
