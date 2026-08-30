import socket from '@ohos.net.socket';
import { Profile } from '../model/Profile';

/**
 * 真连接延迟测试:对节点服务器做 TCP 三次握手计时(不含代理协议握手),
 * 并发测试所有节点。VPN 运行中测试时,流量会经隧道转发,延迟包含隧道开销。
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

/** 并发测试全部节点;ms = -1 表示失败 */
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
