import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import notificationManager from '@ohos.notificationManager';
import BusinessError from '@ohos.base';
import { initStore, LogStore } from '../model/Store';
import { subscribeVpnEvents } from '../core/VpnIpc';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogStore.addLog('[app] NekoBox 启动');
    initStore(this.context).catch((e: Error) => {
      LogStore.addLog(`[app] 初始化存储失败: ${e.message}`);
    });
    // 请求通知权限(常驻通知用),用户拒绝也不影响功能
    try {
      notificationManager.requestEnableNotification(this.context, (err: BusinessError) => {
        if (err && err.code !== 0) {
          LogStore.addLog(`[app] 通知权限未授予: ${err.code}`);
        }
      });
    } catch (e) {
      // ignore
    }
    // 接收 :vpn 扩展进程发来的日志与状态
    subscribeVpnEvents((line: string) => {
      LogStore.appendRemote(line);
    }, (status: string, running: boolean, profileId: string) => {
      AppStorage.setOrCreate('vpnRunning', running);
      AppStorage.setOrCreate('vpnStatus', status);
      AppStorage.setOrCreate('vpnRunningProfileId', profileId);
    });
  }

  onDestroy(): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        return;
      }
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
