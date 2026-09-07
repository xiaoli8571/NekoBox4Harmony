import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { setPendingProfileId, clearPendingProfileId, LogStore } from '../model/Store';

/**
 * UI 进程侧的 VPN 开关:只负责把请求转给 VpnExtensionAbility。
 * 真正的 TUN/内核生命周期在 VpnExtAbility.ets 中完成。
 */

function wantFor(context: common.UIAbilityContext, profileId: string = '', forceRestart: boolean = false): Want {
  const w: Want = {
    bundleName: context.abilityInfo.bundleName,
    abilityName: 'VpnExtAbility'
  };
  // 节点 ID 和强制重启标记经 Want 直达扩展，避免依赖跨进程 Preferences 缓存。
  if (profileId.length > 0 || forceRestart) {
    const params: Record<string, Object> = {
      'profileId': profileId,
      'forceRestart': forceRestart
    };
    w.parameters = params;
  }
  return w;
}

export class VpnService {
  private static operation: Promise<void> = Promise.resolve();
  private static generation: number = 0;

  static async connect(context: common.UIAbilityContext, profileId: string, forceRestart: boolean = false): Promise<void> {
    const generation = ++VpnService.generation;
    const previous = VpnService.operation;
    VpnService.operation = (async (): Promise<void> => {
      try {
        await previous;
      } catch (e) {
        // A failed previous operation must not block later user requests.
      }
    await setPendingProfileId(profileId);
    AppStorage.setOrCreate('vpnStatus', 'connecting');
    try {
      await vpnExtension.startVpnExtensionAbility(wantFor(context, profileId, forceRestart));
      LogStore.addLog('[app] startVpnExtensionAbility 已调用,等待扩展回调…');
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
    setTimeout(() => {
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
    setTimeout(() => {
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
    const previous = VpnService.operation;
    VpnService.operation = (async (): Promise<void> => {
      try {
        await previous;
      } catch (e) {
        // Continue with teardown even if startup failed.
      }
    AppStorage.setOrCreate('vpnStatus', 'disconnecting');
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
