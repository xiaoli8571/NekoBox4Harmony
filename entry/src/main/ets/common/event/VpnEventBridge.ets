/** common/event 统一暴露 VPN 跨进程事件，底层协议保持不变。 */
export {
  VPN_EVENT_LOG,
  VPN_EVENT_STATUS,
  publishVpnLog,
  publishVpnStatus,
  subscribeVpnEvents
} from '../../core/VpnIpc';
