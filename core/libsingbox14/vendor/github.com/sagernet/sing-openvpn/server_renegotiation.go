package openvpn

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

func (s *tlsServerSession) configureRenegotiation(activeKeyID uint8) {
	s.renegotiationAccess.Lock()
	defer s.renegotiationAccess.Unlock()
	s.renegotiationBudget = newDataRenegotiationBudget(
		s.selectedCipher,
		s.server.parent.options.Timing.RenegotiationBytes,
		s.server.parent.options.Timing.RenegotiationPackets,
		activeKeyID,
	)
	s.renegotiationInterval = s.server.parent.options.Timing.RenegotiationInterval
	jitteredDuration := applyServerRenegotiationJitter(s.renegotiationInterval)
	if jitteredDuration > 0 {
		s.renegotiationDeadline = time.Now().Add(jitteredDuration)
	}
}

func (s *tlsServerSession) noteRenegotiated(activeKeyID uint8) {
	s.renegotiationAccess.Lock()
	defer s.renegotiationAccess.Unlock()
	s.renegotiationBudget.reset(activeKeyID)
	jitteredDuration := applyServerRenegotiationJitter(s.renegotiationInterval)
	if jitteredDuration > 0 {
		s.renegotiationDeadline = time.Now().Add(jitteredDuration)
	}
}

// Upstream tls_post_encrypt/tls_pre_decrypt (ssl.c) count inbound and
// outbound bytes against the same renegotiation budget.
func (s *tlsServerSession) consumeOutboundRenegotiationBudget(
	keyID uint8,
	packetID uint32,
	aeadBlockBytes int,
	accountedBytes int,
) {
	s.renegotiationAccess.Lock()
	transferErr := s.renegotiationBudget.consumeTransfer(keyID, accountedBytes)
	usageErr := s.renegotiationBudget.consumeUsage(
		keyID,
		dataRenegotiationDirectionSend,
		packetID,
		aeadBlockBytes,
	)
	s.renegotiationAccess.Unlock()
	if transferErr != nil || usageErr != nil {
		s.requestSoftReset()
	}
}

func (s *tlsServerSession) consumeInboundRenegotiationCounter(keyID uint8, accountedBytes int) {
	s.renegotiationAccess.Lock()
	budgetErr := s.renegotiationBudget.consumeTransfer(keyID, accountedBytes)
	s.renegotiationAccess.Unlock()
	if budgetErr != nil {
		s.requestSoftReset()
	}
}

func (s *tlsServerSession) consumeInboundRenegotiationUsage(
	keyID uint8,
	packetID uint32,
	aeadBlockBytes int,
) {
	s.renegotiationAccess.Lock()
	budgetErr := s.renegotiationBudget.consumeUsage(
		keyID,
		dataRenegotiationDirectionReceive,
		packetID,
		aeadBlockBytes,
	)
	s.renegotiationAccess.Unlock()
	if budgetErr != nil {
		s.requestSoftReset()
	}
}

// Upstream should_trigger_renegotiation/key_state_soft_reset (ssl.c).
func (s *tlsServerSession) runRenegotiationLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		s.renegotiationAccess.Lock()
		deadline := s.renegotiationDeadline
		s.renegotiationAccess.Unlock()
		if !deadline.IsZero() && !time.Now().Before(deadline) {
			s.requestSoftReset()
		}
	}
}

// Upstream key_state_soft_reset (ssl.c) negotiates a new key_id while
// the current key remains active.
func (s *tlsServerSession) requestSoftReset() {
	s.renegotiationAccess.Lock()
	if s.renegotiationInProgress {
		s.renegotiationAccess.Unlock()
		return
	}
	s.renegotiationInProgress = true
	s.renegotiationAccess.Unlock()
	go func() {
		_ = s.triggerSoftReset()
		s.renegotiationAccess.Lock()
		s.renegotiationInProgress = false
		s.renegotiationAccess.Unlock()
	}()
}

// Upstream do_init_crypto_tls (init.c) applies server-only reneg-sec jitter.
func applyServerRenegotiationJitter(renegotiationDuration time.Duration) time.Duration {
	if renegotiationDuration == 0 {
		return 0
	}
	jitterRange := renegotiationDuration / 10
	if jitterRange < time.Second {
		return renegotiationDuration
	}
	var randomByteBuffer [4]byte
	_, readErr := rand.Read(randomByteBuffer[:])
	if readErr != nil {
		return renegotiationDuration
	}
	jitter := time.Duration(binary.BigEndian.Uint32(randomByteBuffer[:])%uint32(jitterRange/time.Second)) * time.Second
	return renegotiationDuration - jitter
}

// Upstream tls_process reads the client key-method message before the
// server reply during soft-reset renegotiation.
func (s *tlsServerSession) runRenegotiation(channel *tlsControlChannel, mustNegotiate time.Time) (dataCodec, error) {
	tlsConnection := tls.Server(channel, s.server.tlsConfiguration)
	deadlineErr := tlsConnection.SetDeadline(mustNegotiate)
	if deadlineErr != nil {
		return nil, deadlineErr
	}
	handshakeErr := tlsConnection.Handshake()
	if handshakeErr != nil {
		return nil, handshakeErr
	}
	channel.setTLSConnection(tlsConnection)
	certificateIdentityErr := s.verifyLockedCertificateIdentity(tlsConnection)
	if certificateIdentityErr != nil {
		return nil, certificateIdentityErr
	}
	clientKeyMethodRecord, err := readTLSControlRecord(tlsConnection, mustNegotiate)
	if err != nil {
		if E.IsTimeout(err) {
			return nil, ErrHandshakeTimeout
		}
		return nil, err
	}
	clientMessage, err := parseTLSKeyMethod2Payload(clientKeyMethodRecord, false)
	if err != nil {
		return nil, err
	}
	verifyUserPassErr := s.verifyUserPass(s.sessionContext, clientMessage)
	if verifyUserPassErr != nil {
		_, writeErr := tlsConnection.Write(tlsControlStringPayload(buildAuthFailedPayload("invalid credentials")))
		if writeErr != nil {
			return nil, writeErr
		}
		channel.waitForReliableDelivery(serverScheduledExitInterval)
		return nil, verifyUserPassErr
	}
	serverKeySource, err := generateTLSKeyMethodKeySource(false)
	if err != nil {
		return nil, err
	}
	serverKeyMethodPayload, err := buildTLSKeyMethod2Payload(true, tlsKeyMethodMessage{
		OptionsString: s.localOptionsString,
		PeerInfo:      buildTLSServerPeerInfo(s.server.parent.options),
		KeySource:     serverKeySource,
	})
	if err != nil {
		return nil, err
	}
	remoteSessionID, hasRemoteSessionID := s.sessionManager.RemoteSessionID()
	if !hasRemoteSessionID {
		return nil, E.New("missing remote session id for renegotiation")
	}
	keyMaterial, err := deriveRenegotiatedKeyMaterial(
		tlsConnection,
		peerSupportsIVProtoFlag(clientMessage.PeerInfo, tlsIVProtoTLSKeyExport),
		clientMessage.KeySource,
		serverKeySource,
		s.sessionManager.LocalSessionID(),
		remoteSessionID,
		true,
	)
	if err != nil {
		return nil, err
	}
	newCodec, err := newTLSDataCodec(
		keyMaterial,
		true,
		s.selectedCipher,
		s.selectedAuth,
		s.server.parent.options.DataChannel.ReplayWindow,
		s.server.parent.options.DataChannel.ReplayWindowTime,
	)
	if err != nil {
		return nil, err
	}
	s.stageNegotiatedReceiveKey(channel.sessionManager.CurrentKeyID(), newCodec)
	_, writeErr := tlsConnection.Write(serverKeyMethodPayload)
	if writeErr != nil {
		return newCodec, writeErr
	}
	if !channel.waitForReliableDelivery(time.Until(mustNegotiate)) {
		return newCodec, ErrHandshakeTimeout
	}
	_ = tlsConnection.SetDeadline(time.Time{})
	return newCodec, nil
}
