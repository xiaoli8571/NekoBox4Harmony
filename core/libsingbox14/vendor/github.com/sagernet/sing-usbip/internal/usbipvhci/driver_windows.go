//go:build windows

package usbipvhci

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"time"
	"unsafe"

	"github.com/sagernet/sing-usbip/driverassets"
	"github.com/sagernet/sing-usbip/internal/winsetupapi"
	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/windows"
)

// GUID_DEVCLASS_USB (devguid.h), matching usbip2_ude.inf Class=USB.
var classGUIDDevClassUSB = windows.GUID{
	Data1: 0x36fc9e60,
	Data2: 0xc465,
	Data3: 0x11cf,
	Data4: [8]byte{0x80, 0x56, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00},
}

func EnsureDriver() error {
	driverOnce.Do(func() {
		driverErr = installDriver()
	})
	return driverErr
}

var (
	driverOnce sync.Once
	driverErr  error
)

func installDriver() error {
	err := probeDriver()
	if err == nil {
		return nil
	}

	dir, err := ensureExtracted()
	if err != nil {
		return err
	}

	mutexName, _ := windows.UTF16PtrFromString(`Global\SingBoxUSBIPVHCIInstallMutex`)
	mutex, err := windows.CreateMutex(nil, false, mutexName)
	if err != nil {
		return E.Cause(err, "usbipvhci: create install mutex")
	}
	defer windows.CloseHandle(mutex)
	_, err = windows.WaitForSingleObject(mutex, windows.INFINITE)
	if err != nil {
		return E.Cause(err, "usbipvhci: wait install mutex")
	}
	defer windows.ReleaseMutex(mutex)

	err = probeDriver()
	if err == nil {
		return nil
	}

	// The upper filter is an extension INF: copying it into the driver
	// store is enough; PnP applies it once the VHCI root hub appears.
	err = addToDriverStore(filepath.Join(dir, "usbip2_filter.inf"))
	if err != nil {
		return E.Cause(err, "usbipvhci: register upper-filter driver")
	}
	err = createDevnodeAndInstall(filepath.Join(dir, "usbip2_ude.inf"))
	if err != nil {
		return E.Cause(err, "usbipvhci: create VHCI devnode")
	}
	return waitForInterface(20 * time.Second)
}

// The interface GUID is identical across all usbip-win2 releases, while
// PLUGIN_HARDWARE_ONCE and STOP_ATTACH_ATTEMPTS only exist since 0.9.7.5 — an
// installed community release older than that opens fine and then fails every
// Plugin. The empty location passed to StopAttachAttempts means "cancel all
// scheduled attach attempts".
func probeDriver() error {
	controller, err := Open()
	if err != nil {
		return err
	}
	defer controller.Close()
	_, err = controller.StopAttachAttempts("", "", "")
	if err != nil {
		return E.Cause(err, "usbipvhci: installed driver lacks STOP_ATTACH_ATTEMPTS (older than 0.9.7.5); upgrading")
	}
	return nil
}

// SetupCopyOEMInfW rejects unsigned or tampered packages; ERROR_FILE_EXISTS
// means the package is already present.
func addToDriverStore(infPath string) error {
	infW, err := windows.UTF16PtrFromString(infPath)
	if err != nil {
		return E.Cause(err, "usbipvhci: utf16 inf path")
	}
	dirW, err := windows.UTF16PtrFromString(filepath.Dir(infPath))
	if err != nil {
		return E.Cause(err, "usbipvhci: utf16 inf dir")
	}
	const spostPath = 1
	ret, _, callErr := procSetupCopyOEMInfW.Call(
		uintptr(unsafe.Pointer(infW)),
		uintptr(unsafe.Pointer(dirW)),
		uintptr(spostPath),
		0, 0, 0, 0, 0,
	)
	if ret == 0 && !errors.Is(callErr, windows.ERROR_FILE_EXISTS) {
		if errors.Is(callErr, windows.ERROR_ACCESS_DENIED) {
			return E.Cause(callErr, "SetupCopyOEMInfW (Administrator required)")
		}
		return winsetupapi.Cause(callErr, "SetupCopyOEMInfW")
	}
	return nil
}

func createDevnodeAndInstall(infPath string) error {
	err := updateDriverForPlugAndPlayDevices(udeHardwareID, infPath)
	if err == nil {
		return nil
	}

	devInfoSet, err := windows.SetupDiCreateDeviceInfoListEx(&classGUIDDevClassUSB, 0, "")
	if err != nil {
		return winsetupapi.Cause(err, "SetupDiCreateDeviceInfoListEx")
	}
	defer devInfoSet.Close()

	devInfoData, err := windows.SetupDiCreateDeviceInfo(devInfoSet, "USB", &classGUIDDevClassUSB, "", 0, windows.DICD_GENERATE_ID)
	if err != nil {
		return winsetupapi.Cause(err, "SetupDiCreateDeviceInfo")
	}

	err = windows.SetupDiSetDeviceRegistryProperty(devInfoSet, devInfoData, windows.SPDRP_HARDWAREID, multiSzUTF16(udeHardwareID))
	if err != nil {
		return winsetupapi.Cause(err, "SetupDiSetDeviceRegistryProperty")
	}
	err = windows.SetupDiCallClassInstaller(windows.DIF_REGISTERDEVICE, devInfoSet, devInfoData)
	if err != nil {
		return winsetupapi.Cause(err, "SetupDiCallClassInstaller(DIF_REGISTERDEVICE)")
	}
	return updateDriverForPlugAndPlayDevices(udeHardwareID, infPath)
}

// INSTALLFLAG_FORCE installs even when the bundled driver is not strictly
// newer.
func updateDriverForPlugAndPlayDevices(hardwareID, infPath string) error {
	hardwareIDW, err := windows.UTF16PtrFromString(hardwareID)
	if err != nil {
		return E.Cause(err, "usbipvhci: utf16 hardware id")
	}
	infW, err := windows.UTF16PtrFromString(infPath)
	if err != nil {
		return E.Cause(err, "usbipvhci: utf16 inf path")
	}
	const installFlagForce = 0x00000001
	var rebootRequired int32
	ret, _, callErr := procUpdateDriverForPlugAndPlayDevicesW.Call(
		0,
		uintptr(unsafe.Pointer(hardwareIDW)),
		uintptr(unsafe.Pointer(infW)),
		uintptr(installFlagForce),
		uintptr(unsafe.Pointer(&rebootRequired)),
	)
	if ret == 0 {
		return winsetupapi.Cause(callErr, "UpdateDriverForPlugAndPlayDevices")
	}
	return nil
}

func waitForInterface(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		err := probeDriver()
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return E.Cause(err, "usbipvhci: VHCI interface did not appear after install (the devnode may have failed to start; check Device Manager)")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func multiSzUTF16(s string) []byte {
	u16, err := windows.UTF16FromString(s)
	if err != nil {
		return nil
	}
	u16 = append(u16, 0)
	buf := make([]byte, len(u16)*2)
	for i, v := range u16 {
		binary.LittleEndian.PutUint16(buf[i*2:], v)
	}
	return buf
}

var (
	extractOnce sync.Once
	extractErr  error
	extractDir  string
)

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
		return "", E.New("usbipvhci: no bundled driver for ", runtime.GOARCH)
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", E.Cause(err, "usbipvhci: locate user cache dir")
	}
	dir := filepath.Join(base, "sing-usbip", "usbipvhci", "v"+driverassets.VHCI[runtime.GOARCH].Version)
	err = os.MkdirAll(dir, 0o755)
	if err != nil {
		return "", E.Cause(err, "usbipvhci: mkdir ", dir)
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
		return E.Cause(err, "usbipvhci: read ", asset.name)
	}
	tmp := target + ".tmp-" + strconv.Itoa(os.Getpid())
	file, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return E.Cause(err, "usbipvhci: create ", asset.name)
	}
	_, err = file.Write(asset.data)
	err = E.Errors(err, file.Sync(), file.Close())
	if err != nil {
		os.Remove(tmp)
		return E.Cause(err, "usbipvhci: write ", asset.name)
	}
	err = os.Rename(tmp, target)
	if err != nil {
		os.Remove(tmp)
		current, readErr := os.ReadFile(target)
		if readErr == nil && bytes.Equal(current, asset.data) {
			return nil
		}
		return E.Cause(err, "usbipvhci: replace ", asset.name)
	}
	return nil
}

var (
	modSetupAPI          = windows.NewLazyDLL("setupapi.dll")
	procSetupCopyOEMInfW = modSetupAPI.NewProc("SetupCopyOEMInfW")

	modNewDev                              = windows.NewLazyDLL("newdev.dll")
	procUpdateDriverForPlugAndPlayDevicesW = modNewDev.NewProc("UpdateDriverForPlugAndPlayDevicesW")
)
