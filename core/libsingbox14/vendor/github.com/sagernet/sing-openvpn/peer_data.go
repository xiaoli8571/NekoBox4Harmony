package openvpn

import (
	"bytes"
	"sort"
	"strings"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	"github.com/sagernet/sing/common"
	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type tlsPeerHooks struct {
	outgoingDataPayloads     func(payloads [][]byte, codec dataCodec, packetHeaderSize int) [][][]byte
	outgoingDataBuffers      func(payloads []*buf.Buffer, codec dataCodec, packetHeaderSize int) [][]*buf.Buffer
	decodeIncomingFraming    func(payload *buf.Buffer) (*buf.Buffer, bool, error)
	deliverIncomingPayloads  func(payloads [][]byte, codec dataCodec, packetHeaderSize int)
	deliverIncomingBuffers   func(payloads []*buf.Buffer, codec dataCodec, packetHeaderSize int)
	incomingPacketHeadroom   int
	sessionTerminated        func(err error)
	logDroppedIncomingPacket func(err error)
}

func (s *tlsPeerSession) currentPeerID() *uint32 {
	s.dataAccess.Lock()
	defer s.dataAccess.Unlock()
	if s.peerID == nil {
		return nil
	}
	peerIDCopy := *s.peerID
	return &peerIDCopy
}

func (s *tlsPeerSession) setPeerID(peerID *uint32) {
	s.dataAccess.Lock()
	defer s.dataAccess.Unlock()
	if peerID == nil {
		s.peerID = nil
		return
	}
	peerIDCopy := *peerID
	s.peerID = &peerIDCopy
}

func (s *tlsPeerSession) setDataObservers(
	writeObserver dataWriteObserver,
	readCounterObserver dataReadCounterObserver,
	readUsageObserver dataReadUsageObserver,
	readActivityObserver func(),
	readBytesObserver func(payloadBytes int),
	writeActivityObserver func(),
	writeBytesObserver func(payloadBytes int),
) {
	s.dataAccess.Lock()
	defer s.dataAccess.Unlock()
	s.dataWriteObserver = writeObserver
	s.dataReadCounterObserver = readCounterObserver
	s.dataReadUsageObserver = readUsageObserver
	s.readActivityObserver = readActivityObserver
	s.readBytesObserver = readBytesObserver
	s.writeActivityObserver = writeActivityObserver
	s.writeBytesObserver = writeBytesObserver
}

func (s *tlsPeerSession) currentReadObservers() (
	dataReadCounterObserver,
	dataReadUsageObserver,
	func(),
	func(payloadBytes int),
) {
	s.dataAccess.Lock()
	defer s.dataAccess.Unlock()
	return s.dataReadCounterObserver, s.dataReadUsageObserver, s.readActivityObserver, s.readBytesObserver
}

func (s *tlsPeerSession) currentWriteObservers() (dataWriteObserver, func(), func(payloadBytes int)) {
	s.dataAccess.Lock()
	defer s.dataAccess.Unlock()
	return s.dataWriteObserver, s.writeActivityObserver, s.writeBytesObserver
}

func (s *tlsPeerSession) setAuthenticatedDataPacketObserver(observer func() bool) {
	s.dataAccess.Lock()
	s.authenticatedDataPacketObserver = observer
	s.dataAccess.Unlock()
}

func (s *tlsPeerSession) currentAuthenticatedDataPacketObserver() func() bool {
	s.dataAccess.Lock()
	defer s.dataAccess.Unlock()
	return s.authenticatedDataPacketObserver
}

func (s *tlsPeerSession) handleIncomingDataPackets(packets []*proto.Packet) {
	decodedPayloads := make([]*buf.Buffer, 0, len(packets))
	var batchCodec dataCodec
	var batchPacketHeaderSize int
	flushDecodedPayloads := func() {
		if len(decodedPayloads) == 0 {
			return
		}
		s.hooks.deliverIncomingBuffers(decodedPayloads, batchCodec, batchPacketHeaderSize)
		decodedPayloads = decodedPayloads[:0]
	}
	for _, packet := range packets {
		if packet == nil {
			continue
		}
		receiveCodec := s.selectReceiveCodec(packet.KeyID)
		if receiveCodec == nil {
			continue
		}
		packetHeaderSize := s.dataPacketHeaderSize(packet.Opcode)
		if len(decodedPayloads) > 0 && (receiveCodec != batchCodec || packetHeaderSize != batchPacketHeaderSize) {
			flushDecodedPayloads()
		}
		var aadPrefix []byte
		if packet.Opcode == proto.OpcodeDataV2 {
			header := byte((uint8(packet.Opcode) << 3) | (packet.KeyID & 0x07))
			aadPrefix = []byte{header, packet.PeerID[0], packet.PeerID[1], packet.PeerID[2]}
		}
		readCounterObserver, readUsageObserver, readActivityObserver, readBytesObserver := s.currentReadObservers()
		accountedBytes := len(packet.Payload)
		if readCounterObserver != nil {
			readCounterObserver(packet.KeyID, accountedBytes)
		}
		packetID, decodedPayload, err := receiveCodec.DecodeBuffer(aadPrefix, packet.Payload, s.hooks.incomingPacketHeadroom)
		if err != nil {
			if s.hooks.logDroppedIncomingPacket != nil {
				s.hooks.logDroppedIncomingPacket(err)
			}
			// Upstream process_incoming_link_part1 (forward.c) registers SIGUSR1
			// with "Fatal decryption error (process_incoming_link), restarting"
			// whenever openvpn_decrypt fails while
			// link_socket_connection_oriented holds, and the event loop takes
			// that signal before the next packet of the stream reaches it: the
			// client restarts the connection, and multi_process_post closes the
			// server instance together with its socket.  Only the data channel
			// decrypt reaches that test — tls_pre_decrypt empties the buffer
			// both for a control packet and for a data packet whose key id
			// matches no key_state, and openvpn_decrypt reports success for an
			// empty buffer.
			if s.packetConnection.ConnectionOriented() {
				flushDecodedPayloads()
				go s.hooks.sessionTerminated(E.Extend(ErrFatalDecryption, err.Error()))
				return
			}
			continue
		}
		if readUsageObserver != nil {
			readUsageObserver(packet.KeyID, packetID, decodedPayload.Len())
		}
		s.confirmDataKey(packet.KeyID)
		if authenticatedObserver := s.currentAuthenticatedDataPacketObserver(); authenticatedObserver != nil && !authenticatedObserver() {
			decodedPayload.Release()
			continue
		}
		if readActivityObserver != nil {
			readActivityObserver()
		}
		// Upstream process_incoming_link_part2 reassembles fragments and
		// decompresses before is_ping_msg and is_occ_msg, and ping.c and occ.c
		// hand their payloads to encrypt_sign with comp_frag enabled, so both
		// carry client data framing.
		if s.hooks.decodeIncomingFraming != nil {
			var framingComplete bool
			var framingErr error
			decodedPayload, framingComplete, framingErr = s.hooks.decodeIncomingFraming(decodedPayload)
			if framingErr != nil {
				if s.hooks.logDroppedIncomingPacket != nil {
					s.hooks.logDroppedIncomingPacket(framingErr)
				}
				continue
			}
			if !framingComplete {
				continue
			}
		}
		// process_incoming_link_part2 tests is_ping_msg, is_occ_msg and the tun
		// write under a single len > 0 guard, so an empty payload reaches
		// neither the tunnel nor the occ handlers.
		if decodedPayload.IsEmpty() {
			decodedPayload.Release()
			continue
		}
		if bytes.Equal(decodedPayload.Bytes(), openVPNDataChannelPingPayload) {
			flushDecodedPayloads()
			decodedPayload.Release()
			continue
		}
		if occOpcode(decodedPayload.Bytes()) == int(openVPNOCCExit) {
			flushDecodedPayloads()
			decodedPayload.Release()
			go s.hooks.sessionTerminated(ErrPeerExit)
			continue
		}
		if bytes.HasPrefix(decodedPayload.Bytes(), openVPNOCCMagic) {
			flushDecodedPayloads()
			response, shouldSend := buildOCCResponseForIncoming(decodedPayload.Bytes(), s.localOptionsString)
			if shouldSend {
				messages := s.dataChannelMessages()
				if messages != nil {
					messages.sendOCCMessage(response)
				}
			}
			decodedPayload.Release()
			continue
		}
		if readBytesObserver != nil {
			readBytesObserver(decodedPayload.Len())
		}
		if len(decodedPayloads) == 0 {
			batchCodec = receiveCodec
			batchPacketHeaderSize = packetHeaderSize
		}
		decodedPayloads = append(decodedPayloads, decodedPayload)
	}
	flushDecodedPayloads()
}

type tlsReceiveCodec struct {
	keyID    uint8
	codec    dataCodec
	expiry   time.Time
	sequence uint64
}

// Upstream --tran-window defaults to 3600 seconds.
const tlsTransitionWindow = 3600 * time.Second

// Upstream KEY_SCAN_SIZE caps retained key_states.
const tlsKeyScanSize = 3

func (s *tlsPeerSession) installInitialDataCodec(codec dataCodec, keyID uint8) {
	s.dataKeyAccess.Lock()
	defer s.dataKeyAccess.Unlock()
	s.dataCodec = codec
	s.sendCodec = codec
	s.sendKeyID = keyID
	s.sendSessionManager = s.sessionManager
	s.receiveCodecs = []tlsReceiveCodec{{keyID: keyID, codec: codec}}
}

func (s *tlsPeerSession) installDataKeyState(
	codec dataCodec,
	keyID uint8,
	manager *proto.SessionManager,
	sequence uint64,
	promote bool,
) {
	s.dataKeyAccess.Lock()
	defer s.dataKeyAccess.Unlock()
	now := time.Now()
	expiry := now.Add(tlsTransitionWindow)
	var retained []tlsReceiveCodec
	for _, entry := range s.receiveCodecs {
		if entry.keyID == keyID {
			continue
		}
		if promote && entry.keyID == s.sendKeyID {
			entry.expiry = expiry
		}
		if !entry.expiry.IsZero() && !now.Before(entry.expiry) {
			continue
		}
		retained = append(retained, entry)
	}
	newEntry := tlsReceiveCodec{keyID: keyID, codec: codec, sequence: sequence}
	if !promote {
		newEntry.expiry = expiry
	}
	retained = append(retained, newEntry)
	sort.SliceStable(retained, func(i, j int) bool {
		return retained[i].sequence < retained[j].sequence
	})
	if len(retained) > tlsKeyScanSize {
		retained = retained[len(retained)-tlsKeyScanSize:]
	}
	s.receiveCodecs = retained
	if promote {
		s.dataCodec = codec
		s.sendCodec = codec
		s.sendKeyID = keyID
		s.sendSessionManager = manager
	}
}

func (s *tlsPeerSession) stageNegotiatedReceiveKey(keyID uint8, codec dataCodec) bool {
	s.softResetAccess.Lock()
	defer s.softResetAccess.Unlock()
	state := s.renegotiations[keyID]
	if state == nil || state.status != tlsRenegotiationNegotiating {
		return false
	}
	s.installDataKeyState(codec, keyID, state.sessionManager, state.sequence, false)
	return true
}

func (s *tlsPeerSession) discardDataKeyState(keyID uint8, sequence uint64) {
	s.dataKeyAccess.Lock()
	defer s.dataKeyAccess.Unlock()
	retained := s.receiveCodecs[:0]
	for _, entry := range s.receiveCodecs {
		if entry.keyID == keyID && entry.sequence == sequence {
			continue
		}
		retained = append(retained, entry)
	}
	s.receiveCodecs = retained
}

func (s *tlsPeerSession) receiveDataCodec(keyID uint8, sequence uint64) dataCodec {
	s.dataKeyAccess.Lock()
	defer s.dataKeyAccess.Unlock()
	for _, entry := range s.receiveCodecs {
		if entry.keyID == keyID && entry.sequence == sequence {
			return entry.codec
		}
	}
	return nil
}

func (s *tlsPeerSession) currentSendCodec() (dataCodec, uint8) {
	s.dataKeyAccess.Lock()
	defer s.dataKeyAccess.Unlock()
	return s.sendCodec, s.sendKeyID
}

func (s *tlsPeerSession) currentSendKeyState() (dataCodec, uint8, *proto.SessionManager) {
	s.dataKeyAccess.Lock()
	defer s.dataKeyAccess.Unlock()
	return s.sendCodec, s.sendKeyID, s.sendSessionManager
}

// Upstream lame_duck_must_die expires old key_states before tls_pre_decrypt.
func (s *tlsPeerSession) selectReceiveCodec(keyID uint8) dataCodec {
	s.dataKeyAccess.Lock()
	defer s.dataKeyAccess.Unlock()
	now := time.Now()
	var selected dataCodec
	var retained []tlsReceiveCodec
	for _, entry := range s.receiveCodecs {
		if !entry.expiry.IsZero() && !now.Before(entry.expiry) {
			continue
		}
		retained = append(retained, entry)
		if entry.keyID == keyID {
			selected = entry.codec
		}
	}
	s.receiveCodecs = retained
	return selected
}

func (s *tlsPeerSession) WriteDataPacket(payload []byte) error {
	return s.WriteDataPackets([][]byte{payload})
}

type tlsOutgoingDataPacket struct {
	rawPayload     []byte
	packetID       uint32
	aeadBlockBytes int
	accountedBytes int
}

func (s *tlsPeerSession) WriteDataPackets(payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	s.dataWriteAccess.Lock()
	defer s.dataWriteAccess.Unlock()
	return s.writeDataPacketsLocked(payloads)
}

func (s *tlsPeerSession) WriteDataPacketBuffers(payloads []*buf.Buffer) error {
	if len(payloads) == 0 {
		return nil
	}
	s.dataWriteAccess.Lock()
	defer s.dataWriteAccess.Unlock()
	return s.writeDataPacketBuffersLocked(payloads)
}

// Upstream process_explicit_exit_notification_timer_wakeup (forward.c) only
// stamps occ_op on the instance's single outgoing slot and process_outgoing_link
// carries it whenever the link takes it, so an attempt still queued when the
// next tick arrives is left to that tick.  The link write it queues behind
// belongs to another writer and carries no deadline of this one.
func (s *tlsPeerSession) writeDataPacketWithinTick(payload []byte, tick time.Duration) {
	attempt := make(chan struct{})
	go func() {
		defer close(attempt)
		_ = s.WriteDataPacket(payload)
	}()
	timer := time.NewTimer(tick)
	defer timer.Stop()
	select {
	case <-attempt:
	case <-timer.C:
	}
}

// process_incoming_tun (forward.c) reaches encrypt_sign only for a tun buffer
// with len > 0, so an empty payload never becomes a wire packet and never
// consumes an outgoing packet id.
func (s *tlsPeerSession) writeDataPacketsLocked(payloads [][]byte) error {
	payloads = common.Filter(payloads, func(payload []byte) bool {
		return len(payload) > 0
	})
	if len(payloads) == 0 {
		return nil
	}
	sendCodec, currentKeyID, sendSessionManager := s.currentSendKeyState()
	if sendCodec == nil {
		return ErrDataChannelNotReady
	}
	if sendSessionManager == nil {
		sendSessionManager = s.sessionManager
	}
	peerID := s.currentPeerID()
	outgoingOpcode := proto.OpcodeDataV1
	if peerID != nil {
		outgoingOpcode = proto.OpcodeDataV2
	}
	packetHeaderSize := s.dataPacketHeaderSize(outgoingOpcode)
	var aadPrefix []byte
	if outgoingOpcode == proto.OpcodeDataV2 {
		header := byte((uint8(outgoingOpcode) << 3) | (currentKeyID & 0x07))
		encodedPeerID := *peerID & 0x00ffffff
		aadPrefix = []byte{
			header,
			byte(encodedPeerID >> 16),
			byte(encodedPeerID >> 8),
			byte(encodedPeerID),
		}
	}
	preparedPayloads := s.hooks.outgoingDataPayloads(payloads, sendCodec, packetHeaderSize)
	preparedPacketCount := 0
	for _, outgoingPayloads := range preparedPayloads {
		preparedPacketCount += len(outgoingPayloads)
	}
	if preparedPacketCount == 0 {
		return nil
	}
	dataPacketIDs, err := sendSessionManager.NewDataPacketIDs(outgoingOpcode, preparedPacketCount)
	if err != nil {
		return err
	}
	encodedPackets := make([]tlsOutgoingDataPacket, 0, preparedPacketCount)
	lastEncodedPacket := make([]int, len(payloads))
	for i := range lastEncodedPacket {
		lastEncodedPacket[i] = -1
	}
	completedPayloads := 0
	var encodeErr error
	dataPacketIndex := 0
	for i, outgoingPayloads := range preparedPayloads {
		for _, outgoingPayload := range outgoingPayloads {
			packetID := uint32(dataPacketIDs[dataPacketIndex])
			dataPacketIndex++
			var encodedPayload []byte
			encodedPayload, encodeErr = sendCodec.Encode(packetID, aadPrefix, outgoingPayload)
			if encodeErr != nil {
				break
			}
			dataPacket := proto.NewPacket(outgoingOpcode, currentKeyID, encodedPayload)
			if outgoingOpcode == proto.OpcodeDataV2 {
				encodedPeerID := *peerID & 0x00ffffff
				dataPacket.PeerID = proto.PeerID{
					byte(encodedPeerID >> 16),
					byte(encodedPeerID >> 8),
					byte(encodedPeerID),
				}
			}
			var rawPacket []byte
			rawPacket, encodeErr = dataPacket.Bytes()
			if encodeErr != nil {
				break
			}
			encodedPackets = append(encodedPackets, tlsOutgoingDataPacket{
				rawPayload:     rawPacket,
				packetID:       packetID,
				aeadBlockBytes: len(encodedPayload) + len(aadPrefix),
				accountedBytes: len(rawPacket),
			})
			lastEncodedPacket[i] = len(encodedPackets) - 1
		}
		if encodeErr != nil {
			break
		}
		completedPayloads++
	}
	rawPackets := make([][]byte, len(encodedPackets))
	for i, encodedPacket := range encodedPackets {
		rawPackets[i] = encodedPacket.rawPayload
	}
	dataWriteObserver, writeActivityObserver, writeBytesObserver := s.currentWriteObservers()
	if dataWriteObserver != nil {
		for _, encodedPacket := range encodedPackets {
			dataWriteObserver(currentKeyID, encodedPacket.packetID, encodedPacket.aeadBlockBytes, encodedPacket.accountedBytes)
		}
	}
	writtenPackets, writeErr := s.packetConnection.WritePackets(rawPackets)
	for i, payload := range payloads[:completedPayloads] {
		if lastEncodedPacket[i] < 0 {
			continue
		}
		if lastEncodedPacket[i] >= writtenPackets {
			break
		}
		if writeActivityObserver != nil {
			writeActivityObserver()
		}
		if writeBytesObserver != nil && !bytes.Equal(payload, openVPNDataChannelPingPayload) {
			writeBytesObserver(len(payload))
		}
	}
	if writeErr != nil {
		return writeErr
	}
	return encodeErr
}

type tlsOutgoingDataBuffer struct {
	buffer         *buf.Buffer
	packetID       uint32
	aeadBlockBytes int
	accountedBytes int
}

func (s *tlsPeerSession) writeDataPacketBuffersLocked(payloads []*buf.Buffer) error {
	retainedPayloads := payloads[:0]
	for _, payload := range payloads {
		if payload.IsEmpty() {
			payload.Release()
			continue
		}
		retainedPayloads = append(retainedPayloads, payload)
	}
	payloads = retainedPayloads
	if len(payloads) == 0 {
		return nil
	}
	payloadLengths := make([]int, len(payloads))
	payloadPings := make([]bool, len(payloads))
	for i, payload := range payloads {
		payloadLengths[i] = payload.Len()
		payloadPings[i] = bytes.Equal(payload.Bytes(), openVPNDataChannelPingPayload)
	}
	sendCodec, currentKeyID, sendSessionManager := s.currentSendKeyState()
	if sendCodec == nil {
		buf.ReleaseMulti(payloads)
		return ErrDataChannelNotReady
	}
	if sendSessionManager == nil {
		sendSessionManager = s.sessionManager
	}
	peerID := s.currentPeerID()
	outgoingOpcode := proto.OpcodeDataV1
	if peerID != nil {
		outgoingOpcode = proto.OpcodeDataV2
	}
	packetHeaderSize := s.dataPacketHeaderSize(outgoingOpcode)
	var aadPrefix []byte
	if outgoingOpcode == proto.OpcodeDataV2 {
		header := byte((uint8(outgoingOpcode) << 3) | (currentKeyID & 0x07))
		encodedPeerID := *peerID & 0x00ffffff
		aadPrefix = []byte{
			header,
			byte(encodedPeerID >> 16),
			byte(encodedPeerID >> 8),
			byte(encodedPeerID),
		}
	}
	preparedPayloads := s.hooks.outgoingDataBuffers(payloads, sendCodec, packetHeaderSize)
	preparedPacketCount := 0
	for _, outgoingPayloads := range preparedPayloads {
		preparedPacketCount += len(outgoingPayloads)
	}
	if preparedPacketCount == 0 {
		return nil
	}
	dataPacketIDs, err := sendSessionManager.NewDataPacketIDs(outgoingOpcode, preparedPacketCount)
	if err != nil {
		for _, outgoingPayloads := range preparedPayloads {
			buf.ReleaseMulti(outgoingPayloads)
		}
		return err
	}
	encodedPackets := make([]tlsOutgoingDataBuffer, 0, preparedPacketCount)
	lastEncodedPacket := make([]int, len(payloads))
	for i := range lastEncodedPacket {
		lastEncodedPacket[i] = -1
	}
	dataPacketIndex := 0
	for i, outgoingPayloads := range preparedPayloads {
		for j, outgoingPayload := range outgoingPayloads {
			packetID := uint32(dataPacketIDs[dataPacketIndex])
			dataPacketIndex++
			requiredHeadroom := packetHeaderSize + 4 + tlsDataAEADTagSize
			if outgoingPayload.Start() < requiredHeadroom || outgoingPayload.FreeLen() < tlsDataAEADTagSize {
				newPayload := buf.NewSize(requiredHeadroom + outgoingPayload.Len() + tlsDataAEADTagSize)
				newPayload.Resize(requiredHeadroom, 0)
				_, _ = newPayload.Write(outgoingPayload.Bytes())
				outgoingPayload.Release()
				outgoingPayload = newPayload
			}
			encodedPayload, encodeErr := sendCodec.EncodeBuffer(packetID, aadPrefix, outgoingPayload)
			if encodeErr != nil {
				buf.ReleaseMulti(outgoingPayloads[j+1:])
				for _, remainingPayloads := range preparedPayloads[i+1:] {
					buf.ReleaseMulti(remainingPayloads)
				}
				for _, encodedPacket := range encodedPackets {
					encodedPacket.buffer.Release()
				}
				return encodeErr
			}
			aeadBlockBytes := encodedPayload.Len() + len(aadPrefix)
			if outgoingOpcode == proto.OpcodeDataV2 {
				copy(encodedPayload.ExtendHeader(len(aadPrefix)), aadPrefix)
			} else {
				encodedPayload.ExtendHeader(1)[0] = byte((uint8(outgoingOpcode) << 3) | (currentKeyID & 0x07))
			}
			encodedPackets = append(encodedPackets, tlsOutgoingDataBuffer{
				buffer:         encodedPayload,
				packetID:       packetID,
				aeadBlockBytes: aeadBlockBytes,
				accountedBytes: encodedPayload.Len(),
			})
			lastEncodedPacket[i] = len(encodedPackets) - 1
		}
	}
	packetBuffers := make([]*buf.Buffer, len(encodedPackets))
	for i, encodedPacket := range encodedPackets {
		packetBuffers[i] = encodedPacket.buffer
	}
	dataWriteObserver, writeActivityObserver, writeBytesObserver := s.currentWriteObservers()
	if dataWriteObserver != nil {
		for _, encodedPacket := range encodedPackets {
			dataWriteObserver(currentKeyID, encodedPacket.packetID, encodedPacket.aeadBlockBytes, encodedPacket.accountedBytes)
		}
	}
	writtenPackets, writeErr := s.packetConnection.WritePacketBuffers(packetBuffers)
	for i := range payloads {
		if lastEncodedPacket[i] < 0 {
			continue
		}
		if lastEncodedPacket[i] >= writtenPackets {
			break
		}
		if writeActivityObserver != nil {
			writeActivityObserver()
		}
		if writeBytesObserver != nil && !payloadPings[i] {
			writeBytesObserver(payloadLengths[i])
		}
	}
	return writeErr
}

func (s *tlsPeerSession) dataPacketHeaderSize(opcode proto.Opcode) int {
	headerSize := s.dataTransportHeaderSize
	if opcode == proto.OpcodeDataV2 {
		return headerSize + 4
	}
	return headerSize + 1
}

func dataTransportHeaderSize(protocol string) int {
	if strings.HasPrefix(protocol, "tcp") {
		return 2
	}
	return 0
}
