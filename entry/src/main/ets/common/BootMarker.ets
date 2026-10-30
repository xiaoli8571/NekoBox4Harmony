import systemDateTime from '@ohos.systemDateTime';

/**
 * 开机检测(替代 OwnBox 的 BootReceiver)。
 *
 * 平台事实:鸿蒙 SDK 26 不再向三方应用开放 StaticSubscriberExtensionAbility
 * (ets/api 里没有该声明),`BOOT_COMPLETED` 静态订阅收不到,装机也会因权限被拒。
 * 所以「开机自启」在这里落成**语义等价的最小实现**:记录本次开机的起始时刻,
 * 下次应用被打开时若与上次不同 ⇒ 期间发生过重启 ⇒ 依据设置自动连接。
 *
 * 与 OwnBox 的差异:OwnBox 是重启后由系统拉起;我们只能在用户首次打开应用时连。
 * 这是平台限制,不是实现取舍。
 */
export const KEY_BOOT_STARTED: string = 'boot_started_at';
/** 两次开机时刻差超过该容差(2 分钟)才算重启过(容忍时钟抖动/时区调整) */
const REBOOT_TOLERANCE_MS: number = 120000;

/** 本次开机时刻(毫秒时间戳);取不到返回 0(调用方按"无法判断"处理) */
export function currentBootStartedAt(): number {
  try {
    // isNanoseconds=false ⇒ 返回毫秒
    const uptimeMs = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
    if (uptimeMs <= 0) {
      return 0;
    }
    return Date.now() - uptimeMs;
  } catch (e) {
    return 0;
  }
}

/** 纯判定:上次记录 0/本次 0 都视为"无法判断",不触发自启(宁可不动) */
export function isNewBoot(previous: number, current: number): boolean {
  if (previous <= 0 || current <= 0) {
    return false;
  }
  const diff = current > previous ? current - previous : previous - current;
  return diff > REBOOT_TOLERANCE_MS;
}
