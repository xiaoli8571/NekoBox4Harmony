package cloudflared

import (
	"context"
	"net"
	"time"

	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type routedPipeTCPOptions struct {
	timeout     time.Duration
	onHandshake func(net.Conn)
}

func (s *Service) dialRouterTCPWithMetadata(ctx context.Context, destination M.Socksaddr, options routedPipeTCPOptions) (net.Conn, func(), error) {
	dialCtx := ctx
	var cancel context.CancelFunc
	if options.timeout > 0 {
		dialCtx, cancel = context.WithTimeout(ctx, options.timeout)
	}
	conn, err := s.connectionDialer.DialContext(dialCtx, N.NetworkTCP, destination)
	if cancel != nil {
		cancel()
	}
	if err != nil {
		return nil, func() {}, err
	}
	if options.onHandshake != nil {
		options.onHandshake(conn)
	}
	return conn, func() { conn.Close() }, nil
}

func applyTCPKeepAlive(conn net.Conn, keepAlive time.Duration) error {
	if keepAlive <= 0 {
		return nil
	}
	type keepAliveConn interface {
		SetKeepAlive(bool) error
		SetKeepAlivePeriod(time.Duration) error
	}
	tcpConn, ok := conn.(keepAliveConn)
	if !ok {
		return nil
	}
	err := tcpConn.SetKeepAlive(true)
	if err != nil {
		return err
	}
	return tcpConn.SetKeepAlivePeriod(keepAlive)
}
