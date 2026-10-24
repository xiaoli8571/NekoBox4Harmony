import BusinessError from '@ohos.base';

/**
 * 把 JS 抛出的任意值转成可读文本。
 *
 * 为什么需要:ArkTS 里 `try/catch` 捕获到的业务错误往往是**普通对象**(`BusinessError` 是
 * `{code, message}` 结构,并不是 `Error` 实例),所以 `e instanceof Error ? e.message : `${e}``
 * 这类写法会掉进 `${e}` 分支,真机日志里表现为 `启动失败: [object Object]`
 * (2026-10-23 真机走查 P2 实测)。统一走这里,日志才可直接定位。
 */
export function errText(e: Object): string {
  if (e === null || e === undefined) {
    return '(空异常)';
  }
  const be = e as BusinessError;
  const code: number = typeof be.code === 'number' ? be.code : -1;
  const message: string = typeof be.message === 'string' ? be.message : '';
  if (code >= 0 && message.length > 0) {
    return `code=${code} msg=${message}`;
  }
  if (message.length > 0) {
    return message;
  }
  const asString: string = `${e}`;
  if (asString !== '[object Object]') {
    return asString;
  }
  try {
    return JSON.stringify(e);
  } catch (inner) {
    return '[object Object](不可序列化)';
  }
}
