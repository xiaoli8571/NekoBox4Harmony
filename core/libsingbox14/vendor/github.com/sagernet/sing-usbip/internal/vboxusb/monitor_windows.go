//go:build windows

package vboxusb

import (
	"encoding/binary"
	"errors"
	"sync"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/windows"
)

// The driver serializes filter mutations internally.
type Monitor struct {
	handle   windows.Handle
	closing  sync.Once
	closeErr error
}

func OpenMonitor() (*Monitor, error) {
	pathW, err := windows.UTF16PtrFromString(MonitorDevicePath)
	if err != nil {
		return nil, E.Cause(err, "vboxusb: utf16 monitor path")
	}
	handle, err := windows.CreateFile(
		pathW,
		windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_ATTRIBUTE_NORMAL|windows.FILE_FLAG_OVERLAPPED,
		0,
	)
	if err != nil {
		if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) {
			return nil, E.Cause(err, "vboxusb: open monitor (driver not loaded?)")
		}
		if errors.Is(err, windows.ERROR_ACCESS_DENIED) {
			return nil, E.Cause(err, "vboxusb: open monitor (administrator required)")
		}
		return nil, E.Cause(err, "vboxusb: open monitor")
	}
	return &Monitor{handle: handle}, nil
}

func (m *Monitor) Close() error {
	m.closing.Do(func() {
		if m.handle != 0 {
			m.closeErr = windows.CloseHandle(m.handle)
		}
	})
	return m.closeErr
}

func (m *Monitor) GetVersion() (uint32, uint32, error) {
	var buf [8]byte
	_, err := m.ioctl(IOCTLMonitorGetVersion, nil, buf[:])
	if err != nil {
		return 0, 0, E.Cause(err, "vboxusb: monitor GET_VERSION")
	}
	return binary.LittleEndian.Uint32(buf[0:4]), binary.LittleEndian.Uint32(buf[4:8]), nil
}

// A CAPTURE filter is permanent: every PnP arrival matching it is handed
// to VBoxUSB.sys until the filter is removed (or the monitor handle that
// owns it closes). usbipd-win uses the same permanent-filter pattern so
// capture survives transient PnP retries during RestartingDevice.
func (m *Monitor) AddFilter(filter Filter) (uint64, error) {
	in := encodeFilter(filter)
	var out [12]byte // UsbSupFltAddOut: uint64 uId + int32 rc
	_, err := m.ioctl(IOCTLMonitorAddFilter, in[:], out[:])
	if err != nil {
		return 0, E.Cause(err, "vboxusb: monitor ADD_FILTER")
	}
	id := binary.LittleEndian.Uint64(out[0:8])
	rc := int32(binary.LittleEndian.Uint32(out[8:12]))
	if rc < 0 {
		return 0, E.New("vboxusb: monitor ADD_FILTER returned rc=", rc)
	}
	return id, nil
}

// Safe to call after the device has already left.
func (m *Monitor) RemoveFilter(id uint64) error {
	var in [8]byte
	binary.LittleEndian.PutUint64(in[:], id)
	_, err := m.ioctl(IOCTLMonitorRemoveFilter, in[:], nil)
	if err != nil {
		return E.Cause(err, "vboxusb: monitor REMOVE_FILTER")
	}
	return nil
}

func (m *Monitor) ioctl(code uint32, in []byte, out []byte) (uint32, error) {
	return overlappedIoctl(m.handle, code, in, out)
}

// encodeFilter builds a 312-byte USBFILTER packed struct matching the
// layout in VirtualBox usbfilter.h (also documented in
// /tmp/usbipd-win/Usbipd/Interop/VBoxUsbMon.cs:77-105).
//
// Layout (offsets):
//
//	 0 u32Magic    uint32  (0x19670408)
//	 4 enmType     uint32  (4 = CAPTURE)
//	 8 aFields     [11]{enmMatch uint16, u16Value uint16}  (44 bytes)
//	52 offCurEnd   uint32  (0)
//	56 achStrTab   [256]byte  (0)
//
// All entries default to IGNORE; caller-specified fields are upgraded
// to NUM_EXACT with the supplied value. String matches and offCurEnd
// stay zero (we never use string filters; the driver rejects nonzero
// offCurEnd with strange offsets).
func encodeFilter(f Filter) [312]byte {
	const (
		filterMagic   uint32 = 0x19670408
		filterCapture uint32 = 4 // UsbFilterType.CAPTURE (5 is END, the enum sentinel)
		matchIgnore   uint16 = 1 // UsbFilterMatch.IGNORE
		matchNumExact uint16 = 3 // UsbFilterMatch.NUM_EXACT
	)
	const (
		idxVendorID       = 0
		idxProductID      = 1
		idxDeviceRev      = 2
		idxDeviceClass    = 3
		idxDeviceSubClass = 4
		idxDeviceProtocol = 5
		idxBus            = 6
		idxPort           = 7
	)
	var raw [312]byte
	binary.LittleEndian.PutUint32(raw[0:4], filterMagic)
	binary.LittleEndian.PutUint32(raw[4:8], filterCapture)
	for i := 0; i < 11; i++ {
		binary.LittleEndian.PutUint16(raw[8+i*4:8+i*4+2], matchIgnore)
	}
	setField := func(idx int, value uint16) {
		binary.LittleEndian.PutUint16(raw[8+idx*4:8+idx*4+2], matchNumExact)
		binary.LittleEndian.PutUint16(raw[8+idx*4+2:8+idx*4+4], value)
	}
	if f.VendorID != nil {
		setField(idxVendorID, *f.VendorID)
	}
	if f.ProductID != nil {
		setField(idxProductID, *f.ProductID)
	}
	if f.DeviceRev != nil {
		setField(idxDeviceRev, *f.DeviceRev)
	}
	if f.DeviceClass != nil {
		setField(idxDeviceClass, *f.DeviceClass)
	}
	if f.DeviceSubClass != nil {
		setField(idxDeviceSubClass, *f.DeviceSubClass)
	}
	if f.DeviceProtocol != nil {
		setField(idxDeviceProtocol, *f.DeviceProtocol)
	}
	if f.Bus != nil {
		setField(idxBus, *f.Bus)
	}
	if f.Port != nil {
		setField(idxPort, *f.Port)
	}
	return raw
}
