package openconnect

import (
	"bufio"
	"context"
	"crypto/md5" //nolint:gosec // Pulse sends a late informational MD5 certificate fingerprint AVP.
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"

	"golang.org/x/net/publicsuffix"
)

const (
	pulseConnectTimeout = 30 * time.Second
	pulseLogoutTimeout  = 5 * time.Second
)

type pulseFrontend struct {
	client        *Client
	localHostname string
}

type pulseAuthentication struct {
	access                sync.Mutex
	frontend              *pulseFrontend
	initializationErr     error
	serverURL             *url.URL
	acceptedAddress       netip.Addr
	jar                   http.CookieJar
	connection            *pulseIFTConnection
	ttlsConnection        *tls.Conn
	ttlsTransport         *pulseTTLSConn
	pending               *pulseAuthenticationChallenge
	tokenGenerator        *softwareTokenGenerator
	cookie                []byte
	authenticationExpires time.Time
	idleTimeout           time.Duration
	promptFlags           int
	userPrompt            string
	passwordPrompt        string
	secondaryUserPrompt   string
	secondaryPassPrompt   string
	previousGTC           bool
	started               bool
	connecting            bool
	closed                bool
	advancing             bool
	steps                 int
}

type pulseSessionState struct {
	access                sync.Mutex
	frontend              *pulseFrontend
	serverURL             *url.URL
	acceptedAddress       netip.Addr
	jar                   http.CookieJar
	cookie                []byte
	liveConnection        *pulseIFTConnection
	authenticationExpires time.Time
	idleTimeout           time.Duration
	activeSession         *pulseSession
	gracefulBye           bool
	closeOnce             sync.Once
	closeErr              error
}

type pulseSessionSnapshot struct {
	serverURL             *url.URL
	acceptedAddress       netip.Addr
	jar                   http.CookieJar
	cookie                []byte
	authenticationExpires time.Time
	idleTimeout           time.Duration
}

func init() {
	registerFlavorFrontend(FlavorPulse, func(client *Client) (flavorFrontend, error) {
		return newPulseFrontend(client)
	})
}

func newPulseFrontend(client *Client) (*pulseFrontend, error) {
	if client.options.ReportedOS == "" {
		client.options.ReportedOS = defaultReportedOS()
	}
	switch client.options.ReportedOS {
	case "linux", "linux-64", "win", "mac-intel", "android", "apple-ios":
	default:
		return nil, E.New("unsupported Pulse reported OS: ", client.options.ReportedOS)
	}
	return &pulseFrontend{client: client, localHostname: client.options.LocalHostname}, nil
}

func (f *pulseFrontend) BeginAuthentication() authContinuation {
	jar, err := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	authentication := &pulseAuthentication{
		frontend:          f,
		initializationErr: err,
		serverURL:         clonePulseURL(f.client.serverURL),
		jar:               jar,
		tokenGenerator:    newSoftwareTokenGenerator(f.client.options.Token),
		promptFlags:       pulsePromptPrimary | pulsePromptUsername | pulsePromptPassword,
	}
	directCookie := f.client.takeDirectCookie()
	if directCookie != "" && err == nil {
		authentication.cookie = []byte(directCookie)
		authentication.connecting = true
		jar.SetCookies(authentication.serverURL, []*http.Cookie{{Name: "DSID", Value: directCookie, Path: "/", Secure: true}})
	}
	return authentication
}

func (f *pulseFrontend) ConnectTunnel(ctx context.Context, obtained obtainedSession) (clientSession, error) {
	state, loaded := obtained.(*pulseSessionState)
	if !loaded || state == nil || state.frontend != f {
		return nil, E.Extend(ErrProtocolNotSupported, "invalid Pulse obtained session")
	}
	snapshot := state.snapshot()
	if snapshot.serverURL == nil || !snapshot.acceptedAddress.IsValid() || snapshot.jar == nil || len(snapshot.cookie) == 0 {
		clear(snapshot.cookie)
		return nil, ErrSessionRejected
	}
	clear(snapshot.cookie)
	return newPulseSession(ctx, f.client, state), nil
}

func (a *pulseAuthentication) Done() <-chan error {
	return nil
}

func (a *pulseAuthentication) Close() error {
	a.access.Lock()
	if a.closed {
		a.access.Unlock()
		return nil
	}
	a.closed = true
	connection := a.connection
	a.connection = nil
	ttlsTransport := a.ttlsTransport
	a.ttlsConnection = nil
	a.ttlsTransport = nil
	clear(a.cookie)
	a.cookie = nil
	a.pending = nil
	a.access.Unlock()
	var result error
	if connection != nil {
		closeErr := connection.Close()
		if closeErr != nil && !E.IsClosed(closeErr) {
			result = E.Cause(closeErr, "close Pulse authentication connection")
		}
	}
	if ttlsTransport != nil {
		result = E.Append(result, ttlsTransport.Close(), func(cause error) error {
			return E.Cause(cause, "close Pulse EAP-TTLS transport")
		})
	}
	return result
}

func (a *pulseAuthentication) Advance(
	ctx context.Context,
	response *authenticationResponse,
) (obtainedSession, *authenticationRequest, error) {
	a.access.Lock()
	if a.closed {
		a.access.Unlock()
		return nil, nil, ErrClientClosed
	}
	if a.advancing {
		a.access.Unlock()
		return nil, nil, E.Extend(ErrProtocolNotSupported, "authentication continuation is already advancing")
	}
	a.advancing = true
	a.access.Unlock()
	defer func() {
		a.access.Lock()
		a.advancing = false
		a.access.Unlock()
	}()
	stopCancellation := context.AfterFunc(ctx, a.interruptConnection)
	defer stopCancellation()
	if a.initializationErr != nil {
		return nil, nil, a.initializationErr
	}
	if !a.started {
		if response != nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "unexpected form response before Pulse authentication")
		}
		err := a.start(ctx)
		if err != nil {
			return nil, nil, err
		}
		a.started = true
	} else if a.pending != nil {
		if response == nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "missing Pulse authentication form response")
		}
		content, retryMessage, err := a.pending.buildResponse(*response)
		if err != nil {
			return nil, nil, err
		}
		if retryMessage != "" {
			a.pending.errorMessage = retryMessage
			request, requestErr := a.pending.formRequest(a.tokenGenerator)
			return nil, request, requestErr
		}
		err = a.sendExpandedResponse(a.pending.outerIdentifier, content)
		clear(content)
		if err != nil {
			return nil, nil, err
		}
		a.pending = nil
	} else if response != nil {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "unexpected Pulse authentication form response")
	}
	for {
		a.steps++
		if a.steps > pulseMaximumAuthenticationStep {
			return nil, nil, markTerminal(E.New("authentication exceeded ", pulseMaximumAuthenticationStep, " wire steps"))
		}
		packet, err := a.receiveExpandedRequest()
		if err != nil {
			return nil, nil, err
		}
		challenge, err := a.parseChallenge(packet)
		if err != nil {
			return nil, nil, err
		}
		if challenge.kind == pulseChallengeCookie {
			err = a.sendExpandedResponse(challenge.outerIdentifier, nil)
			if err != nil {
				return nil, nil, err
			}
			err = a.receiveAuthenticationSuccess()
			if err != nil {
				return nil, nil, err
			}
			return a.complete(), nil, nil
		}
		if a.connecting {
			return nil, nil, ErrSessionRejected
		}
		if challenge.kind == pulseChallengeSignIn {
			var value [4]byte
			binary.BigEndian.PutUint32(value[:], 1)
			content, buildErr := appendPulseAVP(nil, 0xd7c, pulseVendorJuniper2, value[:])
			if buildErr != nil {
				return nil, nil, buildErr
			}
			err = a.sendExpandedResponse(challenge.outerIdentifier, content)
			clear(content)
			if err != nil {
				return nil, nil, err
			}
			continue
		}
		a.pending = &challenge
		request, err := challenge.formRequest(a.tokenGenerator)
		if err != nil {
			return nil, nil, err
		}
		return nil, request, nil
	}
}

func (a *pulseAuthentication) start(ctx context.Context) error {
	connection, acceptedAddress, err := a.openConnection(ctx)
	if err != nil {
		return err
	}
	a.access.Lock()
	if a.closed {
		a.access.Unlock()
		_ = connection.Close()
		return ErrClientClosed
	}
	a.connection = connection
	a.acceptedAddress = acceptedAddress
	a.access.Unlock()
	contextErr := ctx.Err()
	if contextErr != nil {
		_ = connection.Close()
		return contextErr
	}
	versionPayload := []byte{0, 1, 2, 2}
	err = connection.writeFrame(pulseVendorTCG, pulseIFTVersionRequest, versionPayload)
	if err != nil {
		return E.Cause(err, "send Pulse IF-T version request")
	}
	frame, err := connection.readFrame(pulseAuthenticationFrameLimit)
	if err != nil {
		return err
	}
	if frame.vendor&0x00ffffff != pulseVendorTCG || frame.frameType != pulseIFTVersionResponse || len(frame.payload) != 4 {
		return markTerminal(E.New("unexpected Pulse IF-T version response"))
	}
	clientInformation := a.buildClientInformation()
	err = connection.writeFrame(pulseVendorJuniper, 0x88, clientInformation)
	clear(clientInformation)
	if err != nil {
		return E.Cause(err, "send Pulse client information")
	}
	frame, err = connection.readFrame(pulseAuthenticationFrameLimit)
	if err != nil {
		return err
	}
	if frame.vendor&0x00ffffff != pulseVendorTCG || frame.frameType != pulseIFTClientAuthChallenge || len(frame.payload) != 4 ||
		binary.BigEndian.Uint32(frame.payload) != pulseIFTAuthenticationJuniper {
		return markTerminal(E.New("unexpected initial Pulse authentication challenge"))
	}
	identity, err := buildPulseEAP(pulseEAPResponse, 1, pulseEAPTypeIdentity, 0, []byte("anonymous"))
	if err != nil {
		return err
	}
	authenticationPayload := buildPulseAuthenticationPayload(identity)
	err = connection.writeFrame(pulseVendorTCG, pulseIFTClientAuthResponse, authenticationPayload)
	clear(authenticationPayload)
	if err != nil {
		clear(identity)
		return E.Cause(err, "send Pulse anonymous EAP identity")
	}
	frame, err = connection.readFrame(pulseAuthenticationFrameLimit)
	if err != nil {
		clear(identity)
		return err
	}
	packet, err := parsePulseAuthenticationEAP(frame)
	if err != nil {
		clear(identity)
		return markTerminal(err)
	}
	if packet.typeValue == pulseEAPExpandedJuniper && packet.subtype == 1 {
		clear(identity)
	} else {
		if packet.typeValue != pulseEAPTypeTTLS {
			clear(identity)
			return markTerminal(E.New("server requested unsupported outer EAP type: ", packet.typeValue))
		}
		ttlsTransport := &pulseTTLSConn{outer: connection, identifier: packet.identifier}
		tlsConfiguration := a.frontend.client.tlsConfig.Clone()
		if tlsConfiguration.ServerName == "" {
			tlsConfiguration.ServerName = a.serverURL.Hostname()
		}
		tlsConfiguration.NextProtos = nil
		ttlsConnection := tls.Client(ttlsTransport, tlsConfiguration)
		err = ttlsConnection.HandshakeContext(ctx)
		if err != nil {
			clear(identity)
			_ = ttlsTransport.Close()
			return E.Cause(err, "handshake Pulse EAP-TTLS session")
		}
		err = writePulseInnerEAP(ttlsConnection, identity)
		clear(identity)
		if err != nil {
			_ = ttlsTransport.Close()
			return E.Cause(err, "send Pulse anonymous identity inside EAP-TTLS")
		}
		a.ttlsTransport = ttlsTransport
		a.ttlsConnection = ttlsConnection
		packet, err = readPulseInnerEAP(ttlsConnection)
		if err != nil {
			return err
		}
	}
	_, err = parsePulseAVPs(packet.payload)
	if err != nil {
		return markTerminal(E.Cause(err, "parse Pulse server information"))
	}
	content, err := a.buildAuthenticationClientAVPs()
	if err != nil {
		return err
	}
	err = a.sendExpandedResponse(packet.identifier, content)
	clear(content)
	return err
}

func (a *pulseAuthentication) openConnection(ctx context.Context) (*pulseIFTConnection, netip.Addr, error) {
	port, err := pulseURLPort(a.serverURL)
	if err != nil {
		return nil, netip.Addr{}, err
	}
	destinationHost := a.serverURL.Hostname()
	if a.acceptedAddress.IsValid() {
		destinationHost = a.acceptedAddress.String()
	}
	destination := M.ParseSocksaddrHostPort(destinationHost, port)
	rawConnection, err := a.frontend.client.options.Dialer.DialContext(ctx, N.NetworkTCP, destination)
	if err != nil {
		return nil, netip.Addr{}, E.Cause(err, "connect Pulse TLS endpoint")
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
	deadline := time.Now().Add(pulseConnectTimeout)
	contextDeadline, hasDeadline := ctx.Deadline()
	if hasDeadline && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	err = rawConnection.SetDeadline(deadline)
	if err != nil {
		return nil, netip.Addr{}, E.Cause(err, "set Pulse TLS connection deadline")
	}
	tlsConfiguration := a.frontend.client.tlsConfig.Clone()
	if tlsConfiguration.ServerName == "" {
		tlsConfiguration.ServerName = a.serverURL.Hostname()
	}
	tlsConfiguration.NextProtos = []string{"http/1.1"}
	tlsConnection := tls.Client(rawConnection, tlsConfiguration)
	err = tlsConnection.HandshakeContext(ctx)
	if err != nil {
		return nil, netip.Addr{}, E.Cause(err, "handshake Pulse TLS endpoint")
	}
	acceptedAddress := parseAnyConnectRemoteAddress(tlsConnection.RemoteAddr())
	if a.acceptedAddress.IsValid() {
		acceptedAddress = a.acceptedAddress
	}
	if !acceptedAddress.IsValid() {
		return nil, netip.Addr{}, markTerminal(E.New("TLS endpoint did not expose an accepted IP address"))
	}
	reader := bufio.NewReader(tlsConnection)
	err = a.writeUpgradeRequest(tlsConnection)
	if err != nil {
		return nil, netip.Addr{}, err
	}
	response, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
	if err != nil {
		return nil, netip.Addr{}, E.Cause(err, "read Pulse IF-T/TLS upgrade response")
	}
	if a.jar != nil {
		a.jar.SetCookies(a.serverURL, response.Cookies())
	}
	if response.StatusCode != http.StatusSwitchingProtocols {
		if response.Body != nil {
			_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
			_ = response.Body.Close()
		}
		if a.connecting && (response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden) {
			return nil, netip.Addr{}, ErrSessionRejected
		}
		statusErr := E.New("IF-T/TLS upgrade returned HTTP ", response.StatusCode)
		if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
			return nil, netip.Addr{}, E.Errors(ErrAuthenticationFailed, statusErr)
		}
		if response.StatusCode >= 400 && response.StatusCode < 500 {
			return nil, netip.Addr{}, markTerminal(statusErr)
		}
		return nil, netip.Addr{}, statusErr
	}
	err = tlsConnection.SetDeadline(time.Time{})
	if err != nil {
		return nil, netip.Addr{}, E.Cause(err, "clear Pulse TLS connection deadline")
	}
	setupComplete = true
	return &pulseIFTConnection{Conn: tlsConnection, reader: reader}, acceptedAddress, nil
}

func (a *pulseAuthentication) writeUpgradeRequest(w io.Writer) error {
	requestPath := a.serverURL.EscapedPath()
	if requestPath == "" {
		requestPath = "/"
	}
	if a.serverURL.RawQuery != "" {
		requestPath += "?" + a.serverURL.RawQuery
	}
	var request strings.Builder
	request.WriteString("GET ")
	request.WriteString(requestPath)
	request.WriteString(" HTTP/1.1\r\nHost: ")
	request.WriteString(a.serverURL.Host)
	request.WriteString("\r\nUser-Agent: ")
	request.WriteString(anyConnectUserAgent(a.frontend.client))
	request.WriteString("\r\n")
	if a.jar != nil {
		cookies := a.jar.Cookies(a.serverURL)
		if len(cookies) > 0 {
			request.WriteString("Cookie: ")
			for i, cookie := range cookies {
				if i > 0 {
					request.WriteString("; ")
				}
				request.WriteString(cookie.Name)
				request.WriteByte('=')
				request.WriteString(cookie.Value)
			}
			request.WriteString("\r\n")
		}
	}
	request.WriteString("Content-Type: EAP\r\nUpgrade: IF-T/TLS 1.0\r\nContent-Length: 0\r\n\r\n")
	return writePulseBytes(w, []byte(request.String()))
}

func (a *pulseAuthentication) buildClientInformation() []byte {
	var content strings.Builder
	content.WriteString("clientHostName=")
	content.WriteString(a.frontend.localHostname)
	if a.connection != nil {
		localAddress := parseAnyConnectRemoteAddress(a.connection.LocalAddr())
		if localAddress.IsValid() {
			content.WriteString(" clientIp=")
			content.WriteString(localAddress.String())
		}
	}
	content.WriteString(" clientCapabilities={}\n")
	content.WriteByte(0)
	return []byte(content.String())
}

func (a *pulseAuthentication) buildAuthenticationClientAVPs() ([]byte, error) {
	var content []byte
	var err error
	content, err = appendPulseAVP(content, 0xd5e, pulseVendorJuniper2, []byte(reportedGPOS(a.frontend.client)))
	if err != nil {
		return nil, err
	}
	userAgent := anyConnectUserAgent(a.frontend.client)
	if !a.frontend.client.options.IPv6Disabled && !strings.HasPrefix(userAgent, "Pulse-Secure/") {
		userAgent = "Pulse-Secure/22.2.1.1295 (" + userAgent + ")"
	}
	content, err = appendPulseAVP(content, 0xd70, pulseVendorJuniper2, []byte(userAgent))
	if err != nil {
		clear(content)
		return nil, err
	}
	if len(a.cookie) > 0 {
		content, err = appendPulseAVP(content, 0xd53, pulseVendorJuniper2, a.cookie)
		if err != nil {
			clear(content)
			return nil, err
		}
	}
	return content, nil
}

func (a *pulseAuthentication) receiveExpandedRequest() (pulseEAPPacket, error) {
	if a.ttlsConnection != nil {
		return readPulseInnerEAP(a.ttlsConnection)
	}
	frame, err := a.connection.readFrame(pulseAuthenticationFrameLimit)
	if err != nil {
		return pulseEAPPacket{}, err
	}
	packet, err := parsePulseAuthenticationEAP(frame)
	if err != nil {
		return pulseEAPPacket{}, markTerminal(err)
	}
	if packet.typeValue != pulseEAPExpandedJuniper || packet.subtype != 1 {
		return pulseEAPPacket{}, markTerminal(E.New("unexpected Pulse EAP authentication type"))
	}
	return packet, nil
}

func (a *pulseAuthentication) sendExpandedResponse(identifier byte, content []byte) error {
	packet, err := buildPulseEAP(pulseEAPResponse, identifier, pulseEAPTypeExpanded, 1, content)
	if err != nil {
		return err
	}
	defer clear(packet)
	if a.ttlsConnection != nil {
		err = writePulseInnerEAP(a.ttlsConnection, packet)
		if err != nil {
			return E.Cause(err, "send Pulse EAP response inside EAP-TTLS")
		}
		return nil
	}
	payload := buildPulseAuthenticationPayload(packet)
	err = a.connection.writeFrame(pulseVendorTCG, pulseIFTClientAuthResponse, payload)
	clear(payload)
	if err != nil {
		return E.Cause(err, "send Pulse IF-T authentication response")
	}
	return nil
}

func (a *pulseAuthentication) parseChallenge(packet pulseEAPPacket) (pulseAuthenticationChallenge, error) {
	attributes, err := parsePulseAVPs(packet.payload)
	if err != nil {
		return pulseAuthenticationChallenge{}, markTerminal(E.Cause(err, "parse Pulse authentication AVPs"))
	}
	challenge := pulseAuthenticationChallenge{outerIdentifier: packet.identifier, promptFlags: a.promptFlags}
	if a.previousGTC {
		challenge.promptFlags |= pulsePromptGTCNext
	} else {
		challenge.promptFlags &^= pulsePromptGTCNext
	}
	var realmEntry bool
	var signIn bool
	var cookieReceived bool
	for _, attribute := range attributes {
		if attribute.vendor == pulseVendorJuniper2 {
			switch attribute.code {
			case 0xd55:
				a.checkCertificateFingerprint(attribute.data)
			case 0xd65:
				choice, choiceErr := parsePulseSessionChoice(attribute.data)
				if choiceErr != nil {
					return pulseAuthenticationChallenge{}, markTerminal(E.Cause(choiceErr, "parse Pulse active session"))
				}
				challenge.sessions = append(challenge.sessions, choice)
			case 0xd60:
				return pulseAuthenticationChallenge{}, a.authenticationFailure(attribute.data)
			case 0xd80:
				a.userPrompt = normalizePulsePrompt(attribute.data)
			case 0xd81:
				a.passwordPrompt = normalizePulsePrompt(attribute.data)
			case 0xd82:
				a.secondaryUserPrompt = normalizePulsePrompt(attribute.data)
			case 0xd83:
				a.secondaryPassPrompt = normalizePulsePrompt(attribute.data)
			case 0xd73:
				if len(attribute.data) != 4 {
					return pulseAuthenticationChallenge{}, markTerminal(E.New("prompt flags have invalid length"))
				}
				switch binary.BigEndian.Uint32(attribute.data) {
				case 1:
					challenge.promptFlags = pulsePromptUsername | pulsePromptPassword
				case 3, 15:
					challenge.promptFlags = pulsePromptPassword
				case 5:
					challenge.promptFlags = pulsePromptUsername
				default:
					challenge.promptFlags = pulsePromptUsername | pulsePromptPassword
					if a.frontend.client.options.Logger != nil {
						a.frontend.client.options.Logger.WarnContext(a.frontend.client.options.Context, "Unknown Pulse D73 prompt value; requesting username and password")
					}
				}
			case 0xd7b:
				signIn = true
			case 0xd4e:
				challenge.realmChoices = append(challenge.realmChoices, string(attribute.data))
			case 0xd4f:
				realmEntry = true
			case 0xd51:
				challenge.regionChoices = append(challenge.regionChoices, string(attribute.data))
			case 0xd5c:
				if len(attribute.data) != 4 {
					return pulseAuthenticationChallenge{}, markTerminal(E.New("authentication expiration has invalid length"))
				}
				seconds := binary.BigEndian.Uint32(attribute.data)
				if seconds > 0 {
					a.authenticationExpires = time.Now().Add(time.Duration(seconds) * time.Second)
				}
			case 0xd75:
				if len(attribute.data) != 4 {
					return pulseAuthenticationChallenge{}, markTerminal(E.New("idle timeout has invalid length"))
				}
				a.idleTimeout = time.Duration(binary.BigEndian.Uint32(attribute.data)) * time.Second
			case 0xd53:
				if len(attribute.data) == 0 {
					return pulseAuthenticationChallenge{}, markTerminal(E.New("authentication returned an empty cookie"))
				}
				clear(a.cookie)
				a.cookie = append([]byte(nil), attribute.data...)
				a.jar.SetCookies(a.serverURL, []*http.Cookie{{Name: "DSID", Value: string(a.cookie), Secure: true, Path: "/"}})
				cookieReceived = true
			default:
				if attribute.flags&pulseAVPFlagMandatory != 0 {
					return pulseAuthenticationChallenge{}, markTerminal(E.New("unsupported mandatory Pulse AVP: ", attribute.code))
				}
			}
			continue
		}
		if attribute.vendor == 0 && attribute.code == pulseAVPEAPMessage {
			innerPacket, parseErr := parsePulseEAP(attribute.data)
			if parseErr != nil {
				return pulseAuthenticationChallenge{}, markTerminal(E.Cause(parseErr, "parse nested Pulse EAP request"))
			}
			if innerPacket.code != pulseEAPRequest {
				return pulseAuthenticationChallenge{}, markTerminal(E.New("unexpected nested Pulse EAP code"))
			}
			challenge.innerIdentifier = innerPacket.identifier
			if innerPacket.typeValue == pulseEAPTypeGTC {
				challenge.kind = pulseChallengeGTC
				challenge.gtcPrompt = string(innerPacket.payload)
				challenge.gtcNext = challenge.promptFlags&pulsePromptGTCNext != 0
				continue
			}
			if innerPacket.typeValue == pulseEAPExpandedJuniper {
				switch innerPacket.subtype {
				case 2:
					parseErr = a.parsePasswordChallenge(&challenge, innerPacket.payload)
				case 3:
					return pulseAuthenticationChallenge{}, markTerminal(E.Extend(ErrProtocolNotSupported, "server requested Host Checker; use the nc flavor"))
				case 5:
					parseErr = a.parseJuniper2021Challenge(&challenge, innerPacket.payload)
				default:
					parseErr = E.New("unsupported Pulse expanded EAP subtype: ", innerPacket.subtype)
				}
				if parseErr != nil {
					return pulseAuthenticationChallenge{}, markTerminal(parseErr)
				}
				continue
			}
			if innerPacket.typeValue == pulseEAPTypeTLS && !a.frontend.client.configuredTLSClientCertificate() {
				return pulseAuthenticationChallenge{}, markTerminal(E.Extend(ErrProtocolNotSupported, "server requested EAP-TLS inside EAP-TTLS without a configured client certificate"))
			}
			return pulseAuthenticationChallenge{}, markTerminal(E.New("unsupported Pulse nested EAP type: ", innerPacket.typeValue))
		}
		if attribute.flags&pulseAVPFlagMandatory != 0 {
			return pulseAuthenticationChallenge{}, markTerminal(E.New("unsupported mandatory Pulse AVP vendor: ", attribute.vendor))
		}
	}
	requestKind := challenge.kind
	categoryCount := 0
	if realmEntry {
		categoryCount++
	}
	if len(challenge.realmChoices) > 0 {
		categoryCount++
	}
	if len(challenge.regionChoices) > 0 {
		categoryCount++
	}
	if len(challenge.sessions) > 0 {
		categoryCount++
	}
	if requestKind == pulseChallengePassword || requestKind == pulseChallengePasswordChange || requestKind == pulseChallengeGTC {
		categoryCount++
	}
	if cookieReceived {
		categoryCount++
	}
	if categoryCount != 1 && !signIn {
		return pulseAuthenticationChallenge{}, markTerminal(E.New("authentication packet mixed or omitted request categories"))
	}
	switch {
	case cookieReceived:
		challenge.kind = pulseChallengeCookie
	case realmEntry:
		challenge.kind = pulseChallengeRealmEntry
	case len(challenge.realmChoices) > 0:
		challenge.kind = pulseChallengeRealmChoice
	case len(challenge.regionChoices) > 0:
		challenge.kind = pulseChallengeRegionChoice
	case requestKind == pulseChallengePassword || requestKind == pulseChallengePasswordChange || requestKind == pulseChallengeGTC:
		challenge.kind = requestKind
	case len(challenge.sessions) > 0:
		challenge.kind = pulseChallengeSession
	case signIn:
		challenge.kind = pulseChallengeSignIn
	default:
		return pulseAuthenticationChallenge{}, markTerminal(E.New("authentication packet omitted its request category"))
	}
	primary := challenge.promptFlags&pulsePromptPrimary != 0
	if primary {
		challenge.userPrompt = a.userPrompt
		challenge.passwordPrompt = a.passwordPrompt
	} else {
		challenge.userPrompt = a.secondaryUserPrompt
		challenge.passwordPrompt = a.secondaryPassPrompt
	}
	a.promptFlags = challenge.promptFlags
	a.previousGTC = challenge.kind == pulseChallengeGTC
	return challenge, nil
}

func (a *pulseAuthentication) parsePasswordChallenge(challenge *pulseAuthenticationChallenge, payload []byte) error {
	if len(payload) < 1 {
		return E.New("password challenge omitted its request code")
	}
	requestCode := payload[0]
	challenge.passwordRequestCode = requestCode
	switch requestCode {
	case pulseJuniperPasswordRequest, pulseJuniperPasswordRetry:
		if len(payload) != 1 {
			return E.New("password request has unexpected payload")
		}
		challenge.kind = pulseChallengePassword
		if requestCode == pulseJuniperPasswordRetry {
			challenge.errorMessage = "rejected the previous credentials."
		}
	case pulseJuniperPasswordChange:
		if len(payload) != 1 {
			return E.New("password-change request has unexpected payload")
		}
		challenge.kind = pulseChallengePasswordChange
	case pulseJuniperPasswordFailure:
		if len(payload) <= 3 || payload[1] != 1 || int(payload[2]) != len(payload)-1 {
			return E.New("invalid Pulse password-change failure payload")
		}
		return E.Errors(ErrAuthenticationFailed, E.New("password change failed: ", strings.TrimRight(string(payload[3:]), "\x00")))
	default:
		return E.New("unknown Pulse password request code: ", requestCode)
	}
	return nil
}

func (a *pulseAuthentication) parseJuniper2021Challenge(challenge *pulseAuthenticationChallenge, payload []byte) error {
	if len(payload) != 6 || payload[0] != pulseJuniperPasswordRequest {
		return E.New("unexpected Pulse Juniper/5 password request")
	}
	challenge.kind = pulseChallengePassword
	challenge.passwordRequestCode = payload[0]
	challenge.promptFlags |= pulsePromptJuniper2021
	return nil
}

func (a *pulseAuthentication) authenticationFailure(content []byte) error {
	if len(content) != 4 {
		return markTerminal(E.New("authentication failure code has invalid length"))
	}
	code := binary.BigEndian.Uint32(content)
	message := "authentication failed with code " + strconv.FormatUint(uint64(code), 16)
	switch code {
	case 0x0d:
		message = "authentication failed: account is locked"
	case 0x0e:
		message = "authentication failed: client certificate is required"
	}
	if a.connecting {
		return E.Errors(ErrSessionRejected, E.New(message))
	}
	return E.Errors(ErrAuthenticationFailed, E.New(message))
}

func (a *pulseAuthentication) checkCertificateFingerprint(content []byte) {
	if len(content) != md5.Size*2 || a.connection == nil {
		return
	}
	tlsConnection, loaded := a.connection.Conn.(*tls.Conn)
	if !loaded {
		return
	}
	state := tlsConnection.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return
	}
	fingerprint := md5.Sum(state.PeerCertificates[0].Raw) //nolint:gosec // Pulse exposes only this late informational digest.
	encoded := make([]byte, hex.EncodedLen(len(fingerprint)))
	hex.Encode(encoded, fingerprint[:])
	matched := strings.EqualFold(string(content), string(encoded))
	clear(encoded)
	if !matched && a.frontend.client.options.Logger != nil {
		a.frontend.client.options.Logger.WarnContext(a.frontend.client.options.Context, "server certificate MD5 AVP does not match the authenticated TLS peer")
	}
}

func (a *pulseAuthentication) receiveAuthenticationSuccess() error {
	if a.ttlsTransport != nil {
		err := a.ttlsTransport.flush()
		if err != nil {
			return E.Cause(err, "flush final Pulse EAP-TTLS response")
		}
		_ = a.ttlsTransport.Close()
		a.ttlsConnection = nil
		a.ttlsTransport = nil
	}
	frame, err := a.connection.readFrame(pulseAuthenticationFrameLimit)
	if err != nil {
		return err
	}
	if frame.vendor&0x00ffffff != pulseVendorTCG || frame.frameType != pulseIFTClientAuthSuccess || len(frame.payload) != 8 ||
		binary.BigEndian.Uint32(frame.payload[:4]) != pulseIFTAuthenticationJuniper {
		return markTerminal(E.New("unexpected Pulse IF-T authentication success frame"))
	}
	packet, err := parsePulseEAP(frame.payload[4:])
	if err != nil {
		return markTerminal(E.Cause(err, "parse Pulse EAP success"))
	}
	if packet.code != pulseEAPSuccess {
		return E.Errors(ErrAuthenticationFailed, E.New("server did not complete EAP authentication"))
	}
	return nil
}

func (a *pulseAuthentication) complete() *pulseSessionState {
	a.access.Lock()
	defer a.access.Unlock()
	state := &pulseSessionState{
		frontend:              a.frontend,
		serverURL:             clonePulseURL(a.serverURL),
		acceptedAddress:       a.acceptedAddress,
		jar:                   a.jar,
		cookie:                append([]byte(nil), a.cookie...),
		liveConnection:        a.connection,
		authenticationExpires: a.authenticationExpires,
		idleTimeout:           a.idleTimeout,
	}
	a.connection = nil
	clear(a.cookie)
	a.cookie = nil
	a.closed = true
	return state
}

func (a *pulseAuthentication) interruptConnection() {
	a.access.Lock()
	connection := a.connection
	a.access.Unlock()
	if connection != nil {
		_ = connection.Close()
	}
}

func newPulseReconnectAuthentication(state *pulseSessionState, snapshot pulseSessionSnapshot) *pulseAuthentication {
	return &pulseAuthentication{
		frontend:              state.frontend,
		serverURL:             clonePulseURL(snapshot.serverURL),
		acceptedAddress:       snapshot.acceptedAddress,
		jar:                   snapshot.jar,
		cookie:                append([]byte(nil), snapshot.cookie...),
		authenticationExpires: snapshot.authenticationExpires,
		idleTimeout:           snapshot.idleTimeout,
		promptFlags:           pulsePromptPrimary | pulsePromptUsername | pulsePromptPassword,
		connecting:            true,
	}
}

func (s *pulseSessionState) snapshot() pulseSessionSnapshot {
	s.access.Lock()
	defer s.access.Unlock()
	return pulseSessionSnapshot{
		serverURL:             clonePulseURL(s.serverURL),
		acceptedAddress:       s.acceptedAddress,
		jar:                   s.jar,
		cookie:                append([]byte(nil), s.cookie...),
		authenticationExpires: s.authenticationExpires,
		idleTimeout:           s.idleTimeout,
	}
}

func (s *pulseSessionState) takeLiveConnection(session *pulseSession) (*pulseIFTConnection, error) {
	s.access.Lock()
	defer s.access.Unlock()
	if s.activeSession != nil && s.activeSession != session {
		return nil, E.New("obtained session already owns an active tunnel")
	}
	if len(s.cookie) == 0 {
		return nil, ErrSessionRejected
	}
	s.activeSession = session
	s.gracefulBye = false
	connection := s.liveConnection
	s.liveConnection = nil
	return connection, nil
}

func (s *pulseSessionState) installReconnect(result *pulseSessionState, session *pulseSession) (*pulseIFTConnection, error) {
	if result == nil {
		return nil, E.New("cookie reconnect returned an empty session")
	}
	s.access.Lock()
	defer s.access.Unlock()
	if s.activeSession != session {
		return nil, ErrClientClosed
	}
	clear(s.cookie)
	s.cookie = append(s.cookie[:0], result.cookie...)
	s.jar = result.jar
	s.authenticationExpires = result.authenticationExpires
	s.idleTimeout = result.idleTimeout
	connection := result.liveConnection
	result.liveConnection = nil
	clear(result.cookie)
	result.cookie = nil
	return connection, nil
}

func (s *pulseSessionState) detachSession(session *pulseSession) {
	s.access.Lock()
	if s.activeSession == session {
		s.activeSession = nil
	}
	s.access.Unlock()
}

func (s *pulseSessionState) recordGracefulBye() {
	s.access.Lock()
	s.gracefulBye = true
	s.access.Unlock()
}

func (s *pulseSessionState) rejectCookie() {
	s.access.Lock()
	clear(s.cookie)
	s.cookie = nil
	s.access.Unlock()
}

func (s *pulseSessionState) Close() error {
	s.closeOnce.Do(func() {
		s.access.Lock()
		activeSession := s.activeSession
		liveConnection := s.liveConnection
		s.liveConnection = nil
		s.access.Unlock()
		if activeSession != nil {
			s.closeErr = activeSession.Close()
		}
		if liveConnection != nil {
			closeErr := liveConnection.Close()
			if closeErr != nil && !E.IsClosed(closeErr) {
				s.closeErr = E.Append(s.closeErr, closeErr, func(cause error) error {
					return E.Cause(cause, "close unused Pulse live connection")
				})
			}
		}
		s.access.Lock()
		gracefulBye := s.gracefulBye
		s.access.Unlock()
		snapshot := s.snapshot()
		if !snapshot.acceptedAddress.IsValid() || snapshot.serverURL == nil || snapshot.jar == nil || len(snapshot.cookie) == 0 {
			clear(snapshot.cookie)
		} else if !gracefulBye {
			logoutContext, cancelLogout := context.WithTimeout(context.Background(), pulseLogoutTimeout)
			logoutErr := s.frontend.logout(logoutContext, snapshot)
			cancelLogout()
			s.closeErr = E.Append(s.closeErr, logoutErr, func(cause error) error {
				return E.Cause(cause, "logout Pulse session")
			})
		}
		clear(snapshot.cookie)
		s.access.Lock()
		clear(s.cookie)
		s.cookie = nil
		s.jar = nil
		s.serverURL = nil
		s.access.Unlock()
	})
	return s.closeErr
}

func (f *pulseFrontend) logout(ctx context.Context, snapshot pulseSessionSnapshot) error {
	logoutURL := clonePulseURL(snapshot.serverURL)
	logoutURL.Path = "/dana-na/auth/logout.cgi"
	logoutURL.RawPath = ""
	logoutURL.RawQuery = ""
	port, err := pulseURLPort(logoutURL)
	if err != nil {
		return err
	}
	transport := f.client.httpTransport.Clone()
	defer transport.CloseIdleConnections()
	expectedHostname := logoutURL.Hostname()
	transport.DialContext = func(dialContext context.Context, network string, address string) (net.Conn, error) {
		hostname, portText, splitErr := net.SplitHostPort(address)
		if splitErr != nil {
			return nil, E.Cause(splitErr, "parse Pulse logout destination")
		}
		parsedPort, parseErr := strconv.ParseUint(portText, 10, 16)
		if parseErr != nil || uint16(parsedPort) != port || !strings.EqualFold(hostname, expectedHostname) {
			return nil, E.New("logout attempted to dial outside the accepted endpoint")
		}
		return f.client.options.Dialer.DialContext(dialContext, network, M.ParseSocksaddrHostPort(snapshot.acceptedAddress.String(), port))
	}
	logoutClient := &http.Client{
		Transport: f.client.wrapHTTPTransport(transport),
		Jar:       snapshot.jar,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, logoutURL.String(), nil)
	if err != nil {
		return E.Cause(err, "create Pulse logout request")
	}
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", anyConnectUserAgent(f.client))
	response, err := logoutClient.Do(request)
	if err != nil {
		return E.Cause(err, "send Pulse logout request")
	}
	_, readErr := io.Copy(io.Discard, io.LimitReader(response.Body, 1024*1024+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return E.Errors(E.Cause(readErr, "read Pulse logout response"), closeErr)
	}
	if closeErr != nil {
		return E.Cause(closeErr, "close Pulse logout response")
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return E.New("logout returned HTTP ", response.StatusCode)
	}
	return nil
}

func pulseURLPort(serverURL *url.URL) (uint16, error) {
	portText := serverURL.Port()
	if portText == "" {
		return 443, nil
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 {
		return 0, E.New("server URL has an invalid port")
	}
	return uint16(port), nil
}

func clonePulseURL(serverURL *url.URL) *url.URL {
	if serverURL == nil {
		return nil
	}
	cloned := *serverURL
	return &cloned
}
