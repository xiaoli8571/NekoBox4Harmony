/**
 * 内核 clash API 鉴权头。
 *
 * 背景: ConfigBuilder 会把 AppSettings.clashApiSecret 写进 experimental.clash_api.secret,
 * 而 Store.loadSettings 在密钥为空时会自动生成一个随机密钥并落盘 —— 也就是说
 * 内核控制器实际上一直在要求 `Authorization: Bearer <secret>`,并不存在"没设密钥"的装机。
 *
 * 任何直连 127.0.0.1:<clashApiPort> 的调用都必须带上它,否则内核直接回 401
 * (sing-box clashapi 的 auth 中间件对 Bearer 不匹配/缺失一律 401 Unauthorized)。
 * 2026-10-14 用户反馈的「URL Test 失败: HTTP 401」就是 URL Test 那条路径漏带导致的:
 * /proxies/proxy/delay 是唯一一处手搓请求却没构造 header 的地方。
 *
 * 统一在这里构造,新增调用方不必再重复这段逻辑,也就不会再漏。
 */

/** Bearer 鉴权头;密钥为空(测试/极端旧数据)时返回空头,不发送 Authorization。 */
export function clashApiHeaders(secret: string): Record<string, string> {
  const headers: Record<string, string> = {};
  if (secret.length > 0) {
    headers['Authorization'] = `Bearer ${secret}`;
  }
  return headers;
}

/**
 * clash API 非 2xx 时的用户可见错误文案。
 * 401/403 基本只有两种成因:密钥不匹配(设置里被改过/端口上坐的是别的应用),
 * 或 19290 端口被其他 Clash 系应用的控制器占用,所以直接把排查方向写进提示。
 */
export function clashApiErrorMessage(status: number, what: string): string {
  if (status === 401 || status === 403) {
    return `${what}: HTTP ${status}(内核 API 鉴权失败:请在设置中重置 Clash API 密钥,`
      + `或改一个未被其他 Clash 系应用占用的端口)`;
  }
  return `${what}: HTTP ${status}`;
}
