/**
 * 流量曲线与测速换算 —— 纯模型(无 I/O、无 UI)。
 *
 * 页面(pages/TrafficPage.ets)每秒把 `vpnUpSpeed/vpnDownSpeed`(AppStorage 里已是
 * 字节/秒)推进环形缓冲,再由这里算归一化柱高、坐标上限和峰值;测速结果也只在这里换算。
 * 这样一来图表逻辑和 Canvas/布局无关,可以在 Node 里直接测(tests/traffic-chart.cjs)。
 */

/** 固定容量的采样环:满了从头部丢,天然得到「最近 N 秒」窗口 */
export class TrafficSeries {
  capacity: number = 60;
  values: Array<number> = [];

  constructor(capacity: number = 60) {
    this.capacity = capacity > 0 ? Math.floor(capacity) : 60;
  }

  push(value: number): void {
    const v: number = value > 0 && isFinite(value) ? value : 0;
    this.values.push(v);
    while (this.values.length > this.capacity) {
      this.values.shift();
    }
  }

  /** 用首尾差补一次同值采样(采样定时器被系统挂起时,不让曲线出现断崖) */
  fill(count: number): void {
    if (this.values.length === 0) {
      return;
    }
    const last: number = this.values[this.values.length - 1];
    const n: number = Math.min(Math.max(0, Math.floor(count)), this.capacity);
    for (let i = 0; i < n; i++) {
      this.push(last);
    }
  }

  latest(): number {
    if (this.values.length === 0) {
      return 0;
    }
    return this.values[this.values.length - 1];
  }

  max(): number {
    let m = 0;
    for (let i = 0; i < this.values.length; i++) {
      if (this.values[i] > m) {
        m = this.values[i];
      }
    }
    return m;
  }

  avg(): number {
    if (this.values.length === 0) {
      return 0;
    }
    let sum = 0;
    for (let i = 0; i < this.values.length; i++) {
      sum += this.values[i];
    }
    return sum / this.values.length;
  }

  reset(): void {
    this.values = [];
  }

  /** 曲线右对齐:不足容量的部分补 0(让新数据永远贴在右边) */
  padded(): Array<number> {
    const out: Array<number> = [];
    const missing: number = this.capacity - this.values.length;
    for (let i = 0; i < missing; i++) {
      out.push(0);
    }
    for (let i = 0; i < this.values.length; i++) {
      out.push(this.values[i]);
    }
    return out;
  }
}

/**
 * 坐标上限取「好看的整数」:1/2/5 × 10^n。
 * 直接拿峰值当上限会让波动被压扁,固定上限又会让小流量贴地,所以按量级取整。
 */
export function niceMax(value: number): number {
  if (!(value > 0) || !isFinite(value)) {
    return 1;
  }
  const exp: number = Math.floor(Math.log10(value));
  const base: number = Math.pow(10, exp);
  const n: number = value / base;
  let mult = 10;
  if (n <= 1) {
    mult = 1;
  } else if (n <= 2) {
    mult = 2;
  } else if (n <= 5) {
    mult = 5;
  }
  return mult * base;
}

/** 归一化到 0..1;上限由调用方给(niceMax(峰值)) */
export function normalize(values: Array<number>, scaleMax: number): Array<number> {
  const max: number = scaleMax > 0 ? scaleMax : 1;
  const out: Array<number> = [];
  for (let i = 0; i < values.length; i++) {
    const v = values[i] > 0 ? values[i] : 0;
    out.push(Math.min(1, v / max));
  }
  return out;
}

/** 柱高像素:至少留 1px,否则「有流量」和「没流量」在视觉上分不出来 */
export function barHeight(value: number, maxValue: number, trackHeight: number): number {
  if (!(value > 0) || !(trackHeight > 0)) {
    return 0;
  }
  const max: number = maxValue > 0 ? maxValue : 1;
  const h: number = Math.min(1, value / max) * trackHeight;
  return h < 1 ? 1 : h;
}

/** 测速:Mbps = bytes × 8 / ms / 1000(ms 为墙钟耗时) */
export function computeMbps(bytes: number, ms: number): number {
  if (!(bytes > 0) || !(ms > 0)) {
    return 0;
  }
  return (bytes * 8) / ms / 1000;
}

/** 测速展示:小数值保留两位,免得 0.04 和 0.4 都显示成 0 */
export function formatMbps(mbps: number): string {
  if (!(mbps > 0) || !isFinite(mbps)) {
    return '0';
  }
  if (mbps < 1) {
    return mbps.toFixed(2);
  }
  if (mbps < 10) {
    return mbps.toFixed(1);
  }
  return `${Math.round(mbps)}`;
}

export const SPEED_SLOW: string = 'slow';
export const SPEED_FAIR: string = 'fair';
export const SPEED_GOOD: string = 'good';
export const SPEED_FAST: string = 'fast';

/** 粗判档位(页面据此上色),阈值按移动网络常见体验划 */
export function speedVerdict(mbps: number): string {
  if (!(mbps > 2)) {
    return SPEED_SLOW;
  }
  if (mbps < 10) {
    return SPEED_FAIR;
  }
  if (mbps < 30) {
    return SPEED_GOOD;
  }
  return SPEED_FAST;
}

/** 本次会话累计(上/下行字节),页面每次采样增量累加 */
export class TrafficTotals {
  up: number = 0;
  down: number = 0;
  peakUp: number = 0;
  peakDown: number = 0;

  add(upBps: number, downBps: number): void {
    const up: number = upBps > 0 ? upBps : 0;
    const down: number = downBps > 0 ? downBps : 0;
    this.up += up;
    this.down += down;
    if (up > this.peakUp) {
      this.peakUp = up;
    }
    if (down > this.peakDown) {
      this.peakDown = down;
    }
  }

  reset(): void {
    this.up = 0;
    this.down = 0;
    this.peakUp = 0;
    this.peakDown = 0;
  }
}
