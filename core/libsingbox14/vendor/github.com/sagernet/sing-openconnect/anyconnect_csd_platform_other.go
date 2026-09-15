//go:build !linux && !android && !darwin && !freebsd

package openconnect

import "runtime"

type anyConnectHostScanPlatform struct {
	system  string
	release string
	machine string
}

func localAnyConnectHostScanPlatform() anyConnectHostScanPlatform {
	return anyConnectHostScanPlatform{system: runtime.GOOS, machine: runtime.GOARCH}
}
