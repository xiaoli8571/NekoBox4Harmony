//go:build linux || (darwin && cgo) || windows

package usbip

import E "github.com/sagernet/sing/common/exceptions"

type LocalDevice interface {
	DeviceTransport
	StableID() string
	Entry() DeviceEntry
	Close() error
}

type LocalDeviceInfo struct {
	StableID string
	Backend  BackendID
	Entry    DeviceEntry
}

func newLocalDeviceInfo(stableID string, backend BackendID, entry DeviceEntry) LocalDeviceInfo {
	if stableID == "" {
		stableID = entry.Info.BusIDString()
	}
	return LocalDeviceInfo{
		StableID: stableID,
		Backend:  backend,
		Entry:    entry,
	}
}

func setDeviceInfoBusID(info *DeviceInfoTruncated, busid string) error {
	if busid == "" {
		return E.New("missing bus id")
	}
	if len(busid) >= len(info.BusID) {
		return E.New("bus id too long: ", busid)
	}
	info.BusID = [32]byte{}
	copy(info.BusID[:], busid)
	return nil
}
