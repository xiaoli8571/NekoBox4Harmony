import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { setPendingProfileId, clearPendingProfileId, loadSettings, LogStore } from '../model/Store';
import { fetchTrafficTotals } from '../utils/TrafficStats';

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
    // CommonEvent 在部分真机上可能丢失。此时以内核 Clash API 可访问作为数据面已就绪的可靠兜底，
    // 同步修正 UI 运行状态并启动首页统计，不把正常工作的 VPN 挂在 connecting。
    let probeCount: number = 0;
    const probeDataPlane = async (): Promise<void> => {
      if (generation !== VpnService.generation) {
        return;
      }
      const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      const status: string = AppStorage.get<string>('vpnStatus') ?? '';
      if (running || (status !== 'connecting' && status !== 'awaiting_auth')) {
        return;
      }
      try {
        const settings = await loadSettings();
        const totals = await fetchTrafficTotals(settings.clashApiPort, settings.clashApiSecret);
        if (totals !== null) {
          AppStorage.setOrCreate('vpnRunning', true);
          AppStorage.setOrCreate('vpnRunningProfileId', profileId);
          AppStorage.setOrCreate('vpnStatus', 'connected');
          LogStore.addLog('[app] VPN 状态事件未同步，已通过 Clash API 确认数据面就绪');
          return;
        }
      } catch (e) {
        // API 尚未就绪时继续有限重试。
      }
      probeCount++;
      if (probeCount < 30) {
        setTimeout(probeDataPlane, 2000);
      } else {
        AppStorage.setOrCreate('vpnStatus', 'start_timeout');
        LogStore.addLog('[app] VPN 启动看门狗超时(60s):未收到状态事件且 Clash API 不可用');
      }
    };
    setTimeout(probeDataPlane, 2000);
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
