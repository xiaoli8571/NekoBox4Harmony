import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import window from '@ohos.window';
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import notificationManager from '@ohos.notificationManager';
import notification from '@ohos.notification';
import wantAgent from '@ohos.wantAgent';
import BusinessError from '@ohos.base';
import { initStore, LogStore } from '../model/Store';
import { subscribeVpnEvents } from '../common/event/VpnEventBridge';
import { ConnectionStateManager } from '../common/manager/ConnectionStateManager';
import { VpnService } from '../common/service/VpnService';
import { Profile } from '../model/Profile';
import { ProfileStorage } from '../common/storage/ProfileStorage';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    ConnectionStateManager.initialize();
    this.captureIncomingWant(want);
    LogStore.addLog('[app] NekBox 启动');
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
      const wasRunning: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
      // 扩展在创建 TUN/等待系统授权时也会发送 running=false；那是连接中间态，
      // 不能把本次会话的起始时间和累计流量提前清掉。只有明确的断开或失败终态
      // 才允许归零，且归零集中在这里，避免请求侧 disconnect() 与页面生命周期
      // 各自清零造成状态闪烁。
      const terminal: boolean = !running && (status.includes('已断开')
        || status.includes('连接失败') || status.includes('启动 VPN 服务失败')
        || status.includes('超时') || status.includes('错误') || status.includes('未连接'));
      if (running && !wasRunning) {
        AppStorage.setOrCreate('vpnConnectedAt', Date.now());
      } else if (terminal) {
        AppStorage.setOrCreate('vpnConnectedAt', 0);
        AppStorage.setOrCreate('vpnUpSpeed', 0);
        AppStorage.setOrCreate('vpnDownSpeed', 0);
        AppStorage.setOrCreate('vpnTotalUp', 0);
        AppStorage.setOrCreate('vpnTotalDown', 0);
      }
      AppStorage.setOrCreate('vpnRunning', running);
      AppStorage.setOrCreate('vpnStatus', status);
      AppStorage.setOrCreate('vpnRunningProfileId', profileId);
      ConnectionStateManager.sync(status, running);
      if (running) {
        // The extension publishes the basic persistent notification.  Refresh
        // the same notification from the UI ability with action buttons so a
        // notification tap can disconnect or switch without hot-reloading the
        // core.  A failure here must never affect VPN state.
        this.publishQuickActionNotification(profileId, status);
      }
    });
  }

  /** Handle a reused UIAbility instance (share intents and notification taps). */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.captureIncomingWant(want);
    const action = this.wantString(want, 'notificationAction');
    if (action === 'disconnect') {
      VpnService.disconnect(this.context).catch((e: Error) => {
        LogStore.addLog(`[app] 通知断开失败: ${e.message}`);
      });
    } else if (action === 'switch') {
      this.switchFromNotification();
    }
  }

  onDestroy(): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    const pending = AppStorage.get<string>('pendingShareText') ?? '';
    const initialPage = pending.trim().length > 0 ? 'pages/ShareImportPage' : 'pages/Index';
    windowStage.loadContent(initialPage, (err) => {
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

  /**
   * Extract text/plain from both the legacy shareData string and the newer
   * object/array Want parameter shapes.  The parser intentionally accepts only
   * text/plain actions; unrelated intents are ignored.
   */
  private captureIncomingWant(want: Want): void {
    if (want === undefined || want === null) {
      return;
    }
    if (want.action !== 'ohos.want.action.sendData') {
      return;
    }
    if (want.type !== undefined && want.type !== 'text/plain' && want.type !== 'text/*') {
      return;
    }
    let text = '';
    if (want.parameters !== undefined && want.parameters !== null) {
      const params = want.parameters as Record<string, Object>;
      const preferred: Array<string> = [
        'ohos.extra.param.key.shareData',
        'shareData',
        'text',
        'content',
        'data'
      ];
      for (const key of preferred) {
        const value = params[key];
        text = this.extractText(value);
        if (text.trim().length > 0) {
          break;
        }
      }
      if (text.trim().length === 0) {
        for (const key of Object.keys(params)) {
          text = this.extractText(params[key]);
          if (text.trim().length > 0) {
            break;
          }
        }
      }
    }
    if (text.trim().length === 0 && want.uri !== undefined && want.uri !== null) {
      const uri = `${want.uri}`;
      const comma = uri.indexOf(',');
      if (uri.startsWith('data:text/plain') && comma >= 0) {
        const encoded = uri.substring(comma + 1);
        try {
          text = decodeURIComponent(encoded);
        } catch (e) {
          text = encoded;
        }
      }
    }
    if (text.trim().length > 0) {
      // Want payloads are limited by the platform; cap again before storing so
      // a malformed caller cannot make the UI allocate an unbounded string.
      AppStorage.setOrCreate('pendingShareText', text.substring(0, 100 * 1024));
      AppStorage.setOrCreate('pendingShareAt', Date.now());
      LogStore.addLog('[app] 收到 text/plain 分享内容,等待导入');
      // If the ability is already visible, best-effort navigate to the import
      // page.  The page also consumes AppStorage on its next appearance, so a
      // navigation failure does not lose the share.
      try {
        router.pushUrl({ url: 'pages/ShareImportPage' });
      } catch (e) {
        // UI may not yet have a stage during cold start.
      }
    }
  }

  private extractText(value: Object): string {
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'string') {
      return value;
    }
    if (Array.isArray(value)) {
      const items: Array<Object> = value as Array<Object>;
      for (const item of items) {
        const text = this.extractText(item as Object);
        if (text.trim().length > 0) {
          return text;
        }
      }
      return '';
    }
    if (typeof value === 'object') {
      const record = value as Record<string, Object>;
      const keys: Array<string> = ['text', 'content', 'data', 'plainText', 'value'];
      for (const key of keys) {
        const text = this.extractText(record[key]);
        if (text.trim().length > 0) {
          return text;
        }
      }
    }
    return '';
  }

  private wantString(want: Want, key: string): string {
    if (want.parameters === undefined || want.parameters === null) {
      return '';
    }
    const value = (want.parameters as Record<string, Object>)[key];
    return value === undefined || value === null ? '' : `${value}`;
  }

  private async switchFromNotification(): Promise<void> {
    try {
      await ProfileStorage.initialize(this.context);
      const profiles = await ProfileStorage.profiles();
      if (profiles.length === 0) {
        LogStore.addLog('[app] 通知切换失败:没有可用节点');
        return;
      }
      const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
      let index = profiles.findIndex((p: Profile) => p.id === runningId);
      if (index < 0) {
        index = 0;
      } else {
        index = (index + 1) % profiles.length;
      }
      // VpnService.switchTo enforces disconnect → 1.5s wait → connect;
      // notification actions never invoke an in-process hot switch.
      await VpnService.switchTo(this.context, profiles[index].id);
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[app] 通知切换失败: ${message}`);
    }
  }

  private async createNotificationAction(action: string, requestCode: number,
    title: string): Promise<notificationManager.NotificationActionButton | null> {
    try {
      const target: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: 'EntryAbility',
        parameters: { 'notificationAction': action }
      };
      const agent = await wantAgent.getWantAgent({
        wants: [target],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: requestCode,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      return { title: title, wantAgent: agent };
    } catch (e) {
      return null;
    }
  }

  private async publishQuickActionNotification(profileId: string, status: string): Promise<void> {
    try {
      const disconnect = await this.createNotificationAction('disconnect', 10011, '断开连接');
      const switchNode = await this.createNotificationAction('switch', 10012, '切换节点');
      const actions: Array<notificationManager.NotificationActionButton> = [];
      if (disconnect !== null) {
        actions.push(disconnect);
      }
      if (switchNode !== null) {
        actions.push(switchNode);
      }
      if (actions.length === 0) {
        return;
      }
      const title = status.startsWith('已连接:') ? status.substring('已连接:'.length).trim() : profileId;
      const content: notificationManager.NotificationContent = {
        contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'VPN 已连接',
          text: title,
          additionalText: 'NekBox'
        }
      };
      const request: notificationManager.NotificationRequest = {
        id: 1001,
        isOngoing: true,
        content: content,
        actionButtons: actions
      };
      await notificationManager.publish(request);
    } catch (e) {
      LogStore.addLog('[app] 通知快捷操作不可用(忽略)');
    }
  }
}
