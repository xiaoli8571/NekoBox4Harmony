import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { setPendingProfileId, clearPendingProfileId, LogStore } from '../../model/Store';
import { ProfileStorage } from '../storage/ProfileStorage';
import { ConnectionState } from '../model/ConnectionState';
import { ConnectionStateManager } from '../manager/ConnectionStateManager';

function wantFor(context: common.UIAbilityContext, profileId: string = ''): Want {
  const w: Want = {
    bundleName: context.abilityInfo.bundleName,
    abilityName: 'VpnExtAbility'
  };
  if (profileId.length > 0) {
    const params: Record<string, Object> = { 'profileId': profileId };
    w.parameters = params;
  }
  return w;
}

/** UI 进程侧 VPN 生命周期服务；请求仍串行执行。 */
export class VpnService {
  private static operation: Promise<void> = Promise.resolve();
  private static generation: number = 0;

  static async connect(context: common.UIAbilityContext, profileId: string): Promise<void> {
    const generation = ++VpnService.generation;
    const previous = VpnService.operation;
    VpnService.operation = (async (): Promise<void> => {
      try {
        await previous;
      } catch (e) {
        // A failed previous operation must not block later user requests.
      }
      ConnectionStateManager.transition(ConnectionState.CONNECTING);
      // 首次点击可能早于 EntryAbility 的异步初始化；在写 pending 前确保
      // Preferences 已就绪，避免请求节点 ID 丢失。
      await ProfileStorage.initialize(context);
      await setPendingProfileId(profileId);
      AppStorage.setOrCreate('vpnStatus', '正在建立 VPN…');
      try {
        await vpnExtension.startVpnExtensionAbility(wantFor(context, profileId));
        LogStore.addLog('[app] startVpnExtensionAbility 已调用,等待扩展回调…');
      } catch (e) {
        await clearPendingProfileId();
        AppStorage.setOrCreate('vpnRunning', false);
        ConnectionStateManager.transition(ConnectionState.IDLE);
        const msg = e instanceof Error ? e.message : `${e}`;
        AppStorage.setOrCreate('vpnStatus', `启动 VPN 服务失败: ${msg}`);
        LogStore.addLog(`[app] startVpnExtensionAbility 失败: ${msg}`);
        throw new Error(msg);
      }
      setTimeout(() => {
        if (generation !== VpnService.generation) {
          return;
        }
        const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
        const status: string = AppStorage.get<string>('vpnStatus') ?? '';
        if (!running && status === '正在建立 VPN…') {
          AppStorage.setOrCreate('vpnStatus', '建立 VPN 超时:扩展没有完成启动,请到「日志」页查看卡在哪一步');
          LogStore.addLog('[app] VPN 启动看门狗超时(60s):扩展未报告任何进展');
          VpnService.disconnect(context);
        }
      }, 60000);
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
      ConnectionStateManager.transition(ConnectionState.DISCONNECTING);
      AppStorage.setOrCreate('vpnStatus', '正在断开…');
      await ProfileStorage.initialize(context);
      try {
        await vpnExtension.stopVpnExtensionAbility(wantFor(context));
      } catch (e) {
        LogStore.addLog(`[app] stopVpnExtensionAbility 失败: ${e}`);
      }
      await clearPendingProfileId();
      AppStorage.setOrCreate('vpnRunning', false);
      AppStorage.setOrCreate('vpnRunningProfileId', '');
      AppStorage.setOrCreate('vpnStatus', '已断开');
      // vpnConnectedAt 由 EntryAbility 在扩展实际发布“已断开”事件时统一
      // 更新；请求侧不要提前清零，否则页面重建/断开重连期间会丢失会话时序。
      AppStorage.setOrCreate('vpnUpSpeed', 0);
      AppStorage.setOrCreate('vpnDownSpeed', 0);
      AppStorage.setOrCreate('vpnTotalUp', 0);
      AppStorage.setOrCreate('vpnTotalDown', 0);
      ConnectionStateManager.transition(ConnectionState.IDLE);
    })();
    return VpnService.operation;
  }

  /** 保持稳定路径：断开 → 等待 1.5 秒 → 重连，不做运行中热切换。 */
  static async switchTo(context: common.UIAbilityContext, profileId: string): Promise<void> {
    AppStorage.setOrCreate('vpnStatus', '正在切换节点…');
    LogStore.addLog('[app] 切换节点:自动断开后重连');
    await VpnService.disconnect(context);
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 1500);
    });
    await VpnService.connect(context, profileId);
  }
}
