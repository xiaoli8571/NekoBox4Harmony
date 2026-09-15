package openconnect

import (
	"context"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/net/publicsuffix"
)

type completedAuthentication struct {
	session obtainedSession
	err     error
}

func (a *completedAuthentication) Advance(_ context.Context, _ *authenticationResponse) (obtainedSession, *authenticationRequest, error) {
	if a.err != nil {
		a.session = nil
		return nil, nil, a.err
	}
	session := a.session
	a.session = nil
	return session, nil, nil
}

func (a *completedAuthentication) Done() <-chan error {
	return nil
}

func (a *completedAuthentication) Close() error {
	session := a.session
	a.session = nil
	return closeObtainedSession(session)
}

func newDirectCookieJar(serverURL *url.URL, content string, defaultName string) (http.CookieJar, map[string]string, error) {
	jar, err := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	if err != nil {
		return nil, nil, E.Cause(err, "create direct authentication cookie jar")
	}
	values := make(map[string]string)
	for rawCookie := range strings.SplitSeq(content, ";") {
		rawCookie = strings.TrimSpace(rawCookie)
		if rawCookie == "" {
			continue
		}
		name, value, hasName := strings.Cut(rawCookie, "=")
		if !hasName {
			if defaultName == "" {
				return nil, nil, E.New("direct authentication cookie has no name: ", rawCookie)
			}
			name = defaultName
			value = rawCookie
		}
		name = strings.TrimSpace(name)
		if name == "" {
			return nil, nil, E.New("direct authentication cookie has an empty name")
		}
		values[name] = value
	}
	if len(values) == 0 {
		return nil, nil, E.New("direct authentication cookie is empty")
	}
	cookies := make([]*http.Cookie, 0, len(values))
	for name, value := range values {
		cookies = append(cookies, &http.Cookie{Name: name, Value: value, Path: "/", Secure: true})
	}
	jar.SetCookies(serverURL, cookies)
	return jar, values, nil
}
