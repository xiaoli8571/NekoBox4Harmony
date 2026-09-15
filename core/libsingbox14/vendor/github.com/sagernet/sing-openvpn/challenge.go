package openvpn

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"strings"
	"time"
)

type ChallengeKind string

const (
	ChallengeCredentials ChallengeKind = "credentials"
	ChallengeSecret      ChallengeKind = "secret"
	ChallengeMessage     ChallengeKind = "message"
	ChallengeOpenURL     ChallengeKind = "open-url"
)

type Challenge struct {
	ID            string
	Kind          ChallengeKind
	Username      string
	Message       string
	URL           string
	SecretMessage string
	Echo          bool
	PreviousError string
	Deadline      time.Time
}

type ChallengeResponse struct {
	Username string
	Password string
	Secret   string
}

type pendingChallengeState struct {
	challenge Challenge
	owner     any
	complete  func(response ChallengeResponse) error
	cancel    func()
}

type challengeResponseCompletion struct {
	response     ChallengeResponse
	acknowledged chan struct{}
}

func newChallengeID() string {
	identifier := make([]byte, 8)
	_, _ = rand.Read(identifier)
	return hex.EncodeToString(identifier)
}

func (c *Client) PendingChallenge() *Challenge {
	c.authentication.access.Lock()
	defer c.authentication.access.Unlock()
	if c.authentication.pendingChallenge == nil {
		return nil
	}
	challenge := c.authentication.pendingChallenge.challenge
	return &challenge
}

func (c *Client) ChallengeUpdated() <-chan struct{} {
	c.authentication.access.Lock()
	defer c.authentication.access.Unlock()
	return c.authentication.updated
}

func (c *Client) CompleteChallenge(challengeID string, response ChallengeResponse) error {
	c.authentication.access.Lock()
	pending := c.authentication.pendingChallenge
	if pending == nil || pending.challenge.ID != challengeID {
		c.authentication.access.Unlock()
		return ErrNoPendingChallenge
	}
	if pending.complete == nil {
		c.authentication.access.Unlock()
		return ErrChallengeNotAnswerable
	}
	c.authentication.pendingChallenge = nil
	c.signalChallengeUpdatedLocked()
	c.authentication.access.Unlock()
	return pending.complete(response)
}

func (c *Client) CancelChallenge(challengeID string) error {
	c.authentication.access.Lock()
	pending := c.authentication.pendingChallenge
	if pending == nil || pending.challenge.ID != challengeID {
		c.authentication.access.Unlock()
		return ErrNoPendingChallenge
	}
	c.authentication.pendingChallenge = nil
	c.signalChallengeUpdatedLocked()
	c.authentication.access.Unlock()
	pending.cancel()
	return nil
}

func (c *Client) publishChallenge(state *pendingChallengeState) {
	c.authentication.access.Lock()
	if c.authentication.closed {
		c.authentication.access.Unlock()
		return
	}
	if state.challenge.PreviousError == "" {
		state.challenge.PreviousError = c.authentication.previousAuthenticationError
	}
	c.authentication.previousAuthenticationError = ""
	c.authentication.pendingChallenge = state
	c.signalChallengeUpdatedLocked()
	c.authentication.access.Unlock()
}

func (c *Client) clearChallengeOwnedBy(owner any) {
	c.authentication.access.Lock()
	if c.authentication.pendingChallenge != nil && c.authentication.pendingChallenge.owner == owner {
		c.authentication.pendingChallenge = nil
		c.signalChallengeUpdatedLocked()
	}
	c.authentication.access.Unlock()
}

func (c *Client) updateChallengeDeadline(owner any, deadline time.Time) {
	c.authentication.access.Lock()
	if c.authentication.pendingChallenge != nil && c.authentication.pendingChallenge.owner == owner && !c.authentication.pendingChallenge.challenge.Deadline.Equal(deadline) {
		c.authentication.pendingChallenge.challenge.Deadline = deadline
		c.signalChallengeUpdatedLocked()
	}
	c.authentication.access.Unlock()
}

func (c *Client) noteChallengeResponseSubmitted() {
	c.authentication.access.Lock()
	c.authentication.sentInteractiveCredentials = true
	c.authentication.access.Unlock()
}

func (c *Client) notePreviousAuthFailure(reason string) {
	c.authentication.access.Lock()
	c.authentication.previousAuthenticationError = reason
	c.authentication.access.Unlock()
}

func (c *Client) clearPreviousAuthFailure() {
	c.authentication.access.Lock()
	c.authentication.previousAuthenticationError = ""
	c.authentication.access.Unlock()
}

func (c *Client) signalChallengeUpdatedLocked() {
	if c.authentication.closed {
		select {
		case <-c.authentication.updated:
		default:
			close(c.authentication.updated)
		}
		return
	}
	close(c.authentication.updated)
	c.authentication.updated = make(chan struct{})
}

func (c *Client) awaitChallengeResponse(ctx context.Context, challenge Challenge) (ChallengeResponse, error) {
	responseChannel := make(chan challengeResponseCompletion)
	cancelChannel := make(chan struct{})
	challenge.ID = newChallengeID()
	c.publishChallenge(&pendingChallengeState{
		challenge: challenge,
		owner:     c,
		complete: func(response ChallengeResponse) error {
			completion := challengeResponseCompletion{
				response:     response,
				acknowledged: make(chan struct{}),
			}
			select {
			case responseChannel <- completion:
				<-completion.acknowledged
				return nil
			case <-ctx.Done():
				return ErrChallengeCanceled
			}
		},
		cancel: func() {
			close(cancelChannel)
		},
	})
	select {
	case <-ctx.Done():
		c.clearChallengeOwnedBy(c)
		return ChallengeResponse{}, ctx.Err()
	case <-cancelChannel:
		return ChallengeResponse{}, ErrChallengeCanceled
	case completion := <-responseChannel:
		close(completion.acknowledged)
		return completion.response, nil
	}
}

// Upstream doc/management-notes.txt defines the INFO_PRE payloads sent during
// AUTH_PENDING: "OPEN_URL:<url>", "WEB_AUTH:<flags>:<url>" whose
// comma-separated flags (proxy, hidden, external) only tune webview embedding
// and are ignored here because the URL is always opened externally, and
// "CR_TEXT:<flags>:<text>" with flags E (echo the response) and R (a response
// is required).
func parseServerPushedChallenge(payload string) (Challenge, bool) {
	switch {
	case strings.HasPrefix(payload, "OPEN_URL:"):
		return Challenge{
			Kind: ChallengeOpenURL,
			URL:  strings.TrimPrefix(payload, "OPEN_URL:"),
		}, true
	case strings.HasPrefix(payload, "WEB_AUTH:"):
		_, url, hasURL := strings.Cut(strings.TrimPrefix(payload, "WEB_AUTH:"), ":")
		if !hasURL {
			return Challenge{}, false
		}
		return Challenge{
			Kind: ChallengeOpenURL,
			URL:  url,
		}, true
	case strings.HasPrefix(payload, "CR_TEXT:"):
		flagBag, text, hasText := strings.Cut(strings.TrimPrefix(payload, "CR_TEXT:"), ":")
		if !hasText {
			return Challenge{}, false
		}
		kind := ChallengeMessage
		if challengeFlagsContain(flagBag, "R") {
			kind = ChallengeSecret
		}
		return Challenge{
			Kind:    kind,
			Message: text,
			Echo:    challengeFlagsContain(flagBag, "E"),
		}, true
	default:
		return Challenge{}, false
	}
}

func challengeFlagsContain(flagBag string, flag string) bool {
	for flagEntry := range strings.SplitSeq(flagBag, ",") {
		if strings.TrimSpace(flagEntry) == flag {
			return true
		}
	}
	return false
}
