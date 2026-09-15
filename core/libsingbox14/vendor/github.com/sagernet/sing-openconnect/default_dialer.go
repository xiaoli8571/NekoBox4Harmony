package openconnect

import (
	"context"
	"net"
	"strconv"

	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type defaultClientDialer struct {
	tcp       net.Dialer
	udp       net.Dialer
	listen    net.ListenConfig
	localPort uint16
}

func (d *defaultClientDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	if N.NetworkName(network) == N.NetworkUDP {
		return d.udp.DialContext(ctx, network, destination.String())
	}
	return d.tcp.DialContext(ctx, network, destination.String())
}

func (d *defaultClientDialer) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	host := ""
	network := N.NetworkUDP
	if destination.IsIPv4() {
		host = net.IPv4zero.String()
		network += "4"
	} else if destination.IsIPv6() {
		host = net.IPv6unspecified.String()
		network += "6"
	}
	return d.listen.ListenPacket(ctx, network, net.JoinHostPort(host, strconv.Itoa(int(d.localPort))))
}
