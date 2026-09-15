package openvpn

import (
	"context"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type staticKeyServer struct {
	parent          *Server
	client          *Client
	loopContext     context.Context
	cancelLoop      context.CancelFunc
	transportAccess sync.Mutex
	streamListener  net.Listener
	packetLink      *staticServerPacketLink
	access          sync.RWMutex
	peerAddress     string
	readLoopDone    chan struct{}
}

func newStaticKeyServer(parent *Server) *staticKeyServer {
	return &staticKeyServer{parent: parent}
}

func (s *staticKeyServer) Start() error {
	s.loopContext, s.cancelLoop = context.WithCancel(s.parent.options.Context)
	remote, err := s.prepareTransport()
	if err != nil {
		s.cancelLoop()
		return err
	}
	client, err := NewClient(ClientOptions{
		Context: s.loopContext,
		Mode:    ModeStaticKey,
		Transport: ClientTransportOptions{
			Remotes:     []Remote{remote},
			Protocol:    s.parent.protocol,
			DialContext: s.dialContext,
		},
		DataChannel: ClientDataChannelOptions{
			MTU:              s.parent.options.DataChannel.MTU,
			MSSFix:           s.parent.options.DataChannel.MSSFix,
			MSSFixDisabled:   s.parent.options.DataChannel.MSSFixDisabled,
			MSSFixMode:       s.parent.options.DataChannel.MSSFixMode,
			Cipher:           s.parent.options.DataChannel.Cipher,
			Auth:             s.parent.options.DataChannel.Auth,
			ReplayWindow:     s.parent.options.DataChannel.ReplayWindow,
			ReplayWindowTime: s.parent.options.DataChannel.ReplayWindowTime,
		},
		Tunnel: ClientTunnelOptions{
			DevType:        "tun",
			Topology:       s.parent.options.Tunnel.Topology,
			LocalAddress:   s.parent.options.Tunnel.LocalAddress,
			VPNGateway:     s.parent.options.Tunnel.VPNGateway,
			VPNGatewayIPv6: s.parent.options.Tunnel.VPNGatewayIPv6,
		},
		Timing: ClientTimingOptions{
			PingInterval: s.parent.options.Timing.PingInterval,
			PingRestart:  s.parent.options.Timing.PingRestart,
		},
		StaticKey:    s.parent.options.StaticKey,
		KeyDirection: s.parent.options.KeyDirection,
		Logger:       s.parent.options.Logger,
	})
	if err != nil {
		s.closeTransport()
		s.cancelLoop()
		return err
	}
	s.client = client
	err = client.Start()
	if err != nil {
		s.closeTransport()
		s.cancelLoop()
		_ = client.Close()
		return err
	}
	s.readLoopDone = make(chan struct{})
	go s.readLoop()
	return nil
}

func (s *staticKeyServer) prepareTransport() (Remote, error) {
	if strings.HasPrefix(s.parent.protocol, "tcp") {
		listener := s.parent.options.Transport.Listener
		if listener == nil {
			var err error
			listener, err = net.Listen(s.parent.listenNetwork, s.parent.options.Transport.ListenAddress)
			if err != nil {
				return Remote{}, err
			}
		}
		s.transportAccess.Lock()
		s.streamListener = listener
		s.transportAccess.Unlock()
		host, port, err := splitStaticServerAddress(listener.Addr().String())
		if err != nil {
			return Remote{}, err
		}
		return Remote{Host: host, Port: port, Protocol: s.parent.protocol}, nil
	}
	if s.parent.options.Transport.RemoteAddress == "" {
		return Remote{}, E.New("static_key UDP server requires Transport.RemoteAddress")
	}
	remoteNetworkAddress, err := net.ResolveUDPAddr(s.parent.listenNetwork, s.parent.options.Transport.RemoteAddress)
	if err != nil {
		return Remote{}, err
	}
	packetListener := s.parent.options.Transport.PacketConn
	if packetListener == nil {
		packetListener, err = net.ListenPacket(s.parent.listenNetwork, s.parent.options.Transport.ListenAddress)
		if err != nil {
			return Remote{}, err
		}
	}
	s.transportAccess.Lock()
	s.packetLink = &staticServerPacketLink{listener: packetListener, remoteAddress: remoteNetworkAddress}
	s.transportAccess.Unlock()
	s.setPeerAddress(remoteNetworkAddress.String())
	host, port, err := splitStaticServerAddress(remoteNetworkAddress.String())
	if err != nil {
		return Remote{}, err
	}
	return Remote{Host: host, Port: port, Protocol: s.parent.protocol}, nil
}

func splitStaticServerAddress(address string) (string, uint16, error) {
	host, portString, err := net.SplitHostPort(address)
	if err != nil {
		return "", 0, err
	}
	portValue, err := strconv.ParseUint(portString, 10, 16)
	if err != nil || portValue == 0 {
		return "", 0, E.New("invalid static_key peer port")
	}
	if host == "" || net.ParseIP(host) == nil {
		host = "127.0.0.1"
		if strings.Contains(address, "[") {
			host = "::1"
		}
	}
	return host, uint16(portValue), nil
}

func (s *staticKeyServer) dialContext(ctx context.Context, network string, address string) (net.Conn, error) {
	s.transportAccess.Lock()
	streamListener := s.streamListener
	packetLink := s.packetLink
	s.transportAccess.Unlock()
	if strings.HasPrefix(s.parent.protocol, "tcp") {
		if streamListener == nil {
			return nil, net.ErrClosed
		}
		connection, err := streamListener.Accept()
		if err != nil {
			return nil, err
		}
		s.setPeerAddress(connection.RemoteAddr().String())
		return connection, nil
	}
	if packetLink == nil {
		return nil, net.ErrClosed
	}
	return packetLink.newSession(), nil
}

func (s *staticKeyServer) setPeerAddress(peerAddress string) {
	s.access.Lock()
	s.peerAddress = peerAddress
	s.access.Unlock()
	if s.parent.options.Tunnel.VPNGateway.IsValid() {
		s.parent.routes.Register(s.parent.options.Tunnel.VPNGateway, peerAddress, nil)
	}
	if s.parent.options.Tunnel.VPNGatewayIPv6.IsValid() {
		s.parent.routes.Register(s.parent.options.Tunnel.VPNGatewayIPv6, peerAddress, nil)
	}
}

func (s *staticKeyServer) currentPeerAddress() string {
	s.access.RLock()
	defer s.access.RUnlock()
	return s.peerAddress
}

func (s *staticKeyServer) readLoop() {
	defer close(s.readLoopDone)
	for {
		packet, err := s.client.ReadDataPacket(s.loopContext)
		if err != nil {
			return
		}
		peerAddress := s.currentPeerAddress()
		if peerAddress == "" || !s.validSource(packet) {
			continue
		}
		s.parent.pushIncomingDataPackets([]ServerDataPacket{{PeerAddress: peerAddress, Payload: packet}})
	}
}

func (s *staticKeyServer) validSource(packet []byte) bool {
	source, parsed := sourceFromIPPacket(packet)
	if !parsed {
		return false
	}
	if source.Is4() {
		return s.parent.options.Tunnel.VPNGateway.IsValid() && source == s.parent.options.Tunnel.VPNGateway
	}
	if source.Is6() {
		return s.parent.options.Tunnel.VPNGatewayIPv6.IsValid() && source == s.parent.options.Tunnel.VPNGatewayIPv6
	}
	return false
}

func (s *staticKeyServer) WriteDataPackets(peerAddress string, packets [][]byte) error {
	if peerAddress == "" || peerAddress != s.currentPeerAddress() {
		return ErrPeerNotFound
	}
	return s.client.WriteDataPackets(packets)
}

func (s *staticKeyServer) WriteDataPacketBuffers(peerAddress string, packetBuffers []*buf.Buffer) error {
	if peerAddress == "" || peerAddress != s.currentPeerAddress() {
		buf.ReleaseMulti(packetBuffers)
		return ErrPeerNotFound
	}
	return s.client.WriteDataPacketBuffers(packetBuffers)
}

func (s *staticKeyServer) Close() error {
	if s.cancelLoop != nil {
		s.cancelLoop()
	}
	closeErr := s.closeTransport()
	if s.client != nil {
		closeErr = E.Errors(closeErr, s.client.Close())
	}
	if s.readLoopDone != nil {
		<-s.readLoopDone
	}
	return closeErr
}

func (s *staticKeyServer) closeTransport() error {
	s.transportAccess.Lock()
	streamListener := s.streamListener
	s.streamListener = nil
	packetLink := s.packetLink
	s.packetLink = nil
	s.transportAccess.Unlock()
	var err error
	if streamListener != nil {
		err = E.Errors(err, streamListener.Close())
	}
	if packetLink != nil {
		err = E.Errors(err, packetLink.Close())
	}
	return err
}

// A --secret peer that restarts its tunnel takes the SIGUSR1 path of openvpn.c,
// which re-enters link_socket_init with the unchanged --lport: the bound
// datagram endpoint belongs to the process and keeps answering the peer, while
// the session that used it is the only thing the restart tears down.
type staticServerPacketLink struct {
	listener      net.PacketConn
	remoteAddress net.Addr
	readAccess    sync.Mutex
	writeAccess   sync.Mutex
	stateAccess   sync.Mutex
	activeReader  *staticServerPacketConnection
	closeOnce     sync.Once
	closeErr      error
}

func (l *staticServerPacketLink) newSession() *staticServerPacketConnection {
	return &staticServerPacketConnection{link: l, closed: make(chan struct{})}
}

func (l *staticServerPacketLink) Close() error {
	l.closeOnce.Do(func() {
		l.closeErr = l.listener.Close()
	})
	return l.closeErr
}

func (l *staticServerPacketLink) readFrom(session *staticServerPacketConnection, buffer []byte) (int, net.Addr, error) {
	l.readAccess.Lock()
	defer l.readAccess.Unlock()
	select {
	case <-session.closed:
		return 0, nil, net.ErrClosed
	default:
	}
	l.stateAccess.Lock()
	l.activeReader = session
	readDeadline, _ := session.currentReadDeadline()
	deadlineErr := l.listener.SetReadDeadline(readDeadline)
	l.stateAccess.Unlock()
	if deadlineErr != nil {
		l.finishRead(session)
		return 0, nil, deadlineErr
	}
	dataLength, source, err := l.listener.ReadFrom(buffer)
	l.finishRead(session)
	return dataLength, source, err
}

func (l *staticServerPacketLink) finishRead(session *staticServerPacketConnection) {
	l.stateAccess.Lock()
	if l.activeReader == session {
		l.activeReader = nil
	}
	l.stateAccess.Unlock()
}

func (l *staticServerPacketLink) setReadDeadline(session *staticServerPacketConnection, deadline time.Time) error {
	l.stateAccess.Lock()
	defer l.stateAccess.Unlock()
	session.deadlineAccess.Lock()
	session.readDeadline = deadline
	session.deadlineAccess.Unlock()
	if l.activeReader != session {
		return nil
	}
	return l.listener.SetReadDeadline(deadline)
}

func (l *staticServerPacketLink) interruptRead(session *staticServerPacketConnection) {
	l.stateAccess.Lock()
	defer l.stateAccess.Unlock()
	if l.activeReader != session {
		return
	}
	_ = l.listener.SetReadDeadline(time.Now())
}

func (l *staticServerPacketLink) writeTo(buffer []byte) (int, error) {
	l.writeAccess.Lock()
	defer l.writeAccess.Unlock()
	return l.listener.WriteTo(buffer, l.remoteAddress)
}

type staticServerPacketConnection struct {
	link           *staticServerPacketLink
	deadlineAccess sync.Mutex
	readDeadline   time.Time
	writeDeadline  time.Time
	closeOnce      sync.Once
	closed         chan struct{}
}

func (c *staticServerPacketConnection) Read(buffer []byte) (int, error) {
	for {
		select {
		case <-c.closed:
			return 0, net.ErrClosed
		default:
		}
		readDeadline, hasDeadline := c.currentReadDeadline()
		if hasDeadline && !time.Now().Before(readDeadline) {
			return 0, os.ErrDeadlineExceeded
		}
		dataLength, source, err := c.link.readFrom(c, buffer)
		if err != nil {
			if E.IsTimeout(err) {
				continue
			}
			return 0, err
		}
		if source.String() != c.link.remoteAddress.String() {
			continue
		}
		return dataLength, nil
	}
}

func (c *staticServerPacketConnection) Write(buffer []byte) (int, error) {
	select {
	case <-c.closed:
		return 0, net.ErrClosed
	default:
	}
	writeDeadline, hasDeadline := c.currentWriteDeadline()
	if hasDeadline && !time.Now().Before(writeDeadline) {
		return 0, os.ErrDeadlineExceeded
	}
	return c.link.writeTo(buffer)
}

func (c *staticServerPacketConnection) Close() error {
	c.closeOnce.Do(func() {
		close(c.closed)
		c.link.interruptRead(c)
	})
	return nil
}

func (c *staticServerPacketConnection) LocalAddr() net.Addr {
	return c.link.listener.LocalAddr()
}

func (c *staticServerPacketConnection) RemoteAddr() net.Addr {
	return c.link.remoteAddress
}

func (c *staticServerPacketConnection) SetDeadline(deadline time.Time) error {
	return E.Errors(c.SetReadDeadline(deadline), c.SetWriteDeadline(deadline))
}

func (c *staticServerPacketConnection) SetReadDeadline(deadline time.Time) error {
	return c.link.setReadDeadline(c, deadline)
}

func (c *staticServerPacketConnection) SetWriteDeadline(deadline time.Time) error {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	c.writeDeadline = deadline
	return nil
}

func (c *staticServerPacketConnection) currentReadDeadline() (time.Time, bool) {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	return c.readDeadline, !c.readDeadline.IsZero()
}

func (c *staticServerPacketConnection) currentWriteDeadline() (time.Time, bool) {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	return c.writeDeadline, !c.writeDeadline.IsZero()
}

var _ net.Conn = (*staticServerPacketConnection)(nil)
