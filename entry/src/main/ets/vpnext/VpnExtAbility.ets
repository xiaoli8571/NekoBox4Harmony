import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
import connection from '@ohos.net.connection';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import notificationManager from '@ohos.notificationManager';
import notification from '@ohos.notification';
import BusinessError from '@ohos.base';
import { Profile, AppSettings } from '../model/Profile';
import { initStore, loadProfiles, loadSettings, getPendingProfileId, clearPendingProfileId, setRunningProfileId, LogStore } from '../model/Store';
import { buildCoreConfig } from '../core/ConfigBuilder';
import { CoreManager } from '../core/CoreManager';
import { publishVpnLog, publishVpnStatus } from '../core/VpnIpc';
import { geoReady, geoSitePath as geoSiteFile, geoIpPath as geoIpFile } from '../utils/GeoAssets';

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
  private teardownPromise: Promise<void> | null = null;
  private lifecycleGeneration: number = 0;

  onCreate(want: Want): void {
    this.hookLifecycle('onCreate');
  }

  /** 本 SDK 上 startVpnExtensionAbility 实际走的是 onRequest(hilog 已证实) */
  onRequest(want: Want, startId: number): void {
    this.hookLifecycle(`onRequest(startId=${startId})`);
  }

  async onConnect(want: Want): Promise<void> {
    this.hookLifecycle('onConnect');
  }

  private hookLifecycle(name: string): void {
    LogStore.addLog(`[vpn] 扩展 ${name}`);
    LogStore.setPublisher((line: string) => {
      publishVpnLog(line);
    });
    this.tryStart();
  }

  onDisconnect(want: Want): void {
    LogStore.addLog('[vpn] 扩展 onDisconnect');
    this.lifecycleGeneration++;
    this.teardown();
  }

  onDestroy(): void {
    LogStore.addLog('[vpn] 扩展 onDestroy');
    this.lifecycleGeneration++;
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
    try {
      await CoreManager.stopCore();
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 停止内核失败,继续销毁隧道: ${msg}`);
    }
    this.cancelNotification();
    if (this.vpnConnection !== null) {
      try {
        await this.vpnConnection.destroy();
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
      publishVpnStatus('已断开', false);
    }
  }

  private async tryStart(): Promise<void> {
    if (this.starting) {
      LogStore.addLog('[vpn] 正在启动中,忽略重复触发');
      return;
    }
    // 防重入标记必须在任何一个 await 之前同步置位:
    // onCreate/onRequest 会在同一瞬间连发,否则会出现双重启动互拆
    this.starting = true;
    const generation = ++this.lifecycleGeneration;
    try {
      const context: common.Context = this.context;
      await initStore(context);
      const pendingId = await getPendingProfileId();
      if (this.started) {
        if (pendingId.length === 0 || pendingId === this.currentRunId) {
          LogStore.addLog('[vpn] 已在运行且节点未变化,忽略重复触发');
          return;
        }
        // 运行中收到不同节点:原地重启(免断开切换)
        LogStore.addLog('[vpn] 检测到节点切换,重启内核…');
        publishVpnStatus('正在切换节点…', true, pendingId);
        await this.teardown(true);
        this.starting = true;
        await this.startVpn(context, pendingId, generation);
      } else {
        await this.startVpn(context, pendingId, generation);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 启动失败: ${msg}`);
      await clearPendingProfileId();
      await this.teardown(true);
      publishVpnStatus(`连接失败: ${msg}`, false);
    } finally {
      this.starting = false;
    }
  }

  private async startVpn(context: common.Context, pendingId: string, generation: number): Promise<void> {
    // ---- 0. 待启动节点 ----
    if (pendingId.length === 0) {
      LogStore.addLog('[vpn] 没有待启动的节点(可能授权框被取消),退出');
      await this.stopSelf();
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
    const configJson = buildCoreConfig(profile, settings, ifname, logPath, geositePath, geoIpPath);
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
    publishVpnStatus('等待 VPN 授权…', false);
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
    await setRunningProfileId(pendingId);
    this.showConnectedNotification(node.name);
    publishVpnStatus(`已连接: ${node.name}`, true, pendingId);
    await clearPendingProfileId();
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
