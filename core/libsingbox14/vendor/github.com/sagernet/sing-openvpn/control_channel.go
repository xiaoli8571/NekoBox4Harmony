package openvpn

import (
	"crypto/tls"
	"net"
	"os"
	"sync"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
)

const (
	// Upstream TLS_CHANNEL_BUF_SIZE bounds a single control channel payload and
	// TLS_MTU_DEFAULT is the --max-packet-size default which bounds the whole
	// control channel packet including its overhead.
	tlsControlPayloadSize = 1024
	tlsControlChannelMTU  = 1250
)

func isControlOrAcknowledgmentOpcode(opcode proto.Opcode) bool {
	return opcode.IsControl() || opcode == proto.OpcodeAcknowledgmentV1
}

type tlsControlChannel struct {
	packetConnection proto.PacketConnection
	sessionManager   *proto.SessionManager
	protection       tlsControlProtection
	outgoing         *proto.OutgoingReliableState
	incoming         *proto.IncomingReliableState
	onDataPackets    func([]*proto.Packet)
	onSoftReset      func(*proto.Packet)
	wrappedClientKey []byte
	readChunks       chan []byte
	closeOnce        sync.Once
	closed           chan struct{}
	loopWaitGroup    sync.WaitGroup
	outgoingAccess   sync.Mutex
	readAccess       sync.Mutex
	readRemainder    []byte
	deadlineAccess   sync.Mutex
	readDeadline     time.Time
	writeDeadline    time.Time
	activityAccess   sync.RWMutex
	readActivity     func()
	writeActivity    func()
	tlsAccess        sync.RWMutex
	tlsConnection    *tls.Conn

	// Upstream tls_pre_decrypt keeps every live key_state addressable by
	// key_id.  The root channel remains the sole packet reader and dispatches
	// packets to the reliable/TLS channel which owns that key-id.
	renegotiationAccess   sync.Mutex
	renegotiationChannels map[uint8]*tlsControlChannel
}

func (c *tlsControlChannel) setTLSConnection(connection *tls.Conn) {
	c.tlsAccess.Lock()
	c.tlsConnection = connection
	c.tlsAccess.Unlock()
}

func (c *tlsControlChannel) connection() *tls.Conn {
	c.tlsAccess.RLock()
	defer c.tlsAccess.RUnlock()
	return c.tlsConnection
}

func newTLSControlChannel(
	packetConnection proto.PacketConnection,
	sessionManager *proto.SessionManager,
	protection tlsControlProtection,
	onDataPackets func([]*proto.Packet),
	onSoftReset func(*proto.Packet),
) *tlsControlChannel {
	return &tlsControlChannel{
		packetConnection:      packetConnection,
		sessionManager:        sessionManager,
		protection:            protection,
		outgoing:              proto.NewOutgoingReliableState(),
		incoming:              proto.NewIncomingReliableState(),
		onDataPackets:         onDataPackets,
		onSoftReset:           onSoftReset,
		readChunks:            make(chan []byte, 32),
		closed:                make(chan struct{}),
		renegotiationChannels: make(map[uint8]*tlsControlChannel),
	}
}

func (c *tlsControlChannel) registerRenegotiationChannel(keyID uint8, channel *tlsControlChannel) bool {
	if keyID == 0 || keyID > proto.KeyIDMaxValue || channel == nil {
		return false
	}
	readActivity, writeActivity := c.activityObservers()
	channel.setActivityObservers(readActivity, writeActivity)
	c.renegotiationAccess.Lock()
	defer c.renegotiationAccess.Unlock()
	if _, loaded := c.renegotiationChannels[keyID]; loaded {
		return false
	}
	c.renegotiationChannels[keyID] = channel
	return true
}

func (c *tlsControlChannel) setActivityObservers(readActivity func(), writeActivity func()) {
	c.activityAccess.Lock()
	c.readActivity = readActivity
	c.writeActivity = writeActivity
	c.activityAccess.Unlock()
	c.renegotiationAccess.Lock()
	children := make([]*tlsControlChannel, 0, len(c.renegotiationChannels))
	for _, child := range c.renegotiationChannels {
		children = append(children, child)
	}
	c.renegotiationAccess.Unlock()
	for _, child := range children {
		child.setActivityObservers(readActivity, writeActivity)
	}
}

func (c *tlsControlChannel) activityObservers() (func(), func()) {
	c.activityAccess.RLock()
	defer c.activityAccess.RUnlock()
	return c.readActivity, c.writeActivity
}

func (c *tlsControlChannel) markReadActivity() {
	readActivity, _ := c.activityObservers()
	if readActivity != nil {
		readActivity()
	}
}

func (c *tlsControlChannel) markWriteActivity() {
	_, writeActivity := c.activityObservers()
	if writeActivity != nil {
		writeActivity()
	}
}

func (c *tlsControlChannel) unregisterRenegotiationChannel(keyID uint8, channel *tlsControlChannel) {
	c.renegotiationAccess.Lock()
	if c.renegotiationChannels[keyID] == channel {
		delete(c.renegotiationChannels, keyID)
	}
	c.renegotiationAccess.Unlock()
}

func (c *tlsControlChannel) routeToRenegotiationChannel(packet *proto.Packet) bool {
	if packet == nil || packet.KeyID == 0 {
		return false
	}
	c.renegotiationAccess.Lock()
	channel := c.renegotiationChannels[packet.KeyID]
	c.renegotiationAccess.Unlock()
	if channel == nil {
		return false
	}
	channel.processIncomingControlPacket(packet)
	return true
}

func (c *tlsControlChannel) seedIncomingPacket(packet *proto.Packet) {
	if packet == nil {
		return
	}
	if !c.sessionManager.ValidateIncomingRemoteSessionID(packet) {
		return
	}
	c.outgoing.OnIncomingPacket(packet)
}

func (c *tlsControlChannel) Read(buffer []byte) (int, error) {
	for {
		c.readAccess.Lock()
		if len(c.readRemainder) > 0 {
			readCount := copy(buffer, c.readRemainder)
			c.readRemainder = c.readRemainder[readCount:]
			c.readAccess.Unlock()
			return readCount, nil
		}
		c.readAccess.Unlock()

		readDeadline, hasDeadline := c.currentReadDeadline()
		if hasDeadline {
			timeout := time.Until(readDeadline)
			if timeout <= 0 {
				return 0, os.ErrDeadlineExceeded
			}
			timer := time.NewTimer(timeout)
			select {
			case chunk := <-c.readChunks:
				timer.Stop()
				if len(chunk) == 0 {
					continue
				}
				c.readAccess.Lock()
				c.readRemainder = chunk
				c.readAccess.Unlock()
			case <-c.closed:
				timer.Stop()
				return 0, net.ErrClosed
			case <-timer.C:
				return 0, os.ErrDeadlineExceeded
			}
			continue
		}

		select {
		case chunk := <-c.readChunks:
			if len(chunk) == 0 {
				continue
			}
			c.readAccess.Lock()
			c.readRemainder = chunk
			c.readAccess.Unlock()
		case <-c.closed:
			return 0, net.ErrClosed
		}
	}
}

func (c *tlsControlChannel) Write(buffer []byte) (int, error) {
	totalWritten := 0
	for len(buffer) > 0 {
		writeDeadline, hasDeadline := c.currentWriteDeadline()
		if hasDeadline && !time.Now().Before(writeDeadline) {
			return totalWritten, os.ErrDeadlineExceeded
		}
		packet, chunkSize, err := c.newOutgoingControlPacket(buffer)
		if err != nil {
			return totalWritten, err
		}
		if packet == nil {
			timer := time.NewTimer(10 * time.Millisecond)
			select {
			case <-c.closed:
				timer.Stop()
				return totalWritten, net.ErrClosed
			case <-timer.C:
			}
			continue
		}
		err = c.writePacket(packet)
		if err != nil {
			return totalWritten, err
		}
		totalWritten += chunkSize
		buffer = buffer[chunkSize:]
	}
	return totalWritten, nil
}

// Upstream write_outgoing_tls_ciphertext takes the reliable send buffer slot
// before it spends the control packet id, and splits the TLS ciphertext into
// packets of min(TLS_CHANNEL_BUF_SIZE, --max-packet-size) minus the control
// channel frame overhead.  The packet which carries the appended tls-crypt-v2
// wrapped client key is shortened by that key's length, down to an empty
// payload when the key alone fills the packet.  No packet is returned while the
// reliable send buffer holds no free slot.
func (c *tlsControlChannel) newOutgoingControlPacket(buffer []byte) (*proto.Packet, int, error) {
	c.outgoingAccess.Lock()
	defer c.outgoingAccess.Unlock()
	payloadSize := min(tlsControlPayloadSize, tlsControlChannelMTU) -
		c.controlChannelFrameOverhead(c.outgoing.PendingAcknowledgmentCount())
	if c.nextPacketCarriesWrappedClientKey() {
		payloadSize = max(0, payloadSize-len(c.wrappedClientKey))
	}
	chunkSize := min(len(buffer), payloadSize)
	packet, err := c.outgoing.InsertOutgoingPacket(
		proto.MaximumAcknowledgmentsPerPacket,
		func(acknowledgmentIDs []proto.PacketID) (*proto.Packet, error) {
			controlPacket, controlErr := c.sessionManager.NewControlPacket(proto.OpcodeControlV1, buffer[:chunkSize])
			if controlErr != nil {
				return nil, controlErr
			}
			controlPacket.AcknowledgmentIDs = acknowledgmentIDs
			return controlPacket, nil
		},
	)
	if err != nil || packet == nil {
		return nil, 0, err
	}
	return packet, chunkSize, nil
}

// Upstream calc_control_channel_frame_overhead books the opcode, the local
// session id, the acknowledgment array, the control packet id, the tls-auth or
// tls-crypt overhead and the UDP datagram overhead of the peer's address
// family, the last one even when the session runs over TCP.
func (c *tlsControlChannel) controlChannelFrameOverhead(acknowledgmentCount int) int {
	overhead := 1 + proto.SessionIDLength
	overhead += acknowledgmentArrayLength(acknowledgmentCount)
	overhead += proto.PacketIDLength
	overhead += c.protection.controlPacketOverhead()
	overhead += controlChannelDatagramOverhead(c.packetConnection.RemoteAddr())
	return overhead
}

// Upstream ACK_SIZE.
func acknowledgmentArrayLength(acknowledgmentCount int) int {
	acknowledgmentCount = min(acknowledgmentCount, proto.MaximumAcknowledgmentsPerPacket)
	if acknowledgmentCount == 0 {
		return 1
	}
	return 1 + proto.PacketIDLength*acknowledgmentCount + proto.SessionIDLength
}

func controlChannelDatagramOverhead(remoteAddress net.Addr) int {
	ipHeaderSize := ipv6HeaderLength
	if remoteAddress != nil && M.SocksaddrFromNet(remoteAddress).Addr.Is4() {
		ipHeaderSize = ipv4HeaderMinLength
	}
	return ipHeaderSize + udpHeaderLength
}

// Upstream control_packet_needs_wkc keeps the wrapped client key on reliable
// packet 1 until the peer acknowledges it.
func (c *tlsControlChannel) nextPacketCarriesWrappedClientKey() bool {
	return len(c.wrappedClientKey) > 0 && c.sessionManager.NextLocalControlPacketID() == 1
}

func (c *tlsControlChannel) waitForReliableDelivery(timeout time.Duration) bool {
	if timeout <= 0 {
		return !c.outgoing.HasInFlightPackets()
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for c.outgoing.HasInFlightPackets() {
		select {
		case <-c.closed:
			return false
		case <-timer.C:
			return false
		case <-ticker.C:
		}
	}
	return true
}

// Upstream session_move_pre_start sends the soft-reset initial_opcode as
// packet ID 0 on the new key_state.
func (c *tlsControlChannel) sendInitialSoftReset() error {
	c.outgoingAccess.Lock()
	packet, err := c.outgoing.InsertOutgoingPacket(
		proto.MaximumAcknowledgmentsPerPacket,
		func(acknowledgmentIDs []proto.PacketID) (*proto.Packet, error) {
			softResetPacket, softResetErr := c.sessionManager.NewSoftResetPacket()
			if softResetErr != nil {
				return nil, softResetErr
			}
			softResetPacket.AcknowledgmentIDs = acknowledgmentIDs
			return softResetPacket, nil
		},
	)
	c.outgoingAccess.Unlock()
	if err != nil {
		return err
	}
	if packet == nil {
		return net.ErrClosed
	}
	return c.writePacket(packet)
}

func (c *tlsControlChannel) Close() error {
	c.shutdown()
	c.loopWaitGroup.Wait()
	return nil
}

func (c *tlsControlChannel) LocalAddr() net.Addr {
	return c.packetConnection.LocalAddr()
}

func (c *tlsControlChannel) RemoteAddr() net.Addr {
	return c.packetConnection.RemoteAddr()
}

// Upstream key_state_read_plaintext and key_state_write_plaintext move bytes
// between the TLS object of one key_state and that key_state's reliable layer
// and never touch the link: one io_wait drives the whole instance, so a
// key_state's must_negotiate stamp reaches neither the link read nor the link
// write and the link keeps serving the other key_states of the session, the
// data channel and, on a server, every other instance bound to the socket.
// tls_process fails only the key_state whose stamp expired, and its own
// plaintext reads and writes are all that stamp bounds.
func (c *tlsControlChannel) SetDeadline(deadline time.Time) error {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	c.readDeadline = deadline
	c.writeDeadline = deadline
	return nil
}

func (c *tlsControlChannel) SetReadDeadline(deadline time.Time) error {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	c.readDeadline = deadline
	return nil
}

func (c *tlsControlChannel) SetWriteDeadline(deadline time.Time) error {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	c.writeDeadline = deadline
	return nil
}

func (c *tlsControlChannel) currentReadDeadline() (time.Time, bool) {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	return c.readDeadline, !c.readDeadline.IsZero()
}

func (c *tlsControlChannel) currentWriteDeadline() (time.Time, bool) {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	return c.writeDeadline, !c.writeDeadline.IsZero()
}

func (c *tlsControlChannel) runReader() {
	defer c.loopWaitGroup.Done()
	for {
		select {
		case <-c.closed:
			return
		default:
		}
		err := c.setNextPacketReadDeadline()
		if err != nil {
			c.shutdown()
			return
		}
		rawPacketBuffers, readErr := c.packetConnection.ReadPackets()
		dataPackets := make([]*proto.Packet, 0, len(rawPacketBuffers))
		dataPacketBuffers := make([]*buf.Buffer, 0, len(rawPacketBuffers))
		flushDataPackets := func() {
			if len(dataPackets) > 0 && c.onDataPackets != nil {
				c.onDataPackets(dataPackets)
			}
			buf.ReleaseMulti(dataPacketBuffers)
			dataPackets = dataPackets[:0]
			dataPacketBuffers = dataPacketBuffers[:0]
		}
		for rawPacketIndex, rawPacketBuffer := range rawPacketBuffers {
			rawPacket := rawPacketBuffer.Bytes()
			if len(rawPacket) == 0 || !proto.Opcode(rawPacket[0]>>3).IsData() {
				flushDataPackets()
			}
			packet, parseErr := c.parseIncomingPacket(rawPacket)
			if parseErr != nil {
				rawPacketBuffer.Release()
				flushDataPackets()
				continue
			}
			if packet.Opcode.IsData() {
				dataPackets = append(dataPackets, packet)
				dataPacketBuffers = append(dataPacketBuffers, rawPacketBuffer)
				continue
			}
			rawPacketBuffer.Release()
			flushDataPackets()
			if c.routeToRenegotiationChannel(packet) {
				continue
			}
			if !c.processIncomingControlPacket(packet) {
				flushDataPackets()
				buf.ReleaseMulti(rawPacketBuffers[rawPacketIndex+1:])
				return
			}
		}
		flushDataPackets()
		if readErr != nil {
			if E.IsTimeout(readErr) {
				continue
			}
			c.shutdown()
			return
		}
	}
}

// A deadline the TLS object of one key_state sets on this conn may only
// postpone the moment the packet reader re-checks whether the session ended,
// never bring it forward: shortening it would starve the key_states which do
// not own that TLS object.
func (c *tlsControlChannel) setNextPacketReadDeadline() error {
	c.deadlineAccess.Lock()
	readDeadline := c.readDeadline
	c.deadlineAccess.Unlock()
	pollDeadline := time.Now().Add(time.Second)
	if readDeadline.After(pollDeadline) {
		pollDeadline = readDeadline
	}
	return c.packetConnection.SetReadDeadline(pollDeadline)
}

func (c *tlsControlChannel) processIncomingControlPacket(packet *proto.Packet) bool {
	if !c.sessionManager.ValidateIncomingRemoteSessionID(packet) {
		return true
	}
	// Upstream tls_pre_decrypt matches a hard reset against the session ids its
	// tls_multi holds before anything else happens to it, and a hard reset which
	// matches none of them never reaches the reliable layer of an established
	// session: it opens a fresh TM_INITIAL tls_session instead and leaves
	// TM_ACTIVE serving, so no unauthenticated reset acknowledges this session's
	// packets, refreshes its peer_last_packet or ends it.
	if isTLSHardResetOpcode(packet.Opcode) {
		if packet.KeyID != 0 || c.sessionManager.CurrentKeyID() != 0 {
			return true
		}
		if !c.sessionManager.ValidateIncomingLocalSessionID(packet) {
			return true
		}
		c.outgoing.OnIncomingPacket(packet)
		c.markReadActivity()
		return true
	}
	if packet.Opcode == proto.OpcodeControlSoftResetV1 {
		if !c.sessionManager.ValidateIncomingLocalSessionID(packet) {
			return true
		}
		if c.onSoftReset != nil {
			c.markReadActivity()
			c.onSoftReset(packet)
		} else {
			c.outgoing.OnIncomingPacket(packet)
			c.markReadActivity()
		}
		return true
	}
	if !c.sessionManager.ValidateIncomingLocalSessionID(packet) {
		return true
	}
	if packet.KeyID != c.sessionManager.CurrentKeyID() {
		return true
	}
	c.outgoing.OnIncomingPacket(packet)
	c.markReadActivity()
	if packet.Opcode == proto.OpcodeAcknowledgmentV1 {
		return true
	}
	if !packet.Opcode.IsControl() {
		return true
	}
	if !c.incoming.TryInsertIncomingPacket(packet) {
		return true
	}
	for _, orderedPacket := range c.incoming.NextOrderedSequence() {
		if len(orderedPacket.Payload) == 0 {
			continue
		}
		payloadCopy := append([]byte{}, orderedPacket.Payload...)
		select {
		case c.readChunks <- payloadCopy:
		case <-c.closed:
			return false
		}
	}
	return true
}

// Upstream tls_process (ssl.c) leaves a control packet in the reliable send
// buffer once reliable_mark_active_outgoing has armed its retransmit timer, and
// a link write that fails afterwards only reaches check_status: the reliable
// layer resends the packet and the key state is never reset because of it.
func (c *tlsControlChannel) runSender() {
	defer c.loopWaitGroup.Done()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-c.closed:
			return
		case <-ticker.C:
		}
		now := time.Now()
		for _, packet := range c.outgoing.PacketsReadyToSend(now) {
			_ = c.writePacket(packet)
		}
		if c.outgoing.PendingAcknowledgmentCount() == 0 {
			continue
		}
		ackPacket, err := c.newAcknowledgmentPacket()
		if err != nil {
			continue
		}
		_ = c.writePacket(ackPacket)
	}
}

// Upstream tls_process writes its dedicated P_ACK into a scratch buffer, except
// while the wrapped client key still has to be resent: it then takes an empty
// control packet out of the reliable send buffer and marks it P_CONTROL_WKC_V1,
// so the key is retransmitted until the peer acknowledges it.  Both carry up to
// RELIABLE_ACK_SIZE acknowledgments, unlike a packet which also carries control
// channel payload.
func (c *tlsControlChannel) newAcknowledgmentPacket() (*proto.Packet, error) {
	c.outgoingAccess.Lock()
	defer c.outgoingAccess.Unlock()
	if c.nextPacketCarriesWrappedClientKey() {
		packet, err := c.outgoing.InsertOutgoingPacket(
			proto.AcknowledgmentSetCapacity,
			func(acknowledgmentIDs []proto.PacketID) (*proto.Packet, error) {
				wrappedKeyPacket, controlErr := c.sessionManager.NewControlPacket(proto.OpcodeControlWKCv1, nil)
				if controlErr != nil {
					return nil, controlErr
				}
				wrappedKeyPacket.AcknowledgmentIDs = acknowledgmentIDs
				return wrappedKeyPacket, nil
			},
		)
		if err != nil {
			return nil, err
		}
		if packet == nil {
			return nil, E.New("reliable send buffer is full")
		}
		return packet, nil
	}
	acknowledgmentIDs := c.outgoing.TakeAcknowledgmentIDs(proto.AcknowledgmentSetCapacity)
	if len(acknowledgmentIDs) == 0 {
		return nil, E.New("no pending acknowledgment")
	}
	packet, err := c.sessionManager.NewAcknowledgmentPacket(acknowledgmentIDs)
	if err != nil {
		c.outgoing.ReturnAcknowledgmentIDs(acknowledgmentIDs)
		return nil, err
	}
	return packet, nil
}

func (c *tlsControlChannel) shutdown() {
	c.closeOnce.Do(func() {
		close(c.closed)
	})
}

func (c *tlsControlChannel) writePacket(packet *proto.Packet) error {
	outgoingPacket := packet
	if c.shouldSendWrappedClientKey(packet) && packet.Opcode != proto.OpcodeControlWKCv1 {
		packetCopy := *packet
		packetCopy.Opcode = proto.OpcodeControlWKCv1
		outgoingPacket = &packetCopy
	}
	rawPacket, err := outgoingPacket.Bytes()
	if err == nil {
		if isControlOrAcknowledgmentOpcode(outgoingPacket.Opcode) {
			rawPacket = c.protection.encodeOutgoingControlPacket(rawPacket)
		}
		if c.shouldSendWrappedClientKey(outgoingPacket) {
			rawPacket = appendTLSCryptV2WrappedClientKey(rawPacket, c.wrappedClientKey, outgoingPacket.Opcode)
		}
		err = c.packetConnection.WritePacket(rawPacket)
	}
	if err != nil {
		// A dedicated P_ACK_V1 is the one packet the reliable send buffer does
		// not hold, so nothing carries its acknowledgment ids again once the
		// datagram fails to reach the link and they stay pending.
		if outgoingPacket.Opcode == proto.OpcodeAcknowledgmentV1 {
			c.outgoing.ReturnAcknowledgmentIDs(outgoingPacket.AcknowledgmentIDs)
		}
		return err
	}
	c.markWriteActivity()
	return nil
}

func (c *tlsControlChannel) shouldSendWrappedClientKey(packet *proto.Packet) bool {
	if packet == nil || len(c.wrappedClientKey) == 0 || packet.ID != 1 {
		return false
	}
	return packet.Opcode == proto.OpcodeControlV1 || packet.Opcode == proto.OpcodeControlWKCv1
}

func (c *tlsControlChannel) parseIncomingPacket(rawPacket []byte) (*proto.Packet, error) {
	if len(rawPacket) == 0 {
		return nil, E.New("empty packet")
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
	if opcode.IsData() {
		return proto.ParsePacketView(packetBytes)
	}
	return proto.ParsePacket(packetBytes)
}

func isTLSHardResetOpcode(opcode proto.Opcode) bool {
	switch opcode {
	case proto.OpcodeControlHardResetClientV1,
		proto.OpcodeControlHardResetServerV1,
		proto.OpcodeControlHardResetClientV2,
		proto.OpcodeControlHardResetServerV2,
		proto.OpcodeControlHardResetClientV3:
		return true
	default:
		return false
	}
}
