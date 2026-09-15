package openvpn

import (
	"strings"
	"time"
)

// Upstream reliable_schedule_packet (reliable.c) caps TLS retransmission
// backoff; options_postprocess_mutate (options.c) defaults hand-window.
const (
	tlsHandshakeRetryInitial  = 2 * time.Second
	tlsHandshakeRetryMaximum  = 60 * time.Second
	tlsHandshakeTotalDuration = 60 * time.Second
	prePullInitialPingRestart = 120 * time.Second
	defaultMSSFix             = 1492
)

const (
	MSSFixModeMTU   = "mtu"
	MSSFixModeFixed = "fixed"
)

// Upstream check_push_request (forward.c) re-sends PUSH_REQUEST every
// PUSH_REQUEST_INTERVAL seconds until push_request_timeout, which starts at
// hand-window and is replaced by AUTH_PENDING; this resend is also what keeps
// the pending authentication exchange alive.
const tlsPushRequestResendInterval = 5 * time.Second

type clientPingTimeoutAction uint8

const (
	clientPingTimeoutNone clientPingTimeoutAction = iota
	clientPingTimeoutRestart
	clientPingTimeoutExit
)

// Upstream stores one ping receive timeout and the action selected by the
// latest ping-exit/ping-restart directive. A pushed ping-exit takes precedence
// over a locally configured ping-restart in the effective tunnel state.
func effectiveClientPingTimeout(configuration TunnelConfiguration) (time.Duration, clientPingTimeoutAction) {
	if configuration.PingExit > 0 {
		return configuration.PingExit, clientPingTimeoutExit
	}
	if configuration.PingRestart > 0 {
		return configuration.PingRestart, clientPingTimeoutRestart
	}
	return 0, clientPingTimeoutNone
}

func (c *tlsClient) prePullPingRestart() time.Duration {
	if c.parent.options.Timing.PingRestartDisabled {
		return 0
	}
	if c.parent.options.Timing.PingRestart > 0 {
		return c.parent.options.Timing.PingRestart
	}
	if c.parent.options.Pull.Enabled && strings.HasPrefix(c.remote.remote.Protocol, "udp") {
		return prePullInitialPingRestart
	}
	return 0
}

// Upstream check_ping_restart/check_ping_exit (forward.c).
func shouldExitForPingTimeout(lastInbound time.Time, now time.Time, threshold time.Duration) bool {
	if threshold <= 0 || lastInbound.IsZero() {
		return false
	}
	return now.Sub(lastInbound) > threshold
}

// Upstream check_inactivity_timeout (forward.c).
func shouldExitForInactivityTimeout(lastInactivityReset time.Time, now time.Time, inactiveTimeout time.Duration) bool {
	if inactiveTimeout <= 0 {
		return false
	}
	if lastInactivityReset.IsZero() {
		return false
	}
	return now.Sub(lastInactivityReset) >= inactiveTimeout
}
