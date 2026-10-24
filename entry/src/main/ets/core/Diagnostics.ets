import { redactLogText } from '../model/LogView';

/**
 * 诊断包 —— REDESIGN-PLAN-2026-10-23.md §10.5(P5/W20)。
 *
 * 内容:版本、实际内核能力、系统 API 级别、运行/保存 revision、错误类别、脱敏日志尾部、
 * 检测参数与结果摘要。**不默认包含**完整节点密钥或私人订阅 URL(只有计数与名称以外的
 * 元数据)。生成后由用户选择保存或分享,不自动上传。
 *
 * 收集器由页面注入(异步平台信息),本类只做组装与脱敏 —— 便于主机测试
 * (tests/diagnostics.cjs)注入全部输入验证输出结构与脱敏行为。
 */

/** 诊断输入(字段缺省值=「未知」,如实输出不猜)。 */
export class DiagnosticsInput {
  appVersion: string = '';
  versionCode: number = 0;
  /** 内核能力描述(如 RuleSetRepository.describeCapability()/测速导出能力) */
  kernelCapability: string = '';
  /** 内核版本串(如 1.14.0-ohos-inproc) */
  kernelVersion: string = '';
  sdkApiLevel: number = 0;
  /** 保存 revision(ConfigRepository.getActiveRevision) */
  savedRevision: number = 0;
  /** 运行 revision(vpnAppliedRevision;0=未运行/未知) */
  runningRevision: number = 0;
  /** 应用事务状态摘要(AppCoordinator 快照文本) */
  applyState: string = '';
  /** 最近错误类别(调用方归类:订阅/连接/内核/配置/检测) */
  errorCategory: string = '';
  /** 订阅数(不含 URL) */
  subscriptionCount: number = 0;
  /** 节点数(不含任何节点字段) */
  profileCount: number = 0;
  /** 检测参数摘要(testUrl/timeout/concurrent/method) */
  probeParams: string = '';
  /** 最近一次检测结果摘要(成功/失败/取消计数) */
  probeSummary: string = '';
  /** 日志尾部原始文本(组装时统一脱敏) */
  logTail: string = '';
  /** 日志保留行数上限 */
  logTailLines: number = 80;
}

const REDACTED_KEYS: Array<string> = ['appVersion', 'versionCode', 'kernelCapability',
  'kernelVersion', 'sdkApiLevel', 'savedRevision', 'runningRevision', 'applyState',
  'errorCategory', 'subscriptionCount', 'profileCount', 'probeParams', 'probeSummary'];

/** 组装诊断包文本(固定键序 JSON;日志行截断 + 全量脱敏)。 */
export function buildDiagnosticsPackage(input: DiagnosticsInput, nowMs: number): string {
  const logLines = input.logTail.split('\n');
  const kept = logLines.slice(Math.max(0, logLines.length - Math.max(1, input.logTailLines)));
  const redactedTail = redactLogText(kept.join('\n'));
  const parts: Array<string> = [];
  parts.push(`"schema":"nekobox-diagnostics-1"`);
  parts.push(`"generatedAt":${nowMs}`);
  parts.push(`"appVersion":${JSON.stringify(orUnknown(input.appVersion))}`);
  parts.push(`"versionCode":${input.versionCode}`);
  parts.push(`"kernelVersion":${JSON.stringify(orUnknown(input.kernelVersion))}`);
  parts.push(`"kernelCapability":${JSON.stringify(orUnknown(input.kernelCapability))}`);
  parts.push(`"sdkApiLevel":${input.sdkApiLevel}`);
  parts.push(`"savedRevision":${input.savedRevision}`);
  parts.push(`"runningRevision":${input.runningRevision}`);
  parts.push(`"applyState":${JSON.stringify(orUnknown(input.applyState))}`);
  parts.push(`"errorCategory":${JSON.stringify(orUnknown(input.errorCategory))}`);
  parts.push(`"subscriptionCount":${input.subscriptionCount}`);
  parts.push(`"profileCount":${input.profileCount}`);
  parts.push(`"probeParams":${JSON.stringify(orUnknown(input.probeParams))}`);
  parts.push(`"probeSummary":${JSON.stringify(orUnknown(input.probeSummary))}`);
  parts.push(`"logTail":${JSON.stringify(redactedTail)}`);
  return `{${parts.join(',')}}`;
}

function orUnknown(value: string): string {
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : '未知';
}

/**
 * 结构自检(主机防漂移):输出必须包含全部元数据键,且不得包含任何 URL scheme
 * 凭据或未脱敏 token —— 用于测试与页面预览前的最后一道校验。
 */
export function diagnosticsLooksSafe(packageText: string): boolean {
  for (let i = 0; i < REDACTED_KEYS.length; i++) {
    if (packageText.indexOf(`"${REDACTED_KEYS[i]}"`) < 0) {
      return false;
    }
  }
  // 粗检:任何 :// 后紧跟 user:pass@ 形态即为未脱敏凭据;
  // 密码段只含 *(打码痕迹)不算泄露(redactUrl 输出 user:****@)。
  return !/:\/\/[^/"'\s@]+:[^/"'\s*@]+@/.test(packageText);
}
