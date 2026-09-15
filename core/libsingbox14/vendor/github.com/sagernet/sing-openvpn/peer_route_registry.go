package openvpn

import (
	"encoding/binary"
	"net/netip"
	"sync"
)

type peerRoute struct {
	peerAddress string
	session     *tlsPeerSession
}

type peerRouteRegistry struct {
	access sync.RWMutex
	routes map[netip.Addr]peerRoute
}

type peerRouteLookup struct {
	route       peerRoute
	destination netip.Addr
	found       bool
}

type peerSourceOwnership struct {
	sourceAddress netip.Addr
	owned         bool
}

func newPeerRouteRegistry() *peerRouteRegistry {
	return &peerRouteRegistry{
		routes: make(map[netip.Addr]peerRoute),
	}
}

func (r *peerRouteRegistry) Register(address netip.Addr, peerAddress string, session *tlsPeerSession) {
	if !address.IsValid() || peerAddress == "" {
		return
	}
	r.access.Lock()
	defer r.access.Unlock()
	r.routes[address] = peerRoute{
		peerAddress: peerAddress,
		session:     session,
	}
}

func (r *peerRouteRegistry) Unregister(address netip.Addr) {
	if !address.IsValid() {
		return
	}
	r.access.Lock()
	defer r.access.Unlock()
	delete(r.routes, address)
}

func (r *peerRouteRegistry) LookupPackets(ipPackets [][]byte) []peerRouteLookup {
	lookups := make([]peerRouteLookup, len(ipPackets))
	r.access.RLock()
	defer r.access.RUnlock()
	for i, ipPacket := range ipPackets {
		destination, parsed := destinationFromIPPacket(ipPacket)
		if !parsed {
			continue
		}
		lookups[i].destination = destination
		lookups[i].route, lookups[i].found = r.routes[destination]
	}
	return lookups
}

// Upstream OpenVPN 2.x performs this check with
// multi_get_instance_by_virtual_addr() after decrypting a packet.  It currently
// has no ownership-learning model for IPv6 link-local addresses, so reject them
// rather than accepting an address that cannot be associated with a peer.
func (r *peerRouteRegistry) SourcesOwnedBy(ipPackets [][]byte, session *tlsPeerSession) []peerSourceOwnership {
	ownerships := make([]peerSourceOwnership, len(ipPackets))
	for i, ipPacket := range ipPackets {
		sourceAddress, parsed := sourceFromIPPacket(ipPacket)
		ownerships[i].sourceAddress = sourceAddress
		ownerships[i].owned = parsed && session != nil && !(sourceAddress.Is6() && sourceAddress.IsLinkLocalUnicast())
	}
	r.access.RLock()
	defer r.access.RUnlock()
	for i := range ownerships {
		if !ownerships[i].owned {
			continue
		}
		owner, found := r.routes[ownerships[i].sourceAddress]
		ownerships[i].owned = found && owner.session == session
	}
	return ownerships
}

func sourceFromIPPacket(packet []byte) (netip.Addr, bool) {
	if len(packet) == 0 {
		return netip.Addr{}, false
	}
	switch packet[0] >> 4 {
	case 4:
		if len(packet) < 20 {
			return netip.Addr{}, false
		}
		headerLength := int(packet[0]&0x0f) * 4
		if headerLength < 20 || headerLength > len(packet) {
			return netip.Addr{}, false
		}
		totalLength := int(binary.BigEndian.Uint16(packet[2:4]))
		if totalLength < headerLength || totalLength != len(packet) {
			return netip.Addr{}, false
		}
		var sourceAddress [4]byte
		copy(sourceAddress[:], packet[12:16])
		return netip.AddrFrom4(sourceAddress), true
	case 6:
		if len(packet) < 40 {
			return netip.Addr{}, false
		}
		payloadLength := int(binary.BigEndian.Uint16(packet[4:6]))
		if payloadLength != len(packet)-40 {
			return netip.Addr{}, false
		}
		var sourceAddress [16]byte
		copy(sourceAddress[:], packet[8:24])
		return netip.AddrFrom16(sourceAddress), true
	default:
		return netip.Addr{}, false
	}
}

func destinationFromIPPacket(packet []byte) (netip.Addr, bool) {
	if len(packet) == 0 {
		return netip.Addr{}, false
	}
	switch packet[0] >> 4 {
	case 4:
		if len(packet) < 20 {
			return netip.Addr{}, false
		}
		var destAddress [4]byte
		copy(destAddress[:], packet[16:20])
		return netip.AddrFrom4(destAddress), true
	case 6:
		if len(packet) < 40 {
			return netip.Addr{}, false
		}
		var destAddress [16]byte
		copy(destAddress[:], packet[24:40])
		return netip.AddrFrom16(destAddress), true
	}
	return netip.Addr{}, false
}
