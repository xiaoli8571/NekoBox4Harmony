package openvpn

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	authFailedPayload  = "AUTH_FAILED"
	authPendingPayload = "AUTH_PENDING"
)

// Upstream receive_auth_pending (push.c) replaces the pending-auth expiry:
// the timeout defaults to hand-window, the server may propose one with
// "AUTH_PENDING,timeout <seconds>", and the result is capped at
// max(reneg-sec/2, hand-window).
func authPendingDeadline(options ClientOptions, controlRecord []byte) time.Time {
	handWindow := options.Timing.HandWindow
	renegotiationInterval := options.Timing.RenegotiationInterval
	maximumExtension := max(handWindow, renegotiationInterval/2)
	extension := handWindow
	parsedTimeout, hasTimeout := parseAuthPendingTimeout(controlRecord)
	if hasTimeout {
		extension = time.Duration(parsedTimeout) * time.Second
	}
	extension = min(extension, maximumExtension)
	return time.Now().Add(extension)
}

// Upstream auth_user_pass_setup (ssl.c) fills auth_user_pass once, before the
// connection attempt and only while it is undefined, and get_user_pass_cr
// (misc.c) packs the static or dynamic challenge answer into its password field
// at that point. The record is what every key_method_2_write sends, survives
// failed attempts and renegotiations, and is dropped only by ssl_purge_auth.
type stagedCredentials struct {
	defined     bool
	interactive bool
	username    string
	password    string
}

func (c *Client) sessionCredentials(useActiveAuthToken bool) (string, string) {
	staged := c.loadStagedCredentials()
	if useActiveAuthToken {
		tokenUsername, tokenPassword, tokenDefined := c.activeAuthTokenCredentials(staged.username)
		if tokenDefined {
			return c.noteSentCredentials(tokenUsername, tokenPassword, false)
		}
	}
	return c.noteSentCredentials(staged.username, staged.password, staged.interactive)
}

func (c *Client) noteSentCredentials(username string, password string, usedInteractive bool) (string, string) {
	c.authentication.access.Lock()
	c.authentication.sentInteractiveCredentials = usedInteractive
	c.authentication.access.Unlock()
	return username, password
}

func (c *Client) lastSentCredentialsInteractive() bool {
	c.authentication.access.Lock()
	defer c.authentication.access.Unlock()
	return c.authentication.sentInteractiveCredentials
}

func (c *Client) loadStagedCredentials() stagedCredentials {
	c.authentication.access.Lock()
	defer c.authentication.access.Unlock()
	return c.authentication.staged
}

func (c *Client) stageCredentials(username string, password string, interactive bool) {
	c.authentication.access.Lock()
	c.authentication.staged = stagedCredentials{
		defined:     true,
		interactive: interactive,
		username:    username,
		password:    password,
	}
	c.authentication.access.Unlock()
}

// Upstream ssl_purge_auth (ssl.c) drops auth_user_pass so that the next
// auth_user_pass_setup queries the credentials again.
func (c *Client) purgeStagedCredentials() {
	c.authentication.access.Lock()
	c.authentication.staged = stagedCredentials{}
	c.authentication.access.Unlock()
}

func (c *Client) activeAuthTokenCredentials(fallbackUsername string) (string, string, bool) {
	c.tunnel.access.RLock()
	tokenConfiguration := TunnelConfiguration{
		AuthToken:     c.tunnel.authToken,
		AuthTokenUser: c.tunnel.authTokenUser,
	}
	c.tunnel.access.RUnlock()
	return resolveAuthTokenCredentials(c.options, tokenConfiguration, fallbackUsername)
}

func resolveAuthTokenCredentials(options ClientOptions, configuration TunnelConfiguration, stagedUsername string) (string, string, bool) {
	if configuration.AuthToken == "" {
		return "", "", false
	}
	if configuration.AuthTokenUser != "" {
		username, defined := decodeAuthTokenUsername(configuration.AuthTokenUser)
		if !defined {
			return "", "", false
		}
		return username, configuration.AuthToken, true
	}
	username := options.Authentication.Username
	if username == "" {
		username = stagedUsername
	}
	if username == "" {
		return "", "", false
	}
	return username, configuration.AuthToken, true
}

func decodeAuthTokenUsername(encodedUsername string) (string, bool) {
	decodedUsername, err := base64.StdEncoding.DecodeString(encodedUsername)
	if err != nil {
		return "", false
	}
	if len(decodedUsername) == 0 {
		return "", false
	}
	nullIndex := bytes.IndexByte(decodedUsername, 0)
	if nullIndex >= 0 {
		decodedUsername = decodedUsername[:nullIndex]
	}
	return string(decodedUsername), true
}

func isAuthFailedPayload(payload []byte) bool {
	normalizedPayload := normalizeControlPayload(payload)
	if normalizedPayload == "" {
		return false
	}
	if strings.EqualFold(normalizedPayload, authFailedPayload) {
		return true
	}
	return strings.HasPrefix(strings.ToUpper(normalizedPayload), authFailedPayload+",")
}

func buildAuthFailedPayload(reason string) []byte {
	trimmedReason := strings.TrimSpace(reason)
	if trimmedReason == "" {
		return []byte(authFailedPayload)
	}
	return []byte(authFailedPayload + "," + trimmedReason)
}

type AuthFailedAdvance int

const (
	AuthFailedAdvanceNextAddress AuthFailedAdvance = iota
	AuthFailedAdvanceNextRemote
	AuthFailedAdvanceStay
)

type AuthFailedTemporaryError struct {
	BackoffSeconds uint32
	Advance        AuthFailedAdvance
	Reason         string
}

func (temporaryError *AuthFailedTemporaryError) Error() string {
	if temporaryError.Reason == "" {
		return ErrAuthenticationFailed.Error() + ": temporary failure"
	}
	return ErrAuthenticationFailed.Error() + ": temporary failure: " + temporaryError.Reason
}

func (temporaryError *AuthFailedTemporaryError) Unwrap() error {
	return ErrAuthenticationFailed
}

type authFailedInfo struct {
	failed         bool
	temporary      bool
	reason         string
	backoffSeconds uint32
	advance        AuthFailedAdvance
}

// Upstream parse_auth_failed_temp parses:
//
//	AUTH_FAILED,TEMP[<flags>]:<reason>
//
// with "backoff <N>" and "advance no|remote|addr" flags.
func parseAuthFailedPayload(payload []byte) authFailedInfo {
	normalized := normalizeControlPayload(payload)
	if normalized == "" {
		return authFailedInfo{}
	}
	if !strings.HasPrefix(strings.ToUpper(normalized), authFailedPayload) {
		return authFailedInfo{}
	}
	suffix := strings.TrimPrefix(normalized, authFailedPayload)
	if suffix == "" {
		return authFailedInfo{failed: true}
	}
	if !strings.HasPrefix(suffix, ",") {
		return authFailedInfo{}
	}
	suffix = strings.TrimPrefix(suffix, ",")
	info := authFailedInfo{failed: true}
	if !strings.HasPrefix(strings.ToUpper(suffix), "TEMP") {
		info.reason = strings.TrimSpace(suffix)
		return info
	}
	info.temporary = true
	suffix = strings.TrimPrefix(suffix, "TEMP")
	if strings.HasPrefix(suffix, "[") {
		closingBracketIndex := strings.Index(suffix, "]")
		if closingBracketIndex >= 0 {
			bracketContent := suffix[1:closingBracketIndex]
			applyAuthFailedTemporaryFlags(&info, bracketContent)
			suffix = suffix[closingBracketIndex+1:]
		}
	}
	suffix = strings.TrimPrefix(suffix, ":")
	info.reason = strings.TrimSpace(suffix)
	return info
}

func applyAuthFailedTemporaryFlags(info *authFailedInfo, bracketContent string) {
	for flagEntry := range strings.SplitSeq(bracketContent, ",") {
		trimmedFlag := strings.TrimSpace(flagEntry)
		if trimmedFlag == "" {
			continue
		}
		keyword, value, hasSpace := strings.Cut(trimmedFlag, " ")
		if !hasSpace {
			continue
		}
		trimmedValue := strings.TrimSpace(value)
		switch strings.ToLower(keyword) {
		case "backoff":
			parsedBackoff, err := strconv.ParseUint(trimmedValue, 10, 32)
			if err == nil {
				info.backoffSeconds = uint32(parsedBackoff)
			}
		case "advance":
			switch strings.ToLower(trimmedValue) {
			case "no":
				info.advance = AuthFailedAdvanceStay
			case "remote":
				info.advance = AuthFailedAdvanceNextRemote
			case "addr":
				info.advance = AuthFailedAdvanceNextAddress
			}
		}
	}
}

func newAuthFailedErrorFromPayload(payload []byte, authRetry string) error {
	challenge, foundChallenge := extractCRV1FromAuthFailed(payload)
	if foundChallenge {
		return &AuthChallengeError{Challenge: challenge}
	}
	info := parseAuthFailedPayload(payload)
	if !info.failed {
		if resolveAuthRetryMode(authRetry) == AuthRetryModeNone {
			return &AuthFailedTerminalError{}
		}
		return ErrAuthenticationFailed
	}
	if info.temporary {
		return &AuthFailedTemporaryError{
			BackoffSeconds: info.backoffSeconds,
			Advance:        info.advance,
			Reason:         info.reason,
		}
	}
	if resolveAuthRetryMode(authRetry) == AuthRetryModeNone {
		return &AuthFailedTerminalError{Reason: info.reason}
	}
	return ErrAuthenticationFailed
}

type AuthTokenAuthenticationFailedError struct {
	Reason string
}

func (tokenError *AuthTokenAuthenticationFailedError) Error() string {
	if tokenError.Reason == "" {
		return ErrAuthenticationFailed.Error() + ": auth-token rejected"
	}
	return ErrAuthenticationFailed.Error() + ": auth-token rejected: " + tokenError.Reason
}

func (tokenError *AuthTokenAuthenticationFailedError) Unwrap() error {
	return ErrAuthenticationFailed
}

type AuthRetryMode string

const (
	AuthRetryModeNone       AuthRetryMode = "none"
	AuthRetryModeNoInteract AuthRetryMode = "nointeract"
	AuthRetryModeInteract   AuthRetryMode = "interact"
)

// Upstream auth_retry_get defaults unknown --auth-retry values to none.
func resolveAuthRetryMode(value string) AuthRetryMode {
	switch value {
	case string(AuthRetryModeNoInteract):
		return AuthRetryModeNoInteract
	case string(AuthRetryModeInteract):
		return AuthRetryModeInteract
	default:
		return AuthRetryModeNone
	}
}

type AuthFailedTerminalError struct {
	Reason string
}

func (terminalError *AuthFailedTerminalError) Error() string {
	if terminalError.Reason == "" {
		return ErrAuthenticationFailed.Error() + ": terminal (auth-retry none)"
	}
	return ErrAuthenticationFailed.Error() + ": terminal (auth-retry none): " + terminalError.Reason
}

func (terminalError *AuthFailedTerminalError) Unwrap() error {
	return ErrAuthenticationFailed
}

func (terminalError *AuthFailedTerminalError) Terminal() bool {
	return true
}

func parseAuthPendingTimeout(payload []byte) (uint32, bool) {
	normalized := normalizeControlPayload(payload)
	if normalized == "" {
		return 0, false
	}
	if !strings.HasPrefix(strings.ToUpper(normalized), authPendingPayload) {
		return 0, false
	}
	suffix := strings.TrimPrefix(normalized, authPendingPayload)
	if !strings.HasPrefix(suffix, ",") {
		return 0, false
	}
	suffix = strings.TrimPrefix(suffix, ",")
	for fieldEntry := range strings.SplitSeq(suffix, ",") {
		trimmedField := strings.TrimSpace(fieldEntry)
		if !strings.HasPrefix(strings.ToLower(trimmedField), "timeout") {
			continue
		}
		valueText := strings.TrimSpace(strings.TrimPrefix(trimmedField, "timeout"))
		valueText = strings.TrimPrefix(valueText, "=")
		valueText = strings.TrimSpace(valueText)
		parsedTimeout, err := strconv.ParseUint(valueText, 10, 32)
		if err == nil {
			return uint32(parsedTimeout), true
		}
	}
	return 0, false
}

type CRV1Challenge struct {
	StateID       string
	Username      string
	ChallengeText string
	Echo          bool
}

// Upstream get_auth_challenge (misc.c) reads
//
//	CRV1:<flags>:<state id>:<base64 user>:<challenge text>
//
// as colon-delimited fields through buf_parse, which fails only when the
// message ends before a field begins: the message must reach into the user name
// field, every field it reaches may be empty, and only the challenge text may
// be cut off entirely. The flag bag is scanned character by character for `E`
// and `R`, neither is required, and a user name that does not decode leaves the
// zero-filled user buffer as it is instead of rejecting the challenge.
func parseCRV1Challenge(challenge string) (CRV1Challenge, bool) {
	fields := strings.SplitN(challenge, ":", 5)
	if len(fields) < 4 || fields[0] != "CRV1" {
		return CRV1Challenge{}, false
	}
	if len(fields) == 4 && fields[3] == "" {
		return CRV1Challenge{}, false
	}
	challengeText := ""
	if len(fields) == 5 {
		challengeText = fields[4]
	}
	decodedUsername, _ := base64.StdEncoding.DecodeString(fields[3])
	return CRV1Challenge{
		StateID:       fields[2],
		Username:      string(decodedUsername),
		ChallengeText: challengeText,
		Echo:          strings.ContainsRune(fields[1], 'E'),
	}, true
}

// Upstream receive_auth_failed (push.c) keeps the challenge only when the text
// following "AUTH_FAILED," starts with "CRV1:".
func extractCRV1FromAuthFailed(payload []byte) (CRV1Challenge, bool) {
	normalized := normalizeControlPayload(payload)
	if !strings.HasPrefix(strings.ToUpper(normalized), authFailedPayload+",") {
		return CRV1Challenge{}, false
	}
	return parseCRV1Challenge(normalized[len(authFailedPayload)+1:])
}

type AuthChallengeError struct {
	Challenge CRV1Challenge
}

func (authError *AuthChallengeError) Error() string {
	return fmt.Sprintf("%s: dynamic challenge required: %s", ErrAuthenticationFailed.Error(), authError.Challenge.ChallengeText)
}

func (authError *AuthChallengeError) Unwrap() error {
	return ErrAuthenticationFailed
}
