//go:build linux || (darwin && cgo) || windows

package usbip

import (
	"context"
	"net"
	"sync"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
)

type DeviceTransport interface {
	Submit(request URBRequest) URBResponse
	AbortEndpoint(endpoint uint8) error
}

type ProvidedDeviceInfo struct {
	Entry    DeviceEntry
	StableID string
}

type DynamicHost struct {
	logger logger.ContextLogger

	access     sync.Mutex
	closed     bool
	nextDevNum uint32
	exports    map[string]*dynamicExport
	lastKeys   map[string]struct{}
	events     chan struct{}
}

func NewDynamicHost(contextLogger logger.ContextLogger) *DynamicHost {
	if contextLogger == nil {
		contextLogger = logger.NOP()
	}
	return &DynamicHost{
		logger:   contextLogger,
		exports:  make(map[string]*dynamicExport),
		lastKeys: make(map[string]struct{}),
		events:   make(chan struct{}, 1),
	}
}

func (h *DynamicHost) Start() error { return nil }

func (h *DynamicHost) Close() error {
	h.access.Lock()
	h.closed = true
	h.exports = make(map[string]*dynamicExport)
	events := h.events
	h.events = nil
	h.access.Unlock()
	if events != nil {
		close(events)
	}
	return nil
}

func (h *DynamicHost) Events() (<-chan struct{}, error) {
	h.access.Lock()
	defer h.access.Unlock()
	return h.events, nil
}

func (h *DynamicHost) Reconcile(isReserved func(busid string) bool) (map[string]Export, []string, error) {
	h.access.Lock()
	defer h.access.Unlock()
	snapshot := make(map[string]Export, len(h.exports))
	current := make(map[string]struct{}, len(h.exports))
	for busid, export := range h.exports {
		snapshot[busid] = export
		current[busid] = struct{}{}
	}
	var released []string
	for busid := range h.lastKeys {
		_, stillPresent := current[busid]
		if !stillPresent {
			released = append(released, busid)
		}
	}
	h.lastKeys = current
	return snapshot, released, nil
}

func (h *DynamicHost) FinishImport(busid string) (bool, error) {
	return false, nil
}

func (h *DynamicHost) AddDevice(info ProvidedDeviceInfo, transport DeviceTransport) (string, error) {
	if transport == nil {
		return "", E.New("dynamic device: missing transport")
	}
	entry := info.Entry
	busid := entry.Info.BusIDString()
	if busid == "" {
		return "", E.New("dynamic device: missing bus id")
	}
	if err := setDeviceInfoBusID(&entry.Info, busid); err != nil {
		return "", E.Cause(err, "dynamic device")
	}
	h.access.Lock()
	defer h.access.Unlock()
	if h.closed {
		return "", E.New("dynamic host closed")
	}
	_, exists := h.exports[busid]
	if exists {
		return "", E.New("dynamic device already provided: ", busid)
	}
	if entry.Info.DevNum == 0 {
		h.nextDevNum++
		entry.Info.DevNum = h.nextDevNum
	}
	if entry.Info.BusNum == 0 {
		entry.Info.BusNum = 1
	}
	if entry.Info.PathString() == "" {
		encodePathField(&entry.Info.Path, "/dynamic/"+busid)
	}
	if entry.Info.BNumInterfaces == 0 && len(entry.Interfaces) > 0 {
		entry.Info.BNumInterfaces = uint8(len(entry.Interfaces))
	}
	h.exports[busid] = &dynamicExport{
		stableID:  info.StableID,
		busid:     busid,
		entry:     entry,
		transport: transport,
		logger:    h.logger,
	}
	h.notifyLocked()
	return busid, nil
}

func (h *DynamicHost) RemoveDevice(busid string) {
	h.access.Lock()
	_, exists := h.exports[busid]
	if exists {
		delete(h.exports, busid)
		h.notifyLocked()
	}
	h.access.Unlock()
}

func (h *DynamicHost) notifyLocked() {
	if h.events == nil {
		return
	}
	select {
	case h.events <- struct{}{}:
	default:
	}
}

type dynamicExport struct {
	stableID  string
	busid     string
	entry     DeviceEntry
	transport DeviceTransport
	logger    logger.ContextLogger
}

func (e *dynamicExport) BusID() string {
	return e.busid
}

func (e *dynamicExport) Snapshot(busy bool) ExportSnapshot {
	state := DeviceStateIdle
	if busy {
		state = DeviceStateAttached
	}
	stableID := e.stableID
	if stableID == "" {
		stableID = BackendIDDynamic.String() + ":" + e.busid
	}
	return ExportSnapshot{
		Entry:    e.entry,
		Backend:  BackendIDDynamic,
		StableID: stableID,
		State:    state,
	}
}

func (e *dynamicExport) DeviceInfo() (DeviceInfoTruncated, error) {
	return e.entry.Info, nil
}

func (e *dynamicExport) NewServerDataSession(ctx context.Context, conn net.Conn) (DataSession, error) {
	return newUserspaceURBSession(ctx, e.logger, conn, &dynamicSessionEngine{transport: e.transport}), nil
}

type dynamicSessionEngine struct {
	transport DeviceTransport
}

func (e *dynamicSessionEngine) Submit(request URBRequest) URBResponse {
	return e.transport.Submit(request)
}

func (e *dynamicSessionEngine) AbortEndpoint(endpoint uint8) error {
	return e.transport.AbortEndpoint(endpoint)
}

func (e *dynamicSessionEngine) Close() error {
	return nil
}

func NewDynamicServerService(ctx context.Context, options ServerOptions, host *DynamicHost) (*ServerService, error) {
	if host == nil {
		return nil, E.New("dynamic server: missing host")
	}
	serviceLogger := options.Logger
	if serviceLogger == nil {
		serviceLogger = logger.NOP()
	}
	ctx, cancel := context.WithCancel(ctx)
	return newServerServiceWithHost(ctx, cancel, serviceLogger, options, host), nil
}
