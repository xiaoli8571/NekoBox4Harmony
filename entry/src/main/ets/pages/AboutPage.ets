import router from '@ohos.router';
import { APP_VERSION_LABEL } from '../common/AppVersion';

@Entry
@Component
struct AboutPage {
  build(): void {
    Column({ space: 14 }) {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text('关于').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
      }.width('100%').padding(12)
      Text('NekBox for Harmony').fontSize(24).fontWeight(FontWeight.Bold)
      Text('sing-box VPN client').fontSize(14).fontColor('#666666')
      Text(APP_VERSION_LABEL).fontSize(13).fontColor('#1E88E5')
      Text('HarmonyOS NEXT · API 24+').fontSize(13).fontColor('#666666')
      Text('VPN 扩展在进程内加载 c-shared 内核。').fontSize(13).fontColor('#555555')
    }.width('100%').height('100%').padding(12).backgroundColor('#F2F4F7')
  }
}
