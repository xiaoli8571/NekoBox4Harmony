package openvpn

import (
	"cmp"
	"crypto/tls"
	"net"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	E "github.com/sagernet/sing/common/exceptions"
)

type tlsRenegotiationStatus uint8

const (
	tlsRenegotiationNegotiating tlsRenegotiationStatus = iota
	tlsRenegotiationAwaitingData
	tlsRenegotiationActive
	tlsRenegotiationLameDuck
	tlsRenegotiationFailed
)

type tlsRenegotiationState struct {
	keyID          uint8
	sequence       uint64
	initiator      bool
	mustNegotiate  time.Time
	sessionManager *proto.SessionManager
	channel        *tlsControlChannel
	done           chan struct{}
	finishOnce     sync.Once

	status      tlsRenegotiationStatus
	resultErr   error
	expiresAt   time.Time
	expiryTimer *time.Timer

	peerDataConfirmed bool
}

// Upstream should_trigger_renegotiation calls key_state_soft_reset and
// keeps the old key serving inbound as a lame duck.
func (s *tlsPeerSession) triggerSoftReset() error {
	if s.roleCallbacks.renegotiate == nil {
		return E.New("tls mode: renegotiation not supported for role")
	}
	if sendCodec, _ := s.currentSendCodec(); sendCodec == nil {
		return ErrDataChannelNotReady
	}

	state, created, err := s.beginLocalSoftReset()
	if err != nil {
		return err
	}
	if created {
		s.runSoftResetState(state, nil)
	}
	<-state.done
	return state.resultErr
}

// Upstream process_incoming_link_part2 handles P_CONTROL_SOFT_RESET_V1
// by rekeying in place on the requested key_id.
func (s *tlsPeerSession) handleIncomingSoftResetPacket(packet *proto.Packet) {
	if packet == nil || packet.KeyID == 0 || packet.KeyID > proto.KeyIDMaxValue {
		return
	}
	state, created, err := s.beginSoftReset(packet.KeyID, false)
	if err != nil || state == nil {
		return
	}
	packetCopy := *packet
	if created {
		s.runSoftResetState(state, &packetCopy)
		return
	}
	state.channel.processIncomingControlPacket(&packetCopy)
}

func (s *tlsPeerSession) beginLocalSoftReset() (*tlsRenegotiationState, bool, error) {
	s.softResetAccess.Lock()
	var newest *tlsRenegotiationState
	for _, state := range s.renegotiations {
		if (state.status == tlsRenegotiationNegotiating || state.status == tlsRenegotiationAwaitingData) &&
			(newest == nil || state.sequence > newest.sequence) {
			newest = state
		}
	}
	s.softResetAccess.Unlock()
	if newest != nil {
		return newest, false, nil
	}

	_, currentKeyID := s.currentSendCodec()
	return s.beginSoftReset(proto.NextKeyID(currentKeyID), true)
}

func (s *tlsPeerSession) beginSoftReset(keyID uint8, initiator bool) (*tlsRenegotiationState, bool, error) {
	if keyID == 0 || keyID > proto.KeyIDMaxValue {
		return nil, false, E.New("tls mode: invalid soft-reset key-id: ", keyID)
	}
	if s.controlChannel == nil || s.sessionManager == nil || s.packetConnection == nil {
		return nil, false, net.ErrClosed
	}

	s.softResetAccess.Lock()
	if s.renegotiationsClosed {
		s.softResetAccess.Unlock()
		return nil, false, net.ErrClosed
	}
	var replacedChannel *tlsControlChannel
	if s.renegotiations == nil {
		s.renegotiations = make(map[uint8]*tlsRenegotiationState)
	}
	if existing := s.renegotiations[keyID]; existing != nil {
		_, currentKeyID := s.currentSendCodec()
		if existing.status == tlsRenegotiationNegotiating || existing.status == tlsRenegotiationAwaitingData || currentKeyID == keyID {
			s.softResetAccess.Unlock()
			return existing, false, nil
		}
		// Upstream P_KEY_ID_MASK cycles renegotiated key ids through 1..7.
		s.removeRenegotiationLocked(existing)
		if existing.expiryTimer != nil {
			existing.expiryTimer.Stop()
		}
		replacedChannel = existing.channel
	}

	s.renegotiationSequence++
	stateManager := s.sessionManager.NewRenegotiationSessionManager(keyID)
	state := &tlsRenegotiationState{
		keyID:          keyID,
		sequence:       s.renegotiationSequence,
		initiator:      initiator,
		mustNegotiate:  time.Now().Add(s.handshakeWindow),
		sessionManager: stateManager,
		done:           make(chan struct{}),
		status:         tlsRenegotiationNegotiating,
	}
	state.channel = newTLSControlChannel(
		s.packetConnection,
		stateManager,
		s.protection,
		nil,
		nil,
	)
	if !s.controlChannel.registerRenegotiationChannel(keyID, state.channel) {
		s.softResetAccess.Unlock()
		return nil, false, E.New("tls mode: duplicate soft-reset key-id: ", keyID)
	}
	s.renegotiations[keyID] = state
	s.controlStream.beginHandover(state.sequence)
	state.channel.loopWaitGroup.Add(1)
	go state.channel.runSender()
	s.softResetAccess.Unlock()
	if replacedChannel != nil {
		_ = replacedChannel.Close()
	}
	return state, true, nil
}

func (s *tlsPeerSession) runSoftResetState(state *tlsRenegotiationState, incomingSoftReset *proto.Packet) {
	if state.initiator {
		softResetErr := state.channel.sendInitialSoftReset()
		if softResetErr != nil {
			s.finishSoftReset(state, nil, softResetErr)
			return
		}
	} else if incomingSoftReset != nil {
		state.channel.processIncomingControlPacket(incomingSoftReset)
	}

	newCodec, err := s.roleCallbacks.renegotiate(s, state.channel, state.mustNegotiate)
	s.finishSoftReset(state, newCodec, err)
	if err != nil && E.IsMulti(err, ErrAuthenticationFailed) && s.hooks.sessionTerminated != nil {
		go s.hooks.sessionTerminated(err)
	}
}

func (s *tlsPeerSession) finishSoftReset(state *tlsRenegotiationState, codec dataCodec, err error) {
	if err == nil && codec == nil {
		err = E.New("tls mode: renegotiation completed without a data codec")
	}
	state.finishOnce.Do(func() {
		var channelsToClose []*tlsControlChannel
		promoted := false

		s.softResetAccess.Lock()
		current := s.renegotiations[state.keyID]
		if err != nil || current != state {
			s.discardDataKeyState(state.keyID, state.sequence)
			s.controlStream.abortHandover(state.sequence)
			if err == nil {
				err = net.ErrClosed
			}
			state.status = tlsRenegotiationFailed
			state.resultErr = err
			if current == state {
				s.removeRenegotiationLocked(state)
			}
			channelsToClose = append(channelsToClose, state.channel)
		} else {
			// Upstream selects the newly generated primary key for outbound
			// data immediately.  Receiving a data packet with the new key is
			// not a prerequisite; the previous key remains receive-capable as
			// a lame duck for the transition window.
			promoted = s.promoteKeyStateLocked(state, codec)
			state.resultErr = nil
			channelsToClose = append(channelsToClose, s.pruneRenegotiationsLocked(time.Now())...)
		}
		s.softResetAccess.Unlock()

		if promoted && s.roleCallbacks.onRenegotiated != nil {
			s.roleCallbacks.onRenegotiated(s, state.keyID)
		}
		close(state.done)
		for _, channel := range channelsToClose {
			_ = channel.Close()
		}
	})
}

func (s *tlsPeerSession) makeLameDuckLocked(state *tlsRenegotiationState, now time.Time) {
	state.status = tlsRenegotiationLameDuck
	state.expiresAt = now.Add(tlsTransitionWindow)
	s.armKeyStateExpiryLocked(state)
}

func (s *tlsPeerSession) promoteKeyStateLocked(state *tlsRenegotiationState, codec dataCodec) bool {
	if state.sequence <= s.promotedKeyStateSequence {
		state.status = tlsRenegotiationLameDuck
		state.expiresAt = time.Now().Add(tlsTransitionWindow)
		s.installDataKeyState(codec, state.keyID, state.sessionManager, state.sequence, false)
		s.armKeyStateExpiryLocked(state)
		s.controlStream.abortHandover(state.sequence)
		return false
	}
	now := time.Now()
	for _, oldState := range s.renegotiations {
		if oldState == state || oldState.status != tlsRenegotiationActive {
			continue
		}
		s.makeLameDuckLocked(oldState, now)
	}
	s.promotedKeyStateSequence = state.sequence
	state.status = tlsRenegotiationActive
	s.installDataKeyState(codec, state.keyID, state.sessionManager, state.sequence, true)
	s.controlStream.install(state.channel, state.sequence)
	return true
}

func (s *tlsPeerSession) confirmDataKey(keyID uint8) {
	if s.role != tlsRoleServer {
		return
	}
	var channelsToClose []*tlsControlChannel
	promoted := false
	s.softResetAccess.Lock()
	state := s.renegotiations[keyID]
	if state == nil {
		s.softResetAccess.Unlock()
		return
	}
	switch state.status {
	case tlsRenegotiationNegotiating:
		state.peerDataConfirmed = true
	case tlsRenegotiationAwaitingData:
		state.peerDataConfirmed = true
		codec := s.receiveDataCodec(keyID, state.sequence)
		if codec != nil {
			promoted = s.promoteKeyStateLocked(state, codec)
			channelsToClose = append(channelsToClose, s.pruneRenegotiationsLocked(time.Now())...)
		}
	}
	s.softResetAccess.Unlock()
	if promoted && s.roleCallbacks.onRenegotiated != nil {
		s.roleCallbacks.onRenegotiated(s, keyID)
	}
	for _, channel := range channelsToClose {
		_ = channel.Close()
	}
}

func (s *tlsPeerSession) armKeyStateExpiryLocked(state *tlsRenegotiationState) {
	if state.expiryTimer != nil {
		state.expiryTimer.Stop()
	}
	delay := max(time.Until(state.expiresAt), 0)
	state.expiryTimer = time.AfterFunc(delay, func() {
		s.expireKeyState(state)
	})
}

func (s *tlsPeerSession) expireKeyState(state *tlsRenegotiationState) {
	s.softResetAccess.Lock()
	if s.renegotiations[state.keyID] != state {
		s.softResetAccess.Unlock()
		return
	}
	retiring := state.status == tlsRenegotiationLameDuck || state.status == tlsRenegotiationAwaitingData
	if !retiring || time.Now().Before(state.expiresAt) {
		s.softResetAccess.Unlock()
		return
	}
	s.removeRenegotiationLocked(state)
	s.softResetAccess.Unlock()
	_ = state.channel.Close()
}

func (s *tlsPeerSession) pruneRenegotiationsLocked(now time.Time) []*tlsControlChannel {
	var completed []*tlsRenegotiationState
	var channelsToClose []*tlsControlChannel
	for _, state := range s.renegotiations {
		retiring := state.status == tlsRenegotiationLameDuck || state.status == tlsRenegotiationAwaitingData
		if retiring && !now.Before(state.expiresAt) {
			s.removeRenegotiationLocked(state)
			channelsToClose = append(channelsToClose, state.channel)
			continue
		}
		if state.status == tlsRenegotiationActive || retiring {
			completed = append(completed, state)
		}
	}
	slices.SortStableFunc(completed, func(left *tlsRenegotiationState, right *tlsRenegotiationState) int {
		return cmp.Compare(left.sequence, right.sequence)
	})
	for len(completed) > tlsKeyScanSize {
		state := completed[0]
		completed = completed[1:]
		s.removeRenegotiationLocked(state)
		channelsToClose = append(channelsToClose, state.channel)
	}
	return channelsToClose
}

func (s *tlsPeerSession) removeRenegotiationLocked(state *tlsRenegotiationState) {
	if s.renegotiations[state.keyID] != state {
		return
	}
	delete(s.renegotiations, state.keyID)
	s.controlChannel.unregisterRenegotiationChannel(state.keyID, state.channel)
	s.discardDataKeyState(state.keyID, state.sequence)
	if state.expiryTimer != nil {
		state.expiryTimer.Stop()
	}
}

func (s *tlsPeerSession) failAllRenegotiations(err error) {
	s.softResetAccess.Lock()
	s.renegotiationsClosed = true
	states := make([]*tlsRenegotiationState, 0, len(s.renegotiations))
	for _, state := range s.renegotiations {
		s.removeRenegotiationLocked(state)
		s.controlStream.abortHandover(state.sequence)
		states = append(states, state)
	}
	s.softResetAccess.Unlock()
	for _, state := range states {
		state.finishOnce.Do(func() {
			state.status = tlsRenegotiationFailed
			state.resultErr = err
			close(state.done)
		})
		_ = state.channel.Close()
	}
}

// Upstream process_incoming_link_part2 honors soft reset only after keys
// are generated.
func (s *tlsPeerSession) handleIncomingSoftReset(packet *proto.Packet) {
	if packet == nil {
		return
	}
	sendCodec, _ := s.currentSendCodec()
	if sendCodec == nil {
		return
	}
	packetCopy := *packet
	go s.handleIncomingSoftResetPacket(&packetCopy)
}

// Upstream generate_key_expansion uses EKM when negotiated, otherwise
// the OpenVPN TLS 1.0 PRF over key sources and session IDs.
func deriveRenegotiatedKeyMaterial(
	tlsConnection *tls.Conn,
	useKeyMaterialExport bool,
	clientKeySource tlsKeyMethodKeySource,
	serverKeySource tlsKeyMethodKeySource,
	localSessionID proto.SessionID,
	remoteSessionID proto.SessionID,
	server bool,
) ([]byte, error) {
	if useKeyMaterialExport {
		connectionState := tlsConnection.ConnectionState()
		return connectionState.ExportKeyingMaterial("EXPORTER-OpenVPN-datakeys", nil, tlsPRFKeyMaterialLength)
	}
	if len(clientKeySource.PreMaster) != 48 ||
		len(clientKeySource.Random1) != 32 || len(clientKeySource.Random2) != 32 ||
		len(serverKeySource.Random1) != 32 || len(serverKeySource.Random2) != 32 {
		return nil, E.New("tls mode: incomplete key source material for renegotiation")
	}
	clientSessionID := localSessionID
	serverSessionID := remoteSessionID
	if server {
		clientSessionID = remoteSessionID
		serverSessionID = localSessionID
	}
	return deriveTLSKeyMaterialPRF(
		clientKeySource.PreMaster,
		clientKeySource.Random1,
		serverKeySource.Random1,
		clientKeySource.Random2,
		serverKeySource.Random2,
		clientSessionID,
		serverSessionID,
	), nil
}

// Upstream PACKET_ID_WRAP_TRIGGER (packet_id.h).
const packetIDWrapTrigger uint32 = 0xFF000000

// Upstream tls_limit_reneg_bytes (ssl.c) caps SWEET32 ciphers at 64 MiB.
const sweet32CipherRenegotiationBytesClamp uint64 = 64 * 1024 * 1024

// Upstream cipher_kt_insecure (crypto_openssl.c) flags these ciphers.
var sweet32VulnerableCipherNames = map[string]struct{}{
	"BF-CBC":       {},
	"BF-CFB":       {},
	"BF-OFB":       {},
	"CAST5-CBC":    {},
	"CAST5-CFB":    {},
	"CAST5-OFB":    {},
	"DES-CBC":      {},
	"DES-CFB":      {},
	"DES-OFB":      {},
	"DES-EDE-CBC":  {},
	"DES-EDE-CFB":  {},
	"DES-EDE-OFB":  {},
	"DES-EDE3-CBC": {},
	"DES-EDE3-CFB": {},
	"DES-EDE3-OFB": {},
	"RC2-CBC":      {},
	"RC2-40-CBC":   {},
	"RC2-64-CBC":   {},
}

// Upstream init_options (options.c) defaults reneg-sec to 3600.
const defaultRenegotiationInterval time.Duration = time.Hour

type dataRenegotiationBudget struct {
	bytesLimit         uint64
	packetsLimit       uint64
	aeadUsageLimit     uint64
	activeKeyID        uint8
	bytesTransferred   uint64
	packetsTransferred uint64
	sendUsage          dataRenegotiationDirectionUsage
	receiveUsage       dataRenegotiationDirectionUsage
}

type dataRenegotiationDirectionUsage struct {
	highestPacketID uint32
	plaintextBlocks uint64
}

type dataRenegotiationDirection uint8

const (
	dataRenegotiationDirectionSend dataRenegotiationDirection = iota
	dataRenegotiationDirectionReceive
)

const aesGCMUsageLimit = (((uint64(1) << 36) - 1) / 8) * 7

func newDataRenegotiationBudget(
	cipherName string,
	configuredBytes uint64,
	configuredPackets uint64,
	activeKeyID uint8,
) dataRenegotiationBudget {
	normalizedCipherName := strings.ToUpper(strings.TrimSpace(cipherName))
	bytesLimit := configuredBytes
	// Upstream tls_limit_reneg_bytes (ssl.c) only applies the SWEET32 clamp
	// when reneg-bytes is unset.
	_, sweet32Vulnerable := sweet32VulnerableCipherNames[normalizedCipherName]
	if bytesLimit == 0 && sweet32Vulnerable {
		bytesLimit = sweet32CipherRenegotiationBytesClamp
	}
	budget := dataRenegotiationBudget{
		bytesLimit:   bytesLimit,
		packetsLimit: configuredPackets,
		activeKeyID:  activeKeyID,
	}
	switch normalizedCipherName {
	case "AES-128-GCM", "AES-192-GCM", "AES-256-GCM":
		budget.aeadUsageLimit = aesGCMUsageLimit
	}
	return budget
}

func (b *dataRenegotiationBudget) consumeTransfer(keyID uint8, accountedBytes int) error {
	if keyID != b.activeKeyID {
		return nil
	}
	if accountedBytes > 0 {
		b.bytesTransferred += uint64(accountedBytes)
	}
	b.packetsTransferred++
	if b.bytesLimit > 0 && b.bytesTransferred >= b.bytesLimit {
		return ErrRenegotiationRequired
	}
	if b.packetsLimit > 0 && b.packetsTransferred >= b.packetsLimit {
		return ErrRenegotiationRequired
	}
	return nil
}

func (b *dataRenegotiationBudget) consumeUsage(
	keyID uint8,
	direction dataRenegotiationDirection,
	packetID uint32,
	aeadBlockBytes int,
) error {
	if keyID != b.activeKeyID {
		return nil
	}
	usage := &b.sendUsage
	if direction == dataRenegotiationDirectionReceive {
		usage = &b.receiveUsage
	}
	if packetID > usage.highestPacketID {
		usage.highestPacketID = packetID
	}
	if aeadBlockBytes > 0 {
		usage.plaintextBlocks += (uint64(aeadBlockBytes) + 15) / 16
	}
	if direction == dataRenegotiationDirectionSend && packetID >= packetIDWrapTrigger {
		return ErrRenegotiationRequired
	}
	if b.aeadUsageLimit > 0 && usage.plaintextBlocks+uint64(usage.highestPacketID) > b.aeadUsageLimit {
		return ErrRenegotiationRequired
	}
	return nil
}

func (b *dataRenegotiationBudget) reset(activeKeyID uint8) {
	b.activeKeyID = activeKeyID
	b.bytesTransferred = 0
	b.packetsTransferred = 0
	b.sendUsage = dataRenegotiationDirectionUsage{}
	b.receiveUsage = dataRenegotiationDirectionUsage{}
}
