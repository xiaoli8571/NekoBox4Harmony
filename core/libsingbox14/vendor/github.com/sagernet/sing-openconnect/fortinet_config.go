package openconnect

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/xml"
	"io"
	"math"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

type fortinetTunnelConfiguration struct {
	configuration      TunnelConfiguration
	tlsConnectRequest  []byte
	dtlsConnectRequest []byte
	wantIPv4           bool
	wantIPv6           bool
	proposedIPv4       netip.Prefix
	proposedIPv6       netip.Prefix
	dtlsEnabled        bool
	echoInterval       time.Duration
	reconnectAllowed   bool
	checkSourceIP      bool
	cleanupTimeout     time.Duration
	platform           string
}

type fortinetXMLNode struct {
	name       xml.Name
	attributes []xml.Attr
	children   []fortinetXMLNode
	text       string
}

func (n *fortinetXMLNode) UnmarshalXML(decoder *xml.Decoder, start xml.StartElement) error {
	n.name = start.Name
	n.attributes = append([]xml.Attr(nil), start.Attr...)
	var text strings.Builder
	for {
		token, tokenErr := decoder.Token()
		if tokenErr != nil {
			return tokenErr
		}
		switch typedToken := token.(type) {
		case xml.StartElement:
			var child fortinetXMLNode
			decodeErr := decoder.DecodeElement(&child, &typedToken)
			if decodeErr != nil {
				return decodeErr
			}
			n.children = append(n.children, child)
		case xml.CharData:
			text.Write([]byte(typedToken))
		case xml.EndElement:
			if typedToken.Name == start.Name {
				n.text = text.String()
				return nil
			}
		}
	}
}

func (s *fortinetSessionState) loadConfiguration(ctx context.Context) (*fortinetTunnelConfiguration, error) {
	s.configurationOnce.Do(func() {
		snapshot := s.snapshot()
		configuration, cookie, configurationErr := s.frontend.fetchTunnelConfiguration(ctx, snapshot)
		if configurationErr != nil && classifyClientSessionError(configurationErr) != clientSessionErrorTerminal {
			configurationErr = E.Errors(ErrSessionRejected, configurationErr)
		}
		if configurationErr == nil && configuration != nil {
			s.access.Lock()
			s.svpnCookie = cookie
			s.acceptedAddress = configuration.configuration.RemoteAddress
			s.access.Unlock()
		}
		s.configuration = configuration
		s.configurationErr = configurationErr
	})
	if s.configurationErr != nil {
		return nil, s.configurationErr
	}
	if s.configuration == nil {
		return nil, markTerminal(E.New("configuration fetch returned no configuration"))
	}
	return s.configuration, nil
}

func (f *fortinetFrontend) fetchTunnelConfiguration(
	ctx context.Context,
	snapshot fortinetSessionSnapshot,
) (*fortinetTunnelConfiguration, string, error) {
	httpClient, transport, peer, clientErr := f.newPinnedHTTPClient(snapshot)
	if clientErr != nil {
		return nil, "", clientErr
	}
	defer transport.CloseIdleConnections()
	configurationURL := newFortinetEndpointURL(snapshot.serverURL, "/remote/fortisslvpn_xml")
	if !f.client.options.IPv6Disabled {
		configurationURL.RawQuery = "dual_stack=1"
	}
	response, responseBody, requestErr := f.doConfigurationRequest(ctx, httpClient, configurationURL)
	if requestErr != nil {
		return nil, "", requestErr
	}
	if response.StatusCode == http.StatusForbidden {
		legacyErr := f.probeLegacyConfiguration(ctx, httpClient, snapshot.serverURL)
		if legacyErr != nil {
			return nil, "", legacyErr
		}
		return nil, "", ErrSessionRejected
	}
	locationHeader := response.Header.Get("Location")
	if isFortinetRedirectStatus(response.StatusCode) {
		location, locationErr := response.Request.URL.Parse(locationHeader)
		if locationErr == nil && strings.HasPrefix(location.Path, "/remote/login") {
			return nil, "", ErrSessionRejected
		}
		return nil, "", markTerminal(E.New("configuration returned an unexpected redirect"))
	}
	if response.StatusCode == http.StatusUnauthorized {
		return nil, "", ErrSessionRejected
	}
	if response.StatusCode != http.StatusOK {
		return nil, "", E.New("configuration returned HTTP ", response.StatusCode)
	}
	configuration, parseErr := parseFortinetXMLConfiguration(responseBody, time.Now())
	if parseErr != nil {
		return nil, "", markTerminal(parseErr)
	}
	if f.client.options.IPv6Disabled {
		configuration.wantIPv6 = false
		configuration.proposedIPv6 = netip.Prefix{}
		if !configuration.wantIPv4 {
			return nil, "", markTerminal(E.New("server did not provide IPv4 tunnel configuration"))
		}
	}
	if f.client.options.DPDInterval > 0 {
		configuration.echoInterval = f.client.options.DPDInterval
	}
	acceptedAddress := peer.address
	if !acceptedAddress.IsValid() {
		return nil, "", markTerminal(E.New("configuration endpoint did not expose an accepted IP address"))
	}
	configuration.configuration.MTU = calculatePPPTunnelMTU(
		f.client.options.MTU,
		f.client.options.BaseMTU,
		acceptedAddress.Is6(),
		pppEncapsulationFortinet,
	)
	ipv6Disabled := f.client.options.IPv6Disabled || configuration.configuration.MTU < minimumIPv6MTU
	if ipv6Disabled {
		configuration.wantIPv6 = false
		configuration.proposedIPv6 = netip.Prefix{}
		if !configuration.wantIPv4 {
			return nil, "", markTerminal(E.New("calculated tunnel MTU is too small for the server's IPv6-only configuration"))
		}
	}
	configuration.configuration.RemoteAddress = acceptedAddress.Unmap()
	configuration.configuration = normalizeTunnelConfiguration(
		configuration.configuration,
		ipv6Disabled,
	)
	tunnelURL := newFortinetEndpointURL(snapshot.serverURL, "/remote/sslvpn-tunnel")
	cookie, loaded := fortinetCookieValue(snapshot.jar, tunnelURL)
	if !loaded {
		return nil, "", ErrSessionRejected
	}
	tlsRequest, buildTLSErr := buildFortinetTLSConnectRequest(tunnelURL, snapshot.jar, fortinetUserAgent(f.client))
	if buildTLSErr != nil {
		return nil, "", markTerminal(buildTLSErr)
	}
	dtlsRequest, buildDTLSErr := buildFortinetDTLSConnectRequest(cookie)
	if buildDTLSErr != nil {
		return nil, "", markTerminal(buildDTLSErr)
	}
	configuration.tlsConnectRequest = tlsRequest
	configuration.dtlsConnectRequest = dtlsRequest
	return configuration, cookie, nil
}

func (f *fortinetFrontend) doConfigurationRequest(
	ctx context.Context,
	httpClient *http.Client,
	requestURL *url.URL,
) (*http.Response, []byte, error) {
	request, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if requestErr != nil {
		return nil, nil, E.Cause(requestErr, "create Fortinet configuration request")
	}
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", fortinetUserAgent(f.client))
	response, responseErr := httpClient.Do(request)
	if responseErr != nil {
		return nil, nil, E.Cause(responseErr, "send Fortinet configuration request")
	}
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, fortinetMaximumAuthenticationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return nil, nil, E.Errors(E.Cause(readErr, "read Fortinet configuration response"), closeErr)
	}
	if closeErr != nil {
		return nil, nil, E.Cause(closeErr, "close Fortinet configuration response")
	}
	if len(responseBody) > fortinetMaximumAuthenticationBody {
		return nil, nil, markTerminal(E.New("configuration response exceeds ", fortinetMaximumAuthenticationBody, " bytes"))
	}
	return response, responseBody, nil
}

func (f *fortinetFrontend) probeLegacyConfiguration(
	ctx context.Context,
	httpClient *http.Client,
	serverURL *url.URL,
) error {
	legacyURL := newFortinetEndpointURL(serverURL, "/remote/fortisslvpn")
	response, responseBody, requestErr := f.doConfigurationRequest(ctx, httpClient, legacyURL)
	if requestErr != nil {
		return E.Errors(ErrSessionRejected, requestErr)
	}
	if response.StatusCode == http.StatusOK && len(bytes.TrimSpace(responseBody)) > 0 {
		return markTerminal(E.Extend(ErrProtocolNotSupported, "ancient pre-v5 Fortinet HTML configuration"))
	}
	return ErrSessionRejected
}

func parseFortinetXMLConfiguration(content []byte, now time.Time) (*fortinetTunnelConfiguration, error) {
	decoder := xml.NewDecoder(bytes.NewReader(bytes.TrimSpace(content)))
	var root fortinetXMLNode
	decodeErr := decoder.Decode(&root)
	if decodeErr != nil {
		return nil, E.Cause(decodeErr, "decode Fortinet VPN configuration XML")
	}
	var trailing fortinetXMLNode
	trailingErr := decoder.Decode(&trailing)
	if trailingErr == nil {
		return nil, E.New("VPN configuration contains trailing XML data")
	}
	if trailingErr != io.EOF {
		return nil, E.Cause(trailingErr, "VPN configuration contains trailing XML data")
	}
	if root.name.Local != "sslvpn-tunnel" {
		return nil, E.New("VPN configuration has no sslvpn-tunnel root")
	}
	configuration := &fortinetTunnelConfiguration{
		configuration: TunnelConfiguration{MTU: pppDefaultTunnelMTU},
	}
	if dtlsValue, loaded := root.attribute("dtls"); loaded {
		dtlsEnabled, parseErr := parseFortinetBoolean(dtlsValue)
		if parseErr != nil {
			return nil, E.Cause(parseErr, "parse Fortinet DTLS enablement")
		}
		configuration.dtlsEnabled = dtlsEnabled
	}
	var ipv4IncludeRoutes int
	for childIndex := range root.children {
		child := &root.children[childIndex]
		switch child.name.Local {
		case "dtls-config":
			intervalValue, loaded := child.attribute("heartbeat-interval")
			if loaded {
				interval, parseErr := parseFortinetDurationSeconds(intervalValue)
				if parseErr != nil {
					return nil, E.Cause(parseErr, "parse Fortinet heartbeat interval")
				}
				configuration.echoInterval = interval
			}
		case "idle-timeout":
			value, loaded := child.attribute("val")
			if loaded {
				idleTimeout, parseErr := parseFortinetDurationSeconds(value)
				if parseErr != nil {
					return nil, E.Cause(parseErr, "parse Fortinet idle timeout")
				}
				configuration.configuration.IdleTimeout = idleTimeout
			}
		case "auth-timeout":
			value, loaded := child.attribute("val")
			if loaded {
				authenticationTimeout, parseErr := parseFortinetDurationSeconds(value)
				if parseErr != nil {
					return nil, E.Cause(parseErr, "parse Fortinet authentication timeout")
				}
				if authenticationTimeout > 0 {
					configuration.configuration.AuthenticationExpiration = now.Add(authenticationTimeout)
				}
			}
		case "auth-ses":
			parseErr := parseFortinetReconnectPolicy(child, configuration)
			if parseErr != nil {
				return nil, parseErr
			}
		case "fos":
			configuration.platform = formatFortinetPlatform(child)
		case "ipv4":
			includeCount, parseErr := parseFortinetIPSection(child, false, configuration)
			if parseErr != nil {
				return nil, parseErr
			}
			ipv4IncludeRoutes += includeCount
		case "ipv6":
			_, parseErr := parseFortinetIPSection(child, true, configuration)
			if parseErr != nil {
				return nil, parseErr
			}
		}
	}
	if configuration.wantIPv4 && ipv4IncludeRoutes == 0 {
		configuration.configuration.Routes = append(configuration.configuration.Routes, TunnelRoute{
			Prefix: netip.PrefixFrom(netip.IPv4Unspecified(), 0),
		})
	}
	if !configuration.wantIPv4 && !configuration.wantIPv6 {
		return nil, E.New("VPN configuration enables no usable network family")
	}
	return configuration, nil
}

func parseFortinetReconnectPolicy(node *fortinetXMLNode, configuration *fortinetTunnelConfiguration) error {
	value, loaded := node.attribute("tun-connect-without-reauth")
	if !loaded {
		return nil
	}
	allowed, parseErr := parseFortinetBoolean(value)
	if parseErr != nil {
		return E.Cause(parseErr, "parse Fortinet reconnect permission")
	}
	configuration.reconnectAllowed = allowed
	if !allowed {
		return nil
	}
	if checkValue, checkLoaded := node.attribute("check-src-ip"); checkLoaded {
		checkSourceIP, checkErr := parseFortinetBoolean(checkValue)
		if checkErr != nil {
			return E.Cause(checkErr, "parse Fortinet reconnect source-IP policy")
		}
		configuration.checkSourceIP = checkSourceIP
	}
	timeoutValue, timeoutLoaded := node.attribute("tun-user-ses-timeout")
	if !timeoutLoaded {
		configuration.reconnectAllowed = false
		return nil
	}
	cleanupTimeout, timeoutErr := parseFortinetDurationSeconds(timeoutValue)
	if timeoutErr != nil {
		return E.Cause(timeoutErr, "parse Fortinet reconnect cleanup timeout")
	}
	if cleanupTimeout == 0 {
		configuration.reconnectAllowed = false
		return nil
	}
	configuration.cleanupTimeout = cleanupTimeout
	return nil
}

func parseFortinetIPSection(
	node *fortinetXMLNode,
	ipv6 bool,
	configuration *fortinetTunnelConfiguration,
) (int, error) {
	includeRoutes := 0
	for childIndex := range node.children {
		child := &node.children[childIndex]
		switch child.name.Local {
		case "assigned-addr":
			prefix, parseErr := parseFortinetAssignedAddress(child, ipv6)
			if parseErr != nil {
				return 0, parseErr
			}
			if ipv6 {
				configuration.wantIPv6 = true
				configuration.proposedIPv6 = prefix
			} else {
				configuration.wantIPv4 = true
				configuration.proposedIPv4 = prefix
			}
		case "dns":
			parseErr := parseFortinetDNS(child, ipv6, configuration)
			if parseErr != nil {
				return 0, parseErr
			}
		case "split-dns":
			rule, parseErr := parseFortinetSplitDNS(child, ipv6)
			if parseErr != nil {
				return 0, parseErr
			}
			configuration.configuration.SplitDNSRules = append(configuration.configuration.SplitDNSRules, rule)
		case "split-tunnel-info":
			negate := false
			negateValue, loaded := child.attribute("negate")
			if loaded {
				parsedNegate, parseErr := parseFortinetBoolean(negateValue)
				if parseErr != nil {
					return 0, E.Cause(parseErr, "parse Fortinet route negate flag")
				}
				negate = parsedNegate
			}
			for addressIndex := range child.children {
				addressNode := &child.children[addressIndex]
				if addressNode.name.Local != "addr" {
					continue
				}
				prefix, parseErr := parseFortinetRoute(addressNode, ipv6)
				if parseErr != nil {
					return 0, parseErr
				}
				route := TunnelRoute{Prefix: prefix}
				if negate {
					configuration.configuration.ExcludedRoutes = append(configuration.configuration.ExcludedRoutes, route)
				} else {
					configuration.configuration.Routes = append(configuration.configuration.Routes, route)
					includeRoutes++
				}
			}
		}
	}
	return includeRoutes, nil
}

func parseFortinetAssignedAddress(node *fortinetXMLNode, ipv6 bool) (netip.Prefix, error) {
	attributeName := "ipv4"
	bits := 32
	if ipv6 {
		attributeName = "ipv6"
		bits = 128
	}
	value, loaded := node.attribute(attributeName)
	if !loaded || strings.TrimSpace(value) == "" {
		return netip.Prefix{}, E.New("assigned address is empty")
	}
	address, parseErr := netip.ParseAddr(strings.TrimSpace(value))
	if parseErr != nil || address.Is6() != ipv6 || ipv6 && address.Is4In6() {
		return netip.Prefix{}, E.New("assigned address is invalid: ", value)
	}
	if ipv6 {
		prefixValue, prefixLoaded := node.attribute("prefix-len")
		if prefixLoaded {
			parsedBits, bitsErr := strconv.Atoi(prefixValue)
			if bitsErr != nil || parsedBits < 0 || parsedBits > 128 {
				return netip.Prefix{}, E.New("assigned IPv6 prefix is invalid: ", prefixValue)
			}
			bits = parsedBits
		}
	}
	return netip.PrefixFrom(address.Unmap(), bits), nil
}

func parseFortinetDNS(
	node *fortinetXMLNode,
	ipv6 bool,
	configuration *fortinetTunnelConfiguration,
) error {
	if domain, loaded := node.attribute("domain"); loaded && strings.TrimSpace(domain) != "" {
		configuration.configuration.SearchDomains = append(configuration.configuration.SearchDomains, strings.TrimSpace(domain))
	}
	attributeName := "ip"
	if ipv6 {
		attributeName = "ipv6"
	}
	value, loaded := node.attribute(attributeName)
	if !loaded || strings.TrimSpace(value) == "" {
		return nil
	}
	address, parseErr := netip.ParseAddr(strings.TrimSpace(value))
	if parseErr != nil || address.Is6() != ipv6 || ipv6 && address.Is4In6() {
		return E.New("DNS address is invalid: ", value)
	}
	if len(configuration.configuration.DNS) < 3 {
		configuration.configuration.DNS = append(configuration.configuration.DNS, address.Unmap())
	}
	return nil
}

func parseFortinetSplitDNS(node *fortinetXMLNode, ipv6 bool) (TunnelSplitDNSRule, error) {
	domainsValue, domainsLoaded := node.attribute("domains")
	if !domainsLoaded || strings.TrimSpace(domainsValue) == "" {
		return TunnelSplitDNSRule{}, E.New("split-DNS rule omitted domains")
	}
	var rule TunnelSplitDNSRule
	domainSet := make(map[string]struct{})
	for domain := range strings.SplitSeq(domainsValue, ",") {
		domain = strings.TrimSpace(domain)
		if domain == "" {
			return TunnelSplitDNSRule{}, E.New("split-DNS rule contains an empty domain")
		}
		if _, exists := domainSet[domain]; exists {
			continue
		}
		domainSet[domain] = struct{}{}
		rule.Domains = append(rule.Domains, domain)
	}
	indexedServers := make(map[int]string)
	highestNonemptyServer := 0
	for _, attribute := range node.attributes {
		if !strings.HasPrefix(attribute.Name.Local, "dnsserver") {
			continue
		}
		index, parseErr := strconv.Atoi(strings.TrimPrefix(attribute.Name.Local, "dnsserver"))
		if parseErr != nil || index < 1 || index > 9 {
			return TunnelSplitDNSRule{}, E.New("split-DNS server attribute is invalid: ", attribute.Name.Local)
		}
		if _, exists := indexedServers[index]; exists {
			return TunnelSplitDNSRule{}, E.New("duplicate Fortinet split-DNS server attribute: ", attribute.Name.Local)
		}
		value := strings.TrimSpace(attribute.Value)
		indexedServers[index] = value
		if value != "" && index > highestNonemptyServer {
			highestNonemptyServer = index
		}
	}
	serverSet := make(map[netip.Addr]struct{})
	for serverIndex := 1; serverIndex <= highestNonemptyServer; serverIndex++ {
		serverValue, exists := indexedServers[serverIndex]
		if !exists || serverValue == "" {
			return TunnelSplitDNSRule{}, E.New("split-DNS servers are empty or non-contiguous")
		}
		address, parseErr := netip.ParseAddr(serverValue)
		if parseErr != nil || address.Is6() != ipv6 || ipv6 && address.Is4In6() {
			return TunnelSplitDNSRule{}, E.New("split-DNS server is invalid: ", serverValue)
		}
		address = address.Unmap()
		if _, exists := serverSet[address]; exists {
			continue
		}
		serverSet[address] = struct{}{}
		rule.Servers = append(rule.Servers, address)
	}
	if len(rule.Servers) == 0 {
		return TunnelSplitDNSRule{}, E.New("split-DNS rule omitted dedicated servers")
	}
	return rule, nil
}

func parseFortinetRoute(node *fortinetXMLNode, ipv6 bool) (netip.Prefix, error) {
	if ipv6 {
		addressValue, addressLoaded := node.attribute("ipv6")
		prefixValue, prefixLoaded := node.attribute("prefix-len")
		if !addressLoaded || !prefixLoaded {
			return netip.Prefix{}, E.New("IPv6 route omitted address or prefix")
		}
		address, parseErr := netip.ParseAddr(strings.TrimSpace(addressValue))
		bits, bitsErr := strconv.Atoi(strings.TrimSpace(prefixValue))
		if parseErr != nil || !address.Is6() || address.Is4In6() || bitsErr != nil || bits < 0 || bits > 128 {
			return netip.Prefix{}, E.New("IPv6 route is invalid: ", addressValue, "/", prefixValue)
		}
		return netip.PrefixFrom(address, bits).Masked(), nil
	}
	addressValue, addressLoaded := node.attribute("ip")
	maskValue, maskLoaded := node.attribute("mask")
	if !addressLoaded || !maskLoaded {
		return netip.Prefix{}, E.New("IPv4 route omitted address or mask")
	}
	address, parseErr := netip.ParseAddr(strings.TrimSpace(addressValue))
	maskAddress, maskErr := netip.ParseAddr(strings.TrimSpace(maskValue))
	if parseErr != nil || !address.Is4() || maskErr != nil || !maskAddress.Is4() {
		return netip.Prefix{}, E.New("IPv4 route is invalid: ", addressValue, "/", maskValue)
	}
	maskBytes := maskAddress.As4()
	bits, width := net.IPMask(maskBytes[:]).Size()
	if width != 32 || bits < 0 {
		return netip.Prefix{}, E.New("IPv4 route mask is not contiguous: ", maskValue)
	}
	return netip.PrefixFrom(address, bits).Masked(), nil
}

func (n *fortinetXMLNode) attribute(name string) (string, bool) {
	for _, attribute := range n.attributes {
		if attribute.Name.Local == name {
			return attribute.Value, true
		}
	}
	return "", false
}

func parseFortinetBoolean(value string) (bool, error) {
	switch strings.TrimSpace(value) {
	case "0":
		return false, nil
	case "1":
		return true, nil
	default:
		return false, E.New("invalid Fortinet boolean: ", value)
	}
}

func parseFortinetNonnegativeInteger(value string) (int64, error) {
	parsed, parseErr := strconv.ParseInt(strings.TrimSpace(value), 10, 63)
	if parseErr != nil || parsed < 0 {
		return 0, E.New("invalid Fortinet nonnegative integer: ", value)
	}
	return parsed, nil
}

func parseFortinetDurationSeconds(value string) (time.Duration, error) {
	seconds, parseErr := parseFortinetNonnegativeInteger(value)
	if parseErr != nil {
		return 0, parseErr
	}
	if seconds > math.MaxInt64/int64(time.Second) {
		return 0, E.New("duration exceeds time.Duration: ", value)
	}
	return time.Duration(seconds) * time.Second, nil
}

func formatFortinetPlatform(node *fortinetXMLNode) string {
	platform, _ := node.attribute("platform")
	var builder strings.Builder
	builder.WriteString(platform)
	for _, component := range []struct {
		name   string
		prefix string
	}{
		{name: "major", prefix: " v"},
		{name: "minor", prefix: "."},
		{name: "patch", prefix: "."},
		{name: "build", prefix: " build "},
		{name: "branch", prefix: " branch "},
		{name: "mr_num", prefix: " mr_num "},
	} {
		value, loaded := node.attribute(component.name)
		if loaded {
			builder.WriteString(component.prefix)
			builder.WriteString(value)
		}
	}
	return strings.TrimSpace(builder.String())
}

func fortinetCookieValue(jar http.CookieJar, requestURL *url.URL) (string, bool) {
	if jar == nil || requestURL == nil {
		return "", false
	}
	for _, cookie := range jar.Cookies(requestURL) {
		if cookie.Name == "SVPNCOOKIE" && cookie.Value != "" {
			return cookie.Value, true
		}
	}
	return "", false
}

func buildFortinetTLSConnectRequest(requestURL *url.URL, jar http.CookieJar, userAgent string) ([]byte, error) {
	port, portErr := fortinetURLPort(requestURL)
	if portErr != nil {
		return nil, portErr
	}
	hostHeader := requestURL.Hostname()
	if port != 443 {
		hostHeader = net.JoinHostPort(requestURL.Hostname(), strconv.Itoa(int(port)))
	} else if strings.Contains(hostHeader, ":") {
		hostHeader = "[" + hostHeader + "]"
	}
	if strings.ContainsAny(hostHeader, "\r\n") {
		return nil, E.New("tunnel Host contains a line break")
	}
	cookies := jar.Cookies(requestURL)
	if len(cookies) == 0 {
		return nil, E.New("tunnel request has no cookies")
	}
	var builder strings.Builder
	builder.WriteString("GET /remote/sslvpn-tunnel HTTP/1.1\r\nHost: ")
	builder.WriteString(hostHeader)
	builder.WriteString("\r\nUser-Agent: ")
	builder.WriteString(userAgent)
	builder.WriteString("\r\nCookie: ")
	for cookieIndex, cookie := range cookies {
		if cookie.Name == "" || strings.ContainsAny(cookie.Name+cookie.Value, "\r\n;") {
			return nil, E.New("tunnel cookie contains invalid request characters")
		}
		if cookieIndex > 0 {
			builder.WriteString("; ")
		}
		builder.WriteString(cookie.Name)
		builder.WriteByte('=')
		builder.WriteString(cookie.Value)
	}
	builder.WriteString("\r\n\r\n")
	return []byte(builder.String()), nil
}

func buildFortinetDTLSConnectRequest(cookie string) ([]byte, error) {
	if cookie == "" || strings.IndexByte(cookie, 0) >= 0 {
		return nil, E.New("DTLS cookie is empty or contains NUL")
	}
	prefix := []byte("GFtype\x00clthello\x00SVPNCOOKIE\x00")
	totalLength := 2 + len(prefix) + len(cookie) + 1
	if totalLength > 65535 {
		return nil, E.New("DTLS client hello exceeds its length field")
	}
	request := make([]byte, totalLength)
	binary.BigEndian.PutUint16(request[:2], uint16(totalLength))
	copy(request[2:], prefix)
	copy(request[2+len(prefix):], cookie)
	return request, nil
}
