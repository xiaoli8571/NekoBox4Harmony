package openvpn

import (
	"net/netip"
	"slices"
	"strings"
	"time"
)

type pushedOptions struct {
	kind                  pushOptionsKind
	modernDNS             bool
	modernDNSAddresses    []pushedAddress
	modernSearchDomains   []string
	pullFilterRejection   string
	Topology              string
	TunMTU                uint32
	LocalAddress          []pushedLocalAddress
	RouteGateway          netip.Addr
	RouteGatewayVPN       bool
	RouteGatewayRaw       string
	Routes                []pushedRoute
	DNS                   []pushedAddress
	DNSServers            []TunnelDNSServer
	DHCPOptions           []string
	SearchDomains         []string
	DNSRoutes             []string
	BlockIPv6             bool
	BlockOutsideDNS       bool
	RedirectGateway       bool
	RedirectGatewayFlags  []string
	RedirectPrivate       bool
	RouteMetric           int
	RouteMetricSet        bool
	PingInterval          time.Duration
	PingIntervalEnabled   bool
	PingRestart           time.Duration
	PingRestartEnabled    bool
	AuthToken             string
	AuthTokenUser         string
	PeerID                *uint32
	SelectedCipher        string
	SelectedAuth          string
	ProtocolFlags         []string
	KeyDerivation         string
	ExplicitExitNotify    uint32
	ExplicitExitNotifySet bool
	CompressionDirectives []compressionDirective
	InactiveTimeout       time.Duration
	InactiveMinimumBytes  uint64
	InactiveTimeoutSet    bool
	SessionTimeout        time.Duration
	SessionTimeoutSet     bool
	PingExit              time.Duration
	PingExitSet           bool
	PingTimerRemote       bool
	parseErrors           []pushedOptionParseError
	excludedRoutes        []pushedExcludedRoute
}

type pushedLocalAddress struct {
	Prefix netip.Prefix
	Peer   netip.Addr
	Raw    string
}

type pushedRoute struct {
	Route TunnelRoute
	Raw   string
}

type pushedAddress struct {
	Address    netip.Addr
	Raw        string
	OptionName string
}

func buildInitialTunnelConfiguration(options ClientOptions) TunnelConfiguration {
	localIPv4, localIPv6 := splitLocalAddressPrefixes(options.Tunnel.LocalAddress)
	ipv4Routes, ipv6Routes := splitTunnelRoutes(
		options.Tunnel.Routes,
		options.Tunnel.RouteGateway,
		options.Tunnel.VPNGateway,
		options.Tunnel.VPNGatewayIPv6,
		options.Tunnel.RouteMetric,
	)
	configuration := TunnelConfiguration{
		DevType:              options.Tunnel.DevType,
		Topology:             options.Tunnel.Topology,
		TunMTU:               options.DataChannel.MTU,
		LocalIPv4:            localIPv4,
		LocalIPv6:            localIPv6,
		VPNGateway:           options.Tunnel.VPNGateway,
		VPNGatewayIPv6:       options.Tunnel.VPNGatewayIPv6,
		RouteGateway:         options.Tunnel.RouteGateway,
		IPv4Routes:           ipv4Routes,
		IPv6Routes:           ipv6Routes,
		DHCPOptions:          slices.Clone(options.Tunnel.DHCPOptions),
		BlockIPv6:            options.Tunnel.BlockIPv6,
		BlockOutsideDNS:      options.Tunnel.BlockOutsideDNS,
		RedirectGateway:      options.Tunnel.RedirectGateway,
		RedirectGatewayFlags: slices.Clone(options.Tunnel.RedirectGatewayFlags),
		RedirectPrivate:      options.Tunnel.RedirectPrivate,
		RouteMetric:          options.Tunnel.RouteMetric,
		PingInterval:         options.Timing.PingInterval,
		PingRestart:          options.Timing.PingRestart,
	}
	var parsedDHCPOptions pushedOptions
	for _, dhcpOption := range options.Tunnel.DHCPOptions {
		parsedDHCPOptions.addWireDHCPOptionDNS(dhcpOption)
	}
	configuration.DNS = pushedAddresses(parsedDHCPOptions.DNS)
	configuration.SearchDomains = slices.Clone(parsedDHCPOptions.SearchDomains)
	configuration.DNSRoutes = slices.Clone(parsedDHCPOptions.DNSRoutes)
	return configuration
}

func cloneTunnelConfiguration(configuration TunnelConfiguration) TunnelConfiguration {
	cloned := TunnelConfiguration{
		DevType:              configuration.DevType,
		Topology:             configuration.Topology,
		TunMTU:               configuration.TunMTU,
		LocalIPv4:            slices.Clone(configuration.LocalIPv4),
		LocalIPv6:            slices.Clone(configuration.LocalIPv6),
		VPNGateway:           configuration.VPNGateway,
		VPNGatewayIPv6:       configuration.VPNGatewayIPv6,
		RouteGateway:         configuration.RouteGateway,
		IPv4Routes:           slices.Clone(configuration.IPv4Routes),
		IPv6Routes:           slices.Clone(configuration.IPv6Routes),
		ExcludedIPv4Routes:   slices.Clone(configuration.ExcludedIPv4Routes),
		ExcludedIPv6Routes:   slices.Clone(configuration.ExcludedIPv6Routes),
		DNS:                  slices.Clone(configuration.DNS),
		DNSServers:           cloneTunnelDNSServers(configuration.DNSServers),
		DHCPOptions:          slices.Clone(configuration.DHCPOptions),
		SearchDomains:        slices.Clone(configuration.SearchDomains),
		DNSRoutes:            slices.Clone(configuration.DNSRoutes),
		BlockIPv6:            configuration.BlockIPv6,
		BlockOutsideDNS:      configuration.BlockOutsideDNS,
		RedirectGateway:      configuration.RedirectGateway,
		RedirectGatewayFlags: slices.Clone(configuration.RedirectGatewayFlags),
		RedirectPrivate:      configuration.RedirectPrivate,
		RouteMetric:          configuration.RouteMetric,
		PingInterval:         configuration.PingInterval,
		PingRestart:          configuration.PingRestart,
		AuthToken:            configuration.AuthToken,
		AuthTokenUser:        configuration.AuthTokenUser,
		ExplicitExitNotify:   configuration.ExplicitExitNotify,
		SelectedCipher:       configuration.SelectedCipher,
		SelectedAuth:         configuration.SelectedAuth,
		ProtocolFlags:        slices.Clone(configuration.ProtocolFlags),
		KeyDerivation:        configuration.KeyDerivation,
		InactiveTimeout:      configuration.InactiveTimeout,
		InactiveMinimumBytes: configuration.InactiveMinimumBytes,
		SessionTimeout:       configuration.SessionTimeout,
		PingExit:             configuration.PingExit,
		PingTimerRemote:      configuration.PingTimerRemote,
	}
	if configuration.PeerID != nil {
		peerIDCopy := *configuration.PeerID
		cloned.PeerID = &peerIDCopy
	}
	return cloned
}

func cloneTunnelDNSServers(servers []TunnelDNSServer) []TunnelDNSServer {
	cloned := make([]TunnelDNSServer, len(servers))
	for i, server := range servers {
		cloned[i] = TunnelDNSServer{
			Priority:       server.Priority,
			Addresses:      slices.Clone(server.Addresses),
			ResolveDomains: slices.Clone(server.ResolveDomains),
			DNSSEC:         server.DNSSEC,
			Transport:      server.Transport,
			SNI:            server.SNI,
		}
	}
	return cloned
}

func (options pushedOptions) localAddressByFamily(ipv4 bool) []pushedLocalAddress {
	if len(options.LocalAddress) == 0 {
		return nil
	}
	values := make([]pushedLocalAddress, 0, len(options.LocalAddress))
	for _, value := range options.LocalAddress {
		if value.Prefix.IsValid() && value.Prefix.Addr().Is4() == ipv4 {
			values = append(values, value)
		}
	}
	return values
}

func (options pushedOptions) routesByFamily(ipv4 bool) []pushedRoute {
	if len(options.Routes) == 0 {
		return nil
	}
	values := make([]pushedRoute, 0, len(options.Routes))
	for _, value := range options.Routes {
		if value.Route.Prefix.IsValid() && value.Route.Prefix.Addr().Is4() == ipv4 {
			values = append(values, value)
		}
	}
	return values
}

func (options pushedOptions) routeGatewayFilterValue() string {
	if options.RouteGatewayRaw != "" {
		return options.RouteGatewayRaw
	}
	if options.RouteGatewayVPN {
		return "vpn_gateway"
	}
	if options.RouteGateway.IsValid() {
		return options.RouteGateway.String()
	}
	return ""
}

func (options pushedOptions) routeGateway(vpnGateway netip.Addr, topology string) netip.Addr {
	if options.RouteGateway.IsValid() {
		return options.RouteGateway
	}
	if options.RouteGatewayVPN && vpnGateway.IsValid() && !strings.EqualFold(strings.TrimSpace(topology), "subnet") {
		return vpnGateway
	}
	return netip.Addr{}
}

func pushedLocalAddressPrefixes(values []pushedLocalAddress) ([]netip.Prefix, netip.Addr) {
	prefixes := make([]netip.Prefix, 0, len(values))
	var vpnGateway netip.Addr
	for _, value := range values {
		if !value.Prefix.IsValid() {
			continue
		}
		if !vpnGateway.IsValid() && value.Peer.IsValid() {
			vpnGateway = value.Peer
		}
		if !slices.Contains(prefixes, value.Prefix) {
			prefixes = append(prefixes, value.Prefix)
		}
	}
	return prefixes, vpnGateway
}

func pushedAddresses(values []pushedAddress) []netip.Addr {
	addresses := make([]netip.Addr, 0, len(values))
	for _, value := range values {
		if value.Address.IsValid() {
			addresses = append(addresses, value.Address)
		}
	}
	return addresses
}

func pushedTunnelRoutes(values []pushedRoute, routeMetric int) []TunnelRoute {
	routes := make([]TunnelRoute, 0, len(values))
	for _, value := range values {
		route := value.Route
		if !route.Prefix.IsValid() {
			continue
		}
		route.Prefix = route.Prefix.Masked()
		if route.Metric == 0 {
			route.Metric = routeMetric
		}
		routes = append(routes, route)
	}
	return routes
}

func splitLocalAddressPrefixes(values []netip.Prefix) ([]netip.Prefix, []netip.Prefix) {
	var ipv4Values []netip.Prefix
	var ipv6Values []netip.Prefix
	for _, value := range values {
		if !value.IsValid() {
			continue
		}
		if value.Addr().Is4() {
			ipv4Values = append(ipv4Values, value)
		} else if value.Addr().Is6() {
			ipv6Values = append(ipv6Values, value)
		}
	}
	return ipv4Values, ipv6Values
}

func splitTunnelRoutes(values []TunnelRoute, routeGateway netip.Addr, vpnGateway netip.Addr, vpnGatewayIPv6 netip.Addr, routeMetric int) ([]TunnelRoute, []TunnelRoute) {
	var ipv4Routes []TunnelRoute
	var ipv6Routes []TunnelRoute
	for _, route := range values {
		if !route.Prefix.IsValid() {
			continue
		}
		route.Prefix = route.Prefix.Masked()
		if route.Metric == 0 {
			route.Metric = routeMetric
		}
		if route.Prefix.Addr().Is4() {
			if !route.Gateway.IsValid() && routeGateway.Is4() {
				route.Gateway = routeGateway
			} else if !route.Gateway.IsValid() && vpnGateway.Is4() {
				route.Gateway = vpnGateway
			}
			ipv4Routes = append(ipv4Routes, route)
		} else if route.Prefix.Addr().Is6() {
			if !route.Gateway.IsValid() && vpnGatewayIPv6.Is6() {
				route.Gateway = vpnGatewayIPv6
			}
			ipv6Routes = append(ipv6Routes, route)
		}
	}
	return ipv4Routes, ipv6Routes
}

func fillTunnelRouteGateways(routes []TunnelRoute, gateway netip.Addr) {
	if !gateway.IsValid() {
		return
	}
	for routeIndex := range routes {
		if !routes[routeIndex].Gateway.IsValid() && routes[routeIndex].Prefix.Addr().Is4() == gateway.Is4() {
			routes[routeIndex].Gateway = gateway
		}
	}
}

func appendUniqueAddresses(destination []netip.Addr, values []netip.Addr) []netip.Addr {
	for _, value := range values {
		if !value.IsValid() {
			continue
		}
		if !slices.Contains(destination, value) {
			destination = append(destination, value)
		}
	}
	return destination
}

func appendUniqueTunnelRoutes(destination []TunnelRoute, values []TunnelRoute) []TunnelRoute {
	for _, value := range values {
		if !value.Prefix.IsValid() {
			continue
		}
		value.Prefix = value.Prefix.Masked()
		if !slices.Contains(destination, value) {
			destination = append(destination, value)
		}
	}
	return destination
}
