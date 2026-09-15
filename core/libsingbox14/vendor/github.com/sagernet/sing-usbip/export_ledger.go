//go:build linux || (darwin && cgo) || windows

package usbip

import (
	"maps"
	"net"
	"slices"
	"strings"
	"sync"

	"github.com/sagernet/sing/common/logger"
)

type exportLedger struct {
	logger logger.ContextLogger

	broadcastAccess sync.Mutex
	nextSubID       uint64
	subs            map[uint64]*exportSubscriber
	state           map[string]ControlDeviceInfo
	nextListenerID  uint64
	stateListeners  map[uint64]func([]ControlDeviceInfo)

	inventoryAccess sync.Mutex
	exports         map[string]Export
	busy            map[string]bool
}

type exportSubscriber struct {
	id   uint64
	conn net.Conn
	send chan controlMessage
}

const controlSubscriberSendBuffer = 16

func newExportLedger(logger logger.ContextLogger) *exportLedger {
	return &exportLedger{
		logger:         logger,
		subs:           make(map[uint64]*exportSubscriber),
		state:          make(map[string]ControlDeviceInfo),
		stateListeners: make(map[uint64]func([]ControlDeviceInfo)),
		exports:        make(map[string]Export),
		busy:           make(map[string]bool),
	}
}

func (l *exportLedger) withInventoryWrite(body func() bool) {
	l.inventoryAccess.Lock()
	changed := body()
	l.inventoryAccess.Unlock()
	if changed {
		l.BroadcastIfChanged()
	}
}

func (l *exportLedger) withInventoryRead(body func()) {
	l.inventoryAccess.Lock()
	defer l.inventoryAccess.Unlock()
	body()
}

func (l *exportLedger) withInventoryWriteQuiet(body func()) {
	l.inventoryAccess.Lock()
	defer l.inventoryAccess.Unlock()
	body()
}

func (l *exportLedger) IsReserved(busid string) bool {
	var reserved bool
	l.withInventoryRead(func() {
		reserved = l.busy[busid]
	})
	return reserved
}

func (l *exportLedger) AvailableExports() []Export {
	var out []Export
	l.withInventoryRead(func() {
		out = make([]Export, 0, len(l.exports))
		for busid, export := range l.exports {
			if l.busy[busid] {
				continue
			}
			out = append(out, export)
		}
	})
	slices.SortFunc(out, func(a, b Export) int {
		return strings.Compare(a.BusID(), b.BusID())
	})
	return out
}

func (l *exportLedger) ApplyHostSnapshot(snapshot map[string]Export, released []string) {
	l.withInventoryWriteQuiet(func() {
		l.exports = snapshot
		for _, busid := range released {
			delete(l.busy, busid)
		}
	})
}

func (l *exportLedger) SeedBroadcastState() {
	l.broadcastAccess.Lock()
	l.state = controlDeviceInfoMap(l.snapshotDeviceState())
	l.broadcastAccess.Unlock()
}

func (l *exportLedger) BroadcastIfChanged() bool {
	l.broadcastAccess.Lock()
	defer l.broadcastAccess.Unlock()
	nextState := controlDeviceInfoMap(l.snapshotDeviceState())
	if maps.EqualFunc(l.state, nextState, controlDeviceInfoEqual) {
		return false
	}
	l.state = nextState
	devices := sortedControlDeviceInfoValues(nextState)
	frame := controlFrame{Type: controlFrameDeviceSnapshot, Version: controlProtocolVersion}
	payload := controlDeviceSnapshot{Devices: devices}
	for _, sub := range l.subs {
		l.enqueuePayload(sub, frame, payload)
	}
	for _, listener := range l.stateListeners {
		listener(devices)
	}
	return true
}

func (l *exportLedger) StateSnapshot() []ControlDeviceInfo {
	l.broadcastAccess.Lock()
	defer l.broadcastAccess.Unlock()
	return sortedControlDeviceInfoValues(l.state)
}

func (l *exportLedger) AddStateListener(listener func([]ControlDeviceInfo)) uint64 {
	l.broadcastAccess.Lock()
	defer l.broadcastAccess.Unlock()
	l.nextListenerID++
	id := l.nextListenerID
	l.stateListeners[id] = listener
	listener(sortedControlDeviceInfoValues(l.state))
	return id
}

func (l *exportLedger) RemoveStateListener(id uint64) {
	l.broadcastAccess.Lock()
	delete(l.stateListeners, id)
	l.broadcastAccess.Unlock()
}

func (l *exportLedger) TryReserveForImport(busid string) (Export, bool, string) {
	var (
		export Export
		ok     bool
		reason string
	)
	l.withInventoryWriteQuiet(func() {
		current, found := l.exports[busid]
		if !found {
			reason = "unknown busid"
			return
		}
		if l.busy[busid] {
			reason = DeviceStateAttached.String()
			return
		}
		l.busy[busid] = true
		export = current
		ok = true
	})
	if !ok {
		return nil, false, reason
	}
	return export, true, ""
}

func (l *exportLedger) ReleaseImport(busid string, removeExport bool) {
	l.withInventoryWrite(func() bool {
		delete(l.busy, busid)
		if removeExport {
			delete(l.exports, busid)
		}
		return true
	})
}

func (l *exportLedger) Subscribe(conn net.Conn) *exportSubscriber {
	l.broadcastAccess.Lock()
	defer l.broadcastAccess.Unlock()
	l.nextSubID++
	sub := &exportSubscriber{
		id:   l.nextSubID,
		conn: conn,
		send: make(chan controlMessage, controlSubscriberSendBuffer),
	}
	l.enqueuePayload(sub, controlFrame{
		Type:    controlFrameDeviceSnapshot,
		Version: controlProtocolVersion,
	}, controlDeviceSnapshot{Devices: sortedControlDeviceInfoValues(l.state)})
	l.subs[sub.id] = sub
	return sub
}

func (l *exportLedger) Unsubscribe(sub *exportSubscriber) {
	l.broadcastAccess.Lock()
	delete(l.subs, sub.id)
	l.broadcastAccess.Unlock()
}

func (l *exportLedger) CloseAllSubscribers() []net.Conn {
	l.broadcastAccess.Lock()
	conns := make([]net.Conn, 0, len(l.subs))
	for _, sub := range l.subs {
		conns = append(conns, sub.conn)
	}
	l.subs = make(map[uint64]*exportSubscriber)
	l.broadcastAccess.Unlock()
	return conns
}

func (l *exportLedger) ResetForClose() {
	l.withInventoryWriteQuiet(func() {
		l.exports = make(map[string]Export)
		l.busy = make(map[string]bool)
	})
}

func (l *exportLedger) snapshotDeviceState() []ControlDeviceInfo {
	type entry struct {
		export Export
		busy   bool
	}
	var entries []entry
	l.withInventoryRead(func() {
		entries = make([]entry, 0, len(l.exports))
		for busid, export := range l.exports {
			entries = append(entries, entry{export: export, busy: l.busy[busid]})
		}
	})
	if len(entries) == 0 {
		return nil
	}
	slices.SortFunc(entries, func(a, b entry) int {
		return strings.Compare(a.export.BusID(), b.export.BusID())
	})
	out := make([]ControlDeviceInfo, 0, len(entries))
	for _, e := range entries {
		snapshot := e.export.Snapshot(e.busy)
		if snapshot.State == DeviceStateUnavailable && snapshot.Entry.Info.BusIDString() == "" {
			continue
		}
		out = append(out, controlDeviceInfoFromEntry(snapshot.Entry, snapshot.Backend, snapshot.StableID, snapshot.State, snapshot.RawStatus, snapshot.StatusReason))
	}
	return out
}

func (l *exportLedger) enqueueFrame(sub *exportSubscriber, frame controlFrame) {
	select {
	case sub.send <- controlMessage{Frame: frame}:
	default:
		l.logger.Debug("control subscriber ", sub.id, " lagged behind")
		_ = sub.conn.Close()
	}
}

func (l *exportLedger) enqueuePayload(sub *exportSubscriber, frame controlFrame, payload any) {
	rawPayload, err := marshalControlPayload(payload)
	if err != nil || len(rawPayload) > maxControlPayloadLength {
		l.logger.Debug("control subscriber ", sub.id, " payload encode failed; closing")
		_ = sub.conn.Close()
		return
	}
	select {
	case sub.send <- controlMessage{Frame: frame, Payload: rawPayload}:
	default:
		l.logger.Debug("control subscriber ", sub.id, " lagged behind")
		_ = sub.conn.Close()
	}
}
