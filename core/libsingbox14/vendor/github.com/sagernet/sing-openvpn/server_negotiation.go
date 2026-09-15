package openvpn

import (
	"net/netip"
	"slices"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

func tlsServerCipher(peerInfo string, optionsString string, options ServerOptions) (string, error) {
	serverCiphers := tlsAdvertisedDataCiphers(options.DataChannel.Ciphers)
	clientCiphers, clientCipherListKnown := parsePeerInfoCipherList(peerInfo)
	remoteCipher := strings.TrimSpace(extractRemoteCipherName(optionsString))
	if clientCipherListKnown {
		remoteCipher = ""
	}
	for _, serverCipher := range serverCiphers {
		for _, clientCipher := range clientCiphers {
			if strings.EqualFold(serverCipher, clientCipher) {
				return serverCipher, nil
			}
		}
		if remoteCipher != "" && strings.EqualFold(serverCipher, remoteCipher) {
			return serverCipher, nil
		}
	}
	if clientCipherListKnown || remoteCipher != "" {
		return "", E.Extend(ErrCipherNegotiationFailed, "no shared cipher")
	}
	if options.DataChannel.FallbackCipher != "" {
		return options.DataChannel.FallbackCipher, nil
	}
	return "", E.Extend(ErrCipherNegotiationFailed, "no shared cipher")
}

// Upstream tls_peer_ncp_list (ssl_ncp.c) answers IV_CIPHERS when the peer sent
// it and otherwise reads IV_NCP=2 as the two GCM ciphers.
func parsePeerInfoCipherList(peerInfo string) ([]string, bool) {
	ciphers, announced := peerInfoIVCipherList(peerInfo)
	if announced {
		return ciphers, true
	}
	if peerInfoNCPVersion(peerInfo) >= 2 {
		return []string{"AES-256-GCM", "AES-128-GCM"}, true
	}
	return nil, false
}

func peerInfoIVCipherList(peerInfo string) ([]string, bool) {
	for line := range strings.SplitSeq(peerInfo, "\n") {
		if !strings.HasPrefix(line, "IV_CIPHERS=") {
			continue
		}
		return splitPeerInfoCipherList(strings.TrimPrefix(line, "IV_CIPHERS=")), true
	}
	return nil, false
}

func splitPeerInfoCipherList(value string) []string {
	var ciphers []string
	for cipherName := range strings.SplitSeq(value, ":") {
		trimmedCipherName := strings.TrimSpace(cipherName)
		if trimmedCipherName == "" {
			continue
		}
		ciphers = append(ciphers, trimmedCipherName)
	}
	return ciphers
}

func peerInfoNCPVersion(peerInfo string) int {
	for line := range strings.SplitSeq(peerInfo, "\n") {
		trimmedLine := strings.TrimRight(line, "\r")
		if !strings.HasPrefix(trimmedLine, "IV_NCP=") {
			continue
		}
		parsedValue, err := strconv.Atoi(strings.TrimPrefix(trimmedLine, "IV_NCP="))
		if err != nil {
			return 0
		}
		return parsedValue
	}
	return 0
}

const (
	serverPushBundleSize     = 1024
	serverPushBundleOverhead = 84
	serverPushSafeCapacity   = serverPushBundleSize - serverPushBundleOverhead
)

func buildServerPushReplyPayloads(options ServerOptions, peerInfo string, selectedCipher string, assignment serverPushAssignment) ([][]byte, error) {
	serverPushOptions := buildPushedOptions(options)
	if _, supportsPushMTU := peerInfoMTU(peerInfo); !supportsPushMTU {
		serverPushOptions.TunMTU = 0
	}
	if assignment.LocalAddressIPv4.Prefix.IsValid() {
		serverPushOptions.LocalAddress = replacePushedLocalAddressByFamily(serverPushOptions.LocalAddress, assignment.LocalAddressIPv4)
	}
	if assignment.LocalAddressIPv6.Prefix.IsValid() {
		serverPushOptions.LocalAddress = replacePushedLocalAddressByFamily(serverPushOptions.LocalAddress, assignment.LocalAddressIPv6)
	}
	if assignment.IPv4Topology != "" {
		serverPushOptions.Topology = assignment.IPv4Topology
		switch assignment.IPv4Topology {
		case ipv4TopologySubnet:
			if !serverPushOptions.RouteGateway.IsValid() && !serverPushOptions.RouteGatewayVPN && serverPushOptions.RouteGatewayRaw == "" {
				serverPushOptions.RouteGateway = assignment.ServerIPv4
			}
		case ipv4TopologyNet30:
			serverRoute := TunnelRoute{Prefix: netip.PrefixFrom(assignment.ServerIPv4, 32)}
			serverPushOptions.Routes = appendUniquePushedRoutes(serverPushOptions.Routes, serverRoute)
		}
	}
	fields := buildPushReplyOptionFields(serverPushOptions)
	_, hasCipherList := parsePeerInfoCipherList(peerInfo)
	if selectedCipher != "" && (hasCipherList || peerInfoNCPVersion(peerInfo) >= 2) {
		fields = append(fields, "cipher "+selectedCipher)
	}
	if assignment.PeerID != nil && peerSupportsIVProtoFlag(peerInfo, tlsIVProtoDataV2) {
		fields = append(fields, "peer-id "+strconv.FormatUint(uint64(*assignment.PeerID), 10))
	}
	supportsCCExit := peerSupportsIVProtoFlag(peerInfo, tlsIVProtoCCExitNotify)
	supportsTLSKeyExport := peerSupportsIVProtoFlag(peerInfo, tlsIVProtoTLSKeyExport)
	if supportsCCExit {
		protocolFlags := []string{"cc-exit"}
		if supportsTLSKeyExport {
			protocolFlags = append(protocolFlags, "tls-ekm")
		}
		fields = append(fields, "protocol-flags "+strings.Join(protocolFlags, " "))
	} else if supportsTLSKeyExport {
		fields = append(fields, "key-derivation tls-ekm")
	}
	return splitServerPushReplyFields(fields)
}

func splitServerPushReplyFields(fields []string) ([][]byte, error) {
	if len(fields) == 0 || fields[0] != pushReplyPayloadPrefix {
		return nil, E.New("invalid OpenVPN push reply fields")
	}
	current := pushReplyPayloadPrefix
	multiPush := false
	payloads := make([][]byte, 0, 1)
	for _, field := range fields[1:] {
		addition := "," + field
		if len(current)+len(addition) >= serverPushSafeCapacity {
			if current == pushReplyPayloadPrefix {
				return nil, E.New("push option is too long: ", field)
			}
			payloads = append(payloads, []byte(current+",push-continuation 2"))
			current = pushReplyPayloadPrefix
			multiPush = true
		}
		if len(current)+len(addition) >= serverPushSafeCapacity {
			return nil, E.New("push option is too long: ", field)
		}
		current += addition
	}
	if multiPush {
		current += ",push-continuation 1"
	}
	return append(payloads, []byte(current)), nil
}

func appendUniquePushedRoutes(routes []pushedRoute, route TunnelRoute) []pushedRoute {
	if slices.ContainsFunc(routes, func(existingRoute pushedRoute) bool {
		return existingRoute.Route == route
	}) {
		return routes
	}
	return append(routes, pushedRoute{Route: route})
}
