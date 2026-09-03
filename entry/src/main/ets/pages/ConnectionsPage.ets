import http from '@ohos.net.http';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { formatBytes } from '../utils/TrafficStats';
import { CLASH_API_PORT } from '../utils/TrafficStats';

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

async function apiCall(method: string, path: string): Promise<string> {
  const client = http.createHttp();
  try {
    const resp = await client.request(`http://127.0.0.1:${CLASH_API_PORT}${path}`, {
      method: method === 'DELETE' ? http.RequestMethod.DELETE : http.RequestMethod.GET,
      connectTimeout: 1500,
      readTimeout: 1500,
      expectDataType: http.HttpDataType.STRING
    });
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
  @State lastError: string = '';
  @State loading: boolean = true;
  private timer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.timer = setInterval(() => {
      this.refresh();
    }, 2000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  async refresh(): Promise<void> {
    try {
      const raw = await apiCall('GET', '/connections');
      this.conns = parseConnections(raw);
      this.lastError = '';
    } catch (e) {
      this.lastError = '无法连接内核 API(VPN 未运行?)';
    } finally {
      this.loading = false;
    }
  }

  async closeConn(item: ConnItem): Promise<void> {
    try {
      await apiCall('DELETE', `/connections/${item.id}`);
      promptAction.showToast({ message: '已断开该连接' });
      this.refresh();
    } catch (e) {
      promptAction.showToast({ message: `关闭失败: ${e}` });
    }
  }

  build() {
    Column() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text(`连接 (${this.conns.length})`).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text('刷新').fontSize(14).fontColor($r('app.color.primary')).padding(8)
          .onClick(() => this.refresh())
      }
      .width('100%').padding(12)

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.primary'))
          Text('正在加载连接…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      } else if (this.lastError.length > 0) {
        Column({ space: 8 }) {
          Text('连接信息暂不可用')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.lastError)
            .fontSize(13)
            .fontColor($r('app.color.error'))
          Button('重新加载')
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
          Text('暂无活动连接')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('启动 VPN 并访问网络后，连接会显示在这里。')
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
                Text('断开')
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
