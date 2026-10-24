//go:build openharmony

package tun

func (m *defaultInterfaceMonitor) checkUpdate() error {
	return ErrNoRoute
}
