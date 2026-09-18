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
import { initStore, loadProfiles, loadGroups, loadSettings, getPendingProfileId, setPendingProfileId, clearPendingProfileId, setRunningProfileId, mutateProfiles, LogStore } from '../model/Store';
import { buildCoreConfig, effectiveIpv6Mode } from '../core/ConfigBuilder';
import { loadRouteRules, RouteRule, loadRemoteRuleSets, RemoteRuleSet } from '../model/RouteRule';
import { CoreManager } from '../core/CoreManager';
import { publishVpnLog, publishVpnStatus, publishVpnTraffic, VPN_EVENT_LATENCY, VPN_EVENT_APP_FOREGROUND } from '../core/VpnIpc';
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
  private foregroundSubscribed: boolean = false;
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
  /** 连续通知发布失败计数:通知被关闭时不再按 speedInterval(1s) 无界重试刷日志。 */
  private notificationFailStreak: number = 0;
  // 网络变化重置连接(功能对齐安卓 networkChangeResetConnections,2.0.2 起默认关)
  private netConnection: connection.NetConnection | null = null;
  private netChangeGeneration: number = 0;
  /** 两次网络变化强制重连的最小间隔(ms):即便用户显式打开该开关,也为共存兜底,
   *  防止被其他 VPN 应用建/拆隧道触发的网络事件连环拉进抢槽位互踢环。 */
  private lastForcedResetAt: number = 0;

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
    this.subscribeForegroundEvents();
    this.registerNetworkChange();
    this.tryStart();
  }

  /**
   * 网络变化时重置连接(功能对齐安卓 networkChangeResetConnections,2.0.2 起默认关):
   * Wi-Fi/移动数据切换会造成旧 socket 全部失效,重启隧道恢复连通性。
   * 鸿蒙上其它 VPN 应用建/拆隧道也会触发本回调,因此叠加 15s 最小间隔合并突发
   * 事件(真机实证:共存互踢环的放大器就是这条链路,故默认值同步翻转为关)。
   * 短时间多次网络变化由 generation 去重,只在最后一次变化后重连一次。
   * 本 SDK 的回调挂在 NetConnection 对象上(需 register),没有自由函数 on/off。
   */
  private registerNetworkChange(): void {
    if (this.netConnection !== null) {
      return;
    }
    try {
      const conn = connection.createNetConnection();
      conn.on('netAvailable', () => {
        this.handleNetworkChange('网络可用');
      });
      conn.on('netLost', () => {
        this.handleNetworkChange('网络丢失');
      });
      conn.on('netCapabilitiesChange', () => {
        this.handleNetworkChange('网络能力变化');
      });
      conn.register((err: BusinessError) => {
        if (err) {
          LogStore.addLog(`[vpn] 注册网络变化监听失败: ${err.message}`);
        }
      });
      this.netConnection = conn;
    } catch (e) {
      LogStore.addLog(`[vpn] 创建网络监听对象失败: ${e}`);
    }
  }

  private handleNetworkChange(reason: string): void {
    if (!this.started || this.starting) {
      return;
    }
    const generation = ++this.netChangeGeneration;
    setTimeout(() => {
      if (generation !== this.netChangeGeneration) {
        // 期间又发生了网络变化,等最后一次再处理
        return;
      }
      void this.resetConnectionsAfterNetworkChange(reason);
    }, 1500);
  }

  private async resetConnectionsAfterNetworkChange(reason: string): Promise<void> {
    try {
      const settings = await loadSettings();
      if (!settings.networkChangeResetConnections) {
        return;
      }
      if (!this.started || this.starting) {
        return;
      }
      const profileId = this.currentRunId;
      if (profileId.length === 0) {
        return;
      }
      const now = Date.now();
      if (now - this.lastForcedResetAt < 15000) {
        return; // 15s 窗口内的连环网络事件(常见于另一款 VPN 应用建/拆隧道)直接合并忽略
      }
      this.lastForcedResetAt = now;
      LogStore.addLog(`[vpn] ${reason},重置连接…`);
      setPendingProfileId(profileId);
      this.forceRestartRequested = true;
      await this.teardown(true);
      await this.tryStart();
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 网络变化重连失败: ${msg}`);
    }
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

  /**
   * 应用回到前台时重置连接(对齐安卓 wakeResetConnections):
   * 安卓在设备退出 Doze 闲置模式时重置;鸿蒙 SDK 无屏幕亮灭事件订阅,
   * 退而用「应用回到前台」近似(用户唤醒设备后通常会打开应用)。
   * 需手动在设置里开启,默认关闭。
   */
  private subscribeForegroundEvents(): void {
    if (this.foregroundSubscribed) {
      return;
    }
    this.foregroundSubscribed = true;
    const info: commonEventManager.CommonEventSubscribeInfo = { events: [VPN_EVENT_APP_FOREGROUND] };
    commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
      commonEventManager.subscribe(subscriber,
        (err: BusinessError, data: commonEventManager.CommonEventData) => {
          if (err || data === undefined || data.event !== VPN_EVENT_APP_FOREGROUND) {
            return;
          }
          void this.resetConnectionsAfterWake();
        });
    }).catch((e: Object) => {
      this.foregroundSubscribed = false;
      LogStore.addLog(`[vpn] 前台事件订阅失败: ${e}`);
    });
  }

  private unsubscribeForegroundEvents(): void {
    // 与延迟事件一致:订阅随扩展生命周期存在,此处仅占位,实际注销在进程退出时由系统回收
  }

  private async resetConnectionsAfterWake(): Promise<void> {
    try {
      if (!this.started || this.starting) {
        return;
      }
      const settings = await loadSettings();
      if (!settings.wakeResetConnections) {
        return;
      }
      const profileId = this.currentRunId;
      if (profileId.length === 0) {
        return;
      }
      LogStore.addLog('[vpn] 应用回到前台,重置连接…');
      setPendingProfileId(profileId);
      this.forceRestartRequested = true;
      await this.teardown(true);
      await this.tryStart();
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 唤醒重连失败: ${msg}`);
    }
  }

  onDisconnect(want: Want): void {
    LogStore.addLog('[vpn] 扩展 onDisconnect');
    this.lifecycleGeneration++;
    this.stopNotificationTrafficPoller();
    this.cancelNotification();
    this.unregisterNetworkChange();
    this.unsubscribeForegroundEvents();
    this.teardown();
  }

  onDestroy(): void {
    LogStore.addLog('[vpn] 扩展 onDestroy');
    this.lifecycleGeneration++;
    this.stopNotificationTrafficPoller();
    this.cancelNotification();
    this.unregisterNetworkChange();
    this.unsubscribeForegroundEvents();
    this.teardown();
  }

  private unregisterNetworkChange(): void {
    if (this.netConnection === null) {
      return;
    }
    const conn = this.netConnection;
    this.netConnection = null;
    try {
      conn.unregister((err: BusinessError) => {
        // 注销失败不阻断退出
      });
    } catch (e) {
      // 对象已销毁
    }
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
    const groups = await loadGroups();
    this.notificationSettings = settings;
    // 通知显示分组名(设置开启且节点有分组时)
    this.notificationGroupName = '';
    if (settings.notificationGroup && node.groupId.length > 0) {
      try {
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
    // 路由只有"默认 → TUN",防回环靠 protectProcessNet。
    // 平台 VPN 与内核 TUN 是两层,规则不同(安卓 VpnService.kt:100-124):
    //   - 平台层**始终**保留 IPv4 地址/路由(含 ONLY),只有 IPv6 段随模式增删;
    //   - 内核 TUN 层则由 ConfigBuilder 按模式给出 v4-only / v6-only / 双栈。
    // 此前把内核语义套到平台层,ONLY 下删掉 IPv4 地址与路由,与安卓不一致。
    const ipv6Mode = effectiveIpv6Mode(settings);
    const dualStackOrV6Only = ipv6Mode !== 'disable';
    const addresses: Array<connection.LinkAddress> = [linkAddr('172.19.0.1', 30)];
    if (dualStackOrV6Only) {
      addresses.push(linkAddr('fdfe:dcba:9876::1', 126));
    }
    const routes: Array<vpnExtension.RouteInfo> = [buildRoute(VPN_TUN_IFNAME, '0.0.0.0', 0, true)];
    if (dualStackOrV6Only) {
      routes.push(buildRoute(VPN_TUN_IFNAME, '::', 0, true));
    }
    const config: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      dnsAddresses: [dnsAddressForApps(settings)],
      mtu: settings.mtu,
      isIPv4Accepted: true,
      isIPv6Accepted: dualStackOrV6Only
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
      customRules, remoteRuleSets, cachePath, profiles, groups);
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
    this.notificationFailStreak = 0;
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
    // 通知刷新间隔(对齐安卓 speedInterval,默认 1000ms,允许 500ms~10s)
    const rawMs = settings.speedIntervalMs;
    const intervalMs = rawMs >= 500 && rawMs <= 10000 ? rawMs : 1000;
    this.notificationTrafficTimer = setInterval(() => { void poll(); }, intervalMs);
  }

  private stopNotificationTrafficPoller(): void {
    this.notificationGeneration++;
    if (this.notificationTrafficTimer >= 0) {
      clearInterval(this.notificationTrafficTimer);
      this.notificationTrafficTimer = -1;
    }
    // 会话流量累加到节点历史统计(对齐安卓 TrafficLooper.stop 的 finally traffic post)
    void this.persistSessionTraffic();
    this.notificationLastUp = 0;
    this.notificationLastDown = 0;
    this.notificationLastAt = 0;
    this.notificationUpSpeed = 0;
    this.notificationDownSpeed = 0;
    this.notificationTotalUp = 0;
    this.notificationTotalDown = 0;
  }

  /**
   * 把本次会话的上下行累计写入节点记录(对齐安卓 profileTrafficStatistics):
   * 鸿蒙无内核级按出站统计,单出站场景下会话总量即当前节点流量。
   * 开关关闭则跳过;累加后通知 UI 进程刷新节点卡显示。
   */
  private async persistSessionTraffic(): Promise<void> {
    try {
      const up = this.notificationTotalUp;
      const down = this.notificationTotalDown;
      const profileId = this.currentRunId;
      if (profileId.length === 0 || (up <= 0 && down <= 0)) {
        return;
      }
      const settings = await loadSettings();
      if (!settings.profileTrafficStatistics) {
        return;
      }
      await mutateProfiles((profiles: Array<Profile>): Array<Profile> => {
        for (let i = 0; i < profiles.length; i++) {
          if (profiles[i].id === profileId) {
            profiles[i].rx = Math.max(0, profiles[i].rx) + down;
            profiles[i].tx = Math.max(0, profiles[i].tx) + up;
            profiles[i].updatedAt = Date.now();
            break;
          }
        }
        return profiles;
      });
      publishVpnTraffic(0, 0, up, down);
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 会话流量持久化失败: ${msg}`);
    }
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
    if (this.notificationFailStreak >= 5) {
      return; // 连续 5 次发布失败(通知权限被关):本会话内停用周期通知,流量统计不受影响
    }
    try {
      const latencyText: string = latencyMs >= 0 ? `${latencyMs}ms` : '--';
      const disconnectAgent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.nekobox.app.jynxen',
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
      this.notificationFailStreak = 0;
    } catch (e) {
      this.notificationFailStreak = this.notificationFailStreak + 1;
      // 只记首次与停用阈值,避免通知被关闭时以 1Hz 刷爆日志
      if (this.notificationFailStreak === 1 || this.notificationFailStreak === 5) {
        LogStore.addLog(`[vpn] 通知发布失败(忽略,连续第 ${this.notificationFailStreak} 次): ${e}`);
      }
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
