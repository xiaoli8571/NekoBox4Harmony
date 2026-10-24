//go:build linux

package usbip

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"

	"golang.org/x/sys/unix"
)

func newPlatformExportHost(ctx context.Context, logger logger.ContextLogger, matches []DeviceMatch) (ExportHost, error) {
	return newLinuxExportHost(ctx, logger, matches), nil
}

func newPlatformImportHost(logger logger.ContextLogger) (ImportHost, error) {
	return &linuxImportHost{
		logger: logger,
		ports:  make(map[int]struct{}),
	}, nil
}

func ListLocalDevices() ([]LocalDeviceInfo, error) {
	devices, err := listUSBDevices()
	if err != nil {
		return nil, err
	}
	entries := make([]LocalDeviceInfo, 0, len(devices))
	for i := range devices {
		if devices[i].DeviceClass == 0x09 {
			continue
		}
		entry := DeviceEntry{
			Info:       devices[i].toProtocol(),
			Interfaces: devices[i].Interfaces,
			Serial:     devices[i].Serial,
			Product:    devices[i].Product,
		}
		entries = append(entries, newLocalDeviceInfo("", BackendIDLinuxSysfs, entry))
	}
	return entries, nil
}

func isMissingUSBDeviceError(err error) bool {
	return errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ENODEV)
}

func linuxUSBIPStatusReason(status int) string {
	switch status {
	case usbipStatusAvailable:
		return "available"
	case usbipStatusUsed:
		return "used"
	case usbipStatusError:
		return "error"
	default:
		return fmt.Sprintf("status=0x%08x", uint32(status))
	}
}

type linuxExportIdentity struct {
	BusNum         uint32
	DevNum         uint32
	Speed          uint32
	VendorID       uint16
	ProductID      uint16
	BCDDevice      uint16
	DeviceClass    uint8
	DeviceSubClass uint8
	DeviceProtocol uint8
	ConfigValue    uint8
	NumConfigs     uint8
	NumInterfaces  uint8
	Serial         string
	Interfaces     []DeviceInterface
}

func newLinuxExportIdentity(descriptor sysfsDevice) linuxExportIdentity {
	return linuxExportIdentity{
		BusNum:         descriptor.BusNum,
		DevNum:         descriptor.DevNum,
		Speed:          descriptor.Speed,
		VendorID:       descriptor.VendorID,
		ProductID:      descriptor.ProductID,
		BCDDevice:      descriptor.BCDDevice,
		DeviceClass:    descriptor.DeviceClass,
		DeviceSubClass: descriptor.DeviceSubClass,
		DeviceProtocol: descriptor.DeviceProtocol,
		ConfigValue:    descriptor.ConfigValue,
		NumConfigs:     descriptor.NumConfigs,
		NumInterfaces:  descriptor.NumInterfaces,
		Serial:         descriptor.Serial,
		Interfaces:     slices.Clone(descriptor.Interfaces),
	}
}

func (i linuxExportIdentity) Equal(other linuxExportIdentity) bool {
	if i.BusNum != other.BusNum ||
		i.DevNum != other.DevNum ||
		i.Speed != other.Speed ||
		i.VendorID != other.VendorID ||
		i.ProductID != other.ProductID ||
		i.BCDDevice != other.BCDDevice ||
		i.DeviceClass != other.DeviceClass ||
		i.DeviceSubClass != other.DeviceSubClass ||
		i.DeviceProtocol != other.DeviceProtocol ||
		i.ConfigValue != other.ConfigValue ||
		i.NumConfigs != other.NumConfigs ||
		i.NumInterfaces != other.NumInterfaces ||
		i.Serial != other.Serial {
		return false
	}
	return slices.Equal(i.Interfaces, other.Interfaces)
}

type linuxExportHost struct {
	logger  logger.ContextLogger
	matches []DeviceMatch

	runCtx    context.Context
	runCancel context.CancelFunc

	access  sync.Mutex
	exports map[string]*linuxExport
}

type linuxReconcilePlan struct {
	toRelease []*linuxExport
	toStale   []string
	toBind    map[string]sysfsDevice
	released  []string
}

func newLinuxExportHost(ctx context.Context, logger logger.ContextLogger, matches []DeviceMatch) *linuxExportHost {
	runCtx, runCancel := context.WithCancel(ctx)
	return &linuxExportHost{
		runCtx:    runCtx,
		runCancel: runCancel,
		logger:    logger,
		matches:   matches,
		exports:   make(map[string]*linuxExport),
	}
}

func (h *linuxExportHost) Start() error {
	return ensureKernelPath(sysUsbipHostDriver, "usbip-host", "usbip-host driver")
}

func (h *linuxExportHost) Close() error {
	h.runCancel()
	h.access.Lock()
	exports := h.exports
	h.exports = make(map[string]*linuxExport)
	h.access.Unlock()
	for _, export := range exports {
		releaseErr := h.releaseExport(export)
		if releaseErr != nil {
			h.logger.Warn("rollback ", export.busid, ": ", releaseErr)
		}
	}
	return nil
}

func (h *linuxExportHost) Events() (<-chan struct{}, error) {
	ch := make(chan struct{}, 1)
	go h.ueventLoop(h.runCtx, ch)
	return ch, nil
}

func (h *linuxExportHost) ueventLoop(ctx context.Context, ch chan<- struct{}) {
	defer close(ch)
	signal := func() {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
	backoff := ueventListenerBackoffInitial
	for {
		listener, err := newUEventListener()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			h.logger.Warn("open uevent listener: ", err)
			if !sleepCtx(ctx, backoff) {
				return
			}
			backoff *= 2
			if backoff > ueventListenerBackoffMax {
				backoff = ueventListenerBackoffMax
			}
			continue
		}
		backoff = ueventListenerBackoffInitial
		listenerDone := make(chan struct{})
		go func() {
			select {
			case <-ctx.Done():
				_ = listener.Close()
			case <-listenerDone:
			}
		}()
		signal()
		for {
			err = listener.WaitUSBEvent()
			if err != nil {
				close(listenerDone)
				_ = listener.Close()
				if ctx.Err() != nil {
					return
				}
				h.logger.Warn("read uevent: ", err)
				if !sleepCtx(ctx, backoff) {
					return
				}
				backoff *= 2
				if backoff > ueventListenerBackoffMax {
					backoff = ueventListenerBackoffMax
				}
				break
			}
			signal()
		}
	}
}

const (
	ueventListenerBackoffInitial = time.Second
	ueventListenerBackoffMax     = 30 * time.Second
)

func classifyLinuxReconcile(current map[string]*linuxExport, desired map[string]sysfsDevice, isReserved func(busid string) bool, isBound func(busid string) bool) linuxReconcilePlan {
	remainingDesired := maps.Clone(desired)
	plan := linuxReconcilePlan{
		toBind: make(map[string]sysfsDevice),
	}
	for busid, export := range current {
		device, wanted := remainingDesired[busid]
		reserved := isReserved(busid)
		identityMatches := wanted && export.identity.Equal(newLinuxExportIdentity(device))
		switch {
		case export.stale:
			if reserved {
				delete(remainingDesired, busid)
				continue
			}
			plan.toRelease = append(plan.toRelease, export)
			plan.released = append(plan.released, busid)
		case identityMatches && isBound(busid):
			delete(remainingDesired, busid)
		case reserved:
			plan.toStale = append(plan.toStale, busid)
			delete(remainingDesired, busid)
		default:
			plan.toRelease = append(plan.toRelease, export)
			plan.released = append(plan.released, busid)
		}
	}
	for busid, device := range remainingDesired {
		if isReserved(busid) {
			continue
		}
		plan.toBind[busid] = device
	}
	return plan
}

func (h *linuxExportHost) Reconcile(isReserved func(busid string) bool) (map[string]Export, []string, error) {
	devices, err := listUSBDevices()
	if err != nil {
		return h.snapshotSelf(), nil, E.Cause(err, "enumerate usb devices")
	}
	keys := make([]DeviceKey, len(devices))
	for i := range devices {
		keys[i] = DeviceKey{
			BusID:     devices[i].BusID,
			VendorID:  devices[i].VendorID,
			ProductID: devices[i].ProductID,
			Serial:    devices[i].Serial,
		}
	}
	desired := make(map[string]sysfsDevice)
	for _, idx := range SelectMatches(h.matches, keys) {
		path := devices[idx].Path
		isVHCIImport := strings.Contains(path, "vhci_hcd")
		if !isVHCIImport {
			realPath, symlinkErr := filepath.EvalSymlinks(path)
			if symlinkErr == nil {
				isVHCIImport = strings.Contains(realPath, "vhci_hcd")
			}
		}
		if isVHCIImport {
			h.logger.Debug("skip vhci-imported device ", devices[idx].BusID)
			continue
		}
		if devices[idx].DeviceClass == 0x09 {
			h.logger.Warn("skip hub device ", devices[idx].BusID)
			continue
		}
		desired[devices[idx].BusID] = devices[idx]
	}

	h.access.Lock()
	current := make(map[string]*linuxExport, len(h.exports))
	maps.Copy(current, h.exports)
	h.access.Unlock()

	plan := classifyLinuxReconcile(current, desired, isReserved, func(busid string) bool {
		driver, driverErr := currentDriver(busid)
		return driverErr == nil && driver == "usbip-host"
	})
	committed := make(map[string]*linuxExport, len(current)+len(plan.toBind))
	maps.Copy(committed, current)
	var reconcileErrors []error

	for _, busid := range plan.toStale {
		cloned := cloneLinuxExport(committed[busid])
		cloned.stale = true
		committed[busid] = cloned
	}

	for _, export := range plan.toRelease {
		releaseErr := h.releaseExport(export)
		if releaseErr != nil {
			h.logger.Warn("release ", export.busid, ": ", releaseErr)
			reconcileErrors = append(reconcileErrors, E.Cause(releaseErr, "release ", export.busid))
		}
		var desiredDevice *sysfsDevice
		desiredEntry, found := desired[export.busid]
		if found {
			desiredDevice = &desiredEntry
		}
		resolved, resolveErr := h.resolveCommittedRelease(export, desiredDevice)
		if resolveErr != nil {
			reconcileErrors = append(reconcileErrors, resolveErr)
		}
		if resolved == nil {
			delete(committed, export.busid)
			continue
		}
		committed[export.busid] = resolved
	}

	for busid, device := range plan.toBind {
		_, found := committed[busid]
		if found {
			continue
		}
		previousDriver, probeErr := currentDriver(busid)
		if probeErr != nil {
			reconcileErrors = append(reconcileErrors, E.Cause(probeErr, "probe driver before bind ", busid))
		}
		export, bindErr := h.bindOne(&device)
		if bindErr == nil {
			committed[busid] = export
			continue
		}
		reconcileErrors = append(reconcileErrors, E.Cause(bindErr, "bind ", busid))
		resolved, resolveErr := h.resolveCommittedBind(busid, &device, previousDriver)
		if resolveErr != nil {
			reconcileErrors = append(reconcileErrors, resolveErr)
		}
		if resolved != nil {
			committed[busid] = resolved
		}
	}

	released := make([]string, 0, len(plan.released))
	for _, busid := range plan.released {
		export, found := committed[busid]
		if found && !export.stale {
			continue
		}
		released = append(released, busid)
	}

	h.access.Lock()
	h.exports = committed
	h.access.Unlock()

	return snapshotLinuxExports(committed), released, E.Errors(reconcileErrors...)
}

func (h *linuxExportHost) FinishImport(busid string) (bool, error) {
	err := writeSysfs(filepath.Join(sysBusUSBDevices, busid, "usbip_sockfd"), "-1")
	if err != nil && !os.IsNotExist(err) && !isMissingUSBDeviceError(err) {
		h.logger.Debug("release ", busid, " from usbip-host: ", err)
	}
	waitForUsbipStatusCleared(h.runCtx, busid)
	h.access.Lock()
	export, ok := h.exports[busid]
	h.access.Unlock()
	if !ok || !export.stale {
		return false, nil
	}
	releaseErr := h.releaseExport(export)
	h.access.Lock()
	current, stillPresent := h.exports[busid]
	if stillPresent && current == export {
		delete(h.exports, busid)
	}
	h.access.Unlock()
	if releaseErr != nil {
		h.logger.Warn("release stale ", busid, ": ", releaseErr)
	}
	return true, E.Errors(err, releaseErr)
}

func (h *linuxExportHost) snapshotSelf() map[string]Export {
	h.access.Lock()
	defer h.access.Unlock()
	return snapshotLinuxExports(h.exports)
}

func snapshotLinuxExports(exports map[string]*linuxExport) map[string]Export {
	out := make(map[string]Export, len(exports))
	for busid, export := range exports {
		out[busid] = export
	}
	return out
}

func cloneLinuxExport(export *linuxExport) *linuxExport {
	clone := *export
	clone.descriptor.Interfaces = slices.Clone(export.descriptor.Interfaces)
	clone.identity.Interfaces = slices.Clone(export.identity.Interfaces)
	return &clone
}

func (h *linuxExportHost) resolveCommittedRelease(export *linuxExport, desired *sysfsDevice) (*linuxExport, error) {
	if desired != nil {
		resolved, found, err := h.probeDesiredBoundExport(export.busid, desired, export.originalDriver)
		if err != nil {
			return export, err
		}
		if found {
			return resolved, nil
		}
	}
	driver, err := currentDriver(export.busid)
	if err != nil {
		return export, E.Cause(err, "probe driver ", export.busid)
	}
	if driver != "usbip-host" {
		return nil, nil
	}
	return export, nil
}

func (h *linuxExportHost) resolveCommittedBind(busid string, desired *sysfsDevice, originalDriver string) (*linuxExport, error) {
	if desired == nil {
		return nil, nil
	}
	resolved, found, err := h.probeDesiredBoundExport(busid, desired, originalDriver)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, nil
	}
	return resolved, nil
}

func (h *linuxExportHost) probeDesiredBoundExport(busid string, desired *sysfsDevice, originalDriver string) (*linuxExport, bool, error) {
	driver, err := currentDriver(busid)
	if err != nil {
		return nil, false, E.Cause(err, "probe driver ", busid)
	}
	if driver != "usbip-host" {
		return nil, false, nil
	}
	descriptor, err := readSysfsDevice(busid, filepath.Join(sysBusUSBDevices, busid))
	if err != nil {
		descriptor = *desired
	} else if !newLinuxExportIdentity(descriptor).Equal(newLinuxExportIdentity(*desired)) {
		return nil, false, nil
	}
	return h.newExport(descriptor, originalDriver), true, nil
}

func (h *linuxExportHost) bindOne(d *sysfsDevice) (*linuxExport, error) {
	var (
		export *linuxExport
		err    error
	)
	for attempt := range 2 {
		export, err = h.bindOneOnce(d)
		if err == nil {
			return export, nil
		}
		if attempt > 0 || !errors.Is(err, unix.ENODEV) {
			break
		}
		_, statErr := os.Stat(filepath.Join(sysBusUSBDevices, d.BusID))
		if statErr != nil {
			// The device left mid-bind: mundane hotplug churn, not a
			// wedged driver. Reloading here can yank the module while
			// the departed device's stub teardown is still in flight,
			// which wedges usbip_host in the kernel (refcount underflow,
			// unrecoverable without a reboot).
			break
		}
		h.logger.Warn("reset usbip-host after bind failure on ", d.BusID, ": ", err)
		h.access.Lock()
		active := len(h.exports) > 0
		h.access.Unlock()
		if active {
			return nil, E.Cause(E.New("tracked usbip-host exports are present"), "reset usbip-host after bind failure")
		}
		bound, scanErr := usbipHostBoundBusIDs()
		if scanErr != nil {
			return nil, E.Cause(scanErr, "reset usbip-host after bind failure")
		}
		bound = slices.DeleteFunc(bound, func(busid string) bool { return busid == d.BusID })
		if len(bound) > 0 {
			return nil, E.Cause(E.New("usbip-host has bound devices: ", strings.Join(bound, " ")), "reset usbip-host after bind failure")
		}
		resetErr := reloadHostDriver()
		if resetErr != nil {
			return nil, E.Cause(resetErr, "reset usbip-host after bind failure")
		}
	}
	return nil, err
}

func (h *linuxExportHost) bindOneOnce(d *sysfsDevice) (*linuxExport, error) {
	driver, err := currentDriver(d.BusID)
	if err != nil {
		return nil, err
	}
	if driver == "usbip-host" {
		h.logger.Info("device ", d.BusID, " already bound to usbip-host; adopting")
		return h.newExport(*d, ""), nil
	}
	if driver != "" {
		err = writeSysfs(filepath.Join("/sys/bus/usb/drivers", driver, "unbind"), d.BusID)
		if err != nil {
			return nil, E.Cause(err, "unbind from ", driver)
		}
	}
	matchBusIDPath := filepath.Join(sysUsbipHostDriver, "match_busid")
	err = writeSysfs(matchBusIDPath, "add "+d.BusID)
	if err != nil {
		if driver != "" {
			_ = writeSysfs(filepath.Join("/sys/bus/usb/drivers", driver, "bind"), d.BusID)
		}
		return nil, E.Cause(err, "match_busid add")
	}
	err = writeSysfs(filepath.Join(sysUsbipHostDriver, "bind"), d.BusID)
	if err != nil {
		_ = writeSysfs(matchBusIDPath, "del "+d.BusID)
		if driver != "" {
			_ = writeSysfs(filepath.Join("/sys/bus/usb/drivers", driver, "bind"), d.BusID)
		}
		return nil, E.Cause(err, "bind to usbip-host")
	}
	previousDriver := driver
	if previousDriver == "" {
		previousDriver = "(no driver)"
	}
	h.logger.Info("exported ", d.BusID, " (previously on ", previousDriver, ")")
	return h.newExport(*d, driver), nil
}

func (h *linuxExportHost) releaseExport(export *linuxExport) error {
	status, statusErr := readUsbipStatus(export.busid)
	if statusErr != nil && !os.IsNotExist(statusErr) && !isMissingUSBDeviceError(statusErr) {
		return statusErr
	}
	if statusErr == nil && status == usbipStatusUsed {
		err := writeSysfs(filepath.Join(sysBusUSBDevices, export.busid, "usbip_sockfd"), "-1")
		if err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	err := writeSysfs(filepath.Join(sysUsbipHostDriver, "unbind"), export.busid)
	if err != nil && !os.IsNotExist(err) && !isMissingUSBDeviceError(err) {
		return err
	}
	delErr := writeSysfs(filepath.Join(sysUsbipHostDriver, "match_busid"), "del "+export.busid)
	if delErr != nil && (os.IsNotExist(delErr) || isMissingUSBDeviceError(delErr)) {
		delErr = nil
	}
	if delErr != nil {
		delErr = E.Cause(delErr, "match_busid del ", export.busid)
	}
	descriptor, err := readSysfsDevice(export.busid, filepath.Join(sysBusUSBDevices, export.busid))
	if err != nil {
		if os.IsNotExist(err) || isMissingUSBDeviceError(err) {
			h.logger.Info("removed export state for ", export.busid)
			return delErr
		}
		return E.Errors(delErr, E.Cause(err, "read current device ", export.busid))
	}
	if export.originalDriver != "" && export.identity.Equal(newLinuxExportIdentity(descriptor)) {
		err = writeSysfs(filepath.Join("/sys/bus/usb/drivers", export.originalDriver, "bind"), export.busid)
		if err == nil {
			h.logger.Info("restored ", export.busid, " to ", export.originalDriver)
			return delErr
		}
		h.logger.Warn("bind ", export.busid, " back to ", export.originalDriver, ": ", err)
	}
	// Device replaced while exported, original driver unknown, or the
	// precise re-bind failed. The USB core never re-probes a driverless
	// device on its own — without an explicit re-probe the device stays
	// dead until physically replugged.
	err = h.reprobeDevice(export.busid)
	if err != nil {
		return E.Errors(delErr, E.Cause(err, "re-probe ", export.busid))
	}
	h.logger.Info("released ", export.busid, " for driver re-probe")
	return delErr
}

// usbip-host's rebind attribute calls device_attach — the path the
// official usbip unbind tool uses; drivers_probe is the bus-generic
// fallback.
func (h *linuxExportHost) reprobeDevice(busid string) error {
	err := writeSysfs(filepath.Join(sysUsbipHostDriver, "rebind"), busid)
	if err == nil {
		return nil
	}
	probeErr := writeSysfs("/sys/bus/usb/drivers_probe", busid)
	if probeErr == nil {
		return nil
	}
	return E.Errors(err, probeErr)
}

func (h *linuxExportHost) newExport(descriptor sysfsDevice, originalDriver string) *linuxExport {
	return &linuxExport{
		busid:          descriptor.BusID,
		descriptor:     descriptor,
		identity:       newLinuxExportIdentity(descriptor),
		originalDriver: originalDriver,
		logger:         h.logger,
	}
}

type linuxExport struct {
	busid          string
	descriptor     sysfsDevice
	identity       linuxExportIdentity
	originalDriver string
	logger         logger.ContextLogger
	stale          bool
}

func (e *linuxExport) BusID() string {
	return e.busid
}

func (e *linuxExport) Snapshot(busy bool) ExportSnapshot {
	stableID := "linux-busid:" + e.descriptor.BusID
	if e.descriptor.Serial != "" {
		stableID = fmt.Sprintf("usb:%04x:%04x:%s", e.descriptor.VendorID, e.descriptor.ProductID, e.descriptor.Serial)
	}
	if e.stale {
		return ExportSnapshot{
			Entry: DeviceEntry{
				Info:       e.descriptor.toProtocol(),
				Interfaces: e.descriptor.Interfaces,
				Serial:     e.descriptor.Serial,
				Product:    e.descriptor.Product,
			},
			Backend:      BackendIDLinuxSysfs,
			StableID:     stableID,
			State:        DeviceStateUnavailable,
			StatusReason: "device replaced",
		}
	}
	status, statusErr := readUsbipStatus(e.busid)
	var (
		state  DeviceState
		reason string
	)
	switch {
	case statusErr != nil:
		state = DeviceStateUnavailable
		reason = statusErr.Error()
	case busy:
		status = usbipStatusUsed
		state = DeviceStateAttached
		reason = linuxUSBIPStatusReason(status)
	case status == usbipStatusAvailable:
		state = DeviceStateIdle
		reason = linuxUSBIPStatusReason(status)
	case status == usbipStatusUsed:
		state = DeviceStateAttached
		reason = linuxUSBIPStatusReason(status)
	default:
		state = DeviceStateUnavailable
		reason = linuxUSBIPStatusReason(status)
	}
	return ExportSnapshot{
		Entry: DeviceEntry{
			Info:       e.descriptor.toProtocol(),
			Interfaces: e.descriptor.Interfaces,
			Serial:     e.descriptor.Serial,
			Product:    e.descriptor.Product,
		},
		Backend:      BackendIDLinuxSysfs,
		StableID:     stableID,
		State:        state,
		StatusReason: reason,
		RawStatus:    status,
	}
}

func (e *linuxExport) DeviceInfo() (DeviceInfoTruncated, error) {
	return e.descriptor.toProtocol(), nil
}

func (e *linuxExport) NewServerDataSession(ctx context.Context, conn net.Conn) (DataSession, error) {
	if e.stale {
		return nil, E.New("linux export ", e.busid, " is stale")
	}
	handoff, err := newKernelHandoffSession(ctx, conn, e.logger, "server", e.busid)
	if err != nil {
		return nil, E.Cause(err, "prepare handoff")
	}
	mode := "direct"
	if handoff.relayConn != nil {
		mode = "relay"
	}
	e.logger.Debug("usbip server handoff ", e.busid, ": ", mode)
	err = writeSysfs(filepath.Join(sysBusUSBDevices, e.busid, "usbip_sockfd"), strconv.Itoa(int(handoff.file.Fd())))
	if err != nil {
		handoff.abortPreservingConn()
		return nil, E.Cause(err, "hand off ", e.busid, " to kernel")
	}
	closeErr := handoff.closeKernelFD()
	if closeErr != nil {
		e.logger.Debug("close kernel fd ", e.busid, ": ", closeErr)
	}
	return handoff, nil
}

type linuxImportHost struct {
	logger logger.ContextLogger

	portsAccess sync.Mutex
	ports       map[int]struct{}
}

func (h *linuxImportHost) Start() error {
	return ensureKernelPath(sysVHCIControllerV0, "vhci-hcd", "vhci_hcd.0")
}

func (h *linuxImportHost) Close() error {
	return nil
}

func (h *linuxImportHost) Attach(ctx context.Context, info DeviceInfoTruncated, conn net.Conn) (AttachedSession, error) {
	handoff, err := newKernelHandoffSession(ctx, conn, h.logger, "client", info.BusIDString())
	if err != nil {
		return nil, E.Cause(err, "prepare handoff")
	}
	mode := "direct"
	if handoff.relayConn != nil {
		mode = "relay"
	}
	h.logger.Debug("usbip client handoff ", info.BusIDString(), ": ", mode)
	port, attachErr := h.attachOnce(ctx, info, handoff)
	if attachErr != nil {
		_ = handoff.Close()
		return nil, attachErr
	}
	_ = handoff.Start()
	return &linuxClientSession{
		handoff: handoff,
		host:    h,
		port:    port,
	}, nil
}

func (h *linuxImportHost) attachOnce(ctx context.Context, info DeviceInfoTruncated, handoff *kernelHandoffSession) (int, error) {
	triedPorts := make(map[int]struct{})
	for {
		port, err := vhciPickFreePort(info.Speed, triedPorts)
		if err != nil {
			return -1, err
		}
		if !h.reservePort(port) {
			triedPorts[port] = struct{}{}
			continue
		}
		attachLine := fmt.Sprintf("%d %d %d %d", port, int(handoff.file.Fd()), info.DevID(), info.Speed)
		err = writeSysfs(filepath.Join(sysVHCIControllerV0, "attach"), attachLine)
		if err != nil {
			h.releasePort(port)
			if errors.Is(err, unix.EBUSY) {
				triedPorts[port] = struct{}{}
				continue
			}
			return -1, E.Cause(err, "vhci attach")
		}
		err = handoff.closeKernelFD()
		if err != nil {
			h.logger.Debug("close kernel fd ", info.BusIDString(), ": ", err)
		}
		return port, nil
	}
}

func (h *linuxImportHost) reservePort(port int) bool {
	h.portsAccess.Lock()
	defer h.portsAccess.Unlock()
	_, exists := h.ports[port]
	if exists {
		h.logger.Debug("vhci port ", port, " already reserved locally")
		return false
	}
	h.logger.Debug("reserve vhci port ", port)
	h.ports[port] = struct{}{}
	return true
}

func (h *linuxImportHost) releasePort(port int) {
	h.portsAccess.Lock()
	defer h.portsAccess.Unlock()
	h.logger.Debug("release vhci port ", port)
	delete(h.ports, port)
}

type linuxClientSession struct {
	handoff *kernelHandoffSession
	host    *linuxImportHost
	port    int

	closeOnce sync.Once
	closeErr  error
}

func (s *linuxClientSession) Done() <-chan struct{} {
	return s.handoff.Done()
}

func (s *linuxClientSession) Err() error {
	return s.handoff.Err()
}

func (s *linuxClientSession) Start() error {
	return s.handoff.Start()
}

func (s *linuxClientSession) Close() error {
	s.closeOnce.Do(func() {
		detachErr := writeSysfs(filepath.Join(sysVHCIControllerV0, "detach"), strconv.Itoa(s.port))
		closeErr := s.handoff.Close()
		s.host.releasePort(s.port)
		s.closeErr = E.Errors(detachErr, closeErr)
	})
	return s.closeErr
}

func (s *linuxClientSession) Description() string {
	return fmt.Sprintf("vhci_hcd.0 port %d", s.port)
}
