import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import window from '@ohos.window';
import display from '@ohos.display';
import { UiSpec } from '../common/UiSpec';
import { resolveUiBreakpoint } from '../common/Breakpoint';
import common from '@ohos.app.ability.common';
import notificationManager from '@ohos.notificationManager';
import BusinessError from '@ohos.base';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { initStore, loadSettings, LogStore } from '../model/Store';
import { subscribeVpnEvents } from '../core/VpnIpc';
import { VpnService } from '../core/VpnService';
import { needAutoUpdate, updateSubscription, markSubSuccess, markSubFailure, setAppContext } from '../core/Subscriptions';

export default class EntryAbility extends UIAbility {
  private backgroundUpdating: boolean = false;
  private windowStage?: window.WindowStage;
  private mainWindow?: window.Window;
  private readonly onWindowSizeChange = (size: window.Size): void => {
    const density = display.getDefaultDisplaySync().densityPixels;
    const shortestSideVp = Math.min(size.width, size.height) / density;
    AppStorage.setOrCreate('uiBreakpoint', resolveUiBreakpoint(shortestSideVp));
    this.updateStatusBarAvoid();
  };

  /** 系统栏避让高度(px→vp),内容区据此下移,避免状态栏区域被页面内容与背景整体覆盖 */
  private updateStatusBarAvoid(): void {
    if (this.mainWindow === undefined) {
      return;
    }
    try {
      const systemArea = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const cutout = this.mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const density = display.getDefaultDisplaySync().densityPixels;
      const topPx = Math.max(systemArea.topRect.height, cutout.topRect.height);
      AppStorage.setOrCreate('statusBarHeightVp', density > 0 ? topPx / density : 0);
    } catch (e) {
      LogStore.addLog(`[app] 获取状态栏避让区失败: ${e}`);
    }
  }

  private updateUiBreakpoint(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      this.onWindowSizeChange(mainWindow.getWindowProperties().windowRect);
    }).catch((e: Object) => {
      LogStore.addLog(`[app] 初始化窗口断点失败: ${e}`);
    });
  }

  private async updateDueSubscriptionsInBackground(): Promise<void> {
    if (this.backgroundUpdating) {
      return;
    }
    this.backgroundUpdating = true;
    let backgroundRunning: boolean = false;
    try {
      await initStore(this.context);
      setAppContext(this.context);
      const settings = await loadSettings();
      if (!settings.autoUpdateSubs) {
        return;
      }
      const due = await needAutoUpdate();
      if (due.length === 0) {
        return;
      }
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1003,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent);
      backgroundRunning = true;
      for (const sub of due) {
        try {
          const result = await updateSubscription(sub.url);
          await markSubSuccess(sub.url);
          LogStore.addLog(`[app] 后台更新订阅 ${sub.name}:新增 ${result.added},移除 ${result.removed}`);
        } catch (e) {
          await markSubFailure(sub.url);
          LogStore.addLog(`[app] 后台更新订阅 ${sub.name} 失败: ${e}`);
        }
      }
    } catch (e) {
      LogStore.addLog(`[app] 后台订阅更新任务失败: ${e}`);
    } finally {
      if (backgroundRunning) {
        try {
          await backgroundTaskManager.stopBackgroundRunning(this.context);
        } catch (e) {
          LogStore.addLog(`[app] 释放后台订阅任务失败: ${e}`);
        }
      }
      this.backgroundUpdating = false;
    }
  }

  private async applyAppearance(): Promise<void> {
    try {
      await initStore(this.context);
      const settings = await loadSettings();
      const colorMode = settings.appearance === 'dark'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : (settings.appearance === 'light'
          ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      this.context.setColorMode(colorMode);
    } catch (e) {
      LogStore.addLog(`[app] 应用主题失败: ${e}`);
    }
  }

  private handleAction(want: Want): void {
    if (want.parameters === undefined || `${want.parameters['action']}` !== 'disconnect') {
      return;
    }
    VpnService.disconnect(this.context).catch((e: Object) => {
      LogStore.addLog(`[app] 通知栏断开失败: ${e}`);
    });
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogStore.addLog('[app] NekoBox 启动');
    this.handleAction(want);
    this.applyAppearance();
    this.updateDueSubscriptionsInBackground();
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

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogStore.addLog('[app] 收到新的 Want');
    this.handleAction(want);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.applyAppearance();
    this.updateStatusBarAvoid();
    if (this.windowStage !== undefined) {
      this.applyStatusBarStyle(this.windowStage);
    }
  }

  onDestroy(): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStage = windowStage;
    this.updateUiBreakpoint(windowStage);
    windowStage.getMainWindow().then((mainWindow: window.Window) => {
      this.mainWindow = mainWindow;
      mainWindow.on('windowSizeChange', this.onWindowSizeChange);
      this.updateStatusBarAvoid();
    }).catch((e: Object) => {
      LogStore.addLog(`[app] 注册窗口尺寸监听失败: ${e}`);
    });
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        return;
      }
      this.applyStatusBarStyle(windowStage);
    });
  }

  /** F7c:状态栏前景色跟随深浅色(外观偏好 + 系统色模式) */
  private async applyStatusBarStyle(windowStage: window.WindowStage): Promise<void> {
    try {
      const win = await windowStage.getMainWindow();
      let dark = false;
      let decided = false;
      try {
        await initStore(this.context);
        const settings = await loadSettings();
        if (settings.appearance === 'dark') {
          dark = true;
          decided = true;
        } else if (settings.appearance === 'light') {
          dark = false;
          decided = true;
        }
      } catch (e) {
        LogStore.addLog(`[app] 读取主题偏好失败,状态栏按系统色模式处理: ${e}`);
      }
      if (!decided) {
        // 跟随系统:直接读当前生效 colorMode。resourceManager 亮度推断在 colorMode
        // 异步生效前会误判,曾导致深色背景下写入黑色图标、状态栏整体不可见。
        const cm = this.context.config?.colorMode;
        if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
          dark = true;
          decided = true;
        } else if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
          dark = false;
          decided = true;
        }
      }
      if (!decided) {
        const c = this.context.resourceManager.getColorSync($r('app.color.text_primary'));
        const r = (c >> 16) & 0xFF;
        const g = (c >> 8) & 0xFF;
        const b = c & 0xFF;
        dark = (r * 299 + g * 587 + b * 114) / 1000 >= 128;
      }
      win.setWindowSystemBarProperties({
        statusBarContentColor: dark ? UiSpec.STATUS_BAR_CONTENT_DARK_BG : UiSpec.STATUS_BAR_CONTENT_LIGHT_BG
      });
    } catch (e) {
      LogStore.addLog(`[app] 设置状态栏样式失败: ${e}`);
    }
  }

  onWindowStageDestroy(): void {
    if (this.windowStage !== undefined) {
      if (this.mainWindow !== undefined) {
        this.mainWindow.off('windowSizeChange', this.onWindowSizeChange);
        this.mainWindow = undefined;
      }
    }
  }

  onForeground(): void {
    this.applyAppearance();
    this.updateDueSubscriptionsInBackground();
  }

  onBackground(): void {
    this.updateDueSubscriptionsInBackground();
  }
}
