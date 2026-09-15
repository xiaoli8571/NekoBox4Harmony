package openconnect

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/xml"
	"hash/crc32"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"

	"golang.org/x/net/publicsuffix"
)

type anyConnectHostScanResponse struct {
	statusCode int
	body       []byte
}

type anyConnectHostScanTokenXML struct {
	XMLName xml.Name
	Token   string `xml:"token"`
}

type anyConnectHostScanDataXML struct {
	Fields []anyConnectHostScanDataField `xml:"hostscan>field"`
}

type anyConnectHostScanDataField struct {
	Value string `xml:"value,attr"`
}

type anyConnectHostScanRequestedField struct {
	Kind  string
	Name  string
	Value string
}

var anyConnectHostScanHTMLRefresh = regexp.MustCompile(`(?i)http-equiv\s*=\s*["']\s*refresh\s*["']`)

// Upstream cstp_obtain_cookie runs CSD before collecting credentials, posts the scan with the token.xml token, then polls with the original host-scan-token before refreshing the pre-CSD authentication URL.
func (a *anyConnectAuthentication) runHostScan(ctx context.Context) error {
	state := a.hostScan
	baseURL, err := resolveAnyConnectHostScanURL(a.currentURL, state.BaseURL)
	if err != nil {
		return markTerminal(E.Cause(err, "resolve AnyConnect CSD base URL"))
	}
	waitURL, err := resolveAnyConnectHostScanURL(a.currentURL, state.WaitURL)
	if err != nil {
		return markTerminal(E.Cause(err, "resolve AnyConnect CSD wait URL"))
	}
	if state.StubURL != "" {
		_, err = resolveAnyConnectHostScanURL(a.currentURL, state.StubURL)
		if err != nil {
			return markTerminal(E.Cause(err, "validate AnyConnect CSD stub URL"))
		}
	}
	authenticationJar, err := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	if err != nil {
		return markTerminal(E.Cause(err, "replace AnyConnect authentication cookie jar for CSD"))
	}
	// Upstream handle_auth_form removes every authentication cookie before starting CSD.
	a.frontend.authenticationClient.Jar = authenticationJar
	a.frontend.client.httpClient.Jar = authenticationJar
	hostScanJar, err := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	if err != nil {
		return markTerminal(E.Cause(err, "create AnyConnect CSD cookie jar"))
	}
	hostScanTransport := a.frontend.client.httpTransport.Clone()
	defer hostScanTransport.CloseIdleConnections()
	var hostScanAddressAccess sync.Mutex
	hostScanAddress := a.authenticatedAddress
	hostScanHost := a.currentURL.Hostname()
	hostScanTransport.DialContext = func(dialContext context.Context, network string, address string) (net.Conn, error) {
		destination := M.ParseSocksaddr(address)
		destinationHost, destinationPort, splitErr := net.SplitHostPort(address)
		pinDestination := splitErr == nil && strings.EqualFold(destinationHost, hostScanHost)
		hostScanAddressAccess.Lock()
		pinnedAddress := hostScanAddress
		hostScanAddressAccess.Unlock()
		if pinDestination && pinnedAddress.IsValid() {
			parsedPort, parseErr := strconv.ParseUint(destinationPort, 10, 16)
			if parseErr != nil {
				return nil, E.Cause(parseErr, "parse AnyConnect CSD destination port")
			}
			destination = M.ParseSocksaddrHostPort(pinnedAddress.String(), uint16(parsedPort))
		}
		conn, dialErr := a.frontend.client.options.Dialer.DialContext(dialContext, network, destination)
		if dialErr != nil {
			return nil, dialErr
		}
		if pinDestination && !pinnedAddress.IsValid() {
			remoteAddress := parseAnyConnectRemoteAddress(conn.RemoteAddr())
			if remoteAddress.IsValid() {
				hostScanAddressAccess.Lock()
				if !hostScanAddress.IsValid() {
					hostScanAddress = remoteAddress
				}
				hostScanAddressAccess.Unlock()
			}
		}
		return conn, nil
	}
	hostScanClient := &http.Client{
		Transport: a.frontend.client.wrapHTTPTransport(hostScanTransport),
		Jar:       hostScanJar,
		CheckRedirect: func(request *http.Request, previous []*http.Request) error {
			if len(previous) >= anyConnectMaximumRedirects {
				return markTerminal(E.New("CSD exceeded ", anyConnectMaximumRedirects, " redirects"))
			}
			return validateAnyConnectHostScanURL(request.URL)
		},
	}
	if a.frontend.client.options.CSD != nil && a.frontend.client.options.CSD.WrapperPath != "" {
		err = a.runAnyConnectHostScanWrapper(ctx, baseURL)
		hostScanAddressAccess.Lock()
		if a.authenticatedAddress.IsValid() {
			hostScanAddress = a.authenticatedAddress
		}
		hostScanAddressAccess.Unlock()
	} else {
		err = a.runBuiltInAnyConnectHostScan(ctx, hostScanClient)
		hostScanAddressAccess.Lock()
		if hostScanAddress.IsValid() {
			a.authenticatedAddress = hostScanAddress
		}
		hostScanAddressAccess.Unlock()
	}
	if err != nil {
		return err
	}
	err = setAnyConnectHostScanCookie(hostScanJar, waitURL, state.Token)
	if err != nil {
		return err
	}
	err = setAnyConnectHostScanCookie(a.frontend.authenticationClient.Jar, a.currentURL, state.Token)
	if err != nil {
		return err
	}
	err = a.pollAnyConnectHostScanWait(ctx, hostScanClient, waitURL)
	if err != nil {
		return err
	}
	a.hostScan = anyConnectHostScan{}
	a.hostScanCompleted = true
	return nil
}

// Upstream csd-post.sh fetches token.xml and optional data.xml, posts the endpoint report to scan.xml with the fetched sdesktop token, and never executes the downloaded Cisco stub.
func (a *anyConnectAuthentication) runBuiltInAnyConnectHostScan(ctx context.Context, client *http.Client) error {
	tokenURL := anyConnectHostScanEndpoint(a.currentURL, "/+CSCOE+/sdesktop/token.xml")
	query := tokenURL.Query()
	query.Set("ticket", a.hostScan.Ticket)
	query.Set("stub", "0")
	tokenURL.RawQuery = query.Encode()
	response, err := a.doAnyConnectHostScanRequest(ctx, client, http.MethodGet, tokenURL, "", nil)
	if err != nil {
		return err
	}
	if response.statusCode != http.StatusOK {
		return anyConnectHTTPStatusError(response.statusCode, "CSD token request returned HTTP ")
	}
	var tokenDocument anyConnectHostScanTokenXML
	decoder := xml.NewDecoder(bytes.NewReader(response.body))
	decoder.Strict = false
	err = decoder.Decode(&tokenDocument)
	if err != nil {
		return markTerminal(E.Cause(err, "parse AnyConnect CSD token response"))
	}
	if tokenDocument.XMLName.Local != "hostscan" {
		return markTerminal(E.New("unexpected AnyConnect CSD token XML root: ", tokenDocument.XMLName.Local))
	}
	scanToken := strings.TrimSpace(tokenDocument.Token)
	if scanToken == "" {
		return markTerminal(E.New("CSD token response omitted token"))
	}
	requestedFields, err := a.fetchAnyConnectHostScanData(ctx, client)
	if err != nil {
		return err
	}
	report, err := buildAnyConnectHostScanReport(
		ctx,
		requestedFields,
		a.frontend.client.options.LocalHostname,
		a.frontend.client.options.Logger,
		a.frontend.client.options.Context,
	)
	if err != nil {
		return err
	}
	scanURL := anyConnectHostScanEndpoint(a.currentURL, "/+CSCOE+/sdesktop/scan.xml")
	query = scanURL.Query()
	query.Set("reusebrowser", "1")
	scanURL.RawQuery = query.Encode()
	err = setAnyConnectHostScanCookie(client.Jar, scanURL, scanToken)
	if err != nil {
		return err
	}
	response, err = a.doAnyConnectHostScanRequest(ctx, client, http.MethodPost, scanURL, "text/xml", report)
	if err != nil {
		return err
	}
	if response.statusCode < http.StatusOK || response.statusCode >= http.StatusMultipleChoices {
		return anyConnectHTTPStatusError(response.statusCode, "CSD scan submission returned HTTP ")
	}
	return nil
}

func (a *anyConnectAuthentication) fetchAnyConnectHostScanData(ctx context.Context, client *http.Client) ([]anyConnectHostScanRequestedField, error) {
	dataURL := anyConnectHostScanEndpoint(a.currentURL, "/CACHE/sdesktop/data.xml")
	response, err := a.doAnyConnectHostScanRequest(ctx, client, http.MethodGet, dataURL, "", nil)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if a.frontend.client.options.Logger != nil {
			a.frontend.client.options.Logger.WarnContext(ctx, "optional AnyConnect CSD data request failed: ", err)
		}
		return nil, nil
	}
	if response.statusCode == http.StatusNotFound || response.statusCode == http.StatusGone || response.statusCode == http.StatusNoContent {
		return nil, nil
	}
	if response.statusCode != http.StatusOK {
		if a.frontend.client.options.Logger != nil {
			a.frontend.client.options.Logger.WarnContext(ctx, "optional AnyConnect CSD data request returned HTTP ", response.statusCode)
		}
		return nil, nil
	}
	var dataDocument anyConnectHostScanDataXML
	decoder := xml.NewDecoder(bytes.NewReader(response.body))
	decoder.Strict = false
	err = decoder.Decode(&dataDocument)
	if err != nil {
		if a.frontend.client.options.Logger != nil {
			a.frontend.client.options.Logger.WarnContext(ctx, "ignored malformed optional AnyConnect CSD data response: ", err)
		}
		return nil, nil
	}
	fields := make([]anyConnectHostScanRequestedField, 0, len(dataDocument.Fields))
	malformedFields := 0
	for _, dataField := range dataDocument.Fields {
		field, parseErr := parseAnyConnectHostScanRequestedField(dataField.Value)
		if parseErr != nil {
			malformedFields++
			if a.frontend.client.options.Logger != nil {
				a.frontend.client.options.Logger.DebugContext(ctx, "ignored malformed AnyConnect CSD data field: ", parseErr)
			}
			continue
		}
		fields = append(fields, field)
	}
	if malformedFields > 0 && a.frontend.client.options.Logger != nil {
		a.frontend.client.options.Logger.WarnContext(ctx, "ignored ", malformedFields, " malformed optional AnyConnect CSD data fields")
	}
	return fields, nil
}

func (a *anyConnectAuthentication) doAnyConnectHostScanRequest(
	ctx context.Context,
	client *http.Client,
	method string,
	targetURL *url.URL,
	contentType string,
	body []byte,
) (anyConnectHostScanResponse, error) {
	err := validateAnyConnectHostScanURL(targetURL)
	if err != nil {
		return anyConnectHostScanResponse{}, err
	}
	var bodyReader io.Reader
	if body != nil {
		bodyReader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, targetURL.String(), bodyReader)
	if err != nil {
		return anyConnectHostScanResponse{}, markTerminal(E.Cause(err, "create AnyConnect CSD request"))
	}
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", anyConnectUserAgent(a.frontend.client))
	if contentType != "" {
		request.Header.Set("Content-Type", contentType)
	}
	response, err := client.Do(request)
	if err != nil {
		if response != nil && response.Body != nil {
			closeErr := response.Body.Close()
			err = E.Append(err, closeErr, func(cause error) error {
				return E.Cause(cause, "close failed AnyConnect CSD response")
			})
		}
		return anyConnectHostScanResponse{}, E.Cause(err, "send AnyConnect CSD request")
	}
	responseBody, readErr := io.ReadAll(response.Body)
	closeErr := response.Body.Close()
	if readErr != nil {
		return anyConnectHostScanResponse{}, E.Errors(E.Cause(readErr, "read AnyConnect CSD response"), closeErr)
	}
	if closeErr != nil {
		return anyConnectHostScanResponse{}, E.Cause(closeErr, "close AnyConnect CSD response")
	}
	return anyConnectHostScanResponse{statusCode: response.StatusCode, body: responseBody}, nil
}

func (a *anyConnectAuthentication) pollAnyConnectHostScanWait(ctx context.Context, client *http.Client, waitURL *url.URL) error {
	for {
		response, err := a.doAnyConnectHostScanRequest(ctx, client, http.MethodGet, waitURL, "", nil)
		if err != nil {
			return err
		}
		if response.statusCode != http.StatusOK {
			return anyConnectHTTPStatusError(response.statusCode, "CSD wait request returned HTTP ")
		}
		trimmedBody := bytes.TrimSpace(response.body)
		if bytes.HasPrefix(trimmedBody, []byte("<?xml")) {
			return nil
		}
		if !anyConnectHostScanHTMLRefresh.Match(trimmedBody) {
			return markTerminal(E.New("CSD wait endpoint returned neither XML nor an HTML refresh page"))
		}
		timer := time.NewTimer(time.Second)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return ctx.Err()
		case <-timer.C:
		}
	}
}

// Upstream run_csd_script invokes the configured wrapper directly with an empty downloaded-stub argument, quoted legacy option values, CSD_SHA256/CSD_TOKEN/CSD_HOSTNAME, and ignores only a started wrapper's non-zero exit status.
func (a *anyConnectAuthentication) runAnyConnectHostScanWrapper(ctx context.Context, baseURL *url.URL) error {
	wrapperPath := a.frontend.client.options.CSD.WrapperPath
	var err error
	serverCertificate := a.peerCertificate
	if serverCertificate == nil {
		serverCertificate, err = a.probeAnyConnectHostScanCertificate(ctx, a.currentURL)
		if err != nil {
			return err
		}
	}
	serverMD5 := md5.Sum(serverCertificate.Raw)
	clientMD5Text := ""
	clientCertificate := a.frontend.client.selectedTLSClientCertificateDER()
	if len(clientCertificate) == 0 && len(a.frontend.client.tlsConfig.Certificates) > 0 && len(a.frontend.client.tlsConfig.Certificates[0].Certificate) > 0 {
		clientCertificate = a.frontend.client.tlsConfig.Certificates[0].Certificate[0]
	}
	if len(clientCertificate) > 0 {
		clientMD5 := md5.Sum(clientCertificate)
		clientMD5Text = strings.ToUpper(hex.EncodeToString(clientMD5[:]))
	}
	serverMD5Text := strings.ToUpper(hex.EncodeToString(serverMD5[:]))
	wrapperURL := cloneAnyConnectURL(baseURL)
	wrapperAuthority := a.currentURL.Host
	if a.authenticatedAddress.IsValid() {
		wrapperHostname := a.authenticatedAddress.String()
		if wrapperURL.Port() == "" {
			if a.authenticatedAddress.Is6() {
				wrapperURL.Host = "[" + wrapperHostname + "]"
			} else {
				wrapperURL.Host = wrapperHostname
			}
		} else {
			wrapperURL.Host = net.JoinHostPort(wrapperHostname, wrapperURL.Port())
		}
		wrapperAuthority = wrapperURL.Host
	}
	arguments := []string{
		"",
		"-ticket", strconv.Quote(a.hostScan.Ticket),
		"-stub", strconv.Quote("0"),
		"-group", strconv.Quote(a.selectedGroup),
		"-certhash", strconv.Quote(serverMD5Text + ":" + clientMD5Text),
		"-url", strconv.Quote(wrapperURL.String()),
		"-langselen",
	}
	publicKeyHash := sha256.Sum256(serverCertificate.RawSubjectPublicKeyInfo)
	environment := filterAnyConnectHostScanEnvironment(os.Environ())
	environment = append(environment,
		"CSD_SHA256="+base64.StdEncoding.EncodeToString(publicKeyHash[:]),
		"CSD_TOKEN="+a.hostScan.Token,
		"CSD_HOSTNAME="+wrapperAuthority,
	)
	command := exec.CommandContext(ctx, wrapperPath, arguments...)
	command.Env = environment
	err = command.Run()
	if err == nil {
		return nil
	}
	if ctx.Err() != nil {
		return E.Cause(ctx.Err(), "run AnyConnect CSD wrapper")
	}
	exitError, exited := err.(*exec.ExitError)
	if exited && exitError.ProcessState.Exited() {
		if a.frontend.client.options.Logger != nil {
			a.frontend.client.options.Logger.WarnContext(ctx, "CSD wrapper exited unsuccessfully; continuing as upstream does: ", err)
		}
		return nil
	}
	if exited {
		return markTerminal(E.Cause(err, "CSD wrapper terminated abnormally"))
	}
	return markTerminal(E.Cause(err, "start AnyConnect CSD wrapper"))
}

func (a *anyConnectAuthentication) probeAnyConnectHostScanCertificate(ctx context.Context, targetURL *url.URL) (*x509.Certificate, error) {
	address := targetURL.Host
	if targetURL.Port() == "" {
		address = net.JoinHostPort(targetURL.Hostname(), "443")
	}
	conn, err := a.frontend.client.httpTransport.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, E.Cause(err, "dial AnyConnect CSD wrapper TLS peer")
	}
	tlsConfig := a.frontend.client.tlsConfig.Clone()
	if tlsConfig.ServerName == "" {
		tlsConfig.ServerName = targetURL.Hostname()
	}
	tlsConfig.NextProtos = []string{"http/1.1"}
	tlsConn := tls.Client(conn, tlsConfig)
	err = tlsConn.HandshakeContext(ctx)
	if err != nil {
		closeErr := conn.Close()
		return nil, E.Errors(E.Cause(err, "handshake with AnyConnect CSD wrapper TLS peer"), closeErr)
	}
	connectionState := tlsConn.ConnectionState()
	if len(connectionState.PeerCertificates) == 0 {
		closeErr := tlsConn.Close()
		return nil, markTerminal(E.Errors(E.New("CSD wrapper TLS peer sent no certificate"), closeErr))
	}
	certificate := connectionState.PeerCertificates[0]
	authenticatedAddress := parseAnyConnectRemoteAddress(tlsConn.RemoteAddr())
	if authenticatedAddress.IsValid() {
		a.authenticatedAddress = authenticatedAddress
	}
	_ = tlsConn.Close()
	return certificate, nil
}

func resolveAnyConnectHostScanURL(baseURL *url.URL, reference string) (*url.URL, error) {
	referenceURL, err := url.Parse(reference)
	if err != nil {
		return nil, markTerminal(E.Cause(err, "parse AnyConnect CSD URL"))
	}
	resolvedURL := baseURL.ResolveReference(referenceURL)
	err = validateAnyConnectHostScanURL(resolvedURL)
	if err != nil {
		return nil, err
	}
	return resolvedURL, nil
}

func validateAnyConnectHostScanURL(targetURL *url.URL) error {
	if targetURL == nil || targetURL.Scheme != "https" || targetURL.Hostname() == "" {
		if targetURL == nil {
			return markTerminal(E.New("CSD URL is empty"))
		}
		return markTerminal(E.New("CSD URL is not an HTTPS host URL: ", targetURL.String()))
	}
	return nil
}

func anyConnectHostScanEndpoint(baseURL *url.URL, path string) *url.URL {
	targetURL := cloneAnyConnectURL(baseURL)
	targetURL.Path = path
	targetURL.RawPath = ""
	targetURL.RawQuery = ""
	targetURL.Fragment = ""
	targetURL.User = nil
	return targetURL
}

func setAnyConnectHostScanCookie(jar http.CookieJar, targetURL *url.URL, token string) error {
	cookie := &http.Cookie{
		Name:     "sdesktop",
		Value:    token,
		Path:     "/",
		Secure:   true,
		HttpOnly: true,
	}
	jar.SetCookies(targetURL, []*http.Cookie{cookie})
	return nil
}

func parseAnyConnectHostScanRequestedField(value string) (anyConnectHostScanRequestedField, error) {
	var parts [3]string
	position := 0
	for i := range parts {
		for position < len(value) && (value[position] == ' ' || value[position] == '\t') {
			position++
		}
		if position >= len(value) || value[position] != '\'' {
			return anyConnectHostScanRequestedField{}, E.New("invalid field tuple: ", value)
		}
		position++
		var part strings.Builder
		closed := false
		for position < len(value) {
			character := value[position]
			position++
			if character == '\\' && position < len(value) {
				part.WriteByte(value[position])
				position++
				continue
			}
			if character == '\'' {
				if position < len(value) && value[position] == '\'' {
					part.WriteByte('\'')
					position++
					continue
				}
				closed = true
				break
			}
			part.WriteByte(character)
		}
		if !closed {
			return anyConnectHostScanRequestedField{}, E.New("unterminated field tuple: ", value)
		}
		parts[i] = part.String()
		for position < len(value) && (value[position] == ' ' || value[position] == '\t') {
			position++
		}
		if i < len(parts)-1 {
			if position >= len(value) || value[position] != ',' {
				return anyConnectHostScanRequestedField{}, E.New("invalid field tuple separator: ", value)
			}
			position++
		}
	}
	if strings.TrimSpace(value[position:]) != "" {
		return anyConnectHostScanRequestedField{}, E.New("trailing field tuple data: ", value)
	}
	return anyConnectHostScanRequestedField{Kind: parts[0], Name: parts[1], Value: parts[2]}, nil
}

func buildAnyConnectHostScanReport(
	ctx context.Context,
	requestedFields []anyConnectHostScanRequestedField,
	localHostname string,
	logger interface {
		DebugContext(context.Context, ...any)
		WarnContext(context.Context, ...any)
	},
	logContext context.Context,
) ([]byte, error) {
	var report strings.Builder
	platform := localAnyConnectHostScanPlatform()
	appendAnyConnectHostScanValue(&report, "endpoint.os.version", platform.system)
	appendAnyConnectHostScanValue(&report, "endpoint.os.architecture", platform.machine)
	if platform.release != "" {
		appendAnyConnectHostScanValue(&report, "endpoint.os.servicepack", platform.release)
	}
	appendAnyConnectHostScanValue(&report, "endpoint.device.hostname", localHostname)
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, markTerminal(E.Cause(err, "list network interfaces for AnyConnect CSD report"))
	}
	macAddresses := make([]string, 0, len(interfaces))
	for _, networkInterface := range interfaces {
		macAddress := formatAnyConnectHostScanMAC(networkInterface.HardwareAddr)
		if macAddress != "" {
			macAddresses = append(macAddresses, macAddress)
		}
	}
	sort.Strings(macAddresses)
	for _, macAddress := range macAddresses {
		appendAnyConnectHostScanValue(&report, "endpoint.device.MAC["+strconv.Quote(macAddress)+"]", "true")
	}
	ipv4Ports := readAnyConnectHostScanListeningPorts("/proc/net/tcp")
	ipv6Ports := readAnyConnectHostScanListeningPorts("/proc/net/tcp6")
	allPorts := make(map[int]bool, len(ipv4Ports)+len(ipv6Ports))
	for port := range ipv4Ports {
		allPorts[port] = true
	}
	for port := range ipv6Ports {
		allPorts[port] = true
	}
	ports := make([]int, 0, len(allPorts))
	for port := range allPorts {
		ports = append(ports, port)
	}
	sort.Ints(ports)
	for _, port := range ports {
		portText := strconv.Itoa(port)
		appendAnyConnectHostScanValue(&report, "endpoint.device.port["+strconv.Quote(portText)+"]", "true")
		if ipv4Ports[port] {
			appendAnyConnectHostScanValue(&report, "endpoint.device.tcp4port["+strconv.Quote(portText)+"]", "true")
		}
		if ipv6Ports[port] {
			appendAnyConnectHostScanValue(&report, "endpoint.device.tcp6port["+strconv.Quote(portText)+"]", "true")
		}
	}
	omittedFields := make([]string, 0)
	for _, field := range requestedFields {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		switch field.Kind {
		case "File":
			err = appendAnyConnectHostScanFile(ctx, &report, field)
			if err != nil {
				omittedFields = append(omittedFields, "File "+strconv.Quote(field.Name))
				if logger != nil {
					logger.DebugContext(logContext, "could not inspect AnyConnect CSD file field ", field.Name, ": ", err)
				}
			}
		case "Process":
			exists, known := localAnyConnectHostScanProcessExists(field.Value)
			if !known {
				omittedFields = append(omittedFields, "Process "+strconv.Quote(field.Name))
				if logger != nil {
					logger.DebugContext(logContext, "could not enumerate processes for AnyConnect CSD field ", field.Name)
				}
				continue
			}
			prefix := "endpoint.process[" + strconv.Quote(field.Name) + "]"
			report.WriteString(prefix)
			report.WriteString("={};\n")
			appendAnyConnectHostScanValue(&report, prefix+".name", field.Value)
			appendAnyConnectHostScanValue(&report, prefix+".exists", strconv.FormatBool(exists))
		case "Registry":
			omittedFields = append(omittedFields, "Registry "+strconv.Quote(field.Name))
			if logger != nil {
				logger.DebugContext(logContext, "ignored unsupported AnyConnect CSD Registry field ", field.Name)
			}
		default:
			omittedFields = append(omittedFields, field.Kind+" "+strconv.Quote(field.Name))
			if logger != nil {
				logger.DebugContext(logContext, "ignored unsupported AnyConnect CSD field kind ", field.Kind, " for ", field.Name)
			}
		}
	}
	if len(omittedFields) > 0 && logger != nil {
		logger.WarnContext(logContext, "CSD report omitted or incompletely inspected ", len(omittedFields), " requested fields")
	}
	return []byte(report.String()), nil
}

func appendAnyConnectHostScanFile(ctx context.Context, report *strings.Builder, field anyConnectHostScanRequestedField) error {
	prefix := "endpoint.file[" + strconv.Quote(field.Name) + "]"
	report.WriteString(prefix)
	report.WriteString("={};\n")
	appendAnyConnectHostScanValue(report, prefix+".path", field.Value)
	appendAnyConnectHostScanValue(report, prefix+".name", filepath.Base(field.Value))
	fileInfo, err := os.Stat(field.Value)
	if err != nil {
		if os.IsNotExist(err) {
			appendAnyConnectHostScanValue(report, prefix+".exists", "false")
			return nil
		}
		return err
	}
	appendAnyConnectHostScanValue(report, prefix+".exists", "true")
	timestamp := fileInfo.ModTime().Unix()
	appendAnyConnectHostScanValue(report, prefix+".timestamp", strconv.FormatInt(timestamp, 10))
	secondsSinceModification := max(time.Now().Unix()-timestamp, 0)
	appendAnyConnectHostScanValue(report, prefix+".lastmodified", strconv.FormatInt(secondsSinceModification, 10))
	if !fileInfo.Mode().IsRegular() {
		return nil
	}
	file, err := os.Open(field.Value)
	if err != nil {
		return err
	}
	checksum := crc32.NewIEEE()
	buffer := make([]byte, 32*1024)
	for {
		select {
		case <-ctx.Done():
			closeErr := file.Close()
			return E.Errors(ctx.Err(), closeErr)
		default:
		}
		n, readErr := file.Read(buffer)
		if n > 0 {
			_, writeErr := checksum.Write(buffer[:n])
			if writeErr != nil {
				closeErr := file.Close()
				return E.Errors(writeErr, closeErr)
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			closeErr := file.Close()
			return E.Errors(readErr, closeErr)
		}
	}
	err = file.Close()
	if err != nil {
		return E.Cause(err, "close AnyConnect CSD inspected file")
	}
	appendAnyConnectHostScanValue(report, prefix+".crc32", "0x"+hex.EncodeToString(checksum.Sum(nil)))
	return nil
}

func appendAnyConnectHostScanValue(report *strings.Builder, name string, value string) {
	report.WriteString(name)
	report.WriteByte('=')
	report.WriteString(strconv.QuoteToASCII(value))
	report.WriteString(";\n")
}

func formatAnyConnectHostScanMAC(address net.HardwareAddr) string {
	if len(address) != 6 {
		return ""
	}
	allZero := true
	for _, value := range address {
		if value != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		return ""
	}
	hexAddress := strings.ToUpper(hex.EncodeToString(address))
	return hexAddress[:4] + "." + hexAddress[4:8] + "." + hexAddress[8:]
}

func readAnyConnectHostScanListeningPorts(path string) map[int]bool {
	ports := make(map[int]bool)
	content, err := os.ReadFile(path)
	if err != nil {
		return ports
	}
	for line := range strings.SplitSeq(string(content), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 || fields[3] != "0A" {
			continue
		}
		separator := strings.LastIndexByte(fields[1], ':')
		if separator < 0 || separator == len(fields[1])-1 {
			continue
		}
		portValue, parseErr := strconv.ParseUint(fields[1][separator+1:], 16, 16)
		if parseErr == nil && portValue > 0 {
			ports[int(portValue)] = true
		}
	}
	return ports
}

func localAnyConnectHostScanProcessExists(processName string) (bool, bool) {
	targetName := filepath.Base(processName)
	executable, executableErr := os.Executable()
	if executableErr == nil && (filepath.Base(executable) == targetName || filepath.Base(os.Args[0]) == targetName) {
		return true, true
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return false, false
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		_, parseErr := strconv.ParseUint(entry.Name(), 10, 32)
		if parseErr != nil {
			continue
		}
		processDir := filepath.Join("/proc", entry.Name())
		commandNameContent, readErr := os.ReadFile(filepath.Join(processDir, "comm"))
		if readErr == nil && strings.TrimSpace(string(commandNameContent)) == targetName {
			return true, true
		}
		processExecutable, linkErr := os.Readlink(filepath.Join(processDir, "exe"))
		if linkErr == nil && filepath.Base(strings.TrimSuffix(processExecutable, " (deleted)")) == targetName {
			return true, true
		}
		commandLine, commandErr := os.ReadFile(filepath.Join(processDir, "cmdline"))
		if commandErr == nil {
			firstArgument := commandLine
			if separator := bytes.IndexByte(firstArgument, 0); separator >= 0 {
				firstArgument = firstArgument[:separator]
			}
			if filepath.Base(string(firstArgument)) == targetName {
				return true, true
			}
		}
	}
	return false, anyConnectHostScanProcessEnumerationReliable()
}

func anyConnectHostScanProcessEnumerationReliable() bool {
	content, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return false
	}
	for line := range strings.SplitSeq(string(content), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 || fields[1] != "/proc" || fields[2] != "proc" {
			continue
		}
		for option := range strings.SplitSeq(fields[3], ",") {
			if strings.HasPrefix(option, "hidepid=") && option != "hidepid=0" {
				return false
			}
		}
		return true
	}
	return false
}

func filterAnyConnectHostScanEnvironment(environment []string) []string {
	filtered := make([]string, 0, len(environment))
	for _, entry := range environment {
		name, _, found := strings.Cut(entry, "=")
		if found && (name == "CSD_SHA256" || name == "CSD_TOKEN" || name == "CSD_HOSTNAME") {
			continue
		}
		filtered = append(filtered, entry)
	}
	return filtered
}
