package transport

import (
	"context"
	"crypto/tls"
	"io"
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-cloudflared/internal/config"
	"github.com/sagernet/sing-cloudflared/internal/control"
	"github.com/sagernet/sing-cloudflared/internal/discovery"
	"github.com/sagernet/sing-cloudflared/internal/protocol"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"

	"github.com/google/uuid"
	"golang.org/x/net/http2"
)

const (
	H2EdgeSNI                        = "h2.cftunnel.com"
	H2ResponseMetaCloudflared        = `{"src":"cloudflared"}`
	h2ResponseMetaCloudflaredLimited = `{"src":"cloudflared","flow_rate_limited":true}`
	contentTypeHeader                = "content-type"
	contentLengthHeader              = "content-length"
	transferEncodingHeader           = "transfer-encoding"
	chunkTransferEncoding            = "chunked"
	sseContentType                   = "text/event-stream"
	grpcContentType                  = "application/grpc"
	ndjsonContentType                = "application/x-ndjson"
)

var FlushableContentTypes = []string{sseContentType, grpcContentType, ndjsonContentType}

type HTTP2Handler interface {
	DispatchRequest(ctx context.Context, stream io.ReadWriteCloser, writer protocol.ConnectResponseWriter, request *protocol.ConnectRequest)
	ApplyConfig(version int32, config []byte) config.UpdateResult
	NotifyConnected(connIndex uint8, protocol string)
}

type HTTP2Connection struct {
	conn         net.Conn
	server       *http2.Server
	logger       logger.ContextLogger
	edgeAddr     *discovery.EdgeAddr
	connIndex    uint8
	credentials  protocol.Credentials
	connectorID  uuid.UUID
	features     []string
	gracePeriod  time.Duration
	tunnelDialer N.Dialer
	handler      HTTP2Handler

	numPreviousAttempts uint8
	registrationClient  control.RegistrationRPCClient
	registrationResult  *protocol.RegistrationResult
	controlStreamErr    error

	activeRequests    sync.WaitGroup
	serveCancel       context.CancelFunc
	registrationClose sync.Once
	shutdownOnce      sync.Once
	closeOnce         sync.Once
}

func NewHTTP2Connection(
	ctx context.Context,
	edgeAddr *discovery.EdgeAddr,
	connIndex uint8,
	credentials protocol.Credentials,
	connectorID uuid.UUID,
	features []string,
	numPreviousAttempts uint8,
	gracePeriod time.Duration,
	tunnelDialer N.Dialer,
	handler HTTP2Handler,
	log logger.ContextLogger,
) (*HTTP2Connection, error) {
	rootCAs, err := CloudflareRootCertPool()
	if err != nil {
		return nil, E.Cause(err, "load Cloudflare root CAs")
	}

	tlsConfig := NewEdgeTLSConfig(rootCAs, H2EdgeSNI, nil)

	tcpConn, err := tunnelDialer.DialContext(ctx, "tcp", M.SocksaddrFrom(edgeAddr.TCP.AddrPort().Addr(), edgeAddr.TCP.AddrPort().Port()))
	if err != nil {
		return nil, E.Cause(err, "dial edge TCP")
	}

	tlsConn := tls.Client(tcpConn, tlsConfig)
	err = tlsConn.HandshakeContext(ctx)
	if err != nil {
		tcpConn.Close()
		return nil, E.Cause(err, "TLS handshake")
	}

	return &HTTP2Connection{
		conn: tlsConn,
		server: &http2.Server{
			MaxConcurrentStreams: math.MaxUint32,
		},
		logger:              log,
		edgeAddr:            edgeAddr,
		connIndex:           connIndex,
		credentials:         credentials,
		connectorID:         connectorID,
		features:            features,
		numPreviousAttempts: numPreviousAttempts,
		gracePeriod:         gracePeriod,
		tunnelDialer:        tunnelDialer,
		handler:             handler,
	}, nil
}

func (c *HTTP2Connection) Serve(ctx context.Context) error {
	serveCtx, serveCancel := context.WithCancel(context.WithoutCancel(ctx))
	c.serveCancel = serveCancel

	shutdownDone := make(chan struct{})
	go func() {
		<-ctx.Done()
		c.gracefulShutdown()
		close(shutdownDone)
	}()

	c.server.ServeConn(c.conn, &http2.ServeConnOpts{
		Context: serveCtx,
		Handler: c,
	})

	if ctx.Err() != nil {
		<-shutdownDone
		return ctx.Err()
	}
	if c.controlStreamErr != nil {
		return c.controlStreamErr
	}
	if c.registrationResult == nil {
		return E.New("edge connection closed before registration")
	}
	return E.New("edge connection closed")
}

func (c *HTTP2Connection) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(protocol.H2HeaderUpgrade) == protocol.H2UpgradeControlStream {
		c.handleControlStream(r.Context(), r, w)
		return
	}

	c.activeRequests.Add(1)
	defer c.activeRequests.Done()

	switch {
	case r.Header.Get(protocol.H2HeaderUpgrade) == protocol.H2UpgradeWebsocket:
		c.handleH2DataStream(r.Context(), r, w, protocol.ConnectionTypeWebsocket)
	case r.Header.Get(protocol.H2HeaderTCPSrc) != "":
		c.handleH2DataStream(r.Context(), r, w, protocol.ConnectionTypeTCP)
	case r.Header.Get(protocol.H2HeaderUpgrade) == protocol.H2UpgradeConfiguration:
		c.handleConfigurationUpdate(r, w)
	default:
		c.handleH2DataStream(r.Context(), r, w, protocol.ConnectionTypeHTTP)
	}
}

func (c *HTTP2Connection) handleControlStream(ctx context.Context, r *http.Request, w http.ResponseWriter) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		c.logger.Error("response writer does not support flushing")
		return
	}

	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	flushWriter := &HTTP2FlushWriter{w: w, flusher: flusher}
	defer flushWriter.CloseWrapper()
	stream := NewHTTP2Stream(r.Body, flushWriter)

	c.registrationClient = control.NewRegistrationClient(ctx, stream)

	host, _, _ := net.SplitHostPort(c.conn.LocalAddr().String())
	originLocalIP := net.ParseIP(host)
	options := control.BuildConnectionOptions(c.connectorID, c.features, c.numPreviousAttempts, originLocalIP)
	result, err := c.registrationClient.RegisterConnection(
		ctx, c.credentials.Auth(), c.credentials.TunnelID, c.connIndex, options,
	)
	if err != nil {
		c.controlStreamErr = err
		c.logger.Error("register connection: ", err)
		go c.forceClose()
		return
	}
	err = control.ValidateRegistrationResult(result)
	if err != nil {
		c.controlStreamErr = err
		c.logger.Error("register connection: ", err)
		go c.forceClose()
		return
	}
	c.registrationResult = result
	c.handler.NotifyConnected(c.connIndex, ProtocolHTTP2)

	c.logger.Info("connected to ", result.Location,
		" (connection ", result.ConnectionID, ")")

	<-ctx.Done()
}

func (c *HTTP2Connection) handleH2DataStream(ctx context.Context, r *http.Request, w http.ResponseWriter, connectionType protocol.ConnectionType) {
	r.Header.Del(protocol.H2HeaderUpgrade)
	r.Header.Del(protocol.H2HeaderTCPSrc)

	flusher, ok := w.(http.Flusher)
	if !ok {
		c.logger.Error("response writer does not support flushing")
		return
	}

	var destination string
	if connectionType == protocol.ConnectionTypeTCP {
		destination = r.Host
		if destination == "" && r.URL != nil {
			destination = r.URL.Host
		}
	} else {
		if r.URL.Scheme == "" {
			r.URL.Scheme = "http"
		}
		if r.URL.Host == "" {
			r.URL.Host = r.Host
		}
		destination = r.URL.String()
	}

	request := &protocol.ConnectRequest{
		Dest: destination,
		Type: connectionType,
	}
	request.Metadata = append(request.Metadata, protocol.Metadata{
		Key: protocol.MetadataHTTPMethod,
		Val: r.Method,
	})
	request.Metadata = append(request.Metadata, protocol.Metadata{
		Key: protocol.MetadataHTTPHost,
		Val: r.Host,
	})
	for name, values := range r.Header {
		for _, value := range values {
			request.Metadata = append(request.Metadata, protocol.Metadata{
				Key: protocol.MetadataHTTPHeaderPrefix + name,
				Val: value,
			})
		}
	}

	flushState := &HTTP2FlushState{shouldFlush: connectionType != protocol.ConnectionTypeHTTP}
	stream := &HTTP2DataStream{
		reader:  r.Body,
		writer:  w,
		flusher: flusher,
		state:   flushState,
		logger:  c.logger,
	}
	respWriter := &HTTP2ResponseWriter{
		writer:     w,
		flusher:    flusher,
		flushState: flushState,
	}

	c.handler.DispatchRequest(ctx, stream, respWriter, request)
}

type h2ConfigurationUpdateResponse struct {
	LastAppliedVersion int32   `json:"lastAppliedVersion"`
	Err                *string `json:"err"`
}

type h2ConfigurationUpdateBody struct {
	Version int32           `json:"version"`
	Config  json.RawMessage `json:"config"`
}

func (c *HTTP2Connection) handleConfigurationUpdate(r *http.Request, w http.ResponseWriter) {
	var body h2ConfigurationUpdateBody
	err := json.NewDecoder(r.Body).Decode(&body)
	if err != nil {
		c.logger.Error("decode configuration update: ", err)
		w.Header().Set(protocol.H2HeaderResponseMeta, H2ResponseMetaCloudflared)
		w.WriteHeader(http.StatusBadGateway)
		return
	}
	result := c.handler.ApplyConfig(body.Version, body.Config)
	w.WriteHeader(http.StatusOK)
	response := h2ConfigurationUpdateResponse{
		LastAppliedVersion: result.LastAppliedVersion,
	}
	if result.Err != nil {
		errString := result.Err.Error()
		response.Err = &errString
	}
	data, _ := json.Marshal(response)
	w.Write(data)
}

func (c *HTTP2Connection) gracefulShutdown() {
	c.shutdownOnce.Do(func() {
		if c.registrationClient == nil || c.registrationResult == nil {
			c.closeNow()
			return
		}

		unregisterCtx, cancel := context.WithTimeout(context.Background(), c.gracePeriod)
		err := c.registrationClient.Unregister(unregisterCtx)
		cancel()
		if err != nil {
			c.logger.Debug("failed to unregister: ", err)
		}
		c.closeRegistrationClient()
		c.waitForActiveRequests(c.gracePeriod)
		c.closeNow()
	})
}

func (c *HTTP2Connection) forceClose() {
	c.shutdownOnce.Do(func() {
		c.closeNow()
	})
}

func (c *HTTP2Connection) waitForActiveRequests(timeout time.Duration) {
	if timeout <= 0 {
		c.activeRequests.Wait()
		return
	}

	done := make(chan struct{})
	go func() {
		c.activeRequests.Wait()
		close(done)
	}()

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case <-done:
	case <-timer.C:
	}
}

func (c *HTTP2Connection) closeRegistrationClient() {
	c.registrationClose.Do(func() {
		if c.registrationClient != nil {
			_ = c.registrationClient.Close()
		}
	})
}

func (c *HTTP2Connection) closeNow() {
	c.closeOnce.Do(func() {
		_ = c.conn.Close()
		if c.serveCancel != nil {
			c.serveCancel()
		}
		c.closeRegistrationClient()
		c.activeRequests.Wait()
	})
}

func (c *HTTP2Connection) Close() error {
	c.forceClose()
	return nil
}

type HTTP2Stream struct {
	reader io.ReadCloser
	writer io.Writer
}

func NewHTTP2Stream(reader io.ReadCloser, writer io.Writer) *HTTP2Stream {
	return &HTTP2Stream{reader: reader, writer: writer}
}

func (s *HTTP2Stream) Read(p []byte) (int, error)  { return s.reader.Read(p) }
func (s *HTTP2Stream) Write(p []byte) (int, error) { return s.writer.Write(p) }
func (s *HTTP2Stream) Close() error                { return s.reader.Close() }

type HTTP2FlushWriter struct {
	w       http.ResponseWriter
	flusher http.Flusher
	access  sync.Mutex
	closed  bool
}

func (w *HTTP2FlushWriter) Write(p []byte) (int, error) {
	w.access.Lock()
	defer w.access.Unlock()
	if w.closed {
		return 0, net.ErrClosed
	}
	n, err := w.w.Write(p)
	if err == nil {
		w.flusher.Flush()
	}
	return n, err
}

func (w *HTTP2FlushWriter) CloseWrapper() error {
	w.access.Lock()
	w.closed = true
	w.access.Unlock()
	return nil
}

type HTTP2DataStream struct {
	reader  io.ReadCloser
	writer  http.ResponseWriter
	flusher http.Flusher
	state   *HTTP2FlushState
	logger  logger.ContextLogger
}

func (s *HTTP2DataStream) Read(p []byte) (int, error) {
	return s.reader.Read(p)
}

func (s *HTTP2DataStream) Write(p []byte) (n int, err error) {
	n, err = s.writer.Write(p)
	if err == nil && s.state != nil && s.state.shouldFlush {
		s.flusher.Flush()
	}
	return n, err
}

func (s *HTTP2DataStream) Close() error {
	return s.reader.Close()
}

type HTTP2ResponseWriter struct {
	writer      http.ResponseWriter
	flusher     http.Flusher
	headersSent bool
	flushState  *HTTP2FlushState
}

func (w *HTTP2ResponseWriter) AddTrailer(name, value string) {
	if !w.headersSent {
		return
	}
	w.writer.Header().Add(http2.TrailerPrefix+name, value)
}

func (w *HTTP2ResponseWriter) WriteResponse(responseError error, metadata []protocol.Metadata) error {
	if w.headersSent {
		return nil
	}
	w.headersSent = true

	if responseError != nil {
		if protocol.HasFlowConnectRateLimited(metadata) {
			w.writer.Header().Set(protocol.H2HeaderResponseMeta, h2ResponseMetaCloudflaredLimited)
		} else {
			w.writer.Header().Set(protocol.H2HeaderResponseMeta, H2ResponseMetaCloudflared)
		}
		w.writer.WriteHeader(http.StatusBadGateway)
		w.flusher.Flush()
		return nil
	}

	statusCode := http.StatusOK
	userHeaders := make(http.Header)

	for _, entry := range metadata {
		if entry.Key == protocol.MetadataHTTPStatus {
			code, err := strconv.Atoi(entry.Val)
			if err == nil {
				statusCode = code
			}
			continue
		}
		if strings.HasPrefix(entry.Key, protocol.MetadataHTTPHeader+":") {
			headerName := strings.TrimPrefix(entry.Key, protocol.MetadataHTTPHeader+":")
			lower := strings.ToLower(headerName)

			if lower == "content-length" {
				w.writer.Header().Set(headerName, entry.Val)
			}

			if !protocol.IsControlResponseHeader(lower) || protocol.IsWebsocketClientHeader(lower) {
				userHeaders.Add(headerName, entry.Val)
			}
		}
	}

	w.writer.Header().Set(protocol.H2HeaderResponseUser, protocol.SerializeHeaders(userHeaders))
	w.writer.Header().Set(protocol.H2HeaderResponseMeta, protocol.H2ResponseMetaOrigin)
	if w.flushState != nil && ShouldFlushHTTPHeaders(userHeaders) {
		w.flushState.shouldFlush = true
	}

	if statusCode == http.StatusSwitchingProtocols {
		statusCode = http.StatusOK
	}

	w.writer.WriteHeader(statusCode)
	if w.flushState != nil && w.flushState.shouldFlush {
		w.flusher.Flush()
	}
	return nil
}

type HTTP2FlushState struct {
	shouldFlush bool
}

func ShouldFlushHTTPHeaders(headers http.Header) bool {
	if headers.Get(contentLengthHeader) == "" {
		return true
	}
	transferEncoding := strings.ToLower(headers.Get(transferEncodingHeader))
	if transferEncoding != "" && strings.Contains(transferEncoding, chunkTransferEncoding) {
		return true
	}
	contentType := strings.ToLower(headers.Get(contentTypeHeader))
	for _, flushable := range FlushableContentTypes {
		if strings.HasPrefix(contentType, flushable) {
			return true
		}
	}
	return false
}
