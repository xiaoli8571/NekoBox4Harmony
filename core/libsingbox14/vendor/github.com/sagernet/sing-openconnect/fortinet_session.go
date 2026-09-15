package openconnect

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

const (
	fortinetTLSConnectTimeout      = 30 * time.Second
	fortinetTLSClassificationWait  = 250 * time.Millisecond
	fortinetTLSFailureClassifyWait = 3 * time.Second
	fortinetMaximumStatusLine      = 8192
	fortinetMaximumHeaderSize      = 1024 * 1024
)

type fortinetSession struct {
	*pppSession
	state         *fortinetSessionState
	snapshot      fortinetSessionSnapshot
	configuration *fortinetTunnelConfiguration
}

type fortinetTLSConn struct {
	net.Conn
	access              sync.Mutex
	classified          bool
	pending             []byte
	pendingErr          error
	classificationReady chan struct{}
	classificationOnce  sync.Once
	classificationWait  sync.Once
	classificationErr   error
}

type fortinetBufferedDatagramConn struct {
	net.Conn
	access  sync.Mutex
	initial []byte
}

func init() {
	registerFlavorFrontend(FlavorFortinet, func(client *Client) (flavorFrontend, error) {
		return &fortinetFrontend{client: client}, nil
	})
}

func (f *fortinetFrontend) ConnectTunnel(ctx context.Context, obtained obtainedSession) (clientSession, error) {
	state, loaded := obtained.(*fortinetSessionState)
	if !loaded || state == nil {
		return nil, E.Extend(ErrProtocolNotSupported, "invalid Fortinet obtained session")
	}
	snapshot := state.snapshot()
	if state.frontend != f || snapshot.serverURL == nil || snapshot.jar == nil || snapshot.svpnCookie == "" {
		return nil, ErrSessionRejected
	}
	sessionContext, cancelSession := context.WithCancel(ctx)
	session := &fortinetSession{
		state:    state,
		snapshot: snapshot,
	}
	session.pppSession = &pppSession{
		ctx:     sessionContext,
		cancel:  cancelSession,
		client:  f.client,
		owner:   session,
		flavor:  "Fortinet",
		state:   state,
		handler: session,
		done:    make(chan error, 1),
	}
	return session, nil
}

func (s *fortinetSession) preparePPP() (pppSessionSetup, error) {
	configuration, configurationErr := s.state.loadConfiguration(s.ctx)
	if configurationErr != nil {
		return pppSessionSetup{}, configurationErr
	}
	if configuration.platform != "" && s.client.options.Logger != nil {
		s.client.options.Logger.InfoContext(s.ctx, "gateway reports ", configuration.platform)
	}
	s.snapshot = s.state.snapshot()
	reconnectErr := validateFortinetReconnect(configuration, s.snapshot, time.Now())
	if reconnectErr != nil {
		return pppSessionSetup{}, reconnectErr
	}
	s.configuration = configuration
	dtlsEnabled := configuration.dtlsEnabled && !s.client.options.NoUDP
	carrier, usingDTLS, carrierErr := s.connectInitialPPPCarrier(dtlsEnabled, s.snapshot.skipInitialDTLS)
	if carrierErr != nil {
		return pppSessionSetup{}, carrierErr
	}
	if s.snapshot.connectedOnce && configuration.checkSourceIP && carrier.localSourceIP != s.snapshot.initialSourceAddress {
		_ = carrier.connection.Close()
		return pppSessionSetup{}, ErrSessionRejected
	}
	proposedIPv4 := configuration.proposedIPv4
	proposedIPv6 := configuration.proposedIPv6
	if s.snapshot.hasPreviousAddresses {
		proposedIPv4 = s.snapshot.previousIPv4
		proposedIPv6 = s.snapshot.previousIPv6
	}
	requestNameServers := configuration.wantIPv4 && len(configuration.configuration.DNS) == 0
	return pppSessionSetup{
		linkConfiguration: pppLinkConfig{
			Carrier: pppCarrierConfig{
				Connection: carrier.connection,
				Datagram:   carrier.datagram,
				MTU:        carrier.mtu,
			},
			Encapsulation:          pppEncapsulationFortinet,
			WantIPv4:               configuration.wantIPv4,
			WantIPv6:               configuration.wantIPv6 && !s.client.options.IPv6Disabled,
			IPv4Address:            proposedIPv4,
			IPv6Address:            proposedIPv6,
			LockAddresses:          s.snapshot.hasPreviousAddresses,
			MTU:                    carrier.mtu,
			RequestIPv4NameServers: requestNameServers,
			EchoInterval:           configuration.echoInterval,
			Deliver: func(packetBuffer *buf.Buffer) {
				s.client.pushIncomingDataPacketContext(s.ctx, packetBuffer)
			},
		},
		configuration:   configuration.configuration,
		usingDTLS:       usingDTLS,
		dtlsEnabled:     dtlsEnabled,
		checkSourceIP:   configuration.checkSourceIP,
		initialSourceIP: s.snapshot.initialSourceAddress,
		carrierSourceIP: carrier.localSourceIP,
	}, nil
}

func validateFortinetReconnect(
	configuration *fortinetTunnelConfiguration,
	snapshot fortinetSessionSnapshot,
	now time.Time,
) error {
	if !configuration.configuration.AuthenticationExpiration.IsZero() && !now.Before(configuration.configuration.AuthenticationExpiration) {
		return ErrSessionRejected
	}
	if !snapshot.connectedOnce {
		return nil
	}
	if !configuration.reconnectAllowed || snapshot.droppedAt.IsZero() || configuration.cleanupTimeout <= 0 {
		return ErrSessionRejected
	}
	if !now.Before(snapshot.droppedAt.Add(configuration.cleanupTimeout)) {
		return ErrSessionRejected
	}
	return nil
}

func (s *fortinetSession) connectPPPTLS() (pppSessionCarrier, error) {
	configuration := s.configuration
	serverPort, portErr := fortinetURLPort(s.snapshot.serverURL)
	if portErr != nil {
		return pppSessionCarrier{}, portErr
	}
	destination := M.ParseSocksaddrHostPort(s.snapshot.acceptedAddress.String(), serverPort)
	dialer := s.client.options.Dialer
	rawConnection, dialErr := dialer.DialContext(s.ctx, N.NetworkTCP, destination)
	if dialErr != nil {
		return pppSessionCarrier{}, E.Cause(dialErr, "connect Fortinet TLS transport")
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
	deadline := time.Now().Add(fortinetTLSConnectTimeout)
	if contextDeadline, hasDeadline := s.ctx.Deadline(); hasDeadline && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	deadlineErr := rawConnection.SetDeadline(deadline)
	if deadlineErr != nil {
		return pppSessionCarrier{}, E.Cause(deadlineErr, "set Fortinet TLS connection deadline")
	}
	tlsConfiguration := s.client.tlsConfig.Clone()
	if tlsConfiguration.ServerName == "" {
		tlsConfiguration.ServerName = s.snapshot.serverURL.Hostname()
	}
	tlsConfiguration.NextProtos = []string{"http/1.1"}
	tlsConnection := tls.Client(rawConnection, tlsConfiguration)
	handshakeErr := tlsConnection.HandshakeContext(s.ctx)
	if handshakeErr != nil {
		return pppSessionCarrier{}, E.Cause(handshakeErr, "handshake Fortinet TLS transport")
	}
	writeErr := writeFortinetBytes(tlsConnection, configuration.tlsConnectRequest)
	if writeErr != nil {
		return pppSessionCarrier{}, writeErr
	}
	clearDeadlineErr := tlsConnection.SetDeadline(time.Time{})
	if clearDeadlineErr != nil {
		return pppSessionCarrier{}, E.Cause(clearDeadlineErr, "clear Fortinet TLS connection deadline")
	}
	localSourceIP := parseFortinetRemoteAddress(tlsConnection.LocalAddr())
	if !localSourceIP.IsValid() {
		return pppSessionCarrier{}, E.New("TLS transport has no local source IP")
	}
	setupComplete = true
	return pppSessionCarrier{
		connection: &fortinetTLSConn{
			Conn:                tlsConnection,
			classificationReady: make(chan struct{}),
		},
		localSourceIP: localSourceIP,
		mtu:           configuration.configuration.MTU,
	}, nil
}

func (s *fortinetSession) connectPPPDTLS(ctx context.Context) (pppSessionCarrier, error) {
	configuration := s.configuration
	serverPort, portErr := fortinetURLPort(s.snapshot.serverURL)
	if portErr != nil {
		return pppSessionCarrier{}, portErr
	}
	tlsConfiguration := s.client.tlsConfig.Clone()
	if tlsConfiguration.ServerName == "" {
		tlsConfiguration.ServerName = s.snapshot.serverURL.Hostname()
	}
	connection, connectErr := connectCertificateDTLS(ctx, certificateDTLSNegotiation{
		Address:    net.JoinHostPort(s.snapshot.acceptedAddress.String(), strconv.Itoa(int(serverPort))),
		ServerName: s.snapshot.serverURL.Hostname(),
		TLSConfig:  tlsConfiguration,
		Dialer:     s.client.options.Dialer,
		MTU:        fortinetDTLSRecordMTU(s.snapshot.acceptedAddress),
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
	if connection.DataMTU() > 0 && len(configuration.dtlsConnectRequest) > connection.DataMTU() {
		return pppSessionCarrier{}, E.New("DTLS client hello exceeds negotiated datagram MTU")
	}
	applicationConnection, probeErr := probeFortinetDTLS(ctx, connection, configuration.dtlsConnectRequest)
	if probeErr != nil {
		return pppSessionCarrier{}, probeErr
	}
	dataMTU := connection.DataMTU() - 10
	if dataMTU < pppMinimumMRU {
		return pppSessionCarrier{}, E.New("DTLS data MTU is too small for PPP")
	}
	tunnelMTU := min(int(configuration.configuration.MTU), dataMTU)
	localSourceIP := parseFortinetRemoteAddress(connection.LocalAddr())
	if !localSourceIP.IsValid() {
		return pppSessionCarrier{}, E.New("DTLS transport has no local source IP")
	}
	setupComplete = true
	return pppSessionCarrier{
		connection:    applicationConnection,
		datagram:      true,
		localSourceIP: localSourceIP,
		mtu:           uint32(tunnelMTU),
	}, nil
}

func probeFortinetDTLS(
	ctx context.Context,
	connection net.Conn,
	clientHello []byte,
) (net.Conn, error) {
	buffer := make([]byte, 65536)
	for {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		written, writeErr := connection.Write(clientHello)
		if writeErr != nil {
			return nil, E.Cause(writeErr, "write Fortinet DTLS client hello")
		}
		if written != len(clientHello) {
			return nil, E.New("short Fortinet DTLS client hello write")
		}
		readDeadline := time.Now().Add(time.Second)
		if contextDeadline, hasDeadline := ctx.Deadline(); hasDeadline && contextDeadline.Before(readDeadline) {
			readDeadline = contextDeadline
		}
		deadlineErr := connection.SetReadDeadline(readDeadline)
		if deadlineErr != nil {
			return nil, E.Cause(deadlineErr, "set Fortinet DTLS probe deadline")
		}
		readLength, readErr := connection.Read(buffer)
		if readErr != nil {
			if networkErr, loaded := readErr.(net.Error); loaded && networkErr.Timeout() && ctx.Err() == nil {
				continue
			}
			return nil, E.Cause(readErr, "read Fortinet DTLS server hello")
		}
		response := append([]byte(nil), buffer[:readLength]...)
		if validFortinetDTLSServerHello(response) {
			clearDeadlineErr := connection.SetDeadline(time.Time{})
			if clearDeadlineErr != nil {
				return nil, E.Cause(clearDeadlineErr, "clear Fortinet DTLS probe deadline")
			}
			return &fortinetBufferedDatagramConn{Conn: connection}, nil
		}
		if validFortinetPPPDatagram(response) {
			clearDeadlineErr := connection.SetDeadline(time.Time{})
			if clearDeadlineErr != nil {
				return nil, E.Cause(clearDeadlineErr, "clear Fortinet DTLS probe deadline")
			}
			return &fortinetBufferedDatagramConn{Conn: connection, initial: response}, nil
		}
		return nil, E.Extend(ErrProtocolNotSupported, "malformed or rejected Fortinet DTLS server hello")
	}
}

func validFortinetDTLSServerHello(content []byte) bool {
	prefix := []byte("GFtype\x00svrhello\x00handshake\x00")
	if len(content) < 2+len(prefix)+2 || int(binary.BigEndian.Uint16(content[:2])) != len(content) || !bytes.Equal(content[2:2+len(prefix)], prefix) {
		return false
	}
	status := content[2+len(prefix):]
	return bytes.Equal(status, []byte("ok")) || bytes.Equal(status, []byte{'o', 'k', 0})
}

func validFortinetPPPDatagram(content []byte) bool {
	if len(content) < 6 || int(binary.BigEndian.Uint16(content[:2])) != len(content) || binary.BigEndian.Uint16(content[2:4]) != pppFortinetMagic {
		return false
	}
	payloadLength := int(binary.BigEndian.Uint16(content[4:6]))
	return payloadLength > 0 && payloadLength+6 == len(content)
}

func fortinetDTLSRecordMTU(acceptedAddress netip.Addr) int {
	if acceptedAddress.Is6() {
		return 1232
	}
	return 1400
}

func writeFortinetBytes(connection net.Conn, content []byte) error {
	written := 0
	for written < len(content) {
		count, writeErr := connection.Write(content[written:])
		if writeErr != nil {
			return E.Cause(writeErr, "write Fortinet tunnel request")
		}
		if count <= 0 {
			return E.New("short Fortinet tunnel request write")
		}
		written += count
	}
	return nil
}

func (c *fortinetTLSConn) Write(content []byte) (int, error) {
	if c.classificationReady != nil {
		c.classificationWait.Do(func() {
			timer := time.NewTimer(fortinetTLSClassificationWait)
			defer timer.Stop()
			select {
			case <-c.classificationReady:
			case <-timer.C:
			}
		})
		if classificationErr, classified := c.pppCarrierError(); classified && classificationErr != nil {
			return 0, classificationErr
		}
	}
	written, writeErr := c.Conn.Write(content)
	if writeErr == nil || c.classificationReady == nil {
		return written, writeErr
	}
	timer := time.NewTimer(fortinetTLSFailureClassifyWait)
	defer timer.Stop()
	select {
	case <-c.classificationReady:
		if c.classificationErr != nil {
			return written, c.classificationErr
		}
	case <-timer.C:
	}
	return written, writeErr
}

func (c *fortinetTLSConn) publishClassification(err error) {
	if c.classificationReady == nil {
		return
	}
	c.classificationOnce.Do(func() {
		c.classificationErr = err
		close(c.classificationReady)
	})
}

func (c *fortinetTLSConn) pppCarrierError() (error, bool) {
	if c.classificationReady == nil {
		return nil, false
	}
	select {
	case <-c.classificationReady:
		return c.classificationErr, true
	default:
		return nil, false
	}
}

func (c *fortinetTLSConn) pppCarrierErrorReady() <-chan struct{} {
	return c.classificationReady
}

func (c *fortinetTLSConn) Read(content []byte) (int, error) {
	c.access.Lock()
	defer c.access.Unlock()
	if c.classified {
		if len(c.pending) > 0 {
			n := copy(content, c.pending)
			c.pending = c.pending[n:]
			return n, nil
		}
		if c.pendingErr != nil {
			pendingErr := c.pendingErr
			c.pendingErr = nil
			return 0, pendingErr
		}
		return c.Conn.Read(content)
	}
	prefix := []byte("HTTP/")
	buffer := make([]byte, 65536)
	for {
		n, readErr := c.Conn.Read(buffer)
		if n > 0 {
			c.pending = append(c.pending, buffer[:n]...)
		}
		comparisonLength := min(len(c.pending), len(prefix))
		if !bytes.Equal(c.pending[:comparisonLength], prefix[:comparisonLength]) {
			c.classified = true
			c.pendingErr = readErr
			c.publishClassification(nil)
			written := copy(content, c.pending)
			c.pending = c.pending[written:]
			return written, nil
		}
		if len(c.pending) >= len(prefix) {
			reader := bufio.NewReader(io.MultiReader(bytes.NewReader(c.pending), c.Conn))
			statusCode, responseErr := readFortinetHTTPStatus(reader)
			if responseErr != nil {
				classificationErr := markTerminal(E.Cause(responseErr, "parse Fortinet TLS tunnel failure response"))
				c.publishClassification(classificationErr)
				return 0, classificationErr
			}
			if statusCode >= 400 && statusCode <= 499 {
				c.publishClassification(ErrSessionRejected)
				return 0, ErrSessionRejected
			}
			classificationErr := markTerminal(E.New("response-less TLS switch unexpectedly returned HTTP status ", statusCode))
			c.publishClassification(classificationErr)
			return 0, classificationErr
		}
		if readErr != nil {
			classificationErr := markTerminal(E.Cause(readErr, "read partial Fortinet TLS response prefix"))
			c.publishClassification(classificationErr)
			return 0, classificationErr
		}
	}
}

func readFortinetHTTPStatus(reader *bufio.Reader) (int, error) {
	statusLine, statusErr := readFortinetHTTPLine(reader, fortinetMaximumStatusLine)
	if statusErr != nil {
		return 0, statusErr
	}
	parts := strings.Fields(statusLine)
	if len(parts) < 2 || !strings.HasPrefix(parts[0], "HTTP/") {
		return 0, E.New("invalid Fortinet HTTP status line")
	}
	statusCode, parseErr := strconv.Atoi(parts[1])
	if parseErr != nil || statusCode < 100 || statusCode > 999 {
		return 0, E.New("invalid Fortinet HTTP status code")
	}
	headerBytes := 0
	for {
		remaining := fortinetMaximumHeaderSize - headerBytes
		if remaining <= 0 {
			return 0, E.New("HTTP headers exceed ", fortinetMaximumHeaderSize, " bytes")
		}
		line, lineErr := readFortinetHTTPLine(reader, remaining)
		if lineErr != nil {
			return 0, lineErr
		}
		headerBytes += len(line) + 2
		if headerBytes > fortinetMaximumHeaderSize {
			return 0, E.New("HTTP headers exceed ", fortinetMaximumHeaderSize, " bytes")
		}
		if line == "" {
			return statusCode, nil
		}
		if !strings.Contains(line, ":") {
			return 0, E.New("malformed Fortinet HTTP response header")
		}
	}
}

func readFortinetHTTPLine(reader *bufio.Reader, maximum int) (string, error) {
	var content []byte
	for {
		fragment, continued, readErr := reader.ReadLine()
		if readErr != nil {
			return "", readErr
		}
		if len(content)+len(fragment) > maximum {
			return "", E.New("HTTP line exceeds ", maximum, " bytes")
		}
		content = append(content, fragment...)
		if !continued {
			return string(content), nil
		}
	}
}

func (c *fortinetBufferedDatagramConn) Read(content []byte) (int, error) {
	c.access.Lock()
	if len(c.initial) > 0 {
		if len(content) < len(c.initial) {
			c.access.Unlock()
			return 0, io.ErrShortBuffer
		}
		n := copy(content, c.initial)
		clear(c.initial)
		c.initial = nil
		c.access.Unlock()
		return n, nil
	}
	c.access.Unlock()
	for {
		n, readErr := c.Conn.Read(content)
		if readErr == nil && validFortinetDTLSServerHello(content[:n]) {
			continue
		}
		return n, readErr
	}
}

func (s *fortinetSession) setSkipInitialDTLS(skip bool) {
	s.state.access.Lock()
	s.state.skipInitialDTLS = skip
	s.state.access.Unlock()
}

func (s *fortinetSession) storePPPConfiguration(configurationState pppSessionConfigurationState) {
	s.state.access.Lock()
	s.state.previousIPv4 = configurationState.previousIPv4
	s.state.previousIPv6 = configurationState.previousIPv6
	s.state.hasPreviousAddresses = true
	s.state.connectedOnce = true
	if !s.state.initialSourceAddress.IsValid() {
		s.state.initialSourceAddress = configurationState.localSourceIP
	}
	s.state.droppedAt = time.Time{}
	s.state.access.Unlock()
	s.snapshot = s.state.snapshot()
}

func (s *fortinetSession) recordPPPTermination(termination pppSessionTermination) {
	if termination.err != nil && termination.wasReady {
		s.state.access.Lock()
		s.state.droppedAt = time.Now()
		if termination.usingDTLS {
			s.state.skipInitialDTLS = true
		}
		s.state.access.Unlock()
	}
}

var (
	_ clientSession = (*fortinetSession)(nil)
	_ net.Conn      = (*fortinetTLSConn)(nil)
	_ net.Conn      = (*fortinetBufferedDatagramConn)(nil)
)
