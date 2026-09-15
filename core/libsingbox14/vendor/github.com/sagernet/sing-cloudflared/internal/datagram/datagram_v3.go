package datagram

import (
	"context"
	"encoding/binary"
	"net/netip"
	"os"
	"sync"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/icmp"
	"github.com/sagernet/sing-cloudflared/internal/protocol"
	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

const (
	V3RegistrationFlagLen = 1
	V3RegistrationPortLen = 2
	V3RegistrationIdleLen = 2
	V3RequestIDLength     = 16
	V3IPv4AddrLen         = 4
	V3IPv6AddrLen         = 16
	v3RegistrationBaseLen = 1 + V3RegistrationFlagLen + V3RegistrationPortLen + V3RegistrationIdleLen + V3RequestIDLength
	V3PayloadHeaderLen    = 1 + V3RequestIDLength
	v3RegistrationRespLen = 1 + 1 + V3RequestIDLength + 2

	V3FlagIPv6   byte = 0x01
	v3FlagTraced byte = 0x02
	v3FlagBundle byte = 0x04

	v3ResponseOK                     byte = 0x00
	V3ResponseDestinationUnreachable byte = 0x01
	v3ResponseUnableToBindSocket     byte = 0x02
	v3ResponseTooManyActiveFlows     byte = 0x03
	V3ResponseErrorWithMsg           byte = 0xFF
)

type v3RegistrationState uint8

const (
	v3RegistrationNew v3RegistrationState = iota
	v3RegistrationExisting
	v3RegistrationMigrated
)

type DatagramV3SessionManager struct {
	sessionAccess sync.RWMutex
	sessions      map[protocol.RequestID]*V3Session
}

func NewDatagramV3SessionManager() *DatagramV3SessionManager {
	return &DatagramV3SessionManager{
		sessions: make(map[protocol.RequestID]*V3Session),
	}
}

type DatagramV3Muxer struct {
	context MuxerContext
	logger  logger.ContextLogger
	sender  protocol.DatagramSender
	icmp    *icmp.Bridge
	manager *DatagramV3SessionManager
}

func NewDatagramV3Muxer(muxerContext MuxerContext, sender protocol.DatagramSender, log logger.ContextLogger, manager *DatagramV3SessionManager) *DatagramV3Muxer {
	return &DatagramV3Muxer{
		context: muxerContext,
		logger:  log,
		sender:  sender,
		icmp:    icmp.NewBridge(muxerContext.Context, muxerContext.ICMPHandler, sender, icmp.WireV3, log),
		manager: manager,
	}
}

func (m *DatagramV3Muxer) HandleDatagram(ctx context.Context, data []byte) {
	if len(data) < 1 {
		return
	}

	datagramType := protocol.DatagramV3Type(data[0])
	payload := data[1:]

	switch datagramType {
	case protocol.DatagramV3TypeRegistration:
		m.handleRegistration(ctx, payload)
	case protocol.DatagramV3TypePayload:
		m.handlePayload(payload)
	case protocol.DatagramV3TypeICMP:
		err := m.icmp.HandleV3(ctx, payload)
		if err != nil {
			m.logger.Debug("drop V3 ICMP datagram: ", err)
		}
	case protocol.DatagramV3TypeRegistrationResponse:
		m.logger.Debug("received unexpected V3 registration response")
	}
}

func (m *DatagramV3Muxer) handleRegistration(ctx context.Context, data []byte) {
	if len(data) < V3RegistrationFlagLen+V3RegistrationPortLen+V3RegistrationIdleLen+V3RequestIDLength {
		m.logger.Debug("V3 registration too short")
		return
	}

	flags := data[0]
	destinationPort := binary.BigEndian.Uint16(data[1:3])
	idleDurationSeconds := binary.BigEndian.Uint16(data[3:5])

	var requestID protocol.RequestID
	copy(requestID[:], data[5:5+V3RequestIDLength])

	offset := 5 + V3RequestIDLength
	var destination netip.AddrPort

	if flags&V3FlagIPv6 != 0 {
		if len(data) < offset+V3IPv6AddrLen {
			m.sendRegistrationResponse(requestID, V3ResponseErrorWithMsg, "registration too short for IPv6")
			return
		}
		var addr [16]byte
		copy(addr[:], data[offset:offset+V3IPv6AddrLen])
		destination = netip.AddrPortFrom(netip.AddrFrom16(addr), destinationPort)
		offset += V3IPv6AddrLen
	} else {
		if len(data) < offset+V3IPv4AddrLen {
			m.sendRegistrationResponse(requestID, V3ResponseErrorWithMsg, "registration too short for IPv4")
			return
		}
		var addr [4]byte
		copy(addr[:], data[offset:offset+V3IPv4AddrLen])
		destination = netip.AddrPortFrom(netip.AddrFrom4(addr), destinationPort)
		offset += V3IPv4AddrLen
	}

	closeAfterIdle := time.Duration(idleDurationSeconds) * time.Second
	if closeAfterIdle == 0 {
		closeAfterIdle = 210 * time.Second
	}
	if !destination.Addr().IsValid() || destination.Addr().IsUnspecified() || destination.Port() == 0 {
		m.sendRegistrationResponse(requestID, V3ResponseDestinationUnreachable, "")
		return
	}

	session, state, err := m.manager.Register(m.context, ctx, requestID, destination, closeAfterIdle, m.sender)
	if err == errTooManyActiveFlows {
		m.sendRegistrationResponse(requestID, v3ResponseTooManyActiveFlows, "")
		return
	}
	if err != nil {
		m.sendRegistrationResponse(requestID, v3ResponseUnableToBindSocket, "")
		return
	}

	if state == v3RegistrationNew {
		m.logger.Info("registered V3 UDP session to ", destination)
	}
	m.sendRegistrationResponse(requestID, v3ResponseOK, "")

	if flags&v3FlagBundle != 0 && len(data) > offset {
		session.writeToOrigin(data[offset:])
	}
}

func (m *DatagramV3Muxer) handlePayload(data []byte) {
	if len(data) < V3RequestIDLength || len(data) > V3RequestIDLength+protocol.MaxV3UDPPayloadLen {
		return
	}

	var requestID protocol.RequestID
	copy(requestID[:], data[:V3RequestIDLength])
	payload := data[V3RequestIDLength:]

	session, exists := m.manager.Get(requestID)
	if !exists {
		return
	}

	session.writeToOrigin(payload)
}

func (m *DatagramV3Muxer) sendRegistrationResponse(requestID protocol.RequestID, responseType byte, errorMessage string) {
	errorBytes := []byte(errorMessage)
	data := make([]byte, v3RegistrationRespLen+len(errorBytes))
	data[0] = byte(protocol.DatagramV3TypeRegistrationResponse)
	data[1] = responseType
	copy(data[2:2+V3RequestIDLength], requestID[:])
	binary.BigEndian.PutUint16(data[2+V3RequestIDLength:], uint16(len(errorBytes)))
	copy(data[v3RegistrationRespLen:], errorBytes)
	m.sender.SendDatagram(data)
}

func (m *DatagramV3Muxer) sendPayload(requestID protocol.RequestID, payload []byte) {
	data := make([]byte, V3PayloadHeaderLen+len(payload))
	data[0] = byte(protocol.DatagramV3TypePayload)
	copy(data[1:1+V3RequestIDLength], requestID[:])
	copy(data[V3PayloadHeaderLen:], payload)
	m.sender.SendDatagram(data)
}

func (m *DatagramV3Muxer) Close() {}

type V3Session struct {
	id             protocol.RequestID
	destination    netip.AddrPort
	closeAfterIdle time.Duration
	origin         N.PacketConn
	manager        *DatagramV3SessionManager
	muxerContext   MuxerContext

	writeChan chan []byte
	closeOnce sync.Once
	closeChan chan struct{}

	activeAccess sync.RWMutex
	activeAt     time.Time

	senderAccess sync.RWMutex
	sender       protocol.DatagramSender

	contextAccess sync.RWMutex
	connCtx       context.Context
	contextChan   chan context.Context
}

var errTooManyActiveFlows = E.New("too many active flows")

func (m *DatagramV3SessionManager) Register(
	muxerContext MuxerContext,
	ctx context.Context,
	requestID protocol.RequestID,
	destination netip.AddrPort,
	closeAfterIdle time.Duration,
	sender protocol.DatagramSender,
) (*V3Session, v3RegistrationState, error) {
	m.sessionAccess.Lock()
	if existing, exists := m.sessions[requestID]; exists {
		if existing.sender == sender {
			existing.updateContext(ctx)
			existing.markActive()
			m.sessionAccess.Unlock()
			return existing, v3RegistrationExisting, nil
		}
		existing.migrate(sender, ctx)
		existing.markActive()
		m.sessionAccess.Unlock()
		return existing, v3RegistrationMigrated, nil
	}

	limit := muxerContext.MaxActiveFlows()
	if !muxerContext.FlowLimiter.Acquire(limit) {
		m.sessionAccess.Unlock()
		return nil, 0, errTooManyActiveFlows
	}
	origin, err := muxerContext.DialPacket(ctx, M.SocksaddrFromNetIP(destination))
	if err != nil {
		muxerContext.FlowLimiter.Release(limit)
		m.sessionAccess.Unlock()
		return nil, 0, err
	}

	sessionCtx := ctx
	if sessionCtx == nil {
		sessionCtx = context.Background()
	}
	session := &V3Session{
		id:             requestID,
		destination:    destination,
		closeAfterIdle: closeAfterIdle,
		origin:         origin,
		manager:        m,
		muxerContext:   muxerContext,
		writeChan:      make(chan []byte, 512),
		closeChan:      make(chan struct{}),
		activeAt:       time.Now(),
		sender:         sender,
		connCtx:        sessionCtx,
		contextChan:    make(chan context.Context, 1),
	}
	m.sessions[requestID] = session
	m.sessionAccess.Unlock()

	go session.serve(sessionCtx, limit)
	return session, v3RegistrationNew, nil
}

func (m *DatagramV3SessionManager) Get(requestID protocol.RequestID) (*V3Session, bool) {
	m.sessionAccess.RLock()
	defer m.sessionAccess.RUnlock()
	session, exists := m.sessions[requestID]
	return session, exists
}

func (m *DatagramV3SessionManager) remove(session *V3Session) {
	m.sessionAccess.Lock()
	if current, exists := m.sessions[session.id]; exists && current == session {
		delete(m.sessions, session.id)
	}
	m.sessionAccess.Unlock()
}

func (s *V3Session) serve(ctx context.Context, limit uint64) {
	defer s.muxerContext.FlowLimiter.Release(limit)
	defer s.manager.remove(s)

	go s.readLoop()
	go s.writeLoop()

	connCtx := ctx

	tickInterval := s.closeAfterIdle / 2
	if tickInterval <= 0 || tickInterval > 10*time.Second {
		tickInterval = time.Second
	}
	ticker := time.NewTicker(tickInterval)
	defer ticker.Stop()

	for {
		select {
		case <-connCtx.Done():
			latestCtx := s.currentContext()
			if latestCtx != nil && latestCtx != connCtx {
				connCtx = latestCtx
				continue
			}
			s.close()
		case newCtx := <-s.contextChan:
			if newCtx != nil {
				connCtx = newCtx
			}
		case <-ticker.C:
			if time.Since(s.lastActive()) >= s.closeAfterIdle {
				s.close()
			}
		case <-s.closeChan:
			return
		}
	}
}

func (s *V3Session) readLoop() {
	for {
		buffer := buf.NewPacket()
		_, err := s.origin.ReadPacket(buffer)
		if err != nil {
			buffer.Release()
			s.close()
			return
		}
		if buffer.Len() > protocol.MaxV3UDPPayloadLen {
			s.muxerContext.Logger.Debug("drop oversized V3 UDP payload: ", buffer.Len())
			buffer.Release()
			continue
		}
		s.markActive()
		err = s.senderDatagram(buffer.Bytes())
		if err != nil {
			buffer.Release()
			s.close()
			return
		}
		buffer.Release()
	}
}

func (s *V3Session) writeLoop() {
	for {
		select {
		case payload := <-s.writeChan:
			err := s.origin.WritePacket(buf.As(payload), M.SocksaddrFromNetIP(s.destination))
			if err != nil {
				if E.IsMulti(err, os.ErrDeadlineExceeded) {
					s.muxerContext.Logger.Debug("drop V3 UDP payload due to write deadline exceeded")
					continue
				}
				s.close()
				return
			}
			s.markActive()
		case <-s.closeChan:
			return
		}
	}
}

func (s *V3Session) writeToOrigin(payload []byte) {
	data := make([]byte, len(payload))
	copy(data, payload)
	select {
	case s.writeChan <- data:
	default:
	}
}

func (s *V3Session) senderDatagram(payload []byte) error {
	data := make([]byte, V3PayloadHeaderLen+len(payload))
	data[0] = byte(protocol.DatagramV3TypePayload)
	copy(data[1:1+V3RequestIDLength], s.id[:])
	copy(data[V3PayloadHeaderLen:], payload)

	s.senderAccess.RLock()
	sender := s.sender
	s.senderAccess.RUnlock()
	return sender.SendDatagram(data)
}

func (s *V3Session) setSender(sender protocol.DatagramSender) {
	s.senderAccess.Lock()
	s.sender = sender
	s.senderAccess.Unlock()
}

func (s *V3Session) updateContext(ctx context.Context) {
	if ctx == nil {
		return
	}
	s.contextAccess.Lock()
	s.connCtx = ctx
	s.contextAccess.Unlock()
	select {
	case s.contextChan <- ctx:
	default:
		select {
		case <-s.contextChan:
		default:
		}
		s.contextChan <- ctx
	}
}

func (s *V3Session) migrate(sender protocol.DatagramSender, ctx context.Context) {
	s.setSender(sender)
	s.updateContext(ctx)
}

func (s *V3Session) currentContext() context.Context {
	s.contextAccess.RLock()
	defer s.contextAccess.RUnlock()
	return s.connCtx
}

func (s *V3Session) markActive() {
	s.activeAccess.Lock()
	s.activeAt = time.Now()
	s.activeAccess.Unlock()
}

func (s *V3Session) lastActive() time.Time {
	s.activeAccess.RLock()
	defer s.activeAccess.RUnlock()
	return s.activeAt
}

func (s *V3Session) close() {
	s.closeOnce.Do(func() {
		if s.origin != nil {
			_ = s.origin.Close()
		}
		close(s.closeChan)
	})
}
