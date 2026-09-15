package openconnect

import (
	"context"
	"encoding/binary"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	pulsePromptPrimary     = 1
	pulsePromptUsername    = 2
	pulsePromptPassword    = 4
	pulsePromptGTCNext     = 0x10000
	pulsePromptJuniper2021 = 0x20000

	pulseJuniperPasswordChange  = 0x43
	pulseJuniperPasswordRequest = 0x01
	pulseJuniperPasswordRetry   = 0x81
	pulseJuniperPasswordFailure = 0xc5

	pulseRealmSubmissionKey          = "pulse:realm"
	pulseRealmChoiceSubmissionKey    = "pulse:realm-choice"
	pulseRegionChoiceSubmissionKey   = "pulse:region-choice"
	pulseSessionSubmissionKey        = "pulse:session"
	pulseUsernameSubmissionKey       = "pulse:username"
	pulsePasswordSubmissionKey       = "pulse:password"
	pulseOldPasswordSubmissionKey    = "pulse:old-password"
	pulseNewPasswordSubmissionKey    = "pulse:new-password"
	pulseVerifyPasswordSubmissionKey = "pulse:verify-password"
	pulseTokenSubmissionKey          = "pulse:token"
)

type pulseChallengeKind uint8

const (
	pulseChallengeUnknown pulseChallengeKind = iota
	pulseChallengeRealmEntry
	pulseChallengeRealmChoice
	pulseChallengeRegionChoice
	pulseChallengePassword
	pulseChallengePasswordChange
	pulseChallengeGTC
	pulseChallengeSession
	pulseChallengeSignIn
	pulseChallengeCookie
)

type pulseSessionChoice struct {
	identifier string
	source     string
	createdAt  time.Time
}

type pulseAuthenticationChallenge struct {
	kind                pulseChallengeKind
	outerIdentifier     byte
	innerIdentifier     byte
	promptFlags         int
	userPrompt          string
	passwordPrompt      string
	gtcPrompt           string
	gtcNext             bool
	realmChoices        []string
	regionChoices       []string
	sessions            []pulseSessionChoice
	passwordRequestCode byte
	errorMessage        string
}

func (c pulseAuthenticationChallenge) formRequest(generator *softwareTokenGenerator) (*authenticationRequest, error) {
	switch c.kind {
	case pulseChallengeRealmEntry:
		return &authenticationRequest{
			FormID:  "pulse_realm_entry",
			Message: "Enter Pulse user realm:",
			Fields: []authenticationRequestField{{
				SubmissionKey: pulseRealmSubmissionKey,
				Name:          "realm",
				Label:         "Realm:",
				Kind:          AuthFormFieldText,
			}},
		}, nil
	case pulseChallengeRealmChoice:
		return pulseChoiceForm("pulse_realm_choice", "Choose Pulse user realm:", "realm_choice", "Realm:", pulseRealmChoiceSubmissionKey, c.realmChoices, authCacheAuthGroup), nil
	case pulseChallengeRegionChoice:
		return pulseChoiceForm("pulse_region_choice", "Choose Pulse region:", "region_choice", "Region:", pulseRegionChoiceSubmissionKey, c.regionChoices, ""), nil
	case pulseChallengeSession:
		choices := make([]AuthFormChoice, 0, len(c.sessions))
		var message strings.Builder
		message.WriteString("Session limit reached. Choose session to terminate:")
		for _, session := range c.sessions {
			label := session.identifier + " from " + session.source + " at " + session.createdAt.Format(time.RFC1123)
			choices = append(choices, AuthFormChoice{Value: session.identifier, Label: label})
		}
		return &authenticationRequest{
			FormID:  "pulse_session_kill",
			Message: message.String(),
			Fields: []authenticationRequestField{{
				SubmissionKey: pulseSessionSubmissionKey,
				Name:          "session_choice",
				Label:         "Session:",
				Kind:          AuthFormFieldSelect,
				Options:       choices,
			}},
		}, nil
	case pulseChallengePassword:
		return c.passwordForm(), nil
	case pulseChallengePasswordChange:
		return c.passwordChangeForm(), nil
	case pulseChallengeGTC:
		return c.gtcForm(generator), nil
	default:
		return nil, E.New("authentication challenge has no user form")
	}
}

func pulseChoiceForm(
	formID string,
	message string,
	name string,
	label string,
	submissionKey string,
	values []string,
	cacheKey string,
) *authenticationRequest {
	choices := make([]AuthFormChoice, 0, len(values))
	for _, value := range values {
		choices = append(choices, AuthFormChoice{Value: value, Label: value})
	}
	defaultValue := ""
	if len(values) > 0 {
		defaultValue = values[0]
	}
	return &authenticationRequest{
		FormID:  formID,
		Message: message,
		Fields: []authenticationRequestField{{
			SubmissionKey: submissionKey,
			Name:          name,
			Label:         label,
			Kind:          AuthFormFieldSelect,
			Value:         defaultValue,
			Options:       choices,
			CacheKey:      cacheKey,
		}},
	}
}

func (c pulseAuthenticationChallenge) passwordForm() *authenticationRequest {
	primary := c.promptFlags&pulsePromptPrimary != 0
	formID := "pulse_secondary"
	message := "Enter secondary credentials:"
	if primary {
		formID = "pulse_user"
		message = "Enter user credentials:"
	}
	request := &authenticationRequest{FormID: formID, Message: message, Error: c.errorMessage}
	if primary && c.passwordRequestCode == pulseJuniperPasswordRetry {
		request.ClearCacheKeys = []string{authCacheUsername, authCachePassword}
	}
	if c.promptFlags&pulsePromptUsername != 0 {
		label := c.userPrompt
		if label == "" {
			if primary {
				label = "Username:"
			} else {
				label = "Secondary username:"
			}
		}
		cacheKey := ""
		if primary {
			cacheKey = authCacheUsername
		}
		request.Fields = append(request.Fields, authenticationRequestField{
			SubmissionKey: pulseUsernameSubmissionKey,
			Name:          "username",
			Label:         label,
			Kind:          AuthFormFieldText,
			CacheKey:      cacheKey,
		})
	}
	if c.promptFlags&pulsePromptPassword != 0 {
		label := c.passwordPrompt
		if label == "" {
			if primary {
				label = "Password:"
			} else {
				label = "Secondary password:"
			}
		}
		cacheKey := ""
		if primary {
			cacheKey = authCachePassword
		}
		request.Fields = append(request.Fields, authenticationRequestField{
			SubmissionKey: pulsePasswordSubmissionKey,
			Name:          "password",
			Label:         label,
			Kind:          AuthFormFieldPassword,
			CacheKey:      cacheKey,
		})
	}
	return request
}

func (c pulseAuthenticationChallenge) passwordChangeForm() *authenticationRequest {
	formID := "pulse_secondary_change"
	if c.promptFlags&pulsePromptPrimary != 0 {
		formID = "pulse_user_change"
	}
	return &authenticationRequest{
		FormID:  formID,
		Message: "Password expired. Please change password:",
		Error:   c.errorMessage,
		Fields: []authenticationRequestField{
			{
				SubmissionKey: pulseOldPasswordSubmissionKey,
				Name:          "oldpass",
				Label:         "Current password:",
				Kind:          AuthFormFieldPassword,
			},
			{
				SubmissionKey: pulseNewPasswordSubmissionKey,
				Name:          "newpass1",
				Label:         "New password:",
				Kind:          AuthFormFieldPassword,
			},
			{
				SubmissionKey: pulseVerifyPasswordSubmissionKey,
				Name:          "newpass1",
				Label:         "Verify new password:",
				Kind:          AuthFormFieldPassword,
			},
		},
	}
}

func (c pulseAuthenticationChallenge) gtcForm(generator *softwareTokenGenerator) *authenticationRequest {
	primary := c.promptFlags&pulsePromptPrimary != 0
	message := "Token code request:"
	if c.gtcNext && c.gtcPrompt != "" {
		message = c.gtcPrompt
	}
	request := &authenticationRequest{FormID: "pulse_gtc", Message: message}
	if c.promptFlags&pulsePromptUsername != 0 {
		label := c.userPrompt
		if label == "" {
			if primary {
				label = "Username:"
			} else {
				label = "Secondary username:"
			}
		}
		cacheKey := ""
		if primary {
			cacheKey = authCacheUsername
		}
		request.Fields = append(request.Fields, authenticationRequestField{
			SubmissionKey: pulseUsernameSubmissionKey,
			Name:          "username",
			Label:         label,
			Kind:          AuthFormFieldText,
			CacheKey:      cacheKey,
		})
	}
	label := c.passwordPrompt
	if c.gtcNext {
		label = "Please enter response:"
	} else if label == "" && primary {
		label = "Please enter your passcode:"
	} else if label == "" {
		label = "Please enter your secondary token information:"
	}
	tokenField := authenticationRequestField{
		SubmissionKey: pulseTokenSubmissionKey,
		Name:          "tokencode",
		Label:         label,
		Kind:          AuthFormFieldPassword,
	}
	if generator != nil && generator.CanGenerate(message) {
		tokenField.Kind = authFormFieldToken
		tokenMessage := message
		tokenField.Automatic = func(ctx context.Context) (string, error) {
			code, err := generator.Generate(ctx, tokenMessage)
			if err != nil {
				return "", markTerminal(E.Cause(err, "generate Pulse software token"))
			}
			return code, nil
		}
	}
	request.Fields = append(request.Fields, tokenField)
	return request
}

func (c pulseAuthenticationChallenge) buildResponse(response authenticationResponse) ([]byte, string, error) {
	switch c.kind {
	case pulseChallengeRealmEntry:
		return pulseStringResponse(response, pulseRealmSubmissionKey, 0xd50)
	case pulseChallengeRealmChoice:
		return pulseStringResponse(response, pulseRealmChoiceSubmissionKey, 0xd50)
	case pulseChallengeRegionChoice:
		return pulseStringResponse(response, pulseRegionChoiceSubmissionKey, 0xd52)
	case pulseChallengeSession:
		return pulseStringResponse(response, pulseSessionSubmissionKey, 0xd69)
	case pulseChallengePassword:
		return c.buildPasswordResponse(response)
	case pulseChallengePasswordChange:
		return c.buildPasswordChangeResponse(response)
	case pulseChallengeGTC:
		return c.buildGTCResponse(response)
	default:
		return nil, "", E.New("authentication challenge does not accept a form response")
	}
}

func pulseStringResponse(response authenticationResponse, submissionKey string, code uint32) ([]byte, string, error) {
	value, loaded := response.Values[submissionKey]
	if !loaded || value == "" {
		return nil, "", E.New("authentication response omitted ", submissionKey)
	}
	content, err := appendPulseAVP(nil, code, pulseVendorJuniper2, []byte(value))
	return content, "", err
}

func (c pulseAuthenticationChallenge) buildPasswordResponse(response authenticationResponse) ([]byte, string, error) {
	var content []byte
	if c.promptFlags&pulsePromptUsername != 0 {
		username, loaded := response.Values[pulseUsernameSubmissionKey]
		if !loaded {
			return nil, "", E.New("credential response omitted username")
		}
		var err error
		content, err = appendPulseAVP(content, 0xd6d, pulseVendorJuniper2, []byte(username))
		if err != nil {
			return nil, "", err
		}
	}
	password := ""
	if c.promptFlags&pulsePromptPassword != 0 {
		var loaded bool
		password, loaded = response.Values[pulsePasswordSubmissionKey]
		if !loaded {
			return nil, "", E.New("credential response omitted password")
		}
	}
	var innerPacket []byte
	var err error
	if c.promptFlags&pulsePromptJuniper2021 != 0 {
		passwordBytes := []byte(password)
		innerPayload := make([]byte, 19)
		innerPayload[0] = 1
		copy(innerPayload[1:], passwordBytes[:min(len(passwordBytes), 18)])
		innerPacket, err = buildPulseEAP(pulseEAPResponse, c.innerIdentifier, pulseEAPTypeExpanded, 5, innerPayload)
		clear(passwordBytes)
		clear(innerPayload)
	} else {
		passwordBytes := []byte(password)
		if len(passwordBytes) > 253 {
			clear(passwordBytes)
			return nil, "Password exceeds the Pulse 253-byte limit.", nil
		}
		innerPayload := make([]byte, 3+len(passwordBytes))
		innerPayload[0] = 2
		innerPayload[1] = 2
		innerPayload[2] = byte(len(passwordBytes) + 2)
		copy(innerPayload[3:], passwordBytes)
		innerPacket, err = buildPulseEAP(pulseEAPResponse, c.innerIdentifier, pulseEAPTypeExpanded, 2, innerPayload)
		clear(passwordBytes)
		clear(innerPayload)
	}
	if err != nil {
		clear(content)
		return nil, "", err
	}
	content, err = appendPulseAVP(content, pulseAVPEAPMessage, 0, innerPacket)
	clear(innerPacket)
	if err != nil {
		clear(content)
		return nil, "", err
	}
	return content, "", nil
}

func (c pulseAuthenticationChallenge) buildPasswordChangeResponse(response authenticationResponse) ([]byte, string, error) {
	oldPassword, oldLoaded := response.Values[pulseOldPasswordSubmissionKey]
	newPassword, newLoaded := response.Values[pulseNewPasswordSubmissionKey]
	verifyPassword, verifyLoaded := response.Values[pulseVerifyPasswordSubmissionKey]
	if !oldLoaded || !newLoaded || !verifyLoaded {
		return nil, "", E.New("password-change response omitted a password field")
	}
	if newPassword != verifyPassword {
		return nil, "New passwords do not match.", nil
	}
	oldBytes := []byte(oldPassword)
	newBytes := []byte(newPassword)
	defer clear(oldBytes)
	defer clear(newBytes)
	if len(oldBytes) > 253 {
		return nil, "Current password exceeds the Pulse 253-byte limit.", nil
	}
	if len(newBytes) > 253 {
		return nil, "New password exceeds the Pulse 253-byte limit.", nil
	}
	innerPayload := make([]byte, 0, len(oldBytes)+len(newBytes)+5)
	innerPayload = append(innerPayload, 2, 2, byte(len(oldBytes)+2))
	innerPayload = append(innerPayload, oldBytes...)
	innerPayload = append(innerPayload, 3, byte(len(newBytes)+2))
	innerPayload = append(innerPayload, newBytes...)
	innerPacket, err := buildPulseEAP(pulseEAPResponse, c.innerIdentifier, pulseEAPTypeExpanded, 2, innerPayload)
	clear(innerPayload)
	if err != nil {
		return nil, "", err
	}
	content, err := appendPulseAVP(nil, pulseAVPEAPMessage, 0, innerPacket)
	clear(innerPacket)
	return content, "", err
}

func (c pulseAuthenticationChallenge) buildGTCResponse(response authenticationResponse) ([]byte, string, error) {
	var content []byte
	if c.promptFlags&pulsePromptUsername != 0 {
		username, loaded := response.Values[pulseUsernameSubmissionKey]
		if !loaded {
			return nil, "", E.New("GTC response omitted username")
		}
		var err error
		content, err = appendPulseAVP(content, 0xd6d, pulseVendorJuniper2, []byte(username))
		if err != nil {
			return nil, "", err
		}
	}
	token, loaded := response.Values[pulseTokenSubmissionKey]
	if !loaded {
		clear(content)
		return nil, "", E.New("GTC response omitted token code")
	}
	tokenBytes := []byte(token)
	defer clear(tokenBytes)
	if len(tokenBytes) > 253 {
		clear(content)
		return nil, "Token code exceeds the Pulse 253-byte limit.", nil
	}
	innerPacket, err := buildPulseEAP(pulseEAPResponse, c.innerIdentifier, pulseEAPTypeGTC, 0, tokenBytes)
	if err != nil {
		clear(content)
		return nil, "", err
	}
	content, err = appendPulseAVP(content, pulseAVPEAPMessage, 0, innerPacket)
	clear(innerPacket)
	if err != nil {
		clear(content)
		return nil, "", err
	}
	return content, "", nil
}

func parsePulseSessionChoice(content []byte) (pulseSessionChoice, error) {
	attributes, err := parsePulseAVPs(content)
	if err != nil {
		return pulseSessionChoice{}, err
	}
	var choice pulseSessionChoice
	for _, attribute := range attributes {
		if attribute.vendor != pulseVendorJuniper2 {
			continue
		}
		switch attribute.code {
		case 0xd66:
			choice.identifier = string(attribute.data)
		case 0xd67:
			choice.source = string(attribute.data)
		case 0xd68:
			if len(attribute.data) != 8 {
				return pulseSessionChoice{}, E.New("session timestamp has invalid length")
			}
			seconds := binary.BigEndian.Uint64(attribute.data)
			if seconds > uint64(^uint64(0)>>1) {
				return pulseSessionChoice{}, E.New("session timestamp exceeds the supported range")
			}
			choice.createdAt = time.Unix(int64(seconds), 0)
		}
	}
	if choice.identifier == "" || choice.source == "" || choice.createdAt.IsZero() {
		return pulseSessionChoice{}, E.New("session choice omitted required fields")
	}
	return choice, nil
}

func normalizePulsePrompt(content []byte) string {
	if len(content) == 0 {
		return ""
	}
	prompt := string(content)
	if !strings.HasSuffix(prompt, ":") {
		prompt += ":"
	}
	return prompt
}
