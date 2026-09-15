package openvpn

import "net/netip"

func (s *tlsServerSession) allocateAndRegisterTunnelAddress() error {
	parent := s.server.parent
	if parent.ipPool == nil {
		return nil
	}
	stickyIdentity := ""
	if !parent.options.Authentication.DuplicateCN {
		stickyIdentity = s.authenticatedIdentity
	}
	if parent.ipPool.HasIPv4() && !s.ifconfigInet4.IsValid() {
		lease, err := parent.ipPool.AllocateIPv4ForIdentity(stickyIdentity)
		if err != nil {
			return err
		}
		s.ifconfigInet4 = lease.Client
		s.ifconfigPeer4 = lease.Peer
		parent.routes.Register(lease.Client, s.peerAddress, s.tlsPeerSession)
	}
	if parent.ipPool.HasIPv6() && !s.ifconfigInet6.IsValid() {
		address, err := parent.ipPool.AllocateIPv6ForIdentity(stickyIdentity)
		if err != nil {
			return err
		}
		s.ifconfigInet6 = address
		parent.routes.Register(address, s.peerAddress, s.tlsPeerSession)
	}
	return nil
}

func (s *tlsServerSession) releaseTunnelAddress() {
	parent := s.server.parent
	if s.ifconfigInet4.IsValid() {
		parent.routes.Unregister(s.ifconfigInet4)
		parent.ipPool.Release(s.ifconfigInet4)
		s.ifconfigInet4 = netip.Addr{}
		s.ifconfigPeer4 = netip.Addr{}
	}
	if s.ifconfigInet6.IsValid() {
		parent.routes.Unregister(s.ifconfigInet6)
		parent.ipPool.Release(s.ifconfigInet6)
		s.ifconfigInet6 = netip.Addr{}
	}
}

// helper.c expands --server into the pool plus a "topology" push entry, so the
// topology a peer is addressed under always reaches it together with its
// ifconfig; an IPv6-only --server-ipv6 pushes no topology at all.
type serverPushAssignment struct {
	IPv4Topology     string
	ServerIPv4       netip.Addr
	LocalAddressIPv4 pushedLocalAddress
	LocalAddressIPv6 pushedLocalAddress
	PeerID           *uint32
}

func (s *tlsServerSession) pushAssignment() serverPushAssignment {
	assignment := serverPushAssignment{PeerID: s.currentPeerID()}
	pool := s.server.parent.ipPool
	if pool == nil {
		return assignment
	}
	if pool.HasIPv4() && s.ifconfigInet4.IsValid() {
		assignment.IPv4Topology = pool.IPv4Topology()
		assignment.ServerIPv4 = pool.ServerIPv4()
		switch assignment.IPv4Topology {
		case ipv4TopologySubnet:
			assignment.LocalAddressIPv4 = pushedLocalAddress{Prefix: netip.PrefixFrom(s.ifconfigInet4, pool.IPv4Prefix().Bits())}
		case ipv4TopologyP2P:
			assignment.LocalAddressIPv4 = pushedLocalAddress{Prefix: netip.PrefixFrom(s.ifconfigInet4, 32), Peer: s.ifconfigPeer4}
		case ipv4TopologyNet30:
			assignment.LocalAddressIPv4 = pushedLocalAddress{Prefix: netip.PrefixFrom(s.ifconfigInet4, 30), Peer: s.ifconfigPeer4}
		}
	}
	if pool.HasIPv6() && s.ifconfigInet6.IsValid() {
		assignment.LocalAddressIPv6 = pushedLocalAddress{Prefix: netip.PrefixFrom(s.ifconfigInet6, pool.IPv6Prefix().Bits()), Peer: pool.ServerIPv6()}
	}
	return assignment
}
