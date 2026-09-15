package openvpn

import (
	"context"
	"crypto/tls"
	"net"
	"sync"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type tlsClient struct {
	*tlsPeerSession
	parent *Client
	remote clientRemote

	keepalive *tlsClientKeepalive

	remoteCipherName   string
	useActiveAuthToken bool

	// Upstream key_state_soft_reset keeps session->opt->key_type across renegotiations.
	remoteSelectedCipher   string
	remoteSelectedAuth     string
	resendWrappedClientKey bool

	tlsConfiguration *tls.Config

	sessionContext context.Context
	cancelSession  context.CancelFunc
	done           chan error
	doneOnce       sync.Once

	access             sync.Mutex
	ready              bool
	challengeCancelErr error
	pushAccess         sync.Mutex
}

func newTLSClient(parent *Client, useActiveAuthToken bool, remote clientRemote) (*tlsClient, error) {
	sessionManager, err := proto.NewSessionManager()
	if err != nil {
		return nil, err
	}
	protection, wrappedClientKey, err := newTLSClientProtection(parent.options)
	if err != nil {
		if !E.IsMulti(err, errClientSessionConfiguration) {
			err = E.Errors(errClientSessionConfiguration, err)
		}
		return nil, err
	}
	client := &tlsClient{
		tlsPeerSession: &tlsPeerSession{
			role:                    tlsRoleClient,
			sessionManager:          sessionManager,
			protection:              protection,
			wrappedClientKey:        wrappedClientKey,
			dataTransportHeaderSize: dataTransportHeaderSize(remote.remote.Protocol),
			handshakeWindow:         parent.options.Timing.HandWindow,
		},
		parent:             parent,
		remote:             remote,
		useActiveAuthToken: useActiveAuthToken,
		done:               make(chan error, 1),
	}
	client.roleCallbacks = tlsRoleCallbacks{
		appendWrappedKey: func(session *tlsPeerSession, rawPacket []byte, opcode proto.Opcode) []byte {
			return appendTLSCryptV2WrappedClientKey(rawPacket, session.wrappedClientKey, opcode)
		},
		onTerminate: func(_ *tlsPeerSession) {
			client.sendExplicitExitNotifyIfRequested()
			client.cancelSessionContext()
		},
		// Upstream generate_key_expansion orders the client session ID before the server session ID.
		deriveKeyMaterial: func(session *tlsPeerSession) ([]byte, error) {
			if tunnelUsesKeyMaterialExport(parent.TunnelConfiguration()) || client.p2pUsesKeyMaterialExport() {
				connectionState := session.tlsConnection.ConnectionState()
				return connectionState.ExportKeyingMaterial("EXPORTER-OpenVPN-datakeys", nil, tlsPRFKeyMaterialLength)
			}
			keySourceErr := checkTLSKeySourcesComplete(session)
			if keySourceErr != nil {
				return nil, keySourceErr
			}
			remoteSessionID, hasRemoteSessionID := session.sessionManager.RemoteSessionID()
			if !hasRemoteSessionID {
				return nil, E.New("missing remote session id for PRF derivation")
			}
			return deriveTLSKeyMaterialPRF(
				session.clientKeySource.PreMaster,
				session.clientKeySource.Random1,
				session.serverKeySource.Random1,
				session.clientKeySource.Random2,
				session.serverKeySource.Random2,
				session.sessionManager.LocalSessionID(),
				remoteSessionID,
			), nil
		},
		renegotiate: func(_ *tlsPeerSession, channel *tlsControlChannel, mustNegotiate time.Time) (dataCodec, error) {
			return client.runRenegotiation(channel, mustNegotiate)
		},
		onRenegotiated: func(_ *tlsPeerSession, keyID uint8) {
			if client.keepalive != nil {
				client.keepalive.noteRenegotiated(keyID)
			}
		},
	}
	client.hooks = tlsPeerHooks{
		outgoingDataPayloads: func(payloads [][]byte, codec dataCodec, packetHeaderSize int) [][][]byte {
			return client.parent.outgoingDataPayloadBatches(payloads, codec, packetHeaderSize, client.mssFixOuterTransportOverhead())
		},
		outgoingDataBuffers: func(payloads []*buf.Buffer, codec dataCodec, packetHeaderSize int) [][]*buf.Buffer {
			return client.parent.outgoingDataBufferBatches(payloads, codec, packetHeaderSize, client.mssFixOuterTransportOverhead())
		},
		decodeIncomingFraming: client.parent.decodeIncomingDataFramingBuffer,
		deliverIncomingPayloads: func(payloads [][]byte, codec dataCodec, packetHeaderSize int) {
			client.parent.handleIncomingDataPayloads(payloads, codec, packetHeaderSize, client.mssFixOuterTransportOverhead())
		},
		deliverIncomingBuffers: func(payloads []*buf.Buffer, codec dataCodec, packetHeaderSize int) {
			client.parent.handleIncomingDataBuffers(payloads, codec, packetHeaderSize, client.mssFixOuterTransportOverhead())
		},
		incomingPacketHeadroom:   client.parent.options.DataChannel.PacketHeadroom,
		sessionTerminated:        client.finish,
		logDroppedIncomingPacket: client.parent.dataPlane.incomingPacketDropLog.Log,
	}
	return client, nil
}

func (c *tlsClient) mssFixOuterTransportOverhead() int {
	var remoteAddress net.Addr
	if c.packetConnection != nil {
		remoteAddress = c.packetConnection.RemoteAddr()
	}
	return openVPNOuterTransportOverhead(c.remote.remote.Protocol, remoteAddress)
}

func newTLSClientProtection(options ClientOptions) (tlsControlProtection, []byte, error) {
	switch {
	case options.TLS.CryptV2.IsSet():
		keyMaterial, wrappedClientKey, err := loadTLSCryptV2ClientKey(options.TLS.CryptV2)
		if err != nil {
			return tlsControlProtection{}, nil, err
		}
		cryptCodec, err := newControlCryptCodecFromMaterial(keyMaterial, tlsCryptKeyDirectionInverse)
		if err != nil {
			return tlsControlProtection{}, nil, err
		}
		cryptCodec.sendState.seedNextID(tlsCryptV2EarlyNegotiationStart)
		return tlsControlProtection{crypt: cryptCodec}, wrappedClientKey, nil
	case options.TLS.Crypt.IsSet():
		cryptCodec, err := newControlCryptCodec(options.TLS.Crypt, tlsCryptKeyDirectionInverse)
		if err != nil {
			return tlsControlProtection{}, nil, err
		}
		return tlsControlProtection{crypt: cryptCodec}, nil, nil
	case options.TLS.Auth.IsSet():
		authName := options.DataChannel.Auth
		if authName == "" || authName == "NONE" {
			authName = "SHA1"
		}
		authCodec, err := newControlAuthCodecWithAuth(
			options.TLS.Auth,
			options.KeyDirection,
			authName,
		)
		if err != nil {
			return tlsControlProtection{}, nil, err
		}
		return tlsControlProtection{auth: authCodec}, nil, nil
	default:
		return tlsControlProtection{}, nil, nil
	}
}

func (c *tlsClient) Initialize(ctx context.Context) error {
	if c.packetConnection != nil {
		return nil
	}
	sessionContext, cancelSession := context.WithCancel(ctx)
	c.access.Lock()
	c.sessionContext = sessionContext
	c.cancelSession = cancelSession
	c.access.Unlock()
	tlsConfiguration, err := buildTLSClientConfiguration(c.parent.options)
	if err != nil {
		cancelSession()
		if !E.IsMulti(err, errClientSessionConfiguration) {
			err = E.Errors(errClientSessionConfiguration, err)
		}
		return err
	}
	c.tlsConfiguration = tlsConfiguration
	var underlyingConnection net.Conn
	if c.parent.options.Transport.DialContextWithAddressIndex != nil {
		underlyingConnection, err = c.parent.options.Transport.DialContextWithAddressIndex(sessionContext, c.remote.transportNetwork, c.remote.address, c.remote.addressIndex)
	} else if c.parent.options.Transport.DialContext != nil {
		underlyingConnection, err = c.parent.options.Transport.DialContext(sessionContext, c.remote.transportNetwork, c.remote.address)
	} else {
		underlyingConnection, err = (&net.Dialer{}).DialContext(sessionContext, c.remote.transportNetwork, c.remote.address)
	}
	if err != nil {
		cancelSession()
		return err
	}
	packetConnection, err := proto.NewPacketConnection(underlyingConnection, c.remote.remote.Protocol)
	if err != nil {
		_ = underlyingConnection.Close()
		cancelSession()
		return err
	}
	if !c.installPacketConnection(packetConnection) {
		_ = packetConnection.Close()
		cancelSession()
		return net.ErrClosed
	}
	sessionErr := sessionContext.Err()
	if sessionErr != nil {
		_ = packetConnection.Close()
		cancelSession()
		return sessionErr
	}
	return nil
}

func (c *tlsClient) Start() error {
	if c.packetConnection == nil || c.sessionContext == nil {
		return ErrDataChannelNotReady
	}
	// Upstream tls_process (ssl.c) bounds the whole S_INITIAL..S_ACTIVE
	// exchange with the key_state's must_negotiate stamp, so the HARD_RESET
	// round trip, the TLS negotiation and the key-method exchange share one
	// hand-window deadline.
	handshakeDeadline := time.Now().Add(c.handshakeWindow)
	serverResetPacket, err := c.handshakeReset(handshakeDeadline)
	if err != nil {
		_ = c.Close()
		return err
	}

	// Upstream process_incoming_link_part1 (forward.c) resets ping_rec_interval
	// whenever tls_pre_decrypt accepts a control channel packet, and
	// process_outgoing_link resets ping_send_interval for every packet written
	// to the link, so the whole session shares one liveness clock which control
	// traffic keeps alive while the data channel is idle.
	keepalive := &tlsClientKeepalive{
		session: c,
		parent:  c.parent,
	}
	keepalive.markActivity(true, true)
	c.keepalive = keepalive

	controlChannel := newTLSControlChannel(
		c.packetConnection,
		c.sessionManager,
		c.protection,
		c.handleIncomingDataPackets,
		c.tlsPeerSession.handleIncomingSoftReset,
	)
	if c.resendWrappedClientKey {
		controlChannel.wrappedClientKey = append([]byte{}, c.wrappedClientKey...)
	}
	controlChannel.setActivityObservers(
		func() { keepalive.markActivity(true, false) },
		func() { keepalive.markActivity(false, true) },
	)
	controlChannel.seedIncomingPacket(serverResetPacket)
	tlsConnection := tls.Client(controlChannel, c.tlsConfiguration)
	if !c.installInitialControlChannel(controlChannel, tlsConnection) {
		_ = c.Close()
		return net.ErrClosed
	}
	if !time.Now().Before(handshakeDeadline) {
		_ = c.Close()
		return E.Extend(ErrHandshakeTimeout, "tls control handshake budget exhausted")
	}
	deadlineErr := tlsConnection.SetDeadline(handshakeDeadline)
	if deadlineErr != nil {
		_ = c.Close()
		return deadlineErr
	}
	handshakeErr := tlsConnection.Handshake()
	if handshakeErr != nil {
		_ = c.Close()
		if E.IsTimeout(handshakeErr) {
			return E.Extend(ErrHandshakeTimeout, handshakeErr.Error())
		}
		return handshakeErr
	}
	_ = tlsConnection.SetDeadline(time.Time{})

	err = c.exchangeKeyMethod(handshakeDeadline)
	if err != nil {
		_ = c.Close()
		return err
	}

	selectedCipher := ""
	selectedAuth := ""
	if c.parent.options.Pull.Enabled {
		c.parent.setInitialTunnelEventDeferred(true)
		selectedCipher, selectedAuth, err = c.pullConfigurationAndCipher()
		c.parent.setInitialTunnelEventDeferred(false)
	} else {
		selectedCipher, selectedAuth, err = c.configureP2PDataChannel()
	}
	if err != nil {
		_ = c.Close()
		return err
	}
	c.parent.clearChallengeOwnedBy(c)
	selectedCipher, err = tlsValidateServerPushedCipher(c.parent.options, selectedCipher)
	if err != nil {
		_ = c.Close()
		return err
	}
	keyMaterial, err := c.roleCallbacks.deriveKeyMaterial(c.tlsPeerSession)
	if err != nil {
		_ = c.Close()
		return err
	}
	initialCodec, err := newTLSDataCodec(
		keyMaterial,
		false,
		selectedCipher,
		selectedAuth,
		c.parent.options.DataChannel.ReplayWindow,
		c.parent.options.DataChannel.ReplayWindowTime,
	)
	if err != nil {
		_ = c.Close()
		return err
	}
	c.remoteSelectedCipher = selectedCipher
	c.remoteSelectedAuth = selectedAuth
	keepalive.configureRenegotiation(selectedCipher, c.sessionManager.CurrentKeyID())
	c.setDataObservers(
		keepalive.consumeOutboundRenegotiationBudget,
		keepalive.consumeInboundRenegotiationCounter,
		keepalive.consumeInboundRenegotiationUsage,
		func() { keepalive.markActivity(true, false) },
		keepalive.registerInactivityBytes,
		func() { keepalive.markActivity(false, true) },
		keepalive.registerInactivityBytes,
	)
	keepalive.noteSessionStart()
	// Upstream do_up (init.c) re-runs do_init_timers once the pulled options are
	// applied, so the tunnel start restamps the liveness clock.
	keepalive.markActivity(true, true)
	keepalive.resetInactivityTimer()
	keepalive.refreshFromTunnelConfiguration()
	c.installInitialDataCodec(initialCodec, c.sessionManager.CurrentKeyID())
	c.setReady(true)
	c.parent.emitTunnelConfigurationEvent(TunnelConfigurationEventInitial)
	go c.controlMessageLoop()
	go keepalive.runLoop()
	return nil
}

func (c *tlsClient) Done() <-chan error {
	return c.done
}

func (c *tlsClient) Ready() bool {
	c.access.Lock()
	defer c.access.Unlock()
	return c.ready
}

func (c *tlsClient) Fail(err error) {
	c.finish(err)
	_ = c.Close()
}

func (c *tlsClient) Close() error {
	c.finish(nil)
	closeErr := c.tlsPeerSession.Close()
	return closeErr
}

func (c *tlsClient) setReady(ready bool) {
	c.access.Lock()
	c.ready = ready
	c.access.Unlock()
}

func (c *tlsClient) finish(err error) {
	c.setReady(false)
	c.parent.clearChallengeOwnedBy(c)
	c.doneOnce.Do(func() {
		c.done <- err
		close(c.done)
	})
	c.cancelSessionContext()
}

func (c *tlsClient) canceledChallengeError() error {
	c.access.Lock()
	defer c.access.Unlock()
	return c.challengeCancelErr
}

func (c *tlsClient) cancelSessionContext() {
	c.access.Lock()
	cancelSession := c.cancelSession
	c.access.Unlock()
	if cancelSession != nil {
		cancelSession()
	}
}

func (c *tlsClient) handshakeReset(handshakeDeadline time.Time) (*proto.Packet, error) {
	resetOpcode := proto.OpcodeControlHardResetClientV2
	if len(c.wrappedClientKey) > 0 {
		resetOpcode = proto.OpcodeControlHardResetClientV3
	}
	resetPacket := &proto.Packet{
		Opcode:         resetOpcode,
		KeyID:          c.sessionManager.CurrentKeyID(),
		LocalSessionID: c.sessionManager.LocalSessionID(),
	}
	writeErr := c.writeHandshakePacket(resetPacket)
	if writeErr != nil {
		return nil, writeErr
	}
	currentRetryTimeout := c.parent.options.Timing.TLSTimeout
	nextRetryTime := time.Now().Add(currentRetryTimeout)
	for time.Now().Before(handshakeDeadline) {
		readDeadline := nextRetryTime
		if readDeadline.After(handshakeDeadline) {
			readDeadline = handshakeDeadline
		}
		_ = c.packetConnection.SetReadDeadline(readDeadline)
		rawPacket, readErr := c.packetConnection.ReadPacket()
		if readErr != nil {
			if !E.IsTimeout(readErr) {
				return nil, readErr
			}
			if !time.Now().Before(handshakeDeadline) {
				break
			}
			retransmitErr := c.writeHandshakePacket(resetPacket)
			if retransmitErr != nil {
				return nil, retransmitErr
			}
			// Upstream reliable_schedule_packet uses doubling-with-cap.
			currentRetryTimeout = min(currentRetryTimeout*2, tlsHandshakeRetryMaximum)
			nextRetryTime = time.Now().Add(currentRetryTimeout)
			continue
		}
		packet, parseErr := c.parseIncomingHandshakePacket(rawPacket)
		if parseErr != nil {
			continue
		}
		if packet.Opcode != proto.OpcodeControlHardResetServerV2 && packet.Opcode != proto.OpcodeControlHardResetServerV1 {
			continue
		}
		if !c.sessionManager.ValidateIncomingRemoteSessionID(packet) {
			continue
		}
		c.sessionManager.SetRemoteSessionID(packet.LocalSessionID)
		earlyNegotiationErr := c.handleServerResetEarlyNegotiation(packet)
		if earlyNegotiationErr != nil {
			return nil, earlyNegotiationErr
		}
		return packet, nil
	}
	return nil, E.Extend(ErrHandshakeTimeout, "tls control handshake timeout")
}

func (c *tlsClient) handleServerResetEarlyNegotiation(packet *proto.Packet) error {
	if len(c.wrappedClientKey) == 0 || len(packet.Payload) == 0 {
		return nil
	}
	resendWrappedClientKey, err := tlsCryptV2ServerRequestsWrappedClientKeyResend(packet.Payload)
	if err != nil {
		return err
	}
	c.resendWrappedClientKey = resendWrappedClientKey
	return nil
}

func (c *tlsClient) parseIncomingHandshakePacket(rawPacket []byte) (*proto.Packet, error) {
	if len(rawPacket) == 0 {
		return nil, E.New("invalid empty tls control packet")
	}
	opcode := proto.Opcode(rawPacket[0] >> 3)
	packetBytes := rawPacket
	if isControlOrAcknowledgmentOpcode(opcode) {
		decodedPacket, err := c.protection.decodeIncomingControlPacket(rawPacket)
		if err != nil {
			return nil, err
		}
		packetBytes = decodedPacket
	}
	return proto.ParsePacket(packetBytes)
}

func (c *tlsClient) exchangeKeyMethod(mustNegotiate time.Time) error {
	clientKeySource, err := generateTLSKeyMethodKeySource(true)
	if err != nil {
		return err
	}
	username, password := c.parent.sessionCredentials(c.useActiveAuthToken)
	selectedAuth := c.parent.options.DataChannel.Auth
	if selectedAuth == "" {
		selectedAuth = "SHA1"
	}
	localOptionsString := buildTLSOptionsStringWithMTU(
		c.remote.remote.Protocol,
		true,
		c.parent.options.TLS.Auth.IsSet(),
		c.parent.dataPlane.compression,
		tlsPreferredCipher(c.parent.options),
		selectedAuth,
		c.parent.options.DataChannel.MTU,
	)
	keyMethodPayload, err := buildTLSKeyMethod2Payload(false, tlsKeyMethodMessage{
		OptionsString: localOptionsString,
		Username:      username,
		Password:      password,
		PeerInfo:      buildTLSPeerInfo(c.parent.options, c.parent.options.Pull.Enabled),
		KeySource:     clientKeySource,
	})
	if err != nil {
		return err
	}
	c.clientKeySource = clientKeySource
	c.localOptionsString = localOptionsString
	_, err = c.tlsConnection.Write(keyMethodPayload)
	if err != nil {
		return err
	}
	controlRecord, err := readTLSControlRecord(c.tlsConnection, mustNegotiate)
	if err != nil {
		if E.IsTimeout(err) {
			return E.Extend(ErrHandshakeTimeout, "key method exchange")
		}
		return err
	}
	if isAuthFailedPayload(controlRecord) {
		return c.authFailedError(controlRecord)
	}
	serverMessage, err := parseTLSKeyMethod2Payload(controlRecord, true)
	if err != nil {
		return err
	}
	c.serverKeySource = serverMessage.KeySource
	c.peerInfo = serverMessage.PeerInfo
	c.remoteCipherName = extractRemoteCipherName(serverMessage.OptionsString)
	return nil
}

func (c *tlsClient) configureP2PDataChannel() (string, string, error) {
	selectedCipher, err := selectP2PCipher(c.parent.options, c.peerInfo)
	if err != nil {
		return "", "", err
	}
	selectedAuth := c.parent.options.DataChannel.Auth
	if selectedAuth == "" {
		selectedAuth = "SHA1"
	}
	if !peerSupportsIVProtoFlag(c.peerInfo, tlsIVProtoNCPP2P) || !peerSupportsIVProtoFlag(c.peerInfo, tlsIVProtoDataV2) {
		return selectedCipher, selectedAuth, nil
	}
	peerID := uint32(0x76706e)
	if peerSupportsIVProtoFlag(c.peerInfo, tlsIVProtoTLSKeyExport) {
		connectionState := c.tlsConnection.ConnectionState()
		peerIDMaterial, exportErr := connectionState.ExportKeyingMaterial("EXPORTER-OpenVPN-p2p-peerid", nil, 3)
		if exportErr != nil {
			return "", "", E.Cause(exportErr, "derive p2p peer id")
		}
		peerID = uint32(peerIDMaterial[0])<<16 | uint32(peerIDMaterial[1])<<8 | uint32(peerIDMaterial[2])
	}
	c.setPeerID(&peerID)
	return selectedCipher, selectedAuth, nil
}

func (c *tlsClient) p2pUsesKeyMaterialExport() bool {
	return !c.parent.options.Pull.Enabled &&
		peerSupportsIVProtoFlag(c.peerInfo, tlsIVProtoNCPP2P) &&
		peerSupportsIVProtoFlag(c.peerInfo, tlsIVProtoTLSKeyExport)
}

// Upstream tls_process (ssl.c) keeps the client key-method order during
// soft reset.
func (c *tlsClient) runRenegotiation(channel *tlsControlChannel, mustNegotiate time.Time) (dataCodec, error) {
	tlsConnection := tls.Client(channel, c.tlsConfiguration)
	deadlineErr := tlsConnection.SetDeadline(mustNegotiate)
	if deadlineErr != nil {
		return nil, deadlineErr
	}
	handshakeErr := tlsConnection.Handshake()
	if handshakeErr != nil {
		return nil, handshakeErr
	}
	channel.setTLSConnection(tlsConnection)
	clientKeySource, err := generateTLSKeyMethodKeySource(true)
	if err != nil {
		return nil, err
	}
	username, password := c.parent.sessionCredentials(true)
	keyMethodPayload, err := buildTLSKeyMethod2Payload(false, tlsKeyMethodMessage{
		OptionsString: c.localOptionsString,
		Username:      username,
		Password:      password,
		PeerInfo:      buildTLSPeerInfo(c.parent.options, false),
		KeySource:     clientKeySource,
	})
	if err != nil {
		return nil, err
	}
	_, writeErr := tlsConnection.Write(keyMethodPayload)
	if writeErr != nil {
		return nil, writeErr
	}
	controlRecord, err := readTLSControlRecord(tlsConnection, mustNegotiate)
	if err != nil {
		if E.IsTimeout(err) {
			return nil, E.Extend(ErrHandshakeTimeout, "renegotiated key method exchange")
		}
		return nil, err
	}
	if isAuthFailedPayload(controlRecord) {
		return nil, c.authFailedError(controlRecord)
	}
	serverMessage, err := parseTLSKeyMethod2Payload(controlRecord, true)
	if err != nil {
		return nil, err
	}
	remoteSessionID, hasRemoteSessionID := c.sessionManager.RemoteSessionID()
	if !hasRemoteSessionID {
		return nil, E.New("missing remote session id for renegotiation")
	}
	keyMaterial, err := deriveRenegotiatedKeyMaterial(
		tlsConnection,
		tunnelUsesKeyMaterialExport(c.parent.TunnelConfiguration()) ||
			(!c.parent.options.Pull.Enabled &&
				peerSupportsIVProtoFlag(serverMessage.PeerInfo, tlsIVProtoNCPP2P) &&
				peerSupportsIVProtoFlag(serverMessage.PeerInfo, tlsIVProtoTLSKeyExport)),
		clientKeySource,
		serverMessage.KeySource,
		c.sessionManager.LocalSessionID(),
		remoteSessionID,
		false,
	)
	if err != nil {
		return nil, err
	}
	newCodec, err := newTLSDataCodec(
		keyMaterial,
		false,
		c.remoteSelectedCipher,
		c.remoteSelectedAuth,
		c.parent.options.DataChannel.ReplayWindow,
		c.parent.options.DataChannel.ReplayWindowTime,
	)
	if err != nil {
		return nil, err
	}
	_ = tlsConnection.SetDeadline(time.Time{})
	return newCodec, nil
}
