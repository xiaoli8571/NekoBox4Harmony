import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import common from '@ohos.app.ability.common';
import BusinessError from '@ohos.base';
import { LogStore } from '../model/Store';
import { shouldHoldTransfer, transferNeedsWarn, TRANSFER_CANCEL_MS } from './KeepAlivePolicy';

/**
 * 传输期长时任务守卫(2026-10-23 保活整改,依据 docs/REA-FLCLASH-KEEPALIVE.md)。
 *
 * 为什么不是"会话级保活":
 *  FlClash 用的是 `BackgroundMode.TASK_KEEPING`,但该模式在 phone/tablet 上**必需**受限 ACL
 *  `ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM`(SDK d.ts:non-PC/2-in-1 设备需该 ACL),
 *  个人开发者在 AGC 拿不到 ⇒ 不可复制。
 *  退而用 `DATA_TRANSFER` 也不成立:SDK 明确它是"上传/下载"任务,**进度通知 10 分钟不更新
 *  (且必须是 live view 类型)就会被系统取消**,低速也会被取消
 *  (ContinuousTaskCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED=4)。
 *  把 DATA_TRANSFER 当"VPN 会话保活"用,既与申请用途不符(AGC 审核风险),也会 10 分钟后失效。
 *
 * 因此本类只做一件事:**真实数据传输(订阅更新 / Geo 资产下载)期间**短时持有 DATA_TRANSFER,
 * 申请失败不影响业务;传输本身通常几秒~几十秒,远低于 10 分钟取消线;超过 8 分钟会记一条
 * 告警日志(提示后续接 live view 进度通知)。
 *
 * VPN 会话本身的存活靠:VpnExtensionAbility(系统托管,:vpn 进程)+ 常驻通知 + 被杀自愈
 * (core/CrashGuard.ets),这些都不需要额外权限。
 */
export class KeepAliveManager {
  private static context: common.UIAbilityContext | null = null;
  private static active: boolean = false;
  private static reason: string = '';
  private static rearming: boolean = false;
  private static startedAt: number = 0;
  private static warnTimer: number = -1;

  /** 由 EntryAbility.onCreate / 页面注入 UIAbilityContext(长时任务只能用 UIAbility 上下文申请)。 */
  static setContext(context: common.UIAbilityContext): void {
    KeepAliveManager.context = context;
  }

  static isTransferActive(): boolean {
    return KeepAliveManager.active;
  }

  /**
   * 开始一段数据传输:申请 DATA_TRANSFER 长时任务(失败仅记日志,不抛)。
   * @param reason 'subscription' | 'geo'(见 KeepAlivePolicy.TRANSFER_REASONS)
   */
  static async beginTransfer(reason: string): Promise<boolean> {
    if (!shouldHoldTransfer(reason)) {
      LogStore.addLog(`[app] 拒绝为非传输场景申请长时任务: ${reason}(见 docs/REA-FLCLASH-KEEPALIVE.md)`);
      return false;
    }
    if (KeepAliveManager.active) {
      return true;
    }
    const context = KeepAliveManager.context;
    if (context === null) {
      LogStore.addLog('[app] 无 UIAbility 上下文,跳过长时任务申请');
      return false;
    }
    KeepAliveManager.reason = reason;
    const ok = await KeepAliveManager.acquire(context);
    if (ok) {
      KeepAliveManager.active = true;
      KeepAliveManager.startedAt = Date.now();
      KeepAliveManager.armWarnTimer();
    }
    return ok;
  }

  /** 结束数据传输:停告警计时、解除取消监听、释放长时任务。幂等。 */
  static async endTransfer(reason: string = ''): Promise<void> {
    if (!KeepAliveManager.active) {
      return;
    }
    KeepAliveManager.active = false;
    KeepAliveManager.rearming = false;
    if (KeepAliveManager.warnTimer >= 0) {
      clearTimeout(KeepAliveManager.warnTimer);
      KeepAliveManager.warnTimer = -1;
    }
    const elapsed = Date.now() - KeepAliveManager.startedAt;
    try {
      backgroundTaskManager.off('continuousTaskCancel');
    } catch (e) {
      // 未注册时 off 会抛,忽略
    }
    const context = KeepAliveManager.context;
    if (context !== null) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
      } catch (e) {
        LogStore.addLog(`[app] 释放长时任务失败(${reason}): ${e}`);
      }
    }
    LogStore.addLog(`[app] 长时任务已释放(${reason.length > 0 ? reason : KeepAliveManager.reason},耗时 ${elapsed}ms)`);
    KeepAliveManager.reason = '';
  }

  private static async acquire(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const agent: WantAgent = await wantAgent.getWantAgent({
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1004,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      // 取消监听必须在 startBackgroundRunning 之前注册,否则首次取消可能错过。
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        LogStore.addLog(`[app] 长时任务被系统取消(reason=${info.reason}),若是传输未结束则 1 秒后重挂`);
        KeepAliveManager.onCancelled();
      });
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      LogStore.addLog(`[app] 长时任务已申请: DATA_TRANSFER(${KeepAliveManager.reason},仅传输期)`);
      return true;
    } catch (e) {
      const msg = KeepAliveManager.errText(e);
      LogStore.addLog(`[app] DATA_TRANSFER 长时任务申请失败(不影响传输): ${msg}`);
      try {
        backgroundTaskManager.off('continuousTaskCancel');
      } catch (offErr) {
        // ignore
      }
      return false;
    }
  }

  /** BusinessError 的 `toString()` 会给 `[object Object]`,这里显式取 code/message 便于真机定因。 */
  private static errText(e: Object): string {
    const be = e as BusinessError;
    if (be !== undefined && be !== null && be.code !== undefined) {
      return `code=${be.code} msg=${be.message}`;
    }
    return e instanceof Error ? e.message : `${e}`;
  }

  /** 传输还在进行就被系统取消 → 1 秒后重挂(FlClash 同语义,但只限传输期)。 */
  private static onCancelled(): void {
    if (!KeepAliveManager.active || KeepAliveManager.rearming) {
      return;
    }
    const context = KeepAliveManager.context;
    if (context === null) {
      return;
    }
    KeepAliveManager.rearming = true;
    setTimeout(() => {
      KeepAliveManager.rearming = false;
      if (!KeepAliveManager.active || KeepAliveManager.context === null) {
        return;
      }
      KeepAliveManager.acquire(context).catch((e: Object) => {
        LogStore.addLog(`[app] 长时任务重挂失败: ${e}`);
      });
    }, 1000);
  }

  /** 8 分钟告警:超过此线说明传输过久,系统 10 分钟无 live view 进度通知就会取消。 */
  private static armWarnTimer(): void {
    if (KeepAliveManager.warnTimer >= 0) {
      clearTimeout(KeepAliveManager.warnTimer);
    }
    KeepAliveManager.warnTimer = setTimeout(() => {
      KeepAliveManager.warnTimer = -1;
      const elapsed = Date.now() - KeepAliveManager.startedAt;
      if (KeepAliveManager.active && transferNeedsWarn(elapsed)) {
        LogStore.addLog(`[app] 传输已持续 ${elapsed}ms,接近系统 ${TRANSFER_CANCEL_MS}ms 取消线;` +
          '若需更长传输,须改接 live view 进度通知(SDK 要求)');
      }
    }, TRANSFER_CANCEL_MS - 120000);
  }
}
