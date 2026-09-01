import http from '@ohos.net.http';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
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
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text(`连接 (${this.conns.length})`).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text('刷新').fontSize(14).fontColor('#1E88E5').padding(8)
          .onClick(() => this.refresh())
      }
      .width('100%').padding(12)

      if (this.lastError.length > 0) {
        Text(this.lastError).fontSize(13).fontColor('#E53935').padding(12)
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
                  .fontSize(11).fontColor('#1E88E5')
              }.width('100%')

              Text(`${c.rule}  ${c.chains}`)
                .fontSize(11).fontColor('#888888')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              Row() {
                Text(`↑ ${formatBytes(c.up)}  ↓ ${formatBytes(c.down)}`)
                  .fontSize(11).fontColor('#666666').layoutWeight(1)
                Text('断开')
                  .fontSize(12).fontColor('#E53935')
                  .onClick(() => this.closeConn(c))
              }.width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(10)
            .borderRadius(8)
            .backgroundColor('#FFFFFF')
          }
        }, (c: ConnItem) => c.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12 })
      .scrollBar(BarState.On)
    }
    .width('100%').height('100%').backgroundColor('#F2F4F7')
  }
}
