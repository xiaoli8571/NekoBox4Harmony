import http from '@ohos.net.http';
import { computeMbps } from '../core/TrafficChart';

/**
 * 吞吐测速(下载/上传)—— 对齐 OwnBox 的 SpeedTestRunner 语义:真的搬字节,而不是测 RTT。
 *
 * 端点用 Cloudflare 的公开测速接口(与 OwnBox 默认一致):
 *  - 下行 `__down?bytes=N` 返回 N 个字节,读到多少算多少;
 *  - 上行 `__up` 接收 POST body,传多少算多少。
 *
 * 口径提醒:请求走应用自己的网络路径(与落地 IP 诊断相同)。全局模式下应用流量同样进
 * TUN,量到的就是节点吞吐;分应用模式若没把自己列进去,量到的是本机直连 —— 页面上
 * 会根据 `vpnRunning` 明确标注,不把直连速度当节点速度汇报。
 */

const DOWN_URL: string = 'https://speed.cloudflare.com/__down?bytes=';
const UP_URL: string = 'https://speed.cloudflare.com/__up';

export class SpeedResult {
  ok: boolean = false;
  /** Mbit/s */
  mbps: number = 0;
  bytes: number = 0;
  ms: number = 0;
  error: string = '';
}

function fail(error: string): SpeedResult {
  const r = new SpeedResult();
  r.error = error;
  return r;
}

function byteLengthOf(raw: string | Object | ArrayBuffer): number {
  if (raw instanceof ArrayBuffer) {
    return raw.byteLength;
  }
  if (typeof raw === 'string') {
    // 字符串按 UTF-8 估算:测速正文是随机字节,1 字符≈1 字节,误差可忽略
    return raw.length;
  }
  return 0;
}

/** 下行:拉 sizeBytes 字节,按「实际到手字节 / 墙钟耗时」算 Mbps */
export async function downloadTest(sizeBytes: number, timeoutMs: number): Promise<SpeedResult> {
  const size: number = sizeBytes > 0 ? Math.floor(sizeBytes) : 10 * 1024 * 1024;
  const client = http.createHttp();
  const started = Date.now();
  try {
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'Accept': '*/*', 'Cache-Control': 'no-store' },
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      usingProtocol: http.HttpProtocol.HTTP1_1,
      connectTimeout: 10000,
      readTimeout: timeoutMs,
      usingCache: false
    };
    const resp = await client.request(`${DOWN_URL}${size}`, opts);
    const ms: number = Date.now() - started;
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      return fail(`http_${resp.responseCode}`);
    }
    const bytes: number = byteLengthOf(resp.result);
    if (bytes <= 0) {
      return fail('empty_body');
    }
    const r = new SpeedResult();
    r.ok = true;
    r.bytes = bytes;
    r.ms = ms;
    r.mbps = computeMbps(bytes, ms);
    return r;
  } catch (e) {
    return fail(e instanceof Error ? e.message : `${e}`);
  } finally {
    try {
      client.destroy();
    } catch (e) {
      // 忽略
    }
  }
}

/** 上行:POST sizeBytes 随机字节(不用全 0,避免中间层压缩把结果虚高) */
export async function uploadTest(sizeBytes: number, timeoutMs: number): Promise<SpeedResult> {
  const size: number = sizeBytes > 0 ? Math.floor(sizeBytes) : 2 * 1024 * 1024;
  const buffer = new ArrayBuffer(size);
  const view = new Uint8Array(buffer);
  // 伪随机填充:LCG 够用,且不引入依赖
  let seed = 0x9e3779b9;
  for (let i = 0; i < size; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    view[i] = seed & 0xff;
  }
  const client = http.createHttp();
  const started = Date.now();
  try {
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/octet-stream' },
      extraData: buffer,
      expectDataType: http.HttpDataType.STRING,
      usingProtocol: http.HttpProtocol.HTTP1_1,
      connectTimeout: 10000,
      readTimeout: timeoutMs,
      usingCache: false
    };
    const resp = await client.request(UP_URL, opts);
    const ms: number = Date.now() - started;
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      return fail(`http_${resp.responseCode}`);
    }
    const r = new SpeedResult();
    r.ok = true;
    r.bytes = size;
    r.ms = ms;
    r.mbps = computeMbps(size, ms);
    return r;
  } catch (e) {
    return fail(e instanceof Error ? e.message : `${e}`);
  } finally {
    try {
      client.destroy();
    } catch (e) {
      // 忽略
    }
  }
}
