package openvpn

import (
	"context"
	"math"
	"net"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	listenerErrorRetryInitialDelay = 5 * time.Millisecond
	listenerErrorRetryMaximumDelay = time.Second
)

// forward.c passes the result of every link_socket_read to check_status, which
// only reports the failure, and multi_io.c logs an accept() that produced no
// socket and keeps polling the listen socket: upstream never stops serving a
// listener because one datagram could not be picked up or one connection could
// not be accepted.
type listenerErrorRetry struct {
	delay time.Duration
}

func (r *listenerErrorRetry) reset() {
	r.delay = 0
}

func (r *listenerErrorRetry) wait(ctx context.Context) bool {
	if r.delay == 0 {
		r.delay = listenerErrorRetryInitialDelay
	} else {
		r.delay = min(2*r.delay, listenerErrorRetryMaximumDelay)
	}
	timer := time.NewTimer(r.delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func (s *tlsServer) listenerShutdown(err error) bool {
	select {
	case <-s.loopContext.Done():
		return true
	default:
	}
	return E.IsMulti(err, net.ErrClosed)
}

func (s *tlsServer) logListenerError(operation string, err error) {
	if s.parent.options.Logger == nil {
		return
	}
	s.parent.options.Logger.WarnContext(s.parent.options.Context, E.Cause(err, operation))
}

func (s *tlsServer) markListenerStopped(err error) {
	s.lifecycleAccess.Lock()
	s.listenerStopped = true
	s.lifecycleAccess.Unlock()
	select {
	case <-s.loopContext.Done():
		return
	default:
	}
	if err != nil {
		s.logListenerError("stopped serving the OpenVPN listener", err)
	}
}

func (s *tlsServer) runStreamAcceptLoop() {
	defer s.loopWaitGroup.Done()
	var retry listenerErrorRetry
	for {
		streamConnection, err := s.streamListener.Accept()
		if err != nil {
			if s.listenerShutdown(err) {
				s.markListenerStopped(err)
				return
			}
			if E.IsTimeout(err) {
				retry.reset()
				continue
			}
			s.logListenerError("accept OpenVPN connection", err)
			if !retry.wait(s.loopContext) {
				s.markListenerStopped(nil)
				return
			}
			continue
		}
		retry.reset()
		reservation := s.resourcePolicy.reserveInstance()
		if reservation == nil {
			_ = streamConnection.Close()
			continue
		}
		if !s.reserveLoopWorker() {
			reservation.release()
			_ = streamConnection.Close()
			s.markListenerStopped(nil)
			return
		}
		go s.runStreamSession(streamConnection, reservation)
	}
}

func (s *tlsServer) runStreamSession(streamConnection net.Conn, reservation *serverResourceReservation) {
	defer s.loopWaitGroup.Done()
	packetConnection, err := proto.NewPacketConnection(streamConnection, s.parent.protocol)
	if err != nil {
		reservation.release()
		_ = streamConnection.Close()
		return
	}
	peerAddress := streamConnection.RemoteAddr().String()
	session := s.newSession(packetConnection)
	session.resourceReservation.Store(reservation)
	defer session.releaseResourceReservation()
	defer session.finish()
	err = s.registerSession(peerAddress, session, nil)
	if err != nil {
		return
	}
	defer s.unregisterSession(session)
	clientResetPacket, protection, err := session.readClientReset(nil)
	if err != nil {
		return
	}
	err = session.runWithClientReset(clientResetPacket, protection)
	session.logTermination(err)
}

func (s *tlsServer) runPacketLoop() {
	defer s.loopWaitGroup.Done()
	readBuffer := make([]byte, math.MaxUint16)
	var retry listenerErrorRetry
	for {
		select {
		case <-s.loopContext.Done():
			s.markListenerStopped(nil)
			return
		default:
		}
		deadlineErr := s.packetListener.SetReadDeadline(time.Now().Add(time.Second))
		if deadlineErr != nil {
			if s.listenerShutdown(deadlineErr) {
				s.markListenerStopped(deadlineErr)
				return
			}
			s.logListenerError("arm OpenVPN link read deadline", deadlineErr)
			if !retry.wait(s.loopContext) {
				s.markListenerStopped(nil)
				return
			}
			continue
		}
		rawPacketBuffers, remoteAddresses, readErr := s.readListenerPackets(readBuffer)
		if len(rawPacketBuffers) > 0 {
			s.dispatchListenerPackets(rawPacketBuffers, remoteAddresses)
		}
		if readErr == nil || E.IsTimeout(readErr) {
			retry.reset()
			continue
		}
		if s.listenerShutdown(readErr) {
			s.markListenerStopped(readErr)
			return
		}
		s.logListenerError("read OpenVPN link", readErr)
		if !retry.wait(s.loopContext) {
			s.markListenerStopped(nil)
			return
		}
	}
}

func (s *tlsServer) readListenerPackets(readBuffer []byte) ([]*buf.Buffer, []net.Addr, error) {
	if s.packetBatchReader != nil {
		rawPacketBuffers, destinations, readErr := s.packetBatchReader.WaitReadPackets()
		if len(rawPacketBuffers) != len(destinations) {
			buf.ReleaseMulti(rawPacketBuffers)
			return nil, nil, E.Errors(readErr, E.New("OpenVPN link batch read reported ",
				len(rawPacketBuffers), " datagrams for ", len(destinations), " sources"))
		}
		remoteAddresses := make([]net.Addr, len(destinations))
		for i, destination := range destinations {
			remoteAddresses[i] = destination.UDPAddr()
		}
		return rawPacketBuffers, remoteAddresses, readErr
	}
	readCount, remoteAddress, readErr := s.packetListener.ReadFrom(readBuffer)
	if readCount <= 0 {
		return nil, nil, readErr
	}
	rawPacket := append([]byte{}, readBuffer[:readCount]...)
	return []*buf.Buffer{buf.As(rawPacket)}, []net.Addr{remoteAddress}, readErr
}

func (s *tlsServer) dispatchListenerPackets(rawPacketBuffers []*buf.Buffer, remoteAddresses []net.Addr) {
	defer buf.ReleaseMulti(rawPacketBuffers)
	peerAddresses := make([]string, len(remoteAddresses))
	for i, remoteAddress := range remoteAddresses {
		peerAddresses[i] = remoteAddress.String()
	}
	routes := s.findUDPPacketRoutes(rawPacketBuffers, peerAddresses)
	sessionsChanged := false
	queuedPackets := make(map[*udpPeerPacketConnection][]udpPeerPacket)
	queuedPacketConnections := make([]*udpPeerPacketConnection, 0, len(rawPacketBuffers))
	for rawPacketIndex, rawPacketBuffer := range rawPacketBuffers {
		rawPacket := rawPacketBuffer.Bytes()
		remoteAddress := remoteAddresses[rawPacketIndex]
		peerAddress := peerAddresses[rawPacketIndex]
		route := routes[rawPacketIndex]
		if route.session == nil && sessionsChanged {
			route = s.findUDPPacketRoute(rawPacket, peerAddress)
		}
		switch route.verdict {
		case udpPacketDrop:
			continue
		case udpPacketUnbound:
			if s.acceptUnboundUDPPacket(rawPacket, remoteAddress, peerAddress) {
				sessionsChanged = true
			}
			continue
		case udpPacketInitialReset:
			if s.acceptInitialUDPReset(rawPacket, remoteAddress, peerAddress) {
				sessionsChanged = true
			}
			continue
		}
		session := route.session
		udpPacketConnection, ok := session.packetConnection.(*udpPeerPacketConnection)
		if !ok {
			continue
		}
		if _, loaded := queuedPackets[udpPacketConnection]; !loaded {
			queuedPacketConnections = append(queuedPacketConnections, udpPacketConnection)
		}
		queuedPacketBuffer := buf.NewSize(rawPacketBuffer.Len())
		_, _ = queuedPacketBuffer.Write(rawPacket)
		queuedPackets[udpPacketConnection] = append(queuedPackets[udpPacketConnection], udpPeerPacket{
			buffer:        queuedPacketBuffer,
			remoteAddress: remoteAddress,
		})
	}
	for _, packetConnection := range queuedPacketConnections {
		dropped := packetConnection.pushPackets(queuedPackets[packetConnection])
		if dropped > 0 {
			s.droppedUDPPackets.Add(dropped)
		}
	}
}

func (s *tlsServer) acceptUnboundUDPPacket(rawPacket []byte, remoteAddress net.Addr, peerAddress string) bool {
	if !isPossibleUDPPreDecryptPacket(rawPacket) {
		return false
	}
	now := time.Now()
	preDecryptResult, parseErr := s.preDecryptUDPPacket(rawPacket, remoteAddress, now)
	if parseErr != nil {
		return false
	}
	if preDecryptResult.verdict == udpPreDecryptChallenge {
		writeErr := s.packetWriter.writePacketTo(preDecryptResult.challenge, remoteAddress)
		if writeErr != nil {
			s.droppedUDPPackets.Add(1)
		}
		return false
	}
	if preDecryptResult.verdict != udpPreDecryptAccept {
		return false
	}
	if !s.resourcePolicy.allowNewConnection(now) {
		return false
	}
	// Upstream refunds the initial-packet budget spent on a reset whose
	// three-way handshake completed, before the max-clients admission.
	s.resourcePolicy.refundInitialPacket()
	reservation := s.resourcePolicy.reserveInstance()
	if reservation == nil {
		return false
	}
	session := s.newUDPSession(remoteAddress, preDecryptResult.packet.LocalSessionID)
	session.resourceReservation.Store(reservation)
	registerErr := s.registerSession(peerAddress, session, remoteAddress)
	if registerErr != nil {
		session.releaseResourceReservation()
		_ = session.packetConnection.Close()
		return false
	}
	if !s.reserveLoopWorker() {
		s.unregisterSession(session)
		session.releaseResourceReservation()
		session.finish()
		return false
	}
	go func() {
		defer s.loopWaitGroup.Done()
		defer session.releaseResourceReservation()
		defer s.unregisterSession(session)
		defer session.finish()
		var sessionErr error
		if preDecryptResult.directReset {
			sessionErr = session.runWithClientReset(preDecryptResult.packet, preDecryptResult.protection)
		} else {
			sessionErr = session.runWithCookieResponse(
				preDecryptResult.packet,
				preDecryptResult.protection,
				preDecryptResult.serverSessionID,
			)
		}
		session.logTermination(sessionErr)
	}()
	return true
}

// Upstream never reaches the stateless session-id challenge for a datagram from
// an address it already serves: tls_pre_decrypt authenticates the reset against
// that instance's TM_INITIAL tls_wrap and negotiates it there, unmetered by
// --connect-freq-initial and --connect-freq, while TM_ACTIVE keeps carrying the
// tunnel until the new session authenticates.
func (s *tlsServer) acceptInitialUDPReset(rawPacket []byte, remoteAddress net.Addr, peerAddress string) bool {
	packet, protection, _, decodeErr := s.decodeUDPPreDecryptPacket(rawPacket)
	if decodeErr != nil {
		return false
	}
	validateErr := validateInitialClientReset(packet)
	if validateErr != nil {
		return false
	}
	session := s.newUDPSession(remoteAddress, packet.LocalSessionID)
	displaced, registerErr := s.registerInitialSession(peerAddress, session, remoteAddress)
	if displaced != nil {
		_ = displaced.Close()
	}
	if registerErr != nil {
		_ = session.packetConnection.Close()
		return false
	}
	if !s.reserveLoopWorker() {
		s.unregisterSession(session)
		session.finish()
		return false
	}
	go func() {
		defer s.loopWaitGroup.Done()
		defer session.releaseResourceReservation()
		defer s.unregisterSession(session)
		defer session.finish()
		session.logTermination(session.runWithClientReset(packet, protection))
	}()
	return true
}

func (s *tlsServer) newUDPSession(remoteAddress net.Addr, remoteSessionID proto.SessionID) *tlsServerSession {
	session := s.newSession(&udpPeerPacketConnection{
		writer:          s.packetWriter,
		localAddress:    s.packetWriter.listener.LocalAddr(),
		remoteAddress:   remoteAddress,
		incomingPackets: newDataPacketQueueWithCapacity[udpPeerPacket](256),
		closed:          make(chan struct{}),
	})
	session.remoteSessionID = remoteSessionID
	return session
}
