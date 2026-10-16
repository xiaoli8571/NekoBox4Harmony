/**
 * 首页分组折叠与订阅视图的纯逻辑(便于单元测试;UI 层 Index.ets 只做绑定)。
 * - 折叠状态自 2.1.5 起以 JSON 数组持久化(键 home_collapsed_groups),
 *   旧版 '|' 分隔格式仍可解析;空串条目是「未分组」分组的合法 id,必须保留。
 * - 首页底部订阅选择器(键 home_selected_sub):'' 表示手动节点视图。
 */

/** 解析折叠状态:JSON 数组优先,兼容旧版 '|' 分隔;空串→空列表 */
export function parseCollapsedIds(raw: string): Array<string> {
  if (raw.length === 0) {
    return [];
  }
  if (raw.startsWith('[')) {
    try {
      const parsed = JSON.parse(raw) as Array<object>;
      if (Array.isArray(parsed)) {
        const ids: Array<string> = [];
        for (const item of parsed) {
          if (typeof item === 'string') {
            ids.push(item);
          }
        }
        return ids;
      }
    } catch (e) {
      // 非 JSON,按旧格式处理
    }
  }
  return raw.split('|');
}

/** 序列化折叠状态(JSON 数组;保留空串=未分组条目) */
export function serializeCollapsedIds(ids: Array<string>): string {
  return JSON.stringify(ids);
}

/** 折叠/展开一个分组(返回新数组,不修改入参) */
export function toggleCollapsed(ids: Array<string>, groupId: string): Array<string> {
  const next = ids.slice();
  const i = next.indexOf(groupId);
  if (i >= 0) {
    next.splice(i, 1);
  } else {
    next.push(groupId);
  }
  return next;
}

/**
 * 解析首页底部选中的订阅:
 * 持久化值仍有效→用之;否则激活订阅(运行中)→用之;否则第一个订阅;无订阅→手动视图('')
 */
export function resolveSelectedSub(savedSub: string, activeSubUrl: string, subUrls: Array<string>): string {
  if (savedSub.length > 0 && subUrls.indexOf(savedSub) >= 0) {
    return savedSub;
  }
  if (activeSubUrl.length > 0 && subUrls.indexOf(activeSubUrl) >= 0) {
    return activeSubUrl;
  }
  if (subUrls.length > 0) {
    return subUrls[0];
  }
  return '';
}

/** 节点是否属于当前首页视图:''=手动视图只显示非订阅节点 */
export function inSubView(subUrl: string, selectedSubUrl: string): boolean {
  return subUrl === selectedSubUrl;
}
