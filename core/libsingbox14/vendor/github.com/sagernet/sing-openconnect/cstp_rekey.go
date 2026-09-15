package openconnect

import (
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

type cstpRekeyMethod uint8

const (
	cstpRekeyNone cstpRekeyMethod = iota
	cstpRekeyNewTunnel
	cstpRekeyTLS
)

type sessionRekeyError struct {
	method cstpRekeyMethod
}

func (e *sessionRekeyError) Error() string {
	switch e.method {
	case cstpRekeyTLS:
		return "CSTP SSL rekey requires a new tunnel"
	case cstpRekeyNewTunnel:
		return "CSTP new-tunnel rekey due"
	default:
		return "CSTP rekey due"
	}
}

func parseCSTPRekeyMethod(value string) (cstpRekeyMethod, error) {
	switch strings.TrimSpace(value) {
	case "", "none":
		return cstpRekeyNone, nil
	case "new-tunnel":
		return cstpRekeyNewTunnel, nil
	case "ssl":
		return cstpRekeyTLS, nil
	default:
		return cstpRekeyNone, E.Extend(ErrProtocolNotSupported, "unknown negotiated rekey method: ", value)
	}
}
