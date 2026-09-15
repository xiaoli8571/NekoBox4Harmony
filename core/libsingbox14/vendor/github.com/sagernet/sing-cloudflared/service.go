package cloudflared

import (
	"context"
	"encoding/base64"
	"io"
	"math/rand"
	"net/http"
	"runtime/debug"
	"sync"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/config"
	"github.com/sagernet/sing-cloudflared/internal/control"
	"github.com/sagernet/sing-cloudflared/internal/datagram"
	"github.com/sagernet/sing-cloudflared/internal/discovery"
	"github.com/sagernet/sing-cloudflared/internal/protocol"
	"github.com/sagernet/sing-cloudflared/internal/transport"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/common/logger"
	N "github.com/sagernet/sing/common/network"

	"github.com/google/uuid"
)

var (
	discoverEdge        = discovery.DiscoverEdge
	newQUICConnection   = transport.NewQUICConnection
	newHTTP2Connection  = transport.NewHTTP2Connection
	serveQUICConnection = func(connection *transport.QUICConnection, ctx context.Context, handler transport.StreamHandler) error {
		return connection.Serve(ctx, handler)
	}
	serveHTTP2Connection = func(connection *transport.HTTP2Connection, ctx context.Context) error {
		return connection.Serve(ctx)
	}
)

type Service struct {
	ctx              context.Context
	cancel           context.CancelFunc
	logger           logger.ContextLogger
	connectionDialer N.Dialer
	icmpHandler      ICMPHandler
	connContext      func(context.Context) context.Context
	clientVersion    string
	credentials      protocol.Credentials
	connectorID      uuid.UUID
	haConnections    int
	protocol         string
	postQuantum      bool
	protocolSelector transport.ProtocolSelector
	region           string
	edgeIPVersion    int
	datagramVersion  string
	featureSelector  *transport.FeatureSelector
	gracePeriod      time.Duration
	configManager    *config.ConfigManager
	flowLimiter      *datagram.FlowLimiter
	accessCache      *accessValidatorCache
	controlDialer    N.Dialer
	tunnelDialer     N.Dialer
	controlResolver  Resolver
	tunnelResolver   Resolver

	connectionAccess sync.Mutex
	connections      []io.Closer
	done             sync.WaitGroup

	datagramMuxerAccess sync.Mutex
	datagramV2Muxers    map[protocol.DatagramSender]*datagram.DatagramV2Muxer
	datagramV3Muxers    map[protocol.DatagramSender]*datagram.DatagramV3Muxer
	datagramV3Manager   *datagram.DatagramV3SessionManager

	connectedAccess  sync.Mutex
	connectedIndices map[uint8]struct{}
	connectedNotify  chan uint8

	stateAccess      sync.Mutex
	connectionStates []connectionState

	directTransportAccess sync.Mutex
	directTransports      map[string]*http.Transport
}

type connectionState struct {
	protocol string
	retries  uint8
}

func connectionRetryDecision(err error) (retry bool, cancelAll bool) {
	switch {
	case err == nil:
		return false, false
	case E.IsMulti(err, control.ErrNonRemoteManagedTunnelUnsupported):
		return false, true
	case control.IsPermanentRegistrationError(err):
		return false, false
	default:
		return true, false
	}
}

func NewService(options ServiceOptions) (*Service, error) {
	if options.Token == "" {
		return nil, E.New("missing token")
	}
	credentials, err := parseToken(options.Token)
	if err != nil {
		return nil, E.Cause(err, "parse token")
	}

	haConnections := options.HAConnections
	if haConnections <= 0 {
		haConnections = 4
	}

	serviceLogger := options.Logger
	if serviceLogger == nil {
		serviceLogger = logger.NOP()
	}

	normalizedProtocol, err := transport.NormalizeProtocol(options.Protocol)
	if err != nil {
		return nil, err
	}
	selector, err := transport.NewProtocolSelector(normalizedProtocol, options.PostQuantum)
	if err != nil {
		return nil, err
	}
	if options.Protocol == transport.ProtocolH2MUX {
		serviceLogger.Warn("h2mux is no longer supported, using HTTP/2 instead")
	}

	edgeIPVersion := options.EdgeIPVersion
	if edgeIPVersion != 0 && edgeIPVersion != 4 && edgeIPVersion != 6 {
		return nil, E.New("unsupported edge_ip_version: ", edgeIPVersion, ", expected 0, 4 or 6")
	}

	datagramVersion := options.DatagramVersion
	if datagramVersion != "" && datagramVersion != protocol.DefaultDatagramVersion && datagramVersion != protocol.DatagramVersionV3 {
		return nil, E.New("unsupported datagram_version: ", datagramVersion, ", expected v2 or v3")
	}

	gracePeriod := options.GracePeriod
	if gracePeriod <= 0 {
		gracePeriod = 30 * time.Second
	}

	configManager, err := config.NewConfigManager()
	if err != nil {
		return nil, E.Cause(err, "build cloudflared runtime config")
	}

	controlDialer := options.ControlDialer
	if controlDialer == nil {
		controlDialer = N.SystemDialer
	}
	tunnelDialer := options.TunnelDialer
	if tunnelDialer == nil {
		tunnelDialer = N.SystemDialer
	}

	region := options.Region
	if region != "" && credentials.Endpoint != "" {
		return nil, E.New("region cannot be specified when credentials already include an endpoint")
	}
	if region == "" {
		region = credentials.Endpoint
	}

	clientVersion := options.ClientVersion
	if clientVersion == "" {
		clientVersion = "sing-cloudflared"
	}

	serviceCtx, cancel := context.WithCancel(context.Background())

	return &Service{
		ctx:               serviceCtx,
		cancel:            cancel,
		logger:            serviceLogger,
		connectionDialer:  options.ConnectionDialer,
		icmpHandler:       options.ICMPHandler,
		connContext:       options.ConnContext,
		clientVersion:     clientVersion,
		credentials:       credentials,
		connectorID:       uuid.New(),
		haConnections:     haConnections,
		protocol:          normalizedProtocol,
		postQuantum:       options.PostQuantum,
		protocolSelector:  selector,
		region:            region,
		edgeIPVersion:     edgeIPVersion,
		datagramVersion:   datagramVersion,
		featureSelector:   transport.NewFeatureSelector(serviceCtx, credentials.AccountTag, datagramVersion),
		gracePeriod:       gracePeriod,
		configManager:     configManager,
		flowLimiter:       &datagram.FlowLimiter{},
		accessCache:       &accessValidatorCache{values: make(map[string]accessValidator), dialer: controlDialer},
		controlDialer:     controlDialer,
		tunnelDialer:      tunnelDialer,
		controlResolver:   options.ControlResolver,
		tunnelResolver:    options.TunnelResolver,
		datagramV2Muxers:  make(map[protocol.DatagramSender]*datagram.DatagramV2Muxer),
		datagramV3Muxers:  make(map[protocol.DatagramSender]*datagram.DatagramV3Muxer),
		datagramV3Manager: datagram.NewDatagramV3SessionManager(),
		connectedIndices:  make(map[uint8]struct{}),
		connectedNotify:   make(chan uint8, haConnections),
		connectionStates:  make([]connectionState, haConnections),
		directTransports:  make(map[string]*http.Transport),
	}, nil
}

func (s *Service) Start() error {
	s.logger.Info("starting Cloudflare Tunnel with ", s.haConnections, " HA connections")

	regions, err := discoverEdge(s.ctx, s.region, s.controlDialer, s.controlResolver, s.tunnelResolver)
	if err != nil {
		return E.Cause(err, "discover edge")
	}
	regions = discovery.FilterByIPVersion(regions, s.edgeIPVersion)
	edgeAddrs := flattenRegions(regions)
	if len(edgeAddrs) == 0 {
		return E.New("no edge addresses available")
	}
	if cappedHAConnections := effectiveHAConnections(s.haConnections, len(edgeAddrs)); cappedHAConnections != s.haConnections {
		s.logger.Info("requested ", s.haConnections, " HA connections but only ", cappedHAConnections, " edge addresses are available")
		s.haConnections = cappedHAConnections
	}

	for connIndex := 0; connIndex < s.haConnections; connIndex++ {
		s.initializeConnectionState(uint8(connIndex))
		s.done.Add(1)
		go s.superviseConnection(uint8(connIndex), edgeAddrs)
		select {
		case readyConnIndex := <-s.connectedNotify:
			if readyConnIndex != uint8(connIndex) {
				s.logger.Debug("received unexpected ready notification for connection ", readyConnIndex)
			}
		case <-time.After(firstConnectionReadyTimeout):
		case <-s.ctx.Done():
			if connIndex == 0 {
				return s.ctx.Err()
			}
			return nil
		}
	}
	return nil
}

func (s *Service) notifyConnected(connIndex uint8, _ string) {
	s.stateAccess.Lock()
	s.ensureConnectionStateLocked(connIndex)
	state := s.connectionStates[connIndex]
	state.retries = 0
	state.protocol = s.currentProtocol()
	s.connectionStates[connIndex] = state
	s.stateAccess.Unlock()

	if s.connectedNotify == nil {
		return
	}
	s.connectedAccess.Lock()
	if _, loaded := s.connectedIndices[connIndex]; loaded {
		s.connectedAccess.Unlock()
		return
	}
	s.connectedIndices[connIndex] = struct{}{}
	s.connectedAccess.Unlock()
	s.connectedNotify <- connIndex
}

func (s *Service) ApplyConfig(version int32, configData []byte) config.UpdateResult {
	result := s.configManager.Apply(version, configData)
	if result.Err != nil {
		s.logger.Error("update ingress configuration: ", result.Err)
		return result
	}
	s.resetDirectOriginTransports()
	s.logger.Info("updated ingress configuration (version ", result.LastAppliedVersion, ")")
	return result
}

func (s *Service) maxActiveFlows() uint64 {
	return s.configManager.Snapshot().WarpRouting.MaxActiveFlows
}

func (s *Service) Close() error {
	s.cancel()
	s.done.Wait()
	s.connectionAccess.Lock()
	for _, connection := range s.connections {
		connection.Close()
	}
	s.connections = nil
	s.connectionAccess.Unlock()
	s.resetDirectOriginTransports()
	return nil
}

const (
	backoffBaseTime             = time.Second
	backoffMaxTime              = 2 * time.Minute
	firstConnectionReadyTimeout = 15 * time.Second
)

func (s *Service) superviseConnection(connIndex uint8, edgeAddrs []*discovery.EdgeAddr) {
	defer s.done.Done()

	edgeIndex := initialEdgeAddrIndex(connIndex, len(edgeAddrs))
	for {
		select {
		case <-s.ctx.Done():
			return
		default:
		}

		edgeAddr := edgeAddrs[edgeIndex]
		err := s.safeServeConnection(connIndex, edgeAddr)
		if err == nil || s.ctx.Err() != nil {
			return
		}
		retry, cancelAll := connectionRetryDecision(err)
		if cancelAll {
			s.logger.Error("connection ", connIndex, " failed permanently: ", err)
			s.cancel()
			return
		}
		if !retry {
			s.logger.Error("connection ", connIndex, " failed permanently: ", err)
			return
		}

		retries, switchedProtocol, switched := s.recordConnectionFailure(connIndex, err)
		edgeIndex = rotateEdgeAddrIndex(edgeIndex, len(edgeAddrs))
		backoff := backoffDuration(int(retries))
		retryableErr, isRetryable := E.Cast[*protocol.RetryableError](err)
		if isRetryable && retryableErr.Delay > 0 {
			backoff = retryableErr.Delay
		}
		if switched {
			s.logger.Warn("connection ", connIndex, " switching to fallback protocol ", switchedProtocol, ": ", err)
		}
		s.logger.Error("connection ", connIndex, " failed: ", err, ", retrying in ", backoff)

		select {
		case <-time.After(backoff):
		case <-s.ctx.Done():
			return
		}
	}
}

func (s *Service) serveConnection(connIndex uint8, edgeAddr *discovery.EdgeAddr) error {
	state := s.connectionState(connIndex)
	connProtocol := state.protocol
	numPreviousAttempts := state.retries
	datagramVersion, features := s.currentConnectionFeatures()

	switch connProtocol {
	case transport.ProtocolQUIC:
		return s.serveQUIC(connIndex, edgeAddr, datagramVersion, features, numPreviousAttempts)
	case transport.ProtocolHTTP2:
		return s.serveHTTP2(connIndex, edgeAddr, features, numPreviousAttempts)
	default:
		return E.New("unsupported protocol: ", connProtocol)
	}
}

func (s *Service) safeServeConnection(connIndex uint8, edgeAddr *discovery.EdgeAddr) (err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			err = E.New("panic in serve connection: ", recovered, "\n", string(debug.Stack()))
		}
	}()
	return s.serveConnection(connIndex, edgeAddr)
}

func (s *Service) serveQUIC(connIndex uint8, edgeAddr *discovery.EdgeAddr, datagramVersion string, features []string, numPreviousAttempts uint8) error {
	s.logger.Info("connecting to edge via QUIC (connection ", connIndex, ")")

	connection, err := newQUICConnection(
		s.ctx, edgeAddr, connIndex,
		s.credentials, s.connectorID, datagramVersion,
		features, numPreviousAttempts, s.gracePeriod, s.tunnelDialer, func() {
			s.notifyConnected(connIndex, transport.ProtocolQUIC)
		}, s.logger,
	)
	if err != nil {
		return E.Cause(err, "create QUIC connection")
	}

	s.trackConnection(connection)
	defer func() {
		s.untrackConnection(connection)
		s.removeDatagramMuxer(connection)
	}()

	return serveQUICConnection(connection, s.ctx, &streamHandlerAdapter{s})
}

func (s *Service) currentConnectionFeatures() (string, []string) {
	version, features := s.featureSelector.Snapshot()
	if s.postQuantum && !transport.HasFeature(features, transport.FeaturePostQuantum) {
		features = append(features, transport.FeaturePostQuantum)
	}
	return version, features
}

func (s *Service) serveHTTP2(connIndex uint8, edgeAddr *discovery.EdgeAddr, features []string, numPreviousAttempts uint8) error {
	s.logger.Info("connecting to edge via HTTP/2 (connection ", connIndex, ")")

	connection, err := newHTTP2Connection(
		s.ctx, edgeAddr, connIndex,
		s.credentials, s.connectorID,
		features, numPreviousAttempts, s.gracePeriod, s.tunnelDialer,
		&http2HandlerAdapter{s}, s.logger,
	)
	if err != nil {
		return E.Cause(err, "create HTTP/2 connection")
	}

	s.trackConnection(connection)
	defer s.untrackConnection(connection)

	return serveHTTP2Connection(connection, s.ctx)
}

func (s *Service) initializeConnectionState(connIndex uint8) {
	s.stateAccess.Lock()
	defer s.stateAccess.Unlock()
	s.ensureConnectionStateLocked(connIndex)
	if s.connectionStates[connIndex].protocol == "" {
		s.connectionStates[connIndex].protocol = s.currentProtocol()
	}
}

func (s *Service) connectionState(connIndex uint8) connectionState {
	s.stateAccess.Lock()
	defer s.stateAccess.Unlock()
	s.ensureConnectionStateLocked(connIndex)
	state := s.connectionStates[connIndex]
	if state.protocol == "" {
		state.protocol = s.currentProtocol()
		s.connectionStates[connIndex] = state
	}
	return state
}

func (s *Service) recordConnectionFailure(connIndex uint8, err error) (uint8, string, bool) {
	s.stateAccess.Lock()
	defer s.stateAccess.Unlock()
	s.ensureConnectionStateLocked(connIndex)
	state := s.connectionStates[connIndex]
	if state.protocol == "" {
		state.protocol = s.currentProtocol()
	}
	if state.retries < transport.DefaultProtocolRetry {
		state.retries++
	}
	backoffRetries := state.retries
	if state.protocol == transport.ProtocolQUIC && (backoffRetries >= transport.DefaultProtocolRetry || transport.IsQUICBroken(err)) {
		if fallback, hasFallback := s.fallbackProtocol(); hasFallback && state.protocol != fallback {
			state.protocol = fallback
			state.retries = 0
			s.connectionStates[connIndex] = state
			return backoffRetries, fallback, true
		}
	}
	s.connectionStates[connIndex] = state
	return backoffRetries, "", false
}

func (s *Service) incrementConnectionRetries(connIndex uint8) uint8 {
	s.stateAccess.Lock()
	defer s.stateAccess.Unlock()
	s.ensureConnectionStateLocked(connIndex)
	state := s.connectionStates[connIndex]
	if state.retries < transport.DefaultProtocolRetry {
		state.retries++
	}
	s.connectionStates[connIndex] = state
	return state.retries
}

func (s *Service) ensureConnectionStateLocked(connIndex uint8) {
	requiredLen := int(connIndex) + 1
	if len(s.connectionStates) >= requiredLen {
		return
	}
	grown := make([]connectionState, requiredLen)
	copy(grown, s.connectionStates)
	s.connectionStates = grown
}

func (s *Service) selector() transport.ProtocolSelector {
	if s.protocolSelector != nil {
		return s.protocolSelector
	}
	selector, err := transport.NewProtocolSelector(s.protocol, s.postQuantum)
	if err != nil {
		return staticProtocolSelector{current: transport.ProtocolQUIC}
	}
	return selector
}

func (s *Service) currentProtocol() string {
	return s.selector().Current()
}

func (s *Service) fallbackProtocol() (string, bool) {
	return s.selector().Fallback()
}

func (s *Service) resetDirectOriginTransports() {
	s.directTransportAccess.Lock()
	transports := s.directTransports
	s.directTransports = make(map[string]*http.Transport)
	s.directTransportAccess.Unlock()

	for _, t := range transports {
		t.CloseIdleConnections()
	}
}

func (s *Service) trackConnection(connection io.Closer) {
	s.connectionAccess.Lock()
	defer s.connectionAccess.Unlock()
	s.connections = append(s.connections, connection)
}

func (s *Service) untrackConnection(connection io.Closer) {
	s.connectionAccess.Lock()
	defer s.connectionAccess.Unlock()
	for index, tracked := range s.connections {
		if tracked == connection {
			s.connections = append(s.connections[:index], s.connections[index+1:]...)
			break
		}
	}
}

func backoffDuration(retries int) time.Duration {
	backoff := backoffBaseTime * (1 << min(retries, 7))
	if backoff > backoffMaxTime {
		backoff = backoffMaxTime
	}
	jitter := time.Duration(rand.Int63n(int64(backoff / 2)))
	return backoff/2 + jitter
}

func initialEdgeAddrIndex(connIndex uint8, size int) int {
	if size <= 1 {
		return 0
	}
	return int(connIndex) % size
}

func rotateEdgeAddrIndex(current int, size int) int {
	if size <= 1 {
		return 0
	}
	return (current + 1) % size
}

func flattenRegions(regions [][]*discovery.EdgeAddr) []*discovery.EdgeAddr {
	var result []*discovery.EdgeAddr
	for _, region := range regions {
		result = append(result, region...)
	}
	return result
}

func effectiveHAConnections(requested, available int) int {
	if available <= 0 {
		return 0
	}
	return min(requested, available)
}

func parseToken(token string) (protocol.Credentials, error) {
	data, err := base64.StdEncoding.DecodeString(token)
	if err != nil {
		return protocol.Credentials{}, E.Cause(err, "decode token")
	}
	var tunnelToken protocol.TunnelToken
	err = json.Unmarshal(data, &tunnelToken)
	if err != nil {
		return protocol.Credentials{}, E.Cause(err, "unmarshal token")
	}
	return tunnelToken.ToCredentials(), nil
}

type staticProtocolSelector struct {
	current string
}

func (s staticProtocolSelector) Current() string {
	return s.current
}

func (s staticProtocolSelector) Fallback() (string, bool) {
	return "", false
}

type streamHandlerAdapter struct {
	service *Service
}

func (a *streamHandlerAdapter) HandleDataStream(ctx context.Context, stream io.ReadWriteCloser, request *protocol.ConnectRequest, connIndex uint8) {
	a.service.handleDataStream(ctx, stream, request, connIndex)
}

func (a *streamHandlerAdapter) HandleRPCStream(ctx context.Context, stream io.ReadWriteCloser, connIndex uint8) {
	a.service.handleRPCStream(ctx, stream, connIndex)
}

func (a *streamHandlerAdapter) HandleRPCStreamWithSender(ctx context.Context, stream io.ReadWriteCloser, connIndex uint8, sender protocol.DatagramSender) {
	a.service.handleRPCStreamWithSender(ctx, stream, connIndex, sender)
}

func (a *streamHandlerAdapter) HandleDatagram(ctx context.Context, data []byte, sender protocol.DatagramSender) {
	a.service.handleDatagram(ctx, data, sender)
}

type http2HandlerAdapter struct {
	service *Service
}

func (a *http2HandlerAdapter) DispatchRequest(ctx context.Context, stream io.ReadWriteCloser, writer protocol.ConnectResponseWriter, request *protocol.ConnectRequest) {
	a.service.dispatchRequest(ctx, stream, writer, request)
}

func (a *http2HandlerAdapter) ApplyConfig(version int32, configData []byte) config.UpdateResult {
	return a.service.ApplyConfig(version, configData)
}

func (a *http2HandlerAdapter) NotifyConnected(connIndex uint8, connProtocol string) {
	a.service.notifyConnected(connIndex, connProtocol)
}
