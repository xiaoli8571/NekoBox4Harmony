import {
  effectivePackages,
  invalidBundleNames,
  isValidBundleName,
  normalizeBundleName,
  parseEntries,
  PerAppEntry
} from './PerApp';

/**
 * 分应用策略校验(W07,REDESIGN-PLAN §8.2/§8.4 / REQ-13)。
 *
 * 单一**纯函数**:`evaluatePerAppPolicy` 只做数据变换,不碰任何 HarmonyOS API / I/O,
 * 便于主机测试(tests/per-app-policy.cjs)转译后直接断言。§8.2 明确要求
 * 「UI 校验和扩展启动前校验各做一次,Want 与磁盘读取分支必须执行同一纯策略函数」——
 * VpnService.connect()(UI 进程)与 VpnExtAbility.startVpn()(:vpn 进程)都调用它,
 * 两侧结论一致,不能依赖按钮禁用作为唯一保障。
 *
 * 规则(§8.2/§8.4):
 *   - off + 任意列表 → 允许(系统不附加应用名单,§8.2 第 1 条,含超限列表);
 *   - exclude + 空列表 → 允许(界面另有文案「当前没有排除应用」);
 *   - include + 空名单 → blocked(blockReason=include_empty):草稿可保留,
 *     连接/应用被阻止,提示至少选择一个有效应用。生效名单为空的 include
 *     (含"勾选项全是非法包名")同判空名单,非法项在 dropped 里可见;
 *   - exclude/include 的有效包名数超过上限 → blocked(blockReason=over_limit),
 *     不静默截断后宣称全部勾选生效;off 不附加名单,无截断风险,仍允许;
 *   - 上限按系统 API 版本:API < 23 → 64,API >= 23 → 256(§8.4);
 *   - 非法/重复包名进 dropped 并被过滤,不因此扩大范围,也不单独拦截。
 *
 * blockReason 是机器 token(而不是文案),便于测试断言与上层 i18n 映射。
 */

export interface PerAppPolicyResult {
  /** 归一后的模式:off / exclude / include(非法值按 off) */
  mode: string;
  /** 实际下发给 VpnConfig 的名单;blocked 时为空数组(调用方不得再使用旧值) */
  effectivePackages: Array<string>;
  /** 有效包名数量(勾选 + 合法 + 去重,未截断):超限提示"定位数量"用 */
  count: number;
  /** 按 apiLevel 决定的有效上限 */
  limit: number;
  blocked: boolean;
  /** 机器 token: '' / 'include_empty' / 'over_limit' */
  blockReason: string;
  /** 被过滤掉的非法/重复包名(仅诊断,不改变结论) */
  dropped: Array<string>;
}

/** VpnConfig 应用名单上限:API 23 以前 64,API 23 起 256(§8.4)。 */
export function perAppListLimit(apiLevel: number): number {
  return apiLevel >= 23 ? 256 : 64;
}

/**
 * 阻断原因 → 面向用户的失败文案(UI 与扩展两侧共用,保证提示一致)。
 * 沿用现有 vpnStatus 失败文案的中文约定;blockReason 仍保留机器 token 供测试与 i18n。
 */
export function perAppBlockMessage(result: PerAppPolicyResult): string {
  if (result.blockReason === 'include_empty') {
    return '分应用代理:仅以下应用走 VPN 需要至少选择一个有效应用';
  }
  if (result.blockReason === 'over_limit') {
    return `分应用代理:应用名单 ${result.count} 个,超过当前上限 ${result.limit} 个,请缩减后重试`;
  }
  return `分应用代理:策略校验未通过(${result.blockReason})`;
}

function normalizeMode(mode: string): string {
  const modes: Array<string> = ['off', 'exclude', 'include'];
  return modes.indexOf(mode) >= 0 ? mode : 'off';
}

/**
 * 未截断的有效包名清单。语义与 model/PerApp.effectivePackages 一致(勾选 + 合法 +
 * 去重 + 保序),但**不按 PER_APP_MAX_ENTRIES(256)截断** —— 截断会把"超限"伪装成
 * "刚好 256",§8.4 要求超限必须可见、可定位数量,所以计数在这里先做完整版;
 * 名单本身在未超限时与 effectivePackages 逐元素相等(见 evaluatePerAppPolicy)。
 */
function validPackagesUntruncated(entries: Array<PerAppEntry>): Array<string> {
  const result: Array<string> = [];
  const seen = new Set<string>();
  for (const entry of entries) {
    if (!entry.enabled) {
      continue;
    }
    const bundleName = normalizeBundleName(entry.bundleName);
    if (!isValidBundleName(bundleName) || seen.has(bundleName)) {
      continue;
    }
    seen.add(bundleName);
    result.push(bundleName);
  }
  return result;
}

/**
 * 被过滤掉的包名:非法包名 + 原始 JSON 里的重复项。
 * parseEntries 对重复包名"后到先丢"且不回报,这里单独扫一遍原始 JSON,
 * 把重复出现的包名补进 dropped(供界面"格式错误数量"/日志,不改变结论)。
 */
function droppedBundleNames(entries: Array<PerAppEntry>, rawJson: string): Array<string> {
  const result: Array<string> = invalidBundleNames(entries);
  const seen: Array<string> = [];
  for (const name of result) {
    seen.push(name);
  }
  if (rawJson === undefined || rawJson === null || rawJson.trim().length === 0) {
    return result;
  }
  let parsed: Array<Record<string, Object>>;
  try {
    parsed = JSON.parse(rawJson) as Array<Record<string, Object>>;
  } catch (e) {
    return result;
  }
  if (!Array.isArray(parsed)) {
    return result;
  }
  const once: Array<string> = [];
  for (const item of parsed) {
    if (item === undefined || item === null) {
      continue;
    }
    const rawName: Object = item['bundleName'];
    if (typeof rawName !== 'string') {
      continue;
    }
    const name = normalizeBundleName(rawName as string);
    if (name.length === 0) {
      continue;
    }
    if (once.indexOf(name) >= 0) {
      // 重复出现:补进 dropped(parseEntries 已把后续出现静默丢弃)
      if (seen.indexOf(name) < 0) {
        seen.push(name);
        result.push(name);
      }
    } else {
      once.push(name);
    }
  }
  return result;
}

/**
 * 唯一的策略评估入口:UI 与扩展两侧都必须调用本函数(§8.2)。
 *
 * @param mode        per-app 模式(off/exclude/include;非法值按 off 处理)
 * @param entriesJson perAppEntries 的持久化 JSON。Want 分支只有 CSV,调用点需先
 *                    `serializeEntries(entriesFromLegacyList(csv))` 转成同一格式,
 *                    保证 Want / 读盘两条分支执行完全相同的判定。
 * @param apiLevel    系统 API 版本(sdkApiVersion;取不到时按 23 处理并在调用点写日志)
 */
export function evaluatePerAppPolicy(mode: string, entriesJson: string,
  apiLevel: number): PerAppPolicyResult {
  const effectiveMode: string = normalizeMode(mode);
  const limit: number = perAppListLimit(apiLevel);
  const entries: Array<PerAppEntry> = parseEntries(entriesJson);
  const candidates: Array<string> = validPackagesUntruncated(entries);
  const dropped: Array<string> = droppedBundleNames(entries, entriesJson);
  const count: number = candidates.length;
  let blocked: boolean = false;
  let blockReason: string = '';
  if (effectiveMode === 'include') {
    if (count === 0) {
      // §8.2:include + 空名单阻止连接/应用,绝不静默降级成"全部应用进 VPN"
      blocked = true;
      blockReason = 'include_empty';
    } else if (count > limit) {
      // §8.4:超限阻止应用并定位数量,不静默截断后宣称全部勾选生效
      blocked = true;
      blockReason = 'over_limit';
    }
  } else if (effectiveMode !== 'off' && count > limit) {
    // exclude 同样受 VpnConfig 容量约束:超限必须显式阻止,而不是截断后照常连接
    blocked = true;
    blockReason = 'over_limit';
  }
  // blocked 时返回空名单:调用方拿到 blocked=true 就不会建 TUN,空数组同时保证
  // 即使调用点漏判也不会把超限/无效名单下发给系统。未 blocked 的 exclude/include
  // 名单与 model/PerApp.effectivePackages 逐元素相等(数量未超限时截断不触发)。
  const list: Array<string> = blocked ? [] : effectivePackages(entries);
  return {
    mode: effectiveMode,
    effectivePackages: list,
    count: count,
    limit: limit,
    blocked: blocked,
    blockReason: blockReason,
    dropped: dropped
  };
}
