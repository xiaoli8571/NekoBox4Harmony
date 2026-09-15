package openvpn

import (
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"time"
)

func buildPushedOptions(options ServerOptions) pushedOptions {
	var localAddress []pushedLocalAddress
	if !hasPushedLocalAddressFamily(localAddress, true) {
		if prefix, loaded := firstPrefixByFamily(options.Tunnel.AddressPools, true); loaded {
			localAddress = append(localAddress, pushedLocalAddress{Prefix: prefix})
		}
	}
	if !hasPushedLocalAddressFamily(localAddress, false) {
		if prefix, loaded := firstPrefixByFamily(options.Tunnel.AddressPools, false); loaded {
			localAddress = append(localAddress, pushedLocalAddress{Prefix: prefix})
		}
	}
	if prefix, loaded := firstPrefixByFamily(options.Tunnel.LocalAddress, false); loaded {
		localAddress = applyPushedIPv6LocalAddressPeer(localAddress, prefix.Addr())
	}
	return pushedOptions{
		TunMTU:               options.DataChannel.MTU,
		LocalAddress:         localAddress,
		Routes:               pushedRoutesFromPrefixes(options.Push.Routes),
		DNS:                  pushedAddressesFromAddresses(options.Push.DNS),
		DNSServers:           cloneTunnelDNSServers(options.Push.DNSServers),
		DHCPOptions:          slices.Clone(options.Push.DHCPOptions),
		SearchDomains:        slices.Clone(options.Push.SearchDomains),
		modernDNS:            len(options.Push.DNSServers) > 0,
		BlockOutsideDNS:      options.Push.BlockOutsideDNS,
		RedirectGateway:      options.Push.RedirectGateway,
		RedirectGatewayFlags: slices.Clone(options.Push.RedirectGatewayFlags),
		PingInterval:         options.Push.PingInterval,
		PingIntervalEnabled:  options.Push.PingIntervalEnabled || options.Push.PingInterval > 0,
		PingRestart:          options.Push.PingRestart,
		PingRestartEnabled:   options.Push.PingRestartEnabled || options.Push.PingRestart > 0,
	}
}

func buildPushReplyOptionFields(options pushedOptions) []string {
	pushOptionFields := []string{pushReplyPayloadPrefix}
	if topology := strings.TrimSpace(options.Topology); topology != "" {
		pushOptionFields = append(pushOptionFields, "topology "+topology)
	}
	if options.TunMTU > 0 {
		pushOptionFields = append(pushOptionFields, "tun-mtu "+strconv.FormatUint(uint64(options.TunMTU), 10))
	}
	for _, localAddress := range options.LocalAddress {
		if localAddress.Prefix.Addr().Is4() {
			ifconfigValue := strings.TrimSpace(formatPushedIfconfig(localAddress, options.Topology))
			if ifconfigValue != "" {
				pushOptionFields = append(pushOptionFields, "ifconfig "+ifconfigValue)
			}
		} else if localAddress.Prefix.Addr().Is6() {
			ifconfigIPv6Value := strings.TrimSpace(formatPushedIfconfigIPv6(localAddress))
			if ifconfigIPv6Value != "" {
				pushOptionFields = append(pushOptionFields, "ifconfig-ipv6 "+ifconfigIPv6Value)
			}
		}
	}
	if routeGateway := formatPushedRouteGateway(options); routeGateway != "" {
		pushOptionFields = append(pushOptionFields, "route-gateway "+routeGateway)
	}
	for _, route := range options.Routes {
		routeValue := strings.TrimSpace(formatPushedRoute(route))
		if routeValue == "" {
			continue
		}
		if route.Route.Prefix.Addr().Is4() {
			pushOptionFields = append(pushOptionFields, "route "+routeValue)
		} else if route.Route.Prefix.Addr().Is6() {
			pushOptionFields = append(pushOptionFields, "route-ipv6 "+routeValue)
		}
	}
	for _, dnsValue := range options.DNS {
		if !dnsValue.Address.IsValid() {
			continue
		}
		if dnsValue.Address.Is4() {
			pushOptionFields = append(pushOptionFields, "dhcp-option DNS "+dnsValue.Address.String())
		} else if dnsValue.Address.Is6() {
			pushOptionFields = append(pushOptionFields, "dhcp-option DNS6 "+dnsValue.Address.String())
		}
	}
	if len(options.SearchDomains) > 0 {
		pushOptionFields = append(pushOptionFields, "dns search-domains "+strings.Join(options.SearchDomains, " "))
	}
	servers := cloneTunnelDNSServers(options.DNSServers)
	slices.SortFunc(servers, func(left TunnelDNSServer, right TunnelDNSServer) int {
		return left.Priority - right.Priority
	})
	for _, server := range servers {
		priority := strconv.Itoa(server.Priority)
		if len(server.Addresses) > 0 {
			addresses := make([]string, len(server.Addresses))
			for i, address := range server.Addresses {
				if address.Port() == 0 {
					addresses[i] = address.Addr().String()
				} else {
					addresses[i] = address.String()
				}
			}
			pushOptionFields = append(pushOptionFields, "dns server "+priority+" address "+strings.Join(addresses, " "))
		}
		if len(server.ResolveDomains) > 0 {
			pushOptionFields = append(pushOptionFields, "dns server "+priority+" resolve-domains "+strings.Join(server.ResolveDomains, " "))
		}
		if server.DNSSEC != "" {
			pushOptionFields = append(pushOptionFields, "dns server "+priority+" dnssec "+server.DNSSEC)
		}
		if server.Transport != "" {
			transport := server.Transport
			switch transport {
			case "doh":
				transport = "DoH"
			case "dot":
				transport = "DoT"
			}
			pushOptionFields = append(pushOptionFields, "dns server "+priority+" transport "+transport)
		}
		if server.SNI != "" {
			pushOptionFields = append(pushOptionFields, "dns server "+priority+" sni "+server.SNI)
		}
	}
	for _, dhcpOption := range options.DHCPOptions {
		dhcpOption = strings.TrimSpace(dhcpOption)
		if dhcpOption == "" {
			continue
		}
		pushOptionFields = append(pushOptionFields, "dhcp-option "+dhcpOption)
	}
	if options.BlockIPv6 {
		pushOptionFields = append(pushOptionFields, "block-ipv6")
	}
	if options.BlockOutsideDNS {
		pushOptionFields = append(pushOptionFields, "block-outside-dns")
	}
	if options.RedirectGateway {
		redirectGatewayValue := strings.TrimSpace(strings.Join(options.RedirectGatewayFlags, " "))
		if redirectGatewayValue == "" {
			pushOptionFields = append(pushOptionFields, "redirect-gateway")
		} else {
			pushOptionFields = append(pushOptionFields, "redirect-gateway "+redirectGatewayValue)
		}
	}
	if options.RedirectPrivate {
		pushOptionFields = append(pushOptionFields, "redirect-private")
	}
	if options.RouteMetric != 0 {
		pushOptionFields = append(pushOptionFields, "route-metric "+strconv.Itoa(options.RouteMetric))
	}
	if options.PingIntervalEnabled {
		pushOptionFields = append(pushOptionFields, "ping "+strconv.FormatInt(int64(options.PingInterval/time.Second), 10))
	}
	if options.PingRestartEnabled {
		pushOptionFields = append(pushOptionFields, "ping-restart "+strconv.FormatInt(int64(options.PingRestart/time.Second), 10))
	}
	if authToken := strings.TrimSpace(options.AuthToken); authToken != "" {
		pushOptionFields = append(pushOptionFields, "auth-token "+authToken)
	}
	if authTokenUser := strings.TrimSpace(options.AuthTokenUser); authTokenUser != "" {
		pushOptionFields = append(pushOptionFields, "auth-token-user "+authTokenUser)
	}
	if options.PeerID != nil {
		pushOptionFields = append(pushOptionFields, "peer-id "+strconv.FormatUint(uint64(*options.PeerID), 10))
	}
	if selectedCipher := strings.TrimSpace(options.SelectedCipher); selectedCipher != "" {
		pushOptionFields = append(pushOptionFields, "cipher "+selectedCipher)
	}
	if selectedAuth := strings.TrimSpace(options.SelectedAuth); selectedAuth != "" {
		pushOptionFields = append(pushOptionFields, "auth "+selectedAuth)
	}
	if len(options.ProtocolFlags) > 0 {
		pushOptionFields = append(pushOptionFields, "protocol-flags "+strings.Join(options.ProtocolFlags, " "))
	}
	if keyDerivation := strings.TrimSpace(options.KeyDerivation); keyDerivation != "" {
		pushOptionFields = append(pushOptionFields, "key-derivation "+keyDerivation)
	}
	if options.ExplicitExitNotify > 0 {
		pushOptionFields = append(pushOptionFields, "explicit-exit-notify "+strconv.FormatUint(uint64(options.ExplicitExitNotify), 10))
	}
	for _, directive := range options.CompressionDirectives {
		directiveValue := strings.TrimSpace(directive.Value)
		if directiveValue == "" {
			pushOptionFields = append(pushOptionFields, directive.Name)
			continue
		}
		pushOptionFields = append(pushOptionFields, directive.Name+" "+directiveValue)
	}
	if options.InactiveTimeout > 0 {
		inactiveField := "inactive " + strconv.FormatInt(int64(options.InactiveTimeout/time.Second), 10)
		if options.InactiveMinimumBytes > 0 {
			inactiveField += " " + strconv.FormatUint(options.InactiveMinimumBytes, 10)
		}
		pushOptionFields = append(pushOptionFields, inactiveField)
	}
	if options.SessionTimeout > 0 {
		pushOptionFields = append(pushOptionFields, "session-timeout "+strconv.FormatInt(int64(options.SessionTimeout/time.Second), 10))
	}
	if options.PingExit > 0 {
		pushOptionFields = append(pushOptionFields, "ping-exit "+strconv.FormatInt(int64(options.PingExit/time.Second), 10))
	}
	if options.PingTimerRemote {
		pushOptionFields = append(pushOptionFields, "ping-timer-rem")
	}
	return pushOptionFields
}

func applyPushedIPv6LocalAddressPeer(values []pushedLocalAddress, peer netip.Addr) []pushedLocalAddress {
	if !peer.Is6() {
		return values
	}
	for i := range values {
		if values[i].Prefix.IsValid() && values[i].Prefix.Addr().Is6() && !values[i].Peer.Is6() {
			values[i].Peer = peer
		}
	}
	return values
}

func hasPushedLocalAddressFamily(values []pushedLocalAddress, ipv4 bool) bool {
	for _, value := range values {
		if value.Prefix.IsValid() && value.Prefix.Addr().Is4() == ipv4 {
			return true
		}
	}
	return false
}

func replacePushedLocalAddressByFamily(values []pushedLocalAddress, replacement pushedLocalAddress) []pushedLocalAddress {
	if !replacement.Prefix.IsValid() {
		return values
	}
	ipv4 := replacement.Prefix.Addr().Is4()
	replaced := make([]pushedLocalAddress, 0, len(values)+1)
	for _, value := range values {
		if value.Prefix.IsValid() && value.Prefix.Addr().Is4() == ipv4 {
			continue
		}
		replaced = append(replaced, value)
	}
	replaced = append(replaced, replacement)
	return replaced
}

func pushedRoutesFromPrefixes(values []netip.Prefix) []pushedRoute {
	if len(values) == 0 {
		return nil
	}
	routes := make([]pushedRoute, 0, len(values))
	for _, value := range values {
		if value.IsValid() {
			routes = append(routes, pushedRoute{Route: TunnelRoute{Prefix: value.Masked()}})
		}
	}
	return routes
}

func pushedAddressesFromAddresses(values []netip.Addr) []pushedAddress {
	if len(values) == 0 {
		return nil
	}
	addresses := make([]pushedAddress, 0, len(values))
	for _, value := range values {
		if value.IsValid() {
			addresses = append(addresses, pushedAddress{Address: value})
		}
	}
	return addresses
}

func formatPushedIfconfig(value pushedLocalAddress, topology string) string {
	prefix := value.Prefix
	if !prefix.IsValid() || !prefix.Addr().Is4() {
		return ""
	}
	normalizedTopology := strings.ToLower(strings.TrimSpace(topology))
	if value.Peer.Is4() && normalizedTopology != ipv4TopologySubnet {
		return prefix.Addr().String() + " " + value.Peer.String()
	}
	if normalizedTopology == ipv4TopologyP2P || normalizedTopology == ipv4TopologyNet30 {
		return ""
	}
	return formatIfconfigPrefix(prefix, topology)
}

func formatPushedIfconfigIPv6(value pushedLocalAddress) string {
	prefix := value.Prefix
	if !prefix.IsValid() || !prefix.Addr().Is6() {
		return ""
	}
	if value.Peer.Is6() {
		return prefix.String() + " " + value.Peer.String()
	}
	return ""
}

func formatPushedRouteGateway(options pushedOptions) string {
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

func formatPushedRoute(route pushedRoute) string {
	if route.Raw != "" {
		return route.Raw
	}
	tunnelRoute := route.Route
	prefix := tunnelRoute.Prefix.Masked()
	if !prefix.IsValid() {
		return ""
	}
	var routeValue string
	if prefix.Addr().Is4() {
		routeValue = formatIPv4RoutePrefix(prefix)
	} else if prefix.Addr().Is6() {
		routeValue = prefix.String()
	} else {
		return ""
	}
	if tunnelRoute.Gateway.IsValid() {
		routeValue += " " + tunnelRoute.Gateway.String()
		if tunnelRoute.Metric != 0 {
			routeValue += " " + strconv.Itoa(tunnelRoute.Metric)
		}
	}
	return routeValue
}

func formatIfconfigPrefix(prefix netip.Prefix, topology string) string {
	if !prefix.IsValid() || !prefix.Addr().Is4() {
		return ""
	}
	mask := net.CIDRMask(prefix.Bits(), 32)
	return prefix.Addr().String() + " " + net.IP(mask).String()
}

func formatIPv4RoutePrefix(prefix netip.Prefix) string {
	prefix = prefix.Masked()
	if !prefix.IsValid() || !prefix.Addr().Is4() {
		return ""
	}
	mask := net.CIDRMask(prefix.Bits(), 32)
	return prefix.Addr().String() + " " + net.IP(mask).String()
}
