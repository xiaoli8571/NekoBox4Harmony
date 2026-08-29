import vpnExtension from '@ohos.net.vpnExtension';
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { setPendingProfileId, clearPendingProfileId, LogStore } from '../model/Store';

/**
 * UI 进程侧的 VPN 开关:只负责把请求转给 VpnExtensionAbility。
 * 真正的 TUN/内核生命周期在 VpnExtAbility.ets 中完成。
 */

function wantFor(context: common.UIAbilityContext): Want {
  const w: Want = {
    bundleName: context.abilityInfo.bundleName,
    abilityName: 'VpnExtAbility'
  };
  return w;
}

export class VpnService {
  static async connect(context: common.UIAbilityContext, profileId: string): Promise<void> {
    await setPendingProfileId(profileId);
    AppStorage.setOrCreate('vpnStatus', '正在建立 VPN…');
    try {
      await vpnExtension.startVpnExtensionAbility(wantFor(context));
      LogStore.addLog('[app] startVpnExtensionAbility 已调用,等待扩展回调…');
    } catch (e) {
      await clearPendingProfileId();
      AppStorage.setOrCreate('vpnRunning', false);
      const msg = e instanceof Error ? e.message : `${e}`;
      AppStorage.setOrCreate('vpnStatus', `启动 VPN 服务失败: ${msg}`);
      LogStore.addLog(`[app] startVpnExtensionAbility 失败: ${msg}`);
      throw new Error(msg);
    }
    // 看门狗:扩展长时间无进展时给出明确提示(正常路径中状态会被扩展改写)
    setTimeout(() => {
      const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      const status: string = AppStorage.get<string>('vpnStatus') ?? '';
      if (!running && status === '正在建立 VPN…') {
        AppStorage.setOrCreate('vpnStatus', '建立 VPN 超时:扩展没有完成启动,请到「日志」页查看卡在哪一步');
        LogStore.addLog('[app] VPN 启动看门狗超时(60s):扩展未报告任何进展');
      }
    }, 60000);
  }

  static async disconnect(context: common.UIAbilityContext): Promise<void> {
    AppStorage.setOrCreate('vpnStatus', '正在断开…');
    try {
      await vpnExtension.stopVpnExtensionAbility(wantFor(context));
    } catch (e) {
      LogStore.addLog(`[app] stopVpnExtensionAbility 失败: ${e}`);
    }
    await clearPendingProfileId();
    AppStorage.setOrCreate('vpnRunning', false);
    AppStorage.setOrCreate('vpnRunningProfileId', '');
    AppStorage.setOrCreate('vpnStatus', '已断开');
  }

  /** 运行中切换节点:自动断开 → 等待系统清理 → 自动重连(最稳路径) */
  static async switchTo(context: common.UIAbilityContext, profileId: string): Promise<void> {
    AppStorage.setOrCreate('vpnStatus', '正在切换节点…');
    LogStore.addLog('[app] 切换节点:自动断开后重连');
    await VpnService.disconnect(context);
    // 给系统一点时间完成路由/隧道的拆除,避免立即重建时挂起
    await new Promise<void>((resolve) => {
      setTimeout(resolve, 1500);
    });
    await VpnService.connect(context, profileId);
  }
}
