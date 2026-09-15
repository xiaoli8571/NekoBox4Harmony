package openvpn

import (
	"context"
	"sync"
	"sync/atomic"
)

type Server struct {
	options                    ServerOptions
	protocol                   string
	listenNetwork              string
	tls                        *tlsServer
	static                     *staticKeyServer
	incomingPacketDropLog      droppedPacketLog
	incomingDataPackets        *dataPacketQueue[ServerDataBuffer]
	droppedIncomingDataPackets atomic.Uint64
	lifecycleAccess            sync.Mutex
	lifecycleState             serverLifecycleState
	closeDone                  chan struct{}
	closeErr                   error
	routes                     *peerRouteRegistry
	ipPool                     *ipPool
}

type serverLifecycleState uint8

const (
	serverLifecycleInitial serverLifecycleState = iota
	serverLifecycleStarting
	serverLifecycleRunning
	serverLifecycleClosing
	serverLifecycleClosed
)

func NewServer(options ServerOptions) (*Server, error) {
	if options.Context == nil {
		options.Context = context.Background()
	}
	protocol, listenNetwork, err := resolveTransportProtocol(options.Transport.Protocol)
	if err != nil {
		return nil, err
	}
	if options.Transport.ListenAddress == "" && options.Transport.Listener == nil && options.Transport.PacketConn == nil {
		return nil, ErrMissingListenAddress
	}
	if options.Transport.ListenAddress == "" {
		if options.Transport.Listener != nil {
			options.Transport.ListenAddress = options.Transport.Listener.Addr().String()
		} else {
			options.Transport.ListenAddress = options.Transport.PacketConn.LocalAddr().String()
		}
	}
	mode, err := validateMode(options.Mode)
	if err != nil {
		return nil, err
	}
	err = validateImplementedServerOptions(options)
	if err != nil {
		return nil, err
	}
	if options.DataChannel.MSSFix == 0 && !options.DataChannel.MSSFixDisabled {
		if options.DataChannel.MTU == 0 || options.DataChannel.MTU == 1500 {
			options.DataChannel.MSSFix = defaultMSSFix
			options.DataChannel.MSSFixMode = MSSFixModeMTU
		} else {
			options.DataChannel.MSSFix = options.DataChannel.MTU
			options.DataChannel.MSSFixMode = MSSFixModeFixed
		}
	}
	if mode == ModeTLS {
		if options.Timing.RenegotiationInterval == 0 && !options.Timing.RenegotiationDisabled {
			options.Timing.RenegotiationInterval = defaultRenegotiationInterval
		}
		if options.Timing.HandWindow == 0 {
			options.Timing.HandWindow = tlsHandshakeTotalDuration
		}
	}
	server := &Server{
		options:             options,
		protocol:            protocol,
		listenNetwork:       listenNetwork,
		incomingDataPackets: newDataPacketQueueWithCapacity[ServerDataBuffer](dataPacketQueueCapacity),
		closeDone:           make(chan struct{}),
		routes:              newPeerRouteRegistry(),
	}
	server.incomingPacketDropLog.logger = options.Logger
	server.incomingPacketDropLog.ctx = options.Context
	if mode == ModeTLS {
		server.tls, err = newTLSServer(server)
		if err != nil {
			return nil, err
		}
	} else {
		server.static = newStaticKeyServer(server)
	}
	return server, nil
}

func (s *Server) Start() error {
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	switch s.lifecycleState {
	case serverLifecycleRunning:
		return nil
	case serverLifecycleStarting:
		return nil
	case serverLifecycleClosing, serverLifecycleClosed:
		return ErrServerClosed
	}
	s.lifecycleState = serverLifecycleStarting
	err := s.prepareServerDataPlane()
	if err != nil {
		s.lifecycleState = serverLifecycleInitial
		return err
	}
	if s.static != nil {
		err = s.static.Start()
	} else {
		err = s.tls.Start()
	}
	if err != nil {
		s.lifecycleState = serverLifecycleInitial
		return err
	}
	s.lifecycleState = serverLifecycleRunning
	return nil
}

func (s *Server) Close() error {
	s.lifecycleAccess.Lock()
	switch s.lifecycleState {
	case serverLifecycleClosing:
		closeDone := s.closeDone
		s.lifecycleAccess.Unlock()
		<-closeDone
		s.lifecycleAccess.Lock()
		closeErr := s.closeErr
		s.lifecycleAccess.Unlock()
		return closeErr
	case serverLifecycleClosed:
		closeErr := s.closeErr
		s.lifecycleAccess.Unlock()
		return closeErr
	default:
		s.lifecycleState = serverLifecycleClosing
		s.lifecycleAccess.Unlock()
	}

	var closeErr error
	if s.static != nil {
		closeErr = s.static.Close()
	} else {
		closeErr = s.tls.Close()
	}
	s.incomingDataPackets.Drain(func(packet ServerDataBuffer) {
		if packet.Buffer != nil {
			packet.Buffer.Release()
		}
	})

	s.lifecycleAccess.Lock()
	s.closeErr = closeErr
	s.lifecycleState = serverLifecycleClosed
	close(s.closeDone)
	s.lifecycleAccess.Unlock()
	return closeErr
}

func (s *Server) activeLoopContext() (context.Context, error) {
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	switch s.lifecycleState {
	case serverLifecycleRunning:
		if s.static != nil {
			return s.static.loopContext, nil
		}
		if !s.tls.isRunning() {
			return nil, ErrServerClosed
		}
		return s.tls.loopContext, nil
	case serverLifecycleClosing, serverLifecycleClosed:
		return nil, ErrServerClosed
	default:
		return nil, ErrDataChannelNotReady
	}
}

func (s *Server) requireRunning() error {
	s.lifecycleAccess.Lock()
	defer s.lifecycleAccess.Unlock()
	switch s.lifecycleState {
	case serverLifecycleRunning:
		if s.tls != nil && !s.tls.isRunning() {
			return ErrServerClosed
		}
		return nil
	case serverLifecycleClosing, serverLifecycleClosed:
		return ErrServerClosed
	default:
		return ErrDataChannelNotReady
	}
}
