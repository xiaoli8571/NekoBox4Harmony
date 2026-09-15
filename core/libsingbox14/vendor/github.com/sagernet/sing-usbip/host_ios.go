//go:build ios && cgo

package usbip

// usbhost_darwin.m is selected for iOS by its _darwin filename suffix even
// though everything it implements is gated behind TARGET_OS_OSX and compiles to
// an empty translation unit there. The Go tool rejects a package that ships an
// Objective-C file while "not using cgo", so this import keeps cgo active.

import "C"

import (
	"context"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
)

func newPlatformExportHost(_ context.Context, _ logger.ContextLogger, _ []DeviceMatch) (ExportHost, error) {
	return nil, E.New("usbip host backend is only available on macOS")
}

func newPlatformImportHost(_ logger.ContextLogger) (ImportHost, error) {
	return nil, E.New("usbip host backend is only available on macOS")
}

func OpenLocalDevice(_ string, _ bool) (LocalDevice, error) {
	return nil, E.New("local usb devices are only available on macOS")
}

func WatchLocalDevices(_ context.Context, _ func()) error {
	return E.New("local usb devices are only available on macOS")
}

func ListLocalDevices() ([]LocalDeviceInfo, error) {
	return nil, E.New("local usb devices are only available on macOS")
}
