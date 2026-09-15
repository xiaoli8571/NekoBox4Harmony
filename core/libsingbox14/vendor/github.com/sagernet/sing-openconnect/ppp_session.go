package openconnect

import (
	"context"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	pppInitialDTLSWindow         = 5 * time.Second
	pppLateDTLSRetryPeriod       = 5 * time.Second
	pppLateDTLSNegotiationWindow = 10 * time.Second
)

type pppSessionState interface {
	attachSession(session *pppSession) error
	detachSession(session *pppSession)
}

type pppSessionHandler interface {
	preparePPP() (pppSessionSetup, error)
	connectPPPTLS() (pppSessionCarrier, error)
	connectPPPDTLS(ctx context.Context) (pppSessionCarrier, error)
	setSkipInitialDTLS(skip bool)
	storePPPConfiguration(state pppSessionConfigurationState)
	recordPPPTermination(termination pppSessionTermination)
}

type pppSessionCarrier struct {
	connection    net.Conn
	datagram      bool
	proposedIPv4  netip.Prefix
	proposedIPv6  netip.Prefix
	localSourceIP netip.Addr
	mtu           uint32
}

type pppCarrierErrorProvider interface {
	pppCarrierError() (error, bool)
	pppCarrierErrorReady() <-chan struct{}
}

type pppSessionSetup struct {
	linkConfiguration pppLinkConfig
	configuration     TunnelConfiguration
	usingDTLS         bool
	dtlsEnabled       bool
	checkSourceIP     bool
	initialSourceIP   netip.Addr
	carrierSourceIP   netip.Addr
}

type pppSessionConfigurationState struct {
	previousIPv4  netip.Prefix
	previousIPv6  netip.Prefix
	localSourceIP netip.Addr
}

type pppSessionTermination struct {
	err       error
	wasReady  bool
	usingDTLS bool
}

type pppSession struct {
	ctx               context.Context
	cancel            context.CancelFunc
	client            *Client
	owner             clientSession
	flavor            string
	state             pppSessionState
	handler           pppSessionHandler
	access            sync.RWMutex
	baseConfiguration TunnelConfiguration
	configuration     TunnelConfiguration
	link              *pppLink
	done              chan error
	doneOnce          sync.Once
	closeOnce         sync.Once
	waitGroup         sync.WaitGroup
	started           bool
	closed            bool
	usingDTLS         bool
	dtlsEnabled       bool
	checkSourceIP     bool
	initialSourceIP   netip.Addr
	localSourceIP     netip.Addr
	closeErr          error
	ready             atomic.Bool
}

func (s *pppSession) Start() error {
	s.access.Lock()
	if s.started {
		ready := s.ready.Load()
		s.access.Unlock()
		if ready {
			return nil
		}
		return ErrDataChannelNotReady
	}
	if s.closed {
		s.access.Unlock()
		return ErrClientClosed
	}
	s.started = true
	s.waitGroup.Add(1)
	s.access.Unlock()
	defer s.waitGroup.Done()
	attachErr := s.state.attachSession(s)
	if attachErr != nil {
		s.terminate(attachErr)
		return attachErr
	}
	setup, setupErr := s.handler.preparePPP()
	if setupErr != nil {
		s.terminate(setupErr)
		return setupErr
	}
	setup.linkConfiguration.Logger = s.client.options.Logger
	link, linkErr := newPPPLink(context.WithoutCancel(s.ctx), setup.linkConfiguration)
	if linkErr != nil {
		_ = setup.linkConfiguration.Carrier.Connection.Close()
		s.terminate(linkErr)
		return linkErr
	}
	initialSourceIP := setup.initialSourceIP
	if setup.checkSourceIP && !initialSourceIP.IsValid() {
		initialSourceIP = setup.carrierSourceIP
	}
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		_ = link.Close()
		return ErrClientClosed
	}
	s.baseConfiguration = cloneTunnelConfiguration(setup.configuration)
	s.link = link
	s.usingDTLS = setup.usingDTLS
	s.dtlsEnabled = setup.dtlsEnabled
	s.checkSourceIP = setup.checkSourceIP
	s.initialSourceIP = initialSourceIP
	s.localSourceIP = setup.carrierSourceIP
	s.access.Unlock()
	startErr := link.Start()
	if startErr != nil {
		if provider, loaded := setup.linkConfiguration.Carrier.Connection.(pppCarrierErrorProvider); loaded {
			if carrierErr, classified := provider.pppCarrierError(); classified && carrierErr != nil {
				startErr = carrierErr
			}
		}
		s.terminate(startErr)
		return startErr
	}
	s.publishPPPConfiguration(link.TunnelConfiguration())
	if setup.usingDTLS {
		s.handler.setSkipInitialDTLS(false)
	}
	s.ready.Store(true)
	transport := TransportTLS
	if setup.usingDTLS {
		transport = TransportDTLS
	}
	s.client.setActiveTransport(s.owner, transport)
	s.waitGroup.Add(1)
	go s.controlLoop(link, setup.usingDTLS)
	return nil
}

func (s *pppSession) connectInitialPPPCarrier(dtlsEnabled bool, skipInitialDTLS bool) (pppSessionCarrier, bool, error) {
	if dtlsEnabled && !skipInitialDTLS {
		dtlsContext, cancelDTLS := context.WithTimeout(s.ctx, pppInitialDTLSWindow)
		dtlsCarrier, dtlsErr := s.handler.connectPPPDTLS(dtlsContext)
		cancelDTLS()
		if dtlsErr == nil {
			return dtlsCarrier, true, nil
		}
		if E.IsMulti(dtlsErr, ErrSessionRejected) || s.ctx.Err() != nil {
			return pppSessionCarrier{}, false, dtlsErr
		}
		if s.client.options.Logger != nil {
			s.client.options.Logger.WarnContext(s.ctx, s.flavor, " DTLS did not establish; using TLS: ", dtlsErr)
		}
	}
	tlsCarrier, tlsErr := s.handler.connectPPPTLS()
	if tlsErr != nil {
		return pppSessionCarrier{}, false, tlsErr
	}
	return tlsCarrier, false, nil
}

func (s *pppSession) publishPPPConfiguration(pppConfiguration TunnelConfiguration) {
	merged := cloneTunnelConfiguration(s.baseConfiguration)
	merged.MTU = pppConfiguration.MTU
	merged.Addresses = append([]netip.Prefix(nil), pppConfiguration.Addresses...)
	if len(merged.DNS) == 0 {
		merged.DNS = append([]netip.Addr(nil), pppConfiguration.DNS...)
	}
	if len(merged.NBNS) == 0 {
		merged.NBNS = append([]netip.Addr(nil), pppConfiguration.NBNS...)
	}
	s.access.Lock()
	s.configuration = merged
	localSourceIP := s.localSourceIP
	s.access.Unlock()
	state := pppSessionConfigurationState{localSourceIP: localSourceIP}
	for _, prefix := range pppConfiguration.Addresses {
		if prefix.Addr().Is4() {
			state.previousIPv4 = prefix
		} else if prefix.Addr().Is6() {
			state.previousIPv6 = prefix
		}
	}
	s.handler.storePPPConfiguration(state)
}

func (s *pppSession) controlLoop(link *pppLink, usingDTLS bool) {
	defer s.waitGroup.Done()
	s.access.RLock()
	dtlsEnabled := s.dtlsEnabled
	s.access.RUnlock()
	var retryTimer *time.Timer
	var retryChannel <-chan time.Time
	if !usingDTLS && dtlsEnabled {
		retryTimer = time.NewTimer(pppLateDTLSRetryPeriod)
		retryChannel = retryTimer.C
		defer retryTimer.Stop()
	}
	for {
		select {
		case <-s.ctx.Done():
			return
		case linkErr, open := <-link.Done():
			if !open || linkErr == nil {
				linkErr = E.New(s.flavor, " PPP link closed unexpectedly")
			}
			s.terminate(linkErr)
			return
		case <-retryChannel:
			dtlsContext, cancelDTLS := context.WithTimeout(s.ctx, pppInitialDTLSWindow)
			carrier, connectErr := s.handler.connectPPPDTLS(dtlsContext)
			cancelDTLS()
			if connectErr != nil {
				if E.IsMulti(connectErr, ErrSessionRejected) || s.ctx.Err() != nil {
					s.terminate(connectErr)
					return
				}
				if s.client.options.Logger != nil {
					s.client.options.Logger.DebugContext(s.ctx, s.flavor, " late DTLS attempt failed: ", connectErr)
				}
				retryTimer.Reset(pppLateDTLSRetryPeriod)
				continue
			}
			s.access.RLock()
			checkSourceIP := s.checkSourceIP
			initialSourceIP := s.initialSourceIP
			s.access.RUnlock()
			if checkSourceIP && initialSourceIP.IsValid() && carrier.localSourceIP != initialSourceIP {
				_ = carrier.connection.Close()
				s.terminate(ErrSessionRejected)
				return
			}
			s.handler.setSkipInitialDTLS(true)
			switchErr := link.SwitchCarrier(pppCarrierConfig{
				Connection:         carrier.connection,
				Datagram:           carrier.datagram,
				MTU:                carrier.mtu,
				NegotiationTimeout: pppLateDTLSNegotiationWindow,
			})
			if switchErr != nil {
				if terminal, isTerminal := E.Cast[*terminalError](switchErr); isTerminal {
					// A late DTLS takeover is optional. Its PPP negotiation failure must
					// reconnect the established session over TLS instead of permanently
					// stopping the client.
					switchErr = terminal.err
				}
				_ = carrier.connection.Close()
				s.client.setActiveTransport(s.owner, "")
				s.terminate(switchErr)
				return
			}
			s.access.Lock()
			s.usingDTLS = true
			s.localSourceIP = carrier.localSourceIP
			s.access.Unlock()
			s.client.setActiveTransport(s.owner, TransportDTLS)
			s.handler.setSkipInitialDTLS(false)
			s.publishPPPConfiguration(link.TunnelConfiguration())
			clientConfiguration := s.client.setTunnelConfiguration(s.TunnelConfiguration())
			s.client.publishTunnelConfigurationEvent(TunnelConfigurationEventReestablishment, clientConfiguration)
			retryChannel = nil
		}
	}
}

func (s *pppSession) Done() <-chan error {
	return s.done
}

func (s *pppSession) Ready() bool {
	s.access.RLock()
	link := s.link
	closed := s.closed
	s.access.RUnlock()
	return !closed && s.ready.Load() && link != nil && link.Ready()
}

func (s *pppSession) TunnelConfiguration() TunnelConfiguration {
	s.access.RLock()
	defer s.access.RUnlock()
	return cloneTunnelConfiguration(s.configuration)
}

func (s *pppSession) WriteDataPackets(payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	return s.WriteDataPacketBuffers(newPacketBuffersFrom(payloads))
}

func (s *pppSession) WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error {
	s.access.RLock()
	link := s.link
	closed := s.closed
	s.access.RUnlock()
	if closed || link == nil || !link.Ready() {
		buf.ReleaseMulti(packetBuffers)
		return ErrDataChannelNotReady
	}
	return link.WriteDataPacketBuffers(packetBuffers)
}

func (s *pppSession) Fail(err error) {
	if err == nil {
		err = E.New(s.flavor, " session failed")
	}
	s.terminate(err)
}

func (s *pppSession) Close() error {
	s.closeOnce.Do(func() {
		s.terminate(nil)
		s.waitGroup.Wait()
	})
	s.access.RLock()
	closeErr := s.closeErr
	s.access.RUnlock()
	return closeErr
}

func (s *pppSession) terminate(err error) {
	s.doneOnce.Do(func() {
		wasReady := s.ready.Swap(false)
		s.access.Lock()
		s.closed = true
		link := s.link
		usingDTLS := s.usingDTLS
		s.link = nil
		s.access.Unlock()
		s.client.stopActiveTransport(s.owner)
		s.handler.recordPPPTermination(pppSessionTermination{
			err:       err,
			wasReady:  wasReady,
			usingDTLS: usingDTLS,
		})
		if link != nil {
			linkCloseErr := link.Close()
			if linkCloseErr != nil {
				s.access.Lock()
				s.closeErr = linkCloseErr
				s.access.Unlock()
				if err == nil {
					err = linkCloseErr
				} else {
					err = E.Errors(err, linkCloseErr)
				}
			}
		}
		s.cancel()
		s.state.detachSession(s)
		if err != nil {
			s.done <- err
		}
		close(s.done)
	})
}
