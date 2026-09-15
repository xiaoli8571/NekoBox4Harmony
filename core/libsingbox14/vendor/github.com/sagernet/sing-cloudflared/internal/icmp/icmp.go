package icmp

import (
	"context"
	"net/netip"
	"sync"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/protocol"
	"github.com/sagernet/sing-tun"
	"github.com/sagernet/sing-tun/gtcpip/header"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
)

const (
	FlowTimeout             = 30 * time.Second
	TraceIdentityLength     = 16 + 8 + 1
	defaultPacketTTL        = 255
	IPv4TTLExceededQuoteLen = 548
	IPv6TTLExceededQuoteLen = 1232
	MaxPayloadLen           = 1280
)

type WireVersion uint8

const (
	WireV2 WireVersion = iota + 1
	WireV3
)

type TraceContext struct {
	Traced   bool
	Identity []byte
}

type FlowKey struct {
	IPVersion   uint8
	SourceIP    netip.Addr
	Destination netip.Addr
}

type RequestKey struct {
	Flow       FlowKey
	Identifier uint16
	Sequence   uint16
}

type PacketInfo struct {
	IPVersion     uint8
	Protocol      uint8
	SourceIP      netip.Addr
	Destination   netip.Addr
	ICMPType      uint8
	ICMPCode      uint8
	Identifier    uint16
	Sequence      uint16
	IPv4HeaderLen int
	IPv4TTL       uint8
	IPv6HopLimit  uint8
	RawPacket     []byte
}

func (i PacketInfo) FlowKey() FlowKey {
	return FlowKey{
		IPVersion:   i.IPVersion,
		SourceIP:    i.SourceIP,
		Destination: i.Destination,
	}
}

func (i PacketInfo) RequestKey() RequestKey {
	return RequestKey{
		Flow:       i.FlowKey(),
		Identifier: i.Identifier,
		Sequence:   i.Sequence,
	}
}

func (i PacketInfo) ReplyRequestKey() RequestKey {
	return RequestKey{
		Flow: FlowKey{
			IPVersion:   i.IPVersion,
			SourceIP:    i.Destination,
			Destination: i.SourceIP,
		},
		Identifier: i.Identifier,
		Sequence:   i.Sequence,
	}
}

func (i PacketInfo) IsEchoRequest() bool {
	switch i.IPVersion {
	case 4:
		return i.ICMPType == uint8(header.ICMPv4Echo) && i.ICMPCode == 0
	case 6:
		return i.ICMPType == uint8(header.ICMPv6EchoRequest) && i.ICMPCode == 0
	default:
		return false
	}
}

func (i PacketInfo) IsEchoReply() bool {
	switch i.IPVersion {
	case 4:
		return i.ICMPType == uint8(header.ICMPv4EchoReply) && i.ICMPCode == 0
	case 6:
		return i.ICMPType == uint8(header.ICMPv6EchoReply) && i.ICMPCode == 0
	default:
		return false
	}
}

func (i PacketInfo) TTL() uint8 {
	if i.IPVersion == 4 {
		return i.IPv4TTL
	}
	return i.IPv6HopLimit
}

func (i PacketInfo) TTLExpired() bool {
	return i.TTL() <= 1
}

func (i *PacketInfo) DecrementTTL() error {
	switch i.IPVersion {
	case 4:
		if i.IPv4TTL == 0 || i.IPv4HeaderLen < header.IPv4MinimumSize || len(i.RawPacket) < i.IPv4HeaderLen {
			return E.New("invalid IPv4 packet TTL state")
		}
		i.IPv4TTL--
		ipHeader := header.IPv4(i.RawPacket)
		ipHeader.SetTTL(i.IPv4TTL)
		ipHeader.SetChecksum(0)
		ipHeader.SetChecksum(^ipHeader.CalculateChecksum())
	case 6:
		if i.IPv6HopLimit == 0 || len(i.RawPacket) < header.IPv6MinimumSize {
			return E.New("invalid IPv6 packet hop limit state")
		}
		i.IPv6HopLimit--
		ipHeader := header.IPv6(i.RawPacket)
		ipHeader.SetHopLimit(i.IPv6HopLimit)
	default:
		return E.New("unsupported IP version: ", i.IPVersion)
	}
	return nil
}

type FlowState struct {
	writer       *ReplyWriter
	activeAccess sync.RWMutex
	lastActive   time.Time

	routeAccess   sync.Mutex
	routeResolved bool
	routePort     tun.Port
}

type TraceEntry struct {
	context   TraceContext
	createdAt time.Time
}

type ReplyWriter struct {
	sender      protocol.DatagramSender
	WireVersion WireVersion

	access sync.Mutex
	traces map[RequestKey]TraceEntry
}

func NewReplyWriter(sender protocol.DatagramSender, WireVersion WireVersion) *ReplyWriter {
	return &ReplyWriter{
		sender:      sender,
		WireVersion: WireVersion,
		traces:      make(map[RequestKey]TraceEntry),
	}
}

func (w *ReplyWriter) RegisterRequestTrace(packetInfo PacketInfo, traceContext TraceContext) {
	if !traceContext.Traced {
		return
	}
	w.access.Lock()
	w.traces[packetInfo.RequestKey()] = TraceEntry{
		context:   traceContext,
		createdAt: time.Now(),
	}
	w.access.Unlock()
}

func (w *ReplyWriter) WritePacket(packet []byte) error {
	packetInfo, err := ParsePacket(packet)
	if err != nil {
		return err
	}
	if !packetInfo.IsEchoReply() {
		return nil
	}

	requestKey := packetInfo.ReplyRequestKey()
	w.access.Lock()
	entry, loaded := w.traces[requestKey]
	if loaded {
		delete(w.traces, requestKey)
	}
	w.access.Unlock()
	traceContext := entry.context

	datagram, err := EncodeDatagram(packetInfo.RawPacket, w.WireVersion, traceContext)
	if err != nil {
		return err
	}
	return w.sender.SendDatagram(datagram)
}

func (w *ReplyWriter) cleanupExpired(now time.Time) {
	w.access.Lock()
	defer w.access.Unlock()
	for key, entry := range w.traces {
		if now.After(entry.createdAt.Add(FlowTimeout)) {
			delete(w.traces, key)
		}
	}
}

type Bridge struct {
	ctx         context.Context
	handler     RouteHandler
	sender      protocol.DatagramSender
	WireVersion WireVersion
	logger      logger.ContextLogger

	flowAccess sync.Mutex
	flows      map[FlowKey]*FlowState

	portAccess    sync.Mutex
	attachedPorts map[tun.Port]bool
}

func NewBridge(ctx context.Context, handler RouteHandler, sender protocol.DatagramSender, WireVersion WireVersion, logger logger.ContextLogger) *Bridge {
	bridge := &Bridge{
		ctx:           ctx,
		handler:       handler,
		sender:        sender,
		WireVersion:   WireVersion,
		logger:        logger,
		flows:         make(map[FlowKey]*FlowState),
		attachedPorts: make(map[tun.Port]bool),
	}
	if ctx != nil {
		go bridge.cleanupLoop(ctx)
	}
	return bridge
}

func (b *Bridge) HandleV2(ctx context.Context, datagramType protocol.DatagramV2Type, payload []byte) error {
	traceContext := TraceContext{}
	switch datagramType {
	case protocol.DatagramV2TypeIP:
	case protocol.DatagramV2TypeIPWithTrace:
		if len(payload) < TraceIdentityLength {
			return E.New("icmp trace payload is too short")
		}
		traceContext.Traced = true
		traceContext.Identity = append([]byte(nil), payload[len(payload)-TraceIdentityLength:]...)
		payload = payload[:len(payload)-TraceIdentityLength]
	default:
		return E.New("unsupported v2 icmp datagram type: ", datagramType)
	}
	return b.handlePacket(ctx, payload, traceContext)
}

func (b *Bridge) HandleV3(ctx context.Context, payload []byte) error {
	return b.handlePacket(ctx, payload, TraceContext{})
}

func (b *Bridge) handlePacket(ctx context.Context, payload []byte, traceContext TraceContext) error {
	packetInfo, err := ParsePacket(payload)
	if err != nil {
		return err
	}
	if !packetInfo.IsEchoRequest() {
		return nil
	}
	if packetInfo.TTLExpired() {
		ttlExceededPacket, err := BuildTTLExceededPacket(packetInfo)
		if err != nil {
			return err
		}
		datagram, err := EncodeDatagram(ttlExceededPacket, b.WireVersion, traceContext)
		if err != nil {
			return err
		}
		return b.sender.SendDatagram(datagram)
	}

	err = packetInfo.DecrementTTL()
	if err != nil {
		return err
	}

	state := b.getFlowState(packetInfo.FlowKey())
	state.activeAccess.Lock()
	state.lastActive = time.Now()
	state.activeAccess.Unlock()
	if traceContext.Traced {
		state.writer.RegisterRequestTrace(packetInfo, traceContext)
	}

	if b.handler == nil {
		return nil
	}

	state.routeAccess.Lock()
	if !state.routeResolved {
		state.routePort = b.routeFlow(ctx, packetInfo)
		state.routeResolved = true
	}
	port := state.routePort
	state.routeAccess.Unlock()
	if port == nil {
		return nil
	}
	return port.WritePackets([][]byte{packetInfo.RawPacket})
}

func (b *Bridge) routeFlow(ctx context.Context, packetInfo PacketInfo) tun.Port {
	port, err := b.handler.RouteICMPFlow(packetInfo.SourceIP, packetInfo.Destination)
	if err != nil {
		b.logger.DebugContext(ctx, E.Cause(err, "route ICMP flow from ", packetInfo.SourceIP, " to ", packetInfo.Destination))
		return nil
	}
	err = b.attachPort(port)
	if err != nil {
		b.logger.ErrorContext(ctx, E.Cause(err, "attach ICMP return path"))
		return nil
	}
	return port
}

func (b *Bridge) attachPort(port tun.Port) error {
	b.portAccess.Lock()
	defer b.portAccess.Unlock()
	if b.attachedPorts[port] {
		return nil
	}
	err := port.AttachReturn(bridgeReturn{b})
	if err != nil {
		return err
	}
	b.attachedPorts[port] = true
	return nil
}

type bridgeReturn struct {
	bridge *Bridge
}

func (r bridgeReturn) ReturnHeadroom() int {
	return 0
}

func (r bridgeReturn) ReturnPackets(packets [][]byte) [][]byte {
	unconsumed := packets[:0]
	for _, packet := range packets {
		packetInfo, err := ParsePacket(packet)
		if err != nil || !packetInfo.IsEchoReply() {
			unconsumed = append(unconsumed, packet)
			continue
		}
		key := FlowKey{IPVersion: packetInfo.IPVersion, SourceIP: packetInfo.Destination, Destination: packetInfo.SourceIP}
		r.bridge.flowAccess.Lock()
		state := r.bridge.flows[key]
		r.bridge.flowAccess.Unlock()
		if state == nil {
			unconsumed = append(unconsumed, packet)
			continue
		}
		err = state.writer.WritePacket(packet)
		if err != nil {
			r.bridge.logger.Error(E.Cause(err, "write ICMP reply to ", packetInfo.Destination))
		}
	}
	return unconsumed
}

func (b *Bridge) getFlowState(key FlowKey) *FlowState {
	b.flowAccess.Lock()
	defer b.flowAccess.Unlock()
	state, loaded := b.flows[key]
	if loaded {
		return state
	}
	state = &FlowState{
		writer: NewReplyWriter(b.sender, b.WireVersion),
	}
	b.flows[key] = state
	return state
}

func (b *Bridge) detachPorts() {
	b.portAccess.Lock()
	defer b.portAccess.Unlock()
	for port := range b.attachedPorts {
		port.DetachReturn(bridgeReturn{b})
		delete(b.attachedPorts, port)
	}
}

func (b *Bridge) cleanupLoop(ctx context.Context) {
	defer b.detachPorts()
	ticker := time.NewTicker(FlowTimeout)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			b.cleanupExpired(now)
		}
	}
}

func (b *Bridge) cleanupExpired(now time.Time) {
	b.flowAccess.Lock()
	var expiredWriters []*ReplyWriter
	var activeWriters []*ReplyWriter
	for key, state := range b.flows {
		state.activeAccess.RLock()
		expired := now.After(state.lastActive.Add(FlowTimeout))
		state.activeAccess.RUnlock()
		if expired {
			expiredWriters = append(expiredWriters, state.writer)
			delete(b.flows, key)
		} else {
			activeWriters = append(activeWriters, state.writer)
		}
	}
	b.flowAccess.Unlock()
	for _, writer := range expiredWriters {
		writer.cleanupExpired(now)
	}
	for _, writer := range activeWriters {
		writer.cleanupExpired(now)
	}
}

func ParsePacket(packet []byte) (PacketInfo, error) {
	if len(packet) < 1 {
		return PacketInfo{}, E.New("empty IP packet")
	}
	switch header.IPVersion(packet) {
	case header.IPv4Version:
		return parseIPv4Packet(packet)
	case header.IPv6Version:
		return parseIPv6Packet(packet)
	default:
		return PacketInfo{}, E.New("unsupported IP version: ", packet[0]>>4)
	}
}

func parseIPv4Packet(packet []byte) (PacketInfo, error) {
	if len(packet) < header.IPv4MinimumSize {
		return PacketInfo{}, E.New("IPv4 packet too short")
	}
	ipHeader := header.IPv4(packet)
	headerLen := int(ipHeader.HeaderLength())
	if headerLen < header.IPv4MinimumSize || len(packet) < headerLen+header.ICMPv4MinimumSize {
		return PacketInfo{}, E.New("invalid IPv4 header length")
	}
	if ipHeader.Protocol() != uint8(header.ICMPv4ProtocolNumber) {
		return PacketInfo{}, E.New("IPv4 packet is not ICMP")
	}
	icmpHeader := header.ICMPv4(ipHeader.Payload())
	return PacketInfo{
		IPVersion:     4,
		Protocol:      uint8(header.ICMPv4ProtocolNumber),
		SourceIP:      ipHeader.SourceAddr(),
		Destination:   ipHeader.DestinationAddr(),
		ICMPType:      uint8(icmpHeader.Type()),
		ICMPCode:      uint8(icmpHeader.Code()),
		Identifier:    icmpHeader.Ident(),
		Sequence:      icmpHeader.Sequence(),
		IPv4HeaderLen: headerLen,
		IPv4TTL:       ipHeader.TTL(),
		RawPacket:     append([]byte(nil), packet...),
	}, nil
}

func parseIPv6Packet(packet []byte) (PacketInfo, error) {
	if len(packet) < header.IPv6MinimumSize+header.ICMPv6MinimumSize {
		return PacketInfo{}, E.New("IPv6 packet too short")
	}
	ipHeader := header.IPv6(packet)
	if ipHeader.NextHeader() != uint8(header.ICMPv6ProtocolNumber) {
		return PacketInfo{}, E.New("IPv6 packet is not ICMP")
	}
	icmpHeader := header.ICMPv6(ipHeader.Payload())
	return PacketInfo{
		IPVersion:    6,
		Protocol:     uint8(header.ICMPv6ProtocolNumber),
		SourceIP:     ipHeader.SourceAddr(),
		Destination:  ipHeader.DestinationAddr(),
		ICMPType:     uint8(icmpHeader.Type()),
		ICMPCode:     uint8(icmpHeader.Code()),
		Identifier:   icmpHeader.Ident(),
		Sequence:     icmpHeader.Sequence(),
		IPv6HopLimit: ipHeader.HopLimit(),
		RawPacket:    append([]byte(nil), packet...),
	}, nil
}

func MaxEncodedPacketLen(WireVersion WireVersion, traceContext TraceContext) int {
	limit := protocol.MaxV3UDPPayloadLen
	switch WireVersion {
	case WireV2:
		limit -= protocol.TypeIDLength
		if traceContext.Traced {
			limit -= len(traceContext.Identity)
		}
	case WireV3:
		limit -= 1
	default:
		return 0
	}
	if limit < 0 {
		return 0
	}
	return limit
}

func BuildTTLExceededPacket(packetInfo PacketInfo) ([]byte, error) {
	switch packetInfo.IPVersion {
	case 4:
		return buildIPv4TTLExceededPacket(packetInfo)
	case 6:
		return buildIPv6TTLExceededPacket(packetInfo)
	default:
		return nil, E.New("unsupported IP version: ", packetInfo.IPVersion)
	}
}

func buildIPv4TTLExceededPacket(packetInfo PacketInfo) ([]byte, error) {
	if !packetInfo.SourceIP.Is4() || !packetInfo.Destination.Is4() {
		return nil, E.New("TTL exceeded packet requires IPv4 addresses")
	}
	quotedLength := min(len(packetInfo.RawPacket), IPv4TTLExceededQuoteLen)
	packet := make([]byte, header.IPv4MinimumSize+header.ICMPv4MinimumSize+quotedLength)

	ipHeader := header.IPv4(packet)
	ipHeader.Encode(&header.IPv4Fields{
		TotalLength: uint16(len(packet)),
		TTL:         defaultPacketTTL,
		Protocol:    uint8(header.ICMPv4ProtocolNumber),
		SrcAddr:     packetInfo.Destination,
		DstAddr:     packetInfo.SourceIP,
	})

	icmpHeader := header.ICMPv4(ipHeader.Payload())
	icmpHeader.SetType(header.ICMPv4TimeExceeded)
	icmpHeader.SetCode(header.ICMPv4TTLExceeded)
	copy(packet[header.IPv4MinimumSize+header.ICMPv4MinimumSize:], packetInfo.RawPacket[:quotedLength])
	icmpHeader.SetChecksum(header.ICMPv4Checksum(icmpHeader, 0))
	ipHeader.SetChecksum(^ipHeader.CalculateChecksum())

	return packet, nil
}

func buildIPv6TTLExceededPacket(packetInfo PacketInfo) ([]byte, error) {
	if !packetInfo.SourceIP.Is6() || !packetInfo.Destination.Is6() {
		return nil, E.New("TTL exceeded packet requires IPv6 addresses")
	}
	quotedLength := min(len(packetInfo.RawPacket), IPv6TTLExceededQuoteLen)
	packet := make([]byte, header.IPv6MinimumSize+header.ICMPv6MinimumSize+quotedLength)

	ipHeader := header.IPv6(packet)
	ipHeader.Encode(&header.IPv6Fields{
		PayloadLength:     uint16(header.ICMPv6MinimumSize + quotedLength),
		TransportProtocol: header.ICMPv6ProtocolNumber,
		HopLimit:          defaultPacketTTL,
		SrcAddr:           packetInfo.Destination,
		DstAddr:           packetInfo.SourceIP,
	})

	icmpHeader := header.ICMPv6(ipHeader.Payload())
	icmpHeader.SetType(header.ICMPv6TimeExceeded)
	icmpHeader.SetCode(header.ICMPv6HopLimitExceeded)
	copy(packet[header.IPv6MinimumSize+header.ICMPv6MinimumSize:], packetInfo.RawPacket[:quotedLength])
	icmpHeader.SetChecksum(header.ICMPv6Checksum(header.ICMPv6ChecksumParams{
		Header: icmpHeader,
		Src:    packetInfo.Destination.AsSlice(),
		Dst:    packetInfo.SourceIP.AsSlice(),
	}))

	return packet, nil
}

func EncodeDatagram(packet []byte, WireVersion WireVersion, traceContext TraceContext) ([]byte, error) {
	switch WireVersion {
	case WireV2:
		return encodeV2Datagram(packet, traceContext)
	case WireV3:
		return EncodeV3Datagram(packet)
	default:
		return nil, E.New("unsupported icmp wire version: ", WireVersion)
	}
}

func encodeV2Datagram(packet []byte, _ TraceContext) ([]byte, error) {
	data := make([]byte, 0, len(packet)+1)
	data = append(data, packet...)
	data = append(data, byte(protocol.DatagramV2TypeIP))
	return data, nil
}

func EncodeV3Datagram(packet []byte) ([]byte, error) {
	if len(packet) == 0 {
		return nil, E.New("icmp payload is missing")
	}
	if len(packet) > MaxPayloadLen {
		return nil, E.New("icmp payload is too large")
	}
	data := make([]byte, 0, len(packet)+1)
	data = append(data, byte(protocol.DatagramV3TypeICMP))
	data = append(data, packet...)
	return data, nil
}
