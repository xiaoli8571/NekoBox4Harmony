import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import notificationManager from '@ohos.notificationManager';
import common from '@ohos.app.ability.common';
import BusinessError from '@ohos.base';
import { LogStore } from '../model/Store';
import { formatBytes } from '../utils/TrafficStats';
import { KeepAliveManager } from './KeepAliveManager';

/** 实况窗刷新间隔:DATA_TRANSFER 10 分钟不更新 live view 就会被系统取消。 */
const LIVE_VIEW_UPDATE_MS: number = 30000;
/** 未持有任务时的重试间隔(系统取消、或订阅下载正占着旧接口的任务)。 */
const RETRY_MS: number = 30000;

/**
 * VPN 会话期长时任务(实验,对照 Tailscale-OHOS 的做法)。
 *
 * 目的:让 UI 进程在后台保持 200 档;:vpn 扩展被 UI 进程绑定(VpnService.bindExtension)后
 * 跟随 UI 档位 +100,从而落在 300 档,而不是没有长时任务时的 400 档。
 *
 * 用新版接口 startBackgroundRunning(context, ['dataTransfer'], agent) 拿到系统分配的
 * notificationId,每 30 秒以 LIVE_VIEW 刷新同一条通知,避开 DATA_TRANSFER 的 10 分钟取消线。
 *
 * 与 KeepAliveManager(订阅/Geo 下载期的旧接口任务)互斥:会话持有期间下载直接复用本任务;
 * 下载正持有时本类不抢,等下一轮重试。
 */
export class SessionKeepAlive {
  private static context: common.UIAbilityContext | null = null;
  /** 期望持有(VPN 运行中) */
  private static wanted: boolean = false;
  private static task: backgroundTaskManager.ContinuousTaskNotification | null = null;
  private static acquiring: boolean = false;
  /** 用户在通知里主动停止后,本次会话不再重挂 */
  private static userCancelled: boolean = false;
  private static timer: number = -1;
  private static listening: boolean = false;

  private static readonly cancelCallback = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    const task = SessionKeepAlive.task;
    if (task === null || (task.continuousTaskId !== undefined && info.id !== task.continuousTaskId)) {
      return;
    }
    SessionKeepAlive.task = null;
    const byUser = info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
      info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION;
    SessionKeepAlive.userCancelled = byUser;
    LogStore.addLog(`[app] 会话长时任务被取消(reason=${info.reason}${byUser ? ',用户操作,本次会话不再重挂' : ',稍后重挂'})`);
  };

  /** 会话持有中:订阅/Geo 下载据此跳过自己的旧接口任务。 */
  static isHeld(): boolean {
    return SessionKeepAlive.task !== null;
  }

  static start(context: common.UIAbilityContext): void {
    SessionKeepAlive.context = context;
    if (SessionKeepAlive.wanted) {
      return;
    }
    SessionKeepAlive.wanted = true;
    SessionKeepAlive.userCancelled = false;
    SessionKeepAlive.tick();
    SessionKeepAlive.timer = setInterval(() => {
      SessionKeepAlive.tick();
    }, LIVE_VIEW_UPDATE_MS);
  }

  static async stop(): Promise<void> {
    if (!SessionKeepAlive.wanted && SessionKeepAlive.task === null) {
      return;
    }
    SessionKeepAlive.wanted = false;
    if (SessionKeepAlive.timer >= 0) {
      clearInterval(SessionKeepAlive.timer);
      SessionKeepAlive.timer = -1;
    }
    const task = SessionKeepAlive.task;
    SessionKeepAlive.task = null;
    SessionKeepAlive.unlisten();
    const context = SessionKeepAlive.context;
    if (task === null || context === null) {
      return;
    }
    try {
      if (task.continuousTaskId !== undefined) {
        await backgroundTaskManager.stopBackgroundRunning(context, task.continuousTaskId);
      } else {
        await backgroundTaskManager.stopBackgroundRunning(context);
      }
      LogStore.addLog('[app] 会话长时任务已释放');
    } catch (e) {
      LogStore.addLog(`[app] 释放会话长时任务失败: ${SessionKeepAlive.errText(e)}`);
    }
  }

  private static tick(): void {
    if (!SessionKeepAlive.wanted) {
      return;
    }
    if (SessionKeepAlive.task !== null) {
      void SessionKeepAlive.publishLiveView();
      return;
    }
    if (SessionKeepAlive.userCancelled || SessionKeepAlive.acquiring) {
      return;
    }
    if (KeepAliveManager.isTransferActive()) {
      LogStore.addLog(`[app] 订阅/Geo 下载正持有长时任务,会话任务 ${RETRY_MS / 1000}s 后再申请`);
      return;
    }
    void SessionKeepAlive.acquire();
  }

  private static listen(): void {
    if (SessionKeepAlive.listening) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel', SessionKeepAlive.cancelCallback);
      SessionKeepAlive.listening = true;
    } catch (e) {
      LogStore.addLog(`[app] 注册长时任务取消监听失败: ${SessionKeepAlive.errText(e)}`);
    }
  }

  private static unlisten(): void {
    if (!SessionKeepAlive.listening) {
      return;
    }
    SessionKeepAlive.listening = false;
    try {
      backgroundTaskManager.off('continuousTaskCancel', SessionKeepAlive.cancelCallback);
    } catch (e) {
      // 已被其他 off() 清掉时会抛,忽略
    }
  }

  private static async acquire(): Promise<void> {
    const context = SessionKeepAlive.context;
    if (context === null) {
      return;
    }
    SessionKeepAlive.acquiring = true;
    try {
      const agent: WantAgent = await wantAgent.getWantAgent({
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1005,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      // KeepAliveManager.endTransfer 会无差别 off() 所有取消监听,这里每次申请前重新注册
      SessionKeepAlive.listening = false;
      SessionKeepAlive.listen();
      const task = await backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
      if (!SessionKeepAlive.wanted) {
        // 申请途中 VPN 已断开
        SessionKeepAlive.task = task;
        await SessionKeepAlive.stop();
        return;
      }
      SessionKeepAlive.task = task;
      LogStore.addLog(`[app] 会话长时任务已申请: DATA_TRANSFER(id=${task.continuousTaskId ?? -1},通知=${task.notificationId})`);
      await SessionKeepAlive.publishLiveView();
    } catch (e) {
      LogStore.addLog(`[app] 会话长时任务申请失败(${RETRY_MS / 1000}s 后重试): ${SessionKeepAlive.errText(e)}`);
    } finally {
      SessionKeepAlive.acquiring = false;
    }
  }

  private static async publishLiveView(): Promise<void> {
    const task = SessionKeepAlive.task;
    if (task === null) {
      return;
    }
    const up: number = AppStorage.get<number>('vpnTotalUp') ?? 0;
    const down: number = AppStorage.get<number>('vpnTotalDown') ?? 0;
    const title: string = 'NekoBox VPN 运行中';
    const text: string = `↑ ${formatBytes(up)}  ↓ ${formatBytes(down)}`;
    const templateData: Record<string, Object> = {};
    templateData['title'] = title;
    templateData['fileName'] = text;
    const request: notificationManager.NotificationRequest = {
      id: task.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      isAlertOnce: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title: title, text: text }
      },
      template: {
        name: 'downloadTemplate',
        // 隧道没有完成百分比,只显示累计流量
        data: templateData
      }
    };
    try {
      await notificationManager.publish(request);
    } catch (e) {
      LogStore.addLog(`[app] 会话实况窗刷新失败: ${SessionKeepAlive.errText(e)}`);
    }
  }

  private static errText(e: Object): string {
    const be = e as BusinessError;
    if (be !== undefined && be !== null && be.code !== undefined) {
      return `code=${be.code} msg=${be.message}`;
    }
    return e instanceof Error ? e.message : `${e}`;
  }
}
