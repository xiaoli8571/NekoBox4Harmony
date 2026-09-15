package openconnect

import (
	"bytes"
	"compress/zlib"
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/pem"
	"encoding/xml"
	"io"
	"maps"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"

	HTML "golang.org/x/net/html"
)

const (
	ncTNCCMaximumHTTPBody       = 8 * 1024 * 1024
	ncTNCCMaximumDecodedMessage = 8 * 1024 * 1024
	ncTNCCMaximumPacketCount    = 4096
	ncTNCCMaximumNesting        = 16
	ncTNCCPolicyMessage         = uint32(0x58316)
	ncTNCCFunkPlatformMessage   = uint32(0x58301)
	ncTNCCFunkMessage           = uint32(0xa4c01)
	ncTNCCDefaultUserAgent      = "Neoteris HC Http"
	ncTNCCCommandMessage        = uint32(0x0013)
	ncTNCCCommandCompressed     = uint32(0x0016)
	ncTNCCCommandEncapsulation  = uint32(0x0ce4)
	ncTNCCCommandStringWithID   = uint32(0x0ce7)
	ncTNCCCommandNested         = uint32(0x0cf0)
	ncTNCCPacketConstant        = uint32(0x583)
	ncTNCCInitialConnectionID   = "0"
	ncTNCCResponseConnectionID  = "1"
	ncTNCCMachineVendorID       = "2636"
	ncTNCCMachineProductID      = "1"
	ncTNCCMachineVersion        = "1"
	ncTNCCMachineClientType     = "Agentless"
)

type ncTNCCRunner interface {
	Start(ctx context.Context, preauthenticationCookie string, signInURL string) (string, error)
	SetCookie(ctx context.Context, preauthenticationCookie string) error
	Interval() time.Duration
	Close() error
}

type ncTNCCString struct {
	identifier uint32
	content    []byte
}

type ncTNCCDecodeState struct {
	strings     []ncTNCCString
	packetCount int
}

type ncTNCCPolicy struct {
	name string
}

type ncTNCCCertificate struct {
	certificate *x509.Certificate
	pemContent  string
}

type ncTNCCFunkDocument struct {
	AttributeRequest ncTNCCFunkAttributeRequest `xml:"AttributeRequest"`
}

type ncTNCCFunkAttributeRequest struct {
	Certificates []ncTNCCFunkCertificateRequest `xml:"CertData"`
}

type ncTNCCFunkCertificateRequest struct {
	Identifier string                                  `xml:"Id,attr"`
	Attributes []ncTNCCFunkCertificateAttributeRequest `xml:"Attribute"`
}

type ncTNCCFunkCertificateAttributeRequest struct {
	Name  string `xml:"Name,attr"`
	Value string `xml:"Value,attr"`
	Type  string `xml:"Type,attr"`
}

type ncBuiltInTNCCRunner struct {
	client                *Client
	serverURL             *url.URL
	acceptedAddress       netip.Addr
	jar                   http.CookieJar
	httpClient            *http.Client
	transport             *http.Transport
	userAgent             string
	deviceID              string
	machineIdentification bool
	platform              string
	hostname              string
	macAddresses          []string
	certificates          []ncTNCCCertificate
	interval              time.Duration
	closeOnce             sync.Once
}

func newNCTNCCRunner(
	frontend *ncFrontend,
	serverURL *url.URL,
	acceptedAddress netip.Addr,
	jar http.CookieJar,
	peerCertificate *x509.Certificate,
) (ncTNCCRunner, error) {
	options := frontend.client.options.TNCC
	if options != nil && options.WrapperPath != "" {
		return newNCExternalTNCCRunner(frontend, serverURL, acceptedAddress, jar, peerCertificate)
	}
	return newNCBuiltInTNCCRunner(frontend, serverURL, acceptedAddress, jar)
}

func newNCBuiltInTNCCRunner(
	frontend *ncFrontend,
	serverURL *url.URL,
	acceptedAddress netip.Addr,
	jar http.CookieJar,
) (*ncBuiltInTNCCRunner, error) {
	if serverURL == nil || !acceptedAddress.IsValid() || jar == nil {
		return nil, markTerminal(E.New("built-in TNCC requires an accepted HTTPS endpoint and cookie jar"))
	}
	options := frontend.client.options.TNCC
	userAgent := ncTNCCDefaultUserAgent
	deviceID := ""
	machineIdentification := false
	if options != nil {
		if options.UserAgent != "" {
			userAgent = options.UserAgent
		}
		deviceID = options.DeviceID
		machineIdentification = options.MachineIdentificationEnabled
	}
	httpClient, transport, _, err := newNCPinnedHTTPClient(frontend.client, serverURL, acceptedAddress, jar)
	if err != nil {
		return nil, err
	}
	runner := &ncBuiltInTNCCRunner{
		client:                frontend.client,
		serverURL:             cloneNCURL(serverURL),
		acceptedAddress:       acceptedAddress,
		jar:                   jar,
		httpClient:            httpClient,
		transport:             transport,
		userAgent:             userAgent,
		deviceID:              deviceID,
		machineIdentification: machineIdentification,
		platform:              reportedNCTNCCPlatform(frontend.client),
		hostname:              frontend.localHostname,
	}
	if machineIdentification {
		runner.macAddresses, err = observedNCTNCCMACAddresses()
		if err != nil {
			transport.CloseIdleConnections()
			return nil, err
		}
		if options != nil {
			runner.certificates, err = loadNCTNCCCertificates(options.Certificates)
			if err != nil {
				transport.CloseIdleConnections()
				return nil, err
			}
		}
	}
	return runner, nil
}

func (r *ncBuiltInTNCCRunner) Start(
	ctx context.Context,
	preauthenticationCookie string,
	signInURL string,
) (string, error) {
	setNCCookie(r.jar, r.serverURL, "DSPREAUTH", preauthenticationCookie)
	if signInURL != "" && signInURL != "null" {
		setNCCookie(r.jar, r.serverURL, "DSSIGNIN", signInURL)
	}
	return r.exchange(ctx)
}

func (r *ncBuiltInTNCCRunner) SetCookie(ctx context.Context, preauthenticationCookie string) error {
	setNCCookie(r.jar, r.serverURL, "DSPREAUTH", preauthenticationCookie)
	_, err := r.exchange(ctx)
	return err
}

func (r *ncBuiltInTNCCRunner) Interval() time.Duration {
	return r.interval
}

func (r *ncBuiltInTNCCRunner) Close() error {
	r.closeOnce.Do(func() {
		r.transport.CloseIdleConnections()
		for certificateIndex := range r.certificates {
			r.certificates[certificateIndex].pemContent = ""
			r.certificates[certificateIndex].certificate = nil
		}
		r.certificates = nil
	})
	return nil
}

// /tmp/openconnect/trojans/tncc-emulate.py:get_cookie performs two semicolon-delimited HTTPS posts containing the nested TNCC command stream and takes the shortest server interval in minutes.
func (r *ncBuiltInTNCCRunner) exchange(ctx context.Context) (string, error) {
	requestMessage := buildNCTNCCInitialMessage(r)
	firstBody := "connID=" + ncTNCCInitialConnectionID + ";timestamp=0;msg=" + base64.StdEncoding.EncodeToString(requestMessage) + ";firsttime=1;"
	if r.deviceID != "" {
		firstBody += "deviceid=" + r.deviceID + ";"
	}
	responseBody, err := r.post(ctx, firstBody, "initial request")
	if err != nil {
		return "", err
	}
	responseValues, err := parseNCTNCCHTTPResponse(responseBody)
	if err != nil {
		return "", err
	}
	encodedMessage := responseValues["msg"]
	if encodedMessage == "" {
		return "", markTerminal(E.New("TNCC initial response omitted msg"))
	}
	message, err := base64.StdEncoding.DecodeString(encodedMessage)
	if err != nil {
		return "", markTerminal(E.Cause(err, "decode Network Connect TNCC response message"))
	}
	decodedStrings, err := decodeNCTNCCMessage(message)
	if err != nil {
		return "", err
	}
	responseInner, err := r.buildResponse(decodedStrings)
	if err != nil {
		return "", err
	}
	responseEnvelope := encodeNCTNCCPacket(ncTNCCCommandEncapsulation, responseInner)
	responseEnvelope = append(responseEnvelope, encodeNCTNCCPacket(0x0ce5, []byte("Accept-Language: en"))...)
	responseMessage := encodeNCTNCCPacket(ncTNCCCommandMessage, responseEnvelope)
	secondBody := "connID=" + ncTNCCResponseConnectionID + ";msg=" + base64.StdEncoding.EncodeToString(responseMessage) + ";firsttime=1;"
	_, err = r.post(ctx, secondBody, "response")
	if err != nil {
		return "", err
	}
	intervalText := responseValues["interval"]
	if intervalText != "" {
		intervalMinutes, parseErr := strconv.ParseUint(strings.TrimSpace(intervalText), 10, 31)
		if parseErr != nil {
			return "", markTerminal(E.Cause(parseErr, "parse Network Connect TNCC interval"))
		}
		interval := time.Duration(intervalMinutes) * time.Minute
		if interval > 0 && (r.interval == 0 || interval < r.interval) {
			r.interval = interval
		}
	}
	preauthenticationCookie := ncCookieValue(r.jar, r.serverURL, "DSPREAUTH")
	if preauthenticationCookie == "" {
		return "", markTerminal(E.New("TNCC response omitted a DSPREAUTH cookie"))
	}
	return preauthenticationCookie, nil
}

func (r *ncBuiltInTNCCRunner) post(ctx context.Context, body string, operation string) ([]byte, error) {
	targetURL := cloneNCURL(r.serverURL)
	targetURL.Path = "/dana-na/hc/tnchcupdate.cgi"
	targetURL.RawPath = ""
	targetURL.RawQuery = ""
	targetURL.ForceQuery = false
	targetURL.Fragment = ""
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, targetURL.String(), strings.NewReader(body))
	if err != nil {
		return nil, markTerminal(E.Cause(err, "create Network Connect TNCC ", operation))
	}
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("User-Agent", r.userAgent)
	response, err := r.httpClient.Do(request)
	if err != nil {
		if response != nil && response.Body != nil {
			closeErr := response.Body.Close()
			err = E.Append(err, closeErr, func(cause error) error {
				return E.Cause(cause, "close failed Network Connect TNCC ", operation, " response")
			})
		}
		return nil, E.Cause(err, "send Network Connect TNCC ", operation)
	}
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, ncTNCCMaximumHTTPBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return nil, E.Errors(E.Cause(readErr, "read Network Connect TNCC ", operation, " response"), closeErr)
	}
	if closeErr != nil {
		return nil, E.Cause(closeErr, "close Network Connect TNCC ", operation, " response")
	}
	if len(responseBody) > ncTNCCMaximumHTTPBody {
		return nil, markTerminal(E.New("TNCC ", operation, " response exceeds ", ncTNCCMaximumHTTPBody, " bytes"))
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return nil, markTerminal(E.New("TNCC ", operation, " returned HTTP ", response.StatusCode))
	}
	return responseBody, nil
}

func parseNCTNCCHTTPResponse(content []byte) (map[string]string, error) {
	values := make(map[string]string)
	lines := strings.Split(strings.ReplaceAll(string(content), "\r\n", "\n"), "\n")
	lastKey := ""
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			lastKey = ""
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if found {
			key = strings.TrimSpace(key)
			if key != "" {
				values[key] = strings.TrimSpace(value)
				lastKey = key
			}
			continue
		}
		if lastKey == "msg" {
			values[lastKey] += line
		}
	}
	return values, nil
}

func buildNCTNCCInitialMessage(runner *ncBuiltInTNCCRunner) []byte {
	policyRequest := "<parameter name=\"policy_request\" value=\"message_version=3;\">" +
		"<parameter name=\"esap\" value=\"esap_version=NOT_AVAILABLE;fileinfo=NOT_AVAILABLE;has_file_versions=YES;needs_exact_sdk=YES;opswat_sdk_version=3;\">" +
		"<parameter name=\"system_info\" value=\"os_version=2.6.2;sp_version=0;hc_mode=userMode;\">"
	inner := encodeNCTNCCString(0xa4c18, []byte(policyRequest))
	inner = append(inner, encodeNCTNCCString(ncTNCCPolicyMessage, []byte("policy request\x00v4"))...)
	if runner.machineIdentification {
		inner = append(inner, encodeNCTNCCString(ncTNCCFunkPlatformMessage, []byte(runner.funkPlatformDocument()))...)
		inner = append(inner, encodeNCTNCCString(ncTNCCFunkMessage, []byte(runner.funkPresentDocument()))...)
	}
	outer := encodeNCTNCCPacket(ncTNCCCommandEncapsulation, inner)
	outer = append(outer, encodeNCTNCCPacket(0x0ce5, []byte("Accept-Language: en"))...)
	number := make([]byte, 4)
	binary.LittleEndian.PutUint32(number, 1)
	outer = append(outer, encodeNCTNCCPacket(ncTNCCCommandMessage, number)...)
	return encodeNCTNCCPacket(ncTNCCCommandMessage, outer)
}

func encodeNCTNCCString(identifier uint32, content []byte) []byte {
	payload := make([]byte, 4, len(content)+6)
	binary.BigEndian.PutUint32(payload, identifier)
	payload = append(payload, content...)
	payload = append(payload, 0, 0)
	return encodeNCTNCCPacket(ncTNCCCommandStringWithID, payload)
}

func encodeNCTNCCPacket(command uint32, payload []byte) []byte {
	packetLength := 12 + len(payload)
	paddedLength := (packetLength + 3) &^ 3
	packet := make([]byte, paddedLength)
	binary.BigEndian.PutUint32(packet, command)
	packet[4] = 0xc0
	binary.BigEndian.PutUint16(packet[6:], uint16(packetLength))
	binary.BigEndian.PutUint32(packet[8:], ncTNCCPacketConstant)
	copy(packet[12:], payload)
	return packet
}

func decodeNCTNCCMessage(content []byte) ([]ncTNCCString, error) {
	state := &ncTNCCDecodeState{}
	err := decodeNCTNCCPackets(content, 0, state)
	if err != nil {
		return nil, err
	}
	return state.strings, nil
}

func decodeNCTNCCPackets(content []byte, depth int, state *ncTNCCDecodeState) error {
	if depth > ncTNCCMaximumNesting {
		return markTerminal(E.New("TNCC message nesting exceeds ", ncTNCCMaximumNesting))
	}
	position := 0
	for position < len(content) {
		if len(content)-position < 12 {
			for _, value := range content[position:] {
				if value != 0 {
					return markTerminal(E.New("TNCC message has a truncated packet header"))
				}
			}
			return nil
		}
		state.packetCount++
		if state.packetCount > ncTNCCMaximumPacketCount {
			return markTerminal(E.New("TNCC message contains too many packets"))
		}
		command := binary.BigEndian.Uint32(content[position:])
		packetLength := int(binary.BigEndian.Uint16(content[position+6:]))
		if packetLength < 12 || packetLength > len(content)-position {
			return markTerminal(E.New("TNCC packet has an invalid length: ", packetLength))
		}
		paddedLength := (packetLength + 3) &^ 3
		if paddedLength > len(content)-position {
			return markTerminal(E.New("TNCC packet padding exceeds its container"))
		}
		payload := content[position+12 : position+packetLength]
		switch command {
		case ncTNCCCommandMessage:
			if len(payload) >= 12 {
				err := decodeNCTNCCPackets(payload, depth+1, state)
				if err != nil {
					return err
				}
			}
		case ncTNCCCommandEncapsulation, ncTNCCCommandNested:
			err := decodeNCTNCCPackets(payload, depth+1, state)
			if err != nil {
				return err
			}
		case ncTNCCCommandCompressed:
			if len(payload) < 4 {
				return markTerminal(E.New("TNCC compressed packet is too short"))
			}
			decoded, err := decompressNCTNCC(payload[4:])
			if err != nil {
				return err
			}
			err = decodeNCTNCCPackets(decoded, depth+1, state)
			if err != nil {
				return err
			}
		case ncTNCCCommandStringWithID:
			if len(payload) < 4 {
				return markTerminal(E.New("TNCC identified string is too short"))
			}
			identifier := binary.BigEndian.Uint32(payload)
			stringContent := bytes.TrimRight(payload[4:], "\x00")
			if bytes.HasPrefix(stringContent, []byte("COMPRESSED:")) {
				parts := bytes.SplitN(stringContent, []byte(":"), 3)
				if len(parts) != 3 {
					return markTerminal(E.New("TNCC compressed string has no payload"))
				}
				decoded, err := decompressNCTNCC(parts[2])
				if err != nil {
					return err
				}
				stringContent = decoded
			}
			state.strings = append(state.strings, ncTNCCString{identifier: identifier, content: append([]byte(nil), stringContent...)})
		}
		position += paddedLength
	}
	return nil
}

func decompressNCTNCC(content []byte) ([]byte, error) {
	reader, err := zlib.NewReader(bytes.NewReader(content))
	if err != nil {
		return nil, markTerminal(E.Cause(err, "initialize Network Connect TNCC zlib decoder"))
	}
	decoded, readErr := io.ReadAll(io.LimitReader(reader, ncTNCCMaximumDecodedMessage+1))
	closeErr := reader.Close()
	if readErr != nil {
		return nil, markTerminal(E.Errors(E.Cause(readErr, "decompress Network Connect TNCC message"), closeErr))
	}
	if closeErr != nil {
		return nil, markTerminal(E.Cause(closeErr, "close Network Connect TNCC zlib decoder"))
	}
	if len(decoded) > ncTNCCMaximumDecodedMessage {
		return nil, markTerminal(E.New("TNCC decompressed message exceeds ", ncTNCCMaximumDecodedMessage, " bytes"))
	}
	return decoded, nil
}

func (r *ncBuiltInTNCCRunner) buildResponse(stringsFound []ncTNCCString) ([]byte, error) {
	policies := make(map[string]ncTNCCPolicy)
	certificateRequests := make(map[string]map[string]string)
	for _, messageString := range stringsFound {
		switch messageString.identifier {
		case ncTNCCPolicyMessage:
			parsedPolicies, err := parseNCTNCCPolicies(messageString.content)
			if err != nil {
				return nil, err
			}
			for _, policy := range parsedPolicies {
				policies[policy.name] = policy
			}
		case ncTNCCFunkMessage:
			parsedRequests, err := parseNCTNCCFunkRequests(messageString.content)
			if err != nil {
				return nil, err
			}
			maps.Copy(certificateRequests, parsedRequests)
		}
	}
	var response []byte
	if len(certificateRequests) > 0 {
		if !r.machineIdentification {
			return nil, markTerminal(E.Extend(ErrProtocolNotSupported, "TNCC requested machine certificates; enable machine identification or configure an external TNCC wrapper"))
		}
		certificateResponse, err := r.funkCertificateResponse(certificateRequests)
		if err != nil {
			return nil, err
		}
		response = append(response, encodeNCTNCCString(ncTNCCFunkMessage, []byte(certificateResponse))...)
	}
	policyNames := make([]string, 0, len(policies))
	for policyName := range policies {
		policyNames = append(policyNames, policyName)
	}
	sort.Strings(policyNames)
	var policyResponse strings.Builder
	for _, policyName := range policyNames {
		policyResponse.WriteString("\npolicy:")
		policyResponse.WriteString(policyName)
		policyResponse.WriteString("\nstatus:")
		if strings.Contains(policyName, "Unsupported") || strings.Contains(policyName, "Deny") {
			policyResponse.WriteString("NOTOK\nerror:Unknown error")
			continue
		}
		return nil, markTerminal(E.Extend(ErrProtocolNotSupported, "TNCC requested unmodeled mandatory policy ", policyName, "; configure an external TNCC wrapper"))
	}
	response = append(response, encodeNCTNCCString(ncTNCCPolicyMessage, []byte(policyResponse.String()))...)
	return response, nil
}

func parseNCTNCCPolicies(content []byte) ([]ncTNCCPolicy, error) {
	if !bytes.Contains(bytes.ToLower(content), []byte("<param")) {
		return nil, nil
	}
	document, err := HTML.Parse(bytes.NewReader(content))
	if err != nil {
		return nil, markTerminal(E.Cause(err, "parse Network Connect TNCC policy response"))
	}
	policies := make(map[string]struct{})
	var walk func(node *HTML.Node)
	walk = func(node *HTML.Node) {
		if node.Type == HTML.ElementNode && strings.EqualFold(node.Data, "param") {
			value, _ := htmlAttribute(node, "value")
			for field := range strings.SplitSeq(value, ";") {
				name, fieldValue, found := strings.Cut(strings.TrimSpace(field), "=")
				if found && name == "policy" && strings.TrimSpace(fieldValue) != "" {
					policies[strings.TrimSpace(fieldValue)] = struct{}{}
				}
			}
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(document)
	policyNames := make([]string, 0, len(policies))
	for policyName := range policies {
		policyNames = append(policyNames, policyName)
	}
	sort.Strings(policyNames)
	result := make([]ncTNCCPolicy, 0, len(policyNames))
	for _, policyName := range policyNames {
		result = append(result, ncTNCCPolicy{name: policyName})
	}
	return result, nil
}

func parseNCTNCCFunkRequests(content []byte) (map[string]map[string]string, error) {
	requests := make(map[string]map[string]string)
	if !bytes.Contains(content, []byte("AttributeRequest")) {
		return requests, nil
	}
	var document ncTNCCFunkDocument
	decoder := xml.NewDecoder(bytes.NewReader(content))
	decoder.Strict = false
	err := decoder.Decode(&document)
	if err != nil {
		return nil, markTerminal(E.Cause(err, "parse Network Connect TNCC Funk request XML"))
	}
	var trailing any
	err = decoder.Decode(&trailing)
	if err != io.EOF {
		if err == nil {
			return nil, markTerminal(E.New("TNCC Funk request contains trailing XML values"))
		}
		return nil, markTerminal(E.Cause(err, "parse trailing Network Connect TNCC Funk request XML"))
	}
	for _, certificateRequest := range document.AttributeRequest.Certificates {
		if certificateRequest.Identifier == "" {
			return nil, markTerminal(E.New("TNCC certificate request has no ID"))
		}
		issuerValues := make(map[string]string)
		for _, attribute := range certificateRequest.Attributes {
			if attribute.Type != "DN" || attribute.Name != "IssuerDN" {
				return nil, markTerminal(E.Extend(ErrProtocolNotSupported, "TNCC requested unsupported certificate attribute ", attribute.Name, "/", attribute.Type, "; configure an external TNCC wrapper"))
			}
			for distinguishedName := range strings.SplitSeq(attribute.Value, ",") {
				name, value, found := strings.Cut(strings.TrimSpace(distinguishedName), "=")
				if !found || name == "" || value == "" {
					return nil, markTerminal(E.New("TNCC certificate issuer request is malformed"))
				}
				issuerValues[name] = value
			}
		}
		requests[certificateRequest.Identifier] = issuerValues
	}
	return requests, nil
}

func (r *ncBuiltInTNCCRunner) funkPlatformDocument() string {
	var document strings.Builder
	document.WriteString("<FunkMessage VendorID='")
	document.WriteString(ncTNCCMachineVendorID)
	document.WriteString("' ProductID='")
	document.WriteString(ncTNCCMachineProductID)
	document.WriteString("' Version='")
	document.WriteString(ncTNCCMachineVersion)
	document.WriteString("' Platform='")
	document.WriteString(escapeNCXMLAttribute(r.platform))
	document.WriteString("' ClientType='")
	document.WriteString(ncTNCCMachineClientType)
	document.WriteString("'> <ClientAttributes SequenceID='-1'> <Attribute Name='Platform' Value='")
	document.WriteString(escapeNCXMLAttribute(r.platform))
	document.WriteString("' />")
	if r.hostname != "" {
		document.WriteString(" <Attribute Name='")
		document.WriteString(escapeNCXMLAttribute(r.hostname))
		document.WriteString("' Value='NETBIOSName' />")
	}
	for _, macAddress := range r.macAddresses {
		document.WriteString(" <Attribute Name='")
		document.WriteString(escapeNCXMLAttribute(macAddress))
		document.WriteString("' Value='MACAddress' />")
	}
	document.WriteString("</ClientAttributes>  </FunkMessage>")
	return document.String()
}

func (r *ncBuiltInTNCCRunner) funkPresentDocument() string {
	return "<FunkMessage VendorID='" + ncTNCCMachineVendorID + "' ProductID='" + ncTNCCMachineProductID + "' Version='" + ncTNCCMachineVersion + "' Platform='" + escapeNCXMLAttribute(r.platform) + "' ClientType='" + ncTNCCMachineClientType + "'> <Present SequenceID='0'></Present>  </FunkMessage>"
}

func (r *ncBuiltInTNCCRunner) funkCertificateResponse(requests map[string]map[string]string) (string, error) {
	requestIdentifiers := make([]string, 0, len(requests))
	for identifier := range requests {
		requestIdentifiers = append(requestIdentifiers, identifier)
	}
	sort.Strings(requestIdentifiers)
	matched := make(map[string]ncTNCCCertificate, len(requests))
	for _, identifier := range requestIdentifiers {
		issuerValues := requests[identifier]
		found := false
		for _, certificate := range r.certificates {
			if ncTNCCCertificateMatchesIssuer(certificate.certificate, issuerValues) {
				matched[identifier] = certificate
				found = true
				break
			}
		}
		if !found {
			return "", markTerminal(E.Extend(ErrProtocolNotSupported, "TNCC could not satisfy certificate request ", identifier, "; configure the certificate or an external TNCC wrapper"))
		}
	}
	var document strings.Builder
	document.WriteString("<FunkMessage VendorID='")
	document.WriteString(ncTNCCMachineVendorID)
	document.WriteString("' ProductID='")
	document.WriteString(ncTNCCMachineProductID)
	document.WriteString("' Version='")
	document.WriteString(ncTNCCMachineVersion)
	document.WriteString("' Platform='")
	document.WriteString(escapeNCXMLAttribute(r.platform))
	document.WriteString("' ClientType='")
	document.WriteString(ncTNCCMachineClientType)
	document.WriteString("'> <ClientAttributes SequenceID='0'> <Attribute Name='Platform' Value='")
	document.WriteString(escapeNCXMLAttribute(r.platform))
	document.WriteString("' />")
	for _, identifier := range requestIdentifiers {
		certificate := matched[identifier]
		for range 2 {
			document.WriteString(" <Attribute Name='")
			document.WriteString(escapeNCXMLAttribute(identifier))
			document.WriteString("' Value='")
			document.WriteString(escapeNCXMLAttribute(strings.TrimSpace(certificate.pemContent)))
			document.WriteString("' />")
		}
	}
	document.WriteString("</ClientAttributes>  </FunkMessage>")
	return document.String(), nil
}

func loadNCTNCCCertificates(materials []Material) ([]ncTNCCCertificate, error) {
	var certificates []ncTNCCCertificate
	for materialIndex, material := range materials {
		content, err := loadMaterial(material)
		if err != nil {
			return nil, markTerminal(E.Cause(err, "load Network Connect TNCC certificate ", materialIndex))
		}
		remaining := content
		for len(bytes.TrimSpace(remaining)) > 0 {
			block, rest := pem.Decode(remaining)
			if block == nil {
				return nil, markTerminal(E.New("TNCC certificate material contains invalid PEM"))
			}
			remaining = rest
			if block.Type != "CERTIFICATE" {
				return nil, markTerminal(E.New("TNCC certificate material contains PEM type ", block.Type))
			}
			certificate, parseErr := x509.ParseCertificate(block.Bytes)
			if parseErr != nil {
				return nil, markTerminal(E.Cause(parseErr, "parse Network Connect TNCC certificate"))
			}
			encoded := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: block.Bytes})
			certificates = append(certificates, ncTNCCCertificate{certificate: certificate, pemContent: string(encoded)})
		}
		clear(content)
	}
	return certificates, nil
}

func ncTNCCCertificateMatchesIssuer(certificate *x509.Certificate, expected map[string]string) bool {
	if certificate == nil {
		return false
	}
	issuerValues := make(map[string][]string)
	for _, attribute := range certificate.Issuer.Names {
		value, isString := attribute.Value.(string)
		if !isString {
			continue
		}
		identifier := attribute.Type.String()
		issuerValues[identifier] = append(issuerValues[identifier], value)
	}
	for identifier, value := range expected {
		matched := slices.Contains(issuerValues[identifier], value)
		if !matched {
			return false
		}
	}
	return true
}

func observedNCTNCCMACAddresses() ([]string, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, markTerminal(E.Cause(err, "list network interfaces for Network Connect TNCC"))
	}
	addresses := make([]string, 0, len(interfaces))
	for _, networkInterface := range interfaces {
		if len(networkInterface.HardwareAddr) == 0 {
			continue
		}
		allZero := true
		for _, value := range networkInterface.HardwareAddr {
			if value != 0 {
				allZero = false
				break
			}
		}
		if !allZero {
			addresses = append(addresses, strings.ToLower(networkInterface.HardwareAddr.String()))
		}
	}
	sort.Strings(addresses)
	return addresses, nil
}

func reportedNCTNCCPlatform(client *Client) string {
	if client.options.ReportedOS != "" {
		return client.options.ReportedOS
	}
	return runtime.GOOS + " " + runtime.GOARCH
}

func escapeNCXMLAttribute(value string) string {
	replacer := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		"'", "&apos;",
		"\"", "&quot;",
	)
	return replacer.Replace(value)
}

func setNCCookie(jar http.CookieJar, serverURL *url.URL, name string, value string) {
	if jar == nil || serverURL == nil || name == "" || value == "" {
		return
	}
	jar.SetCookies(serverURL, []*http.Cookie{{
		Name:   name,
		Value:  value,
		Path:   "/",
		Secure: true,
	}})
}

func ncCookieValue(jar http.CookieJar, serverURL *url.URL, name string) string {
	if jar == nil || serverURL == nil {
		return ""
	}
	for _, cookie := range jar.Cookies(serverURL) {
		if cookie.Name == name {
			return cookie.Value
		}
	}
	return ""
}
