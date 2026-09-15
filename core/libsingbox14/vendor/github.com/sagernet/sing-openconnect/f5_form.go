package openconnect

import (
	"bytes"
	"encoding/json"
	"io"
	"strconv"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/net/html"
)

type f5AuthenticationForm struct {
	id      string
	action  string
	banner  string
	message string
	fields  []f5AuthenticationField
	html    bool
}

type f5AuthenticationField struct {
	submissionKey string
	name          string
	label         string
	kind          string
	value         string
	options       []AuthFormChoice
}

type f5JSONForm struct {
	ID     json.RawMessage `json:"id"`
	Title  json.RawMessage `json:"title"`
	Fields json.RawMessage `json:"fields"`
}

type f5JSONField struct {
	Type     json.RawMessage `json:"type"`
	Name     json.RawMessage `json:"name"`
	Caption  json.RawMessage `json:"caption"`
	Value    json.RawMessage `json:"value"`
	Disabled json.RawMessage `json:"disabled"`
}

func parseF5AuthenticationDocument(content []byte) (*f5AuthenticationForm, []string, error) {
	document, parseErr := html.Parse(bytes.NewReader(content))
	if parseErr != nil {
		return nil, nil, E.Cause(parseErr, "parse F5 authentication HTML")
	}
	formNode := findHTMLElement(document, "form")
	if formNode != nil {
		form, formErr := parseF5HTMLForm(formNode)
		return form, nil, formErr
	}
	return parseF5JSONForm(document)
}

func parseF5HTMLForm(node *html.Node) (*f5AuthenticationForm, error) {
	method, _ := htmlAttribute(node, "method")
	if !strings.EqualFold(strings.TrimSpace(method), "post") {
		return nil, E.New("authentication form method is not POST")
	}
	formID, _ := htmlAttribute(node, "id")
	action, _ := htmlAttribute(node, "action")
	form := &f5AuthenticationForm{
		id:     strings.TrimSpace(formID),
		action: strings.TrimSpace(action),
		html:   true,
	}
	if form.id == "" {
		form.id = "unknown"
	}
	var walk func(*html.Node) error
	walk = func(current *html.Node) error {
		if current.Type == html.ElementNode {
			switch {
			case strings.EqualFold(current.Data, "input"):
				field, retained, fieldErr := parseF5HTMLInput(form.id, len(form.fields), current)
				if fieldErr != nil {
					return fieldErr
				}
				if retained {
					form.fields = append(form.fields, field)
				}
			case strings.EqualFold(current.Data, "select"):
				field, fieldErr := parseF5HTMLSelect(form.id, len(form.fields), current)
				if fieldErr != nil {
					return fieldErr
				}
				form.fields = append(form.fields, field)
				return nil
			case strings.EqualFold(current.Data, "td"):
				identifier, _ := htmlAttribute(current, "id")
				switch identifier {
				case "credentials_table_header":
					form.banner = strings.TrimSpace(htmlText(current))
				case "credentials_table_postheader":
					form.message = strings.TrimSpace(htmlText(current))
				}
			}
		}
		for child := current.FirstChild; child != nil; child = child.NextSibling {
			walkErr := walk(child)
			if walkErr != nil {
				return walkErr
			}
		}
		return nil
	}
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		walkErr := walk(child)
		if walkErr != nil {
			return nil, walkErr
		}
	}
	return form, nil
}

func parseF5HTMLInput(formID string, index int, node *html.Node) (f5AuthenticationField, bool, error) {
	inputType, loaded := htmlAttribute(node, "type")
	if !loaded {
		return f5AuthenticationField{}, false, nil
	}
	inputType = strings.ToLower(strings.TrimSpace(inputType))
	var kind string
	style, _ := htmlAttribute(node, "style")
	switch {
	case strings.EqualFold(strings.TrimSpace(style), "display: none;"):
		kind = authFormFieldHidden
	case inputType == "hidden" || inputType == "checkbox":
		kind = authFormFieldHidden
	case inputType == "password":
		kind = AuthFormFieldPassword
	case inputType == "text" || inputType == "username" || inputType == "email":
		kind = AuthFormFieldText
	default:
		return f5AuthenticationField{}, false, nil
	}
	name, _ := htmlAttribute(node, "name")
	name = strings.TrimSpace(name)
	if name == "" {
		return f5AuthenticationField{}, false, E.New("authentication input has no name")
	}
	value, _ := htmlAttribute(node, "value")
	return f5AuthenticationField{
		submissionKey: f5SubmissionKey(formID, index),
		name:          name,
		label:         name + ":",
		kind:          kind,
		value:         value,
	}, true, nil
}

func parseF5HTMLSelect(formID string, index int, node *html.Node) (f5AuthenticationField, error) {
	name, _ := htmlAttribute(node, "name")
	name = strings.TrimSpace(name)
	if name == "" {
		return f5AuthenticationField{}, E.New("authentication select has no name")
	}
	field := f5AuthenticationField{
		submissionKey: f5SubmissionKey(formID, index),
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
		_, isSelected := htmlAttribute(child, "selected")
		if !selected && (isSelected || len(field.options) == 1) {
			field.value = value
			selected = isSelected
		}
	}
	if len(field.options) == 0 {
		return f5AuthenticationField{}, E.New("authentication select has no choices: ", name)
	}
	return field, nil
}

func parseF5JSONForm(document *html.Node) (*f5AuthenticationForm, []string, error) {
	var encodedForms [][]byte
	var extractionErr error
	var walk func(*html.Node)
	walk = func(node *html.Node) {
		if extractionErr != nil {
			return
		}
		if node.Type == html.ElementNode && strings.EqualFold(node.Data, "script") {
			for child := node.FirstChild; child != nil; child = child.NextSibling {
				if child.Type != html.TextNode {
					continue
				}
				extracted, found, extractErr := extractF5AppLoaderObject(child.Data)
				if extractErr != nil {
					extractionErr = extractErr
					return
				}
				if found {
					encodedForms = append(encodedForms, extracted)
				}
			}
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(document)
	if extractionErr != nil {
		return nil, nil, extractionErr
	}
	if len(encodedForms) == 0 {
		return nil, nil, nil
	}
	if len(encodedForms) != 1 {
		return nil, nil, E.New("authentication document contains multiple appLoader.configure objects")
	}
	form, warnings, parseErr := decodeF5JSONForm(encodedForms[0])
	if parseErr != nil {
		return nil, nil, parseErr
	}
	return form, warnings, nil
}

func extractF5AppLoaderObject(script string) ([]byte, bool, error) {
	const marker = "appLoader.configure"
	markerIndex := strings.Index(script, marker)
	if markerIndex < 0 {
		return nil, false, nil
	}
	if strings.Contains(script[markerIndex+len(marker):], marker) {
		return nil, false, E.New("authentication script contains multiple appLoader.configure calls")
	}
	position := markerIndex + len(marker)
	for position < len(script) && isF5JavaScriptSpace(script[position]) {
		position++
	}
	if position >= len(script) || script[position] != '(' {
		return nil, false, E.New("appLoader.configure call has no opening parenthesis")
	}
	position++
	for position < len(script) && isF5JavaScriptSpace(script[position]) {
		position++
	}
	if position >= len(script) || script[position] != '{' {
		return nil, false, E.New("appLoader.configure call does not start with a JSON object")
	}
	start := position
	depth := 0
	inString := false
	escaped := false
	for ; position < len(script); position++ {
		character := script[position]
		if inString {
			if escaped {
				escaped = false
				continue
			}
			if character == '\\' {
				escaped = true
				continue
			}
			if character == '"' {
				inString = false
			}
			continue
		}
		switch character {
		case '"':
			inString = true
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				encoded := []byte(script[start : position+1])
				position++
				for position < len(script) && isF5JavaScriptSpace(script[position]) {
					position++
				}
				if position >= len(script) || script[position] != ')' {
					return nil, false, E.New("appLoader.configure JSON object has trailing arguments")
				}
				return encoded, true, nil
			}
			if depth < 0 {
				return nil, false, E.New("appLoader.configure JSON object is unbalanced")
			}
		}
	}
	return nil, false, E.New("appLoader.configure JSON object is incomplete")
}

func decodeF5JSONForm(content []byte) (*f5AuthenticationForm, []string, error) {
	root, decodeErr := decodeF5JSONObject(content, "appLoader.configure")
	if decodeErr != nil {
		return nil, nil, decodeErr
	}
	logonContent, loaded := root["logon"]
	if !loaded {
		return nil, nil, E.New("appLoader.configure object has no logon object")
	}
	logon, decodeErr := decodeF5JSONObject(logonContent, "appLoader.configure logon")
	if decodeErr != nil {
		return nil, nil, decodeErr
	}
	formContent, loaded := logon["form"]
	if !loaded {
		return nil, nil, E.New("appLoader.configure logon has no form object")
	}
	var encoded f5JSONForm
	decodeErr = json.Unmarshal(formContent, &encoded)
	if decodeErr != nil {
		return nil, nil, E.Cause(decodeErr, "decode F5 appLoader.configure form")
	}
	formID, decodeErr := requiredF5JSONString(encoded.ID, "form id")
	if decodeErr != nil {
		return nil, nil, decodeErr
	}
	title, decodeErr := optionalF5JSONString(encoded.Title, "form title")
	if decodeErr != nil {
		return nil, nil, decodeErr
	}
	if len(encoded.Fields) == 0 {
		return nil, nil, E.New("appLoader.configure form has no fields array")
	}
	var encodedFields []json.RawMessage
	decodeErr = json.Unmarshal(encoded.Fields, &encodedFields)
	if decodeErr != nil {
		return nil, nil, E.Cause(decodeErr, "decode F5 appLoader.configure fields")
	}
	form := &f5AuthenticationForm{id: formID, banner: title}
	var warnings []string
	for fieldIndex, fieldContent := range encodedFields {
		var encodedField f5JSONField
		decodeErr = json.Unmarshal(fieldContent, &encodedField)
		if decodeErr != nil {
			return nil, nil, E.Cause(decodeErr, "decode F5 appLoader.configure field ", fieldIndex)
		}
		fieldType, typeErr := requiredF5JSONString(encodedField.Type, "field type")
		if typeErr != nil {
			return nil, nil, typeErr
		}
		fieldName, nameErr := requiredF5JSONString(encodedField.Name, "field name")
		if nameErr != nil {
			return nil, nil, nameErr
		}
		caption, captionErr := optionalF5JSONString(encodedField.Caption, "field caption")
		if captionErr != nil {
			return nil, nil, captionErr
		}
		value, valueErr := optionalF5JSONString(encodedField.Value, "field value")
		if valueErr != nil {
			return nil, nil, valueErr
		}
		if len(encodedField.Disabled) > 0 {
			var disabled bool
			disabledErr := json.Unmarshal(encodedField.Disabled, &disabled)
			if disabledErr != nil {
				return nil, nil, E.Cause(disabledErr, "decode F5 appLoader.configure disabled marker")
			}
		}
		kind := AuthFormFieldText
		switch fieldType {
		case "text":
		case "password":
			kind = AuthFormFieldPassword
		default:
			warnings = append(warnings, "Unknown F5 JSON authentication field type "+fieldType+"; treating it as text")
		}
		label := fieldName + ":"
		if caption != "" {
			label = caption + ":"
		}
		form.fields = append(form.fields, f5AuthenticationField{
			submissionKey: f5SubmissionKey(form.id, fieldIndex),
			name:          fieldName,
			label:         label,
			kind:          kind,
			value:         value,
		})
	}
	return form, warnings, nil
}

func decodeF5JSONObject(content []byte, description string) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(content))
	var object map[string]json.RawMessage
	decodeErr := decoder.Decode(&object)
	if decodeErr != nil {
		return nil, E.Cause(decodeErr, "decode ", description, " JSON object")
	}
	var trailing any
	trailingErr := decoder.Decode(&trailing)
	if trailingErr != io.EOF {
		if trailingErr == nil {
			return nil, E.New(description, " contains trailing JSON values")
		}
		return nil, E.Cause(trailingErr, "decode trailing ", description, " JSON")
	}
	if object == nil {
		return nil, E.New(description, " is not a JSON object")
	}
	return object, nil
}

func requiredF5JSONString(content json.RawMessage, description string) (string, error) {
	value, decodeErr := optionalF5JSONString(content, description)
	if decodeErr != nil {
		return "", decodeErr
	}
	if value == "" {
		return "", E.New("appLoader.configure ", description, " is empty")
	}
	return value, nil
}

func optionalF5JSONString(content json.RawMessage, description string) (string, error) {
	if len(content) == 0 || bytes.Equal(content, []byte("null")) {
		return "", nil
	}
	var value string
	decodeErr := json.Unmarshal(content, &value)
	if decodeErr != nil {
		return "", E.Cause(decodeErr, "decode F5 appLoader.configure ", description)
	}
	return value, nil
}

func f5SubmissionKey(formID string, index int) string {
	return "f5:" + formID + ":" + strconv.Itoa(index)
}

func isF5JavaScriptSpace(character byte) bool {
	switch character {
	case ' ', '\t', '\r', '\n':
		return true
	default:
		return false
	}
}
