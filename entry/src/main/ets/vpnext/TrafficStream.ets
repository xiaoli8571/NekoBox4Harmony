import webSocket from '@ohos.net.webSocket';
import BusinessError from '@ohos.base';
import { clashApiHeaders } from '../utils/ClashAuth';
import { parseTrafficDelta, TrafficDelta } from '../model/TrafficMeter';

/**
 * 内核 /traffic WebSocket 客户端(P1:扩展进程作为唯一流量生产者)。
 *
 * 之前的实现是 UI(Index.startSpeedPoller)与扩展通知各开一个 1s 定时器,
 * 每秒 GET `/connections` 并 JSON.parse 整份连接列表 —— 连接多时主线程和
 * 扩展线程都要为「只要两个累计数」付出全量解析成本。`/traffic` 是内核原生
 * 流式接口(sing-box clashapi,1s 一帧增量),只推两个数字。
 *
 * 可靠性:
 *  - 断线自动重连(1s→2s→4s…最多 10s);
 *  - 每次连接成功回调 onOpen,调用方据此用一次 `/connections` 快照重对齐累计值
 *    (断线期间漏掉的增量不会让累计值倒退);
 *  - stop() 后不再重连;过期代次的回调一律丢弃。
 */

export class TrafficStreamCallbacks {
  /** 连接建立(含重连成功):调用方应做一次累计值 resync。 */
  onOpen: () => void = () => {
  };
  /** 收到一帧增量(字节/秒)。 */
  onDelta: (up: number, down: number) => void = (up: number, down: number) => {
  };
  /** 连接/解析错误(用于诊断日志;重连由本类负责)。 */
  onError: (message: string) => void = (message: string) => {
  };
}

export class TrafficStream {
  private socket: webSocket.WebSocket | null = null;
  private callbacks: TrafficStreamCallbacks | null = null;
  private port: number = 0;
  private secret: string = '';
  private stopped: boolean = true;
  private generation: number = 0;
  private retryTimer: number = -1;
  private retryDelayMs: number = 1000;

  start(port: number, secret: string, callbacks: TrafficStreamCallbacks): void {
    this.stop();
    this.port = port;
    this.secret = secret;
    this.callbacks = callbacks;
    this.stopped = false;
    this.retryDelayMs = 1000;
    const generation = ++this.generation;
    this.connect(generation);
  }

  stop(): void {
    this.stopped = true;
    this.generation++;
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const socket = this.socket;
    this.socket = null;
    this.callbacks = null;
    if (socket !== null) {
      try {
        socket.close((err: BusinessError) => {
          // 关闭失败不影响调用方状态机
        });
      } catch (e) {
        // 已销毁
      }
    }
  }

  private connect(generation: number): void {
    if (this.stopped || generation !== this.generation) {
      return;
    }
    // 工厂及事件注册也可能同步抛错,与异步 connect 失败走同一退避路径。
    try {
      const socket = webSocket.createWebSocket();
      this.socket = socket;
      socket.on('open', (err: BusinessError) => {
        if (err || this.stopped || generation !== this.generation) {
          return;
        }
        this.retryDelayMs = 1000;
        const callbacks = this.callbacks;
        if (callbacks !== null) {
          callbacks.onOpen();
        }
      });
      socket.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
        if (err || this.stopped || generation !== this.generation) {
          return;
        }
        if (typeof data !== 'string') {
          return;
        }
        const delta: TrafficDelta | null = parseTrafficDelta(data);
        if (delta === null) {
          return;
        }
        const callbacks = this.callbacks;
        if (callbacks !== null) {
          callbacks.onDelta(delta.up, delta.down);
        }
      });
      socket.on('close', (err: BusinessError) => {
        this.handleDrop(generation);
      });
      socket.on('error', (err: BusinessError) => {
        if (this.stopped || generation !== this.generation) {
          return;
        }
        const callbacks = this.callbacks;
        if (callbacks !== null) {
          callbacks.onError(`traffic ws ${err.code}: ${err.message}`);
        }
        this.handleDrop(generation);
      });
      const options: webSocket.WebSocketRequestOptions = { header: clashApiHeaders(this.secret) };
      socket.connect(`ws://127.0.0.1:${this.port}/traffic`, options, (err: BusinessError) => {
        if (err) {
          this.handleDrop(generation);
        }
      });
    } catch (e) {
      this.handleDrop(generation);
    }
  }

  /** 连接断开:关闭旧 socket 并按退避重连(调用方代次不变,累计值由 onOpen 重对齐)。 */
  private handleDrop(generation: number): void {
    if (this.stopped || generation !== this.generation) {
      return;
    }
    this.generation++;
    const socket = this.socket;
    this.socket = null;
    if (socket !== null) {
      try {
        socket.close((err: BusinessError) => {
          // 已断开
        });
      } catch (e) {
        // 已销毁
      }
    }
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
    }
    const nextGeneration = this.generation;
    const delay = this.retryDelayMs;
    this.retryDelayMs = Math.min(10000, this.retryDelayMs * 2);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.connect(nextGeneration);
    }, delay);
  }
}
