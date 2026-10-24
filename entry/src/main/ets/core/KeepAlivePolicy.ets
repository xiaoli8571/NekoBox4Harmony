/**
 * KeepAlivePolicy.ets — 后台保活策略的**纯函数**(可被 tests/keepalive-policy.cjs 直测)。
 *
 * 结论来源:docs/REA-FLCLASH-KEEPALIVE.md(2026-10-23,SDK d.ts + PermissionDefinitions.json 取证):
 *  - TASK_KEEPING 在 phone/tablet 上必需受限 ACL `KEEP_BACKGROUND_RUNNING_SYSTEM`,
 *    个人开发者拿不到 ⇒ 不使用;
 *  - DATA_TRANSFER 是"上传/下载"任务:**进度通知 10 分钟不更新(live view)会被系统取消**,
 *    低速也会被取消(ContinuousTaskCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED=4)
 *    ⇒ 只允许在**真实数据传输**(订阅更新/Geo 资产下载)期间短时持有,VPN 会话本身不持有;
 *  - VPN 会话存活的正解是 VpnExtensionAbility(系统托管)+ 常驻通知 + 被杀自愈,零权限。
 */

/** 系统取消线:DATA_TRANSFER 10 分钟无进度通知即取消(d.ts MODE_DATA_TRANSFER 注释)。 */
export const TRANSFER_CANCEL_MS: number = 10 * 60 * 1000;

/** 我们自己的告警线:传输超过 8 分钟仍未结束就记日志(给 live view 进度通知留出改造窗口)。 */
export const TRANSFER_WARN_MS: number = 8 * 60 * 1000;

/** 允许持有 DATA_TRANSFER 长时任务的场景(必须是真实的数据传输)。 */
export const TRANSFER_REASONS: Array<string> = ['subscription', 'geo'];

/**
 * 是否允许为该场景持有长时任务。
 * 只有真实数据传输可以;`session`(VPN 会话级保活)在个人开发者权限模型下不合法,一律拒绝。
 */
export function shouldHoldTransfer(reason: string): boolean {
  return TRANSFER_REASONS.indexOf(reason) >= 0;
}

/** 传输已持续 elapsedMs,是否已接近系统取消线(需要告警/收尾)。 */
export function transferNeedsWarn(elapsedMs: number): boolean {
  return elapsedMs >= TRANSFER_WARN_MS;
}

/** 传输剩余的"安全窗口"(毫秒);<=0 表示已越过告警线。 */
export function transferRemainingMs(elapsedMs: number): number {
  return TRANSFER_CANCEL_MS - elapsedMs;
}

/**
 * 被杀自愈决策(启动时调用):
 *  - 上次进程死亡时 VPN 开着(alive=1)且现在没连 → 需要恢复;
 *  - `autoReconnect`(用户开了"启动自动连接")→ 直接重连;
 *  - 否则 → 弹确认框询问。
 * 返回 'none' | 'reconnect' | 'prompt'(ArkTS 不收字符串字面量联合,统一返回 string)。
 */
export function killRecoveryAction(wasAlive: boolean, vpnRunningNow: boolean,
  profileId: string, autoReconnect: boolean): string {
  if (!wasAlive || vpnRunningNow || profileId.length === 0) {
    return 'none';
  }
  return autoReconnect ? 'reconnect' : 'prompt';
}

/** 被杀标记解析结果(ArkTS 不允许匿名对象类型,用显式类)。 */
export class KillState {
  alive: boolean = false;
  profileId: string = '';
  updatedAt: number = 0;

  constructor(alive: boolean, profileId: string, updatedAt: number) {
    this.alive = alive;
    this.profileId = profileId;
    this.updatedAt = updatedAt;
  }
}

/** 被杀标记的持久化编码:`alive|profileId|updatedAt`(纯字符串,避免 JSON 解析的类型断言)。 */
export function encodeKillState(alive: boolean, profileId: string, updatedAt: number): string {
  return `${alive ? 1 : 0}|${profileId}|${updatedAt}`;
}

/** 被杀标记的解析;非法输入一律按"干净退出"处理。 */
export function decodeKillState(raw: string): KillState {
  const parts = raw.split('|');
  if (parts.length !== 3) {
    return new KillState(false, '', 0);
  }
  return new KillState(parts[0] === '1', parts[1], Number(parts[2]) || 0);
}
