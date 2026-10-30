import http from '@ohos.net.http';

/**
 * 诊断/测速用的极简 HTTP 探测 —— 只负责「发一个 GET,拿回状态码和正文,顺便量耗时」。
 *
 * 与订阅的 fetch 故意分开:订阅那边对 304/重定向/UA 兜底/压缩有一整套业务规则,
 * 这里只要一个能失败的原始请求,免得两套逻辑互相牵制。
 */

/** 与订阅默认 UA 保持一致(Mozilla 形态,避免服务端把 CLI UA 直接 403) */
export const PROBE_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
    'Chrome/128.0.0.0 Safari/537.36';

export class ProbeResponse {
  ok: boolean = false;
  status: number = 0;
  body: string = '';
  error: string = '';
  /** 从 request() 调用到响应返回的墙钟耗时(毫秒) */
  ms: number = 0;
}

export async function httpGet(url: string, timeoutMs: number, ua: string,
  maxBodyChars: number): Promise<ProbeResponse> {
  const res = new ProbeResponse();
  if (url.length === 0) {
    res.error = 'empty_url';
    return res;
  }
  const client = http.createHttp();
  const started = Date.now();
  try {
    const headers: Record<string, string> = {
      'User-Agent': ua.length > 0 ? ua : PROBE_UA,
      'Accept': '*/*'
    };
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.STRING,
      usingProtocol: http.HttpProtocol.HTTP1_1,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      // 诊断必须看真实响应,缓存命中会让「地区/风控」全部失真
      usingCache: false
    };
    const resp = await client.request(url, opts);
    res.ms = Date.now() - started;
    res.status = resp.responseCode;
    const raw = resp.result;
    const text = typeof raw === 'string' ? raw : '';
    res.body = text.length > maxBodyChars ? text.substring(0, maxBodyChars) : text;
    // 对齐 OwnBox 的「能拿到正文才算通」:2xx 视为通(204 也算),
    // 其余保留状态码但判失败(classify 只看 ok)。
    res.ok = resp.responseCode >= 200 && resp.responseCode < 300;
    if (!res.ok) {
      res.error = `http_${resp.responseCode}`;
    }
  } catch (e) {
    res.ms = Date.now() - started;
    res.ok = false;
    res.error = e instanceof Error ? e.message : `${e}`;
  } finally {
    try {
      client.destroy();
    } catch (e) {
      // destroy 失败不影响结果
    }
  }
  return res;
}
