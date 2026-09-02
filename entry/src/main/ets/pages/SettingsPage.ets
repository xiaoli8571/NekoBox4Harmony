import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import pasteboard from '@ohos.pasteboard';
import { AppSettings } from '../model/Profile';
import { initStore, loadSettings, saveSettings, LogStore } from '../model/Store';
import { SubInfo, listSubs, updateSubscription, removeSub, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { formatBytes } from '../utils/TrafficStats';
import { exportBackup, importBackup } from '../core/Backup';
import { getClipboardText } from '../utils/ClipboardHelper';
import { geoReady, downloadGeoAssets } from '../utils/GeoAssets';

const APP_MODES: Array<string> = ['off', 'exclude', 'include'];
const APP_MODE_LABELS: Array<string> = ['关闭', '排除模式', '仅这些走代理'];

const STACKS: Array<string> = ['system'];
const MODES: Array<string> = ['rule', 'global', 'direct'];
const MODE_LABELS: Array<string> = ['规则', '全局', '直连'];

@Entry
@Component
struct SettingsPage {
  @State s: AppSettings = new AppSettings();
  @State subs: Array<SubInfo> = [];
  @State updatingUrl: string = '';
  @State geoOk: boolean = false;
  @State geoLoading: boolean = false;
  @State loading: boolean = true;
  @State loadError: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      await initStore(this.context);
      this.s = await loadSettings();
      this.subs = await listSubs();
      this.geoOk = geoReady(this.context);
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  async downloadGeo(): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    promptAction.showToast({ message: '正在下载 Geo 数据(约 1MB,多源尝试)…' });
    try {
      await downloadGeoAssets(this.context);
      this.geoOk = geoReady(this.context);
      promptAction.showToast({ message: 'Geo 数据下载完成,重连后启用 cn 直连分流' });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `下载失败: ${msg}` });
    } finally {
      this.geoLoading = false;
    }
  }

  modeIndex(): number {
    const i = MODES.indexOf(this.s.mode);
    return i < 0 ? 0 : i;
  }

  async save(quiet: boolean = false): Promise<void> {
    try {
      await saveSettings(this.s);
      if (!quiet) {
        promptAction.showToast({ message: '已保存,重连 VPN 后生效' });
      }
    } catch (e) {
      promptAction.showToast({ message: `保存失败: ${e}` });
    }
  }

  async updateOne(sub: SubInfo): Promise<void> {
    if (this.updatingUrl.length > 0) {
      return;
    }
    this.updatingUrl = sub.url;
    promptAction.showToast({ message: '正在更新订阅…' });
    try {
      const r = await updateSubscription(sub.url);
      await markSubSuccess(sub.url);
      promptAction.showToast({ message: `订阅已更新:新增 ${r.added},移除 ${r.removed}` });
      this.subs = await listSubs();
    } catch (e) {
      await markSubFailure(sub.url);
      this.subs = await listSubs();
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `更新失败: ${msg}` });
    } finally {
      this.updatingUrl = '';
    }
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => {
          this.save(true);
          router.back();
        }).padding(8)
        Text('设置').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('保存').height(34).onClick(() => this.save())
      }
      .width('100%').padding(12)

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.primary'))
          Text('正在加载设置…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      } else if (this.loadError.length > 0) {
        Column({ space: 8 }) {
          Text('设置加载失败')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.loadError)
            .fontSize(13)
            .fontColor($r('app.color.error'))
          Button('重新加载')
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => this.load())
        }
        .width('100%')
        .padding({ top: 28, bottom: 20 })
      }

      Scroll() {
        Column({ space: 14 }) {
          // 出站模式
          Column() {
            Text('出站模式').fontSize(13).fontColor('#666').width('100%')
            Row({ space: 8 }) {
              ForEach(MODES, (m: string, idx: number) => {
                Button(MODE_LABELS[idx])
                  .backgroundColor(this.s.mode === m ? '#1E88E5' : '#F5F5F5')
                  .fontColor(this.s.mode === m ? '#FFFFFF' : '#333333')
                  .onClick(() => {
                    this.s.mode = m;
                    this.save(true);
                    promptAction.showToast({ message: `已切换为${MODE_LABELS[idx]}模式,重连后生效` });
                  })
              }, (m: string) => m)
            }.width('100%')
            Text(this.s.mode === 'direct' ? '所有流量直连(不走代理)'
              : this.s.mode === 'global' ? '所有流量走代理' : '私网与自定义列表直连,其余走代理')
              .fontSize(11).fontColor('#999').width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Row() {
            Column() {
              Text('自定义路由规则').fontSize(14)
              Text('按域名、IP、端口指定代理、直连或拒绝').fontSize(11).fontColor('#999')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text('进入 ›').fontSize(14).fontColor('#1E88E5')
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .onClick(() => router.pushUrl({ url: 'pages/RouteRulesPage' }))

          if (this.s.mode === 'rule') {
            Column() {
              Text('直连域名后缀(逗号分隔)').fontSize(13).fontColor('#666').width('100%')
              TextInput({ text: this.s.directDomains, placeholder: 'baidu.com,qq.com,163.com' })
                .width('100%').height(40)
                .onChange((v: string) => { this.s.directDomains = v; })
              Text('直连 IP 段(逗号分隔 CIDR)').fontSize(13).fontColor('#666').width('100%')
                .margin({ top: 6 })
              TextInput({ text: this.s.directIpCidrs, placeholder: '114.114.114.114/32' })
                .width('100%').height(40)
                .onChange((v: string) => { this.s.directIpCidrs = v; })
              Row({ space: 8 }) {
                Text(this.geoOk ? '✓ Geo 数据已就绪(cn 直连分流已启用)'
                  : '未下载 Geo 数据(cn 分流不可用)')
                  .fontSize(12).fontColor(this.geoOk ? '#2E7D32' : '#999').layoutWeight(1)
                Button(this.geoLoading ? '下载中…' : (this.geoOk ? '重新下载' : '下载数据'))
                  .height(30)
                  .backgroundColor(this.geoLoading ? '#BBBBBB' : '#1E88E5')
                  .onClick(() => this.downloadGeo())
              }.width('100%').margin({ top: 6 })
            }.alignItems(HorizontalAlign.Start).width('100%')
          }

          Blank().height(2)

          // 订阅
          Column({ space: 8 }) {
            Text('订阅').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            if (this.subs.length === 0) {
              Text('暂无订阅。在主页「导入链接」粘贴订阅地址后会自动记录到这里。')
                .fontSize(12).fontColor('#999').width('100%')
            }
            ForEach(this.subs, (sub: SubInfo) => {
              Row() {
                Column() {
                  Text(sub.name).fontSize(14).maxLines(1)
                  Text(sub.lastUpdate === 0 ? '从未更新'
                    : `更新于 ${new Date(sub.lastUpdate).toLocaleString()}`)
                    .fontSize(11).fontColor('#999')
                  if (sub.total > 0) {
                    Text(`已用 ${formatBytes(sub.upload + sub.download)} / ${formatBytes(sub.total)}`)
                      .fontSize(11).fontColor(sub.upload + sub.download > sub.total ? '#E53935' : '#2E7D32')
                  }
                  if (sub.expire > 0) {
                    Text(`到期: ${new Date(sub.expire * 1000).toLocaleDateString()}`)
                      .fontSize(11).fontColor('#999')
                  }
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)

                Button('更新')
                  .height(30)
                  .backgroundColor(this.updatingUrl === sub.url ? '#BBBBBB' : '#1E88E5')
                  .onClick(() => this.updateOne(sub))
                Text('删除').fontSize(13).fontColor('#E53935').padding(6)
                  .onClick(() => {
                    removeSub(sub.url);
                    this.subs = this.subs.filter(x => x.url !== sub.url);
                  })
              }.width('100%')
            }, (sub: SubInfo) => sub.url)

            Row() {
              Text('启动时自动更新订阅').fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.s.autoUpdateSubs })
                .onChange((v: boolean) => {
                  this.s.autoUpdateSubs = v;
                  this.save(true);
                })
            }.width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          Column() {
            Text('TUN MTU').fontSize(13).fontColor('#666').width('100%')
            TextInput({ text: `${this.s.mtu}`, placeholder: '9000' })
              .type(InputType.Number).width('100%').height(40)
              .onChange((v: string) => {
                const n = parseInt(v);
                this.s.mtu = isNaN(n) ? 9000 : n;
              })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text('TUN 协议栈').fontSize(13).fontColor('#666').width('100%')
            Select(STACKS.map((t: string) => ({ value: t } as SelectOption)))
              .selected(STACKS.indexOf(this.s.stack) < 0 ? 0 : STACKS.indexOf(this.s.stack))
              .value(this.s.stack)
              .onSelect((index: number) => { this.s.stack = STACKS[index]; })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text('远程 DNS (经代理, 防泄漏)').fontSize(13).fontColor('#666').width('100%')
            TextInput({ text: this.s.remoteDns })
              .width('100%').height(40)
              .onChange((v: string) => { this.s.remoteDns = v; })
            Text('远程 DNS 的主机部分必须是 IP(如 https://8.8.8.8/dns-query),避免启动时引导解析')
              .fontSize(11).fontColor('#999').width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Column() {
            Text('直连 DNS (用于解析代理服务器域名)').fontSize(13).fontColor('#666').width('100%')
            TextInput({ text: this.s.directDns })
              .width('100%').height(40)
              .onChange((v: string) => { this.s.directDns = v; })
          }.alignItems(HorizontalAlign.Start).width('100%')

          Row() {
            Text('启用 IPv6').fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.ipv6 })
              .onChange((v: boolean) => { this.s.ipv6 = v; })
          }.width('100%')

          Blank().height(2)

          // 分应用代理
          Column({ space: 8 }) {
            Text('分应用代理').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            Row({ space: 8 }) {
              ForEach(APP_MODES, (m: string, idx: number) => {
                Button(APP_MODE_LABELS[idx])
                  .backgroundColor(this.s.perAppMode === m ? '#1E88E5' : '#F5F5F5')
                  .fontColor(this.s.perAppMode === m ? '#FFFFFF' : '#333333')
                  .onClick(() => {
                    this.s.perAppMode = m;
                    this.save(true);
                  })
              }, (m: string) => m)
            }.width('100%')
            if (this.s.perAppMode !== 'off') {
              TextInput({
                text: this.s.perAppList,
                placeholder: this.s.perAppMode === 'exclude'
                  ? '不走 VPN 的应用包名,逗号分隔'
                  : '仅走 VPN 的应用包名,逗号分隔'
              })
                .width('100%').height(40)
                .onChange((v: string) => { this.s.perAppList = v; })
              Text('示例: com.huawei.hmos.browser。包名可在应用详情/日志中查看,重连生效。')
                .fontSize(11).fontColor('#999').width('100%')
            }
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          // 备份与恢复
          Column({ space: 8 }) {
            Text('备份与恢复').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
            Row({ space: 8 }) {
              Button('备份到剪贴板')
                .backgroundColor('#F5F5F5')
                .fontColor('#333333')
                .onClick(async () => {
                  try {
                    const data = await exportBackup(this.context);
                    const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, data);
                    await pasteboard.getSystemPasteboard().setData(pasteData);
                    promptAction.showToast({ message: '备份已复制到剪贴板' });
                  } catch (e) {
                    promptAction.showToast({ message: `备份失败: ${e}` });
                  }
                })
              Button('从剪贴板恢复')
                .backgroundColor('#F5F5F5')
                .fontColor('#333333')
                .onClick(async () => {
                  try {
                    const text = await getClipboardText();
                    if (text.trim().length === 0) {
                      promptAction.showToast({ message: '剪贴板为空' });
                      return;
                    }
                    const msg = await importBackup(this.context, text.trim());
                    this.s = await loadSettings();
                    promptAction.showToast({ message: msg });
                  } catch (e) {
                    const msg = e instanceof Error ? e.message : `${e}`;
                    promptAction.showToast({ message: `恢复失败: ${msg}` });
                  }
                })
            }.width('100%')
            Text('备份包含全部节点与设置(不含订阅列表),以 JSON 存于剪贴板,可自行保存。')
              .fontSize(11).fontColor('#999').width('100%')
          }.alignItems(HorizontalAlign.Start).width('100%')

          Blank().height(2)

          Row() {
            Column() {
              Text('全局放行不安全 TLS').fontSize(14)
              Text('调试自签证书节点时使用').fontSize(11).fontColor('#999')
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.s.allowInsecureAll })
              .onChange((v: boolean) => { this.s.allowInsecureAll = v; })
          }.width('100%')

          Text('注意:修改设置后需重新连接 VPN 才会生效。')
            .fontSize(12).fontColor('#E53935').width('100%')
        }
        .width('100%')
        .padding(12)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%').height('100%').backgroundColor('#F2F4F7')
  }
}
