import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
import connection from '@ohos.net.connection';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import notificationManager from '@ohos.notificationManager';
import notification from '@ohos.notification';
import wantAgent from '@ohos.app.ability.wantAgent';
import commonEventManager from '@ohos.commonEventManager';
import BusinessError from '@ohos.base';
import { Profile, ProfileGroup, AppSettings } from '../model/Profile';
import { initStore, loadProfiles, loadGroups, loadSettings, getPendingProfileId, setPendingProfileId, clearPendingProfileId, setRunningProfileId, LogStore } from '../model/Store';
import { buildCoreConfig } from '../core/ConfigBuilder';
import { loadRouteRules, RouteRule, loadRemoteRuleSets, RemoteRuleSet } from '../model/RouteRule';
import { CoreManager } from '../core/CoreManager';
import { publishVpnLog, publishVpnStatus, publishVpnTraffic, VPN_EVENT_LATENCY } from '../core/VpnIpc';
import { geoReady, geoSitePath as geoSiteFile, geoIpPath as geoIpFile } from '../utils/GeoAssets';
import { fetchTrafficTotals } from '../utils/TrafficStats';

/**
 * VPN 扩展能力 — 真正的 VPN 生命周期在这里:
 *
 *   onCreate / onConnect(哪个触发都接管)→ 读待启动 Profile
 *     → 解析服务器 IP(加排除路由防回环)→ vpnConnection.create(config) 拿 TUN fd
 *     → 生成 sing-box 配置 → NAPI fork/exec 内核子进程(fd 被子进程继承)
 *   onDisconnect / onDestroy → 结束内核子进程、销毁隧道
 *
 * 每一步都写日志;关键等待有超时,卡住时能在「日志」页定位。
 */

const VPN_TUN_IFNAME = 'vpn-tun';

function withTimeout<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${what} 超时(${Math.round(ms / 1000)}s)`));
    }, ms);
    promise.then((v: T) => {
      clearTimeout(timer);
      resolve(v);
    }, (e: Object) => {
      clearTimeout(timer);
      reject(e as Error);
    });
  });
}

export default class VpnExtAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private starting: boolean = false;
  private started: boolean = false;
  private currentRunId: string = '';
  private currentNodeName: string = '';
  private latencySubscribed: boolean = false;
  private teardownPromise: Promise<void> | null = null;
  private lifecycleGeneration: number = 0;
  private restartRequested: boolean = false;
  private latestRequestedProfileId: string = '';
  private forceRestartRequested: boolean = false;
  private notificationTrafficTimer: number = -1;
  private notificationGeneration: number = 0;
  private notificationLatencyMs: number = -1;
  private notificationLastUp: number = 0;
  private notificationLastDown: number = 0;
  private notificationLastAt: number = 0;
  private notificationUpSpeed: number = 0;
  private notificationDownSpeed: number = 0;
  private notificationTotalUp: number = 0;
  private notificationTotalDown: number = 0;
  private notificationSettings: AppSettings | null = null;
  private notificationGroupName: string = '';

  onCreate(want: Want): void {
    this.hookLifecycle('onCreate', want);
  }

  /** 本 SDK 上 startVpnExtensionAbility 实际走的是 onRequest(hilog 已证实) */
  onRequest(want: Want, startId: number): void {
    this.hookLifecycle(`onRequest(startId=${startId})`, want);
  }

  async onConnect(want: Want): Promise<void> {
    this.hookLifecycle('onConnect', want);
  }

  private hookLifecycle(name: string, want: Want): void {
    LogStore.addLog(`[vpn] 扩展 ${name}`);
    // 节点 ID 经 want 参数直达（跨进程 Preferences 缓存不刷新，不可靠）
    if (want !== undefined && want.parameters !== undefined) {
      const params = want.parameters as Record<string, Object>;
      const wantProfileId = params['profileId'];
      if (wantProfileId !== undefined && `${wantProfileId}`.length > 0) {
        this.latestRequestedProfileId = `${wantProfileId}`;
        setPendingProfileId(this.latestRequestedProfileId);
      }
      if (`${params['forceRestart']}` === 'true') {
        this.forceRestartRequested = true;
      }
    }
    LogStore.setPublisher((line: string) => {
      publishVpnLog(line);
    });
    this.subscribeLatencyEvents();
    this.tryStart();
  }

  private subscribeLatencyEvents(): void {
    if (this.latencySubscribed) {
      return;
    }
    this.latencySubscribed = true;
    const info: commonEventManager.CommonEventSubscribeInfo = { events: [VPN_EVENT_LATENCY] };
    commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      commonEventManager.subscribe(subscriber,
        (err: BusinessError, data: commonEventManager.CommonEventData) => {
          if (err || data === undefined || data.data === undefined || data.event !== VPN_EVENT_LATENCY) {
            return;
          }
          try {
            const payload = JSON.parse(data.data) as Record<string, Object>;
            const profileId: string = payload['profileId'] === undefined ? '' : `${payload['profileId']}`;
            if (!this.started || profileId !== this.currentRunId) {
              return;
            }
            const nodeName: string = payload['nodeName'] === undefined
              ? this.currentNodeName : `${payload['nodeName']}`;
            const latencyMs: number = Number(payload['latencyMs']);
            this.currentNodeName = nodeName;
            this.notificationLatencyMs = latencyMs;
            void this.showConnectedNotification(nodeName, latencyMs);
          } catch (e) {
            // 忽略格式错误的测速事件
          }
        });
    }).catch((e: Object) => {
      this.latencySubscribed = false;
      LogStore.addLog(`[vpn] 延迟事件订阅失败: ${e}`);
    });
  }

  onDisconnect(want: Want): void {
    LogStore.addLog('[vpn] 扩展 onDisconnect');
    this.lifecycleGeneration++;
    this.stopNotificationTrafficPoller();
    this.cancelNotification();
    this.teardown();
  }

  onDestroy(): void {
    LogStore.addLog('[vpn] 扩展 onDestroy');
    this.lifecycleGeneration++;
    this.stopNotificationTrafficPoller();
    this.cancelNotification();
    this.teardown();
  }

  private teardown(silent: boolean = false): Promise<void> {
    if (this.teardownPromise !== null) {
      return this.teardownPromise;
    }
    this.teardownPromise = this.doTeardown(silent).finally(() => {
      this.teardownPromise = null;
    });
    return this.teardownPromise;
  }

  private async doTeardown(silent: boolean): Promise<void> {
    this.stopNotificationTrafficPoller();
    this.cancelNotification();
    try {
      // 内核长时间闲置后可能无响应,stopCore 回调若永不触发会卡死 starting,
      // 导致之后所有启动请求被队列吞掉——这里必须带超时兜底。
      await withTimeout(CoreManager.stopCore(), 8000, '停止内核超时');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 停止内核失败,继续销毁隧道: ${msg}`);
    }
    if (this.vpnConnection !== null) {
      try {
        await withTimeout(this.vpnConnection.destroy(), 5000, '销毁隧道超时');
      } catch (e) {
        const msg = e instanceof Error ? e.message : `${e}`;
        LogStore.addLog(`[vpn] 销毁隧道失败: ${msg}`);
      }
      this.vpnConnection = null;
    }
    this.currentRunId = '';
    await setRunningProfileId('');
    this.started = false;
    this.starting = false;
    if (!silent) {
      publishVpnStatus('disconnected', false);
    }
  }

  private async tryStart(): Promise<void> {
    if (this.starting) {
      this.restartRequested = true;
      LogStore.addLog('[vpn] 正在启动中,记录最新请求并在当前操作结束后处理');
      return;
    }
    // 防重入标记必须在任何一个 await 之前同步置位:
    // onCreate/onRequest 会在同一瞬间连发,否则会出现双重启动互拆
    this.starting = true;
    this.restartRequested = false;
    const generation = ++this.lifecycleGeneration;
    try {
      const context: common.Context = this.context;
      await initStore(context);
      const pendingId = this.latestRequestedProfileId.length > 0
        ? this.latestRequestedProfileId : await getPendingProfileId();
      if (this.started) {
        if (pendingId.length === 0) {
          // UI 进程可能刚被系统回收重建(AppStorage 已重置),必须重播当前状态,
          // 否则 UI 永远停在「连接中」——这是闲置后无法启动的主要根因。
          LogStore.addLog('[vpn] 已在运行且没有新的启动目标,忽略重复触发并重播已连接状态');
          publishVpnStatus(`connected:${this.currentNodeName}`, true, this.currentRunId);
          return;
        }
        if (pendingId === this.currentRunId && !this.forceRestartRequested) {
          LogStore.addLog('[vpn] 已在运行且节点未变化,忽略重复触发并重播已连接状态');
          publishVpnStatus(`connected:${this.currentNodeName}`, true, this.currentRunId);
          await clearPendingProfileId();
          return;
        }
        const restartReason: string = pendingId === this.currentRunId ? '模式变更' : '节点切换';
        this.forceRestartRequested = false;
        LogStore.addLog(`[vpn] 检测到${restartReason},串行重启内核…`);
        publishVpnStatus('switching', true, pendingId);
        await this.teardown(true);
        this.starting = true;
        await this.startVpn(context, pendingId, generation);
      } else {
        await this.startVpn(context, pendingId, generation);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 启动失败: ${msg}`);
      this.stopNotificationTrafficPoller();
      this.cancelNotification();
      await clearPendingProfileId();
      await this.teardown(true);
      publishVpnStatus(`connect_failed:${msg}`, false);
    } finally {
      this.starting = false;
      if (this.restartRequested) {
        this.restartRequested = false;
        LogStore.addLog('[vpn] 继续处理启动期间收到的最新请求');
        this.tryStart();
      }
    }
  }

  private async startVpn(context: common.Context, pendingId: string, generation: number): Promise<void> {
    // ---- 0. 待启动节点 ----
    if (pendingId.length === 0) {
      // 保持扩展待命:下一次 startVpnExtensionAbility 会带着新节点再次进入
      LogStore.addLog('[vpn] 暂无待启动节点,扩展保持待命');
      this.stopNotificationTrafficPoller();
      this.cancelNotification();
      return;
    }
    const profiles = await loadProfiles();
    let profile: Profile | null = null;
    for (const p of profiles) {
      if (p.id === pendingId) {
        profile = p;
        break;
      }
    }
    if (profile === null) {
      throw new Error('找不到待启动的节点');
    }
    const node: Profile = profile;
    const settings = await loadSettings();
    this.notificationSettings = settings;
    // 通知显示分组名(设置开启且节点有分组时)
    this.notificationGroupName = '';
    if (settings.notificationGroup && node.groupId.length > 0) {
      try {
        const groups = await loadGroups();
        const g = groups.find((item: ProfileGroup) => item.id === node.groupId);
        if (g !== undefined) {
          this.notificationGroupName = g.name;
        }
      } catch (e) {
        // 分组名缺失不影响连接
      }
    }
    LogStore.addLog(`[vpn] 准备连接: ${node.name} (${node.server}:${node.serverPort})`);

    // ---- 1. 防回环策略 ----
    // 不再往 VpnConfig 加"服务器 IP/32 → wlan0"排除路由:实测该路由不带网关,
    // 对公网地址无法完成 ARP(死路由),反而遮蔽默认路由导致 no route to host。
    // 防回环完全依赖 protectProcessNet(创建隧道后调用,对本进程后续 socket 生效,
    // 进程内内核的 socket 均在其中)。
    let ifname = '';
    try {
      const net: connection.NetHandle = await withTimeout(connection.getDefaultNet(), 10000, '获取默认网络');
      const props: connection.ConnectionProperties =
        await withTimeout(connection.getConnectionProperties(net), 10000, '获取网卡信息');
      ifname = props.interfaceName;
      LogStore.addLog(`[vpn] 物理网卡: ${ifname}`);
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 获取物理网卡失败: ${msg}`);
    }
    if (settings.mode === 'global' && ifname.length === 0) {
      throw new Error('全局模式无法获取物理网卡,为防止整机断网已取消启动');
    }

    // ---- 2. VpnConfig(LinkAddress.address 是嵌套的 NetAddress 对象) ----
    // 路由只有"默认 → TUN",防回环靠 protectProcessNet
    const addresses: Array<connection.LinkAddress> = [linkAddr('172.19.0.1', 30)];
    if (settings.ipv6) {
      addresses.push(linkAddr('fdfe:dcba:9876::1', 126));
    }
    const routes: Array<vpnExtension.RouteInfo> = [];
    routes.push(buildRoute(VPN_TUN_IFNAME, '0.0.0.0', 0, true));
    if (settings.ipv6) {
      routes.push(buildRoute(VPN_TUN_IFNAME, '::', 0, true));
    }
    const config: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      dnsAddresses: [dnsAddressForApps(settings)],
      mtu: settings.mtu,
      isIPv4Accepted: true,
      isIPv6Accepted: settings.ipv6
    };
    // ---- 2.5 分应用代理(VPN 框架原生支持) ----
    const perAppList: Array<string> = settings.perAppList.split(',')
      .map((s: string) => s.trim())
      .filter((s: string) => s.length > 0);
    if (settings.perAppMode === 'exclude' && perAppList.length > 0) {
      config.blockedApplications = perAppList; // 这些应用不走 VPN
      LogStore.addLog(`[vpn] 分应用(排除): ${perAppList.join(', ')}`);
    } else if (settings.perAppMode === 'include' && perAppList.length > 0) {
      config.trustedApplications = perAppList; // 仅这些应用走 VPN
      LogStore.addLog(`[vpn] 分应用(仅这些): ${perAppList.join(', ')}`);
    }

    // ---- 3. 生成配置文件(内核日志写 log.output 文件,由日志页直读) ----
    const logPath = CoreManager.resetLogFile(context);
    let geositePath = '';
    let geoIpPath = '';
    if (settings.mode === 'rule') {
      try {
        if (geoReady(context)) {
          geositePath = geoSiteFile(context);
          geoIpPath = geoIpFile(context);
          LogStore.addLog('[vpn] Geo 分流数据就绪,cn 直连分流已启用');
        } else {
          LogStore.addLog('[vpn] Geo 数据未下载,规则模式仅私网/自定义直连');
        }
      } catch (e) {
        // ignore
      }
    }
    // 自定义路由规则(仅追加注入,不改变 DNS 与出站结构)
    let customRules: Array<RouteRule> = [];
    try {
      customRules = await loadRouteRules();
      const enabledCount = customRules.filter((r: RouteRule) => r.enabled).length;
      if (enabledCount > 0) {
        LogStore.addLog(`[vpn] 注入自定义路由规则 ${enabledCount} 条`);
      }
    } catch (e) {
      LogStore.addLog('[vpn] 读取自定义路由规则失败,本次连接忽略');
    }
    let remoteRuleSets: Array<RemoteRuleSet> = [];
    try {
      remoteRuleSets = await loadRemoteRuleSets();
      const enabledRuleSetCount = remoteRuleSets.filter((item: RemoteRuleSet) => item.enabled).length;
      if (enabledRuleSetCount > 0) {
        LogStore.addLog(`[vpn] 注入远程规则集 ${enabledRuleSetCount} 个`);
      }
    } catch (e) {
      LogStore.addLog('[vpn] 读取远程规则集失败,本次连接忽略');
    }
    const cachePath = logPath.length > 0 ? logPath.substring(0, logPath.lastIndexOf('/') + 1) + 'cache.db' : '';
    const configJson = buildCoreConfig(node, settings, ifname, logPath, geositePath, geoIpPath,
      customRules, remoteRuleSets, cachePath, profiles);
    const configPath = CoreManager.writeConfigFile(context, configJson);
    LogStore.addLog(`[vpn] sing-box 配置已写入 ${configPath}`);

    // ---- 4. 创建 TUN ----
    if (this.vpnConnection === null) {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    }
    try {
      await this.vpnConnection.destroy();
      LogStore.addLog('[vpn] 已清理残留隧道');
    } catch (e) {
      // 正常情况:没有残留
    }
    LogStore.addLog('[vpn] 正在创建 VPN 隧道(如弹出授权框请点「允许」)…');
    publishVpnStatus('awaiting_auth', false);
    const tunFd: number = await withTimeout(this.vpnConnection.create(config), 60000,
      '创建 TUN 超时:未收到系统 VPN 授权,或系统 VPN 服务无响应');
    LogStore.addLog(`[vpn] TUN fd = ${tunFd}`);
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }

    // ---- 4.5 保护本进程后续 socket 不走 VPN(防回环,API 22+) ----
    // 必须在启动内核前完成。protectProcessNet 只保护随后创建的 socket,
    // 因此 proxy outbound 和 DNS bootstrap 都会稳定走底层物理网络。
    try {
      await withTimeout(this.vpnConnection.protectProcessNet(), 10000, '防回环保护超时');
      LogStore.addLog('[vpn] protectProcessNet 成功:内核 socket 将绕过 VPN');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] protectProcessNet 失败,终止启动并回滚 TUN: ${msg}`);
      throw new Error(`防回环保护失败: ${msg}`);
    }

    // ---- 5. 启动内核(进程内 c-shared 库,无 exec) ----
    await withTimeout(new Promise<void>((resolve, reject) => {
      CoreManager.startCore(configPath, tunFd, (err: string) => {
        if (err.length > 0) {
          LogStore.addLog(`[vpn] 内核启动失败: ${err}`);
          reject(new Error(err));
          return;
        }
        resolve();
      });
    }), 15000, 'sing-box 内核启动');
    if (!this.starting || generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }
    LogStore.addLog('[vpn] 内核已启动(进程内)');
    this.started = true;
    this.currentRunId = pendingId;
    this.currentNodeName = node.name;
    await setRunningProfileId(pendingId);
    this.notificationLatencyMs = -1;
    await this.showConnectedNotification(node.name, -1);
    this.startNotificationTrafficPoller();
    publishVpnStatus(`connected:${node.name}`, true, pendingId);
    await clearPendingProfileId();
  }

  private startNotificationTrafficPoller(): void {
    this.stopNotificationTrafficPoller();
    const settings = this.notificationSettings;
    if (!this.started || settings === null || !settings.clashApiEnabled) {
      return;
    }
    this.notificationLastUp = 0;
    this.notificationLastDown = 0;
    this.notificationLastAt = 0;
    this.notificationUpSpeed = 0;
    this.notificationDownSpeed = 0;
    this.notificationTotalUp = 0;
    this.notificationTotalDown = 0;
    const generation = ++this.notificationGeneration;
    const poll = async (): Promise<void> => {
      const startedAt = Date.now();
      const totals = await fetchTrafficTotals(settings.clashApiPort, settings.clashApiSecret);
      if (generation !== this.notificationGeneration || !this.started || totals === null) {
        return;
      }
      if (this.notificationLastAt > 0) {
        const elapsedSeconds = Math.max(0.001, (startedAt - this.notificationLastAt) / 1000);
        this.notificationUpSpeed = Math.max(0,
          Math.round((totals.up - this.notificationLastUp) / elapsedSeconds));
        this.notificationDownSpeed = Math.max(0,
          Math.round((totals.down - this.notificationLastDown) / elapsedSeconds));
      }
      this.notificationLastUp = totals.up;
      this.notificationLastDown = totals.down;
      this.notificationLastAt = startedAt;
      this.notificationTotalUp = totals.up;
      this.notificationTotalDown = totals.down;
      publishVpnTraffic(this.notificationUpSpeed, this.notificationDownSpeed,
        this.notificationTotalUp, this.notificationTotalDown);
      await this.showConnectedNotification(this.currentNodeName, this.notificationLatencyMs);
    };
    void poll();
    this.notificationTrafficTimer = setInterval(() => { void poll(); }, 1500);
  }

  private stopNotificationTrafficPoller(): void {
    this.notificationGeneration++;
    if (this.notificationTrafficTimer >= 0) {
      clearInterval(this.notificationTrafficTimer);
      this.notificationTrafficTimer = -1;
    }
    this.notificationLastUp = 0;
    this.notificationLastDown = 0;
    this.notificationLastAt = 0;
    this.notificationUpSpeed = 0;
    this.notificationDownSpeed = 0;
    this.notificationTotalUp = 0;
    this.notificationTotalDown = 0;
  }

  private formatNotificationSpeed(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${bytesPerSecond} B/s`;
    }
    const kb = bytesPerSecond / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB/s`;
    }
    return `${(kb / 1024).toFixed(1)} MB/s`;
  }

  private formatNotificationBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    const kb = bytes / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  /** 常驻通知:显示当前连接、延迟、实时速率和累计流量,并提供断开操作 */
  private async showConnectedNotification(nodeName: string, latencyMs: number): Promise<void> {
    try {
      const latencyText: string = latencyMs >= 0 ? `${latencyMs}ms` : '--';
      const disconnectAgent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.nekobox.app',
          abilityName: 'EntryAbility',
          parameters: { 'action': 'disconnect' }
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1002,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      // 本机 SDK(API 24)通知字段为 string 类型,不接受 Resource:构建时现取本地化字符串
      const res = this.context.resourceManager;
      const displayName = this.notificationGroupName.length > 0
        ? `[${this.notificationGroupName}] ${nodeName}` : nodeName;
      const uploadLabel = res.getStringSync($r('app.string.notification_upload'));
      const downloadLabel = res.getStringSync($r('app.string.notification_download'));
      const totalLabel = res.getStringSync($r('app.string.notification_total'));
      const trafficText = `${uploadLabel} ${this.formatNotificationSpeed(this.notificationUpSpeed)} / ` +
        `${downloadLabel} ${this.formatNotificationSpeed(this.notificationDownSpeed)} · ` +
        `${totalLabel} ${uploadLabel} ${this.formatNotificationBytes(this.notificationTotalUp)} / ` +
        `${downloadLabel} ${this.formatNotificationBytes(this.notificationTotalDown)}`;
      const content: notificationManager.NotificationContent = {
        contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: res.getStringSync($r('app.string.notification_vpn_connected')),
          text: `${displayName} · ${latencyText}`,
          additionalText: trafficText
        }
      };
      const request: notificationManager.NotificationRequest = {
        id: 1001,
        isOngoing: true,
        content: content,
        actionButtons: [{
          title: res.getStringSync($r('app.string.notification_disconnect')),
          wantAgent: disconnectAgent
        }]
      };
      await notificationManager.publish(request);
    } catch (e) {
      LogStore.addLog(`[vpn] 通知发布失败(忽略): ${e}`);
    }
  }

  private cancelNotification(): void {
    try {
      notificationManager.cancel(1001).catch((e: BusinessError) => {
        // ignore
      });
    } catch (e) {
      // ignore
    }
  }

  private async stopSelf(): Promise<void> {
    await clearPendingProfileId();
    await this.teardown();
    LogStore.addLog('[vpn] 扩展自退出清理完成');
  }
}

function isIpLiteral(s: string): boolean {
  if (s.includes(':')) {
    return /^[0-9a-fA-F:]+$/.test(s);
  }
  const parts = s.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const p of parts) {
    const n = Number(p);
    if (isNaN(n) || n < 0 || n > 255 || `${n}` !== p) {
      return false;
    }
  }
  return true;
}

function linkAddr(ip: string, prefix: number): connection.LinkAddress {
  const na: connection.NetAddress = { address: ip };
  const la: connection.LinkAddress = { address: na, prefixLength: prefix };
  return la;
}

function buildRoute(ifname: string, ip: string, prefix: number, isDefault: boolean): vpnExtension.RouteInfo {
  const gw: connection.NetAddress = { address: '0.0.0.0' };
  const r: vpnExtension.RouteInfo = {
    interface: ifname,
    destination: linkAddr(ip, prefix),
    gateway: gw,
    hasGateway: false,
    isDefaultRoute: isDefault
  };
  return r;
}

function hostOf(dnsUrl: string): string {
  let s = dnsUrl.trim();
  const scheme = s.indexOf('://');
  if (scheme >= 0) {
    s = s.substring(scheme + 3);
  }
  const path = s.indexOf('/');
  if (path >= 0) {
    s = s.substring(0, path);
  }
  if (s.startsWith('[')) {
    // [IPv6]:port
    const end = s.indexOf(']');
    return end > 0 ? s.substring(1, end) : s;
  }
  if (s.split(':').length === 2) {
    // host:port(IPv6 裸地址场景请用方括号书写)
    s = s.substring(0, s.indexOf(':'));
  }
  return s;
}

/** 系统在 VPN 内下发的 DNS:指向 remote(经代理),由 dns-out 劫持,防泄漏 */
function dnsAddressForApps(s: AppSettings): string {
  const h = hostOf(s.remoteDns);
  if (isIpLiteral(h)) {
    return h;
  }
  return '8.8.8.8';
}
