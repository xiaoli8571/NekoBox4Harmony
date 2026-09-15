package openconnect

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/xml"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
)

const (
	gpHIPDefaultInterval     = time.Hour
	gpHIPMaximumResponseBody = 8 * 1024 * 1024
	gpHIPMaximumReportBody   = 8 * 1024 * 1024
)

type gpHIPRunner struct {
	client               *Client
	checkURL             *url.URL
	reportURL            *url.URL
	authenticatedAddress netip.Addr
	cookie               string
	cookieIdentity       gpHIPCookieIdentity
	assignedIPv4         netip.Addr
	assignedIPv6         netip.Addr
	appVersion           string
	reportedOS           string
	interval             time.Duration
	md5                  string
}

type gpHIPCookieIdentity struct {
	user   string
	domain string
}

type gpHIPCheckResult struct {
	ReportNeeded    bool
	ReportSubmitted bool
	NextCheck       time.Duration
}

type gpHIPResponseXML struct {
	XMLName         xml.Name
	Status          string `xml:"status,attr"`
	Error           string `xml:"error"`
	HIPReportNeeded string `xml:"hip-report-needed"`
}

type gpHIPReportXML struct {
	XMLName          xml.Name           `xml:"hip-report"`
	Name             string             `xml:"name,attr"`
	MD5Sum           string             `xml:"md5-sum"`
	UserName         string             `xml:"user-name"`
	Domain           string             `xml:"domain"`
	HostName         string             `xml:"host-name"`
	IPAddress        string             `xml:"ip-address,omitempty"`
	IPv6Address      string             `xml:"ipv6-address,omitempty"`
	GenerateTime     string             `xml:"generate-time"`
	HIPReportVersion int                `xml:"hip-report-version"`
	Categories       gpHIPCategoriesXML `xml:"categories"`
}

type gpHIPCategoriesXML struct {
	Entries []gpHIPCategoryXML `xml:"entry"`
}

type gpHIPCategoryXML struct {
	Name                  string                     `xml:"name,attr"`
	ClientVersion         *string                    `xml:"client-version,omitempty"`
	OperatingSystem       string                     `xml:"os,omitempty"`
	OperatingSystemVendor string                     `xml:"os-vendor,omitempty"`
	Domain                *string                    `xml:"domain,omitempty"`
	HostName              string                     `xml:"host-name,omitempty"`
	NetworkInterfaces     *gpHIPNetworkInterfacesXML `xml:"network-interface,omitempty"`
	List                  *gpHIPEmptyXML             `xml:"list,omitempty"`
	MissingPatches        *gpHIPEmptyXML             `xml:"missing-patches,omitempty"`
}

type gpHIPNetworkInterfacesXML struct {
	Entries []gpHIPNetworkInterfaceXML `xml:"entry"`
}

type gpHIPNetworkInterfaceXML struct {
	Name       string `xml:"name,attr"`
	MACAddress string `xml:"mac-address"`
}

type gpHIPEmptyXML struct{}

type gpHIPBoundedBuffer struct {
	buffer      bytes.Buffer
	maximumSize int
	exceeded    bool
}

func newGPHIPRunner(
	client *Client,
	serverURL *url.URL,
	authenticatedAddress netip.Addr,
	opaqueCookie string,
	assignedIPv4 netip.Addr,
	assignedIPv6 netip.Addr,
	appVersion string,
	reportedGPOS string,
	interval time.Duration,
) (*gpHIPRunner, error) {
	if client == nil || client.httpClient == nil || client.httpTransport == nil {
		return nil, markTerminal(E.New("HIP requires an initialized client"))
	}
	if serverURL == nil || serverURL.Scheme != "https" || serverURL.Hostname() == "" || serverURL.User != nil || serverURL.Opaque != "" {
		return nil, markTerminal(E.New("HIP server must be an HTTPS host URL"))
	}
	serverPort := serverURL.Port()
	if serverPort != "" {
		parsedPort, err := strconv.ParseUint(serverPort, 10, 16)
		if err != nil || parsedPort == 0 {
			return nil, markTerminal(E.New("HIP server has an invalid port"))
		}
	}
	if !authenticatedAddress.IsValid() {
		return nil, markTerminal(E.New("HIP requires the authenticated gateway address"))
	}
	if opaqueCookie == "" {
		return nil, markTerminal(E.New("HIP requires an authentication cookie"))
	}
	assignedIPv4 = assignedIPv4.Unmap()
	assignedIPv6 = assignedIPv6.Unmap()
	if assignedIPv4.IsValid() && !assignedIPv4.Is4() {
		return nil, markTerminal(E.New("HIP assigned IPv4 address is not IPv4"))
	}
	if assignedIPv6.IsValid() && !assignedIPv6.Is6() {
		return nil, markTerminal(E.New("HIP assigned IPv6 address is not IPv6"))
	}
	if !assignedIPv4.IsValid() && !assignedIPv6.IsValid() {
		return nil, markTerminal(E.New("HIP requires an assigned IP address"))
	}
	if reportedGPOS == "" {
		return nil, markTerminal(E.New("HIP requires a reported GlobalProtect OS"))
	}
	md5Text, cookieIdentity, err := buildGPHIPToken(opaqueCookie)
	if err != nil {
		return nil, err
	}
	if interval <= 0 {
		interval = gpHIPDefaultInterval
	}
	checkURL := *serverURL
	checkURL.Path = "/ssl-vpn/hipreportcheck.esp"
	checkURL.RawPath = ""
	checkURL.RawQuery = ""
	checkURL.ForceQuery = false
	checkURL.Fragment = ""
	checkURL.User = nil
	reportURL := checkURL
	reportURL.Path = "/ssl-vpn/hipreport.esp"
	return &gpHIPRunner{
		client:               client,
		checkURL:             &checkURL,
		reportURL:            &reportURL,
		authenticatedAddress: authenticatedAddress.Unmap(),
		cookie:               opaqueCookie,
		cookieIdentity:       cookieIdentity,
		assignedIPv4:         assignedIPv4,
		assignedIPv6:         assignedIPv6,
		appVersion:           appVersion,
		reportedOS:           reportedGPOS,
		interval:             interval,
		md5:                  md5Text,
	}, nil
}

func (r *gpHIPRunner) Check(ctx context.Context) (gpHIPCheckResult, error) {
	result := gpHIPCheckResult{NextCheck: r.interval}
	transport := r.client.httpTransport.Clone()
	defer transport.CloseIdleConnections()
	gatewayHost := r.checkURL.Hostname()
	transport.DialContext = func(dialContext context.Context, network string, address string) (net.Conn, error) {
		destinationHost, destinationPort, err := net.SplitHostPort(address)
		if err != nil {
			return nil, markTerminal(E.Cause(err, "parse GlobalProtect HIP destination"))
		}
		if !strings.EqualFold(destinationHost, gatewayHost) {
			return nil, markTerminal(E.New("HIP attempted to dial outside the authenticated gateway origin"))
		}
		parsedPort, err := strconv.ParseUint(destinationPort, 10, 16)
		if err != nil || parsedPort == 0 {
			return nil, markTerminal(E.New("HIP attempted to dial an invalid gateway port"))
		}
		destination := M.ParseSocksaddrHostPort(r.authenticatedAddress.String(), uint16(parsedPort))
		dialer := r.client.options.Dialer
		conn, err := dialer.DialContext(dialContext, network, destination)
		if err != nil {
			return nil, err
		}
		return conn, nil
	}
	httpClient := &http.Client{
		Transport: r.client.wrapHTTPTransport(transport),
		Jar:       r.client.httpClient.Jar,
		CheckRedirect: func(request *http.Request, previousRequests []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	var checkBody strings.Builder
	checkBody.WriteString("client-role=global-protect-full&")
	checkBody.WriteString(r.cookie)
	if r.assignedIPv4.IsValid() {
		appendGPHIPFormOption(&checkBody, "client-ip", r.assignedIPv4.String())
	}
	if r.assignedIPv6.IsValid() {
		appendGPHIPFormOption(&checkBody, "client-ipv6", r.assignedIPv6.String())
	}
	appendGPHIPFormOption(&checkBody, "md5", r.md5)
	responseBody, err := r.post(ctx, httpClient, r.checkURL, checkBody.String(), "check")
	if err != nil {
		return gpHIPCheckResult{}, err
	}
	checkDocument, err := parseGPHIPResponse(responseBody, "check", r.cookie)
	if err != nil {
		return gpHIPCheckResult{}, err
	}
	switch strings.TrimSpace(checkDocument.HIPReportNeeded) {
	case "no":
		return result, nil
	case "yes":
		result.ReportNeeded = true
	default:
		return gpHIPCheckResult{}, markTerminal(E.New("HIP check response omitted a valid hip-report-needed value"))
	}
	var report []byte
	if r.client.options.HIP != nil && r.client.options.HIP.WrapperPath != "" {
		report, err = r.runWrapper(ctx)
	} else {
		report, err = r.buildReport()
	}
	if err != nil {
		return gpHIPCheckResult{}, err
	}
	var reportBody strings.Builder
	reportBody.WriteString("client-role=global-protect-full&")
	reportBody.WriteString(r.cookie)
	if r.assignedIPv4.IsValid() {
		appendGPHIPFormOption(&reportBody, "client-ip", r.assignedIPv4.String())
	}
	if r.assignedIPv6.IsValid() {
		appendGPHIPFormOption(&reportBody, "client-ipv6", r.assignedIPv6.String())
	}
	appendGPHIPFormOption(&reportBody, "report", string(report))
	responseBody, err = r.post(ctx, httpClient, r.reportURL, reportBody.String(), "report submission")
	if err != nil {
		return gpHIPCheckResult{}, err
	}
	_, err = parseGPHIPResponse(responseBody, "report submission", r.cookie)
	if err != nil {
		return gpHIPCheckResult{}, err
	}
	result.ReportSubmitted = true
	return result, nil
}

// Upstream build_csd_token hashes the unmodified query segments after removing only authcookie and the preferred address fields; the MD5 value is a correlation identifier, not a security primitive.
func buildGPHIPToken(cookie string) (string, gpHIPCookieIdentity, error) {
	var filteredCookie strings.Builder
	var identity gpHIPCookieIdentity
	for segment := range strings.SplitSeq(cookie, "&") {
		if segment == "" {
			continue
		}
		name, value, hasValue := strings.Cut(segment, "=")
		switch name {
		case "user", "domain":
			if hasValue {
				decodedValue, err := url.QueryUnescape(value)
				if err != nil {
					return "", gpHIPCookieIdentity{}, markTerminal(E.Cause(err, "decode GlobalProtect HIP cookie identity"))
				}
				switch name {
				case "user":
					if identity.user == "" {
						identity.user = decodedValue
					}
				case "domain":
					if identity.domain == "" {
						identity.domain = decodedValue
					}
				}
			}
		}
		switch name {
		case "authcookie", "preferred-ip", "preferred-ipv6":
			continue
		}
		if filteredCookie.Len() > 0 {
			filteredCookie.WriteByte('&')
		}
		filteredCookie.WriteString(segment)
	}
	//nolint:gosec // OpenConnect's GlobalProtect peer contract requires MD5 as this non-security correlation identifier.
	digest := md5.Sum([]byte(filteredCookie.String()))
	return hex.EncodeToString(digest[:]), identity, nil
}

func appendGPHIPFormOption(body *strings.Builder, name string, value string) {
	body.WriteByte('&')
	body.WriteString(encodeGPFormComponent(name))
	body.WriteByte('=')
	body.WriteString(encodeGPFormComponent(value))
}

// OpenConnect buf_append_urlencoded preserves RFC3986 unreserved bytes and encodes every other byte with lowercase %xx escapes.
func encodeGPFormComponent(value string) string {
	const hexadecimal = "0123456789abcdef"
	var encoded strings.Builder
	encoded.Grow(len(value))
	for i := 0; i < len(value); i++ {
		character := value[i]
		if character >= 'a' && character <= 'z' ||
			character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' ||
			character == '-' || character == '_' || character == '.' || character == '~' {
			encoded.WriteByte(character)
			continue
		}
		encoded.WriteByte('%')
		encoded.WriteByte(hexadecimal[character>>4])
		encoded.WriteByte(hexadecimal[character&0x0f])
	}
	return encoded.String()
}

func (r *gpHIPRunner) post(
	ctx context.Context,
	httpClient *http.Client,
	targetURL *url.URL,
	body string,
	operation string,
) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, targetURL.String(), strings.NewReader(body))
	if err != nil {
		return nil, markTerminal(E.Cause(err, "create GlobalProtect HIP ", operation, " request"))
	}
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	userAgent := gpUserAgent
	if r.client.options.UserAgent != "" {
		userAgent = r.client.options.UserAgent
	}
	request.Header.Set("User-Agent", userAgent)
	response, err := httpClient.Do(request)
	if err != nil {
		if response != nil && response.Body != nil {
			closeErr := response.Body.Close()
			err = E.Append(err, closeErr, func(cause error) error {
				return E.Cause(cause, "close failed GlobalProtect HIP ", operation, " response")
			})
		}
		return nil, E.Cause(err, "send GlobalProtect HIP ", operation, " request")
	}
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, gpHIPMaximumResponseBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		resultErr := E.Cause(readErr, "read GlobalProtect HIP ", operation, " response")
		resultErr = E.Append(resultErr, closeErr, func(cause error) error {
			return E.Cause(cause, "close GlobalProtect HIP ", operation, " response after read failure")
		})
		return nil, resultErr
	}
	if closeErr != nil {
		return nil, E.Cause(closeErr, "close GlobalProtect HIP ", operation, " response")
	}
	if len(responseBody) > gpHIPMaximumResponseBody {
		return nil, markTerminal(E.New("HIP ", operation, " response exceeds ", gpHIPMaximumResponseBody, " bytes"))
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, gpHIPHTTPStatusError(response.StatusCode, operation)
	}
	return responseBody, nil
}

func gpHIPHTTPStatusError(statusCode int, operation string) error {
	err := E.New("HIP ", operation, " returned HTTP ", statusCode)
	switch statusCode {
	case http.StatusUnauthorized, http.StatusForbidden, 512:
		return E.Errors(ErrSessionRejected, err)
	case 513:
		return markTerminal(err)
	case http.StatusRequestTimeout, http.StatusTooEarly, http.StatusTooManyRequests:
		return err
	default:
		if statusCode >= http.StatusInternalServerError && statusCode <= 599 {
			return err
		}
		return markTerminal(err)
	}
}

func parseGPHIPResponse(content []byte, operation string, opaqueCookie string) (gpHIPResponseXML, error) {
	var document gpHIPResponseXML
	decoder := xml.NewDecoder(bytes.NewReader(content))
	decoder.Strict = false
	err := decoder.Decode(&document)
	if err != nil {
		return gpHIPResponseXML{}, markTerminal(E.Cause(err, "parse GlobalProtect HIP ", operation, " response"))
	}
	if document.XMLName.Local != "response" {
		return gpHIPResponseXML{}, markTerminal(E.New("unexpected GlobalProtect HIP ", operation, " XML root: ", document.XMLName.Local))
	}
	if strings.EqualFold(strings.TrimSpace(document.Status), "error") || strings.TrimSpace(document.Error) != "" {
		serverMessage := strings.TrimSpace(document.Error)
		safeMessage := serverMessage
		if safeMessage == "" {
			safeMessage = "unspecified server error"
		}
		if opaqueCookie != "" {
			safeMessage = strings.ReplaceAll(safeMessage, opaqueCookie, "[redacted authentication cookie]")
		}
		for cookieSegment := range strings.SplitSeq(opaqueCookie, "&") {
			cookieName, cookieValue, hasCookieValue := strings.Cut(cookieSegment, "=")
			if cookieName != "authcookie" || !hasCookieValue || cookieValue == "" {
				continue
			}
			safeMessage = strings.ReplaceAll(safeMessage, cookieValue, "[redacted authcookie]")
			decodedCookieValue, decodeErr := url.QueryUnescape(cookieValue)
			if decodeErr == nil && decodedCookieValue != "" {
				safeMessage = strings.ReplaceAll(safeMessage, decodedCookieValue, "[redacted authcookie]")
			}
		}
		serverErr := E.New("HIP ", operation, " response reported an error: ", safeMessage)
		switch serverMessage {
		case "Invalid authentication cookie", "Portal name not found":
			return gpHIPResponseXML{}, E.Errors(ErrSessionRejected, serverErr)
		case "Valid client certificate is required", "Allow Automatic Restoration of SSL VPN is disabled":
			return gpHIPResponseXML{}, markTerminal(serverErr)
		default:
			return gpHIPResponseXML{}, markTerminal(serverErr)
		}
	}
	return document, nil
}

func (r *gpHIPRunner) buildReport() ([]byte, error) {
	hostname := r.client.options.LocalHostname
	networkInterfaces, err := net.Interfaces()
	if err != nil {
		return nil, markTerminal(E.Cause(err, "list network interfaces for GlobalProtect HIP report"))
	}
	sort.Slice(networkInterfaces, func(i int, j int) bool {
		if networkInterfaces[i].Name == networkInterfaces[j].Name {
			return networkInterfaces[i].Index < networkInterfaces[j].Index
		}
		return networkInterfaces[i].Name < networkInterfaces[j].Name
	})
	interfaceReports := make([]gpHIPNetworkInterfaceXML, 0, len(networkInterfaces))
	for _, networkInterface := range networkInterfaces {
		macAddress := formatGPHIPMAC(networkInterface.HardwareAddr)
		if macAddress == "" {
			continue
		}
		interfaceReport := gpHIPNetworkInterfaceXML{
			Name:       networkInterface.Name,
			MACAddress: macAddress,
		}
		interfaceReports = append(interfaceReports, interfaceReport)
	}
	operatingSystem, operatingSystemVendor := localGPHIPOperatingSystem()
	emptyList := &gpHIPEmptyXML{}
	categories := []gpHIPCategoryXML{{
		Name:                  "host-info",
		ClientVersion:         &r.appVersion,
		OperatingSystem:       operatingSystem,
		OperatingSystemVendor: operatingSystemVendor,
		Domain:                &r.cookieIdentity.domain,
		HostName:              hostname,
		NetworkInterfaces:     &gpHIPNetworkInterfacesXML{Entries: interfaceReports},
	}}
	for _, categoryName := range []string{
		"antivirus",
		"anti-malware",
		"anti-spyware",
		"disk-backup",
		"disk-encryption",
		"firewall",
	} {
		categories = append(categories, gpHIPCategoryXML{Name: categoryName, List: emptyList})
	}
	categories = append(categories,
		gpHIPCategoryXML{Name: "patch-management", List: emptyList, MissingPatches: emptyList},
		gpHIPCategoryXML{Name: "data-loss-prevention", List: emptyList},
	)
	document := gpHIPReportXML{
		Name:             "hip-report",
		MD5Sum:           r.md5,
		UserName:         r.cookieIdentity.user,
		Domain:           r.cookieIdentity.domain,
		HostName:         hostname,
		GenerateTime:     time.Now().Format("01/02/2006 15:04:05"),
		HIPReportVersion: 4,
		Categories:       gpHIPCategoriesXML{Entries: categories},
	}
	if r.assignedIPv4.IsValid() {
		document.IPAddress = r.assignedIPv4.String()
	}
	if r.assignedIPv6.IsValid() {
		document.IPv6Address = r.assignedIPv6.String()
	}
	reportContent, err := xml.MarshalIndent(document, "", "\t")
	if err != nil {
		return nil, markTerminal(E.Cause(err, "encode GlobalProtect HIP report"))
	}
	report := make([]byte, 0, len(xml.Header)+len(reportContent)+1)
	report = append(report, xml.Header...)
	report = append(report, reportContent...)
	report = append(report, '\n')
	if len(report) > gpHIPMaximumReportBody {
		return nil, markTerminal(E.New("HIP report exceeds ", gpHIPMaximumReportBody, " bytes"))
	}
	return report, nil
}

func localGPHIPOperatingSystem() (string, string) {
	switch runtime.GOOS {
	case "darwin":
		return "Apple macOS " + runtime.GOARCH, "Apple"
	case "windows":
		return "Microsoft Windows " + runtime.GOARCH, "Microsoft"
	case "linux":
		return "Linux " + runtime.GOARCH, "Linux"
	default:
		return runtime.GOOS + " " + runtime.GOARCH, runtime.GOOS
	}
}

func formatGPHIPMAC(address net.HardwareAddr) string {
	if len(address) == 0 {
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
	return strings.ToUpper(strings.ReplaceAll(address.String(), ":", "-"))
}

// Upstream run_hip_script passes only these legacy long options and clears inherited APP_VERSION before optionally setting the negotiated client version.
func (r *gpHIPRunner) runWrapper(ctx context.Context) ([]byte, error) {
	wrapperPath := r.client.options.HIP.WrapperPath
	arguments := []string{"--cookie", r.cookie}
	if r.assignedIPv4.IsValid() {
		arguments = append(arguments, "--client-ip", r.assignedIPv4.String())
	}
	if r.assignedIPv6.IsValid() {
		arguments = append(arguments, "--client-ipv6", r.assignedIPv6.String())
	}
	arguments = append(arguments, "--md5", r.md5, "--client-os", r.reportedOS)
	environment := make([]string, 0, len(os.Environ())+1)
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if strings.EqualFold(name, "APP_VERSION") {
			continue
		}
		environment = append(environment, entry)
	}
	if r.appVersion != "" {
		environment = append(environment, "APP_VERSION="+r.appVersion)
	}
	standardOutput := gpHIPBoundedBuffer{maximumSize: gpHIPMaximumReportBody}
	command := exec.CommandContext(ctx, wrapperPath, arguments...)
	command.Env = environment
	command.Stdout = &standardOutput
	command.Stderr = io.Discard
	err := command.Start()
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, markTerminal(E.Cause(err, "start GlobalProtect HIP wrapper"))
	}
	err = command.Wait()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		exitError, exited := E.Cast[*exec.ExitError](err)
		if exited && exitError.ProcessState != nil && exitError.ProcessState.Exited() {
			return nil, markTerminal(E.New("HIP wrapper returned non-zero status: ", exitError.ExitCode()))
		}
		return nil, markTerminal(E.Cause(err, "HIP wrapper terminated abnormally"))
	}
	if standardOutput.exceeded {
		return nil, markTerminal(E.New("HIP wrapper report exceeds ", gpHIPMaximumReportBody, " bytes"))
	}
	if standardOutput.buffer.Len() == 0 {
		return nil, markTerminal(E.New("HIP wrapper returned an empty report"))
	}
	return append([]byte(nil), standardOutput.buffer.Bytes()...), nil
}

func (b *gpHIPBoundedBuffer) Write(content []byte) (int, error) {
	contentSize := len(content)
	remaining := b.maximumSize - b.buffer.Len()
	if remaining > 0 {
		writeSize := min(remaining, contentSize)
		_, _ = b.buffer.Write(content[:writeSize])
	}
	if contentSize > remaining {
		b.exceeded = true
	}
	return contentSize, nil
}
