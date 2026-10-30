/**
 * 订阅节点名过滤(对齐 OwnBox `SubscriptionFilterMode` + `filterRegex`,RawUpdater.kt:199-212)。
 *
 * 语义逐字对齐:
 *   - off      : 不过滤;
 *   - include  : 只保留 **名称匹配** 的节点;
 *   - exclude  : 排除 **名称匹配** 的节点;
 *   - 匹配用 `RegExp(pattern, 'i')`(忽略大小写),非法正则 → 视为未启用(不静默清空节点)。
 *
 * 纯模型:只接收名称数组、返回下标,便于 tests/node-filter.cjs 直接断言,
 * 不依赖 Profile 类型,避免模型层循环引用。
 */

export const FILTER_OFF: string = 'off';
export const FILTER_INCLUDE: string = 'include';
export const FILTER_EXCLUDE: string = 'exclude';

export function normalizeFilterMode(mode: string): string {
  if (mode === FILTER_INCLUDE || mode === FILTER_EXCLUDE) {
    return mode;
  }
  return FILTER_OFF;
}

/** 编译过滤表达式;空白/非法正则返回 null(调用方据此判定「过滤未启用」)。 */
export function buildFilterRegex(pattern: string): RegExp | null {
  const trimmed: string = pattern === undefined || pattern === null ? '' : pattern.trim();
  if (trimmed.length === 0) {
    return null;
  }
  try {
    return new RegExp(trimmed, 'i');
  } catch (e) {
    return null;
  }
}

/** 是否真的会过滤(模式非 off 且表达式合法)。 */
export function filterIsActive(mode: string, pattern: string): boolean {
  return normalizeFilterMode(mode) !== FILTER_OFF && buildFilterRegex(pattern) !== null;
}

/**
 * 返回应保留的节点下标(升序)。
 * 过滤未启用时返回全部下标 —— 调用方可以无脑按返回值重建数组。
 */
export function filterNameIndexes(names: Array<string>, mode: string, pattern: string): Array<number> {
  const result: Array<number> = [];
  const normalized: string = normalizeFilterMode(mode);
  const regex: RegExp | null = buildFilterRegex(pattern);
  const active: boolean = normalized !== FILTER_OFF && regex !== null;
  for (let i = 0; i < names.length; i++) {
    if (!active) {
      result.push(i);
      continue;
    }
    const hit: boolean = regex !== null && regex.test(names[i]);
    if ((normalized === FILTER_INCLUDE && hit) || (normalized === FILTER_EXCLUDE && !hit)) {
      result.push(i);
    }
  }
  return result;
}
