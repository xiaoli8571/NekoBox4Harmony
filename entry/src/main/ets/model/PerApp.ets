/**
 * 分应用代理条目模型(应用名 + 包名 + 勾选)。
 *
 * 背景(2026-10-19 用户报障):原实现只有一个逗号分隔的包名输入框,
 * 用户填了包名却"没有完成分流"。根因不在解析,而在两道链路:
 *   1) 条目里没有应用名,无法区分是哪个应用,容易填错包名。
 *   2) :vpn 扩展进程读的是自己进程内缓存的 Preferences 快照,UI 改完名单后
 *      扩展拿到的还是旧名单(详见 VpnExtAbility 的 Want 参数与 refreshStore)。
 *
 * 本文件只做**纯函数**数据变换,不依赖任何 HarmonyOS API,便于 tests/*.cjs 直接
 * 转译后断言。持久化字段约定:
 *   - `perAppEntries`: JSON 数组,每项 {bundleName, label, enabled};本文件是唯一权威。
 *   - `perAppList`: 逗号分隔的**生效**包名,由 Store.saveSettings 从 entries 派生,
 *     保持对内核/VpnConfig/备份的旧契约不变(旧数据可读)。
 */

export class PerAppEntry {
  bundleName: string = '';
  label: string = '';        // 应用名(仅界面显示,不参与系统路由)
  enabled: boolean = true;   // 勾选状态:未勾选只保留条目,不写入 VpnConfig

  constructor(bundleName: string, label: string, enabled: boolean) {
    this.bundleName = bundleName;
    this.label = label;
    this.enabled = enabled;
  }
}

/** VpnConfig 的应用名单上限:API 23 前 64,API 23 起 256。这里按 256 兜底,超限截断并如实写日志。 */
export const PER_APP_MAX_ENTRIES: number = 256;

/** 鸿蒙包名校验:字母开头,点分段,允许字母/数字/下划线。Android 包名常带 '-' 或不含点,会被拒。 */
const BUNDLE_NAME_PATTERN = new RegExp('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$');

export function isValidBundleName(name: string): boolean {
  const trimmed = name.trim();
  if (trimmed.length < 3 || trimmed.length > 127) {
    return false;
  }
  return BUNDLE_NAME_PATTERN.test(trimmed);
}

/** 去掉首尾空白与零宽字符(从聊天/网页复制包名时常带)。 */
export function normalizeBundleName(raw: string): string {
  return raw.replace(/[\u200b-\u200d\ufeff]/g, '').trim();
}

/** 应用名备注:压掉换行与多余空白,空则回退包名(界面不出现空标题行)。 */
export function normalizeLabel(raw: string, bundleName: string): string {
  const cleaned = raw.replace(/\s+/g, ' ').trim();
  return cleaned.length > 0 ? cleaned : bundleName;
}

/** 宽松解析持久化 JSON:任何脏数据都不抛异常,只丢弃非法项。 */
export function parseEntries(json: string): Array<PerAppEntry> {
  if (json === undefined || json === null || json.trim().length === 0) {
    return [];
  }
  let parsed: Array<Record<string, Object>>;
  try {
    parsed = JSON.parse(json) as Array<Record<string, Object>>;
  } catch (e) {
    return [];
  }
  if (!Array.isArray(parsed)) {
    return [];
  }
  const result: Array<PerAppEntry> = [];
  const seen = new Set<string>();
  for (const item of parsed) {
    if (item === undefined || item === null) {
      continue;
    }
    const rawName: Object = item['bundleName'];
    if (typeof rawName !== 'string') {
      continue;
    }
    const bundleName = normalizeBundleName(rawName as string);
    if (bundleName.length === 0 || seen.has(bundleName)) {
      continue;
    }
    seen.add(bundleName);
    const rawLabel: Object = item['label'];
    const label = typeof rawLabel === 'string' ? (rawLabel as string) : '';
    const rawEnabled: Object = item['enabled'];
    const enabled = typeof rawEnabled === 'boolean' ? (rawEnabled as boolean) : true;
    result.push(new PerAppEntry(bundleName, normalizeLabel(label, bundleName), enabled));
  }
  return result;
}

/**
 * 序列化。注意空列表要序列化成 `'[]'` 而不是空串 —— 空串在持久化字段里代表
 * "从未初始化"(首次载入会重新灌入预置应用),`'[]'` 才代表"用户确实清空了名单"。
 */
export function serializeEntries(list: Array<PerAppEntry>): string {
  return JSON.stringify(list);
}

/** 老数据迁移:逗号/换行/空格混合分隔的包名 → 条目(默认勾选,名称先用包名占位)。 */
export function entriesFromLegacyList(csv: string): Array<PerAppEntry> {
  const result: Array<PerAppEntry> = [];
  if (csv === undefined || csv === null || csv.trim().length === 0) {
    return result;
  }
  const parts = csv.split(/[\s,;]+/);
  const seen = new Set<string>();
  for (const part of parts) {
    const bundleName = normalizeBundleName(part);
    if (bundleName.length === 0 || seen.has(bundleName)) {
      continue;
    }
    seen.add(bundleName);
    result.push(new PerAppEntry(bundleName, bundleName, true));
  }
  return result;
}

/** 合并:按包名去重;已存在只补名称/更新勾选,不产生重复行。 */
export function mergeEntries(base: Array<PerAppEntry>, incoming: Array<PerAppEntry>): Array<PerAppEntry> {
  const result: Array<PerAppEntry> = [];
  for (const entry of base) {
    result.push(new PerAppEntry(entry.bundleName, entry.label, entry.enabled));
  }
  for (const entry of incoming) {
    let found = false;
    for (let i = 0; i < result.length; i++) {
      if (result[i].bundleName === entry.bundleName) {
        const label = entry.label.length > 0 && entry.label !== entry.bundleName
          ? entry.label : result[i].label;
        result[i] = new PerAppEntry(entry.bundleName, label, entry.enabled || result[i].enabled);
        found = true;
        break;
      }
    }
    if (!found) {
      result.push(new PerAppEntry(entry.bundleName, entry.label, entry.enabled));
    }
  }
  return result;
}

export function removeEntry(list: Array<PerAppEntry>, bundleName: string): Array<PerAppEntry> {
  const result: Array<PerAppEntry> = [];
  for (const entry of list) {
    if (entry.bundleName !== bundleName) {
      result.push(new PerAppEntry(entry.bundleName, entry.label, entry.enabled));
    }
  }
  return result;
}

export function toggleEntry(list: Array<PerAppEntry>, bundleName: string, enabled: boolean): Array<PerAppEntry> {
  const result: Array<PerAppEntry> = [];
  for (const entry of list) {
    if (entry.bundleName === bundleName) {
      result.push(new PerAppEntry(entry.bundleName, entry.label, enabled));
    } else {
      result.push(new PerAppEntry(entry.bundleName, entry.label, entry.enabled));
    }
  }
  return result;
}

/**
 * 传给 VpnConfig 的生效名单:仅勾选项、仅合法包名、去重、保序、按上限截断。
 * 非法包名会让系统把整份名单当无效配置处理,所以这里必须前置过滤。
 */
export function effectivePackages(list: Array<PerAppEntry>): Array<string> {
  const result: Array<string> = [];
  const seen = new Set<string>();
  for (const entry of list) {
    if (!entry.enabled) {
      continue;
    }
    const bundleName = normalizeBundleName(entry.bundleName);
    if (!isValidBundleName(bundleName) || seen.has(bundleName)) {
      continue;
    }
    seen.add(bundleName);
    result.push(bundleName);
    if (result.length >= PER_APP_MAX_ENTRIES) {
      break;
    }
  }
  return result;
}

/** 直接过滤一份逗号分隔名单(扩张进程用:Want/设置里拿到的都已勾选,只需校验合法性)。 */
export function effectivePackagesFromCsv(csv: string): Array<string> {
  return effectivePackages(entriesFromLegacyList(csv));
}

/** 条目里被丢弃的非法包名(用于界面提示与日志,不静默吞掉)。 */export function invalidBundleNames(list: Array<PerAppEntry>): Array<string> {
  const result: Array<string> = [];
  const seen = new Set<string>();
  for (const entry of list) {
    const bundleName = normalizeBundleName(entry.bundleName);
    if (bundleName.length > 0 && !isValidBundleName(bundleName) && !seen.has(bundleName)) {
      seen.add(bundleName);
      result.push(bundleName);
    }
  }
  return result;
}

/**
 * 对话框输入 → 条目。整段文本按行/逗号/分号/空白拆分;名称备注只用于单个包名
 * (与用户提供的参考设计一致:批量导入时逐行一个包名,备注无意义)。
 */
export function entriesFromInput(text: string, label: string): Array<PerAppEntry> {
  const result: Array<PerAppEntry> = [];
  if (text === undefined || text === null || text.trim().length === 0) {
    return result;
  }
  const parts = text.split(/[\s,;]+/);
  const seen = new Set<string>();
  const cleaned: Array<string> = [];
  for (const part of parts) {
    const bundleName = normalizeBundleName(part);
    if (bundleName.length > 0 && !seen.has(bundleName)) {
      seen.add(bundleName);
      cleaned.push(bundleName);
    }
  }
  const single = cleaned.length === 1;
  for (const bundleName of cleaned) {
    result.push(new PerAppEntry(bundleName, single ? normalizeLabel(label, bundleName) : bundleName, true));
  }
  return result;
}

/** 剪贴板导入(安卓口径 `false\n<包名列表>`):合并进现有条目,不清空用户已有名单。 */
export function entriesFromClipboardPayload(text: string): Array<PerAppEntry> {
  const nl = text.indexOf('\n');
  if (text.trim().length === 0 || nl < 0) {
    return [];
  }
  return entriesFromInput(text.substring(nl + 1), '');
}

/** 预置常用鸿蒙应用(用户 2026-10-14 提供;名称仅用于界面显示,可删除)。 */
class PresetApp {
  bundleName: string = '';
  label: string = '';

  constructor(bundleName: string, label: string) {
    this.bundleName = bundleName;
    this.label = label;
  }
}

const PRESET_APPS: Array<PresetApp> = [
  new PresetApp('com.tencent.wechat', '微信'),
  new PresetApp('com.ss.hm.ugc.aweme', '抖音'),
  new PresetApp('com.alipay.mobile.client', '支付宝'),
  new PresetApp('com.amap.hmapp', '高德地图'),
  new PresetApp('com.cmbchina.harmony', '招商银行'),
  new PresetApp('com.taobao.taobao4hmos', '淘宝'),
  new PresetApp('com.taobao.idlefish4ohos', '闲鱼'),
  new PresetApp('com.sina.weibo.stage', '微博'),
  new PresetApp('app.huawei.hmos.motor', '鸿蒙智行'),
  new PresetApp('com.sankuai.hmeituan', '美团'),
  new PresetApp('com.jd.hm.mall', '京东'),
  new PresetApp('com.sdu.didi.hmos.psnger', '滴滴出行'),
];

export function presetEntries(): Array<PerAppEntry> {
  const result: Array<PerAppEntry> = [];
  for (const preset of PRESET_APPS) {
    result.push(new PerAppEntry(preset.bundleName, preset.label, false));
  }
  return result;
}

/** 是否预置应用(仅用于界面上的来源标签,不影响路由)。 */
export function isPresetBundleName(bundleName: string): boolean {
  for (const preset of PRESET_APPS) {
    if (preset.bundleName === bundleName) {
      return true;
    }
  }
  return false;
}

/**
 * 首次升级/首次进入时的初始名单:预置项(默认不勾选) + 旧 CSV 迁移项(勾选)。
 * 兼容"老版本填了包名但没勾选概念"的装机:老包名必须保持生效,不能静默失效。
 */
export function initialEntries(legacyCsv: string): Array<PerAppEntry> {
  return mergeEntries(presetEntries(), entriesFromLegacyList(legacyCsv));
}

/** 名称映射:给批量导入/剪贴板导入的包名补上界面可读名称(找不到就显示包名)。 */
export function labelForBundle(list: Array<PerAppEntry>, bundleName: string): string {
  for (const entry of list) {
    if (entry.bundleName === bundleName && entry.label.length > 0) {
      return entry.label;
    }
  }
  return bundleName;
}
