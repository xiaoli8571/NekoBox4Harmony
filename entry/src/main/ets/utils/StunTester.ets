import socket from '@ohos.net.socket';

/**
 * 最小 STUN 探测(RFC 5389 Binding Request):
 * 返回公网映射地址与响应耗时;两次请求映射地址是否一致作为 NAT 特征启发判断。
 */

export interface StunResult {
  ok: boolean;
  publicEndpoint: string;
  latencyMs: number;
  mappingStable: boolean;
  detail: string;
}

const MAGIC_COOKIE: number = 0x2112A442;

function randomTransactionId(): Uint8Array {
  const id = new Uint8Array(12);
  for (let i = 0; i < 12; i++) {
    id[i] = Math.floor(Math.random() * 256);
  }
  return id;
}

function buildBindingRequest(): Uint8Array {
  const msg = new Uint8Array(20);
  const view = new DataView(msg.buffer);
  view.setUint16(0, 0x0001);       // Binding Request
  view.setUint16(2, 0);            // message length
  view.setUint32(4, MAGIC_COOKIE); // magic cookie
  msg.set(randomTransactionId(), 8);
  return msg;
}

/** 解析 Binding Success Response 中的 XOR-MAPPED-ADDRESS / MAPPED-ADDRESS */
function parseMappedAddress(data: DataView): string {
  // 先找 XOR-MAPPED-ADDRESS(0x0020),退化找 MAPPED-ADDRESS(0x0001)
  let offset = 20;
  let xorFound = '';
  let plainFound = '';
  while (offset + 4 <= data.byteLength) {
    const type = data.getUint16(offset);
    const len = data.getUint16(offset + 2);
    if (type === 0x0020 && len >= 8) {
      const port = (data.getUint8(offset + 6) ^ 0x21) << 8 | (data.getUint8(offset + 7) ^ 0x12);
      const xorAddr = data.getUint32(offset + 8) ^ MAGIC_COOKIE;
      const ip = `${(xorAddr >>> 24) & 0xFF}.${(xorAddr >>> 16) & 0xFF}.${(xorAddr >>> 8) & 0xFF}.${xorAddr & 0xFF}`;
      xorFound = `${ip}:${port}`;
    }
    if (type === 0x0001 && len >= 8) {
      const port = data.getUint16(offset + 6);
      const addr = data.getUint32(offset + 8);
      const ip = `${(addr >>> 24) & 0xFF}.${(addr >>> 16) & 0xFF}.${(addr >>> 8) & 0xFF}.${addr & 0xFF}`;
      plainFound = `${ip}:${port}`;
    }
    offset += 4 + len + ((4 - (len % 4)) % 4);
  }
  return xorFound.length > 0 ? xorFound : plainFound;
}

function stunQuery(host: string, port: number, timeoutMs: number): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const udp = socket.constructUDPSocketInstance();
    let settled = false;
    const finish = (err: string | null, mapping: string): void => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        udp.off('message');
        udp.close();
      } catch (e) {
        // ignore
      }
      if (err !== null) {
        reject(new Error(err));
      } else {
        resolve(mapping);
      }
    };
    const timer = setTimeout(() => {
      finish('STUN 响应超时', '');
    }, timeoutMs);
    udp.on('message', (value: socket.SocketMessageInfo) => {
      try {
        const view = new DataView(value.message);
        if (view.getUint16(0) !== 0x0101) {
          return;
        }
        const mapping = parseMappedAddress(view);
        clearTimeout(timer);
        if (mapping.length === 0) {
          finish('响应中未找到映射地址', '');
        } else {
          finish(null, mapping);
        }
      } catch (e) {
        clearTimeout(timer);
        finish(`解析响应失败: ${e instanceof Error ? e.message : `${e}`}`, '');
      }
    });
    udp.bind({ address: '0.0.0.0', port: 0 }).then(() => {
      const request = buildBindingRequest();
      udp.send({
        data: request.buffer,
        address: { address: host, port: port, family: 1 }
      }).catch((e: Object) => {
        clearTimeout(timer);
        finish(`发送失败: ${e instanceof Error ? e.message : `${e}`}`, '');
      });
    }).catch((e: Object) => {
      clearTimeout(timer);
      finish(`绑定失败: ${e instanceof Error ? e.message : `${e}`}`, '');
    });
  });
}

/** 对单个 STUN 服务器执行两次探测:映射地址 + 稳定性启发 */
export async function stunTest(server: string, timeoutMs: number = 5000): Promise<StunResult> {
  let host = server.trim();
  let port = 3478;
  const colon = host.lastIndexOf(':');
  if (colon > 0) {
    const parsed = parseInt(host.substring(colon + 1));
    if (!isNaN(parsed)) {
      port = parsed;
      host = host.substring(0, colon);
    }
  }
  const start = Date.now();
  try {
    const first = await stunQuery(host, port, timeoutMs);
    const latency = Date.now() - start;
    let stable = true;
    try {
      const second = await stunQuery(host, port, timeoutMs);
      stable = second === first;
    } catch (e) {
      stable = true;
    }
    const result: StunResult = {
      ok: true,
      publicEndpoint: first,
      latencyMs: latency,
      mappingStable: stable,
      detail: ''
    };
    return result;
  } catch (e) {
    const result: StunResult = {
      ok: false,
      publicEndpoint: '',
      latencyMs: 0,
      mappingStable: false,
      detail: e instanceof Error ? e.message : `${e}`
    };
    return result;
  }
}
