//go:build windows

package usbip

import (
	"context"
	"time"

	"github.com/sagernet/sing-usbip/internal/vboxusb"
	"github.com/sagernet/sing-usbip/internal/wincfgmgr32"
	E "github.com/sagernet/sing/common/exceptions"
)

type windowsLocalDevice struct {
	stableID string
	entry    DeviceEntry
	busID    string

	monitor    *vboxusb.Monitor
	filterID   uint64
	hasFilter  bool
	ownCapture bool
	device     *vboxusb.Device
	engine     *vboxusbEngine
}

func windowsStableID(instanceID string) string {
	return "windows-instance:" + instanceID
}

func resolveWindowsLocalDevice(id string) (vboxusb.USBDeviceInfo, error) {
	devices, err := vboxusb.EnumerateUSBDevices()
	if err != nil {
		return vboxusb.USBDeviceInfo{}, err
	}
	for _, info := range devices {
		if info.BusID == id || windowsStableID(info.InstanceID) == id {
			return info, nil
		}
	}
	return vboxusb.USBDeviceInfo{}, E.New("windows local device not found: ", id)
}

func OpenLocalDevice(id string, capture bool) (LocalDevice, error) {
	err := vboxusb.EnableLoadDriverPrivilege()
	if err != nil {
		return nil, E.Cause(err, "enable SeLoadDriverPrivilege")
	}
	err = vboxusb.EnsureDrivers()
	if err != nil {
		return nil, E.Cause(err, "install VBoxUSB drivers")
	}
	info, err := resolveWindowsLocalDevice(id)
	if err != nil {
		return nil, err
	}
	if info.DeviceClass == 0x09 {
		return nil, E.New("refusing to open hub device ", info.BusID)
	}
	monitor, err := vboxusb.OpenMonitor()
	if err != nil {
		return nil, E.Cause(err, "open VBoxUSBMon")
	}
	major, _, err := monitor.GetVersion()
	if err != nil {
		_ = monitor.Close()
		return nil, E.Cause(err, "monitor GET_VERSION")
	}
	if major != vboxusb.DriverMajorVersion {
		_ = monitor.Close()
		return nil, E.New("VBoxUSBMon major version ", major, " (need ", vboxusb.DriverMajorVersion, ")")
	}

	local := &windowsLocalDevice{
		stableID: windowsStableID(info.InstanceID),
		entry:    windowsDeviceEntry(info),
		busID:    info.BusID,
		monitor:  monitor,
	}

	// VBoxUSB only serves a device that has been captured away from its
	// function driver; mirror windowsExportHost.captureDevice / addFilter.
	if info.Captured {
		filterID, filterErr := monitor.AddFilter(captureFilter(info))
		if filterErr != nil {
			local.cleanup()
			return nil, E.Cause(filterErr, "add VBoxUSBMon filter")
		}
		local.filterID = filterID
		local.hasFilter = true
	} else {
		if !capture {
			local.cleanup()
			return nil, E.New("windows local device ", info.BusID, " requires capture; pass capture=true")
		}
		restart, restartErr := vboxusb.BeginDeviceRestart(info.InstanceID, info.Address)
		if restartErr != nil {
			local.cleanup()
			return nil, E.Cause(restartErr, "begin device restart for capture")
		}
		filterID, filterErr := monitor.AddFilter(captureFilter(info))
		if filterErr != nil {
			restart.Finish()
			local.cleanup()
			return nil, E.Cause(filterErr, "add VBoxUSBMon filter")
		}
		local.filterID = filterID
		local.hasFilter = true
		local.ownCapture = true
		restart.Finish()
	}

	path, err := vboxusb.WaitForCapturedDevice(info.BusNumber, info.Address, 10*time.Second)
	if err != nil {
		local.cleanup()
		return nil, E.Cause(err, "locate VBoxUSB interface")
	}
	device, err := vboxusb.OpenDevice(path)
	if err != nil {
		local.cleanup()
		return nil, E.Cause(err, "open VBoxUSB device")
	}
	local.device = device
	deviceMajor, deviceMinor, err := device.GetVersion()
	if err != nil {
		local.cleanup()
		return nil, E.Cause(err, "device GET_VERSION")
	}
	if deviceMajor != vboxusb.DriverMajorVersion {
		local.cleanup()
		return nil, E.New("VBoxUSB major version ", deviceMajor, ".", deviceMinor, " (need ", vboxusb.DriverMajorVersion, ")")
	}
	claimed, err := device.Claim()
	if err != nil {
		local.cleanup()
		return nil, E.Cause(err, "claim device")
	}
	if !claimed {
		local.cleanup()
		return nil, E.New("device ", info.BusID, " is already claimed by another handle")
	}
	local.engine = newVBoxUSBEngine(device)
	return local, nil
}

func WatchLocalDevices(ctx context.Context, callback func()) error {
	onEvent := func(action uint32) { callback() }
	deviceNotification, err := wincfgmgr32.RegisterDeviceInterfaceNotification(vboxusb.USBDeviceInterfaceGUID, onEvent)
	if err != nil {
		return E.Cause(err, "register USB interface notification")
	}
	captureNotification, err := wincfgmgr32.RegisterDeviceInterfaceNotification(vboxusb.MonitorAccessGUID, onEvent)
	if err != nil {
		_ = deviceNotification.Close()
		return E.Cause(err, "register VBoxUSB interface notification")
	}
	go func() {
		<-ctx.Done()
		_ = deviceNotification.Close()
		_ = captureNotification.Close()
	}()
	return nil
}

func (d *windowsLocalDevice) StableID() string {
	return d.stableID
}

func (d *windowsLocalDevice) Entry() DeviceEntry {
	return d.entry
}

func (d *windowsLocalDevice) Submit(request URBRequest) URBResponse {
	return d.engine.Submit(request)
}

func (d *windowsLocalDevice) AbortEndpoint(endpoint uint8) error {
	return d.engine.AbortEndpoint(endpoint)
}

func (d *windowsLocalDevice) Close() error {
	d.cleanup()
	return nil
}

// cleanup closes the device and, when this handle originated the capture,
// restarts it so the original function driver re-binds. Mirrors
// windowsExportHost.releaseDevice; the post-capture instance ID is re-read
// because capture rewrites it to the VBox stub ID.
func (d *windowsLocalDevice) cleanup() {
	if d.engine != nil {
		_ = d.engine.Close()
		d.engine = nil
		d.device = nil
	} else if d.device != nil {
		_ = d.device.Close()
		d.device = nil
	}
	if d.monitor == nil {
		return
	}
	var restart *vboxusb.DeviceRestart
	if d.ownCapture {
		info, err := d.currentInfo()
		if err == nil {
			restart, _ = vboxusb.BeginDeviceRestart(info.InstanceID, info.Address)
		}
	}
	if d.hasFilter {
		_ = d.monitor.RemoveFilter(d.filterID)
		d.hasFilter = false
	}
	if restart != nil {
		restart.Finish()
	}
	_ = d.monitor.Close()
	d.monitor = nil
}

func (d *windowsLocalDevice) currentInfo() (vboxusb.USBDeviceInfo, error) {
	devices, err := vboxusb.EnumerateUSBDevices()
	if err != nil {
		return vboxusb.USBDeviceInfo{}, err
	}
	for _, info := range devices {
		if info.BusID == d.busID {
			return info, nil
		}
	}
	return vboxusb.USBDeviceInfo{}, E.New("device no longer present")
}
