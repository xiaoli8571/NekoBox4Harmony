import http from '@ohos.net.http';
import { clashApiHeaders } from '../utils/ClashAuth';

/**
 * Clash API 客户端 —— P4/W15(方案 §9.2 热切换 / §9.4 组管理)。
 *
 * 纯客户端：HTTP 传输可注入(tests/clash-api.cjs 用桩，不联网)，默认传输用
 * `@ohos.net.http`(与 utils/ClashApi.ets:22-44 同风格)。
 *
 * ---- 路由与鉴权事实(sing-box 1.14 源码，2026-10-24 核对) ----
 * 1) 路由表 `core/sing-box-1.14/experimental/clashapi/proxies.go:30-40`：
 *    GET  /proxies                     → 全部代理(含合成项 GLOBAL，type=Fallback)
 *    GET  /proxies/{name}              → 单个代理
 *    GET  /proxies/{name}/delay        → 真实延迟(本项目 utils/ClashApi 已用)
 *    PUT  /proxies/{name}              → 组内切换 body {"name": 成员名}
 *    成功是 204 No Content(`render.NoContent`，proxies.go:185)；
 *    非 selector 组 → 400 "Must be a Selector"(proxies.go:171-175)；
 *    成员不存在 → 400 "Selector update error: not found"(proxies.go:179-183)；
 *    组名不存在 → 404(proxies.go:56-64)。
 * 2) GET /proxies 响应外层是 `{"proxies": {...}}`(proxies.go:124-139)；组才会带
 *    `now`/`all`(proxies.go:78-84)，普通出站没有这两个字段。
 * 3) `type` 是展示名 `C.ProxyDisplayName`：selector→"Selector"、urltest→"URLTest"
 *    (constant/proxy.go:115-117)，**不能**拿显示名当标识(§9.2-2，标识用 tag)。
 * 4) 鉴权：`Authorization: Bearer <secret>`，不匹配一律 401
 *    (server.go:270-283)；secret 为空时中间件直接放行(server.go:251-255)，
 *    所以空 secret 不能发 Authorization 头 —— 统一走 utils/ClashAuth.clashApiHeaders。
 * 5) 控制器地址由 ConfigBuilder 写入 `experimental.clash_api.external_controller =
 *    127.0.0.1:<clashApiPort>` 与 `secret`(ConfigBuilder.ets:1233-1237)。
 */

// 可用性/结果 reason 词表(空串 = 成功)
export const CLASH_REASON_DISABLED: string = 'disabled';
export const CLASH_REASON_REFUSED: string = 'refused';
export const CLASH_REASON_TIMEOUT: string = 'timeout';
export const CLASH_REASON_UNAUTHORIZED: string = 'unauthorized';
export const CLASH_REASON_HTTP_ERROR: string = 'http_error';
export const CLASH_REASON_NOT_FOUND: string = 'not_found';
export const CLASH_REASON_REJECTED: string = 'rejected';
export const CLASH_REASON_PARSE_ERROR: string = 'parse_error';

/** 客户端配置：端口/密钥与 AppSettings.clashApiPort/clashApiSecret 同名同值。 */
export class ClashApiConfig {
  port: number = 19290;
  secret: string = '';
  timeoutMs: number = 5000;
}

/**
 * 传输层响应。`errorKind` 为空 = 真的收到 HTTP 响应；
 * 非空表示没连上：'timeout' | 'refused' | 'other'(由 defaultTransport 归类)。
 * 注入的桩也可以直接抛异常，ClashApi 会按 message 归类。
 */
export class ClashHttpResp {
  status: number = 0;
  body: string = '';
  errorKind: string = '';
  errorMessage: string = '';
}

export class ClashAvailability {
  available: boolean = false;
  reason: string = '';
}

/** 一个代理/组(字段取自 clash API proxyInfo：type/name/now/all)。 */
export class ClashProxy {
  tag: string = '';
  /** 展示名：Selector / URLTest / Shadowsocks / Fallback …(constant/proxy.go:53-121) */
  type: string = '';
  /** 仅组：当前选中的成员 tag(proxies.go:78-80) */
  now: string = '';
  /** 仅组：全部成员 tag(proxies.go:81-83) */
  all: Array<string> = [];
}

export class ClashProxiesResult {
  ok: boolean = false;
  reason: string = '';
  proxies: Map<string, ClashProxy> = new Map<string, ClashProxy>();
}

export class ClashSelectResult {
  ok: boolean = false;
  reason: string = '';
}

/** 构造鉴权头(与 utils/ClashAuth 单一来源；空密钥不带头)。 */
export function buildRequestHeaders(cfg: ClashApiConfig): Record<string, string> {
  return clashApiHeaders(cfg.secret);
}

function bodyText(value: Object | null): string {
  if (value === null || value === undefined) {
    return '';
  }
  return `${value}`;
}

/** 传输异常 → 归类(普通 @ohos.net.http 错误码：2300028=超时)。 */
function classifyTransportError(message: string): string {
  const lower = message.toLowerCase();
  if (lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0 ||
    lower.indexOf('2300028') >= 0) {
    return CLASH_REASON_TIMEOUT;
  }
  return CLASH_REASON_REFUSED;
}

function statusReason(status: number): string {
  if (status === 401 || status === 403) {
    return CLASH_REASON_UNAUTHORIZED;
  }
  return CLASH_REASON_HTTP_ERROR;
}

function strOf(obj: Record<string, Object>, key: string): string {
  const v = obj[key];
  return typeof v === 'string' ? v : '';
}

function arrayOfStrings(obj: Record<string, Object>, key: string): Array<string> {
  const v = obj[key];
  if (!Array.isArray(v)) {
    return [];
  }
  const out: Array<string> = [];
  const list = v as Array<Object>;
  for (let i = 0; i < list.length; i++) {
    out.push(`${list[i]}`);
  }
  return out;
}

function parseProxy(tag: string, raw: Record<string, Object>): ClashProxy {
  const proxy = new ClashProxy();
  proxy.tag = tag;
  proxy.type = strOf(raw, 'type');
  proxy.now = strOf(raw, 'now');
  proxy.all = arrayOfStrings(raw, 'all');
  return proxy;
}

export class ClashApi {
  private transport: (path: string, method: string, body: string | null,
    cfg: ClashApiConfig) => Promise<ClashHttpResp>;

  constructor(transport?: (path: string, method: string, body: string | null,
    cfg: ClashApiConfig) => Promise<ClashHttpResp>) {
    this.transport = transport !== undefined ? transport : ClashApi.defaultTransport;
  }

  /**
   * 默认传输：@ohos.net.http 请求 127.0.0.1:<port>。
   * 失败不抛异常，统一写进 errorKind/errorMessage(调用方按 reason 展示)。
   */
  static async defaultTransport(path: string, method: string,
    body: string | null, cfg: ClashApiConfig): Promise<ClashHttpResp> {
    const out = new ClashHttpResp();
    const client = http.createHttp();
    try {
      const headers = buildRequestHeaders(cfg);
      if (body !== null) {
        headers['Content-Type'] = 'application/json';
      }
      let httpMethod: http.RequestMethod = http.RequestMethod.GET;
      if (method === 'PUT') {
        httpMethod = http.RequestMethod.PUT;
      } else if (method === 'POST') {
        httpMethod = http.RequestMethod.POST;
      } else if (method === 'DELETE') {
        httpMethod = http.RequestMethod.DELETE;
      }
      const options: http.HttpRequestOptions = {
        method: httpMethod,
        header: headers,
        connectTimeout: cfg.timeoutMs,
        readTimeout: cfg.timeoutMs,
        expectDataType: http.HttpDataType.STRING
      };
      if (body !== null) {
        options.extraData = body;
      }
      const resp = await client.request(`http://127.0.0.1:${cfg.port}${path}`, options);
      out.status = resp.responseCode;
      out.body = bodyText(resp.result);
      return out;
    } catch (e) {
      out.status = 0;
      out.errorKind = classifyTransportError(`${e}`);
      out.errorMessage = `${e}`;
      return out;
    } finally {
      client.destroy();
    }
  }

  /** 传输调用 + 异常归类，所有方法共用。 */
  private async call(cfg: ClashApiConfig, path: string, method: string,
    body: string | null): Promise<ClashHttpResp> {
    let resp: ClashHttpResp;
    try {
      resp = await this.transport(path, method, body, cfg);
    } catch (e) {
      resp = new ClashHttpResp();
      resp.status = 0;
      resp.errorKind = classifyTransportError(`${e}`);
      resp.errorMessage = `${e}`;
    }
    // 归一化：注入的桩可能只给 {status, body}(没有 ClashHttpResp 的其余字段)
    const out = new ClashHttpResp();
    if (resp !== undefined && resp !== null) {
      out.status = typeof resp.status === 'number' ? resp.status : 0;
      out.body = typeof resp.body === 'string' ? resp.body : '';
      out.errorKind = typeof resp.errorKind === 'string' ? resp.errorKind : '';
      out.errorMessage = typeof resp.errorMessage === 'string' ? resp.errorMessage : '';
    }
    if (out.errorKind.length > 0) {
      // 'other' 也归 refused(没连上控制器，和拒绝没有可区分的用户动作)
      out.errorKind = out.errorKind === CLASH_REASON_TIMEOUT
        ? CLASH_REASON_TIMEOUT : CLASH_REASON_REFUSED;
      out.status = 0;
    }
    return out;
  }

  /** 控制器可用性：port<=0 视为未启用(不发起请求)；否则 GET /version。 */
  async checkAvailability(cfg: ClashApiConfig): Promise<ClashAvailability> {
    const out = new ClashAvailability();
    if (cfg.port <= 0) {
      out.reason = CLASH_REASON_DISABLED;
      return out;
    }
    const resp = await this.call(cfg, '/version', 'GET', null);
    if (resp.errorKind.length > 0) {
      out.reason = resp.errorKind;
      return out;
    }
    if (resp.status >= 200 && resp.status < 300) {
      out.available = true;
      out.reason = '';
      return out;
    }
    out.reason = statusReason(resp.status);
    return out;
  }

  /** GET /proxies：全部代理(含合成项 GLOBAL，type=Fallback)。 */
  async getProxies(cfg: ClashApiConfig): Promise<ClashProxiesResult> {
    const out = new ClashProxiesResult();
    const resp = await this.call(cfg, '/proxies', 'GET', null);
    if (resp.errorKind.length > 0) {
      out.reason = resp.errorKind;
      return out;
    }
    if (resp.status < 200 || resp.status >= 300) {
      out.reason = statusReason(resp.status);
      return out;
    }
    try {
      const root = JSON.parse(resp.body) as Record<string, Object>;
      const rawProxies = root['proxies'];
      if (rawProxies === undefined || rawProxies === null || typeof rawProxies !== 'object') {
        out.reason = CLASH_REASON_PARSE_ERROR;
        return out;
      }
      const proxyMap = rawProxies as Record<string, Object>;
      const tags = Object.keys(proxyMap);
      for (let i = 0; i < tags.length; i++) {
        const tag = tags[i];
        const value = proxyMap[tag];
        if (value === null || typeof value !== 'object') {
          continue;
        }
        out.proxies.set(tag, parseProxy(tag, value as Record<string, Object>));
      }
      out.ok = true;
      return out;
    } catch (e) {
      out.reason = CLASH_REASON_PARSE_ERROR;
      return out;
    }
  }

  /** GET /proxies/<tag>：单个代理(内核直接返回对象，不包 proxies 层，proxies.go:154-163)。 */
  async getProxy(cfg: ClashApiConfig, tag: string): Promise<ClashProxiesResult> {
    const out = new ClashProxiesResult();
    const resp = await this.call(cfg, `/proxies/${encodeURIComponent(tag)}`, 'GET', null);
    if (resp.errorKind.length > 0) {
      out.reason = resp.errorKind;
      return out;
    }
    if (resp.status === 404) {
      out.reason = CLASH_REASON_NOT_FOUND;
      return out;
    }
    if (resp.status < 200 || resp.status >= 300) {
      out.reason = statusReason(resp.status);
      return out;
    }
    try {
      const raw = JSON.parse(resp.body) as Record<string, Object>;
      const name = strOf(raw, 'name');
      out.proxies.set(name.length > 0 ? name : tag, parseProxy(name.length > 0 ? name : tag, raw));
      out.ok = true;
      return out;
    } catch (e) {
      out.reason = CLASH_REASON_PARSE_ERROR;
      return out;
    }
  }

  /**
   * PUT /proxies/<groupTag> body {"name": memberTag}（proxies.go:34-40/166-189）。
   * 成功只表示内核接受了切换；**必须**再 getProxy 核对 now(§9.2-3)，
   * 本方法不写任何"正在使用"状态。
   */
  async selectProxy(cfg: ClashApiConfig, groupTag: string,
    memberTag: string): Promise<ClashSelectResult> {
    const out = new ClashSelectResult();
    const body = JSON.stringify({ 'name': memberTag } as Record<string, Object>);
    const resp = await this.call(cfg, `/proxies/${encodeURIComponent(groupTag)}`, 'PUT', body);
    if (resp.errorKind.length > 0) {
      out.reason = resp.errorKind;
      return out;
    }
    if (resp.status === 204 || (resp.status >= 200 && resp.status < 300)) {
      out.ok = true;
      out.reason = '';
      return out;
    }
    if (resp.status === 400) {
      out.reason = CLASH_REASON_REJECTED; // 非 selector / 成员不在组内(proxies.go:171-183)
      return out;
    }
    out.reason = statusReason(resp.status);
    return out;
  }
}
