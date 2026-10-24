//go:build linux || (darwin && cgo) || windows

package usbip

import (
	"context"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/sagernet/sing/common"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type ServerService struct {
	ctx           context.Context
	cancel        context.CancelFunc
	logger        logger.ContextLogger
	listen        ListenFunc
	listenAddress M.Socksaddr
	listener      net.Listener
	matches       []DeviceMatch
	host          ExportHost
	ledger        *exportLedger

	reconcileAccess sync.Mutex

	sessionsAccess sync.Mutex
	sessions       map[DataSession]struct{}
	sessionsClosed bool
}

func NewServerService(ctx context.Context, options ServerOptions) (*ServerService, error) {
	if len(options.Devices) == 0 {
		return nil, E.New("devices: at least one match is required")
	}
	for i, deviceMatch := range options.Devices {
		if deviceMatch.IsZero() {
			return nil, E.New("devices[", i, "]: at least one of busid/vendor_id/product_id/serial is required")
		}
	}
	serviceLogger := options.Logger
	if serviceLogger == nil {
		serviceLogger = logger.NOP()
	}
	ctx, cancel := context.WithCancel(ctx)
	host, err := newPlatformExportHost(ctx, serviceLogger, options.Devices)
	if err != nil {
		cancel()
		return nil, err
	}
	return newServerServiceWithHost(ctx, cancel, serviceLogger, options, host), nil
}

func newServerServiceWithHost(ctx context.Context, cancel context.CancelFunc, serviceLogger logger.ContextLogger, options ServerOptions, host ExportHost) *ServerService {
	return &ServerService{
		ctx:           ctx,
		cancel:        cancel,
		logger:        serviceLogger,
		listen:        options.Listen,
		listenAddress: options.ListenAddress,
		matches:       options.Devices,
		host:          host,
		ledger:        newExportLedger(serviceLogger),
		sessions:      make(map[DataSession]struct{}),
	}
}

func (s *ServerService) Start() (err error) {
	defer func() {
		if err != nil {
			s.cancel()
			_ = s.host.Close()
		}
	}()
	err = s.host.Start()
	if err != nil {
		return err
	}
	events, err := s.host.Events()
	if err != nil {
		return E.Cause(err, "subscribe topology events")
	}
	err = s.reconcileAndBroadcast(false)
	if err != nil {
		return err
	}
	tcpListener, err := s.listenTCP()
	if err != nil {
		return err
	}
	go s.acceptLoop(tcpListener)
	go s.eventLoop(events)
	return nil
}

func (s *ServerService) Close() error {
	if s.cancel != nil {
		s.cancel()
	}

	s.sessionsAccess.Lock()
	s.sessionsClosed = true
	sessions := make([]DataSession, 0, len(s.sessions))
	for session := range s.sessions {
		sessions = append(sessions, session)
	}
	s.sessionsAccess.Unlock()

	for _, conn := range s.ledger.CloseAllSubscribers() {
		_ = conn.Close()
	}
	err := common.Close(s.listener)

	for _, session := range sessions {
		_ = session.Close()
	}

	s.reconcileAccess.Lock()
	defer s.reconcileAccess.Unlock()
	_ = s.host.Close()
	s.ledger.ResetForClose()
	return err
}

func (s *ServerService) ListenAddr() net.Addr {
	if s.listener == nil {
		return nil
	}
	return s.listener.Addr()
}

func (s *ServerService) DeviceSnapshot() []ControlDeviceInfo {
	return s.ledger.StateSnapshot()
}

func (s *ServerService) SubscribeDevices(ctx context.Context, listener func([]ControlDeviceInfo)) {
	id := s.ledger.AddStateListener(listener)
	defer s.ledger.RemoveStateListener(id)
	<-ctx.Done()
}

func (s *ServerService) listenTCP() (net.Listener, error) {
	if s.listen != nil {
		listener, err := s.listen(s.ctx)
		if err != nil {
			return nil, err
		}
		s.listener = listener
		return listener, nil
	}
	listenAddress := s.listenAddress
	if !listenAddress.IsValid() {
		listenAddress = M.ParseSocksaddrHostPort("127.0.0.1", DefaultPort)
	}
	var listenConfig net.ListenConfig
	tcpListener, err := listenConfig.Listen(s.ctx, N.NetworkTCP, listenAddress.String())
	if err != nil {
		return nil, err
	}
	s.logger.Info("tcp server started at ", tcpListener.Addr())
	s.listener = tcpListener
	return tcpListener, nil
}

func (s *ServerService) eventLoop(events <-chan struct{}) {
	for {
		select {
		case <-s.ctx.Done():
			return
		case _, ok := <-events:
			if !ok {
				return
			}
		}
		err := s.reconcileAndBroadcast(true)
		if err != nil {
			s.logger.Warn("reconcile exports: ", err)
		}
	}
}

func (s *ServerService) tearDownPreparedSession(busid string, session DataSession) {
	_ = session.Close()
	<-session.Done()
	released := s.finishImport(busid)
	if released {
		err := s.reconcileAndBroadcast(true)
		if err != nil {
			s.logger.Debug("reconcile after ", busid, ": ", err)
		}
	}
}

func (s *ServerService) finishImport(busid string) bool {
	s.reconcileAccess.Lock()
	defer s.reconcileAccess.Unlock()
	released, err := s.host.FinishImport(busid)
	if err != nil {
		s.logger.Debug("finish import ", busid, ": ", err)
	}
	s.ledger.ReleaseImport(busid, released)
	return released
}

func (s *ServerService) reconcileAndBroadcast(notify bool) error {
	s.reconcileAccess.Lock()
	defer s.reconcileAccess.Unlock()
	if s.ctx.Err() != nil {
		return nil
	}
	snapshot, released, err := s.host.Reconcile(s.ledger.IsReserved)
	s.ledger.ApplyHostSnapshot(snapshot, released)
	if notify {
		s.ledger.BroadcastIfChanged()
	} else {
		s.ledger.SeedBroadcastState()
	}
	return err
}

func (s *ServerService) handleStandardConn(conn net.Conn, header OpHeader) {
	closeConn := true
	defer func() {
		if closeConn {
			_ = conn.Close()
		}
	}()
	switch header.Code {
	case OpReqDevList:
		entries := s.buildDevListEntries()
		err := WriteOpRepDevList(conn, entries)
		if err != nil {
			s.logger.Debug("write devlist: ", err)
		}
	case OpReqImport:
		busid, err := ReadOpReqImportBody(conn)
		if err != nil {
			s.logger.Debug("read import body: ", err)
			break
		}
		_ = conn.SetReadDeadline(time.Time{})
		closeConn = !s.handleImportBusID(conn, busid)
	default:
		s.logger.Debug(fmt.Sprintf("unknown opcode 0x%04x", header.Code))
	}
}

func (s *ServerService) handleControlConn(conn net.Conn) {
	defer conn.Close()
	var reader controlReader
	helloMessage, err := reader.read(conn)
	if err != nil {
		s.logger.Debug("read control hello: ", err)
		return
	}
	hello := helloMessage.Frame
	if hello.Type != controlFrameHello {
		s.logger.Debug("unexpected control frame ", hello.Type, " before hello")
		return
	}
	if hello.Version != controlProtocolVersion {
		s.logger.Debug("unsupported control version ", hello.Version)
		return
	}
	_ = conn.SetReadDeadline(time.Time{})
	sub := s.ledger.Subscribe(conn)
	defer s.ledger.Unsubscribe(sub)
	_ = conn.SetWriteDeadline(time.Now().Add(controlWriteTimeout))
	err = writeControlMessage(conn, controlFrame{
		Type:    controlFrameAck,
		Version: controlProtocolVersion,
	}, nil)
	_ = conn.SetWriteDeadline(time.Time{})
	if err != nil {
		s.logger.Debug("write control ack: ", err)
		return
	}
	readDone := make(chan struct{})
	go s.readControlConn(sub, readDone)
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-readDone:
			return
		case message := <-sub.send:
			_ = conn.SetWriteDeadline(time.Now().Add(controlWriteTimeout))
			err = writeControlMessage(conn, message.Frame, message.Payload)
			_ = conn.SetWriteDeadline(time.Time{})
			if err != nil {
				s.logger.Debug("write control frame: ", err)
				return
			}
		}
	}
}

func (s *ServerService) buildDevListEntries() []DeviceEntry {
	exports := s.ledger.AvailableExports()
	if len(exports) == 0 {
		return nil
	}
	entries := make([]DeviceEntry, 0, len(exports))
	for _, export := range exports {
		snapshot := export.Snapshot(false)
		if snapshot.State != DeviceStateIdle {
			continue
		}
		entries = append(entries, snapshot.Entry)
	}
	return entries
}

func (s *ServerService) handleImportBusID(conn net.Conn, busid string) bool {
	s.reconcileAccess.Lock()
	export, ok, reason := s.ledger.TryReserveForImport(busid)
	s.reconcileAccess.Unlock()
	if !ok {
		s.logger.Info("import rejected (", busid, ": ", reason, ")")
		_ = WriteOpRepImport(conn, OpRepImport, OpStatusError, nil)
		return false
	}
	return s.handleImportReserved(conn, busid, export)
}

func (s *ServerService) handleImportReserved(conn net.Conn, busid string, export Export) bool {
	info, err := export.DeviceInfo()
	if err != nil {
		s.ledger.ReleaseImport(busid, false)
		s.logger.Warn("refresh ", busid, ": ", err)
		_ = WriteOpRepImport(conn, OpRepImport, OpStatusError, nil)
		return false
	}
	session, err := export.NewServerDataSession(s.ctx, conn)
	if err != nil {
		s.ledger.ReleaseImport(busid, false)
		s.logger.Warn("open data session ", busid, ": ", err)
		_ = WriteOpRepImport(conn, OpRepImport, OpStatusError, nil)
		return false
	}
	s.ledger.BroadcastIfChanged()
	err = WriteOpRepImport(conn, OpRepImport, OpStatusOK, &info)
	if err != nil {
		s.logger.Warn("reply import ", busid, ": ", err)
		s.tearDownPreparedSession(busid, session)
		return false
	}

	s.sessionsAccess.Lock()
	if s.sessionsClosed {
		s.sessionsAccess.Unlock()
		s.tearDownPreparedSession(busid, session)
		return false
	}
	s.sessions[session] = struct{}{}
	s.sessionsAccess.Unlock()

	err = session.Start()
	if err != nil {
		s.sessionsAccess.Lock()
		delete(s.sessions, session)
		s.sessionsAccess.Unlock()
		s.logger.Warn("start data session ", busid, ": ", err)
		s.tearDownPreparedSession(busid, session)
		return false
	}
	s.logger.Info("attached ", busid, " to remote ", conn.RemoteAddr())
	go func() {
		<-session.Done()
		s.sessionsAccess.Lock()
		delete(s.sessions, session)
		s.sessionsAccess.Unlock()
		_ = session.Close()
		released := s.finishImport(busid)
		if released {
			err := s.reconcileAndBroadcast(true)
			if err != nil {
				s.logger.Debug("reconcile after ", busid, ": ", err)
			}
		}
	}()
	return true
}
