import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
// Alias the network module: VpnExtensionAbility exposes a `connection`
// member in the ArkTS type environment, which can otherwise shadow this
// namespace import and produce misleading "possibly null" diagnostics.
import netConnection from '@ohos.net.connection';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import notificationManager from '@ohos.notificationManager';
import notification from '@ohos.notification';
import BusinessError from '@ohos.base';
import { Profile, AppSettings } from '../model/Profile';
import { getPendingProfileId, setPendingProfileId, clearPendingProfileId, setRunningProfileId, LogStore } from '../model/Store';
import { buildCoreConfig } from '../core/ConfigBuilder';
import { CoreManager } from '../core/CoreManager';
import { publishVpnLog, publishVpnStatus } from '../common/event/VpnEventBridge';
import { ProfileStorage } from '../common/storage/ProfileStorage';
import { RouteStorage } from '../common/storage/RouteStorage';
import { RouteProfile } from '../common/model/RouteProfile';
import { geoReady, geoSitePath as geoSiteFile, geoIpPath as geoIpFile } from '../utils/GeoAssets';

/**
 * VPN 扩展能力 — 真正的 VPN 生命周期在这里:
 *
 *   onCreate / onConnect(哪个触发都接管)→ 读待启动 Profile
 *     → 获取物理网卡并生成配置 → vpnConnection.create(config) 拿 TUN fd
 *     → 生成 sing-box 配置 → NAPI 在扩展进程内启动 c-shared 内核
 *   onDisconnect / onDestroy → 停止内核、销毁隧道
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
  private teardownPromise: Promise<void> | null = null;
  // 启动回调是异步 native 调用；teardown 必须先等它 settle，避免旧代
  // 在新代接管后才完成 startCore，把新代内核一并停掉或留下孤儿内核。
  private coreStartPromise: Promise<void> | null = null;
  private lifecycleGeneration: number = 0;
  // onCreate/onRequest 可能早于存储初始化到达；先把 Want 中的节点 ID
  // 缓存在扩展实例内，待 Preferences 就绪后再落盘，避免首启丢失请求。
  private requestedProfileId: string = '';

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
        this.requestedProfileId = `${wantProfileId}`;
      }
    }
    LogStore.setPublisher((line: string) => {
      publishVpnLog(line);
    });
    this.tryStart();
  }

  onDisconnect(want: Want): void {
    LogStore.addLog('[vpn] 扩展 onDisconnect');
    this.requestedProfileId = '';
    this.lifecycleGeneration++;
    this.teardown();
  }

  onDestroy(): void {
    LogStore.addLog('[vpn] 扩展 onDestroy');
    this.requestedProfileId = '';
    this.lifecycleGeneration++;
    this.teardown();
  }

  private teardown(silent: boolean = false): Promise<void> {
    if (this.teardownPromise !== null) {
      return this.teardownPromise;
    }
    this.teardownPromise = this.doTeardown(silent).finally(() => {
      this.teardownPromise = null;
      // stopVpnExtensionAbility 可能在 teardown 完成前就返回；若用户已经
      // 发起下一次连接请求，完成清理后补偿一次启动，避免 1.5s 窗口内丢单。
      if (this.requestedProfileId.length > 0 && !this.started && !this.starting) {
        this.tryStart();
      }
    });
    return this.teardownPromise;
  }

  private async doTeardown(silent: boolean): Promise<void> {
    // 先摘下本代隧道引用，避免极端并发下后续代替换引用后被旧 teardown
    // 销毁；正常路径仍由 VpnService 的串行队列保证 disconnect→connect。
    const connectionToDestroy = this.vpnConnection;
    this.vpnConnection = null;
    const pendingCoreStart = this.coreStartPromise;
    if (pendingCoreStart !== null) {
      try {
        await pendingCoreStart;
      } catch (e) {
        // 启动失败/超时后仍继续 stopCore 和销毁 TUN；这里的等待只用于
        // 把 native start 回调与 teardown 排序，不改变最终错误状态。
      }
    }
    try {
      await CoreManager.stopCore();
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 停止内核失败,继续销毁隧道: ${msg}`);
    }
    this.cancelNotification();
    if (connectionToDestroy !== null) {
      try {
        await connectionToDestroy.destroy();
      } catch (e) {
        const msg = e instanceof Error ? e.message : `${e}`;
        LogStore.addLog(`[vpn] 销毁隧道失败: ${msg}`);
      }
    }
    this.currentRunId = '';
    await setRunningProfileId('');
    this.started = false;
    this.starting = false;
    if (!silent) {
      publishVpnStatus('已断开', false);
    }
  }

  private async tryStart(): Promise<void> {
    if (this.starting) {
      LogStore.addLog('[vpn] 正在启动中,忽略重复触发');
      return;
    }
    if (this.teardownPromise !== null) {
      // 等待当前代完整释放 CoreManager/TUN；teardown 的 finally 会根据
      // requestedProfileId 自动补偿这次请求。
      LogStore.addLog('[vpn] 正在清理旧隧道,排队本次启动');
      return;
    }
    // 防重入标记必须在任何一个 await 之前同步置位:
    // onCreate/onRequest 会在同一瞬间连发,否则会出现双重启动互拆
    this.starting = true;
    const generation = ++this.lifecycleGeneration;
    const requestAtStart = this.requestedProfileId;
    try {
      const context: common.Context = this.context;
      await ProfileStorage.initialize(context);
      // Preferences 现在已就绪，再写入 Want 传来的节点 ID；这一步替代
      // hookLifecycle 中未经等待的 setPendingProfileId()。
      if (this.requestedProfileId.length > 0) {
        await setPendingProfileId(this.requestedProfileId);
      }
      const pendingId = await getPendingProfileId();
      if (this.started) {
        if (pendingId.length === 0 || pendingId === this.currentRunId) {
          LogStore.addLog('[vpn] 已在运行且节点未变化,忽略重复触发');
          return;
        }
        // 明确禁止扩展层运行中热切换；UI 必须先 stop，再等待 1.5s 后重新 start。
        LogStore.addLog('[vpn] 运行中收到不同节点请求,拒绝热切换,请先断开后重连');
        // 丢弃这次请求，避免它残留到下一次无参数重连时被误启动。
        await clearPendingProfileId();
        if (this.requestedProfileId === pendingId) {
          this.requestedProfileId = '';
        }
        return;
      } else {
        await this.startVpn(context, pendingId, generation);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 启动失败: ${msg}`);
      // 断开/新一代启动已经接管时，旧代不能清空新请求或拆掉新隧道。
      if (generation === this.lifecycleGeneration) {
        if (this.requestedProfileId === requestAtStart) {
          // 失败后不应由 teardown 的补偿逻辑无限重试同一份坏配置。
          this.requestedProfileId = '';
        }
        await clearPendingProfileId();
        await this.teardown(true);
        publishVpnStatus(`连接失败: ${msg}`, false);
      } else {
        LogStore.addLog('[vpn] 忽略已取消启动代的失败回调');
      }
    } finally {
      if (generation === this.lifecycleGeneration) {
        this.starting = false;
      }
    }
  }

  private async startVpn(context: common.Context, pendingId: string, generation: number): Promise<void> {
    // ---- 0. 待启动节点 ----
    if (pendingId.length === 0) {
      // 保持扩展待命:下一次 startVpnExtensionAbility 会带着新节点再次进入
      LogStore.addLog('[vpn] 暂无待启动节点,扩展保持待命');
      return;
    }
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }
    const profiles = await ProfileStorage.profiles();
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }
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
    const settings = await ProfileStorage.settings();
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }
    LogStore.addLog(`[vpn] 准备连接: ${node.name} (${node.server}:${node.serverPort})`);

    // ---- 1. 防回环策略 ----
    // 不再往 VpnConfig 加"服务器 IP/32 → wlan0"排除路由:实测该路由不带网关,
    // 对公网地址无法完成 ARP(死路由),反而遮蔽默认路由导致 no route to host。
    // 防回环三层：自身包名 blockedApplications + protectProcessNet +
    // sing-box route.default_interface。禁止添加服务器 IP/32 死路由。
    let ifname = '';
    try {
      const net: netConnection.NetHandle = await withTimeout(netConnection.getDefaultNet(), 10000, '获取默认网络');
      const props: netConnection.ConnectionProperties =
        await withTimeout(netConnection.getConnectionProperties(net), 10000, '获取网卡信息');
      ifname = props.interfaceName;
      LogStore.addLog(`[vpn] 物理网卡: ${ifname}`);
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 获取物理网卡失败: ${msg}`);
    }
    if (ifname.length === 0) {
      throw new Error('无法获取物理网卡,为确保 VPN 防回环已取消启动');
    }

    // ---- 2. VpnConfig(LinkAddress.address 是嵌套的 NetAddress 对象) ----
    // 路由只有"默认 → TUN"，不添加服务器 IP/32 排除路由。
    const addresses: Array<netConnection.LinkAddress> = [linkAddr('172.19.0.1', 30)];
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
    // 防回环第一层：应用自身必须始终进入 blockedApplications。
    // HarmonyOS 明确规定 trustedApplications 与 blockedApplications 互斥，
    // 因此 v1.7.0 不启用“仅这些应用走代理”的 trusted 白名单模式；该模式
    // 留待后续版本在不破坏自身排除保险的前提下重新设计。
    const selfBundleName = 'com.example.jynxen';
    const blockedApplications: Array<string> = [selfBundleName];
    if (settings.perAppMode === 'include') {
      // 不能静默降级为 off：那会把原本应直连的应用意外纳入 VPN。
      throw new Error('当前版本不支持“仅这些应用走代理”，请改为关闭或排除模式后重连');
    }
    if (settings.perAppMode === 'exclude' && perAppList.length > 0) {
      for (const bundleName of perAppList) {
        if (!blockedApplications.includes(bundleName)) {
          blockedApplications.push(bundleName);
        }
      }
      LogStore.addLog(`[vpn] 分应用(排除): ${perAppList.join(', ')}`);
    }
    if (blockedApplications.length > 256) {
      throw new Error('分应用排除列表超过系统上限(含应用自身共 256)');
    }
    config.blockedApplications = blockedApplications;

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
    // 路由配置属于可选增强项：存储损坏或尚未初始化时回退到基础模式，
    // 不能因为单独的路由数据拖垮整体 VPN 启动。
    let routeProfile: RouteProfile | null = null;
    try {
      await RouteStorage.initialize(context);
      routeProfile = await RouteStorage.active();
      if (routeProfile !== null) {
        LogStore.addLog(`[vpn] 已加载路由配置: ${routeProfile.name}`);
      }
    } catch (e) {
      const routeError = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 路由配置不可用,使用默认路由: ${routeError}`);
    }
    const configJson = buildCoreConfig(profile, settings, ifname, logPath, geositePath, geoIpPath);
    const configPath = CoreManager.writeConfigFile(context, configJson);
    LogStore.addLog(`[vpn] sing-box 配置已写入 ${configPath}`);

    // ---- 4. 创建 TUN ----
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }
    // 使用局部引用贯穿本次启动；teardown 会把字段摘空，不能让旧代在
    // await 之后再解引用到新代隧道或 null。
    let tunConnection = this.vpnConnection;
    if (tunConnection === null) {
      tunConnection = vpnExtension.createVpnConnection(this.context);
      this.vpnConnection = tunConnection;
    }
    try {
      await tunConnection.destroy();
      LogStore.addLog('[vpn] 已清理残留隧道');
    } catch (e) {
      // 正常情况:没有残留
    }
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }
    LogStore.addLog('[vpn] 正在创建 VPN 隧道(如弹出授权框请点「允许」)…');
    publishVpnStatus('等待 VPN 授权…', false);
    const tunFd: number = await withTimeout(tunConnection.create(config), 60000,
      '创建 TUN 超时:未收到系统 VPN 授权,或系统 VPN 服务无响应');
    LogStore.addLog(`[vpn] TUN fd = ${tunFd}`);
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }

    // ---- 4.5 保护本进程后续 socket 不走 VPN(防回环,API 22+) ----
    // 必须在启动内核前完成。protectProcessNet 只保护随后创建的 socket,
    // 因此 proxy outbound 和 DNS bootstrap 都会稳定走底层物理网络。
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }
    try {
      await withTimeout(tunConnection.protectProcessNet(), 10000, '防回环保护超时');
      LogStore.addLog('[vpn] protectProcessNet 成功:内核 socket 将绕过 VPN');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] protectProcessNet 失败,终止启动并回滚 TUN: ${msg}`);
      throw new Error(`防回环保护失败: ${msg}`);
    }
    if (generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }

    // ---- 5. 启动内核(进程内 c-shared 库,无 exec) ----
    // 原始 native 回调 promise 与 15s 启动超时必须分开保存。超时只限制
    // 调用方等待，无法取消脱离线程的 native 启动；teardown 必须保留这个
    // 原始 promise，等回调 settle 后才能调用 stopCore。
    // 把实际物理网卡名传给 Go wrapper；SO_BINDTODEVICE 必须在任何
    // sing-box 出站 socket 创建前设置，否则 DNS transport 可能回到 TUN。
    // 1.11.9 内核回退:不再激活 forcebind(其 BindToDevice 回退在沙箱返回 EPERM);
    // 防回环由 default_interface 绑定(1.5.6 真机验证)+ protectProcessNet + blockedApplications 承担。
    // CoreManager.setBindIfname(ifname);
    const coreStart = new Promise<void>((resolve, reject) => {
      CoreManager.startCore(configPath, tunFd, (err: string) => {
        // Native callbacks are declared as string, but older wrappers may
        // pass null/undefined on a successful return. Normalize that edge
        // case before checking length so the original Promise always settles.
        const errorText: string = err === undefined || err === null ? '' : `${err}`;
        if (errorText.length > 0) {
          LogStore.addLog(`[vpn] 内核启动失败: ${errorText}`);
          reject(new Error(errorText));
          return;
        }
        resolve();
      });
    });
    this.coreStartPromise = coreStart;
    // timeout wrapper 可能先于 native 回调 reject；附加 rejection observer
    // 消费迟到的 native 错误，teardown 仍单独等待原始 promise。
    const clearCoreStart = (): void => {
      if (this.coreStartPromise === coreStart) {
        this.coreStartPromise = null;
      }
    };
    coreStart.then(clearCoreStart, clearCoreStart);

    // wrapper 只在本地用于限制启动等待，不能存进 coreStartPromise；否则
    // wrapper 超时而 native 回调仍在飞行时，teardown 会与 startCore 竞态 stopCore。
    const coreStartWait = withTimeout(coreStart, 15000, 'sing-box 内核启动');
    await coreStartWait;
    if (!this.starting || generation !== this.lifecycleGeneration) {
      throw new Error('VPN 启动已取消');
    }
    LogStore.addLog('[vpn] 内核已启动(进程内)');
    this.started = true;
    this.currentRunId = pendingId;
    await setRunningProfileId(pendingId);
    this.showConnectedNotification(node.name);
    publishVpnStatus(`已连接: ${node.name}`, true, pendingId);
    await clearPendingProfileId();
    if (this.requestedProfileId === pendingId) {
      this.requestedProfileId = '';
    }
  }

  /** 常驻通知:显示当前连接,常驻不掉 */
  private showConnectedNotification(nodeName: string): void {
    try {
      const content: notificationManager.NotificationContent = {
        contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'VPN 已连接',
          text: nodeName,
          additionalText: 'NekBox'
        }
      };
      const request: notificationManager.NotificationRequest = {
        id: 1001,
        isOngoing: true,
        content: content
      };
      notificationManager.publish(request).catch((e: BusinessError) => {
        LogStore.addLog(`[vpn] 通知发布失败(忽略): ${e.message}`);
      });
    } catch (e) {
      // 通知失败不影响 VPN
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

function linkAddr(ip: string, prefix: number): netConnection.LinkAddress {
  const na: netConnection.NetAddress = { address: ip };
  const la: netConnection.LinkAddress = { address: na, prefixLength: prefix };
  return la;
}

function buildRoute(ifname: string, ip: string, prefix: number, isDefault: boolean): vpnExtension.RouteInfo {
  const gw: netConnection.NetAddress = { address: '0.0.0.0' };
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
