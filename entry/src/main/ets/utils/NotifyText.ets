/**
 * 通知栏文本格式化(纯函数,便于主机单测)。
 *
 * 背景(2026-10-23 用户要求):常驻通知从"节点名 · 延迟"改成"实时速率 + 本次运行时长"。
 * 速率格式化仍留在 VpnExtAbility.formatNotificationSpeed(需要按 B/KB/MB 进位,已有实现),
 * 这里只抽"运行时长",因为它有明确边界(时/分/秒补零),适合用断言锁住。
 */

/** 运行时长:不足 1 小时 `mm:ss`,否则 `h:mm:ss`(小时不补零)。负值/非法值按 0 处理。 */
export function formatUptimeText(ms: number): string {
  const safe = ms > 0 ? ms : 0;
  const total = Math.floor(safe / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const mm = m < 10 ? `0${m}` : `${m}`;
  const ss = s < 10 ? `0${s}` : `${s}`;
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}
