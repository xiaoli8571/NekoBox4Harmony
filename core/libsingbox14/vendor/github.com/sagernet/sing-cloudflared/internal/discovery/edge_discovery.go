package discovery

import (
	"context"
	"crypto/tls"
	"net"
	"net/netip"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type Resolver interface {
	LookupSRV(ctx context.Context, service, proto, name string) ([]*net.SRV, error)
	LookupNetIP(ctx context.Context, host string) ([]netip.Addr, error)
}

const (
	EdgeSRVService = "v2-origintunneld"
	edgeSRVProto   = "tcp"
	edgeSRVName    = "argotunnel.com"

	DotServerName = "cloudflare-dns.com"
	DotServerAddr = "1.1.1.1:853"
	dotTimeout    = 15 * time.Second
)

var (
	LookupEdgeSRVFn        = lookupEdgeSRV
	LookupEdgeSRVWithDoTFn = lookupEdgeSRVWithDoT
	EdgeLookupSRV          = net.LookupSRV
	EdgeLookupIP           = net.LookupIP
	EdgeDoTDestination     = M.ParseSocksaddr(DotServerAddr)
	EdgeDoTTLSClient       = func(conn net.Conn) net.Conn {
		return tls.Client(conn, &tls.Config{ServerName: DotServerName})
	}
)

func GetRegionalServiceName(region string) string {
	if region == "" {
		return EdgeSRVService
	}
	return region + "-" + EdgeSRVService
}

type EdgeAddr struct {
	TCP       *net.TCPAddr
	UDP       *net.UDPAddr
	IPVersion int // 4 or 6
}

func DiscoverEdge(ctx context.Context, region string, controlDialer N.Dialer, controlResolver Resolver, tunnelResolver Resolver) ([][]*EdgeAddr, error) {
	var (
		regions [][]*EdgeAddr
		err     error
	)
	if controlResolver != nil {
		var records []*net.SRV
		records, err = controlResolver.LookupSRV(ctx, GetRegionalServiceName(region), edgeSRVProto, edgeSRVName)
		if err != nil {
			return nil, E.Cause(err, "edge discovery: lookup SRV records")
		}
		if tunnelResolver != nil {
			regions, err = resolveSRVRecordsWithResolver(ctx, records, tunnelResolver)
		} else {
			regions, err = ResolveSRVRecords(records)
		}
		if err != nil {
			return nil, E.Cause(err, "edge discovery")
		}
	} else {
		regions, err = LookupEdgeSRVFn(region)
		if err != nil {
			regions, err = LookupEdgeSRVWithDoTFn(ctx, region, controlDialer)
			if err != nil {
				return nil, E.Cause(err, "edge discovery")
			}
		}
	}
	if len(regions) == 0 {
		return nil, E.New("edge discovery: no edge addresses found")
	}
	return regions, nil
}

func lookupEdgeSRV(region string) ([][]*EdgeAddr, error) {
	_, addrs, err := EdgeLookupSRV(GetRegionalServiceName(region), edgeSRVProto, edgeSRVName)
	if err != nil {
		return nil, err
	}
	return ResolveSRVRecords(addrs)
}

func lookupEdgeSRVWithDoT(ctx context.Context, region string, controlDialer N.Dialer) ([][]*EdgeAddr, error) {
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			conn, err := controlDialer.DialContext(ctx, "tcp", EdgeDoTDestination)
			if err != nil {
				return nil, err
			}
			return EdgeDoTTLSClient(conn), nil
		},
	}
	lookupCtx, cancel := context.WithTimeout(ctx, dotTimeout)
	defer cancel()
	_, addrs, err := resolver.LookupSRV(lookupCtx, GetRegionalServiceName(region), edgeSRVProto, edgeSRVName)
	if err != nil {
		return nil, err
	}
	return ResolveSRVRecords(addrs)
}

func ResolveSRVRecords(records []*net.SRV) ([][]*EdgeAddr, error) {
	var regions [][]*EdgeAddr
	for _, record := range records {
		ips, err := EdgeLookupIP(record.Target)
		if err != nil {
			return nil, E.Cause(err, "resolve SRV target: ", record.Target)
		}
		if len(ips) == 0 {
			continue
		}
		regions = append(regions, buildEdgeAddrs(ips, record.Port))
	}
	return regions, nil
}

func resolveSRVRecordsWithResolver(ctx context.Context, records []*net.SRV, tunnelResolver Resolver) ([][]*EdgeAddr, error) {
	var regions [][]*EdgeAddr
	for _, record := range records {
		addresses, err := tunnelResolver.LookupNetIP(ctx, record.Target)
		if err != nil {
			return nil, E.Cause(err, "resolve SRV target: ", record.Target)
		}
		if len(addresses) == 0 {
			continue
		}
		ips := make([]net.IP, 0, len(addresses))
		for _, address := range addresses {
			ips = append(ips, net.IP(address.AsSlice()))
		}
		regions = append(regions, buildEdgeAddrs(ips, record.Port))
	}
	return regions, nil
}

func buildEdgeAddrs(ips []net.IP, port uint16) []*EdgeAddr {
	edgeAddrs := make([]*EdgeAddr, 0, len(ips))
	for _, ip := range ips {
		ipVersion := 6
		if ip.To4() != nil {
			ipVersion = 4
		}
		edgeAddrs = append(edgeAddrs, &EdgeAddr{
			TCP:       &net.TCPAddr{IP: ip, Port: int(port)},
			UDP:       &net.UDPAddr{IP: ip, Port: int(port)},
			IPVersion: ipVersion,
		})
	}
	return edgeAddrs
}

func FilterByIPVersion(regions [][]*EdgeAddr, version int) [][]*EdgeAddr {
	if version == 0 {
		return regions
	}
	var filtered [][]*EdgeAddr
	for _, region := range regions {
		var addrs []*EdgeAddr
		for _, addr := range region {
			if addr.IPVersion == version {
				addrs = append(addrs, addr)
			}
		}
		if len(addrs) > 0 {
			filtered = append(filtered, addrs)
		}
	}
	return filtered
}
