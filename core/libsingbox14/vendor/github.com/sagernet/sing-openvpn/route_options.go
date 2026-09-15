package openvpn

import (
	"net"
	"net/netip"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

var errInvalidPushedRouteGateway = E.New("invalid pushed route-gateway")

func parseIfconfigVPNGateway(ifconfigValues []string, topology string) netip.Addr {
	normalizedTopology := strings.ToLower(strings.TrimSpace(topology))
	if normalizedTopology == "subnet" {
		return netip.Addr{}
	}
	for _, ifconfigValue := range ifconfigValues {
		ifconfigFields := strings.Fields(ifconfigValue)
		if len(ifconfigFields) < 2 {
			continue
		}
		gatewayAddress, parseGatewayError := netip.ParseAddr(ifconfigFields[1])
		if parseGatewayError != nil || !gatewayAddress.Is4() {
			continue
		}
		if isIPv4MaskGateway(gatewayAddress) {
			continue
		}
		return gatewayAddress
	}
	return netip.Addr{}
}

func isIPv4MaskGateway(address netip.Addr) bool {
	if !address.Is4() {
		return false
	}
	maskBytes := address.As4()
	mask := net.IPv4Mask(maskBytes[0], maskBytes[1], maskBytes[2], maskBytes[3])
	maskSize, bits := mask.Size()
	return bits == 32 && maskSize >= 0 && maskSize < 32
}

func isNetGatewayToken(routeGateway string) bool {
	normalizedGateway := strings.ToLower(strings.TrimSpace(routeGateway))
	return normalizedGateway == "net_gateway" || normalizedGateway == "dhcp"
}

func parseIfconfigPrefix(ifconfig string, topology string) (netip.Prefix, error) {
	trimmed := strings.TrimSpace(ifconfig)
	if trimmed == "" {
		return netip.Prefix{}, E.New("empty ifconfig")
	}
	if strings.Contains(trimmed, "/") {
		prefix, err := netip.ParsePrefix(trimmed)
		if err != nil {
			return netip.Prefix{}, E.Cause(err, "parse ifconfig cidr: ", trimmed)
		}
		return prefix, nil
	}
	tokens := strings.Fields(trimmed)
	if len(tokens) != 2 {
		return netip.Prefix{}, E.New("invalid ifconfig: ", trimmed)
	}
	localAddress, err := netip.ParseAddr(tokens[0])
	if err != nil {
		return netip.Prefix{}, E.Cause(err, "parse ifconfig local: ", tokens[0])
	}
	if !localAddress.Is4() {
		return netip.Prefix{}, E.New("ipv4 ifconfig expected, got: ", tokens[0])
	}
	bits, parsedAsMask := parseDottedIPv4Mask(tokens[1])
	normalizedTopology := strings.ToLower(strings.TrimSpace(topology))
	if normalizedTopology == "" {
		if parsedAsMask {
			normalizedTopology = "subnet"
		} else {
			normalizedTopology = "net30"
		}
	}
	switch normalizedTopology {
	case ipv4TopologySubnet:
		if !parsedAsMask {
			return netip.Prefix{}, E.New("ifconfig subnet topology requires dotted-quad netmask: ", trimmed)
		}
		return netip.PrefixFrom(localAddress, bits), nil
	case ipv4TopologyP2P, ipv4TopologyNet30:
		peer, parseErr := netip.ParseAddr(tokens[1])
		if parseErr != nil {
			return netip.Prefix{}, E.Cause(parseErr, "parse ifconfig peer: ", tokens[1])
		}
		if !peer.Is4() {
			return netip.Prefix{}, E.New("ipv4 ifconfig peer expected, got: ", tokens[1])
		}
		if normalizedTopology == ipv4TopologyP2P {
			return netip.PrefixFrom(localAddress, 32), nil
		}
		return netip.PrefixFrom(localAddress, 30), nil
	default:
		return netip.Prefix{}, E.New("unsupported topology: ", topology)
	}
}

// Upstream get_ipv6_addr (options.c) leaves an IPv6 prefix that carries no '/'
// at /64, and reads the count behind the '/' with strtol(sep + 1, &endp, 10):
// an empty count is 0, and a count the conversion does not consume whole, a
// negative one or one above 128 rejects the prefix.
func parseIPv6AddressPrefix(token string) (netip.Prefix, error) {
	netbits := 64
	addressToken, netbitsToken, netbitsFound := strings.Cut(token, "/")
	if netbitsFound {
		netbits = 0
		if netbitsToken != "" {
			parsedNetbits, err := strconv.Atoi(netbitsToken)
			if err != nil || parsedNetbits < 0 || parsedNetbits > 128 {
				return netip.Prefix{}, E.New("ipv6 prefix '", token, "': invalid '/bits' spec (", netbitsToken, ")")
			}
			netbits = parsedNetbits
		}
	}
	address, err := parseIPv6Address(addressToken)
	if err != nil {
		return netip.Prefix{}, E.Cause(err, "ipv6 prefix '", token, "'")
	}
	return netip.PrefixFrom(address, netbits), nil
}

// Upstream get_ipv6_addr and ipv6_addr_safe (options.c) admit an address only
// through inet_pton(AF_INET6), which takes neither an IPv4 address nor the
// scope zone netip.ParseAddr accepts.
func parseIPv6Address(token string) (netip.Addr, error) {
	address, err := netip.ParseAddr(token)
	if err != nil {
		return netip.Addr{}, E.Cause(err, "parse ipv6 address: ", token)
	}
	if !address.Is6() || address.Zone() != "" {
		return netip.Addr{}, E.New("ipv6 address expected, got: ", token)
	}
	return address, nil
}

// Upstream add_option (options.c) takes --ifconfig-ipv6 with exactly two
// parameters, reads the local endpoint through get_ipv6_addr, requires the
// remote endpoint to be a bare address, and refuses netbits outside 64..124.
func parseIfconfigIPv6(row string) (netip.Prefix, netip.Addr, error) {
	tokens := strings.Fields(strings.TrimSpace(row))
	if len(tokens) != 2 {
		return netip.Prefix{}, netip.Addr{}, E.New("ifconfig-ipv6 expects a local and a remote endpoint, got: ", row)
	}
	localPrefix, err := parseIPv6AddressPrefix(tokens[0])
	if err != nil {
		return netip.Prefix{}, netip.Addr{}, err
	}
	remoteAddress, err := parseIPv6Address(tokens[1])
	if err != nil {
		return netip.Prefix{}, netip.Addr{}, err
	}
	if localPrefix.Bits() < 64 || localPrefix.Bits() > 124 {
		return netip.Prefix{}, netip.Addr{}, E.New("ifconfig-ipv6 netbits must be between 64 and 124, not '/", localPrefix.Bits(), "'")
	}
	return localPrefix, remoteAddress, nil
}

func parsePushedRoute(row string, remoteHost netip.Addr) (netip.Prefix, netip.Addr, int, bool, error) {
	tokens := strings.Fields(strings.TrimSpace(row))
	if len(tokens) == 0 {
		return netip.Prefix{}, netip.Addr{}, 0, false, E.New("empty route")
	}
	var destinationAddress netip.Addr
	bits := 32
	nextIndex := 1
	if strings.Contains(tokens[0], "/") {
		destinationPrefix, err := netip.ParsePrefix(tokens[0])
		if err != nil {
			return netip.Prefix{}, netip.Addr{}, 0, false, E.Cause(err, "parse route destination: ", tokens[0])
		}
		if !destinationPrefix.Addr().Is4() {
			return netip.Prefix{}, netip.Addr{}, 0, false, E.New("ipv4 route expected, got: ", tokens[0])
		}
		destinationAddress = destinationPrefix.Addr()
		bits = destinationPrefix.Bits()
	} else {
		address, err := netip.ParseAddr(tokens[0])
		if err != nil {
			return netip.Prefix{}, netip.Addr{}, 0, false, E.Cause(err, "parse route destination: ", tokens[0])
		}
		if !address.Is4() {
			return netip.Prefix{}, netip.Addr{}, 0, false, E.New("ipv4 route expected, got: ", tokens[0])
		}
		destinationAddress = address
		if len(tokens) >= 2 {
			maskBits, parsed := parseDottedIPv4Mask(tokens[1])
			if parsed {
				bits = maskBits
				nextIndex = 2
			}
		}
	}
	var gateway netip.Addr
	metric := 0
	excluded := false
	if len(tokens) > nextIndex {
		parsedMetric, metricErr := strconv.Atoi(tokens[nextIndex])
		if metricErr == nil {
			metric = parsedMetric
			nextIndex++
		} else {
			gatewayAddress, gatewayExcluded, parseErr := parsePushedRouteGateway(tokens[nextIndex], remoteHost, true)
			if parseErr != nil {
				return netip.Prefix{}, netip.Addr{}, 0, false, E.Cause(parseErr, "parse route gateway: ", tokens[nextIndex])
			}
			if gatewayExcluded {
				excluded = true
			}
			gateway = gatewayAddress
			nextIndex++
		}
	}
	if len(tokens) > nextIndex {
		parsedMetric, parseErr := strconv.Atoi(tokens[nextIndex])
		if parseErr != nil {
			return netip.Prefix{}, netip.Addr{}, 0, false, E.Cause(parseErr, "parse route metric: ", tokens[nextIndex])
		}
		metric = parsedMetric
	}
	if bits < 0 || bits > 32 {
		return netip.Prefix{}, netip.Addr{}, 0, false, E.New("invalid ipv4 prefix bits: ", bits)
	}
	prefix := netip.PrefixFrom(destinationAddress, bits)
	return prefix, gateway, metric, excluded, nil
}

func parsePushedRouteIPv6(row string, remoteHost netip.Addr) (netip.Prefix, netip.Addr, int, bool, error) {
	tokens := strings.Fields(strings.TrimSpace(row))
	if len(tokens) == 0 {
		return netip.Prefix{}, netip.Addr{}, 0, false, E.New("empty route-ipv6")
	}
	prefix, err := parseIPv6AddressPrefix(tokens[0])
	if err != nil {
		return netip.Prefix{}, netip.Addr{}, 0, false, E.Cause(err, "parse route-ipv6 destination")
	}
	var gateway netip.Addr
	metric := 0
	excluded := false
	nextIndex := 1
	if len(tokens) > nextIndex {
		parsedMetric, metricErr := strconv.Atoi(tokens[nextIndex])
		if metricErr == nil {
			metric = parsedMetric
			nextIndex++
		} else {
			gatewayAddress, gatewayExcluded, parseErr := parsePushedRouteGateway(tokens[nextIndex], remoteHost, false)
			if parseErr != nil {
				return netip.Prefix{}, netip.Addr{}, 0, false, E.Cause(parseErr, "parse route-ipv6 gateway: ", tokens[nextIndex])
			}
			if gatewayExcluded {
				excluded = true
			}
			gateway = gatewayAddress
			nextIndex++
		}
	}
	if len(tokens) > nextIndex {
		parsedMetric, parseErr := strconv.Atoi(tokens[nextIndex])
		if parseErr != nil {
			return netip.Prefix{}, netip.Addr{}, 0, false, E.Cause(parseErr, "parse route-ipv6 metric: ", tokens[nextIndex])
		}
		metric = parsedMetric
	}
	return prefix.Masked(), gateway, metric, excluded, nil
}

func parsePushedRouteGateway(token string, remoteHost netip.Addr, ipv4 bool) (netip.Addr, bool, error) {
	trimmedToken := strings.TrimSpace(token)
	if trimmedToken == "" {
		return netip.Addr{}, false, nil
	}
	if strings.EqualFold(trimmedToken, "vpn_gateway") {
		return netip.Addr{}, false, nil
	}
	if strings.EqualFold(trimmedToken, "remote_host") {
		if remoteHost.IsValid() && remoteHost.Is4() == ipv4 {
			return remoteHost, false, nil
		}
		return netip.Addr{}, false, nil
	}
	if isNetGatewayToken(trimmedToken) {
		return netip.Addr{}, true, nil
	}
	gateway, err := netip.ParseAddr(trimmedToken)
	if err != nil {
		return netip.Addr{}, false, err
	}
	if gateway.Is4() != ipv4 {
		if ipv4 {
			return netip.Addr{}, false, E.New("ipv4 route gateway expected, got: ", trimmedToken)
		}
		return netip.Addr{}, false, E.New("ipv6 route gateway expected, got: ", trimmedToken)
	}
	return gateway, false, nil
}

func parseDottedIPv4Mask(token string) (int, bool) {
	maskIP := net.ParseIP(token)
	if maskIP == nil {
		return 0, false
	}
	mask4 := maskIP.To4()
	if mask4 == nil {
		return 0, false
	}
	bits, total := net.IPv4Mask(mask4[0], mask4[1], mask4[2], mask4[3]).Size()
	if total != 32 {
		return 0, false
	}
	return bits, true
}
