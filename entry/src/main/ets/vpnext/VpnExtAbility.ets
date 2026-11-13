import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
import rpc from '@ohos.rpc';
import connection from '@ohos.net.connection';
import common from '@ohos.app.ability.common';
import notificationManager from '@ohos.notificationManager';
import notification from '@ohos.notification';
import wantAgent from '@ohos.app.ability.wantAgent';
import commonEventManager from '@ohos.commonEventManager';
import BusinessError from '@ohos.base';
import { Profile, ProfileGroup, AppSettings } from '../model/Profile';
import { refreshStore, loadProfiles, loadGroups, loadSettings, getPendingProfileId, setPendingProfileId, clearPendingProfileId, setRunningProfileId, mutateProfiles, LogStore } from '../model/Store';
import { TrafficBaseline, parseBaseline, displayTotals, baselineStale, buildBaseline } from '../model/TrafficBaseline';
import { readPrefString, readRawConfigOverride } from '../model/Store';
import { buildCoreConfig, effectiveIpv6Mode, TUN_STACK } from '../core/ConfigBuilder';
import { loadRouteRules, RouteRule, loadRemoteRuleSets, RemoteRuleSet } from '../model/RouteRule';
import { CoreManager } from '../core/CoreManager';
import {
  ResourceResolver, PrepareOptions
} from '../core/ResourceResolver';
import { PreparedRuleSet, PreparedResources } from '../core/PreparedResource';
import { entriesFromLegacyList, serializeEntries } from '../model/PerApp';
import { evaluatePerAppPolicy, perAppBlockMessage } from '../model/PerAppPolicy';
import deviceInfo from '@ohos.deviceInfo';
import { publishVpnLog, publishVpnStatusEx, publishVpnTraffic, VPN_EVENT_LATENCY,
  subscribeVpnCommands, VpnCommand, VpnEnvelope, publishVpnApplied } from '../core/VpnIpc';
import { SnapshotStore } from '../core/SnapshotStore';
import { parseSnapshot, SnapshotParseResult, ConfigSnapshot } from '../model/ConfigSnapshot';
import { fetchTrafficTotals } from '../utils/TrafficStats';
import { TrafficStream, TrafficStreamCallbacks } from './TrafficStream';
import { TrafficMeter, TrafficDelta } from '../model/TrafficMeter';
import { ensureYacdExtracted } from '../utils/WebUiAssets';
import { errText } from '../utils/ErrText';
import { autoUpdateGeoAssets } from '../utils/GeoAssets';
import { addMessage } from '../model/MessageStore';
import { formatUptimeText } from '../utils/NotifyText';

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

/**
 * §8.4:分应用名单上限按系统 API 版本选择(API<23 → 64,API>=23 → 256)。
 * 读不到 sdkApiVersion 时按 23 处理并写日志注明;与 VpnService.ets 的同名兜底口径一致。
 */
function currentSdkApiLevel(): number {
  try {
    const level: number = deviceInfo.sdkApiVersion;
    if (level > 0) {
      return level;
    }
  } catch (e) {
    // fall through 到兜底
  }
  LogStore.addLog('[vpn] 读取 sdkApiVersion 失败,分应用上限按 API 23(256)处理');
  return 23;
}

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
  // 通知内容偏好(连接时快照一次,避免通知刷新时 1Hz 读设置):对齐 OwnBox 显示节点名/分组
  private notifyShowProfile: boolean = true;
  private notifyShowGroup: boolean = false;
  private notifyGroupLabel: string = '';
  private latencySubscribed: boolean = false;
  private teardownPromise: Promise<void> | null = null;
  private lifecycleGeneration: number = 0;
  private restartRequested: boolean = false;
  private latestRequestedProfileId: string = '';
  private forceRestartRequested: boolean = false;
  /** Want 直达的分应用名单(权威):UI 进程每次启动/重启隧道都会带上当前值。 */
  private wantPerAppMode: string = '';
  private wantPerAppList: string = '';
  private wantPerAppProvided: boolean = false;
  /** P1:唯一流量生产者 —— 内核 /traffic WebSocket(1s 增量),不再每秒 GET /connections */
  private trafficStream: TrafficStream | null = null;
  private notificationGeneration: number = 0;
  /** 通知正文刷新间隔(ms):流固定 1s 采样,通知按设置节流 */
  private notificationIntervalMs: number = 1000;
  private notificationPublishAt: number = 0;
  /** 连接建立后是否已用 /connections 快照对齐累计值(未对齐前丢弃流样本) */
  private notificationSynced: boolean = false;
  /** 每次重连快照独立排序,避免旧 HTTP 响应覆盖新连接的累计值。 */
  private trafficResyncGeneration: number = 0;
  private trafficStreamFailLogged: boolean = false;
  /** 内核累计口径(P1):/connections 快照对齐一次,之后只累加 /traffic 1s 增量 */
  private trafficMeter: TrafficMeter = new TrafficMeter();
  private notificationLatencyMs: number = -1;
  private notificationUpSpeed: number = 0;
  private notificationDownSpeed: number = 0;
  /** W20:显示累计流量基准(与 UI 共用 Preferences 键;重置后通知与 UI 同基准) */
  private notificationBaseline: TrafficBaseline | null = null;
  private notificationTotalUp: number = 0;
  private notificationTotalDown: number = 0;
  private notificationSettings: AppSettings | null = null;
  /** 本次连接建立的时刻:通知栏"运行时长"基准(重启会话/断开时清零) */
  private notificationStartedAt: number = 0;
  /** 上一次已发布的通知正文(速率|运行时长),用于"内容变化才记日志"的去重 */
  private lastNotificationLine: string = '';
  /** 连续通知发布失败计数:通知被关闭时不再按 speedInterval(1s) 无界重试刷日志。 */
  private notificationFailStreak: number = 0;
  // 网络变化重置连接(功能对齐安卓 networkChangeResetConnections,2.0.2 起默认关)
  private netConnection: connection.NetConnection | null = null;
  private netChangeGeneration: number = 0;
  /** 两次网络变化强制重连的最小间隔(ms):即便用户显式打开该开关,也为共存兜底,
   *  防止被其他 VPN 应用建/拆隧道触发的网络事件连环拉进抢槽位互踢环。 */
  private lastForcedResetAt: number = 0;

  // ---- 版本化事件信封(§16.1,docs/p1-design/runtime-protocol.md) ----
  /** 扩展进程会话标识:进程内懒生成、保持稳定;UI 据此过滤跨会话迟到事件。 */
  private sessionId: string = '';
  /** 事件序列号:进程内单调递增,排序/去重依据(时间戳不作排序依据)。 */
  private eventSequence: number = 0;
  private cmdSubscribed: boolean = false;

  // ---- 应用事务(§12.3,docs/p4-design/apply-transaction.md) ----
  /** 正在处理的应用操作 id:同一操作重复投递直接忽略,不重启发起第二次重连。 */
  private applyingOperationId: string = '';
  /** 最近一次成功完成的应用操作 id:重复投递时重播结果(幂等)。 */
  private appliedOperationId: string = '';
  /** 最近一次确认生效的快照 revision(仅当快照校验通过且本地设置与快照一致时非 0)。 */
  private lastAppliedRevision: number = 0;
  /** 最近一次生效的分应用名单摘要(回执给 UI,§12.3-5)。 */
  private lastPerAppSummary: string = '';

  // ---- UI 进程保活绑定(VpnService.bindExtension) ----
  /** 首次绑定时创建、随扩展存活;不承载任何调用,只为让系统记下"有应用进程连着扩展"。 */
  private bindStub: rpc.RemoteObject | null = null;
  /** 当前是否被 UI 进程以 bindOnly 方式绑定;据此区分 onDisconnect 是解绑还是停止。 */
  private uiBound: boolean = false;

  private static isBindOnly(want: Want | undefined): boolean {
    if (want === undefined || want.parameters === undefined) {
      return false;
    }
    const params = want.parameters as Record<string, Object>;
    return `${params['bindOnly']}` === 'true';
  }

  onCreate(want: Want): void {
    if (VpnExtAbility.isBindOnly(want)) {
      // 绑定只在隧道运行时发起;万一由绑定拉起了空闲扩展,也不能据此启动隧道
      LogStore.addLog('[vpn] 扩展 onCreate(由保活绑定拉起,不启动隧道)');
      return;
    }
    this.hookLifecycle('onCreate', want);
  }

  /** 本 SDK 上 startVpnExtensionAbility 实际走的是 onRequest(hilog 已证实) */
  onRequest(want: Want, startId: number): void {
    this.hookLifecycle(`onRequest(startId=${startId})`, want);
  }

  /**
   * 必须同步返回 RemoteObject:框架 native OnConnect 拿不到 remote object 会抛错,
   * 扩展进程随之以 JS 错误退出(Tailscale-OHOS 真机踩过)。
   */
  onConnect(want: Want): rpc.RemoteObject {
    if (this.bindStub === null) {
      this.bindStub = new rpc.RemoteObject('com.nekobox.vpn.keepalive');
    }
    if (VpnExtAbility.isBindOnly(want)) {
      this.uiBound = true;
      LogStore.addLog('[vpn] 扩展 onConnect(UI 保活绑定)');
    } else {
      this.hookLifecycle('onConnect', want);
    }
    return this.bindStub;
  }

  private hookLifecycle(name: string, want: Want): void {
    LogStore.addLog(`[vpn] 扩展 ${name}`);
    // P1:命令通道只订阅一次(版本化 IPC,§16.1);失败不影响现有 Want/事件流程
    this.ensureCommandSubscription();
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
      // 分应用名单同样经 Want 直达:扩展进程常驻,Preferences 的进程内读缓存不会
      // 因为 UI 进程刷盘而失效,只靠 loadSettings() 会一直拿到旧名单(真机"填了
      // 包名却不分流"的根因)。这里只要带上就覆盖,空串也是有效值(= 本次不限制)。
      const wantPerAppMode = params['perAppMode'];
      if (wantPerAppMode !== undefined) {
        this.wantPerAppMode = `${wantPerAppMode}`;
        const wantPerAppList = params['perAppList'];
        this.wantPerAppList = wantPerAppList === undefined ? '' : `${wantPerAppList}`;
        this.wantPerAppProvided = true;
      }
    }
    LogStore.setPublisher((line: string) => {
      publishVpnLog(line);
    });
    this.subscribeLatencyEvents();
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
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [VPN_EVENT_LATENCY],
      publisherBundleName: 'com.nekobox.app.jynxen'
    };
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
            // 通知栏不再显示节点/延迟(用户 2026-10-23 要求:改成速率 + 运行时长),测速只更新内存态
            void this.showConnectedNotification();
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
    if (this.uiBound) {
      // UI 进程解绑(显式断开、UI 进程退出/被杀):只是失去保活,隧道照常运行
      this.uiBound = false;
      LogStore.addLog('[vpn] 扩展 onDisconnect(UI 保活绑定解除,隧道保持)');
      return;
    }
    LogStore.addLog('[vpn] 扩展 onDisconnect');
    this.lifecycleGeneration++;
    this.stopTrafficStream();
    this.cancelNotification();
    this.unregisterNetworkChange();
    this.teardown();
  }

  onDestroy(): void {
    LogStore.addLog('[vpn] 扩展 onDestroy');
    this.lifecycleGeneration++;
    this.stopTrafficStream();
    this.cancelNotification();
    this.unregisterNetworkChange();
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
    this.stopTrafficStream();
    this.cancelNotification();
    try {
      // 先停内核再解除 pin。
      // 否则 stopCore 期间若后台刷新/GC 运行，已解除固定的旧版本文件理论上可能被回收。
      // 会话资源稳定性的生命周期应覆盖到内核完全停止为止。
      await withTimeout(CoreManager.stopCore(), 8000, '停止内核超时');
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[vpn] 停止内核失败,继续销毁隧道: ${msg}`);
    }
    // stopCore 已返回(成功或超时兜底)后再解除资源固定。
    ResourceResolver.releaseSessionFiles();
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
      this.publishStatus('disconnected', false);
    }
  }

  /** 懒生成进程会话标识(稳定、可读);新扩展进程=新会话,UI 据此重新拉快照。 */
  private ensureSession(): void {
    if (this.sessionId.length === 0) {
      this.sessionId = `vpn-${Date.now().toString(16)}-${Math.floor(Math.random() * 0xffff).toString(16)}`;
    }
  }

  /** 构造事件信封(§16.1):appliedRevision 在 M5(扩展读快照)接入前恒为 0=未知,不得冒充已知。 */
  private nextEnvelope(operationId: string): VpnEnvelope {
    this.ensureSession();
    this.eventSequence = this.eventSequence + 1;
    const env = new VpnEnvelope();
    env.sessionId = this.sessionId;
    env.sequence = this.eventSequence;
    env.operationId = operationId;
    env.appliedRevision = 0;
    env.emittedAt = Date.now();
    return env;
  }

  /** 状态发布统一入口:自动附带信封(旧字段不变,新增 env 字段向后兼容)。 */
  private publishStatus(status: string, running: boolean, profileId: string = '', operationId: string = ''): void {
    publishVpnStatusEx(status, running, profileId, this.nextEnvelope(operationId));
  }

  /** 订阅 UI 命令通道(P1 骨架:query 支持;connect/apply 走 Want/system 流程,P4 接入)。 */
  private ensureCommandSubscription(): void {
    if (this.cmdSubscribed) {
      return;
    }
    this.cmdSubscribed = true;
    subscribeVpnCommands((command: VpnCommand): void => {
      if (command.cmd === 'query') {
        // 全量运行快照:以当前已知状态回执(appliedRevision 在扩展读快照前为未知,如实填 0)
        const running = this.started;
        const name = running ? this.currentNodeName : '';
        this.publishStatus(running ? `connected:${name}` : 'disconnected', running, this.currentRunId,
          command.operationId);
        return;
      }
      if (command.cmd === 'apply') {
        this.handleApplyCommand(command);
        return;
      }
      if (command.cmd === 'clearTraffic') {
        this.handleClearTrafficCommand(command);
        return;
      }
      if (command.cmd === 'queryApplyStatus') {
        // 查询当前应用事务状态(UI 重启后避免重复投递,§12.3-8)
        this.publishApplyResult(this.started, command.operationId, this.lastAppliedRevision,
          this.lastPerAppSummary, this.started ? '' : 'not_running');
        return;
      }
      LogStore.addLog(`[vpn] 命令 ${command.cmd} 暂未支持, operationId=${command.operationId}`);
    });
  }

  /**
   * 应用配置事务(§12.3)：校验目标 revision 快照 → 确认本地设置与快照一致 →
   * 串行重启内核一次 → 回执 operationId/appliedRevision。
   *
   * 只读校验快照文件(不初始化 ConfigRepository：UI 进程才是写者，扩展进程不参与
   * recover/GC，避免两个进程同时裁决孤儿文件)。
   * 快照不可用或不一致时**不重启**并如实回执错误——UI 显示"已保存但未生效"。
   */
  private async handleApplyCommand(command: VpnCommand): Promise<void> {
    const opId = command.operationId;
    if (opId.length > 0 && opId === this.appliedOperationId) {
      this.publishApplyResult(true, opId, this.lastAppliedRevision, this.lastPerAppSummary, '');
      return;
    }
    if (opId.length > 0 && opId === this.applyingOperationId) {
      LogStore.addLog(`[vpn] 应用操作 ${opId} 正在处理中，忽略重复投递`);
      return;
    }
    const targetRevision = command.revision;
    if (targetRevision <= 0) {
      this.publishApplyResult(false, opId, 0, '', 'invalid_revision');
      return;
    }
    const snapshot = this.readSnapshotForApply(targetRevision);
    if (snapshot === null) {
      LogStore.addLog(`[vpn] 应用失败：快照 revision=${targetRevision} 不存在或校验未通过`);
      this.publishApplyResult(false, opId, 0, '', 'snapshot_unavailable');
      return;
    }
    let currentSettings: AppSettings;
    try {
      await refreshStore(this.context);
      currentSettings = await loadSettings();
    } catch (e) {
      this.publishApplyResult(false, opId, 0, '', 'settings_unreadable');
      return;
    }
    const mismatch = this.settingsMismatchWithSnapshot(snapshot, currentSettings);
    if (mismatch.length > 0) {
      LogStore.addLog(`[vpn] 应用失败：本地设置与快照不一致(${mismatch})，请先保存设置`);
      this.publishApplyResult(false, opId, 0, '', `settings_out_of_sync:${mismatch}`);
      return;
    }
    this.applyingOperationId = opId;
    LogStore.addLog(`[vpn] 收到应用配置请求 revision=${targetRevision} operationId=${opId}`);
    try {
      this.publishStatus('switching', this.started, this.currentRunId, opId);
      this.forceRestartRequested = true;
      await this.tryStart();
      const ok = this.started;
      if (ok) {
        this.appliedOperationId = opId;
        this.lastAppliedRevision = targetRevision;
        LogStore.addLog(`[vpn] 配置应用完成 revision=${targetRevision} operationId=${opId}`);
      } else {
        LogStore.addLog(`[vpn] 配置应用失败 revision=${targetRevision} operationId=${opId}`);
      }
      this.publishApplyResult(ok, opId, ok ? targetRevision : 0, this.lastPerAppSummary, ok ? '' : 'apply_failed');
    } finally {
      this.applyingOperationId = '';
    }
  }

  /**
   * UI「清除流量统计」:用 UI 发来的原始累计值更新扩展内基准,通知立即归零。
   * Preferences 里的基准由 UI 写入;这里同步内存副本,避免通知要等到下一次会话才生效。
   */
  private handleClearTrafficCommand(command: VpnCommand): void {
    const rawUp = Number(command.extra['rawUp'] ?? '0');
    const rawDown = Number(command.extra['rawDown'] ?? '0');
    const sessionId = command.extra['sessionId'] ?? '';
    if (!isNaN(rawUp) && !isNaN(rawDown) && (rawUp > 0 || rawDown > 0)) {
      this.notificationBaseline = buildBaseline(rawUp, rawDown, sessionId, Date.now());
    } else {
      this.notificationBaseline = null;
    }
    this.publishTrafficTotals();
    void this.showConnectedNotification();
  }

  /** 只读读取并校验指定 revision 的快照(checksum 由 parseSnapshot 复核)。 */
  private readSnapshotForApply(revision: number): ConfigSnapshot | null {
    try {
      const dir = SnapshotStore.configDir(this.context);
      const path = `${dir}/config-snapshot-${revision}.json`;
      if (!SnapshotStore.exists(path)) {
        return null;
      }
      const text = SnapshotStore.readText(path);
      const parsed: SnapshotParseResult = parseSnapshot(text);
      if (!parsed.ok || parsed.snapshot === null) {
        LogStore.addLog(`[vpn] 快照解析失败 revision=${revision}: ${parsed.error}`);
        return null;
      }
      if (parsed.snapshot.revision !== revision) {
        LogStore.addLog(`[vpn] 快照 revision 不符: 期望 ${revision} 实际 ${parsed.snapshot.revision}`);
        return null;
      }
      return parsed.snapshot;
    } catch (e) {
      LogStore.addLog(`[vpn] 读取快照异常 revision=${revision}: ${errText(e)}`);
      return null;
    }
  }

  /**
   * 本地(Preferences)设置必须已写入目标快照，否则重启也只会加载旧设置。
   * 返回空串=一致；否则返回第一个不一致的键(不含值，避免把密码写进日志)。
   */
  private settingsMismatchWithSnapshot(snapshot: ConfigSnapshot, current: AppSettings): string {
    try {
      const currentRec = JSON.parse(JSON.stringify(current)) as Record<string, Object>;
      const snapshotRec: Record<string, Object> = snapshot.content.settings;
      const currentKeys = Object.keys(currentRec);
      for (let i = 0; i < currentKeys.length; i++) {
        const key = currentKeys[i];
        const snapshotHasKey = Object.keys(snapshotRec).indexOf(key) >= 0;
        if (!snapshotHasKey) {
          return `settings.${key}(missing_in_snapshot)`;
        }
        const a = JSON.stringify(currentRec[key]);
        const b = JSON.stringify(snapshotRec[key]);
        if (a !== b) {
          return `settings.${key}`;
        }
      }
      return '';
    } catch (e) {
      return `compare_failed`;
    }
  }

  /** 应用事务回执统一入口(信封带 operationId + appliedRevision)。 */
  private publishApplyResult(ok: boolean, operationId: string, appliedRevision: number,
    perAppSummary: string, error: string): void {
    const env = this.nextEnvelope(operationId);
    if (env !== null) {
      env.appliedRevision = appliedRevision;
      env.configHash = '';
    }
    publishVpnApplied(ok, perAppSummary, env, error);
    if (!ok && error.length > 0) {
      LogStore.addLog(`[vpn] 应用事务未生效: ${error} (operationId=${operationId})`);
    }
  }

  /**
   * 启动前配置校验(K1 `CoreManager.checkConfig`:只解析 schema,不启动实例、不联网)。
   * 通过 = 返回;'unsupported' = 旧 .so 无导出,能力降级放行(如实记日志);
   * 其余 = 抛错 → tryStart 捕获后 teardown 并报 connect_failed,**不会创建 TUN**。
   */
  private async checkConfigGate(configPath: string): Promise<void> {
    let res = '';
    try {
      res = await withTimeout(CoreManager.checkConfig(configPath), 15000, '配置校验');
    } catch (e) {
      LogStore.addLog(`[vpn] 配置校验不可用,跳过(能力降级): ${errText(e)}`);
      return;
    }
    if (res.length === 0) {
      LogStore.addLog('[vpn] 配置校验通过');
      return;
    }
    if (res === 'unsupported') {
      LogStore.addLog('[vpn] 内核无 checkConfig 导出(旧 .so),跳过配置校验');
      return;
    }
    const detail = res.startsWith('err:') ? res.substring('err:'.length) : res;
    throw new Error(`配置校验未通过(未启动 VPN): ${detail}`);
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
      // 强制丢弃本进程的 Preferences 读缓存再重新加载:UI 进程改过设置(分应用名单、
      // 出站模式、DNS 等)后,常驻的扩展进程不刷新就永远读到旧快照。这里每次启动
      // 都重新从磁盘读,是分应用"改了不生效"的通用兜底。
      await refreshStore(context);
      const pendingId = this.latestRequestedProfileId.length > 0
        ? this.latestRequestedProfileId : await getPendingProfileId();
      if (this.started) {
        if (pendingId.length === 0) {
          // UI 进程可能刚被系统回收重建(AppStorage 已重置),必须重播当前状态,
          // 否则 UI 永远停在「连接中」——这是闲置后无法启动的主要根因。
          LogStore.addLog('[vpn] 已在运行且没有新的启动目标,忽略重复触发并重播已连接状态');
          this.publishStatus(`connected:${this.currentNodeName}`, true, this.currentRunId);
          return;
        }
        if (pendingId === this.currentRunId && !this.forceRestartRequested) {
          LogStore.addLog('[vpn] 已在运行且节点未变化,忽略重复触发并重播已连接状态');
          this.publishStatus(`connected:${this.currentNodeName}`, true, this.currentRunId);
          await clearPendingProfileId();
          return;
        }
        const restartReason: string = pendingId === this.currentRunId ? '模式变更' : '节点切换';
        this.forceRestartRequested = false;
        LogStore.addLog(`[vpn] 检测到${restartReason},串行重启内核…`);
        this.publishStatus('switching', true, pendingId);
        await this.teardown(true);
        this.starting = true;
        await this.startVpn(context, pendingId, generation);
      } else {
        await this.startVpn(context, pendingId, generation);
      }
    } catch (e) {
      const msg = errText(e);
      LogStore.addLog(`[vpn] 启动失败: ${msg}`);
      this.stopTrafficStream();
      this.cancelNotification();
      await clearPendingProfileId();
      await this.teardown(true);
      this.publishStatus(`connect_failed:${msg}`, false);
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
      this.stopTrafficStream();
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
    // 通知只显示速率 + 运行时长(用户 2026-10-23 要求去掉节点名/分组名),不再为通知取分组名
    LogStore.addLog(`[vpn] 准备连接: ${node.name} (${node.server}:${node.serverPort}) [mode=${settings.mode} mtu=${settings.mtu} stack=${TUN_STACK} mixed=${settings.mixedPort}]`);

    /* GeoSite/GeoIP 后台自动更新(2026-10-26):隧道起来后异步刷新,7 天过期 + 1 小时节流。
       不 await、失败只写日志与消息,绝不影响本次连接。 */
    autoUpdateGeoAssets(this.context).then((geoResult: string) => {
      if (geoResult === 'updated') {
        LogStore.addLog('[vpn] Geo 数据已自动更新(geosite-cn / geoip-cn),下次连接生效');
        addMessage('geo', 'Geo 数据已自动更新', 'geosite-cn / geoip-cn 已在后台刷新,下次连接生效。')
          .catch((e: Error) => LogStore.addLog(`[vpn] Geo 更新消息写入失败: ${e.message}`));
      }
    }).catch((e: Error) => {
      LogStore.addLog(`[vpn] Geo 自动更新失败(下次连接重试): ${e.message}`);
    });

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
    // ---- 2.5 分应用代理(策略校验 + VPN 框架原生支持) ----
    // 名单优先级:Want 直达(UI 刚下发的当前值)> 磁盘设置(冷启动/自动连接)。
    // W07(§8.2):启动前校验必须执行与 UI 侧同一纯策略函数 evaluatePerAppPolicy;
    // Want 分支只有 CSV,先转成 entries JSON 再评估,保证 Want/读盘两条分支判定同构。
    // (2026-10-24 整改:旧实现名单为空时静默"全部应用按路由规则处理",include 空名单
    //  会把全部应用拉进 VPN —— 现改为 blocked,由 tryStart 统一发布 connect_failed。)
    const perAppMode = this.wantPerAppProvided ? this.wantPerAppMode : settings.perAppMode;
    const rawPerAppCsv = this.wantPerAppProvided ? this.wantPerAppList : settings.perAppList;
    const perAppEntriesJson = serializeEntries(entriesFromLegacyList(rawPerAppCsv));
    const policy = evaluatePerAppPolicy(perAppMode, perAppEntriesJson, currentSdkApiLevel());
    LogStore.addLog(`[vpn] 分应用: 模式=${policy.mode} 来源=${this.wantPerAppProvided ? 'want' : 'settings'} 有效=${policy.count} 上限=${policy.limit} 过滤=${policy.dropped.length} 个`);
    if (policy.blocked) {
      const msg = perAppBlockMessage(policy);
      LogStore.addLog(`[vpn] 分应用策略未通过(${policy.blockReason}): ${msg}`);
      // 不建 TUN、不启动内核:抛给 tryStart 统一 teardown 并 publishStatus(connect_failed:…)
      throw new Error(msg);
    }
    this.lastPerAppSummary = policy.mode === 'off'
      ? '全应用走 VPN'
      : `${policy.mode === 'include' ? '仅代理' : '排除'} ${policy.count} 个应用(上限 ${policy.limit})`;
    if (policy.mode === 'exclude' && policy.effectivePackages.length === 0) {
      LogStore.addLog('[vpn] 分应用(排除): 当前没有排除应用');
    }
    if (policy.mode === 'exclude' && policy.effectivePackages.length > 0) {
      config.blockedApplications = policy.effectivePackages; // 这些应用不走 VPN
      LogStore.addLog(`[vpn] 分应用(排除): ${policy.effectivePackages.join(', ')}`);
    } else if (policy.mode === 'include' && policy.effectivePackages.length > 0) {
      config.trustedApplications = policy.effectivePackages; // 仅这些应用走 VPN
      LogStore.addLog(`[vpn] 分应用(仅这些): ${policy.effectivePackages.join(', ')}`);
    }

    // ---- 3. 资源预处理 → 生成配置(启动与网络解耦) ----
    // 方案 docs/REMOTE_RULESET_ARCHITECTURE_REFACTOR_PLAN.md:
    //   load settings → prepareResources → build config(local rule_set) → checkConfig → startCore
    const logPath = CoreManager.resetLogFile(context);

    // :vpn 扩展是**独立进程**(静态字段不共享),资源仓库必须在本进程 init;
    // 目录(应用私有 filesDir/config/resources)与 UI 进程共用。validator 桥接让扩展侧
    // 下载的规则集能拿到「已验证」资格,否则默认策略下永远不可用。
    ResourceResolver.ensureRepository(context,
      (path: string): Promise<string> => CoreManager.validateSrs(path));

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
        LogStore.addLog(`[vpn] 读取远程规则集 ${enabledRuleSetCount} 个(启动前统一准备本地缓存)`);
      }
    } catch (e) {
      LogStore.addLog('[vpn] 读取远程规则集失败,本次连接忽略');
    }

    // 统一资源准备:geosite/geoip + 远程规则集。
    // 启动阶段严格只读本地资源，不执行 HTTP/DNS/TLS；缺失资源在内核启动后后台刷新。
    const prepareOptions = new PrepareOptions();
    prepareOptions.allowDownload = false;
    prepareOptions.withGeo = settings.mode === 'rule';
    prepareOptions.budgetMs = 0;
    let prepared: PreparedResources = new PreparedResources();
    try {
      prepared = await ResourceResolver.prepareResources(context, remoteRuleSets, prepareOptions);
    } catch (e) {
      LogStore.addLog(`[vpn] 资源准备异常(已降级为无规则集启动): ${errText(e)}`);
    }
    if (prepared.geoEnabled) {
      LogStore.addLog('[vpn] Geo 分流数据就绪,cn 直连分流已启用');
    } else if (settings.mode === 'rule') {
      LogStore.addLog('[vpn] Geo 数据不可用,规则模式仅私网/自定义直连' +
        (prepared.warning.length > 0 ? `(${prepared.warning})` : ''));
    }
    if (remoteRuleSets.length > 0) {
      let enabledCount = 0;
      for (const item of remoteRuleSets) {
        if (item.enabled) {
          enabledCount++;
        }
      }
      LogStore.addLog(`[vpn] 规则集准备完成: 可用 ${prepared.availableCount}/${enabledCount}` +
        ` 不可用 ${prepared.unavailableCount} 本次补缓存 ${prepared.downloadedCount}`);
      if (prepared.warning.length > 0) {
        LogStore.addLog(`[vpn] 规则集降级说明: ${prepared.warning}`);
      }
      for (let i = 0; i < prepared.ruleSets.length; i++) {
        const item: PreparedRuleSet = prepared.ruleSets[i];
        const source = remoteRuleSets[i];
        if (!item.available) {
          const label = source !== undefined && source.name.length > 0 ? source.name : item.resourceId;
          LogStore.addLog(`[vpn] 规则集不可用,本次不进入配置: ${label}` +
            `(${item.reason}${item.error.length > 0 ? ` ${item.error}` : ''})`);
        } else if (item.fromCache) {
          LogStore.addLog(`[vpn] 规则集使用本地缓存: ${item.tag} → ${item.path}`);
        } else {
          LogStore.addLog(`[vpn] 规则集已就绪: ${item.tag} → ${item.path}`);
        }
      }
    }

    const cachePath = logPath.length > 0 ? logPath.substring(0, logPath.lastIndexOf('/') + 1) + 'cache.db' : '';
    /* Web 面板(yacd,对齐 OwnBox DashboardManager/LocalYacdDashboard):把 HAP 内置的
       rawfile/yacd.zip 解压到沙箱,路径交给内核 clash_api.external_ui 静态托管。
       解压失败只丢面板,不能影响建隧道 —— 所以整段 best-effort。 */
    let webUiPath = '';
    if (settings.clashApiEnabled) {
      try {
        webUiPath = await ensureYacdExtracted(this.context);
        LogStore.addLog(webUiPath.length > 0
          ? `[vpn] Web 面板目录就绪: ${webUiPath}`
          : '[vpn] Web 面板资源不可用(不影响代理)');
      } catch (e) {
        LogStore.addLog(`[vpn] Web 面板准备失败(不影响代理): ${e instanceof Error ? e.message : `${e}`}`);
      }
    }
    /* 原始配置覆盖(对齐 OwnBox ConfigEditActivity):用户显式编辑过就优先用它。
       只在「JSON 能解析 + 含 outbounds 数组」时采纳;否则回退生成配置并写日志,
       避免一个手滑的括号让整个 VPN 起不来。 */
    let configJson = '';
    const rawOverride = await readRawConfigOverride(node.id);
    if (rawOverride.trim().length > 0) {
      try {
        const parsedOverride = JSON.parse(rawOverride) as Record<string, Object>;
        if (parsedOverride !== null && parsedOverride !== undefined
          && parsedOverride['outbounds'] !== undefined) {
          configJson = rawOverride;
          LogStore.addLog('[vpn] 使用原始配置覆盖(raw config override)');
        } else {
          LogStore.addLog('[vpn] 原始配置覆盖缺少 outbounds,已回退生成的配置');
        }
      } catch (e) {
        LogStore.addLog(`[vpn] 原始配置覆盖解析失败,已回退生成的配置: ${e instanceof Error ? e.message : `${e}`}`);
      }
    }
    if (configJson.length === 0) {
      configJson = buildCoreConfig(node, settings, ifname, logPath, prepared.geositePath,
        prepared.geoIpPath, customRules, prepared.ruleSets, cachePath, profiles, groups, webUiPath);
    }
    const configPath = CoreManager.writeConfigFile(context, configJson);
    LogStore.addLog(`[vpn] sing-box 配置已写入 ${configPath}`);
    // ---- 3.2 固定本次会话使用的资源文件(方案 §7) ----
    // 后台刷新会写入新版本目录，但内核仍可能在读旧文件；固定后版本裁剪/GC 不会删它们。
    ResourceResolver.pinSessionFiles(prepared);

    // ---- 3.5 启动前配置校验(K1 纯解析):不通过则直接报错,不建 TUN、不启动 VPN ----
    await this.checkConfigGate(configPath);

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
    this.publishStatus('awaiting_auth', false);
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
    const notifySettings: AppSettings = await loadSettings();
    this.notifyShowProfile = notifySettings.notificationShowProfile;
    this.notifyShowGroup = notifySettings.notificationGroup;
    this.notifyGroupLabel = '';
    if (this.notifyShowGroup) {
      const notifyGroups: Array<ProfileGroup> = await loadGroups();
      const notifyGroup: ProfileGroup | undefined =
        notifyGroups.find((g: ProfileGroup) => g.id === node.groupId);
      this.notifyGroupLabel = notifyGroup !== undefined ? notifyGroup.name : '';
    }
    await setRunningProfileId(pendingId);
    // ---- 5.5 后台刷新(方案第五阶段):只补缓存,失败保留旧缓存,不影响当前会话 ----
    void ResourceResolver.refreshInBackground(remoteRuleSets);
    this.notificationLatencyMs = -1;
    this.notificationStartedAt = Date.now();
    this.lastNotificationLine = '';
    await this.showConnectedNotification();
    void this.startTrafficStream();
    this.publishStatus(`connected:${node.name}`, true, pendingId);
    await clearPendingProfileId();
  }

  private async loadNotificationBaseline(): Promise<TrafficBaseline | null> {
    try {
      const text = await readPrefString('traffic_display_baseline', '');
      return text.length > 0 ? parseBaseline(text) : null;
    } catch (e) {
      return null;
    }
  }

  /** 单流量生产者:内核 /traffic WebSocket(1s 增量)→ 累计/显示/CommonEvent。 */
  private async startTrafficStream(): Promise<void> {
    const startedAt = this.notificationStartedAt;
    this.stopTrafficStream();
    this.notificationStartedAt = startedAt;
    const generation = this.notificationGeneration;
    const settings = this.notificationSettings;
    if (!this.started || settings === null || !settings.clashApiEnabled) {
      return;
    }
    this.trafficMeter.reset(0, 0);
    this.notificationUpSpeed = 0;
    this.notificationDownSpeed = 0;
    /* W20:会话启动读一次显示基准(扩展进程 Preferences 缓存约束:会话中途 UI 重置,
      通知最迟在下一次会话/apply 后同步 —— 已知降级,如实记录) */
    const baseline = await this.loadNotificationBaseline();
    if (generation !== this.notificationGeneration || !this.started) {
      return;
    }
    this.notificationBaseline = baseline;
    this.notificationTotalUp = 0;
    this.notificationTotalDown = 0;
    this.notificationFailStreak = 0;
    this.notificationSynced = false;
    this.trafficStreamFailLogged = false;
    this.notificationPublishAt = 0;
    // 通知刷新间隔(对齐安卓 speedInterval,默认 1000ms,允许 500ms~10s)
    const rawMs = settings.speedIntervalMs;
    this.notificationIntervalMs = rawMs >= 500 && rawMs <= 10000 ? rawMs : 1000;
    const callbacks = new TrafficStreamCallbacks();
    callbacks.onOpen = (): void => {
      this.trafficStreamFailLogged = false;
      void this.resyncTraffic(generation);
    };
    callbacks.onError = (message: string): void => {
      if (!this.trafficStreamFailLogged) {
        this.trafficStreamFailLogged = true;
        LogStore.addLog(`[vpn] 流量流断开,自动重连中: ${message}`);
      }
    };
    callbacks.onDelta = (up: number, down: number): void => {
      if (generation !== this.notificationGeneration || !this.started || !this.notificationSynced) {
        return;
      }
      const delta: TrafficDelta = { up: Math.max(0, Math.floor(up)), down: Math.max(0, Math.floor(down)) };
      this.trafficMeter.add(delta);
      this.notificationUpSpeed = delta.up;
      this.notificationDownSpeed = delta.down;
      this.publishTrafficTotals();
      const now = Date.now();
      if (now - this.notificationPublishAt >= this.notificationIntervalMs) {
        this.notificationPublishAt = now;
        void this.showConnectedNotification();
      }
    };
    const stream = new TrafficStream();
    this.trafficStream = stream;
    stream.start(settings.clashApiPort, settings.clashApiSecret, callbacks);
  }

  /** 用一次 /connections 快照重对齐累计值(会话开始/断线重连),之后只消费 1s 增量。 */
  private async resyncTraffic(generation: number): Promise<void> {
    const settings = this.notificationSettings;
    if (settings === null || generation !== this.notificationGeneration || !this.started) {
      return;
    }
    this.notificationSynced = false;
    const resyncGeneration = ++this.trafficResyncGeneration;
    const totals = await fetchTrafficTotals(settings.clashApiPort, settings.clashApiSecret);
    if (generation !== this.notificationGeneration || resyncGeneration !== this.trafficResyncGeneration || !this.started) {
      return;
    }
    if (totals !== null) {
      this.trafficMeter.reset(totals.up, totals.down);
    }
    this.notificationSynced = true;
    this.publishTrafficTotals();
  }

  /** 由累计值 + 显示基准生成 UI/通知同源数据(W20 口径不变)。 */
  private publishTrafficTotals(): void {
    const rawUp = this.trafficMeter.up();
    const rawDown = this.trafficMeter.down();
    if (baselineStale(rawUp, rawDown, this.notificationBaseline)) {
      this.notificationBaseline = null;
    }
    const shown = displayTotals(rawUp, rawDown, this.notificationBaseline);
    this.notificationTotalUp = shown[0];
    this.notificationTotalDown = shown[1];
    publishVpnTraffic(this.notificationUpSpeed, this.notificationDownSpeed,
      this.notificationTotalUp, this.notificationTotalDown, rawUp, rawDown);
  }

  private stopTrafficStream(): void {
    this.notificationGeneration++;
    const stream = this.trafficStream;
    this.trafficStream = null;
    if (stream !== null) {
      stream.stop();
    }
    this.notificationSynced = false;
    // 当前实现仅清理会话内流量计数器；节点历史统计未在此处更新。
    // 若后续恢复 Profile.rx/tx 统计，需要在重置前显式落盘累计值。
    this.trafficMeter.reset(0, 0);
    this.notificationUpSpeed = 0;
    this.notificationDownSpeed = 0;
    this.notificationTotalUp = 0;
    this.notificationTotalDown = 0;
    this.notificationStartedAt = 0;
    this.lastNotificationLine = '';
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

  /** 常驻通知:标题=已连接,正文=**实时速率**,附加行=**节点名[ · 分组名] · 运行时长**,
   *  右侧"断开"按钮。节点名/分组由设置页开关控制(notificationShowProfile / notificationGroup,
   *  对齐 OwnBox ServiceNotification;关掉就只剩时长,回到 2026-10-23 的简洁形态)。 */
  private notificationSubtitle(uptimeLabel: string, elapsedMs: number): string {
    const uptime: string = formatUptimeText(elapsedMs);
    if (!this.notifyShowProfile || this.currentNodeName.length === 0) {
      return `${uptimeLabel} ${uptime}`;
    }
    const parts: Array<string> = [this.currentNodeName];
    if (this.notifyShowGroup && this.notifyGroupLabel.length > 0) {
      parts.push(this.notifyGroupLabel);
    }
    parts.push(uptime);
    return parts.join(' · ');
  }

  private async showConnectedNotification(): Promise<void> {
    const generation = this.notificationGeneration;
    if (!this.started || this.notificationFailStreak >= 5) {
      return; // 连续 5 次发布失败(通知权限被关):本会话内停用周期通知,流量统计不受影响
    }
    try {
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
      if (generation !== this.notificationGeneration || !this.started) {
        return;
      }
      // 本机 SDK(API 24)通知字段为 string 类型,不接受 Resource:构建时现取本地化字符串
      const res = this.context.resourceManager;
      const uploadLabel = res.getStringSync($r('app.string.notification_upload'));
      const downloadLabel = res.getStringSync($r('app.string.notification_download'));
      const uptimeLabel = res.getStringSync($r('app.string.notification_uptime'));
      const speedText = `${uploadLabel} ${this.formatNotificationSpeed(this.notificationUpSpeed)} / ` +
        `${downloadLabel} ${this.formatNotificationSpeed(this.notificationDownSpeed)}`;
      const elapsedMs = this.notificationStartedAt > 0 ? Date.now() - this.notificationStartedAt : 0;
      const uptimeText = this.notificationSubtitle(uptimeLabel, elapsedMs);
      // 仅在内容变化时记一条:通知栏实际显示什么,真机排查(及本轮验收)都能直接对着日志核
      const contentLine = `${speedText} | ${uptimeText}`;
      if (contentLine !== this.lastNotificationLine) {
        this.lastNotificationLine = contentLine;
        LogStore.addLog(`[vpn] 通知内容: ${contentLine}`);
      }
      const content: notificationManager.NotificationContent = {
        contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: res.getStringSync($r('app.string.notification_vpn_connected')),
          text: speedText,
          additionalText: uptimeText
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
