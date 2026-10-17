import http from '@ohos.net.http';
import { CLASH_API_PORT } from './TrafficStats';
import { clashApiHeaders, clashApiErrorMessage } from './ClashAuth';

/**
 * 内核 clash API 封装。单出站架构下 route 只有 'proxy' 一个代理出站,
 * URL Test 直接查它的真实转发延迟(完整走一遍代理隧道 + 目标 204 探测)。
 */

// 与 Clash/mihomo 同口径的 HTTP 204 探测(HTTPS 会多算到目标站的 TLS 握手)
export const URL_TEST_TARGET: string = 'http://www.gstatic.com/generate_204';

/** 查询当前激活出站('proxy')经隧道的真实延迟(ms);非 200 或缺 delay 抛异常 */
export async function fetchCurrentProxyDelay(timeoutMs: number = 5000,
  port: number = CLASH_API_PORT, testUrl: string = URL_TEST_TARGET,
  secret: string = ''): Promise<number> {
  const client = http.createHttp();
  try {
    const url = `http://127.0.0.1:${port}/proxies/proxy/delay`
      + `?url=${encodeURIComponent(testUrl)}&timeout=${timeoutMs}`;
    const resp = await client.request(url, {
      method: http.RequestMethod.GET,
      header: clashApiHeaders(secret),
      connectTimeout: timeoutMs + 3000,
      readTimeout: timeoutMs + 3000,
      expectDataType: http.HttpDataType.STRING
    });
    if (resp.responseCode !== 200) {
      throw new Error(clashApiErrorMessage(resp.responseCode, 'URL Test 失败'));
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
export async function fetchProxyDelay(timeoutMs: number = 5000,
  port: number = CLASH_API_PORT, testUrl: string = URL_TEST_TARGET,
  secret: string = ''): Promise<number> {
  return fetchCurrentProxyDelay(timeoutMs, port, testUrl, secret);
}

/**
 * selector 组内热切换(对齐安卓 cbSelectorUpdate / Selector select):
 * PUT /proxies/{selectorTag} body {name: 节点名}。内核在 selector 组内
 * 直接切换激活出站,免配置重建零断流;返回是否成功。
 */
export async function selectProxy(selectorTag: string, nodeName: string,
  port: number = CLASH_API_PORT, secret: string = ''): Promise<boolean> {
  const client = http.createHttp();
  try {
    const url = `http://127.0.0.1:${port}/proxies/${encodeURIComponent(selectorTag)}`;
    const headers: Record<string, string> = clashApiHeaders(secret);
    headers['Content-Type'] = 'application/json';
    const body: Record<string, string> = { 'name': nodeName };
    const resp = await client.request(url, {
      method: http.RequestMethod.PUT,
      header: headers,
      extraData: JSON.stringify(body),
      connectTimeout: 3000,
      readTimeout: 3000,
      expectDataType: http.HttpDataType.STRING
    });
    return resp.responseCode === 204 || resp.responseCode === 200;
  } catch (e) {
    return false;
  } finally {
    client.destroy();
  }
}
