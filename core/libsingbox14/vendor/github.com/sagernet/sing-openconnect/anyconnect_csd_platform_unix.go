//go:build linux || android || darwin || freebsd

package openconnect

import (
	"runtime"

	"golang.org/x/sys/unix"
)

type anyConnectHostScanPlatform struct {
	system  string
	release string
	machine string
}

func localAnyConnectHostScanPlatform() anyConnectHostScanPlatform {
	var name unix.Utsname
	err := unix.Uname(&name)
	if err != nil {
		return anyConnectHostScanPlatform{system: runtime.GOOS, machine: runtime.GOARCH}
	}
	platform := anyConnectHostScanPlatform{
		system:  anyConnectHostScanUnameString(name.Sysname[:]),
		release: anyConnectHostScanUnameString(name.Release[:]),
		machine: anyConnectHostScanUnameString(name.Machine[:]),
	}
	if platform.system == "" {
		platform.system = runtime.GOOS
	}
	if platform.machine == "" {
		platform.machine = runtime.GOARCH
	}
	return platform
}

func anyConnectHostScanUnameString(value []byte) string {
	for i, character := range value {
		if character == 0 {
			return string(value[:i])
		}
	}
	return string(value)
}
