import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { fetchTrafficTotals, formatBytes, formatSpeed } from '../utils/TrafficStats';
import { currentLanguage, isEnglish, t } from '../utils/I18n';

/** Read-only traffic centre.  It follows the same AppStorage counters as the
 * home status card and refreshes the Clash API while this page is visible. */
@Entry
@Component
struct TrafficPage {
  @StorageLink('vpnRunning') running: boolean = false;
  @StorageLink('vpnStatus') status: string = '未连接';
  @StorageLink('vpnUpSpeed') upSpeed: number = 0;
  @StorageLink('vpnDownSpeed') downSpeed: number = 0;
  @StorageLink('vpnTotalUp') totalUp: number = 0;
  @StorageLink('vpnTotalDown') totalDown: number = 0;
  @StorageLink('vpnConnectedAt') connectedAt: number = 0;
  @State lastRefresh: number = 0;
  @State apiAvailable: boolean = false;
  private timer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.timer = setInterval(() => {
      this.refresh();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private async refresh(): Promise<void> {
    // When the VPN is down, the extension/EntryAbility owns the zeroing of
    // counters.  Do not write zeros here merely because the API is absent.
    if (!this.running) {
      this.apiAvailable = false;
      this.lastRefresh = Date.now();
      return;
    }
    const totals = await fetchTrafficTotals();
    this.apiAvailable = totals !== null;
    if (totals !== null) {
      AppStorage.setOrCreate('vpnTotalUp', Math.max(0, totals.up));
      AppStorage.setOrCreate('vpnTotalDown', Math.max(0, totals.down));
    }
    this.lastRefresh = Date.now();
  }

  private durationText(): string {
    if (!this.running || this.connectedAt <= 0) {
      return '00:00:00';
    }
    const seconds = Math.max(0, Math.floor((Date.now() - this.connectedAt) / 1000));
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = seconds % 60;
    const hh = hours < 10 ? `0${hours}` : `${hours}`;
    const mm = minutes < 10 ? `0${minutes}` : `${minutes}`;
    const ss = secs < 10 ? `0${secs}` : `${secs}`;
    return `${hh}:${mm}:${ss}`;
  }

  private showApiHint(): void {
    const lang = currentLanguage();
    promptAction.showToast({
      message: this.apiAvailable
        ? (isEnglish(lang) ? 'Clash API connected' : '内核流量接口已连接')
        : (isEnglish(lang) ? 'VPN is not running or API is unavailable' : 'VPN 未运行或内核接口暂不可用')
    });
  }

  // build() 顶层只允许组件树(不允许变量声明),语言状态用方法取。
  private en(): boolean {
    return isEnglish(currentLanguage());
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text(t('traffic')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text(t('refresh')).fontSize(14).fontColor('#1E88E5').padding(8)
          .onClick(() => this.refresh())
      }.width('100%').padding(12)

      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text(this.en() ? 'Upload speed' : '上传速度').fontSize(12).fontColor('#666666')
              Text(formatSpeed(Math.max(0, this.upSpeed))).fontSize(20).fontWeight(FontWeight.Bold)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Column({ space: 4 }) {
              Text(this.en() ? 'Download speed' : '下载速度').fontSize(12).fontColor('#666666')
              Text(formatSpeed(Math.max(0, this.downSpeed))).fontSize(20).fontWeight(FontWeight.Bold)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%').padding(14).borderRadius(12).backgroundColor('#FFFFFF')

          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text(this.en() ? 'Uploaded' : '累计上传').fontSize(12).fontColor('#666666')
              Text(formatBytes(Math.max(0, this.totalUp))).fontSize(18).fontWeight(FontWeight.Medium)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Column({ space: 4 }) {
              Text(this.en() ? 'Downloaded' : '累计下载').fontSize(12).fontColor('#666666')
              Text(formatBytes(Math.max(0, this.totalDown))).fontSize(18).fontWeight(FontWeight.Medium)
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%').padding(14).borderRadius(12).backgroundColor('#FFFFFF')

          Column({ space: 8 }) {
            Row() {
              Text(this.en() ? 'Connection' : '连接状态').fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1)
              Text(this.running ? (this.en() ? 'Connected' : '已连接') : (this.en() ? 'Disconnected' : '未连接'))
                .fontSize(13).fontColor(this.running ? '#2E7D32' : '#888888')
            }.width('100%')
            Text(this.status).fontSize(12).fontColor('#666666').width('100%').maxLines(2)
            Row() {
              Text(this.en() ? 'Session duration' : '本次运行时长').fontSize(12).fontColor('#666666').layoutWeight(1)
              Text(this.durationText()).fontSize(14).fontFamily('monospace')
            }.width('100%')
          }.width('100%').padding(14).borderRadius(12).backgroundColor('#FFFFFF')

          Row() {
            Text(this.apiAvailable
              ? (this.en() ? 'Clash API · live' : 'Clash API · 实时')
              : (this.en() ? 'Clash API · unavailable' : 'Clash API · 不可用'))
              .fontSize(12).fontColor(this.apiAvailable ? '#2E7D32' : '#999999').layoutWeight(1)
            Text('ⓘ').fontSize(16).fontColor('#1E88E5').onClick(() => this.showApiHint())
          }.width('100%').padding({ left: 14, right: 14, top: 10, bottom: 10 })
        }.width('100%').padding(12)
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#F2F4F7')
  }
}

