package openconnect

import (
	"context"
	"encoding/hex"
	"encoding/xml"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/netip"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
)

const (
	gpConfigurationPath        = "/ssl-vpn/getconfig.esp"
	gpDefaultTunnelPath        = "/ssl-tunnel-connect.sslvpn"
	gpDefaultDPDInterval       = 10 * time.Second
	gpMaximumConfigurationBody = 16 * 1024 * 1024
	gpDefaultBaseMTU           = 1406
)

type gpTunnelConfiguration struct {
	Configuration TunnelConfiguration
	TunnelPath    string
	DPD           time.Duration
	Keepalive     time.Duration
	Rekey         time.Duration
	AssignedIPv4  netip.Addr
	AssignedIPv6  netip.Addr
	ESP           *gpESPConfiguration
}

type gpESPConfiguration struct {
	Remote M.Socksaddr
	Magic  netip.Addr
	Keys   *espKeySet
}

type gpConfigurationXMLNode struct {
	XMLName  xml.Name
	Text     string                   `xml:",chardata"`
	Status   string                   `xml:"status,attr"`
	Children []gpConfigurationXMLNode `xml:",any"`
}

type gpRawESPConfiguration struct {
	port                   uint16
	encryption             espEncryption
	authentication         espAuthentication
	outboundSPI            uint32
	inboundSPI             uint32
	outboundEncryptionKey  []byte
	inboundEncryptionKey   []byte
	outboundAuthentication []byte
	inboundAuthentication  []byte
	mode                   string
}

func (f *gpFrontend) fetchTunnelConfiguration(ctx context.Context, snapshot gpSessionSnapshot) (*gpTunnelConfiguration, error) {
	requestBody := buildGPConfigurationRequest(f.client, snapshot)
	requestURL := cloneGPURL(snapshot.serverURL)
	requestURL.Path = gpConfigurationPath
	requestURL.RawPath = ""
	requestURL.RawQuery = ""
	requestURL.ForceQuery = false
	requestURL.Fragment = ""
	transport := f.client.httpTransport.Clone()
	defer transport.CloseIdleConnections()
	gatewayHostname := requestURL.Hostname()
	gatewayPort := effectiveGPPort(requestURL)
	transport.DialContext = func(dialContext context.Context, network string, address string) (net.Conn, error) {
		destinationHostname, destinationPort, splitErr := net.SplitHostPort(address)
		if splitErr != nil {
			return nil, markTerminal(E.Cause(splitErr, "parse GlobalProtect configuration destination"))
		}
		if !strings.EqualFold(destinationHostname, gatewayHostname) || destinationPort != gatewayPort {
			return nil, markTerminal(E.New("configuration attempted to dial outside the authenticated gateway endpoint"))
		}
		parsedPort, parseErr := strconv.ParseUint(destinationPort, 10, 16)
		if parseErr != nil || parsedPort == 0 {
			return nil, markTerminal(E.New("configuration attempted to dial an invalid gateway port"))
		}
		destinationHost := gatewayHostname
		if snapshot.authenticatedAddress.IsValid() {
			destinationHost = snapshot.authenticatedAddress.String()
		}
		dialer := f.client.options.Dialer
		destination := M.ParseSocksaddrHostPort(destinationHost, uint16(parsedPort))
		return dialer.DialContext(dialContext, network, destination)
	}
	configurationClient := &http.Client{
		Transport: f.client.wrapHTTPTransport(transport),
		Jar:       f.client.httpClient.Jar,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, requestURL.String(), strings.NewReader(requestBody))
	if err != nil {
		return nil, markTerminal(E.Cause(err, "create GlobalProtect configuration request"))
	}
	peer := &pinnedHTTPPeer{address: snapshot.authenticatedAddress}
	request = request.WithContext(httptrace.WithClientTrace(request.Context(), &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			peer.record(info.Conn)
		},
	}))
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	userAgent := gpUserAgent
	if f.client.options.UserAgent != "" {
		userAgent = f.client.options.UserAgent
	}
	request.Header.Set("User-Agent", userAgent)
	response, err := configurationClient.Do(request)
	if err != nil {
		requestErr := E.Cause(err, "send GlobalProtect configuration request")
		if response != nil && response.Body != nil {
			closeErr := response.Body.Close()
			if closeErr != nil {
				requestErr = E.Errors(requestErr, E.Cause(closeErr, "close failed GlobalProtect configuration response"))
			}
		}
		return nil, requestErr
	}
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, gpMaximumConfigurationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		responseErr := E.Cause(readErr, "read GlobalProtect configuration response")
		if closeErr != nil {
			responseErr = E.Errors(responseErr, E.Cause(closeErr, "close failed GlobalProtect configuration response"))
		}
		return nil, responseErr
	}
	if closeErr != nil {
		return nil, E.Cause(closeErr, "close GlobalProtect configuration response")
	}
	if len(responseBody) > gpMaximumConfigurationBody {
		return nil, markTerminal(E.New("configuration response exceeds ", gpMaximumConfigurationBody, " bytes"))
	}
	statusErr := classifyGPTunnelHTTPStatus(response.StatusCode, "configuration")
	if statusErr != nil {
		return nil, statusErr
	}
	if string(responseBody) == "errors getting SSL/VPN config" {
		return nil, E.Errors(ErrSessionRejected, E.New("gateway rejected the configuration cookie"))
	}
	authenticatedAddress := peer.address
	if !authenticatedAddress.IsValid() {
		return nil, markTerminal(E.New("configuration endpoint did not expose an authenticated IP address"))
	}
	configuration, err := parseGPTunnelConfiguration(ctx, f.client, responseBody, authenticatedAddress)
	if err != nil {
		return nil, err
	}
	return configuration, nil
}

// /tmp/openconnect/gpst.c:gpst_get_config() appends options without parsing and re-encoding the authenticated query, so its byte order remains part of the gateway contract.
func buildGPConfigurationRequest(client *Client, snapshot gpSessionSnapshot) string {
	var body strings.Builder
	body.WriteString("client-type=1&protocol-version=p1&internal=no")
	appendGPEncodedOption(&body, "app-version", snapshot.clientVersion)
	ipv6Support := "yes"
	if client.options.IPv6Disabled {
		ipv6Support = "no"
	}
	appendGPEncodedOption(&body, "ipv6-support", ipv6Support)
	appendGPEncodedOption(&body, "clientos", reportedGPOS(client))
	appendGPEncodedOption(&body, "os-version", client.options.ReportedOS)
	appendGPEncodedOption(&body, "hmac-algo", "sha1,md5,sha256")
	appendGPEncodedOption(&body, "enc-algo", "aes-128-cbc,aes-256-cbc")
	if snapshot.previousIPv4.IsValid() || !client.options.IPv6Disabled && snapshot.previousIPv6.IsValid() {
		if snapshot.previousIPv4.IsValid() {
			appendGPEncodedOption(&body, "preferred-ip", snapshot.previousIPv4.String())
		}
		if !client.options.IPv6Disabled && snapshot.previousIPv6.IsValid() {
			appendGPEncodedOption(&body, "preferred-ipv6", snapshot.previousIPv6.String())
		}
		filtered := filterGPOpaqueQuery(snapshot.opaqueQuery, map[string]struct{}{
			"preferred-ip":   {},
			"preferred-ipv6": {},
		}, false)
		if filtered != "" {
			body.WriteByte('&')
			body.WriteString(filtered)
		}
	} else if snapshot.opaqueQuery != "" {
		filtered := snapshot.opaqueQuery
		if client.options.IPv6Disabled {
			filtered = filterGPOpaqueQuery(filtered, map[string]struct{}{"preferred-ipv6": {}}, false)
		}
		if filtered != "" {
			body.WriteByte('&')
			body.WriteString(filtered)
		}
	}
	return body.String()
}

func appendGPEncodedOption(body *strings.Builder, name string, value string) {
	body.WriteByte('&')
	body.WriteString(name)
	body.WriteByte('=')
	body.WriteString(encodeGPFormComponent(value))
}

func filterGPOpaqueQuery(query string, selected map[string]struct{}, includeSelected bool) string {
	parts := strings.Split(query, "&")
	filtered := make([]string, 0, len(parts))
	for _, part := range parts {
		parsedName, _, found := strings.Cut(part, "=")
		name := part
		if found {
			name = parsedName
		}
		_, listed := selected[name]
		if listed == includeSelected {
			filtered = append(filtered, part)
		}
	}
	return strings.Join(filtered, "&")
}

func classifyGPTunnelHTTPStatus(statusCode int, operation string) error {
	if statusCode == http.StatusOK {
		return nil
	}
	if statusCode == http.StatusUnauthorized || statusCode == http.StatusForbidden || statusCode == 512 ||
		(operation == "GPST" && statusCode == http.StatusBadGateway) {
		return E.Errors(ErrSessionRejected, E.New(operation, " returned HTTP ", statusCode))
	}
	if operation == "GPST" && statusCode == http.StatusMethodNotAllowed {
		return markTerminal(E.Extend(ErrProtocolNotSupported, "GPST endpoint returned HTTP 405"))
	}
	statusErr := E.New(operation, " returned HTTP ", statusCode)
	if statusCode == 513 {
		return E.Errors(ErrAuthenticationFailed, statusErr)
	}
	if statusCode == http.StatusRequestTimeout || statusCode == http.StatusTooEarly || statusCode == http.StatusTooManyRequests || statusCode >= 500 {
		return statusErr
	}
	return markTerminal(statusErr)
}

func parseGPTunnelConfiguration(
	ctx context.Context,
	client *Client,
	responseBody []byte,
	authenticatedAddress netip.Addr,
) (*gpTunnelConfiguration, error) {
	var document gpConfigurationXMLNode
	err := decodeGPXML(responseBody, &document, "parse GlobalProtect tunnel configuration XML")
	if err != nil {
		return nil, markTerminal(err)
	}
	if document.XMLName.Local != "response" {
		return nil, markTerminal(E.New("unexpected GlobalProtect tunnel configuration XML root: ", document.XMLName.Local))
	}
	var responseError string
	for _, child := range document.Children {
		if child.XMLName.Local == "error" {
			responseError = strings.TrimSpace(child.Text)
			break
		}
	}
	if responseError != "" || strings.EqualFold(strings.TrimSpace(document.Status), "error") {
		return nil, markTerminal(classifyGPResponseError(responseError))
	}
	result := &gpTunnelConfiguration{
		TunnelPath: gpDefaultTunnelPath,
		DPD:        gpDefaultDPDInterval,
		Keepalive:  gpDefaultDPDInterval,
	}
	if client.options.DPDInterval > 0 {
		result.DPD = client.options.DPDInterval
		result.Keepalive = client.options.DPDInterval
	}
	var assignedIPv4Text string
	var assignedIPv6Text string
	var netmaskText string
	var magicIPv4 netip.Addr
	var magicIPv6 netip.Addr
	var rawESP *gpRawESPConfiguration
	var configuredMTU uint64
	var lifetime time.Duration
	for _, child := range document.Children {
		name := child.XMLName.Local
		value := strings.TrimSpace(child.Text)
		switch name {
		case "ip-address":
			assignedIPv4Text = value
		case "ip-address-v6":
			assignedIPv6Text = value
		case "netmask":
			netmaskText = value
		case "mtu":
			configuredMTU, err = parseGPUnsigned(value, "MTU", 32)
		case "lifetime":
			lifetime, err = parseGPSeconds(value, "authentication lifetime")
		case "disconnect-on-idle":
			result.Configuration.IdleTimeout, err = parseGPSeconds(value, "idle timeout")
		case "timeout":
			result.Rekey, err = parseGPAdjustedInterval(value, "rekey interval")
		case "ssl-tunnel-url":
			result.TunnelPath, err = parseGPTunnelPath(value)
		case "gw-address":
			if !client.options.NoUDP {
				parsedMagic, parseErr := parseGPAddress(value, false, "IPv4 ESP magic address")
				if parseErr != nil {
					if client.options.Logger != nil {
						client.options.Logger.WarnContext(ctx, "Ignoring invalid GlobalProtect IPv4 ESP magic address; using GPST: ", parseErr)
					}
				} else {
					magicIPv4 = parsedMagic
				}
			}
		case "gw-address-v6":
			if !client.options.NoUDP {
				parsedMagic, parseErr := parseGPAddress(value, true, "IPv6 ESP magic address")
				if parseErr != nil {
					if client.options.Logger != nil {
						client.options.Logger.WarnContext(ctx, "Ignoring invalid GlobalProtect IPv6 ESP magic address; using GPST: ", parseErr)
					}
				} else {
					magicIPv6 = parsedMagic
				}
			}
		case "dns", "dns-v6":
			err = appendGPAddresses(&result.Configuration.DNS, child, 3, "DNS server", true)
		case "wins":
			err = appendGPAddresses(&result.Configuration.NBNS, child, 3, "WINS server", false)
		case "dns-suffix":
			for _, member := range child.Children {
				if member.XMLName.Local == "member" && strings.TrimSpace(member.Text) != "" {
					result.Configuration.SearchDomains = append(result.Configuration.SearchDomains, strings.TrimSpace(member.Text))
				}
			}
		case "access-routes", "access-routes-v6":
			err = appendGPRoutes(&result.Configuration.Routes, child, strings.HasSuffix(name, "-v6"))
		case "exclude-access-routes", "exclude-access-routes-v6":
			err = appendGPRoutes(&result.Configuration.ExcludedRoutes, child, strings.HasSuffix(name, "-v6"))
		case "ipsec":
			if !client.options.NoUDP {
				if rawESP != nil {
					rawESP.clear()
					rawESP = nil
				}
				parsedESP, parseErr := parseGPRawESP(child)
				if parseErr != nil {
					if client.options.Logger != nil {
						client.options.Logger.WarnContext(ctx, "Ignoring invalid GlobalProtect ESP configuration; using GPST: ", parseErr)
					}
				} else {
					rawESP = parsedESP
				}
			}
		case "quarantine":
			if value != "" && value != "no" && client.options.Logger != nil {
				client.options.Logger.WarnContext(ctx, "tunnel configuration reports quarantine status: ", value)
			}
		case "connected-gw-ip", "need-tunnel", "bw-c2s", "bw-s2c", "default-gateway", "default-gateway-v6",
			"no-direct-access-to-local-network", "ip-address-preferred", "ip-address-v6-preferred", "ipv6-connection", "portal", "user", "error":
			// /tmp/openconnect/gpst.c:gpst_parse_config_xml() treats these gateway fields as informational and does not install them into tunnel configuration.
		default:
			if client.options.Logger != nil {
				client.options.Logger.WarnContext(ctx, "Ignoring unknown GlobalProtect tunnel configuration tag <", name, ">: ", value)
			}
		}
		if err != nil {
			if rawESP != nil {
				rawESP.clear()
			}
			return nil, markTerminal(err)
		}
	}
	assignedIPv4, ipv4Prefix, err := parseGPAssignedAddress(assignedIPv4Text, netmaskText, false)
	if err != nil {
		if rawESP != nil {
			rawESP.clear()
		}
		return nil, markTerminal(err)
	}
	assignedIPv6, ipv6Prefix, err := parseGPAssignedAddress(assignedIPv6Text, "", true)
	if err != nil {
		if rawESP != nil {
			rawESP.clear()
		}
		return nil, markTerminal(err)
	}
	if client.options.IPv6Disabled {
		assignedIPv6 = netip.Addr{}
		ipv6Prefix = netip.Prefix{}
		magicIPv6 = netip.Addr{}
	}
	if !assignedIPv4.IsValid() && !assignedIPv6.IsValid() {
		if rawESP != nil {
			rawESP.clear()
		}
		return nil, markTerminal(E.New("tunnel configuration has no assigned IP address"))
	}
	result.AssignedIPv4 = assignedIPv4
	result.AssignedIPv6 = assignedIPv6
	result.Configuration.RemoteAddress = authenticatedAddress.Unmap()
	if ipv4Prefix.IsValid() {
		result.Configuration.Addresses = append(result.Configuration.Addresses, ipv4Prefix)
	}
	if ipv6Prefix.IsValid() {
		result.Configuration.Addresses = append(result.Configuration.Addresses, ipv6Prefix)
	}
	if lifetime > 0 {
		result.Configuration.AuthenticationExpiration = time.Now().Add(lifetime)
	}
	if rawESP != nil {
		if !client.options.NoUDP {
			result.ESP = buildGPESPConfiguration(client, ctx, rawESP, authenticatedAddress, assignedIPv4, assignedIPv6, magicIPv4, magicIPv6)
		}
		rawESP.clear()
	}
	if configuredMTU == 0 {
		result.Configuration.MTU = uint32(calculateGPTunnelMTU(client.options.MTU, client.options.BaseMTU, authenticatedAddress.Is6(), result.ESP))
	} else {
		minimumMTU := uint64(576)
		if assignedIPv6.IsValid() {
			minimumMTU = 1280
		}
		if configuredMTU < minimumMTU || configuredMTU > 65535 {
			if result.ESP != nil {
				result.ESP.Keys.destroy()
			}
			return nil, markTerminal(E.New("invalid GlobalProtect tunnel MTU: ", configuredMTU))
		}
		result.Configuration.MTU = uint32(configuredMTU)
	}
	result.Configuration = normalizeTunnelConfiguration(result.Configuration, client.options.IPv6Disabled)
	return result, nil
}

func parseGPAssignedAddress(addressText string, netmaskText string, ipv6 bool) (netip.Addr, netip.Prefix, error) {
	addressText = strings.TrimSpace(addressText)
	if addressText == "" {
		return netip.Addr{}, netip.Prefix{}, nil
	}
	bits := 32
	if ipv6 {
		bits = 128
	}
	var address netip.Addr
	if strings.Contains(addressText, "/") {
		prefix, err := netip.ParsePrefix(addressText)
		if err != nil {
			return netip.Addr{}, netip.Prefix{}, E.Cause(err, "parse GlobalProtect assigned address")
		}
		address = prefix.Addr().Unmap()
		bits = prefix.Bits()
	} else {
		parsedAddress, err := netip.ParseAddr(addressText)
		if err != nil {
			return netip.Addr{}, netip.Prefix{}, E.Cause(err, "parse GlobalProtect assigned address")
		}
		address = parsedAddress.Unmap()
	}
	if ipv6 != address.Is6() {
		return netip.Addr{}, netip.Prefix{}, E.New("assigned address has the wrong address family: ", address)
	}
	if !ipv6 && strings.TrimSpace(netmaskText) != "" {
		parsedBits, err := parseGPIPv4Netmask(netmaskText)
		if err != nil {
			return netip.Addr{}, netip.Prefix{}, err
		}
		bits = parsedBits
	}
	return address, netip.PrefixFrom(address, bits), nil
}

func parseGPIPv4Netmask(value string) (int, error) {
	value = strings.TrimSpace(strings.TrimPrefix(value, "/"))
	if !strings.Contains(value, ".") {
		bits, err := strconv.Atoi(value)
		if err != nil || bits < 0 || bits > 32 {
			return 0, E.New("invalid GlobalProtect IPv4 netmask: ", value)
		}
		return bits, nil
	}
	maskAddress, err := netip.ParseAddr(value)
	if err != nil || !maskAddress.Is4() {
		return 0, E.New("invalid GlobalProtect IPv4 netmask: ", value)
	}
	bytes := maskAddress.As4()
	mask := uint32(bytes[0])<<24 | uint32(bytes[1])<<16 | uint32(bytes[2])<<8 | uint32(bytes[3])
	bits := 0
	zeroSeen := false
	for bit := 31; bit >= 0; bit-- {
		set := mask&(uint32(1)<<uint(bit)) != 0
		if zeroSeen && set {
			return 0, E.New("non-contiguous GlobalProtect IPv4 netmask: ", value)
		}
		if set {
			bits++
		} else {
			zeroSeen = true
		}
	}
	return bits, nil
}

func appendGPAddresses(destination *[]netip.Addr, node gpConfigurationXMLNode, maximum int, description string, deduplicate bool) error {
	for _, member := range node.Children {
		if member.XMLName.Local != "member" || len(*destination) >= maximum {
			continue
		}
		address, err := netip.ParseAddr(strings.TrimSpace(member.Text))
		if err != nil {
			return E.Cause(err, "parse GlobalProtect ", description)
		}
		address = address.Unmap()
		duplicate := false
		if deduplicate {
			if slices.Contains(*destination, address) {
				duplicate = true
			}
		}
		if !duplicate {
			*destination = append(*destination, address)
		}
	}
	return nil
}

func appendGPRoutes(destination *[]TunnelRoute, node gpConfigurationXMLNode, ipv6 bool) error {
	for _, member := range node.Children {
		if member.XMLName.Local != "member" {
			continue
		}
		value := strings.TrimSpace(member.Text)
		var prefix netip.Prefix
		if strings.Contains(value, "/") {
			parsedPrefix, err := netip.ParsePrefix(value)
			if err != nil {
				return E.Cause(err, "parse GlobalProtect tunnel route")
			}
			prefix = parsedPrefix
		} else {
			address, err := netip.ParseAddr(value)
			if err != nil {
				return E.Cause(err, "parse GlobalProtect tunnel route")
			}
			address = address.Unmap()
			bits := 32
			if address.Is6() {
				bits = 128
			}
			prefix = netip.PrefixFrom(address, bits)
		}
		prefix = netip.PrefixFrom(prefix.Addr().Unmap(), prefix.Bits()).Masked()
		if prefix.Addr().Is6() != ipv6 {
			return E.New("tunnel route has the wrong address family: ", value)
		}
		*destination = append(*destination, TunnelRoute{Prefix: prefix})
	}
	return nil
}

func parseGPRawESP(node gpConfigurationXMLNode) (*gpRawESPConfiguration, error) {
	raw := &gpRawESPConfiguration{}
	var err error
	for _, child := range node.Children {
		value := strings.TrimSpace(child.Text)
		switch child.XMLName.Local {
		case "udp-port":
			parsedPort, parseErr := parseGPUnsigned(value, "ESP UDP port", 16)
			if parseErr == nil && parsedPort == 0 {
				parseErr = E.New("ESP UDP port is zero")
			}
			raw.port = uint16(parsedPort)
			err = parseErr
		case "enc-algo":
			switch value {
			case "aes128", "aes-128-cbc":
				raw.encryption = espEncryptionAES128CBC
			case "aes-256-cbc":
				raw.encryption = espEncryptionAES256CBC
			default:
				err = E.New("unsupported GlobalProtect ESP encryption algorithm: ", value)
			}
		case "hmac-algo":
			switch value {
			case "md5":
				raw.authentication = espAuthenticationHMACMD596
			case "sha1":
				raw.authentication = espAuthenticationHMACSHA196
			case "sha256":
				raw.authentication = espAuthenticationHMACSHA256128
			default:
				err = E.New("unsupported GlobalProtect ESP authentication algorithm: ", value)
			}
		case "c2s-spi":
			raw.outboundSPI, err = parseGPSPI(value)
		case "s2c-spi":
			raw.inboundSPI, err = parseGPSPI(value)
		case "ekey-c2s":
			clear(raw.outboundEncryptionKey)
			raw.outboundEncryptionKey, err = parseGPESPKey(child, "outbound encryption")
		case "ekey-s2c":
			clear(raw.inboundEncryptionKey)
			raw.inboundEncryptionKey, err = parseGPESPKey(child, "inbound encryption")
		case "akey-c2s":
			clear(raw.outboundAuthentication)
			raw.outboundAuthentication, err = parseGPESPKey(child, "outbound authentication")
		case "akey-s2c":
			clear(raw.inboundAuthentication)
			raw.inboundAuthentication, err = parseGPESPKey(child, "inbound authentication")
		case "ipsec-mode":
			raw.mode = value
		}
		if err != nil {
			raw.clear()
			return nil, err
		}
	}
	return raw, nil
}

func parseGPESPKey(node gpConfigurationXMLNode, description string) ([]byte, error) {
	var bits uint64
	var encoded string
	var err error
	for _, child := range node.Children {
		switch child.XMLName.Local {
		case "bits":
			bits, err = parseGPUnsigned(strings.TrimSpace(child.Text), "ESP "+description+" key bit length", 32)
		case "val":
			encoded = strings.TrimSpace(child.Text)
		}
		if err != nil {
			return nil, err
		}
	}
	key, err := hex.DecodeString(encoded)
	if err != nil {
		return nil, E.Cause(err, "decode GlobalProtect ESP ", description, " key")
	}
	if bits == 0 || bits%8 != 0 || uint64(len(key)) != bits/8 {
		clear(key)
		return nil, E.New("ESP ", description, " key length does not match its bit count")
	}
	return key, nil
}

func parseGPSPI(value string) (uint32, error) {
	value = strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(value), "0x"), "0X")
	parsed, err := strconv.ParseUint(value, 16, 32)
	if err != nil || parsed == 0 {
		return 0, E.New("invalid GlobalProtect ESP SPI: ", value)
	}
	return uint32(parsed), nil
}

func (c *gpRawESPConfiguration) clear() {
	clear(c.outboundEncryptionKey)
	clear(c.inboundEncryptionKey)
	clear(c.outboundAuthentication)
	clear(c.inboundAuthentication)
	*c = gpRawESPConfiguration{}
}

func buildGPESPConfiguration(
	client *Client,
	ctx context.Context,
	raw *gpRawESPConfiguration,
	authenticatedAddress netip.Addr,
	assignedIPv4 netip.Addr,
	assignedIPv6 netip.Addr,
	magicIPv4 netip.Addr,
	magicIPv6 netip.Addr,
) *gpESPConfiguration {
	fallback := func(reason any) *gpESPConfiguration {
		if client.options.Logger != nil {
			client.options.Logger.WarnContext(ctx, "ESP configuration is unavailable; using GPST: ", reason)
		}
		return nil
	}
	if raw.mode != "" && raw.mode != "esp-tunnel" {
		return fallback("unsupported IPsec mode")
	}
	if raw.port == 0 || raw.encryption == 0 || raw.authentication == 0 || raw.outboundSPI == 0 || raw.inboundSPI == 0 {
		return fallback("incomplete ESP parameters")
	}
	var magic netip.Addr
	if assignedIPv6.IsValid() && magicIPv6.IsValid() {
		magic = magicIPv6
	} else if assignedIPv4.IsValid() && magicIPv4.IsValid() {
		magic = magicIPv4
	} else {
		return fallback("no magic gateway matching an assigned address")
	}
	keys, err := newESPKeySet(espKeySetConfig{
		Encryption:     raw.encryption,
		Authentication: raw.authentication,
		Outbound: espKeyMaterial{
			SPI:               raw.outboundSPI,
			EncryptionKey:     raw.outboundEncryptionKey,
			AuthenticationKey: raw.outboundAuthentication,
		},
		Inbound: espKeyMaterial{
			SPI:               raw.inboundSPI,
			EncryptionKey:     raw.inboundEncryptionKey,
			AuthenticationKey: raw.inboundAuthentication,
		},
	})
	if err != nil {
		return fallback(err)
	}
	if !authenticatedAddress.IsValid() {
		keys.destroy()
		return fallback("authenticated gateway address is missing")
	}
	return &gpESPConfiguration{
		Remote: M.ParseSocksaddrHostPort(authenticatedAddress.Unmap().String(), raw.port),
		Magic:  magic,
		Keys:   keys,
	}
}

func parseGPTunnelPath(value string) (string, error) {
	parsed, err := url.Parse(value)
	if err != nil {
		return "", E.Cause(err, "parse GlobalProtect tunnel path")
	}
	if parsed.IsAbs() || parsed.Host != "" || parsed.User != nil || parsed.Opaque != "" || parsed.RawQuery != "" || parsed.Fragment != "" || !strings.HasPrefix(parsed.Path, "/") {
		return "", E.New("invalid GlobalProtect tunnel path: ", value)
	}
	return parsed.EscapedPath(), nil
}

func parseGPAddress(value string, ipv6 bool, description string) (netip.Addr, error) {
	address, err := netip.ParseAddr(value)
	if err != nil {
		return netip.Addr{}, E.Cause(err, "parse GlobalProtect ", description)
	}
	address = address.Unmap()
	if address.Is6() != ipv6 {
		return netip.Addr{}, E.New(description, " has the wrong address family")
	}
	return address, nil
}

func parseGPUnsigned(value string, description string, bitSize int) (uint64, error) {
	parsed, err := strconv.ParseUint(strings.TrimSpace(value), 10, bitSize)
	if err != nil {
		return 0, E.Cause(err, "parse GlobalProtect ", description)
	}
	return parsed, nil
}

func parseGPSeconds(value string, description string) (time.Duration, error) {
	seconds, err := parseGPUnsigned(value, description, 64)
	if err != nil {
		return 0, err
	}
	if seconds > uint64(math.MaxInt64/int64(time.Second)) {
		return 0, E.New(description, " exceeds the supported duration")
	}
	return time.Duration(seconds) * time.Second, nil
}

func parseGPAdjustedInterval(value string, description string) (time.Duration, error) {
	interval, err := parseGPSeconds(value, description)
	if err != nil || interval == 0 {
		return interval, err
	}
	if interval > time.Minute {
		return interval - time.Minute, nil
	}
	interval /= 2
	if interval < time.Second {
		interval = time.Second
	}
	return interval, nil
}

func calculateGPTunnelMTU(requestedMTU uint32, baseMTU uint32, outerIPv6 bool, configuration *gpESPConfiguration) int {
	if baseMTU == 0 {
		baseMTU = gpDefaultBaseMTU
	}
	if baseMTU < 1280 {
		baseMTU = 1280
	}
	mtu := int(requestedMTU)
	if mtu == 0 {
		outerHeader := 20
		if outerIPv6 {
			outerHeader = 40
		}
		mtu = int(baseMTU) - outerHeader
		if configuration == nil {
			mtu -= 20
		} else {
			mtu -= 8
		}
	}
	if configuration == nil {
		return mtu - 5
	}
	configuration.Keys.outboundAccess.Lock()
	icvLength := configuration.Keys.outbound.authentication.icvLength()
	configuration.Keys.outboundAccess.Unlock()
	mtu -= 8 + icvLength + 16
	mtu -= mtu % 16
	mtu -= 2
	return mtu
}
