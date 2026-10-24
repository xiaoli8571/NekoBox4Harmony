import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import deviceInfo from '@ohos.deviceInfo';
import { setPendingProfileId, clearPendingProfileId, loadSettings, LogStore } from '../model/Store';
import { evaluatePerAppPolicy, perAppBlockMessage } from '../model/PerAppPolicy';


/**
 * UI 进程侧的 VPN 开关:只负责把请求转给 VpnExtensionAbility。
 * 真正的 TUN/内核生命周期在 VpnExtAbility.ets 中完成。
 */

function wantFor(context: common.UIAbilityContext, profileId: string = '', forceRestart: boolean = false,
  perAppMode: string = '', perAppPackages: string = '', perAppProvided: boolean = false): Want {
  const w: Want = {
    bundleName: context.abilityInfo.bundleName,
    abilityName: 'VpnExtAbility'
  };
  // 节点 ID / 强制重启经 Want 直达扩展，避免依赖跨进程 Preferences 缓存。
  const params: Record<string, Object> = {
    'profileId': profileId,
    'forceRestart': forceRestart
  };
  // 分应用名单必须走 Want:VpnExtensionAbility 与 UI 是**两个进程**,而 Preferences
  // 的读缓存是进程内的 —— 扩展进程常驻期间 UI 改名单它看不到,这正是真机「填了
  // 包名却不分流」的根因(profileId 早就因同一个坑改走 Want)。
  // perAppProvided 为 false 时必须**不带这两个键**:扩展据此区分"UI 明确下发
  // 的名单(可能为空=本次不限制)"与"UI 读设置失败、请自行从磁盘读",否则一次
  // 读取失败就会把磁盘上有效的 exclude 名单覆盖成空。
  if (perAppProvided) {
    params['perAppMode'] = perAppMode;
    params['perAppList'] = perAppPackages;
  }
  w.parameters = params;
  return w;
}

/**
 * §8.4:分应用名单上限按系统 API 版本选择(API<23 → 64,API>=23 → 256)。
 * 读不到 sdkApiVersion 时按 23 处理并写日志注明(保守兜底:23 起上限翻倍,
 * 取不到按较小口径只会"更早拦截",不会放行超限名单)。
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
  LogStore.addLog('[app] 读取 sdkApiVersion 失败,分应用上限按 API 23(256)处理');
  return 23;
}

export class VpnService {
  private static operation: Promise<void> = Promise.resolve();
  private static generation: number = 0;
  private static evidenceWatchdog: number = -1;
  private static timeoutWatchdog: number = -1;

  private static clearWatchdogs(): void {
    if (VpnService.evidenceWatchdog >= 0) {
      clearTimeout(VpnService.evidenceWatchdog);
      VpnService.evidenceWatchdog = -1;
    }
    if (VpnService.timeoutWatchdog >= 0) {
      clearTimeout(VpnService.timeoutWatchdog);
      VpnService.timeoutWatchdog = -1;
    }
  }

  static async connect(context: common.UIAbilityContext, profileId: string, forceRestart: boolean = false): Promise<void> {
    const generation = ++VpnService.generation;
    VpnService.clearWatchdogs();
    AppStorage.setOrCreate('vpnUpSpeed', 0);
    AppStorage.setOrCreate('vpnDownSpeed', 0);
    AppStorage.setOrCreate('vpnTotalUp', 0);
    AppStorage.setOrCreate('vpnTotalDown', 0);
    const previous = VpnService.operation;
    VpnService.operation = (async (): Promise<void> => {
      try {
        await previous;
      } catch (e) {
        // A failed previous operation must not block later user requests.
      }
    await setPendingProfileId(profileId);
    AppStorage.setOrCreate('vpnStatus', 'connecting');
    // 当前分应用名单随启动请求一起下发(见 wantFor 注释:跨进程 Preferences 不可靠)。
    // 读取失败时 perAppProvided 保持 false —— 扩展侧 refreshStore 后仍能从磁盘拿到名单,
    // 绝不把磁盘上已有的有效名单覆盖成空。
    let perAppMode = '';
    let perAppPackages = '';
    let perAppProvided = false;
    // W07(§8.2/§8.4):连接前用纯策略函数评估一次(include 空名单/超限拦截);
    // 与扩展侧 startVpn() 的启动前校验执行**同一**纯函数 evaluatePerAppPolicy。
    let blockedMessage = '';
    let blockedToken = '';
    try {
      const settings = await loadSettings();
      const policy = evaluatePerAppPolicy(settings.perAppMode, settings.perAppEntries, currentSdkApiLevel());
      LogStore.addLog(`[app] 分应用策略: 模式=${policy.mode} 有效=${policy.count} 上限=${policy.limit} 过滤=${policy.dropped.length} 个`);
      if (policy.blocked) {
        blockedMessage = perAppBlockMessage(policy);
        blockedToken = policy.blockReason;
      } else {
        // 下发归一后的 mode(与扩展侧 policy.mode 一致),避免把脏模式名经 Want 传下去
        perAppMode = policy.mode;
        perAppPackages = policy.effectivePackages.join(',');
        perAppProvided = true;
      }
    } catch (e) {
      LogStore.addLog(`[app] 读取分应用名单失败,交由扩展自行读取: ${e}`);
    }
    if (blockedMessage.length > 0) {
      // §8.2:include 空名单/超限 → 不启动扩展,沿用 vpnStatus 失败约定(connect_failed:<文案>)。
      // 不动 vpnRunning:强制切换场景下旧会话仍在跑旧配置,不能谎报断开(§8.3 维持待应用)。
      await clearPendingProfileId();
      AppStorage.setOrCreate('vpnStatus', `connect_failed:${blockedMessage}`);
      LogStore.addLog(`[app] 分应用策略拦截连接(${blockedToken}): ${blockedMessage}`);
      throw new Error(blockedMessage);
    }
    try {
      await vpnExtension.startVpnExtensionAbility(
        wantFor(context, profileId, forceRestart, perAppMode, perAppPackages, perAppProvided));
      LogStore.addLog('[app] startVpnExtensionAbility 已调用,等待扩展回调…');
      /* 后台保活(2026-10-23 整改,依据 docs/REA-FLCLASH-KEEPALIVE.md):
       * VPN 会话**不再**申请长时任务。TASK_KEEPING 在 phone/tablet 上必需受限 ACL
       * KEEP_BACKGROUND_RUNNING_SYSTEM(个人开发者拿不到);DATA_TRANSFER 是上传/下载任务,
       * 10 分钟无 live view 进度通知会被系统取消 —— 都不适合"会话级保活"。
       * 会话存活靠 VpnExtensionAbility(系统托管,:vpn 进程)+ 常驻通知 + 被杀自愈(CrashGuard)。 */
    } catch (e) {
      await clearPendingProfileId();
      AppStorage.setOrCreate('vpnRunning', false);
      const msg = e instanceof Error ? e.message : `${e}`;
      AppStorage.setOrCreate('vpnStatus', `start_failed:${msg}`);
      LogStore.addLog(`[app] startVpnExtensionAbility 失败: ${msg}`);
      throw new Error(msg);
    }
    // 看门狗只报告控制面状态丢失，不再主动断开可能已经正常工作的 VPN。
    // 真机日志已证明 CommonEvent 丢失时 TUN、DNS 和代理数据面仍可能完全可用。
    VpnService.evidenceWatchdog = setTimeout(() => {
      VpnService.evidenceWatchdog = -1;
      if (generation !== VpnService.generation) {
        return;
      }
      const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      const status: string = AppStorage.get<string>('vpnStatus') ?? '';
      if (!running && status === 'connecting') {
        const upSpeed: number = AppStorage.get<number>('vpnUpSpeed') ?? 0;
        const downSpeed: number = AppStorage.get<number>('vpnDownSpeed') ?? 0;
        const totalUp: number = AppStorage.get<number>('vpnTotalUp') ?? 0;
        const totalDown: number = AppStorage.get<number>('vpnTotalDown') ?? 0;
        const hasDataPlaneEvidence = upSpeed > 0 || downSpeed > 0 || totalUp > 0 || totalDown > 0;
        if (hasDataPlaneEvidence) {
          AppStorage.setOrCreate('vpnRunning', true);
          AppStorage.setOrCreate('vpnRunningProfileId', profileId);
          // 保持与 UI 状态机约定一致：已连接状态必须使用 connected:<描述> 格式。
          AppStorage.setOrCreate('vpnStatus', 'connected:running');
          LogStore.addLog('[app] VPN 状态回调缺失，但已检测到流量，按数据面状态恢复为已连接');
        }
      }
    }, 60000);
    // 长时间闲置后扩展可能对启动请求完全无响应(进程被回收/冻结残留),
    // 120s 仍停留在 connecting 就明确报错并解锁按钮,避免永远转圈。
    VpnService.timeoutWatchdog = setTimeout(() => {
      VpnService.timeoutWatchdog = -1;
      if (generation !== VpnService.generation) {
        return;
      }
      const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      const status: string = AppStorage.get<string>('vpnStatus') ?? '';
      if (!running && status === 'connecting') {
        AppStorage.setOrCreate('vpnStatus', 'connect_failed:启动超时,VPN 扩展无响应,请重试或重启应用');
        AppStorage.setOrCreate('vpnRunning', false);
        LogStore.addLog('[app] 启动 120s 超时:扩展始终无状态回调,已解锁重试');
      }
    }, 120000);
    })();
    return VpnService.operation;
  }

  static async disconnect(context: common.UIAbilityContext): Promise<void> {
    ++VpnService.generation;
    VpnService.clearWatchdogs();
    const previous = VpnService.operation;
    VpnService.operation = (async (): Promise<void> => {
      try {
        await previous;
      } catch (e) {
        // Continue with teardown even if startup failed.
      }
    AppStorage.setOrCreate('vpnStatus', 'disconnecting');
    /* 长时任务只服务真实数据传输(订阅更新/Geo 下载),与 VPN 会话无关,这里无需释放。 */
    try {
      await vpnExtension.stopVpnExtensionAbility(wantFor(context));
    } catch (e) {
      LogStore.addLog(`[app] stopVpnExtensionAbility 失败: ${e}`);
    }
    await clearPendingProfileId();
    AppStorage.setOrCreate('vpnRunning', false);
    AppStorage.setOrCreate('vpnRunningProfileId', '');
    AppStorage.setOrCreate('vpnStatus', 'disconnected');
    })();
    return VpnService.operation;
  }

  /** 运行中切换节点:把目标节点交给扩展，由扩展在同一实例内串行重启。 */
  static async switchTo(context: common.UIAbilityContext, profileId: string): Promise<void> {
    AppStorage.setOrCreate('vpnStatus', 'switching');
    LogStore.addLog('[app] 切换节点:交由扩展串行重启');
    await VpnService.connect(context, profileId, true);
  }
}
