import notificationManager from '@ohos.notificationManager';
import notification from '@ohos.notification';
import common from '@ohos.app.ability.common';

/**
 * 批量测速完成通知(对齐 OwnBox 的 ConnectionTestNotification)。
 *
 * 语义边界:
 *  - 只在应用**不在前台**时打扰用户(前台已经有 toast + 行内延迟,再弹通知是噪音);
 *  - 通知 id 固定,下一轮复用同一条,不在通知栏堆积;
 *  - 整段 best-effort:没有通知权限/系统拒绝时静默失败,不能影响测速本身。
 */
const PROBE_NOTIFY_ID: number = 1002;

/** 前台标志:EntryAbility 的 onForeground/onBackground 维护(UI 进程内单例) */
export class ForegroundFlag {
  private static foreground: boolean = true;

  static set(value: boolean): void {
    ForegroundFlag.foreground = value;
  }

  static isForeground(): boolean {
    return ForegroundFlag.foreground;
  }
}

/** 通知文案(纯字符串,便于主机测试与本地化取值解耦) */
export function probeNotifyText(available: number, total: number, cancelled: boolean,
  titleLabel: string, cancelledLabel: string): string {
  const ok = available > 0 ? available : 0;
  const all = total > 0 ? total : 0;
  if (cancelled) {
    return `${cancelledLabel} ${ok}/${all}`;
  }
  return `${ok}/${all}`;
}

/**
 * 发布"测速完成"通知。
 * @param context UIAbility context
 * @param available 可用(延迟测试通过)节点数
 * @param total 本轮参与测试的节点数
 * @param cancelled 是否被用户取消
 */
export async function notifyProbeDone(context: common.Context, available: number, total: number,
  cancelled: boolean): Promise<void> {
  if (ForegroundFlag.isForeground()) {
    return;
  }
  try {
    const res = context.resourceManager;
    const title = res.getStringSync($r('app.string.probe_notify_title'));
    const cancelledLabel = res.getStringSync($r('app.string.probe_notify_cancelled'));
    const text = probeNotifyText(available, total, cancelled, title, cancelledLabel);
    const content: notificationManager.NotificationContent = {
      contentType: notification.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal: {
        title: title,
        text: text
      }
    };
    const request: notificationManager.NotificationRequest = {
      id: PROBE_NOTIFY_ID,
      isOngoing: false,
      content: content
    };
    await notificationManager.publish(request);
  } catch (e) {
    // 没有通知权限等场景:只丢通知,不影响测速流程
  }
}
