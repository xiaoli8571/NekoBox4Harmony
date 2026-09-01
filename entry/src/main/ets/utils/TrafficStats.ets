import http from '@ohos.net.http';

/** 通过内核 clash API(/connections)轮询流量累计值,差分得到实时速率。 */

export const CLASH_API_PORT: number = 19290;

export interface TrafficTotals {
  up: number;
  down: number;
}

/** 通过当前运行节点的 Clash API proxy tag 执行 URL Test。 */
export async function fetchProxyDelay(tag: string, testUrl: string = 'https://www.gstatic.com/generate_204',
  timeout: number = 5000): Promise<number> {
  const client = http.createHttp();
  try {
    const encodedTag = encodeURIComponent(tag);
    const encodedUrl = encodeURIComponent(testUrl);
    const resp = await client.request(
      `http://127.0.0.1:${CLASH_API_PORT}/proxies/${encodedTag}/delay?url=${encodedUrl}&timeout=${timeout}`,
      {
        method: http.RequestMethod.GET,
        connectTimeout: timeout + 1000,
        readTimeout: timeout + 1000,
        expectDataType: http.HttpDataType.STRING
      }
    );
    if (resp.responseCode !== 200) {
      return -1;
    }
    const obj = JSON.parse(`${resp.result}`) as Record<string, Object>;
    const delay = Number(obj['delay']);
    if (isNaN(delay) || delay < 0) {
      return -1;
    }
    return delay;
  } catch (e) {
    return -1;
  } finally {
    client.destroy();
  }
}

export async function fetchTrafficTotals(): Promise<TrafficTotals | null> {
  const client = http.createHttp();
  try {
    const resp = await client.request(`http://127.0.0.1:${CLASH_API_PORT}/connections`, {
      method: http.RequestMethod.GET,
      connectTimeout: 1500,
      readTimeout: 1500,
      expectDataType: http.HttpDataType.STRING
    });
    if (resp.responseCode !== 200) {
      return null;
    }
    const obj = JSON.parse(`${resp.result}`) as Record<string, Object>;
    const up = Number(obj['uploadTotal']);
    const down = Number(obj['downloadTotal']);
    if (isNaN(up) || isNaN(down)) {
      return null;
    }
    const t: TrafficTotals = { up: up, down: down };
    return t;
  } catch (e) {
    return null;
  } finally {
    client.destroy();
  }
}

export function formatBytes(n: number): string {
  if (n < 1024) {
    return `${n} B`;
  }
  const kb = n / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB`;
  }
  const mb = kb / 1024;
  if (mb < 1024) {
    return `${mb.toFixed(1)} MB`;
  }
  return `${(mb / 1024).toFixed(2)} GB`;
}

export function formatSpeed(bytesPerSec: number): string {
  if (bytesPerSec < 1024) {
    return `${bytesPerSec} B/s`;
  }
  const kb = bytesPerSec / 1024;
  if (kb < 1024) {
    return `${kb.toFixed(1)} KB/s`;
  }
  return `${(kb / 1024).toFixed(1)} MB/s`;
}
