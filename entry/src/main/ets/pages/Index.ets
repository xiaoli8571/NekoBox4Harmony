import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import util from '@ohos.util';
import { scanBarcode } from '@kit.ScanKit';
import { Profile, AppSettings, profileTypeLabel } from '../model/Profile';
import { LogStore } from '../model/Store';
import { VpnService } from '../common/service/VpnService';
import { ProfileStorage } from '../common/storage/ProfileStorage';
import { ConnectionState } from '../common/model/ConnectionState';
import { ConnectionStateManager } from '../common/manager/ConnectionStateManager';
import { parseShareText, parseSingleLink, looksLikeHttpProxyLink } from '../utils/LinkParser';
import { getClipboardText, setClipboardText } from '../utils/ClipboardHelper';
import { exportProfileLink } from '../utils/LinkExporter';
import { fetchSubscriptionWithInfo, looksLikeClashYaml, parseClashProxies, ClashParseResult } from '../utils/Subscription';
import { upsertSub, needAutoUpdate, updateSubscription, setAppContext, subNameOf, listSubs, SubInfo } from '../core/Subscriptions';
import { fetchTrafficTotals, fetchProxyDelay, formatSpeed, formatBytes } from '../utils/TrafficStats';
import { profileOutboundTag } from '../core/ConfigBuilder';

// API 24's ArkTS standard library does not declare Number.MAX_SAFE_INTEGER.
const MAX_DELAY_SORT = 9007199254740991;

interface GroupOption {
  id: string;
  name: string;
}

@Entry
@Component
struct Index {
  @State profiles: Array<Profile> = [];
  // 与 Android NekoBox 主页一致：节点列表支持按名称、地址或协议快速筛选。
  @State searchQuery: string = '';
  @State selectedGroupFilter: string = 'all';
  @State subscriptions: Array<SubInfo> = [];
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
  @StorageLink('vpnRunningProfileId') runningProfileId: string = '';
  @StorageLink('vpnConnectionState') connectionState: string = ConnectionState.IDLE;
  @StorageLink('vpnConnectedAt') vpnConnectedAt: number = 0;
  @State runningSeconds: number = 0;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  private switching: boolean = false;
  private speedTimer: number = -1;
  private runtimeTimer: number = -1;
  private autoTestTimer: number = -1;
  private initialAutoTestTimer: number = -1;
  private speedPollGeneration: number = 0;
  private lastUp: number = 0;
  private lastDown: number = 0;
  private lastTrafficAt: number = 0;

  aboutToAppear(): void {
    ConnectionStateManager.initialize();
    setAppContext(this.context);
    this.refresh();
    this.autoUpdateSubs();
    if (this.isRunning) {
      // 页面可能是在 VPN 已经建立后重新创建；恢复轮询不能把本次会话
      // 的累计流量清零，只有 running 从 false→true 时才开始新会话。
      this.startSpeedPoller(false);
      this.startRuntimeTimer();
      this.startAutoTestTimer();
    }
  }

  // 从编辑页 router.back() 回来时刷新列表(否则新保存的节点不显示)
  onPageShow(): void {
    this.refresh();
    // 页面离开期间轮询器会被停止；VPN 仍在运行时回到主页要恢复实时状态卡片。
    if (this.isRunning) {
      // 从编辑页/后台返回只恢复轮询，累计流量归零由断开事件负责。
      this.startSpeedPoller(false);
      this.startRuntimeTimer();
      this.startAutoTestTimer();
    } else {
      // 页面不可见期间断开时，watch 回调可能暂未调度；回到主页时再确保
      // 速率、累计流量和运行时长均回到本次会话的初始值。
      this.stopSpeedPoller();
      this.stopRuntimeTimer();
      this.stopAutoTestTimer();
    }
  }

  aboutToDisappear(): void {
    this.stopSpeedPoller(false);
    this.stopRuntimeTimer();
    this.stopAutoTestTimer();
  }

  onRunningChange(): void {
    if (this.isRunning) {
      this.startSpeedPoller(true);
      this.startRuntimeTimer();
      this.startAutoTestTimer();
    } else {
      this.stopSpeedPoller();
      this.stopRuntimeTimer();
      this.stopAutoTestTimer();
    }
    this.refresh();
  }

  private startSpeedPoller(resetSession: boolean = false): void {
    this.stopSpeedPoller(false);
    this.lastUp = 0;
    this.lastDown = 0;
    if (resetSession) {
      AppStorage.setOrCreate('vpnUpSpeed', 0);
      AppStorage.setOrCreate('vpnDownSpeed', 0);
      AppStorage.setOrCreate('vpnTotalUp', 0);
      AppStorage.setOrCreate('vpnTotalDown', 0);
    }
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

  private stopSpeedPoller(resetTotals: boolean = true): void {
    if (this.speedTimer >= 0) {
      clearInterval(this.speedTimer);
      this.speedTimer = -1;
    }
    if (resetTotals) {
      AppStorage.setOrCreate('vpnUpSpeed', 0);
      AppStorage.setOrCreate('vpnDownSpeed', 0);
      AppStorage.setOrCreate('vpnTotalUp', 0);
      AppStorage.setOrCreate('vpnTotalDown', 0);
    }
  }

  private startRuntimeTimer(): void {
    this.stopRuntimeTimer();
    if (this.vpnConnectedAt <= 0) {
      AppStorage.setOrCreate('vpnConnectedAt', Date.now());
    }
    this.runningSeconds = 0;
    this.runtimeTimer = setInterval(() => {
      this.runningSeconds = Math.max(0, Math.floor((Date.now() - this.vpnConnectedAt) / 1000));
    }, 1000);
  }

  private stopRuntimeTimer(): void {
    if (this.runtimeTimer >= 0) {
      clearInterval(this.runtimeTimer);
      this.runtimeTimer = -1;
    }
    this.runningSeconds = 0;
  }

  private runtimeText(): string {
    const hours = Math.floor(this.runningSeconds / 3600);
    const minutes = Math.floor((this.runningSeconds % 3600) / 60);
    const seconds = this.runningSeconds % 60;
    const hh = hours < 10 ? `0${hours}` : `${hours}`;
    const mm = minutes < 10 ? `0${minutes}` : `${minutes}`;
    const ss = seconds < 10 ? `0${seconds}` : `${seconds}`;
    return `${hh}:${mm}:${ss}`;
  }

  private currentNodeName(): string {
    const id = this.runningProfileId.length > 0 ? this.runningProfileId : this.selectedId;
    const profile = this.profiles.find((p: Profile) => p.id === id);
    return profile === undefined ? '未选择节点' : profile.name;
  }

  private stateColor(): string {
    if (this.connectionState === ConnectionState.CONNECTED) {
      return '#2E7D32';
    }
    if (this.connectionState === ConnectionState.CONNECTING
      || this.connectionState === ConnectionState.DISCONNECTING
      || this.connectionState === ConnectionState.TESTING) {
      return '#F9A825';
    }
    return '#757575';
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
      await ProfileStorage.initialize(this.context);
      this.profiles = await ProfileStorage.profiles();
      this.subscriptions = await listSubs();
      this.settings = await ProfileStorage.settings();
      const restored: Record<string, number> = {};
      for (const profile of this.profiles) {
        if (profile.lastDelay !== 0) {
          restored[profile.id] = profile.lastDelay;
        }
      }
      this.latencies = restored;
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
      await ProfileStorage.initialize(this.context);
      if (!this.settings.autoUpdateSubs) {
        return;
      }
      const stale = await needAutoUpdate();
      for (const sub of stale) {
        try {
          const r = await updateSubscription(sub.url);
          LogStore.addLog(`[app] 订阅 ${sub.name} 自动更新:新增 ${r.added},移除 ${r.removed}`);
          this.refresh();
        } catch (e) {
          LogStore.addLog(`[app] 订阅 ${sub.name} 自动更新失败: ${e}`);
        }
      }
    } catch (e) {
      // ignore
    }
  }

  private startAutoTestTimer(): void {
    this.stopAutoTestTimer();
    this.initialAutoTestTimer = setTimeout(() => {
      this.runSpeedTest(true);
    }, 10000);
    this.autoTestTimer = setInterval(() => {
      this.runSpeedTest(true);
    }, 300000);
  }

  private stopAutoTestTimer(): void {
    if (this.initialAutoTestTimer >= 0) {
      clearTimeout(this.initialAutoTestTimer);
      this.initialAutoTestTimer = -1;
    }
    if (this.autoTestTimer >= 0) {
      clearInterval(this.autoTestTimer);
      this.autoTestTimer = -1;
    }
  }

  private updateDelay(p: Profile, delay: number): void {
    const next: Record<string, number> = {};
    for (const key of Object.keys(this.latencies)) {
      next[key] = this.latencies[key];
    }
    next[p.id] = delay;
    this.latencies = next;
    p.lastDelay = delay;
  }

  /** Clash API URL Test：当前运行配置包含所有有效节点出站。 */
  async runSpeedTest(automatic: boolean = false): Promise<void> {
    if (this.testing || this.profiles.length === 0) {
      return;
    }
    if (!this.isRunning) {
      if (!automatic) {
        promptAction.showToast({ message: '请先连接 VPN，再执行 URL 测速' });
      }
      return;
    }
    this.testing = true;
    ConnectionStateManager.transition(ConnectionState.TESTING);
    this.latencies = {};
    if (!automatic) {
      promptAction.showToast({ message: `正在 URL 测试 ${this.profiles.length} 个节点…` });
    }
    const snapshot: Array<Profile> = this.profiles.slice();
    try {
      for (const profile of snapshot) {
        let delay = -1;
        try {
          delay = await fetchProxyDelay(profileOutboundTag(profile.id));
        } catch (e) {
          // 单个节点异常只记为超时，继续测试其他节点。
          delay = -1;
        }
        this.updateDelay(profile, delay);
      }
      await ProfileStorage.saveProfiles(this.profiles);
      if (!automatic) {
        promptAction.showToast({ message: 'URL 测速完成' });
      }
    } finally {
      this.testing = false;
      ConnectionStateManager.restoreRunningState(this.isRunning);
    }
  }

  async runSingleUrlTest(p: Profile): Promise<void> {
    if (this.testing) {
      return;
    }
    if (!this.isRunning) {
      promptAction.showToast({ message: '请先连接 VPN，再执行 URL 测速' });
      return;
    }
    this.testing = true;
    ConnectionStateManager.transition(ConnectionState.TESTING);
    try {
      const delay = await fetchProxyDelay(profileOutboundTag(p.id));
      this.updateDelay(p, delay);
      await ProfileStorage.saveProfiles(this.profiles);
      promptAction.showToast({ message: delay < 0 ? `${p.name}: 测速失败` : `${p.name}: ${delay}ms` });
    } finally {
      this.testing = false;
      ConnectionStateManager.restoreRunningState(this.isRunning);
    }
  }

  async sortByDelay(): Promise<void> {
    this.profiles.sort((a: Profile, b: Profile) => {
      if (a.pinned !== b.pinned) {
        return a.pinned ? -1 : 1;
      }
      const ad = this.latencies[a.id] === undefined ? a.lastDelay : this.latencies[a.id];
      const bd = this.latencies[b.id] === undefined ? b.lastDelay : this.latencies[b.id];
      const av = ad > 0 ? ad : MAX_DELAY_SORT;
      const bv = bd > 0 ? bd : MAX_DELAY_SORT;
      return av - bv;
    });
    this.profiles = this.profiles.slice();
    await ProfileStorage.saveProfiles(this.profiles);
    promptAction.showToast({ message: '已按延迟排序（置顶节点优先）' });
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

  private sourceDomain(p: Profile): string {
    if (p.subUrl.trim().length === 0) {
      return '手动配置';
    }
    let source = p.subUrl.trim();
    const scheme = source.indexOf('://');
    if (scheme >= 0) {
      source = source.substring(scheme + 3);
    }
    const slash = source.indexOf('/');
    if (slash >= 0) {
      source = source.substring(0, slash);
    }
    const at = source.lastIndexOf('@');
    if (at >= 0) {
      source = source.substring(at + 1);
    }
    return source.length > 0 ? source : '订阅节点';
  }

  /**
   * 返回当前搜索条件下的节点。搜索不改变持久化顺序，清空输入即可恢复完整列表。
   * 统一转小写后匹配名称、协议、服务器、端口和订阅来源，方便从 Android 端迁移使用习惯。
   */
  private visibleProfiles(): Array<Profile> {
    const query = this.searchQuery.trim().toLowerCase();
    return this.profiles.filter((p: Profile) => {
      if (this.selectedGroupFilter !== 'all' && p.groupId !== this.selectedGroupFilter) {
        return false;
      }
      if (query.length === 0) {
        return true;
      }
      const haystack = `${p.name} ${profileTypeLabel(p.type)} ${p.type} ${p.server} ${p.serverPort} ${this.sourceDomain(p)}`;
      return haystack.toLowerCase().includes(query);
    });
  }

  private groupOptions(): Array<GroupOption> {
    const options: Array<GroupOption> = [
      { id: 'all', name: '全部' }, { id: 'manual', name: '手动配置' }
    ];
    for (const sub of this.subscriptions) {
      options.push({ id: `subscription:${sub.url}`, name: sub.name });
    }
    return options;
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
      const isHttpUrl = firstLine.startsWith('http://') || firstLine.startsWith('https://');
      if (isHttpUrl) {
        // http(s) 同时承担代理节点和订阅 URL。对只有 host:port 的歧义
        // 地址先尝试下载；下载失败或内容没有节点时，再回退到单节点解析，
        // 避免把合法订阅根地址静默保存成一个“HTTP 代理节点”。
        let nodeCandidate: Profile | null = null;
        try {
          nodeCandidate = parseSingleLink(firstLine);
        } catch (e) {
          nodeCandidate = null;
        }
        const preferNode = looksLikeHttpProxyLink(firstLine);
        if (preferNode && nodeCandidate !== null) {
          parsed = [nodeCandidate];
        } else {
          // 订阅链接:下载内容后解析(服务商返回 Clash YAML 时自动切换解析器)
          promptAction.showToast({ message: '正在获取订阅…' });
          subUrl = firstLine;
          try {
            const fetched = await fetchSubscriptionWithInfo(firstLine);
            const content = fetched.content;
            subUserinfo = fetched.userinfo;
            if (looksLikeClashYaml(content)) {
              const r: ClashParseResult = parseClashProxies(content);
              parsed = r.profiles;
              if (parsed.length === 0 && nodeCandidate === null) {
                promptAction.showToast({
                  message: `订阅返回 Clash 格式,但没有可导入的节点(跳过 ${r.skipped} 个不支持的协议)`
                });
                return;
              }
            } else {
              parsed = parseShareText(content);
            }
            if (parsed.length === 0 && nodeCandidate !== null) {
              // HTTP 代理服务端常会返回 4xx/非订阅正文；此时保留
              // 原始节点候选，且不要把它记录成订阅来源。
              parsed = [nodeCandidate];
              subUrl = '';
              subUserinfo = '';
              promptAction.showToast({ message: '订阅内容为空,已按 HTTP 代理节点导入' });
            }
          } catch (fetchError) {
            if (nodeCandidate === null) {
              const fetchMsg = fetchError instanceof Error ? fetchError.message : `${fetchError}`;
              throw new Error(fetchMsg);
            }
            parsed = [nodeCandidate];
            subUrl = '';
            subUserinfo = '';
            const fetchMsg = fetchError instanceof Error ? fetchError.message : `${fetchError}`;
            LogStore.addLog(`[ui] HTTP 地址订阅下载失败,回退单节点: ${fetchMsg}`);
            promptAction.showToast({ message: '订阅下载失败,已按 HTTP 代理节点导入' });
          }
        }
      } else {
        parsed = parseShareText(text);
      }
      if (parsed.length === 0) {
        promptAction.showToast({ message: '未解析到可识别的节点' });
        return;
      }
      await ProfileStorage.initialize(this.context);
      const profiles = await ProfileStorage.profiles();
      for (const p of parsed) {
        p.id = this.genId();
        p.subUrl = subUrl;
        p.updatedAt = Date.now();
        profiles.push(p);
      }
      await ProfileStorage.saveProfiles(profiles);
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
          ProfileStorage.saveProfiles(this.profiles);
        }
      }
    });
  }

  private importActionDialog: CustomDialogController = new CustomDialogController({
    builder: ImportActionDialog({
      onAction: (action: string) => {
        this.handleImportAction(action);
      }
    }),
    autoCancel: true
  });

  private async handleImportAction(action: string): Promise<void> {
    if (action === 'manual') {
      AppStorage.setOrCreate('editProfileId', '');
      router.pushUrl({ url: 'pages/ProfileEdit' });
      return;
    }
    if (action === 'paste') {
      const text = await getClipboardText();
      if (text.trim().length === 0) {
        promptAction.showToast({ message: '剪贴板为空' });
        return;
      }
      await this.doImport(text);
      return;
    }
    if (action === 'scan') {
      await this.importFromScan();
      return;
    }
    if (action === 'file') {
      await this.importFromFile();
      return;
    }
    this.openImportDialog();
  }

  private async importFromScan(): Promise<void> {
    try {
      const result = await scanBarcode.startScanForResult(this.context, {
        enableMultiMode: false,
        enableAlbum: true
      });
      if (result === undefined || result === null || result.originalValue === undefined
        || result.originalValue === null || result.originalValue.trim().length === 0) {
        promptAction.showToast({ message: '二维码内容为空' });
        return;
      }
      await this.doImport(result.originalValue);
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      if (!msg.includes('1000500002')) {
        promptAction.showToast({ message: `扫码失败: ${msg}` });
      }
    }
  }

  private async importFromFile(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['节点/订阅文件|.txt,.conf,.yaml,.yml,.json'];
      const uris = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const text = this.readPickedText(uris[0]);
      await this.doImport(text);
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `文件导入失败: ${msg}` });
    }
  }

  /**
   * Picker 返回的是临时授权的 document URI，不能当作应用沙箱路径直接
   * 调用 readTextSync；按 FilePicker 约定用 READ_ONLY FD 分块读取。
   */
  private readPickedText(uri: string): string {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const decoder = util.TextDecoder.create('utf-8');
    const chunks: Array<string> = [];
    const chunkSize = 64 * 1024;
    const maxBytes = 8 * 1024 * 1024;
    let total = 0;
    try {
      while (total < maxBytes) {
        const buffer = new ArrayBuffer(Math.min(chunkSize, maxBytes - total));
        const readLen = fs.readSync(file.fd, buffer);
        if (readLen <= 0) {
          break;
        }
        chunks.push(decoder.decodeToString(new Uint8Array(buffer, 0, readLen)));
        total += readLen;
        if (readLen < buffer.byteLength) {
          break;
        }
      }
    } finally {
      fs.closeSync(file);
    }
    return chunks.join('');
  }

  @State actionProfile: Profile = new Profile();
  private nodeActionDialog: CustomDialogController = new CustomDialogController({
    builder: NodeActionDialog({
      profile: $actionProfile,
      onAction: (action: string) => {
        this.handleNodeAction(action);
      }
    }),
    autoCancel: true
  });

  private openNodeActions(p: Profile): void {
    this.actionProfile = p;
    this.nodeActionDialog.open();
  }

  private async handleNodeAction(action: string): Promise<void> {
    const p = this.actionProfile;
    if (action === 'edit') {
      AppStorage.setOrCreate('editProfileId', p.id);
      router.pushUrl({ url: 'pages/ProfileEdit' });
      return;
    }
    if (action === 'delete') {
      this.deleteProfile(p);
      return;
    }
    if (action === 'pin') {
      p.pinned = !p.pinned;
      this.profiles.sort((a: Profile, b: Profile) => {
        if (a.pinned === b.pinned) {
          return 0;
        }
        return a.pinned ? -1 : 1;
      });
      this.profiles = this.profiles.slice();
      await ProfileStorage.saveProfiles(this.profiles);
      promptAction.showToast({ message: p.pinned ? '已置顶' : '已取消置顶' });
      return;
    }
    if (action === 'urltest') {
      await this.runSingleUrlTest(p);
      return;
    }
    try {
      const link = exportProfileLink(p);
      if (action === 'copy') {
        await setClipboardText(link);
        promptAction.showToast({ message: '节点链接已复制' });
        return;
      }
      if (action === 'share') {
        const parameters: Record<string, Object> = {
          'ohos.extra.param.key.content': link,
          'ohos.extra.param.key.contentTitle': p.name,
          'ohos.extra.param.key.shareAbstract': link,
          'ohos.extra.param.key.shareUrl': link
        };
        await this.context.startAbility({
          action: 'ohos.want.action.sendData',
          type: 'text/plain',
          uri: link,
          parameters: parameters
        });
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `操作失败: ${msg}` });
    }
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('NekBox')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Text(`· ${this.modeLabel()}`)
          .fontSize(13)
          .fontColor('#1E88E5')
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
        Text(this.testing ? '⏳' : '⚡')
          .fontSize(20)
          .padding(8)
          .onClick(() => this.runSpeedTest())
        Text('↕')
          .fontSize(20)
          .padding(8)
          .onClick(() => this.sortByDelay())
        Text('⚙')
          .fontSize(22)
          .padding(8)
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
        Text('🔗')
          .fontSize(20)
          .padding(8)
          .onClick(() => {
            router.pushUrl({ url: 'pages/ConnectionsPage' });
          })
        Text('📋')
          .fontSize(20)
          .padding(8)
          .onClick(() => {
            router.pushUrl({ url: 'pages/LogPage' });
          })
        Text('分组')
          .fontSize(14)
          .fontColor('#1E88E5')
          .padding(8)
          .onClick(() => router.pushUrl({ url: 'pages/SubscriptionPage' }))
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 8 })

      // Android NekoBox 的节点页提供常驻搜索入口；这里使用 ArkUI 原生输入框，
      // 不依赖 showActionMenu 或其他 SDK 扩展，且不会影响 VPN 配置生成。
      Row({ space: 8 }) {
        TextInput({ text: this.searchQuery, placeholder: '搜索节点名称、地址或协议' })
          .layoutWeight(1)
          .height(40)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.searchQuery = value;
          })
        if (this.searchQuery.length > 0) {
          Text('清除')
            .fontSize(13)
            .fontColor('#1E88E5')
            .padding({ left: 4, right: 8 })
            .onClick(() => {
              this.searchQuery = '';
            })
        }
      }
      .width('calc(100% - 24vp)')
      .margin({ left: 12, right: 12, top: 2, bottom: 4 })

      // Android NekoBox 的分组 Tab；横向滚动适配多个订阅来源。
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.groupOptions(), (group: GroupOption) => {
            Text(group.name)
              .fontSize(13)
              .fontColor(this.selectedGroupFilter === group.id ? '#FFFFFF' : '#555555')
              .backgroundColor(this.selectedGroupFilter === group.id ? '#1E88E5' : '#FFFFFF')
              .borderRadius(14)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .onClick(() => {
                this.selectedGroupFilter = group.id;
              })
          }, (group: GroupOption) => group.id)
        }.padding({ left: 12, right: 12 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(38)

      // 1.6.1 顶部状态卡片
      Column({ space: 8 }) {
        Row() {
          Row()
            .width(9)
            .height(9)
            .borderRadius(5)
            .backgroundColor(this.stateColor())
          Text(this.statusText)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.stateColor())
            .margin({ left: 8 })
          Blank()
          Text(this.isRunning ? this.runtimeText() : '00:00:00')
            .fontSize(13)
            .fontColor('#666666')
        }
        .width('100%')
        Row() {
          Text(this.currentNodeName())
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank()
          Text(`↑ ${formatSpeed(this.upSpeed)}  ↓ ${formatSpeed(this.downSpeed)}`)
            .fontSize(12)
            .fontColor('#555555')
        }
        .width('100%')
        Text(`累计 ↑ ${formatBytes(this.totalUp)}   ↓ ${formatBytes(this.totalDown)}`)
          .fontSize(12)
          .fontColor('#777777')
      }
      .width('calc(100% - 24vp)')
      .padding(14)
      .margin({ left: 12, right: 12, top: 8, bottom: 8 })
      .borderRadius(14)
      .backgroundColor('#FFFFFF')

      // 节点列表
      List({ space: 8 }) {
        ForEach(this.visibleProfiles(), (p: Profile) => {
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
                Row({ space: 6 }) {
                  Text(profileTypeLabel(p.type))
                    .fontSize(10)
                    .fontColor('#1565C0')
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(6)
                    .backgroundColor('#E3F2FD')
                  if (p.pinned) {
                    Text('置顶')
                      .fontSize(10)
                      .fontColor('#E65100')
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(6)
                      .backgroundColor('#FFF3E0')
                  }
                  Text(p.name)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                Text(`${this.sourceDomain(p)} · ${p.server}:${p.serverPort}`)
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

              Row({ space: 5 }) {
                Row()
                  .width(8)
                  .height(8)
                  .borderRadius(4)
                  .backgroundColor(this.latencyColor(p))
                Text(this.latencyText(p).length > 0 ? this.latencyText(p) : '未测速')
                  .fontSize(11)
                  .fontColor(this.latencyColor(p))
              }
              .margin({ right: 4 })

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
            .gesture(LongPressGesture().onAction(() => this.openNodeActions(p)))
          }
        }, (p: Profile) => p.id)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12 })

      // 1.6.5 FAB 导入菜单
      Row() {
        Blank()
        Button('+', { type: ButtonType.Circle })
          .width(52)
          .height(52)
          .fontSize(28)
          .backgroundColor('#1E88E5')
          .shadow({ radius: 10, color: '#55000000', offsetX: 0, offsetY: 4 })
          .onClick(() => this.importActionDialog.open())
      }
      .width('100%')
      .padding({ right: 20, top: 8, bottom: 2 })

      Button(this.isRunning ? '断开连接' : '启动 VPN')
        .width('90%')
        .height(46)
        .margin({ top: 10, bottom: 20 })
        .backgroundColor(this.isRunning ? '#E53935' : '#1E88E5')
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F4F7')
  }
}

/** FAB 导入菜单：自定义弹窗避免依赖返回 void 的 showActionMenu。 */
@CustomDialog
struct ImportActionDialog {
  controller?: CustomDialogController;
  onAction: (action: string) => void = (action: string) => {
  };

  private choose(action: string): void {
    if (this.controller !== undefined) {
      this.controller.close();
    }
    this.onAction(action);
  }

  build() {
    Column({ space: 8 }) {
      Text('导入节点')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 6 })
      Button('从剪贴板导入').width('100%').backgroundColor('#F5F5F5').fontColor('#333333')
        .onClick(() => this.choose('paste'))
      Button('扫码导入').width('100%').backgroundColor('#F5F5F5').fontColor('#333333')
        .onClick(() => this.choose('scan'))
      Button('手动创建').width('100%').backgroundColor('#F5F5F5').fontColor('#333333')
        .onClick(() => this.choose('manual'))
      Button('从文件导入').width('100%').backgroundColor('#F5F5F5').fontColor('#333333')
        .onClick(() => this.choose('file'))
      Button('粘贴文本 / 订阅 URL').width('100%').backgroundColor('#F5F5F5').fontColor('#333333')
        .onClick(() => this.choose('text'))
    }
    .padding(18)
    .width('100%')
  }
}

/** 节点长按菜单：使用自定义弹窗兼容当前 SDK 的 void showActionMenu。 */
@CustomDialog
struct NodeActionDialog {
  controller?: CustomDialogController;
  @Link profile: Profile;
  onAction: (action: string) => void = (action: string) => {
  };

  private choose(action: string): void {
    if (this.controller !== undefined) {
      this.controller.close();
    }
    this.onAction(action);
  }

  build() {
    Column({ space: 4 }) {
      Text(this.profile.name)
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ bottom: 8 })
      Button('分享').width('100%').backgroundColor('#F5F5F5').fontColor('#333333')
        .onClick(() => this.choose('share'))
      Button('编辑').width('100%').backgroundColor('#F5F5F5').fontColor('#333333')
        .onClick(() => this.choose('edit'))
      Button('URL 测速').width('100%').backgroundColor('#F5F5F5').fontColor('#333333')
        .onClick(() => this.choose('urltest'))
      Button(this.profile.pinned ? '取消置顶' : '置顶').width('100%').backgroundColor('#F5F5F5')
        .fontColor('#333333').onClick(() => this.choose('pin'))
      Button('复制').width('100%').backgroundColor('#F5F5F5').fontColor('#333333')
        .onClick(() => this.choose('copy'))
      Button('删除').width('100%').backgroundColor('#FFF0F0').fontColor('#E53935')
        .onClick(() => this.choose('delete'))
    }
    .padding(18)
    .width('100%')
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
