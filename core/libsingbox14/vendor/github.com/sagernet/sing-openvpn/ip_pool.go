package openvpn

import (
	"net/netip"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	ipv4TopologySubnet = "subnet"
	ipv4TopologyP2P    = "p2p"
	ipv4TopologyNet30  = "net30"
	ipPoolMaximumSize  = 65536
)

type ipv4PoolLease struct {
	Client netip.Addr
	Peer   netip.Addr
}

type ipPool struct {
	access       sync.Mutex
	ipv4Prefix   netip.Prefix
	ipv4Topology string
	ipv4Server   netip.Addr
	ipv4Start    netip.Addr
	ipv4End      netip.Addr
	ipv4UsedSet  map[netip.Addr]struct{}
	ipv4Identity map[netip.Addr]string
	ipv4Address  map[string]netip.Addr
	ipv4Released map[netip.Addr]time.Time
	ipv6Prefix   netip.Prefix
	ipv6Server   netip.Addr
	ipv6UsedSet  map[netip.Addr]struct{}
	ipv6Identity map[netip.Addr]string
	ipv6Address  map[string]netip.Addr
	ipv6Released map[netip.Addr]time.Time
}

func newIPPool(addressPools []netip.Prefix, topology string) (*ipPool, error) {
	resolvedTopology, err := resolveIPv4PoolTopology(topology)
	if err != nil {
		return nil, err
	}
	pool := &ipPool{
		ipv4Topology: resolvedTopology,
		ipv4UsedSet:  make(map[netip.Addr]struct{}),
		ipv4Identity: make(map[netip.Addr]string),
		ipv4Address:  make(map[string]netip.Addr),
		ipv4Released: make(map[netip.Addr]time.Time),
		ipv6UsedSet:  make(map[netip.Addr]struct{}),
		ipv6Identity: make(map[netip.Addr]string),
		ipv6Address:  make(map[string]netip.Addr),
		ipv6Released: make(map[netip.Addr]time.Time),
	}
	for _, prefix := range addressPools {
		if !prefix.IsValid() {
			continue
		}
		prefix = prefix.Masked()
		if !prefix.Addr().Is4() || pool.ipv4Prefix.IsValid() {
			continue
		}
		err = pool.configureIPv4(prefix)
		if err != nil {
			return nil, err
		}
	}
	for _, prefix := range addressPools {
		if !prefix.IsValid() {
			continue
		}
		prefix = prefix.Masked()
		if !prefix.Addr().Is6() || pool.ipv6Prefix.IsValid() {
			continue
		}
		pool.ipv6Prefix = prefix
		pool.ipv6Server = prefix.Masked().Addr().Next()
		pool.ipv6UsedSet[pool.ipv6Server] = struct{}{}
	}
	return pool, nil
}

func resolveIPv4PoolTopology(topology string) (string, error) {
	if topology == "" {
		return ipv4TopologyNet30, nil
	}
	switch topology {
	case ipv4TopologySubnet, ipv4TopologyP2P, ipv4TopologyNet30:
		return topology, nil
	default:
		return "", E.New("unsupported IPv4 topology: ", topology)
	}
}

func (p *ipPool) configureIPv4(prefix netip.Prefix) error {
	// OpenVPN's --server helper accepts at most 65536 addresses and requires
	// enough room for its server endpoints plus a client pool.
	if prefix.Bits() < 16 || prefix.Bits() > 29 {
		return E.New("IPv4 address pool must be between /16 and /29: ", prefix)
	}
	network := prefix.Masked().Addr()
	broadcast := lastIPv4InPrefix(prefix)
	p.ipv4Prefix = prefix
	p.ipv4Server = prefix.Masked().Addr().Next()
	switch p.ipv4Topology {
	case ipv4TopologySubnet:
		p.ipv4Start = addIPv4(network, 2)
		p.ipv4End = addIPv4(broadcast, -1)
	case ipv4TopologyP2P, ipv4TopologyNet30:
		// This mirrors helper.c: the first /30 is reserved for the server
		// interface.  OpenVPN also reserves the last four addresses except for
		// the smallest accepted (/29) network.
		p.ipv4Start = addIPv4(network, 4)
		poolEndReserve := int64(4)
		if prefix.Bits() == 29 {
			poolEndReserve = 0
		}
		p.ipv4End = addIPv4(broadcast, -poolEndReserve)
	}
	if !p.ipv4Start.IsValid() || !p.ipv4End.IsValid() || p.ipv4Start.Compare(p.ipv4End) > 0 {
		return E.New("IPv4 address pool has no allocatable addresses: ", prefix)
	}
	return nil
}

func (p *ipPool) HasIPv4() bool {
	return p.ipv4Prefix.IsValid()
}

func (p *ipPool) HasIPv6() bool {
	return p.ipv6Prefix.IsValid()
}

func (p *ipPool) ServerIPv4() netip.Addr {
	return p.ipv4Server
}

func (p *ipPool) ServerIPv6() netip.Addr {
	return p.ipv6Server
}

func (p *ipPool) SetServerIPv4(address netip.Addr) error {
	if !address.IsValid() {
		return nil
	}
	if !address.Is4() || !p.ipv4Prefix.Contains(address) {
		return E.New("server IPv4 address ", address, " is outside pool ", p.ipv4Prefix)
	}
	if address == p.ipv4Prefix.Masked().Addr() || address == lastIPv4InPrefix(p.ipv4Prefix) {
		return E.New("server IPv4 address ", address, " is not a usable host in pool ", p.ipv4Prefix)
	}
	p.access.Lock()
	defer p.access.Unlock()
	if len(p.ipv4UsedSet) > 0 {
		return E.New("cannot change server IPv4 address after allocating client addresses")
	}
	p.ipv4Server = address
	return nil
}

func (p *ipPool) SetServerIPv6(address netip.Addr) error {
	if !address.IsValid() {
		return nil
	}
	if !address.Is6() || !p.ipv6Prefix.Contains(address) {
		return E.New("server IPv6 address ", address, " is outside pool ", p.ipv6Prefix)
	}
	p.access.Lock()
	defer p.access.Unlock()
	delete(p.ipv6UsedSet, p.ipv6Server)
	p.ipv6Server = address
	p.ipv6UsedSet[address] = struct{}{}
	return nil
}

func (p *ipPool) IPv4Prefix() netip.Prefix {
	return p.ipv4Prefix
}

func (p *ipPool) IPv4Topology() string {
	return p.ipv4Topology
}

func (p *ipPool) IPv6Prefix() netip.Prefix {
	return p.ipv6Prefix
}

func (p *ipPool) AllocateIPv4() (ipv4PoolLease, error) {
	return p.AllocateIPv4ForIdentity("")
}

func (p *ipPool) AllocateIPv4ForIdentity(identity string) (ipv4PoolLease, error) {
	if !p.HasIPv4() {
		return ipv4PoolLease{}, E.New("ipv4 pool not configured")
	}
	p.access.Lock()
	defer p.access.Unlock()
	if identity != "" {
		if previous, found := p.findAvailableIPv4Lease(identity, true); found {
			p.commitIPv4Lease(previous, identity)
			return previous, nil
		}
	}
	lease, found := p.findAvailableIPv4Lease(identity, false)
	if found {
		p.commitIPv4Lease(lease, identity)
		return lease, nil
	}
	return ipv4PoolLease{}, ErrIPPoolExhausted
}

func (p *ipPool) AllocateIPv6() (netip.Addr, error) {
	return p.AllocateIPv6ForIdentity("")
}

func (p *ipPool) AllocateIPv6ForIdentity(identity string) (netip.Addr, error) {
	if !p.HasIPv6() {
		return netip.Addr{}, E.New("ipv6 pool not configured")
	}
	p.access.Lock()
	defer p.access.Unlock()
	if identity != "" {
		if previous, found := p.findAvailableIPv6Address(identity, true); found {
			p.commitIPv6Address(previous, identity)
			return previous, nil
		}
	}
	address, found := p.findAvailableIPv6Address(identity, false)
	if found {
		p.commitIPv6Address(address, identity)
		return address, nil
	}
	return netip.Addr{}, ErrIPPoolExhausted
}

func (p *ipPool) Release(address netip.Addr) {
	if !address.IsValid() {
		return
	}
	p.access.Lock()
	defer p.access.Unlock()
	if address.Is4() {
		delete(p.ipv4UsedSet, address)
		if p.ipv4Identity[address] != "" {
			p.ipv4Released[address] = time.Now()
		} else {
			delete(p.ipv4Released, address)
		}
		return
	}
	delete(p.ipv6UsedSet, address)
	if p.ipv6Identity[address] != "" {
		p.ipv6Released[address] = time.Now()
	} else {
		delete(p.ipv6Released, address)
	}
}

func (p *ipPool) visitIPv4Leases(visitor func(ipv4PoolLease) bool) {
	switch p.ipv4Topology {
	case ipv4TopologySubnet, ipv4TopologyP2P:
		for client := p.ipv4Start; client.IsValid() && client.Compare(p.ipv4End) <= 0; client = client.Next() {
			if client == p.ipv4Server {
				continue
			}
			lease := ipv4PoolLease{Client: client}
			if p.ipv4Topology == ipv4TopologyP2P {
				lease.Peer = p.ipv4Server
			}
			if !visitor(lease) {
				return
			}
		}
	case ipv4TopologyNet30:
		for block := p.ipv4Start; block.IsValid() && block.Compare(p.ipv4End) <= 0; block = addIPv4(block, 4) {
			peer := addIPv4(block, 1)
			client := addIPv4(block, 2)
			if !peer.IsValid() || !client.IsValid() || client.Compare(p.ipv4End) > 0 {
				return
			}
			if peer == p.ipv4Server || client == p.ipv4Server {
				continue
			}
			if !visitor(ipv4PoolLease{Client: client, Peer: peer}) {
				return
			}
		}
	}
}

func (p *ipPool) findAvailableIPv4Lease(identity string, requireIdentity bool) (ipv4PoolLease, bool) {
	if requireIdentity {
		previous := p.ipv4Address[identity]
		if !previous.IsValid() {
			return ipv4PoolLease{}, false
		}
		if _, used := p.ipv4UsedSet[previous]; used {
			return ipv4PoolLease{}, false
		}
		return p.ipv4Lease(previous), true
	}
	var selected ipv4PoolLease
	var selectedRelease time.Time
	p.visitIPv4Leases(func(candidate ipv4PoolLease) bool {
		if _, used := p.ipv4UsedSet[candidate.Client]; used {
			return true
		}
		if identity == "" {
			selected = candidate
			return false
		}
		released := p.ipv4Released[candidate.Client]
		if !selected.Client.IsValid() || released.Before(selectedRelease) {
			selected = candidate
			selectedRelease = released
		}
		if released.IsZero() {
			return false
		}
		return true
	})
	return selected, selected.Client.IsValid()
}

func (p *ipPool) ipv4Lease(address netip.Addr) ipv4PoolLease {
	lease := ipv4PoolLease{Client: address}
	switch p.ipv4Topology {
	case ipv4TopologyP2P:
		lease.Peer = p.ipv4Server
	case ipv4TopologyNet30:
		lease.Peer = address.Prev()
	}
	return lease
}

func (p *ipPool) commitIPv4Lease(lease ipv4PoolLease, identity string) {
	p.ipv4UsedSet[lease.Client] = struct{}{}
	delete(p.ipv4Released, lease.Client)
	previousIdentity := p.ipv4Identity[lease.Client]
	if previousIdentity != "" && previousIdentity != identity && p.ipv4Address[previousIdentity] == lease.Client {
		delete(p.ipv4Address, previousIdentity)
	}
	if identity != "" {
		if previousAddress := p.ipv4Address[identity]; previousAddress.IsValid() && previousAddress != lease.Client {
			delete(p.ipv4Identity, previousAddress)
			delete(p.ipv4Released, previousAddress)
		}
		p.ipv4Identity[lease.Client] = identity
		p.ipv4Address[identity] = lease.Client
	} else {
		delete(p.ipv4Identity, lease.Client)
	}
}

func (p *ipPool) findAvailableIPv6Address(identity string, requireIdentity bool) (netip.Addr, bool) {
	if requireIdentity {
		previous := p.ipv6Address[identity]
		if !previous.IsValid() || !p.ipv6Prefix.Contains(previous) || previous == p.ipv6Server {
			return netip.Addr{}, false
		}
		_, used := p.ipv6UsedSet[previous]
		return previous, !used
	}
	var selected netip.Addr
	var selectedRelease time.Time
	visited := 0
	for current := p.ipv6Prefix.Addr().Next(); current.IsValid() && p.ipv6Prefix.Contains(current) && visited < ipPoolMaximumSize; current = current.Next() {
		if current == p.ipv6Server {
			continue
		}
		visited++
		if _, used := p.ipv6UsedSet[current]; used {
			continue
		}
		if identity == "" {
			return current, true
		}
		if p.ipv6Identity[current] == "" && len(p.ipv6Address) >= ipPoolMaximumSize {
			continue
		}
		released := p.ipv6Released[current]
		if !selected.IsValid() || released.Before(selectedRelease) {
			selected = current
			selectedRelease = released
		}
		if released.IsZero() {
			break
		}
	}
	return selected, selected.IsValid()
}

func (p *ipPool) commitIPv6Address(address netip.Addr, identity string) {
	p.ipv6UsedSet[address] = struct{}{}
	delete(p.ipv6Released, address)
	previousIdentity := p.ipv6Identity[address]
	if previousIdentity != "" && previousIdentity != identity && p.ipv6Address[previousIdentity] == address {
		delete(p.ipv6Address, previousIdentity)
	}
	if identity != "" {
		if previousAddress := p.ipv6Address[identity]; previousAddress.IsValid() && previousAddress != address {
			delete(p.ipv6Identity, previousAddress)
			delete(p.ipv6Released, previousAddress)
		}
		p.ipv6Identity[address] = identity
		p.ipv6Address[identity] = address
	} else {
		delete(p.ipv6Identity, address)
	}
}

func lastIPv4InPrefix(prefix netip.Prefix) netip.Addr {
	maskedAddress := prefix.Masked().Addr().As4()
	hostBits := 32 - prefix.Bits()
	if hostBits <= 0 {
		return prefix.Addr()
	}
	last := uint32(maskedAddress[0])<<24 | uint32(maskedAddress[1])<<16 | uint32(maskedAddress[2])<<8 | uint32(maskedAddress[3])
	last |= (uint32(1) << hostBits) - 1
	var lastBytes [4]byte
	lastBytes[0] = byte(last >> 24)
	lastBytes[1] = byte(last >> 16)
	lastBytes[2] = byte(last >> 8)
	lastBytes[3] = byte(last)
	return netip.AddrFrom4(lastBytes)
}

func addIPv4(address netip.Addr, offset int64) netip.Addr {
	if !address.Is4() {
		return netip.Addr{}
	}
	bytes := address.As4()
	value := int64(uint32(bytes[0])<<24 | uint32(bytes[1])<<16 | uint32(bytes[2])<<8 | uint32(bytes[3]))
	value += offset
	if value < 0 || value > int64(^uint32(0)) {
		return netip.Addr{}
	}
	result := uint32(value)
	return netip.AddrFrom4([4]byte{byte(result >> 24), byte(result >> 16), byte(result >> 8), byte(result)})
}
