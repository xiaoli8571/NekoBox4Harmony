package openconnect

import (
	"bytes"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/net/html"
)

type ncAuthenticationForm struct {
	id       string
	action   string
	banner   string
	message  string
	fields   []ncAuthenticationField
	roleForm bool
}

type ncAuthenticationField struct {
	submissionKey string
	name          string
	label         string
	kind          string
	value         string
	options       []AuthFormChoice
}

// /tmp/openconnect/auth-juniper.c:oncp_obtain_cookie recognizes these HTML form identities and treats frmSelectRoles links as an authentication-group form.
func parseNCAuthenticationDocument(content []byte) (*ncAuthenticationForm, error) {
	document, err := html.Parse(bytes.NewReader(content))
	if err != nil {
		return nil, E.Cause(err, "parse Network Connect authentication HTML")
	}
	formNode := findHTMLElement(document, "form")
	if formNode == nil {
		return nil, nil
	}
	formName, _ := htmlAttribute(formNode, "name")
	formIdentifier, _ := htmlAttribute(formNode, "id")
	formName = strings.TrimSpace(formName)
	formIdentifier = strings.TrimSpace(formIdentifier)
	identifier := formName
	if identifier == "" {
		identifier = formIdentifier
	}
	if identifier == "" {
		return nil, E.New("authentication form has no name or ID")
	}
	if identifier == "frmSelectRoles" {
		return parseNCRoleForm(formNode)
	}
	method, _ := htmlAttribute(formNode, "method")
	if !strings.EqualFold(strings.TrimSpace(method), "post") {
		return nil, E.New("authentication form method is not POST: ", identifier)
	}
	action, _ := htmlAttribute(formNode, "action")
	form := &ncAuthenticationForm{
		id:     identifier,
		action: strings.TrimSpace(action),
		banner: identifier,
	}
	var walk func(node *html.Node) error
	walk = func(node *html.Node) error {
		if node.Type == html.ElementNode {
			switch {
			case strings.EqualFold(node.Data, "input"):
				field, retained, parseErr := parseNCHTMLInput(form, len(form.fields), node)
				if parseErr != nil {
					return parseErr
				}
				if retained {
					form.fields = append(form.fields, field)
				}
			case strings.EqualFold(node.Data, "select"):
				field, parseErr := parseNCHTMLSelect(form.id, len(form.fields), node)
				if parseErr != nil {
					return parseErr
				}
				form.fields = append(form.fields, field)
				return nil
			case strings.EqualFold(node.Data, "textarea"):
				fieldName, _ := htmlAttribute(node, "name")
				if strings.EqualFold(fieldName, "sn-postauth-text") || strings.EqualFold(fieldName, "sn-preauth-text") {
					form.banner = strings.TrimSpace(htmlText(node))
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
	for child := formNode.FirstChild; child != nil; child = child.NextSibling {
		walkErr := walk(child)
		if walkErr != nil {
			return nil, walkErr
		}
	}
	return form, nil
}

func parseNCHTMLInput(form *ncAuthenticationForm, fieldIndex int, node *html.Node) (ncAuthenticationField, bool, error) {
	inputType, loaded := htmlAttribute(node, "type")
	if !loaded {
		return ncAuthenticationField{}, false, nil
	}
	inputType = strings.ToLower(strings.TrimSpace(inputType))
	style, _ := htmlAttribute(node, "style")
	var kind string
	switch {
	case strings.EqualFold(strings.TrimSpace(style), "display: none;"):
		kind = authFormFieldHidden
	case inputType == "hidden", inputType == "checkbox":
		kind = authFormFieldHidden
	case inputType == "password":
		kind = AuthFormFieldPassword
	case inputType == "text", inputType == "username", inputType == "email":
		kind = AuthFormFieldText
	case inputType == "submit":
		name, _ := htmlAttribute(node, "name")
		name = strings.TrimSpace(name)
		if !ncSubmitFieldRetained(form.id, name) {
			return ncAuthenticationField{}, false, nil
		}
		kind = authFormFieldHidden
	default:
		return ncAuthenticationField{}, false, nil
	}
	name, _ := htmlAttribute(node, "name")
	name = strings.TrimSpace(name)
	if name == "" {
		return ncAuthenticationField{}, false, E.New("authentication input has no name in form ", form.id)
	}
	value, _ := htmlAttribute(node, "value")
	return ncAuthenticationField{
		submissionKey: ncSubmissionKey(form.id, fieldIndex),
		name:          name,
		label:         name + ":",
		kind:          kind,
		value:         value,
	}, true, nil
}

func parseNCHTMLSelect(formIdentifier string, fieldIndex int, node *html.Node) (ncAuthenticationField, error) {
	name, _ := htmlAttribute(node, "name")
	name = strings.TrimSpace(name)
	if name == "" {
		return ncAuthenticationField{}, E.New("authentication select has no name in form ", formIdentifier)
	}
	field := ncAuthenticationField{
		submissionKey: ncSubmissionKey(formIdentifier, fieldIndex),
		name:          name,
		label:         name,
		kind:          AuthFormFieldSelect,
	}
	selected := false
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		if child.Type != html.ElementNode || !strings.EqualFold(child.Data, "option") {
			continue
		}
		label := strings.TrimSpace(htmlText(child))
		value, hasValue := htmlAttribute(child, "value")
		if !hasValue {
			value = label
		}
		field.options = append(field.options, AuthFormChoice{Value: value, Label: label})
		_, hasSelected := htmlAttribute(child, "selected")
		if !selected && (hasSelected || len(field.options) == 1) {
			field.value = value
			selected = hasSelected
		}
	}
	if len(field.options) == 0 {
		return ncAuthenticationField{}, E.New("authentication select has no choices: ", name)
	}
	return field, nil
}

func parseNCRoleForm(formNode *html.Node) (*ncAuthenticationForm, error) {
	tableNode := findNCHTMLTableByID(formNode, "TABLE_SelectRole_1")
	if tableNode == nil {
		return nil, E.New("role form has no TABLE_SelectRole_1 table")
	}
	field := ncAuthenticationField{
		submissionKey: ncSubmissionKey("frmSelectRoles", 0),
		name:          "frmSelectRoles",
		label:         "frmSelectRoles",
		kind:          AuthFormFieldSelect,
	}
	var collect func(node *html.Node)
	collect = func(node *html.Node) {
		if node.Type == html.ElementNode && strings.EqualFold(node.Data, "a") {
			href, loaded := htmlAttribute(node, "href")
			label := strings.TrimSpace(htmlText(node))
			if loaded && strings.TrimSpace(href) != "" && label != "" {
				field.options = append(field.options, AuthFormChoice{Value: strings.TrimSpace(href), Label: label})
			}
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			collect(child)
		}
	}
	collect(tableNode)
	if len(field.options) == 0 {
		return nil, E.New("role form has no selectable roles")
	}
	field.value = field.options[0].Value
	return &ncAuthenticationForm{
		id:       "frmSelectRoles",
		banner:   "frmSelectRoles",
		fields:   []ncAuthenticationField{field},
		roleForm: true,
	}, nil
}

func findNCHTMLTableByID(root *html.Node, identifier string) *html.Node {
	if root.Type == html.ElementNode && strings.EqualFold(root.Data, "table") {
		value, loaded := htmlAttribute(root, "id")
		if loaded && value == identifier {
			return root
		}
	}
	for child := root.FirstChild; child != nil; child = child.NextSibling {
		match := findNCHTMLTableByID(child, identifier)
		if match != nil {
			return match
		}
	}
	return nil
}

func ncSubmitFieldRetained(formIdentifier string, name string) bool {
	expected := ""
	switch formIdentifier {
	case "frmLogin":
		expected = "btnSubmit"
	case "loginForm":
		expected = "submitButton"
	case "frmDefender", "frmNextToken":
		expected = "btnAction"
	case "frmConfirmation":
		expected = "btnContinue"
	case "frmTotpToken":
		expected = "totpactionEnter"
	case "hiddenform", "formSAMLSSO":
		expected = "submit"
	}
	return name != "" && (name == expected || name == "sn-postauth-proceed" || name == "sn-preauth-proceed" || name == "secidactionEnter")
}

func ncSubmissionKey(formIdentifier string, fieldIndex int) string {
	return "nc:" + formIdentifier + ":" + strconv.Itoa(fieldIndex)
}
