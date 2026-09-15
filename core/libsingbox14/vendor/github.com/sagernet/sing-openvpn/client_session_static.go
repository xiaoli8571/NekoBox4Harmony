package openvpn

import (
	"bytes"
	"context"
	"net"
	"sync"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	"github.com/sagernet/sing/common"
	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type staticKeyClientSession struct {
	parent           *Client
	remote           clientRemote
	sessionManager   *proto.SessionManager
	dataCodec        dataCodec
	packetConnection proto.PacketConnection

	sessionContext context.Context
	cancelSession  context.CancelFunc
	done           chan error
	doneOnce       sync.Once
	closeOnce      sync.Once
	closeErr       error

	access           sync.Mutex
	writeAccess      sync.Mutex
	ready            bool
	closed           bool
	messages         *dataChannelMessageSender
	lastInboundTime  time.Time
	lastOutboundTime time.Time
}

func newStaticKeyClientSession(parent *Client, remote clientRemote) (*staticKeyClientSession, error) {
	sessionManager, err := proto.NewSessionManager()
	if err != nil {
		return nil, err
	}
	replayWindowSize, replayWindowTime := dataReplayWindowParameters(
		parent.options.DataChannel.ReplayWindow,
		parent.options.DataChannel.ReplayWindowTime,
	)
	codec, err := newStaticKeyDataCodec(
		parent.options.StaticKey,
		parent.options.KeyDirection,
		parent.options.DataChannel.Cipher,
		parent.options.DataChannel.Auth,
		replayWindowSize,
		replayWindowTime,
	)
	if err != nil {
		if !E.IsMulti(err, errClientSessionConfiguration) {
			err = E.Errors(errClientSessionConfiguration, err)
		}
		return nil, err
	}
	return &staticKeyClientSession{
		parent:         parent,
		remote:         remote,
		sessionManager: sessionManager,
		dataCodec:      codec,
		done:           make(chan error, 1),
	}, nil
}

func (s *staticKeyClientSession) Initialize(ctx context.Context) error {
	sessionContext, cancelSession := context.WithCancel(ctx)
	s.access.Lock()
	s.sessionContext = sessionContext
	s.cancelSession = cancelSession
	closed := s.closed
	s.access.Unlock()
	if closed {
		cancelSession()
		return net.ErrClosed
	}
	var underlyingConnection net.Conn
	var err error
	if s.parent.options.Transport.DialContextWithAddressIndex != nil {
		underlyingConnection, err = s.parent.options.Transport.DialContextWithAddressIndex(sessionContext, s.remote.transportNetwork, s.remote.address, s.remote.addressIndex)
	} else if s.parent.options.Transport.DialContext != nil {
		underlyingConnection, err = s.parent.options.Transport.DialContext(sessionContext, s.remote.transportNetwork, s.remote.address)
	} else {
		underlyingConnection, err = (&net.Dialer{}).DialContext(sessionContext, s.remote.transportNetwork, s.remote.address)
	}
	if err != nil {
		cancelSession()
		return err
	}
	packetConnection, err := proto.NewPacketConnection(underlyingConnection, s.remote.remote.Protocol)
	if err != nil {
		_ = underlyingConnection.Close()
		cancelSession()
		return err
	}
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		_ = packetConnection.Close()
		cancelSession()
		return net.ErrClosed
	}
	s.packetConnection = packetConnection
	s.access.Unlock()
	sessionErr := sessionContext.Err()
	if sessionErr != nil {
		_ = packetConnection.Close()
		cancelSession()
		return sessionErr
	}
	return nil
}

func (s *staticKeyClientSession) Start() error {
	if s.packetConnection == nil || s.sessionContext == nil {
		return ErrDataChannelNotReady
	}
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		return net.ErrClosed
	}
	sessionErr := s.sessionContext.Err()
	if sessionErr != nil {
		s.access.Unlock()
		return sessionErr
	}
	s.sessionManager.SetNegotiationState(proto.NegotiationStatePreStart)
	s.sessionManager.SetNegotiationState(proto.NegotiationStateControlReady)
	now := time.Now()
	s.lastInboundTime = now
	s.lastOutboundTime = now
	s.ready = true
	go s.readLoop()
	s.access.Unlock()
	s.parent.emitTunnelConfigurationEvent(TunnelConfigurationEventInitial)
	return nil
}

func (s *staticKeyClientSession) Done() <-chan error {
	return s.done
}

func (s *staticKeyClientSession) Ready() bool {
	s.access.Lock()
	defer s.access.Unlock()
	return s.ready
}

func (s *staticKeyClientSession) WriteDataPackets(packets [][]byte) error {
	if len(packets) == 0 {
		return nil
	}
	if !s.Ready() || s.packetConnection == nil {
		return ErrDataChannelNotReady
	}
	packets = common.Filter(packets, func(packet []byte) bool {
		return len(packet) > 0
	})
	if len(packets) == 0 {
		return nil
	}
	s.writeAccess.Lock()
	defer s.writeAccess.Unlock()
	transportHeaderSize := dataTransportHeaderSize(s.remote.remote.Protocol)
	preparedPayloads := s.parent.outgoingDataPayloadBatches(packets, s.dataCodec, transportHeaderSize, openVPNOuterTransportOverhead(s.remote.remote.Protocol, s.packetConnection.RemoteAddr()))
	preparedPacketCount := 0
	for _, outgoingPayloads := range preparedPayloads {
		preparedPacketCount += len(outgoingPayloads)
	}
	if preparedPacketCount == 0 {
		return nil
	}
	dataPacketIDs, err := s.sessionManager.NewDataPacketIDs(proto.OpcodeDataV1, preparedPacketCount)
	if err != nil {
		return err
	}
	rawPackets := make([][]byte, 0, preparedPacketCount)
	dataPacketIndex := 0
	var encodeErr error
	for _, outgoingPayloads := range preparedPayloads {
		for _, outgoingPayload := range outgoingPayloads {
			dataPacketID := dataPacketIDs[dataPacketIndex]
			dataPacketIndex++
			var encodedPayload []byte
			encodedPayload, encodeErr = s.dataCodec.Encode(uint32(dataPacketID), nil, outgoingPayload)
			if encodeErr != nil {
				break
			}
			rawPackets = append(rawPackets, encodedPayload)
		}
		if encodeErr != nil {
			break
		}
	}
	writtenPackets, writeErr := s.packetConnection.WritePackets(rawPackets)
	if writeErr != nil {
		return writeErr
	}
	if writtenPackets > 0 {
		s.access.Lock()
		s.lastOutboundTime = time.Now()
		s.access.Unlock()
	}
	return encodeErr
}

func (s *staticKeyClientSession) WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error {
	packets := make([][]byte, len(packetBuffers))
	for i, packetBuffer := range packetBuffers {
		packets[i] = packetBuffer.Bytes()
	}
	err := s.WriteDataPackets(packets)
	buf.ReleaseMulti(packetBuffers)
	return err
}

func (s *staticKeyClientSession) Fail(err error) {
	s.finish(err)
	_ = s.Close()
}

func (s *staticKeyClientSession) Close() error {
	s.closeOnce.Do(func() {
		s.access.Lock()
		s.closed = true
		s.ready = false
		cancelSession := s.cancelSession
		packetConnection := s.packetConnection
		messages := s.messages
		s.access.Unlock()
		if messages != nil {
			messages.shutdown()
		}
		if cancelSession != nil {
			cancelSession()
		}
		if packetConnection != nil {
			s.closeErr = packetConnection.Close()
		}
	})
	return s.closeErr
}

func (s *staticKeyClientSession) readLoop() {
	for {
		select {
		case <-s.sessionContext.Done():
			s.finish(nil)
			return
		default:
		}
		err := s.packetConnection.SetReadDeadline(time.Now().Add(time.Second))
		if err != nil {
			s.finish(err)
			return
		}
		rawPacketBuffers, readErr := s.packetConnection.ReadPackets()
		decodedPayloads := make([][]byte, 0, len(rawPacketBuffers))
		authenticatedPacketReceived := false
		var fatalDecodeError error
		for _, rawPacketBuffer := range rawPacketBuffers {
			_, decodedPayload, decodeError := s.dataCodec.Decode(nil, rawPacketBuffer.Bytes())
			if decodeError != nil {
				s.parent.dataPlane.incomingPacketDropLog.Log(decodeError)
				// Upstream process_incoming_link_part1 (forward.c) registers
				// SIGUSR1 for an openvpn_decrypt failure while
				// link_socket_connection_oriented holds, which restarts the
				// --secret connection instead of reading the stream on.
				if s.packetConnection.ConnectionOriented() {
					fatalDecodeError = E.Extend(ErrFatalDecryption, decodeError.Error())
					break
				}
				continue
			}
			authenticatedPacketReceived = true
			framedPayload, framingComplete, framingError := s.parent.decodeIncomingDataFraming(decodedPayload)
			if framingError != nil {
				s.parent.dataPlane.incomingPacketDropLog.Log(framingError)
				continue
			}
			if !framingComplete {
				continue
			}
			if len(framedPayload) == 0 {
				continue
			}
			if bytes.Equal(framedPayload, openVPNDataChannelPingPayload) {
				continue
			}
			decodedPayloads = append(decodedPayloads, framedPayload)
		}
		buf.ReleaseMulti(rawPacketBuffers)
		if authenticatedPacketReceived {
			s.access.Lock()
			s.lastInboundTime = time.Now()
			s.access.Unlock()
		}
		s.parent.handleIncomingDataPayloads(decodedPayloads, s.dataCodec, dataTransportHeaderSize(s.remote.remote.Protocol), openVPNOuterTransportOverhead(s.remote.remote.Protocol, s.packetConnection.RemoteAddr()))
		if fatalDecodeError != nil {
			s.finish(fatalDecodeError)
			return
		}
		keepaliveErr := s.checkKeepalive(time.Now())
		if keepaliveErr != nil {
			s.finish(keepaliveErr)
			return
		}
		if readErr != nil {
			if E.IsTimeout(readErr) {
				continue
			}
			if E.IsMulti(readErr, net.ErrClosed) {
				s.finish(nil)
				return
			}
			s.finish(readErr)
			return
		}
	}
}

func (s *staticKeyClientSession) dataChannelMessages() *dataChannelMessageSender {
	s.access.Lock()
	defer s.access.Unlock()
	if s.closed {
		return nil
	}
	if s.messages == nil {
		s.messages = startDataChannelMessageSender(func(payload []byte) error {
			return s.WriteDataPackets([][]byte{payload})
		})
	}
	return s.messages
}

func (s *staticKeyClientSession) checkKeepalive(now time.Time) error {
	s.access.Lock()
	lastInboundTime := s.lastInboundTime
	lastOutboundTime := s.lastOutboundTime
	s.access.Unlock()
	pingRestart := s.parent.options.Timing.PingRestart
	if pingRestart > 0 && !now.Before(lastInboundTime.Add(pingRestart)) {
		return ErrPingRestartTimeout
	}
	pingInterval := s.parent.options.Timing.PingInterval
	if pingInterval > 0 && !now.Before(lastOutboundTime.Add(pingInterval)) {
		messages := s.dataChannelMessages()
		if messages != nil {
			messages.sendPing()
		}
	}
	return nil
}

func (s *staticKeyClientSession) setReady(ready bool) {
	s.access.Lock()
	s.ready = ready
	s.access.Unlock()
}

func (s *staticKeyClientSession) finish(err error) {
	s.setReady(false)
	s.doneOnce.Do(func() {
		s.done <- err
		close(s.done)
	})
}
