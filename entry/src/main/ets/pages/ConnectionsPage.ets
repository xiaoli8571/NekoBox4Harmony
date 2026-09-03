import http from '@ohos.net.http';
import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { formatBytes, formatSpeed } from '../utils/TrafficStats';
import { AppSettings } from '../model/Profile';
import { initStore, loadSettings } from '../model/Store';

interface ConnItem {
  id: string;
  host: string;
  network: string;
  chains: string;
  rule: string;
  up: number;
  down: number;
}

interface ConnectionsResponse {
  uploadTotal: number;
  downloadTotal: number;
  connections: Array<Record<string, Object>>;
}

async function apiCall(settings: AppSettings, method: string, path: string): Promise<string> {
  const client = http.createHttp();
  try {
    const headers: Record<string, string> = {};
    if (settings.clashApiSecret.length > 0) {
      headers['Authorization'] = `Bearer ${settings.clashApiSecret}`;
    }
    const resp = await client.request(`http://127.0.0.1:${settings.clashApiPort}${path}`, {
      method: method === 'DELETE' ? http.RequestMethod.DELETE : http.RequestMethod.GET,
      header: headers,
      connectTimeout: 1500,
      readTimeout: 1500,
      expectDataType: http.HttpDataType.STRING
    });
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    return `${resp.result}`;
  } finally {
    client.destroy();
  }
}

function parseConnections(raw: string): Array<ConnItem> {
  const out: Array<ConnItem> = [];
  try {
    const obj = JSON.parse(raw) as ConnectionsResponse;
    if (obj.connections === undefined || obj.connections === null) {
      return out;
    }
    for (const c of obj.connections) {
      const meta = c['metadata'] as Record<string, Object>;
      const chains = c['chains'] as Array<string>;
      const item: ConnItem = {
        id: `${c['id']}`,
        host: `${meta['host']}`.length > 0 ? `${meta['host']}` : `${meta['destinationIP']}`,
        network: `${meta['network']}`,
        chains: Array.isArray(chains) ? chains.slice().reverse().join('→') : '',
        rule: `${c['rule']}` + (`${c['rulePayload']}`.length > 0 ? `(${c['rulePayload']})` : ''),
        up: Number(c['upload']),
        down: Number(c['download'])
      };
      out.push(item);
    }
  } catch (e) {
    // ignore
  }
  return out;
}

@Entry
@Component
struct ConnectionsPage {
  @State conns: Array<ConnItem> = [];
  @State lastError: ResourceStr = '';
  @State loading: boolean = true;
  @State uploadTotal: number = 0;
  @State downloadTotal: number = 0;
  @State uploadSpeed: number = 0;
  @State downloadSpeed: number = 0;
  @State settings: AppSettings = new AppSettings();
  @StorageLink('vpnRunning') @Watch('onRunningChange') isRunning: boolean = false;
  @StorageLink('vpnUpSpeed') fallbackUpSpeed: number = 0;
  @StorageLink('vpnDownSpeed') fallbackDownSpeed: number = 0;
  @StorageLink('vpnTotalUp') fallbackTotalUp: number = 0;
  @StorageLink('vpnTotalDown') fallbackTotalDown: number = 0;
  private timer: number = -1;
  private lastUpload: number = 0;
  private lastDownload: number = 0;

  async aboutToAppear(): Promise<void> {
    await initStore(getContext(this) as common.UIAbilityContext);
    this.settings = await loadSettings();
    this.updatePolling();
  }

  aboutToDisappear(): void {
    this.stopPolling();
  }

  onRunningChange(): void {
    this.updatePolling();
  }

  private updatePolling(): void {
    this.stopPolling();
    if (!this.isRunning || !this.settings.clashApiEnabled) {
      this.loading = false;
      this.conns = [];
      return;
    }
    this.loading = true;
    this.refresh();
    this.timer = setInterval(() => this.refresh(), 1000);
  }

  private stopPolling(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  async refresh(): Promise<void> {
    if (!this.isRunning || !this.settings.clashApiEnabled) {
      return;
    }
    try {
      const raw = await apiCall(this.settings, 'GET', '/connections');
      const response = JSON.parse(raw) as ConnectionsResponse;
      const upload = Number(response.uploadTotal);
      const download = Number(response.downloadTotal);
      this.uploadSpeed = this.lastUpload > 0 ? Math.max(0, upload - this.lastUpload) : 0;
      this.downloadSpeed = this.lastDownload > 0 ? Math.max(0, download - this.lastDownload) : 0;
      this.lastUpload = upload;
      this.lastDownload = download;
      this.uploadTotal = upload;
      this.downloadTotal = download;
      this.conns = parseConnections(raw);
      this.lastError = '';
    } catch (e) {
      this.lastError = $r('app.string.connections_api_unavailable');
      this.uploadSpeed = this.fallbackUpSpeed;
      this.downloadSpeed = this.fallbackDownSpeed;
      this.uploadTotal = this.fallbackTotalUp;
      this.downloadTotal = this.fallbackTotalDown;
    } finally {
      this.loading = false;
    }
  }

  async closeConn(item: ConnItem): Promise<void> {
    try {
      await apiCall(this.settings, 'DELETE', `/connections/${encodeURIComponent(item.id)}`);
      promptAction.showToast({ message: $r('app.string.connection_closed') });
      this.refresh();
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.connection_close_failed', `${e}`) });
    }
  }

  build() {
    Column() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text($r('app.string.connections_title_count', this.conns.length)).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text($r('app.string.refresh')).fontSize(14).fontColor($r('app.color.primary')).padding(8)
          .onClick(() => this.refresh())
      }
      .width('100%').padding(12)

      if (this.isRunning) {
        Text($r('app.string.traffic_speed_total', formatSpeed(this.uploadSpeed), formatSpeed(this.downloadSpeed), formatBytes(this.uploadTotal), formatBytes(this.downloadTotal)))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 10 })
      }

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.primary'))
          Text($r('app.string.connections_loading'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      } else if (this.lastError !== '') {
        Column({ space: 8 }) {
          Text($r('app.string.connections_unavailable'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.lastError)
            .fontSize(13)
            .fontColor($r('app.color.error'))
          Button($r('app.string.reload'))
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => {
              this.loading = true;
              this.refresh();
            })
        }
        .width('100%')
        .padding({ top: 28, bottom: 20 })
      } else if (this.conns.length === 0) {
        Column({ space: 8 }) {
          Text($r('app.string.connections_empty'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.connections_empty_hint'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      }

      List({ space: 6 }) {
        ForEach(this.conns, (c: ConnItem) => {
          ListItem() {
            Column({ space: 2 }) {
              Row() {
                Text(c.host)
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(`${c.network}`)
                  .fontSize(11).fontColor($r('app.color.primary'))
              }.width('100%')

              Text(`${c.rule}  ${c.chains}`)
                .fontSize(11).fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              Row() {
                Text(`↑ ${formatBytes(c.up)}  ↓ ${formatBytes(c.down)}`)
                  .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                Text($r('app.string.notification_disconnect'))
                  .fontSize(12).fontColor($r('app.color.error'))
                  .onClick(() => this.closeConn(c))
              }.width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(10)
            .borderRadius(8)
            .backgroundColor($r('app.color.surface'))
          }
        }, (c: ConnItem) => c.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
      .scrollBar(BarState.On)
    }
    .width('100%')
    .height('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.app_background'))
    .width('100%').height('100%').backgroundColor($r('app.color.app_background'))
  }
}
