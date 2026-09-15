package openconnect

import (
	"context"
	"crypto/x509"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	clientReconnectInitialBackoff = time.Second
	clientReconnectMaximumBackoff = 60 * time.Second
)

type clientSession interface {
	Start() error
	Done() <-chan error
	WriteDataPackets(packets [][]byte) error
	WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error
	Fail(err error)
	Close() error
	Ready() bool
	TunnelConfiguration() TunnelConfiguration
}

type clientSessionErrorClass uint8

const (
	clientSessionErrorRetryable clientSessionErrorClass = iota
	clientSessionErrorTerminal
)

func classifyClientSessionError(err error) clientSessionErrorClass {
	if err == nil {
		return clientSessionErrorRetryable
	}
	_, retryableAuthentication := E.Cast[*retryableAuthenticationError](err)
	if retryableAuthentication {
		return clientSessionErrorRetryable
	}
	terminal, isTerminal := E.Cast[interface{ Terminal() bool }](err)
	if isTerminal && terminal.Terminal() {
		return clientSessionErrorTerminal
	}
	if E.IsMulti(
		err,
		ErrMissingServer,
		ErrUnsupportedFlavor,
		ErrAuthenticationFailed,
		ErrInvalidBrowserAuthentication,
		ErrMaterialSourceConflict,
		ErrInvalidTLSMaterial,
		ErrDeprecatedCryptoDisabled,
		ErrProtocolNotSupported,
		errTunnelConfiguration,
	) {
		return clientSessionErrorTerminal
	}
	_, unknownAuthority := E.Cast[x509.UnknownAuthorityError](err)
	if unknownAuthority {
		return clientSessionErrorTerminal
	}
	_, hostnameError := E.Cast[x509.HostnameError](err)
	if hostnameError {
		return clientSessionErrorTerminal
	}
	_, certificateError := E.Cast[x509.CertificateInvalidError](err)
	if certificateError {
		return clientSessionErrorTerminal
	}
	return clientSessionErrorRetryable
}

func (c *Client) runSupervisor(ctx context.Context) {
	defer close(c.supervisorDone)
	defer c.closeSupervisorState()
	var sessionState obtainedSession
	backoff := clientReconnectInitialBackoff
	established := false
	pendingRekeyEvent := false
	reconnecting := false
	var reconnectTimeoutRemaining time.Duration
	for {
		if ctx.Err() != nil || c.isClosed() {
			_ = closeObtainedSession(sessionState)
			return
		}
		if sessionState == nil {
			obtained, err := c.obtainSession(ctx)
			if err != nil {
				if ctx.Err() != nil || c.isClosed() {
					return
				}
				c.handleRetryableAuthenticationError(err)
				if classifyClientSessionError(err) == clientSessionErrorTerminal {
					c.setTerminalError(err)
					return
				}
				if c.options.Logger != nil {
					c.options.Logger.DebugContext(ctx, "session setup failed; retrying in ", backoff, ": ", err)
				}
				if !c.waitClientReconnectBackoff(ctx, backoff, reconnecting, &reconnectTimeoutRemaining) {
					return
				}
				backoff = nextClientReconnectBackoff(backoff)
				continue
			}
			if obtained == nil {
				c.setTerminalError(E.Extend(ErrProtocolNotSupported, "flavor returned an empty obtained session"))
				return
			}
			sessionState = obtained
		}
		session, err := c.frontend.ConnectTunnel(ctx, sessionState)
		if err != nil {
			if E.IsMulti(err, ErrSessionRejected) {
				_ = closeObtainedSession(sessionState)
				sessionState = nil
				pendingRekeyEvent = false
				if c.options.Logger != nil {
					c.options.Logger.DebugContext(ctx, "tunnel session was rejected; retrying in ", backoff, ": ", err)
				}
				if !c.waitClientReconnectBackoff(ctx, backoff, reconnecting, &reconnectTimeoutRemaining) {
					return
				}
				backoff = nextClientReconnectBackoff(backoff)
				continue
			}
			_, rekeyRequested := E.Cast[*sessionRekeyError](err)
			if rekeyRequested {
				pendingRekeyEvent = true
				backoff = clientReconnectInitialBackoff
				continue
			}
			if ctx.Err() != nil || c.isClosed() {
				_ = closeObtainedSession(sessionState)
				return
			}
			if c.handleRetryableAuthenticationError(err) {
				_ = closeObtainedSession(sessionState)
				sessionState = nil
				pendingRekeyEvent = false
				backoff = clientReconnectInitialBackoff
				if c.options.Logger != nil {
					c.options.Logger.DebugContext(ctx, "authentication was rejected; restarting authentication: ", err)
				}
				continue
			}
			if classifyClientSessionError(err) == clientSessionErrorTerminal {
				_ = closeObtainedSession(sessionState)
				c.setTerminalError(err)
				return
			}
			if c.options.Logger != nil {
				c.options.Logger.DebugContext(ctx, "tunnel connection failed; retrying in ", backoff, ": ", err)
			}
			if !c.waitClientReconnectBackoff(ctx, backoff, reconnecting, &reconnectTimeoutRemaining) {
				_ = closeObtainedSession(sessionState)
				return
			}
			backoff = nextClientReconnectBackoff(backoff)
			continue
		}
		if !c.setCurrentSession(ctx, session) {
			_ = session.Close()
			_ = closeObtainedSession(sessionState)
			return
		}
		err = session.Start()
		if err != nil {
			closeErr := session.Close()
			err = E.Append(err, closeErr, func(cause error) error {
				return E.Cause(cause, "close failed openconnect session")
			})
			c.clearCurrentSession(session)
			_, rekeyRequested := E.Cast[*sessionRekeyError](err)
			if rekeyRequested {
				pendingRekeyEvent = true
				backoff = clientReconnectInitialBackoff
				continue
			}
			sessionRejected := E.IsMulti(err, ErrSessionRejected)
			retryableAuthentication := false
			if !sessionRejected {
				retryableAuthentication = c.handleRetryableAuthenticationError(err)
			}
			if sessionRejected || retryableAuthentication {
				_ = closeObtainedSession(sessionState)
				sessionState = nil
				pendingRekeyEvent = false
				if sessionRejected {
					if c.options.Logger != nil {
						c.options.Logger.DebugContext(ctx, "tunnel session start was rejected; retrying in ", backoff, ": ", err)
					}
					if !c.waitClientReconnectBackoff(ctx, backoff, reconnecting, &reconnectTimeoutRemaining) {
						return
					}
					backoff = nextClientReconnectBackoff(backoff)
				} else {
					backoff = clientReconnectInitialBackoff
					if c.options.Logger != nil {
						c.options.Logger.DebugContext(ctx, "authentication was rejected while starting the tunnel; restarting authentication: ", err)
					}
				}
				continue
			}
			if classifyClientSessionError(err) == clientSessionErrorTerminal {
				_ = closeObtainedSession(sessionState)
				c.setTerminalError(err)
				return
			}
			if c.options.Logger != nil {
				c.options.Logger.DebugContext(ctx, "tunnel start failed; retrying in ", backoff, ": ", err)
			}
			if !c.waitClientReconnectBackoff(ctx, backoff, reconnecting, &reconnectTimeoutRemaining) {
				_ = closeObtainedSession(sessionState)
				return
			}
			backoff = nextClientReconnectBackoff(backoff)
			continue
		}
		reason := TunnelConfigurationEventInitial
		if pendingRekeyEvent {
			reason = TunnelConfigurationEventRekey
			pendingRekeyEvent = false
		} else if established {
			reason = TunnelConfigurationEventReestablishment
		}
		established = true
		reconnecting = false
		reconnectTimeoutRemaining = 0
		configuration := c.setTunnelConfiguration(session.TunnelConfiguration())
		if !c.publishCurrentSession(ctx, session) {
			_ = session.Close()
			c.clearCurrentSession(session)
			_ = closeObtainedSession(sessionState)
			return
		}
		c.publishTunnelConfigurationEvent(reason, configuration)
		if c.options.Logger != nil {
			if reason == TunnelConfigurationEventInitial {
				c.options.Logger.InfoContext(ctx, c.options.Flavor, " tunnel established using ", c.ActiveTransport())
			} else {
				c.options.Logger.InfoContext(ctx, c.options.Flavor, " tunnel re-established using ", c.ActiveTransport())
			}
		}
		var sessionErr error
		select {
		case <-ctx.Done():
		case doneErr, open := <-session.Done():
			if open {
				sessionErr = doneErr
			}
		}
		closeErr := session.Close()
		if closeErr != nil {
			sessionErr = E.Append(sessionErr, closeErr, func(cause error) error {
				return E.Cause(cause, "close openconnect session")
			})
		}
		c.clearCurrentSession(session)
		if ctx.Err() != nil || c.isClosed() {
			_ = closeObtainedSession(sessionState)
			return
		}
		if E.IsMulti(sessionErr, ErrSessionRejected) {
			_ = closeObtainedSession(sessionState)
			sessionState = nil
			pendingRekeyEvent = false
			reconnecting = true
			reconnectTimeoutRemaining = c.options.ReconnectTimeout
			backoff = clientReconnectInitialBackoff
			if c.options.Logger != nil {
				c.options.Logger.DebugContext(ctx, "established tunnel session was rejected; retrying immediately: ", sessionErr)
			}
			continue
		}
		_, rekeyRequested := E.Cast[*sessionRekeyError](sessionErr)
		if rekeyRequested {
			pendingRekeyEvent = true
			backoff = clientReconnectInitialBackoff
			continue
		}
		if c.handleRetryableAuthenticationError(sessionErr) {
			_ = closeObtainedSession(sessionState)
			sessionState = nil
			pendingRekeyEvent = false
			backoff = clientReconnectInitialBackoff
			if c.options.Logger != nil {
				c.options.Logger.DebugContext(ctx, "authentication expired; restarting authentication: ", sessionErr)
			}
			continue
		}
		if classifyClientSessionError(sessionErr) == clientSessionErrorTerminal {
			_ = closeObtainedSession(sessionState)
			c.setTerminalError(sessionErr)
			return
		}
		if sessionErr == nil {
			sessionErr = E.New("tunnel ended without an error")
		}
		reconnecting = true
		reconnectTimeoutRemaining = c.options.ReconnectTimeout
		backoff = clientReconnectInitialBackoff
		if c.options.Logger != nil {
			c.options.Logger.DebugContext(ctx, "tunnel ended; retrying immediately: ", sessionErr)
		}
	}
}

func (c *Client) obtainSession(ctx context.Context) (obtainedSession, error) {
	c.resetTLSClientCertificate()
	continuation := c.frontend.BeginAuthentication()
	if continuation == nil {
		return nil, E.Extend(ErrProtocolNotSupported, "flavor returned an empty authentication continuation")
	}
	var response *authenticationResponse
	for {
		session, request, err := continuation.Advance(ctx, response)
		if err != nil {
			closeErr := continuation.Close()
			return nil, E.Append(err, closeErr, func(cause error) error {
				return E.Cause(cause, "close failed openconnect authentication continuation")
			})
		}
		if session != nil {
			if request != nil {
				closeErr := continuation.Close()
				contractErr := E.Extend(ErrProtocolNotSupported, "authentication continuation returned a session and a pending challenge together")
				return nil, E.Append(contractErr, closeErr, func(cause error) error {
					return E.Cause(cause, "close invalid openconnect authentication continuation")
				})
			}
			return session, nil
		}
		if request == nil {
			closeErr := continuation.Close()
			contractErr := E.Extend(ErrProtocolNotSupported, "authentication continuation returned neither a session nor a pending challenge")
			return nil, E.Append(contractErr, closeErr, func(cause error) error {
				return E.Cause(cause, "close invalid openconnect authentication continuation")
			})
		}
		challengeResponse, challengeErr := c.awaitAuthChallenge(ctx, *request, continuation)
		if challengeErr != nil {
			closeErr := continuation.Close()
			return nil, E.Append(challengeErr, closeErr, func(cause error) error {
				return E.Cause(cause, "close openconnect authentication continuation")
			})
		}
		response = &challengeResponse
	}
}

func closeObtainedSession(session obtainedSession) error {
	if session == nil {
		return nil
	}
	return session.Close()
}

func (c *Client) handleRetryableAuthenticationError(err error) bool {
	authenticationError, loaded := E.Cast[*retryableAuthenticationError](err)
	if loaded {
		c.clearStableCredentials(authenticationError.cacheKeys...)
	}
	return loaded
}

func (c *Client) waitClientReconnectBackoff(
	ctx context.Context,
	backoff time.Duration,
	reconnecting bool,
	reconnectTimeoutRemaining *time.Duration,
) bool {
	wait := backoff
	if reconnecting {
		if *reconnectTimeoutRemaining <= 0 {
			c.setTerminalError(ErrReconnectTimeout)
			return false
		}
		if *reconnectTimeoutRemaining < wait {
			wait = *reconnectTimeoutRemaining
		}
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		if reconnecting {
			*reconnectTimeoutRemaining -= wait
		}
		return true
	}
}

func nextClientReconnectBackoff(backoff time.Duration) time.Duration {
	next := backoff * 2
	if next > clientReconnectMaximumBackoff {
		return clientReconnectMaximumBackoff
	}
	return next
}

func (c *Client) setCurrentSession(ctx context.Context, session clientSession) bool {
	c.lifecycleAccess.Lock()
	defer c.lifecycleAccess.Unlock()
	if c.closed || ctx.Err() != nil {
		return false
	}
	c.currentSession = session
	c.publishedSession = nil
	c.activeTransportSession = session
	c.setActiveTransportWithLifecycleLocked("")
	c.signalStateChangedLocked()
	return true
}

func (c *Client) publishCurrentSession(ctx context.Context, session clientSession) bool {
	c.lifecycleAccess.Lock()
	defer c.lifecycleAccess.Unlock()
	if c.closed || c.terminalError != nil || ctx.Err() != nil || c.currentSession != session || !session.Ready() {
		return false
	}
	c.publishedSession = session
	c.signalStateChangedLocked()
	return true
}

func (c *Client) clearCurrentSession(session clientSession) {
	c.lifecycleAccess.Lock()
	if c.currentSession == session {
		c.currentSession = nil
		c.publishedSession = nil
		c.activeTransportSession = nil
		c.setActiveTransportWithLifecycleLocked("")
	}
	c.signalStateChangedLocked()
	c.lifecycleAccess.Unlock()
}

func (c *Client) readySession() clientSession {
	c.lifecycleAccess.Lock()
	defer c.lifecycleAccess.Unlock()
	if c.closed || c.terminalError != nil || c.currentSession == nil || c.publishedSession != c.currentSession || !c.currentSession.Ready() {
		return nil
	}
	return c.currentSession
}

func (c *Client) setTerminalError(err error) {
	if err == nil {
		err = E.New("session terminated")
	}
	c.lifecycleAccess.Lock()
	if c.closed {
		c.lifecycleAccess.Unlock()
		return
	}
	if c.terminalError == nil {
		c.terminalError = err
		c.activeTransportSession = nil
		c.setActiveTransportWithLifecycleLocked("")
		c.signalStateChangedLocked()
	}
	cancelSupervisor := c.supervisorCancel
	c.lifecycleAccess.Unlock()
	if cancelSupervisor != nil {
		cancelSupervisor()
	}
}

func (c *Client) isClosed() bool {
	c.lifecycleAccess.Lock()
	defer c.lifecycleAccess.Unlock()
	return c.closed
}

func (c *Client) signalStateChangedLocked() {
	close(c.stateChanged)
	c.stateChanged = make(chan struct{})
}

func (c *Client) closeSupervisorState() {
	c.lifecycleAccess.Lock()
	if !c.closed && c.terminalError == nil {
		c.closed = true
	}
	c.currentSession = nil
	c.publishedSession = nil
	c.activeTransportSession = nil
	c.setActiveTransportWithLifecycleLocked("")
	c.signalStateChangedLocked()
	c.lifecycleAccess.Unlock()
}
