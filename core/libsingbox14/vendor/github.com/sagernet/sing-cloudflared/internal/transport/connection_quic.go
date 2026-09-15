package transport

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/quic-go"
	"github.com/sagernet/sing-cloudflared/internal/control"
	"github.com/sagernet/sing-cloudflared/internal/discovery"
	"github.com/sagernet/sing-cloudflared/internal/protocol"
	"github.com/sagernet/sing/common/bufio"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"

	"github.com/google/uuid"
)

const (
	QuicEdgeSNI  = "quic.cftunnel.com"
	QuicEdgeALPN = "argotunnel"

	quicHandshakeIdleTimeout = 5 * time.Second
	quicMaxIdleTimeout       = 5 * time.Second
	quicKeepAlivePeriod      = 1 * time.Second
)

var DialQUIC = func(ctx context.Context, packetConn net.PacketConn, addr net.Addr, tlsConfig *tls.Config, quicConfig *quic.Config) (*quic.Conn, error) {
	return quic.Dial(ctx, packetConn, addr, tlsConfig, quicConfig)
}

func QuicInitialPacketSize(ipVersion int) uint16 {
	initialPacketSize := uint16(1252)
	if ipVersion == 4 {
		initialPacketSize = 1232
	}
	return initialPacketSize
}

type QUICConnection struct {
	conn                quicConn
	logger              logger.ContextLogger
	edgeAddr            *discovery.EdgeAddr
	connIndex           uint8
	credentials         protocol.Credentials
	connectorID         uuid.UUID
	datagramVersion     string
	features            []string
	numPreviousAttempts uint8
	gracePeriod         time.Duration
	registrationClient  control.RegistrationRPCClient
	registrationResult  *protocol.RegistrationResult
	onConnected         func()

	serveCtx          context.Context
	serveCancel       context.CancelFunc
	registrationClose sync.Once
	shutdownOnce      sync.Once
	closeOnce         sync.Once
}

type QuicStreamHandle interface {
	io.Reader
	io.Writer
	io.Closer
	CancelRead(code quic.StreamErrorCode)
	CancelWrite(code quic.StreamErrorCode)
	SetWriteDeadline(t time.Time) error
}

type quicConn interface {
	OpenStream() (QuicStreamHandle, error)
	AcceptStream(ctx context.Context) (QuicStreamHandle, error)
	ReceiveDatagram(ctx context.Context) ([]byte, error)
	SendDatagram(data []byte) error
	LocalAddr() net.Addr
	CloseWithError(code quic.ApplicationErrorCode, reason string) error
}

type closeableQUICConn struct {
	*quic.Conn
	packetConn net.PacketConn
}

func (c *closeableQUICConn) CloseWithError(code quic.ApplicationErrorCode, reason string) error {
	err := c.Conn.CloseWithError(code, reason)
	_ = c.packetConn.Close()
	return err
}

func (c *closeableQUICConn) OpenStream() (QuicStreamHandle, error) {
	return c.Conn.OpenStream()
}

func (c *closeableQUICConn) AcceptStream(ctx context.Context) (QuicStreamHandle, error) {
	return c.Conn.AcceptStream(ctx)
}

func NewQUICConnection(
	ctx context.Context,
	edgeAddr *discovery.EdgeAddr,
	connIndex uint8,
	credentials protocol.Credentials,
	connectorID uuid.UUID,
	datagramVersion string,
	features []string,
	numPreviousAttempts uint8,
	gracePeriod time.Duration,
	tunnelDialer N.Dialer,
	onConnected func(),
	log logger.ContextLogger,
) (*QUICConnection, error) {
	rootCAs, err := CloudflareRootCertPool()
	if err != nil {
		return nil, E.Cause(err, "load Cloudflare root CAs")
	}

	tlsConfig := NewEdgeTLSConfig(rootCAs, QuicEdgeSNI, []string{QuicEdgeALPN})
	ApplyPostQuantumCurvePreferences(tlsConfig, features)

	quicConfig := &quic.Config{
		HandshakeIdleTimeout:  quicHandshakeIdleTimeout,
		MaxIdleTimeout:        quicMaxIdleTimeout,
		KeepAlivePeriod:       quicKeepAlivePeriod,
		MaxIncomingStreams:    1 << 60,
		MaxIncomingUniStreams: 1 << 60,
		EnableDatagrams:       true,
		InitialPacketSize:     QuicInitialPacketSize(edgeAddr.IPVersion),
	}

	packetConn, err := createPacketConnForConnIndex(ctx, edgeAddr, tunnelDialer)
	if err != nil {
		return nil, E.Cause(err, "dial UDP for QUIC edge")
	}

	conn, err := DialQUIC(ctx, packetConn, edgeAddr.UDP, tlsConfig, quicConfig)
	if err != nil {
		packetConn.Close()
		return nil, E.Cause(err, "dial QUIC edge")
	}

	return &QUICConnection{
		conn:                &closeableQUICConn{Conn: conn, packetConn: packetConn},
		logger:              log,
		edgeAddr:            edgeAddr,
		connIndex:           connIndex,
		credentials:         credentials,
		connectorID:         connectorID,
		datagramVersion:     datagramVersion,
		features:            features,
		numPreviousAttempts: numPreviousAttempts,
		gracePeriod:         gracePeriod,
		onConnected:         onConnected,
	}, nil
}

func createPacketConnForConnIndex(ctx context.Context, edgeAddr *discovery.EdgeAddr, tunnelDialer N.Dialer) (net.PacketConn, error) {
	conn, err := tunnelDialer.DialContext(ctx, N.NetworkUDP, M.SocksaddrFrom(edgeAddr.UDP.AddrPort().Addr(), edgeAddr.UDP.AddrPort().Port()))
	if err != nil {
		return nil, err
	}
	return bufio.NewUnbindPacketConn(conn), nil
}

func (q *QUICConnection) Serve(ctx context.Context, handler StreamHandler) error {
	controlStream, err := q.conn.OpenStream()
	if err != nil {
		return E.Cause(err, "open control stream")
	}

	err = q.register(ctx, controlStream)
	if err != nil {
		controlStream.Close()
		q.Close()
		return err
	}

	q.logger.Info("connected to ", q.registrationResult.Location,
		" (connection ", q.registrationResult.ConnectionID, ")")

	serveCtx, serveCancel := context.WithCancel(context.WithoutCancel(ctx))
	q.serveCtx = serveCtx
	q.serveCancel = serveCancel

	errChan := make(chan error, 2)

	go func() {
		errChan <- q.acceptStreams(serveCtx, handler)
	}()

	go func() {
		errChan <- q.handleDatagrams(serveCtx, handler)
	}()

	select {
	case <-ctx.Done():
		q.gracefulShutdown()
		<-errChan
		return ctx.Err()
	case err = <-errChan:
		q.forceClose()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return err
	}
}

func (q *QUICConnection) register(ctx context.Context, stream QuicStreamHandle) error {
	q.registrationClient = control.NewRegistrationClient(ctx, NewStreamReadWriteCloser(stream))

	host, _, _ := net.SplitHostPort(q.conn.LocalAddr().String())
	originLocalIP := net.ParseIP(host)
	options := control.BuildConnectionOptions(q.connectorID, q.features, q.numPreviousAttempts, originLocalIP)
	result, err := q.registrationClient.RegisterConnection(
		ctx, q.credentials.Auth(), q.credentials.TunnelID, q.connIndex, options,
	)
	if err != nil {
		return E.Cause(err, "register connection")
	}
	err = control.ValidateRegistrationResult(result)
	if err != nil {
		return err
	}
	q.registrationResult = result
	if q.onConnected != nil {
		q.onConnected()
	}
	return nil
}

func (q *QUICConnection) acceptStreams(ctx context.Context, handler StreamHandler) error {
	for {
		stream, err := q.conn.AcceptStream(ctx)
		if err != nil {
			return E.Cause(err, "accept stream")
		}
		go q.handleStream(ctx, stream, handler)
	}
}

func (q *QUICConnection) handleStream(ctx context.Context, stream QuicStreamHandle, handler StreamHandler) {
	rwc := NewStreamReadWriteCloser(stream)
	defer rwc.Close()

	streamType, err := protocol.ReadStreamSignature(rwc)
	if err != nil {
		q.logger.Debug("failed to read stream signature: ", err)
		stream.CancelWrite(0)
		return
	}

	switch streamType {
	case protocol.StreamTypeData:
		var request *protocol.ConnectRequest
		request, err = protocol.ReadConnectRequest(rwc)
		if err != nil {
			q.logger.Debug("failed to read connect request: ", err)
			stream.CancelWrite(0)
			return
		}
		handler.HandleDataStream(ctx, &nopCloserReadWriter{ReadWriteCloser: rwc}, request, q.connIndex)

	case protocol.StreamTypeRPC:
		handler.HandleRPCStreamWithSender(ctx, rwc, q.connIndex, q)
	}
}

func (q *QUICConnection) handleDatagrams(ctx context.Context, handler StreamHandler) error {
	for {
		datagram, err := q.conn.ReceiveDatagram(ctx)
		if err != nil {
			return E.Cause(err, "receive datagram")
		}
		handler.HandleDatagram(ctx, datagram, q)
	}
}

func (q *QUICConnection) SendDatagram(data []byte) error {
	return q.conn.SendDatagram(data)
}

func (q *QUICConnection) DatagramVersion() string {
	return q.datagramVersion
}

func (q *QUICConnection) OpenRPCStream(ctx context.Context) (io.ReadWriteCloser, error) {
	stream, err := q.conn.OpenStream()
	if err != nil {
		return nil, E.Cause(err, "open rpc stream")
	}
	rwc := NewStreamReadWriteCloser(stream)
	err = protocol.WriteRPCStreamSignature(rwc)
	if err != nil {
		rwc.Close()
		return nil, E.Cause(err, "write rpc stream signature")
	}
	return rwc, nil
}

func (q *QUICConnection) gracefulShutdown() {
	q.shutdownOnce.Do(func() {
		if q.registrationClient == nil || q.registrationResult == nil {
			q.closeNow("connection closed")
			return
		}

		ctx, cancel := context.WithTimeout(context.Background(), q.gracePeriod)
		err := q.registrationClient.Unregister(ctx)
		cancel()
		if err != nil {
			q.logger.Debug("failed to unregister: ", err)
		}
		q.closeRegistrationClient()
		if q.gracePeriod > 0 {
			waitCtx := q.serveCtx
			if waitCtx == nil {
				waitCtx = context.Background()
			}
			timer := time.NewTimer(q.gracePeriod)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-waitCtx.Done():
			}
		}
		q.closeNow("graceful shutdown")
	})
}

func (q *QUICConnection) forceClose() {
	q.shutdownOnce.Do(func() {
		q.closeNow("connection closed")
	})
}

func (q *QUICConnection) closeRegistrationClient() {
	q.registrationClose.Do(func() {
		if q.registrationClient != nil {
			_ = q.registrationClient.Close()
		}
	})
}

func (q *QUICConnection) closeNow(reason string) {
	q.closeOnce.Do(func() {
		if q.serveCancel != nil {
			q.serveCancel()
		}
		q.closeRegistrationClient()
		_ = q.conn.CloseWithError(0, reason)
	})
}

func (q *QUICConnection) Close() error {
	q.forceClose()
	return nil
}

type StreamHandler interface {
	HandleDataStream(ctx context.Context, stream io.ReadWriteCloser, request *protocol.ConnectRequest, connIndex uint8)
	HandleRPCStream(ctx context.Context, stream io.ReadWriteCloser, connIndex uint8)
	HandleRPCStreamWithSender(ctx context.Context, stream io.ReadWriteCloser, connIndex uint8, sender protocol.DatagramSender)
	HandleDatagram(ctx context.Context, datagram []byte, sender protocol.DatagramSender)
}

type streamReadWriteCloser struct {
	stream      QuicStreamHandle
	writeAccess sync.Mutex
}

func NewStreamReadWriteCloser(stream QuicStreamHandle) *streamReadWriteCloser {
	return &streamReadWriteCloser{stream: stream}
}

func (s *streamReadWriteCloser) Read(p []byte) (int, error) {
	return s.stream.Read(p)
}

func (s *streamReadWriteCloser) Write(p []byte) (int, error) {
	s.writeAccess.Lock()
	defer s.writeAccess.Unlock()
	return s.stream.Write(p)
}

func (s *streamReadWriteCloser) Close() error {
	_ = s.stream.SetWriteDeadline(time.Now())
	s.writeAccess.Lock()
	defer s.writeAccess.Unlock()
	s.stream.CancelRead(0)
	return s.stream.Close()
}

type nopCloserReadWriter struct {
	io.ReadWriteCloser

	sawEOF bool
	closed atomic.Bool
}

func (n *nopCloserReadWriter) Read(p []byte) (int, error) {
	if n.sawEOF {
		return 0, io.EOF
	}
	if n.closed.Load() {
		return 0, E.New("closed by handler")
	}

	readLen, err := n.ReadWriteCloser.Read(p)
	if err == io.EOF {
		n.sawEOF = true
	}
	return readLen, err
}

func (n *nopCloserReadWriter) Close() error {
	n.closed.Store(true)
	return nil
}
