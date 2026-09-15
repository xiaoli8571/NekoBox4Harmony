package openconnect

import (
	"bytes"
	"encoding/xml"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

type anyConnectFormFieldKind uint8

const (
	anyConnectFormFieldText anyConnectFormFieldKind = iota + 1
	anyConnectFormFieldPassword
	anyConnectFormFieldSelect
	anyConnectFormFieldHidden
	anyConnectFormFieldToken
	anyConnectFormFieldSSOToken
	anyConnectFormFieldSSOUser
)

type anyConnectForm struct {
	AuthenticationID               string
	Banner                         string
	Message                        string
	Error                          string
	Action                         string
	Fields                         []anyConnectFormField
	AuthenticationComplete         bool
	PostAuthenticationComplete     bool
	SessionToken                   string
	Opaque                         *anyConnectOpaque
	HostScan                       anyConnectHostScan
	SSO                            anyConnectSSO
	ClientCertificateRequested     bool
	ClientCertificateAuthenticated bool
	MultipleCertificatesRequested  bool
	MultipleCertificateHashMethods []string
	RawResponse                    []byte
}

type anyConnectFormField struct {
	Name                 string
	Label                string
	ServerLabel          string
	Value                string
	Kind                 anyConnectFormFieldKind
	SecondAuthentication bool
	Choices              []anyConnectFormChoice
	SelectedChoice       int
	Ignore               bool
	StableCredential     bool
	SubmissionKey        string
}

type anyConnectFormChoice struct {
	Name                      string
	Label                     string
	AuthenticationType        string
	OverrideName              string
	OverrideLabel             string
	SecondAuthentication      bool
	SecondaryUsername         string
	SecondaryUsernameEditable bool
	NoAAA                     bool
}

type anyConnectOpaque struct {
	XMLName    xml.Name
	Attributes []xml.Attr `xml:",any,attr"`
	InnerXML   string     `xml:",innerxml"`
}

type anyConnectHostScan struct {
	Ticket  string
	Token   string
	BaseURL string
	WaitURL string
	StubURL string
}

type anyConnectSSO struct {
	LoginURL    string
	FinalURL    string
	TokenCookie string
	ErrorCookie string
	BrowserMode string
	Requested   bool
}

type anyConnectAuthenticationXML struct {
	XMLName                    xml.Name
	SessionToken               string                             `xml:"session-token"`
	Opaque                     *anyConnectOpaque                  `xml:"opaque"`
	Authentication             *anyConnectAuthenticationNode      `xml:"auth"`
	HostScan                   *anyConnectHostScanNode            `xml:"host-scan"`
	ClientCertificateRequest   *struct{}                          `xml:"client-cert-request"`
	ClientCertificateAccepted  *struct{}                          `xml:"cert-authenticated"`
	MultipleCertificateRequest *anyConnectMultipleCertificateNode `xml:"multiple-client-cert-request"`
}

type anyConnectAuthenticationNode struct {
	ID                     string                    `xml:"id,attr"`
	Banner                 anyConnectMessageNode     `xml:"banner"`
	Message                anyConnectMessageNode     `xml:"message"`
	Error                  anyConnectMessageNode     `xml:"error"`
	Form                   *anyConnectFormNode       `xml:"form"`
	AuthenticationComplete *struct{}                 `xml:"authentication-complete"`
	SSOLogin               anyConnectMessageNode     `xml:"sso-v2-login"`
	SSOLoginFinal          anyConnectMessageNode     `xml:"sso-v2-login-final"`
	SSOTokenCookie         anyConnectMessageNode     `xml:"sso-v2-token-cookie-name"`
	SSOErrorCookie         anyConnectMessageNode     `xml:"sso-v2-error-cookie-name"`
	SSOBrowserMode         anyConnectMessageNode     `xml:"sso-v2-browser-mode"`
	LegacyCSD              []anyConnectLegacyCSDNode `xml:"csd"`
	LegacyCSDMac           []anyConnectLegacyCSDNode `xml:"csdMac"`
	LegacyCSDLinux         []anyConnectLegacyCSDNode `xml:"csdLinux"`
}

type anyConnectMessageNode struct {
	ParameterOne string `xml:"param1,attr"`
	ParameterTwo string `xml:"param2,attr"`
	Text         string `xml:",chardata"`
}

type anyConnectFormNode struct {
	Method  *string                `xml:"method,attr"`
	Action  *string                `xml:"action,attr"`
	Inputs  []anyConnectInputNode  `xml:"input"`
	Selects []anyConnectSelectNode `xml:"select"`
}

type anyConnectInputNode struct {
	Type                 string `xml:"type,attr"`
	Name                 string `xml:"name,attr"`
	Label                string `xml:"label,attr"`
	Value                string `xml:"value,attr"`
	SecondAuthentication string `xml:"second-auth,attr"`
}

type anyConnectSelectNode struct {
	Name    string                 `xml:"name,attr"`
	Label   string                 `xml:"label,attr"`
	Options []anyConnectOptionNode `xml:"option"`
}

type anyConnectOptionNode struct {
	Value                     string `xml:"value,attr"`
	Selected                  string `xml:"selected,attr"`
	AuthenticationType        string `xml:"auth-type,attr"`
	OverrideName              string `xml:"override-name,attr"`
	OverrideLabel             string `xml:"override-label,attr"`
	SecondAuthentication      string `xml:"second-auth,attr"`
	SecondaryUsername         string `xml:"secondary_username,attr"`
	SecondaryUsernameEditable string `xml:"secondary_username_editable,attr"`
	NoAAA                     string `xml:"noaaa,attr"`
	Label                     string `xml:",chardata"`
}

type anyConnectHostScanNode struct {
	Ticket  string `xml:"host-scan-ticket"`
	Token   string `xml:"host-scan-token"`
	BaseURL string `xml:"host-scan-base-uri"`
	WaitURL string `xml:"host-scan-wait-uri"`
}

type anyConnectLegacyCSDNode struct {
	Ticket   string `xml:"ticket,attr"`
	Token    string `xml:"token,attr"`
	StubURL  string `xml:"stuburl,attr"`
	StartURL string `xml:"starturl,attr"`
	WaitURL  string `xml:"waiturl,attr"`
}

type anyConnectMultipleCertificateNode struct {
	HashMethods []string `xml:"hash-algorithm"`
}

func parseAnyConnectAuthenticationXML(content []byte, reportedOS string) (anyConnectForm, error) {
	decoder := xml.NewDecoder(bytes.NewReader(content))
	decoder.Strict = false
	var document anyConnectAuthenticationXML
	err := decoder.Decode(&document)
	if err != nil {
		return anyConnectForm{}, markTerminal(E.Cause(err, "parse AnyConnect authentication XML"))
	}
	if document.XMLName.Local != "config-auth" && document.XMLName.Local != "auth" {
		return anyConnectForm{}, markTerminal(E.New("unexpected AnyConnect authentication XML root: ", document.XMLName.Local))
	}
	if document.XMLName.Local == "auth" {
		var authentication anyConnectAuthenticationNode
		decoder = xml.NewDecoder(bytes.NewReader(content))
		decoder.Strict = false
		err = decoder.Decode(&authentication)
		if err != nil {
			return anyConnectForm{}, markTerminal(E.Cause(err, "parse legacy AnyConnect authentication XML"))
		}
		document.Authentication = &authentication
	}
	result := anyConnectForm{
		SessionToken:                   strings.TrimSpace(document.SessionToken),
		Opaque:                         document.Opaque,
		ClientCertificateRequested:     document.ClientCertificateRequest != nil || document.MultipleCertificateRequest != nil,
		ClientCertificateAuthenticated: document.ClientCertificateAccepted != nil,
		MultipleCertificatesRequested:  document.MultipleCertificateRequest != nil,
		RawResponse:                    append([]byte(nil), content...),
	}
	if document.MultipleCertificateRequest != nil {
		result.MultipleCertificateHashMethods = append([]string(nil), document.MultipleCertificateRequest.HashMethods...)
	}
	if document.HostScan != nil {
		result.HostScan = anyConnectHostScan{
			Ticket:  strings.TrimSpace(document.HostScan.Ticket),
			Token:   strings.TrimSpace(document.HostScan.Token),
			BaseURL: strings.TrimSpace(document.HostScan.BaseURL),
			WaitURL: strings.TrimSpace(document.HostScan.WaitURL),
		}
	}
	if document.Authentication == nil {
		if result.ClientCertificateRequested || result.MultipleCertificatesRequested {
			return result, nil
		}
		return anyConnectForm{}, markTerminal(E.New("authentication XML has no auth node"))
	}
	authentication := document.Authentication
	result.AuthenticationID = authentication.ID
	result.Banner = renderAnyConnectMessage(authentication.Banner)
	result.Message = renderAnyConnectMessage(authentication.Message)
	result.Error = renderAnyConnectMessage(authentication.Error)
	result.AuthenticationComplete = authentication.ID == "success"
	result.PostAuthenticationComplete = authentication.AuthenticationComplete != nil
	if result.PostAuthenticationComplete {
		result.AuthenticationID = "openconnect_authentication_complete"
	}
	result.SSO = anyConnectSSO{
		LoginURL:    strings.TrimSpace(authentication.SSOLogin.Text),
		FinalURL:    strings.TrimSpace(authentication.SSOLoginFinal.Text),
		TokenCookie: strings.TrimSpace(authentication.SSOTokenCookie.Text),
		ErrorCookie: strings.TrimSpace(authentication.SSOErrorCookie.Text),
		BrowserMode: strings.TrimSpace(authentication.SSOBrowserMode.Text),
	}
	if result.AuthenticationID == "" && authentication.AuthenticationComplete == nil {
		return anyConnectForm{}, markTerminal(E.New("authentication XML auth node has no id"))
	}
	mergeAnyConnectLegacyCSD(&result.HostScan, selectAnyConnectLegacyCSD(authentication, reportedOS))
	if authentication.Form == nil {
		return result, nil
	}
	formNode := authentication.Form
	if formNode.Method != nil && !strings.EqualFold(*formNode.Method, "POST") {
		return anyConnectForm{}, markTerminal(E.New("unsupported AnyConnect authentication form method: ", *formNode.Method))
	}
	if formNode.Action != nil {
		if *formNode.Action == "" {
			return anyConnectForm{}, markTerminal(E.New("authentication form has an empty action"))
		}
		result.Action = *formNode.Action
	}
	for _, selectNode := range formNode.Selects {
		field, parseErr := parseAnyConnectSelect(selectNode)
		if parseErr != nil {
			return anyConnectForm{}, markTerminal(parseErr)
		}
		if len(field.Choices) == 0 {
			continue
		}
		field.SubmissionKey = anyConnectSubmissionKey(result.AuthenticationID, len(result.Fields), field.Name)
		result.Fields = append(result.Fields, field)
	}
	for _, inputNode := range formNode.Inputs {
		field, include := parseAnyConnectInput(inputNode)
		if !include {
			continue
		}
		if field.Kind == anyConnectFormFieldPassword {
			field.StableCredential = field.Name == "password" && result.AuthenticationID != "challenge"
		}
		field.SubmissionKey = anyConnectSubmissionKey(result.AuthenticationID, len(result.Fields), field.Name)
		if field.Kind == anyConnectFormFieldSSOToken {
			result.SSO.Requested = true
		}
		result.Fields = append(result.Fields, field)
	}
	return result, nil
}

func parseAnyConnectSelect(node anyConnectSelectNode) (anyConnectFormField, error) {
	if node.Name == "" {
		return anyConnectFormField{}, E.New("authentication select has no name")
	}
	field := anyConnectFormField{
		Name:           node.Name,
		Label:          node.Label,
		ServerLabel:    node.Label,
		Kind:           anyConnectFormFieldSelect,
		SelectedChoice: 0,
	}
	for _, optionNode := range node.Options {
		value := optionNode.Value
		if value == "" {
			value = strings.TrimSpace(optionNode.Label)
		}
		if value == "" {
			continue
		}
		choice := anyConnectFormChoice{
			Name:                      value,
			Label:                     strings.TrimSpace(optionNode.Label),
			AuthenticationType:        optionNode.AuthenticationType,
			OverrideName:              optionNode.OverrideName,
			OverrideLabel:             optionNode.OverrideLabel,
			SecondAuthentication:      anyConnectXMLBoolean(optionNode.SecondAuthentication),
			SecondaryUsername:         optionNode.SecondaryUsername,
			SecondaryUsernameEditable: anyConnectXMLBoolean(optionNode.SecondaryUsernameEditable),
			NoAAA:                     anyConnectXMLBoolean(optionNode.NoAAA),
		}
		if anyConnectXMLBoolean(optionNode.Selected) {
			field.SelectedChoice = len(field.Choices)
		}
		field.Choices = append(field.Choices, choice)
	}
	if len(field.Choices) > 0 {
		field.Value = field.Choices[field.SelectedChoice].Name
	}
	return field, nil
}

// Upstream parse_form ignores input nodes without a type or name and vendor input types it does not recognize.
func parseAnyConnectInput(node anyConnectInputNode) (anyConnectFormField, bool) {
	inputType := strings.ToLower(node.Type)
	if inputType == "" || inputType == "submit" || inputType == "reset" {
		return anyConnectFormField{}, false
	}
	if node.Name == "" {
		return anyConnectFormField{}, false
	}
	field := anyConnectFormField{
		Name:                 node.Name,
		Label:                node.Label,
		ServerLabel:          node.Label,
		Value:                node.Value,
		SecondAuthentication: anyConnectXMLBoolean(node.SecondAuthentication),
	}
	if field.Label == "" {
		field.Label = field.Name + ":"
		field.ServerLabel = field.Label
	}
	switch inputType {
	case "hidden":
		field.Kind = anyConnectFormFieldHidden
	case "text":
		field.Kind = anyConnectFormFieldText
		field.StableCredential = anyConnectUsernameField(field.Name)
	case "password":
		field.Kind = anyConnectFormFieldPassword
	case "sso":
		field.Kind = anyConnectFormFieldSSOToken
	default:
		return anyConnectFormField{}, false
	}
	return field, true
}

// Upstream parse_auth_choice prepends select controls before input controls so authgroup selection can restart XMLPOST before credentials are collected.
func reorderAnyConnectAuthGroup(form *anyConnectForm) {
	for i := range form.Fields {
		if form.Fields[i].Name != "group_list" {
			continue
		}
		if i > 0 {
			authGroup := form.Fields[i]
			copy(form.Fields[1:i+1], form.Fields[0:i])
			form.Fields[0] = authGroup
		}
		return
	}
}

// Upstream process_auth_form suppresses second-auth fields according to the selected group and injects a fixed secondary username when the choice requires it.
func applyAnyConnectAuthGroup(form *anyConnectForm, selectedGroup string) {
	var selectedChoice *anyConnectFormChoice
	for i := range form.Fields {
		field := &form.Fields[i]
		field.Ignore = false
		field.Label = field.ServerLabel
		if field.Name != "group_list" || field.Kind != anyConnectFormFieldSelect {
			continue
		}
		for j := range field.Choices {
			if field.Choices[j].Name == selectedGroup || field.Choices[j].Label == selectedGroup {
				field.Value = field.Choices[j].Name
				field.SelectedChoice = j
				selectedChoice = &field.Choices[j]
				break
			}
		}
	}
	if selectedChoice == nil {
		return
	}
	for i := range form.Fields {
		field := &form.Fields[i]
		if selectedChoice.OverrideName == field.Name && selectedChoice.OverrideLabel != "" {
			field.Label = selectedChoice.OverrideLabel
		}
		if field.Kind != anyConnectFormFieldText && field.Kind != anyConnectFormFieldPassword {
			continue
		}
		if selectedChoice.NoAAA || field.SecondAuthentication && !selectedChoice.SecondAuthentication {
			field.Ignore = true
			continue
		}
		if field.Name == "secondary_username" && field.SecondAuthentication && selectedChoice.SecondaryUsername != "" {
			field.Value = selectedChoice.SecondaryUsername
			field.Ignore = !selectedChoice.SecondaryUsernameEditable
		}
	}
}

// Upstream cstp_can_gen_tokencode marks OATH fields only for secondary_password or challenge forms; stoken additionally accepts password and answer.
func configureAnyConnectTokenField(form *anyConnectForm, tokenType string, automatic bool, ocservOATHRound bool) {
	for i := range form.Fields {
		field := &form.Fields[i]
		if field.Kind != anyConnectFormFieldPassword {
			continue
		}
		stokenField := tokenType == "stoken" && (field.Name == "password" || field.Name == "answer")
		oathField := (tokenType == "totp" || tokenType == "hotp") &&
			(field.Name == "secondary_password" || form.AuthenticationID == "challenge" || ocservOATHRound && field.Name == "password")
		if stokenField || oathField {
			field.StableCredential = false
			if automatic {
				field.Kind = anyConnectFormFieldToken
			}
			return
		}
	}
}

// ocserv get_auth_handler2 emits the plain-auth password continuation as the same main/password control and carries no structured password counter when plain_auth_msg returns counter zero.
func anyConnectOcservSuccessorPasswordField(form *anyConnectForm) *anyConnectFormField {
	if form.AuthenticationID != "main" {
		return nil
	}
	var passwordField *anyConnectFormField
	for i := range form.Fields {
		field := &form.Fields[i]
		if field.Kind == anyConnectFormFieldHidden {
			continue
		}
		if field.Kind != anyConnectFormFieldPassword || field.Name != "password" || field.SecondAuthentication || passwordField != nil {
			return nil
		}
		passwordField = field
	}
	return passwordField
}

// ocserv plain_auth_pass selects the hard-coded pass_msg_otp after accepting the stable password; deployed ocserv versions use both "OTP password" and "one time password" spellings.
func anyConnectOcservOATHMessage(message string) bool {
	normalizedMessage := strings.ToLower(strings.ReplaceAll(message, "-", " "))
	return strings.Contains(normalizedMessage, "otp password") ||
		strings.Contains(normalizedMessage, "one time password") ||
		strings.Contains(normalizedMessage, "one time passcode")
}

// ocserv plain_auth_pass selects the hard-coded pass_msg_failed after rejecting the stable password.
func anyConnectOcservPasswordRejectionMessage(message string) bool {
	return strings.Contains(strings.ToLower(message), "login failed")
}

func renderAnyConnectMessage(node anyConnectMessageNode) string {
	message := strings.TrimSpace(node.Text)
	for _, parameter := range []string{node.ParameterOne, node.ParameterTwo} {
		position := strings.Index(message, "%s")
		if position < 0 {
			break
		}
		message = message[:position] + parameter + message[position+2:]
	}
	return message
}

func selectAnyConnectLegacyCSD(authentication *anyConnectAuthenticationNode, reportedOS string) anyConnectLegacyCSDNode {
	var candidates []anyConnectLegacyCSDNode
	switch reportedOS {
	case "win":
		candidates = authentication.LegacyCSD
	case "mac-intel":
		candidates = authentication.LegacyCSDMac
	default:
		candidates = authentication.LegacyCSDLinux
	}
	var result anyConnectLegacyCSDNode
	for _, candidate := range candidates {
		if candidate.Ticket != "" {
			result.Ticket = candidate.Ticket
		}
		if candidate.Token != "" {
			result.Token = candidate.Token
		}
		if candidate.StubURL != "" {
			result.StubURL = candidate.StubURL
		}
		if candidate.StartURL != "" {
			result.StartURL = candidate.StartURL
		}
		if candidate.WaitURL != "" {
			result.WaitURL = candidate.WaitURL
		}
	}
	if reportedOS == "android" || reportedOS == "apple-ios" {
		result.StubURL = ""
	}
	return result
}

func mergeAnyConnectLegacyCSD(destination *anyConnectHostScan, source anyConnectLegacyCSDNode) {
	if destination.Ticket == "" {
		destination.Ticket = source.Ticket
	}
	if destination.Token == "" {
		destination.Token = source.Token
	}
	if destination.StubURL == "" {
		destination.StubURL = source.StubURL
	}
	if destination.BaseURL == "" {
		destination.BaseURL = source.StartURL
	}
	if destination.WaitURL == "" {
		destination.WaitURL = source.WaitURL
	}
}

func anyConnectSubmissionKey(authenticationID string, index int, name string) string {
	return authenticationID + ":" + name + ":" + strconv.Itoa(index+1)
}

func anyConnectUsernameField(name string) bool {
	lowerName := strings.ToLower(name)
	return strings.HasPrefix(lowerName, "user") || strings.HasPrefix(lowerName, "uname")
}

func anyConnectXMLBoolean(value string) bool {
	return value == "1" || strings.EqualFold(value, "true") || strings.EqualFold(value, "yes") || strings.EqualFold(value, "on")
}
