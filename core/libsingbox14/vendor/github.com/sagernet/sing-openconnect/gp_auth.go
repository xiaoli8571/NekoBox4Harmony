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
	M "github.com/sagernet/sing/common/metadata"

	"golang.org/x/net/publicsuffix"
)

const (
	gpMaximumAuthenticationBody      = 16 * 1024 * 1024
	gpMaximumAuthenticationRequests  = 64
	gpMaximumAuthenticationRedirects = 10
	gpLogoutTimeout                  = 5 * time.Second
	gpUserAgent                      = "PAN GlobalProtect"
	gpUsernameSubmissionKey          = "gp:user"
	gpSecretSubmissionKey            = "gp:secret"
	gpGatewaySubmissionKey           = "gp:gateway"
)

type gpInterface uint8

const (
	gpInterfacePortal gpInterface = iota
	gpInterfaceGateway
)

type gpAuthenticationStage uint8

const (
	gpAuthenticationPrelogin gpAuthenticationStage = iota
	gpAuthenticationAwaitLogin
	gpAuthenticationAwaitSAML
	gpAuthenticationAwaitGateway
	gpAuthenticationComplete
)

type gpFrontend struct {
	client               *Client
	authenticationClient *http.Client
	localHostname        string
	previousIPv4         netip.Addr
	previousIPv6         netip.Addr
}

type gpAuthentication struct {
	access                       sync.Mutex
	frontend                     *gpFrontend
	initializationErr            error
	stage                        gpAuthenticationStage
	currentInterface             gpInterface
	automaticInterface           bool
	currentURL                   *url.URL
	alternateSecret              string
	currentForm                  gpLoginForm
	region                       string
	username                     string
	portalUserAuthCookie         string
	portalPrelogonUserAuthCookie string
	hipReportInterval            time.Duration
	clientVersion                string
	gatewayChoices               []gpPortalGateway
	blindGatewayLogin            bool
	authenticatedAddress         netip.Addr
	previousIPv4                 netip.Addr
	previousIPv6                 netip.Addr
	tokenGenerator               *softwareTokenGenerator
	requests                     int
	closed                       bool
	advancing                    bool
}

type gpLoginForm struct {
	formID         string
	message        string
	errorMessage   string
	usernameLabel  string
	usernameValue  string
	usernameHidden bool
	secretName     string
	secretLabel    string
	secretKind     string
	secretValue    string
	secretHidden   bool
	inputString    string
	challenge      bool
	usedSAML       bool
	clearPassword  bool
}

type gpHTTPResponse struct {
	statusCode           int
	body                 []byte
	finalURL             *url.URL
	authenticatedAddress netip.Addr
}

type gpFormParameter struct {
	name  string
	value string
}

type gpSessionState struct {
	access               sync.RWMutex
	frontend             *gpFrontend
	serverURL            *url.URL
	authenticatedAddress netip.Addr
	opaqueQuery          string
	hipReportInterval    time.Duration
	clientVersion        string
	previousIPv4         netip.Addr
	previousIPv6         netip.Addr
	closeOnce            sync.Once
	closeErr             error
}

type gpSessionSnapshot struct {
	serverURL            *url.URL
	authenticatedAddress netip.Addr
	opaqueQuery          string
	hipReportInterval    time.Duration
	clientVersion        string
	previousIPv4         netip.Addr
	previousIPv6         netip.Addr
}

func init() {
	registerFlavorFrontend(FlavorGP, func(client *Client) (flavorFrontend, error) {
		return newGPFrontend(client)
	})
}

func newGPFrontend(client *Client) (*gpFrontend, error) {
	if client.options.ReportedOS == "" {
		client.options.ReportedOS = defaultReportedOS()
	}
	switch client.options.ReportedOS {
	case "linux", "linux-64", "win", "mac-intel", "android", "apple-ios":
	default:
		return nil, E.New("unsupported GlobalProtect reported OS: ", client.options.ReportedOS)
	}
	authenticationClient := &http.Client{
		Transport: client.wrapHTTPTransport(client.httpTransport),
		Jar:       client.httpClient.Jar,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return &gpFrontend{
		client:               client,
		authenticationClient: authenticationClient,
		localHostname:        client.options.LocalHostname,
	}, nil
}

func (f *gpFrontend) BeginAuthentication() authContinuation {
	f.client.httpTransport.CloseIdleConnections()
	serverURL := cloneGPURL(f.client.serverURL)
	currentInterface, automaticInterface, alternateSecret, parseErr := parseGPServerTarget(serverURL)
	if parseErr == nil {
		serverURL.Path = ""
		serverURL.RawPath = ""
		serverURL.RawQuery = ""
		serverURL.Fragment = ""
		directCookie := f.client.takeDirectCookie()
		if directCookie != "" {
			return &completedAuthentication{session: &gpSessionState{
				frontend:      f,
				serverURL:     serverURL,
				opaqueQuery:   directCookie,
				clientVersion: gpDefaultClientVersion,
				previousIPv4:  f.previousIPv4,
				previousIPv6:  f.previousIPv6,
			}}
		}
		parseErr = f.resetAuthenticationJar()
	}
	previousIPv4 := f.previousIPv4
	previousIPv6 := f.previousIPv6
	return &gpAuthentication{
		frontend:           f,
		initializationErr:  parseErr,
		stage:              gpAuthenticationPrelogin,
		currentInterface:   currentInterface,
		automaticInterface: automaticInterface,
		currentURL:         serverURL,
		alternateSecret:    alternateSecret,
		previousIPv4:       previousIPv4,
		previousIPv6:       previousIPv6,
		tokenGenerator:     newSoftwareTokenGenerator(f.client.options.Token),
	}
}

func (f *gpFrontend) ConnectTunnel(ctx context.Context, obtained obtainedSession) (clientSession, error) {
	session, loaded := obtained.(*gpSessionState)
	if !loaded || session == nil {
		return nil, E.Extend(ErrProtocolNotSupported, "invalid GlobalProtect obtained session")
	}
	snapshot := session.snapshot()
	if session.frontend != f || snapshot.serverURL == nil || snapshot.opaqueQuery == "" {
		return nil, ErrSessionRejected
	}
	return newGPSession(ctx, f.client, session, snapshot), nil
}

func (f *gpFrontend) resetAuthenticationJar() error {
	authenticationJar, err := cookiejar.New(&cookiejar.Options{PublicSuffixList: publicsuffix.List})
	if err != nil {
		return E.Cause(err, "create GlobalProtect authentication cookie jar")
	}
	f.authenticationClient.Jar = authenticationJar
	f.client.httpClient.Jar = authenticationJar
	return nil
}

func (a *gpAuthentication) Done() <-chan error {
	return nil
}

func (a *gpAuthentication) Close() error {
	a.access.Lock()
	if a.closed {
		a.access.Unlock()
		return nil
	}
	a.closed = true
	a.alternateSecret = ""
	a.portalUserAuthCookie = ""
	a.portalPrelogonUserAuthCookie = ""
	a.currentForm.secretValue = ""
	a.currentForm.inputString = ""
	a.access.Unlock()
	return nil
}

func (a *gpAuthentication) Advance(
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
	case gpAuthenticationPrelogin:
		if response != nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "unexpected form response before GlobalProtect prelogin")
		}
		return a.advancePrelogin(ctx)
	case gpAuthenticationAwaitLogin:
		if response == nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "missing GlobalProtect login form response")
		}
		return a.advanceLogin(ctx, response)
	case gpAuthenticationAwaitSAML:
		if response == nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "missing GlobalProtect SAML browser response")
		}
		return a.advanceSAML(ctx, response)
	case gpAuthenticationAwaitGateway:
		if response == nil {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "missing GlobalProtect gateway selection response")
		}
		return a.advanceGatewaySelection(ctx, response)
	case gpAuthenticationComplete:
		return nil, nil, E.Extend(ErrProtocolNotSupported, "authentication continuation is already complete")
	default:
		return nil, nil, E.Extend(ErrProtocolNotSupported, "invalid GlobalProtect authentication continuation stage")
	}
}

func (a *gpAuthentication) advancePrelogin(ctx context.Context) (obtainedSession, *authenticationRequest, error) {
	interfacePath := "global-protect"
	if a.currentInterface == gpInterfaceGateway {
		interfacePath = "ssl-vpn"
	}
	preloginURL := cloneGPURL(a.currentURL)
	preloginURL.Path = "/" + interfacePath + "/prelogin.esp"
	preloginURL.RawQuery = "tmp=tmp&clientVer=4100&clientos=" + encodeGPFormComponent(reportedGPOS(a.frontend.client))
	var form []gpFormParameter
	if !a.frontend.client.options.ExternalAuthDisabled {
		form = []gpFormParameter{{name: "cas-support", value: "yes"}}
	}
	httpResponse, err := a.doAuthenticationRequest(ctx, preloginURL, form, true)
	if err != nil {
		return nil, nil, err
	}
	if httpResponse.statusCode == http.StatusNotFound && a.automaticInterface && a.currentInterface == gpInterfacePortal {
		a.currentInterface = gpInterfaceGateway
		return a.advancePrelogin(ctx)
	}
	if httpResponse.statusCode != http.StatusOK {
		return nil, nil, gpHTTPStatusError(httpResponse.statusCode, "prelogin returned HTTP ")
	}
	prelogin, err := parseGPPreloginResponse(httpResponse.body)
	if err != nil {
		if E.IsMulti(err, errGPInterfaceNotFound) && a.automaticInterface && a.currentInterface == gpInterfacePortal {
			a.currentInterface = gpInterfaceGateway
			return a.advancePrelogin(ctx)
		}
		if E.IsMulti(err, errGPInterfaceNotFound) && a.automaticInterface {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "server is neither a GlobalProtect portal nor a gateway")
		}
		return nil, nil, err
	}
	a.recordHTTPResponse(httpResponse)
	a.region = prelogin.region
	a.currentForm = a.buildLoginForm(prelogin)
	if prelogin.samlMethod != "" || prelogin.samlRequest != "" {
		if a.frontend.client.options.ExternalAuthDisabled {
			return nil, nil, markTerminal(E.Extend(ErrProtocolNotSupported, "gateway requested disabled external authentication"))
		}
		if prelogin.samlMethod == "" || prelogin.samlRequest == "" {
			return nil, nil, E.Extend(ErrProtocolNotSupported, "prelogin returned incomplete SAML parameters")
		}
		return a.processSAMLPrelogin(prelogin)
	}
	a.stage = gpAuthenticationAwaitLogin
	return nil, a.buildLoginRequest(), nil
}

func (a *gpAuthentication) processSAMLPrelogin(prelogin gpPreloginForm) (obtainedSession, *authenticationRequest, error) {
	a.currentForm.usedSAML = true
	if a.alternateSecret != "" {
		a.currentForm.secretLabel = a.alternateSecret
		a.stage = gpAuthenticationAwaitLogin
		return nil, a.buildLoginRequest(), nil
	}
	browserURL, err := decodeGPSAMLURL(prelogin.samlMethod, prelogin.samlRequest)
	if err != nil {
		return nil, nil, err
	}
	a.stage = gpAuthenticationAwaitSAML
	return nil, &authenticationRequest{
		FormID:  gpAuthenticationFormID,
		Message: a.currentForm.message,
		Browser: &BrowserRequest{
			URL:         browserURL,
			HeaderNames: []string{"saml-username", "prelogin-cookie", "portal-userauthcookie"},
		},
	}, nil
}

func (a *gpAuthentication) advanceSAML(
	ctx context.Context,
	response *authenticationResponse,
) (obtainedSession, *authenticationRequest, error) {
	if response.BrowserResult == nil {
		return nil, nil, ErrInvalidBrowserAuthentication
	}
	username := gpBrowserHeader(response.BrowserResult.Header, "saml-username")
	secretName := "prelogin-cookie"
	secretValue := gpBrowserHeader(response.BrowserResult.Header, secretName)
	if secretValue == "" {
		secretName = "portal-userauthcookie"
		secretValue = gpBrowserHeader(response.BrowserResult.Header, secretName)
	}
	if username == "" || secretValue == "" {
		return nil, nil, E.Errors(ErrInvalidBrowserAuthentication, E.New("SAML browser result omitted saml-username or authentication cookie headers"))
	}
	a.currentForm.usernameValue = username
	a.currentForm.secretName = secretName
	a.currentForm.secretValue = secretValue
	a.currentForm.secretHidden = true
	return a.submitLogin(ctx)
}

func (a *gpAuthentication) advanceLogin(
	ctx context.Context,
	response *authenticationResponse,
) (obtainedSession, *authenticationRequest, error) {
	username, usernameLoaded := response.Values[gpUsernameSubmissionKey]
	if !usernameLoaded {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "login response omitted username")
	}
	secret, secretLoaded := response.Values[gpSecretSubmissionKey]
	if !secretLoaded {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "login response omitted secret")
	}
	a.currentForm.usernameValue = username
	a.currentForm.secretValue = secret
	return a.submitLogin(ctx)
}

func (a *gpAuthentication) submitLogin(ctx context.Context) (obtainedSession, *authenticationRequest, error) {
	form := a.buildLoginValues()
	loginURL := cloneGPURL(a.currentURL)
	if a.currentInterface == gpInterfacePortal {
		loginURL.Path = "/global-protect/getconfig.esp"
	} else {
		loginURL.Path = "/ssl-vpn/login.esp"
	}
	loginURL.RawQuery = ""
	httpResponse, err := a.doAuthenticationRequest(ctx, loginURL, form, false)
	if err != nil {
		return nil, nil, err
	}
	if httpResponse.statusCode == 512 {
		return a.handleRejectedLogin(ctx, strings.TrimSpace(string(httpResponse.body)))
	}
	if httpResponse.statusCode != http.StatusOK {
		return nil, nil, gpHTTPStatusError(httpResponse.statusCode, "login returned HTTP ")
	}
	a.recordHTTPResponse(httpResponse)
	if a.currentInterface == gpInterfacePortal {
		return a.processPortalLogin(ctx, httpResponse.body)
	}
	return a.processGatewayLogin(httpResponse.body)
}

func (a *gpAuthentication) processPortalLogin(
	ctx context.Context,
	responseBody []byte,
) (obtainedSession, *authenticationRequest, error) {
	configuration, challenge, err := parseGPPortalConfiguration(responseBody, a.region)
	if err != nil {
		return nil, nil, err
	}
	if challenge != nil {
		a.applyChallenge(*challenge)
		a.stage = gpAuthenticationAwaitLogin
		return nil, a.buildLoginRequest(), nil
	}
	a.username = a.currentForm.usernameValue
	a.portalUserAuthCookie = configuration.portalUserAuthCookie
	a.portalPrelogonUserAuthCookie = configuration.portalPrelogonUserAuthCookie
	a.hipReportInterval = configuration.hipReportInterval
	a.clientVersion = configuration.clientVersion
	a.gatewayChoices = append([]gpPortalGateway(nil), configuration.gateways...)
	a.blindGatewayLogin = a.portalUserAuthCookie != "" || a.portalPrelogonUserAuthCookie != "" ||
		(!a.currentForm.challenge && !a.currentForm.usedSAML && a.alternateSecret == "")
	return a.selectConfiguredGateway(ctx)
}

func (a *gpAuthentication) processGatewayLogin(responseBody []byte) (obtainedSession, *authenticationRequest, error) {
	opaqueQuery, challenge, err := parseGPLoginResponse(responseBody, a.frontend.localHostname)
	if err != nil {
		return nil, nil, err
	}
	if challenge != nil {
		a.applyChallenge(*challenge)
		a.stage = gpAuthenticationAwaitLogin
		return nil, a.buildLoginRequest(), nil
	}
	a.username = a.currentForm.usernameValue
	a.stage = gpAuthenticationComplete
	a.currentForm.secretValue = ""
	a.currentForm.inputString = ""
	a.portalUserAuthCookie = ""
	a.portalPrelogonUserAuthCookie = ""
	clientVersion := a.clientVersion
	if clientVersion == "" {
		clientVersion = gpDefaultClientVersion
	}
	return &gpSessionState{
		frontend:             a.frontend,
		serverURL:            cloneGPURL(a.currentURL),
		authenticatedAddress: a.authenticatedAddress,
		opaqueQuery:          opaqueQuery,
		hipReportInterval:    a.hipReportInterval,
		clientVersion:        clientVersion,
		previousIPv4:         a.previousIPv4,
		previousIPv6:         a.previousIPv6,
	}, nil, nil
}

func (a *gpAuthentication) handleRejectedLogin(
	ctx context.Context,
	message string,
) (obtainedSession, *authenticationRequest, error) {
	if message == "" {
		message = "Invalid username or password"
	}
	a.currentForm.secretValue = ""
	a.currentForm.errorMessage = message
	a.currentForm.clearPassword = a.currentForm.secretKind == AuthFormFieldPassword && !a.currentForm.challenge
	if a.blindGatewayLogin {
		a.blindGatewayLogin = false
		a.frontend.client.clearStableCredentials(authCachePassword)
		a.stage = gpAuthenticationPrelogin
		return a.advancePrelogin(ctx)
	}
	a.stage = gpAuthenticationAwaitLogin
	return nil, a.buildLoginRequest(), nil
}

func (a *gpAuthentication) selectConfiguredGateway(ctx context.Context) (obtainedSession, *authenticationRequest, error) {
	if len(a.gatewayChoices) == 1 {
		return a.selectGateway(ctx, a.gatewayChoices[0])
	}
	configuredGroup := a.stableCredential(authCacheAuthGroup)
	for _, gateway := range a.gatewayChoices {
		if configuredGroup == gateway.name || configuredGroup == gateway.label || configuredGroup == gateway.formValue {
			a.frontend.client.storeStableCredential(authCacheAuthGroup, gateway.formValue)
			return a.selectGateway(ctx, gateway)
		}
	}
	if configuredGroup != "" {
		a.frontend.client.clearStableCredentials(authCacheAuthGroup)
	}
	a.stage = gpAuthenticationAwaitGateway
	options := make([]AuthFormChoice, 0, len(a.gatewayChoices))
	for _, gateway := range a.gatewayChoices {
		options = append(options, AuthFormChoice{Value: gateway.formValue, Label: gateway.label})
	}
	return nil, &authenticationRequest{
		FormID:  gpPortalFormID,
		Message: "Please select GlobalProtect gateway.",
		Fields: []authenticationRequestField{{
			SubmissionKey: gpGatewaySubmissionKey,
			Name:          "gateway",
			Label:         "GATEWAY:",
			Kind:          AuthFormFieldSelect,
			Value:         a.gatewayChoices[0].formValue,
			Options:       options,
			CacheKey:      authCacheAuthGroup,
		}},
	}, nil
}

func (a *gpAuthentication) advanceGatewaySelection(
	ctx context.Context,
	response *authenticationResponse,
) (obtainedSession, *authenticationRequest, error) {
	selection, loaded := response.Values[gpGatewaySubmissionKey]
	if !loaded {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "gateway selection response omitted gateway")
	}
	for _, gateway := range a.gatewayChoices {
		if gateway.formValue == selection {
			return a.selectGateway(ctx, gateway)
		}
	}
	return nil, nil, E.Extend(ErrProtocolNotSupported, "gateway selection returned an unknown gateway")
}

func (a *gpAuthentication) selectGateway(
	ctx context.Context,
	gateway gpPortalGateway,
) (obtainedSession, *authenticationRequest, error) {
	gatewayURL, err := url.Parse("https://" + gateway.name)
	if err != nil {
		return nil, nil, E.Cause(err, "parse GlobalProtect gateway endpoint")
	}
	err = validateHTTPSRequestURL(gatewayURL)
	if err != nil {
		return nil, nil, err
	}
	if gatewayURL.Path != "" || gatewayURL.RawQuery != "" || gatewayURL.Fragment != "" {
		return nil, nil, E.New("portal returned a gateway endpoint with an unsupported path, query, or fragment: ", gateway.name)
	}
	if !equalGPEndpoint(a.currentURL, gatewayURL) {
		err = a.frontend.resetAuthenticationJar()
		if err != nil {
			return nil, nil, err
		}
		a.frontend.client.httpTransport.CloseIdleConnections()
		a.authenticatedAddress = netip.Addr{}
	}
	a.currentURL = gatewayURL
	a.currentInterface = gpInterfaceGateway
	if a.blindGatewayLogin {
		return a.submitLogin(ctx)
	}
	a.stage = gpAuthenticationPrelogin
	return a.advancePrelogin(ctx)
}

func (a *gpAuthentication) buildLoginForm(prelogin gpPreloginForm) gpLoginForm {
	message := prelogin.message
	if message == "" {
		message = "Please enter your username and password"
	}
	usernameLabel := prelogin.usernameLabel
	if usernameLabel == "" {
		usernameLabel = "Username"
	}
	secretName := a.alternateSecret
	if secretName == "" {
		secretName = "passwd"
	}
	secretLabel := prelogin.passwordLabel
	if secretLabel == "" {
		secretLabel = "Password"
	}
	secretKind := AuthFormFieldPassword
	if a.alternateSecret == "" && prelogin.passwordLabel != "" && prelogin.passwordLabel != "Password" && a.tokenGenerator.CanGenerate(message) {
		secretKind = authFormFieldToken
	}
	return gpLoginForm{
		formID:         gpAuthenticationFormID,
		message:        message,
		usernameLabel:  usernameLabel,
		usernameValue:  a.username,
		usernameHidden: a.username != "",
		secretName:     secretName,
		secretLabel:    secretLabel,
		secretKind:     secretKind,
	}
}

func (a *gpAuthentication) buildLoginRequest() *authenticationRequest {
	usernameKind := AuthFormFieldText
	usernameCacheKey := authCacheUsername
	if a.currentForm.usernameHidden {
		usernameKind = authFormFieldHidden
		usernameCacheKey = ""
	}
	secretKind := a.currentForm.secretKind
	secretCacheKey := ""
	if a.currentForm.secretHidden {
		secretKind = authFormFieldHidden
	} else if secretKind == AuthFormFieldPassword && !a.currentForm.challenge {
		secretCacheKey = authCachePassword
	}
	request := &authenticationRequest{
		FormID:  a.currentForm.formID,
		Message: a.currentForm.message,
		Error:   a.currentForm.errorMessage,
		Fields: []authenticationRequestField{
			{
				SubmissionKey: gpUsernameSubmissionKey,
				Name:          "user",
				Label:         a.currentForm.usernameLabel,
				Kind:          usernameKind,
				Value:         a.currentForm.usernameValue,
				CacheKey:      usernameCacheKey,
			},
			{
				SubmissionKey: gpSecretSubmissionKey,
				Name:          a.currentForm.secretName,
				Label:         a.currentForm.secretLabel,
				Kind:          secretKind,
				Value:         a.currentForm.secretValue,
				CacheKey:      secretCacheKey,
			},
		},
	}
	if a.currentForm.clearPassword {
		request.ClearCacheKeys = []string{authCachePassword}
		a.currentForm.clearPassword = false
	}
	if secretKind == authFormFieldToken {
		tokenMessage := a.currentForm.message
		request.Fields[1].Automatic = func(ctx context.Context) (string, error) {
			token, err := a.tokenGenerator.Generate(ctx, tokenMessage)
			if err != nil {
				return "", markTerminal(E.Cause(err, "generate GlobalProtect software token"))
			}
			return token, nil
		}
	}
	return request
}

func (a *gpAuthentication) buildLoginValues() []gpFormParameter {
	ipv6Support := "yes"
	if a.frontend.client.options.IPv6Disabled {
		ipv6Support = "no"
	}
	values := []gpFormParameter{
		{name: "jnlpReady", value: "jnlpReady"},
		{name: "ok", value: "Login"},
		{name: "direct", value: "yes"},
		{name: "clientVer", value: "4100"},
		{name: "prot", value: "https:"},
		{name: "internal", value: "no"},
		{name: "ipv6-support", value: ipv6Support},
		{name: "clientos", value: reportedGPOS(a.frontend.client)},
		{name: "os-version", value: a.frontend.client.options.ReportedOS},
		{name: "server", value: a.currentURL.Hostname()},
		{name: "computer", value: a.frontend.localHostname},
	}
	if a.portalUserAuthCookie != "" {
		values = append(values, gpFormParameter{name: "portal-userauthcookie", value: a.portalUserAuthCookie})
	}
	if a.portalPrelogonUserAuthCookie != "" {
		values = append(values, gpFormParameter{name: "portal-prelogonuserauthcookie", value: a.portalPrelogonUserAuthCookie})
	}
	if a.previousIPv4.IsValid() {
		values = append(values, gpFormParameter{name: "preferred-ip", value: a.previousIPv4.String()})
	}
	if !a.frontend.client.options.IPv6Disabled && a.previousIPv6.IsValid() {
		values = append(values, gpFormParameter{name: "preferred-ipv6", value: a.previousIPv6.String()})
	}
	if a.currentForm.inputString != "" {
		values = append(values, gpFormParameter{name: "inputStr", value: a.currentForm.inputString})
	}
	values = append(values,
		gpFormParameter{name: "user", value: a.currentForm.usernameValue},
		gpFormParameter{name: a.currentForm.secretName, value: a.currentForm.secretValue},
	)
	return values
}

func (a *gpAuthentication) applyChallenge(challenge gpChallenge) {
	previousSecretKind := a.currentForm.secretKind
	a.currentForm.formID = gpChallengeFormID
	a.currentForm.message = challenge.message
	a.currentForm.errorMessage = ""
	a.currentForm.usernameHidden = true
	a.currentForm.secretLabel = "Challenge:"
	a.currentForm.secretValue = ""
	a.currentForm.secretHidden = false
	a.currentForm.inputString = challenge.inputString
	a.currentForm.challenge = true
	a.currentForm.clearPassword = false
	if previousSecretKind == AuthFormFieldPassword && a.tokenGenerator.CanGenerate(challenge.message) {
		a.currentForm.secretKind = authFormFieldToken
	} else {
		a.currentForm.secretKind = AuthFormFieldPassword
	}
}

func (a *gpAuthentication) doAuthenticationRequest(
	ctx context.Context,
	targetURL *url.URL,
	form []gpFormParameter,
	followRedirects bool,
) (gpHTTPResponse, error) {
	currentURL := cloneGPURL(targetURL)
	var encodedForm strings.Builder
	for i, parameter := range form {
		if i > 0 {
			encodedForm.WriteByte('&')
		}
		encodedForm.WriteString(encodeGPFormComponent(parameter.name))
		encodedForm.WriteByte('=')
		encodedForm.WriteString(encodeGPFormComponent(parameter.value))
	}
	formBody := encodedForm.String()
	maximumRequests := 1
	if followRedirects {
		maximumRequests = gpMaximumAuthenticationRedirects
	}
	for requestIndex := 0; requestIndex < maximumRequests; requestIndex++ {
		a.requests++
		if a.requests > gpMaximumAuthenticationRequests {
			return gpHTTPResponse{}, markTerminal(E.New("authentication exceeded ", gpMaximumAuthenticationRequests, " wire requests"))
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodPost, currentURL.String(), bytes.NewBufferString(formBody))
		if err != nil {
			return gpHTTPResponse{}, markTerminal(E.Cause(err, "create GlobalProtect authentication request"))
		}
		request.Header.Set("Accept", "*/*")
		request.Header.Set("Accept-Encoding", "identity")
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		userAgent := gpUserAgent
		if a.frontend.client.options.UserAgent != "" {
			userAgent = a.frontend.client.options.UserAgent
		}
		request.Header.Set("User-Agent", userAgent)
		var authenticatedAddress netip.Addr
		trace := &httptrace.ClientTrace{
			GotConn: func(info httptrace.GotConnInfo) {
				authenticatedAddress = parseGPRemoteAddress(info.Conn.RemoteAddr())
			},
		}
		request = request.WithContext(httptrace.WithClientTrace(request.Context(), trace))
		response, err := a.frontend.authenticationClient.Do(request)
		if err != nil {
			requestErr := E.Cause(err, "send GlobalProtect authentication request")
			if response != nil && response.Body != nil {
				closeErr := response.Body.Close()
				if closeErr != nil {
					requestErr = E.Errors(requestErr, E.Cause(closeErr, "close failed GlobalProtect authentication response"))
				}
			}
			return gpHTTPResponse{}, requestErr
		}
		responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, gpMaximumAuthenticationBody+1))
		closeErr := response.Body.Close()
		if readErr != nil {
			readResponseErr := E.Cause(readErr, "read GlobalProtect authentication response")
			if closeErr != nil {
				readResponseErr = E.Errors(readResponseErr, E.Cause(closeErr, "close failed GlobalProtect authentication response"))
			}
			return gpHTTPResponse{}, readResponseErr
		}
		if closeErr != nil {
			return gpHTTPResponse{}, E.Cause(closeErr, "close GlobalProtect authentication response")
		}
		if len(responseBody) > gpMaximumAuthenticationBody {
			return gpHTTPResponse{}, markTerminal(E.New("authentication response exceeds ", gpMaximumAuthenticationBody, " bytes"))
		}
		locationHeader := response.Header.Get("Location")
		if !followRedirects || !gpRedirectStatus(response.StatusCode) || locationHeader == "" {
			return gpHTTPResponse{
				statusCode:           response.StatusCode,
				body:                 responseBody,
				finalURL:             cloneGPURL(currentURL),
				authenticatedAddress: authenticatedAddress,
			}, nil
		}
		location, err := currentURL.Parse(locationHeader)
		if err != nil {
			return gpHTTPResponse{}, markTerminal(E.Cause(err, "parse GlobalProtect authentication redirect"))
		}
		err = validateHTTPSRequestURL(location)
		if err != nil {
			return gpHTTPResponse{}, markTerminal(err)
		}
		if !equalGPEndpoint(currentURL, location) {
			err = a.frontend.resetAuthenticationJar()
			if err != nil {
				return gpHTTPResponse{}, markTerminal(err)
			}
			a.frontend.client.httpTransport.CloseIdleConnections()
			a.authenticatedAddress = netip.Addr{}
		}
		currentURL = location
	}
	return gpHTTPResponse{}, markTerminal(E.New("authentication exceeded ", maximumRequests, " redirect requests"))
}

func (a *gpAuthentication) recordHTTPResponse(response gpHTTPResponse) {
	if response.finalURL != nil && !equalGPEndpoint(a.currentURL, response.finalURL) {
		a.currentURL.Scheme = response.finalURL.Scheme
		a.currentURL.Host = response.finalURL.Host
	}
	if response.authenticatedAddress.IsValid() {
		a.authenticatedAddress = response.authenticatedAddress
	}
}

func (a *gpAuthentication) stableCredential(key string) string {
	a.frontend.client.authChallengeAccess.Lock()
	value := a.frontend.client.stableCredentials[key]
	a.frontend.client.authChallengeAccess.Unlock()
	return value
}

func (s *gpSessionState) snapshot() gpSessionSnapshot {
	s.access.RLock()
	defer s.access.RUnlock()
	return gpSessionSnapshot{
		serverURL:            cloneGPURL(s.serverURL),
		authenticatedAddress: s.authenticatedAddress,
		opaqueQuery:          s.opaqueQuery,
		hipReportInterval:    s.hipReportInterval,
		clientVersion:        s.clientVersion,
		previousIPv4:         s.previousIPv4,
		previousIPv6:         s.previousIPv6,
	}
}

func (s *gpSessionState) Close() error {
	s.closeOnce.Do(func() {
		snapshot := s.snapshot()
		if snapshot.serverURL != nil && snapshot.opaqueQuery != "" && snapshot.authenticatedAddress.IsValid() {
			ctx, cancel := context.WithTimeout(context.Background(), gpLogoutTimeout)
			s.closeErr = s.frontend.logout(ctx, snapshot)
			cancel()
		}
		s.access.Lock()
		s.opaqueQuery = ""
		s.access.Unlock()
	})
	return s.closeErr
}

// Upstream gpst_bye sends the complete authenticated query because logout validation includes otherwise redundant portal, user, computer, and domain values.
func (f *gpFrontend) logout(ctx context.Context, snapshot gpSessionSnapshot) error {
	if !snapshot.authenticatedAddress.IsValid() {
		return E.New("logout requires the authenticated gateway address")
	}
	logoutURL := cloneGPURL(snapshot.serverURL)
	logoutURL.Path = "/ssl-vpn/logout.esp"
	logoutURL.RawPath = ""
	logoutURL.RawQuery = ""
	f.client.httpTransport.CloseIdleConnections()
	transport := f.client.httpTransport.Clone()
	defer transport.CloseIdleConnections()
	gatewayHostname := logoutURL.Hostname()
	gatewayPort := effectiveGPPort(logoutURL)
	transport.DialContext = func(dialContext context.Context, network string, address string) (net.Conn, error) {
		destinationHostname, destinationPort, splitErr := net.SplitHostPort(address)
		if splitErr != nil {
			return nil, E.Cause(splitErr, "parse GlobalProtect logout destination")
		}
		if !strings.EqualFold(destinationHostname, gatewayHostname) || destinationPort != gatewayPort {
			return nil, E.New("logout attempted to dial outside the authenticated gateway endpoint")
		}
		parsedPort, parseErr := strconv.ParseUint(destinationPort, 10, 16)
		if parseErr != nil || parsedPort == 0 {
			return nil, E.New("logout attempted to dial an invalid gateway port")
		}
		destination := M.ParseSocksaddrHostPort(snapshot.authenticatedAddress.String(), uint16(parsedPort))
		return f.client.options.Dialer.DialContext(dialContext, network, destination)
	}
	logoutClient := &http.Client{
		Transport: f.client.wrapHTTPTransport(transport),
		Jar:       f.authenticationClient.Jar,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, logoutURL.String(), strings.NewReader(snapshot.opaqueQuery))
	if err != nil {
		return E.Cause(err, "create GlobalProtect logout request")
	}
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Encoding", "identity")
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	userAgent := gpUserAgent
	if f.client.options.UserAgent != "" {
		userAgent = f.client.options.UserAgent
	}
	request.Header.Set("User-Agent", userAgent)
	response, err := logoutClient.Do(request)
	if err != nil {
		requestErr := E.Cause(err, "send GlobalProtect logout request")
		if response != nil && response.Body != nil {
			closeResponseErr := response.Body.Close()
			if closeResponseErr != nil {
				requestErr = E.Errors(requestErr, E.Cause(closeResponseErr, "close failed GlobalProtect logout response"))
			}
		}
		return requestErr
	}
	responseBody, readErr := io.ReadAll(io.LimitReader(response.Body, gpMaximumAuthenticationBody+1))
	closeErr := response.Body.Close()
	if readErr != nil {
		readResponseErr := E.Cause(readErr, "read GlobalProtect logout response")
		if closeErr != nil {
			readResponseErr = E.Errors(readResponseErr, E.Cause(closeErr, "close failed GlobalProtect logout response"))
		}
		return readResponseErr
	}
	if closeErr != nil {
		return E.Cause(closeErr, "close GlobalProtect logout response")
	}
	if len(responseBody) > gpMaximumAuthenticationBody {
		return E.New("logout response exceeds ", gpMaximumAuthenticationBody, " bytes")
	}
	if response.StatusCode != http.StatusOK {
		return E.New("logout returned HTTP ", response.StatusCode)
	}
	return parseGPLogoutResponse(responseBody)
}

func parseGPServerTarget(serverURL *url.URL) (gpInterface, bool, string, error) {
	serverPath := strings.Trim(serverURL.Path, "/")
	alternateSecret := ""
	separator := strings.LastIndexByte(serverPath, ':')
	if separator >= 0 {
		alternateSecret = serverPath[separator+1:]
		serverPath = serverPath[:separator]
		if alternateSecret == "" {
			return gpInterfacePortal, false, "", E.New("alternate secret field name is empty")
		}
	}
	switch serverPath {
	case "":
		return gpInterfacePortal, true, alternateSecret, nil
	case "portal", "global-protect":
		return gpInterfacePortal, false, alternateSecret, nil
	case "gateway", "ssl-vpn":
		return gpInterfaceGateway, false, alternateSecret, nil
	default:
		return gpInterfacePortal, false, "", E.New("unsupported GlobalProtect server path: ", serverURL.Path)
	}
}

func reportedGPOS(client *Client) string {
	switch client.options.ReportedOS {
	case "mac-intel":
		return "Mac"
	case "apple-ios":
		return "iOS"
	case "linux", "linux-64":
		return "Linux"
	case "android":
		return "Android"
	default:
		return "Windows"
	}
}

func gpBrowserHeader(header http.Header, name string) string {
	for headerName, values := range header {
		if !strings.EqualFold(headerName, name) {
			continue
		}
		for _, value := range values {
			if value != "" {
				return value
			}
		}
	}
	return ""
}

func cloneGPURL(source *url.URL) *url.URL {
	if source == nil {
		return nil
	}
	cloned := *source
	return &cloned
}

func equalGPEndpoint(left *url.URL, right *url.URL) bool {
	if left == nil || right == nil {
		return false
	}
	return strings.EqualFold(left.Hostname(), right.Hostname()) && effectiveGPPort(left) == effectiveGPPort(right)
}

func effectiveGPPort(endpoint *url.URL) string {
	port := endpoint.Port()
	if port == "" {
		return "443"
	}
	return port
}

func gpRedirectStatus(statusCode int) bool {
	switch statusCode {
	case http.StatusMovedPermanently, http.StatusFound, http.StatusSeeOther, http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
		return true
	default:
		return false
	}
}

func parseGPRemoteAddress(address net.Addr) netip.Addr {
	if address == nil {
		return netip.Addr{}
	}
	host, _, err := net.SplitHostPort(address.String())
	if err != nil {
		return netip.Addr{}
	}
	parsed, err := netip.ParseAddr(host)
	if err != nil {
		return netip.Addr{}
	}
	return parsed.Unmap()
}

func gpHTTPStatusError(statusCode int, message string) error {
	err := E.New(message, statusCode)
	switch statusCode {
	case http.StatusUnauthorized, http.StatusForbidden:
		return E.Errors(ErrAuthenticationFailed, err)
	case 513:
		return E.Errors(ErrAuthenticationFailed, err)
	case http.StatusMethodNotAllowed:
		return E.Extend(ErrProtocolNotSupported, err.Error())
	case 512:
		return newRetryableAuthenticationError(err, authCachePassword)
	case http.StatusRequestTimeout, http.StatusTooEarly, http.StatusTooManyRequests:
		return err
	default:
		if statusCode >= http.StatusInternalServerError && statusCode <= 599 {
			return err
		}
		return markTerminal(err)
	}
}
