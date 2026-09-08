import socket from '@ohos.net.socket';
import common from '@ohos.app.ability.common';
import { AppSettings, Profile } from '../model/Profile';
import { buildLatencyTestConfig, LatencyTestConfig } from '../core/ConfigBuilder';
import { CoreManager } from '../core/CoreManager';
import { LogStore } from '../model/Store';

/**
 * 节点延迟测试,两种模式:
 *  - tcpPing:对节点服务器做 TCP 三次握手计时(快,但假节点/协议失效也会绿);
 *  - URL Test:把全部节点编成临时配置,起一个独立的内核测试实例(UI 进程内,
 *    无 TUN/不碰 VPN),逐节点做「代理隧道 → TLS → HTTP HEAD 测试网址」真连接,
 *    只有全链路通的节点才返回 ms,其余 -1(红)。
 * VPN 运行中测试时,测试流量同样经过隧道,延迟包含隧道开销(与安卓行为一致)。
 */

export async function tcpPing(host: string, port: number, timeoutMs: number = 5000): Promise<number> {
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

/** TCPing:并发测试全部节点;ms = -1 表示失败 */
export async function testProfiles(profiles: Array<Profile>,
  onResult: (id: string, ms: number) => void, concurrency: number = 4): Promise<void> {
  let index = 0;
  const runWorker = async (): Promise<void> => {
    while (index < profiles.length) {
      const p = profiles[index];
      index++;
      let ms = -1;
      try {
        ms = await tcpPing(p.server, p.serverPort, 5000);
      } catch (e) {
        ms = -1;
      }
      onResult(p.id, ms);
    }
  };
  const workers: Array<Promise<void>> = [];
  const n = concurrency < profiles.length ? concurrency : profiles.length;
  for (let i = 0; i < n; i++) {
    workers.push(runWorker());
  }
  await Promise.all(workers);
}

/** URL Test:真连接延迟测试(内核 CGoTest* 导出);ms = -1 表示失败 */
export async function urlTestProfiles(targets: Array<Profile>, allProfiles: Array<Profile>,
  settings: AppSettings, context: common.Context,
  onResult: (id: string, ms: number) => void, concurrency: number = 4,
  timeoutMs: number = 5000): Promise<void> {
  let cfg: LatencyTestConfig;
  try {
    cfg = buildLatencyTestConfig(targets, allProfiles, settings, CoreManager.testLogFilePath(context));
  } catch (e) {
    const msg = e instanceof Error ? e.message : `${e}`;
    LogStore.addLog(`[test] 测速配置生成失败,回退 TCPing: ${msg}`);
    await testProfiles(targets, onResult, concurrency);
    return;
  }
  const configPath = CoreManager.writeTestConfigFile(context, cfg.json);
  const startErr = await CoreManager.testStart(configPath);
  if (startErr.length > 0) {
    LogStore.addLog(`[test] 测速内核启动失败,回退 TCPing: ${startErr}`);
    await testProfiles(targets, onResult, concurrency);
    return;
  }
  let next = 0;
  try {
    const runWorker = async (): Promise<void> => {
      while (next < targets.length) {
        const i = next;
        next++;
        let ms = -1;
        const tag = i < cfg.tags.length ? cfg.tags[i] : '';
        if (tag.length > 0) {
          try {
            const res = await CoreManager.testProxy(tag, settings.testUrl.trim(), timeoutMs);
            if (!res.startsWith('err:') && !res.startsWith('内核不支持')) {
              const n = parseInt(res);
              if (!isNaN(n) && n >= 0) {
                ms = n;
              }
            }
          } catch (e) {
            ms = -1;
          }
        }
        onResult(targets[i].id, ms);
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
}
