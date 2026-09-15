package openvpn

import (
	"math"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	pushRequestPayload       = "PUSH_REQUEST"
	legacyPullRequestPayload = "PULL_REQUEST"
	pushReplyPayloadPrefix   = "PUSH_REPLY"
	pushUpdatePayloadPrefix  = "PUSH_UPDATE"
)

type pushedOptionParseError struct {
	Name  string
	Value string
	Err   error
}

type pushedExcludedRoute struct {
	Name  string
	Value string
	Route TunnelRoute
}

type pushedPingTimeoutAction uint8

const (
	pushedPingTimeoutNone pushedPingTimeoutAction = iota
	pushedPingTimeoutRestart
	pushedPingTimeoutExit
)

type wirePushedOptions struct {
	Topology              string
	TunMTU                uint32
	Ifconfig              string
	IfconfigIPv6          string
	RouteGateway          string
	Route                 []string
	RouteIPv6             []string
	DNS                   []string
	DHCPOptions           []string
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
	PingTimeoutAction     pushedPingTimeoutAction
	PingTimerRemote       bool
}

type pushOptionsKind int

const (
	pushOptionsKindReply pushOptionsKind = iota
	pushOptionsKindUpdate
)

const peerIDMaxValue = (1 << 24) - 1

// Upstream process_incoming_push_msg (push.c) hands the payload that follows
// "PUSH_REPLY," to apply_push_options (options.c), which cuts it into option
// lines with buf_parse(buf, ','): the comma is a raw separator and carries no
// escape of any kind.
func splitPushReplyPayloadLines(payload []byte) (string, []string, bool) {
	payloadValue := normalizeControlPayload(payload)
	if payloadValue == "" {
		return "", nil, false
	}
	payloadLines := strings.Split(payloadValue, ",")
	commandName := strings.TrimSpace(payloadLines[0])
	if !strings.EqualFold(commandName, pushReplyPayloadPrefix) &&
		!strings.EqualFold(commandName, pushUpdatePayloadPrefix) {
		return "", nil, false
	}
	return commandName, payloadLines[1:], true
}

func appendPushReplyPayloadSegment(accumulatedLines []string, payload []byte) ([]string, int, bool) {
	commandName, payloadLines, decoded := splitPushReplyPayloadLines(payload)
	if !decoded {
		return accumulatedLines, 0, false
	}
	if len(accumulatedLines) == 0 {
		accumulatedLines = append(accumulatedLines, commandName)
	}
	continuation := 0
	for _, optionLine := range payloadLines {
		parameters, parsed := parsePushedOptionLine(optionLine)
		if parsed && len(parameters) >= 2 && strings.EqualFold(parameters[0], "push-continuation") {
			continuationValue, err := strconv.Atoi(parameters[1])
			if err == nil && continuationValue >= 0 && continuationValue <= 2 {
				continuation = continuationValue
			}
		}
		accumulatedLines = append(accumulatedLines, optionLine)
	}
	return accumulatedLines, continuation, true
}

func decodePushReplyPayloadWithFilters(payload []byte, remoteHost netip.Addr, filters []PullFilter) (pushedOptions, int, bool) {
	commandName, payloadLines, decoded := splitPushReplyPayloadLines(payload)
	if !decoded {
		return pushedOptions{}, 0, false
	}
	options, continuation := decodePushReplyOptionLines(commandName, payloadLines, remoteHost, filters)
	return options, continuation, true
}

func decodePushReplyOptionLines(commandName string, optionLines []string, remoteHost netip.Addr, filters []PullFilter) (pushedOptions, int) {
	kind := pushOptionsKindReply
	if strings.EqualFold(commandName, pushUpdatePayloadPrefix) {
		kind = pushOptionsKindUpdate
	}
	var wireOptions wirePushedOptions
	var continuation int
	var pullFilterRejection string
	for _, payloadLine := range optionLines {
		optionLine := strings.TrimLeft(payloadLine, " \t\r\n\v\f")
		allowed, rejected := applyPullFilters(filters, optionLine)
		if rejected {
			pullFilterRejection = optionLine
			break
		}
		if !allowed {
			continue
		}
		parameters, parsed := parsePushedOptionLine(payloadLine)
		if !parsed {
			continue
		}
		optionName := parameters[0]
		optionValue := strings.Join(parameters[1:], " ")
		switch strings.ToLower(optionName) {
		case "topology":
			if optionValue != "" {
				wireOptions.Topology = optionValue
			}
		case "tun-mtu":
			tunMTUValue := parsePushedPositiveInteger(optionValue)
			if tunMTUValue > 0 {
				wireOptions.TunMTU = uint32(tunMTUValue)
			}
		case "ifconfig":
			if optionValue != "" {
				wireOptions.Ifconfig = optionValue
			}
		case "ifconfig-ipv6":
			if optionValue != "" {
				wireOptions.IfconfigIPv6 = optionValue
			}
		case "route":
			if optionValue != "" {
				wireOptions.Route = append(wireOptions.Route, optionValue)
			}
		case "route-gateway":
			if optionValue != "" {
				wireOptions.RouteGateway = optionValue
			}
		case "route-ipv6":
			if optionValue != "" {
				wireOptions.RouteIPv6 = append(wireOptions.RouteIPv6, optionValue)
			}
		case "dns":
			if optionValue != "" {
				wireOptions.DNS = append(wireOptions.DNS, optionValue)
			}
		case "dhcp-option":
			if optionValue != "" {
				wireOptions.DHCPOptions = append(wireOptions.DHCPOptions, optionValue)
			}
		case "block-ipv6":
			wireOptions.BlockIPv6 = true
		case "block-outside-dns":
			wireOptions.BlockOutsideDNS = true
		case "redirect-gateway":
			wireOptions.RedirectGateway = true
			if optionValue != "" {
				wireOptions.RedirectGatewayFlags = strings.Fields(optionValue)
			}
		case "redirect-private":
			wireOptions.RedirectPrivate = true
			if optionValue != "" {
				wireOptions.RedirectGatewayFlags = strings.Fields(optionValue)
			}
		case "route-metric":
			if optionValue != "" {
				wireOptions.RouteMetric = int(parsePushedPositiveInteger(optionValue))
				wireOptions.RouteMetricSet = true
			}
		case "ping":
			if optionValue != "" {
				wireOptions.PingInterval = parsePushedSecondCount(optionValue)
				wireOptions.PingIntervalEnabled = true
			}
		case "ping-restart":
			if optionValue != "" {
				wireOptions.PingRestart = parsePushedSecondCount(optionValue)
				wireOptions.PingRestartEnabled = true
				wireOptions.PingTimeoutAction = pushedPingTimeoutRestart
			}
		case "auth-token":
			wireOptions.AuthToken = optionValue
		case "auth-token-user":
			wireOptions.AuthTokenUser = optionValue
		case "peer-id":
			peerIDValue, err := strconv.ParseUint(strings.TrimSpace(optionValue), 10, 32)
			if err == nil && peerIDValue <= peerIDMaxValue {
				peerIDCopy := uint32(peerIDValue)
				wireOptions.PeerID = &peerIDCopy
			}
		case "cipher":
			if optionValue != "" {
				wireOptions.SelectedCipher = optionValue
			}
		case "auth":
			if optionValue != "" {
				wireOptions.SelectedAuth = optionValue
			}
		case "protocol-flags":
			if optionValue != "" {
				wireOptions.ProtocolFlags = strings.Fields(optionValue)
			}
		case "key-derivation":
			if optionValue != "" {
				wireOptions.KeyDerivation = strings.ToLower(strings.TrimSpace(optionValue))
			}
		case "explicit-exit-notify":
			if optionValue == "" {
				wireOptions.ExplicitExitNotify = 1
			} else {
				wireOptions.ExplicitExitNotify = uint32(parsePushedPositiveInteger(optionValue))
			}
			wireOptions.ExplicitExitNotifySet = true
		case compressionDirectiveCompress, compressionDirectiveLZO:
			wireOptions.CompressionDirectives = append(wireOptions.CompressionDirectives, compressionDirective{
				Name:  strings.ToLower(optionName),
				Value: strings.TrimSpace(optionValue),
			})
		case "inactive":
			inactiveFields := strings.Fields(optionValue)
			if len(inactiveFields) >= 1 {
				wireOptions.InactiveTimeout = parsePushedSecondCount(inactiveFields[0])
				wireOptions.InactiveTimeoutSet = true
				if len(inactiveFields) >= 2 {
					// Upstream parse_inactive (options.c) clamps negative
					// minimum-bytes to 0.
					minimumBytes, minimumBytesErr := strconv.ParseInt(inactiveFields[1], 10, 64)
					if minimumBytesErr == nil && minimumBytes > 0 {
						wireOptions.InactiveMinimumBytes = uint64(minimumBytes)
					}
				}
			}
		case "session-timeout":
			if optionValue != "" {
				wireOptions.SessionTimeout = parsePushedSecondCount(optionValue)
				wireOptions.SessionTimeoutSet = true
			}
		case "ping-exit":
			if optionValue != "" {
				wireOptions.PingExit = parsePushedSecondCount(optionValue)
				wireOptions.PingExitSet = true
				wireOptions.PingTimeoutAction = pushedPingTimeoutExit
			}
		case "ping-timer-rem":
			wireOptions.PingTimerRemote = true
		case "push-continuation":
			continuationValue, err := strconv.Atoi(optionValue)
			if err == nil && continuationValue >= 0 && continuationValue <= 2 {
				continuation = continuationValue
			}
		}
	}
	options := pushedOptionsFromWire(wireOptions, remoteHost)
	options.kind = kind
	options.pullFilterRejection = pullFilterRejection
	return options, continuation
}

// Upstream reads these pushed values with positive_atoi (options.c): atoi()
// with a negative result replaced by zero. atoi() is (int)strtol(), so it skips
// leading whitespace, stops at the first character the number does not cover,
// saturates at LONG_MIN/LONG_MAX and keeps only the low 32 bits of what strtol
// returned.
func parsePushedPositiveInteger(value string) int32 {
	text := strings.TrimLeft(value, " \t\n\v\f\r")
	numberEnd := 0
	if numberEnd < len(text) && (text[numberEnd] == '+' || text[numberEnd] == '-') {
		numberEnd++
	}
	digitStart := numberEnd
	for numberEnd < len(text) && text[numberEnd] >= '0' && text[numberEnd] <= '9' {
		numberEnd++
	}
	if numberEnd == digitStart {
		return 0
	}
	parsed, err := strconv.ParseInt(text[:numberEnd], 10, 64)
	if err != nil {
		parsed = math.MaxInt64
		if text[0] == '-' {
			parsed = math.MinInt64
		}
	}
	truncated := int32(parsed)
	if truncated < 0 {
		return 0
	}
	return truncated
}

func parsePushedSecondCount(value string) time.Duration {
	return time.Duration(parsePushedPositiveInteger(value)) * time.Second
}

func applyPullFilters(filters []PullFilter, optionLine string) (bool, bool) {
	for _, filter := range filters {
		if !strings.HasPrefix(optionLine, filter.Text) {
			continue
		}
		switch filter.Action {
		case "accept":
			return true, false
		case "ignore":
			return false, false
		case "reject":
			return false, true
		}
	}
	return true, false
}

func pushedOptionsFromWire(wireOptions wirePushedOptions, remoteHost netip.Addr) pushedOptions {
	options := pushedOptions{
		Topology:              wireOptions.Topology,
		TunMTU:                wireOptions.TunMTU,
		DHCPOptions:           slices.Clone(wireOptions.DHCPOptions),
		BlockIPv6:             wireOptions.BlockIPv6,
		BlockOutsideDNS:       wireOptions.BlockOutsideDNS,
		RedirectGateway:       wireOptions.RedirectGateway,
		RedirectGatewayFlags:  slices.Clone(wireOptions.RedirectGatewayFlags),
		RedirectPrivate:       wireOptions.RedirectPrivate,
		RouteMetric:           wireOptions.RouteMetric,
		RouteMetricSet:        wireOptions.RouteMetricSet,
		PingInterval:          wireOptions.PingInterval,
		PingIntervalEnabled:   wireOptions.PingIntervalEnabled,
		PingRestart:           wireOptions.PingRestart,
		PingRestartEnabled:    wireOptions.PingRestartEnabled,
		AuthToken:             wireOptions.AuthToken,
		AuthTokenUser:         wireOptions.AuthTokenUser,
		PeerID:                wireOptions.PeerID,
		SelectedCipher:        wireOptions.SelectedCipher,
		SelectedAuth:          wireOptions.SelectedAuth,
		ProtocolFlags:         slices.Clone(wireOptions.ProtocolFlags),
		KeyDerivation:         wireOptions.KeyDerivation,
		ExplicitExitNotify:    wireOptions.ExplicitExitNotify,
		ExplicitExitNotifySet: wireOptions.ExplicitExitNotifySet,
		CompressionDirectives: slices.Clone(wireOptions.CompressionDirectives),
		InactiveTimeout:       wireOptions.InactiveTimeout,
		InactiveMinimumBytes:  wireOptions.InactiveMinimumBytes,
		InactiveTimeoutSet:    wireOptions.InactiveTimeoutSet,
		SessionTimeout:        wireOptions.SessionTimeout,
		SessionTimeoutSet:     wireOptions.SessionTimeoutSet,
		PingExit:              wireOptions.PingExit,
		PingExitSet:           wireOptions.PingExitSet,
		PingTimerRemote:       wireOptions.PingTimerRemote,
	}
	switch wireOptions.PingTimeoutAction {
	case pushedPingTimeoutRestart:
		options.PingExit = 0
		options.PingExitSet = false
	case pushedPingTimeoutExit:
		options.PingRestart = 0
		options.PingRestartEnabled = false
	}
	if wireOptions.Ifconfig != "" {
		options.addWireIfconfig(wireOptions.Ifconfig, wireOptions.Topology)
	}
	if wireOptions.IfconfigIPv6 != "" {
		options.addWireIfconfigIPv6(wireOptions.IfconfigIPv6)
	}
	options.setWireRouteGateway(wireOptions.RouteGateway)
	for _, value := range wireOptions.Route {
		options.addWireRoute(value, remoteHost)
	}
	for _, value := range wireOptions.RouteIPv6 {
		options.addWireRouteIPv6(value, remoteHost)
	}
	for _, value := range wireOptions.DNS {
		options.addWireDNSOptionV2(value)
	}
	options.DNSServers = slices.DeleteFunc(options.DNSServers, func(server TunnelDNSServer) bool {
		if len(server.Addresses) > 0 {
			return false
		}
		options.addParseError("dns", "server "+strconv.Itoa(server.Priority), E.New("dns server has no address assigned"))
		return true
	})
	options.modernDNS = len(options.DNSServers) > 0
	for _, value := range wireOptions.DHCPOptions {
		if !options.modernDNS {
			options.addWireDHCPOptionDNS(value)
		}
	}
	if options.modernDNS {
		options.DHCPOptions = filterOpenVPNNonDNSDHCPOptions(options.DHCPOptions)
	}
	return options
}

func (options *pushedOptions) addWireIfconfig(value string, topology string) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return
	}
	prefix, err := parseIfconfigPrefix(raw, topology)
	if err != nil {
		options.addParseError("ifconfig", raw, err)
		return
	}
	options.LocalAddress = append(options.LocalAddress, pushedLocalAddress{
		Prefix: prefix,
		Peer:   parseIfconfigVPNGateway([]string{raw}, topology),
		Raw:    raw,
	})
}

func (options *pushedOptions) addWireIfconfigIPv6(value string) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return
	}
	prefix, peer, err := parseIfconfigIPv6(raw)
	if err != nil {
		options.addParseError("ifconfig-ipv6", raw, err)
		return
	}
	options.LocalAddress = append(options.LocalAddress, pushedLocalAddress{
		Prefix: prefix,
		Peer:   peer,
		Raw:    raw,
	})
}

func (options *pushedOptions) setWireRouteGateway(value string) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return
	}
	options.RouteGatewayRaw = raw
	fields := strings.Fields(raw)
	if len(fields) == 0 {
		return
	}
	if strings.EqualFold(fields[0], "vpn_gateway") {
		options.RouteGatewayVPN = true
		return
	}
	routeGateway, err := netip.ParseAddr(fields[0])
	if err != nil {
		options.addParseError("route-gateway", raw, errInvalidPushedRouteGateway)
		return
	}
	options.RouteGateway = routeGateway
}

func (options *pushedOptions) addWireRoute(value string, remoteHost netip.Addr) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return
	}
	prefix, gateway, metric, excluded, err := parsePushedRoute(raw, remoteHost)
	if err != nil {
		options.addParseError("route", raw, err)
		return
	}
	if excluded {
		options.addExcludedRoute("route", raw, TunnelRoute{Prefix: prefix, Metric: metric})
		return
	}
	options.Routes = append(options.Routes, pushedRoute{
		Route: TunnelRoute{
			Prefix:  prefix,
			Gateway: gateway,
			Metric:  metric,
		},
		Raw: raw,
	})
}

func (options *pushedOptions) addWireRouteIPv6(value string, remoteHost netip.Addr) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return
	}
	prefix, gateway, metric, excluded, err := parsePushedRouteIPv6(raw, remoteHost)
	if err != nil {
		options.addParseError("route-ipv6", raw, err)
		return
	}
	if excluded {
		options.addExcludedRoute("route-ipv6", raw, TunnelRoute{Prefix: prefix, Metric: metric})
		return
	}
	options.Routes = append(options.Routes, pushedRoute{
		Route: TunnelRoute{
			Prefix:  prefix,
			Gateway: gateway,
			Metric:  metric,
		},
		Raw: raw,
	})
}

func (options *pushedOptions) addWireDNSOptionV2(value string) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return
	}
	fields := strings.Fields(raw)
	if len(fields) == 0 {
		return
	}
	if strings.EqualFold(fields[0], "search-domains") {
		if len(fields) < 2 {
			options.addParseError("dns", raw, E.New("dns search-domains requires domain value"))
			return
		}
		for _, domain := range fields[1:] {
			if !validateTunnelDNSDomain(domain) {
				options.addParseError("dns", raw, E.New("dns search domain contains invalid characters: ", domain))
				continue
			}
			options.SearchDomains = appendUniqueStringValues(options.SearchDomains, []string{domain})
			options.modernSearchDomains = appendUniqueStringValues(options.modernSearchDomains, []string{domain})
		}
		return
	}
	if !strings.EqualFold(fields[0], "server") {
		return
	}
	if len(fields) < 3 {
		options.addParseError("dns", raw, E.New("invalid dns server option: ", raw))
		return
	}
	priority, err := strconv.Atoi(fields[1])
	if err != nil {
		options.addParseError("dns", raw, E.Cause(err, "parse dns server priority: ", fields[1]))
		return
	}
	if priority < 0 || priority > 127 {
		options.addParseError("dns", raw, E.New("pushed dns server priority must be between 0 and 127"))
		return
	}
	server := options.tunnelDNSServer(priority)
	switch strings.ToLower(fields[2]) {
	case "address":
		if len(fields) < 4 {
			options.addParseError("dns", raw, E.New("dns server address requires address value"))
			return
		}
		for _, addressValue := range fields[3:] {
			if len(server.Addresses) >= maxTunnelDNSServerAddresses {
				options.addParseError("dns", raw, E.New("dns server address maximum exceeded: ", addressValue))
				return
			}
			address, parseErr := parseTunnelDNSAddress(addressValue)
			if parseErr != nil {
				options.addParseError("dns", raw, E.Cause(parseErr, "parse dns server address: ", addressValue))
				continue
			}
			server.Addresses = append(server.Addresses, address)
			modernAddress := pushedAddress{Address: address.Addr(), Raw: raw, OptionName: "dns"}
			options.DNS = append(options.DNS, modernAddress)
			options.modernDNSAddresses = append(options.modernDNSAddresses, modernAddress)
		}
	case "resolve-domains":
		if len(fields) < 4 {
			options.addParseError("dns", raw, E.New("dns server resolve-domains requires domain value"))
			return
		}
		for _, domain := range fields[3:] {
			if !validateTunnelDNSDomain(domain) {
				options.addParseError("dns", raw, E.New("dns resolve domain contains invalid characters: ", domain))
				continue
			}
			server.ResolveDomains = appendUniqueStringValues(server.ResolveDomains, []string{domain})
		}
	case "dnssec":
		if len(fields) != 4 {
			options.addParseError("dns", raw, E.New("dns server dnssec requires one value"))
			return
		}
		dnssec := strings.ToLower(fields[3])
		switch dnssec {
		case "yes", "optional", "no":
			server.DNSSEC = dnssec
		default:
			options.addParseError("dns", raw, E.New("invalid dnssec mode: ", fields[3]))
		}
	case "transport":
		if len(fields) != 4 {
			options.addParseError("dns", raw, E.New("dns server transport requires one value"))
			return
		}
		switch fields[3] {
		case "plain":
			server.Transport = "plain"
		case "DoT":
			server.Transport = "dot"
		case "DoH":
			server.Transport = "doh"
		default:
			options.addParseError("dns", raw, E.New("invalid dns transport: ", fields[3]))
		}
	case "sni":
		if len(fields) != 4 {
			options.addParseError("dns", raw, E.New("dns server sni requires one value"))
			return
		}
		if !validateTunnelDNSDomain(fields[3]) {
			options.addParseError("dns", raw, E.New("dns server sni contains invalid characters: ", fields[3]))
			return
		}
		server.SNI = fields[3]
	default:
		options.addParseError("dns", raw, E.New("unsupported dns server option: ", fields[2]))
	}
}

func (options *pushedOptions) tunnelDNSServer(priority int) *TunnelDNSServer {
	for i := range options.DNSServers {
		if options.DNSServers[i].Priority == priority {
			return &options.DNSServers[i]
		}
	}
	options.DNSServers = append(options.DNSServers, TunnelDNSServer{Priority: priority})
	return &options.DNSServers[len(options.DNSServers)-1]
}

func parseTunnelDNSAddress(value string) (netip.AddrPort, error) {
	address, err := netip.ParseAddr(value)
	if err == nil {
		return netip.AddrPortFrom(address, 0), nil
	}
	addressPort, addressPortErr := netip.ParseAddrPort(value)
	if addressPortErr != nil {
		return netip.AddrPort{}, addressPortErr
	}
	if addressPort.Port() == 0 {
		return netip.AddrPort{}, E.New("dns server port must not be zero")
	}
	return addressPort, nil
}

func (options *pushedOptions) addWireDHCPOptionDNS(value string) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return
	}
	fields := strings.Fields(raw)
	if len(fields) == 0 {
		return
	}
	optionName := strings.ToUpper(fields[0])
	if optionName == "DOMAIN" || optionName == "ADAPTER_DOMAIN_SUFFIX" || optionName == "DOMAIN-SEARCH" {
		if len(fields) < 2 {
			options.addParseError("dhcp-option", raw, E.New("dhcp-option ", optionName, " requires domain value"))
			return
		}
		for _, domain := range fields[1:] {
			if !validateTunnelDNSDomain(domain) {
				options.addParseError("dhcp-option", raw, E.New("dhcp-option ", optionName, " contains invalid domain: ", domain))
				continue
			}
			options.SearchDomains = appendUniqueStringValues(options.SearchDomains, []string{domain})
		}
		return
	}
	if optionName == "DOMAIN-ROUTE" {
		if len(fields) < 2 {
			options.addParseError("dhcp-option", raw, E.New("dhcp-option DOMAIN-ROUTE requires domain value"))
			return
		}
		for _, domain := range fields[1:] {
			if !validateTunnelDNSDomain(domain) {
				options.addParseError("dhcp-option", raw, E.New("dhcp-option DOMAIN-ROUTE contains invalid domain: ", domain))
				continue
			}
			options.DNSRoutes = appendUniqueStringValues(options.DNSRoutes, []string{domain})
		}
		return
	}
	if optionName != "DNS" && optionName != "DNS6" {
		return
	}
	if len(fields) < 2 {
		options.addParseError("dhcp-option", raw, E.New("dhcp-option ", optionName, " requires address value"))
		return
	}
	for _, addressValue := range fields[1:] {
		address, err := netip.ParseAddr(addressValue)
		if err != nil {
			options.addParseError("dhcp-option", raw, E.Cause(err, "parse dhcp-option ", optionName, " address: ", addressValue))
			continue
		}
		if optionName == "DNS" && !address.Is4() {
			options.addParseError("dhcp-option", raw, E.New("dhcp-option DNS expected IPv4 address: ", addressValue))
			continue
		}
		if optionName == "DNS6" && !address.Is6() {
			options.addParseError("dhcp-option", raw, E.New("dhcp-option DNS6 expected IPv6 address: ", addressValue))
			continue
		}
		options.DNS = append(options.DNS, pushedAddress{Address: address, Raw: raw, OptionName: "dhcp-option"})
	}
}

func filterOpenVPNNonDNSDHCPOptions(values []string) []string {
	return slices.DeleteFunc(slices.Clone(values), func(value string) bool {
		fields := strings.Fields(value)
		if len(fields) == 0 {
			return false
		}
		switch strings.ToUpper(fields[0]) {
		case "DNS", "DNS6", "DOMAIN", "ADAPTER_DOMAIN_SUFFIX", "DOMAIN-SEARCH", "DOMAIN-ROUTE":
			return true
		default:
			return false
		}
	})
}

func (options *pushedOptions) addParseError(name string, value string, err error) {
	options.parseErrors = append(options.parseErrors, pushedOptionParseError{
		Name:  name,
		Value: value,
		Err:   err,
	})
}

func (options *pushedOptions) addExcludedRoute(name string, value string, route TunnelRoute) {
	options.excludedRoutes = append(options.excludedRoutes, pushedExcludedRoute{
		Name:  name,
		Value: value,
		Route: route,
	})
}

func normalizeControlPayload(payload []byte) string {
	trimmedPayload := strings.Trim(string(payload), "\x00")
	return strings.TrimSpace(trimmedPayload)
}

const (
	pushedOptionLineStateInitial = iota
	pushedOptionLineStateQuoted
	pushedOptionLineStateUnquoted
	pushedOptionLineStateDone
	pushedOptionLineStateSingleQuoted
)

// MAX_PARMS (options.h); apply_push_options calls parse_line with
// SIZE(p) - 1 parameter slots.
const pushedOptionLineMaxParameters = 16

// Upstream space() (options.c) counts the terminating NUL as whitespace, which
// is what closes the last unquoted parameter of a line.
func isPushedOptionLineSpace(character byte) bool {
	switch character {
	case 0, ' ', '\t', '\n', '\v', '\f', '\r':
		return true
	default:
		return false
	}
}

// parse_line (options.c) splits one option line into parameters, and it is the
// only place upstream processes an escape: a backslash quotes the next
// character, but only '\\', '"' and whitespace may follow it — anything else
// makes parse_line report "Bad backslash ('\') usage" and return zero
// parameters, which drops the whole option line. A line that ends inside a
// parameter (trailing backslash, unbalanced quote) is dropped the same way with
// "Residual parse state". Single quotes suppress backslash processing entirely,
// and ';' or '#' at the start of a parameter comments out the rest of the line.
func parsePushedOptionLine(line string) ([]string, bool) {
	parameters := make([]string, 0, 4)
	var parameter strings.Builder
	state := pushedOptionLineStateInitial
	backslash := false
parameterLoop:
	for index := 0; index <= len(line); index++ {
		var character byte
		if index < len(line) {
			character = line[index]
		}
		if !backslash && character == '\\' && state != pushedOptionLineStateSingleQuoted {
			backslash = true
			continue
		}
		if backslash && character != '\\' && character != '"' && !isPushedOptionLineSpace(character) {
			return nil, false
		}
		var stored byte
		switch state {
		case pushedOptionLineStateInitial:
			if isPushedOptionLineSpace(character) {
				break
			}
			if character == ';' || character == '#' {
				break parameterLoop
			}
			switch {
			case !backslash && character == '"':
				state = pushedOptionLineStateQuoted
			case !backslash && character == '\'':
				state = pushedOptionLineStateSingleQuoted
			default:
				stored = character
				state = pushedOptionLineStateUnquoted
			}
		case pushedOptionLineStateUnquoted:
			if !backslash && isPushedOptionLineSpace(character) {
				state = pushedOptionLineStateDone
			} else {
				stored = character
			}
		case pushedOptionLineStateQuoted:
			if !backslash && character == '"' {
				state = pushedOptionLineStateDone
			} else {
				stored = character
			}
		case pushedOptionLineStateSingleQuoted:
			if character == '\'' {
				state = pushedOptionLineStateDone
			} else {
				stored = character
			}
		}
		if state == pushedOptionLineStateDone {
			parameters = append(parameters, parameter.String())
			parameter.Reset()
			state = pushedOptionLineStateInitial
			if len(parameters) >= pushedOptionLineMaxParameters {
				break parameterLoop
			}
		}
		backslash = false
		if stored != 0 {
			parameter.WriteByte(stored)
		}
	}
	if state != pushedOptionLineStateInitial || len(parameters) == 0 {
		return nil, false
	}
	return parameters, true
}
