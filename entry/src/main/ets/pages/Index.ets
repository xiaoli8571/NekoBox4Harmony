import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { Profile, AppSettings, profileTypeLabel } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, saveGroups, loadSettings, LogStore } from '../model/Store';
import { ProfileGroup, LOCAL_GROUP_ID } from '../model/Group';
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
  @State groups: Array<ProfileGroup> = [];
  @State selectedId: string = '';
  @State editingGroupId: string = '';
  @State editingGroupName: string = '';
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
      this.groups = await loadGroups(this.profiles);
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
      liquidGlass: this.settings.liquidGlass,
      tactileInteraction: this.settings.tactileInteraction,
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

  sortedGroups(): Array<ProfileGroup> {
    return this.groups.slice().sort((a: ProfileGroup, b: ProfileGroup) => a.sortOrder - b.sortOrder);
  }

  profilesInGroup(groupId: string): Array<Profile> {
    return this.profiles.filter((p: Profile) => p.groupId === groupId).sort((a: Profile, b: Profile) => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      return a.sortOrder - b.sortOrder;
    });
  }

  async toggleGroup(group: ProfileGroup): Promise<void> {
    group.expanded = !group.expanded;
    group.updatedAt = Date.now();
    await saveGroups(this.groups);
    this.groups = this.groups.slice();
  }

  async moveGroup(group: ProfileGroup, offset: number): Promise<void> {
    const ordered = this.sortedGroups();
    const current = ordered.findIndex((item: ProfileGroup) => item.id === group.id);
    const target = current + offset;
    if (current < 0 || target < 0 || target >= ordered.length) {
      return;
    }
    const swap = ordered[target];
    ordered[target] = group;
    ordered[current] = swap;
    for (let i = 0; i < ordered.length; i++) {
      ordered[i].sortOrder = i;
      ordered[i].updatedAt = Date.now();
    }
    this.groups = ordered;
    await saveGroups(ordered);
  }

  sortedProfiles(): Array<Profile> {
    const result: Array<Profile> = [];
    for (const group of this.sortedGroups()) {
      if (group.expanded) {
        result.push(...this.profilesInGroup(group.id));
      }
    }
    return result;
  }

  beginRenameGroup(group: ProfileGroup): void {
    this.editingGroupId = group.id;
    this.editingGroupName = group.name;
  }

  async saveGroupName(group: ProfileGroup): Promise<void> {
    const name = this.editingGroupName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '分组名称不能为空' });
      return;
    }
    group.name = name;
    group.updatedAt = Date.now();
    await saveGroups(this.groups);
    this.groups = this.groups.slice();
    this.editingGroupId = '';
    this.editingGroupName = '';
  }

  confirmDeleteGroup(group: ProfileGroup): void {
    const nodes = this.profilesInGroup(group.id);
    const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (nodes.find((profile: Profile) => profile.id === runningId) !== undefined) {
      promptAction.showToast({ message: '分组包含正在运行的节点，请先断开 VPN' });
      return;
    }
    AlertDialog.show({
      message: `删除分组“${group.name}”及其 ${nodes.length} 个节点?`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: '#E53935',
        action: async () => {
          this.profiles = this.profiles.filter((profile: Profile) => profile.groupId !== group.id);
          this.groups = this.groups.filter((item: ProfileGroup) => item.id !== group.id);
          await saveProfiles(this.profiles);
          await saveGroups(this.groups);
        }
      }
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
      const message = p.type === 'wireguard'
        ? 'WireGuard 暂不支持导出分享链接，请使用备份功能迁移节点配置'
        : '该协议暂不支持导出分享链接';
      promptAction.showToast({ message });
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
    const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    if (runningId === p.id) {
      promptAction.showToast({ message: '当前节点正在运行，请先断开 VPN 再删除' });
      return;
    }
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
          .backgroundColor(this.settings.liquidGlass ? '#CCE3F2FD' : $r('app.color.surface_selected'))
          .stateEffect(this.settings.tactileInteraction)
          .onClick(() => this.runSpeedTest())
        Button('连接')
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(this.settings.liquidGlass ? '#CCFFFFFF' : $r('app.color.surface'))
          .stateEffect(this.settings.tactileInteraction)
          .onClick(() => {
            router.pushUrl({ url: 'pages/ConnectionsPage' });
          })
        Button('日志')
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(this.settings.liquidGlass ? '#CCFFFFFF' : $r('app.color.surface'))
          .stateEffect(this.settings.tactileInteraction)
          .onClick(() => {
            router.pushUrl({ url: 'pages/LogPage' });
          })
        Button('设置')
          .height(34)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor(this.settings.liquidGlass ? '#CCFFFFFF' : $r('app.color.surface'))
          .stateEffect(this.settings.tactileInteraction)
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 12, bottom: 8 })
      .borderRadius(this.settings.liquidGlass ? 18 : 0)
      .backgroundColor(this.settings.liquidGlass ? '#CCFFFFFF' : '#00FFFFFF')
      .border(this.settings.liquidGlass ? { width: 1, color: '#80FFFFFF' } : { width: 0, color: '#00FFFFFF' })
      .shadow(this.settings.liquidGlass ? { radius: 18, color: '#18000000', offsetX: 0, offsetY: 6 } : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
      .stateEffect(this.settings.tactileInteraction)

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
      .borderRadius(this.settings.liquidGlass ? 18 : 12)
      .backgroundColor(this.settings.liquidGlass ? '#CCFFFFFF' : '#FFFFFF')
      .border(this.settings.liquidGlass ? { width: 1, color: '#80FFFFFF' } : { width: 0, color: '#00FFFFFF' })
      .shadow(this.settings.liquidGlass ? { radius: 16, color: '#16000000', offsetX: 0, offsetY: 5 } : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
      .stateEffect(this.settings.tactileInteraction)

      // 分组与节点列表
      List({ space: 8 }) {
        ForEach(this.sortedGroups(), (group: ProfileGroup) => {
          ListItem() {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Text(group.expanded ? '▼' : '▶')
                  .fontSize(14)
                  .padding(8)
                  .onClick(() => this.toggleGroup(group))
                if (this.editingGroupId === group.id) {
                  TextInput({ text: this.editingGroupName, placeholder: '分组名称' })
                    .layoutWeight(1)
                    .onChange((value: string) => {
                      this.editingGroupName = value;
                    })
                  Button('保存')
                    .height(32)
                    .onClick(() => this.saveGroupName(group))
                } else {
                  Column({ space: 2 }) {
                    Text(group.name)
                      .fontSize(16)
                      .fontWeight(FontWeight.Bold)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`${this.profilesInGroup(group.id).length} 个节点`)
                      .fontSize(12)
                      .fontColor($r('app.color.text_secondary'))
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  .onClick(() => this.toggleGroup(group))
                  Button('↑').height(32).onClick(() => this.moveGroup(group, -1))
                  Button('↓').height(32).onClick(() => this.moveGroup(group, 1))
                  Button('重命名').height(32).onClick(() => this.beginRenameGroup(group))
                  Button('删除')
                    .height(32)
                    .fontColor($r('app.color.error'))
                    .onClick(() => this.confirmDeleteGroup(group))
                }
              }
              .width('100%')

              if (group.expanded) {
                ForEach(this.profilesInGroup(group.id), (p: Profile) => {
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
                  const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
                  if (runningId === p.id) {
                    promptAction.showToast({ message: '当前节点正在运行，请先断开 VPN 再编辑' });
                    return;
                  }
                  AppStorage.setOrCreate('editProfileId', p.id);
                  router.pushUrl({ url: 'pages/ProfileEdit' });
                })
            }
            .width('100%')
            .padding(12)
            .borderRadius(this.settings.liquidGlass ? 18 : 12)
            .backgroundColor(this.selectedId === p.id
              ? (this.settings.liquidGlass ? '#CCE3F2FD' : '#E3F2FD')
              : (this.settings.liquidGlass ? '#CCFFFFFF' : '#FFFFFF'))
            .border(this.settings.liquidGlass ? { width: 1, color: '#80FFFFFF' } : { width: 0, color: '#00FFFFFF' })
            .shadow(this.settings.liquidGlass ? { radius: 12, color: '#12000000', offsetX: 0, offsetY: 4 } : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
            .stateEffect(this.settings.tactileInteraction)
            .bindContextMenu(this.profileContextMenu(p), ResponseType.LongPress)
                  }
                }, (p: Profile) => p.id)
              }
            }
            .width('100%')
            .padding(12)
          }
        }, (group: ProfileGroup) => group.id)
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
          .backgroundColor(this.settings.liquidGlass
            ? (this.isRunning ? '#DDE53935' : '#DD1E88E5')
            : (this.isRunning ? $r('app.color.error') : $r('app.color.primary')))
          .border(this.settings.liquidGlass ? { width: 1, color: '#80FFFFFF' } : { width: 0, color: '#00FFFFFF' })
          .shadow(this.settings.liquidGlass ? { radius: 16, color: '#26000000', offsetX: 0, offsetY: 5 } : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
          .stateEffect(this.settings.tactileInteraction)
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
          .backgroundColor(this.settings.liquidGlass ? '#DD1E88E5' : $r('app.color.primary'))
          .borderRadius(26)
          .border(this.settings.liquidGlass ? { width: 1, color: '#A0FFFFFF' } : { width: 0, color: '#00FFFFFF' })
          .shadow(this.settings.liquidGlass ? { radius: 18, color: '#30000000', offsetX: 0, offsetY: 6 } : { radius: 8, color: '#40000000', offsetX: 0, offsetY: 3 })
          .stateEffect(this.settings.tactileInteraction)
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
  liquidGlass: boolean = true;
  tactileInteraction: boolean = true;
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
          .backgroundColor(this.liquidGlass ? '#CCFFFFFF' : '#F5F5F5')
          .fontColor('#333333')
          .stateEffect(this.tactileInteraction)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Blank()
        Button('从剪贴板读取')
          .backgroundColor(this.liquidGlass ? '#CCFFFFFF' : '#F5F5F5')
          .fontColor('#333333')
          .stateEffect(this.tactileInteraction)
          .onClick(() => this.onPickClipboard())
        Button('导入')
          .backgroundColor(this.liquidGlass ? '#DD1E88E5' : '#1E88E5')
          .stateEffect(this.tactileInteraction)
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
    .borderRadius(this.liquidGlass ? 22 : 12)
    .backgroundColor(this.liquidGlass ? '#E6FFFFFF' : '#FFFFFF')
    .border(this.liquidGlass ? { width: 1, color: '#A0FFFFFF' } : { width: 0, color: '#00FFFFFF' })
    .shadow(this.liquidGlass ? { radius: 24, color: '#28000000', offsetX: 0, offsetY: 8 } : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
    .stateEffect(this.tactileInteraction)
  }
}
