//go:build !aix && !android && !darwin && !dragonfly && !freebsd && !illumos && !ios && !linux && !netbsd && !openbsd && !solaris

package openconnect

import (
	"crypto/x509"
	"net/http"
	"net/netip"
	"net/url"

	E "github.com/sagernet/sing/common/exceptions"
)

func newNCExternalTNCCRunner(
	_ *ncFrontend,
	_ *url.URL,
	_ netip.Addr,
	_ http.CookieJar,
	_ *x509.Certificate,
) (ncTNCCRunner, error) {
	return nil, markTerminal(E.Extend(ErrProtocolNotSupported, "external Network Connect TNCC wrapper is not supported on this platform"))
}
