/**
 * 已准备好的规则集资源 —— ResourceResolver 的产出、ConfigBuilder 的输入。
 *
 * 为什么单独一个文件(纯数据、零 import):
 *  - ConfigBuilder 必须保持「只消费已准备资源、不联网、不落盘」(方案第三阶段);
 *  - ResourceResolver 依赖 fs/http/RuleSetRepository,若 ConfigBuilder 直接 import 它,
 *    配置生成器就会被拖进网络与文件系统副作用;
 *  - 于是两边共享这份纯数据契约。
 */

/** sing-box rule_set 的 format 取值(option/rule_set.go:'' 或 'source' 都是 JSON,只需区分 binary)。 */
export const RULESET_FORMAT_BINARY: string = 'binary';
export const RULESET_FORMAT_SOURCE: string = 'source';

/**
 * 单个规则集的启动准备结论。
 * 只有 available=true 且 path 非空的条目才允许进入配置生成(方案的「不允许进入配置生成」)。
 */
export class PreparedRuleSet {
  /** 内核 route.rule_set 引用的 tag(`remote_<资源ID>`),与旧配置引用保持同名。 */
  tag: string = '';
  /** 去敏后的仓库资源 ID(sanitizeResourceId 结果)。 */
  resourceId: string = '';
  /** 本地缓存文件绝对路径;available=false 时为空串。 */
  path: string = '';
  /** sing-box rule_set.format:'binary' | 'source'。 */
  format: string = RULESET_FORMAT_BINARY;
  /** 能否交给配置生成(策略感知:未验证且策略=block 时为 false)。 */
  available: boolean = false;
  /** 是否经内核 K1 完整校验(唯一可标「已验证」的依据)。 */
  verified: boolean = false;
  /** true = 本次启动直接命中缓存,未发生下载。 */
  fromCache: boolean = false;
  /** 'ready' | 'unverified' | 'unavailable' */
  state: string = 'unavailable';
  /** 可用性原因(cache-hit / no-cache / update-failed-using-cache …)。 */
  reason: string = '';
  /** 原始错误文本(下载/校验失败原因)。 */
  error: string = '';
  /** 引用该规则集的路由出站:direct | proxy。 */
  outbound: string = 'direct';
  /** 生效的失败策略:'block' | 'allow-unverified'。 */
  failurePolicy: string = 'block';
  /** 当前版本下载成功时间(0 = 无)。 */
  cachedAt: number = 0;
  /** 本次准备是否发起过下载(日志/诊断用)。 */
  downloaded: boolean = false;
}

/** 一次启动的资源准备结果(规则集 + geo 资产)。 */
export class PreparedResources {
  /** 与输入 RemoteRuleSet 数组**等长同序**(ConfigBuilder 按 available 过滤,便于日志对齐)。 */
  ruleSets: Array<PreparedRuleSet> = [];
  geositePath: string = '';
  geoIpPath: string = '';
  geoEnabled: boolean = false;
  availableCount: number = 0;
  unavailableCount: number = 0;
  downloadedCount: number = 0;
  /** 非致命降级说明(geo 缺失、下载预算耗尽等),写启动日志用。 */
  warning: string = '';
}
