package vboxusb

const (
	DriverMajorVersion = 5
	DriverMinorVersion = 0
)

const (
	MonitorServiceName = "VBoxUSBMon"
	MonitorDevicePath  = `\\.\VBoxUSBMon`
)

// IOCTL codes from VirtualBox usblib-win.h, identical to those used by
// usbipd-win (Usbipd/Interop/VBoxUsb.cs:26-39 and VBoxUsbMon.cs:122-129).
// Encoding is the standard CTL_CODE shape:
//
//	(DeviceType << 16) | (Access << 14) | (Function << 2) | Method
//
// DeviceType = FILE_DEVICE_UNKNOWN (0x22), Access = FILE_WRITE_ACCESS (2),
// Method = METHOD_BUFFERED (0).
const (
	// Per-device VBoxUSB.sys (\\?\<setupapi-resolved path>).
	IOCTLSendURB            uint32 = 0x0022_981C // function 0x607
	IOCTLUSBSelectInterface uint32 = 0x0022_9824 // function 0x609
	IOCTLUSBSetConfig       uint32 = 0x0022_9828 // function 0x60a
	IOCTLUSBClaimDevice     uint32 = 0x0022_982C // function 0x60b
	IOCTLUSBClearEndpoint   uint32 = 0x0022_9838 // function 0x60e
	IOCTLGetVersion         uint32 = 0x0022_983C // function 0x60f
	IOCTLUSBAbortEndpoint   uint32 = 0x0022_9840 // function 0x610

	// VBoxUSBMon (\\.\VBoxUSBMon). Note GET_VERSION shares the numeric
	// code with VBoxUSB's USB_ABORT_ENDPOINT — different handles.
	IOCTLMonitorGetVersion   uint32 = 0x0022_9840 // function 0x610
	IOCTLMonitorAddFilter    uint32 = 0x0022_9844 // function 0x611
	IOCTLMonitorRemoveFilter uint32 = 0x0022_9848 // function 0x612
)

// Matches VirtualBox USBSUP_TRANSFER_TYPE.
type TransferType uint32

const (
	TransferTypeControl TransferType = iota
	TransferTypeIso
	TransferTypeBulk
	TransferTypeInterrupt
	TransferTypeMessage // control with setup packet inline
)

// Matches USBSUP_DIRECTION.
type Direction uint32

const (
	DirectionSetup Direction = iota
	DirectionIn
	DirectionOut
)

// Matches USBSUP_XFER_FLAG. ShortOK is required for IN transfers unless
// the USB/IP request flags include URB_SHORT_NOT_OK.
type TransferFlags uint32

const (
	TransferFlagNone    TransferFlags = 0
	TransferFlagShortOK TransferFlags = 1 << 0
)

// Mirrors USBSUP_ERROR.
type URBError uint32

const (
	URBOK URBError = iota
	URBStall
	URBDeviceNotResponding
	URBCRCError
	URBNACError
	URBUnderrun
	URBOverrun
)

// MaxIsoPacketsPerURB is the hard VBoxUSB limit (USBSUP_URB.aIsoPkts
// is sized for 8 entries). Callers with more iso packets must split
// into multiple URBs sharing one pinned buffer; offsets must stay
// within ushort range.
const MaxIsoPacketsPerURB = 8

// Filter is a VBoxUSBMon ADD_FILTER descriptor.
type Filter struct {
	VendorID       *uint16
	ProductID      *uint16
	DeviceRev      *uint16
	Bus            *uint16
	Port           *uint16
	DeviceClass    *uint16
	DeviceSubClass *uint16
	DeviceProtocol *uint16
}
