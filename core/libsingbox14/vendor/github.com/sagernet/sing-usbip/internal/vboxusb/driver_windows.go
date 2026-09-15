//go:build windows

package vboxusb

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"unsafe"

	"github.com/sagernet/sing-usbip/driverassets"
	"github.com/sagernet/sing-usbip/internal/winsetupapi"
	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/windows"
)

func EnsureDrivers() error {
	driverOnce.Do(func() {
		driverErr = installDrivers()
	})
	return driverErr
}

var (
	driverOnce sync.Once
	driverErr  error
)

func installDrivers() error {
	dir, err := ensureExtracted()
	if err != nil {
		return err
	}

	mutexName, _ := windows.UTF16PtrFromString("Global\\SingBoxVBoxUSBInstallMutex")
	mutex, err := windows.CreateMutex(nil, false, mutexName)
	if err != nil {
		return E.Cause(err, "vboxusb: create install mutex")
	}
	defer windows.CloseHandle(mutex)
	_, err = windows.WaitForSingleObject(mutex, windows.INFINITE)
	if err != nil {
		return E.Cause(err, "vboxusb: wait install mutex")
	}
	defer windows.ReleaseMutex(mutex)

	err = installMonitorService(dir)
	if err != nil {
		return err
	}
	err = installVBoxUSBInf(dir)
	if err != nil {
		return err
	}
	return nil
}

func installMonitorService(dir string) error {
	sysPath := filepath.Join(dir, "VBoxUSBMon.sys")
	sysPathW, err := windows.UTF16PtrFromString(sysPath)
	if err != nil {
		return E.Cause(err, "vboxusb: utf16 monitor path")
	}

	manager, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_ALL_ACCESS)
	if err != nil {
		return E.Cause(err, "vboxusb: open SCM")
	}
	defer windows.CloseServiceHandle(manager)

	serviceNameW, _ := windows.UTF16PtrFromString(MonitorServiceName)
	service, err := windows.OpenService(manager, serviceNameW, windows.SERVICE_ALL_ACCESS)
	if err == nil {
		err = updateMonitorImagePath(service, sysPath, sysPathW)
		if err != nil {
			windows.CloseServiceHandle(service)
			return err
		}
	} else {
		service, err = windows.CreateService(
			manager,
			serviceNameW,
			serviceNameW,
			windows.SERVICE_ALL_ACCESS,
			windows.SERVICE_KERNEL_DRIVER,
			windows.SERVICE_DEMAND_START,
			windows.SERVICE_ERROR_NORMAL,
			sysPathW,
			nil, nil, nil, nil, nil,
		)
		if err != nil {
			if errors.Is(err, windows.ERROR_SERVICE_EXISTS) {
				service, err = windows.OpenService(manager, serviceNameW, windows.SERVICE_ALL_ACCESS)
			}
			if err != nil {
				return wrapInstallError(err)
			}
		}
	}
	defer windows.CloseServiceHandle(service)

	err = windows.StartService(service, 0, nil)
	if err != nil && errors.Is(err, windows.ERROR_SERVICE_DISABLED) {
		err = windows.ChangeServiceConfig(
			service,
			windows.SERVICE_NO_CHANGE,
			windows.SERVICE_DEMAND_START,
			windows.SERVICE_NO_CHANGE,
			nil, nil, nil, nil, nil, nil, nil,
		)
		if err != nil {
			return E.Cause(err, "vboxusb: re-enable disabled monitor service")
		}
		err = windows.StartService(service, 0, nil)
	}
	if err != nil && !errors.Is(err, windows.ERROR_SERVICE_ALREADY_RUNNING) {
		return E.Cause(err, "vboxusb: start monitor service")
	}
	return nil
}

func updateMonitorImagePath(service windows.Handle, sysPath string, sysPathW *uint16) error {
	var bytesNeeded uint32
	err := windows.QueryServiceConfig(service, nil, 0, &bytesNeeded)
	if err != nil && !errors.Is(err, windows.ERROR_INSUFFICIENT_BUFFER) {
		return E.Cause(err, "vboxusb: query monitor service config size")
	}
	buffer := make([]byte, bytesNeeded)
	config := (*windows.QUERY_SERVICE_CONFIG)(unsafe.Pointer(&buffer[0]))
	err = windows.QueryServiceConfig(service, config, uint32(len(buffer)), &bytesNeeded)
	if err != nil {
		return E.Cause(err, "vboxusb: query monitor service config")
	}
	currentPath := windows.UTF16PtrToString(config.BinaryPathName)
	if strings.EqualFold(strings.Trim(currentPath, `"`), sysPath) {
		return nil
	}
	if !strings.Contains(strings.ToLower(currentPath), `\sing-usbip\vboxusb\`) {
		return nil
	}
	err = windows.ChangeServiceConfig(
		service,
		windows.SERVICE_NO_CHANGE,
		windows.SERVICE_NO_CHANGE,
		windows.SERVICE_NO_CHANGE,
		sysPathW,
		nil, nil, nil, nil, nil, nil,
	)
	if err != nil {
		return E.Cause(err, "vboxusb: update monitor service image path")
	}
	return nil
}

func wrapInstallError(err error) error {
	if errors.Is(err, windows.ERROR_ACCESS_DENIED) {
		return E.Cause(err, "vboxusb: installing the kernel driver requires Administrator privileges")
	}
	return E.Cause(err, "vboxusb: create monitor service")
}

func installVBoxUSBInf(dir string) error {
	infPath := filepath.Join(dir, "VBoxUSB.inf")
	infPathW, err := windows.UTF16PtrFromString(infPath)
	if err != nil {
		return E.Cause(err, "vboxusb: utf16 inf path")
	}
	dirW, err := windows.UTF16PtrFromString(dir)
	if err != nil {
		return E.Cause(err, "vboxusb: utf16 inf dir")
	}
	const (
		spostPath     = 1 // SPOST_PATH
		spCopyNoStyle = 0
	)
	ret, _, callErr := procSetupCopyOEMInfW.Call(
		uintptr(unsafe.Pointer(infPathW)),
		uintptr(unsafe.Pointer(dirW)),
		uintptr(spostPath),
		uintptr(spCopyNoStyle),
		0, 0, 0, 0,
	)
	if ret == 0 {
		if errors.Is(callErr, windows.ERROR_FILE_EXISTS) {
			// Already present in driver store; not an error.
			return nil
		}
		return winsetupapi.Cause(callErr, "vboxusb: SetupCopyOEMInfW")
	}
	return nil
}

var (
	modSetupAPI          = windows.NewLazyDLL("setupapi.dll")
	procSetupCopyOEMInfW = modSetupAPI.NewProc("SetupCopyOEMInfW")
)

type assetFile struct {
	name string
	data []byte
}

var (
	extractOnce sync.Once
	extractErr  error
	extractDir  string
)

// The on-disk copy is protected by Authenticode signature enforcement
// at SCM StartService time; any tampering with the .sys is rejected
// by the kernel loader before we ever see it.
func ensureExtracted() (string, error) {
	extractOnce.Do(func() {
		extractDir, extractErr = extractImpl()
	})
	return extractDir, extractErr
}

func extractImpl() (string, error) {
	files, err := assetFiles()
	if err != nil {
		return "", err
	}
	if len(files) == 0 {
		return "", E.New("vboxusb: unsupported architecture ", runtime.GOARCH)
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", E.Cause(err, "vboxusb: locate user cache dir")
	}
	dir := filepath.Join(base, "sing-usbip", "vboxusb", "v"+driverassets.VBoxUSB[runtime.GOARCH].Version)
	err = os.MkdirAll(dir, 0o755)
	if err != nil {
		return "", E.Cause(err, "vboxusb: mkdir ", dir)
	}
	for _, asset := range files {
		err = ensureAsset(dir, asset)
		if err != nil {
			return "", err
		}
	}
	return dir, nil
}

func ensureAsset(dir string, asset assetFile) error {
	target := filepath.Join(dir, asset.name)
	existing, err := os.ReadFile(target)
	if err == nil {
		if bytes.Equal(existing, asset.data) {
			return nil
		}
	} else if !os.IsNotExist(err) {
		return E.Cause(err, "vboxusb: read ", asset.name)
	}
	tmp := target + ".tmp-" + strconv.Itoa(os.Getpid())
	file, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return E.Cause(err, "vboxusb: create ", asset.name)
	}
	_, err = file.Write(asset.data)
	err = E.Errors(err, file.Sync(), file.Close())
	if err != nil {
		os.Remove(tmp)
		return E.Cause(err, "vboxusb: write ", asset.name)
	}
	err = os.Rename(tmp, target)
	if err != nil {
		os.Remove(tmp)
		current, readErr := os.ReadFile(target)
		if readErr == nil && bytes.Equal(current, asset.data) {
			return nil
		}
		return E.Cause(err, "vboxusb: replace ", asset.name)
	}
	return nil
}
