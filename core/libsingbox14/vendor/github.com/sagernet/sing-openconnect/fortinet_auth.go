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
	fortinetMaximumAuthenticationBody      = 16 * 1024 * 1024
	fortinetMaximumAuthenticationRequests  = 64
	fortinetMaximumAuthenticationRedirects = 10
	fortinetMaximumSAMLSessionID           = 1023
	fortinetLogoutTimeout                  = 5 * time.Second
	fortinetProtocolUserAgent              = "Mozilla/5.0 SV1"
)

type fortinetFrontend struct {
	client *Client
}

type fortinetAuthentication struct {
	access            sync.Mutex
	frontend          *fortinetFrontend
	initializationErr error
	httpClient        *http.Client
	jar               http.CookieJar
	currentURL        *url.URL
	currentAddress    netip.Addr
	realm             string
	username          string
	currentForm       *fortinetAuthenticationForm
	tokenGenerator    *softwareTokenGenerator
	requests          int
	started           bool
	completed         bool
	closed            bool
	advancing         bool
	currentInitial    bool
	currentSAML       bool
}

type fortinetHTTPResponse struct {
	statusCode int
	header     http.Header
	body       []byte
	requestURL *url.URL
	address    netip.Addr
}

type fortinetSessionState struct {
	access               sync.RWMutex
	frontend             *fortinetFrontend
	serverURL            *url.URL
	acceptedAddress      netip.Addr
	jar                  http.CookieJar
	svpnCookie           string
	configurationOnce    sync.Once
	configuration        *fortinetTunnelConfiguration
	configurationErr     error
	activeSession        *pppSession
	previousIPv4         netip.Prefix
	previousIPv6         netip.Prefix
	hasPreviousAddresses bool
	connectedOnce        bool
	initialSourceAddress netip.Addr
	droppedAt            time.Time
	skipInitialDTLS      bool
	closeOnce            sync.Once
	closeErr             error
}

type fortinetSessionSnapshot struct {
	serverURL            *url.URL
	acceptedAddress      netip.Addr
	jar                  http.CookieJar
	svpnCookie           string
	previousIPv4         netip.Prefix
	previousIPv6         netip.Prefix
	hasPreviousAddresses bool
	connectedOnce        bool
	initialSourceAddress netip.Addr
	droppedAt            time.Time
	skipInitialDTLS      bool
}

func (f *fortinetFrontend) BeginAuthentication() authContinuation {
	f.client.httpTransport.CloseIdleConnections()
	serverURL := cloneFortinetURL(f.client.serverURL)
	directCookie := f.client.takeDirectCookie()
	if directCookie != "" {
		jar, values, directErr := newDirectCookieJar(serverURL, directCookie, "SVPNCOOKIE")
		svpnCookie := values["SVPNCOOKIE"]
		if directErr == nil && svpnCookie == "" {
			directErr = E.New("direct cookie does not contain SVPNCOOKIE")
		}
		return &completedAuthentication{
			session: &fortinetSessionState{
				frontend:   f,
				serverURL:  serverURL,
				jar:        jar,
				svpnCookie: svpnCookie,
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
	return &fortinetAuthentication{
		frontend:          f,
		initializationErr: initializationErr,
		httpClient:        authenticationClient,
		jar:               jar,
		currentURL:        serverURL,
		tokenGenerator:    newSoftwareTokenGenerator(f.client.options.Token),
	}
}

func (a *fortinetAuthentication) Done() <-chan error {
	return nil
}

func (a *fortinetAuthentication) Close() error {
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
			a.currentForm.fields[fieldIndex].rawPair = ""
		}
	}
	a.currentForm = nil
	a.username = ""
	a.access.Unlock()
	return nil
}

func (a *fortinetAuthentication) Advance(
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
	currentInitial := a.currentInitial
	currentSAML := a.currentSAML
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
			return nil, nil, E.Extend(ErrProtocolNotSupported, "unexpected form response before Fortinet authentication")
		}
		return a.beginAuthentication(ctx)
	}
	if currentSAML {
		if response == nil || response.BrowserResult == nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "missing Fortinet SAML browser response")
		}
		return a.completeSAMLAuthentication(ctx, response.BrowserResult)
	}
	if response == nil || currentForm == nil {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "missing Fortinet authentication form response")
	}
	a.access.Lock()
	realm := a.realm
	a.access.Unlock()
	encodedForm, _, encodeErr := encodeFortinetAuthenticationResponse(currentForm, response, realm, currentInitial)
	if encodeErr != nil {
		return nil, nil, encodeErr
	}
	if currentInitial {
		usernameField := currentForm.fields[0]
		username := response.Values[usernameField.submissionKey]
		a.access.Lock()
		a.username = username
		a.access.Unlock()
	}
	requestURL, requestURLErr := a.authenticationPostURL(currentForm)
	if requestURLErr != nil {
		return nil, nil, requestURLErr
	}
	for fieldIndex := range currentForm.fields {
		if currentForm.fields[fieldIndex].kind == AuthFormFieldPassword || currentForm.fields[fieldIndex].name == "code" {
			currentForm.fields[fieldIndex].value = ""
		}
	}
	httpResponse, requestErr := a.doAuthenticationRequest(ctx, http.MethodPost, requestURL, encodedForm)
	if requestErr != nil {
		return nil, nil, requestErr
	}
	return a.processAuthenticationResponse(ctx, httpResponse, currentForm, currentInitial)
}

func (a *fortinetAuthentication) beginAuthentication(
	ctx context.Context,
) (obtainedSession, *authenticationRequest, error) {
	currentURL := cloneFortinetURL(a.currentURL)
	for redirectNumber := 0; ; redirectNumber++ {
		if redirectNumber > fortinetMaximumAuthenticationRedirects {
			return nil, nil, markTerminal(E.New("authentication exceeded ", fortinetMaximumAuthenticationRedirects, " redirects"))
		}
		httpResponse, requestErr := a.doAuthenticationRequest(ctx, http.MethodGet, currentURL, "")
		if requestErr != nil {
			return nil, nil, requestErr
		}
		a.rememberHTTPResponse(httpResponse)
		locationHeader := httpResponse.header.Get("Location")
		if isFortinetRedirectStatus(httpResponse.statusCode) && locationHeader != "" {
			location, locationErr := httpResponse.requestURL.Parse(locationHeader)
			if locationErr != nil {
				return nil, nil, markTerminal(E.Cause(locationErr, "parse Fortinet authentication redirect"))
			}
			if location.Path == "/remote/saml/start" {
				return a.beginSAMLAuthentication(location)
			}
			if httpResponse.requestURL.Path == "/remote/saml/start" {
				return a.beginSAMLAuthentication(httpResponse.requestURL)
			}
			prepareErr := a.prepareAuthenticationRedirect(httpResponse.requestURL, location)
			if prepareErr != nil {
				return nil, nil, prepareErr
			}
			currentURL = location
			continue
		}
		javascriptLocation, loaded, javascriptErr := parseFortinetTopLocation(httpResponse.body)
		if javascriptErr != nil {
			return nil, nil, markTerminal(javascriptErr)
		}
		if loaded {
			location, locationErr := httpResponse.requestURL.Parse(javascriptLocation)
			if locationErr != nil {
				return nil, nil, markTerminal(E.Cause(locationErr, "parse Fortinet JavaScript authentication redirect"))
			}
			prepareErr := a.prepareAuthenticationRedirect(httpResponse.requestURL, location)
			if prepareErr != nil {
				return nil, nil, prepareErr
			}
			currentURL = location
			continue
		}
		if httpResponse.requestURL.Path == "/remote/saml/start" {
			return a.beginSAMLAuthentication(httpResponse.requestURL)
		}
		if httpResponse.statusCode < http.StatusOK || httpResponse.statusCode >= http.StatusMultipleChoices {
			return nil, nil, markTerminal(E.New("login page returned HTTP ", httpResponse.statusCode))
		}
		realm := httpResponse.requestURL.Query().Get("realm")
		form := staticFortinetAuthenticationForm()
		a.access.Lock()
		a.currentURL = cloneFortinetURL(httpResponse.requestURL)
		a.realm = realm
		a.currentForm = form
		a.currentInitial = true
		a.currentSAML = false
		a.access.Unlock()
		return nil, a.buildAuthenticationRequest(form, true, ""), nil
	}
}

func (a *fortinetAuthentication) processAuthenticationResponse(
	ctx context.Context,
	httpResponse fortinetHTTPResponse,
	previousForm *fortinetAuthenticationForm,
	previousInitial bool,
) (obtainedSession, *authenticationRequest, error) {
	a.rememberHTTPResponse(httpResponse)
	if httpResponse.statusCode == http.StatusOK {
		var rejectedCacheKeys []string
		if previousInitial {
			rejectedCacheKeys = []string{authCachePassword}
		}
		authenticationResultErr := fortinetAuthenticationResultError(httpResponse.body, rejectedCacheKeys...)
		if authenticationResultErr != nil {
			return nil, nil, authenticationResultErr
		}
		state, cookieErr := a.sessionFromAuthenticationResponse(httpResponse)
		if cookieErr != nil {
			return nil, nil, cookieErr
		}
		if state != nil {
			return a.completeAuthenticatedResponse(ctx, httpResponse, state)
		}
	}
	if httpResponse.requestURL.Path == "/remote/saml/start" {
		return a.beginSAMLAuthentication(httpResponse.requestURL)
	}
	locationHeader := httpResponse.header.Get("Location")
	if isFortinetRedirectStatus(httpResponse.statusCode) && locationHeader != "" {
		location, locationErr := httpResponse.requestURL.Parse(locationHeader)
		if locationErr != nil {
			return nil, nil, markTerminal(E.Cause(locationErr, "parse Fortinet authentication redirect"))
		}
		if location.Path == "/remote/saml/start" {
			return a.beginSAMLAuthentication(location)
		}
	}
	switch httpResponse.statusCode {
	case http.StatusOK:
		javascriptLocation, loaded, javascriptErr := parseFortinetTopLocation(httpResponse.body)
		if javascriptErr != nil {
			return nil, nil, markTerminal(javascriptErr)
		}
		if loaded {
			location, locationErr := httpResponse.requestURL.Parse(javascriptLocation)
			if locationErr != nil {
				return nil, nil, markTerminal(E.Cause(locationErr, "parse Fortinet JavaScript authentication redirect"))
			}
			if location.Path == "/remote/saml/start" {
				return a.beginSAMLAuthentication(location)
			}
		}
		if isFortinetHTMLResponse(httpResponse) {
			a.access.Lock()
			currentURL := cloneFortinetURL(a.currentURL)
			realm := a.realm
			a.access.Unlock()
			if currentURL == nil {
				return nil, nil, markTerminal(E.New("authentication endpoint is empty"))
			}
			samlURL := newFortinetEndpointURL(currentURL, "/remote/saml/start")
			if realm != "" {
				query := make(url.Values)
				query.Set("realm", realm)
				samlURL.RawQuery = query.Encode()
			}
			return a.beginSAMLAuthentication(samlURL)
		}
		a.access.Lock()
		username := a.username
		a.access.Unlock()
		form, parseErr := parseFortinetTokenInfo(httpResponse.body, username)
		if parseErr != nil {
			return nil, nil, markTerminal(parseErr)
		}
		a.access.Lock()
		a.currentForm = form
		a.currentInitial = false
		a.currentSAML = false
		a.access.Unlock()
		return nil, a.buildAuthenticationRequest(form, false, ""), nil
	case http.StatusUnauthorized:
		form, parseErr := parseFortinetHTMLChallenge(httpResponse.body)
		if parseErr != nil {
			return nil, nil, markTerminal(parseErr)
		}
		a.access.Lock()
		a.currentForm = form
		a.currentInitial = false
		a.currentSAML = false
		a.access.Unlock()
		return nil, a.buildAuthenticationRequest(form, false, ""), nil
	case http.StatusMethodNotAllowed:
		for fieldIndex := range previousForm.fields {
			field := &previousForm.fields[fieldIndex]
			if field.kind == AuthFormFieldPassword || field.name == "code" {
				field.value = ""
			}
		}
		a.access.Lock()
		a.currentForm = previousForm
		a.currentInitial = previousInitial
		a.currentSAML = false
		a.access.Unlock()
		return nil, a.buildAuthenticationRequest(previousForm, previousInitial, "Invalid credentials; try again."), nil
	default:
		if isFortinetRedirectStatus(httpResponse.statusCode) || httpResponse.statusCode == http.StatusForbidden {
			if previousInitial {
				return nil, nil, newRetryableAuthenticationError(E.New("gateway rejected the primary credentials"), authCachePassword)
			}
			return nil, nil, E.New("gateway rejected the authentication continuation")
		}
		return nil, nil, markTerminal(E.New("logincheck returned HTTP ", httpResponse.statusCode))
	}
}

func (a *fortinetAuthentication) completeAuthenticatedResponse(
	ctx context.Context,
	httpResponse fortinetHTTPResponse,
	state *fortinetSessionState,
) (obtainedSession, *authenticationRequest, error) {
	hostCheckOptions := a.frontend.client.options.FortinetHostCheck
	if hostCheckOptions != nil && hostCheckOptions.HostCheck != "" {
		hostCheckAction, loaded, parseErr := parseFortinetHostCheckAction(httpResponse.body)
		if parseErr != nil {
			return nil, nil, markTerminal(parseErr)
		}
		if loaded {
			hostCheckResponse, hostCheckErr := a.submitHostCheck(ctx, httpResponse.requestURL, hostCheckAction, *hostCheckOptions)
			if hostCheckErr != nil {
				return nil, nil, hostCheckErr
			}
			if hostCheckResponse.statusCode < http.StatusOK || hostCheckResponse.statusCode >= http.StatusMultipleChoices {
				return nil, nil, markTerminal(E.New("hostcheck returned HTTP ", hostCheckResponse.statusCode))
			}
			hostCheckState, cookieErr := a.sessionFromCookies(hostCheckResponse.requestURL)
			if cookieErr != nil {
				return nil, nil, cookieErr
			}
			if hostCheckState == nil {
				return nil, nil, markTerminal(E.New("hostcheck response omitted SVPNCOOKIE"))
			}
			state = hostCheckState
		}
	}
	a.access.Lock()
	a.completed = true
	a.currentForm = nil
	a.currentSAML = false
	a.access.Unlock()
	return state, nil, nil
}

func (a *fortinetAuthentication) submitHostCheck(
	ctx context.Context,
	responseURL *url.URL,
	action string,
	options FortinetHostCheckOptions,
) (fortinetHTTPResponse, error) {
	requestURL, resolveErr := responseURL.Parse(action)
	if resolveErr != nil {
		return fortinetHTTPResponse{}, markTerminal(E.Cause(resolveErr, "resolve Fortinet hostcheck action"))
	}
	if !equalFortinetEndpoint(responseURL, requestURL) {
		return fortinetHTTPResponse{}, markTerminal(E.New("hostcheck action changed the accepted origin"))
	}
	validationErr := validateHTTPSRequestURL(requestURL)
	if validationErr != nil {
		return fortinetHTTPResponse{}, markTerminal(validationErr)
	}
	encodedForm := "hostcheck=" + url.QueryEscape(options.HostCheck) +
		"&check_virtual_desktop=" + url.QueryEscape(options.CheckVirtualDesktop)
	httpResponse, requestErr := a.doAuthenticationRequest(ctx, http.MethodPost, requestURL, encodedForm)
	if requestErr != nil {
		return fortinetHTTPResponse{}, requestErr
	}
	a.rememberHTTPResponse(httpResponse)
	return httpResponse, nil
}

func (a *fortinetAuthentication) beginSAMLAuthentication(browserURL *url.URL) (obtainedSession, *authenticationRequest, error) {
	if a.frontend.client.options.ExternalAuthDisabled {
		return nil, nil, markTerminal(E.Extend(ErrProtocolNotSupported, "gateway requested disabled external authentication"))
	}
	validationErr := validateHTTPSRequestURL(browserURL)
	if validationErr != nil {
		return nil, nil, markTerminal(validationErr)
	}
	a.access.Lock()
	currentURL := cloneFortinetURL(a.currentURL)
	if currentURL == nil || !equalFortinetEndpoint(currentURL, browserURL) {
		a.access.Unlock()
		return nil, nil, markTerminal(E.New("SAML authentication changed the accepted origin"))
	}
	browserURL = cloneFortinetURL(browserURL)
	query := browserURL.Query()
	query.Set("redirect", "1")
	browserURL.RawQuery = query.Encode()
	a.currentForm = nil
	a.currentInitial = false
	a.currentSAML = true
	a.access.Unlock()
	return nil, &authenticationRequest{
		FormID: "_saml",
		Browser: &BrowserRequest{
			URL:                 browserURL.String(),
			CallbackURLPrefixes: []string{"http://127.0.0.1:"},
		},
	}, nil
}

func (a *fortinetAuthentication) completeSAMLAuthentication(
	ctx context.Context,
	result *BrowserResult,
) (obtainedSession, *authenticationRequest, error) {
	if result == nil {
		return nil, nil, ErrInvalidBrowserAuthentication
	}
	a.access.Lock()
	currentURL := cloneFortinetURL(a.currentURL)
	a.access.Unlock()
	if currentURL == nil {
		return nil, nil, markTerminal(E.New("SAML authentication state is unavailable"))
	}
	sessionID, callbackErr := parseFortinetSAMLCallback(result.FinalURL)
	if callbackErr != nil {
		return nil, nil, E.Errors(ErrInvalidBrowserAuthentication, callbackErr)
	}
	authenticationURL := newFortinetEndpointURL(currentURL, "/remote/saml/auth_id")
	query := make(url.Values)
	query.Set("id", sessionID)
	authenticationURL.RawQuery = query.Encode()
	httpResponse, requestErr := a.doAuthenticationRequest(ctx, http.MethodGet, authenticationURL, "")
	if requestErr != nil {
		return nil, nil, requestErr
	}
	a.rememberHTTPResponse(httpResponse)
	if httpResponse.statusCode != http.StatusOK {
		return nil, nil, markTerminal(E.New("SAML auth_id returned HTTP ", httpResponse.statusCode))
	}
	authenticationResultErr := fortinetAuthenticationResultError(httpResponse.body)
	if authenticationResultErr != nil {
		return nil, nil, authenticationResultErr
	}
	state, cookieErr := a.sessionFromAuthenticationResponse(httpResponse)
	if cookieErr != nil {
		return nil, nil, cookieErr
	}
	if state == nil {
		return nil, nil, markTerminal(E.New("SAML auth_id response omitted SVPNCOOKIE"))
	}
	return a.completeAuthenticatedResponse(ctx, httpResponse, state)
}

func isFortinetHTMLResponse(response fortinetHTTPResponse) bool {
	contentType := strings.ToLower(response.header.Get("Content-Type"))
	if strings.HasPrefix(contentType, "text/html") {
		return true
	}
	trimmed := bytes.TrimSpace(response.body)
	lowerContent := bytes.ToLower(trimmed)
	return bytes.HasPrefix(lowerContent, []byte("<!doctype html")) ||
		bytes.HasPrefix(lowerContent, []byte("<html")) ||
		bytes.Contains(lowerContent, []byte("/remote/saml/"))
}

func parseFortinetSAMLCallback(callback string) (string, error) {
	callbackURL, parseErr := url.Parse(callback)
	if parseErr != nil {
		return "", E.Cause(parseErr, "parse Fortinet SAML callback URL")
	}
	if !strings.EqualFold(callbackURL.Scheme, "http") || callbackURL.User != nil || callbackURL.Hostname() != "127.0.0.1" ||
		callbackURL.Port() == "" || callbackURL.EscapedPath() != "/" || callbackURL.Fragment != "" || callbackURL.Opaque != "" {
		return "", E.New("Fortinet SAML callback URL is invalid")
	}
	_, portErr := fortinetURLPort(callbackURL)
	if portErr != nil {
		return "", portErr
	}
	query, queryErr := url.ParseQuery(callbackURL.RawQuery)
	if queryErr != nil {
		return "", E.Cause(queryErr, "parse Fortinet SAML callback query")
	}
	if len(query) != 1 || len(query["id"]) != 1 {
		return "", E.New("Fortinet SAML callback omitted its sole session id")
	}
	sessionID := query.Get("id")
	if len(sessionID) == 0 || len(sessionID) > fortinetMaximumSAMLSessionID {
		return "", E.New("Fortinet SAML callback session id has an invalid length")
	}
	for characterIndex := 0; characterIndex < len(sessionID); characterIndex++ {
		character := sessionID[characterIndex]
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || character == '-' {
			continue
		}
		return "", E.New("Fortinet SAML callback session id has an invalid character")
	}
	return sessionID, nil
}

func (a *fortinetAuthentication) buildAuthenticationRequest(
	form *fortinetAuthenticationForm,
	initial bool,
	errorMessage string,
) *authenticationRequest {
	request := &authenticationRequest{
		FormID:  form.id,
		Message: form.message,
		Error:   errorMessage,
	}
	if initial && errorMessage != "" {
		request.ClearCacheKeys = []string{authCachePassword}
	}
	for _, field := range form.fields {
		requestField := authenticationRequestField{
			SubmissionKey: field.submissionKey,
			Name:          field.name,
			Label:         field.label,
			Kind:          field.kind,
			Value:         field.value,
		}
		if initial && field.name == "username" {
			requestField.CacheKey = authCacheUsername
		}
		if initial && field.name == "credential" {
			requestField.CacheKey = authCachePassword
		}
		if !initial && (field.name == "code" || field.name == "credential") && field.kind == AuthFormFieldPassword && a.tokenGenerator.CanGenerate(form.message) {
			requestField.Kind = authFormFieldToken
			tokenMessage := form.message
			requestField.Automatic = func(ctx context.Context) (string, error) {
				return a.tokenGenerator.Generate(ctx, tokenMessage)
			}
		}
		request.Fields = append(request.Fields, requestField)
	}
	return request
}

func (a *fortinetAuthentication) authenticationPostURL(form *fortinetAuthenticationForm) (*url.URL, error) {
	a.access.Lock()
	currentURL := cloneFortinetURL(a.currentURL)
	a.access.Unlock()
	if currentURL == nil {
		return nil, markTerminal(E.New("authentication endpoint is empty"))
	}
	requestURL := newFortinetEndpointURL(currentURL, "/remote/logincheck")
	if form.action != "" {
		resolvedURL, resolveErr := currentURL.Parse(form.action)
		if resolveErr != nil {
			return nil, markTerminal(E.Cause(resolveErr, "resolve Fortinet HTML challenge action"))
		}
		if !equalFortinetEndpoint(currentURL, resolvedURL) {
			return nil, markTerminal(E.New("HTML challenge action changed the accepted origin"))
		}
		requestURL = resolvedURL
	}
	validationErr := validateHTTPSRequestURL(requestURL)
	if validationErr != nil {
		return nil, markTerminal(validationErr)
	}
	return requestURL, nil
}

func (a *fortinetAuthentication) doAuthenticationRequest(
	ctx context.Context,
	method string,
	requestURL *url.URL,
	encodedForm string,
) (fortinetHTTPResponse, error) {
	a.access.Lock()
	a.requests++
	requestNumber := a.requests
	a.access.Unlock()
	if requestNumber > fortinetMaximumAuthenticationRequests {
		return fortinetHTTPResponse{}, markTerminal(E.New("authentication exceeded ", fortinetMaximumAuthenticationRequests, " wire requests"))
	}
	var body io.Reader
	if method == http.MethodPost {
		body = bytes.NewBufferString(encodedForm)
	}
	request, requestErr := http.NewRequestWithContext(ctx, method, requestURL.String(), body)
	if requestErr != nil {
		return fortinetHTTPResponse{}, markTerminal(E.Cause(requestErr, "create Fortinet authentication request"))
	}
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", fortinetUserAgent(a.frontend.client))
	if method == http.MethodPost {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	var acceptedAddress netip.Addr
	trace := &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			acceptedAddress = parseFortinetRemoteAddress(info.Conn.RemoteAddr())
		},
	}
	request = request.WithContext(httptrace.WithClientTrace(request.Context(), trace))
	response, responseErr := a.httpClient.Do(request)
	if responseErr != nil {
		requestFailure := E.Cause(responseErr, "send Fortinet authentication request")
		if response != nil && response.Body != nil {
			closeErr := response.Body.Close()
			if closeErr != nil {
				requestFailure = E.Errors(requestFailure, E.Cause(closeErr, "close failed Fortinet authentication response"))
			}
		}
		return fortinetHTTPResponse{}, requestFailure
	}
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, fortinetMaximumAuthenticationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return fortinetHTTPResponse{}, E.Errors(E.Cause(readErr, "read Fortinet authentication response"), closeErr)
	}
	if closeErr != nil {
		return fortinetHTTPResponse{}, E.Cause(closeErr, "close Fortinet authentication response")
	}
	if len(responseBody) > fortinetMaximumAuthenticationBody {
		return fortinetHTTPResponse{}, markTerminal(E.New("authentication response exceeds ", fortinetMaximumAuthenticationBody, " bytes"))
	}
	return fortinetHTTPResponse{
		statusCode: response.StatusCode,
		header:     response.Header.Clone(),
		body:       responseBody,
		requestURL: cloneFortinetURL(request.URL),
		address:    acceptedAddress,
	}, nil
}

func (a *fortinetAuthentication) rememberHTTPResponse(response fortinetHTTPResponse) {
	a.access.Lock()
	a.currentURL = cloneFortinetURL(response.requestURL)
	if response.address.IsValid() {
		a.currentAddress = response.address
	}
	a.access.Unlock()
}

func (a *fortinetAuthentication) prepareAuthenticationRedirect(currentURL *url.URL, location *url.URL) error {
	validationErr := validateHTTPSRequestURL(location)
	if validationErr != nil {
		return markTerminal(validationErr)
	}
	if equalFortinetEndpoint(currentURL, location) {
		return nil
	}
	jar, jarErr := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	if jarErr != nil {
		return markTerminal(E.Cause(jarErr, "create Fortinet redirected authentication cookie jar"))
	}
	a.frontend.client.httpTransport.CloseIdleConnections()
	a.access.Lock()
	a.jar = jar
	a.httpClient.Jar = jar
	a.currentAddress = netip.Addr{}
	a.access.Unlock()
	return nil
}

func (a *fortinetAuthentication) sessionFromCookies(requestURL *url.URL) (*fortinetSessionState, error) {
	a.access.Lock()
	jar := a.jar
	acceptedAddress := a.currentAddress
	a.access.Unlock()
	if jar == nil {
		return nil, nil
	}
	var svpnCookie string
	for _, cookie := range jar.Cookies(requestURL) {
		if cookie.Name == "SVPNCOOKIE" {
			svpnCookie = cookie.Value
			break
		}
	}
	if svpnCookie == "" {
		return nil, nil
	}
	if !acceptedAddress.IsValid() {
		return nil, markTerminal(E.New("authenticated endpoint has no accepted peer address"))
	}
	return &fortinetSessionState{
		frontend:        a.frontend,
		serverURL:       cloneFortinetURL(requestURL),
		acceptedAddress: acceptedAddress,
		jar:             jar,
		svpnCookie:      svpnCookie,
	}, nil
}

func (a *fortinetAuthentication) sessionFromAuthenticationResponse(response fortinetHTTPResponse) (*fortinetSessionState, error) {
	if response.requestURL == nil {
		return nil, markTerminal(E.New("authentication response URL is unavailable"))
	}
	parsedResponse := &http.Response{Header: response.header}
	responseJar, jarErr := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	if jarErr != nil {
		return nil, markTerminal(E.Cause(jarErr, "create Fortinet authentication response cookie jar"))
	}
	responseJar.SetCookies(response.requestURL, parsedResponse.Cookies())
	responseCookieValues := make(map[string]struct{})
	for _, cookie := range responseJar.Cookies(response.requestURL) {
		if cookie.Name == "SVPNCOOKIE" && cookie.Value != "" {
			responseCookieValues[cookie.Value] = struct{}{}
		}
	}
	if len(responseCookieValues) == 0 {
		return nil, nil
	}
	state, cookieErr := a.sessionFromCookies(response.requestURL)
	if cookieErr != nil {
		return nil, cookieErr
	}
	if state == nil {
		return nil, markTerminal(E.New("authentication response SVPNCOOKIE was not accepted by the cookie jar"))
	}
	if _, loaded := responseCookieValues[state.svpnCookie]; !loaded {
		return nil, markTerminal(E.New("authentication response did not replace the active SVPNCOOKIE"))
	}
	return state, nil
}

func fortinetAuthenticationResultError(content []byte, rejectedCacheKeys ...string) error {
	authenticationResult, loaded, parseErr := parseFortinetAuthenticationResult(content)
	if parseErr != nil {
		return markTerminal(parseErr)
	}
	if !loaded {
		return nil
	}
	switch authenticationResult {
	case 0:
		return newRetryableAuthenticationError(E.New("gateway rejected the Fortinet authentication"), rejectedCacheKeys...)
	case 6:
		return markTerminal(E.Extend(ErrProtocolNotSupported, "gateway requested an unsupported Fortinet authentication challenge"))
	default:
		return nil
	}
}

func parseFortinetTopLocation(content []byte) (string, bool, error) {
	text := string(content)
	marker := "top.location=\""
	start := strings.Index(text, marker)
	if start < 0 {
		return "", false, nil
	}
	start += len(marker)
	var escaped bool
	for position := start; position < len(text); position++ {
		value := text[position]
		if escaped {
			escaped = false
			continue
		}
		if value == '\\' {
			escaped = true
			continue
		}
		if value == '"' {
			quoted := "\"" + text[start:position] + "\""
			location, unquoteErr := strconv.Unquote(quoted)
			if unquoteErr != nil {
				return "", false, E.Cause(unquoteErr, "decode Fortinet JavaScript redirect")
			}
			if location == "" {
				return "", false, E.New("JavaScript redirect is empty")
			}
			return location, true, nil
		}
	}
	return "", false, E.New("unterminated Fortinet JavaScript redirect")
}

func isFortinetRedirectStatus(statusCode int) bool {
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

func cloneFortinetURL(serverURL *url.URL) *url.URL {
	if serverURL == nil {
		return nil
	}
	cloned := *serverURL
	return &cloned
}

func newFortinetEndpointURL(serverURL *url.URL, path string) *url.URL {
	endpointURL := cloneFortinetURL(serverURL)
	if endpointURL == nil {
		return nil
	}
	endpointURL.Path = path
	endpointURL.RawPath = ""
	endpointURL.ForceQuery = false
	endpointURL.RawQuery = ""
	endpointURL.Fragment = ""
	endpointURL.RawFragment = ""
	return endpointURL
}

func equalFortinetEndpoint(left *url.URL, right *url.URL) bool {
	if left == nil || right == nil || !strings.EqualFold(left.Scheme, right.Scheme) || !strings.EqualFold(left.Hostname(), right.Hostname()) {
		return false
	}
	leftPort, leftErr := fortinetURLPort(left)
	rightPort, rightErr := fortinetURLPort(right)
	return leftErr == nil && rightErr == nil && leftPort == rightPort
}

func fortinetUserAgent(client *Client) string {
	if client.options.UserAgent != "" {
		return client.options.UserAgent
	}
	return fortinetProtocolUserAgent
}

func fortinetURLPort(serverURL *url.URL) (uint16, error) {
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

func parseFortinetRemoteAddress(address net.Addr) netip.Addr {
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

func (s *fortinetSessionState) snapshot() fortinetSessionSnapshot {
	s.access.RLock()
	defer s.access.RUnlock()
	return fortinetSessionSnapshot{
		serverURL:            cloneFortinetURL(s.serverURL),
		acceptedAddress:      s.acceptedAddress,
		jar:                  s.jar,
		svpnCookie:           s.svpnCookie,
		previousIPv4:         s.previousIPv4,
		previousIPv6:         s.previousIPv6,
		hasPreviousAddresses: s.hasPreviousAddresses,
		connectedOnce:        s.connectedOnce,
		initialSourceAddress: s.initialSourceAddress,
		droppedAt:            s.droppedAt,
		skipInitialDTLS:      s.skipInitialDTLS,
	}
}

func (s *fortinetSessionState) attachSession(session *pppSession) error {
	s.access.Lock()
	defer s.access.Unlock()
	if s.svpnCookie == "" || s.jar == nil {
		return ErrSessionRejected
	}
	if s.activeSession != nil && s.activeSession != session {
		return E.New("obtained session already owns an active tunnel")
	}
	s.activeSession = session
	return nil
}

func (s *fortinetSessionState) detachSession(session *pppSession) {
	s.access.Lock()
	if s.activeSession == session {
		s.activeSession = nil
	}
	s.access.Unlock()
}

func (s *fortinetSessionState) Close() error {
	s.closeOnce.Do(func() {
		s.access.RLock()
		activeSession := s.activeSession
		s.access.RUnlock()
		if activeSession != nil {
			s.closeErr = activeSession.Close()
		}
		snapshot := s.snapshot()
		if snapshot.serverURL != nil && snapshot.acceptedAddress.IsValid() && snapshot.jar != nil && snapshot.svpnCookie != "" {
			logoutContext, cancelLogout := context.WithTimeout(context.Background(), fortinetLogoutTimeout)
			logoutErr := s.frontend.logout(logoutContext, snapshot)
			cancelLogout()
			s.closeErr = E.Append(s.closeErr, logoutErr, func(cause error) error {
				return E.Cause(cause, "logout Fortinet session")
			})
		}
		s.access.Lock()
		if s.configuration != nil {
			for byteIndex := range s.configuration.tlsConnectRequest {
				s.configuration.tlsConnectRequest[byteIndex] = 0
			}
			for byteIndex := range s.configuration.dtlsConnectRequest {
				s.configuration.dtlsConnectRequest[byteIndex] = 0
			}
			s.configuration.tlsConnectRequest = nil
			s.configuration.dtlsConnectRequest = nil
		}
		s.jar = nil
		s.svpnCookie = ""
		s.configuration = nil
		s.access.Unlock()
	})
	return s.closeErr
}

func (f *fortinetFrontend) logout(ctx context.Context, snapshot fortinetSessionSnapshot) error {
	logoutURL := newFortinetEndpointURL(snapshot.serverURL, "/remote/logout")
	logoutClient, transport, _, clientErr := f.newPinnedHTTPClient(snapshot)
	if clientErr != nil {
		return clientErr
	}
	defer transport.CloseIdleConnections()
	request, requestErr := http.NewRequestWithContext(ctx, http.MethodGet, logoutURL.String(), nil)
	if requestErr != nil {
		return E.Cause(requestErr, "create Fortinet logout request")
	}
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", fortinetUserAgent(f.client))
	response, responseErr := logoutClient.Do(request)
	if responseErr != nil {
		return E.Cause(responseErr, "send Fortinet logout request")
	}
	_, readErr := io.Copy(io.Discard, io.LimitReader(response.Body, fortinetMaximumAuthenticationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return E.Errors(E.Cause(readErr, "read Fortinet logout response"), closeErr)
	}
	if closeErr != nil {
		return E.Cause(closeErr, "close Fortinet logout response")
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return E.New("logout returned HTTP ", response.StatusCode)
	}
	return nil
}

func (f *fortinetFrontend) newPinnedHTTPClient(
	snapshot fortinetSessionSnapshot,
) (*http.Client, *http.Transport, *pinnedHTTPPeer, error) {
	if snapshot.serverURL == nil || snapshot.jar == nil {
		return nil, nil, nil, E.New("accepted endpoint is incomplete")
	}
	expectedPort, portErr := fortinetURLPort(snapshot.serverURL)
	if portErr != nil {
		return nil, nil, nil, portErr
	}
	f.client.httpTransport.CloseIdleConnections()
	return newPinnedHTTPClient(f.client, snapshot.serverURL, snapshot.acceptedAddress, snapshot.jar, expectedPort, "Fortinet")
}
