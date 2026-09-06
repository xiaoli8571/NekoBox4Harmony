import commonEventManager from '@ohos.commonEventManager';
import BusinessError from '@ohos.base';

/**
 * 跨进程 IPC:VpnExtensionAbility 运行在独立的 ":vpn" 进程,
 * 与 UI 进程之间通过 CommonEvent 传递日志和 VPN 状态。
 */

export const VPN_EVENT_LOG: string = 'com.nekobox.app.VPN_LOG';
export const VPN_EVENT_STATUS: string = 'com.nekobox.app.VPN_STATUS';
export const VPN_EVENT_LATENCY: string = 'com.nekobox.app.VPN_LATENCY';
export const VPN_EVENT_TRAFFIC: string = 'com.nekobox.app.VPN_TRAFFIC';

const APP_BUNDLE = 'com.nekobox.app';

/** 扩展进程调用:把一行日志发到 UI 进程 */
export function publishVpnLog(line: string): void {
  try {
    const opts: commonEventManager.CommonEventPublishData = { bundleName: APP_BUNDLE, data: line };
    commonEventManager.publish(VPN_EVENT_LOG, opts, (err: BusinessError) => {
      // 日志通道失败不影响 VPN 流程
    });
  } catch (e) {
    // ignore
  }
}

/** 扩展进程调用:状态变更通知 UI(profileId 便于 UI 判断当前节点) */
export function publishVpnStatus(status: string, running: boolean, profileId: string = ''): void {
  try {
    const payload: Record<string, string> = {
      'status': status,
      'running': running ? 'true' : 'false',
      'profileId': profileId
    };
    const opts: commonEventManager.CommonEventPublishData = {
      bundleName: APP_BUNDLE,
      data: JSON.stringify(payload)
    };
    commonEventManager.publish(VPN_EVENT_STATUS, opts, (err: BusinessError) => {
      // ignore
    });
  } catch (e) {
    // ignore
  }
}

/** 扩展进程调用:把实时流量数据同步到 UI 进程。 */
export function publishVpnTraffic(upSpeed: number, downSpeed: number, totalUp: number, totalDown: number): void {
  try {
    const payload: Record<string, string> = {
      'upSpeed': `${upSpeed}`,
      'downSpeed': `${downSpeed}`,
      'totalUp': `${totalUp}`,
      'totalDown': `${totalDown}`
    };
    const opts: commonEventManager.CommonEventPublishData = {
      bundleName: APP_BUNDLE,
      data: JSON.stringify(payload)
    };
    commonEventManager.publish(VPN_EVENT_TRAFFIC, opts, (err: BusinessError) => {
      // 流量状态同步失败不影响 VPN 数据面
    });
  } catch (e) {
    // ignore
  }
}

/** UI 进程调用:把测速结果发给 VPN 扩展进程更新常驻通知 */
export function publishVpnLatency(profileId: string, nodeName: string, latencyMs: number): void {
  try {
    const payload: Record<string, string> = {
      'profileId': profileId,
      'nodeName': nodeName,
      'latencyMs': `${latencyMs}`
    };
    const opts: commonEventManager.CommonEventPublishData = {
      bundleName: APP_BUNDLE,
      data: JSON.stringify(payload)
    };
    commonEventManager.publish(VPN_EVENT_LATENCY, opts, (err: BusinessError) => {
      // 测速通知失败不影响测速和 VPN 流程
    });
  } catch (e) {
    // ignore
  }
}

/** UI 进程调用:订阅扩展发来的日志、状态与流量 */
export function subscribeVpnEvents(onLog: (line: string) => void,
  onStatus: (status: string, running: boolean, profileId: string) => void,
  onTraffic: (upSpeed: number, downSpeed: number, totalUp: number, totalDown: number) => void): void {
  const info: commonEventManager.CommonEventSubscribeInfo = {
    events: [VPN_EVENT_LOG, VPN_EVENT_STATUS, VPN_EVENT_TRAFFIC]
  };
  commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
    commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
      if (err || data === undefined || data === null) {
        return;
      }
      if (data.event === VPN_EVENT_LOG && data.data !== undefined) {
        onLog(data.data);
      } else if (data.event === VPN_EVENT_STATUS && data.data !== undefined) {
        try {
          const obj = JSON.parse(data.data) as Record<string, Object>;
          const status: string = obj['status'] === undefined ? '' : `${obj['status']}`;
          const running: boolean = `${obj['running']}` === 'true';
          const profileId: string = obj['profileId'] === undefined ? '' : `${obj['profileId']}`;
          onStatus(status, running, profileId);
        } catch (e) {
          // 忽略格式错误的状态
        }
      } else if (data.event === VPN_EVENT_TRAFFIC && data.data !== undefined) {
        try {
          const obj = JSON.parse(data.data) as Record<string, Object>;
          const upSpeed = Number(obj['upSpeed']);
          const downSpeed = Number(obj['downSpeed']);
          const totalUp = Number(obj['totalUp']);
          const totalDown = Number(obj['totalDown']);
          if (!isNaN(upSpeed) && !isNaN(downSpeed) && !isNaN(totalUp) && !isNaN(totalDown)) {
            onTraffic(upSpeed, downSpeed, totalUp, totalDown);
          }
        } catch (e) {
          // 忽略格式错误的流量数据
        }
      }
    });
  }).catch((e: Object) => {
    // 订阅失败时 UI 退化为看门狗提示
  });
}
