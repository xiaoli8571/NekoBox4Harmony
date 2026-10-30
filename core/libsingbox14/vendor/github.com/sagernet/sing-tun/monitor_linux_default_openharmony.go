//go:build openharmony

package tun

// OHOS: 沙箱内 netlink.RouteListFiltered 不可用,默认接口探测直接"没有默认路由";
// 实际防回环由 sing-box 侧 route.default_interface(设置页实验项)负责。
func (m *defaultInterfaceMonitor) checkUpdate() error {
	return ErrNoRoute
}
