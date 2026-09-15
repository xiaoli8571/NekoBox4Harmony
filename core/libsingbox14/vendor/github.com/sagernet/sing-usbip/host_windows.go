//go:build windows

package usbip

import (
	"context"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/sagernet/sing-usbip/internal/vboxusb"
	"github.com/sagernet/sing-usbip/internal/wincfgmgr32"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
)

func newPlatformExportHost(ctx context.Context, logger logger.ContextLogger, matches []DeviceMatch) (ExportHost, error) {
	return newWindowsExportHost(ctx, logger, matches), nil
}

func ListLocalDevices() ([]LocalDeviceInfo, error) {
	devices, err := vboxusb.EnumerateUSBDevices()
	if err != nil {
		return nil, err
	}
	entries := make([]LocalDeviceInfo, 0, len(devices))
	for _, info := range devices {
		entry := windowsDeviceEntry(info)
		entries = append(entries, newLocalDeviceInfo("", BackendIDWindowsVBoxUSB, entry))
	}
	return entries, nil
}

func newPlatformImportHost(logger logger.ContextLogger) (ImportHost, error) {
	return &windowsImportHost{logger: logger}, nil
}

const (
	windowsExportAbsenceGrace     = 10 * time.Second
	windowsEnumerateRetryInterval = time.Second
)

type windowsExportHost struct {
	logger  logger.ContextLogger
	matches []DeviceMatch

	runCtx    context.Context
	runCancel context.CancelFunc

	access       sync.Mutex
	monitor      *vboxusb.Monitor
	exports      map[string]*windowsExport
	filters      map[string]uint64
	eventsCh     chan struct{}
	recheckTimer *time.Timer
}

func newWindowsExportHost(ctx context.Context, logger logger.ContextLogger, matches []DeviceMatch) *windowsExportHost {
	runCtx, runCancel := context.WithCancel(ctx)
	return &windowsExportHost{
		logger:    logger,
		matches:   matches,
		runCtx:    runCtx,
		runCancel: runCancel,
		exports:   make(map[string]*windowsExport),
		filters:   make(map[string]uint64),
	}
}

func (h *windowsExportHost) Start() error {
	err := vboxusb.EnableLoadDriverPrivilege()
	if err != nil {
		return E.Cause(err, "windows usbip: enable SeLoadDriverPrivilege")
	}
	err = vboxusb.EnsureDrivers()
	if err != nil {
		return E.Cause(err, "windows usbip: install VBoxUSB drivers")
	}
	monitor, err := vboxusb.OpenMonitor()
	if err != nil {
		return E.Cause(err, "windows usbip: open VBoxUSBMon")
	}
	major, minor, err := monitor.GetVersion()
	if err != nil {
		_ = monitor.Close()
		return E.Cause(err, "windows usbip: monitor GET_VERSION")
	}
	if major != vboxusb.DriverMajorVersion {
		_ = monitor.Close()
		return E.New("windows usbip: VBoxUSBMon major version ", major, " (need ", vboxusb.DriverMajorVersion, ")")
	}
	h.logger.Info("VBoxUSBMon ", major, ".", minor, " ready")
	h.monitor = monitor
	return nil
}

func (h *windowsExportHost) Close() error {
	h.runCancel()
	h.access.Lock()
	monitor := h.monitor
	h.monitor = nil
	filters := h.filters
	h.filters = make(map[string]uint64)
	exports := h.exports
	h.exports = make(map[string]*windowsExport)
	h.access.Unlock()
	for busid, export := range exports {
		device := export.takeDevice()
		if device != nil {
			_ = device.Close()
		}
		instanceID, captured := export.lastState()
		var restart *vboxusb.DeviceRestart
		if captured {
			var err error
			restart, err = vboxusb.BeginDeviceRestart(instanceID, export.info.Address)
			if err != nil {
				h.logger.Warn("restart ", busid, " for release: ", err)
			}
		}
		if monitor != nil {
			if id, ok := filters[busid]; ok {
				delete(filters, busid)
				err := monitor.RemoveFilter(id)
				if err != nil {
					h.logger.Debug("remove filter for ", busid, ": ", err)
				}
			}
		}
		if restart != nil {
			restart.Finish()
		}
	}
	if monitor != nil {
		for busid, id := range filters {
			err := monitor.RemoveFilter(id)
			if err != nil {
				h.logger.Debug("remove filter for ", busid, ": ", err)
			}
		}
		_ = monitor.Close()
	}
	return nil
}

func (h *windowsExportHost) Events() (<-chan struct{}, error) {
	ch := make(chan struct{}, 1)
	h.access.Lock()
	h.eventsCh = ch
	h.access.Unlock()
	onEvent := func(action uint32) { h.signalEvents() }
	deviceNotification, err := wincfgmgr32.RegisterDeviceInterfaceNotification(vboxusb.USBDeviceInterfaceGUID, onEvent)
	if err != nil {
		h.clearEvents()
		close(ch)
		return nil, E.Cause(err, "windows usbip: register USB interface notification")
	}
	captureNotification, err := wincfgmgr32.RegisterDeviceInterfaceNotification(vboxusb.MonitorAccessGUID, onEvent)
	if err != nil {
		_ = deviceNotification.Close()
		h.clearEvents()
		close(ch)
		return nil, E.Cause(err, "windows usbip: register VBoxUSB interface notification")
	}
	go func() {
		<-h.runCtx.Done()
		h.clearEvents()
		_ = deviceNotification.Close()
		_ = captureNotification.Close()
		close(ch)
	}()
	return ch, nil
}

func (h *windowsExportHost) signalEvents() {
	h.access.Lock()
	defer h.access.Unlock()
	if h.eventsCh == nil {
		return
	}
	select {
	case h.eventsCh <- struct{}{}:
	default:
	}
}

func (h *windowsExportHost) clearEvents() {
	h.access.Lock()
	defer h.access.Unlock()
	h.eventsCh = nil
	if h.recheckTimer != nil {
		h.recheckTimer.Stop()
		h.recheckTimer = nil
	}
}

// scheduleRecheck wakes the reconcile loop once, for state that expires by
// time instead of by a device event: the absence grace period and retry
// after a failed enumeration.
func (h *windowsExportHost) scheduleRecheck(after time.Duration) {
	h.access.Lock()
	defer h.access.Unlock()
	if h.eventsCh == nil {
		return
	}
	if h.recheckTimer != nil {
		h.recheckTimer.Stop()
	}
	h.recheckTimer = time.AfterFunc(after, h.signalEvents)
}

func (h *windowsExportHost) Reconcile(isReserved func(busid string) bool) (map[string]Export, []string, error) {
	devices, err := vboxusb.EnumerateUSBDevices()
	if err != nil {
		h.scheduleRecheck(windowsEnumerateRetryInterval)
		return h.snapshotSelf(), nil, E.Cause(err, "windows usbip: enumerate USB devices")
	}

	h.access.Lock()
	monitor := h.monitor
	current := make(map[string]*windowsExport, len(h.exports))
	for k, v := range h.exports {
		current[k] = v
	}
	h.access.Unlock()

	present := make(map[string]vboxusb.USBDeviceInfo, len(devices))
	keys := make([]DeviceKey, 0, len(devices))
	for _, d := range devices {
		present[d.BusID] = d
		key := DeviceKey{
			BusID:     d.BusID,
			VendorID:  d.VendorID,
			ProductID: d.ProductID,
		}
		if export, ok := current[d.BusID]; ok && d.Captured && d.IdentityIsStub() {
			key.VendorID = export.info.VendorID
			key.ProductID = export.info.ProductID
		}
		keys = append(keys, key)
	}
	desired := make(map[string]vboxusb.USBDeviceInfo)
	for _, idx := range SelectMatches(h.matches, keys) {
		info := present[keys[idx].BusID]
		if info.DeviceClass == 0x09 {
			h.logger.Warn("skip hub device ", info.BusID)
			continue
		}
		desired[info.BusID] = info
	}

	now := time.Now()
	var released []string
	var graceRecheck time.Duration
	for busid, info := range desired {
		if export, found := current[busid]; found {
			if !info.IdentityIsStub() && (info.VendorID != export.info.VendorID || info.ProductID != export.info.ProductID) {
				h.logger.Warn("device at ", busid, " changed identity; re-exporting")
				h.releaseDevice(monitor, busid, export, info, true)
				delete(current, busid)
				released = append(released, busid)
			} else {
				export.markSeen(now, info.InstanceID, info.Captured)
				continue
			}
		}
		export := newWindowsExport(info, h.logger)
		export.markSeen(now, info.InstanceID, info.Captured)
		if info.Captured {
			// The VBoxUSB device binding outlives the process that
			// created it, while the VBoxUSBMon filter does not.
			h.addFilter(monitor, busid, info)
			h.logger.Info("adopted already-captured ", busid, " (vid=", fmt.Sprintf("0x%04x", info.VendorID), " pid=", fmt.Sprintf("0x%04x", info.ProductID), ")")
		} else {
			h.captureDevice(monitor, busid, info)
			h.logger.Info("matched ", busid, " (vid=", fmt.Sprintf("0x%04x", info.VendorID), " pid=", fmt.Sprintf("0x%04x", info.ProductID), ") — capturing")
		}
		current[busid] = export
	}
	for busid, export := range current {
		if _, ok := desired[busid]; ok {
			continue
		}
		if isReserved(busid) {
			continue
		}
		info, isPresent := present[busid]
		if !isPresent {
			remaining := windowsExportAbsenceGrace - now.Sub(export.seenAt())
			if remaining > 0 {
				if graceRecheck == 0 || remaining < graceRecheck {
					graceRecheck = remaining
				}
				continue
			}
		}
		h.releaseDevice(monitor, busid, export, info, isPresent)
		delete(current, busid)
		released = append(released, busid)
		h.logger.Info("released ", busid, " (no longer matches)")
	}

	h.access.Lock()
	h.exports = current
	h.access.Unlock()

	if graceRecheck > 0 {
		h.scheduleRecheck(graceRecheck)
	}
	return h.snapshotSelf(), released, nil
}

func (h *windowsExportHost) FinishImport(busid string) (bool, error) {
	h.access.Lock()
	export, ok := h.exports[busid]
	h.access.Unlock()
	if !ok {
		return false, nil
	}
	device := export.takeDevice()
	if device != nil {
		_ = device.Close()
	}
	return false, nil
}

func (h *windowsExportHost) snapshotSelf() map[string]Export {
	h.access.Lock()
	defer h.access.Unlock()
	out := make(map[string]Export, len(h.exports))
	for k, v := range h.exports {
		out[k] = v
	}
	return out
}

// VBoxUSBMon only rewrites a device's IDs (handing it to VBoxUSB.sys)
// while the device enumerates, so without a forced re-enumeration an
// already-plugged device keeps its function driver until physically
// replugged.
func (h *windowsExportHost) captureDevice(monitor *vboxusb.Monitor, busid string, info vboxusb.USBDeviceInfo) {
	if monitor == nil {
		return
	}
	restart, err := vboxusb.BeginDeviceRestart(info.InstanceID, info.Address)
	if err != nil {
		h.logger.Warn("restart ", busid, " for capture: ", err)
	}
	h.addFilter(monitor, busid, info)
	if restart != nil {
		restart.Finish()
	}
}

func (h *windowsExportHost) addFilter(monitor *vboxusb.Monitor, busid string, info vboxusb.USBDeviceInfo) {
	if monitor == nil {
		return
	}
	filterID, err := monitor.AddFilter(captureFilter(info))
	if err != nil {
		h.logger.Warn("ADD_FILTER for ", busid, ": ", err)
		return
	}
	h.access.Lock()
	h.filters[busid] = filterID
	h.access.Unlock()
}

// A VBoxUSBMon VID/PID-only filter captures every identical device
// enumerating anywhere while it lives, and keeps capturing the matched
// device at new busids after a port change, so the filter is pinned to
// one device on one hub port.
func captureFilter(info vboxusb.USBDeviceInfo) vboxusb.Filter {
	vendor := info.VendorID
	product := info.ProductID
	port := uint16(info.Address)
	filter := vboxusb.Filter{
		VendorID:  &vendor,
		ProductID: &product,
		Port:      &port,
	}
	if info.DescriptorFromHub {
		revision := info.Revision
		class := uint16(info.DeviceClass)
		subClass := uint16(info.DeviceSubClass)
		protocol := uint16(info.DeviceProtocol)
		filter.DeviceRev = &revision
		filter.DeviceClass = &class
		filter.DeviceSubClass = &subClass
		filter.DeviceProtocol = &protocol
	}
	return filter
}

// Without a restart to re-bind the original function driver, a released
// device stays dead to Windows until physically replugged.
func (h *windowsExportHost) releaseDevice(monitor *vboxusb.Monitor, busid string, export *windowsExport, info vboxusb.USBDeviceInfo, isPresent bool) {
	device := export.takeDevice()
	if device != nil {
		_ = device.Close()
	}
	var restart *vboxusb.DeviceRestart
	if isPresent && info.Captured {
		var err error
		restart, err = vboxusb.BeginDeviceRestart(info.InstanceID, info.Address)
		if err != nil {
			h.logger.Warn("restart ", busid, " for release: ", err)
		}
	}
	h.removeFilter(monitor, busid)
	if restart != nil {
		restart.Finish()
	}
}

func (h *windowsExportHost) removeFilter(monitor *vboxusb.Monitor, busid string) {
	if monitor == nil {
		return
	}
	h.access.Lock()
	id, ok := h.filters[busid]
	delete(h.filters, busid)
	h.access.Unlock()
	if !ok {
		return
	}
	err := monitor.RemoveFilter(id)
	if err != nil {
		h.logger.Debug("remove filter for ", busid, ": ", err)
	}
}

type windowsExport struct {
	info   vboxusb.USBDeviceInfo
	entry  DeviceEntry
	logger logger.ContextLogger

	stateAccess       sync.Mutex
	device            *vboxusb.Device
	lastSeen          time.Time
	currentInstanceID string
	seenCaptured      bool
}

func (e *windowsExport) setDevice(device *vboxusb.Device) {
	e.stateAccess.Lock()
	e.device = device
	e.stateAccess.Unlock()
}

func (e *windowsExport) takeDevice() *vboxusb.Device {
	e.stateAccess.Lock()
	device := e.device
	e.device = nil
	e.stateAccess.Unlock()
	return device
}

// The instance ID must be re-tracked every pass because capture rewrites it to the VBox stub ID.
func (e *windowsExport) markSeen(now time.Time, instanceID string, captured bool) {
	e.stateAccess.Lock()
	e.lastSeen = now
	e.currentInstanceID = instanceID
	e.seenCaptured = captured
	e.stateAccess.Unlock()
}

func (e *windowsExport) seenAt() time.Time {
	e.stateAccess.Lock()
	defer e.stateAccess.Unlock()
	return e.lastSeen
}

func (e *windowsExport) lastState() (string, bool) {
	e.stateAccess.Lock()
	defer e.stateAccess.Unlock()
	return e.currentInstanceID, e.seenCaptured
}

func newWindowsExport(info vboxusb.USBDeviceInfo, logger logger.ContextLogger) *windowsExport {
	return &windowsExport{info: info, entry: windowsDeviceEntry(info), logger: logger}
}

func windowsDeviceEntry(info vboxusb.USBDeviceInfo) DeviceEntry {
	entry := DeviceEntry{
		Info: DeviceInfoTruncated{
			BusNum:             info.BusNumber,
			DevNum:             info.Address,
			Speed:              windowsSpeedToProtocol(info.Speed),
			IDVendor:           info.VendorID,
			IDProduct:          info.ProductID,
			BCDDevice:          info.Revision,
			BDeviceClass:       info.DeviceClass,
			BDeviceSubClass:    info.DeviceSubClass,
			BDeviceProtocol:    info.DeviceProtocol,
			BNumConfigurations: 1,
		},
	}
	entry.Product = info.Product
	encodePathField(&entry.Info.Path, "/sys/bus/usb/devices/"+info.BusID)
	copy(entry.Info.BusID[:], info.BusID)
	return entry
}

func windowsSpeedToProtocol(speed vboxusb.DeviceSpeed) uint32 {
	switch speed {
	case vboxusb.SpeedLow:
		return SpeedLow
	case vboxusb.SpeedFull:
		return SpeedFull
	case vboxusb.SpeedHigh:
		return SpeedHigh
	case vboxusb.SpeedSuper:
		return SpeedSuper
	case vboxusb.SpeedSuperPlus:
		// Linux vhci_hcd only accepts USB_SPEED_SUPER_PLUS since kernel
		// 6.12 and there is no way to learn the importer's version;
		// report SUPER like usbipd-win (only the advertised rate
		// differs, the protocol is the same).
		return SpeedSuper
	default:
		return SpeedUnknown
	}
}

func (e *windowsExport) BusID() string {
	return e.info.BusID
}

func (e *windowsExport) Snapshot(busy bool) ExportSnapshot {
	state := DeviceStateIdle
	if busy {
		state = DeviceStateAttached
	}
	return ExportSnapshot{
		Entry:    e.entry,
		Backend:  BackendIDWindowsVBoxUSB,
		StableID: "windows-instance:" + e.info.InstanceID,
		State:    state,
	}
}

func (e *windowsExport) DeviceInfo() (DeviceInfoTruncated, error) {
	return e.entry.Info, nil
}

func (e *windowsExport) NewServerDataSession(ctx context.Context, conn net.Conn) (DataSession, error) {
	path, err := vboxusb.WaitForCapturedDevice(e.info.BusNumber, e.info.Address, 10*time.Second)
	if err != nil {
		return nil, E.Cause(err, "windows usbip: locate VBoxUSB interface")
	}
	device, err := vboxusb.OpenDevice(path)
	if err != nil {
		return nil, E.Cause(err, "windows usbip: open VBoxUSB device")
	}
	major, minor, err := device.GetVersion()
	if err != nil {
		_ = device.Close()
		return nil, E.Cause(err, "windows usbip: device GET_VERSION")
	}
	if major != vboxusb.DriverMajorVersion {
		_ = device.Close()
		return nil, E.New("windows usbip: VBoxUSB major version ", major, ".", minor, " (need ", vboxusb.DriverMajorVersion, ")")
	}
	claimed, err := device.Claim()
	if err != nil {
		_ = device.Close()
		return nil, E.Cause(err, "windows usbip: claim device")
	}
	if !claimed {
		_ = device.Close()
		return nil, E.New("windows usbip: device ", e.info.BusID, " is already claimed by another handle")
	}
	e.setDevice(device)
	return newUserspaceURBSession(ctx, e.logger, conn, newVBoxUSBEngine(device)), nil
}
