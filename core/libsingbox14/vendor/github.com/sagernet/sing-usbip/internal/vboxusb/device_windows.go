//go:build windows

package vboxusb

import (
	"encoding/binary"
	"errors"
	"runtime"
	"sync"
	"unsafe"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/windows"
)

type Device struct {
	handle   windows.Handle
	closing  sync.Once
	closeErr error
}

func OpenDevice(interfacePath string) (*Device, error) {
	pathW, err := windows.UTF16PtrFromString(interfacePath)
	if err != nil {
		return nil, E.Cause(err, "vboxusb: utf16 device path")
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
		return nil, E.Cause(err, "vboxusb: open ", interfacePath)
	}
	_ = windows.SetFileCompletionNotificationModes(handle, windows.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS)
	return &Device{handle: handle}, nil
}

func (d *Device) Close() error {
	d.closing.Do(func() {
		if d.handle != 0 {
			d.closeErr = windows.CloseHandle(d.handle)
		}
	})
	return d.closeErr
}

func (d *Device) GetVersion() (uint32, uint32, error) {
	var buf [8]byte
	_, err := d.ioctl(IOCTLGetVersion, nil, buf[:])
	if err != nil {
		return 0, 0, E.Cause(err, "vboxusb: GET_VERSION")
	}
	return binary.LittleEndian.Uint32(buf[0:4]), binary.LittleEndian.Uint32(buf[4:8]), nil
}

// Claim acquires exclusive ownership of the device. The driver returns
// Claimed=false if another handle owns the device. The input field is
// unused by the driver but the buffer must equal the output size, so
// pass a zero-initialized 2-byte input.
func (d *Device) Claim() (bool, error) {
	var in [2]byte
	var out [2]byte
	_, err := d.ioctl(IOCTLUSBClaimDevice, in[:], out[:])
	if err != nil {
		return false, E.Cause(err, "vboxusb: USB_CLAIM_DEVICE")
	}
	return out[1] != 0, nil
}

// SetConfig issues USBSUP_IOCTL_USB_SET_CONFIG so VBoxUSB rebuilds its
// pipe-handle table for the requested bConfigurationValue. Must be
// awaited before any URBs targeting endpoints in the new configuration.
func (d *Device) SetConfig(value byte) error {
	in := [1]byte{value}
	_, err := d.ioctl(IOCTLUSBSetConfig, in[:], nil)
	if err != nil {
		return E.Cause(err, "vboxusb: USB_SET_CONFIG")
	}
	return nil
}

// SelectInterface issues USBSUP_IOCTL_USB_SELECT_INTERFACE. Same
// pipe-handle implications as SetConfig.
func (d *Device) SelectInterface(num, alt byte) error {
	in := [2]byte{num, alt}
	_, err := d.ioctl(IOCTLUSBSelectInterface, in[:], nil)
	if err != nil {
		return E.Cause(err, "vboxusb: USB_SELECT_INTERFACE")
	}
	return nil
}

// ClearEndpoint clears the STALL condition on a halted endpoint. The
// argument is the raw 8-bit address (direction bit in MSB).
func (d *Device) ClearEndpoint(rawEndpoint byte) error {
	in := [1]byte{rawEndpoint}
	_, err := d.ioctl(IOCTLUSBClearEndpoint, in[:], nil)
	if err != nil {
		return E.Cause(err, "vboxusb: USB_CLEAR_ENDPOINT")
	}
	return nil
}

// VBoxUSB has no per-URB cancel; callers must use the abort-holdoff
// heuristic to avoid aborting URBs that completed in the race window.
func (d *Device) AbortEndpoint(rawEndpoint byte) error {
	in := [1]byte{rawEndpoint}
	_, err := d.ioctl(IOCTLUSBAbortEndpoint, in[:], nil)
	if err != nil {
		return E.Cause(err, "vboxusb: USB_ABORT_ENDPOINT")
	}
	return nil
}

type URB struct {
	Type       TransferType
	Endpoint   uint32 // 4-bit endpoint index, no direction bit
	Direction  Direction
	Flags      TransferFlags
	Length     uint64
	Buffer     []byte
	IsoPackets []IsoPacket
}

// IsoPacket is one USBSUP_ISOCPKT entry. Length is in/out (requested
// then actual); Offset is in-only; Status is out-only.
type IsoPacket struct {
	Length uint16
	Offset uint16
	Status URBError
}

// urbStructSize is the on-the-wire size of USBSUP_URB with Pack=4 on
// 64-bit systems (both amd64 and arm64; nint is 8 bytes either way).
// Layout (offsets in bytes):
//
//	 0  type        uint32
//	 4  ep          uint32
//	 8  dir         uint32
//	12  flags       uint32
//	16  error       uint32
//	20  len         uint64
//	28  buf         uint64 (native pointer)
//	36  numIsoPkts  uint32
//	40  aIsoPkts    [8]uint64  (each entry is cb(u16) off(u16) stat(u32) = 8 bytes)
//
// Total = 104.
const urbStructSize = 104

func (d *Device) SendURB(urb *URB) error {
	var raw [urbStructSize]byte
	binary.LittleEndian.PutUint32(raw[0:4], uint32(urb.Type))
	binary.LittleEndian.PutUint32(raw[4:8], urb.Endpoint)
	binary.LittleEndian.PutUint32(raw[8:12], uint32(urb.Direction))
	binary.LittleEndian.PutUint32(raw[12:16], uint32(urb.Flags))
	// raw[16:20] error is filled by the driver
	binary.LittleEndian.PutUint64(raw[20:28], urb.Length)
	var bufPtr uintptr
	if len(urb.Buffer) > 0 {
		bufPtr = uintptr(unsafe.Pointer(&urb.Buffer[0]))
	}
	binary.LittleEndian.PutUint64(raw[28:36], uint64(bufPtr))
	binary.LittleEndian.PutUint32(raw[36:40], uint32(len(urb.IsoPackets)))
	for i, iso := range urb.IsoPackets {
		base := 40 + i*8
		binary.LittleEndian.PutUint16(raw[base:base+2], iso.Length)
		binary.LittleEndian.PutUint16(raw[base+2:base+4], iso.Offset)
		binary.LittleEndian.PutUint32(raw[base+4:base+8], uint32(iso.Status))
	}
	_, err := d.ioctl(IOCTLSendURB, raw[:], raw[:])
	runtime.KeepAlive(urb.Buffer)
	if err != nil {
		return E.Cause(err, "vboxusb: SEND_URB")
	}
	urb.Length = binary.LittleEndian.Uint64(raw[20:28])
	errCode := URBError(binary.LittleEndian.Uint32(raw[16:20]))
	for i := range urb.IsoPackets {
		base := 40 + i*8
		urb.IsoPackets[i].Length = binary.LittleEndian.Uint16(raw[base : base+2])
		urb.IsoPackets[i].Offset = binary.LittleEndian.Uint16(raw[base+2 : base+4])
		urb.IsoPackets[i].Status = URBError(binary.LittleEndian.Uint32(raw[base+4 : base+8]))
	}
	if errCode != URBOK {
		return &URBStatusError{Code: errCode}
	}
	return nil
}

type URBStatusError struct {
	Code URBError
}

func (e *URBStatusError) Error() string {
	switch e.Code {
	case URBStall:
		return "vboxusb: URB stalled"
	case URBDeviceNotResponding:
		return "vboxusb: device not responding"
	case URBCRCError:
		return "vboxusb: CRC error"
	case URBNACError:
		return "vboxusb: NAC error"
	case URBUnderrun:
		return "vboxusb: data underrun"
	case URBOverrun:
		return "vboxusb: data overrun"
	default:
		return "vboxusb: unknown URB error"
	}
}

func (d *Device) ioctl(code uint32, in []byte, out []byte) (uint32, error) {
	return overlappedIoctl(d.handle, code, in, out)
}

// overlappedOp owns the memory the kernel keeps raw pointers into for
// one pending DeviceIoControl: the OVERLAPPED (whose IOSB is written at
// completion) and copies of the METHOD_BUFFERED in/out buffers. It must
// live on the non-moving heap: after ERROR_IO_PENDING the goroutine
// keeps executing Go code, and a stack grow/shrink would move
// stack-resident buffers out from under the kernel's captured
// addresses. Go only pins syscall arguments for the syscall's duration.
type overlappedOp struct {
	overlapped windows.Overlapped
	in         []byte
	out        []byte
}

//go:noinline
func newOverlappedOp(inLen, outLen int) *overlappedOp {
	op := new(overlappedOp)
	if inLen > 0 {
		op.in = make([]byte, inLen)
	}
	if outLen > 0 {
		op.out = make([]byte, outLen)
	}
	return op
}

// Sharing one event across simultaneously pending IOCTLs is forbidden by
// the overlapped-I/O contract: the first completion would release every
// waiter with the first operation's results.
func overlappedIoctl(handle windows.Handle, code uint32, in []byte, out []byte) (uint32, error) {
	event, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		return 0, err
	}
	defer windows.CloseHandle(event)
	op := newOverlappedOp(len(in), len(out))
	op.overlapped.HEvent = event
	copy(op.in, in)
	var inPtr *byte
	if len(op.in) > 0 {
		inPtr = &op.in[0]
	}
	var outPtr *byte
	if len(op.out) > 0 {
		outPtr = &op.out[0]
	}
	var returned uint32
	err = windows.DeviceIoControl(handle, code, inPtr, uint32(len(op.in)), outPtr, uint32(len(op.out)), &returned, &op.overlapped)
	if err != nil && !errors.Is(err, windows.ERROR_IO_PENDING) {
		return 0, err
	}
	err = windows.GetOverlappedResult(handle, &op.overlapped, &returned, true)
	runtime.KeepAlive(op)
	if err != nil {
		return 0, err
	}
	copy(out, op.out)
	return returned, nil
}
