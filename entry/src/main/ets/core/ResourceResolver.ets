import common from '@ohos.app.ability.common';
import { RemoteRuleSet } from '../model/RouteRule';
import { LogStore } from '../model/Store';
import { errText } from '../utils/ErrText';
import { geoReady, geoSitePath as geoSiteFile, geoIpPath as geoIpFile } from '../utils/GeoAssets';
import {
  RuleSetRepository, ResourceAvailability, HttpResourceFetcher, sanitizeResourceId,
  FAILURE_POLICY_BLOCK, isValidFailurePolicy, STATE_READY, STATE_UNAVAILABLE, STATE_UNVERIFIED
} from './RuleSetRepository';
import { ResourceValidator, FORMAT_BINARY_SRS, FORMAT_SOURCE_JSON } from './ResourceValidator';
import {
  PreparedRuleSet, PreparedResources, RULESET_FORMAT_BINARY, RULESET_FORMAT_SOURCE
} from './PreparedResource';

/**
 * ResourceResolver —— 统一资源生命周期(方案 docs/REMOTE_RULESET_ARCHITECTURE_REFACTOR_PLAN.md)。
 *
 * 目标架构:
 *
 *   GeoSite / GeoIP / RemoteRuleSet
 *        ↓
 *   ResourceResolver(下载策略 + 失败降级,启动阶段唯一允许联网的地方)
 *        ↓
 *   RuleSetRepository(本地缓存/校验/版本)
 *        ↓
 *   local 文件 → ConfigBuilder(type:'local') → sing-box
 *
 * 铁律:
 *  1. 启动阶段**只使用本地文件**;网络只用于"补缓存",且永远有界(单资源超时 + 总预算),
 *     失败一律降级为「本次不带该规则集」,绝不阻断 VPN 启动;
 *  2. 生成给内核的配置里**不允许**出现 `type:'remote'`(内核启动不再联网拉规则集);
 *  3. 有缓存就用缓存(更新失败也继续用旧缓存),无缓存且策略=block 则该规则集本次不进入配置。
 */

/** 规则集在 route.rule_set 里的 tag 前缀(与改造前 `remote_<id>` 保持同名,路由引用不需迁移)。 */
export const RULESET_TAG_PREFIX: string = 'remote_';

/** 启动阶段:单个资源下载上限。超时即放弃本次下载(有缓存用缓存,没缓存标记不可用)。 */
export const SINGLE_DOWNLOAD_TIMEOUT_MS: number = 12000;
/** 启动阶段:所有缺失资源共享的下载总预算。耗尽后立即停止补缓存,照常启动。 */
export const STARTUP_DOWNLOAD_BUDGET_MS: number = 20000;
/** 后台刷新:缓存超过该时长才重新下载(24h);失败保留旧缓存、不影响当前会话。 */
export const BACKGROUND_REFRESH_AGE_MS: number = 24 * 60 * 60 * 1000;

export class PrepareOptions {
  /** 是否允许调用方显式联网补缓存；启动链必须保持 false。 */
  allowDownload: boolean = false;
  /** 是否准备 geo 资产(规则模式)。 */
  withGeo: boolean = false;
  /** 下载总预算(毫秒),0 = 不下载；启动链必须保持 0。 */
  budgetMs: number = 0;
}

function withTimeout<T>(promise: Promise<T>, ms: number, what: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${what} 超时(${Math.round(ms / 1000)}s)`));
    }, ms);
    promise.then((v: T) => {
      clearTimeout(timer);
      resolve(v);
    }, (e: Object) => {
      clearTimeout(timer);
      reject(e as Error);
    });
  });
}

export class ResourceResolver {

  /**
   * 让本进程的 RuleSetRepository 就绪。
   * :vpn 扩展是**独立进程**(独立 JS VM,静态字段不共享),所以扩展里必须自己 init 一次;
   * 磁盘目录(应用私有 filesDir/config/resources)两个进程共用。
   * validatorBridge 传 CoreManager.validateSrs 才能在扩展里拿到「已验证」资格,
   * 否则扩展侧下载的资源永远是 unverified → 默认策略下不可用。
   */
  static ensureRepository(context: common.Context,
    validatorBridge: ((path: string) => Promise<string>) | null): void {
    if (RuleSetRepository.isInitialized()) {
      return;
    }
    RuleSetRepository.init(context);
    RuleSetRepository.setFetcher(new HttpResourceFetcher());
    if (validatorBridge !== null) {
      RuleSetRepository.setValidator(ResourceValidator.fromKernelBridge(validatorBridge));
    }
  }

  /** 规则集在内核配置里的 tag(`remote_<去敏资源ID>`);ID 非法返回 ''。 */
  static ruleSetTag(id: string): string {
    const sid = sanitizeResourceId(id);
    return sid.length === 0 ? '' : `${RULESET_TAG_PREFIX}${sid}`;
  }

  /** 仓库格式(binary-srs/source-json)→ 内核 rule_set.format(binary/source)。 */
  static kernelFormat(item: RemoteRuleSet): string {
    return item.format === RULESET_FORMAT_SOURCE ? RULESET_FORMAT_SOURCE : RULESET_FORMAT_BINARY;
  }

  /** 用户意图里的格式(源格式 'binary'/'source')→ 仓库格式(binary-srs/source-json)。 */
  static repositoryFormat(item: RemoteRuleSet): string {
    return item.format === RULESET_FORMAT_SOURCE ? FORMAT_SOURCE_JSON : FORMAT_BINARY_SRS;
  }

  private static policyOf(item: RemoteRuleSet): string {
    return isValidFailurePolicy(item.failurePolicy) ? item.failurePolicy : FAILURE_POLICY_BLOCK;
  }

  /** 用可用性结论填充一个准备结果(纯内存,不联网)。 */
  private static fill(target: PreparedRuleSet, item: RemoteRuleSet, sid: string,
    avail: ResourceAvailability): void {
    target.tag = sid.length === 0 ? '' : `${RULESET_TAG_PREFIX}${sid}`;
    target.resourceId = sid;
    target.outbound = item.outbound === 'proxy' ? 'proxy' : 'direct';
    target.failurePolicy = ResourceResolver.policyOf(item);
    target.format = ResourceResolver.kernelFormat(item);
    target.available = avail.available;
    target.verified = avail.verified;
    target.fromCache = avail.fromCache;
    target.state = avail.state;
    target.reason = avail.reason;
    target.cachedAt = avail.cachedAt;
    target.error = avail.error;
    if (!avail.available) {
      target.path = '';
      return;
    }
    // available=true 但文件被清掉(清单与磁盘不一致)→ 视为不可用,不生成悬空定义
    const path = RuleSetRepository.cachedFilePath(sid);
    if (path.length === 0) {
      target.available = false;
      target.state = STATE_UNAVAILABLE;
      target.path = '';
      target.reason = 'cache-missing';
      target.error = '清单记录的缓存文件不存在';
      return;
    }
    target.path = path;
  }

  /**
   * 登记本次会话进入配置的本地资源文件(§7 会话资源稳定性):
   * 内容寻址目录本身不会被后台更新就地覆盖,这里再挡住版本裁剪/GC 的删除,
   * 确保会话生命周期内内核引用的文件始终存在。会话结束时由 releaseSessionFiles 解除。
   */
  static pinSessionFiles(prepared: PreparedResources): void {
    const paths: Array<string> = [];
    for (let i = 0; i < prepared.ruleSets.length; i++) {
      const item = prepared.ruleSets[i];
      if (item.available && item.path.length > 0) {
        paths.push(item.path);
      }
    }
    if (prepared.geositePath.length > 0) {
      paths.push(prepared.geositePath);
    }
    if (prepared.geoIpPath.length > 0) {
      paths.push(prepared.geoIpPath);
    }
    RuleSetRepository.pinSessionFiles(paths);
  }

  /** 会话结束(断开/销毁/重连前)解除固定；旧版本由下一次 GC 清理。 */
  static releaseSessionFiles(): void {
    RuleSetRepository.releaseSessionFiles();
  }

  /**
   * 只读快照:不联网、不落盘。启动前 UI 预校验、可用性展示、以及启动准备的第一步。
   * 与输入数组等长同序(便于日志与索引对齐)。
   */
  static snapshot(ruleSets: Array<RemoteRuleSet>, withGeo: boolean,
    context: common.Context | null): PreparedResources {
    const out = new PreparedResources();
    for (let i = 0; i < ruleSets.length; i++) {
      const item = ruleSets[i];
      const prepared = new PreparedRuleSet();
      const sid = sanitizeResourceId(item.id);
      if (sid.length === 0) {
        prepared.outbound = item.outbound === 'proxy' ? 'proxy' : 'direct';
        prepared.failurePolicy = ResourceResolver.policyOf(item);
        prepared.format = ResourceResolver.kernelFormat(item);
        prepared.error = '资源 ID 非法';
        out.ruleSets.push(prepared);
        continue;
      }
      ResourceResolver.fill(prepared, item, sid, RuleSetRepository.getAvailability(sid));
      out.ruleSets.push(prepared);
    }
    if (withGeo && context !== null) {
      try {
        if (geoReady(context)) {
          out.geositePath = geoSiteFile(context);
          out.geoIpPath = geoIpFile(context);
          out.geoEnabled = true;
        } else {
          out.warning = 'geo 资产未下载,规则模式仅私网/自定义直连';
        }
      } catch (e) {
        out.warning = `geo 资产不可用: ${errText(e)}`;
      }
    }
    ResourceResolver.recount(out);
    return out;
  }

  private static recount(out: PreparedResources): void {
    let available = 0;
    let unavailable = 0;
    let downloaded = 0;
    for (let i = 0; i < out.ruleSets.length; i++) {
      const item = out.ruleSets[i];
      if (item.available) {
        available++;
      } else {
        unavailable++;
      }
      if (item.downloaded) {
        downloaded++;
      }
    }
    out.availableCount = available;
    out.unavailableCount = unavailable;
    out.downloadedCount = downloaded;
  }

  /**
   * 启动前资源预处理(VpnExtAbility 第 2.6 阶段)。
   *
   * 顺序:缓存快照 → (仅对无可用缓存的)有界下载 → 重新快照 → 汇总。
   * 任何异常都被吞掉并转成 warning:本函数的失败**永远不**导致 VPN 启动失败。
   */
  static async prepareResources(context: common.Context, ruleSets: Array<RemoteRuleSet>,
    options: PrepareOptions): Promise<PreparedResources> {
    let out: PreparedResources;
    try {
      out = ResourceResolver.snapshot(ruleSets, options.withGeo, context);
    } catch (e) {
      const empty = new PreparedResources();
      empty.warning = `资源快照失败(已忽略): ${errText(e)}`;
      return empty;
    }
    if (!options.allowDownload || options.budgetMs <= 0) {
      return out;
    }
    const deadline = Date.now() + options.budgetMs;
    const notes: Array<string> = [];
    for (let i = 0; i < ruleSets.length; i++) {
      const item = ruleSets[i];
      const prepared = out.ruleSets[i];
      if (!item.enabled || prepared.available) {
        continue; // 停用的或已命中可用缓存的资源:启动阶段一律不联网
      }
      const sid = sanitizeResourceId(item.id);
      if (sid.length === 0) {
        continue;
      }
      const urlError = RuleSetRepository.validateUrl(item.url);
      if (urlError.length > 0) {
        prepared.reason = 'invalid-url';
        prepared.error = `下载地址无效: ${urlError}`;
        notes.push(`${item.name.length > 0 ? item.name : sid} 地址无效(${urlError})`);
        continue;
      }
      const remaining = deadline - Date.now();
      if (remaining <= 500) {
        prepared.error = prepared.error.length > 0 ? prepared.error : '本次启动未补缓存(下载预算已用完)';
        notes.push('下载预算耗尽,剩余规则集本次跳过');
        break;
      }
      try {
        // 用户意图(模型里的 failurePolicy)与仓库清单对齐:仅在实际要下载时写一次
        const entity = RuleSetRepository.get(sid);
        const policy = ResourceResolver.policyOf(item);
        if (entity !== null && entity.failurePolicy !== policy) {
          await RuleSetRepository.setFailurePolicy(sid, policy);
        }
        const timeout = Math.min(remaining, SINGLE_DOWNLOAD_TIMEOUT_MS);
        await withTimeout(
          RuleSetRepository.ensureResource(sid, item.url, ResourceResolver.repositoryFormat(item), policy),
          timeout, `规则集下载 ${item.name.length > 0 ? item.name : sid}`);
        prepared.downloaded = true;
      } catch (e) {
        prepared.error = `补缓存失败(已降级): ${errText(e)}`;
        notes.push(`${item.name.length > 0 ? item.name : sid} 补缓存失败`);
      }
      ResourceResolver.fill(prepared, item, sid, RuleSetRepository.getAvailability(sid));
      if (prepared.downloaded && prepared.error.length === 0) {
        prepared.error = '';
      }
    }
    ResourceResolver.recount(out);
    if (notes.length > 0) {
      out.warning = out.warning.length > 0 ? `${out.warning};${notes.join(';')}` : notes.join(';');
    }
    return out;
  }

  /**
   * 后台刷新(方案第五阶段):VPN 已运行后异步补缓存。
   * 只做「下载→校验→提交清单」,失败保留旧缓存,不影响当前会话;
   * 内容寻址版本目录 ⇒ 内核正在读的旧文件不会被就地改写。
   */
  static async refreshInBackground(ruleSets: Array<RemoteRuleSet>,
    minAgeMs: number = BACKGROUND_REFRESH_AGE_MS): Promise<void> {
    const now = Date.now();
    for (let i = 0; i < ruleSets.length; i++) {
      const item = ruleSets[i];
      if (!item.enabled) {
        continue;
      }
      const sid = sanitizeResourceId(item.id);
      if (sid.length === 0) {
        continue;
      }
      if (RuleSetRepository.validateUrl(item.url).length > 0) {
        continue;
      }
      const avail = RuleSetRepository.getAvailability(sid);
      const entity = RuleSetRepository.get(sid);
      const expectedFormat = ResourceResolver.repositoryFormat(item);
      // sourceUrl / format 是资源身份的一部分：用户修改任一项时必须立即刷新，
      // 不能继续被旧缓存的 24h 年龄窗口抑制。
      const identityChanged = entity === null || entity.sourceUrl !== item.url || entity.format !== expectedFormat;
      if (!identityChanged && avail.cachedAt > 0 && now - avail.cachedAt < minAgeMs) {
        continue;
      }
      const label = item.name.length > 0 ? item.name : sid;
      try {
        const result = await RuleSetRepository.ensureResource(sid, item.url,
          ResourceResolver.repositoryFormat(item), ResourceResolver.policyOf(item));
        if (result.available) {
          LogStore.addLog(`[ruleset] 后台刷新完成 ${label}: ${result.reason}`);
        } else {
          LogStore.addLog(`[ruleset] 后台刷新未生效 ${label}: ${result.reason}` +
            (result.error.length > 0 ? ` ${result.error}` : '') + '(沿用旧缓存)');
        }
      } catch (e) {
        LogStore.addLog(`[ruleset] 后台刷新失败 ${label}: ${errText(e)}(沿用旧缓存)`);
      }
    }
  }
}

/** 状态文案(日志/UI 共用)。 */
export function preparedStateText(state: string): string {
  if (state === STATE_READY) {
    return '可用';
  }
  if (state === STATE_UNVERIFIED) {
    return '未验证';
  }
  return '不可用';
}
