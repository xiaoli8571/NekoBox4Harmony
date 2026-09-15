//go:build windows

package vboxusb

import (
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/sagernet/sing-usbip/internal/wincfgmgr32"
	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/windows"
)

var MonitorAccessGUID = windows.GUID{
	Data1: 0x00873fdf,
	Data2: 0xCAFE,
	Data3: 0x80EE,
	Data4: [8]byte{0xaa, 0x5e, 0x00, 0xc0, 0x4f, 0xb1, 0x72, 0x0b},
}

var USBDeviceInterfaceGUID = windows.GUID{
	Data1: 0xa5dcbf10,
	Data2: 0x6530,
	Data3: 0x11d2,
	Data4: [8]byte{0x90, 0x1f, 0x00, 0xc0, 0x4f, 0xb9, 0x51, 0xed},
}

// vboxStubVendorID/vboxStubProductID are the IDs VBoxUSBMon rewrites a
// captured device's hardware ID to (so VBoxUSB.inf binds VBoxUSB.sys).
// Their presence marks a device currently owned by VBoxUSB; the true
// identity is then only available from the parent hub's descriptor.
const (
	vboxStubVendorID  uint16 = 0x80EE
	vboxStubProductID uint16 = 0xCAFE
)

// SPDRP_BUSNUMBER is always 0 for USB devices and SPDRP_ADDRESS is the
// port, unique only within one hub; they cannot form a unique key.
// The parent hub's cached device descriptor is stable across VBoxUSB
// capture, while the registry hardware ID reads as the VBox stub ID once
// captured.
type USBDeviceInfo struct {
	InstanceID        string
	HardwareID        string
	VendorID          uint16
	ProductID         uint16
	Revision          uint16
	BusNumber         uint32 // parent hub number (Hub_#NNNN)
	Address           uint32 // parent hub port number (Port_#NNNN)
	BusID             string
	DeviceClass       uint8
	DeviceSubClass    uint8
	DeviceProtocol    uint8
	DescriptorFromHub bool
	Speed             DeviceSpeed
	Captured          bool
	Product           string
}

var devpkeyDeviceBusReportedDeviceDesc = windows.DEVPROPKEY{
	FmtID: windows.DEVPROPGUID{
		Data1: 0x540b947e,
		Data2: 0x8b40,
		Data3: 0x45bc,
		Data4: [8]byte{0xa8, 0xa2, 0x6a, 0x0b, 0x89, 0x4c, 0xbd, 0xa2},
	},
	PID: 4,
}

func (i USBDeviceInfo) IdentityIsStub() bool {
	return i.VendorID == vboxStubVendorID && i.ProductID == vboxStubProductID
}

func EnumerateUSBDevices() ([]USBDeviceInfo, error) {
	guid := USBDeviceInterfaceGUID
	devInfo, err := windows.SetupDiGetClassDevsEx(
		&guid,
		"",
		0,
		windows.DIGCF_PRESENT|windows.DIGCF_DEVICEINTERFACE,
		0,
		"",
	)
	if err != nil {
		return nil, E.Cause(err, "vboxusb: SetupDiGetClassDevsEx")
	}
	defer devInfo.Close()

	probe := newHubSpeedProbe()
	defer probe.close()

	var out []USBDeviceInfo
	for i := 0; ; i++ {
		data, err := windows.SetupDiEnumDeviceInfo(devInfo, i)
		if err != nil {
			if errors.Is(err, windows.ERROR_NO_MORE_ITEMS) {
				break
			}
			return nil, E.Cause(err, "vboxusb: SetupDiEnumDeviceInfo[", i, "]")
		}
		info := USBDeviceInfo{}
		info.InstanceID, err = windows.SetupDiGetDeviceInstanceId(devInfo, data)
		if err != nil {
			continue
		}
		hardwareIDValue, err := windows.SetupDiGetDeviceRegistryProperty(devInfo, data, windows.SPDRP_HARDWAREID)
		if err == nil {
			info.HardwareID = firstString(hardwareIDValue)
			info.VendorID, info.ProductID, info.Revision = parseHardwareID(info.HardwareID)
		}
		productValue, err := windows.SetupDiGetDeviceProperty(devInfo, data, &devpkeyDeviceBusReportedDeviceDesc)
		if err == nil {
			product, ok := productValue.(string)
			if ok {
				info.Product = product
			}
		}
		locationValue, err := windows.SetupDiGetDeviceRegistryProperty(devInfo, data, windows.SPDRP_LOCATION_INFORMATION)
		if err != nil {
			continue
		}
		hubNumber, portNumber, located := parseLocationInfo(firstString(locationValue))
		if !located {
			// Root hubs and devices on unsupported hub types carry no
			// Port_#/Hub_# location; they cannot be captured anyway
			// (usbipd-win marks them IncompatibleHub).
			continue
		}
		info.BusNumber = hubNumber
		info.Address = portNumber
		info.BusID = strconv.FormatUint(uint64(info.BusNumber), 10) + "-" + strconv.FormatUint(uint64(info.Address), 10)
		info.Captured = info.VendorID == vboxStubVendorID && info.ProductID == vboxStubProductID
		descriptor, speed := probe.describe(devInfo, data, info.Address)
		info.Speed = speed
		if descriptor != nil {
			info.VendorID = descriptor.vendorID
			info.ProductID = descriptor.productID
			info.Revision = descriptor.bcdDevice
			info.DeviceClass = descriptor.deviceClass
			info.DeviceSubClass = descriptor.deviceSubClass
			info.DeviceProtocol = descriptor.deviceProtocol
			info.DescriptorFromHub = true
		}
		out = append(out, info)
	}
	return out, nil
}

// Capture changes the device's instance ID (VBoxUSBMon rewrites it to
// the stub ID), so the location information — maintained by the parent
// hub driver and therefore stable across the rewrite — is the only
// reliable key.
func WaitForCapturedDevice(busNumber, address uint32, timeout time.Duration) (string, error) {
	arrival := make(chan struct{}, 1)
	notification, err := wincfgmgr32.RegisterDeviceInterfaceNotification(MonitorAccessGUID, func(action uint32) {
		if action != wincfgmgr32.CM_NOTIFY_ACTION_DEVICEINTERFACEARRIVAL {
			return
		}
		select {
		case arrival <- struct{}{}:
		default:
		}
	})
	if err != nil {
		return "", E.Cause(err, "vboxusb: register VBoxUSB interface notification")
	}
	defer notification.Close()
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	for {
		path, probeErr := findCapturedDevice(busNumber, address)
		if probeErr == nil {
			return path, nil
		}
		select {
		case <-arrival:
		case <-deadline.C:
			return "", E.Cause(probeErr, "vboxusb: VBoxUSB interface for ", busNumber, "-", address, " did not appear within ", timeout)
		}
	}
}

func findCapturedDevice(busNumber, address uint32) (string, error) {
	guid := MonitorAccessGUID
	devInfo, err := windows.SetupDiGetClassDevsEx(
		&guid,
		"",
		0,
		windows.DIGCF_PRESENT|windows.DIGCF_DEVICEINTERFACE,
		0,
		"",
	)
	if err != nil {
		return "", E.Cause(err, "vboxusb: SetupDiGetClassDevsEx(VBoxUSB)")
	}
	defer devInfo.Close()
	for i := 0; ; i++ {
		data, err := windows.SetupDiEnumDeviceInfo(devInfo, i)
		if err != nil {
			if errors.Is(err, windows.ERROR_NO_MORE_ITEMS) {
				return "", E.New("vboxusb: no captured device at ", busNumber, "-", address)
			}
			return "", E.Cause(err, "vboxusb: SetupDiEnumDeviceInfo[", i, "]")
		}
		locationValue, err := windows.SetupDiGetDeviceRegistryProperty(devInfo, data, windows.SPDRP_LOCATION_INFORMATION)
		if err != nil {
			continue
		}
		hubNumber, portNumber, located := parseLocationInfo(firstString(locationValue))
		if !located || hubNumber != busNumber || portNumber != address {
			continue
		}
		instanceID, err := windows.SetupDiGetDeviceInstanceId(devInfo, data)
		if err != nil {
			continue
		}
		paths, err := windows.CM_Get_Device_Interface_List(instanceID, &guid, windows.CM_GET_DEVICE_INTERFACE_LIST_PRESENT)
		if err != nil {
			continue
		}
		for _, p := range paths {
			if p != "" {
				return p, nil
			}
		}
	}
}

func firstString(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case []string:
		if len(v) > 0 {
			return v[0]
		}
	}
	return ""
}

// SPDRP_LOCATION_INFORMATION format: "Port_#0002.Hub_#0003".
func parseLocationInfo(location string) (hub, port uint32, ok bool) {
	upper := strings.ToUpper(location)
	port, portFound := extractDecimal(upper, "PORT_#")
	hub, hubFound := extractDecimal(upper, "HUB_#")
	if !portFound || !hubFound || port == 0 || hub == 0 {
		return 0, 0, false
	}
	return hub, port, true
}

func extractDecimal(s, prefix string) (uint32, bool) {
	idx := strings.Index(s, prefix)
	if idx < 0 {
		return 0, false
	}
	tail := s[idx+len(prefix):]
	end := 0
	for end < len(tail) && tail[end] >= '0' && tail[end] <= '9' {
		end++
	}
	if end == 0 {
		return 0, false
	}
	value, err := strconv.ParseUint(tail[:end], 10, 32)
	if err != nil {
		return 0, false
	}
	return uint32(value), true
}

func parseHardwareID(hwid string) (vid, pid, rev uint16) {
	upper := strings.ToUpper(hwid)
	vid = extractHex16(upper, "VID_")
	pid = extractHex16(upper, "PID_")
	rev = extractHex16(upper, "REV_")
	return
}

func extractHex16(s, prefix string) uint16 {
	idx := strings.Index(s, prefix)
	if idx < 0 {
		return 0
	}
	tail := s[idx+len(prefix):]
	end := len(tail)
	for i, r := range tail {
		if !isHex(r) {
			end = i
			break
		}
	}
	if end == 0 {
		return 0
	}
	v, err := strconv.ParseUint(tail[:end], 16, 16)
	if err != nil {
		return 0
	}
	return uint16(v)
}

func isHex(r rune) bool {
	return (r >= '0' && r <= '9') || (r >= 'A' && r <= 'F') || (r >= 'a' && r <= 'f')
}
