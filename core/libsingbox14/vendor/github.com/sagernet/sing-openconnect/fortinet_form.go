package openconnect

import (
	"bytes"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/net/html"
)

const (
	fortinetMaximumTokenInfoFields = 64
	fortinetMaximumTokenInfoField  = 8192
)

type fortinetAuthenticationForm struct {
	id        string
	action    string
	message   string
	fields    []fortinetAuthenticationField
	tokenInfo bool
	ftmPush   bool
}

type fortinetAuthenticationField struct {
	submissionKey string
	name          string
	label         string
	kind          string
	value         string
	rawPair       string
	magic         bool
}

func staticFortinetAuthenticationForm() *fortinetAuthenticationForm {
	formID := "_login"
	return &fortinetAuthenticationForm{
		id: formID,
		fields: []fortinetAuthenticationField{
			{
				submissionKey: fortinetSubmissionKey(formID, 0),
				name:          "username",
				label:         "Username: ",
				kind:          AuthFormFieldText,
			},
			{
				submissionKey: fortinetSubmissionKey(formID, 1),
				name:          "credential",
				label:         "Password: ",
				kind:          AuthFormFieldPassword,
			},
		},
	}
}

func parseFortinetAuthenticationResult(content []byte) (int, bool, error) {
	trimmed := strings.TrimSpace(string(content))
	if !strings.HasPrefix(trimmed, "ret=") {
		return 0, false, nil
	}
	resultText := strings.TrimPrefix(trimmed, "ret=")
	if separatorIndex := strings.IndexAny(resultText, ",&\r\n"); separatorIndex >= 0 {
		resultText = resultText[:separatorIndex]
	}
	resultText = strings.TrimSpace(resultText)
	if resultText == "" || len(resultText) > fortinetMaximumTokenInfoField {
		return 0, false, E.New("Fortinet authentication result is invalid")
	}
	result, parseErr := strconv.ParseUint(resultText, 10, 31)
	if parseErr != nil {
		return 0, false, E.Cause(parseErr, "parse Fortinet authentication result")
	}
	return int(result), true, nil
}

func parseFortinetTokenInfo(content []byte, username string) (*fortinetAuthenticationForm, error) {
	trimmed := strings.TrimSpace(string(content))
	if !strings.HasPrefix(trimmed, "ret=") {
		return nil, E.New("tokeninfo response does not begin with ret")
	}
	segments := strings.Split(trimmed, ",")
	if len(segments) > fortinetMaximumTokenInfoFields {
		return nil, E.New("tokeninfo response has too many fields")
	}
	values := make(map[string]string, len(segments))
	rawPairs := make(map[string]string, len(segments))
	orderedOpaqueNames := make([]string, 0, len(segments))
	for _, segment := range segments {
		if len(segment) > fortinetMaximumTokenInfoField {
			return nil, E.New("tokeninfo field exceeds ", fortinetMaximumTokenInfoField, " bytes")
		}
		name, value, loaded := strings.Cut(segment, "=")
		if !loaded || name == "" {
			return nil, E.New("malformed Fortinet tokeninfo field")
		}
		if _, exists := values[name]; exists {
			return nil, E.New("duplicate Fortinet tokeninfo field: ", name)
		}
		values[name] = value
		rawPairs[name] = segment
		switch name {
		case "reqid", "polid", "grp", "portal", "peer", "magic":
			orderedOpaqueNames = append(orderedOpaqueNames, name)
		}
	}
	tokenInfo, loaded := values["tokeninfo"]
	if !loaded {
		return nil, E.New("challenge omitted tokeninfo")
	}
	formID := "_challenge"
	form := &fortinetAuthenticationForm{
		id:        formID,
		message:   values["chal_msg"],
		tokenInfo: true,
		ftmPush:   tokenInfo == "ftm_push",
		fields: []fortinetAuthenticationField{
			{
				submissionKey: fortinetSubmissionKey(formID, 0),
				name:          "username",
				kind:          authFormFieldHidden,
				value:         username,
			},
			{
				submissionKey: fortinetSubmissionKey(formID, 1),
				name:          "code",
				label:         "Code: ",
				kind:          AuthFormFieldPassword,
			},
		},
	}
	fieldIndex := 2
	for _, name := range orderedOpaqueNames {
		if name == "magic" {
			continue
		}
		form.fields = append(form.fields, fortinetAuthenticationField{
			submissionKey: fortinetSubmissionKey(formID, fieldIndex),
			name:          name,
			kind:          authFormFieldHidden,
			value:         values[name],
			rawPair:       rawPairs[name],
		})
		fieldIndex++
	}
	if magicPair, exists := rawPairs["magic"]; exists {
		form.fields = append(form.fields, fortinetAuthenticationField{
			submissionKey: fortinetSubmissionKey(formID, fieldIndex),
			name:          "magic",
			kind:          authFormFieldHidden,
			value:         values["magic"],
			rawPair:       magicPair,
			magic:         true,
		})
	}
	return form, nil
}

func parseFortinetHTMLChallenge(content []byte) (*fortinetAuthenticationForm, error) {
	document, parseErr := html.Parse(bytes.NewReader(content))
	if parseErr != nil {
		return nil, E.Cause(parseErr, "parse Fortinet HTML challenge")
	}
	formNode := findFortinetHTMLNode(document, "form")
	if formNode == nil {
		return nil, E.New("HTTP 401 response has no HTML form")
	}
	method := strings.ToUpper(strings.TrimSpace(fortinetHTMLAttribute(formNode, "method")))
	if method != "POST" {
		return nil, E.New("HTML challenge form is not POST")
	}
	formID := strings.TrimSpace(fortinetHTMLAttribute(formNode, "id"))
	if formID == "" {
		formID = "_challenge"
	}
	form := &fortinetAuthenticationForm{
		id:      formID,
		action:  strings.TrimSpace(fortinetHTMLAttribute(formNode, "action")),
		message: strings.TrimSpace(fortinetHTMLText(findFortinetHTMLNode(formNode, "b"))),
	}
	var walk func(*html.Node) error
	walk = func(node *html.Node) error {
		if node.Type == html.ElementNode && strings.EqualFold(node.Data, "input") {
			fieldType := strings.ToLower(strings.TrimSpace(fortinetHTMLAttribute(node, "type")))
			hiddenByStyle := fortinetHTMLAttribute(node, "style") == "display: none;"
			if fieldType == "" {
				fieldType = "text"
			}
			var kind string
			switch fieldType {
			case "hidden":
				kind = authFormFieldHidden
			case "password":
				kind = AuthFormFieldPassword
			case "text", "email":
				kind = AuthFormFieldText
			case "submit", "button", "reset", "image":
				return nil
			default:
				return E.New("unsupported Fortinet HTML challenge input type: ", fieldType)
			}
			if hiddenByStyle {
				kind = authFormFieldHidden
			}
			name := strings.TrimSpace(fortinetHTMLAttribute(node, "name"))
			if name == "" {
				return E.New("HTML challenge input has no name")
			}
			form.fields = append(form.fields, fortinetAuthenticationField{
				submissionKey: fortinetSubmissionKey(formID, len(form.fields)),
				name:          name,
				label:         name + ": ",
				kind:          kind,
				value:         fortinetHTMLAttribute(node, "value"),
			})
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walkErr := walk(child)
			if walkErr != nil {
				return walkErr
			}
		}
		return nil
	}
	walkErr := walk(formNode)
	if walkErr != nil {
		return nil, walkErr
	}
	usernameFound := false
	credentialFound := false
	for _, field := range form.fields {
		if field.name == "username" && field.kind == authFormFieldHidden {
			usernameFound = true
		}
		if field.name == "credential" && field.kind == AuthFormFieldPassword {
			credentialFound = true
		}
	}
	if !usernameFound || !credentialFound {
		return nil, E.New("HTML challenge omitted hidden username or credential input")
	}
	return form, nil
}

func parseFortinetHostCheckAction(content []byte) (string, bool, error) {
	document, parseErr := html.Parse(bytes.NewReader(content))
	if parseErr != nil {
		return "", false, E.Cause(parseErr, "parse Fortinet hostcheck response")
	}
	var action string
	var walk func(*html.Node) error
	walk = func(node *html.Node) error {
		if node.Type == html.ElementNode && strings.EqualFold(node.Data, "form") {
			candidate := strings.TrimSpace(fortinetHTMLAttribute(node, "action"))
			if candidate != "" {
				candidateURL, candidateErr := url.Parse(candidate)
				if candidateErr != nil {
					if strings.Contains(strings.ToLower(candidate), "hostcheck") {
						return E.Cause(candidateErr, "parse Fortinet hostcheck form action")
					}
					candidateURL = nil
				}
				if candidateURL != nil && candidateURL.Path == "/remote/hostcheck_validate" {
					method := strings.ToUpper(strings.TrimSpace(fortinetHTMLAttribute(node, "method")))
					if method != "" && method != http.MethodPost {
						return E.New("Fortinet hostcheck validation form is not POST")
					}
					if action != "" {
						return E.New("Fortinet hostcheck response has multiple forms")
					}
					action = candidate
				}
			}
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walkErr := walk(child)
			if walkErr != nil {
				return walkErr
			}
		}
		return nil
	}
	walkErr := walk(document)
	if walkErr != nil {
		return "", false, walkErr
	}
	return action, action != "", nil
}

func encodeFortinetAuthenticationResponse(
	form *fortinetAuthenticationForm,
	response *authenticationResponse,
	realm string,
	initial bool,
) (string, string, error) {
	if form == nil || response == nil {
		return "", "", E.New("authentication form response is empty")
	}
	code := ""
	formFields := make([]string, 0, len(form.fields)+1)
	opaqueFields := make([]string, 0, len(form.fields))
	var magicField string
	for _, field := range form.fields {
		value, loaded := response.Values[field.submissionKey]
		if !loaded {
			return "", "", E.Extend(ErrProtocolNotSupported, "authentication response omitted field ", field.name)
		}
		if field.name == "code" {
			code = value
		}
		encoded := ""
		if field.rawPair != "" && value == field.value {
			encoded = field.rawPair
		} else {
			encoded = url.QueryEscape(field.name) + "=" + url.QueryEscape(value)
		}
		if field.magic {
			magicField = encoded
			continue
		}
		if form.tokenInfo && field.rawPair != "" {
			opaqueFields = append(opaqueFields, encoded)
		} else {
			formFields = append(formFields, encoded)
		}
	}
	formFields = append(formFields, "realm="+url.QueryEscape(realm))
	if initial {
		formFields = append(formFields, "ajax=1", "just_logged_in=1")
	} else {
		formFields = append(formFields, opaqueFields...)
	}
	if !initial && form.ftmPush && code == "" {
		formFields = append(formFields, "ftmpush=1")
	} else if !initial && magicField != "" {
		formFields = append(formFields, magicField)
	}
	return strings.Join(formFields, "&"), code, nil
}

func fortinetSubmissionKey(formID string, fieldIndex int) string {
	return formID + ":" + strconv.Itoa(fieldIndex)
}

func findFortinetHTMLNode(node *html.Node, name string) *html.Node {
	if node == nil {
		return nil
	}
	if node.Type == html.ElementNode && strings.EqualFold(node.Data, name) {
		return node
	}
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		found := findFortinetHTMLNode(child, name)
		if found != nil {
			return found
		}
	}
	return nil
}

func fortinetHTMLAttribute(node *html.Node, name string) string {
	if node == nil {
		return ""
	}
	for _, attribute := range node.Attr {
		if strings.EqualFold(attribute.Key, name) {
			return attribute.Val
		}
	}
	return ""
}

func fortinetHTMLText(node *html.Node) string {
	if node == nil {
		return ""
	}
	var builder strings.Builder
	var walk func(*html.Node)
	walk = func(current *html.Node) {
		if current.Type == html.TextNode {
			builder.WriteString(current.Data)
			builder.WriteByte(' ')
		}
		for child := current.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(node)
	return strings.Join(strings.Fields(builder.String()), " ")
}
