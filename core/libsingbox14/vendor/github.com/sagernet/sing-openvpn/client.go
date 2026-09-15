package openvpn

import (
	"context"
	"strings"
	"sync"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type Client struct {
	options        ClientOptions
	mode           string
	remotes        []clientRemote
	lifecycle      clientLifecycle
	dataPlane      clientDataPlane
	authentication clientAuthenticationSession
	tunnel         clientTunnelState
}

type clientLifecycle struct {
	access           sync.Mutex
	closeOnce        sync.Once
	started          bool
	closed           bool
	terminalError    error
	supervisorCancel context.CancelFunc
	supervisorDone   chan struct{}
	currentSession   clientSession
	dataReadDone     chan struct{}
	dataReadStopped  bool
	closeErr         error
}

type clientAuthenticationSession struct {
	access                      sync.Mutex
	updated                     chan struct{}
	pendingChallenge            *pendingChallengeState
	staged                      stagedCredentials
	sentInteractiveCredentials  bool
	previousAuthenticationError string
	closed                      bool
}

func NewClient(options ClientOptions) (*Client, error) {
	if options.Context == nil {
		options.Context = context.Background()
	}
	remotes, err := resolveClientRemotes(&options)
	if err != nil {
		return nil, err
	}
	if options.DataChannel.Fragment > 0 {
		for _, remote := range remotes {
			if strings.HasPrefix(remote.remote.Protocol, "tcp") {
				return nil, E.Extend(ErrOptionNotSupported, "fragment with tcp remote")
			}
		}
	}
	mode, err := validateMode(options.Mode)
	if err != nil {
		return nil, err
	}
	if options.Pull.RouteNoPull && !options.Pull.Enabled {
		return nil, E.Extend(ErrOptionNotSupported, "route_nopull without pull")
	}
	if mode == ModeStaticKey {
		if !options.StaticKey.IsSet() {
			return nil, ErrMissingStaticKey
		}
		if options.Timing.RenegotiationInterval > 0 {
			return nil, E.Extend(ErrOptionNotSupported, "reneg_sec in static mode")
		}
		if options.Pull.Enabled {
			return nil, E.Extend(ErrOptionNotSupported, "pull in static mode")
		}
		if options.Pull.RouteNoPull {
			return nil, E.Extend(ErrOptionNotSupported, "route_nopull in static mode")
		}
		if options.Authentication.Username != "" || options.Authentication.Password != "" || options.Authentication.StaticChallenge != "" {
			return nil, E.Extend(ErrOptionNotSupported, "username/password in static mode")
		}
	}
	compressionSettingsValue, err := resolveCompressionSettings(options.DataChannel.Compression, options.DataChannel.CompressionLZO)
	if err != nil {
		return nil, err
	}
	allowCompressionPolicyValue, err := resolveEffectiveAllowCompressionPolicy(
		options.DataChannel.AllowCompression,
		compressionSettingsValue,
	)
	if err != nil {
		return nil, err
	}
	err = validateImplementedClientOptions(options)
	if err != nil {
		return nil, err
	}
	if options.DataChannel.MSSFix == 0 && !options.DataChannel.MSSFixDisabled {
		if options.DataChannel.Fragment > 0 {
			options.DataChannel.MSSFix = options.DataChannel.Fragment
			options.DataChannel.MSSFixMode = MSSFixModeMTU
		} else if options.DataChannel.MTU == 0 || options.DataChannel.MTU == 1500 {
			options.DataChannel.MSSFix = defaultMSSFix
			options.DataChannel.MSSFixMode = MSSFixModeMTU
		} else {
			options.DataChannel.MSSFix = options.DataChannel.MTU
			options.DataChannel.MSSFixMode = MSSFixModeFixed
		}
	}
	if mode == ModeTLS {
		if options.Timing.TLSTimeout == 0 {
			options.Timing.TLSTimeout = tlsHandshakeRetryInitial
		}
		if options.Timing.HandWindow == 0 {
			options.Timing.HandWindow = tlsHandshakeTotalDuration
		}
		if options.Timing.RenegotiationInterval == 0 && !options.Timing.RenegotiationDisabled {
			options.Timing.RenegotiationInterval = defaultRenegotiationInterval
		}
	}
	client := &Client{
		options: options,
		mode:    mode,
		remotes: remotes,
		lifecycle: clientLifecycle{
			dataReadDone: make(chan struct{}),
		},
		dataPlane: clientDataPlane{
			allowCompressionPolicy: allowCompressionPolicyValue,
			compression:            compressionSettingsValue,
			incomingDataPackets:    newDataPacketQueueWithCapacity[*buf.Buffer](dataPacketQueueCapacity),
		},
		authentication: clientAuthenticationSession{
			updated: make(chan struct{}),
		},
		tunnel: clientTunnelState{
			configuration: buildInitialTunnelConfiguration(options),
			dispatcher: clientTunnelConfigurationDispatcher{
				wake: make(chan struct{}, 1),
			},
		},
	}
	client.dataPlane.framing.Store(newDataChannelFraming(compressionSettingsValue, options.DataChannel.Fragment, allowCompressionPolicyValue))
	client.dataPlane.incomingPacketDropLog.logger = options.Logger
	client.dataPlane.incomingPacketDropLog.ctx = options.Context
	client.dataPlane.outgoingPacketDropLog.logger = options.Logger
	client.dataPlane.outgoingPacketDropLog.ctx = options.Context
	return client, nil
}

func (c *Client) Start() error {
	c.lifecycle.access.Lock()
	if c.lifecycle.started {
		c.lifecycle.access.Unlock()
		return nil
	}
	if c.lifecycle.closed {
		c.lifecycle.access.Unlock()
		return ErrClientClosed
	}
	supervisorContext, cancelSupervisor := context.WithCancel(c.options.Context)
	c.lifecycle.supervisorCancel = cancelSupervisor
	c.lifecycle.supervisorDone = make(chan struct{})
	c.lifecycle.started = true
	c.lifecycle.access.Unlock()
	c.startTunnelConfigurationDispatcher()
	go c.runSupervisor(supervisorContext)
	return nil
}

func (c *Client) Ready() bool {
	return c.readySession() != nil
}

func (c *Client) RestartSession() {
	c.lifecycle.access.Lock()
	session := c.lifecycle.currentSession
	c.lifecycle.access.Unlock()
	if session != nil {
		session.Fail(E.New("session restart requested"))
	}
}

func (c *Client) Close() error {
	c.lifecycle.closeOnce.Do(func() {
		var supervisorDone chan struct{}
		var currentSession clientSession
		c.lifecycle.access.Lock()
		c.lifecycle.closed = true
		c.stopDataReadsLocked()
		if c.lifecycle.supervisorCancel != nil {
			c.lifecycle.supervisorCancel()
		}
		supervisorDone = c.lifecycle.supervisorDone
		currentSession = c.lifecycle.currentSession
		c.lifecycle.currentSession = nil
		c.lifecycle.access.Unlock()
		c.authentication.access.Lock()
		c.authentication.pendingChallenge = nil
		c.authentication.closed = true
		c.signalChallengeUpdatedLocked()
		c.authentication.access.Unlock()
		c.stopTunnelConfigurationDispatcher()
		if currentSession != nil {
			c.lifecycle.closeErr = currentSession.Close()
		}
		if supervisorDone != nil {
			<-supervisorDone
		}
		c.dataPlane.incomingDataPackets.Drain(func(packetBuffer *buf.Buffer) {
			packetBuffer.Release()
		})
	})
	return c.lifecycle.closeErr
}
