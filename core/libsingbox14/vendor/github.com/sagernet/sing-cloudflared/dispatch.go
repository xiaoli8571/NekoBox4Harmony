package cloudflared

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/config"
	"github.com/sagernet/sing-cloudflared/internal/datagram"
	"github.com/sagernet/sing-cloudflared/internal/protocol"
	"github.com/sagernet/sing-cloudflared/internal/transport"
	"github.com/sagernet/sing/common/bufio"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/json"
	M "github.com/sagernet/sing/common/metadata"
)

var (
	loadOriginCABasePool = transport.CloudflareRootCertPool
	readOriginCAFile     = os.ReadFile
	proxyFromEnvironment = http.ProxyFromEnvironment
)

type connectResponseTrailerWriter interface {
	AddTrailer(name, value string)
}

type quicResponseWriter struct {
	stream io.Writer
}

func (w *quicResponseWriter) WriteResponse(responseError error, metadata []protocol.Metadata) error {
	return protocol.WriteConnectResponse(w.stream, responseError, metadata...)
}

func (s *Service) handleDataStream(ctx context.Context, stream io.ReadWriteCloser, request *protocol.ConnectRequest, connIndex uint8) {
	if s.connContext != nil {
		ctx = s.connContext(ctx)
	}
	respWriter := &quicResponseWriter{stream: stream}
	s.dispatchRequest(ctx, stream, respWriter, request)
}

func (s *Service) handleRPCStream(ctx context.Context, stream io.ReadWriteCloser, connIndex uint8) {
	s.logger.DebugContext(ctx, "received RPC stream on connection ", connIndex)
}

func (s *Service) handleRPCStreamWithSender(ctx context.Context, stream io.ReadWriteCloser, connIndex uint8, sender protocol.DatagramSender) {
	switch datagramVersionForSender(sender) {
	case protocol.DatagramVersionV3:
		datagram.ServeV3RPCStream(ctx, stream, s.configApplier(), s.logger)
	default:
		muxer := s.getOrCreateV2Muxer(sender)
		datagram.ServeRPCStream(ctx, stream, s.configApplier(), muxer, s.logger)
	}
}

func (s *Service) handleDatagram(ctx context.Context, data []byte, sender protocol.DatagramSender) {
	switch datagramVersionForSender(sender) {
	case protocol.DatagramVersionV3:
		muxer := s.getOrCreateV3Muxer(sender)
		muxer.HandleDatagram(ctx, data)
	default:
		muxer := s.getOrCreateV2Muxer(sender)
		muxer.HandleDatagram(ctx, data)
	}
}

func (s *Service) configApplier() func(int32, []byte) config.UpdateResult {
	return s.ApplyConfig
}

func (s *Service) muxerContext() datagram.MuxerContext {
	return datagram.MuxerContext{
		Context:        s.ctx,
		Logger:         s.logger,
		MaxActiveFlows: s.maxActiveFlows,
		FlowLimiter:    s.flowLimiter,
		DialPacket:     s.dialWarpPacketConnection,
		ICMPHandler:    s.icmpHandler,
	}
}

func (s *Service) getOrCreateV2Muxer(sender protocol.DatagramSender) *datagram.DatagramV2Muxer {
	s.datagramMuxerAccess.Lock()
	defer s.datagramMuxerAccess.Unlock()
	muxer, exists := s.datagramV2Muxers[sender]
	if !exists {
		muxer = datagram.NewDatagramV2Muxer(s.muxerContext(), sender, s.logger)
		s.datagramV2Muxers[sender] = muxer
	}
	return muxer
}

func (s *Service) getOrCreateV3Muxer(sender protocol.DatagramSender) *datagram.DatagramV3Muxer {
	s.datagramMuxerAccess.Lock()
	defer s.datagramMuxerAccess.Unlock()
	muxer, exists := s.datagramV3Muxers[sender]
	if !exists {
		muxer = datagram.NewDatagramV3Muxer(s.muxerContext(), sender, s.logger, s.datagramV3Manager)
		s.datagramV3Muxers[sender] = muxer
	}
	return muxer
}

func (s *Service) removeDatagramMuxer(sender protocol.DatagramSender) {
	s.datagramMuxerAccess.Lock()
	if muxer, exists := s.datagramV2Muxers[sender]; exists {
		muxer.Close()
		delete(s.datagramV2Muxers, sender)
	}
	if muxer, exists := s.datagramV3Muxers[sender]; exists {
		muxer.Close()
		delete(s.datagramV3Muxers, sender)
	}
	s.datagramMuxerAccess.Unlock()
}

func (s *Service) dispatchRequest(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, request *protocol.ConnectRequest) {
	switch request.Type {
	case protocol.ConnectionTypeTCP:
		destination := M.ParseSocksaddr(request.Dest)
		s.handleTCPStream(ctx, stream, respWriter, destination)
	case protocol.ConnectionTypeHTTP, protocol.ConnectionTypeWebsocket:
		service, originURL, err := s.resolveHTTPService(request.Dest)
		if err != nil {
			s.logger.ErrorContext(ctx, "resolve origin service: ", err)
			respWriter.WriteResponse(err, nil)
			return
		}
		request.Dest = originURL
		s.handleHTTPService(ctx, stream, respWriter, request, service)
	default:
		err := E.New("unknown connection type: ", request.Type)
		s.logger.ErrorContext(ctx, err)
		respWriter.WriteResponse(err, nil)
	}
}

func (s *Service) resolveHTTPService(requestURL string) (config.ResolvedService, string, error) {
	parsedURL, err := url.Parse(requestURL)
	if err != nil {
		return config.ResolvedService{}, "", E.Cause(err, "parse request URL")
	}
	service, loaded := s.configManager.Resolve(parsedURL.Hostname(), parsedURL.Path)
	if !loaded {
		return config.ResolvedService{}, "", E.New("no ingress rule matched request host/path")
	}
	originURL, err := service.BuildRequestURL(requestURL)
	if err != nil {
		return config.ResolvedService{}, "", E.Cause(err, "build origin request URL")
	}
	return service, originURL, nil
}

func (s *Service) handleTCPStream(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, destination M.Socksaddr) {
	s.logger.InfoContext(ctx, "inbound TCP connection to ", destination)
	limit := s.maxActiveFlows()
	if !s.flowLimiter.Acquire(limit) {
		err := E.New("too many active flows")
		s.logger.ErrorContext(ctx, err)
		respWriter.WriteResponse(err, protocol.FlowConnectRateLimitedMetadata())
		return
	}
	defer s.flowLimiter.Release(limit)

	warpRouting := s.configManager.Snapshot().WarpRouting
	targetConn, cleanup, err := s.dialRouterTCPWithMetadata(ctx, destination, routedPipeTCPOptions{
		timeout: warpRouting.ConnectTimeout,
		onHandshake: func(conn net.Conn) {
			_ = applyTCPKeepAlive(conn, warpRouting.TCPKeepAlive)
		},
	})
	if err != nil {
		s.logger.ErrorContext(ctx, "dial tcp origin: ", err)
		respWriter.WriteResponse(err, nil)
		return
	}
	defer cleanup()

	err = respWriter.WriteResponse(nil, nil)
	if err != nil {
		s.logger.ErrorContext(ctx, "write connect response: ", err)
		return
	}

	err = bufio.CopyConn(ctx, newStreamConn(stream), targetConn)
	if err != nil && !E.IsClosedOrCanceled(err) {
		s.logger.DebugContext(ctx, "copy TCP stream: ", err)
	}
}

func (s *Service) handleHTTPService(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, request *protocol.ConnectRequest, service config.ResolvedService) {
	validationRequest, err := buildMetadataOnlyHTTPRequest(ctx, request)
	if err != nil {
		s.logger.ErrorContext(ctx, "build request for access validation: ", err)
		respWriter.WriteResponse(err, nil)
		return
	}
	validationRequest = applyOriginRequest(validationRequest, service.OriginRequest)
	if service.OriginRequest.Access.Required {
		validator, err := s.accessCache.Get(service.OriginRequest.Access)
		if err != nil {
			s.logger.ErrorContext(ctx, "create access validator: ", err)
			respWriter.WriteResponse(err, nil)
			return
		}
		err = validator.Validate(validationRequest.Context(), validationRequest)
		if err != nil {
			respWriter.WriteResponse(nil, encodeResponseHeaders(http.StatusForbidden, http.Header{}))
			return
		}
	}

	switch service.Kind {
	case config.ResolvedServiceStatus:
		err = respWriter.WriteResponse(nil, encodeResponseHeaders(service.StatusCode, http.Header{}))
		if err != nil {
			s.logger.ErrorContext(ctx, "write status service response: ", err)
		}
		return
	case config.ResolvedServiceHTTP:
		s.handleRouterOriginStream(ctx, stream, respWriter, request, service.Destination, service)
	case config.ResolvedServiceStream:
		if request.Type != protocol.ConnectionTypeWebsocket {
			err = E.New("stream service requires websocket request type")
			s.logger.ErrorContext(ctx, err)
			respWriter.WriteResponse(err, nil)
			return
		}
		s.handleStreamService(ctx, stream, respWriter, request, service)
	case config.ResolvedServiceUnix, config.ResolvedServiceUnixTLS:
		s.handleDirectOriginStream(ctx, stream, respWriter, request, service)
	case config.ResolvedServiceBastion:
		if request.Type != protocol.ConnectionTypeWebsocket {
			err = E.New("bastion service requires websocket request type")
			s.logger.ErrorContext(ctx, err)
			respWriter.WriteResponse(err, nil)
			return
		}
		s.handleBastionStream(ctx, stream, respWriter, request, service)
	case config.ResolvedServiceSocksProxy:
		if request.Type != protocol.ConnectionTypeWebsocket {
			err = E.New("socks-proxy service requires websocket request type")
			s.logger.ErrorContext(ctx, err)
			respWriter.WriteResponse(err, nil)
			return
		}
		s.handleSocksProxyStream(ctx, stream, respWriter, request, service)
	default:
		err = E.New("unsupported service kind for HTTP/WebSocket request")
		s.logger.ErrorContext(ctx, err)
		respWriter.WriteResponse(err, nil)
	}
}

func (s *Service) handleRouterOriginStream(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, request *protocol.ConnectRequest, destination M.Socksaddr, service config.ResolvedService) {
	s.logger.InfoContext(ctx, "inbound ", request.Type, " connection to ", destination)

	httpTransport, cleanup, err := s.newRouterOriginTransport(ctx, destination, service.OriginRequest, request.MetadataMap()[protocol.MetadataHTTPHost])
	if err != nil {
		s.logger.ErrorContext(ctx, "build origin transport: ", err)
		respWriter.WriteResponse(err, nil)
		return
	}
	defer cleanup()
	s.roundTripHTTP(ctx, stream, respWriter, request, service, httpTransport)
}

func (s *Service) handleDirectOriginStream(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, request *protocol.ConnectRequest, service config.ResolvedService) {
	s.logger.InfoContext(ctx, "inbound ", request.Type, " connection to ", request.Dest)

	httpTransport, cleanup, err := s.newDirectOriginTransport(service, request.MetadataMap()[protocol.MetadataHTTPHost])
	if err != nil {
		s.logger.ErrorContext(ctx, "build direct origin transport: ", err)
		respWriter.WriteResponse(err, nil)
		return
	}
	defer cleanup()
	s.roundTripHTTP(ctx, stream, respWriter, request, service, httpTransport)
}

func (s *Service) roundTripHTTP(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, request *protocol.ConnectRequest, service config.ResolvedService, httpTransport *http.Transport) {
	httpRequest, err := buildHTTPRequestFromMetadata(ctx, request, stream)
	if err != nil {
		s.logger.ErrorContext(ctx, "build HTTP request: ", err)
		respWriter.WriteResponse(err, nil)
		return
	}

	httpRequest = normalizeOriginRequest(request.Type, httpRequest, service.OriginRequest)
	requestCtx := httpRequest.Context()
	if service.OriginRequest.ConnectTimeout > 0 {
		var cancel context.CancelFunc
		requestCtx, cancel = context.WithTimeout(requestCtx, service.OriginRequest.ConnectTimeout)
		defer cancel()
		httpRequest = httpRequest.WithContext(requestCtx)
	}

	httpClient := &http.Client{
		Transport: httpTransport,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	response, err := httpClient.Do(httpRequest)
	if err != nil {
		s.logger.ErrorContext(ctx, "origin request: ", err)
		respWriter.WriteResponse(err, nil)
		return
	}
	defer response.Body.Close()

	responseMetadata := encodeResponseHeaders(response.StatusCode, response.Header)
	err = respWriter.WriteResponse(nil, responseMetadata)
	if err != nil {
		s.logger.ErrorContext(ctx, "write origin response headers: ", err)
		return
	}

	if request.Type == protocol.ConnectionTypeWebsocket && response.StatusCode == http.StatusSwitchingProtocols {
		rwc, ok := response.Body.(io.ReadWriteCloser)
		if !ok {
			s.logger.ErrorContext(ctx, "websocket origin response body is not duplex")
			return
		}
		err = bufio.CopyConn(ctx, newStreamConn(stream), newStreamConn(rwc))
		if err != nil && !E.IsClosedOrCanceled(err) {
			s.logger.DebugContext(ctx, "copy websocket stream: ", err)
		}
		return
	}

	_, err = io.Copy(stream, response.Body)
	if err != nil && !E.IsClosedOrCanceled(err) {
		s.logger.DebugContext(ctx, "copy HTTP response body: ", err)
	}
	if trailerWriter, ok := respWriter.(connectResponseTrailerWriter); ok {
		for name, values := range response.Trailer {
			for _, value := range values {
				trailerWriter.AddTrailer(name, value)
			}
		}
	}
}

func (s *Service) newRouterOriginTransport(ctx context.Context, destination M.Socksaddr, originRequest config.OriginRequestConfig, requestHost string) (*http.Transport, func(), error) {
	tlsConfig, err := newOriginTLSConfig(originRequest, effectiveOriginHost(originRequest, requestHost))
	if err != nil {
		return nil, nil, err
	}
	input, cleanup, err := s.dialRouterTCPWithMetadata(ctx, destination, routedPipeTCPOptions{})
	if err != nil {
		return nil, nil, err
	}

	httpTransport := &http.Transport{
		ExpectContinueTimeout: time.Second,
		ForceAttemptHTTP2:     originRequest.HTTP2Origin,
		TLSHandshakeTimeout:   originRequest.TLSTimeout,
		IdleConnTimeout:       originRequest.KeepAliveTimeout,
		MaxIdleConns:          originRequest.KeepAliveConnections,
		MaxIdleConnsPerHost:   originRequest.KeepAliveConnections,
		Proxy:                 proxyFromEnvironment,
		TLSClientConfig:       tlsConfig,
		DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
			return input, nil
		},
	}
	return httpTransport, cleanup, nil
}

func (s *Service) newDirectOriginTransport(service config.ResolvedService, requestHost string) (*http.Transport, func(), error) {
	cacheKey, err := directOriginTransportKey(service, requestHost)
	if err != nil {
		return nil, nil, E.Cause(err, "marshal direct origin transport key")
	}

	s.directTransportAccess.Lock()
	if cached, exists := s.directTransports[cacheKey]; exists {
		s.directTransportAccess.Unlock()
		return cached, func() {}, nil
	}
	s.directTransportAccess.Unlock()

	dialer := &net.Dialer{
		Timeout:   service.OriginRequest.ConnectTimeout,
		KeepAlive: service.OriginRequest.TCPKeepAlive,
	}
	if service.OriginRequest.NoHappyEyeballs {
		dialer.FallbackDelay = -1
	}
	tlsConfig, err := newOriginTLSConfig(service.OriginRequest, effectiveOriginHost(service.OriginRequest, requestHost))
	if err != nil {
		return nil, nil, err
	}
	httpTransport := &http.Transport{
		ExpectContinueTimeout: time.Second,
		ForceAttemptHTTP2:     service.OriginRequest.HTTP2Origin,
		TLSHandshakeTimeout:   service.OriginRequest.TLSTimeout,
		IdleConnTimeout:       service.OriginRequest.KeepAliveTimeout,
		MaxIdleConns:          service.OriginRequest.KeepAliveConnections,
		MaxIdleConnsPerHost:   service.OriginRequest.KeepAliveConnections,
		Proxy:                 proxyFromEnvironment,
		TLSClientConfig:       tlsConfig,
	}
	switch service.Kind {
	case config.ResolvedServiceUnix, config.ResolvedServiceUnixTLS:
		httpTransport.DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, "unix", service.UnixPath)
		}
	default:
		return nil, nil, E.New("unsupported direct origin service")
	}

	s.directTransportAccess.Lock()
	if cached, exists := s.directTransports[cacheKey]; exists {
		s.directTransportAccess.Unlock()
		httpTransport.CloseIdleConnections()
		return cached, func() {}, nil
	}
	s.directTransports[cacheKey] = httpTransport
	s.directTransportAccess.Unlock()
	return httpTransport, func() {}, nil
}

type directOriginTransportCacheKey struct {
	Kind        config.ResolvedServiceKind `json:"kind"`
	UnixPath    string                     `json:"unix_path,omitempty"`
	RequestHost string                     `json:"request_host,omitempty"`
	Origin      config.OriginRequestConfig `json:"origin"`
}

func directOriginTransportKey(service config.ResolvedService, requestHost string) (string, error) {
	key := directOriginTransportCacheKey{
		Kind:        service.Kind,
		UnixPath:    service.UnixPath,
		RequestHost: effectiveOriginHost(service.OriginRequest, requestHost),
		Origin:      service.OriginRequest,
	}
	data, err := json.Marshal(key)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func effectiveOriginHost(originRequest config.OriginRequestConfig, requestHost string) string {
	if originRequest.HTTPHostHeader != "" {
		return originRequest.HTTPHostHeader
	}
	return requestHost
}

func newOriginTLSConfig(originRequest config.OriginRequestConfig, requestHost string) (*tls.Config, error) {
	rootCAs, err := loadOriginCABasePool()
	if err != nil {
		return nil, E.Cause(err, "load origin root CAs")
	}
	tlsConfig := &tls.Config{
		InsecureSkipVerify: originRequest.NoTLSVerify, //nolint:gosec
		ServerName:         originTLSServerName(originRequest, requestHost),
		RootCAs:            rootCAs,
	}
	if originRequest.CAPool == "" {
		return tlsConfig, nil
	}
	pemData, err := readOriginCAFile(originRequest.CAPool)
	if err != nil {
		return nil, E.Cause(err, "read origin ca pool")
	}
	tlsConfig.RootCAs = tlsConfig.RootCAs.Clone()
	if !tlsConfig.RootCAs.AppendCertsFromPEM(pemData) {
		return nil, E.New("parse origin ca pool")
	}
	return tlsConfig, nil
}

func originTLSServerName(originRequest config.OriginRequestConfig, requestHost string) string {
	if originRequest.OriginServerName != "" {
		return originRequest.OriginServerName
	}
	if !originRequest.MatchSNIToHost {
		return ""
	}
	host, _, err := net.SplitHostPort(requestHost)
	if err == nil {
		return host
	}
	return requestHost
}

func applyOriginRequest(request *http.Request, originRequest config.OriginRequestConfig) *http.Request {
	request = request.Clone(request.Context())
	if originRequest.HTTPHostHeader != "" {
		request.Header.Set("X-Forwarded-Host", request.Host)
		request.Host = originRequest.HTTPHostHeader
	}
	return request
}

func normalizeOriginRequest(connectType protocol.ConnectionType, request *http.Request, originRequest config.OriginRequestConfig) *http.Request {
	request = applyOriginRequest(request, originRequest)

	switch connectType {
	case protocol.ConnectionTypeWebsocket:
		request.Header.Set("Connection", "Upgrade")
		request.Header.Set("Upgrade", "websocket")
		request.Header.Set("Sec-Websocket-Version", "13")
		request.ContentLength = 0
		request.Body = nil
	default:
		if originRequest.DisableChunkedEncoding {
			request.TransferEncoding = []string{"gzip", "deflate"}
			contentLength, err := strconv.ParseInt(request.Header.Get("Content-Length"), 10, 64)
			if err == nil {
				request.ContentLength = contentLength
			}
		}
		request.Header.Set("Connection", "keep-alive")
	}

	if _, exists := request.Header["User-Agent"]; !exists {
		request.Header.Set("User-Agent", "")
	}

	return request
}

func buildMetadataOnlyHTTPRequest(ctx context.Context, connectRequest *protocol.ConnectRequest) (*http.Request, error) {
	return buildHTTPRequestFromMetadata(ctx, connectRequest, http.NoBody)
}

func buildHTTPRequestFromMetadata(ctx context.Context, connectRequest *protocol.ConnectRequest, body io.Reader) (*http.Request, error) {
	metadataMap := connectRequest.MetadataMap()
	method := metadataMap[protocol.MetadataHTTPMethod]
	host := metadataMap[protocol.MetadataHTTPHost]

	request, err := http.NewRequestWithContext(ctx, method, connectRequest.Dest, body)
	if err != nil {
		return nil, E.Cause(err, "create HTTP request")
	}
	request.Host = host

	for _, entry := range connectRequest.Metadata {
		if !strings.HasPrefix(entry.Key, protocol.MetadataHTTPHeaderPrefix) {
			continue
		}
		headerName := strings.TrimPrefix(entry.Key, protocol.MetadataHTTPHeaderPrefix)
		request.Header.Add(headerName, entry.Val)
	}

	contentLengthStr := request.Header.Get("Content-Length")
	if contentLengthStr != "" {
		request.ContentLength, err = strconv.ParseInt(contentLengthStr, 10, 64)
		if err != nil {
			return nil, E.Cause(err, "parse content-length")
		}
	}

	if connectRequest.Type != protocol.ConnectionTypeWebsocket && !isTransferEncodingChunked(request) && request.ContentLength == 0 {
		request.Body = http.NoBody
	}

	request.Header.Del("Cf-Cloudflared-Proxy-Connection-Upgrade")

	return request, nil
}

func isTransferEncodingChunked(request *http.Request) bool {
	for _, encoding := range request.TransferEncoding {
		if strings.Contains(strings.ToLower(encoding), "chunked") {
			return true
		}
	}
	return strings.Contains(strings.ToLower(request.Header.Get("Transfer-Encoding")), "chunked")
}

func encodeResponseHeaders(statusCode int, header http.Header) []protocol.Metadata {
	metadata := make([]protocol.Metadata, 0, len(header)+1)
	metadata = append(metadata, protocol.Metadata{
		Key: protocol.MetadataHTTPStatus,
		Val: strconv.Itoa(statusCode),
	})
	for name, values := range header {
		for _, value := range values {
			metadata = append(metadata, protocol.Metadata{
				Key: protocol.MetadataHTTPHeaderPrefix + name,
				Val: value,
			})
		}
	}
	return metadata
}

type streamConn struct {
	io.ReadWriteCloser
}

func newStreamConn(stream io.ReadWriteCloser) *streamConn {
	return &streamConn{ReadWriteCloser: stream}
}

func (c *streamConn) LocalAddr() net.Addr {
	type localAddr interface{ LocalAddr() net.Addr }
	if conn, ok := c.ReadWriteCloser.(localAddr); ok {
		return conn.LocalAddr()
	}
	return nil
}

func (c *streamConn) RemoteAddr() net.Addr {
	type remoteAddr interface{ RemoteAddr() net.Addr }
	if conn, ok := c.ReadWriteCloser.(remoteAddr); ok {
		return conn.RemoteAddr()
	}
	return nil
}

func (c *streamConn) SetDeadline(t time.Time) error {
	type deadlineSetter interface{ SetDeadline(time.Time) error }
	if conn, ok := c.ReadWriteCloser.(deadlineSetter); ok {
		return conn.SetDeadline(t)
	}
	return nil
}

func (c *streamConn) SetReadDeadline(t time.Time) error {
	type readDeadlineSetter interface{ SetReadDeadline(time.Time) error }
	if conn, ok := c.ReadWriteCloser.(readDeadlineSetter); ok {
		return conn.SetReadDeadline(t)
	}
	return nil
}

func (c *streamConn) SetWriteDeadline(t time.Time) error {
	type writeDeadlineSetter interface{ SetWriteDeadline(time.Time) error }
	if conn, ok := c.ReadWriteCloser.(writeDeadlineSetter); ok {
		return conn.SetWriteDeadline(t)
	}
	return nil
}

type datagramVersionedSender interface {
	DatagramVersion() string
}

func datagramVersionForSender(sender protocol.DatagramSender) string {
	versioned, ok := sender.(datagramVersionedSender)
	if !ok {
		return protocol.DefaultDatagramVersion
	}
	version := versioned.DatagramVersion()
	if version == "" {
		return protocol.DefaultDatagramVersion
	}
	return version
}
