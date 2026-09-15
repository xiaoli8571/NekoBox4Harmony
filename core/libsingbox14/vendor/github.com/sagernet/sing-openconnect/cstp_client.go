package openconnect

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"net"
	"net/http"
	"net/netip"
	"net/textproto"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

const (
	cstpConnectTimeout         = 30 * time.Second
	cstpDefaultBaseMTU         = 1406
	cstpDTLSOverhead           = 82
	cstpLegacyMasterSecretSize = 48
	cstpMaximumMTU             = 65535
	cstpMaximumHeaderSize      = 1024 * 1024
	cstpMaximumStatusLineSize  = 8192
	cstpMaximumTimerSeconds    = (1<<63 - 1) / int64(2*time.Second)
)

type cstpDTLSOption struct {
	Suffix string
	Value  string
	DTLS12 bool
}

type cstpNegotiatedState struct {
	Configuration TunnelConfiguration
	Compression   anyConnectCompression
	DPD           time.Duration
	Keepalive     time.Duration
	Rekey         time.Duration
	RekeyMethod   cstpRekeyMethod
	DynamicDNS    bool
	DTLS          *cstpDTLSNegotiation
}

type cstpConnectedTransport struct {
	connection *tls.Conn
	reader     *bufio.Reader
	negotiated cstpNegotiatedState
}

// Upstream start_cstp_connection sends CONNECT /CSCOSSLC/tunnel on a new TLS connection with the webvpn cookie and CSTP/DTLS capability headers.
func connectCSTP(ctx context.Context, client *Client, session *anyConnectSessionState) (*cstpConnectedTransport, error) {
	session.access.Lock()
	sessionSnapshot := &anyConnectSessionState{
		ServerURL:            cloneAnyConnectURL(session.ServerURL),
		AuthenticatedAddress: session.AuthenticatedAddress,
		Cookie:               session.Cookie,
		PreviousAddresses:    append([]netip.Prefix(nil), session.PreviousAddresses...),
		DynamicDNS:           session.DynamicDNS,
	}
	session.access.Unlock()
	serverURL := sessionSnapshot.ServerURL
	port, err := anyConnectURLPort(serverURL)
	if err != nil {
		return nil, markTerminal(err)
	}
	destinationHost := serverURL.Hostname()
	dynamicDNS := sessionSnapshot.DynamicDNS && sessionSnapshot.AuthenticatedAddress.IsValid()
	if sessionSnapshot.AuthenticatedAddress.IsValid() && !dynamicDNS {
		destinationHost = sessionSnapshot.AuthenticatedAddress.String()
	}
	destination := M.ParseSocksaddrHostPort(destinationHost, port)
	dialer := client.options.Dialer
	rawConnection, err := dialer.DialContext(ctx, N.NetworkTCP, destination)
	if err != nil && dynamicDNS {
		dynamicDNSError := E.Cause(err, "connect dynamic AnyConnect CSTP TCP transport")
		fallbackDestination := M.ParseSocksaddrHostPort(sessionSnapshot.AuthenticatedAddress.String(), port)
		rawConnection, err = dialer.DialContext(ctx, N.NetworkTCP, fallbackDestination)
		if err != nil {
			return nil, E.Errors(dynamicDNSError, E.Cause(err, "connect cached AnyConnect CSTP TCP transport"))
		}
		dynamicDNS = false
	}
	if err != nil {
		return nil, E.Cause(err, "connect AnyConnect CSTP TCP transport")
	}
	if dynamicDNS {
		remoteHost, _, splitErr := net.SplitHostPort(rawConnection.RemoteAddr().String())
		if splitErr == nil {
			remoteAddress, parseErr := netip.ParseAddr(remoteHost)
			if parseErr == nil {
				sessionSnapshot.AuthenticatedAddress = remoteAddress
				session.access.Lock()
				session.AuthenticatedAddress = remoteAddress
				session.access.Unlock()
			}
		}
	}
	setupComplete := false
	defer func() {
		if !setupComplete {
			_ = rawConnection.Close()
		}
	}()
	stopCancellation := context.AfterFunc(ctx, func() {
		_ = rawConnection.Close()
	})
	defer stopCancellation()
	deadline := time.Now().Add(cstpConnectTimeout)
	if contextDeadline, hasDeadline := ctx.Deadline(); hasDeadline && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	err = rawConnection.SetDeadline(deadline)
	if err != nil {
		return nil, E.Cause(err, "set CSTP connection deadline")
	}
	tlsConfiguration := client.tlsConfig.Clone()
	if tlsConfiguration.ServerName == "" {
		tlsConfiguration.ServerName = serverURL.Hostname()
	}
	tlsConfiguration.NextProtos = []string{"http/1.1"}
	tlsConnection := tls.Client(rawConnection, tlsConfiguration)
	err = tlsConnection.HandshakeContext(ctx)
	if err != nil {
		return nil, E.Cause(err, "handshake AnyConnect CSTP TLS")
	}
	masterSecret := make([]byte, cstpLegacyMasterSecretSize)
	if !client.options.NoUDP {
		_, err = rand.Read(masterSecret)
		if err != nil {
			return nil, E.Cause(err, "generate AnyConnect legacy DTLS master secret")
		}
	}
	request, err := buildCSTPConnectRequest(client, sessionSnapshot, masterSecret, rawConnection.RemoteAddr())
	if err != nil {
		return nil, markTerminal(err)
	}
	err = writeCSTPBytes(tlsConnection, request)
	if err != nil {
		return nil, err
	}
	reader := bufio.NewReader(tlsConnection)
	statusLine, err := readCSTPHTTPStatusLine(reader)
	if err != nil {
		return nil, E.Cause(err, "read CSTP HTTP status")
	}
	statusCode, err := parseCSTPStatusLine(statusLine)
	if err != nil {
		return nil, markTerminal(err)
	}
	headers, dtlsOptions, err := readCSTPResponseHeaders(reader)
	if err != nil {
		return nil, E.Cause(err, "read CSTP HTTP headers")
	}
	if statusCode == http.StatusUnauthorized || statusCode == http.StatusForbidden {
		return nil, ErrSessionRejected
	}
	if statusCode != http.StatusOK {
		reason := headers.Get("X-Reason")
		var rejection error
		if reason != "" {
			rejection = E.New("CSTP CONNECT rejected with HTTP ", statusCode, ": ", reason)
		} else {
			rejection = E.New("CSTP CONNECT rejected with HTTP ", statusCode)
		}
		if anyConnectRetryableHTTPStatus(statusCode) {
			return nil, rejection
		}
		return nil, markTerminal(E.Errors(ErrProtocolNotSupported, rejection))
	}
	connectedAddress := parseAnyConnectRemoteAddress(rawConnection.RemoteAddr())
	if connectedAddress.IsValid() {
		sessionSnapshot.AuthenticatedAddress = connectedAddress
	}
	negotiated, err := parseCSTPResponse(headers, dtlsOptions, serverURL, sessionSnapshot.AuthenticatedAddress, masterSecret, client)
	if err != nil {
		return nil, markTerminal(err)
	}
	err = tlsConnection.SetDeadline(time.Time{})
	if err != nil {
		return nil, E.Cause(err, "clear CSTP connection deadline")
	}
	setupComplete = true
	return &cstpConnectedTransport{
		connection: tlsConnection,
		reader:     reader,
		negotiated: negotiated,
	}, nil
}

func readCSTPHTTPStatusLine(reader *bufio.Reader) (string, error) {
	var line strings.Builder
	for {
		fragment, err := reader.ReadSlice('\n')
		if line.Len()+len(fragment) > cstpMaximumStatusLineSize {
			return "", E.Extend(ErrProtocolNotSupported, "CSTP HTTP status line exceeds ", cstpMaximumStatusLineSize, " bytes")
		}
		line.Write(fragment)
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			return "", err
		}
		return line.String(), nil
	}
}

func readCSTPResponseHeaders(reader *bufio.Reader) (http.Header, []cstpDTLSOption, error) {
	var encodedHeaders strings.Builder
	lineLength := 0
	var previousByte byte
	var lastByte byte
	for {
		fragment, err := reader.ReadSlice('\n')
		if encodedHeaders.Len()+len(fragment) > cstpMaximumHeaderSize {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "CSTP HTTP headers exceed ", cstpMaximumHeaderSize, " bytes")
		}
		encodedHeaders.Write(fragment)
		lineLength += len(fragment)
		for _, character := range fragment {
			previousByte = lastByte
			lastByte = character
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			return nil, nil, err
		}
		if lineLength == 1 || (lineLength == 2 && previousByte == '\r' && lastByte == '\n') {
			break
		}
		lineLength = 0
		previousByte = 0
		lastByte = 0
	}
	headerText := encodedHeaders.String()
	mimeHeaders, err := textproto.NewReader(bufio.NewReader(strings.NewReader(headerText))).ReadMIMEHeader()
	if err != nil {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "invalid CSTP HTTP headers: ", err)
	}
	selectionReader := textproto.NewReader(bufio.NewReader(strings.NewReader(headerText)))
	var dtlsOptions []cstpDTLSOption
	for {
		line, readErr := selectionReader.ReadContinuedLine()
		if readErr != nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "invalid ordered CSTP HTTP headers: ", readErr)
		}
		if line == "" {
			break
		}
		nameContent, valueContent, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		name := strings.TrimSpace(nameContent)
		lowerName := strings.ToLower(name)
		var suffix string
		dtls12 := false
		if strings.HasPrefix(lowerName, "x-dtls-") {
			suffix = name[len("X-DTLS-"):]
		} else if strings.HasPrefix(lowerName, "x-dtls12-") {
			suffix = name[len("X-DTLS12-"):]
			dtls12 = true
		}
		if suffix != "" {
			dtlsOptions = append(dtlsOptions, cstpDTLSOption{
				Suffix: suffix,
				Value:  strings.TrimSpace(valueContent),
				DTLS12: dtls12,
			})
		}
	}
	return http.Header(mimeHeaders), dtlsOptions, nil
}

func buildCSTPConnectRequest(
	client *Client,
	session *anyConnectSessionState,
	masterSecret []byte,
	remoteAddress net.Addr,
) ([]byte, error) {
	serverURL := session.ServerURL
	userAgent := anyConnectUserAgent(client)
	localHostname := client.options.LocalHostname
	baseMTU, tunnelMTU := calculateCSTPRequestMTU(client.options.BaseMTU, client.options.MTU, remoteAddress)
	for name, value := range map[string]string{
		"server":         serverURL.Host,
		"user agent":     userAgent,
		"local hostname": localHostname,
		"webvpn cookie":  session.Cookie,
	} {
		if strings.ContainsAny(value, "\r\n") {
			return nil, E.New("invalid CSTP ", name, " header value")
		}
	}
	var request strings.Builder
	request.WriteString("CONNECT /CSCOSSLC/tunnel HTTP/1.1\r\n")
	request.WriteString("Host: ")
	request.WriteString(serverURL.Host)
	request.WriteString("\r\nUser-Agent: ")
	request.WriteString(userAgent)
	request.WriteString("\r\nCookie: webvpn=")
	request.WriteString(session.Cookie)
	request.WriteString("\r\nX-CSTP-Version: 1\r\nX-CSTP-Hostname: ")
	request.WriteString(localHostname)
	request.WriteString("\r\nX-CSTP-Protocol: Copyright (c) 2004 Cisco Systems, Inc.\r\n")
	if client.options.Mobile != nil {
		request.WriteString("X-AnyConnect-Identifier-ClientVersion: ")
		request.WriteString(client.options.Version)
		request.WriteString("\r\nX-AnyConnect-Identifier-Platform: ")
		request.WriteString(reportedAnyConnectOS(client))
		request.WriteString("\r\nX-AnyConnect-Identifier-PlatformVersion: ")
		request.WriteString(client.options.Mobile.PlatformVersion)
		request.WriteString("\r\nX-AnyConnect-Identifier-DeviceType: ")
		request.WriteString(client.options.Mobile.DeviceType)
		request.WriteString("\r\nX-AnyConnect-Identifier-Device-UniqueID: ")
		request.WriteString(client.options.Mobile.DeviceUniqueID)
		request.WriteString("\r\n")
	}
	if !client.options.CompressionDisabled {
		request.WriteString("X-CSTP-Accept-Encoding: oc-lz4,lzs")
		if client.options.CompressionMode == CompressionModeAll {
			request.WriteString(",deflate")
		}
		request.WriteString("\r\n")
	}
	request.WriteString("X-CSTP-Base-MTU: ")
	request.WriteString(strconv.FormatUint(uint64(baseMTU), 10))
	request.WriteString("\r\nX-CSTP-MTU: ")
	request.WriteString(strconv.FormatUint(uint64(tunnelMTU), 10))
	if client.options.IPv6Disabled {
		request.WriteString("\r\nX-CSTP-Address-Type: IPv4\r\n")
	} else {
		request.WriteString("\r\nX-CSTP-Address-Type: IPv6,IPv4\r\nX-CSTP-Full-IPv6-Capability: true\r\n")
	}
	for _, address := range session.PreviousAddresses {
		if client.options.IPv6Disabled && address.Addr().Is6() {
			continue
		}
		request.WriteString("X-CSTP-Address: ")
		request.WriteString(address.Addr().String())
		request.WriteString("\r\n")
	}
	if !client.options.NoUDP {
		request.WriteString("X-DTLS-Master-Secret: ")
		request.WriteString(strings.ToUpper(hex.EncodeToString(masterSecret)))
		request.WriteString("\r\n")
		if client.options.DTLSCipherSuites != "" || client.options.DTLS12CipherSuites != "" {
			if client.options.DTLSCipherSuites != "" {
				request.WriteString("X-DTLS-CipherSuite: ")
				request.WriteString(client.options.DTLSCipherSuites)
				request.WriteString("\r\n")
			}
			if client.options.DTLS12CipherSuites != "" {
				request.WriteString("X-DTLS12-CipherSuite: ")
				request.WriteString(client.options.DTLS12CipherSuites)
				request.WriteString("\r\n")
			}
		} else {
			request.WriteString("X-DTLS-CipherSuite: PSK-NEGOTIATE:OC2-DTLS1_2-CHACHA20-POLY1305:OC-DTLS1_2-AES256-GCM:OC-DTLS1_2-AES128-GCM:DHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA:AES256-SHA:AES128-SHA")
			if client.options.AllowInsecureCrypto {
				request.WriteString(":DES-CBC3-SHA:DES-CBC-SHA")
			}
			request.WriteString("\r\n")
			request.WriteString("X-DTLS12-CipherSuite: ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-GCM-SHA256:DHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA:AES256-SHA:AES128-SHA\r\n")
		}
		if !client.options.CompressionDisabled {
			request.WriteString("X-DTLS-Accept-Encoding: oc-lz4,lzs\r\n")
		}
	}
	request.WriteString("\r\n")
	return []byte(request.String()), nil
}

func calculateCSTPRequestMTU(baseMTU uint32, tunnelMTU uint32, remoteAddress net.Addr) (uint32, uint32) {
	if baseMTU == 0 {
		baseMTU = cstpDefaultBaseMTU
	}
	if baseMTU < 1280 {
		baseMTU = 1280
	}
	if tunnelMTU != 0 {
		return baseMTU, tunnelMTU
	}
	ipHeaderSize := uint32(20)
	if remoteAddress != nil {
		host, _, err := net.SplitHostPort(remoteAddress.String())
		if err == nil {
			address, parseErr := netip.ParseAddr(strings.Trim(host, "[]"))
			if parseErr == nil && address.Is6() {
				ipHeaderSize = 40
			}
		}
	}
	overhead := ipHeaderSize + 8 + cstpDTLSOverhead
	if baseMTU <= overhead {
		return baseMTU, 1
	}
	return baseMTU, baseMTU - overhead
}

func parseCSTPStatusLine(line string) (int, error) {
	fields := strings.Fields(line)
	if len(fields) < 2 || !strings.HasPrefix(fields[0], "HTTP/1.") {
		return 0, E.Extend(ErrProtocolNotSupported, "invalid CSTP HTTP status line: ", strings.TrimSpace(line))
	}
	statusCode, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0, E.Extend(ErrProtocolNotSupported, "invalid CSTP HTTP status code: ", fields[1])
	}
	return statusCode, nil
}

// Upstream start_cstp_connection parses address, route, DNS, MTU, timer, and DTLS headers only after a 200 CONNECT response.
func parseCSTPResponse(
	headers http.Header,
	dtlsOptions []cstpDTLSOption,
	serverURL *url.URL,
	authenticatedAddress netip.Addr,
	masterSecret []byte,
	client *Client,
) (cstpNegotiatedState, error) {
	var result cstpNegotiatedState
	mtu, err := parsePositiveCSTPInteger(headers.Get("X-CSTP-MTU"), "X-CSTP-MTU")
	if err != nil {
		return result, err
	}
	if mtu > cstpMaximumMTU {
		return result, E.Extend(ErrProtocolNotSupported, "X-CSTP-MTU exceeds wire limit: ", mtu, " > ", cstpMaximumMTU)
	}
	for _, value := range append(headers.Values("X-DTLS-MTU"), headers.Values("X-DTLS12-MTU")...) {
		dtlsMTU, parseErr := parsePositiveCSTPInteger(value, "X-DTLS-MTU")
		if parseErr != nil {
			return result, parseErr
		}
		if dtlsMTU > cstpMaximumMTU {
			return result, E.Extend(ErrProtocolNotSupported, "X-DTLS-MTU exceeds wire limit: ", dtlsMTU, " > ", cstpMaximumMTU)
		}
		if dtlsMTU > mtu {
			mtu = dtlsMTU
		}
	}
	if mtu == 0 {
		return result, E.New("CSTP server did not provide a valid MTU")
	}
	result.Configuration.MTU = uint32(mtu)
	result.Configuration.RemoteAddress = authenticatedAddress.Unmap()
	result.Configuration.Addresses, err = parseCSTPAddresses(headers)
	if err != nil {
		return result, err
	}
	if len(result.Configuration.Addresses) == 0 {
		return result, E.New("CSTP server did not provide a tunnel address")
	}
	if client.options.IPv6Disabled {
		result.Configuration.Addresses = slices.DeleteFunc(result.Configuration.Addresses, func(prefix netip.Prefix) bool {
			return prefix.Addr().Is6()
		})
		if len(result.Configuration.Addresses) == 0 {
			return result, E.New("CSTP server did not provide an IPv4 tunnel address")
		}
	}
	result.Configuration.Routes, err = parseCSTPRoutes(headers.Values("X-CSTP-Split-Include"), headers.Values("X-CSTP-Split-Include-IP6"))
	if err != nil {
		return result, err
	}
	result.Configuration.ExcludedRoutes, err = parseCSTPRoutes(headers.Values("X-CSTP-Split-Exclude"), headers.Values("X-CSTP-Split-Exclude-IP6"))
	if err != nil {
		return result, err
	}
	result.Configuration.DNS, err = parseCSTPAddressesWithoutPrefix(headers.Values("X-CSTP-DNS"), headers.Values("X-CSTP-DNS-IP6"), "DNS")
	if err != nil {
		return result, err
	}
	result.Configuration.NBNS, err = parseCSTPAddressesWithoutPrefix(headers.Values("X-CSTP-NBNS"), nil, "NBNS")
	if err != nil {
		return result, err
	}
	for _, domain := range headers.Values("X-CSTP-Default-Domain") {
		result.Configuration.SearchDomains = append(result.Configuration.SearchDomains, strings.Fields(domain)...)
	}
	for _, domain := range headers.Values("X-CSTP-Split-DNS") {
		if domain = strings.TrimSpace(domain); domain != "" {
			result.Configuration.SplitDNS = append(result.Configuration.SplitDNS, domain)
		}
	}
	result.Configuration.ProxyAutoConfigURL = headers.Get("X-CSTP-MSIE-Proxy-PAC-URL")
	result.Configuration.Banner = headers.Get("X-CSTP-Banner")
	result.Configuration.TunnelAllDNS = headers.Get("X-CSTP-Tunnel-All-DNS") == "true"
	result.Configuration.ClientBypassProtocol = headers.Get("X-CSTP-Client-Bypass-Protocol") == "true"
	result.DynamicDNS = headers.Get("X-CSTP-DynDNS") == "true"
	result.DPD, err = parseCSTPDuration(headers.Get("X-CSTP-DPD"), "X-CSTP-DPD")
	if err != nil {
		return result, err
	}
	if client.options.DPDInterval > 0 {
		result.DPD = client.options.DPDInterval
	}
	result.Keepalive, err = parseCSTPDuration(headers.Get("X-CSTP-Keepalive"), "X-CSTP-Keepalive")
	if err != nil {
		return result, err
	}
	result.Rekey, err = parseCSTPDuration(headers.Get("X-CSTP-Rekey-Time"), "X-CSTP-Rekey-Time")
	if err != nil {
		return result, err
	}
	result.RekeyMethod, err = parseCSTPRekeyMethod(headers.Get("X-CSTP-Rekey-Method"))
	if err != nil {
		return result, err
	}
	if result.Rekey <= 0 {
		result.RekeyMethod = cstpRekeyNone
	}
	result.Configuration.IdleTimeout, err = parseCSTPDuration(headers.Get("X-CSTP-Idle-Timeout"), "X-CSTP-Idle-Timeout")
	if err != nil {
		return result, err
	}
	now := time.Now()
	for _, name := range []string{"X-CSTP-Lease-Duration", "X-CSTP-Session-Timeout", "X-CSTP-Session-Timeout-Remaining"} {
		duration, parseErr := parseCSTPDuration(headers.Get(name), name)
		if parseErr != nil {
			return result, parseErr
		}
		if duration > 0 {
			expiration := now.Add(duration)
			if result.Configuration.AuthenticationExpiration.IsZero() || expiration.Before(result.Configuration.AuthenticationExpiration) {
				result.Configuration.AuthenticationExpiration = expiration
			}
		}
	}
	result.Compression, err = parseAnyConnectCompression(
		headers.Get("X-CSTP-Content-Encoding"),
		"X-CSTP-Content-Encoding",
		client.options.CompressionDisabled,
		client.options.CompressionMode,
		true,
	)
	if err != nil {
		return result, err
	}
	result.Configuration = normalizeTunnelConfiguration(result.Configuration, client.options.IPv6Disabled)
	if client.options.NoUDP {
		return result, nil
	}
	dtlsNegotiation, err := parseCSTPDTLSNegotiation(dtlsOptions, serverURL, authenticatedAddress, masterSecret, client, mtu)
	if err != nil {
		return result, err
	}
	result.DTLS = dtlsNegotiation
	if result.DTLS != nil && client.options.DPDInterval > 0 {
		result.DTLS.DPD = client.options.DPDInterval
	}
	return result, nil
}

func parseCSTPDTLSNegotiation(
	dtlsOptions []cstpDTLSOption,
	serverURL *url.URL,
	authenticatedAddress netip.Addr,
	masterSecret []byte,
	client *Client,
	mtu int,
) (*cstpDTLSNegotiation, error) {
	port, err := anyConnectURLPort(serverURL)
	if err != nil {
		return nil, err
	}
	host := serverURL.Hostname()
	if authenticatedAddress.IsValid() {
		host = authenticatedAddress.String()
	}
	negotiation := &cstpDTLSNegotiation{
		Address:             net.JoinHostPort(host, strconv.Itoa(int(port))),
		MasterSecret:        append([]byte(nil), masterSecret...),
		TLSConnection:       nil,
		Dialer:              client.options.Dialer,
		MTU:                 mtu,
		AllowInsecureCrypto: client.options.AllowInsecureCrypto,
		Logger:              client.options.Logger,
	}
	for _, option := range dtlsOptions {
		headerName := "X-DTLS-" + option.Suffix
		if option.DTLS12 {
			headerName = "X-DTLS12-" + option.Suffix
		}
		switch strings.ToLower(option.Suffix) {
		case "ciphersuite":
			negotiation.CipherSuite = option.Value
			negotiation.DTLS12 = option.DTLS12
		case "session-id":
			negotiation.SessionID, err = decodeCSTPHexHeader(option.Value, headerName, false)
			if err != nil {
				return nil, err
			}
			if len(negotiation.SessionID) != 32 {
				return nil, E.New(headerName, " must contain 32 bytes, got ", len(negotiation.SessionID))
			}
		case "app-id":
			negotiation.AppID, err = decodeCSTPHexHeader(option.Value, headerName, false)
			if err != nil {
				return nil, err
			}
			if len(negotiation.AppID) == 0 {
				return nil, E.New(headerName, " must not be empty")
			}
		case "content-encoding":
			negotiation.Compression, err = parseAnyConnectCompression(
				option.Value,
				headerName,
				client.options.CompressionDisabled,
				client.options.CompressionMode,
				false,
			)
			if err != nil {
				return nil, err
			}
		case "port":
			parsedPort, parseErr := strconv.ParseUint(option.Value, 10, 16)
			if parseErr != nil || parsedPort == 0 {
				return nil, E.New("invalid ", headerName, ": ", option.Value)
			}
			port = uint16(parsedPort)
			negotiation.Address = net.JoinHostPort(host, strconv.Itoa(int(port)))
		case "keepalive":
			negotiation.Keepalive, err = parseCSTPDuration(option.Value, headerName)
			if err != nil {
				return nil, err
			}
		case "dpd":
			dpd, parseErr := parseCSTPDuration(option.Value, headerName)
			if parseErr != nil {
				return nil, parseErr
			}
			if dpd > 0 && negotiation.DPD == 0 {
				negotiation.DPD = dpd
			}
		case "rekey-time":
			negotiation.Rekey, err = parseCSTPDuration(option.Value, headerName)
			if err != nil {
				return nil, err
			}
		case "rekey-method":
			dtlsRekeyMethod, parseErr := parseCSTPRekeyMethod(option.Value)
			if parseErr != nil {
				return nil, parseErr
			}
			switch dtlsRekeyMethod {
			case cstpRekeyNewTunnel:
				negotiation.RekeyMethod = "new-tunnel"
			case cstpRekeyTLS:
				negotiation.RekeyMethod = "ssl"
			default:
				negotiation.RekeyMethod = "none"
			}
		}
	}
	if negotiation.CipherSuite == "" {
		return nil, nil
	}
	if negotiation.RekeyMethod == "" {
		negotiation.RekeyMethod = "none"
	}
	return negotiation, nil
}

func parseCSTPAddresses(headers http.Header) ([]netip.Prefix, error) {
	result := make([]netip.Prefix, 0, 2)
	var ipv6Metadata []netip.Prefix
	for _, value := range headers.Values("X-CSTP-Address-IP6") {
		prefix, err := parseCSTPPrefix(value)
		if err != nil {
			return nil, E.Cause(err, "parse X-CSTP-Address-IP6")
		}
		ipv6Metadata = append(ipv6Metadata, prefix)
	}
	addresses := headers.Values("X-CSTP-Address")
	netmasks := headers.Values("X-CSTP-Netmask")
	hasIPv6Address := false
	for _, value := range addresses {
		address, err := netip.ParseAddr(strings.TrimSpace(value))
		if err != nil {
			return nil, E.Cause(err, "parse X-CSTP-Address")
		}
		if address.Is6() {
			hasIPv6Address = true
			prefixBits := 128
			if len(ipv6Metadata) > 0 {
				prefixBits = ipv6Metadata[0].Bits()
			}
			for _, netmask := range netmasks {
				if strings.Contains(netmask, ":") {
					var parseErr error
					if strings.Contains(netmask, "/") {
						var prefix netip.Prefix
						prefix, parseErr = parseCSTPPrefix(netmask)
						prefixBits = prefix.Bits()
					} else {
						prefixBits, parseErr = parseIPv6NetmaskBits(netmask)
					}
					if parseErr != nil {
						return nil, E.Cause(parseErr, "parse IPv6 X-CSTP-Netmask")
					}
					break
				}
			}
			result = append(result, netip.PrefixFrom(address, prefixBits))
			continue
		}
		prefixBits := 32
		for _, netmask := range netmasks {
			if strings.Contains(netmask, ":") {
				continue
			}
			parsedBits, parseErr := parseIPv4NetmaskBits(netmask)
			if parseErr != nil {
				return nil, parseErr
			}
			prefixBits = parsedBits
			break
		}
		result = append(result, netip.PrefixFrom(address, prefixBits))
	}
	// Upstream script.c derives INTERNAL_IP6_ADDRESS from netmask6 when a gateway sends only X-CSTP-Address-IP6, as ocserv does in full-IPv6 mode.
	if !hasIPv6Address {
		result = append(result, ipv6Metadata...)
	}
	return result, nil
}

func parseCSTPRoutes(ipv4Values []string, ipv6Values []string) ([]TunnelRoute, error) {
	values := append(append([]string(nil), ipv4Values...), ipv6Values...)
	result := make([]TunnelRoute, 0, len(values))
	for _, value := range values {
		prefix, err := parseCSTPPrefix(value)
		if err != nil {
			return nil, E.Cause(err, "parse CSTP split route: ", value)
		}
		result = append(result, TunnelRoute{Prefix: prefix.Masked()})
	}
	return result, nil
}

func parseCSTPPrefix(value string) (netip.Prefix, error) {
	value = strings.TrimSpace(value)
	prefix, err := netip.ParsePrefix(value)
	if err == nil {
		return prefix, nil
	}
	addressText, maskText, hasMask := strings.Cut(value, "/")
	if !hasMask {
		address, addressErr := netip.ParseAddr(addressText)
		if addressErr != nil {
			return netip.Prefix{}, addressErr
		}
		return netip.PrefixFrom(address, address.BitLen()), nil
	}
	address, addressErr := netip.ParseAddr(addressText)
	if addressErr != nil {
		return netip.Prefix{}, addressErr
	}
	if !address.Is4() {
		return netip.Prefix{}, err
	}
	bits, maskErr := parseIPv4NetmaskBits(maskText)
	if maskErr != nil {
		return netip.Prefix{}, maskErr
	}
	return netip.PrefixFrom(address, bits), nil
}

func parseIPv4NetmaskBits(value string) (int, error) {
	value = strings.TrimSpace(value)
	bits, decimalErr := strconv.Atoi(value)
	if decimalErr == nil {
		if bits < 0 || bits > 32 {
			return 0, E.New("invalid IPv4 prefix length: ", value)
		}
		return bits, nil
	}
	address, err := netip.ParseAddr(value)
	if err != nil || !address.Is4() {
		return 0, E.New("invalid IPv4 netmask: ", value)
	}
	octets := address.As4()
	ones, bits := net.IPMask(octets[:]).Size()
	if ones == 0 && bits == 0 && value != "0.0.0.0" {
		return 0, E.New("non-contiguous IPv4 netmask: ", value)
	}
	return ones, nil
}

func parseIPv6NetmaskBits(value string) (int, error) {
	address, err := netip.ParseAddr(strings.TrimSpace(value))
	if err != nil || !address.Is6() {
		return 0, E.New("invalid IPv6 netmask: ", value)
	}
	octets := address.As16()
	ones, bits := net.IPMask(octets[:]).Size()
	if ones == 0 && bits == 0 {
		allZero := true
		for _, octet := range octets {
			if octet != 0 {
				allZero = false
				break
			}
		}
		if !allZero {
			return 0, E.New("non-contiguous IPv6 netmask: ", value)
		}
	}
	return ones, nil
}

func parseCSTPAddressesWithoutPrefix(primary []string, secondary []string, name string) ([]netip.Addr, error) {
	values := append(append([]string(nil), primary...), secondary...)
	result := make([]netip.Addr, 0, len(values))
	for _, value := range values {
		address, err := netip.ParseAddr(strings.TrimSpace(value))
		if err != nil {
			return nil, E.Cause(err, "parse CSTP ", name, " address")
		}
		result = append(result, address)
	}
	return result, nil
}

func parsePositiveCSTPInteger(value string, name string) (int, error) {
	value = strings.TrimSpace(value)
	if value == "" || strings.EqualFold(value, "none") {
		return 0, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 0 {
		return 0, E.New("invalid ", name, ": ", value)
	}
	return parsed, nil
}

func parseCSTPDuration(value string, name string) (time.Duration, error) {
	seconds, err := parsePositiveCSTPInteger(value, name)
	if err != nil {
		return 0, err
	}
	if int64(seconds) > cstpMaximumTimerSeconds {
		return 0, E.Extend(ErrProtocolNotSupported, name, " exceeds safe timer limit: ", seconds, " seconds")
	}
	return time.Duration(seconds) * time.Second, nil
}

func decodeCSTPHexHeader(value string, name string, required bool) ([]byte, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		if required {
			return nil, E.New("missing ", name)
		}
		return nil, nil
	}
	decoded, err := hex.DecodeString(value)
	if err != nil {
		return nil, E.Cause(err, "decode ", name)
	}
	return decoded, nil
}

func writeCSTPBytes(connection net.Conn, content []byte) error {
	written := 0
	for written < len(content) {
		n, err := connection.Write(content[written:])
		if err != nil {
			return E.Cause(err, "write CSTP CONNECT request")
		}
		if n <= 0 {
			return E.New("short CSTP CONNECT write: wrote ", written, " of ", len(content), " bytes")
		}
		written += n
	}
	return nil
}

func anyConnectURLPort(serverURL *url.URL) (uint16, error) {
	if serverURL.Port() == "" {
		return 443, nil
	}
	port, err := strconv.ParseUint(serverURL.Port(), 10, 16)
	if err != nil || port == 0 {
		return 0, E.New("invalid AnyConnect server port: ", serverURL.Port())
	}
	return uint16(port), nil
}
