package transport

import (
	"errors"
	"strings"

	"github.com/sagernet/quic-go"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	ProtocolQUIC         = "quic"
	ProtocolHTTP2        = "http2"
	ProtocolH2MUX        = "h2mux"
	DefaultProtocolRetry = 5
)

type ProtocolSelector interface {
	Current() string
	Fallback() (string, bool)
}

type staticProtocolSelector struct {
	current     string
	fallback    string
	hasFallback bool
}

func (s staticProtocolSelector) Current() string {
	return s.current
}

func (s staticProtocolSelector) Fallback() (string, bool) {
	if !s.hasFallback {
		return "", false
	}
	return s.fallback, true
}

func NewProtocolSelector(protocol string, postQuantum bool) (ProtocolSelector, error) {
	switch protocol {
	case "", ProtocolQUIC:
		if postQuantum {
			return staticProtocolSelector{current: ProtocolQUIC}, nil
		}
	case ProtocolHTTP2:
		if postQuantum {
			return nil, E.New("post-quantum is only supported with quic transport")
		}
	default:
		return nil, E.New("unsupported protocol: ", protocol, ", expected auto, quic, http2 or h2mux")
	}

	switch protocol {
	case "":
		return staticProtocolSelector{
			current:     ProtocolQUIC,
			fallback:    ProtocolHTTP2,
			hasFallback: true,
		}, nil
	case ProtocolQUIC:
		return staticProtocolSelector{current: ProtocolQUIC}, nil
	case ProtocolHTTP2:
		return staticProtocolSelector{current: ProtocolHTTP2}, nil
	default:
		return nil, E.New("unsupported protocol: ", protocol, ", expected auto, quic, http2 or h2mux")
	}
}

func NormalizeProtocol(protocol string) (string, error) {
	switch protocol {
	case "", "auto":
		return "", nil
	case ProtocolQUIC, ProtocolHTTP2:
		return protocol, nil
	case ProtocolH2MUX:
		return ProtocolHTTP2, nil
	default:
		return "", E.New("unsupported protocol: ", protocol, ", expected auto, quic, http2 or h2mux")
	}
}

func IsQUICBroken(err error) bool {
	var idleTimeoutError *quic.IdleTimeoutError
	if errors.As(err, &idleTimeoutError) {
		return true
	}

	var transportError *quic.TransportError
	if errors.As(err, &transportError) && strings.Contains(err.Error(), "operation not permitted") {
		return true
	}

	return false
}
