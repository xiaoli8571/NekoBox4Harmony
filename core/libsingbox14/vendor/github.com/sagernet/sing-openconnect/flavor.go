package openconnect

import (
	"context"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	FlavorAnyConnect = "anyconnect"
	FlavorGP         = "gp"
	FlavorFortinet   = "fortinet"
	FlavorF5         = "f5"
	FlavorPulse      = "pulse"
	FlavorNC         = "nc"
)

type obtainedSession interface {
	Close() error
}

type flavorFrontend interface {
	BeginAuthentication() authContinuation
	ConnectTunnel(ctx context.Context, session obtainedSession) (clientSession, error)
}

type authContinuation interface {
	Advance(ctx context.Context, response *authenticationResponse) (obtainedSession, *authenticationRequest, error)
	Done() <-chan error
	Close() error
}

type flavorFrontendFactory func(client *Client) (flavorFrontend, error)

var flavorFrontendFactories = make(map[string]flavorFrontendFactory)

func registerFlavorFrontend(flavor string, factory flavorFrontendFactory) {
	flavorFrontendFactories[flavor] = factory
}

func newFlavorFrontend(flavor string, client *Client) (flavorFrontend, error) {
	factory := flavorFrontendFactories[flavor]
	if factory == nil {
		return nil, E.Extend(ErrUnsupportedFlavor, flavor)
	}
	return factory(client)
}
