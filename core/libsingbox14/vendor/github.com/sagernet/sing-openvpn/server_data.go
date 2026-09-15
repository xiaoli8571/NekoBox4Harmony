package openvpn

import (
	"bytes"
	"context"
	"net/netip"

	"github.com/sagernet/sing/common/buf"
)

type ServerDataPacket struct {
	PeerAddress string
	Payload     []byte
}

type ServerDataBuffer struct {
	PeerAddress string
	Buffer      *buf.Buffer
}

type RouteMissError struct {
	Destination netip.Addr
	Packet      []byte
}

func (e *RouteMissError) Error() string {
	if e == nil || !e.Destination.IsValid() {
		return ErrRouteNotFound.Error()
	}
	return ErrRouteNotFound.Error() + ": " + e.Destination.String()
}

func (e *RouteMissError) Unwrap() error {
	return ErrRouteNotFound
}

func (s *Server) DroppedIncomingDataPackets() uint64 {
	return s.droppedIncomingDataPackets.Load()
}

func (s *Server) ReadDataPacket(ctx context.Context) (ServerDataPacket, error) {
	packetBuffer, err := s.ReadDataPacketBuffer(ctx)
	if err != nil {
		return ServerDataPacket{}, err
	}
	payload := append([]byte(nil), packetBuffer.Buffer.Bytes()...)
	packetBuffer.Buffer.Release()
	return ServerDataPacket{
		PeerAddress: packetBuffer.PeerAddress,
		Payload:     payload,
	}, nil
}

func (s *Server) ReadDataPackets(ctx context.Context) ([]ServerDataBuffer, error) {
	return s.readDataPackets(ctx, 0)
}

func (s *Server) ReadDataPacketBuffer(ctx context.Context) (ServerDataBuffer, error) {
	packetBuffers, err := s.readDataPackets(ctx, 1)
	if err != nil {
		return ServerDataBuffer{}, err
	}
	return packetBuffers[0], nil
}

func (s *Server) readDataPackets(ctx context.Context, maxPackets int) ([]ServerDataBuffer, error) {
	loopContext, err := s.activeLoopContext()
	if err != nil {
		return nil, err
	}
	for {
		select {
		case <-loopContext.Done():
			return nil, ErrServerClosed
		default:
		}
		packetBuffers := s.incomingDataPackets.Pop(maxPackets, nil)
		if len(packetBuffers) > 0 {
			return packetBuffers, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-loopContext.Done():
			return nil, ErrServerClosed
		case <-s.incomingDataPackets.Wake():
		}
	}
}

func (s *Server) WriteDataPacket(peerAddress string, packet []byte) error {
	return s.WriteDataPackets(peerAddress, [][]byte{packet})
}

func (s *Server) WriteDataPackets(peerAddress string, packets [][]byte) error {
	if len(packets) == 0 {
		return nil
	}
	err := s.requireRunning()
	if err != nil {
		return err
	}
	return s.writeDataPackets(peerAddress, packets)
}

func (s *Server) writeDataPackets(peerAddress string, packets [][]byte) error {
	if s.static != nil {
		return s.static.WriteDataPackets(peerAddress, packets)
	}
	return s.tls.WriteDataPackets(peerAddress, packets)
}

func (s *Server) writeDataPacketBuffers(peerAddress string, packetBuffers []*buf.Buffer) error {
	if s.static != nil {
		return s.static.WriteDataPacketBuffers(peerAddress, packetBuffers)
	}
	return s.tls.WriteDataPacketBuffers(peerAddress, packetBuffers)
}

func (s *Server) WriteDataPacketByDestination(packet []byte) error {
	routeMisses, err := s.WriteDataPacketsByDestination([][]byte{packet})
	if err != nil {
		return err
	}
	if len(routeMisses) > 0 {
		return routeMisses[0]
	}
	return nil
}

func (s *Server) WriteDataPacketsByDestination(packets [][]byte) ([]*RouteMissError, error) {
	if len(packets) == 0 {
		return nil, nil
	}
	err := s.requireRunning()
	if err != nil {
		return nil, err
	}
	var routeMisses []*RouteMissError
	routeLookups := s.routes.LookupPackets(packets)
	var currentRoute peerRoute
	currentPackets := make([][]byte, 0, len(packets))
	flushCurrentBatch := func() error {
		if len(currentPackets) == 0 {
			return nil
		}
		var writeErr error
		if currentRoute.session != nil {
			writeErr = currentRoute.session.WriteDataPackets(currentPackets)
		} else {
			writeErr = s.writeDataPackets(currentRoute.peerAddress, currentPackets)
		}
		currentPackets = currentPackets[:0]
		return writeErr
	}
	for i, packet := range packets {
		route := routeLookups[i].route
		if !routeLookups[i].found {
			err = flushCurrentBatch()
			if err != nil {
				return routeMisses, err
			}
			packetRouteErr := newRouteMissError(routeLookups[i].destination, packet)
			routeMiss, isRouteMiss := packetRouteErr.(*RouteMissError)
			if !isRouteMiss {
				return routeMisses, packetRouteErr
			}
			routeMisses = append(routeMisses, routeMiss)
			continue
		}
		if len(currentPackets) > 0 && route != currentRoute {
			err = flushCurrentBatch()
			if err != nil {
				return routeMisses, err
			}
		}
		if len(currentPackets) == 0 {
			currentRoute = route
		}
		currentPackets = append(currentPackets, packet)
	}
	err = flushCurrentBatch()
	return routeMisses, err
}

func (s *Server) WriteDataPacketBuffersByDestination(packetBuffers []*buf.Buffer) ([]*RouteMissError, error) {
	if len(packetBuffers) == 0 {
		return nil, nil
	}
	err := s.requireRunning()
	if err != nil {
		buf.ReleaseMulti(packetBuffers)
		return nil, err
	}
	packets := make([][]byte, len(packetBuffers))
	for i, packetBuffer := range packetBuffers {
		packets[i] = packetBuffer.Bytes()
	}
	var routeMisses []*RouteMissError
	routeLookups := s.routes.LookupPackets(packets)
	var currentRoute peerRoute
	currentPacketBuffers := make([]*buf.Buffer, 0, len(packetBuffers))
	flushCurrentBatch := func() error {
		if len(currentPacketBuffers) == 0 {
			return nil
		}
		var writeErr error
		if currentRoute.session != nil {
			writeErr = currentRoute.session.WriteDataPacketBuffers(currentPacketBuffers)
		} else {
			writeErr = s.writeDataPacketBuffers(currentRoute.peerAddress, currentPacketBuffers)
		}
		currentPacketBuffers = nil
		return writeErr
	}
	for i, packetBuffer := range packetBuffers {
		route := routeLookups[i].route
		if !routeLookups[i].found {
			err = flushCurrentBatch()
			if err != nil {
				packetBuffer.Release()
				buf.ReleaseMulti(packetBuffers[i+1:])
				return routeMisses, err
			}
			packetRouteErr := newRouteMissError(routeLookups[i].destination, packetBuffer.Bytes())
			packetBuffer.Release()
			routeMiss, isRouteMiss := packetRouteErr.(*RouteMissError)
			if !isRouteMiss {
				buf.ReleaseMulti(packetBuffers[i+1:])
				return routeMisses, packetRouteErr
			}
			routeMisses = append(routeMisses, routeMiss)
			continue
		}
		if len(currentPacketBuffers) > 0 && route != currentRoute {
			err = flushCurrentBatch()
			if err != nil {
				packetBuffer.Release()
				buf.ReleaseMulti(packetBuffers[i+1:])
				return routeMisses, err
			}
		}
		if len(currentPacketBuffers) == 0 {
			currentRoute = route
		}
		currentPacketBuffers = append(currentPacketBuffers, packetBuffer)
	}
	err = flushCurrentBatch()
	return routeMisses, err
}

func newRouteMissError(destination netip.Addr, packet []byte) error {
	if !destination.IsValid() {
		return ErrInvalidIPPacket
	}
	return &RouteMissError{
		Destination: destination,
		Packet:      bytes.Clone(packet),
	}
}

func (s *Server) pushIncomingDataPackets(packets []ServerDataPacket) {
	if len(packets) == 0 {
		return
	}
	packetBuffers := make([]ServerDataBuffer, 0, len(packets))
	for _, packet := range packets {
		if packet.PeerAddress == "" || len(packet.Payload) == 0 {
			continue
		}
		packetBuffers = append(packetBuffers, ServerDataBuffer{
			PeerAddress: packet.PeerAddress,
			Buffer:      newDataPacketBuffer(s.options.DataChannel.PacketHeadroom, packet.Payload),
		})
	}
	dropped := s.incomingDataPackets.PushBatch(packetBuffers, func(packetBuffer ServerDataBuffer) {
		if packetBuffer.Buffer != nil {
			packetBuffer.Buffer.Release()
		}
	})
	if dropped > 0 {
		s.droppedIncomingDataPackets.Add(dropped)
	}
}

func (s *Server) pushIncomingDataBuffers(packetBuffers []ServerDataBuffer) {
	if len(packetBuffers) == 0 {
		return
	}
	dropped := s.incomingDataPackets.PushBatch(packetBuffers, func(packetBuffer ServerDataBuffer) {
		if packetBuffer.Buffer != nil {
			packetBuffer.Buffer.Release()
		}
	})
	if dropped > 0 {
		s.droppedIncomingDataPackets.Add(dropped)
	}
}

func (s *Server) prepareServerDataPlane() error {
	if s.static != nil {
		return nil
	}
	pool, err := newIPPool(s.options.Tunnel.AddressPools, s.options.Tunnel.Topology)
	if err != nil {
		return err
	}
	if !pool.HasIPv4() && !pool.HasIPv6() {
		return nil
	}
	if pool.HasIPv4() {
		ipv4Prefix, ipv4PrefixLoaded := firstPrefixByFamily(s.options.Tunnel.LocalAddress, true)
		if ipv4PrefixLoaded {
			err = pool.SetServerIPv4(ipv4Prefix.Addr())
			if err != nil {
				return err
			}
		}
	}
	if pool.HasIPv6() {
		ipv6Prefix, ipv6PrefixLoaded := firstPrefixByFamily(s.options.Tunnel.LocalAddress, false)
		if ipv6PrefixLoaded {
			err = pool.SetServerIPv6(ipv6Prefix.Addr())
			if err != nil {
				return err
			}
		}
	}
	s.ipPool = pool
	return nil
}

func firstPrefixByFamily(prefixes []netip.Prefix, ipv4 bool) (netip.Prefix, bool) {
	for _, prefix := range prefixes {
		if !prefix.IsValid() {
			continue
		}
		if prefix.Addr().Is4() == ipv4 {
			return prefix, true
		}
	}
	return netip.Prefix{}, false
}

func (s *tlsServerSession) outgoingDataPayloads(payloads [][]byte, codec dataCodec, packetHeaderSize int) [][][]byte {
	parent := s.server.parent
	dataChannelOptions := parent.options.DataChannel
	clamp := calculateMSSClamp(
		dataChannelOptions.MSSFix,
		dataChannelOptions.MSSFixMode,
		nil,
		codec,
		packetHeaderSize,
		openVPNOuterTransportOverhead(parent.protocol, s.packetConnection.RemoteAddr()),
	)
	outgoingPayloads := make([][][]byte, len(payloads))
	for i, payload := range payloads {
		outgoingPayloads[i] = [][]byte{append([]byte{}, clamp.Apply(payload)...)}
	}
	return outgoingPayloads
}

func (s *tlsServerSession) outgoingDataBuffers(payloads []*buf.Buffer, codec dataCodec, packetHeaderSize int) [][]*buf.Buffer {
	parent := s.server.parent
	dataChannelOptions := parent.options.DataChannel
	clamp := calculateMSSClamp(
		dataChannelOptions.MSSFix,
		dataChannelOptions.MSSFixMode,
		nil,
		codec,
		packetHeaderSize,
		openVPNOuterTransportOverhead(parent.protocol, s.packetConnection.RemoteAddr()),
	)
	outgoingPayloads := make([][]*buf.Buffer, len(payloads))
	for i, payload := range payloads {
		clamp.ApplyInPlace(payload.Bytes())
		outgoingPayloads[i] = []*buf.Buffer{payload}
	}
	return outgoingPayloads
}

// multi.c matches a peer's source address against the virtual addresses
// multi_client_connect_late_setup() learned from --ifconfig-pool.  A server that
// hands out no address has no such table to match against: upstream runs that
// configuration as a point-to-point --tls-server, which writes every decrypted
// payload to the tun device whatever its source.
func (s *tlsServerSession) acceptIncomingSources(payloads [][]byte) []bool {
	parent := s.server.parent
	accepted := make([]bool, len(payloads))
	if parent.ipPool == nil {
		for i := range accepted {
			accepted[i] = true
		}
		return accepted
	}
	ownerships := parent.routes.SourcesOwnedBy(payloads, s.tlsPeerSession)
	for i, ownership := range ownerships {
		accepted[i] = ownership.owned
		if ownership.owned {
			continue
		}
		if ownership.sourceAddress.IsValid() {
			parent.incomingPacketDropLog.LogMessage("bad source address from client ", s.peerAddress, " [", ownership.sourceAddress, "]")
		} else {
			parent.incomingPacketDropLog.LogMessage("malformed IP packet from client ", s.peerAddress)
		}
	}
	return accepted
}

func (s *tlsServerSession) deliverIncomingPayloads(payloads [][]byte, codec dataCodec, packetHeaderSize int) {
	parent := s.server.parent
	dataChannelOptions := parent.options.DataChannel
	clamp := calculateMSSClamp(
		dataChannelOptions.MSSFix,
		dataChannelOptions.MSSFixMode,
		nil,
		codec,
		packetHeaderSize,
		openVPNOuterTransportOverhead(parent.protocol, s.packetConnection.RemoteAddr()),
	)
	packets := make([]ServerDataPacket, 0, len(payloads))
	accepted := s.acceptIncomingSources(payloads)
	for i, payload := range payloads {
		if !accepted[i] {
			continue
		}
		packets = append(packets, ServerDataPacket{
			PeerAddress: s.peerAddress,
			Payload:     clamp.Apply(payload),
		})
	}
	parent.pushIncomingDataPackets(packets)
}

func (s *tlsServerSession) deliverIncomingBuffers(payloadBuffers []*buf.Buffer, codec dataCodec, packetHeaderSize int) {
	parent := s.server.parent
	dataChannelOptions := parent.options.DataChannel
	clamp := calculateMSSClamp(
		dataChannelOptions.MSSFix,
		dataChannelOptions.MSSFixMode,
		nil,
		codec,
		packetHeaderSize,
		openVPNOuterTransportOverhead(parent.protocol, s.packetConnection.RemoteAddr()),
	)
	payloads := make([][]byte, len(payloadBuffers))
	for i, payloadBuffer := range payloadBuffers {
		payloads[i] = payloadBuffer.Bytes()
	}
	packetBuffers := make([]ServerDataBuffer, 0, len(payloadBuffers))
	accepted := s.acceptIncomingSources(payloads)
	for i, payloadBuffer := range payloadBuffers {
		if !accepted[i] {
			payloadBuffer.Release()
			continue
		}
		clamp.ApplyInPlace(payloadBuffer.Bytes())
		packetBuffers = append(packetBuffers, ServerDataBuffer{
			PeerAddress: s.peerAddress,
			Buffer:      payloadBuffer,
		})
	}
	parent.pushIncomingDataBuffers(packetBuffers)
}
