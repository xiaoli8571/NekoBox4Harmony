import socket from '@ohos.net.socket';
import connection from '@ohos.net.connection';
import common from '@ohos.app.ability.common';
import { AppSettings, Profile, ProfileGroup } from '../model/Profile';
import { buildLatencyTestConfig, LatencyTestConfig } from '../core/ConfigBuilder';
import { CoreManager } from '../core/CoreManager';
import { LogStore } from '../model/Store';

/**
 * 节点延迟测试,两种模式:
 *  - tcpPing:对节点服务器做 TCP 三次握手计时(快,但假节点/协议失效也会绿);
 *  - URL Test:把全部节点编成临时配置,起一个独立的内核测试实例(UI 进程内,
 *    无 TUN/不碰 VPN),逐节点做「代理隧道 → TLS → HTTP 探活」真连接,
 *    只有全链路通的节点才返回 ms,其余 -1(红)。
 * VPN 运行中测试时,测试流量同样经过隧道,延迟包含隧道开销(与安卓行为一致)。
 *
 * 健壮性(本次补齐):
 *  - 单次探测会被首次 TLS 握手偏慢或偶发丢包误杀 → 支持失败重试(testRetries);
 *  - 单点值看不出抖动 → 支持每节点多次取样取平均(testSamples);
 *  - 超时此前硬编码 5000ms → 改读 AppSettings.testTimeoutMs;
 *  - 测速内核启动失败会整批静默降级成 TCPing,用户却以为测的是真连接 →
 *    返回 LatencyRunReport.degraded,由调用方明确提示。
 */

export interface LatencyRunReport {
  // true = URL Test 不可用,已整体回退 TCPing(界面必须提示,否则用户被误导)
  degraded: boolean;
  degradeReason: string;
  // true = 绑定物理网卡导致全组失败,已自动去掉绑定重测
  bindFallback: boolean;
}

/** 一轮测速的通过/总数统计,用于判断"是否全红"以决定要不要去掉绑定重测。 */
class PassCount {
  ok: number = 0;
  total: number = 0;
}

export async function tcpPing(host: string, port: number, timeoutMs: number = 3000): Promise<number> {
  // 默认 3000ms 对齐安卓 TCPing socket.soTimeout=3000(ConfigurationFragment.kt:748)
  const client = socket.constructTCPSocketInstance();
  const start = Date.now();
  const ipv6 = host.includes(':');
  const family = ipv6 ? 2 : 1;
  try {
    await client.bind({ address: ipv6 ? '::' : '0.0.0.0', port: 0, family: family });
    await client.connect({
      address: { address: host, port: port, family: family },
      timeout: timeoutMs
    });
    return Date.now() - start;
  } finally {
    try {
      client.close();
    } catch (e) {
      // ignore
    }
  }
}

/** TCPing:并发测试全部节点;ms = -1 表示失败。samples>1 取平均,retries 为失败追加轮次。 */
export async function testProfiles(profiles: Array<Profile>,
  onResult: (id: string, ms: number) => void, concurrency: number = 4,
  timeoutMs: number = 5000, retries: number = 0, samples: number = 1): Promise<void> {
  const round = samples > 0 ? samples : 1;
  const extra = retries > 0 ? retries : 0;
  let index = 0;
  const runWorker = async (): Promise<void> => {
    while (index < profiles.length) {
      const p = profiles[index];
      index++;
      const ok: Array<number> = [];
      for (let attempt = 0; attempt < round + extra; attempt++) {
        if (attempt >= round && ok.length > 0) {
          break;
        }
        let ms = -1;
        try {
          ms = await tcpPing(p.server, p.serverPort, timeoutMs);
        } catch (e) {
          ms = -1;
        }
        if (ms >= 0) {
          ok.push(ms);
        }
        if (ok.length >= round) {
          break;
        }
      }
      onResult(p.id, ok.length === 0 ? -1 : averageOf(ok));
    }
  };
  const workers: Array<Promise<void>> = [];
  const n = concurrency < profiles.length ? concurrency : profiles.length;
  for (let i = 0; i < n; i++) {
    workers.push(runWorker());
  }
  await Promise.all(workers);
}

function averageOf(values: Array<number>): number {
  let sum = 0;
  for (const v of values) {
    sum += v;
  }
  return Math.round(sum / values.length);
}

/** 单节点一次 URL Test 探测;ms = -1 表示失败。 */
async function urlTestOnce(tag: string, url: string, timeoutMs: number, expectStatus: string): Promise<number> {
  try {
    const res = await CoreManager.testProxy(tag, url, timeoutMs, expectStatus);
    if (res.startsWith('err:') || res.startsWith('内核不支持')) {
      return -1;
    }
    const n = parseInt(res);
    if (isNaN(n) || n < 0) {
      return -1;
    }
    return n;
  } catch (e) {
    return -1;
  }
}

/** URL Test:真连接延迟测试(内核 CGoTest* 导出);ms = -1 表示失败 */
export async function urlTestProfiles(targets: Array<Profile>, allProfiles: Array<Profile>,
  settings: AppSettings, context: common.Context,
  onResult: (id: string, ms: number) => void, concurrency: number = 4,
  groups: Array<ProfileGroup> = []): Promise<LatencyRunReport> {
  const report: LatencyRunReport = { degraded: false, degradeReason: '', bindFallback: false };
  const timeoutMs = settings.testTimeoutMs > 0 ? settings.testTimeoutMs : 5000;
  const testUrl = settings.testUrl.trim();
  const expectStatus = settings.testExpectStatus === 'any' ? 'any' : '2xx';
  const round = settings.testSamples > 0 ? settings.testSamples : 1;
  const extra = settings.testRetries > 0 ? settings.testRetries : 0;
  const fallback = async (why: string): Promise<LatencyRunReport> => {
    report.degraded = true;
    report.degradeReason = why;
    LogStore.addLog(`[test] ${why},已回退 TCPing(结果只反映握手耗时,不代表真连接可用)`);
    await testProfiles(targets, onResult, concurrency, timeoutMs, settings.testRetries, settings.testSamples);
    return report;
  };
  let cfg: LatencyTestConfig;
  try {
    cfg = buildLatencyTestConfig(targets, allProfiles, settings, CoreManager.testLogFilePath(context), groups);
  } catch (e) {
    return await fallback(`测速配置生成失败: ${e instanceof Error ? e.message : `${e}`}`);
  }
  const configPath = CoreManager.writeTestConfigFile(context, cfg.json);
  // 测速实例跑在 UI 进程,没有被 protectProcessNet(),出站会被 TUN 捕获 ——
  // 于是测的是"节点套当前节点",连着 VPN 时全组延迟都被抬高,当前节点慢时
  // 还会把结论带偏。绑定物理网卡让测速直出(内核 SO_BINDTODEVICE)。
  // 只有 V2 内核认 bindIfname;legacy 内核会忽略它,这里提前查一次能力,
  // 免得白跑一遍再靠"全红"反推。
  const caps = await CoreManager.testCaps();
  const v2 = caps === 'v2';
  if (!v2 && settings.testBypassTunnel) {
    LogStore.addLog('[test] 内核为旧版测速导出,「测速绕过当前隧道」暂不生效(需重编 libsingbox.so)');
  }
  if (!v2 && expectStatus === '2xx') {
    LogStore.addLog('[test] 内核为旧版测速导出,不做响应状态码判定(403/500 也会判绿,需重编 libsingbox.so)');
  }
  const bindIfname = (v2 && settings.testBypassTunnel) ? await resolvePhysicalIfname() : '';
  const run = async (bind: string): Promise<PassCount> => {
    const startErr = await CoreManager.testStart(configPath, bind);
    if (startErr.length > 0) {
      throw new Error(startErr);
    }
    let passed = 0;
    let tested = 0;
    let nextIdx = 0;
    try {
      const runWorker = async (): Promise<void> => {
        while (nextIdx < targets.length) {
          const i = nextIdx;
          nextIdx++;
          const tag = i < cfg.tags.length ? cfg.tags[i] : '';
          const ok: Array<number> = [];
          if (tag.length > 0) {
            for (let attempt = 0; attempt < round + extra; attempt++) {
              if (attempt >= round && ok.length > 0) {
                break;
              }
              const ms = await urlTestOnce(tag, testUrl, timeoutMs, expectStatus);
              if (ms >= 0) {
                ok.push(ms);
              }
              if (ok.length >= round) {
                break;
              }
            }
          }
          tested++;
          if (ok.length > 0) {
            passed++;
          }
          onResult(targets[i].id, ok.length === 0 ? -1 : averageOf(ok));
        }
      };
      const workers: Array<Promise<void>> = [];
      const n = concurrency < targets.length ? concurrency : targets.length;
      for (let i = 0; i < n; i++) {
        workers.push(runWorker());
      }
      await Promise.all(workers);
    } finally {
      const stopErr = await CoreManager.testStop();
      if (stopErr.length > 0) {
        LogStore.addLog(`[test] 测速内核停止报错(忽略): ${stopErr}`);
      }
    }
    const count = new PassCount();
    count.ok = passed;
    count.total = tested;
    return count;
  };
  let firstPass: PassCount;
  try {
    firstPass = await run(bindIfname);
  } catch (e) {
    return await fallback(`测速内核启动失败: ${e instanceof Error ? e.message : `${e}`}`);
  }
  // 绑定网卡这条路径在真机上尚未验证过(内核侧的 SO_BINDTODEVICE 原是休眠钩子)。
  // 一旦绑定让所有节点都失败,自动去掉绑定重跑一次,避免测速整体不可用。
  if (bindIfname.length > 0 && firstPass.total > 0 && firstPass.ok === 0) {
    LogStore.addLog('[test] 绑定物理网卡后全部节点失败,去掉绑定重测一次');
    // 无论重测成不成功都要置位:走到这里就说明"绑定"这条路径不可信,
    // 而首轮已经把 -1 写进了所有节点,界面必须有机会说明这批全红不是测量结论。
    report.bindFallback = true;
    try {
      await run('');
    } catch (e) {
      LogStore.addLog(`[test] 去掉绑定后重测仍失败: ${e instanceof Error ? e.message : `${e}`}`);
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
