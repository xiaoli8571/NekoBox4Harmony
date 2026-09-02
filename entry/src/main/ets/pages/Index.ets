import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Profile, AppSettings, profileTypeLabel } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadSettings, LogStore } from '../model/Store';
import { VpnService } from '../core/VpnService';
import { parseShareText } from '../utils/LinkParser';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { fetchSubscriptionWithInfo, fetchSubscription, looksLikeClashYaml, parseClashProxies, ClashParseResult } from '../utils/Subscription';
import { testProfiles, tcpPing } from '../utils/LatencyTester';
import { upsertSub, needAutoUpdate, updateSubscription, setAppContext, subNameOf, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { fetchTrafficTotals, formatSpeed, formatBytes } from '../utils/TrafficStats';
import { fetchCurrentProxyDelay } from '../utils/ClashApi';
import { exportProfileLink } from '../utils/LinkExporter';

@Entry
@Component
struct Index {
  @State profiles: Array<Profile> = [];
  @State selectedId: string = '';
  @State latencies: Record<string, number> = {};
  @State testing: boolean = false;
  @State settings: AppSettings = new AppSettings();
  @StorageLink('vpnRunning') @Watch('onRunningChange') isRunning: boolean = false;
  @StorageLink('vpnStatus') statusText: string = '未连接';
  @StorageLink('vpnUpSpeed') upSpeed: number = 0;
  @StorageLink('vpnDownSpeed') downSpeed: number = 0;
  @StorageLink('vpnTotalUp') totalUp: number = 0;
  @StorageLink('vpnTotalDown') totalDown: number = 0;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private switching: boolean = false;
  private speedTimer: number = -1;
  private speedPollGeneration: number = 0;
  private lastUp: number = 0;
  private lastDown: number = 0;
  private lastTrafficAt: number = 0;

  aboutToAppear(): void {
    setAppContext(this.context);
    this.refresh();
    this.autoUpdateSubs();
  }

  // 从编辑页 router.back() 回来时刷新列表(否则新保存的节点不显示)
  onPageShow(): void {
    this.refresh();
  }

  onRunningChange(): void {
    if (this.isRunning) {
      this.startSpeedPoller();
    } else {
      this.stopSpeedPoller();
    }
    this.refresh();
  }

  private startSpeedPoller(): void {
    this.stopSpeedPoller();
    this.lastUp = 0;
    this.lastDown = 0;
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
    this.speedTimer = setInterval(async () => {
      const t = await fetchTrafficTotals();
      if (t === null) {
        return;
      }
      if (this.lastUp === 0 && this.lastDown === 0) {
        this.lastUp = t.up;
        this.lastDown = t.down;
      }
      AppStorage.setOrCreate('vpnUpSpeed', Math.max(0, t.up - this.lastUp));
      AppStorage.setOrCreate('vpnDownSpeed', Math.max(0, t.down - this.lastDown));
      this.lastUp = t.up;
      this.lastDown = t.down;
      AppStorage.setOrCreate('vpnTotalUp', t.up);
      AppStorage.setOrCreate('vpnTotalDown', t.down);
    }, 1000);
  }

  private stopSpeedPoller(): void {
    if (this.speedTimer >= 0) {
      clearInterval(this.speedTimer);
      this.speedTimer = -1;
    }
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
  }

  modeLabel(): string {
    if (this.settings.mode === 'direct') {
      return '直连';
    }
    if (this.settings.mode === 'global') {
      return '全局';
    }
    return '规则';
  }

  async refresh(): Promise<void> {
    try {
      await initStore(this.context);
      this.profiles = await loadProfiles();
      this.settings = await loadSettings();
      if (this.selectedId.length === 0 && this.profiles.length > 0) {
        this.selectedId = this.profiles[0].id;
      }
    } catch (e) {
      LogStore.addLog(`[ui] 加载节点失败: ${e}`);
    }
  }

  /** 启动时自动更新超过 12 小时的订阅 */
  async autoUpdateSubs(): Promise<void> {
    try {
      await initStore(this.context);
      if (!this.settings.autoUpdateSubs) {
        return;
      }
      const stale = await needAutoUpdate();
      for (const sub of stale) {
        try {
          const r = await updateSubscription(sub.url);
          await markSubSuccess(sub.url);
          LogStore.addLog(`[app] 订阅 ${sub.name} 自动更新:新增 ${r.added},移除 ${r.removed}`);
          this.refresh();
        } catch (e) {
          await markSubFailure(sub.url);
          LogStore.addLog(`[app] 订阅 ${sub.name} 自动更新失败: ${e}`);
        }
      }
    } catch (e) {
      // ignore
    }
  }

  /** 真连接延迟测试(TCP 握手计时) */
  async runSpeedTest(): Promise<void> {
    if (this.testing || this.profiles.length === 0) {
      return;
    }
    this.testing = true;
    this.latencies = {};
    promptAction.showToast({ message: `正在测试 ${this.profiles.length} 个节点…` });
    const snapshot: Array<Profile> = this.profiles;
    await testProfiles(snapshot, (id: string, ms: number) => {
      const next: Record<string, number> = {};
      const keys = Object.keys(this.latencies);
      for (const k of keys) {
        next[k] = this.latencies[k];
      }
      next[id] = ms;
      this.latencies = next;
    });
    this.testing = false;
    promptAction.showToast({ message: '测速完成' });
  }

  latencyText(p: Profile): string {
    const ms = this.latencies[p.id];
    if (this.testing && ms === undefined) {
      return '…';
    }
    if (ms === undefined) {
      return '';
    }
    return ms < 0 ? '超时' : `${ms}ms`;
  }

  latencyColor(p: Profile): string {
    const ms = this.latencies[p.id];
    if (ms === undefined || ms < 0) {
      return ms === -1 ? '#E53935' : '#999999';
    }
    if (ms < 150) {
      return '#2E7D32';
    }
    if (ms < 400) {
      return '#F9A825';
    }
    return '#E53935';
  }

  async connectTo(p: Profile): Promise<void> {
    if (this.isRunning) {
      promptAction.showToast({ message: '请先断开当前连接' });
      return;
    }
    this.selectedId = p.id;
    try {
      await VpnService.connect(this.context, p.id);
    } catch (e) {
      // 状态已在 VpnService 中更新
    }
  }

  async disconnect(): Promise<void> {
    await VpnService.disconnect(this.context);
  }

  /** 点击节点:未运行则选中;运行中点其他节点 = 自动断开重连切换 */
  async onNodeTap(p: Profile): Promise<void> {
    this.selectedId = p.id;
    if (!this.isRunning) {
      return;
    }
    if (this.switching) {
      promptAction.showToast({ message: '正在切换中,请稍候' });
      return;
    }
    const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (runningId.length > 0 && runningId === p.id) {
      return;
    }
    this.switching = true;
    try {
      promptAction.showToast({ message: `正在切换到 ${p.name}…` });
      await VpnService.switchTo(this.context, p.id);
    } finally {
      this.switching = false;
    }
  }

  // ---- 导入弹窗(手动粘贴,不依赖剪贴板权限) ----
  @State importText: string = '';
  private importDialog: CustomDialogController = new CustomDialogController({
    builder: ImportDialog({
      text: $importText,
      onImport: (t: string) => {
        this.doImport(t);
      },
      onPickClipboard: () => {
        this.fillDialogFromClipboard();
      }
    }),
    autoCancel: true
  });

  openImportDialog(): void {
    this.importText = '';
    this.importDialog.open();
  }

  async fillDialogFromClipboard(): Promise<void> {
    const t = await getClipboardText();
    this.importText = t;
    if (t.trim().length === 0) {
      promptAction.showToast({ message: '剪贴板为空,请手动粘贴到输入框' });
    }
  }

  async doImport(raw: string): Promise<void> {
    try {
      const text = raw === undefined || raw === null ? '' : raw;
      if (text.trim().length === 0) {
        promptAction.showToast({ message: '请先粘贴订阅链接或节点链接' });
        return;
      }
      const firstLine = text.trim().split(/[\r\n]+/)[0].trim();
      let parsed: Array<Profile> = [];
      let subUrl = '';
      let subUserinfo = '';
      if (firstLine.startsWith('http://') || firstLine.startsWith('https://')) {
        // 订阅链接:下载内容后解析(服务商返回 Clash YAML 时自动切换解析器)
        promptAction.showToast({ message: '正在获取订阅…' });
        subUrl = firstLine;
        const fetched = await fetchSubscriptionWithInfo(firstLine);
        const content = fetched.content;
        subUserinfo = fetched.userinfo;
        if (looksLikeClashYaml(content)) {
          const r: ClashParseResult = parseClashProxies(content);
          parsed = r.profiles;
          if (parsed.length === 0) {
            promptAction.showToast({
              message: `订阅返回 Clash 格式,但没有可导入的节点(跳过 ${r.skipped} 个不支持的协议)`
            });
            return;
          }
        } else {
          parsed = parseShareText(content);
        }
      } else {
        parsed = parseShareText(text);
      }
      if (parsed.length === 0) {
        promptAction.showToast({ message: '未解析到可识别的节点' });
        return;
      }
      await initStore(this.context);
      const profiles = await loadProfiles();
      for (const p of parsed) {
        p.id = this.genId();
        p.subUrl = subUrl;
        p.updatedAt = Date.now();
        profiles.push(p);
      }
      await saveProfiles(profiles);
      this.profiles = profiles;
      if (subUrl.length > 0) {
        await upsertSub(subUrl, subUserinfo);
        promptAction.showToast({ message: `已导入 ${parsed.length} 个节点(订阅: ${subNameOf(subUrl)})` });
      } else {
        promptAction.showToast({ message: `已导入 ${parsed.length} 个节点` });
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 导入失败: ${msg}`);
      promptAction.showToast({ message: `导入失败: ${msg}` });
    }
  }

  private genId(): string {
    return `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
  }

  sortedProfiles(): Array<Profile> {
    return this.profiles.slice().sort((a: Profile, b: Profile) => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      const aLatency = this.latencies[a.id];
      const bLatency = this.latencies[b.id];
      const aValue = aLatency === undefined || aLatency < 0 ? Number.MAX_SAFE_INTEGER : aLatency;
      const bValue = bLatency === undefined || bLatency < 0 ? Number.MAX_SAFE_INTEGER : bLatency;
      return aValue - bValue;
    });
  }

  sourceHost(p: Profile): string {
    if (p.subUrl.length === 0) {
      return '本地节点';
    }
    try {
      const withoutScheme = p.subUrl.split('://').pop() ?? p.subUrl;
      return withoutScheme.split('/')[0];
    } catch (e) {
      return '订阅节点';
    }
  }

  async togglePinned(p: Profile): Promise<void> {
    p.pinned = !p.pinned;
    await saveProfiles(this.profiles);
    this.profiles = this.profiles.slice();
  }

  async copyProfileLink(p: Profile): Promise<void> {
    const link = exportProfileLink(p);
    if (link.length === 0) {
      promptAction.showToast({ message: '该协议暂不支持导出' });
      return;
    }
    await setClipboardText(link);
    promptAction.showToast({ message: '节点链接已复制' });
  }

  async runUrlTest(p: Profile): Promise<void> {
    if (!this.isRunning) {
      promptAction.showToast({ message: 'URL Test 需要先连接该节点' });
      return;
    }
    const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (runningId !== p.id) {
      promptAction.showToast({ message: 'URL Test 仅支持当前连接节点' });
      return;
    }
    try {
      const delay = await fetchCurrentProxyDelay();
      const next: Record<string, number> = {};
      for (const key of Object.keys(this.latencies)) {
        next[key] = this.latencies[key];
      }
      next[p.id] = delay;
      this.latencies = next;
      promptAction.showToast({ message: `URL Test: ${delay}ms` });
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message });
    }
  }

  deleteProfile(p: Profile): void {
    AlertDialog.show({
      message: `删除节点 "${p.name}"?`,
      primaryButton: {
        value: '取消', action: () => {
        }
      },
      secondaryButton: {
        value: '删除', fontColor: '#E53935', action: () => {
          this.profiles = this.profiles.filter(x => x.id !== p.id);
          saveProfiles(this.profiles);
        }
      }
    });
  }

  @Builder
  profileContextMenu(p: Profile) {
    Column() {
      MenuItem({ content: p.pinned ? '取消置顶' : '置顶' })
        .onClick(() => this.togglePinned(p))
      MenuItem({ content: 'URL Test' })
        .onClick(() => this.runUrlTest(p))
      MenuItem({ content: '复制分享链接' })
        .onClick(() => this.copyProfileLink(p))
      if (p.subUrl.length > 0) {
        MenuItem({ content: '查看订阅' })
          .onClick(() => router.pushUrl({ url: 'pages/SubDetailPage', params: { url: p.subUrl } }))
      }
      MenuItem({ content: '删除', labelInfo: '不可撤销' })
        .onClick(() => this.deleteProfile(p))
    }
  }

  build() {
    Column() {
      // Android NekoBox 风格顶栏与快捷导航
      Row({ space: 4 }) {
        Column({ space: 2 }) {
          Text('NekoBox')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.modeLabel())
            .fontSize(12)
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              router.pushUrl({ url: 'pages/SettingsPage' });
            })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button(this.testing ? '测速中' : '测速')
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.surface_selected'))
          .onClick(() => this.runSpeedTest())
        Button('连接')
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/ConnectionsPage' });
          })
        Button('日志')
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/LogPage' });
          })
        Button('设置')
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.surface'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 12, bottom: 8 })

      // 连接状态卡片
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(this.isRunning ? '●' : '○')
            .fontSize(16)
            .fontColor(this.isRunning ? '#2E7D32' : '#9E9E9E')
          Text(this.statusText)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isRunning ? '#2E7D32' : '#616161')
            .layoutWeight(1)
          Text(this.modeLabel())
            .fontSize(11)
            .fontColor('#1E88E5')
            .backgroundColor('#E3F2FD')
            .borderRadius(10)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        }
        .width('100%')

        if (this.isRunning) {
          Text(`↑ ${formatSpeed(this.upSpeed)}  ↓ ${formatSpeed(this.downSpeed)}   ·   总计 ↑ ${formatBytes(this.totalUp)} ↓ ${formatBytes(this.totalDown)}`)
            .fontSize(11)
            .fontColor('#666666')
            .width('100%')
        }
      }
      .width('calc(100% - 24vp)')
      .margin({ left: 12, right: 12, bottom: 10 })
      .padding(12)
      .borderRadius(12)
      .backgroundColor('#FFFFFF')

      // 节点列表
      List({ space: 8 }) {
        ForEach(this.sortedProfiles(), (p: Profile) => {
          ListItem() {
            Row() {
              Radio({ value: p.id, group: 'profiles' })
                .checked(this.selectedId === p.id)
                .onChange((checked: boolean) => {
                  if (checked) {
                    this.onNodeTap(p);
                  }
                })
              Column() {
                Text(p.name)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${profileTypeLabel(p.type)} · ${p.server}:${p.serverPort}`)
                  .fontSize(12)
                  .fontColor('#888888')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 4 })
              .onClick(() => {
                this.onNodeTap(p);
              })

              if (this.latencies[p.id] !== undefined || this.testing) {
                Text(this.latencyText(p))
                  .fontSize(12)
                  .fontColor(this.latencyColor(p))
                  .margin({ right: 4 })
              }

              Text('✏')
                .fontSize(18)
                .padding(8)
                .onClick(() => {
                  AppStorage.setOrCreate('editProfileId', p.id);
                  router.pushUrl({ url: 'pages/ProfileEdit' });
                })
            }
            .width('100%')
            .padding(12)
            .borderRadius(12)
            .backgroundColor(this.selectedId === p.id ? '#E3F2FD' : '#FFFFFF')
            .bindContextMenu(this.profileContextMenu(p), ResponseType.LongPress)
          }
        }, (p: Profile) => p.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12 })

      // 底部主操作与独立悬浮按钮
      Row({ space: 10 }) {
        Button('导入链接')
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => this.openImportDialog())

        Button(this.isRunning ? '断开连接' : '启动 VPN')
          .layoutWeight(1)
          .height(46)
          .backgroundColor(this.isRunning ? $r('app.color.error') : $r('app.color.primary'))
          .onClick(() => {
            if (this.isRunning) {
              this.disconnect();
            } else {
              const target = this.profiles.find(x => x.id === this.selectedId);
              if (target === undefined) {
                promptAction.showToast({ message: '请先选择或创建一个节点' });
                return;
              }
              this.connectTo(target);
            }
          })

        Button('+')
          .width(52)
          .height(52)
          .fontSize(28)
          .fontColor('#FFFFFF')
          .backgroundColor($r('app.color.primary'))
          .borderRadius(26)
          .shadow({ radius: 8, color: '#40000000', offsetX: 0, offsetY: 3 })
          .onClick(() => {
            AppStorage.setOrCreate('editProfileId', '');
            router.pushUrl({ url: 'pages/ProfileEdit' });
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 10, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}

/** 导入弹窗:手动粘贴订阅链接 / 节点链接 / base64 订阅内容 */
@CustomDialog
struct ImportDialog {
  controller?: CustomDialogController;
  @Link text: string;
  onImport: (t: string) => void = (t: string) => {
  };
  onPickClipboard: () => void = () => {
  };

  build() {
    Column({ space: 10 }) {
      Text('导入链接 / 订阅')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
      TextArea({
        text: this.text,
        placeholder: '粘贴订阅链接(http…)、节点链接(vless:// 等)或 base64 订阅内容'
      })
        .height(120)
        .onChange((v: string) => {
          this.text = v;
        })
      Row({ space: 8 }) {
        Button('取消')
          .backgroundColor('#F5F5F5')
          .fontColor('#333333')
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Blank()
        Button('从剪贴板读取')
          .backgroundColor('#F5F5F5')
          .fontColor('#333333')
          .onClick(() => this.onPickClipboard())
        Button('导入')
          .backgroundColor('#1E88E5')
          .onClick(() => {
            const t = this.text;
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onImport(t);
          })
      }
      .width('100%')
    }
    .padding(16)
    .width('100%')
  }
}
