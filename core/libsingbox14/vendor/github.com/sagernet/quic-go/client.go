package quic

import (
	"context"
	"crypto/tls"
	"errors"
	"net"

	"github.com/sagernet/quic-go/internal/protocol"
)

// make it possible to mock connection ID for initial generation in the tests
var generateConnectionIDForInitial = protocol.GenerateConnectionIDForInitial

// DialAddr establishes a new QUIC connection to a server.
// It resolves the address, and then creates a new UDP connection to dial the QUIC server.
// When the QUIC connection is closed, this UDP connection is closed.
// See [Dial] for more details.
func DialAddr(ctx context.Context, addr string, tlsConf *tls.Config, conf *Config) (*Conn, error) {
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return nil, err
	}
	udpAddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, err
	}
	tr, err := setupTransport(udpConn, tlsConf, conf, true)
	if err != nil {
		return nil, err
	}
	conn, err := tr.dial(ctx, udpAddr, addr, tlsConf, conf, false)
	if err != nil {
		tr.Close()
		return nil, err
	}
	return conn, nil
}

// DialAddrEarly establishes a new 0-RTT QUIC connection to a server.
// See [DialAddr] for more details.
func DialAddrEarly(ctx context.Context, addr string, tlsConf *tls.Config, conf *Config) (*Conn, error) {
	udpConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4zero, Port: 0})
	if err != nil {
		return nil, err
	}
	udpAddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, err
	}
	tr, err := setupTransport(udpConn, tlsConf, conf, true)
	if err != nil {
		return nil, err
	}
	conn, err := tr.dial(ctx, udpAddr, addr, tlsConf, conf, true)
	if err != nil {
		tr.Close()
		return nil, err
	}
	return conn, nil
}

// DialEarly establishes a new 0-RTT QUIC connection to a server using a net.PacketConn.
// See [Dial] for more details.
func DialEarly(ctx context.Context, c net.PacketConn, addr net.Addr, tlsConf *tls.Config, conf *Config) (*Conn, error) {
	dl, err := setupTransport(c, tlsConf, conf, false)
	if err != nil {
		return nil, err
	}
	conn, err := dl.DialEarly(ctx, addr, tlsConf, conf)
	if err != nil {
		dl.Close()
		return nil, err
	}
	return conn, nil
}

// Dial establishes a new QUIC connection to a server using a net.PacketConn.
// If the PacketConn satisfies the [OOBCapablePacketConn] interface (as a [net.UDPConn] does),
// ECN and packet info support will be enabled. In this case, ReadMsgUDP and WriteMsgUDP
// will be used instead of ReadFrom and WriteTo to read/write packets.
// The [tls.Config] must define an application protocol (using tls.Config.NextProtos).
//
// This is a convenience function. More advanced use cases should instantiate a [Transport],
// which offers configuration options for a more fine-grained control of the connection establishment,
// including reusing the underlying UDP socket for multiple QUIC connections.
func Dial(ctx context.Context, c net.PacketConn, addr net.Addr, tlsConf *tls.Config, conf *Config) (*Conn, error) {
	dl, err := setupTransport(c, tlsConf, conf, false)
	if err != nil {
		return nil, err
	}
	conn, err := dl.Dial(ctx, addr, tlsConf, conf)
	if err != nil {
		dl.Close()
		return nil, err
	}
	return conn, nil
}

// DialConn establishes a new QUIC connection to a server over a connected packet-oriented
// net.Conn, such as a conn returned by net.DialUDP. The remote address is taken from the
// conn, and every optimization enabled for a syscall.Conn-capable net.PacketConn is enabled
// here as well, driven by the file descriptor alone.
func DialConn(ctx context.Context, c net.Conn, tlsConf *tls.Config, conf *Config) (*Conn, error) {
	dl, err := setupTransportConn(c, tlsConf, conf)
	if err != nil {
		return nil, err
	}
	conn, err := dl.Dial(ctx, c.RemoteAddr(), tlsConf, conf)
	if err != nil {
		dl.Close()
		return nil, err
	}
	return conn, nil
}

// DialEarlyConn establishes a new 0-RTT QUIC connection to a server over a connected
// packet-oriented net.Conn. See [DialConn] for more details.
func DialEarlyConn(ctx context.Context, c net.Conn, tlsConf *tls.Config, conf *Config) (*Conn, error) {
	dl, err := setupTransportConn(c, tlsConf, conf)
	if err != nil {
		return nil, err
	}
	conn, err := dl.DialEarly(ctx, c.RemoteAddr(), tlsConf, conf)
	if err != nil {
		dl.Close()
		return nil, err
	}
	return conn, nil
}

func setupTransportConn(c net.Conn, tlsConf *tls.Config, conf *Config) (*Transport, error) {
	if tlsConf == nil {
		return nil, errors.New("quic: tls.Config not set")
	}
	conn, err := wrapNetConn(c)
	if err != nil {
		return nil, err
	}
	tr := &Transport{
		Conn:        conn.(net.PacketConn),
		isSingleUse: true,
	}
	if conf != nil && conf.ChromeParrot {
		tr.ConnectionIDGenerator = ZeroLengthConnectionIDGenerator{}
	}
	return tr, nil
}

func setupTransport(c net.PacketConn, tlsConf *tls.Config, conf *Config, createdPacketConn bool) (*Transport, error) {
	if tlsConf == nil {
		return nil, errors.New("quic: tls.Config not set")
	}
	tr := &Transport{
		Conn:        c,
		createdConn: createdPacketConn,
		isSingleUse: true,
	}
	// The zero-length source connection ID a Chrome-parroting client uses can only
	// be chosen here, because the Transport parses every incoming packet's
	// destination connection ID at one fixed length. These Transports are single
	// use, which is the one connection at a time that choice permits.
	if conf != nil && conf.ChromeParrot {
		tr.ConnectionIDGenerator = ZeroLengthConnectionIDGenerator{}
	}
	return tr, nil
}
