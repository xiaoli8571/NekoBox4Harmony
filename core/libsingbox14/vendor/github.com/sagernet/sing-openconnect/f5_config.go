package openconnect

import (
	"bytes"
	"context"
	"encoding/base64"
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

const f5ConfigurationClientVersion = "2.0"

type f5TunnelConfiguration struct {
	configuration  TunnelConfiguration
	connectRequest []byte
	sessionID      string
	urZ            string
	wantIPv4       bool
	wantIPv6       bool
	hdlc           bool
	dtlsEnabled    bool
	dtlsPort       uint16
	dtls12         bool
}

type f5ProfileDocument struct {
	XMLName   xml.Name            `xml:"favorites"`
	Type      string              `xml:"type,attr"`
	Favorites []f5ProfileFavorite `xml:"favorite"`
}

type f5ProfileFavorite struct {
	Params string `xml:"params"`
}

type f5OptionsDocument struct {
	XMLName xml.Name          `xml:"favorite"`
	Objects []f5OptionsObject `xml:"object"`
}

type f5OptionsObject struct {
	Fields []f5OptionsField `xml:",any"`
}

type f5OptionsField struct {
	XMLName xml.Name
	Value   string `xml:",chardata"`
}

func (s *f5SessionState) loadConfiguration(ctx context.Context) (*f5TunnelConfiguration, error) {
	s.configurationOnce.Do(func() {
		snapshot := s.snapshot()
		if !snapshot.authenticationExpiration.IsZero() && !time.Now().Before(snapshot.authenticationExpiration) {
			s.configurationErr = ErrSessionRejected
			return
		}
		configuration, configurationErr := s.frontend.fetchTunnelConfiguration(ctx, snapshot)
		if configurationErr != nil && classifyClientSessionError(configurationErr) != clientSessionErrorTerminal {
			configurationErr = E.Errors(ErrSessionRejected, configurationErr)
		}
		if configurationErr == nil && configuration != nil {
			s.access.Lock()
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

func (f *f5Frontend) fetchTunnelConfiguration(
	ctx context.Context,
	snapshot f5SessionSnapshot,
) (*f5TunnelConfiguration, error) {
	httpClient, transport, peer, clientErr := f.newPinnedHTTPClient(snapshot)
	if clientErr != nil {
		return nil, clientErr
	}
	defer transport.CloseIdleConnections()
	profileURL := cloneF5URL(snapshot.serverURL)
	profileURL.Path = "/vdesk/vpn/index.php3"
	profileURL.RawPath = ""
	profileURL.RawQuery = "outform=xml&client_version=" + f5ConfigurationClientVersion
	profileBody, profileErr := f.doConfigurationRequest(ctx, httpClient, profileURL, "profile")
	if profileErr != nil {
		return nil, profileErr
	}
	profileParameters, parseProfileErr := parseF5Profile(profileBody)
	if parseProfileErr != nil {
		return nil, markTerminal(parseProfileErr)
	}
	if strings.ContainsAny(profileParameters, "\r\n#") {
		return nil, markTerminal(E.New("profile parameters contain invalid request characters"))
	}
	optionsURL := cloneF5URL(snapshot.serverURL)
	optionsURL.Path = "/vdesk/vpn/connect.php3"
	optionsURL.RawPath = ""
	optionsURL.RawQuery = profileParameters + "&outform=xml&client_version=" + f5ConfigurationClientVersion
	optionsBody, optionsErr := f.doConfigurationRequest(ctx, httpClient, optionsURL, "options")
	if optionsErr != nil {
		return nil, optionsErr
	}
	configuration, parseOptionsErr := parseF5Options(optionsBody, snapshot.authenticationExpiration)
	if parseOptionsErr != nil {
		return nil, markTerminal(parseOptionsErr)
	}
	if f.client.options.IPv6Disabled {
		configuration.wantIPv6 = false
		if !configuration.wantIPv4 {
			return nil, markTerminal(E.New("server did not provide IPv4 tunnel configuration"))
		}
	}
	acceptedAddress := peer.address
	if !acceptedAddress.IsValid() {
		return nil, markTerminal(E.New("configuration endpoint did not expose an accepted IP address"))
	}
	encapsulation := pppEncapsulationF5
	if configuration.hdlc {
		encapsulation = pppEncapsulationF5HDLC
	}
	configuration.configuration.MTU = calculatePPPTunnelMTU(
		f.client.options.MTU,
		f.client.options.BaseMTU,
		acceptedAddress.Is6(),
		encapsulation,
	)
	ipv6Disabled := f.client.options.IPv6Disabled || configuration.configuration.MTU < minimumIPv6MTU
	if ipv6Disabled {
		configuration.wantIPv6 = false
		if !configuration.wantIPv4 {
			return nil, markTerminal(E.New("calculated tunnel MTU is too small for the server's IPv6-only configuration"))
		}
	}
	configuration.configuration.RemoteAddress = acceptedAddress.Unmap()
	configuration.configuration = normalizeTunnelConfiguration(
		configuration.configuration,
		ipv6Disabled,
	)
	connectRequest, buildErr := buildF5ConnectRequest(f.client, snapshot.serverURL, f.localHostname, configuration)
	if buildErr != nil {
		return nil, markTerminal(buildErr)
	}
	configuration.connectRequest = connectRequest
	return configuration, nil
}

func (f *f5Frontend) doConfigurationRequest(
	ctx context.Context,
	httpClient *http.Client,
	requestURL *url.URL,
	description string,
) ([]byte, error) {
	request, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if requestErr != nil {
		return nil, E.Cause(requestErr, "create F5 ", description, " request")
	}
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", f5UserAgent(f.client))
	response, responseErr := httpClient.Do(request)
	if responseErr != nil {
		return nil, E.Cause(responseErr, "send F5 ", description, " request")
	}
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, f5MaximumAuthenticationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return nil, E.Errors(E.Cause(readErr, "read F5 ", description, " response"), closeErr)
	}
	if closeErr != nil {
		return nil, E.Cause(closeErr, "close F5 ", description, " response")
	}
	if len(responseBody) > f5MaximumAuthenticationBody {
		return nil, markTerminal(E.New(description, " response exceeds ", f5MaximumAuthenticationBody, " bytes"))
	}
	if isF5RedirectStatus(response.StatusCode) || response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
		return nil, ErrSessionRejected
	}
	if response.StatusCode != http.StatusOK {
		return nil, E.New(description, " returned HTTP ", response.StatusCode)
	}
	return responseBody, nil
}

func parseF5Profile(content []byte) (string, error) {
	var profile f5ProfileDocument
	decodeErr := xml.Unmarshal(bytes.TrimSpace(content), &profile)
	if decodeErr != nil {
		return "", E.Cause(decodeErr, "decode F5 VPN profile XML")
	}
	if profile.XMLName.Local != "favorites" || profile.Type != "VPN" {
		return "", E.New("VPN profile has no VPN favorites root")
	}
	for _, favorite := range profile.Favorites {
		parameters := strings.TrimSpace(favorite.Params)
		if parameters != "" {
			return parameters, nil
		}
	}
	return "", E.New("VPN profile has no favorite parameters")
}

func parseF5Options(content []byte, authenticationExpiration time.Time) (*f5TunnelConfiguration, error) {
	structureErr := validateF5OptionsStructure(content)
	if structureErr != nil {
		return nil, structureErr
	}
	var document f5OptionsDocument
	decodeErr := xml.Unmarshal(bytes.TrimSpace(content), &document)
	if decodeErr != nil {
		return nil, E.Cause(decodeErr, "decode F5 VPN options XML")
	}
	if document.XMLName.Local != "favorite" || len(document.Objects) == 0 {
		return nil, E.New("VPN options has no favorite object")
	}
	configuration := &f5TunnelConfiguration{
		configuration: TunnelConfiguration{
			MTU:                      pppDefaultTunnelMTU,
			AuthenticationExpiration: authenticationExpiration,
		},
	}
	defaultRoute := false
	dtlsAdvertised := false
	var dnsCount int
	var nbnsCount int
	for _, field := range document.Objects[0].Fields {
		name := field.XMLName.Local
		value := strings.TrimSpace(field.Value)
		switch name {
		case "ur_Z":
			configuration.urZ = value
		case "Session_ID":
			configuration.sessionID = value
		case "IPV4_0":
			parsed, parseErr := parseF5Boolean(value)
			if parseErr != nil {
				return nil, E.Cause(parseErr, "parse F5 IPv4 enablement")
			}
			configuration.wantIPv4 = parsed
		case "IPV6_0":
			parsed, parseErr := parseF5Boolean(value)
			if parseErr != nil {
				return nil, E.Cause(parseErr, "parse F5 IPv6 enablement")
			}
			configuration.wantIPv6 = parsed
		case "hdlc_framing":
			parsed, parseErr := parseF5Boolean(value)
			if parseErr != nil {
				return nil, E.Cause(parseErr, "parse F5 HDLC enablement")
			}
			configuration.hdlc = parsed
		case "idle_session_timeout":
			seconds, parseErr := parseF5NonnegativeInteger(value)
			if parseErr != nil {
				return nil, E.Cause(parseErr, "parse F5 idle timeout")
			}
			if seconds > math.MaxInt64/int64(time.Second) {
				return nil, E.New("idle timeout exceeds supported duration")
			}
			configuration.configuration.IdleTimeout = time.Duration(seconds) * time.Second
		case "tunnel_dtls":
			parsed, parseErr := parseF5Boolean(value)
			if parseErr != nil {
				return nil, E.Cause(parseErr, "parse F5 DTLS enablement")
			}
			dtlsAdvertised = parsed
		case "tunnel_port_dtls":
			if value == "" {
				configuration.dtlsPort = 0
				break
			}
			port, parseErr := strconv.ParseUint(value, 10, 16)
			if parseErr != nil {
				return nil, E.New("DTLS port is invalid: ", value)
			}
			configuration.dtlsPort = uint16(port)
		case "dtls_v1_2_supported":
			parsed, parseErr := parseF5Boolean(value)
			if parseErr != nil {
				return nil, E.Cause(parseErr, "parse F5 DTLS 1.2 support")
			}
			configuration.dtls12 = parsed
		case "UseDefaultGateway0":
			parsed, parseErr := parseF5Boolean(value)
			if parseErr != nil {
				return nil, E.Cause(parseErr, "parse F5 default gateway")
			}
			defaultRoute = parsed
		default:
			switch {
			case isF5IndexedName(name, "DNS") || isF5IndexedName(name, "DNS6_"):
				if value != "" && dnsCount < 3 {
					address, parseErr := netip.ParseAddr(value)
					if parseErr != nil {
						return nil, E.Cause(parseErr, "parse F5 DNS address")
					}
					configuration.configuration.DNS = append(configuration.configuration.DNS, address.Unmap())
					dnsCount++
				}
			case isF5IndexedName(name, "WINS"):
				if value != "" && nbnsCount < 3 {
					address, parseErr := netip.ParseAddr(value)
					if parseErr != nil {
						return nil, E.Cause(parseErr, "parse F5 NBNS address")
					}
					configuration.configuration.NBNS = append(configuration.configuration.NBNS, address.Unmap())
					nbnsCount++
				}
			case isF5IndexedName(name, "DNSSuffix"):
				if value != "" {
					configuration.configuration.SearchDomains = append(configuration.configuration.SearchDomains, value)
				}
			case isF5IndexedName(name, "DNS_SPLIT"):
				configuration.configuration.SplitDNS = append(configuration.configuration.SplitDNS, strings.Fields(value)...)
			case isF5IndexedName(name, "LAN") || isF5IndexedName(name, "LAN6_"):
				routes, parseErr := parseF5Routes(value)
				if parseErr != nil {
					return nil, E.Cause(parseErr, "parse F5 include routes")
				}
				configuration.configuration.Routes = append(configuration.configuration.Routes, routes...)
			case isF5IndexedName(name, "ExcludeSubnets") || isF5IndexedName(name, "ExcludeSubnets6_"):
				routes, parseErr := parseF5Routes(value)
				if parseErr != nil {
					return nil, E.Cause(parseErr, "parse F5 exclude routes")
				}
				configuration.configuration.ExcludedRoutes = append(configuration.configuration.ExcludedRoutes, routes...)
			}
		}
	}
	if configuration.sessionID == "" || configuration.urZ == "" {
		return nil, E.New("VPN options is missing Session_ID or ur_Z")
	}
	if !configuration.wantIPv4 && !configuration.wantIPv6 {
		return nil, E.New("VPN options enables no network family")
	}
	if defaultRoute {
		if configuration.wantIPv4 {
			configuration.configuration.Routes = append(configuration.configuration.Routes, TunnelRoute{Prefix: netip.PrefixFrom(netip.IPv4Unspecified(), 0)})
		}
		if configuration.wantIPv6 {
			configuration.configuration.Routes = append(configuration.configuration.Routes, TunnelRoute{Prefix: netip.PrefixFrom(netip.IPv6Unspecified(), 0)})
		}
	} else {
		configuration.configuration.defaultIPv4RouteSuppressed = configuration.wantIPv4
		configuration.configuration.defaultIPv6RouteSuppressed = configuration.wantIPv6
	}
	configuration.dtlsEnabled = dtlsAdvertised && configuration.dtlsPort != 0 && !configuration.hdlc
	return configuration, nil
}

func validateF5OptionsStructure(content []byte) error {
	decoder := xml.NewDecoder(bytes.NewReader(bytes.TrimSpace(content)))
	rootFound := false
	for {
		token, tokenErr := decoder.Token()
		if tokenErr != nil {
			if tokenErr == io.EOF {
				break
			}
			return E.Cause(tokenErr, "decode F5 VPN options structure")
		}
		switch typedToken := token.(type) {
		case xml.StartElement:
			if !rootFound {
				if typedToken.Name.Local != "favorite" {
					return E.New("VPN options root is not favorite")
				}
				rootFound = true
				continue
			}
			if typedToken.Name.Local != "object" {
				return E.New("VPN options first favorite child is not object")
			}
			return nil
		case xml.EndElement:
			if rootFound && typedToken.Name.Local == "favorite" {
				return E.New("VPN options favorite has no object")
			}
		}
	}
	return E.New("VPN options document is empty")
}

func buildF5ConnectRequest(
	client *Client,
	serverURL *url.URL,
	localHostname string,
	configuration *f5TunnelConfiguration,
) ([]byte, error) {
	if serverURL == nil || configuration == nil {
		return nil, E.New("connect request requires an endpoint and configuration")
	}
	userAgent := f5UserAgent(client)
	for name, value := range map[string]string{
		"session ID":     configuration.sessionID,
		"ur_Z":           configuration.urZ,
		"local hostname": localHostname,
		"user agent":     userAgent,
	} {
		if strings.ContainsAny(value, "\r\n") {
			return nil, E.New("connect ", name, " contains a line break")
		}
	}
	port, portErr := f5URLPort(serverURL)
	if portErr != nil {
		return nil, portErr
	}
	hostHeader := serverURL.Hostname()
	if port != 443 {
		hostHeader = net.JoinHostPort(serverURL.Hostname(), strconv.Itoa(int(port)))
	} else if strings.Contains(hostHeader, ":") {
		hostHeader = "[" + hostHeader + "]"
	}
	hdlcValue := "no"
	if configuration.hdlc {
		hdlcValue = "yes"
	}
	ipv4Value := "no"
	if configuration.wantIPv4 {
		ipv4Value = "yes"
	}
	ipv6Value := "no"
	if configuration.wantIPv6 {
		ipv6Value = "yes"
	}
	var request strings.Builder
	request.WriteString("GET /myvpn?sess=")
	request.WriteString(configuration.sessionID)
	request.WriteString("&hdlc_framing=")
	request.WriteString(hdlcValue)
	request.WriteString("&ipv4=")
	request.WriteString(ipv4Value)
	request.WriteString("&ipv6=")
	request.WriteString(ipv6Value)
	request.WriteString("&Z=")
	request.WriteString(configuration.urZ)
	request.WriteString("&hostname=")
	request.WriteString(base64.StdEncoding.EncodeToString([]byte(localHostname)))
	request.WriteString(" HTTP/1.1\r\nHost: ")
	request.WriteString(hostHeader)
	request.WriteString("\r\nUser-Agent: ")
	request.WriteString(userAgent)
	request.WriteString("\r\n\r\n")
	return []byte(request.String()), nil
}

func parseF5Boolean(value string) (bool, error) {
	normalized := strings.ToLower(strings.TrimSpace(value))
	switch normalized {
	case "1", "yes", "true", "on":
		return true, nil
	case "", "0", "no", "false", "off":
		return false, nil
	default:
		integer, parseErr := strconv.ParseInt(normalized, 10, 64)
		if parseErr == nil {
			return integer != 0, nil
		}
		return false, E.New("invalid F5 boolean value: ", value)
	}
}

func parseF5NonnegativeInteger(value string) (int64, error) {
	integer, parseErr := strconv.ParseInt(strings.TrimSpace(value), 10, 63)
	if parseErr != nil || integer < 0 {
		return 0, E.New("invalid F5 nonnegative integer: ", value)
	}
	return integer, nil
}

func isF5IndexedName(name string, prefix string) bool {
	if !strings.HasPrefix(name, prefix) || len(name) == len(prefix) {
		return false
	}
	return name[len(prefix)] >= '0' && name[len(prefix)] <= '9'
}

func parseF5Routes(value string) ([]TunnelRoute, error) {
	words := strings.Fields(value)
	routes := make([]TunnelRoute, 0, len(words))
	for _, word := range words {
		prefix, parseErr := netip.ParsePrefix(word)
		if parseErr != nil {
			return nil, E.Cause(parseErr, "parse F5 route ", word)
		}
		routes = append(routes, TunnelRoute{Prefix: prefix.Masked()})
	}
	return routes, nil
}
