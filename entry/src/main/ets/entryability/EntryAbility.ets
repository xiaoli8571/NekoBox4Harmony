import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import window from '@ohos.window';
import { UiSpec } from '../common/UiSpec';
import common from '@ohos.app.ability.common';
import notificationManager from '@ohos.notificationManager';
import BusinessError from '@ohos.base';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { initStore, loadSettings, LogStore } from '../model/Store';
import { subscribeVpnEvents, unsubscribeVpnEvents } from '../core/VpnIpc';
import { VpnService } from '../core/VpnService';
import { needAutoUpdate, updateSubscription, markSubSuccess, markSubFailure, setAppContext } from '../core/Subscriptions';

export default class EntryAbility extends UIAbility {
  private backgroundUpdating: boolean = false;
  private mainWindow?: window.Window;
  private readonly windowSizeListener = (size: window.Size): void => {
    this.publishBreakpoint(size.width);
  };

  private publishBreakpoint(width: number): void {
    const breakpoint = width < UiSpec.BREAKPOINT_MEDIUM
      ? 'compact'
      : (width < UiSpec.BREAKPOINT_LARGE ? 'medium' : 'large');
    AppStorage.setOrCreate('uiBreakpoint', breakpoint);
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

  private colorToString(color: number): string {
    return `#${(color >>> 0).toString(16).padStart(8, '0').toUpperCase()}`;
  }

  private async syncWindowAppearance(win?: window.Window): Promise<void> {
    const target = win ?? this.mainWindow;
    if (target === undefined) {
      return;
    }
    try {
      const background = this.context.resourceManager.getColorSync($r('app.color.app_background'));
      const red = (background >> 16) & 0xFF;
      const green = (background >> 8) & 0xFF;
      const blue = background & 0xFF;
      const darkBackground = (red * 299 + green * 587 + blue * 114) / 1000 < 128;
      const backgroundColor = this.colorToString(background);
      const contentColor = darkBackground
        ? UiSpec.STATUS_BAR_CONTENT_DARK_BG
        : UiSpec.STATUS_BAR_CONTENT_LIGHT_BG;
      target.setWindowBackgroundColor(backgroundColor);
      target.setWindowSystemBarProperties({
        statusBarColor: backgroundColor,
        navigationBarColor: backgroundColor,
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
    } catch (e) {
      LogStore.addLog(`[app] 同步窗口主题失败: ${e}`);
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
      await this.syncWindowAppearance();
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
    }, (upSpeed: number, downSpeed: number, totalUp: number, totalDown: number) => {
      AppStorage.setOrCreate('vpnUpSpeed', upSpeed);
      AppStorage.setOrCreate('vpnDownSpeed', downSpeed);
      AppStorage.setOrCreate('vpnTotalUp', totalUp);
      AppStorage.setOrCreate('vpnTotalDown', totalDown);

      // CommonEvent 是瞬时事件，connected 状态��偶尔可能丢失；流量事件来自已启动的
      // VPN 内核，可作为数据面已连接的可靠证据，及时修复 UI 一直转圈的问题。
      const status: string = AppStorage.get<string>('vpnStatus') ?? '';
      if ((status === 'connecting' || status === 'switching') &&
        (upSpeed > 0 || downSpeed > 0 || totalUp > 0 || totalDown > 0)) {
        const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
        AppStorage.setOrCreate('vpnRunning', true);
        AppStorage.setOrCreate('vpnStatus', 'connected:running');
        if (profileId.length === 0) {
          LogStore.addLog('[app] connected 状态回调缺失，已根据 VPN 流量恢复连接状态');
        }
      }
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogStore.addLog('[app] 收到新的 Want');
    this.handleAction(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        return;
      }
      this.applyStatusBarStyle(windowStage);
      windowStage.getMainWindow().then((win: window.Window) => {
        this.mainWindow = win;
        this.publishBreakpoint(win.getWindowProperties().windowRect.width);
        win.on('windowSizeChange', this.windowSizeListener);
        this.syncWindowAppearance(win);
      }).catch((e: Object) => {
        LogStore.addLog(`[ui] 初始化窗口断点失败: ${e}`);
      });
    });
  }

  /** F7c:状态栏前景色跟随深浅色(外观偏好 + 系统色模式) */
  private async applyStatusBarStyle(windowStage: window.WindowStage): Promise<void> {
    try {
      const win = await windowStage.getMainWindow();
      let dark = false;
      try {
        await initStore(this.context);
        const settings = await loadSettings();
        if (settings.appearance === 'dark') {
          dark = true;
        } else if (settings.appearance !== 'light') {
          // 跟随系统:取当前生效主题下的 text_primary 亮度判定(resourceManager 自动跟随深浅色)
          const c = this.context.resourceManager.getColorSync($r('app.color.text_primary'));
          const r = (c >> 16) & 0xFF;
          const g = (c >> 8) & 0xFF;
          const b = c & 0xFF;
          dark = (r * 299 + g * 587 + b * 114) / 1000 >= 128;
        }
      } catch (e) {
        LogStore.addLog(`[app] 读取主题偏好失败,状态栏按浅色处理: ${e}`);
      }
      win.setWindowSystemBarProperties({
        statusBarContentColor: dark ? UiSpec.STATUS_BAR_CONTENT_DARK_BG : UiSpec.STATUS_BAR_CONTENT_LIGHT_BG
      });
    } catch (e) {
      LogStore.addLog(`[app] 设置状态栏样式失败: ${e}`);
    }
  }

  onWindowStageDestroy(): void {
    if (this.mainWindow !== undefined) {
      this.mainWindow.off('windowSizeChange', this.windowSizeListener);
      this.mainWindow = undefined;
    }
  }

  onDestroy(): void {
    unsubscribeVpnEvents();
  }

  onForeground(): void {
    this.applyAppearance();
    this.updateDueSubscriptionsInBackground();
  }

  onBackground(): void {
    this.updateDueSubscriptionsInBackground();
  }
}
