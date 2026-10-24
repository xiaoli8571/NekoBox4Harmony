//go:build linux || (darwin && cgo) || windows

package usbip

import (
	"encoding/binary"
	"encoding/json"
	"io"
	"slices"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	controlProtocolVersion uint8 = 1

	controlFrameHello          uint8 = 1
	controlFrameAck            uint8 = 2
	controlFramePing           uint8 = 3
	controlFramePong           uint8 = 4
	controlFrameDeviceSnapshot uint8 = 5

	controlPrefaceSize      = 8
	controlFrameSize        = 4
	maxControlPayloadLength = 64<<10 - 1
)

type DeviceState int32

const (
	DeviceStateIdle DeviceState = iota
	DeviceStateAttached
	DeviceStateUnavailable
)

func (s DeviceState) String() string {
	switch s {
	case DeviceStateIdle:
		return "idle"
	case DeviceStateAttached:
		return "attached"
	case DeviceStateUnavailable:
		return "unavailable"
	default:
		return ""
	}
}

type BackendID int32

const (
	BackendIDUnspecified BackendID = iota
	BackendIDLinuxSysfs
	BackendIDDynamic
	BackendIDDarwinIOKit
	BackendIDWindowsVBoxUSB
)

func (b BackendID) String() string {
	switch b {
	case BackendIDLinuxSysfs:
		return "linux-sysfs"
	case BackendIDDynamic:
		return "dynamic"
	case BackendIDDarwinIOKit:
		return "darwin-iokit"
	case BackendIDWindowsVBoxUSB:
		return "windows-vboxusb"
	default:
		return ""
	}
}

var controlPreface = [controlPrefaceSize]byte{'S', 'B', 'U', 'S', 'B', 'I', 'P', '1'}

type controlFrame struct {
	Type          uint8
	Version       uint8
	PayloadLength uint16
}

type controlMessage struct {
	Frame   controlFrame
	Payload []byte
}

type ControlDeviceInterface struct {
	Class    uint8 `json:"class"`
	SubClass uint8 `json:"subclass"`
	Protocol uint8 `json:"protocol"`
}

type ControlDeviceInfo struct {
	BusID              string                   `json:"busid"`
	StableID           string                   `json:"stable_id,omitempty"`
	Backend            BackendID                `json:"backend,omitempty"`
	Path               string                   `json:"path,omitempty"`
	Serial             string                   `json:"serial,omitempty"`
	Product            string                   `json:"product,omitempty"`
	VendorID           uint16                   `json:"vendor_id"`
	ProductID          uint16                   `json:"product_id"`
	BCDDevice          uint16                   `json:"bcd_device,omitempty"`
	BusNum             uint32                   `json:"busnum"`
	DevNum             uint32                   `json:"devnum"`
	Speed              uint32                   `json:"speed"`
	DeviceClass        uint8                    `json:"device_class"`
	DeviceSubClass     uint8                    `json:"device_subclass"`
	DeviceProtocol     uint8                    `json:"device_protocol"`
	ConfigurationValue uint8                    `json:"configuration_value"`
	NumConfigurations  uint8                    `json:"num_configurations"`
	NumInterfaces      uint8                    `json:"num_interfaces"`
	Interfaces         []ControlDeviceInterface `json:"interfaces,omitempty"`
	State              DeviceState              `json:"state"`
	StatusCode         int                      `json:"status_code,omitempty"`
	StatusReason       string                   `json:"status_reason,omitempty"`
}

type controlDeviceSnapshot struct {
	Devices []ControlDeviceInfo `json:"devices"`
}

type controlReader struct {
	scratch []byte
}

func (c *controlReader) read(r io.Reader) (controlMessage, error) {
	var raw [controlFrameSize]byte
	_, err := io.ReadFull(r, raw[:])
	if err != nil {
		return controlMessage{}, err
	}
	frame := controlFrame{
		Type:          raw[0],
		Version:       raw[1],
		PayloadLength: binary.BigEndian.Uint16(raw[2:4]),
	}
	var payload []byte
	if frame.PayloadLength > 0 {
		if cap(c.scratch) < int(frame.PayloadLength) {
			c.scratch = make([]byte, frame.PayloadLength)
		}
		payload = c.scratch[:frame.PayloadLength]
		_, err = io.ReadFull(r, payload)
		if err != nil {
			return controlMessage{}, err
		}
	}
	return controlMessage{Frame: frame, Payload: payload}, nil
}

func writeControlMessage(w io.Writer, frame controlFrame, payload any) error {
	rawPayload, err := marshalControlPayload(payload)
	if err != nil {
		return err
	}
	if len(rawPayload) > maxControlPayloadLength {
		return E.New("control payload too large: ", len(rawPayload))
	}
	frame.PayloadLength = uint16(len(rawPayload))
	var raw [controlFrameSize]byte
	raw[0] = frame.Type
	raw[1] = frame.Version
	binary.BigEndian.PutUint16(raw[2:4], frame.PayloadLength)
	_, err = w.Write(raw[:])
	if err != nil {
		return err
	}
	if len(rawPayload) == 0 {
		return nil
	}
	_, err = w.Write(rawPayload)
	return err
}

func marshalControlPayload(payload any) ([]byte, error) {
	switch value := payload.(type) {
	case nil:
		return nil, nil
	case []byte:
		return value, nil
	default:
		return json.Marshal(value)
	}
}

func unmarshalControlPayload(payload []byte, value any) error {
	if len(payload) == 0 {
		return E.New("missing control payload")
	}
	return json.Unmarshal(payload, value)
}

func controlDeviceInfoFromEntry(entry DeviceEntry, backend BackendID, stableID string, state DeviceState, statusCode int, statusReason string) ControlDeviceInfo {
	interfaces := make([]ControlDeviceInterface, len(entry.Interfaces))
	for i := range entry.Interfaces {
		interfaces[i] = ControlDeviceInterface{
			Class:    entry.Interfaces[i].BInterfaceClass,
			SubClass: entry.Interfaces[i].BInterfaceSubClass,
			Protocol: entry.Interfaces[i].BInterfaceProtocol,
		}
	}
	return ControlDeviceInfo{
		BusID:              entry.Info.BusIDString(),
		StableID:           stableID,
		Backend:            backend,
		Path:               entry.Info.PathString(),
		Serial:             entry.Serial,
		Product:            entry.Product,
		VendorID:           entry.Info.IDVendor,
		ProductID:          entry.Info.IDProduct,
		BCDDevice:          entry.Info.BCDDevice,
		BusNum:             entry.Info.BusNum,
		DevNum:             entry.Info.DevNum,
		Speed:              entry.Info.Speed,
		DeviceClass:        entry.Info.BDeviceClass,
		DeviceSubClass:     entry.Info.BDeviceSubClass,
		DeviceProtocol:     entry.Info.BDeviceProtocol,
		ConfigurationValue: entry.Info.BConfigurationValue,
		NumConfigurations:  entry.Info.BNumConfigurations,
		NumInterfaces:      entry.Info.BNumInterfaces,
		Interfaces:         interfaces,
		State:              state,
		StatusCode:         statusCode,
		StatusReason:       statusReason,
	}
}

func controlDeviceInfoMap(devices []ControlDeviceInfo) map[string]ControlDeviceInfo {
	out := make(map[string]ControlDeviceInfo, len(devices))
	for _, device := range devices {
		if device.BusID == "" {
			continue
		}
		out[device.BusID] = device
	}
	return out
}

func sortedControlDeviceInfoValues(devices map[string]ControlDeviceInfo) []ControlDeviceInfo {
	busids := make([]string, 0, len(devices))
	for busid := range devices {
		busids = append(busids, busid)
	}
	slices.Sort(busids)
	out := make([]ControlDeviceInfo, 0, len(busids))
	for _, busid := range busids {
		out = append(out, devices[busid])
	}
	return out
}

func controlDeviceInfoToEntries(devices []ControlDeviceInfo, availableOnly bool) []DeviceEntry {
	entries := make([]DeviceEntry, 0, len(devices))
	for _, device := range devices {
		if availableOnly && device.State != DeviceStateIdle {
			continue
		}
		var info DeviceInfoTruncated
		if len(device.BusID) >= len(info.BusID) {
			continue
		}
		encodePathField(&info.Path, device.Path)
		copy(info.BusID[:], device.BusID)
		info.BusNum = device.BusNum
		info.DevNum = device.DevNum
		info.Speed = device.Speed
		info.IDVendor = device.VendorID
		info.IDProduct = device.ProductID
		info.BCDDevice = device.BCDDevice
		info.BDeviceClass = device.DeviceClass
		info.BDeviceSubClass = device.DeviceSubClass
		info.BDeviceProtocol = device.DeviceProtocol
		info.BConfigurationValue = device.ConfigurationValue
		info.BNumConfigurations = device.NumConfigurations
		info.BNumInterfaces = device.NumInterfaces
		interfaces := make([]DeviceInterface, len(device.Interfaces))
		for i := range device.Interfaces {
			interfaces[i] = DeviceInterface{
				BInterfaceClass:    device.Interfaces[i].Class,
				BInterfaceSubClass: device.Interfaces[i].SubClass,
				BInterfaceProtocol: device.Interfaces[i].Protocol,
			}
		}
		entries = append(entries, DeviceEntry{Info: info, Interfaces: interfaces, Serial: device.Serial, Product: device.Product})
	}
	return entries
}

func controlDeviceInfoEqual(a, b ControlDeviceInfo) bool {
	if a.BusID != b.BusID ||
		a.StableID != b.StableID ||
		a.Backend != b.Backend ||
		a.Path != b.Path ||
		a.Serial != b.Serial ||
		a.Product != b.Product ||
		a.VendorID != b.VendorID ||
		a.ProductID != b.ProductID ||
		a.BCDDevice != b.BCDDevice ||
		a.BusNum != b.BusNum ||
		a.DevNum != b.DevNum ||
		a.Speed != b.Speed ||
		a.DeviceClass != b.DeviceClass ||
		a.DeviceSubClass != b.DeviceSubClass ||
		a.DeviceProtocol != b.DeviceProtocol ||
		a.ConfigurationValue != b.ConfigurationValue ||
		a.NumConfigurations != b.NumConfigurations ||
		a.NumInterfaces != b.NumInterfaces ||
		a.State != b.State ||
		a.StatusCode != b.StatusCode ||
		a.StatusReason != b.StatusReason {
		return false
	}
	return slices.Equal(a.Interfaces, b.Interfaces)
}
