//go:build darwin && !ios && cgo

package usbip

import (
	"context"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

type darwinLocalDevice struct {
	stableID string
	entry    DeviceEntry
	device   *darwinUSBHostDevice
	engine   *darwinIOUSBHostEngine
}

func OpenLocalDevice(id string, capture bool) (LocalDevice, error) {
	registryID, err := resolveDarwinLocalDeviceID(id)
	if err != nil {
		return nil, err
	}
	device, err := darwinOpenUSBHostDevice(registryID, capture)
	if err != nil {
		return nil, err
	}
	return &darwinLocalDevice{
		stableID: darwinStableID(device.info.registryID),
		entry:    device.info.entry,
		device:   device,
		engine:   newDarwinIOUSBHostEngine(device),
	}, nil
}

func WatchLocalDevices(ctx context.Context, callback func()) error {
	watcher, err := darwinWatchUSBHostDevices(callback)
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		watcher.Close()
	}()
	return nil
}

func (d *darwinLocalDevice) StableID() string {
	return d.stableID
}

func (d *darwinLocalDevice) Entry() DeviceEntry {
	return d.entry
}

func (d *darwinLocalDevice) Submit(request URBRequest) URBResponse {
	return d.engine.Submit(request)
}

func (d *darwinLocalDevice) AbortEndpoint(endpoint uint8) error {
	return d.engine.AbortEndpoint(endpoint)
}

func (d *darwinLocalDevice) Close() error {
	if d.engine != nil {
		_ = d.engine.Close()
	}
	if d.device != nil {
		d.device.Close()
	}
	return nil
}

func resolveDarwinLocalDeviceID(id string) (uint64, error) {
	if strings.HasPrefix(id, darwinLocalDeviceIDPrefix) {
		registryID, err := strconv.ParseUint(strings.TrimPrefix(id, darwinLocalDeviceIDPrefix), 16, 64)
		if err != nil {
			return 0, E.Cause(err, "parse darwin local device id")
		}
		return registryID, nil
	}
	devices, err := darwinCopyUSBHostDevices()
	if err != nil {
		return 0, err
	}
	for i := range devices {
		if devices[i].entry.Info.BusIDString() == id || darwinStableID(devices[i].registryID) == id {
			return devices[i].registryID, nil
		}
	}
	return 0, E.New("darwin local device not found: ", id)
}
