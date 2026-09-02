import http from '@ohos.net.http';
import { CLASH_API_PORT } from './TrafficStats';

/**
 * 内核 clash API 封装。单出站架构下 route 只有 'proxy' 一个代理出站,
 * URL Test 直接查它的真实转发延迟(完整走一遍代理隧道 + 目标 204 探测)。
 */

export const URL_TEST_TARGET: string = 'https://www.gstatic.com/generate_204';

/** 查询当前激活出站('proxy')经隧道的真实延迟(ms);非 200 或缺 delay 抛异常 */
export async function fetchCurrentProxyDelay(timeoutMs: number = 5000): Promise<number> {
  const client = http.createHttp();
  try {
    const url = `http://127.0.0.1:${CLASH_API_PORT}/proxies/proxy/delay`
      + `?url=${encodeURIComponent(URL_TEST_TARGET)}&timeout=${timeoutMs}`;
    const resp = await client.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: timeoutMs + 3000,
      readTimeout: timeoutMs + 3000,
      expectDataType: http.HttpDataType.STRING
    });
    if (resp.responseCode !== 200) {
      throw new Error(`URL Test 失败: HTTP ${resp.responseCode}`);
    }
    const obj = JSON.parse(`${resp.result}`) as Record<string, Object>;
    const delay = Number(obj['delay']);
    if (isNaN(delay)) {
      throw new Error('URL Test 响应缺少 delay 字段');
    }
    return delay;
  } finally {
    client.destroy();
  }
}

/** 单节点测速别名:当前架构下仅激活出站可做 URL Test,其余节点请用 TCP 握手测速 */
export async function fetchProxyDelay(timeoutMs: number = 5000): Promise<number> {
  return fetchCurrentProxyDelay(timeoutMs);
}
