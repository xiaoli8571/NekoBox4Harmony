package openvpn

import (
	"encoding/base64"
	"strings"
	"time"
)

type tlsControlDirective int

const (
	tlsControlDirectiveUnknown tlsControlDirective = iota
	tlsControlDirectiveAuthFailed
	tlsControlDirectiveAuthPending
	tlsControlDirectivePushReply
	tlsControlDirectiveRestart
	tlsControlDirectiveHalt
	tlsControlDirectiveExit
	tlsControlDirectiveInfoPre
	tlsControlDirectiveInfo
	tlsControlDirectiveCRResponse
)

// Upstream parse_incoming_control_channel_command checks INFO_PRE before INFO.
func classifyTLSControlDirective(payload []byte) tlsControlDirective {
	normalizedPayload := normalizeControlPayload(payload)
	if normalizedPayload == "" {
		return tlsControlDirectiveUnknown
	}
	upperPayload := strings.ToUpper(normalizedPayload)
	switch {
	case upperPayload == "AUTH_FAILED" || strings.HasPrefix(upperPayload, "AUTH_FAILED,"):
		return tlsControlDirectiveAuthFailed
	case upperPayload == "AUTH_PENDING" || strings.HasPrefix(upperPayload, "AUTH_PENDING,"):
		return tlsControlDirectiveAuthPending
	case strings.HasPrefix(upperPayload, "PUSH_"):
		return tlsControlDirectivePushReply
	case upperPayload == "RESTART" || strings.HasPrefix(upperPayload, "RESTART,"):
		return tlsControlDirectiveRestart
	case upperPayload == "HALT" || strings.HasPrefix(upperPayload, "HALT,"):
		return tlsControlDirectiveHalt
	case upperPayload == "INFO_PRE" || strings.HasPrefix(upperPayload, "INFO_PRE,"):
		return tlsControlDirectiveInfoPre
	case upperPayload == "INFO" || strings.HasPrefix(upperPayload, "INFO,"):
		return tlsControlDirectiveInfo
	case upperPayload == "CR_RESPONSE" || strings.HasPrefix(upperPayload, "CR_RESPONSE,"):
		return tlsControlDirectiveCRResponse
	case upperPayload == "EXIT" || strings.HasPrefix(upperPayload, "EXIT,"):
		return tlsControlDirectiveExit
	default:
		return tlsControlDirectiveUnknown
	}
}

// Upstream parse_incoming_control_channel_command (forward.c) treats
// AUTH_PENDING as informational.
func (c *tlsClient) dispatchControlDirective(controlRecord []byte) error {
	switch classifyTLSControlDirective(controlRecord) {
	case tlsControlDirectiveAuthFailed:
		return c.authFailedError(controlRecord)
	case tlsControlDirectiveRestart:
		return newServerRestartError(controlRecord)
	case tlsControlDirectiveHalt:
		return ErrServerHalt
	case tlsControlDirectiveExit:
		return ErrServerExit
	case tlsControlDirectiveInfoPre:
		c.handleServerPushedInfo(controlRecord, time.Time{})
		return nil
	case tlsControlDirectivePushReply:
		decodedPushedOptions, _, decoded := decodePushReplyPayloadWithFilters(controlRecord, c.remoteTransportAddress(), c.parent.options.Pull.Filters)
		if !decoded {
			return nil
		}
		return c.applyDecodedPushedOptions(decodedPushedOptions)
	default:
		return nil
	}
}

func (c *tlsClient) applyDecodedPushedOptions(options pushedOptions) error {
	c.pushAccess.Lock()
	defer c.pushAccess.Unlock()
	applyResult := c.parent.applyPushedOptions(options)
	if applyResult.pullFilterRejection != "" {
		return ErrPullFilterRejected
	}
	if applyResult.compressionPushRejection != "" {
		return ErrCompressionPushRejected
	}
	if options.PeerID != nil {
		c.setPeerID(options.PeerID)
	}
	return nil
}

func (c *tlsClient) handleServerPushedInfo(controlRecord []byte, deadline time.Time) {
	payload := normalizeControlPayload(controlRecord)
	_, infoPayload, hasPayload := strings.Cut(payload, ",")
	if !hasPayload {
		return
	}
	challenge, parsed := parseServerPushedChallenge(infoPayload)
	if !parsed {
		return
	}
	challenge.ID = newChallengeID()
	challenge.Username = c.parent.options.Authentication.Username
	challenge.Deadline = deadline
	state := &pendingChallengeState{
		challenge: challenge,
		owner:     c,
		cancel: func() {
			c.access.Lock()
			c.challengeCancelErr = ErrChallengeCanceled
			c.access.Unlock()
			c.finish(ErrChallengeCanceled)
			_ = c.Close()
		},
	}
	if challenge.Kind == ChallengeSecret {
		state.complete = func(response ChallengeResponse) error {
			c.parent.noteChallengeResponseSubmitted()
			// Upstream man_send_cc_message (manage.c) sends management cr-response answers as CR_RESPONSE,<base64>.
			responsePayload := tlsControlStringPayload([]byte("CR_RESPONSE," + base64.StdEncoding.EncodeToString([]byte(response.Secret))))
			return c.writeControlChannelPayload(responsePayload, time.Now().Add(c.handshakeWindow))
		}
	}
	c.parent.publishChallenge(state)
}

func (c *tlsClient) authFailedError(controlRecord []byte) error {
	info := parseAuthFailedPayload(controlRecord)
	if (!info.failed || !info.temporary) && c.parent.clearAuthToken() {
		return &AuthTokenAuthenticationFailedError{Reason: info.reason}
	}
	return newAuthFailedErrorFromPayload(controlRecord, c.parent.options.Authentication.AuthRetry)
}

// Upstream send_control_channel_string (sig.c) writes "EXIT".
var tlsControlChannelExitPayload = tlsControlStringPayload([]byte("EXIT"))

// Upstream send_push_reply (push.c) uses this protocol-flags token.
const tlsProtocolFlagCCExit = "cc-exit"

// Upstream p2p_ncp_set_options/comp_options_postprocess (ssl_ncp.c/options.c)
// requires both IV_PROTO_CC_EXIT_NOTIFY and pushed cc-exit.
func shouldSendCCExitOverControlChannel(tunnelConfiguration TunnelConfiguration) bool {
	for _, protocolFlag := range tunnelConfiguration.ProtocolFlags {
		if strings.EqualFold(strings.TrimSpace(protocolFlag), tlsProtocolFlagCCExit) {
			return true
		}
	}
	return false
}

// Upstream key-derivation/protocol-flags parsing (options.c) uses this token.
const tlsProtocolFlagTLSKeyMaterialExport = "tls-ekm"

// Upstream generate_key_expansion (ssl.c) branches on the pushed
// CO_USE_TLS_KEY_MATERIAL_EXPORT flag.
func tunnelUsesKeyMaterialExport(tunnelConfiguration TunnelConfiguration) bool {
	if strings.EqualFold(strings.TrimSpace(tunnelConfiguration.KeyDerivation), tlsProtocolFlagTLSKeyMaterialExport) {
		return true
	}
	for _, protocolFlag := range tunnelConfiguration.ProtocolFlags {
		if strings.EqualFold(strings.TrimSpace(protocolFlag), tlsProtocolFlagTLSKeyMaterialExport) {
			return true
		}
	}
	return false
}
