package openvpn

import (
	"context"
	"crypto/tls"
	"fmt"
	"math"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	"github.com/sagernet/sing/common/buf"
	"github.com/sagernet/sing/common/bufio"
	E "github.com/sagernet/sing/common/exceptions"
	N "github.com/sagernet/sing/common/network"
)

type tlsServer struct {
	parent              *Server
	tlsConfiguration    *tls.Config
	staticProtection    tlsControlProtection
	sessionAccess       sync.RWMutex
	sessionByPeer       map[string]*tlsServerSession
	sessionByIdentity   map[string]*tlsServerSession
	sessionByPeerID     map[uint32]*tlsServerSession
	udpSessionByAddress map[string]*tlsServerSession
	// Upstream keeps TM_ACTIVE and TM_INITIAL side by side inside the instance
	// which owns a source address, so a peer negotiating a new session on an
	// address already carrying a tunnel does not disturb that tunnel.
	udpInitialSessionByAddress map[string]*tlsServerSession
	loopContext                context.Context
	cancelLoop                 context.CancelFunc
	loopWaitGroup              sync.WaitGroup
	lifecycleAccess            sync.Mutex
	lifecycleState             serverLifecycleState
	listenerStopped            bool
	closeDone                  chan struct{}
	closeErr                   error
	streamListener             net.Listener
	packetListener             net.PacketConn
	packetBatchReader          N.PacketBatchReadWaiter
	packetWriter               *udpPacketWriter
	resourcePolicy             *serverResourcePolicy
	sessionCounter             uint64
	droppedUDPPackets          atomic.Uint64
	sessionIDHMACSigner        *sessionIDHMACSigner
}

func newTLSServer(parent *Server) (*tlsServer, error) {
	tlsConfiguration, err := buildTLSServerConfiguration(parent.options)
	if err != nil {
		return nil, err
	}
	staticProtection, err := newTLSServerProtection(parent.options)
	if err != nil {
		return nil, err
	}
	sessionIDHMACSignerInstance, err := newSessionIDHMACSigner()
	if err != nil {
		return nil, err
	}
	return &tlsServer{
		parent:                     parent,
		tlsConfiguration:           tlsConfiguration,
		staticProtection:           staticProtection,
		sessionByPeer:              make(map[string]*tlsServerSession),
		sessionByIdentity:          make(map[string]*tlsServerSession),
		sessionByPeerID:            make(map[uint32]*tlsServerSession),
		udpSessionByAddress:        make(map[string]*tlsServerSession),
		udpInitialSessionByAddress: make(map[string]*tlsServerSession),
		resourcePolicy:             newServerResourcePolicy(parent.options),
		closeDone:                  make(chan struct{}),
		sessionIDHMACSigner:        sessionIDHMACSignerInstance,
	}, nil
}

func newTLSServerProtection(options ServerOptions) (tlsControlProtection, error) {
	switch {
	case options.TLS.CryptV2.IsSet():
		serverKey, err := loadTLSCryptV2ServerKey(options.TLS.CryptV2)
		if err != nil {
			return tlsControlProtection{}, err
		}
		return tlsControlProtection{cryptV2ServerKey: serverKey}, nil
	case options.TLS.Crypt.IsSet():
		cryptCodec, err := newControlCryptCodec(options.TLS.Crypt, tlsCryptKeyDirectionNormal)
		if err != nil {
			return tlsControlProtection{}, err
		}
		return tlsControlProtection{crypt: cryptCodec}, nil
	case options.TLS.Auth.IsSet():
		authName := options.DataChannel.Auth
		if authName == "" || authName == "NONE" {
			authName = "SHA1"
		}
		authCodec, err := newControlAuthCodecWithAuth(options.TLS.Auth, options.KeyDirection, authName)
		if err != nil {
			return tlsControlProtection{}, err
		}
		return tlsControlProtection{auth: authCodec}, nil
	default:
		return tlsControlProtection{}, nil
	}
}

func (s *tlsServer) Start() error {
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	switch s.lifecycleState {
	case serverLifecycleRunning:
		return nil
	case serverLifecycleStarting:
		return nil
	case serverLifecycleClosing, serverLifecycleClosed:
		return ErrServerClosed
	}
	s.lifecycleState = serverLifecycleStarting
	s.loopContext, s.cancelLoop = context.WithCancel(s.parent.options.Context)
	err := s.loopContext.Err()
	if err != nil {
		s.resetFailedStartLocked()
		return err
	}
	if strings.HasPrefix(s.parent.protocol, "tcp") {
		streamListener := s.parent.options.Transport.Listener
		if streamListener == nil {
			var streamListenErr error
			streamListener, streamListenErr = net.Listen(s.parent.listenNetwork, s.parent.options.Transport.ListenAddress)
			if streamListenErr != nil {
				s.resetFailedStartLocked()
				return streamListenErr
			}
		}
		if streamListener == nil {
			s.resetFailedStartLocked()
			return ErrMissingListenAddress
		}
		s.streamListener = streamListener
		s.lifecycleState = serverLifecycleRunning
		s.loopWaitGroup.Add(1)
		go s.runStreamAcceptLoop()
		return nil
	}
	packetListener := s.parent.options.Transport.PacketConn
	if packetListener == nil {
		var packetListenErr error
		packetListener, packetListenErr = net.ListenPacket(s.parent.listenNetwork, s.parent.options.Transport.ListenAddress)
		if packetListenErr != nil {
			s.resetFailedStartLocked()
			return packetListenErr
		}
	}
	if packetListener == nil {
		s.resetFailedStartLocked()
		return ErrMissingListenAddress
	}
	s.packetListener = packetListener
	s.packetWriter = &udpPacketWriter{listener: packetListener}
	packetConnection := bufio.NewPacketConn(packetListener)
	s.packetBatchReader, _ = bufio.CreatePacketBatchReadWaiter(packetConnection)
	if s.packetBatchReader != nil {
		s.packetBatchReader.InitializeReadWaiter(N.ReadWaitOptions{
			MTU:       math.MaxUint16,
			BatchSize: dataPacketBatchSize,
		})
	}
	s.packetWriter.batchWriter, _ = bufio.CreatePacketBatchWriter(packetConnection)
	s.lifecycleState = serverLifecycleRunning
	s.loopWaitGroup.Add(1)
	go s.runPacketLoop()
	return nil
}

func (s *tlsServer) resetFailedStartLocked() {
	if s.cancelLoop != nil {
		s.cancelLoop()
	}
	s.loopContext = nil
	s.cancelLoop = nil
	s.lifecycleState = serverLifecycleInitial
}

func (s *tlsServer) Close() error {
	s.lifecycleAccess.Lock()
	switch s.lifecycleState {
	case serverLifecycleClosing:
		closeDone := s.closeDone
		s.lifecycleAccess.Unlock()
		<-closeDone
		s.lifecycleAccess.Lock()
		closeErr := s.closeErr
		s.lifecycleAccess.Unlock()
		return closeErr
	case serverLifecycleClosed:
		closeErr := s.closeErr
		s.lifecycleAccess.Unlock()
		return closeErr
	default:
		s.lifecycleState = serverLifecycleClosing
		s.lifecycleAccess.Unlock()
	}

	if s.cancelLoop != nil {
		s.cancelLoop()
	}
	var closeErr error
	if s.streamListener != nil {
		closeErr = E.Errors(closeErr, s.streamListener.Close())
	}
	if s.packetListener != nil {
		closeErr = E.Errors(closeErr, s.packetListener.Close())
	}
	s.sessionAccess.Lock()
	sessions := make([]*tlsServerSession, 0, len(s.sessionByPeer))
	for _, session := range s.sessionByPeer {
		sessions = append(sessions, session)
	}
	s.sessionAccess.Unlock()
	for _, session := range sessions {
		_ = session.Close()
	}
	s.loopWaitGroup.Wait()

	s.lifecycleAccess.Lock()
	s.closeErr = closeErr
	s.lifecycleState = serverLifecycleClosed
	close(s.closeDone)
	s.lifecycleAccess.Unlock()
	return closeErr
}

func (s *tlsServer) WriteDataPackets(peerAddress string, payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	if !s.isRunning() {
		return ErrServerClosed
	}
	session := s.getSession(peerAddress)
	if session == nil {
		return ErrPeerNotFound
	}
	return session.WriteDataPackets(payloads)
}

func (s *tlsServer) WriteDataPacketBuffers(peerAddress string, payloads []*buf.Buffer) error {
	if len(payloads) == 0 {
		return nil
	}
	if !s.isRunning() {
		buf.ReleaseMulti(payloads)
		return ErrServerClosed
	}
	session := s.getSession(peerAddress)
	if session == nil {
		buf.ReleaseMulti(payloads)
		return ErrPeerNotFound
	}
	return session.WriteDataPacketBuffers(payloads)
}

func (s *tlsServer) isRunning() bool {
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	return s.lifecycleState == serverLifecycleRunning && !s.listenerStopped
}

func (s *tlsServer) reserveLoopWorker() bool {
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	if s.lifecycleState != serverLifecycleRunning {
		return false
	}
	s.loopWaitGroup.Add(1)
	return true
}

func (s *tlsServer) getSession(peerAddress string) *tlsServerSession {
	s.sessionAccess.Lock()
	defer s.sessionAccess.Unlock()
	return s.sessionByPeer[peerAddress]
}

func (s *tlsServer) registerSession(initialPeerAddress string, session *tlsServerSession, udpAddress net.Addr) error {
	if session == nil || initialPeerAddress == "" {
		return ErrPeerNotFound
	}
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	if s.lifecycleState != serverLifecycleRunning {
		return ErrServerClosed
	}
	s.sessionAccess.Lock()
	defer s.sessionAccess.Unlock()
	if udpAddress != nil {
		if existing := s.udpSessionByAddress[udpAddress.String()]; existing != nil && existing != session {
			return ErrServerResourceLimit
		}
	}
	s.bindPeerAddressLocked(initialPeerAddress, session)
	if udpAddress != nil {
		s.udpSessionByAddress[udpAddress.String()] = session
	}
	return nil
}

// Upstream tls_pre_decrypt negotiates a hard reset which matches no session of
// the instance serving its source address in that instance's TM_INITIAL slot,
// which holds one session at a time: the newest reset takes the slot over.  The
// displaced session is returned so the caller ends it outside the registries.
func (s *tlsServer) registerInitialSession(initialPeerAddress string, session *tlsServerSession, udpAddress net.Addr) (*tlsServerSession, error) {
	if session == nil || initialPeerAddress == "" || udpAddress == nil {
		return nil, ErrPeerNotFound
	}
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	if s.lifecycleState != serverLifecycleRunning {
		return nil, ErrServerClosed
	}
	s.sessionAccess.Lock()
	defer s.sessionAccess.Unlock()
	address := udpAddress.String()
	displaced := s.udpInitialSessionByAddress[address]
	if displaced == session {
		displaced = nil
	}
	if displaced != nil {
		s.evictSessionLocked(displaced)
	}
	s.bindPeerAddressLocked(initialPeerAddress, session)
	s.udpInitialSessionByAddress[address] = session
	return displaced, nil
}

func (s *tlsServer) bindPeerAddressLocked(initialPeerAddress string, session *tlsServerSession) {
	stablePeerAddress := initialPeerAddress
	if existing := s.sessionByPeer[stablePeerAddress]; existing != nil && existing != session {
		s.sessionCounter++
		stablePeerAddress = fmt.Sprintf("%s#session=%d", initialPeerAddress, s.sessionCounter)
		for s.sessionByPeer[stablePeerAddress] != nil {
			s.sessionCounter++
			stablePeerAddress = fmt.Sprintf("%s#session=%d", initialPeerAddress, s.sessionCounter)
		}
	}
	session.peerAddress = stablePeerAddress
	s.sessionByPeer[stablePeerAddress] = session
}

// Upstream tls_multi_process moves TM_INITIAL into TM_ACTIVE as soon as its
// key_state authenticates, usurping the session which served the instance until
// then; a TM_INITIAL which never gets there expires with its handshake window
// and the session it would have replaced keeps carrying the tunnel.
func (s *tlsServer) promoteInitialSession(session *tlsServerSession) error {
	udpConnection, isUDPPeer := session.packetConnection.(*udpPeerPacketConnection)
	if !isUDPPeer {
		return nil
	}
	remoteAddress := udpConnection.RemoteAddr()
	if remoteAddress == nil {
		return nil
	}
	address := remoteAddress.String()
	s.sessionAccess.Lock()
	if s.udpInitialSessionByAddress[address] != session {
		s.sessionAccess.Unlock()
		return nil
	}
	delete(s.udpInitialSessionByAddress, address)
	displaced := s.udpSessionByAddress[address]
	if displaced == session {
		displaced = nil
	}
	if displaced != nil {
		s.evictSessionLocked(displaced)
		session.resourceReservation.Store(displaced.resourceReservation.Swap(nil))
	}
	s.udpSessionByAddress[address] = session
	s.sessionAccess.Unlock()
	if session.resourceReservation.Load() == nil {
		reservation := s.resourcePolicy.reserveInstance()
		if reservation == nil {
			return ErrServerResourceLimit
		}
		session.resourceReservation.Store(reservation)
	}
	if displaced == nil {
		return nil
	}
	_ = displaced.Close()
	timer := time.NewTimer(serverScheduledExitInterval)
	defer timer.Stop()
	select {
	case <-displaced.finishDone:
		return nil
	case <-session.sessionContext.Done():
		return session.sessionContext.Err()
	case <-timer.C:
		return E.New("timed out replacing the OpenVPN session bound to ", address)
	}
}

func (s *tlsServer) registerAuthenticatedIdentity(session *tlsServerSession) error {
	if session == nil {
		return ErrPeerNotFound
	}
	identity := session.authenticatedIdentityKey()
	s.sessionAccess.Lock()
	session.authenticatedIdentity = identity
	s.sessionAccess.Unlock()
	if identity == "" || s.parent.options.Authentication.DuplicateCN {
		return nil
	}
	s.lifecycleAccess.Lock()
	if s.lifecycleState != serverLifecycleRunning {
		s.lifecycleAccess.Unlock()
		return ErrServerClosed
	}
	s.sessionAccess.Lock()
	if s.sessionByPeer[session.peerAddress] != session {
		s.sessionAccess.Unlock()
		s.lifecycleAccess.Unlock()
		return ErrPeerNotFound
	}
	existing := s.sessionByIdentity[identity]
	s.sessionByIdentity[identity] = session
	s.sessionAccess.Unlock()
	s.lifecycleAccess.Unlock()
	if existing != nil && existing != session {
		_ = existing.Close()
		timer := time.NewTimer(serverScheduledExitInterval)
		select {
		case <-existing.finishDone:
			timer.Stop()
		case <-session.sessionContext.Done():
			timer.Stop()
			return session.sessionContext.Err()
		case <-timer.C:
			return E.New("timed out replacing prior OpenVPN session for authenticated identity")
		}
	}
	s.sessionAccess.RLock()
	current := s.sessionByIdentity[identity]
	s.sessionAccess.RUnlock()
	if current != session {
		return ErrPeerRestart
	}
	return nil
}

func (s *tlsServer) enablePeerID(session *tlsServerSession) error {
	if session == nil {
		return ErrPeerNotFound
	}
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	if s.lifecycleState != serverLifecycleRunning {
		return ErrServerClosed
	}
	s.sessionAccess.Lock()
	defer s.sessionAccess.Unlock()
	if s.sessionByPeer[session.peerAddress] != session {
		return ErrPeerNotFound
	}
	if session.peerIDAssigned {
		return nil
	}
	peerID, allocated := s.allocatePeerIDLocked()
	if !allocated {
		return ErrServerResourceLimit
	}
	// Upstream accepts peer-id zero and reserves 0xffffff as the disabled sentinel.
	session.serverPeerID = peerID
	session.peerIDAssigned = true
	session.setPeerID(&peerID)
	s.sessionByPeerID[peerID] = session
	return nil
}

func (s *tlsServer) allocatePeerIDLocked() (uint32, bool) {
	for candidate := range uint32(s.resourcePolicy.maxClients) {
		if s.sessionByPeerID[candidate] == nil {
			return candidate, true
		}
	}
	return 0, false
}

func (s *tlsServer) unregisterSession(session *tlsServerSession) {
	if session == nil {
		return
	}
	s.sessionAccess.Lock()
	defer s.sessionAccess.Unlock()
	s.evictSessionLocked(session)
}

func (s *tlsServer) evictSessionLocked(session *tlsServerSession) {
	if s.sessionByPeer[session.peerAddress] == session {
		delete(s.sessionByPeer, session.peerAddress)
	}
	if session.peerIDAssigned && s.sessionByPeerID[session.serverPeerID] == session {
		delete(s.sessionByPeerID, session.serverPeerID)
	}
	if session.authenticatedIdentity != "" && s.sessionByIdentity[session.authenticatedIdentity] == session {
		delete(s.sessionByIdentity, session.authenticatedIdentity)
	}
	for address, boundSession := range s.udpSessionByAddress {
		if boundSession == session {
			delete(s.udpSessionByAddress, address)
		}
	}
	for address, boundSession := range s.udpInitialSessionByAddress {
		if boundSession == session {
			delete(s.udpInitialSessionByAddress, address)
		}
	}
}

type udpPacketVerdict uint8

const (
	udpPacketDeliver udpPacketVerdict = iota
	// No session is bound to the source address, so the datagram may open one
	// through the stateless session-id challenge.
	udpPacketUnbound
	// A session is bound to the source address and the datagram is a hard reset
	// carrying a session id none of the sessions bound there owns.
	udpPacketInitialReset
	udpPacketDrop
)

type udpPacketRoute struct {
	verdict udpPacketVerdict
	session *tlsServerSession
}

// Upstream multi_get_create_instance_udp hands every datagram coming from an
// address it already serves to that instance without consulting
// tls_pre_decrypt_lite, and tls_pre_decrypt then routes it by the peer session
// id it carries: a hard reset matching none of the instance's sessions starts a
// TM_INITIAL session while TM_ACTIVE keeps running, and any other control packet
// which matches none of them is unroutable.
func (s *tlsServer) routeUDPPacketLocked(rawPacket []byte, peerAddress string) udpPacketRoute {
	if len(rawPacket) == 0 {
		return udpPacketRoute{verdict: udpPacketDrop}
	}
	peerID, peerIDEnabled := udpDataV2PeerID(rawPacket)
	if peerIDEnabled {
		// Upstream P_DATA_V2 selects a candidate by peer-id before authenticating a floated source address.
		session := s.sessionByPeerID[peerID]
		if session == nil {
			return udpPacketRoute{verdict: udpPacketDrop}
		}
		return udpPacketRoute{verdict: udpPacketDeliver, session: session}
	}
	activeSession := s.udpSessionByAddress[peerAddress]
	initialSession := s.udpInitialSessionByAddress[peerAddress]
	opcode := proto.Opcode(rawPacket[0] >> 3)
	if !isControlOrAcknowledgmentOpcode(opcode) {
		if activeSession == nil {
			return udpPacketRoute{verdict: udpPacketDrop}
		}
		return udpPacketRoute{verdict: udpPacketDeliver, session: activeSession}
	}
	if len(rawPacket) < tlsControlHeaderLength {
		return udpPacketRoute{verdict: udpPacketDrop}
	}
	var clientSessionID proto.SessionID
	copy(clientSessionID[:], rawPacket[1:tlsControlHeaderLength])
	if initialSession != nil && initialSession.remoteSessionID == clientSessionID {
		return udpPacketRoute{verdict: udpPacketDeliver, session: initialSession}
	}
	if activeSession != nil && activeSession.remoteSessionID == clientSessionID {
		return udpPacketRoute{verdict: udpPacketDeliver, session: activeSession}
	}
	if activeSession == nil && initialSession == nil {
		return udpPacketRoute{verdict: udpPacketUnbound}
	}
	switch opcode {
	case proto.OpcodeControlHardResetClientV2, proto.OpcodeControlHardResetClientV3:
		return udpPacketRoute{verdict: udpPacketInitialReset}
	}
	return udpPacketRoute{verdict: udpPacketDrop}
}

func (s *tlsServer) findUDPPacketRoute(rawPacket []byte, peerAddress string) udpPacketRoute {
	s.sessionAccess.RLock()
	defer s.sessionAccess.RUnlock()
	return s.routeUDPPacketLocked(rawPacket, peerAddress)
}

func (s *tlsServer) findUDPPacketRoutes(rawPacketBuffers []*buf.Buffer, peerAddresses []string) []udpPacketRoute {
	routes := make([]udpPacketRoute, len(rawPacketBuffers))
	s.sessionAccess.RLock()
	defer s.sessionAccess.RUnlock()
	for i, rawPacketBuffer := range rawPacketBuffers {
		routes[i] = s.routeUDPPacketLocked(rawPacketBuffer.Bytes(), peerAddresses[i])
	}
	return routes
}

func udpDataV2PeerID(rawPacket []byte) (uint32, bool) {
	if len(rawPacket) < 4 || proto.Opcode(rawPacket[0]>>3) != proto.OpcodeDataV2 {
		return 0, false
	}
	peerID := uint32(rawPacket[1])<<16 | uint32(rawPacket[2])<<8 | uint32(rawPacket[3])
	if peerID == peerIDMaxValue {
		// MAX_PEER_ID is the upstream sentinel which disables peer-id demux and
		// retains legacy real-address lookup.
		return 0, false
	}
	return peerID, true
}

// multi_process_float (multi.c) runs only for a peer whose datagram arrived from
// an address other than the one its instance is bound to, and it hands that
// address over: the instance already holding it is closed unless its locked
// certificate chain differs, in which case the float is refused and the packet
// is discarded by zeroing the instance buffer.
func (s *tlsServer) floatAuthenticatedUDPPeer(session *tlsServerSession) bool {
	udpConnection, ok := session.packetConnection.(*udpPeerPacketConnection)
	if !ok {
		return true
	}
	sourceAddress := udpConnection.floatCandidateAddress()
	if sourceAddress == nil {
		return true
	}
	displaced, floated := s.floatUDPSessionToSource(session, udpConnection, sourceAddress)
	if displaced != nil {
		_ = displaced.Close()
	}
	return floated
}

func (s *tlsServer) floatUDPSessionToSource(
	session *tlsServerSession,
	udpConnection *udpPeerPacketConnection,
	sourceAddress net.Addr,
) (*tlsServerSession, bool) {
	newAddress := sourceAddress.String()
	udpConnection.writer.writeAccess.Lock()
	defer udpConnection.writer.writeAccess.Unlock()
	s.sessionAccess.Lock()
	defer s.sessionAccess.Unlock()
	if s.sessionByPeer[session.peerAddress] != session {
		return nil, false
	}
	if session.peerIDAssigned && s.sessionByPeerID[session.serverPeerID] != session {
		return nil, false
	}
	var displaced *tlsServerSession
	existing := s.udpSessionByAddress[newAddress]
	if existing != nil && existing != session {
		if !equalClientCertificateIdentity(
			existing.lockedCertificateIdentity.Load(),
			session.lockedCertificateIdentity.Load(),
		) {
			return nil, false
		}
		s.evictSessionLocked(existing)
		displaced = existing
	}
	for address, boundSession := range s.udpSessionByAddress {
		if boundSession == session && address != newAddress {
			delete(s.udpSessionByAddress, address)
		}
	}
	s.udpSessionByAddress[newAddress] = session
	udpConnection.setRemoteAddress(sourceAddress)
	return displaced, true
}
