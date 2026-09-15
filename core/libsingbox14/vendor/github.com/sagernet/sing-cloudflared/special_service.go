package cloudflared

import (
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"

	"github.com/sagernet/sing-cloudflared/internal/config"
	"github.com/sagernet/sing-cloudflared/internal/protocol"
	"github.com/sagernet/sing-cloudflared/internal/transport"
	"github.com/sagernet/sing/common/bufio"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/ws"
)

var wsAcceptGUID = []byte("258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

const (
	socksReplySuccess             = 0
	socksReplyRuleFailure         = 2
	socksReplyNetworkUnreachable  = 3
	socksReplyHostUnreachable     = 4
	socksReplyConnectionRefused   = 5
	socksReplyCommandNotSupported = 7
)

func (s *Service) handleBastionStream(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, request *protocol.ConnectRequest, service config.ResolvedService) {
	destination, err := resolveBastionDestination(request)
	if err != nil {
		respWriter.WriteResponse(err, nil)
		return
	}
	s.handleRouterBackedStream(ctx, stream, respWriter, request, M.ParseSocksaddr(destination), service.OriginRequest.ProxyType)
}

func (s *Service) handleStreamService(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, request *protocol.ConnectRequest, service config.ResolvedService) {
	if !service.StreamHasPort {
		respWriter.WriteResponse(E.New("address ", streamServiceHostname(service), ": missing port in address"), nil)
		return
	}
	s.handleRouterBackedStream(ctx, stream, respWriter, request, service.Destination, service.OriginRequest.ProxyType)
}

func (s *Service) handleRouterBackedStream(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, request *protocol.ConnectRequest, destination M.Socksaddr, proxyType string) {
	targetConn, cleanup, err := s.dialRouterTCP(ctx, destination)
	if err != nil {
		respWriter.WriteResponse(err, nil)
		return
	}
	defer cleanup()

	err = respWriter.WriteResponse(nil, encodeResponseHeaders(http.StatusSwitchingProtocols, websocketResponseHeaders(request)))
	if err != nil {
		s.logger.ErrorContext(ctx, "write bastion websocket response: ", err)
		return
	}

	wsConn := transport.NewWebsocketConn(newStreamConn(stream), ws.StateServerSide)
	defer wsConn.Close()
	if isSocksProxyType(proxyType) {
		err = serveFixedSocksStream(ctx, wsConn, targetConn)
		if err != nil && !E.IsClosedOrCanceled(err) {
			s.logger.DebugContext(ctx, "socks-over-websocket stream closed: ", err)
		}
		return
	}
	_ = bufio.CopyConn(ctx, wsConn, targetConn)
}

func (s *Service) handleSocksProxyStream(ctx context.Context, stream io.ReadWriteCloser, respWriter protocol.ConnectResponseWriter, request *protocol.ConnectRequest, service config.ResolvedService) {
	err := respWriter.WriteResponse(nil, encodeResponseHeaders(http.StatusSwitchingProtocols, websocketResponseHeaders(request)))
	if err != nil {
		s.logger.ErrorContext(ctx, "write socks-proxy websocket response: ", err)
		return
	}

	wsConn := transport.NewWebsocketConn(newStreamConn(stream), ws.StateServerSide)
	defer wsConn.Close()
	err = s.serveSocksProxy(ctx, wsConn, service.SocksPolicy)
	if err != nil && !E.IsClosedOrCanceled(err) {
		s.logger.DebugContext(ctx, "socks-proxy stream closed: ", err)
	}
}

func resolveBastionDestination(request *protocol.ConnectRequest) (string, error) {
	headerValue := requestHeaderValue(request, "Cf-Access-Jump-Destination")
	if headerValue == "" {
		return "", E.New("missing Cf-Access-Jump-Destination header")
	}
	parsed, err := url.Parse(headerValue)
	if err == nil && parsed.Host != "" {
		headerValue = parsed.Host
	}
	return strings.SplitN(headerValue, "/", 2)[0], nil
}

func websocketResponseHeaders(request *protocol.ConnectRequest) http.Header {
	header := http.Header{}
	header.Set("Connection", "Upgrade")
	header.Set("Upgrade", "websocket")
	secKey := requestHeaderValue(request, "Sec-WebSocket-Key")
	if secKey != "" {
		sum := sha1.Sum(append([]byte(secKey), wsAcceptGUID...))
		header.Set("Sec-WebSocket-Accept", base64.StdEncoding.EncodeToString(sum[:]))
	}
	return header
}

func isSocksProxyType(proxyType string) bool {
	lower := strings.ToLower(strings.TrimSpace(proxyType))
	return lower == "socks" || lower == "socks5"
}

func serveFixedSocksStream(ctx context.Context, conn net.Conn, targetConn net.Conn) error {
	_, err := readSocksHandshake(conn)
	if err != nil {
		return err
	}
	err = writeSocksReply(conn, socksReplySuccess)
	if err != nil {
		return err
	}
	return bufio.CopyConn(ctx, conn, targetConn)
}

func requestHeaderValue(request *protocol.ConnectRequest, headerName string) string {
	for _, entry := range request.Metadata {
		if !strings.HasPrefix(entry.Key, protocol.MetadataHTTPHeaderPrefix) {
			continue
		}
		name := strings.TrimPrefix(entry.Key, protocol.MetadataHTTPHeaderPrefix)
		if strings.EqualFold(name, headerName) {
			return entry.Val
		}
	}
	return ""
}

func streamServiceHostname(service config.ResolvedService) string {
	if service.BaseURL != nil && service.BaseURL.Hostname() != "" {
		return service.BaseURL.Hostname()
	}
	parsedURL, err := url.Parse(service.Service)
	if err == nil && parsedURL.Hostname() != "" {
		return parsedURL.Hostname()
	}
	return service.Destination.AddrString()
}

func (s *Service) dialRouterTCP(ctx context.Context, destination M.Socksaddr) (net.Conn, func(), error) {
	return s.dialRouterTCPWithMetadata(ctx, destination, routedPipeTCPOptions{})
}

func (s *Service) serveSocksProxy(ctx context.Context, conn net.Conn, policy *config.IPRulePolicy) error {
	destination, err := readSocksHandshake(conn)
	if err != nil {
		return err
	}
	allowed, err := policy.Allow(ctx, destination)
	if err != nil {
		_ = writeSocksReply(conn, socksReplyRuleFailure)
		return err
	}
	if !allowed {
		_ = writeSocksReply(conn, socksReplyRuleFailure)
		return E.New("connect to ", destination, " denied by ip_rules")
	}
	targetConn, cleanup, err := s.dialRouterTCP(ctx, destination)
	if err != nil {
		_ = writeSocksReply(conn, socksReplyForDialError(err))
		return err
	}
	defer cleanup()

	err = writeSocksReply(conn, socksReplySuccess)
	if err != nil {
		return err
	}
	return bufio.CopyConn(ctx, conn, targetConn)
}

func writeSocksReply(conn net.Conn, reply byte) error {
	_, err := conn.Write([]byte{5, reply, 0, 1, 0, 0, 0, 0, 0, 0})
	return err
}

func socksReplyForDialError(err error) byte {
	lower := strings.ToLower(err.Error())
	switch {
	case strings.Contains(lower, "refused"):
		return socksReplyConnectionRefused
	case strings.Contains(lower, "network is unreachable"):
		return socksReplyNetworkUnreachable
	default:
		return socksReplyHostUnreachable
	}
}

func readSocksHandshake(conn net.Conn) (M.Socksaddr, error) {
	version := make([]byte, 1)
	_, err := io.ReadFull(conn, version)
	if err != nil {
		return M.Socksaddr{}, err
	}
	if version[0] != 5 {
		return M.Socksaddr{}, E.New("unsupported SOCKS version: ", version[0])
	}

	methodCount := make([]byte, 1)
	_, err = io.ReadFull(conn, methodCount)
	if err != nil {
		return M.Socksaddr{}, err
	}
	methods := make([]byte, int(methodCount[0]))
	_, err = io.ReadFull(conn, methods)
	if err != nil {
		return M.Socksaddr{}, err
	}

	var supportsNoAuth bool
	for _, method := range methods {
		if method == 0 {
			supportsNoAuth = true
			break
		}
	}
	if !supportsNoAuth {
		_, err = conn.Write([]byte{5, 255})
		if err != nil {
			return M.Socksaddr{}, err
		}
		return M.Socksaddr{}, E.New("unknown authentication type")
	}
	_, err = conn.Write([]byte{5, 0})
	if err != nil {
		return M.Socksaddr{}, err
	}

	requestHeader := make([]byte, 4)
	_, err = io.ReadFull(conn, requestHeader)
	if err != nil {
		return M.Socksaddr{}, err
	}
	if requestHeader[0] != 5 {
		return M.Socksaddr{}, E.New("unsupported SOCKS request version: ", requestHeader[0])
	}
	if requestHeader[1] != 1 {
		_ = writeSocksReply(conn, socksReplyCommandNotSupported)
		return M.Socksaddr{}, E.New("unsupported SOCKS command: ", requestHeader[1])
	}
	return readSocksDestination(conn, requestHeader[3])
}

func readSocksDestination(conn net.Conn, addressType byte) (M.Socksaddr, error) {
	switch addressType {
	case 1:
		addr := make([]byte, 4)
		_, err := io.ReadFull(conn, addr)
		if err != nil {
			return M.Socksaddr{}, err
		}
		port, err := readSocksPort(conn)
		if err != nil {
			return M.Socksaddr{}, err
		}
		ipAddr, ok := netip.AddrFromSlice(addr)
		if !ok {
			return M.Socksaddr{}, E.New("invalid IPv4 SOCKS destination")
		}
		return M.SocksaddrFrom(ipAddr, port), nil
	case 3:
		length := make([]byte, 1)
		_, err := io.ReadFull(conn, length)
		if err != nil {
			return M.Socksaddr{}, err
		}
		host := make([]byte, int(length[0]))
		_, err = io.ReadFull(conn, host)
		if err != nil {
			return M.Socksaddr{}, err
		}
		port, err := readSocksPort(conn)
		if err != nil {
			return M.Socksaddr{}, err
		}
		return M.ParseSocksaddr(net.JoinHostPort(string(host), strconv.Itoa(int(port)))), nil
	case 4:
		addr := make([]byte, 16)
		_, err := io.ReadFull(conn, addr)
		if err != nil {
			return M.Socksaddr{}, err
		}
		port, err := readSocksPort(conn)
		if err != nil {
			return M.Socksaddr{}, err
		}
		ipAddr, ok := netip.AddrFromSlice(addr)
		if !ok {
			return M.Socksaddr{}, E.New("invalid IPv6 SOCKS destination")
		}
		return M.SocksaddrFrom(ipAddr, port), nil
	default:
		return M.Socksaddr{}, E.New("unsupported SOCKS address type: ", addressType)
	}
}

func readSocksPort(conn net.Conn) (uint16, error) {
	port := make([]byte, 2)
	_, err := io.ReadFull(conn, port)
	if err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint16(port), nil
}
