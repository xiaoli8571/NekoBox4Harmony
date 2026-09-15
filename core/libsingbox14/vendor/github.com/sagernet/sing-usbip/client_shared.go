//go:build linux || (darwin && cgo) || windows

package usbip

import (
	"context"
	"errors"
	"fmt"
	"net"
	"slices"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	N "github.com/sagernet/sing/common/network"
)

const (
	clientReconnectDelay         = 5 * time.Second
	controlPingInterval          = 10 * time.Second
	controlReadTimeout           = 30 * time.Second
	controlWriteTimeout          = 5 * time.Second
	controlSessionIdleHint       = "control session lost"
	controlHandshakeBackoffStart = time.Second
	controlHandshakeBackoffMax   = 30 * time.Second

	opExchangeWriteTimeout = 5 * time.Second
	opExchangeReadTimeout  = 30 * time.Second

	maxImmediateReconnects        = 3
	controlSessionHealthyDuration = 30 * time.Second
)

var (
	errImmediateReconnect = E.New("usbip control reconnect")
	errControlTransient   = E.New("usbip control transient")
	errDialFailed         = E.New("dial server")
	errImportRejected     = E.New("remote rejected import")
)

type clientAssignedWorker struct {
	target  clientTarget
	updates chan string
}

func (c *ClientService) initializeWorkers() {
	if !c.assignment.Matched() {
		return
	}
	targets := c.assignment.targets
	workers := make([]*clientAssignedWorker, len(targets))
	for i, target := range targets {
		workers[i] = &clientAssignedWorker{
			target:  target,
			updates: make(chan string, 1),
		}
	}
	c.workerAccess.Lock()
	c.assignedWorkers = workers
	c.workerAccess.Unlock()

	for _, worker := range workers {
		c.workerGroup.Add(1)
		go func(assigned *clientAssignedWorker) {
			defer c.workerGroup.Done()
			c.runAssignedWorker(assigned)
		}(worker)
	}
}

func (c *ClientService) run() {
	defer c.stopAllWorkers()

	var transientStreak int
	var immediateStreak int
	backoff := controlHandshakeBackoffStart
	immediate := true

	for {
		if !immediate {
			delay := clientReconnectDelay
			if transientStreak > 0 {
				delay = backoff
				backoff *= 2
				if backoff > controlHandshakeBackoffMax {
					backoff = controlHandshakeBackoffMax
				}
			}
			if !sleepCtx(c.ctx, delay) {
				return
			}
		}
		immediate = false

		sessionStart := time.Now()
		err := c.runControlSession()
		if c.ctx.Err() != nil {
			return
		}
		if time.Since(sessionStart) >= controlSessionHealthyDuration {
			immediateStreak = 0
		}

		if errors.Is(err, errControlTransient) {
			transientStreak++
			c.logger.Warn("control handshake ", c.serverAddr, ": ", err)
			continue
		}

		if err != nil {
			c.logger.Error("control ", c.serverAddr, ": ", err)
		}
		transientStreak = 0
		backoff = controlHandshakeBackoffStart
		if errors.Is(err, errImmediateReconnect) && immediateStreak < maxImmediateReconnects {
			immediateStreak++
			immediate = true
		}
	}
}

func (c *ClientService) runControlSession() error {
	conn, err := c.dialer.DialContext(c.ctx, N.NetworkTCP, c.serverAddr)
	if err != nil {
		return E.Cause(err, "dial ", c.serverAddr)
	}
	defer conn.Close()
	stopCloseOnCancel := closeConnOnContextDone(c.ctx, conn)
	defer stopCloseOnCancel()

	_ = conn.SetWriteDeadline(time.Now().Add(controlWriteTimeout))
	_ = conn.SetReadDeadline(time.Now().Add(controlWriteTimeout))
	err = controlHandshake(conn)
	if err != nil {
		return err
	}
	_ = conn.SetWriteDeadline(time.Time{})
	_ = conn.SetReadDeadline(time.Time{})

	pingDone := make(chan struct{})
	go c.controlPingLoop(conn, pingDone)
	defer close(pingDone)

	var reader controlReader
	for {
		err = conn.SetReadDeadline(time.Now().Add(controlReadTimeout))
		if err != nil {
			return err
		}
		var message controlMessage
		message, err = reader.read(conn)
		if err != nil {
			return E.Cause(errImmediateReconnect, controlSessionIdleHint, ": ", err)
		}
		frame := message.Frame
		switch frame.Type {
		case controlFrameDeviceSnapshot:
			var snapshot controlDeviceSnapshot
			err = unmarshalControlPayload(message.Payload, &snapshot)
			if err != nil {
				return E.Cause(errImmediateReconnect, "read device snapshot: ", err)
			}
			devices := controlDeviceInfoMap(snapshot.Devices)
			values := sortedControlDeviceInfoValues(devices)
			c.remoteAccess.Lock()
			c.remoteDevices = devices
			c.remoteAccess.Unlock()
			c.applyRemoteDeviceState(values)
		case controlFramePong:
		default:
			return E.Cause(errImmediateReconnect, "unexpected control frame ", frame.Type)
		}
	}
}

func controlHandshake(conn net.Conn) error {
	_, err := conn.Write(controlPreface[:])
	if err != nil {
		return E.Cause(errControlTransient, "write control preface: ", err)
	}
	err = writeControlMessage(conn, controlFrame{
		Type:    controlFrameHello,
		Version: controlProtocolVersion,
	}, nil)
	if err != nil {
		return E.Cause(errControlTransient, "write control hello: ", err)
	}
	var ackReader controlReader
	ackMessage, err := ackReader.read(conn)
	if err != nil {
		return E.Cause(errControlTransient, "read control ack: ", err)
	}
	if len(ackMessage.Payload) > 0 {
		return E.New("unexpected control ack payload length ", len(ackMessage.Payload))
	}
	ack := ackMessage.Frame
	if ack.Type != controlFrameAck {
		return E.New("unexpected control ack frame ", ack.Type)
	}
	if ack.Version != controlProtocolVersion {
		return E.New("unsupported control version ", ack.Version)
	}
	return nil
}

func FetchControlDeviceEntries(conn net.Conn) ([]DeviceEntry, error) {
	err := controlHandshake(conn)
	if err != nil {
		return nil, err
	}
	var reader controlReader
	for {
		var message controlMessage
		message, err = reader.read(conn)
		if err != nil {
			return nil, E.Cause(err, "read control frame")
		}
		switch message.Frame.Type {
		case controlFrameDeviceSnapshot:
			var snapshot controlDeviceSnapshot
			err = unmarshalControlPayload(message.Payload, &snapshot)
			if err != nil {
				return nil, E.Cause(err, "read device snapshot")
			}
			return controlDeviceInfoToEntries(snapshot.Devices, true), nil
		case controlFramePong:
		default:
			return nil, E.New("unexpected control frame ", message.Frame.Type)
		}
	}
}

func (c *ClientService) controlPingLoop(conn net.Conn, done <-chan struct{}) {
	ticker := time.NewTicker(controlPingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-done:
			return
		case <-ticker.C:
			_ = conn.SetWriteDeadline(time.Now().Add(controlWriteTimeout))
			err := writeControlMessage(conn, controlFrame{
				Type:    controlFramePing,
				Version: controlProtocolVersion,
			}, nil)
			_ = conn.SetWriteDeadline(time.Time{})
			if err != nil {
				_ = conn.Close()
				return
			}
		}
	}
}

func (c *ClientService) syncRemoteStateContext(ctx context.Context) error {
	entries, err := c.fetchDevList(ctx)
	if err != nil {
		return err
	}
	if !c.assignment.Matched() {
		c.applyRemoteExports(entries)
		return nil
	}
	c.applyMatchedExportsWithRetained(entries, nil)
	return nil
}

func (c *ClientService) applyRemoteDeviceState(devices []ControlDeviceInfo) {
	availableEntries := controlDeviceInfoToEntries(devices, true)
	if !c.assignment.Matched() {
		c.applyRemoteExports(availableEntries)
		return
	}
	knownKeys := make(map[string]DeviceKey, len(devices))
	for _, device := range devices {
		if device.BusID == "" {
			continue
		}
		knownKeys[device.BusID] = DeviceKey{
			BusID:     device.BusID,
			VendorID:  device.VendorID,
			ProductID: device.ProductID,
			Serial:    device.Serial,
		}
	}
	c.applyMatchedExportsWithRetained(availableEntries, knownKeys)
}

func (c *ClientService) applyRemoteExports(entries []DeviceEntry) {
	desired := make(map[string]struct{}, len(entries))
	for i := range entries {
		busid := entries[i].Info.BusIDString()
		if busid == "" {
			continue
		}
		desired[busid] = struct{}{}
	}

	c.workerAccess.Lock()
	c.assignment.SetAllDesired(desired)
	var stopCancels []context.CancelFunc
	for busid, worker := range c.allWorkers {
		if _, wanted := desired[busid]; wanted {
			continue
		}
		// A busy device is omitted from devlists; never stop the worker
		// that is the reason it is busy.
		if c.assignment.IsActive(busid) {
			continue
		}
		stopCancels = append(stopCancels, worker.cancel)
		delete(c.allWorkers, busid)
	}
	var start []string
	for busid := range desired {
		if _, exists := c.allWorkers[busid]; exists {
			continue
		}
		start = append(start, busid)
	}
	slices.Sort(start)
	for _, busid := range start {
		c.startRemoteBusIDWorkerLocked(busid)
	}
	c.workerAccess.Unlock()

	for _, cancel := range stopCancels {
		cancel()
	}
}

func (c *ClientService) applyMatchedExportsWithRetained(entries []DeviceEntry, knownKeys map[string]DeviceKey) {
	next, previous := c.assignment.ApplyMatched(entries, knownKeys)
	if next == nil {
		return
	}
	c.workerAccess.Lock()
	workers := append([]*clientAssignedWorker(nil), c.assignedWorkers...)
	c.workerAccess.Unlock()
	for i, worker := range workers {
		if previous[i] == next[i] {
			continue
		}
		worker.setDesiredBusID(next[i])
	}
}

func (c *ClientService) runAssignedWorker(worker *clientAssignedWorker) {
	var current string
	var runnerCancel context.CancelFunc
	var runnerDone chan struct{}

	stopRunner := func() {
		if runnerCancel == nil {
			return
		}
		runnerCancel()
		<-runnerDone
		runnerCancel = nil
		runnerDone = nil
	}

	for {
		select {
		case <-c.ctx.Done():
			return
		case desired := <-worker.updates:
			if desired == current {
				continue
			}
			stopRunner()
			current = desired
			if desired == "" {
				continue
			}

			runCtx, cancel := context.WithCancel(c.ctx)
			done := make(chan struct{})
			runnerCancel = cancel
			runnerDone = done

			match := worker.target.match
			if worker.target.fixedBusID != "" {
				match = DeviceMatch{BusID: worker.target.fixedBusID}
			}
			c.workerGroup.Add(1)
			go func(busid, description string, expected DeviceMatch) {
				defer c.workerGroup.Done()
				defer close(done)
				c.runBusIDLoop(runCtx, busid, description, expected)
			}(desired, describeMatch(match), match)
		}
	}
}

func (w *clientAssignedWorker) setDesiredBusID(busid string) {
	select {
	case w.updates <- busid:
		return
	default:
	}
	select {
	case <-w.updates:
	default:
	}
	w.updates <- busid
}

func (c *ClientService) startRemoteBusIDWorkerLocked(busid string) {
	runCtx, cancel := context.WithCancel(c.ctx)
	worker := &clientRemoteWorker{cancel: cancel}
	c.allWorkers[busid] = worker
	c.workerGroup.Add(1)
	go func() {
		defer c.workerGroup.Done()
		c.runBusIDLoop(runCtx, busid, busid, DeviceMatch{BusID: busid})
		cancel()
		c.workerAccess.Lock()
		if c.allWorkers[busid] == worker {
			delete(c.allWorkers, busid)
			if c.ctx.Err() == nil && c.assignment.IsRetryDesired(busid) {
				c.startRemoteBusIDWorkerLocked(busid)
			}
		}
		c.workerAccess.Unlock()
	}()
}

func (c *ClientService) stopAllWorkers() {
	c.workerAccess.Lock()
	cancels := make([]context.CancelFunc, 0, len(c.allWorkers))
	for _, worker := range c.allWorkers {
		cancels = append(cancels, worker.cancel)
	}
	c.allWorkers = make(map[string]*clientRemoteWorker)
	c.workerAccess.Unlock()

	for _, cancel := range cancels {
		cancel()
	}
}

func (c *ClientService) fetchDevList(ctx context.Context) ([]DeviceEntry, error) {
	conn, err := c.dialer.DialContext(ctx, N.NetworkTCP, c.serverAddr)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	stopCloseOnCancel := closeConnOnContextDone(ctx, conn)
	defer stopCloseOnCancel()
	_ = conn.SetWriteDeadline(time.Now().Add(opExchangeWriteTimeout))
	err = WriteOpHeader(conn, OpReqDevList, OpStatusOK)
	_ = conn.SetWriteDeadline(time.Time{})
	if err != nil {
		return nil, E.Cause(err, "send OP_REQ_DEVLIST")
	}
	_ = conn.SetReadDeadline(time.Now().Add(opExchangeReadTimeout))
	var header OpHeader
	header, err = ReadOpHeader(conn)
	if err != nil {
		return nil, E.Cause(err, "read OP_REP_DEVLIST header")
	}
	if header.Version != ProtocolVersion {
		return nil, E.New("unexpected reply version ", fmt.Sprintf("0x%04x", header.Version))
	}
	if header.Code != OpRepDevList || header.Status != OpStatusOK {
		return nil, E.New("OP_REP_DEVLIST status=", header.Status, " code=", fmt.Sprintf("0x%04x", header.Code))
	}
	return ReadOpRepDevListBody(conn)
}
