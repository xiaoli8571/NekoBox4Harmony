/** UI 与 VPN 服务共享的统一连接状态。 */
export class ConnectionState {
  static readonly IDLE: string = 'IDLE';
  static readonly CONNECTING: string = 'CONNECTING';
  static readonly CONNECTED: string = 'CONNECTED';
  static readonly DISCONNECTING: string = 'DISCONNECTING';
  static readonly TESTING: string = 'TESTING';
}

export function isConnectionState(value: string): boolean {
  return value === ConnectionState.IDLE || value === ConnectionState.CONNECTING
    || value === ConnectionState.CONNECTED || value === ConnectionState.DISCONNECTING
    || value === ConnectionState.TESTING;
}
