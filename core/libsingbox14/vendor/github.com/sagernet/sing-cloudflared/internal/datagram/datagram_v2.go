package datagram

import (
	"context"
	"io"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/control"
	"github.com/sagernet/sing-cloudflared/internal/icmp"
	"github.com/sagernet/sing-cloudflared/internal/protocol"
	"github.com/sagernet/sing-cloudflared/internal/tunnelrpc"
	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"

	"github.com/google/uuid"
	"zombiezen.com/go/capnproto2/rpc"
	"zombiezen.com/go/capnproto2/server"
)

type MuxerContext struct {
	Context        context.Context
	Logger         logger.ContextLogger
	MaxActiveFlows func() uint64
	FlowLimiter    *FlowLimiter
	DialPacket     func(ctx context.Context, destination M.Socksaddr) (N.PacketConn, error)
	ICMPHandler    icmp.RouteHandler
}

type DatagramV2Muxer struct {
	context MuxerContext
	logger  logger.ContextLogger
	sender  protocol.DatagramSender
	icmp    *icmp.Bridge

	sessionAccess sync.RWMutex
	sessions      map[uuid.UUID]*UDPSession
}

func NewDatagramV2Muxer(muxerContext MuxerContext, sender protocol.DatagramSender, log logger.ContextLogger) *DatagramV2Muxer {
	return &DatagramV2Muxer{
		context:  muxerContext,
		logger:   log,
		sender:   sender,
		icmp:     icmp.NewBridge(muxerContext.Context, muxerContext.ICMPHandler, sender, icmp.WireV2, log),
		sessions: make(map[uuid.UUID]*UDPSession),
	}
}

type RPCStreamOpener interface {
	OpenRPCStream(ctx context.Context) (io.ReadWriteCloser, error)
}

type V2SessionRPCClient interface {
	UnregisterSession(ctx context.Context, sessionID uuid.UUID, message string) error
	Close() error
}

var NewV2SessionRPCClient = func(ctx context.Context, sender protocol.DatagramSender) (V2SessionRPCClient, error) {
	opener, ok := sender.(RPCStreamOpener)
	if !ok {
		return nil, E.New("sender does not support rpc streams")
	}
	stream, err := opener.OpenRPCStream(ctx)
	if err != nil {
		return nil, err
	}
	transport := control.SafeTransport(stream)
	conn := control.NewRPCClientConn(transport)
	return &capnpV2SessionRPCClient{
		client:    tunnelrpc.SessionManager{Client: conn.Bootstrap(ctx)},
		rpcConn:   conn,
		transport: transport,
	}, nil
}

type capnpV2SessionRPCClient struct {
	client    tunnelrpc.SessionManager
	rpcConn   *rpc.Conn
	transport rpc.Transport
}

func (c *capnpV2SessionRPCClient) UnregisterSession(ctx context.Context, sessionID uuid.UUID, message string) error {
	promise := c.client.UnregisterUdpSession(ctx, func(p tunnelrpc.SessionManager_unregisterUdpSession_Params) error {
		err := p.SetSessionId(sessionID[:])
		if err != nil {
			return err
		}
		return p.SetMessage(message)
	})
	_, err := promise.Struct()
	return err
}

func (c *capnpV2SessionRPCClient) Close() error {
	return E.Errors(c.rpcConn.Close(), c.transport.Close())
}

func (m *DatagramV2Muxer) HandleDatagram(ctx context.Context, data []byte) {
	if len(data) < protocol.TypeIDLength {
		return
	}

	datagramType := protocol.DatagramV2Type(data[len(data)-protocol.TypeIDLength])
	payload := data[:len(data)-protocol.TypeIDLength]

	switch datagramType {
	case protocol.DatagramV2TypeUDP:
		m.handleUDPDatagram(ctx, payload)
	case protocol.DatagramV2TypeIP:
		err := m.icmp.HandleV2(ctx, datagramType, payload)
		if err != nil {
			m.logger.Debug("drop V2 ICMP datagram: ", err)
		}
	case protocol.DatagramV2TypeIPWithTrace:
		err := m.icmp.HandleV2(ctx, datagramType, payload)
		if err != nil {
			m.logger.Debug("drop V2 traced ICMP datagram: ", err)
		}
	case protocol.DatagramV2TypeTracingSpan:
	}
}

const SessionIDLength = 16

func (m *DatagramV2Muxer) handleUDPDatagram(ctx context.Context, data []byte) {
	if len(data) < SessionIDLength {
		return
	}

	payload := data[:len(data)-SessionIDLength]
	sessionID, err := uuid.FromBytes(data[len(data)-SessionIDLength:])
	if err != nil {
		m.logger.Debug("invalid session ID in V2 datagram: ", err)
		return
	}

	m.sessionAccess.RLock()
	session, exists := m.sessions[sessionID]
	m.sessionAccess.RUnlock()

	if !exists {
		m.logger.Debug("unknown V2 UDP session: ", sessionID)
		return
	}

	session.writeToOrigin(payload)
}

func (m *DatagramV2Muxer) RegisterSession(
	ctx context.Context,
	sessionID uuid.UUID,
	destinationIP net.IP,
	destinationPort uint16,
	closeAfterIdle time.Duration,
) error {
	if destinationIP == nil {
		return E.New("missing destination IP")
	}
	var destinationAddr netip.Addr
	if ip4 := destinationIP.To4(); ip4 != nil {
		destinationAddr = netip.AddrFrom4([4]byte(ip4))
	} else if ip16 := destinationIP.To16(); ip16 != nil {
		destinationAddr = netip.AddrFrom16([16]byte(ip16))
	} else {
		return E.New("invalid destination IP")
	}
	destination := netip.AddrPortFrom(destinationAddr, destinationPort)

	if closeAfterIdle == 0 {
		closeAfterIdle = 210 * time.Second
	}

	m.sessionAccess.Lock()
	if _, exists := m.sessions[sessionID]; exists {
		m.sessionAccess.Unlock()
		return nil
	}
	limit := m.context.MaxActiveFlows()
	if !m.context.FlowLimiter.Acquire(limit) {
		m.sessionAccess.Unlock()
		return E.New("too many active flows")
	}

	origin, err := m.context.DialPacket(ctx, M.SocksaddrFromNetIP(destination))
	if err != nil {
		m.context.FlowLimiter.Release(limit)
		m.sessionAccess.Unlock()
		return err
	}

	session := NewUDPSession(sessionID, destination, closeAfterIdle, origin, m)
	m.sessions[sessionID] = session
	m.sessionAccess.Unlock()

	m.logger.Info("registered V2 UDP session ", sessionID, " to ", destination)

	go m.serveSession(ctx, session, limit)
	return nil
}

func (m *DatagramV2Muxer) UnregisterSession(sessionID uuid.UUID, message string) {
	m.sessionAccess.Lock()
	session, exists := m.sessions[sessionID]
	if exists {
		delete(m.sessions, sessionID)
	}
	m.sessionAccess.Unlock()

	if exists {
		session.markRemoteClosed(message)
		session.close()
		m.logger.Info("unregistered V2 UDP session ", sessionID)
	}
}

func (m *DatagramV2Muxer) serveSession(ctx context.Context, session *UDPSession, limit uint64) {
	defer m.context.FlowLimiter.Release(limit)

	session.serve(ctx)

	m.sessionAccess.Lock()
	if current, exists := m.sessions[session.id]; exists && current == session {
		delete(m.sessions, session.id)
	}
	m.sessionAccess.Unlock()

	if !session.remoteClosed() {
		unregisterCtx, cancel := context.WithTimeout(context.Background(), control.RPCTimeout)
		defer cancel()
		err := m.unregisterRemoteSession(unregisterCtx, session.id, session.closeReason())
		if err != nil {
			m.logger.Debug("failed to unregister V2 UDP session ", session.id, ": ", err)
		}
	}
}

func (m *DatagramV2Muxer) sendToEdge(sessionID uuid.UUID, payload []byte) {
	data := make([]byte, len(payload)+SessionIDLength+protocol.TypeIDLength)
	copy(data, payload)
	copy(data[len(payload):], sessionID[:])
	data[len(data)-1] = byte(protocol.DatagramV2TypeUDP)
	m.sender.SendDatagram(data)
}

func (m *DatagramV2Muxer) Close() {
	m.sessionAccess.Lock()
	sessions := m.sessions
	m.sessions = make(map[uuid.UUID]*UDPSession)
	m.sessionAccess.Unlock()

	for _, session := range sessions {
		session.close()
	}
}

type UDPSession struct {
	id             uuid.UUID
	destination    netip.AddrPort
	closeAfterIdle time.Duration
	origin         N.PacketConn
	muxer          *DatagramV2Muxer

	writeChan chan []byte
	closeOnce sync.Once
	closeChan chan struct{}

	activeAccess sync.RWMutex
	activeAt     time.Time

	stateAccess       sync.RWMutex
	closedByRemote    bool
	closeReasonString string
}

func NewUDPSession(id uuid.UUID, destination netip.AddrPort, closeAfterIdle time.Duration, origin N.PacketConn, muxer *DatagramV2Muxer) *UDPSession {
	return &UDPSession{
		id:             id,
		destination:    destination,
		closeAfterIdle: closeAfterIdle,
		origin:         origin,
		muxer:          muxer,
		writeChan:      make(chan []byte, 256),
		closeChan:      make(chan struct{}),
		activeAt:       time.Now(),
	}
}

func (s *UDPSession) writeToOrigin(payload []byte) {
	data := make([]byte, len(payload))
	copy(data, payload)
	select {
	case s.writeChan <- data:
	default:
	}
}

func (s *UDPSession) close() {
	s.closeOnce.Do(func() {
		if s.origin != nil {
			_ = s.origin.Close()
		}
		close(s.closeChan)
	})
}

func (s *UDPSession) serve(ctx context.Context) {
	go s.readLoop()
	go s.writeLoop()

	tickInterval := s.closeAfterIdle / 2
	if tickInterval <= 0 || tickInterval > 10*time.Second {
		tickInterval = time.Second
	}
	ticker := time.NewTicker(tickInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			s.closeWithReason("connection closed")
		case <-ticker.C:
			if time.Since(s.lastActive()) >= s.closeAfterIdle {
				s.closeWithReason("idle timeout")
			}
		case <-s.closeChan:
			return
		}
	}
}

func (s *UDPSession) readLoop() {
	for {
		buffer := buf.NewPacket()
		_, err := s.origin.ReadPacket(buffer)
		if err != nil {
			buffer.Release()
			s.closeWithReason(err.Error())
			return
		}
		s.markActive()
		s.muxer.sendToEdge(s.id, buffer.Bytes())
		buffer.Release()
	}
}

func (s *UDPSession) writeLoop() {
	for {
		select {
		case payload := <-s.writeChan:
			err := s.origin.WritePacket(buf.As(payload), M.SocksaddrFromNetIP(s.destination))
			if err != nil {
				s.closeWithReason(err.Error())
				return
			}
			s.markActive()
		case <-s.closeChan:
			return
		}
	}
}

func (s *UDPSession) markActive() {
	s.activeAccess.Lock()
	s.activeAt = time.Now()
	s.activeAccess.Unlock()
}

func (s *UDPSession) lastActive() time.Time {
	s.activeAccess.RLock()
	defer s.activeAccess.RUnlock()
	return s.activeAt
}

func (s *UDPSession) closeWithReason(reason string) {
	s.stateAccess.Lock()
	if s.closeReasonString == "" {
		s.closeReasonString = reason
	}
	s.stateAccess.Unlock()
	s.close()
}

func (s *UDPSession) markRemoteClosed(message string) {
	s.stateAccess.Lock()
	s.closedByRemote = true
	if message != "" {
		s.closeReasonString = message
	} else if s.closeReasonString == "" {
		s.closeReasonString = "unregistered by edge"
	}
	s.stateAccess.Unlock()
}

func (s *UDPSession) remoteClosed() bool {
	s.stateAccess.RLock()
	defer s.stateAccess.RUnlock()
	return s.closedByRemote
}

func (s *UDPSession) closeReason() string {
	s.stateAccess.RLock()
	defer s.stateAccess.RUnlock()
	if s.closeReasonString == "" {
		return "session closed"
	}
	return s.closeReasonString
}

func (s *UDPSession) ReadPacket(buffer *buf.Buffer) (M.Socksaddr, error) {
	select {
	case data := <-s.writeChan:
		_, err := buffer.Write(data)
		return M.SocksaddrFromNetIP(s.destination), err
	case <-s.closeChan:
		return M.Socksaddr{}, io.EOF
	}
}

func (s *UDPSession) WritePacket(buffer *buf.Buffer, destination M.Socksaddr) error {
	s.muxer.sendToEdge(s.id, buffer.Bytes())
	return nil
}

func (s *UDPSession) Close() error {
	s.close()
	return nil
}

func (s *UDPSession) LocalAddr() net.Addr                { return nil }
func (s *UDPSession) SetDeadline(_ time.Time) error      { return nil }
func (s *UDPSession) SetReadDeadline(_ time.Time) error  { return nil }
func (s *UDPSession) SetWriteDeadline(_ time.Time) error { return nil }

func (m *DatagramV2Muxer) unregisterRemoteSession(ctx context.Context, sessionID uuid.UUID, message string) error {
	client, err := NewV2SessionRPCClient(ctx, m.sender)
	if err != nil {
		return err
	}
	defer client.Close()
	return client.UnregisterSession(ctx, sessionID, message)
}

type CloudflaredServer struct {
	applyConfig control.ConfigApplier
	muxer       *DatagramV2Muxer
	ctx         context.Context
	logger      logger.ContextLogger
}

func (s *CloudflaredServer) RegisterUdpSession(call tunnelrpc.SessionManager_registerUdpSession) error {
	server.Ack(call.Options)
	sessionIDBytes, err := call.Params.SessionId()
	if err != nil {
		return err
	}
	sessionID, err := uuid.FromBytes(sessionIDBytes)
	if err != nil {
		return err
	}

	destinationIP, err := call.Params.DstIp()
	if err != nil {
		return err
	}

	destinationPort := call.Params.DstPort()
	closeAfterIdle := time.Duration(call.Params.CloseAfterIdleHint())
	_, traceErr := call.Params.TraceContext()
	if traceErr != nil {
		return traceErr
	}

	if len(destinationIP) == 0 {
		err = E.New("missing destination IP")
	} else {
		err = s.muxer.RegisterSession(s.ctx, sessionID, net.IP(destinationIP), destinationPort, closeAfterIdle)
	}

	result, allocErr := call.Results.NewResult()
	if allocErr != nil {
		return allocErr
	}
	spansErr := result.SetSpans([]byte{})
	if spansErr != nil {
		return spansErr
	}
	if err != nil {
		result.SetErr(err.Error())
	}
	return nil
}

func (s *CloudflaredServer) UnregisterUdpSession(call tunnelrpc.SessionManager_unregisterUdpSession) error {
	server.Ack(call.Options)
	sessionIDBytes, err := call.Params.SessionId()
	if err != nil {
		return err
	}
	sessionID, err := uuid.FromBytes(sessionIDBytes)
	if err != nil {
		return err
	}

	message, err := call.Params.Message()
	if err != nil {
		return err
	}

	s.muxer.UnregisterSession(sessionID, message)
	return nil
}

func (s *CloudflaredServer) UpdateConfiguration(call tunnelrpc.ConfigurationManager_updateConfiguration) error {
	return control.HandleUpdateConfiguration(s.applyConfig, call)
}

func ServeRPCStream(ctx context.Context, stream io.ReadWriteCloser, applyConfig control.ConfigApplier, muxer *DatagramV2Muxer, log logger.ContextLogger) {
	srv := &CloudflaredServer{
		applyConfig: applyConfig,
		muxer:       muxer,
		ctx:         ctx,
		logger:      log,
	}
	client := tunnelrpc.CloudflaredServer_ServerToClient(srv)
	control.ServeRPCConn(ctx, stream, client.Client)
}
