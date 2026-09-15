package openconnect

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"

	"golang.org/x/net/publicsuffix"
)

func parseServerURL(server string) (*url.URL, error) {
	if !strings.Contains(server, "://") {
		server = "https://" + server
	}
	serverURL, err := url.Parse(server)
	if err != nil {
		return nil, E.Cause(err, "parse openconnect server")
	}
	if serverURL.Scheme != "https" || serverURL.Hostname() == "" {
		return nil, E.New("server must be an HTTPS host")
	}
	if serverURL.User != nil {
		return nil, E.New("server must not contain URL user information")
	}
	if serverURL.RawQuery != "" || serverURL.Fragment != "" {
		return nil, E.New("server must not contain a query or fragment")
	}
	return serverURL, nil
}

func newHTTPClient(client *Client, tlsConfig *tls.Config) (*http.Client, *http.Transport, error) {
	jar, err := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	if err != nil {
		return nil, nil, E.Cause(err, "create openconnect cookie jar")
	}
	transportTLSConfig := tlsConfig.Clone()
	transportTLSConfig.NextProtos = []string{"http/1.1"}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network string, address string) (net.Conn, error) {
			return client.options.Dialer.DialContext(ctx, network, M.ParseSocksaddr(address))
		},
		ForceAttemptHTTP2: false,
		TLSClientConfig:   transportTLSConfig,
		DisableKeepAlives: client.options.HTTPKeepAliveDisabled,
	}
	return &http.Client{
		Transport: client.wrapHTTPTransport(transport),
		Jar:       jar,
		CheckRedirect: func(request *http.Request, previousRequests []*http.Request) error {
			if len(previousRequests) >= 10 {
				return E.New("HTTP redirect limit exceeded")
			}
			return validateHTTPSRequestURL(request.URL)
		},
	}, transport, nil
}

func validateHTTPSRequestURL(requestURL *url.URL) error {
	if requestURL == nil || requestURL.Scheme != "https" || requestURL.Hostname() == "" {
		return E.New("request URL must be an HTTPS host")
	}
	if requestURL.User != nil {
		return E.New("request URL must not contain user information")
	}
	return nil
}
