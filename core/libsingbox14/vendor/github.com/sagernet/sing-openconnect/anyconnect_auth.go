package openconnect

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/xml"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptrace"
	"net/netip"
	"net/url"
	"strings"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/net/publicsuffix"
)

const anyConnectMaximumRedirects = 10

var errAnyConnectXMLPostFallback = E.New("XMLPOST probe requires legacy authentication fallback")

type anyConnectAuthenticationStage uint8

const (
	anyConnectAuthenticationInitialXML anyConnectAuthenticationStage = iota
	anyConnectAuthenticationInitialLegacy
	anyConnectAuthenticationAwaitGroup
	anyConnectAuthenticationAwaitSSOCompanion
	anyConnectAuthenticationAwaitSSOBrowser
	anyConnectAuthenticationAwaitForm
	anyConnectAuthenticationComplete
)

type anyConnectFrontend struct {
	client               *Client
	authenticationClient *http.Client
}

type anyConnectAuthentication struct {
	access                         sync.Mutex
	frontend                       *anyConnectFrontend
	initializationErr              error
	stage                          anyConnectAuthenticationStage
	xmlPost                        bool
	currentURL                     *url.URL
	currentForm                    anyConnectForm
	opaque                         *anyConnectOpaque
	hostScan                       anyConnectHostScan
	hostScanCompleted              bool
	authenticatedAddress           netip.Addr
	peerCertificate                *x509.Certificate
	selectedGroup                  string
	serverGroupSelection           string
	clientCertificateRetried       bool
	clientCertificateFailureCount  int
	clientCertificateFailureReason string
	primaryPasswordSubmitted       bool
	tokenGenerator                 *softwareTokenGenerator
	closed                         bool
	advancing                      bool
}

type anyConnectHTTPResponse struct {
	StatusCode           int
	Body                 []byte
	FinalURL             *url.URL
	AuthenticatedAddress netip.Addr
	PeerCertificate      *x509.Certificate
}

func init() {
	registerFlavorFrontend(FlavorAnyConnect, func(client *Client) (flavorFrontend, error) {
		return newAnyConnectFrontend(client)
	})
}

func newAnyConnectFrontend(client *Client) (*anyConnectFrontend, error) {
	if client.options.ReportedOS == "" {
		client.options.ReportedOS = defaultReportedOS()
	}
	switch client.options.ReportedOS {
	case "linux", "linux-64", "win", "mac-intel", "android", "apple-ios":
	default:
		return nil, E.New("unsupported AnyConnect reported OS: ", client.options.ReportedOS)
	}
	authenticationClient := &http.Client{
		Transport: client.wrapHTTPTransport(client.httpTransport),
		Jar:       client.httpClient.Jar,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return &anyConnectFrontend{
		client:               client,
		authenticationClient: authenticationClient,
	}, nil
}

func (f *anyConnectFrontend) BeginAuthentication() authContinuation {
	f.client.httpTransport.CloseIdleConnections()
	serverURL := *f.client.serverURL
	directCookie := f.client.takeDirectCookie()
	if directCookie != "" {
		_, values, directErr := newDirectCookieJar(&serverURL, directCookie, "webvpn")
		webVPNCookie := values["webvpn"]
		if directErr == nil && webVPNCookie == "" {
			directErr = E.New("direct cookie does not contain webvpn")
		}
		return &completedAuthentication{
			session: &anyConnectSessionState{
				ServerURL: &serverURL,
				Cookie:    webVPNCookie,
			},
			err: directErr,
		}
	}
	authenticationJar, err := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	if err == nil {
		f.authenticationClient.Jar = authenticationJar
	} else {
		err = E.Cause(err, "create AnyConnect authentication cookie jar")
	}
	authentication := &anyConnectAuthentication{
		frontend:          f,
		initializationErr: err,
		stage:             anyConnectAuthenticationInitialXML,
		xmlPost:           true,
		currentURL:        &serverURL,
		tokenGenerator:    newSoftwareTokenGenerator(f.client.options.Token),
	}
	if f.client.options.XMLPostDisabled {
		authentication.stage = anyConnectAuthenticationInitialLegacy
		authentication.xmlPost = false
	}
	return authentication
}

func (f *anyConnectFrontend) ConnectTunnel(ctx context.Context, obtained obtainedSession) (clientSession, error) {
	session, loaded := obtained.(*anyConnectSessionState)
	if !loaded || session == nil {
		return nil, E.Extend(ErrProtocolNotSupported, "invalid AnyConnect obtained session")
	}
	session.access.Lock()
	cookie := session.Cookie
	session.access.Unlock()
	if cookie == "" {
		return nil, ErrSessionRejected
	}
	transport, err := connectCSTP(ctx, f.client, session)
	if err != nil {
		return nil, err
	}
	return newAnyConnectCSTPSession(ctx, f.client, session, transport)
}

func (a *anyConnectAuthentication) Done() <-chan error {
	return nil
}

func (a *anyConnectAuthentication) Close() error {
	a.access.Lock()
	if a.closed {
		a.access.Unlock()
		return nil
	}
	a.closed = true
	for i := range a.currentForm.Fields {
		a.currentForm.Fields[i].Value = ""
	}
	a.access.Unlock()
	return nil
}

func (a *anyConnectAuthentication) Advance(
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
	if a.advancing {
		a.access.Unlock()
		return nil, nil, E.Extend(ErrProtocolNotSupported, "authentication continuation is already advancing")
	}
	a.advancing = true
	stage := a.stage
	a.access.Unlock()
	defer func() {
		a.access.Lock()
		a.advancing = false
		a.access.Unlock()
	}()
	switch stage {
	case anyConnectAuthenticationInitialXML:
		if response != nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "unexpected form response before AnyConnect XMLPOST initialization")
		}
		return a.advanceInitialXML(ctx)
	case anyConnectAuthenticationInitialLegacy:
		if response != nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "unexpected form response before legacy AnyConnect initialization")
		}
		return a.advanceInitialLegacy(ctx)
	case anyConnectAuthenticationAwaitGroup:
		if response == nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "missing AnyConnect authgroup response")
		}
		return a.advanceAuthGroup(ctx, response)
	case anyConnectAuthenticationAwaitSSOCompanion:
		if response == nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "missing AnyConnect SSO companion form response")
		}
		return a.advanceSSOCompanion(response)
	case anyConnectAuthenticationAwaitSSOBrowser:
		if response == nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "missing AnyConnect SSO browser response")
		}
		return a.advanceSSOBrowser(ctx, response)
	case anyConnectAuthenticationAwaitForm:
		if response == nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "missing AnyConnect authentication form response")
		}
		return a.advanceForm(ctx, response)
	case anyConnectAuthenticationComplete:
		return nil, nil, E.Extend(ErrProtocolNotSupported, "authentication continuation is already complete")
	default:
		return nil, nil, E.Extend(ErrProtocolNotSupported, "invalid AnyConnect authentication continuation stage")
	}
}

func (a *anyConnectAuthentication) advanceInitialXML(ctx context.Context) (obtainedSession, *authenticationRequest, error) {
	a.clearWebVPNCookie()
	a.selectedGroup = a.stableCredential(authCacheAuthGroup)
	body, err := buildAnyConnectInitialXML(a.frontend.client, a.currentURL, a.selectedGroup, false)
	if err != nil {
		return nil, nil, err
	}
	httpResponse, err := a.doAuthenticationRequest(ctx, http.MethodPost, a.currentURL, "application/xml; charset=utf-8", body, true)
	if err != nil {
		if E.IsMulti(err, errAnyConnectXMLPostFallback) {
			a.resetForLegacyAuthentication()
			return a.advanceInitialLegacy(ctx)
		}
		return nil, nil, err
	}
	if httpResponse.StatusCode != http.StatusOK {
		if httpResponse.StatusCode == http.StatusUnauthorized || httpResponse.StatusCode == http.StatusForbidden {
			return nil, nil, E.Errors(ErrAuthenticationFailed, E.New("XMLPOST initialization rejected with HTTP ", httpResponse.StatusCode))
		}
		a.resetForLegacyAuthentication()
		return a.advanceInitialLegacy(ctx)
	}
	form, err := parseAnyConnectAuthenticationXML(httpResponse.Body, reportedAnyConnectOS(a.frontend.client))
	if err != nil {
		a.resetForLegacyAuthentication()
		return a.advanceInitialLegacy(ctx)
	}
	a.recordHTTPResponse(httpResponse)
	return a.processAuthenticationForm(ctx, form)
}

func (a *anyConnectAuthentication) advanceInitialLegacy(ctx context.Context) (obtainedSession, *authenticationRequest, error) {
	httpResponse, err := a.doAuthenticationRequest(ctx, http.MethodGet, a.currentURL, "", nil, false)
	if err != nil {
		return nil, nil, err
	}
	if httpResponse.StatusCode != http.StatusOK {
		if httpResponse.StatusCode == http.StatusUnauthorized || httpResponse.StatusCode == http.StatusForbidden {
			return nil, nil, E.Errors(ErrAuthenticationFailed, E.New("legacy AnyConnect initialization rejected with HTTP ", httpResponse.StatusCode))
		}
		return nil, nil, anyConnectHTTPStatusError(httpResponse.StatusCode, "legacy AnyConnect authentication returned HTTP ")
	}
	form, err := parseAnyConnectAuthenticationXML(httpResponse.Body, reportedAnyConnectOS(a.frontend.client))
	if err != nil {
		return nil, nil, err
	}
	a.recordHTTPResponse(httpResponse)
	return a.processAuthenticationForm(ctx, form)
}

func (a *anyConnectAuthentication) advanceAuthGroup(
	ctx context.Context,
	response *authenticationResponse,
) (obtainedSession, *authenticationRequest, error) {
	groupField := findAnyConnectAuthGroup(&a.currentForm)
	if groupField == nil {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "authgroup response has no matching group_list field")
	}
	selectedGroup, loaded := response.Values[groupField.SubmissionKey]
	if !loaded {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "authgroup response omitted ", groupField.SubmissionKey)
	}
	selectedChoice, loaded := findAnyConnectChoice(groupField, selectedGroup)
	if !loaded {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "authgroup response selected an unknown choice: ", selectedGroup)
	}
	a.selectedGroup = selectedChoice.Name
	groupField.Value = selectedChoice.Name
	applyAnyConnectAuthGroup(&a.currentForm, selectedChoice.Name)
	if a.stageUsesXMLPost() && selectedChoice.Name != a.serverGroupSelection {
		a.stage = anyConnectAuthenticationInitialXML
		return a.advanceInitialXML(ctx)
	}
	return a.yieldAuthenticationRequest()
}

func (a *anyConnectAuthentication) advanceForm(
	ctx context.Context,
	response *authenticationResponse,
) (obtainedSession, *authenticationRequest, error) {
	err := a.applyAuthenticationFieldValues(response, false)
	if err != nil {
		return nil, nil, err
	}
	return a.submitAuthenticationForm(ctx)
}

func (a *anyConnectAuthentication) advanceSSOCompanion(response *authenticationResponse) (obtainedSession, *authenticationRequest, error) {
	err := a.applyAuthenticationFieldValues(response, true)
	if err != nil {
		return nil, nil, err
	}
	request, err := a.buildSSOBrowserRequest()
	if err != nil {
		return nil, nil, err
	}
	a.stage = anyConnectAuthenticationAwaitSSOBrowser
	return nil, request, nil
}

func (a *anyConnectAuthentication) advanceSSOBrowser(
	ctx context.Context,
	response *authenticationResponse,
) (obtainedSession, *authenticationRequest, error) {
	err := a.applySSOResponse(response.BrowserResult)
	if err != nil {
		return nil, nil, err
	}
	for i := range a.currentForm.Fields {
		field := &a.currentForm.Fields[i]
		if field.Ignore || field.Kind != anyConnectFormFieldToken {
			continue
		}
		value, loaded := response.Values[field.SubmissionKey]
		if !loaded {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "SSO response omitted generated token field: ", field.SubmissionKey)
		}
		field.Value = value
	}
	return a.submitAuthenticationForm(ctx)
}

func (a *anyConnectAuthentication) submitAuthenticationForm(ctx context.Context) (obtainedSession, *authenticationRequest, error) {
	for i := range a.currentForm.Fields {
		field := &a.currentForm.Fields[i]
		if field.Kind == anyConnectFormFieldPassword && field.StableCredential {
			a.primaryPasswordSubmitted = true
			break
		}
	}
	var body []byte
	var err error
	contentType := "application/x-www-form-urlencoded"
	if a.stageUsesXMLPost() {
		body, err = buildAnyConnectAuthenticationReplyXML(a.frontend.client, a.currentForm, a.opaque, a.hostScan.Token)
		contentType = "application/xml; charset=utf-8"
	} else {
		body, err = buildAnyConnectLegacyFormBody(a.currentForm)
	}
	if err != nil {
		return nil, nil, err
	}
	targetURL := cloneAnyConnectURL(a.currentURL)
	httpResponse, err := a.doAuthenticationRequest(ctx, http.MethodPost, targetURL, contentType, body, false)
	if err != nil {
		return nil, nil, err
	}
	if httpResponse.StatusCode != http.StatusOK {
		if httpResponse.StatusCode == http.StatusUnauthorized || httpResponse.StatusCode == http.StatusForbidden {
			return nil, nil, newRetryableAuthenticationError(
				E.New("authentication rejected with HTTP ", httpResponse.StatusCode),
				a.rejectedCredentialCacheKeys()...,
			)
		}
		return nil, nil, anyConnectHTTPStatusError(httpResponse.StatusCode, "authentication form returned HTTP ")
	}
	form, err := parseAnyConnectAuthenticationXML(httpResponse.Body, reportedAnyConnectOS(a.frontend.client))
	if err != nil {
		return nil, nil, err
	}
	a.recordHTTPResponse(httpResponse)
	return a.processAuthenticationForm(ctx, form)
}

func (a *anyConnectAuthentication) processAuthenticationForm(
	ctx context.Context,
	form anyConnectForm,
) (obtainedSession, *authenticationRequest, error) {
	reorderAnyConnectAuthGroup(&form)
	if form.Opaque != nil {
		a.opaque = form.Opaque
	}
	if !a.hostScanCompleted {
		mergeAnyConnectHostScan(&a.hostScan, form.HostScan)
	}
	// Upstream cstp_obtain_cookie retries CERT1 on a fresh TLS connection, then answers another request with client-cert-fail before considering legacy fallback.
	if form.ClientCertificateRequested && !form.ClientCertificateAuthenticated {
		configuredCertificate := a.frontend.client.configuredTLSClientCertificate()
		if configuredCertificate && !a.clientCertificateRetried {
			a.clientCertificateRetried = true
			a.frontend.client.httpTransport.CloseIdleConnections()
			a.stage = anyConnectAuthenticationInitialXML
			return a.advanceInitialXML(ctx)
		}
		if configuredCertificate {
			a.clientCertificateFailureReason = "gateway did not accept the configured TLS client certificate"
		} else {
			a.clientCertificateFailureReason = "gateway requested a TLS client certificate, but none was configured"
		}
		if !a.stageUsesXMLPost() {
			return nil, nil, E.Errors(ErrAuthenticationFailed, E.New(a.clientCertificateFailureReason))
		}
		if a.clientCertificateFailureCount >= 1 {
			a.resetForLegacyAuthentication()
			return a.advanceInitialLegacy(ctx)
		}
		a.clientCertificateFailureCount++
		return a.advanceClientCertificateFailure(ctx)
	}
	if form.MultipleCertificatesRequested {
		return a.handleMultipleCertificateRequest(ctx, form)
	}
	err := a.applyAuthenticationFormAction(&form)
	if err != nil {
		return nil, nil, err
	}
	if !a.hostScanCompleted && anyConnectHostScanRequested(a.hostScan) {
		err = a.runHostScan(ctx)
		if err != nil {
			return nil, nil, err
		}
		return a.refreshAfterHostScan(ctx)
	}
	if form.SessionToken != "" {
		a.setWebVPNCookie(form.SessionToken)
	}
	if form.AuthenticationComplete {
		return a.completeAuthentication(form.SessionToken)
	}
	rejectedCacheKeys := a.rejectedCredentialCacheKeys()
	a.currentForm = form
	// Upstream handle_auth_form treats authentication-complete as an empty automatic POST only when the form has no options.
	if form.PostAuthenticationComplete && len(form.Fields) == 0 {
		a.stage = anyConnectAuthenticationAwaitForm
		return a.advanceForm(ctx, &authenticationResponse{Values: map[string]string{}})
	}
	if len(form.Fields) == 0 {
		reason := form.Error
		if reason == "" {
			reason = form.Message
		}
		if reason == "" {
			reason = "gateway returned an empty authentication form"
		}
		return nil, nil, newRetryableAuthenticationError(
			E.New("authentication failed: ", reason),
			rejectedCacheKeys...,
		)
	}
	ocservOATHRound := false
	if a.primaryPasswordSubmitted {
		successorPassword := anyConnectOcservSuccessorPasswordField(&a.currentForm)
		if successorPassword != nil {
			ocservOATHRound = a.currentForm.Error == "" && anyConnectOcservOATHMessage(a.currentForm.Message)
			knownPasswordRejection := a.currentForm.Error != "" || anyConnectOcservPasswordRejectionMessage(a.currentForm.Message)
			if ocservOATHRound || !knownPasswordRejection {
				successorPassword.StableCredential = false
			}
			if !ocservOATHRound {
				a.frontend.client.clearStableCredentials(authCachePassword)
			}
		}
	}
	if a.tokenGenerator != nil {
		configureAnyConnectTokenField(
			&a.currentForm,
			a.frontend.client.options.Token.Mode,
			a.tokenGenerator.CanGenerate(form.Message),
			ocservOATHRound,
		)
	}
	groupField := findAnyConnectAuthGroup(&a.currentForm)
	if groupField != nil {
		a.serverGroupSelection = groupField.Value
		stableGroup := a.stableCredential(authCacheAuthGroup)
		if stableGroup != "" {
			choice, found := findAnyConnectChoice(groupField, stableGroup)
			if found {
				a.selectedGroup = choice.Name
				groupField.Value = choice.Name
				applyAnyConnectAuthGroup(&a.currentForm, choice.Name)
				if a.stageUsesXMLPost() && choice.Name != a.serverGroupSelection {
					a.stage = anyConnectAuthenticationInitialXML
					return a.advanceInitialXML(ctx)
				}
				return a.yieldAuthenticationRequest()
			}
		}
		request := buildAnyConnectAuthGroupRequest(a.currentForm, *groupField)
		a.stage = anyConnectAuthenticationAwaitGroup
		return nil, &request, nil
	}
	return a.yieldAuthenticationRequest()
}

func (a *anyConnectAuthentication) advanceClientCertificateFailure(ctx context.Context) (obtainedSession, *authenticationRequest, error) {
	body, err := buildAnyConnectInitialXML(a.frontend.client, a.currentURL, a.selectedGroup, true)
	if err != nil {
		return nil, nil, err
	}
	a.frontend.client.httpTransport.CloseIdleConnections()
	httpResponse, err := a.doAuthenticationRequest(ctx, http.MethodPost, a.currentURL, "application/xml; charset=utf-8", body, true)
	if err != nil {
		if E.IsMulti(err, errAnyConnectXMLPostFallback) {
			a.resetForLegacyAuthentication()
			return a.advanceInitialLegacy(ctx)
		}
		return nil, nil, err
	}
	if httpResponse.StatusCode != http.StatusOK {
		if httpResponse.StatusCode == http.StatusUnauthorized || httpResponse.StatusCode == http.StatusForbidden {
			return nil, nil, E.Errors(ErrAuthenticationFailed, E.New(a.clientCertificateFailureReason, "; failure marker returned HTTP ", httpResponse.StatusCode))
		}
		a.resetForLegacyAuthentication()
		return a.advanceInitialLegacy(ctx)
	}
	form, err := parseAnyConnectAuthenticationXML(httpResponse.Body, reportedAnyConnectOS(a.frontend.client))
	if err != nil {
		a.resetForLegacyAuthentication()
		return a.advanceInitialLegacy(ctx)
	}
	a.recordHTTPResponse(httpResponse)
	return a.processAuthenticationForm(ctx, form)
}

func (a *anyConnectAuthentication) yieldAuthenticationRequest() (obtainedSession, *authenticationRequest, error) {
	request, err := a.buildAuthenticationRequest()
	if err != nil {
		return nil, nil, err
	}
	if a.currentForm.SSO.Requested {
		if a.frontend.client.options.ExternalAuthDisabled {
			return nil, nil, markTerminal(E.Extend(ErrProtocolNotSupported, "gateway requested disabled external authentication"))
		}
		if len(request.Fields) == 0 {
			browserRequest, browserErr := a.buildSSOBrowserRequest()
			if browserErr != nil {
				return nil, nil, browserErr
			}
			a.stage = anyConnectAuthenticationAwaitSSOBrowser
			return nil, browserRequest, nil
		}
		a.stage = anyConnectAuthenticationAwaitSSOCompanion
		return nil, request, nil
	}
	a.stage = anyConnectAuthenticationAwaitForm
	return nil, request, nil
}

func (a *anyConnectAuthentication) buildAuthenticationRequest() (*authenticationRequest, error) {
	request := &authenticationRequest{
		FormID:  a.currentForm.AuthenticationID,
		Banner:  a.currentForm.Banner,
		Message: a.currentForm.Message,
		Error:   a.currentForm.Error,
	}
	for i := range a.currentForm.Fields {
		field := &a.currentForm.Fields[i]
		if field.Ignore {
			continue
		}
		if field.Kind == anyConnectFormFieldSSOToken {
			continue
		}
		if a.currentForm.SSO.Requested && field.Kind == anyConnectFormFieldToken {
			continue
		}
		requestField := authenticationRequestField{
			SubmissionKey: field.SubmissionKey,
			Name:          field.Name,
			Label:         field.Label,
			Value:         field.Value,
		}
		switch field.Kind {
		case anyConnectFormFieldText:
			requestField.Kind = AuthFormFieldText
			if field.StableCredential {
				requestField.CacheKey = authCacheUsername
			}
		case anyConnectFormFieldPassword:
			requestField.Kind = AuthFormFieldPassword
			if field.StableCredential {
				requestField.CacheKey = authCachePassword
			}
		case anyConnectFormFieldSelect:
			requestField.Kind = AuthFormFieldSelect
			for _, choice := range field.Choices {
				requestField.Options = append(requestField.Options, AuthFormChoice{Value: choice.Name, Label: choice.Label})
			}
			if field.Name == "group_list" {
				requestField.CacheKey = authCacheAuthGroup
			}
		case anyConnectFormFieldHidden:
			requestField.Kind = authFormFieldHidden
		case anyConnectFormFieldToken:
			if a.frontend.client.options.Token == nil {
				return nil, markTerminal(E.New("gateway requested an automatic token, but no TokenOptions were configured"))
			}
			requestField.Kind = authFormFieldToken
			tokenMessage := a.currentForm.Message
			requestField.Automatic = func(ctx context.Context) (string, error) {
				return a.generateSoftwareToken(ctx, tokenMessage)
			}
		default:
			return nil, E.Extend(ErrProtocolNotSupported, "unsupported AnyConnect authentication field kind: ", field.Kind)
		}
		if a.currentForm.Error != "" && requestField.CacheKey == authCachePassword {
			request.ClearCacheKeys = []string{authCachePassword}
		}
		request.Fields = append(request.Fields, requestField)
	}
	return request, nil
}

func (a *anyConnectAuthentication) generateSoftwareToken(ctx context.Context, message string) (string, error) {
	token, err := a.tokenGenerator.Generate(ctx, message)
	if err != nil {
		return "", markTerminal(E.Cause(err, "generate AnyConnect software token"))
	}
	return token, nil
}

func (a *anyConnectAuthentication) buildSSOBrowserRequest() (*authenticationRequest, error) {
	if strings.EqualFold(a.currentForm.SSO.BrowserMode, "external") {
		return nil, markTerminal(E.Extend(ErrProtocolNotSupported, "gateway requested AnyConnect external-browser SSO"))
	}
	if a.currentForm.SSO.LoginURL == "" {
		return nil, markTerminal(E.New("SSO form omitted sso-v2-login URL"))
	}
	if a.currentForm.SSO.FinalURL == "" {
		return nil, markTerminal(E.New("SSO form omitted sso-v2-login-final URL"))
	}
	if a.currentForm.SSO.TokenCookie == "" {
		return nil, markTerminal(E.New("SSO form omitted sso-v2-token-cookie-name"))
	}
	loginURL, err := url.Parse(a.currentForm.SSO.LoginURL)
	if err != nil {
		return nil, markTerminal(E.Cause(err, "parse AnyConnect SSO login URL"))
	}
	finalURL, err := url.Parse(a.currentForm.SSO.FinalURL)
	if err != nil {
		return nil, markTerminal(E.Cause(err, "parse AnyConnect SSO final URL"))
	}
	loginURL = a.currentURL.ResolveReference(loginURL)
	finalURL = a.currentURL.ResolveReference(finalURL)
	a.currentForm.SSO.LoginURL = loginURL.String()
	a.currentForm.SSO.FinalURL = finalURL.String()
	request := &authenticationRequest{
		FormID:  a.currentForm.AuthenticationID,
		Banner:  a.currentForm.Banner,
		Message: a.currentForm.Message,
		Error:   a.currentForm.Error,
		Browser: &BrowserRequest{
			URL:         a.currentForm.SSO.LoginURL,
			FinalURL:    a.currentForm.SSO.FinalURL,
			CookieNames: []string{a.currentForm.SSO.TokenCookie},
		},
	}
	if a.currentForm.SSO.ErrorCookie != "" {
		request.Browser.EarlyCookieNames = []string{a.currentForm.SSO.ErrorCookie}
	}
	for i := range a.currentForm.Fields {
		field := &a.currentForm.Fields[i]
		if field.Ignore || field.Kind != anyConnectFormFieldToken {
			continue
		}
		if a.frontend.client.options.Token == nil {
			return nil, markTerminal(E.New("SSO companion token requires TokenOptions"))
		}
		tokenMessage := a.currentForm.Message
		request.Fields = append(request.Fields, authenticationRequestField{
			SubmissionKey: field.SubmissionKey,
			Name:          field.Name,
			Label:         field.Label,
			Kind:          authFormFieldToken,
			Automatic: func(ctx context.Context) (string, error) {
				return a.generateSoftwareToken(ctx, tokenMessage)
			},
		})
	}
	return request, nil
}

func (a *anyConnectAuthentication) applyAuthenticationFieldValues(response *authenticationResponse, skipToken bool) error {
	for i := range a.currentForm.Fields {
		field := &a.currentForm.Fields[i]
		if field.Ignore || field.Kind == anyConnectFormFieldSSOToken {
			continue
		}
		if skipToken && field.Kind == anyConnectFormFieldToken {
			continue
		}
		value, loaded := response.Values[field.SubmissionKey]
		if !loaded {
			return E.Extend(ErrProtocolNotSupported, "authentication response omitted field: ", field.SubmissionKey)
		}
		if field.Kind == anyConnectFormFieldSelect {
			choice, found := findAnyConnectChoice(field, value)
			if !found {
				return E.Extend(ErrProtocolNotSupported, "authentication response selected an unknown choice for ", field.Name, ": ", value)
			}
			value = choice.Name
		}
		field.Value = value
	}
	return nil
}

// Upstream cstp_sso_detect_done captures the named non-empty token cookie when present, reports the error cookie immediately, and does not finish successfully until the browser reaches sso-v2-login-final.
func (a *anyConnectAuthentication) applySSOResponse(result *BrowserResult) error {
	if result == nil {
		return ErrInvalidBrowserAuthentication
	}
	for _, cookie := range result.Cookies {
		if cookie.Name == a.currentForm.SSO.ErrorCookie && cookie.Value != "" {
			return newRetryableAuthenticationError(E.New("SSO failed: ", cookie.Value))
		}
	}
	if a.currentForm.SSO.FinalURL != "" && result.FinalURL != a.currentForm.SSO.FinalURL {
		return E.Errors(ErrInvalidBrowserAuthentication, E.New("SSO browser did not reach the required final URL: ", a.currentForm.SSO.FinalURL))
	}
	var tokenValue string
	for _, cookie := range result.Cookies {
		if cookie.Name == a.currentForm.SSO.TokenCookie && cookie.Value != "" {
			tokenValue = cookie.Value
			break
		}
	}
	if tokenValue == "" {
		return E.Errors(ErrInvalidBrowserAuthentication, E.New("SSO browser result omitted the token cookie"))
	}
	for i := range a.currentForm.Fields {
		if a.currentForm.Fields[i].Kind == anyConnectFormFieldSSOToken {
			a.currentForm.Fields[i].Value = tokenValue
		}
	}
	return nil
}

func (a *anyConnectAuthentication) doAuthenticationRequest(
	ctx context.Context,
	method string,
	targetURL *url.URL,
	contentType string,
	body []byte,
	xmlPostProbe bool,
) (anyConnectHTTPResponse, error) {
	currentURL := cloneAnyConnectURL(targetURL)
	currentMethod := method
	currentContentType := contentType
	currentBody := append([]byte(nil), body...)
	maximumRequests := anyConnectMaximumRedirects
	if xmlPostProbe {
		maximumRequests = 3
	}
	for requestCount := 0; requestCount < maximumRequests; requestCount++ {
		request, err := http.NewRequestWithContext(ctx, currentMethod, currentURL.String(), bytes.NewReader(currentBody))
		if err != nil {
			return anyConnectHTTPResponse{}, markTerminal(E.Cause(err, "create AnyConnect authentication request"))
		}
		request.Header.Set("Accept", "*/*")
		request.Header.Set("Accept-Encoding", "identity")
		request.Header.Set("X-Transcend-Version", "1")
		if a.stageUsesXMLPost() {
			request.Header.Set("X-Aggregate-Auth", "1")
		}
		request.Header.Set("User-Agent", anyConnectUserAgent(a.frontend.client))
		if currentContentType != "" {
			request.Header.Set("Content-Type", currentContentType)
			paddingLength := 64*(1+len(currentBody)/64) - len(currentBody)
			request.Header.Set("X-Pad", strings.Repeat("0", paddingLength))
		}
		var authenticatedAddress netip.Addr
		var peerCertificate *x509.Certificate
		trace := &httptrace.ClientTrace{
			GotConn: func(info httptrace.GotConnInfo) {
				authenticatedAddress = parseAnyConnectRemoteAddress(info.Conn.RemoteAddr())
				tlsConnection, isTLS := info.Conn.(*tls.Conn)
				if isTLS {
					connectionState := tlsConnection.ConnectionState()
					if len(connectionState.PeerCertificates) > 0 {
						peerCertificate = connectionState.PeerCertificates[0]
					}
				}
			},
		}
		request = request.WithContext(httptrace.WithClientTrace(request.Context(), trace))
		response, err := a.frontend.authenticationClient.Do(request)
		if err != nil {
			return anyConnectHTTPResponse{}, E.Cause(err, "send AnyConnect authentication request")
		}
		responseBody, readErr := io.ReadAll(response.Body)
		closeErr := response.Body.Close()
		if readErr != nil {
			return anyConnectHTTPResponse{}, E.Errors(E.Cause(readErr, "read AnyConnect authentication response"), closeErr)
		}
		if closeErr != nil {
			return anyConnectHTTPResponse{}, E.Cause(closeErr, "close AnyConnect authentication response")
		}
		if !anyConnectRedirectStatus(response.StatusCode) || response.Header.Get("Location") == "" {
			return anyConnectHTTPResponse{
				StatusCode:           response.StatusCode,
				Body:                 responseBody,
				FinalURL:             cloneAnyConnectURL(currentURL),
				AuthenticatedAddress: authenticatedAddress,
				PeerCertificate:      peerCertificate,
			}, nil
		}
		location, err := currentURL.Parse(response.Header.Get("Location"))
		if err != nil {
			return anyConnectHTTPResponse{}, markTerminal(E.Cause(err, "parse AnyConnect authentication redirect"))
		}
		if location.Scheme != "https" || location.Hostname() == "" {
			return anyConnectHTTPResponse{}, markTerminal(E.New("authentication redirected to a non-HTTPS URL: ", location.String()))
		}
		sameEndpoint := equalAnyConnectURLHost(currentURL, location)
		if xmlPostProbe && sameEndpoint {
			return anyConnectHTTPResponse{}, errAnyConnectXMLPostFallback
		}
		if !sameEndpoint {
			// Upstream handle_redirect clears every authentication cookie when the HTTPS host or port changes.
			authenticationJar, jarErr := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
			if jarErr != nil {
				return anyConnectHTTPResponse{}, markTerminal(E.Cause(jarErr, "reset AnyConnect cookies after a cross-host redirect"))
			}
			a.frontend.authenticationClient.Jar = authenticationJar
			a.frontend.client.httpTransport.CloseIdleConnections()
		}
		currentURL = location
	}
	if xmlPostProbe {
		return anyConnectHTTPResponse{}, errAnyConnectXMLPostFallback
	}
	return anyConnectHTTPResponse{}, markTerminal(E.New("authentication exceeded ", maximumRequests, " redirect requests"))
}

func (a *anyConnectAuthentication) processAutomaticAuthenticationReply(
	ctx context.Context,
	body []byte,
	contentType string,
) (obtainedSession, *authenticationRequest, error) {
	targetURL := cloneAnyConnectURL(a.currentURL)
	httpResponse, err := a.doAuthenticationRequest(ctx, http.MethodPost, targetURL, contentType, body, false)
	if err != nil {
		return nil, nil, err
	}
	if httpResponse.StatusCode != http.StatusOK {
		return nil, nil, anyConnectHTTPStatusError(httpResponse.StatusCode, "automatic authentication reply returned HTTP ")
	}
	form, err := parseAnyConnectAuthenticationXML(httpResponse.Body, reportedAnyConnectOS(a.frontend.client))
	if err != nil {
		return nil, nil, err
	}
	a.recordHTTPResponse(httpResponse)
	return a.processAuthenticationForm(ctx, form)
}

func (a *anyConnectAuthentication) refreshAfterHostScan(ctx context.Context) (obtainedSession, *authenticationRequest, error) {
	body, err := buildAnyConnectInitialXML(a.frontend.client, a.currentURL, a.selectedGroup, false)
	if err != nil {
		return nil, nil, err
	}
	method := http.MethodGet
	contentType := ""
	if a.stageUsesXMLPost() {
		method = http.MethodPost
		contentType = "application/xml; charset=utf-8"
	} else {
		body = nil
	}
	httpResponse, err := a.doAuthenticationRequest(ctx, method, a.currentURL, contentType, body, false)
	if err != nil {
		return nil, nil, err
	}
	if httpResponse.StatusCode != http.StatusOK {
		return nil, nil, anyConnectHTTPStatusError(httpResponse.StatusCode, "post-hostscan refresh returned HTTP ")
	}
	form, err := parseAnyConnectAuthenticationXML(httpResponse.Body, reportedAnyConnectOS(a.frontend.client))
	if err != nil {
		return nil, nil, err
	}
	a.recordHTTPResponse(httpResponse)
	return a.processAuthenticationForm(ctx, form)
}

func (a *anyConnectAuthentication) completeAuthentication(sessionToken string) (obtainedSession, *authenticationRequest, error) {
	if sessionToken != "" {
		a.setWebVPNCookie(sessionToken)
	}
	cookie := a.webVPNCookie()
	if cookie == "" {
		return nil, nil, markTerminal(E.New("authentication succeeded without a webvpn cookie"))
	}
	a.stage = anyConnectAuthenticationComplete
	for i := range a.currentForm.Fields {
		a.currentForm.Fields[i].Value = ""
	}
	serverURL := cloneAnyConnectURL(a.currentURL)
	return &anyConnectSessionState{
		ServerURL:            serverURL,
		AuthenticatedAddress: a.authenticatedAddress,
		Cookie:               cookie,
	}, nil, nil
}

// Upstream cstp_obtain_cookie applies form->action after CERT1/CERT2 processing and before CSD, successful completion, or user form handling.
func (a *anyConnectAuthentication) applyAuthenticationFormAction(form *anyConnectForm) error {
	if form.Action == "" {
		return nil
	}
	targetURL, err := a.resolveAuthenticationURL(form.Action)
	if err != nil {
		return err
	}
	if !equalAnyConnectURLHost(a.currentURL, targetURL) {
		authenticationJar, jarErr := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
		if jarErr != nil {
			return markTerminal(E.Cause(jarErr, "reset AnyConnect cookies for a cross-host form action"))
		}
		a.frontend.authenticationClient.Jar = authenticationJar
		a.frontend.client.httpClient.Jar = authenticationJar
		a.frontend.client.httpTransport.CloseIdleConnections()
		a.authenticatedAddress = netip.Addr{}
		a.peerCertificate = nil
	}
	a.currentURL = targetURL
	form.Action = targetURL.String()
	return nil
}

func (a *anyConnectAuthentication) resolveAuthenticationURL(reference string) (*url.URL, error) {
	referenceURL, err := url.Parse(reference)
	if err != nil {
		return nil, markTerminal(E.Cause(err, "parse AnyConnect authentication form action"))
	}
	resolved := a.currentURL.ResolveReference(referenceURL)
	if resolved.Scheme != "https" || resolved.Hostname() == "" {
		return nil, markTerminal(E.New("authentication form action is not HTTPS: ", resolved.String()))
	}
	return resolved, nil
}

func (a *anyConnectAuthentication) recordHTTPResponse(response anyConnectHTTPResponse) {
	a.currentURL = cloneAnyConnectURL(response.FinalURL)
	if response.AuthenticatedAddress.IsValid() {
		a.authenticatedAddress = response.AuthenticatedAddress
	}
	if response.PeerCertificate != nil {
		a.peerCertificate = response.PeerCertificate
	}
}

func (a *anyConnectAuthentication) stableCredential(key string) string {
	a.frontend.client.authChallengeAccess.Lock()
	value := a.frontend.client.stableCredentials[key]
	a.frontend.client.authChallengeAccess.Unlock()
	return value
}

func (a *anyConnectAuthentication) rejectedCredentialCacheKeys() []string {
	for i := range a.currentForm.Fields {
		field := &a.currentForm.Fields[i]
		if field.Kind == anyConnectFormFieldPassword && field.StableCredential {
			return []string{authCachePassword}
		}
	}
	return nil
}

func (a *anyConnectAuthentication) clearWebVPNCookie() {
	a.frontend.authenticationClient.Jar.SetCookies(a.currentURL, []*http.Cookie{{
		Name:     "webvpn",
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		Expires:  time.Unix(1, 0),
		Secure:   true,
		HttpOnly: true,
	}})
}

func (a *anyConnectAuthentication) setWebVPNCookie(value string) {
	a.frontend.authenticationClient.Jar.SetCookies(a.currentURL, []*http.Cookie{{
		Name:     "webvpn",
		Value:    value,
		Path:     "/",
		Secure:   true,
		HttpOnly: true,
	}})
}

func (a *anyConnectAuthentication) webVPNCookie() string {
	for _, cookie := range a.frontend.authenticationClient.Jar.Cookies(a.currentURL) {
		if cookie.Name == "webvpn" && cookie.Value != "" {
			return cookie.Value
		}
	}
	return ""
}

func (a *anyConnectAuthentication) resetForLegacyAuthentication() {
	serverURL := *a.frontend.client.serverURL
	a.currentURL = &serverURL
	a.stage = anyConnectAuthenticationInitialLegacy
	a.xmlPost = false
	a.opaque = nil
	a.hostScan = anyConnectHostScan{}
	a.hostScanCompleted = false
	a.authenticatedAddress = netip.Addr{}
	a.peerCertificate = nil
	a.clientCertificateRetried = false
	a.clientCertificateFailureCount = 0
	a.clientCertificateFailureReason = ""
	a.primaryPasswordSubmitted = false
	a.frontend.client.httpTransport.CloseIdleConnections()
}

func (a *anyConnectAuthentication) stageUsesXMLPost() bool {
	return a.xmlPost
}

func (a *anyConnectAuthentication) handleMultipleCertificateRequest(
	ctx context.Context,
	form anyConnectForm,
) (obtainedSession, *authenticationRequest, error) {
	if a.frontend.client.mcaIdentity == nil {
		return nil, nil, E.Errors(ErrAuthenticationFailed, E.New("gateway requested multiple-certificate authentication, but no MCA identity was configured"))
	}
	form.Opaque = a.opaque
	body, err := buildAnyConnectMCAResponse(a.frontend.client, a.frontend.client.mcaIdentity, form)
	if err != nil {
		return nil, nil, markTerminal(err)
	}
	return a.processAutomaticAuthenticationReply(ctx, body, "application/xml; charset=utf-8")
}

func anyConnectHTTPStatusError(statusCode int, message string) error {
	err := E.New(message, statusCode)
	if anyConnectRetryableHTTPStatus(statusCode) {
		return err
	}
	return markTerminal(err)
}

func anyConnectRetryableHTTPStatus(statusCode int) bool {
	switch statusCode {
	case http.StatusRequestTimeout, http.StatusTooEarly, http.StatusTooManyRequests:
		return true
	default:
		return statusCode >= http.StatusInternalServerError && statusCode <= 599
	}
}

func buildAnyConnectAuthGroupRequest(form anyConnectForm, field anyConnectFormField) authenticationRequest {
	options := make([]AuthFormChoice, 0, len(field.Choices))
	for _, choice := range field.Choices {
		options = append(options, AuthFormChoice{Value: choice.Name, Label: choice.Label})
	}
	return authenticationRequest{
		FormID:  form.AuthenticationID,
		Banner:  form.Banner,
		Message: form.Message,
		Error:   form.Error,
		Fields: []authenticationRequestField{{
			SubmissionKey: field.SubmissionKey,
			Name:          field.Name,
			Label:         field.Label,
			Kind:          AuthFormFieldSelect,
			Value:         field.Value,
			Options:       options,
			CacheKey:      authCacheAuthGroup,
		}},
	}
}

func findAnyConnectAuthGroup(form *anyConnectForm) *anyConnectFormField {
	for i := range form.Fields {
		if form.Fields[i].Name == "group_list" && form.Fields[i].Kind == anyConnectFormFieldSelect {
			return &form.Fields[i]
		}
	}
	return nil
}

func findAnyConnectChoice(field *anyConnectFormField, value string) (anyConnectFormChoice, bool) {
	for _, choice := range field.Choices {
		if choice.Name == value || choice.Label == value {
			return choice, true
		}
	}
	return anyConnectFormChoice{}, false
}

func anyConnectHostScanRequested(state anyConnectHostScan) bool {
	return state.Token != "" && state.Ticket != "" && state.BaseURL != "" && state.WaitURL != ""
}

func mergeAnyConnectHostScan(destination *anyConnectHostScan, source anyConnectHostScan) {
	if source.Ticket != "" {
		destination.Ticket = source.Ticket
	}
	if source.Token != "" {
		destination.Token = source.Token
	}
	if source.BaseURL != "" {
		destination.BaseURL = source.BaseURL
	}
	if source.WaitURL != "" {
		destination.WaitURL = source.WaitURL
	}
	if source.StubURL != "" {
		destination.StubURL = source.StubURL
	}
}

func reportedAnyConnectOS(client *Client) string {
	if client.options.ReportedOS != "" {
		return client.options.ReportedOS
	}
	return defaultReportedOS()
}

func anyConnectUserAgent(client *Client) string {
	if client.options.UserAgent != "" {
		return client.options.UserAgent
	}
	return "AnyConnect-compatible OpenConnect VPN Agent " + defaultClientVersion
}

func parseAnyConnectRemoteAddress(address net.Addr) netip.Addr {
	if address == nil {
		return netip.Addr{}
	}
	host, _, err := net.SplitHostPort(address.String())
	if err != nil {
		return netip.Addr{}
	}
	parsed, parseErr := netip.ParseAddr(strings.Trim(host, "[]"))
	if parseErr != nil {
		return netip.Addr{}
	}
	return parsed.Unmap()
}

func anyConnectRedirectStatus(statusCode int) bool {
	return statusCode == http.StatusMovedPermanently ||
		statusCode == http.StatusFound ||
		statusCode == http.StatusSeeOther ||
		statusCode == http.StatusTemporaryRedirect ||
		statusCode == http.StatusPermanentRedirect
}

func equalAnyConnectURLHost(left *url.URL, right *url.URL) bool {
	return strings.EqualFold(left.Hostname(), right.Hostname()) && effectiveAnyConnectURLPort(left) == effectiveAnyConnectURLPort(right)
}

func effectiveAnyConnectURLPort(value *url.URL) string {
	if value.Port() != "" {
		return value.Port()
	}
	return "443"
}

func cloneAnyConnectURL(value *url.URL) *url.URL {
	if value == nil {
		return nil
	}
	cloned := *value
	return &cloned
}

// Upstream xmlpost_initial_req emits config-auth init with version, device-id, capabilities, group-access, optional client-cert-fail, and group-select.
func buildAnyConnectInitialXML(
	client *Client,
	serverURL *url.URL,
	authGroup string,
	clientCertificateFailure bool,
) ([]byte, error) {
	var content bytes.Buffer
	content.WriteString(xml.Header)
	encoder := xml.NewEncoder(&content)
	root := xml.StartElement{
		Name: xml.Name{Local: "config-auth"},
		Attr: []xml.Attr{
			{Name: xml.Name{Local: "client"}, Value: "vpn"},
			{Name: xml.Name{Local: "type"}, Value: "init"},
			{Name: xml.Name{Local: "aggregate-auth-version"}, Value: "2"},
		},
	}
	err := encoder.EncodeToken(root)
	if err != nil {
		return nil, E.Cause(err, "encode AnyConnect XMLPOST root")
	}
	err = encodeAnyConnectVersionAndDevice(encoder, client)
	if err != nil {
		return nil, err
	}
	err = encodeAnyConnectCapabilities(encoder, client)
	if err != nil {
		return nil, err
	}
	groupAccessURL := cloneAnyConnectURL(serverURL)
	if groupAccessURL.Path == "" {
		groupAccessURL.Path = "/"
	}
	err = encodeAnyConnectTextElement(encoder, "group-access", groupAccessURL.String(), nil)
	if err != nil {
		return nil, err
	}
	if clientCertificateFailure {
		err = encodeAnyConnectTextElement(encoder, "client-cert-fail", "", nil)
		if err != nil {
			return nil, err
		}
	}
	if authGroup != "" {
		err = encodeAnyConnectTextElement(encoder, "group-select", authGroup, nil)
		if err != nil {
			return nil, err
		}
	}
	err = encoder.EncodeToken(root.End())
	if err != nil {
		return nil, E.Cause(err, "close AnyConnect XMLPOST root")
	}
	err = encoder.Flush()
	if err != nil {
		return nil, E.Cause(err, "flush AnyConnect XMLPOST initialization")
	}
	return content.Bytes(), nil
}

// Upstream xmlpost_append_form_opts echoes opaque, places normal fields under auth, moves group_list to group-select, renames answer/whichpin/new_password, and omits verification fields.
func buildAnyConnectAuthenticationReplyXML(
	client *Client,
	form anyConnectForm,
	opaque *anyConnectOpaque,
	hostScanToken string,
) ([]byte, error) {
	var content bytes.Buffer
	content.WriteString(xml.Header)
	encoder := xml.NewEncoder(&content)
	root := xml.StartElement{
		Name: xml.Name{Local: "config-auth"},
		Attr: []xml.Attr{
			{Name: xml.Name{Local: "client"}, Value: "vpn"},
			{Name: xml.Name{Local: "type"}, Value: "auth-reply"},
			{Name: xml.Name{Local: "aggregate-auth-version"}, Value: "2"},
		},
	}
	err := encoder.EncodeToken(root)
	if err != nil {
		return nil, E.Cause(err, "encode AnyConnect auth-reply root")
	}
	err = encodeAnyConnectVersionAndDevice(encoder, client)
	if err != nil {
		return nil, err
	}
	err = encodeAnyConnectCapabilities(encoder, client)
	if err != nil {
		return nil, err
	}
	if opaque != nil {
		err = encoder.Encode(opaque)
		if err != nil {
			return nil, E.Cause(err, "echo AnyConnect opaque authentication state")
		}
	}
	authentication := xml.StartElement{Name: xml.Name{Local: "auth"}}
	err = encoder.EncodeToken(authentication)
	if err != nil {
		return nil, E.Cause(err, "encode AnyConnect auth-reply fields")
	}
	var selectedGroup string
	for _, field := range form.Fields {
		if field.Name == "group_list" {
			selectedGroup = field.Value
			continue
		}
		name := field.Name
		switch name {
		case "answer", "whichpin", "new_password":
			name = "password"
		case "verify_pin", "verify_password":
			continue
		}
		err = encodeAnyConnectTextElement(encoder, name, field.Value, nil)
		if err != nil {
			return nil, err
		}
	}
	err = encoder.EncodeToken(authentication.End())
	if err != nil {
		return nil, E.Cause(err, "close AnyConnect auth-reply fields")
	}
	if selectedGroup != "" {
		err = encodeAnyConnectTextElement(encoder, "group-select", selectedGroup, nil)
		if err != nil {
			return nil, err
		}
	}
	if hostScanToken != "" {
		err = encodeAnyConnectTextElement(encoder, "host-scan-token", hostScanToken, nil)
		if err != nil {
			return nil, err
		}
	}
	err = encoder.EncodeToken(root.End())
	if err != nil {
		return nil, E.Cause(err, "close AnyConnect auth-reply root")
	}
	err = encoder.Flush()
	if err != nil {
		return nil, E.Cause(err, "flush AnyConnect auth-reply XML")
	}
	return content.Bytes(), nil
}

// Upstream append_form_opts preserves field-instance order and duplicate wire names, while buf_append_urlencoded percent-encodes every byte outside the RFC 3986 unreserved set.
func buildAnyConnectLegacyFormBody(form anyConnectForm) ([]byte, error) {
	var content strings.Builder
	for _, field := range form.Fields {
		if content.Len() > 0 {
			content.WriteByte('&')
		}
		appendAnyConnectURLEncoded(&content, field.Name)
		content.WriteByte('=')
		appendAnyConnectURLEncoded(&content, field.Value)
	}
	return []byte(content.String()), nil
}

func appendAnyConnectURLEncoded(content *strings.Builder, value string) {
	const hexadecimal = "0123456789abcdef"
	for i := 0; i < len(value); i++ {
		character := value[i]
		if character >= 'a' && character <= 'z' ||
			character >= 'A' && character <= 'Z' ||
			character >= '0' && character <= '9' ||
			character == '-' || character == '_' || character == '.' || character == '~' {
			content.WriteByte(character)
			continue
		}
		content.WriteByte('%')
		content.WriteByte(hexadecimal[character>>4])
		content.WriteByte(hexadecimal[character&0x0f])
	}
}

func encodeAnyConnectVersionAndDevice(encoder *xml.Encoder, client *Client) error {
	err := encodeAnyConnectTextElement(encoder, "version", client.options.Version, []xml.Attr{{Name: xml.Name{Local: "who"}, Value: "vpn"}})
	if err != nil {
		return err
	}
	var attributes []xml.Attr
	if client.options.Mobile != nil {
		attributes = []xml.Attr{
			{Name: xml.Name{Local: "platform-version"}, Value: client.options.Mobile.PlatformVersion},
			{Name: xml.Name{Local: "device-type"}, Value: client.options.Mobile.DeviceType},
			{Name: xml.Name{Local: "unique-id"}, Value: client.options.Mobile.DeviceUniqueID},
		}
	}
	return encodeAnyConnectTextElement(encoder, "device-id", reportedAnyConnectOS(client), attributes)
}

func encodeAnyConnectCapabilities(encoder *xml.Encoder, client *Client) error {
	capabilities := xml.StartElement{Name: xml.Name{Local: "capabilities"}}
	err := encoder.EncodeToken(capabilities)
	if err != nil {
		return E.Cause(err, "encode AnyConnect authentication capabilities")
	}
	if !client.options.ExternalAuthDisabled {
		err = encodeAnyConnectTextElement(encoder, "auth-method", "single-sign-on-v2", nil)
		if err != nil {
			return err
		}
	}
	if client.mcaIdentity != nil {
		err = encodeAnyConnectTextElement(encoder, "auth-method", "multiple-cert", nil)
		if err != nil {
			return err
		}
	}
	err = encoder.EncodeToken(capabilities.End())
	if err != nil {
		return E.Cause(err, "close AnyConnect authentication capabilities")
	}
	return nil
}

func encodeAnyConnectTextElement(encoder *xml.Encoder, name string, value string, attributes []xml.Attr) error {
	start := xml.StartElement{Name: xml.Name{Local: name}, Attr: attributes}
	err := encoder.EncodeToken(start)
	if err != nil {
		return E.Cause(err, "encode AnyConnect XML element: ", name)
	}
	if value != "" {
		err = encoder.EncodeToken(xml.CharData(value))
		if err != nil {
			return E.Cause(err, "encode AnyConnect XML value: ", name)
		}
	}
	err = encoder.EncodeToken(start.End())
	if err != nil {
		return E.Cause(err, "close AnyConnect XML element: ", name)
	}
	return nil
}
