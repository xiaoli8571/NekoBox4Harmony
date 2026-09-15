package usbipvhci

// Driver string-buffer sizes, from include/usbip/consts.h.
const (
	BusIDSize   = 32   // BUS_ID_SIZE
	serviceSize = 32   // NI_MAXSERV
	hostSize    = 1025 // NI_MAXHOST in ws2def.h
)

// IOCTL codes: CTL_CODE(FILE_DEVICE_UNKNOWN, function, METHOD_BUFFERED,
// FILE_READ_DATA|FILE_WRITE_DATA). PLUGIN_HARDWARE_ONCE only suppresses
// retries of the initial attach (vhci_ioctl.cpp checks one_attempt in the
// connect completion alone); when an established connection later drops,
// wsk_receive.cpp unconditionally schedules reattach attempts toward
// the by-then-dead one-shot loopback port, so every teardown must
// cancel them via STOP_ATTACH_ATTEMPTS.
const (
	ioctlPluginHardwareOnce uint32 = 0x0022_E018 // function 0x806
	ioctlPlugoutHardware    uint32 = 0x0022_E004 // function 0x801
	ioctlStopAttachAttempts uint32 = 0x0022_E014 // function 0x805
)

// Field offsets within usbip::vhci::ioctl::plugin_hardware, which is
// base{size} + imported_device_location{port,busid,service,host}. All
// members are int/char so the layout is dense.
const (
	offsetPluginSize    = 0
	offsetPluginPort    = 4
	offsetPluginBusID   = 8
	offsetPluginService = offsetPluginBusID + BusIDSize     // 40
	offsetPluginHost    = offsetPluginService + serviceSize // 72
)

// sizeof(plugin_hardware): 1097 raw bytes padded to the 4-byte struct
// alignment. The driver rejects any other size.
const pluginHardwareSize = 1100

// sizeof(plugout_hardware): ULONG size + int port.
const plugoutHardwareSize = 8

// sizeof(ioctl::stop_attach_attempts): base + imported_device_location
// (1097) padded to 1100 for the trailing `int count` (OUT), total 1104.
const (
	stopAttachAttemptsSize        = 1104
	offsetStopAttachAttemptsCount = 1100
)

// PORT_ALL = -1.
const PortAll = -1

// Root-enumerated hardware id of the VHCI devnode, from usbip2_ude.inf.
const udeHardwareID = `ROOT\USBIP_WIN2\UDE`

type assetFile struct {
	name string
	data []byte
}
