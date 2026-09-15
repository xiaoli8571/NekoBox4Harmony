package openconnect

import (
	"bytes"
	"encoding/base64"
	"encoding/xml"
	"html"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	gpLoginArgumentAuthCookie       = 1
	gpLoginArgumentPortal           = 3
	gpLoginArgumentUser             = 4
	gpLoginArgumentDomain           = 7
	gpLoginArgumentConnectionType   = 12
	gpLoginArgumentClientVersion    = 14
	gpLoginArgumentPreferredIP      = 15
	gpLoginArgumentPreferredIPv6    = 18
	gpLoginKnownArgumentCount       = 21
	gpAuthenticationFormID          = "_login"
	gpChallengeFormID               = "_challenge"
	gpPortalFormID                  = "_portal"
	gpDefaultClientVersion          = "6.3.0-33"
	gpPortalHIPReportIntervalLead   = 60 * time.Second
	gpMinimumShortHIPReportInterval = time.Second
)

var errGPInterfaceNotFound = E.New("interface does not exist")

type gpPreloginForm struct {
	message       string
	usernameLabel string
	passwordLabel string
	region        string
	samlMethod    string
	samlRequest   string
}

type gpChallenge struct {
	message     string
	inputString string
}

type gpPortalGateway struct {
	name      string
	label     string
	priority  int
	formValue string
}

type gpPortalConfiguration struct {
	gateways                     []gpPortalGateway
	portalUserAuthCookie         string
	portalPrelogonUserAuthCookie string
	hipReportInterval            time.Duration
	clientVersion                string
}

type gpResponseEnvelope struct {
	XMLName xml.Name
	Status  string `xml:"status,attr"`
	Error   string `xml:"error"`
	Result  string `xml:"status"`
	Message string `xml:"msg"`
}

type gpPreloginXML struct {
	XMLName               xml.Name
	Status                string `xml:"status"`
	Message               string `xml:"msg"`
	AuthenticationMessage string `xml:"authentication-message"`
	UsernameLabel         string `xml:"username-label"`
	PasswordLabel         string `xml:"password-label"`
	Region                string `xml:"region"`
	SAMLMethod            string `xml:"saml-auth-method"`
	SAMLRequest           string `xml:"saml-request"`
}

type gpPortalPolicyXML struct {
	XMLName                      xml.Name
	Version                      string               `xml:"version"`
	Gateways                     []gpPortalGatewayXML `xml:"gateways>external>list>entry"`
	HIPReportInterval            string               `xml:"hip-collection>hip-report-interval"`
	PortalUserAuthCookie         string               `xml:"portal-userauthcookie"`
	PortalPrelogonUserAuthCookie string               `xml:"portal-prelogonuserauthcookie"`
}

type gpPortalGatewayXML struct {
	Name          string                    `xml:"name,attr"`
	Description   string                    `xml:"description"`
	PriorityRules []gpPortalPriorityRuleXML `xml:"priority-rule>entry"`
}

type gpPortalPriorityRuleXML struct {
	Name     string `xml:"name,attr"`
	Priority string `xml:"priority"`
}

type gpJNLPXML struct {
	XMLName                xml.Name
	ApplicationDescription gpApplicationDescriptionXML `xml:"application-desc"`
}

type gpApplicationDescriptionXML struct {
	Arguments  []string                 `xml:"argument"`
	Unexpected []gpUnexpectedElementXML `xml:",any"`
}

type gpUnexpectedElementXML struct {
	XMLName xml.Name
}

type gpHTMLXML struct {
	XMLName xml.Name
	Body    string `xml:"body"`
}

func parseGPPreloginResponse(responseBody []byte) (gpPreloginForm, error) {
	_, challengeFound, err := inspectGPResponse(responseBody)
	if err != nil {
		return gpPreloginForm{}, err
	}
	if challengeFound {
		return gpPreloginForm{}, E.Extend(ErrProtocolNotSupported, "prelogin returned an authentication challenge")
	}
	var prelogin gpPreloginXML
	err = decodeGPXML(responseBody, &prelogin, "parse GlobalProtect prelogin XML")
	if err != nil {
		return gpPreloginForm{}, err
	}
	if prelogin.XMLName.Local != "prelogin-response" {
		return gpPreloginForm{}, E.New("prelogin returned unexpected XML root: ", prelogin.XMLName.Local)
	}
	if strings.TrimSpace(prelogin.Status) != "Success" {
		return gpPreloginForm{}, E.New("prelogin failed: ", strings.TrimSpace(prelogin.Message))
	}
	return gpPreloginForm{
		message:       strings.TrimSpace(prelogin.AuthenticationMessage),
		usernameLabel: strings.TrimSpace(prelogin.UsernameLabel),
		passwordLabel: strings.TrimSpace(prelogin.PasswordLabel),
		region:        strings.TrimSpace(prelogin.Region),
		samlMethod:    strings.TrimSpace(prelogin.SAMLMethod),
		samlRequest:   strings.TrimSpace(prelogin.SAMLRequest),
	}, nil
}

func parseGPPortalConfiguration(responseBody []byte, region string) (gpPortalConfiguration, *gpChallenge, error) {
	challenge, challengeFound, err := inspectGPResponse(responseBody)
	if err != nil {
		return gpPortalConfiguration{}, nil, err
	}
	if challengeFound {
		return gpPortalConfiguration{}, &challenge, nil
	}
	var policy gpPortalPolicyXML
	err = decodeGPXML(responseBody, &policy, "parse GlobalProtect portal configuration XML")
	if err != nil {
		return gpPortalConfiguration{}, nil, err
	}
	if policy.XMLName.Local != "policy" {
		return gpPortalConfiguration{}, nil, E.New("portal returned unexpected XML root: ", policy.XMLName.Local)
	}
	configuration := gpPortalConfiguration{
		portalUserAuthCookie:         normalizeGPPortalCookie(policy.PortalUserAuthCookie),
		portalPrelogonUserAuthCookie: normalizeGPPortalCookie(policy.PortalPrelogonUserAuthCookie),
		clientVersion:                strings.TrimSpace(policy.Version),
	}
	configuration.hipReportInterval, err = parseGPHIPReportInterval(policy.HIPReportInterval)
	if err != nil {
		return gpPortalConfiguration{}, nil, err
	}
	for i, gatewayXML := range policy.Gateways {
		gatewayName := strings.TrimSpace(gatewayXML.Name)
		if gatewayName == "" {
			return gpPortalConfiguration{}, nil, E.New("portal returned a gateway without an endpoint name")
		}
		gatewayLabel := strings.TrimSpace(gatewayXML.Description)
		if gatewayLabel == "" {
			gatewayLabel = gatewayName
		}
		gatewayPriority, priorityErr := gpPortalGatewayPriority(gatewayXML.PriorityRules, region)
		if priorityErr != nil {
			return gpPortalConfiguration{}, nil, priorityErr
		}
		configuration.gateways = append(configuration.gateways, gpPortalGateway{
			name:      gatewayName,
			label:     gatewayLabel,
			priority:  gatewayPriority,
			formValue: gatewayName + "#" + strconv.Itoa(i),
		})
	}
	if len(configuration.gateways) == 0 {
		return gpPortalConfiguration{}, nil, E.New("portal configuration lists no gateway servers")
	}
	sort.SliceStable(configuration.gateways, func(i int, j int) bool {
		return configuration.gateways[i].priority < configuration.gateways[j].priority
	})
	return configuration, nil, nil
}

func parseGPLoginResponse(responseBody []byte, localHostname string) (string, *gpChallenge, error) {
	challenge, challengeFound, err := inspectGPResponse(responseBody)
	if err != nil {
		return "", nil, err
	}
	if challengeFound {
		return "", &challenge, nil
	}
	var jnlp gpJNLPXML
	err = decodeGPXML(responseBody, &jnlp, "parse GlobalProtect gateway login JNLP")
	if err != nil {
		return "", nil, err
	}
	if jnlp.XMLName.Local != "jnlp" {
		return "", nil, E.New("gateway login returned unexpected XML root: ", jnlp.XMLName.Local)
	}
	if len(jnlp.ApplicationDescription.Unexpected) > 0 {
		return "", nil, E.New("gateway login returned unexpected JNLP element: ", jnlp.ApplicationDescription.Unexpected[0].XMLName.Local)
	}
	arguments := make([]string, gpLoginKnownArgumentCount)
	copy(arguments, jnlp.ApplicationDescription.Arguments)
	authCookie := normalizeGPLoginArgument(arguments[gpLoginArgumentAuthCookie])
	user := normalizeGPLoginArgument(arguments[gpLoginArgumentUser])
	connectionType := normalizeGPLoginArgument(arguments[gpLoginArgumentConnectionType])
	clientVersion := normalizeGPLoginArgument(arguments[gpLoginArgumentClientVersion])
	if authCookie == "" {
		return "", nil, E.New("gateway login omitted authcookie")
	}
	if user == "" {
		return "", nil, E.New("gateway login omitted user")
	}
	if connectionType != "tunnel" {
		return "", nil, E.New("gateway login returned connection-type ", connectionType, ", expected tunnel")
	}
	if clientVersion != "4100" {
		return "", nil, E.New("gateway login returned clientVer ", clientVersion, ", expected 4100")
	}
	parameterArguments := []struct {
		name  string
		index int
	}{
		{name: "authcookie", index: gpLoginArgumentAuthCookie},
		{name: "portal", index: gpLoginArgumentPortal},
		{name: "user", index: gpLoginArgumentUser},
		{name: "domain", index: gpLoginArgumentDomain},
		{name: "preferred-ip", index: gpLoginArgumentPreferredIP},
		{name: "preferred-ipv6", index: gpLoginArgumentPreferredIPv6},
	}
	parameters := make([]string, 0, len(parameterArguments)+1)
	for _, parameterArgument := range parameterArguments {
		argument := normalizeGPLoginArgument(arguments[parameterArgument.index])
		if argument == "" {
			continue
		}
		decodedArgument := decodeGPFormComponent(argument)
		parameters = append(parameters, encodeGPFormComponent(parameterArgument.name)+"="+encodeGPFormComponent(decodedArgument))
	}
	parameters = append(parameters, "computer="+encodeGPFormComponent(localHostname))
	return strings.Join(parameters, "&"), nil, nil
}

func parseGPLogoutResponse(responseBody []byte) error {
	_, challengeFound, err := inspectGPResponse(responseBody)
	if err != nil {
		return err
	}
	if challengeFound {
		return E.New("logout unexpectedly returned an authentication challenge")
	}
	var envelope gpResponseEnvelope
	err = decodeGPXML(responseBody, &envelope, "parse GlobalProtect logout XML")
	if err != nil {
		return err
	}
	if envelope.XMLName.Local != "response" || envelope.Status != "success" {
		return E.New("logout did not return a successful response")
	}
	return nil
}

func decodeGPSAMLURL(method string, request string) (string, error) {
	switch method {
	case "REDIRECT":
		decoded, err := base64.StdEncoding.DecodeString(request)
		if err != nil {
			return "", E.Cause(err, "decode GlobalProtect SAML REDIRECT request")
		}
		if len(decoded) == 0 {
			return "", E.New("SAML REDIRECT request is empty")
		}
		return string(decoded), nil
	case "POST":
		if request == "" {
			return "", E.New("SAML POST request is empty")
		}
		return "data:text/html;base64," + request, nil
	default:
		return "", E.New("unsupported GlobalProtect SAML authentication method: ", method)
	}
}

// Upstream gpst_xml_or_error accepts XML, JavaScript, and JavaScript embedded as HTML for the same dynamic challenge response.
func inspectGPResponse(responseBody []byte) (gpChallenge, bool, error) {
	response := strings.TrimSpace(string(responseBody))
	if response == "" {
		return gpChallenge{}, false, E.New("server returned an empty response")
	}
	if strings.HasPrefix(response, "var respStatus") {
		return parseGPJavaScriptChallenge(response)
	}
	withoutDeclaration := response
	if strings.HasPrefix(withoutDeclaration, "<?xml") {
		declarationEnd := strings.Index(withoutDeclaration, "?>")
		if declarationEnd >= 0 {
			withoutDeclaration = strings.TrimSpace(withoutDeclaration[declarationEnd+2:])
		}
	}
	if strings.HasPrefix(withoutDeclaration, "<challenge") {
		message, messageFound := extractGPElement(withoutDeclaration, "respmsg")
		inputString, inputFound := extractGPElement(withoutDeclaration, "inputstr")
		if !messageFound || !inputFound {
			return gpChallenge{}, false, E.New("XML challenge omitted respmsg or inputstr")
		}
		return gpChallenge{message: message, inputString: inputString}, true, nil
	}
	var envelope gpResponseEnvelope
	err := decodeGPXML(responseBody, &envelope, "parse GlobalProtect response XML")
	if err != nil {
		return gpChallenge{}, false, err
	}
	switch envelope.XMLName.Local {
	case "html":
		var htmlResponse gpHTMLXML
		err = decodeGPXML(responseBody, &htmlResponse, "parse GlobalProtect HTML challenge")
		if err != nil {
			return gpChallenge{}, false, err
		}
		return parseGPJavaScriptChallenge(strings.TrimSpace(htmlResponse.Body))
	case "response":
		if envelope.Status == "error" {
			return gpChallenge{}, false, classifyGPResponseError(strings.TrimSpace(envelope.Error))
		}
	case "prelogin-response":
		if strings.TrimSpace(envelope.Result) != "Success" {
			return gpChallenge{}, false, classifyGPResponseError(strings.TrimSpace(envelope.Message))
		}
	}
	return gpChallenge{}, false, nil
}

func parseGPJavaScriptChallenge(response string) (gpChallenge, bool, error) {
	remaining := strings.TrimSpace(response)
	status, remaining, found := consumeGPJavaScriptAssignment(remaining, "var respStatus = ")
	if !found {
		return gpChallenge{}, false, E.New("failed to parse GlobalProtect JavaScript challenge status")
	}
	message, remaining, found := consumeGPJavaScriptAssignment(remaining, "var respMsg = ")
	if !found {
		return gpChallenge{}, false, E.New("failed to parse GlobalProtect JavaScript challenge message")
	}
	inputString, remaining, found := consumeGPJavaScriptAssignment(remaining, "thisForm.inputStr.value = ")
	if !found {
		return gpChallenge{}, false, E.New("failed to parse GlobalProtect JavaScript challenge inputStr")
	}
	if strings.Trim(remaining, "; \t\r\n") != "" {
		return gpChallenge{}, false, E.New("JavaScript challenge contains unexpected trailing input")
	}
	decodedMessage := decodeGPJavaScriptString(message)
	if strings.HasPrefix(status, "Error") {
		return gpChallenge{}, false, E.New("authentication failed: ", decodedMessage)
	}
	if !strings.HasPrefix(status, "Challenge") {
		return gpChallenge{}, false, E.New("JavaScript response returned unknown status: ", status)
	}
	return gpChallenge{message: decodedMessage, inputString: inputString}, true, nil
}

func consumeGPJavaScriptAssignment(input string, prefix string) (string, string, bool) {
	trimmed := strings.TrimLeft(input, "; \t\r\n")
	if !strings.HasPrefix(trimmed, prefix) {
		return "", input, false
	}
	quoted := trimmed[len(prefix):]
	if len(quoted) == 0 || quoted[0] != '"' {
		return "", input, false
	}
	escaped := false
	for i := 1; i < len(quoted); i++ {
		character := quoted[i]
		if character == '\\' {
			escaped = !escaped
			continue
		}
		if character == '"' && !escaped {
			return quoted[1:i], quoted[i+1:], true
		}
		escaped = false
	}
	return "", input, false
}

func decodeGPJavaScriptString(value string) string {
	normalized := strings.ReplaceAll(value, `\'`, `'`)
	decoded, err := strconv.Unquote(`"` + normalized + `"`)
	if err != nil {
		return value
	}
	return decoded
}

func extractGPElement(document string, name string) (string, bool) {
	opening := "<" + name + ">"
	closing := "</" + name + ">"
	start := strings.Index(document, opening)
	if start < 0 {
		return "", false
	}
	start += len(opening)
	endRelative := strings.Index(document[start:], closing)
	if endRelative < 0 {
		return "", false
	}
	return html.UnescapeString(document[start : start+endRelative]), true
}

func classifyGPResponseError(message string) error {
	switch message {
	case "GlobalProtect gateway does not exist", "GlobalProtect portal does not exist":
		return E.Errors(errGPInterfaceNotFound, E.New(message))
	case "Invalid authentication cookie", "Portal name not found":
		return E.Errors(ErrSessionRejected, E.New(message))
	case "Valid client certificate is required":
		return E.Errors(ErrAuthenticationFailed, E.New(message))
	case "Allow Automatic Restoration of SSL VPN is disabled":
		return E.Extend(ErrProtocolNotSupported, message)
	default:
		if message == "" {
			return E.Extend(ErrProtocolNotSupported, "server returned an unspecified error")
		}
		return E.Extend(ErrProtocolNotSupported, "server returned an error: ", message)
	}
}

func normalizeGPPortalCookie(value string) string {
	if value == "empty" {
		return ""
	}
	return value
}

func parseGPHIPReportInterval(value string) (time.Duration, error) {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return 0, nil
	}
	seconds, err := strconv.ParseInt(trimmed, 10, 64)
	if err != nil {
		return 0, E.Cause(err, "parse GlobalProtect HIP report interval")
	}
	if seconds < 0 {
		return 0, E.New("HIP report interval is negative: ", seconds)
	}
	if seconds == 0 {
		return 0, nil
	}
	if seconds > math.MaxInt64/int64(time.Second) {
		return 0, E.New("HIP report interval exceeds the supported duration: ", seconds)
	}
	interval := time.Duration(seconds) * time.Second
	if interval > gpPortalHIPReportIntervalLead {
		return interval - gpPortalHIPReportIntervalLead, nil
	}
	interval /= 2
	if interval < gpMinimumShortHIPReportInterval {
		interval = gpMinimumShortHIPReportInterval
	}
	return interval, nil
}

func gpPortalGatewayPriority(rules []gpPortalPriorityRuleXML, region string) (int, error) {
	priority := math.MaxInt
	for _, rule := range rules {
		ruleName := strings.TrimSpace(rule.Name)
		if ruleName != region && ruleName != "Any" {
			continue
		}
		trimmedPriority := strings.TrimSpace(rule.Priority)
		if trimmedPriority == "" {
			continue
		}
		parsedPriority, err := strconv.Atoi(trimmedPriority)
		if err != nil {
			return 0, E.Cause(err, "parse GlobalProtect gateway priority for region ", ruleName)
		}
		if parsedPriority < priority {
			priority = parsedPriority
		}
	}
	return priority, nil
}

func normalizeGPLoginArgument(argument string) string {
	if argument == "" || argument == "(null)" || argument == "-1" {
		return ""
	}
	return argument
}

// Upstream gpst_xml_or_error enables libxml recovery for every GlobalProtect XML response.
func decodeGPXML(responseBody []byte, destination any, operation string) error {
	decoder := xml.NewDecoder(bytes.NewReader(responseBody))
	decoder.Strict = false
	err := decoder.Decode(destination)
	if err != nil {
		return E.Cause(err, operation)
	}
	return nil
}

// Upstream urldecode_inplace decodes valid percent triplets and plus, while preserving malformed percent input byte-for-byte.
func decodeGPFormComponent(value string) string {
	decoded := make([]byte, 0, len(value))
	for i := 0; i < len(value); i++ {
		character := value[i]
		if character == '+' {
			decoded = append(decoded, ' ')
			continue
		}
		if character == '%' && i+2 < len(value) {
			high, highValid := gpHexadecimalValue(value[i+1])
			low, lowValid := gpHexadecimalValue(value[i+2])
			if highValid && lowValid {
				decoded = append(decoded, high<<4|low)
				i += 2
				continue
			}
		}
		decoded = append(decoded, character)
	}
	return string(decoded)
}

func gpHexadecimalValue(character byte) (byte, bool) {
	switch {
	case character >= '0' && character <= '9':
		return character - '0', true
	case character >= 'a' && character <= 'f':
		return character - 'a' + 10, true
	case character >= 'A' && character <= 'F':
		return character - 'A' + 10, true
	default:
		return 0, false
	}
}
