import { ConnectionState, isConnectionState } from '../model/ConnectionState';

/**
 * 连接状态的唯一写入口。状态仅用于协调 UI，不替代 VPN 扩展报告的真实运行状态。
 */
export class ConnectionStateManager {
  static initialize(): void {
    const current = AppStorage.get<string>('vpnConnectionState') ?? '';
    if (!isConnectionState(current)) {
      AppStorage.setOrCreate('vpnConnectionState', ConnectionState.IDLE);
    }
  }

  static current(): string {
    ConnectionStateManager.initialize();
    return AppStorage.get<string>('vpnConnectionState') ?? ConnectionState.IDLE;
  }

  static transition(next: string): void {
    if (!isConnectionState(next)) {
      return;
    }
    const current = ConnectionStateManager.current();
    if (current === next || ConnectionStateManager.canTransition(current, next)) {
      AppStorage.setOrCreate('vpnConnectionState', next);
    }
  }

  static canTransition(from: string, to: string): boolean {
    const allowed: Record<string, Array<string>> = {};
    allowed[ConnectionState.IDLE] = [ConnectionState.CONNECTING, ConnectionState.CONNECTED,
      ConnectionState.DISCONNECTING, ConnectionState.TESTING];
    allowed[ConnectionState.CONNECTING] = [ConnectionState.CONNECTED, ConnectionState.DISCONNECTING,
      ConnectionState.IDLE, ConnectionState.TESTING];
    allowed[ConnectionState.CONNECTED] = [ConnectionState.DISCONNECTING, ConnectionState.TESTING,
      ConnectionState.IDLE];
    allowed[ConnectionState.DISCONNECTING] = [ConnectionState.IDLE, ConnectionState.CONNECTING,
      ConnectionState.CONNECTED];
    allowed[ConnectionState.TESTING] = [ConnectionState.CONNECTED, ConnectionState.IDLE,
      ConnectionState.DISCONNECTING];
    const nextStates = allowed[from];
    return nextStates !== undefined && nextStates.includes(to);
  }

  /** 根据扩展事件文本同步状态，处理授权等待/切换等 running=false 中间态。 */
  static sync(status: string, running: boolean): void {
    if (running) {
      if (status.includes('切换')) {
        ConnectionStateManager.transition(ConnectionState.CONNECTING);
      } else {
        ConnectionStateManager.transition(ConnectionState.CONNECTED);
      }
      return;
    }
    // 失败/超时与“已断开”都是稳定的空闲终态，优先于“启动/建立”关键词判断。
    if (status.includes('失败') || status.includes('错误') || status.includes('超时')
      || status.includes('已断开') || status.includes('未连接')) {
      ConnectionStateManager.transition(ConnectionState.IDLE);
    } else if (status.includes('建立') || status.includes('授权') || status.includes('正在启动')) {
      ConnectionStateManager.transition(ConnectionState.CONNECTING);
    } else if (status.includes('正在断开') || status.includes('断开中') || status.includes('停止中')) {
      ConnectionStateManager.transition(ConnectionState.DISCONNECTING);
    } else {
      // 扩展完成 teardown 后会异步发布“已断开”；它必须是终态 IDLE，
      // 否则可能在 UI 服务已经置为 IDLE 后又被事件回调拉回黄色综合态。
      ConnectionStateManager.transition(ConnectionState.IDLE);
    }
  }

  static restoreRunningState(running: boolean): void {
    ConnectionStateManager.transition(running ? ConnectionState.CONNECTED : ConnectionState.IDLE);
  }
}
