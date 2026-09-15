package openvpn

import (
	"crypto/tls"
	"net"
	"sync"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	E "github.com/sagernet/sing/common/exceptions"
)

type tlsRole uint8

const (
	tlsRoleClient tlsRole = iota
	tlsRoleServer
)

type tlsRoleCallbacks struct {
	deriveKeyMaterial func(session *tlsPeerSession) ([]byte, error)
	appendWrappedKey  func(session *tlsPeerSession, rawPacket []byte, opcode proto.Opcode) []byte
	onTerminate       func(session *tlsPeerSession)
	renegotiate       func(session *tlsPeerSession, channel *tlsControlChannel, mustNegotiate time.Time) (dataCodec, error)
	onRenegotiated    func(session *tlsPeerSession, keyID uint8)
}

type (
	dataWriteObserver       func(keyID uint8, packetID uint32, aeadBlockBytes int, accountedBytes int)
	dataReadCounterObserver func(keyID uint8, accountedBytes int)
	dataReadUsageObserver   func(keyID uint8, packetID uint32, aeadBlockBytes int)
)

func checkTLSKeySourcesComplete(session *tlsPeerSession) error {
	if len(session.clientKeySource.PreMaster) != 48 ||
		len(session.clientKeySource.Random1) != 32 || len(session.clientKeySource.Random2) != 32 ||
		len(session.serverKeySource.Random1) != 32 || len(session.serverKeySource.Random2) != 32 {
		return E.New("incomplete key source material for PRF derivation")
	}
	return nil
}

type tlsPeerSession struct {
	role          tlsRole
	roleCallbacks tlsRoleCallbacks
	hooks         tlsPeerHooks

	packetConnection        proto.PacketConnection
	sessionManager          *proto.SessionManager
	controlChannel          *tlsControlChannel
	tlsConnection           *tls.Conn
	dataCodec               dataCodec
	protection              tlsControlProtection
	dataTransportHeaderSize int
	// Upstream key_state_init (ssl.c) stamps every key_state with
	// must_negotiate = now + session->opt->handshake_window, and tls_process
	// fails the key_state once now passes it before S_ACTIVE.
	handshakeWindow time.Duration
	lifecycleAccess sync.Mutex
	closed          bool
	messages        *dataChannelMessageSender
	controlStream   tlsPrimaryControlStream

	// Upstream tls_pre_decrypt keeps recent key_states addressable by key_id.
	dataKeyAccess      sync.Mutex
	dataWriteAccess    sync.Mutex
	sendCodec          dataCodec
	sendKeyID          uint8
	sendSessionManager *proto.SessionManager
	receiveCodecs      []tlsReceiveCodec

	softResetAccess          sync.Mutex
	renegotiations           map[uint8]*tlsRenegotiationState
	renegotiationsClosed     bool
	renegotiationSequence    uint64
	promotedKeyStateSequence uint64

	closeOnce sync.Once
	closeErr  error

	clientKeySource tlsKeyMethodKeySource
	serverKeySource tlsKeyMethodKeySource

	peerInfo           string
	localOptionsString string
	wrappedClientKey   []byte

	peerID     *uint32
	dataAccess sync.Mutex

	dataWriteObserver       dataWriteObserver
	dataReadCounterObserver dataReadCounterObserver
	dataReadUsageObserver   dataReadUsageObserver
	readActivityObserver    func()
	readBytesObserver       func(payloadBytes int)
	writeActivityObserver   func()
	writeBytesObserver      func(payloadBytes int)

	authenticatedDataPacketObserver func() bool
}

// Upstream BUF_SIZE (ssl.c) bounds plaintext control payloads.
func readTLSControlRecord(connection *tls.Conn, deadline time.Time) ([]byte, error) {
	err := connection.SetReadDeadline(deadline)
	if err != nil {
		return nil, err
	}
	buffer := make([]byte, 16384)
	readCount, err := connection.Read(buffer)
	if err != nil {
		return nil, err
	}
	return append([]byte{}, buffer[:readCount]...), nil
}

func (s *tlsPeerSession) dataChannelMessages() *dataChannelMessageSender {
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	if s.closed {
		return nil
	}
	if s.messages == nil {
		s.messages = startDataChannelMessageSender(s.WriteDataPacket)
	}
	return s.messages
}

func (s *tlsPeerSession) Close() error {
	s.closeOnce.Do(func() {
		s.markClosing()
		s.lifecycleAccess.Lock()
		packetConnection := s.packetConnection
		tlsConnection := s.tlsConnection
		controlChannel := s.controlChannel
		messages := s.messages
		s.lifecycleAccess.Unlock()
		if messages != nil {
			messages.shutdown()
		}
		if s.roleCallbacks.onTerminate != nil {
			s.roleCallbacks.onTerminate(s)
		}
		if packetConnection != nil {
			s.closeErr = E.Errors(s.closeErr, packetConnection.Close())
		}
		s.failAllRenegotiations(net.ErrClosed)
		if tlsConnection != nil {
			s.closeErr = E.Errors(s.closeErr, tlsConnection.Close())
		}
		if controlChannel != nil {
			s.closeErr = E.Errors(s.closeErr, controlChannel.Close())
		}
	})
	return s.closeErr
}

func (s *tlsPeerSession) markClosing() {
	s.lifecycleAccess.Lock()
	s.closed = true
	s.lifecycleAccess.Unlock()
	s.softResetAccess.Lock()
	s.renegotiationsClosed = true
	s.softResetAccess.Unlock()
}

func (s *tlsPeerSession) installInitialControlChannel(channel *tlsControlChannel, tlsConnection *tls.Conn) bool {
	if channel == nil || tlsConnection == nil {
		return false
	}
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	if s.closed {
		return false
	}
	s.controlChannel = channel
	s.tlsConnection = tlsConnection
	channel.setTLSConnection(tlsConnection)
	s.controlStream.install(channel, 0)
	channel.loopWaitGroup.Add(2)
	go channel.runReader()
	go channel.runSender()
	return true
}

func (s *tlsPeerSession) installPacketConnection(packetConnection proto.PacketConnection) bool {
	if packetConnection == nil {
		return false
	}
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	if s.closed {
		return false
	}
	s.packetConnection = packetConnection
	return true
}

func (s *tlsPeerSession) writeHandshakePacket(packet *proto.Packet) error {
	rawPacket, err := packet.Bytes()
	if err != nil {
		return err
	}
	rawPacket = s.protection.encodeOutgoingControlPacket(rawPacket)
	if s.roleCallbacks.appendWrappedKey != nil {
		rawPacket = s.roleCallbacks.appendWrappedKey(s, rawPacket, packet.Opcode)
	}
	return s.packetConnection.WritePacket(rawPacket)
}
