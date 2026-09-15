package openconnect

import E "github.com/sagernet/sing/common/exceptions"

var (
	ErrMissingServer                = E.New("missing openconnect server")
	ErrUnsupportedFlavor            = E.New("unsupported openconnect flavor")
	ErrClientClosed                 = E.New("client is closed")
	ErrDataChannelNotReady          = E.New("data channel is not ready")
	ErrNoPendingAuthChallenge       = E.New("no pending openconnect authentication challenge")
	ErrAuthChallengeNotAnswerable   = E.New("authentication challenge does not accept a response")
	ErrAuthChallengeCanceled        = E.New("authentication challenge canceled")
	ErrInvalidAuthResponse          = E.New("invalid openconnect authentication response")
	ErrAuthenticationFailed         = E.New("authentication failed")
	ErrSessionRejected              = E.New("session rejected")
	ErrInvalidBrowserAuthentication = E.New("invalid openconnect browser authentication result")
	ErrMaterialSourceConflict       = E.New("material path and content are both set")
	ErrInvalidTLSMaterial           = E.New("invalid openconnect TLS material")
	ErrDeprecatedCryptoDisabled     = E.New("deprecated cryptography is disabled")
	ErrReconnectTimeout             = E.New("reconnect timeout exceeded")
	ErrProtocolNotSupported         = E.New("protocol behavior is not supported")
	errTunnelConfiguration          = E.New("tunnel configuration callback failed")
)

type retryableAuthenticationError struct {
	err       error
	cacheKeys []string
}

func (e *retryableAuthenticationError) Error() string {
	return e.err.Error()
}

func (e *retryableAuthenticationError) Unwrap() error {
	return ErrAuthenticationFailed
}

func newRetryableAuthenticationError(err error, cacheKeys ...string) error {
	if err == nil {
		err = ErrAuthenticationFailed
	}
	return &retryableAuthenticationError{
		err:       err,
		cacheKeys: append([]string(nil), cacheKeys...),
	}
}

type terminalError struct {
	err error
}

func (e *terminalError) Error() string {
	return e.err.Error()
}

func (e *terminalError) Unwrap() error {
	return e.err
}

func (e *terminalError) Terminal() bool {
	return true
}

func markTerminal(err error) error {
	if err == nil {
		return nil
	}
	return &terminalError{err: err}
}
