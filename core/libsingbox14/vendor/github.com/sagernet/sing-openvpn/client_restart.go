package openvpn

import (
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

type clientRemoteAdvance uint8

const (
	clientRemoteAdvanceStay clientRemoteAdvance = iota
	clientRemoteAdvanceNextAddress
	clientRemoteAdvanceNextRemote
)

type serverRestartError struct {
	advance clientRemoteAdvance
}

func (e *serverRestartError) Error() string {
	return ErrServerRestart.Error()
}

func (e *serverRestartError) Unwrap() error {
	return ErrServerRestart
}

// Upstream server_pushed_signal keeps the current connection entry after a
// completed initialization. RESTART,[N] clears that no-advance state so the
// next resolved address is selected.
func newServerRestartError(payload []byte) error {
	restartError := &serverRestartError{advance: clientRemoteAdvanceStay}
	normalizedPayload := normalizeControlPayload(payload)
	_, flagsPayload, hasFlags := strings.Cut(normalizedPayload, ",")
	if !hasFlags {
		return restartError
	}
	flagsPayload = strings.TrimSpace(flagsPayload)
	if !strings.HasPrefix(flagsPayload, "[") {
		return restartError
	}
	endIndex := strings.IndexByte(flagsPayload, ']')
	if endIndex < 0 {
		return restartError
	}
	if strings.Contains(strings.ToUpper(flagsPayload[1:endIndex]), "N") {
		restartError.advance = clientRemoteAdvanceNextAddress
	}
	return restartError
}

type clientConnectionCursor struct {
	remoteIndex  int
	addressIndex int
}

func (c *Client) nextConnectionCursor(current clientConnectionCursor, sessionErr error, initialized bool) clientConnectionCursor {
	advance := clientRemoteAdvanceNextAddress
	if initialized {
		advance = clientRemoteAdvanceStay
	}
	if E.IsMulti(sessionErr, ErrRemoteAddressExhausted) {
		advance = clientRemoteAdvanceNextRemote
	}
	if restartError, loaded := E.Cast[*serverRestartError](sessionErr); loaded {
		advance = restartError.advance
	}
	if temporaryAuthError, loaded := E.Cast[*AuthFailedTemporaryError](sessionErr); loaded {
		switch temporaryAuthError.Advance {
		case AuthFailedAdvanceStay:
			advance = clientRemoteAdvanceStay
		case AuthFailedAdvanceNextAddress:
			advance = clientRemoteAdvanceNextAddress
		case AuthFailedAdvanceNextRemote:
			advance = clientRemoteAdvanceNextRemote
		}
	}
	if advance == clientRemoteAdvanceNextAddress && c.options.Transport.DialContextWithAddressIndex == nil {
		advance = clientRemoteAdvanceNextRemote
	}
	switch advance {
	case clientRemoteAdvanceNextAddress:
		current.addressIndex++
	case clientRemoteAdvanceNextRemote:
		current.remoteIndex = (current.remoteIndex + 1) % len(c.remotes)
		current.addressIndex = 0
	}
	return current
}
