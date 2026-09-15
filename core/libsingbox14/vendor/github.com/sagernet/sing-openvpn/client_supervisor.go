package openvpn

import (
	"context"
	cryptorand "crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"math/big"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	clientReconnectInitialBackoff = time.Second
	clientReconnectMaximumBackoff = 60 * time.Second
)

var errClientSessionConfiguration = E.New("client session configuration error")

type clientSession interface {
	Initialize(ctx context.Context) error
	Start() error
	Done() <-chan error
	WriteDataPackets(packets [][]byte) error
	WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error
	Fail(err error)
	Close() error
	Ready() bool
}

type clientSessionErrorClass int

const (
	clientSessionErrorRetryable clientSessionErrorClass = iota
	clientSessionErrorTerminal
)

func classifyClientSessionError(err error) clientSessionErrorClass {
	if err == nil {
		return clientSessionErrorRetryable
	}
	_, retryableAuthFailure := E.Cast[*AuthFailedTemporaryError](err)
	if retryableAuthFailure {
		return clientSessionErrorRetryable
	}
	_, tokenAuthFailure := E.Cast[*AuthTokenAuthenticationFailedError](err)
	if tokenAuthFailure {
		return clientSessionErrorRetryable
	}
	if terminalError, isTerminalError := err.(interface{ Terminal() bool }); isTerminalError && terminalError.Terminal() {
		return clientSessionErrorTerminal
	}
	if E.IsMulti(
		err,
		ErrServerHalt,
		ErrPeerCertificateVerification,
		ErrPeerCertificateRevoked,
		ErrPeerCertificateExtUsage,
		ErrPeerCertificateKeyUsage,
		ErrPeerCertificateNSCertType,
		ErrCRLSignatureInvalid,
		ErrCRLExpired,
		ErrCRLUnavailable,
		ErrCRLIssuerKeyUsage,
		ErrMissingServer,
		ErrUnsupportedProtocol,
		ErrUnsupportedMode,
		ErrMissingStaticKey,
		ErrCompressionNotSupported,
		ErrOptionNotSupported,
		ErrMissingCAOrPeerFingerprint,
		ErrInvalidAllowCompression,
		ErrAllowCompressionConflict,
		ErrPullFilterRejected,
		ErrCompressionPushRejected,
		ErrCipherNegotiationFailed,
		ErrChallengeCanceled,
		ErrPingExitTimeout,
		ErrInactiveTimeout,
		ErrSessionTimeout,
		errClientSessionConfiguration,
	) {
		return clientSessionErrorTerminal
	}
	_, isUnknownAuthorityError := E.Cast[x509.UnknownAuthorityError](err)
	if isUnknownAuthorityError {
		return clientSessionErrorTerminal
	}
	_, isHostnameError := E.Cast[x509.HostnameError](err)
	if isHostnameError {
		return clientSessionErrorTerminal
	}
	_, isCertificateInvalidError := E.Cast[x509.CertificateInvalidError](err)
	if isCertificateInvalidError {
		return clientSessionErrorTerminal
	}
	return clientSessionErrorRetryable
}

// Upstream auth_user_pass_setup (ssl.c) runs before every connection attempt but
// queries the credentials only while neither auth_user_pass nor auth_token is
// defined, so an answered challenge is asked for exactly once.
func (c *Client) acquireSessionCredentials(ctx context.Context, useActiveAuthToken bool) error {
	if c.mode != ModeTLS {
		return nil
	}
	if c.loadStagedCredentials().defined {
		return nil
	}
	if useActiveAuthToken {
		_, _, tokenDefined := c.activeAuthTokenCredentials("")
		if tokenDefined {
			return nil
		}
	}
	authentication := c.options.Authentication
	if authentication.StaticChallenge == "" {
		c.stageCredentials(authentication.Username, authentication.Password, false)
		return nil
	}
	username := authentication.Username
	password := authentication.Password
	var response ChallengeResponse
	var err error
	if username == "" && password == "" {
		response, err = c.awaitChallengeResponse(ctx, Challenge{
			Kind:          ChallengeCredentials,
			Username:      authentication.Username,
			SecretMessage: authentication.StaticChallenge,
			Echo:          authentication.StaticChallengeEcho,
		})
		if err != nil {
			return err
		}
		username = response.Username
		password = response.Password
	} else {
		response, err = c.awaitChallengeResponse(ctx, Challenge{
			Kind:     ChallengeSecret,
			Username: authentication.Username,
			Message:  authentication.StaticChallenge,
			Echo:     authentication.StaticChallengeEcho,
		})
		if err != nil {
			return err
		}
	}
	// Upstream get_user_pass_cr (misc.c) packs static challenge answers as
	// SCRV1:<base64 password>:<base64 answer>.
	encodedPassword := base64.StdEncoding.EncodeToString([]byte(password))
	encodedResponse := base64.StdEncoding.EncodeToString([]byte(response.Secret))
	c.stageCredentials(username, "SCRV1:"+encodedPassword+":"+encodedResponse, true)
	return nil
}

func (c *Client) interceptAuthChallenge(ctx context.Context, sessionErr error) (bool, error) {
	challengeErr, isChallenge := E.Cast[*AuthChallengeError](sessionErr)
	if isChallenge {
		// Upstream receive_auth_failed (push.c) purges auth_user_pass before it
		// stores the challenge, so the next auth_user_pass_setup asks for the
		// answer instead of reusing the rejected credentials.
		rejected := c.loadStagedCredentials()
		c.purgeStagedCredentials()
		if c.lastSentCredentialsInteractive() {
			c.notePreviousAuthFailure(ErrAuthenticationFailed.Error())
		}
		response, err := c.awaitChallengeResponse(ctx, Challenge{
			Kind:     ChallengeSecret,
			Username: challengeErr.Challenge.Username,
			Message:  challengeErr.Challenge.ChallengeText,
			Echo:     challengeErr.Challenge.Echo,
		})
		if err != nil {
			return false, err
		}
		username := challengeErr.Challenge.Username
		if username == "" {
			username = rejected.username
		}
		c.stageCredentials(
			username,
			// Upstream get_user_pass_cr (misc.c) packs dynamic challenge answers as CRV1::<state_id>::<response>.
			"CRV1::"+challengeErr.Challenge.StateID+"::"+response.Secret,
			true,
		)
		return true, nil
	}
	if !E.IsMulti(sessionErr, ErrAuthenticationFailed) {
		return false, nil
	}
	_, isTemporary := E.Cast[*AuthFailedTemporaryError](sessionErr)
	if isTemporary {
		return false, nil
	}
	_, isTokenFailure := E.Cast[*AuthTokenAuthenticationFailedError](sessionErr)
	if isTokenFailure {
		return false, nil
	}
	if !c.lastSentCredentialsInteractive() {
		return false, nil
	}
	c.purgeStagedCredentials()
	c.notePreviousAuthFailure(interactiveAuthFailureReason(sessionErr))
	return true, nil
}

func interactiveAuthFailureReason(sessionErr error) string {
	terminalFailure, isTerminalFailure := E.Cast[*AuthFailedTerminalError](sessionErr)
	if isTerminalFailure && terminalFailure.Reason != "" {
		return terminalFailure.Reason
	}
	return ErrAuthenticationFailed.Error()
}

func (c *Client) runSupervisor(ctx context.Context) {
	defer close(c.lifecycle.supervisorDone)
	defer c.closeSupervisorReadableState()
	backoff := clientReconnectInitialBackoff
	firstSession := true
	cursor := clientConnectionCursor{}
	for {
		if ctx.Err() != nil || c.isClosed() {
			return
		}
		err := c.acquireSessionCredentials(ctx, !firstSession)
		if err != nil {
			if ctx.Err() != nil || c.isClosed() {
				return
			}
			c.setTerminalError(err)
			return
		}
		remote := c.remotes[cursor.remoteIndex]
		remote.addressIndex = cursor.addressIndex
		var session clientSession
		session, err = c.newClientSession(!firstSession, remote)
		var stopSessionOnContextDone func() bool
		if err == nil {
			err = session.Initialize(ctx)
		}
		if err == nil {
			stopSessionOnContextDone = context.AfterFunc(ctx, func() {
				_ = session.Close()
			})
			if !c.setCurrentSession(ctx, session) {
				stopSessionOnContextDone()
				_ = session.Close()
				return
			}
			err = session.Start()
		}
		if err != nil {
			if stopSessionOnContextDone != nil {
				stopSessionOnContextDone()
			}
			if session != nil {
				_ = session.Close()
				c.clearCurrentSession(session)
			}
			if ctx.Err() != nil || c.isClosed() {
				return
			}
			retryNow, replacementErr := c.interceptAuthChallenge(ctx, err)
			if retryNow {
				backoff = clientReconnectInitialBackoff
				continue
			}
			if replacementErr != nil {
				err = replacementErr
			}
			if classifyClientSessionError(err) == clientSessionErrorTerminal {
				c.setTerminalError(err)
				return
			}
			cursor = c.nextConnectionCursor(cursor, err, false)
			backoff = applyClientSessionErrorBackoff(err, backoff)
			if c.options.Logger != nil {
				c.options.Logger.DebugContext(ctx, "session with ", remote.address, " over ", remote.remote.Protocol, " failed; retrying in ", backoff, ": ", err)
			}
			if !waitClientReconnectBackoff(ctx, backoff) {
				return
			}
			backoff = min(backoff*2, clientReconnectMaximumBackoff)
			continue
		}
		if c.options.Logger != nil {
			if firstSession {
				c.options.Logger.InfoContext(ctx, "tunnel established to ", remote.address, " over ", remote.remote.Protocol)
			} else {
				c.options.Logger.InfoContext(ctx, "tunnel re-established to ", remote.address, " over ", remote.remote.Protocol)
			}
		}
		firstSession = false
		backoff = clientReconnectInitialBackoff
		c.clearPreviousAuthFailure()
		sessionErr := <-session.Done()
		stopSessionOnContextDone()
		_ = session.Close()
		c.clearCurrentSession(session)
		if ctx.Err() != nil || c.isClosed() {
			return
		}
		if sessionErr == nil {
			return
		}
		retryNow, replacementErr := c.interceptAuthChallenge(ctx, sessionErr)
		if retryNow {
			backoff = clientReconnectInitialBackoff
			continue
		}
		if replacementErr != nil {
			sessionErr = replacementErr
		}
		if classifyClientSessionError(sessionErr) == clientSessionErrorTerminal {
			c.setTerminalError(sessionErr)
			return
		}
		cursor = c.nextConnectionCursor(cursor, sessionErr, true)
		backoff = applyClientSessionErrorBackoff(sessionErr, backoff)
		if c.options.Logger != nil {
			c.options.Logger.DebugContext(ctx, "session with ", remote.address, " over ", remote.remote.Protocol, " ended; retrying in ", backoff, ": ", sessionErr)
		}
		if !waitClientReconnectBackoff(ctx, backoff) {
			return
		}
		backoff = min(backoff*2, clientReconnectMaximumBackoff)
	}
}

func (c *Client) closeSupervisorReadableState() {
	c.lifecycle.access.Lock()
	if !c.lifecycle.closed && c.lifecycle.terminalError == nil {
		c.lifecycle.closed = true
		c.lifecycle.currentSession = nil
		c.stopDataReadsLocked()
	}
	c.lifecycle.access.Unlock()
}

func waitClientReconnectBackoff(ctx context.Context, backoff time.Duration) bool {
	timer := time.NewTimer(backoff)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func applyClientSessionErrorBackoff(err error, backoff time.Duration) time.Duration {
	temporaryError, retryableAuthFailure := E.Cast[*AuthFailedTemporaryError](err)
	if !retryableAuthFailure || temporaryError.BackoffSeconds == 0 {
		return backoff
	}
	serverBackoff := time.Duration(temporaryError.BackoffSeconds) * time.Second
	return max(backoff, serverBackoff)
}

func (c *Client) newClientSession(useActiveAuthToken bool, remote clientRemote) (clientSession, error) {
	c.resetSessionConfiguration(remote)
	if c.mode == ModeStaticKey {
		return newStaticKeyClientSession(c, remote)
	}
	if c.options.Mode == ModeTLS {
		return newTLSClient(c, useActiveAuthToken, remote)
	}
	return nil, ErrUnsupportedMode
}

func (c *Client) resetSessionConfiguration(remote clientRemote) {
	c.tunnel.access.Lock()
	tunnelConfiguration := buildInitialTunnelConfiguration(c.options)
	tunnelConfiguration.ExplicitExitNotify = c.options.Transport.ExplicitExitNotify
	if c.options.Pull.Enabled && strings.HasPrefix(remote.remote.Protocol, "udp") && c.options.Timing.PingRestart == 0 && !c.options.Timing.PingRestartDisabled {
		tunnelConfiguration.PingRestart = prePullInitialPingRestart
	}
	tunnelConfiguration.AuthToken = c.tunnel.authToken
	tunnelConfiguration.AuthTokenUser = c.tunnel.authTokenUser
	c.tunnel.configuration = tunnelConfiguration
	c.tunnel.pulledOptionsReceived = false
	c.tunnel.modernDNSConfigured = false
	c.tunnel.modernSearchDomains = nil
	c.tunnel.deferInitialEvent = false
	c.tunnel.pullFilterRejection = ""
	c.tunnel.compressionPushRejection = ""
	c.dataPlane.framing.Store(newDataChannelFraming(c.dataPlane.compression, c.options.DataChannel.Fragment, c.dataPlane.allowCompressionPolicy))
	c.dataPlane.incomingPacketDropLog.Reset()
	c.dataPlane.outgoingPacketDropLog.Reset()
	c.tunnel.access.Unlock()
}

func (c *Client) setCurrentSession(ctx context.Context, session clientSession) bool {
	c.lifecycle.access.Lock()
	if c.lifecycle.closed || ctx.Err() != nil {
		c.lifecycle.access.Unlock()
		return false
	}
	c.lifecycle.currentSession = session
	c.lifecycle.access.Unlock()
	return true
}

func (c *Client) clearCurrentSession(session clientSession) {
	c.lifecycle.access.Lock()
	if c.lifecycle.currentSession == session {
		c.lifecycle.currentSession = nil
	}
	c.lifecycle.access.Unlock()
}

func (c *Client) setTerminalError(err error) {
	c.lifecycle.access.Lock()
	c.lifecycle.terminalError = err
	c.stopDataReadsLocked()
	c.lifecycle.access.Unlock()
}

func (c *Client) readySession() clientSession {
	c.lifecycle.access.Lock()
	defer c.lifecycle.access.Unlock()
	if c.lifecycle.closed || c.lifecycle.terminalError != nil || c.lifecycle.currentSession == nil || !c.lifecycle.currentSession.Ready() {
		return nil
	}
	return c.lifecycle.currentSession
}

func (c *Client) currentDataReadError() error {
	c.lifecycle.access.Lock()
	defer c.lifecycle.access.Unlock()
	if c.lifecycle.terminalError != nil {
		return c.lifecycle.terminalError
	}
	if c.lifecycle.closed {
		return ErrClientClosed
	}
	return nil
}

func (c *Client) isClosed() bool {
	c.lifecycle.access.Lock()
	defer c.lifecycle.access.Unlock()
	return c.lifecycle.closed
}

func (c *Client) stopDataReadsLocked() {
	if c.lifecycle.dataReadStopped {
		return
	}
	close(c.lifecycle.dataReadDone)
	c.lifecycle.dataReadStopped = true
}

type clientRemote struct {
	remote           Remote
	address          string
	transportNetwork string
	addressIndex     int
}

func resolveClientRemotes(options *ClientOptions) ([]clientRemote, error) {
	if len(options.Transport.Remotes) == 0 {
		return nil, ErrMissingServer
	}
	globalProtocol, _, err := resolveTransportProtocol(options.Transport.Protocol)
	if err != nil {
		return nil, err
	}
	remotes := make([]clientRemote, 0, len(options.Transport.Remotes))
	for remoteIndex, remote := range options.Transport.Remotes {
		if remote.Host == "" || strings.ContainsAny(remote.Host, " \t\r\n") ||
			strings.HasPrefix(remote.Host, "[") || strings.HasSuffix(remote.Host, "]") {
			return nil, E.Extend(ErrOptionNotSupported, "invalid remote host at index ", remoteIndex)
		}
		if remote.Port == 0 {
			return nil, E.Extend(ErrOptionNotSupported, "empty remote port at index ", remoteIndex)
		}
		protocol := remote.Protocol
		if protocol == "" {
			protocol = globalProtocol
		}
		remoteProtocol, transportNetwork, protocolErr := resolveTransportProtocol(protocol)
		if protocolErr != nil {
			return nil, protocolErr
		}
		remote.Protocol = remoteProtocol
		remotes = append(remotes, clientRemote{
			remote: remote, address: net.JoinHostPort(remote.Host, strconv.Itoa(int(remote.Port))), transportNetwork: transportNetwork,
		})
	}
	if options.Transport.RemoteRandom {
		err = secureShuffleClientRemotes(remotes)
		if err != nil {
			return nil, err
		}
	}
	return remotes, nil
}

func secureShuffleClientRemotes(remotes []clientRemote) error {
	for index := len(remotes) - 1; index > 0; index-- {
		randomIndex, err := cryptorand.Int(cryptorand.Reader, big.NewInt(int64(index+1)))
		if err != nil {
			return err
		}
		swapIndex := int(randomIndex.Int64())
		remotes[index], remotes[swapIndex] = remotes[swapIndex], remotes[index]
	}
	return nil
}
