import commonEventManager from '@ohos.commonEventManager';
import BusinessError from '@ohos.base';

/**
 * 跨进程 IPC:VpnExtensionAbility 运行在独立的 ":vpn" 进程,
 * 与 UI 进程之间通过 CommonEvent 传递日志和 VPN 状态。
 */

export const VPN_EVENT_LOG: string = 'com.nekobox.app.jynxen.VPN_LOG';
export const VPN_EVENT_STATUS: string = 'com.nekobox.app.jynxen.VPN_STATUS';
export const VPN_EVENT_LATENCY: string = 'com.nekobox.app.jynxen.VPN_LATENCY';
export const VPN_EVENT_TRAFFIC: string = 'com.nekobox.app.jynxen.VPN_TRAFFIC';
/** UI 进程 → 扩展进程:应用回到前台,唤醒后重置连接(对齐安卓 wakeResetConnections) */
export const VPN_EVENT_APP_FOREGROUND: string = 'com.nekobox.app.jynxen.VPN_APP_FOREGROUND';
/** UI 进程 → 扩展进程:版本化命令通道(connect/apply/stop/query/queryApplyStatus,§16.1) */
export const VPN_EVENT_CMD: string = 'com.nekobox.app.jynxen.VPN_CMD';
/** 扩展进程 → UI 进程:应用事务回执(operationId/appliedRevision/名单摘要,§12.3-5) */
export const VPN_EVENT_APPLIED: string = 'com.nekobox.app.jynxen.VPN_APPLIED';

/** IPC 协议版本:独立于 config schema 版本(§16.1)。缺失该字段按旧语义处理。 */
export const VPN_PROTOCOL_VERSION: number = 1;

const APP_BUNDLE = 'com.nekobox.app.jynxen';

/**
 * 事件信封(§16.1):状态/流量/回执都带同一套字段。
 *  - sequence 用于排序与去重(时间戳只作展示/诊断);
 *  - generation 与 UI 侧请求代次对齐,迟到事件据此丢弃;
 *  - appliedRevision/configHash 让 UI 知道扩展实际加载的是哪份配置(未知填 0/空串)。
 */
export class VpnEnvelope {
  protocolVersion: number = VPN_PROTOCOL_VERSION;
  sessionId: string = '';
  generation: number = 0;
  sequence: number = 0;
  operationId: string = '';
  appliedRevision: number = 0;
  configHash: string = '';
  emittedAt: number = 0;

  static toJson(env: VpnEnvelope | null): string {
    if (env === null) {
      return '';
    }
    return JSON.stringify(env);
  }

  /** 解析信封;"env" 缺失/损坏返回 null(调用方按旧语义继续,不阻断状态展示)。 */
  static fromJson(text: string): VpnEnvelope | null {
    if (text.length === 0) {
      return null;
    }
    try {
      const raw = JSON.parse(text) as Record<string, Object>;
      const env = new VpnEnvelope();
      env.protocolVersion = Number(raw['protocolVersion'] ?? 0);
      env.sessionId = `${raw['sessionId'] ?? ''}`;
      env.generation = Number(raw['generation'] ?? 0);
      env.sequence = Number(raw['sequence'] ?? 0);
      env.operationId = `${raw['operationId'] ?? ''}`;
      env.appliedRevision = Number(raw['appliedRevision'] ?? 0);
      env.configHash = `${raw['configHash'] ?? ''}`;
      env.emittedAt = Number(raw['emittedAt'] ?? 0);
      return env;
    } catch (e) {
      return null;
    }
  }
}

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

/** UI 进程调用:应用回到前台时通知扩展进程(用于唤醒后重置连接) */
export function publishAppForeground(): void {
  try {
    const opts: commonEventManager.CommonEventPublishData = { bundleName: APP_BUNDLE };
    commonEventManager.publish(VPN_EVENT_APP_FOREGROUND, opts, (err: BusinessError) => {
      // 通知失败不影响 VPN 流程
    });
  } catch (e) {
    // ignore
  }
}

let vpnEventSubscriber: commonEventManager.CommonEventSubscriber | undefined;
let subscriptionGeneration: number = 0;
let vpnCmdSubscriber: commonEventManager.CommonEventSubscriber | undefined;

/** 命令载荷:命令名 + 信封关键字段(§16.1)。 */
export class VpnCommand {
  cmd: string = '';
  operationId: string = '';
  generation: number = 0;
  revision: number = 0;
  sessionId: string = '';
  extra: Record<string, string> = {};
}

/** 扩展进程调用:发布带信封的状态事件(旧字段保留,新字段附加)。 */
export function publishVpnStatusEx(status: string, running: boolean, profileId: string,
  env: VpnEnvelope | null): void {
  try {
    const payload: Record<string, string> = {
      'status': status,
      'running': running ? 'true' : 'false',
      'profileId': profileId,
      'env': VpnEnvelope.toJson(env)
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

/** 扩展进程调用:发布应用事务回执(§12.3-5)。 */
export function publishVpnApplied(ok: boolean, effectivePerAppSummary: string, env: VpnEnvelope | null,
  error: string = ''): void {
  try {
    const payload: Record<string, string> = {
      'ok': ok ? 'true' : 'false',
      'perAppSummary': effectivePerAppSummary,
      'error': error,
      'env': VpnEnvelope.toJson(env)
    };
    const opts: commonEventManager.CommonEventPublishData = {
      bundleName: APP_BUNDLE,
      data: JSON.stringify(payload)
    };
    commonEventManager.publish(VPN_EVENT_APPLIED, opts, (err: BusinessError) => {
      // ignore
    });
  } catch (e) {
    // ignore
  }
}

/** 应用事务回执(§12.3-5)：UI 只接受匹配 operationId/sessionId/revision 的确认。 */
export class VpnApplyResult {
  ok: boolean = false;
  perAppSummary: string = '';
  error: string = '';
  env: VpnEnvelope | null = null;
}

let vpnAppliedSubscriber: commonEventManager.CommonEventSubscriber | null = null;

/** UI 进程调用:订阅扩展的应用事务回执。 */
export function subscribeVpnApplied(onResult: (result: VpnApplyResult) => void): void {
  commonEventManager.createSubscriber({ events: [VPN_EVENT_APPLIED] }).then(
    (subscriber: commonEventManager.CommonEventSubscriber) => {
      vpnAppliedSubscriber = subscriber;
      commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        if (err || data === undefined || data === null || data.data === undefined) {
          return;
        }
        try {
          const raw = JSON.parse(data.data) as Record<string, Object>;
          const out = new VpnApplyResult();
          out.ok = `${raw['ok'] ?? ''}` === 'true';
          out.perAppSummary = `${raw['perAppSummary'] ?? ''}`;
          out.error = `${raw['error'] ?? ''}`;
          out.env = VpnEnvelope.fromJson(`${raw['env'] ?? ''}`);
          onResult(out);
        } catch (e) {
          // 坏包丢弃:看门狗/超时兜底
        }
      });
    }, (err: BusinessError) => {
      // ignore
    });
}

export function unsubscribeVpnApplied(): void {
  try {
    if (vpnAppliedSubscriber !== null) {
      commonEventManager.unsubscribe(vpnAppliedSubscriber);
      vpnAppliedSubscriber = null;
    }
  } catch (e) {
    // ignore
  }
}

/** UI 进程调用:发送命令到扩展(connect/apply/stop/query/queryApplyStatus)。 */
export function publishVpnCommand(command: VpnCommand): void {
  try {
    const opts: commonEventManager.CommonEventPublishData = {
      bundleName: APP_BUNDLE,
      data: JSON.stringify(command)
    };
    commonEventManager.publish(VPN_EVENT_CMD, opts, (err: BusinessError) => {
      // 命令投递失败由调用方超时/看门狗兜底
    });
  } catch (e) {
    // ignore
  }
}

/** 扩展进程调用:订阅 UI 发来的命令。 */
export function subscribeVpnCommands(onCommand: (command: VpnCommand) => void): void {
  commonEventManager.createSubscriber({ events: [VPN_EVENT_CMD] }).then(
    (subscriber: commonEventManager.CommonEventSubscriber) => {
      vpnCmdSubscriber = subscriber;
      commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
        if (err || data === undefined || data === null || data.data === undefined) {
          return;
        }
        try {
          const raw = JSON.parse(data.data) as Record<string, Object>;
          const cmd = new VpnCommand();
          cmd.cmd = `${raw['cmd'] ?? ''}`;
          cmd.operationId = `${raw['operationId'] ?? ''}`;
          cmd.generation = Number(raw['generation'] ?? 0);
          cmd.revision = Number(raw['revision'] ?? 0);
          cmd.sessionId = `${raw['sessionId'] ?? ''}`;
          const extraRaw = raw['extra'];
          if (extraRaw !== undefined && extraRaw !== null) {
            const rec = extraRaw as Record<string, Object>;
            const keys = Object.keys(rec);
            for (let i = 0; i < keys.length; i++) {
              cmd.extra[keys[i]] = `${rec[keys[i]]}`;
            }
          }
          onCommand(cmd);
        } catch (e) {
          // 格式错误命令丢弃
        }
      });
    }).catch((e: Object) => {
      // 订阅失败:命令通道不可用，状态照旧靠事件
    });
}

/** 扩展进程销毁时取消命令订阅。 */
export function unsubscribeVpnCommands(): void {
  const subscriber = vpnCmdSubscriber;
  vpnCmdSubscriber = undefined;
  if (subscriber === undefined) {
    return;
  }
  try {
    commonEventManager.unsubscribe(subscriber, (err: BusinessError) => {
      // ignore
    });
  } catch (e) {
    // ignore
  }
}

/** UI 进程调用:订阅扩展发来的日志、状态与流量。onEnvelope 可选(§16.1 信封,缺失时按旧语义)。 */
export function subscribeVpnEvents(onLog: (line: string) => void,
  onStatus: (status: string, running: boolean, profileId: string) => void,
  onTraffic: (upSpeed: number, downSpeed: number, totalUp: number, totalDown: number) => void,
  onEnvelope?: (env: VpnEnvelope) => void): void {
  const generation = ++subscriptionGeneration;
  const info: commonEventManager.CommonEventSubscribeInfo = {
    events: [VPN_EVENT_LOG, VPN_EVENT_STATUS, VPN_EVENT_TRAFFIC]
  };
  commonEventManager.createSubscriber(info).then((subscriber: commonEventManager.CommonEventSubscriber) => {
    if (generation !== subscriptionGeneration) {
      return;
    }
    vpnEventSubscriber = subscriber;
    commonEventManager.subscribe(subscriber, (err: BusinessError, data: commonEventManager.CommonEventData) => {
      if (generation !== subscriptionGeneration || err || data === undefined || data === null) {
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
          if (onEnvelope !== undefined) {
            const envText = obj['env'] === undefined ? '' : `${obj['env']}`;
            const env = VpnEnvelope.fromJson(envText);
            if (env !== null) {
              onEnvelope(env);
            }
          }
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

/** UI Ability 销毁时调用，避免重复订阅和失效回调继续更新状态。 */
export function unsubscribeVpnEvents(): void {
  subscriptionGeneration++;
  const subscriber = vpnEventSubscriber;
  vpnEventSubscriber = undefined;
  if (subscriber === undefined) {
    return;
  }
  try {
    commonEventManager.unsubscribe(subscriber, (err: BusinessError) => {
      // 取消订阅失败不应影响 Ability 销毁流程
    });
  } catch (e) {
    // Ability 销毁期间忽略 CommonEvent 清理异常
  }
}
