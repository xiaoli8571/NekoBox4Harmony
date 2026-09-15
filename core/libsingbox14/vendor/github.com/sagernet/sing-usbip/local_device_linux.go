//go:build linux

package usbip

import (
	"context"
	"fmt"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/unix"
)

type linuxLocalDevice struct {
	stableID string
	entry    DeviceEntry
	engine   *usbfsEngine
}

func OpenLocalDevice(id string, capture bool) (LocalDevice, error) {
	devices, err := listUSBDevices()
	if err != nil {
		return nil, err
	}
	var found *sysfsDevice
	for i := range devices {
		if devices[i].BusID == id {
			found = &devices[i]
			break
		}
	}
	if found == nil {
		return nil, E.New("linux local device not found: ", id)
	}
	if found.DeviceClass == 0x09 {
		return nil, E.New("refusing to open hub device ", found.BusID)
	}
	path := fmt.Sprintf("/dev/bus/usb/%03d/%03d", found.BusNum, found.DevNum)
	fd, err := unix.Open(path, unix.O_RDWR|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, E.Cause(err, "open ", path)
	}
	claimed, err := claimInterfaces(fd, int(found.NumInterfaces), capture)
	if err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	return &linuxLocalDevice{
		stableID: found.BusID,
		entry: DeviceEntry{
			Info:       found.toProtocol(),
			Interfaces: found.Interfaces,
			Serial:     found.Serial,
			Product:    found.Product,
		},
		engine: newUsbfsEngine(fd, claimed),
	}, nil
}

func WatchLocalDevices(ctx context.Context, callback func()) error {
	listener, err := newUEventListener()
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	go func() {
		for {
			waitErr := listener.WaitUSBEvent()
			if waitErr != nil {
				return
			}
			callback()
		}
	}()
	return nil
}

func (d *linuxLocalDevice) StableID() string {
	return d.stableID
}

func (d *linuxLocalDevice) Entry() DeviceEntry {
	return d.entry
}

func (d *linuxLocalDevice) Submit(request URBRequest) URBResponse {
	return d.engine.Submit(request)
}

func (d *linuxLocalDevice) AbortEndpoint(endpoint uint8) error {
	return d.engine.AbortEndpoint(endpoint)
}

func (d *linuxLocalDevice) Close() error {
	return d.engine.Close()
}
