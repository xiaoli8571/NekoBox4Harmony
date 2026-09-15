//go:build darwin && !ios && cgo

package usbip

import (
	"context"
	"fmt"
	"maps"
	"net"
	"slices"
	"sync"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
)

func newPlatformExportHost(ctx context.Context, logger logger.ContextLogger, matches []DeviceMatch) (ExportHost, error) {
	return newDarwinExportHost(ctx, logger, matches), nil
}

func newPlatformImportHost(logger logger.ContextLogger) (ImportHost, error) {
	return &darwinImportHost{logger: logger}, nil
}

const darwinLocalDeviceIDPrefix = "darwin-registry:"

func darwinStableID(registryID uint64) string {
	return fmt.Sprintf("%s%016x", darwinLocalDeviceIDPrefix, registryID)
}

func ListLocalDevices() ([]LocalDeviceInfo, error) {
	devices, err := darwinCopyUSBHostDevices()
	if err != nil {
		return nil, err
	}
	entries := make([]LocalDeviceInfo, 0, len(devices))
	for i := range devices {
		if devices[i].entry.Info.BDeviceClass == 0x09 {
			continue
		}
		entries = append(entries, newLocalDeviceInfo(darwinStableID(devices[i].registryID), BackendIDDarwinIOKit, devices[i].entry))
	}
	return entries, nil
}

type darwinExportHost struct {
	logger  logger.ContextLogger
	matches []DeviceMatch

	runCtx    context.Context
	runCancel context.CancelFunc

	access   sync.Mutex
	exports  map[string]*darwinExport
	watcher  *darwinUSBHostDeviceWatcher
	eventsCh chan struct{}
}

func newDarwinExportHost(ctx context.Context, logger logger.ContextLogger, matches []DeviceMatch) *darwinExportHost {
	runCtx, runCancel := context.WithCancel(ctx)
	return &darwinExportHost{
		runCtx:    runCtx,
		runCancel: runCancel,
		logger:    logger,
		matches:   matches,
		exports:   make(map[string]*darwinExport),
	}
}

func (h *darwinExportHost) Start() error { return nil }

func (h *darwinExportHost) Close() error {
	h.runCancel()
	h.access.Lock()
	watcher := h.watcher
	eventsCh := h.eventsCh
	h.watcher = nil
	h.eventsCh = nil
	exports := h.exports
	h.exports = make(map[string]*darwinExport)
	h.access.Unlock()
	if watcher != nil {
		watcher.Close()
	}
	if eventsCh != nil {
		close(eventsCh)
	}
	for _, export := range exports {
		if export.device != nil {
			export.device.Close()
		}
	}
	return nil
}

func (h *darwinExportHost) Events() (<-chan struct{}, error) {
	ch := make(chan struct{}, 1)
	signal := func() {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
	watcher, err := darwinWatchUSBHostDevices(signal)
	if err != nil {
		close(ch)
		return nil, err
	}
	h.access.Lock()
	h.watcher = watcher
	h.eventsCh = ch
	h.access.Unlock()
	// An in-flight IOKit callback can still run signal until watcher.Close has
	// drained the dispatch queue.
	go func() {
		<-h.runCtx.Done()
		h.access.Lock()
		takenWatcher := h.watcher
		takenCh := h.eventsCh
		h.watcher = nil
		h.eventsCh = nil
		h.access.Unlock()
		if takenWatcher != nil {
			takenWatcher.Close()
		}
		if takenCh != nil {
			close(takenCh)
		}
	}()
	return ch, nil
}

func (h *darwinExportHost) Reconcile(isReserved func(busid string) bool) (map[string]Export, []string, error) {
	devices, err := darwinCopyUSBHostDevices()
	if err != nil {
		return h.snapshotSelf(), nil, E.Cause(err, "enumerate IOUSBHost devices")
	}
	keys := make([]DeviceKey, len(devices))
	for i := range devices {
		keys[i] = devices[i].key
	}
	desired := make(map[string]darwinUSBHostDeviceInfo)
	for _, idx := range SelectMatches(h.matches, keys) {
		if devices[idx].entry.Info.BDeviceClass == 0x09 {
			h.logger.Warn("skip hub device ", devices[idx].key.BusID)
			continue
		}
		desired[devices[idx].key.BusID] = devices[idx]
	}

	h.access.Lock()
	current := make(map[string]*darwinExport, len(h.exports))
	maps.Copy(current, h.exports)
	h.access.Unlock()

	var (
		toAdd           []*darwinExport
		toRemove        []*darwinExport
		toStale         []darwinStaleMark
		released        []string
		reconcileErrors []error
	)
	for busid, info := range desired {
		if export, ok := current[busid]; ok && export.registryID == info.registryID {
			continue
		}
		if export, ok := current[busid]; ok {
			if isReserved(busid) {
				toStale = append(toStale, darwinStaleMark{busid: busid, pendingRegistryID: info.registryID})
				continue
			}
			toRemove = append(toRemove, export)
			released = append(released, busid)
		}
		device, err := darwinOpenUSBHostDevice(info.registryID, true)
		if err != nil {
			reconcileErrors = append(reconcileErrors, E.Cause(err, "capture ", busid))
			continue
		}
		info = device.info
		toAdd = append(toAdd, &darwinExport{
			busid:      info.key.BusID,
			registryID: info.registryID,
			device:     device,
			entry:      info.entry,
			logger:     h.logger,
		})
		h.logger.Info("exported ", info.key.BusID, " through IOUSBHost capture")
	}
	for busid, export := range current {
		if _, ok := desired[busid]; ok {
			continue
		}
		if isReserved(busid) {
			toStale = append(toStale, darwinStaleMark{busid: busid})
			continue
		}
		toRemove = append(toRemove, export)
		h.logger.Info("released ", busid, " from IOUSBHost capture")
		released = append(released, busid)
	}

	committed := make(map[string]*darwinExport, len(current)+len(toAdd))
	maps.Copy(committed, current)
	for _, mark := range toStale {
		export, found := committed[mark.busid]
		if !found {
			continue
		}
		cloned := cloneDarwinExport(export)
		cloned.stale = true
		if mark.pendingRegistryID != 0 {
			cloned.pendingRegistryID = mark.pendingRegistryID
		}
		committed[mark.busid] = cloned
	}
	for _, export := range toRemove {
		delete(committed, export.busid)
	}
	for _, export := range toAdd {
		committed[export.busid] = export
	}

	h.access.Lock()
	h.exports = committed
	h.access.Unlock()

	for _, export := range toRemove {
		if export.device != nil {
			export.device.Close()
		}
	}
	return snapshotDarwinExports(committed), released, E.Errors(reconcileErrors...)
}

func (h *darwinExportHost) FinishImport(busid string) (bool, error) {
	h.access.Lock()
	export, ok := h.exports[busid]
	if !ok || !export.stale {
		h.access.Unlock()
		return false, nil
	}
	pending := export.pendingRegistryID
	if pending == 0 {
		delete(h.exports, busid)
		h.access.Unlock()
		if export.device != nil {
			export.device.Close()
		}
		return true, nil
	}
	h.access.Unlock()

	device, err := darwinOpenUSBHostDevice(pending, true)
	if err != nil {
		h.logger.Warn("re-capture ", busid, " (registry ", pending, "): ", err)
		h.access.Lock()
		delete(h.exports, busid)
		h.access.Unlock()
		if export.device != nil {
			export.device.Close()
		}
		return true, nil
	}
	info := device.info
	replacement := &darwinExport{
		busid:      info.key.BusID,
		registryID: info.registryID,
		device:     device,
		entry:      info.entry,
		logger:     h.logger,
	}
	h.access.Lock()
	h.exports[busid] = replacement
	h.access.Unlock()
	if export.device != nil {
		export.device.Close()
	}
	h.logger.Info("re-exported ", busid, " through IOUSBHost re-capture (registry ", pending, ")")
	return true, nil
}

func (h *darwinExportHost) snapshotSelf() map[string]Export {
	h.access.Lock()
	defer h.access.Unlock()
	return snapshotDarwinExports(h.exports)
}

func snapshotDarwinExports(exports map[string]*darwinExport) map[string]Export {
	out := make(map[string]Export, len(exports))
	for busid, export := range exports {
		out[busid] = export
	}
	return out
}

func cloneDarwinExport(export *darwinExport) *darwinExport {
	if export == nil {
		return nil
	}
	clone := *export
	clone.entry.Interfaces = slices.Clone(export.entry.Interfaces)
	return &clone
}

type darwinExport struct {
	busid             string
	registryID        uint64
	pendingRegistryID uint64
	device            *darwinUSBHostDevice
	entry             DeviceEntry
	logger            logger.ContextLogger
	stale             bool
}

type darwinStaleMark struct {
	busid             string
	pendingRegistryID uint64
}

func (e *darwinExport) BusID() string {
	return e.busid
}

func (e *darwinExport) staleReason() string {
	if e.pendingRegistryID != 0 {
		return "device replaced"
	}
	return "capture released"
}

func (e *darwinExport) Snapshot(busy bool) ExportSnapshot {
	stableID := darwinStableID(e.registryID)
	if e.stale {
		return ExportSnapshot{
			Entry:        e.entry,
			Backend:      BackendIDDarwinIOKit,
			StableID:     stableID,
			State:        DeviceStateUnavailable,
			StatusReason: e.staleReason(),
		}
	}
	state := DeviceStateIdle
	if busy {
		state = DeviceStateAttached
	}
	return ExportSnapshot{
		Entry:    e.entry,
		Backend:  BackendIDDarwinIOKit,
		StableID: stableID,
		State:    state,
	}
}

func (e *darwinExport) DeviceInfo() (DeviceInfoTruncated, error) {
	return e.entry.Info, nil
}

func (e *darwinExport) NewServerDataSession(ctx context.Context, conn net.Conn) (DataSession, error) {
	return newUserspaceURBSession(ctx, e.logger, conn, newDarwinIOUSBHostEngine(e.device)), nil
}

type darwinImportHost struct {
	logger logger.ContextLogger
}

func (h *darwinImportHost) Start() error {
	return nil
}

func (h *darwinImportHost) Close() error {
	return nil
}

func (h *darwinImportHost) Attach(ctx context.Context, info DeviceInfoTruncated, conn net.Conn) (AttachedSession, error) {
	controller := newDarwinVirtualController(ctx, h.logger, conn, info)
	err := controller.Start()
	if err != nil {
		_ = controller.Close()
		return nil, err
	}
	return controller, nil
}
