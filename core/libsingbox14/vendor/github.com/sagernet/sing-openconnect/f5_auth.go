package openconnect

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptrace"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/net/publicsuffix"
)

const (
	f5MaximumAuthenticationBody      = 16 * 1024 * 1024
	f5MaximumAuthenticationRequests  = 64
	f5MaximumAuthenticationRedirects = 10
	f5LogoutTimeout                  = 5 * time.Second
	f5DefaultUserAgent               = "AnyConnect-compatible OpenConnect VPN Agent " + defaultClientVersion
)

type f5Frontend struct {
	client        *Client
	localHostname string
}

type f5Authentication struct {
	access              sync.Mutex
	frontend            *f5Frontend
	initializationErr   error
	httpClient          *http.Client
	jar                 http.CookieJar
	currentURL          *url.URL
	currentAddress      netip.Addr
	currentForm         *f5AuthenticationForm
	tokenGenerator      *softwareTokenGenerator
	requests            int
	formNumber          int
	seenHTMLForm        bool
	primaryPasswordSeen bool
	primaryPasswordSent bool
	currentFormPrimary  bool
	started             bool
	completed           bool
	closed              bool
	advancing           bool
}

type f5HTTPResponse struct {
	statusCode int
	header     http.Header
	body       []byte
	requestURL *url.URL
	address    netip.Addr
}

type f5SessionState struct {
	access                   sync.RWMutex
	frontend                 *f5Frontend
	serverURL                *url.URL
	acceptedAddress          netip.Addr
	jar                      http.CookieJar
	mrhSession               string
	f5ST                     string
	authenticationExpiration time.Time
	previousIPv4             netip.Prefix
	previousIPv6             netip.Prefix
	hasPreviousAddresses     bool
	skipInitialDTLS          bool
	configurationOnce        sync.Once
	configuration            *f5TunnelConfiguration
	configurationErr         error
	activeSession            *pppSession
	closeOnce                sync.Once
	closeErr                 error
}

type f5SessionSnapshot struct {
	serverURL                *url.URL
	acceptedAddress          netip.Addr
	jar                      http.CookieJar
	mrhSession               string
	f5ST                     string
	authenticationExpiration time.Time
	previousIPv4             netip.Prefix
	previousIPv6             netip.Prefix
	hasPreviousAddresses     bool
	skipInitialDTLS          bool
}

func (f *f5Frontend) BeginAuthentication() authContinuation {
	f.client.httpTransport.CloseIdleConnections()
	serverURL := cloneF5URL(f.client.serverURL)
	directCookie := f.client.takeDirectCookie()
	if directCookie != "" {
		jar, values, directErr := newDirectCookieJar(serverURL, directCookie, "MRHSession")
		mrhSession := values["MRHSession"]
		if directErr == nil && mrhSession == "" {
			directErr = E.New("direct cookie does not contain MRHSession")
		}
		f5ST := values["F5_ST"]
		return &completedAuthentication{
			session: &f5SessionState{
				frontend:                 f,
				serverURL:                serverURL,
				jar:                      jar,
				mrhSession:               mrhSession,
				f5ST:                     f5ST,
				authenticationExpiration: parseF5AuthenticationExpiration(f5ST),
			},
			err: directErr,
		}
	}
	jar, initializationErr := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	authenticationClient := &http.Client{
		Transport: f.client.wrapHTTPTransport(f.client.httpTransport),
		Jar:       jar,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return &f5Authentication{
		frontend:          f,
		initializationErr: initializationErr,
		httpClient:        authenticationClient,
		jar:               jar,
		currentURL:        serverURL,
		tokenGenerator:    newSoftwareTokenGenerator(f.client.options.Token),
	}
}

func (a *f5Authentication) Done() <-chan error {
	return nil
}

func (a *f5Authentication) Close() error {
	a.access.Lock()
	if a.closed {
		a.access.Unlock()
		return nil
	}
	a.closed = true
	if !a.completed {
		a.jar = nil
		a.httpClient.Jar = nil
	}
	if a.currentForm != nil {
		for fieldIndex := range a.currentForm.fields {
			a.currentForm.fields[fieldIndex].value = ""
		}
	}
	a.currentForm = nil
	a.access.Unlock()
	return nil
}

func (a *f5Authentication) Advance(
	ctx context.Context,
	response *authenticationResponse,
) (obtainedSession, *authenticationRequest, error) {
	a.access.Lock()
	if a.closed {
		a.access.Unlock()
		return nil, nil, ErrAuthChallengeCanceled
	}
	if a.initializationErr != nil {
		initializationErr := a.initializationErr
		a.access.Unlock()
		return nil, nil, initializationErr
	}
	if a.completed {
		a.access.Unlock()
		return nil, nil, E.Extend(ErrProtocolNotSupported, "authentication continuation is already complete")
	}
	if a.advancing {
		a.access.Unlock()
		return nil, nil, E.Extend(ErrProtocolNotSupported, "authentication continuation is already advancing")
	}
	a.advancing = true
	started := a.started
	currentForm := a.currentForm
	currentFormPrimary := a.currentFormPrimary
	if !started {
		a.started = true
	}
	a.access.Unlock()
	defer func() {
		a.access.Lock()
		a.advancing = false
		a.access.Unlock()
	}()
	if !started {
		if response != nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "unexpected form response before F5 authentication")
		}
		return a.doAuthenticationExchange(ctx, http.MethodGet, a.currentURL, "")
	}
	if response == nil || currentForm == nil {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "missing F5 authentication form response")
	}
	encodedForm, encodeErr := encodeF5AuthenticationResponse(currentForm, response)
	if encodeErr != nil {
		return nil, nil, encodeErr
	}
	requestURL := cloneF5URL(a.currentURL)
	if currentForm.action != "" {
		resolvedURL, resolveErr := requestURL.Parse(currentForm.action)
		if resolveErr != nil {
			return nil, nil, markTerminal(E.Cause(resolveErr, "resolve F5 authentication form action"))
		}
		validationErr := validateHTTPSRequestURL(resolvedURL)
		if validationErr != nil {
			return nil, nil, markTerminal(validationErr)
		}
		requestURL = resolvedURL
	}
	if !equalF5Endpoint(a.currentURL, requestURL) {
		resetErr := a.resetAuthenticationJar()
		if resetErr != nil {
			return nil, nil, markTerminal(resetErr)
		}
		a.frontend.client.httpTransport.CloseIdleConnections()
		a.access.Lock()
		a.currentAddress = netip.Addr{}
		a.access.Unlock()
	}
	a.access.Lock()
	if currentFormPrimary {
		a.primaryPasswordSent = true
	}
	for fieldIndex := range currentForm.fields {
		if currentForm.fields[fieldIndex].kind == AuthFormFieldPassword {
			currentForm.fields[fieldIndex].value = ""
		}
	}
	a.access.Unlock()
	return a.doAuthenticationExchange(ctx, http.MethodPost, requestURL, encodedForm)
}

func (a *f5Authentication) doAuthenticationExchange(
	ctx context.Context,
	method string,
	requestURL *url.URL,
	encodedForm string,
) (obtainedSession, *authenticationRequest, error) {
	currentMethod := method
	currentURL := cloneF5URL(requestURL)
	currentBody := encodedForm
	for redirectNumber := 0; ; redirectNumber++ {
		if redirectNumber > f5MaximumAuthenticationRedirects {
			return nil, nil, markTerminal(E.New("authentication exceeded ", f5MaximumAuthenticationRedirects, " redirects"))
		}
		httpResponse, requestErr := a.doAuthenticationRequest(ctx, currentMethod, currentURL, currentBody)
		if requestErr != nil {
			return nil, nil, requestErr
		}
		a.access.Lock()
		a.currentURL = cloneF5URL(httpResponse.requestURL)
		if httpResponse.address.IsValid() {
			a.currentAddress = httpResponse.address
		}
		a.access.Unlock()
		state, cookieErr := a.sessionFromCookies(httpResponse.requestURL)
		if cookieErr != nil {
			return nil, nil, cookieErr
		}
		if state != nil {
			a.access.Lock()
			a.completed = true
			a.currentForm = nil
			a.access.Unlock()
			return state, nil, nil
		}
		locationHeader := httpResponse.header.Get("Location")
		if isF5RedirectStatus(httpResponse.statusCode) && locationHeader != "" {
			location, locationErr := httpResponse.requestURL.Parse(locationHeader)
			if locationErr != nil {
				return nil, nil, markTerminal(E.Cause(locationErr, "parse F5 authentication redirect"))
			}
			validationErr := validateHTTPSRequestURL(location)
			if validationErr != nil {
				return nil, nil, markTerminal(validationErr)
			}
			if !equalF5Endpoint(httpResponse.requestURL, location) {
				resetErr := a.resetAuthenticationJar()
				if resetErr != nil {
					return nil, nil, markTerminal(resetErr)
				}
				a.frontend.client.httpTransport.CloseIdleConnections()
				a.access.Lock()
				a.currentAddress = netip.Addr{}
				a.access.Unlock()
			}
			currentMethod = http.MethodGet
			currentURL = location
			currentBody = ""
			continue
		}
		if httpResponse.statusCode < http.StatusOK || httpResponse.statusCode >= http.StatusMultipleChoices {
			return nil, nil, markTerminal(E.New(
				"authentication returned unexpected HTTP status ",
				httpResponse.statusCode,
				" ",
				http.StatusText(httpResponse.statusCode),
			))
		}
		return a.authenticationRequestFromDocument(httpResponse.body)
	}
}

func (a *f5Authentication) doAuthenticationRequest(
	ctx context.Context,
	method string,
	requestURL *url.URL,
	encodedForm string,
) (f5HTTPResponse, error) {
	a.access.Lock()
	a.requests++
	requestNumber := a.requests
	a.access.Unlock()
	if requestNumber > f5MaximumAuthenticationRequests {
		return f5HTTPResponse{}, markTerminal(E.New("authentication exceeded ", f5MaximumAuthenticationRequests, " wire requests"))
	}
	var body io.Reader
	if method == http.MethodPost {
		body = bytes.NewBufferString(encodedForm)
	}
	request, requestErr := http.NewRequestWithContext(ctx, method, requestURL.String(), body)
	if requestErr != nil {
		return f5HTTPResponse{}, markTerminal(E.Cause(requestErr, "create F5 authentication request"))
	}
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", f5UserAgent(a.frontend.client))
	if method == http.MethodPost {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	var acceptedAddress netip.Addr
	trace := &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			acceptedAddress = parseF5RemoteAddress(info.Conn.RemoteAddr())
		},
	}
	request = request.WithContext(httptrace.WithClientTrace(request.Context(), trace))
	response, responseErr := a.httpClient.Do(request)
	if responseErr != nil {
		requestFailure := E.Cause(responseErr, "send F5 authentication request")
		if response != nil && response.Body != nil {
			closeErr := response.Body.Close()
			if closeErr != nil {
				requestFailure = E.Errors(requestFailure, E.Cause(closeErr, "close failed F5 authentication response"))
			}
		}
		return f5HTTPResponse{}, requestFailure
	}
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, f5MaximumAuthenticationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		responseFailure := E.Cause(readErr, "read F5 authentication response")
		if closeErr != nil {
			responseFailure = E.Errors(responseFailure, E.Cause(closeErr, "close failed F5 authentication response"))
		}
		return f5HTTPResponse{}, responseFailure
	}
	if closeErr != nil {
		return f5HTTPResponse{}, E.Cause(closeErr, "close F5 authentication response")
	}
	if len(responseBody) > f5MaximumAuthenticationBody {
		return f5HTTPResponse{}, markTerminal(E.New("authentication response exceeds ", f5MaximumAuthenticationBody, " bytes"))
	}
	return f5HTTPResponse{
		statusCode: response.StatusCode,
		header:     response.Header.Clone(),
		body:       responseBody,
		requestURL: cloneF5URL(request.URL),
		address:    acceptedAddress,
	}, nil
}

func (a *f5Authentication) authenticationRequestFromDocument(
	content []byte,
) (obtainedSession, *authenticationRequest, error) {
	form, warnings, parseErr := parseF5AuthenticationDocument(content)
	if parseErr != nil {
		return nil, nil, markTerminal(parseErr)
	}
	for _, warning := range warnings {
		if a.frontend.client.options.Logger != nil {
			a.frontend.client.options.Logger.WarnContext(a.frontend.client.options.Context, warning)
		}
	}
	a.access.Lock()
	formNumber := a.formNumber
	if form != nil && form.html && !a.seenHTMLForm {
		a.seenHTMLForm = true
		if form.id != "auth_form" {
			a.access.Unlock()
			return nil, nil, markTerminal(E.New("unexpected first F5 HTML form ID: ", form.id))
		}
	}
	if form == nil && formNumber == 0 {
		form = staticF5AuthenticationForm()
	}
	if form == nil {
		a.access.Unlock()
		return nil, nil, markTerminal(E.New("authentication response has no usable form"))
	}
	repeatedPrimary := a.primaryPasswordSent && isF5PrimaryAuthenticationForm(form)
	firstPrimaryPassword := !a.primaryPasswordSeen && f5FormHasPassword(form)
	stablePrimaryPassword := firstPrimaryPassword || repeatedPrimary
	request := a.buildAuthenticationRequestLocked(form, formNumber == 0 || stablePrimaryPassword, stablePrimaryPassword, repeatedPrimary)
	a.currentForm = form
	a.currentFormPrimary = stablePrimaryPassword
	if firstPrimaryPassword {
		a.primaryPasswordSeen = true
	}
	a.formNumber++
	a.access.Unlock()
	return nil, request, nil
}

func (a *f5Authentication) buildAuthenticationRequestLocked(
	form *f5AuthenticationForm,
	stableUsername bool,
	stablePrimaryPassword bool,
	repeatedPrimary bool,
) *authenticationRequest {
	request := &authenticationRequest{
		FormID:  form.id,
		Banner:  form.banner,
		Message: form.message,
	}
	if repeatedPrimary {
		request.Error = "gateway rejected the primary credentials"
		request.ClearCacheKeys = []string{authCachePassword}
	}
	primaryPasswordAssigned := false
	for fieldIndex := range form.fields {
		field := &form.fields[fieldIndex]
		requestField := authenticationRequestField{
			SubmissionKey: field.submissionKey,
			Name:          field.name,
			Label:         field.label,
			Kind:          field.kind,
			Value:         field.value,
			Options:       append([]AuthFormChoice(nil), field.options...),
		}
		if stableUsername && field.kind == AuthFormFieldText && field.name == "username" {
			requestField.CacheKey = authCacheUsername
		}
		if stablePrimaryPassword && field.kind == AuthFormFieldPassword && !primaryPasswordAssigned {
			requestField.CacheKey = authCachePassword
			primaryPasswordAssigned = true
		} else if field.kind == AuthFormFieldPassword && a.tokenGenerator.CanGenerate(form.message) {
			requestField.Kind = authFormFieldToken
			tokenMessage := form.message
			requestField.Automatic = func(ctx context.Context) (string, error) {
				return a.tokenGenerator.Generate(ctx, tokenMessage)
			}
		}
		if field.kind == AuthFormFieldSelect && field.name == "domain" {
			requestField.CacheKey = authCacheAuthGroup
			a.normalizeConfiguredDomainLocked(&requestField)
		}
		request.Fields = append(request.Fields, requestField)
	}
	return request
}

func (a *f5Authentication) normalizeConfiguredDomainLocked(field *authenticationRequestField) {
	a.frontend.client.authChallengeAccess.Lock()
	configuredDomain := a.frontend.client.stableCredentials[authCacheAuthGroup]
	a.frontend.client.authChallengeAccess.Unlock()
	if configuredDomain == "" {
		return
	}
	for _, choice := range field.Options {
		if configuredDomain == choice.Value || configuredDomain == choice.Label {
			a.frontend.client.storeStableCredential(authCacheAuthGroup, choice.Value)
			return
		}
	}
	a.frontend.client.clearStableCredentials(authCacheAuthGroup)
}

func (a *f5Authentication) sessionFromCookies(requestURL *url.URL) (*f5SessionState, error) {
	a.access.Lock()
	jar := a.jar
	acceptedAddress := a.currentAddress
	a.access.Unlock()
	if jar == nil {
		return nil, nil
	}
	var mrhSession string
	var f5ST string
	for _, cookie := range jar.Cookies(requestURL) {
		switch cookie.Name {
		case "MRHSession":
			mrhSession = cookie.Value
		case "F5_ST":
			f5ST = cookie.Value
		}
	}
	if mrhSession == "" || f5ST == "" {
		return nil, nil
	}
	if !acceptedAddress.IsValid() {
		return nil, markTerminal(E.New("authenticated endpoint has no accepted peer address"))
	}
	return &f5SessionState{
		frontend:                 a.frontend,
		serverURL:                cloneF5URL(requestURL),
		acceptedAddress:          acceptedAddress,
		jar:                      jar,
		mrhSession:               mrhSession,
		f5ST:                     f5ST,
		authenticationExpiration: parseF5AuthenticationExpiration(f5ST),
	}, nil
}

func (a *f5Authentication) resetAuthenticationJar() error {
	jar, jarErr := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	if jarErr != nil {
		return E.Cause(jarErr, "create F5 authentication cookie jar")
	}
	a.access.Lock()
	a.jar = jar
	a.httpClient.Jar = jar
	a.access.Unlock()
	return nil
}

func encodeF5AuthenticationResponse(form *f5AuthenticationForm, response *authenticationResponse) (string, error) {
	var encoded strings.Builder
	for fieldIndex, field := range form.fields {
		value, loaded := response.Values[field.submissionKey]
		if !loaded {
			return "", E.Extend(ErrProtocolNotSupported, "authentication response omitted field ", field.name)
		}
		if fieldIndex > 0 {
			encoded.WriteByte('&')
		}
		encoded.WriteString(url.QueryEscape(field.name))
		encoded.WriteByte('=')
		encoded.WriteString(url.QueryEscape(value))
	}
	return encoded.String(), nil
}

func staticF5AuthenticationForm() *f5AuthenticationForm {
	formID := "auth_form"
	return &f5AuthenticationForm{
		id: formID,
		fields: []f5AuthenticationField{
			{
				submissionKey: f5SubmissionKey(formID, 0),
				name:          "username",
				label:         "username:",
				kind:          AuthFormFieldText,
			},
			{
				submissionKey: f5SubmissionKey(formID, 1),
				name:          "password",
				label:         "password:",
				kind:          AuthFormFieldPassword,
			},
		},
	}
}

func isF5PrimaryAuthenticationForm(form *f5AuthenticationForm) bool {
	username := false
	password := false
	for _, field := range form.fields {
		if field.name == "username" && field.kind == AuthFormFieldText {
			username = true
		}
		if field.name == "password" && field.kind == AuthFormFieldPassword {
			password = true
		}
	}
	return username && password
}

func f5FormHasPassword(form *f5AuthenticationForm) bool {
	for _, field := range form.fields {
		if field.kind == AuthFormFieldPassword {
			return true
		}
	}
	return false
}

func parseF5AuthenticationExpiration(value string) time.Time {
	parts := strings.Split(value, "z")
	if len(parts) < 5 {
		return time.Time{}
	}
	start, startErr := strconv.ParseInt(parts[3], 10, 64)
	duration, durationErr := strconv.ParseInt(parts[4], 10, 64)
	if startErr != nil || durationErr != nil || start <= 0 || duration <= 0 || start > 1<<62-duration {
		return time.Time{}
	}
	return time.Unix(start+duration, 0)
}

func isF5RedirectStatus(statusCode int) bool {
	switch statusCode {
	case http.StatusMovedPermanently,
		http.StatusFound,
		http.StatusSeeOther,
		http.StatusTemporaryRedirect,
		http.StatusPermanentRedirect:
		return true
	default:
		return false
	}
}

func equalF5Endpoint(left *url.URL, right *url.URL) bool {
	if left == nil || right == nil || !strings.EqualFold(left.Scheme, right.Scheme) || !strings.EqualFold(left.Hostname(), right.Hostname()) {
		return false
	}
	leftPort, leftErr := f5URLPort(left)
	rightPort, rightErr := f5URLPort(right)
	return leftErr == nil && rightErr == nil && leftPort == rightPort
}

func f5URLPort(serverURL *url.URL) (uint16, error) {
	if serverURL == nil {
		return 0, E.New("endpoint URL is empty")
	}
	portText := serverURL.Port()
	if portText == "" {
		if strings.EqualFold(serverURL.Scheme, "https") {
			return 443, nil
		}
		return 0, E.New("endpoint has no port")
	}
	port, parseErr := strconv.ParseUint(portText, 10, 16)
	if parseErr != nil || port == 0 {
		return 0, E.New("endpoint has an invalid port: ", portText)
	}
	return uint16(port), nil
}

func parseF5RemoteAddress(address net.Addr) netip.Addr {
	if address == nil {
		return netip.Addr{}
	}
	switch typedAddress := address.(type) {
	case *net.TCPAddr:
		parsed, _ := netip.AddrFromSlice(typedAddress.IP)
		return parsed.Unmap()
	case *net.UDPAddr:
		parsed, _ := netip.AddrFromSlice(typedAddress.IP)
		return parsed.Unmap()
	}
	host, _, splitErr := net.SplitHostPort(address.String())
	if splitErr != nil {
		return netip.Addr{}
	}
	parsed, parseErr := netip.ParseAddr(host)
	if parseErr != nil {
		return netip.Addr{}
	}
	return parsed.Unmap()
}

func f5UserAgent(client *Client) string {
	if client.options.UserAgent != "" {
		return client.options.UserAgent
	}
	return f5DefaultUserAgent
}

func cloneF5URL(serverURL *url.URL) *url.URL {
	if serverURL == nil {
		return nil
	}
	cloned := *serverURL
	return &cloned
}

func (s *f5SessionState) snapshot() f5SessionSnapshot {
	s.access.RLock()
	defer s.access.RUnlock()
	return f5SessionSnapshot{
		serverURL:                cloneF5URL(s.serverURL),
		acceptedAddress:          s.acceptedAddress,
		jar:                      s.jar,
		mrhSession:               s.mrhSession,
		f5ST:                     s.f5ST,
		authenticationExpiration: s.authenticationExpiration,
		previousIPv4:             s.previousIPv4,
		previousIPv6:             s.previousIPv6,
		hasPreviousAddresses:     s.hasPreviousAddresses,
		skipInitialDTLS:          s.skipInitialDTLS,
	}
}

func (s *f5SessionState) attachSession(session *pppSession) error {
	s.access.Lock()
	defer s.access.Unlock()
	if s.mrhSession == "" || s.jar == nil {
		return ErrSessionRejected
	}
	if s.activeSession != nil && s.activeSession != session {
		return E.New("obtained session already owns an active tunnel")
	}
	s.activeSession = session
	return nil
}

func (s *f5SessionState) detachSession(session *pppSession) {
	s.access.Lock()
	if s.activeSession == session {
		s.activeSession = nil
	}
	s.access.Unlock()
}

func (s *f5SessionState) Close() error {
	s.closeOnce.Do(func() {
		s.access.RLock()
		activeSession := s.activeSession
		s.access.RUnlock()
		if activeSession != nil {
			s.closeErr = activeSession.Close()
		}
		snapshot := s.snapshot()
		if snapshot.serverURL != nil && snapshot.acceptedAddress.IsValid() && snapshot.jar != nil && snapshot.mrhSession != "" {
			logoutContext, cancelLogout := context.WithTimeout(context.Background(), f5LogoutTimeout)
			logoutErr := s.frontend.logout(logoutContext, snapshot)
			cancelLogout()
			s.closeErr = E.Append(s.closeErr, logoutErr, func(cause error) error {
				return E.Cause(cause, "logout F5 session")
			})
		}
		s.access.Lock()
		if s.configuration != nil {
			for byteIndex := range s.configuration.connectRequest {
				s.configuration.connectRequest[byteIndex] = 0
			}
			s.configuration.sessionID = ""
			s.configuration.urZ = ""
		}
		s.jar = nil
		s.mrhSession = ""
		s.f5ST = ""
		s.configuration = nil
		s.access.Unlock()
	})
	return s.closeErr
}

func (f *f5Frontend) logout(ctx context.Context, snapshot f5SessionSnapshot) error {
	logoutURL := cloneF5URL(snapshot.serverURL)
	logoutURL.Path = "/vdesk/hangup.php3"
	logoutURL.RawPath = ""
	logoutURL.RawQuery = "hangup_error=1"
	logoutClient, transport, _, clientErr := f.newPinnedHTTPClient(snapshot)
	if clientErr != nil {
		return clientErr
	}
	defer transport.CloseIdleConnections()
	request, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, logoutURL.String(), nil)
	if requestErr != nil {
		return E.Cause(requestErr, "create F5 logout request")
	}
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", f5UserAgent(f.client))
	response, responseErr := logoutClient.Do(request)
	if responseErr != nil {
		return E.Cause(responseErr, "send F5 logout request")
	}
	readLength, readErr := io.Copy(io.Discard, io.LimitReader(response.Body, f5MaximumAuthenticationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return E.Errors(E.Cause(readErr, "read F5 logout response"), closeErr)
	}
	if closeErr != nil {
		return E.Cause(closeErr, "close F5 logout response")
	}
	if readLength > f5MaximumAuthenticationBody {
		return E.New("logout response exceeds ", f5MaximumAuthenticationBody, " bytes")
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return E.New("logout returned HTTP ", response.StatusCode)
	}
	return nil
}

func (f *f5Frontend) newPinnedHTTPClient(
	snapshot f5SessionSnapshot,
) (*http.Client, *http.Transport, *pinnedHTTPPeer, error) {
	if snapshot.serverURL == nil || snapshot.jar == nil {
		return nil, nil, nil, E.New("accepted endpoint is incomplete")
	}
	expectedPort, portErr := f5URLPort(snapshot.serverURL)
	if portErr != nil {
		return nil, nil, nil, portErr
	}
	f.client.httpTransport.CloseIdleConnections()
	return newPinnedHTTPClient(f.client, snapshot.serverURL, snapshot.acceptedAddress, snapshot.jar, expectedPort, "F5")
}
