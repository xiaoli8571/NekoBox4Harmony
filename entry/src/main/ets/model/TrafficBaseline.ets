/**
 * 显示累计流量基准 —— REDESIGN-PLAN-2026-10-23.md §10.4(P5/W20)。
 *
 * 「重置显示累计流量」语义:记录**基准偏移**(内核累计总量在重置时刻的值 + 会话 epoch),
 * 显示值 = 当前总量 - 基准;UI 与通知从同一基准计算,轮询不再把旧显示值写回
 * (修复「清除流量统计被 1s 轮询写回」的已知问题)。
 * 节点历史流量(Profile.rx/tx)与会话流量与本显示值分别命名,重置互不影响。
 *
 * 纯函数/纯数据:主机测试见 tests/traffic-baseline.cjs。
 */

/** 显示基准(UI 与扩展通知共用;持久化到 Preferences 以跨进程共享)。 */
export class TrafficBaseline {
  /** 基准所属会话(空 = 无会话约束;扩展侧用它识别过期基准) */
  sessionId: string = '';
  /** 重置时刻的内核上传累计(字节) */
  up: number = 0;
  /** 重置时刻的内核下载累计(字节) */
  down: number = 0;
  createdAt: number = 0;
}

export function baselineToJson(b: TrafficBaseline): string {
  const parts: Array<string> = [];
  parts.push(`"sessionId":${JSON.stringify(b.sessionId)}`);
  parts.push(`"up":${b.up}`);
  parts.push(`"down":${b.down}`);
  parts.push(`"createdAt":${b.createdAt}`);
  return `{${parts.join(',')}}`;
}

export function parseBaseline(text: string): TrafficBaseline | null {
  try {
    const raw = JSON.parse(text) as Record<string, Object>;
    const b = new TrafficBaseline();
    b.sessionId = `${raw['sessionId'] ?? ''}`;
    b.up = Number(raw['up'] ?? 0);
    b.down = Number(raw['down'] ?? 0);
    b.createdAt = Number(raw['createdAt'] ?? 0);
    if (!(b.up >= 0) || !(b.down >= 0)) {
      return null;
    }
    return b;
  } catch (e) {
    return null;
  }
}

/** 由当前总量生成基准(重置动作)。 */
export function buildBaseline(up: number, down: number, sessionId: string, nowMs: number): TrafficBaseline {
  const b = new TrafficBaseline();
  b.up = Math.max(0, Math.floor(up));
  b.down = Math.max(0, Math.floor(down));
  b.sessionId = sessionId;
  b.createdAt = nowMs;
  return b;
}

/**
 * 显示值 = 当前总量 - 基准(不足按 0;基准无效/晚于当前 → 原样返回当前值)。
 * UI 速率条、连接页累计、扩展通知统一走这里,杜绝「清零后被轮询写回」。
 */
export function displayTotals(up: number, down: number, baseline: TrafficBaseline | null): Array<number> {
  if (baseline === null || baseline.createdAt <= 0) {
    return [Math.max(0, up), Math.max(0, down)];
  }
  if (up < baseline.up || down < baseline.down) {
    // 内核重启(计数器归零)或基准过期:显示原始值,不出负数
    return [Math.max(0, up), Math.max(0, down)];
  }
  return [up - baseline.up, down - baseline.down];
}

/** 基准是否已过期(内核计数器小于基准 → 内核重启,应丢弃基准)。 */
export function baselineStale(up: number, down: number, baseline: TrafficBaseline | null): boolean {
  if (baseline === null) {
    return false;
  }
  return up < baseline.up || down < baseline.down;
}
