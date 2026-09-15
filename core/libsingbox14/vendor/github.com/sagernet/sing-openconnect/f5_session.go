package openconnect

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"net/netip"
	"net/textproto"
	"strconv"
	"strings"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

const (
	f5TLSConnectTimeout = 30 * time.Second
	f5MaximumStatusLine = 8192
	f5MaximumHeaderSize = 1024 * 1024
)

type f5Session struct {
	*pppSession
	state         *f5SessionState
	snapshot      f5SessionSnapshot
	configuration *f5TunnelConfiguration
}

type f5BufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func init() {
	registerFlavorFrontend(FlavorF5, func(client *Client) (flavorFrontend, error) {
		return newF5Frontend(client)
	})
}

func newF5Frontend(client *Client) (*f5Frontend, error) {
	return &f5Frontend{client: client, localHostname: client.options.LocalHostname}, nil
}

func (f *f5Frontend) ConnectTunnel(ctx context.Context, obtained obtainedSession) (clientSession, error) {
	state, loaded := obtained.(*f5SessionState)
	if !loaded || state == nil {
		return nil, E.Extend(ErrProtocolNotSupported, "invalid F5 obtained session")
	}
	snapshot := state.snapshot()
	if state.frontend != f || snapshot.serverURL == nil || snapshot.jar == nil || snapshot.mrhSession == "" {
		return nil, ErrSessionRejected
	}
	if !snapshot.authenticationExpiration.IsZero() && !time.Now().Before(snapshot.authenticationExpiration) {
		return nil, ErrSessionRejected
	}
	sessionContext, cancelSession := context.WithCancel(ctx)
	session := &f5Session{
		state:    state,
		snapshot: snapshot,
	}
	session.pppSession = &pppSession{
		ctx:     sessionContext,
		cancel:  cancelSession,
		client:  f.client,
		owner:   session,
		flavor:  "F5",
		state:   state,
		handler: session,
		done:    make(chan error, 1),
	}
	return session, nil
}

func (s *f5Session) preparePPP() (pppSessionSetup, error) {
	configuration, configurationErr := s.state.loadConfiguration(s.ctx)
	if configurationErr != nil {
		return pppSessionSetup{}, configurationErr
	}
	s.snapshot = s.state.snapshot()
	s.configuration = configuration
	dtlsEnabled := configuration.dtlsEnabled && !configuration.hdlc && !s.client.options.NoUDP
	carrier, usingDTLS, carrierErr := s.connectInitialPPPCarrier(dtlsEnabled, s.snapshot.skipInitialDTLS)
	if carrierErr != nil {
		return pppSessionSetup{}, carrierErr
	}
	encapsulation := pppEncapsulationF5
	if configuration.hdlc {
		encapsulation = pppEncapsulationF5HDLC
	}
	proposedIPv4 := carrier.proposedIPv4
	proposedIPv6 := carrier.proposedIPv6
	if s.client.options.IPv6Disabled {
		proposedIPv6 = netip.Prefix{}
	}
	if s.snapshot.hasPreviousAddresses {
		proposedIPv4 = s.snapshot.previousIPv4
		proposedIPv6 = s.snapshot.previousIPv6
	}
	requestNameServers := configuration.wantIPv4 && len(configuration.configuration.DNS) == 0 && len(configuration.configuration.NBNS) == 0
	echoInterval := s.client.options.DPDInterval
	return pppSessionSetup{
		linkConfiguration: pppLinkConfig{
			Carrier: pppCarrierConfig{
				Connection: carrier.connection,
				Datagram:   carrier.datagram,
				MTU:        carrier.mtu,
			},
			Encapsulation:          encapsulation,
			WantIPv4:               configuration.wantIPv4,
			WantIPv6:               configuration.wantIPv6 && !s.client.options.IPv6Disabled,
			IPv4Address:            proposedIPv4,
			IPv6Address:            proposedIPv6,
			LockAddresses:          s.snapshot.hasPreviousAddresses,
			MTU:                    carrier.mtu,
			RequestIPv4NameServers: requestNameServers,
			EchoInterval:           echoInterval,
			Deliver: func(packetBuffer *buf.Buffer) {
				s.client.pushIncomingDataPacketContext(s.ctx, packetBuffer)
			},
		},
		configuration: configuration.configuration,
		usingDTLS:     usingDTLS,
		dtlsEnabled:   dtlsEnabled,
	}, nil
}

func (s *f5Session) connectPPPTLS() (pppSessionCarrier, error) {
	configuration := s.configuration
	serverPort, portErr := f5URLPort(s.snapshot.serverURL)
	if portErr != nil {
		return pppSessionCarrier{}, portErr
	}
	destination := M.ParseSocksaddrHostPort(s.snapshot.acceptedAddress.String(), serverPort)
	dialer := s.client.options.Dialer
	rawConnection, dialErr := dialer.DialContext(s.ctx, N.NetworkTCP, destination)
	if dialErr != nil {
		return pppSessionCarrier{}, E.Cause(dialErr, "connect F5 TLS transport")
	}
	setupComplete := false
	defer func() {
		if !setupComplete {
			_ = rawConnection.Close()
		}
	}()
	stopCancellation := context.AfterFunc(s.ctx, func() {
		_ = rawConnection.Close()
	})
	defer stopCancellation()
	deadline := time.Now().Add(f5TLSConnectTimeout)
	if contextDeadline, hasDeadline := s.ctx.Deadline(); hasDeadline && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	deadlineErr := rawConnection.SetDeadline(deadline)
	if deadlineErr != nil {
		return pppSessionCarrier{}, E.Cause(deadlineErr, "set F5 TLS connection deadline")
	}
	tlsConfiguration := s.client.tlsConfig.Clone()
	if tlsConfiguration.ServerName == "" {
		tlsConfiguration.ServerName = s.snapshot.serverURL.Hostname()
	}
	tlsConfiguration.NextProtos = []string{"http/1.1"}
	tlsConnection := tls.Client(rawConnection, tlsConfiguration)
	handshakeErr := tlsConnection.HandshakeContext(s.ctx)
	if handshakeErr != nil {
		return pppSessionCarrier{}, E.Cause(handshakeErr, "handshake F5 TLS transport")
	}
	writeErr := writeF5Bytes(tlsConnection, configuration.connectRequest)
	if writeErr != nil {
		return pppSessionCarrier{}, writeErr
	}
	reader := bufio.NewReader(tlsConnection)
	statusCode, responseHeader, responseErr := readF5HTTPHeader(reader)
	if responseErr != nil {
		return pppSessionCarrier{}, E.Cause(responseErr, "read F5 TLS tunnel response")
	}
	if statusCode == http.StatusGatewayTimeout {
		return pppSessionCarrier{}, ErrSessionRejected
	}
	if statusCode != http.StatusOK && statusCode != http.StatusCreated {
		return pppSessionCarrier{}, markTerminal(E.New("TLS tunnel returned HTTP ", statusCode))
	}
	proposedIPv4, proposedIPv6, addressErr := parseF5ProposedAddresses(responseHeader)
	if addressErr != nil {
		return pppSessionCarrier{}, markTerminal(addressErr)
	}
	clearDeadlineErr := tlsConnection.SetDeadline(time.Time{})
	if clearDeadlineErr != nil {
		return pppSessionCarrier{}, E.Cause(clearDeadlineErr, "clear F5 TLS connection deadline")
	}
	setupComplete = true
	return pppSessionCarrier{
		connection:   &f5BufferedConn{Conn: tlsConnection, reader: reader},
		proposedIPv4: proposedIPv4,
		proposedIPv6: proposedIPv6,
		mtu:          configuration.configuration.MTU,
	}, nil
}

func (s *f5Session) connectPPPDTLS(ctx context.Context) (pppSessionCarrier, error) {
	configuration := s.configuration
	tlsConfiguration := s.client.tlsConfig.Clone()
	if tlsConfiguration.ServerName == "" {
		tlsConfiguration.ServerName = s.snapshot.serverURL.Hostname()
	}
	connection, connectErr := connectCertificateDTLS(ctx, certificateDTLSNegotiation{
		Address:           net.JoinHostPort(s.snapshot.acceptedAddress.String(), strconv.Itoa(int(configuration.dtlsPort))),
		ServerName:        s.snapshot.serverURL.Hostname(),
		TLSConfig:         tlsConfiguration,
		Dialer:            s.client.options.Dialer,
		MTU:               f5DTLSRecordMTU(s.snapshot.acceptedAddress),
		LegacyVersion:     !configuration.dtls12,
		AllowLegacyCrypto: s.client.options.AllowInsecureCrypto,
	})
	if connectErr != nil {
		return pppSessionCarrier{}, connectErr
	}
	setupComplete := false
	defer func() {
		if !setupComplete {
			_ = connection.Close()
		}
	}()
	if connection.DataMTU() > 0 && len(configuration.connectRequest) > connection.DataMTU() {
		return pppSessionCarrier{}, E.New("DTLS connect request exceeds negotiated datagram MTU")
	}
	proposedIPv4, proposedIPv6, probeErr := probeF5DTLS(ctx, connection, configuration.connectRequest)
	if probeErr != nil {
		return pppSessionCarrier{}, probeErr
	}
	dataMTU := connection.DataMTU() - 8
	if dataMTU < pppMinimumMRU {
		return pppSessionCarrier{}, E.New("DTLS data MTU is too small for PPP")
	}
	tunnelMTU := min(int(configuration.configuration.MTU), dataMTU)
	setupComplete = true
	return pppSessionCarrier{
		connection:   connection,
		datagram:     true,
		proposedIPv4: proposedIPv4,
		proposedIPv6: proposedIPv6,
		mtu:          uint32(tunnelMTU),
	}, nil
}

func probeF5DTLS(
	ctx context.Context,
	connection net.Conn,
	connectRequest []byte,
) (netip.Prefix, netip.Prefix, error) {
	buffer := make([]byte, 65536)
	for {
		if ctx.Err() != nil {
			return netip.Prefix{}, netip.Prefix{}, ctx.Err()
		}
		written, writeErr := connection.Write(connectRequest)
		if writeErr != nil {
			return netip.Prefix{}, netip.Prefix{}, E.Cause(writeErr, "write F5 DTLS application probe")
		}
		if written != len(connectRequest) {
			return netip.Prefix{}, netip.Prefix{}, E.New("short F5 DTLS application probe write")
		}
		readDeadline := time.Now().Add(time.Second)
		if contextDeadline, hasDeadline := ctx.Deadline(); hasDeadline && contextDeadline.Before(readDeadline) {
			readDeadline = contextDeadline
		}
		deadlineErr := connection.SetReadDeadline(readDeadline)
		if deadlineErr != nil {
			return netip.Prefix{}, netip.Prefix{}, E.Cause(deadlineErr, "set F5 DTLS probe deadline")
		}
		readLength, readErr := connection.Read(buffer)
		if readErr != nil {
			if networkErr, loaded := readErr.(net.Error); loaded && networkErr.Timeout() && ctx.Err() == nil {
				continue
			}
			return netip.Prefix{}, netip.Prefix{}, E.Cause(readErr, "read F5 DTLS application probe")
		}
		statusCode, responseHeader, responseErr := readF5HTTPHeader(bufio.NewReader(bytes.NewReader(buffer[:readLength])))
		if responseErr != nil {
			return netip.Prefix{}, netip.Prefix{}, markTerminal(E.Errors(
				ErrProtocolNotSupported,
				E.Cause(responseErr, "parse F5 DTLS application probe"),
			))
		}
		if statusCode >= 400 && statusCode <= 499 {
			return netip.Prefix{}, netip.Prefix{}, ErrSessionRejected
		}
		if statusCode != http.StatusOK {
			return netip.Prefix{}, netip.Prefix{}, markTerminal(E.Errors(
				ErrProtocolNotSupported,
				E.New("DTLS application probe returned HTTP ", statusCode),
			))
		}
		proposedIPv4, proposedIPv6, addressErr := parseF5ProposedAddresses(responseHeader)
		if addressErr != nil {
			return netip.Prefix{}, netip.Prefix{}, markTerminal(addressErr)
		}
		clearDeadlineErr := connection.SetDeadline(time.Time{})
		if clearDeadlineErr != nil {
			return netip.Prefix{}, netip.Prefix{}, E.Cause(clearDeadlineErr, "clear F5 DTLS probe deadline")
		}
		return proposedIPv4, proposedIPv6, nil
	}
}

func f5DTLSRecordMTU(acceptedAddress netip.Addr) int {
	if acceptedAddress.Is6() {
		return 1232
	}
	return 1400
}

func readF5HTTPHeader(reader *bufio.Reader) (int, http.Header, error) {
	statusLine, statusErr := readF5HTTPLine(reader, f5MaximumStatusLine)
	if statusErr != nil {
		return 0, nil, statusErr
	}
	parts := strings.Fields(statusLine)
	if len(parts) < 2 || !strings.HasPrefix(parts[0], "HTTP/") {
		return 0, nil, E.New("invalid F5 HTTP status line")
	}
	statusCode, parseErr := strconv.Atoi(parts[1])
	if parseErr != nil || statusCode < 100 || statusCode > 999 {
		return 0, nil, E.New("invalid F5 HTTP status code")
	}
	var encodedHeaders strings.Builder
	for {
		remaining := f5MaximumHeaderSize - encodedHeaders.Len()
		if remaining <= 0 {
			return 0, nil, E.New("HTTP headers exceed ", f5MaximumHeaderSize, " bytes")
		}
		line, lineErr := readF5HTTPLine(reader, remaining)
		if lineErr != nil {
			return 0, nil, lineErr
		}
		if line == "" {
			break
		}
		encodedHeaders.WriteString(line)
		encodedHeaders.WriteString("\r\n")
	}
	encodedHeaders.WriteString("\r\n")
	mimeHeader, headerErr := textproto.NewReader(bufio.NewReader(strings.NewReader(encodedHeaders.String()))).ReadMIMEHeader()
	if headerErr != nil {
		return 0, nil, E.Cause(headerErr, "parse F5 HTTP headers")
	}
	return statusCode, http.Header(mimeHeader), nil
}

func readF5HTTPLine(reader *bufio.Reader, maximum int) (string, error) {
	var line strings.Builder
	for {
		fragment, readErr := reader.ReadSlice('\n')
		if line.Len()+len(fragment) > maximum {
			return "", E.New("HTTP line exceeds ", maximum, " bytes")
		}
		line.Write(fragment)
		if readErr == bufio.ErrBufferFull {
			continue
		}
		if readErr != nil {
			return "", readErr
		}
		return strings.TrimSuffix(strings.TrimSuffix(line.String(), "\n"), "\r"), nil
	}
}

func parseF5ProposedAddresses(header http.Header) (netip.Prefix, netip.Prefix, error) {
	var ipv4Prefix netip.Prefix
	var ipv6Prefix netip.Prefix
	ipv4Text := strings.TrimSpace(header.Get("X-VPN-client-IP"))
	if ipv4Text != "" {
		address, parseErr := netip.ParseAddr(ipv4Text)
		if parseErr != nil || !address.Is4() {
			return netip.Prefix{}, netip.Prefix{}, E.New("tunnel returned an invalid IPv4 address: ", ipv4Text)
		}
		ipv4Prefix = netip.PrefixFrom(address.Unmap(), 32)
	}
	ipv6Text := strings.TrimSpace(header.Get("X-VPN-client-IPv6"))
	if ipv6Text != "" {
		address, parseErr := netip.ParseAddr(ipv6Text)
		if parseErr != nil || !address.Is6() {
			return netip.Prefix{}, netip.Prefix{}, E.New("tunnel returned an invalid IPv6 address: ", ipv6Text)
		}
		ipv6Prefix = netip.PrefixFrom(address, 64)
	}
	return ipv4Prefix, ipv6Prefix, nil
}

func writeF5Bytes(connection net.Conn, content []byte) error {
	written := 0
	for written < len(content) {
		count, writeErr := connection.Write(content[written:])
		if writeErr != nil {
			return E.Cause(writeErr, "write F5 tunnel request")
		}
		if count <= 0 {
			return E.New("short F5 tunnel request write")
		}
		written += count
	}
	return nil
}

func (c *f5BufferedConn) Read(content []byte) (int, error) {
	return c.reader.Read(content)
}

func (s *f5Session) setSkipInitialDTLS(skip bool) {
	s.state.access.Lock()
	s.state.skipInitialDTLS = skip
	s.state.access.Unlock()
}

func (s *f5Session) storePPPConfiguration(configurationState pppSessionConfigurationState) {
	s.state.access.Lock()
	s.state.previousIPv4 = configurationState.previousIPv4
	s.state.previousIPv6 = configurationState.previousIPv6
	s.state.hasPreviousAddresses = true
	s.state.access.Unlock()
}

func (s *f5Session) recordPPPTermination(termination pppSessionTermination) {
	if termination.err != nil && termination.usingDTLS {
		s.state.access.Lock()
		s.state.skipInitialDTLS = true
		s.state.access.Unlock()
	}
}

var (
	_ clientSession = (*f5Session)(nil)
	_ net.Conn      = (*f5BufferedConn)(nil)
)
