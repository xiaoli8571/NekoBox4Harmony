package openconnect

import (
	"bytes"
	"context"
	"crypto/x509"
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
	M "github.com/sagernet/sing/common/metadata"

	"golang.org/x/net/publicsuffix"
)

const (
	ncMaximumAuthenticationBody      = 16 * 1024 * 1024
	ncMaximumAuthenticationRequests  = 64
	ncMaximumAuthenticationRedirects = 10
	ncLogoutTimeout                  = 5 * time.Second
	ncDefaultUserAgent               = "AnyConnect-compatible OpenConnect VPN Agent " + defaultClientVersion
)

type ncFrontend struct {
	client        *Client
	localHostname string
}

type ncAuthentication struct {
	access              sync.Mutex
	frontend            *ncFrontend
	initializationErr   error
	httpClient          *http.Client
	transport           *http.Transport
	jar                 http.CookieJar
	currentURL          *url.URL
	currentAddress      netip.Addr
	currentCertificate  *x509.Certificate
	currentForm         *ncAuthenticationForm
	tokenGenerator      *softwareTokenGenerator
	tnccRunner          ncTNCCRunner
	requests            int
	primaryPasswordSeen bool
	primaryPasswordSent bool
	currentFormPrimary  bool
	tnccAttempted       bool
	started             bool
	completed           bool
	closed              bool
	advancing           bool
}

type ncHTTPResponse struct {
	statusCode      int
	header          http.Header
	body            []byte
	requestURL      *url.URL
	address         netip.Addr
	peerCertificate *x509.Certificate
}

type ncSessionState struct {
	access          sync.RWMutex
	frontend        *ncFrontend
	serverURL       *url.URL
	acceptedAddress netip.Addr
	jar             http.CookieJar
	dsid            string
	tnccRunner      ncTNCCRunner
	activeSession   clientSession
	closeOnce       sync.Once
	closeErr        error
}

type ncSessionSnapshot struct {
	serverURL       *url.URL
	acceptedAddress netip.Addr
	jar             http.CookieJar
	dsid            string
}

func init() {
	registerFlavorFrontend(FlavorNC, func(client *Client) (flavorFrontend, error) {
		return newNCFrontend(client)
	})
}

func newNCFrontend(client *Client) (*ncFrontend, error) {
	err := validateNCTNCCOptions(client.options.TNCC)
	if err != nil {
		return nil, err
	}
	return &ncFrontend{client: client, localHostname: client.options.LocalHostname}, nil
}

func validateNCTNCCOptions(options *TNCCOptions) error {
	if options == nil {
		return nil
	}
	if strings.ContainsAny(options.DeviceID, ";\r\n") {
		return E.New("TNCC device ID contains a protocol delimiter")
	}
	if strings.ContainsAny(options.UserAgent, "\r\n") {
		return E.New("TNCC user agent contains a line delimiter")
	}
	if options.WrapperPath != "" && (options.DeviceID != "" || options.UserAgent != "" || options.MachineIdentificationEnabled || len(options.Certificates) > 0) {
		return E.New("external Network Connect TNCC wrapper options cannot be combined with built-in TNCC identity options")
	}
	if len(options.Certificates) > 0 && !options.MachineIdentificationEnabled {
		return E.New("TNCC certificates require machine identification")
	}
	for certificateIndex, certificate := range options.Certificates {
		err := certificate.Validate("TNCC certificate " + strconv.Itoa(certificateIndex))
		if err != nil {
			return err
		}
	}
	return nil
}

func (f *ncFrontend) BeginAuthentication() authContinuation {
	f.client.httpTransport.CloseIdleConnections()
	serverURL := cloneNCURL(f.client.serverURL)
	directCookie := f.client.takeDirectCookie()
	if directCookie != "" {
		jar, values, directErr := newDirectCookieJar(serverURL, directCookie, "DSID")
		dsid := values["DSID"]
		if directErr == nil && dsid == "" {
			directErr = E.New("direct cookie does not contain DSID")
		}
		return &completedAuthentication{
			session: &ncSessionState{
				frontend:  f,
				serverURL: serverURL,
				jar:       jar,
				dsid:      dsid,
			},
			err: directErr,
		}
	}
	jar, initializationErr := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	transport := f.client.httpTransport.Clone()
	authenticationClient := &http.Client{
		Transport: f.client.wrapHTTPTransport(transport),
		Jar:       jar,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return &ncAuthentication{
		frontend:          f,
		initializationErr: initializationErr,
		httpClient:        authenticationClient,
		transport:         transport,
		jar:               jar,
		currentURL:        serverURL,
		tokenGenerator:    newSoftwareTokenGenerator(f.client.options.Token),
	}
}

func (f *ncFrontend) ConnectTunnel(ctx context.Context, obtained obtainedSession) (clientSession, error) {
	state, valid := obtained.(*ncSessionState)
	if !valid || state == nil || state.frontend != f {
		return nil, markTerminal(E.Extend(ErrProtocolNotSupported, "received an invalid obtained session"))
	}
	snapshot := state.snapshot()
	if snapshot.serverURL == nil || snapshot.jar == nil || snapshot.dsid == "" {
		return nil, ErrSessionRejected
	}
	sessionContext, cancelSession := context.WithCancel(ctx)
	return &ncSession{
		ctx:           sessionContext,
		cancel:        cancelSession,
		client:        f.client,
		state:         state,
		snapshot:      snapshot,
		localHostname: f.localHostname,
		done:          make(chan error, 1),
	}, nil
}

func (a *ncAuthentication) Done() <-chan error {
	return nil
}

func (a *ncAuthentication) Close() error {
	a.access.Lock()
	if a.closed {
		a.access.Unlock()
		return nil
	}
	a.closed = true
	runner := a.tnccRunner
	a.tnccRunner = nil
	if !a.completed {
		a.jar = nil
		a.httpClient.Jar = nil
	}
	if a.currentForm != nil {
		for fieldIndex := range a.currentForm.fields {
			if a.currentForm.fields[fieldIndex].kind == AuthFormFieldPassword {
				a.currentForm.fields[fieldIndex].value = ""
			}
		}
	}
	a.currentForm = nil
	a.access.Unlock()
	a.transport.CloseIdleConnections()
	if runner != nil {
		return runner.Close()
	}
	return nil
}

func (a *ncAuthentication) Advance(
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
			return nil, nil, E.Extend(ErrProtocolNotSupported, "unexpected form response before Network Connect authentication")
		}
		return a.doAuthenticationExchange(ctx, http.MethodGet, a.currentURL, "")
	}
	if response == nil || currentForm == nil {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "missing Network Connect authentication form response")
	}
	requestURL := cloneNCURL(a.currentURL)
	method := http.MethodPost
	encodedForm := ""
	if currentForm.roleForm {
		selectedRole, loaded := response.Values[currentForm.fields[0].submissionKey]
		if !loaded || !authFormChoiceContains(currentForm.fields[0].options, selectedRole) {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "role response selected an unknown role")
		}
		resolvedURL, resolveErr := requestURL.Parse(selectedRole)
		if resolveErr != nil {
			return nil, nil, markTerminal(E.Cause(resolveErr, "resolve Network Connect role URL"))
		}
		validationErr := validateHTTPSRequestURL(resolvedURL)
		if validationErr != nil {
			return nil, nil, markTerminal(validationErr)
		}
		requestURL = resolvedURL
		method = http.MethodGet
	} else {
		var encodeErr error
		encodedForm, encodeErr = encodeNCAuthenticationResponse(currentForm, response)
		if encodeErr != nil {
			return nil, nil, encodeErr
		}
		if currentForm.action != "" {
			resolvedURL, resolveErr := requestURL.Parse(currentForm.action)
			if resolveErr != nil {
				return nil, nil, markTerminal(E.Cause(resolveErr, "resolve Network Connect authentication form action"))
			}
			validationErr := validateHTTPSRequestURL(resolvedURL)
			if validationErr != nil {
				return nil, nil, markTerminal(validationErr)
			}
			requestURL = resolvedURL
		}
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
	return a.doAuthenticationExchange(ctx, method, requestURL, encodedForm)
}

func (a *ncAuthentication) doAuthenticationExchange(
	ctx context.Context,
	method string,
	requestURL *url.URL,
	encodedForm string,
) (obtainedSession, *authenticationRequest, error) {
	currentMethod := method
	currentURL := cloneNCURL(requestURL)
	currentBody := encodedForm
	for redirectNumber := 0; ; redirectNumber++ {
		if redirectNumber > ncMaximumAuthenticationRedirects {
			return nil, nil, markTerminal(E.New("authentication exceeded ", ncMaximumAuthenticationRedirects, " redirects"))
		}
		httpResponse, err := a.doAuthenticationRequest(ctx, currentMethod, currentURL, currentBody)
		if err != nil {
			return nil, nil, err
		}
		a.recordHTTPResponse(httpResponse)
		state, err := a.sessionFromCookies(ctx, httpResponse)
		if err != nil {
			return nil, nil, err
		}
		if state != nil {
			return state, nil, nil
		}
		locationHeader := httpResponse.header.Get("Location")
		if httpResponse.statusCode != http.StatusOK && locationHeader != "" {
			location, locationErr := httpResponse.requestURL.Parse(locationHeader)
			if locationErr != nil {
				return nil, nil, markTerminal(E.Cause(locationErr, "parse Network Connect authentication redirect"))
			}
			validationErr := validateHTTPSRequestURL(location)
			if validationErr != nil {
				return nil, nil, markTerminal(validationErr)
			}
			currentMethod = http.MethodGet
			currentURL = location
			currentBody = ""
			continue
		}
		if httpResponse.statusCode != http.StatusOK {
			return nil, nil, classifyNCAuthenticationHTTPStatus(httpResponse.statusCode)
		}
		if len(httpResponse.body) == 0 {
			return nil, nil, markTerminal(E.New("authentication returned an empty response body"))
		}
		form, parseErr := parseNCAuthenticationDocument(httpResponse.body)
		if parseErr != nil {
			return nil, nil, markTerminal(parseErr)
		}
		if form == nil {
			preauthenticationCookie := ncCookieValue(a.jar, httpResponse.requestURL, "DSPREAUTH")
			a.access.Lock()
			tnccAttempted := a.tnccAttempted
			a.access.Unlock()
			if !tnccAttempted && preauthenticationCookie != "" {
				err = a.startTNCC(ctx, httpResponse, preauthenticationCookie)
				if err != nil {
					return nil, nil, err
				}
				currentMethod = http.MethodGet
				currentURL = cloneNCURL(httpResponse.requestURL)
				currentBody = ""
				continue
			}
			return nil, nil, markTerminal(E.New("authentication response has no usable form"))
		}
		err = validateNCAuthenticationForm(form)
		if err != nil {
			return nil, nil, err
		}
		request := a.authenticationRequestFromForm(form)
		a.access.Lock()
		a.currentForm = form
		a.access.Unlock()
		return nil, request, nil
	}
}

func (a *ncAuthentication) startTNCC(
	ctx context.Context,
	response ncHTTPResponse,
	preauthenticationCookie string,
) error {
	runner, err := newNCTNCCRunner(a.frontend, response.requestURL, response.address, a.jar, response.peerCertificate)
	if err != nil {
		return err
	}
	signInURL := ncCookieValue(a.jar, response.requestURL, "DSSIGNIN")
	if signInURL == "" {
		signInURL = "null"
	}
	updatedCookie, err := runner.Start(ctx, preauthenticationCookie, signInURL)
	if err != nil {
		_ = runner.Close()
		return err
	}
	if updatedCookie == "" {
		_ = runner.Close()
		return markTerminal(E.New("TNCC returned an empty DSPREAUTH cookie"))
	}
	setNCCookie(a.jar, response.requestURL, "DSPREAUTH", updatedCookie)
	a.access.Lock()
	a.tnccAttempted = true
	a.tnccRunner = runner
	a.access.Unlock()
	return nil
}

func (a *ncAuthentication) sessionFromCookies(ctx context.Context, response ncHTTPResponse) (*ncSessionState, error) {
	dsid := ncCookieValue(a.jar, response.requestURL, "DSID")
	if dsid == "" {
		return nil, nil
	}
	a.access.Lock()
	runner := a.tnccRunner
	a.access.Unlock()
	if runner != nil {
		preauthenticationCookie := ncCookieValue(a.jar, response.requestURL, "DSPREAUTH")
		if preauthenticationCookie == "" {
			return nil, markTerminal(E.New("session obtained DSID without the TNCC DSPREAUTH cookie"))
		}
		err := runner.SetCookie(ctx, preauthenticationCookie)
		if err != nil {
			return nil, err
		}
	}
	if !response.address.IsValid() {
		return nil, markTerminal(E.New("authentication did not record the accepted gateway address"))
	}
	state := &ncSessionState{
		frontend:        a.frontend,
		serverURL:       cloneNCURL(response.requestURL),
		acceptedAddress: response.address,
		jar:             a.jar,
		dsid:            dsid,
		tnccRunner:      runner,
	}
	a.access.Lock()
	a.completed = true
	a.currentForm = nil
	a.tnccRunner = nil
	a.access.Unlock()
	a.transport.CloseIdleConnections()
	return state, nil
}

func (a *ncAuthentication) doAuthenticationRequest(
	ctx context.Context,
	method string,
	requestURL *url.URL,
	encodedForm string,
) (ncHTTPResponse, error) {
	a.access.Lock()
	a.requests++
	requestNumber := a.requests
	a.access.Unlock()
	if requestNumber > ncMaximumAuthenticationRequests {
		return ncHTTPResponse{}, markTerminal(E.New("authentication exceeded ", ncMaximumAuthenticationRequests, " wire requests"))
	}
	var body io.Reader
	if method == http.MethodPost {
		body = bytes.NewBufferString(encodedForm)
	}
	request, err := http.NewRequestWithContext(ctx, method, requestURL.String(), body)
	if err != nil {
		return ncHTTPResponse{}, markTerminal(E.Cause(err, "create Network Connect authentication request"))
	}
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", ncUserAgent(a.frontend.client))
	if method == http.MethodPost {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		paddingLength := 64*(1+len(encodedForm)/64) - len(encodedForm)
		request.Header.Set("X-Pad", strings.Repeat("0", paddingLength))
	}
	var acceptedAddress netip.Addr
	trace := &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			acceptedAddress = parseNCRemoteAddress(info.Conn.RemoteAddr())
		},
	}
	request = request.WithContext(httptrace.WithClientTrace(request.Context(), trace))
	response, err := a.httpClient.Do(request)
	if err != nil {
		requestErr := E.Cause(err, "send Network Connect authentication request")
		if response != nil && response.Body != nil {
			closeErr := response.Body.Close()
			requestErr = E.Append(requestErr, closeErr, func(cause error) error {
				return E.Cause(cause, "close failed Network Connect authentication response")
			})
		}
		return ncHTTPResponse{}, requestErr
	}
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, ncMaximumAuthenticationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return ncHTTPResponse{}, E.Errors(E.Cause(readErr, "read Network Connect authentication response"), closeErr)
	}
	if closeErr != nil {
		return ncHTTPResponse{}, E.Cause(closeErr, "close Network Connect authentication response")
	}
	if len(responseBody) > ncMaximumAuthenticationBody {
		return ncHTTPResponse{}, markTerminal(E.New("authentication response exceeds ", ncMaximumAuthenticationBody, " bytes"))
	}
	var peerCertificate *x509.Certificate
	if response.TLS != nil && len(response.TLS.PeerCertificates) > 0 {
		peerCertificate = response.TLS.PeerCertificates[0]
	}
	return ncHTTPResponse{
		statusCode:      response.StatusCode,
		header:          response.Header.Clone(),
		body:            responseBody,
		requestURL:      cloneNCURL(request.URL),
		address:         acceptedAddress,
		peerCertificate: peerCertificate,
	}, nil
}

func (a *ncAuthentication) recordHTTPResponse(response ncHTTPResponse) {
	a.access.Lock()
	a.currentURL = cloneNCURL(response.requestURL)
	if response.address.IsValid() {
		a.currentAddress = response.address
	}
	if response.peerCertificate != nil {
		a.currentCertificate = response.peerCertificate
	}
	a.access.Unlock()
}

func validateNCAuthenticationForm(form *ncAuthenticationForm) error {
	switch form.id {
	case "frmLogin", "loginForm", "frmDefender", "frmNextToken", "frmConfirmation", "frmSelectRoles", "frmTotpToken", "hiddenform", "formSAMLSSO":
		return nil
	default:
		if strings.Contains(form.action, "remediate.cgi") {
			return markTerminal(E.New("TNCC or Host Checker failed; remediation form returned by gateway"))
		}
		return markTerminal(E.New("unknown Network Connect authentication form: ", form.id))
	}
}

func (a *ncAuthentication) authenticationRequestFromForm(form *ncAuthenticationForm) *authenticationRequest {
	primaryForm := ncPrimaryAuthenticationForm(form)
	a.access.Lock()
	repeatedPrimary := a.primaryPasswordSent && primaryForm
	firstPrimary := !a.primaryPasswordSeen && primaryForm
	if firstPrimary {
		a.primaryPasswordSeen = true
	}
	a.currentFormPrimary = firstPrimary || repeatedPrimary
	a.access.Unlock()
	request := &authenticationRequest{
		FormID:  form.id,
		Banner:  form.banner,
		Message: form.message,
	}
	if repeatedPrimary {
		request.Error = "gateway rejected the primary credentials"
		request.ClearCacheKeys = []string{authCachePassword}
	}
	passwordNumber := 0
	tokenMessage := strings.TrimSpace(form.banner + " " + form.message)
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
		if (form.id == "frmLogin" || form.id == "loginForm") && field.kind == AuthFormFieldText && strings.EqualFold(field.name, "username") {
			requestField.CacheKey = authCacheUsername
		}
		if field.kind == AuthFormFieldPassword {
			passwordNumber++
			if (firstPrimary || repeatedPrimary) && passwordNumber == 1 {
				requestField.CacheKey = authCachePassword
			} else if ncTokenPasswordField(form.id, passwordNumber) && a.tokenGenerator.CanGenerate(tokenMessage) {
				requestField.Kind = authFormFieldToken
				generator := a.tokenGenerator
				requestField.Automatic = func(ctx context.Context) (string, error) {
					return generator.Generate(ctx, tokenMessage)
				}
			}
		}
		if form.id == "loginForm" && field.kind == AuthFormFieldText && field.name == "VerificationCode" && a.tokenGenerator.CanGenerate(tokenMessage) {
			requestField.Kind = authFormFieldToken
			generator := a.tokenGenerator
			requestField.Automatic = func(ctx context.Context) (string, error) {
				return generator.Generate(ctx, tokenMessage)
			}
		}
		if field.kind == AuthFormFieldSelect && (field.name == "realm" || form.roleForm) {
			requestField.CacheKey = authCacheAuthGroup
			a.normalizeConfiguredAuthGroup(&requestField)
		}
		request.Fields = append(request.Fields, requestField)
	}
	return request
}

func ncPrimaryAuthenticationForm(form *ncAuthenticationForm) bool {
	if form == nil || (form.id != "frmLogin" && form.id != "loginForm") {
		return false
	}
	for _, field := range form.fields {
		if field.kind == AuthFormFieldPassword {
			return true
		}
	}
	return false
}

func ncTokenPasswordField(formIdentifier string, passwordNumber int) bool {
	switch formIdentifier {
	case "frmLogin", "loginForm":
		return passwordNumber > 1
	case "frmDefender", "frmNextToken", "frmTotpToken":
		return true
	default:
		return false
	}
}

func (a *ncAuthentication) normalizeConfiguredAuthGroup(field *authenticationRequestField) {
	a.frontend.client.authChallengeAccess.Lock()
	configuredGroup := a.frontend.client.stableCredentials[authCacheAuthGroup]
	a.frontend.client.authChallengeAccess.Unlock()
	if configuredGroup == "" {
		return
	}
	for _, choice := range field.Options {
		if configuredGroup == choice.Value || configuredGroup == choice.Label {
			a.frontend.client.storeStableCredential(authCacheAuthGroup, choice.Value)
			return
		}
	}
	a.frontend.client.clearStableCredentials(authCacheAuthGroup)
}

func encodeNCAuthenticationResponse(form *ncAuthenticationForm, response *authenticationResponse) (string, error) {
	var encoded strings.Builder
	for fieldIndex, field := range form.fields {
		value, loaded := response.Values[field.submissionKey]
		if !loaded {
			return "", E.Extend(ErrProtocolNotSupported, "authentication response omitted field ", field.name)
		}
		if fieldIndex > 0 {
			encoded.WriteByte('&')
		}
		encoded.WriteString(encodeGPFormComponent(field.name))
		encoded.WriteByte('=')
		encoded.WriteString(encodeGPFormComponent(value))
	}
	return encoded.String(), nil
}

func classifyNCAuthenticationHTTPStatus(statusCode int) error {
	statusErr := E.New("authentication returned HTTP ", statusCode)
	if statusCode == http.StatusUnauthorized || statusCode == http.StatusForbidden {
		return newRetryableAuthenticationError(E.Errors(ErrAuthenticationFailed, statusErr), authCachePassword)
	}
	return markTerminal(statusErr)
}

func (s *ncSessionState) snapshot() ncSessionSnapshot {
	s.access.RLock()
	defer s.access.RUnlock()
	return ncSessionSnapshot{
		serverURL:       cloneNCURL(s.serverURL),
		acceptedAddress: s.acceptedAddress,
		jar:             s.jar,
		dsid:            s.dsid,
	}
}

func (s *ncSessionState) attachSession(session clientSession) error {
	s.access.Lock()
	defer s.access.Unlock()
	if s.dsid == "" || s.jar == nil {
		return ErrSessionRejected
	}
	if s.activeSession != nil && s.activeSession != session {
		return E.New("obtained session already owns an active tunnel")
	}
	s.activeSession = session
	return nil
}

func (s *ncSessionState) detachSession(session clientSession) {
	s.access.Lock()
	if s.activeSession == session {
		s.activeSession = nil
	}
	s.access.Unlock()
}

func (s *ncSessionState) tnccInterval() time.Duration {
	s.access.RLock()
	runner := s.tnccRunner
	s.access.RUnlock()
	if runner == nil {
		return 0
	}
	if s.frontend.client.options.TrojanInterval > 0 {
		return s.frontend.client.options.TrojanInterval
	}
	return runner.Interval()
}

func (s *ncSessionState) runPeriodicTNCC(ctx context.Context) error {
	s.access.RLock()
	runner := s.tnccRunner
	serverURL := cloneNCURL(s.serverURL)
	jar := s.jar
	s.access.RUnlock()
	if runner == nil {
		return nil
	}
	preauthenticationCookie := ncCookieValue(jar, serverURL, "DSPREAUTH")
	if preauthenticationCookie == "" {
		return markTerminal(E.New("periodic TNCC check has no DSPREAUTH cookie"))
	}
	return runner.SetCookie(ctx, preauthenticationCookie)
}

func (s *ncSessionState) Close() error {
	s.closeOnce.Do(func() {
		s.access.RLock()
		activeSession := s.activeSession
		s.access.RUnlock()
		if activeSession != nil {
			s.closeErr = activeSession.Close()
		}
		snapshot := s.snapshot()
		if snapshot.serverURL != nil && snapshot.acceptedAddress.IsValid() && snapshot.jar != nil && snapshot.dsid != "" {
			logoutContext, cancelLogout := context.WithTimeout(context.Background(), ncLogoutTimeout)
			logoutErr := s.frontend.logout(logoutContext, snapshot)
			cancelLogout()
			s.closeErr = E.Append(s.closeErr, logoutErr, func(cause error) error {
				return E.Cause(cause, "logout Network Connect session")
			})
		}
		s.access.Lock()
		runner := s.tnccRunner
		s.tnccRunner = nil
		s.jar = nil
		s.dsid = ""
		s.serverURL = nil
		s.acceptedAddress = netip.Addr{}
		s.activeSession = nil
		s.access.Unlock()
		if runner != nil {
			s.closeErr = E.Append(s.closeErr, runner.Close(), func(cause error) error {
				return E.Cause(cause, "close Network Connect TNCC runner")
			})
		}
	})
	return s.closeErr
}

// /tmp/openconnect/oncp.c:oncp_bye closes the live oNCP connection before issuing a fresh authenticated GET to /dana-na/auth/logout.cgi.
func (f *ncFrontend) logout(ctx context.Context, snapshot ncSessionSnapshot) error {
	logoutURL := cloneNCURL(snapshot.serverURL)
	logoutURL.Path = "/dana-na/auth/logout.cgi"
	logoutURL.RawPath = ""
	logoutURL.RawQuery = ""
	logoutURL.ForceQuery = false
	logoutURL.Fragment = ""
	logoutClient, transport, _, err := newNCPinnedHTTPClient(f.client, snapshot.serverURL, snapshot.acceptedAddress, snapshot.jar)
	if err != nil {
		return err
	}
	defer transport.CloseIdleConnections()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, logoutURL.String(), nil)
	if err != nil {
		return E.Cause(err, "create Network Connect logout request")
	}
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("User-Agent", ncUserAgent(f.client))
	response, err := logoutClient.Do(request)
	if err != nil {
		return E.Cause(err, "send Network Connect logout request")
	}
	readLength, readErr := io.Copy(io.Discard, io.LimitReader(response.Body, ncMaximumAuthenticationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		return E.Errors(E.Cause(readErr, "read Network Connect logout response"), closeErr)
	}
	if closeErr != nil {
		return E.Cause(closeErr, "close Network Connect logout response")
	}
	if readLength > ncMaximumAuthenticationBody {
		return E.New("logout response exceeds ", ncMaximumAuthenticationBody, " bytes")
	}
	if response.StatusCode != http.StatusOK {
		return E.New("logout returned HTTP ", response.StatusCode)
	}
	return nil
}

func newNCPinnedHTTPClient(
	client *Client,
	serverURL *url.URL,
	acceptedAddress netip.Addr,
	jar http.CookieJar,
) (*http.Client, *http.Transport, *pinnedHTTPPeer, error) {
	if serverURL == nil || jar == nil {
		return nil, nil, nil, E.New("accepted endpoint is incomplete")
	}
	expectedPort, err := ncURLPort(serverURL)
	if err != nil {
		return nil, nil, nil, err
	}
	return newPinnedHTTPClient(client, serverURL, acceptedAddress, jar, expectedPort, "Network Connect")
}

func cloneNCURL(serverURL *url.URL) *url.URL {
	if serverURL == nil {
		return nil
	}
	cloned := *serverURL
	return &cloned
}

func ncURLPort(serverURL *url.URL) (uint16, error) {
	if serverURL == nil {
		return 0, E.New("URL is missing")
	}
	portText := serverURL.Port()
	if portText == "" {
		return 443, nil
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 {
		return 0, E.New("URL has an invalid port")
	}
	return uint16(port), nil
}

func parseNCRemoteAddress(address net.Addr) netip.Addr {
	if address == nil {
		return netip.Addr{}
	}
	switch address.(type) {
	case *net.TCPAddr, *net.UDPAddr:
	default:
		_, _, err := net.SplitHostPort(address.String())
		if err != nil {
			return netip.Addr{}
		}
	}
	return M.SocksaddrFromNet(address).Addr.Unmap()
}

func ncUserAgent(client *Client) string {
	if client.options.UserAgent != "" {
		return client.options.UserAgent
	}
	return ncDefaultUserAgent
}
