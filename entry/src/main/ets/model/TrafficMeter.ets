/**
 * 内核 /traffic 流样本模型(P1 单流量生产者)。
 *
 * sing-box clash API 的 `/traffic` WebSocket 每 1 秒推送一次**增量**:
 *   {"up": 本秒上传字节, "down": 本秒下载字节}
 * 注意它与 `/connections` 的 `uploadTotal/downloadTotal` 语义不同(后者是累计值)。
 *
 * 扩展进程是唯一流量生产者:把增量累加回内核累计口径,再用同一份
 * TrafficBaseline 计算显示值,经 CommonEvent 分发给 UI(StatsBar)与通知。
 * 纯函数/纯数据,主机测试见 tests/traffic-meter.cjs。
 */

export interface TrafficDelta {
  up: number;
  down: number;
}

/** 解析一帧 /traffic 文本;坏数据返回 null(不抛)。 */
export function parseTrafficDelta(text: string): TrafficDelta | null {
  if (text.length === 0) {
    return null;
  }
  try {
    const raw = JSON.parse(text) as Record<string, Object>;
    const upRaw = raw['up'];
    const downRaw = raw['down'];
    // 只接受 JSON 数字:null/字符串/布尔都不能被 Number() 悄悄转成 0
    if (typeof upRaw !== 'number' || typeof downRaw !== 'number') {
      return null;
    }
    const up = Number(upRaw);
    const down = Number(downRaw);
    // /traffic 的字段是增量,负数/NaN 都说明帧损坏或对端不是 sing-box
    if (!isFinite(up) || !isFinite(down) || up < 0 || down < 0) {
      return null;
    }
    const delta: TrafficDelta = { up: up, down: down };
    return delta;
  } catch (e) {
    return null;
  }
}

/**
 * 内核累计口径的流量表。
 *
 * 会话开始/重连时用一次 `/connections` 快照 `reset()` 对齐内核,
 * 之后每帧增量 `add()`。这样既保留「清除流量统计」基准所需的累计语义,
 * 又不再每秒解析整份连接列表。
 */
export class TrafficMeter {
  private upTotal: number = 0;
  private downTotal: number = 0;

  reset(up: number, down: number): void {
    this.upTotal = isFinite(up) && up > 0 ? Math.floor(up) : 0;
    this.downTotal = isFinite(down) && down > 0 ? Math.floor(down) : 0;
  }

  add(delta: TrafficDelta): void {
    if (delta.up > 0) {
      this.upTotal += Math.floor(delta.up);
    }
    if (delta.down > 0) {
      this.downTotal += Math.floor(delta.down);
    }
  }

  up(): number {
    return this.upTotal;
  }

  down(): number {
    return this.downTotal;
  }
}
