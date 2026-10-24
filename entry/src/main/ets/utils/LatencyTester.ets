import socket from '@ohos.net.socket';
import connection from '@ohos.net.connection';
import common from '@ohos.app.ability.common';
import { AppSettings, Profile, ProfileGroup, ProfileType } from '../model/Profile';
import { buildLatencyTestConfig, LatencyTestConfig } from '../core/ConfigBuilder';
import { CoreManager } from '../core/CoreManager';
import { LogStore } from '../model/Store';
import {
  ProbeResult, PROBE_STATE_RUNNING, PROBE_STATE_SUCCESS, PROBE_STATE_FAILED,
  PROBE_METHOD_HTTP, PROBE_METHOD_TCPING, PROBE_EXPECT_ANY, PROBE_SOURCE_MANUAL,
  computeProfileConfigHash
} from '../model/ProbeResult';
import { ProbeCoordinator, ProbeEnv, ProbeTarget } from '../core/ProbeCoordinator';
import {
  ProbeRunner, ProbeRunnerDeps, ProbeRoundOptions, ProbeRoundOutcome, ProbeBatchConfig, ProbeTcpResult,
  ProbeBridge, ProbeDirProbe, PROBE_BUSY_ERROR
} from '../core/ProbeRunner';

/**
 * 节点延迟测试。两个入口与 Android 一一对应(`ConfigurationFragment.kt:586-592`)：
 *  - TCPing (`pingTest(false)`, :694)：对节点服务器做 TCP 握手计时；
 *  - URL Test (`urlTest()`, :835)：把节点编成临时配置,起独立内核测试实例(UI 进程内,
 *    无 TUN/不碰 VPN),逐节点做「代理隧道 → HTTP 探活」真连接。
 *
 * 结果模型与 Android `ProxyEntity` 完全一致(`status/ping/error`)：
 *   status 0 = 未测 / 1 = 可用(ping=ms) / 2 = 已知失败(error=机器 token)
 *   status 3 = 其它异常(error=内核原文,展示期再走 genFriendlyMsg)
 * 机器 token: timeout / refused / unreachable / domain_not_found，由界面映射到
 * `connection_test_*` 资源(Android 存本地化文本,鸿蒙需双语故存 token,见
 * docs/PARITY-LATENCY-TEST.md D-3.7)。
 *
 * 本轮 1:1 对齐要点(docs/PARITY-LATENCY-TEST.md)：
 *  - TCPing 过滤 canTCPing=false 的协议(:702-713),超时固定 3000(:748-755),
 *    先解析域名取第一个地址(:722-732),解析失败 status=2 domain_not_found(:734-739),
 *    错误按 timeout/refused/unreachable/原文 四分类(:773-793);
 *  - URL Test 不筛协议(:843),超时默认 5000(UrlTest.kt:9),失败一律 status=3 原文
 *    (:860-862),默认不判 HTTP 状态码(libneko speedtest 不看 StatusCode);
 *  - 并发默认 5(DataStore.kt:159);
 *  - 取消后已测结果仍由调用方落库(:807-823)。
 *
 * 实现方式差异(D-1,Lead 裁定)：Android 每节点一个 TestInstance,鸿蒙是"整批一个测试
 * 会话 + 按 tag 探测"——内核 `testInstance` 是包级单例(core/libsingbox14/main.go:180),
 * 逐节点建实例只能全局串行,会让有效并发退化成 1,与"效果一致"目标相反。
 *
 * P2/W09 重构(§6.3-§6.6)：URL Test 的编排搬进 `core/ProbeRunner`(纯编排 + 可注入桥接),
 * 本文件只做「平台接线 + 旧结果模型投影」：
 *  - 能力分档:V3(sessionId 会话隔离)/ V2(旧导出,串行 + 代次守卫)/ legacy;
 *  - 批量启动失败**不再整批静默回退 TCPing**,改为二分隔离(§6.4-4):坏节点单独 failed +
 *    内核原文,健康节点保持 HTTP 结果;
 *  - 环境级失败(内核不支持/目录不可写/URL 非法)整轮不启动:节点 notApplicable +
 *    `tcpingOption=true`(UI 提供"改用 TCPing 检测支持的节点"),只报一次;
 *  - 逐节点 TCP 回退只在调用方显式开启时发生,结果永久带 `methodActual='tcping'` +
 *    `degradedReason='http_fallback_tcping'`(§6.4-7);
 *  - 结果逐轮落盘 `ProbeStore.saveRun`,写失败如实 `saved=false` + `unsaved` 状态;
 *  - `testProfiles`(TCPing)保持原签名/原语义,额外可选回调 ProbeResult(带
 *    `methodActual='tcping'`),供 P3 的可用性展示/落盘复用。
 *
 * 健壮性(既有能力,保留)：失败重试/多次取样(默认 0/1,Android 口径)、桥接调用兜底超时
 * (挪到 ProbeRunner 内)、测速绑定物理网卡绕过隧道、绑定全红自动去掉绑定重测一次。
 */

/** 一轮测速的附加状态报告,由调用方决定如何提示用户。 */
export interface LatencyRunReport {
  // true = 本轮检测已降级(环境级失败,或部分节点改用 TCPing);界面必须提示,否则用户被误导
  degraded: boolean;
  degradeReason: string;
  // true = 绑定物理网卡导致全组失败,已自动去掉绑定重测
  bindFallback: boolean;
  // 本轮实际参与测试的节点数(TCPing 会先按 canTCPing 过滤)
  tested: number;
  // P2/W09 新增(旧字段语义不变,只加不改):
  // true = 结果真的写进了 ProbeStore(§6.3:写失败不假装已保存)
  saved: boolean;
  // 预算耗尽/会话停止未确认等未完成节点数(如实计数,绝不偷偷改检测方式)
  unfinished: number;
  // true = 环境级失败,界面应提供"改用 TCPing 检测支持的节点"(§6.4-7)
  tcpingOption: boolean;
}

/** 单节点测试结果,字段语义与 Android ProxyEntity 一致。 */
export interface TestResult {
  id: string;
  status: number;
  ping: number;
  error: string;
}

/** status 2 的机器 token(界面映射到 connection_test_* 资源)。 */
export class TestError {
  static readonly TIMEOUT: string = 'timeout';
  static readonly REFUSED: string = 'refused';
  static readonly UNREACHABLE: string = 'unreachable';
  static readonly DOMAIN_NOT_FOUND: string = 'domain_not_found';
}

/** Android TCPing 超时:socket.soTimeout = 3000 且 connect timeout 3000(:748,:754)。 */
export const TCPING_TIMEOUT_MS: number = 3000;

/** 连接中测当前节点的超时:Android BaseService.kt:147 固定 3000(不是 5000)。 */
export const CONNECTION_TEST_TIMEOUT_MS: number = 3000;

/**
 * 协议是否支持 TCPing,对齐 Android `canTCPing()`
 * (AbstractBean.java:51 默认 true;HysteriaBean.java:159、TuicBean.java:102、
 *  WireGuardBean.java:58、InternalBean.java:18、NekoBean.java:73 为 false)。
 * 映射:InternalBean(自定义 config)→ CUSTOM,NekoBean → CHAIN。
 */
export function canTCPing(p: Profile): boolean {
  switch (p.type) {
    case ProfileType.HYSTERIA:
    case ProfileType.HYSTERIA2:
    case ProfileType.TUIC:
    case ProfileType.WIREGUARD:
    case ProfileType.CUSTOM:
    case ProfileType.CHAIN:
      return false;
    default:
      return true;
  }
}

/**
 * Android `Protocols.genFriendlyMsg`(Protocols.kt:53-66):
 * 小写含 timeout/deadline → 超时;含 refused/closed pipe → 连接被拒绝;否则原文。
 * 返回 token 或原文;null 表示"没有可映射的友好文本"。
 */
export function genFriendlyMsg(message: string): string | null {
  const lower = message.toLowerCase();
  if (lower.indexOf('timeout') >= 0 || lower.indexOf('deadline') >= 0) {
    return TestError.TIMEOUT;
  }
  if (lower.indexOf('refused') >= 0 || lower.indexOf('closed pipe') >= 0) {
    return TestError.REFUSED;
  }
  return null;
}

/**
 * TCPing 连接错误的分类,对齐 Android :773-793 的四分类:
 *  - 超时类 → status 2 + timeout
 *  - ECONNREFUSED → status 2 + refused
 *  - ENETUNREACH → status 2 + unreachable
 *  - 其它 → status 3 + 原文
 * Android 的判据是 errno 文本(有 "failed:" 前缀才看 errno),OHOS 抛的是
 * {code,message},故按关键字匹配,未命中的一律走 status 3 原文(D-3.2)。
 */
export function classifyConnectError(message: string): TestResult {
  const lower = message.toLowerCase();
  const result = { id: '', status: 3, ping: 0, error: message } as TestResult;
  if (lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0 ||
    lower.indexOf('deadline') >= 0) {
    result.status = 2;
    result.error = TestError.TIMEOUT;
    return result;
  }
  if (lower.indexOf('refused') >= 0 || lower.indexOf('econnrefused') >= 0) {
    result.status = 2;
    result.error = TestError.REFUSED;
    return result;
  }
  if (lower.indexOf('unreachable') >= 0 || lower.indexOf('enetunreach') >= 0) {
    result.status = 2;
    result.error = TestError.UNREACHABLE;
    return result;
  }
  return result;
}

/** 单次 TCPing 的原始结果(status/ping/error,id 由调用方补)。 */
async function tcpPingOnce(host: string, port: number): Promise<TestResult> {
  const out: TestResult = { id: '', status: 3, ping: 0, error: '' };
  const target = host.trim();
  if (target.length === 0) {
    out.status = 2;
    out.error = TestError.DOMAIN_NOT_FOUND;
    return out;
  }
  let address = target;
  // 对齐 Android :722-732:先解析域名,取解析结果的第一个地址(不挑 v4/v6);
  // 解析不出来 → status 2 + domain_not_found(:734-739),不是笼统的失败。
  if (!/^[\d.]+$/.test(address) && address.indexOf(':') < 0) {
    try {
      const addrs = await connection.getAddressesByName(target);
      if (addrs.length > 0) {
        address = addrs[0].address;
      } else {
        address = '';
      }
    } catch (e) {
      address = '';
    }
    if (address.length === 0) {
      out.status = 2;
      out.error = TestError.DOMAIN_NOT_FOUND;
      return out;
    }
  }
  const ipv6 = address.indexOf(':') >= 0;
  const family = ipv6 ? 2 : 1;
  const client = socket.constructTCPSocketInstance();
  const start = Date.now();
  try {
    await client.bind({ address: family === 2 ? '::' : '0.0.0.0', port: 0, family: family });
    await client.connect({
      address: { address: address, port: port, family: family },
      timeout: TCPING_TIMEOUT_MS
    });
    out.status = 1;
    out.ping = Date.now() - start;
    out.error = '';
    return out;
  } catch (e) {
    const message = e instanceof Error ? e.message : `${e}`;
    const classified = classifyConnectError(message);
    out.status = classified.status;
    out.error = classified.error;
    return out;
  } finally {
    try {
      client.close();
    } catch (e) {
      // ignore
    }
  }
}

/**
 * TCPing:并发测试给定节点;内部按 canTCPing 过滤(与 Android :702-713 同位置)。
 * 结果逐个回调(status/ping/error),回调在节点完成时立刻触发 —— 调用方据此即时落库,
 * 取消时已测结果不会丢(Android :813-819)。
 *
 * P2/W09:`onProbe` 可选地把同一批结果投影成 ProbeResult(`methodActual='tcping'`,
 * `methodRequested` 由调用方传入所选方式),供 P3 的持久化/可用性展示复用;
 * 旧 TestResult 回调与返回值的语义不变(Index 无需改动)。
 */
export async function testProfiles(profiles: Array<Profile>,
  onResult: (r: TestResult) => void, concurrency: number = 5,
  retries: number = 0, samples: number = 1,
  isCancelled?: () => boolean, onProbe?: (r: ProbeResult) => void,
  methodRequested: string = PROBE_METHOD_TCPING): Promise<number> {
  const targets = profiles.filter((p: Profile) => canTCPing(p));
  const round = samples > 0 ? samples : 1;
  const extra = retries > 0 ? retries : 0;
  let index = 0;
  const emitProbe = (p: Profile, state: string, latencyMs: number, error: string): void => {
    if (onProbe === undefined) {
      return;
    }
    const probe = new ProbeResult();
    probe.profileId = p.id;
    probe.profileConfigHash = configHashOf(p);
    probe.methodRequested = methodRequested;
    probe.methodActual = PROBE_METHOD_TCPING;
    probe.state = state;
    probe.latencyMs = latencyMs;
    probe.target = `${p.server}:${p.serverPort}`;
    probe.source = PROBE_SOURCE_MANUAL;
    probe.completedAt = Date.now();
    if (state === PROBE_STATE_FAILED) {
      probe.errorDetail = error;
    }
    onProbe(probe);
  };
  const runWorker = async (): Promise<void> => {
    while (index < targets.length) {
      if (isCancelled !== undefined && isCancelled()) {
        return;
      }
      const p = targets[index];
      index++;
      onResult({ id: p.id, status: 0, ping: 0, error: '' } as TestResult);
      emitProbe(p, PROBE_STATE_RUNNING, -1, '');
      const ok: Array<number> = [];
      let last = { id: '', status: 3, ping: 0, error: '' } as TestResult;
      for (let attempt = 0; attempt < round + extra; attempt++) {
        if (attempt >= round && ok.length > 0) {
          break;
        }
        last = await tcpPingOnce(p.server, p.serverPort);
        if (last.status === 1) {
          ok.push(last.ping);
        }
        if (ok.length >= round) {
          break;
        }
      }
      if (ok.length > 0) {
        onResult({ id: p.id, status: 1, ping: averageOf(ok), error: '' } as TestResult);
        emitProbe(p, PROBE_STATE_SUCCESS, averageOf(ok), '');
      } else {
        onResult({ id: p.id, status: last.status, ping: 0, error: last.error } as TestResult);
        emitProbe(p, PROBE_STATE_FAILED, -1, last.error);
      }
    }
  };
  const workers: Array<Promise<void>> = [];
  const n = concurrency < targets.length ? concurrency : targets.length;
  for (let i = 0; i < n; i++) {
    workers.push(runWorker());
  }
  await Promise.all(workers);
  return targets.length;
}

/** 节点配置哈希(§6.2 复合键的一部分):与 ProbeStore 的比较口径一致。 */
function configHashOf(p: Profile): string {
  return computeProfileConfigHash(JSON.stringify(p));
}

function averageOf(values: Array<number>): number {
  let sum = 0;
  for (const v of values) {
    sum += v;
  }
  return Math.round(sum / values.length);
}


// ---------------- 平台接线:ProbeBridge 的生产实现 ----------------

/** 把 ProbeRunner 的抽象桥接接到 CoreManager 的 V3/V2/legacy 导出(§6.5)。 */
class CoreManagerProbeBridge implements ProbeBridge {
  caps(): Promise<string> {
    return CoreManager.testCaps();
  }

  startV3(sessionId: string, configPath: string, bindIfname: string): Promise<string> {
    return CoreManager.testStartV3(sessionId, configPath, bindIfname);
  }

  proxyV3(sessionId: string, tag: string, url: string, timeoutMs: number, expectStatus: string): Promise<string> {
    return CoreManager.testProxyV3(sessionId, tag, url, timeoutMs, expectStatus);
  }

  stopV3(sessionId: string): Promise<string> {
    return CoreManager.testStopV3(sessionId);
  }

  sessionInfoV3(sessionId: string): Promise<string> {
    return CoreManager.testSessionInfoV3(sessionId);
  }

  activeSessions(): Promise<string> {
    return CoreManager.testActiveSessions();
  }

  start(configPath: string, bindIfname: string): Promise<string> {
    return CoreManager.testStart(configPath, bindIfname);
  }

  proxy(tag: string, url: string, timeoutMs: number, expectStatus: string): Promise<string> {
    return CoreManager.testProxy(tag, url, timeoutMs, expectStatus);
  }

  stop(): Promise<string> {
    return CoreManager.testStop();
  }
}

/** VPN 是否在运行(只用于 path 判定;取不到按"不确定"处理,绝不假装直出)。 */
function vpnRunningSafe(): boolean {
  try {
    return AppStorage.get<boolean>('vpnRunning') === true;
  } catch (e) {
    return false;
  }
}

/**
 * 测试目录可写性探针(§6.4-1):写一份最小配置验证目录可写,**不 fsync 目录**。
 * 失败时把内核/系统原文一并带回,界面才能如实说明原因(而不是笼统"不可写")。
 */
function probeDirWritable(context: common.Context): ProbeDirProbe {
  const result = new ProbeDirProbe();
  try {
    CoreManager.writeTestConfigFile(context, '{"log":{"level":"error"}}');
    return result;
  } catch (e) {
    result.writable = false;
    result.error = e instanceof Error ? e.message : `${e}`;
    LogStore.addLog(`[test] 检测目录不可写: ${result.error}`);
    return result;
  }
}

/** 依赖链标识:共享同一前置/落地的多个根节点得到相同标识(§6.4-5 相同依赖错误)。 */
function chainKeyOf(p: Profile): string {
  const dialer = p.dialerProxyId.trim();
  if (dialer.length > 0) {
    return `dialer:${dialer}`;
  }
  const chain = p.chainIds.trim();
  if (chain.length > 0) {
    return `chain:${chain}`;
  }
  return '';
}

function probeTargetOf(p: Profile): ProbeTarget {
  const t = new ProbeTarget();
  t.profileId = p.id;
  t.profileName = p.name;
  t.profileConfigHash = configHashOf(p);
  t.chainKey = chainKeyOf(p);
  return t;
}

/** 旧 TestResult 投影(Index 不变):0=运行中,1=可用,3=异常(error=原文)。 */
function emitLegacy(probe: ProbeResult, onResult: (r: TestResult) => void): void {
  if (probe.state === PROBE_STATE_RUNNING) {
    onResult({ id: probe.profileId, status: 0, ping: 0, error: '' } as TestResult);
    return;
  }
  if (probe.state === PROBE_STATE_SUCCESS) {
    onResult({ id: probe.profileId, status: 1, ping: probe.latencyMs, error: '' } as TestResult);
    return;
  }
  if (probe.state === PROBE_STATE_FAILED) {
    onResult({ id: probe.profileId, status: 3, ping: 0, error: probe.errorDetail } as TestResult);
  }
  // notApplicable / cancelled / unsaved:没有结论,不覆盖界面上的旧值
}

function countSuccess(results: Array<ProbeResult>): number {
  let ok = 0;
  for (let i = 0; i < results.length; i++) {
    if (results[i].state === PROBE_STATE_SUCCESS) {
      ok++;
    }
  }
  return ok;
}

function applyOutcome(report: LatencyRunReport, outcome: ProbeRoundOutcome): void {
  report.tested = outcome.tested;
  report.saved = outcome.saved;
  report.unfinished = outcome.unfinished;
  report.tcpingOption = outcome.tcpingOption;
  report.degraded = outcome.degraded;
  report.degradeReason = outcome.degradeReason;
  if (outcome.degraded) {
    LogStore.addLog(`[test] URL Test 降级: ${outcome.degradeReason}`);
  }
  if (outcome.unfinished > 0) {
    LogStore.addLog(`[test] URL Test 有 ${outcome.unfinished} 个节点未完成(预算/会话收尾),结果如实标未完成`);
  }
}

/**
 * URL Test 的调用方接线(§6.3-§6.7):组装注入依赖 → ProbeRunner 编排 → 旧报告字段投影。
 * 报告字段语义(旧 → 新,P3 UI 请按新语义提示):
 *  - degraded:旧"已整批回退 TCPing" → 新"本轮检测降级"(环境级失败**或**部分节点改用 TCPing);
 *  - degradeReason:旧"回退原因" → 新"降级原因"(环境级失败时含内核/系统原文);
 *  - bindFallback:不变(绑定网卡全红后自动去绑定重测一次);
 *  - tested:不变(实际参与探测的节点数);
 *  - 新增 saved(结果是否真的落盘)/ unfinished(预算耗尽或会话未确认的未完成数)/ tcpingOption(环境级失败时提供 TCPing 入口)。
 */
export async function urlTestProfiles(targets: Array<Profile>, allProfiles: Array<Profile>,
  settings: AppSettings, context: common.Context,
  onResult: (r: TestResult) => void, concurrency: number = 5,
  groups: Array<ProfileGroup> = [], isCancelled?: () => boolean): Promise<LatencyRunReport> {
  const report: LatencyRunReport = {
    degraded: false, degradeReason: '', bindFallback: false, tested: 0,
    saved: false, unfinished: 0, tcpingOption: false
  };
  if (targets.length === 0) {
    return report;
  }
  const env = new ProbeEnv();
  env.method = PROBE_METHOD_HTTP;
  env.target = settings.testUrl.trim();
  env.timeoutMs = settings.testTimeoutMs > 0 ? settings.testTimeoutMs : 5000;
  env.concurrency = concurrency > 0 ? concurrency : 1;
  env.samples = settings.testSamples > 0 ? settings.testSamples : 1;
  env.retries = settings.testRetries > 0 ? settings.testRetries : 0;
  // 默认 'any' 对齐 Android:libneko speedtest 完全不看 HTTP 状态码
  env.expectedStatus = settings.testExpectStatus === '2xx' ? '2xx' : PROBE_EXPECT_ANY;
  env.bypassVpn = settings.testBypassTunnel;
  const probeTargets: Array<ProbeTarget> = [];
  for (let i = 0; i < targets.length; i++) {
    probeTargets.push(probeTargetOf(targets[i]));
  }
  const byId = new Map<string, Profile>();
  for (let i = 0; i < allProfiles.length; i++) {
    byId.set(allProfiles[i].id, allProfiles[i]);
  }
  // 本轮目标优先于 allProfiles:调用方可能只传 targets(旧签名允许 allProfiles 为空),
  // 不能因此把节点当成"构建失败"。
  for (let i = 0; i < targets.length; i++) {
    byId.set(targets[i].id, targets[i]);
  }
  const logPath = CoreManager.testLogFilePath(context);
  const bridge = new CoreManagerProbeBridge();
  const deps = new ProbeRunnerDeps();
  deps.bridge = bridge;
  deps.buildBatch = (batch: Array<ProbeTarget>): ProbeBatchConfig => {
    const profiles: Array<Profile> = [];
    for (let i = 0; i < batch.length; i++) {
      const p = byId.get(batch[i].profileId);
      if (p !== undefined) {
        profiles.push(p);
      }
    }
    const cfg: LatencyTestConfig = buildLatencyTestConfig(profiles, allProfiles, settings, logPath, groups);
    const out = new ProbeBatchConfig();
    out.json = cfg.json;
    out.tags = cfg.tags;
    return out;
  };
  deps.writeConfig = (json: string): string => CoreManager.writeTestConfigFile(context, json);
  deps.tcpPing = async (profileId: string): Promise<ProbeTcpResult> => {
    const tcp = new ProbeTcpResult();
    const p = byId.get(profileId);
    if (p === undefined) {
      tcp.error = 'profile not found';
      return tcp;
    }
    const ping = await tcpPingOnce(p.server, p.serverPort);
    tcp.ok = ping.status === 1;
    tcp.latencyMs = ping.ping;
    tcp.error = ping.error;
    return tcp;
  };
  deps.isVpnRunning = (): boolean => vpnRunningSafe();
  deps.probeDir = (): ProbeDirProbe => probeDirWritable(context);
  deps.log = (line: string): void => LogStore.addLog(line);
  // 测速实例跑在 UI 进程,没有被 protectProcessNet(),出站会被 TUN 捕获 ——
  // 于是测的是"节点套当前节点",连着 VPN 时全组延迟都被抬高。绑定物理网卡让测速
  // 直出(内核 SO_BINDTODEVICE;仅 V2/V3 内核认,legacy 一律 unboundUnknown)。
  const bindIfname = settings.testBypassTunnel ? await resolvePhysicalIfname() : '';
  const coord = new ProbeCoordinator();
  const runner = new ProbeRunner(coord, deps);
  const opts = new ProbeRoundOptions();
  opts.source = PROBE_SOURCE_MANUAL;
  opts.bindIfname = bindIfname;
  // §6.4-7:逐节点 TCP 回退只在用户明确开启时发生。当前还没有这个设置(P3 补开关),
  // 所以默认关闭 —— 绝不再整批静默回退 TCPing。
  opts.allowTcpFallbackPerNode = false;
  opts.isCancelled = isCancelled !== undefined ? isCancelled : null;
  opts.onResult = (r: ProbeResult): void => emitLegacy(r, onResult);
  const outcome = await runner.runProbeRound(probeTargets, env, opts);
  if (outcome.error === PROBE_BUSY_ERROR) {
    throw new Error('已有检测正在进行中');
  }
  applyOutcome(report, outcome);
  let passed = countSuccess(outcome.results);
  // 绑定网卡这条路径在真机上尚未验证过(内核侧 SO_BINDTODEVICE 原是休眠钩子)。
  // 一旦绑定让所有节点都失败,自动去掉绑定重跑一次,避免测速整体不可用。
  if (bindIfname.length > 0 && outcome.sessionStarted && outcome.tested > 0 && passed === 0 &&
    outcome.unfinished === 0 && outcome.envError.length === 0) {
    LogStore.addLog('[test] 绑定物理网卡后全部节点失败,去掉绑定重测一次');
    report.bindFallback = true;
    const retryOpts = new ProbeRoundOptions();
    retryOpts.source = PROBE_SOURCE_MANUAL;
    retryOpts.bindIfname = '';
    retryOpts.allowTcpFallbackPerNode = false;
    retryOpts.isCancelled = isCancelled !== undefined ? isCancelled : null;
    retryOpts.onResult = (r: ProbeResult): void => emitLegacy(r, onResult);
    const retry = await runner.runProbeRound(probeTargets, env, retryOpts);
    if (retry.error !== PROBE_BUSY_ERROR) {
      // 重测结论覆盖首轮"全红";bindFallback 置位以说明这批结论不是在绑定下得到的
      applyOutcome(report, retry);
      passed = countSuccess(retry.results);
    }
  }
  return report;
}

/** 取当前默认网络的物理网卡名(与 VpnExtAbility 建隧道时用的是同一个 API)。 */
async function resolvePhysicalIfname(): Promise<string> {
  try {
    const net: connection.NetHandle = await connection.getDefaultNet();
    const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
    return props.interfaceName;
  } catch (e) {
    LogStore.addLog(`[test] 获取物理网卡失败,测速流量将经过当前隧道: ${e}`);
    return '';
  }
}
