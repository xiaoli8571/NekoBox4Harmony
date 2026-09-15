package openconnect

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type gpSessionPhase uint8

const (
	gpSessionPhaseStarting gpSessionPhase = iota
	gpSessionPhaseAwaitingESP
	gpSessionPhaseESP
	gpSessionPhaseStartingGPST
	gpSessionPhaseGPST
	gpSessionPhaseClosed
)

type gpSession struct {
	ctx                  context.Context
	cancel               context.CancelFunc
	client               *Client
	state                *gpSessionState
	snapshot             gpSessionSnapshot
	access               sync.RWMutex
	configuration        *gpTunnelConfiguration
	hipRunner            *gpHIPRunner
	phase                gpSessionPhase
	generation           uint64
	esp                  *espChannel
	gpst                 *gpstChannel
	done                 chan error
	doneOnce             sync.Once
	closeOnce            sync.Once
	waitGroup            sync.WaitGroup
	started              bool
	closed               bool
	closeErr             error
	ready                atomic.Bool
	rekeyDeadline        time.Time
	nextHIPCheckDeadline time.Time
}

func newGPSession(ctx context.Context, client *Client, state *gpSessionState, snapshot gpSessionSnapshot) *gpSession {
	sessionContext, cancel := context.WithCancel(ctx)
	return &gpSession{
		ctx:      sessionContext,
		cancel:   cancel,
		client:   client,
		state:    state,
		snapshot: snapshot,
		phase:    gpSessionPhaseStarting,
		done:     make(chan error, 1),
	}
}

func (s *gpSession) Start() error {
	s.access.Lock()
	if s.started {
		s.access.Unlock()
		return nil
	}
	if s.closed {
		s.access.Unlock()
		return ErrClientClosed
	}
	s.started = true
	s.waitGroup.Add(1)
	s.access.Unlock()
	defer s.waitGroup.Done()
	configuration, err := s.state.frontend.fetchTunnelConfiguration(s.ctx, s.snapshot)
	if err != nil {
		s.terminate(err)
		return err
	}
	authenticatedAddress := configuration.Configuration.RemoteAddress
	if authenticatedAddress.IsValid() {
		s.snapshot.authenticatedAddress = authenticatedAddress
		s.state.access.Lock()
		s.state.authenticatedAddress = authenticatedAddress
		s.state.access.Unlock()
	}
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		if configuration.ESP != nil && configuration.ESP.Keys != nil {
			configuration.ESP.Keys.destroy()
		}
		return ErrClientClosed
	}
	s.configuration = configuration
	if configuration.Rekey > 0 {
		s.rekeyDeadline = time.Now().Add(configuration.Rekey)
	}
	s.access.Unlock()
	s.state.access.Lock()
	s.state.previousIPv4 = configuration.AssignedIPv4
	s.state.previousIPv6 = configuration.AssignedIPv6
	s.state.access.Unlock()
	s.state.frontend.previousIPv4 = configuration.AssignedIPv4
	s.state.frontend.previousIPv6 = configuration.AssignedIPv6
	hipReportInterval := s.snapshot.hipReportInterval
	if s.client.options.TrojanInterval > 0 {
		hipReportInterval = s.client.options.TrojanInterval
	}
	hipRunner, err := newGPHIPRunner(
		s.client,
		s.snapshot.serverURL,
		s.snapshot.authenticatedAddress,
		s.snapshot.opaqueQuery,
		configuration.AssignedIPv4,
		configuration.AssignedIPv6,
		s.snapshot.clientVersion,
		reportedGPOS(s.client),
		hipReportInterval,
	)
	if err != nil {
		s.terminate(err)
		return err
	}
	hipResult, err := hipRunner.Check(s.ctx)
	if err != nil {
		s.terminate(err)
		return err
	}
	s.access.Lock()
	s.hipRunner = hipRunner
	if hipResult.NextCheck > 0 {
		s.nextHIPCheckDeadline = time.Now().Add(hipResult.NextCheck)
	}
	s.access.Unlock()
	if configuration.ESP != nil {
		err = s.startInitialESP(configuration)
		if err != nil && E.IsMulti(err, ErrProtocolNotSupported, ErrDeprecatedCryptoDisabled) {
			s.terminate(err)
			return err
		}
		if err == nil {
			return s.finishStartup()
		}
		if s.client.options.Logger != nil {
			s.client.options.Logger.WarnContext(s.ctx, "ESP did not establish; using GPST: ", err)
		}
	}
	err = s.openGPST()
	if err != nil {
		s.terminate(err)
		return err
	}
	return s.finishStartup()
}

func (s *gpSession) finishStartup() error {
	s.access.Lock()
	if s.closed || !s.ready.Load() {
		s.access.Unlock()
		return ErrClientClosed
	}
	s.waitGroup.Add(1)
	s.access.Unlock()
	go s.controlLoop()
	return nil
}

func (s *gpSession) startInitialESP(configuration *gpTunnelConfiguration) error {
	espConfiguration := configuration.ESP
	assigned := configuration.AssignedIPv4
	if espConfiguration.Magic.Is6() {
		assigned = configuration.AssignedIPv6
	}
	probe := gpProbe{assigned: assigned, magic: espConfiguration.Magic}
	channelConfig := espChannelConfig{
		Dialer:          s.client.options.Dialer,
		Remote:          espConfiguration.Remote,
		Keys:            espConfiguration.Keys,
		MTU:             int(configuration.Configuration.MTU),
		DPD:             configuration.DPD,
		Logger:          s.client.options.Logger,
		BuildProbe:      probe.build,
		IsProbeResponse: probe.matches,
		Deliver: func(packetBuffer *buf.Buffer) {
			s.client.pushIncomingDataPacketContext(s.ctx, packetBuffer)
		},
		PreserveKeysOnStartupFailure: true,
	}
	started := time.Now()
	var channel *espChannel
	var lastErr error
	for probeNumber := range 5 {
		if probeNumber > 0 {
			probeDeadline := started.Add(time.Duration(probeNumber) * time.Second)
			established, waitErr := s.waitForESP(channel, probeDeadline)
			if waitErr != nil {
				if E.IsMulti(waitErr, ErrProtocolNotSupported, ErrDeprecatedCryptoDisabled) {
					return waitErr
				}
				if E.IsCanceled(waitErr) {
					return waitErr
				}
				lastErr = waitErr
				if channel != nil {
					_ = channel.Close()
				}
				channel = nil
				_, deadlineErr := s.waitForESP(nil, probeDeadline)
				if deadlineErr != nil {
					return deadlineErr
				}
			}
			if established {
				return s.publishESP(channel)
			}
		}
		if channel == nil {
			candidate, err := newESPChannel(s.ctx, channelConfig)
			if err != nil {
				espConfiguration.Keys.destroy()
				return E.Cause(err, "initialize GlobalProtect ESP channel")
			}
			s.access.Lock()
			if s.closed {
				s.access.Unlock()
				_ = candidate.Close()
				return ErrClientClosed
			}
			s.generation++
			s.phase = gpSessionPhaseAwaitingESP
			s.esp = candidate
			s.access.Unlock()
			err = candidate.Start()
			if err != nil {
				lastErr = err
				_ = candidate.Close()
				continue
			}
			channel = candidate
		}
		err := channel.SendProbe()
		if err != nil {
			lastErr = E.Cause(err, "send initial GlobalProtect ESP probe")
			_ = channel.Close()
			channel = nil
		}
	}
	finalDeadline := started.Add(5 * time.Second)
	established, err := s.waitForESP(channel, finalDeadline)
	if err != nil {
		if E.IsMulti(err, ErrProtocolNotSupported, ErrDeprecatedCryptoDisabled) {
			return err
		}
		lastErr = err
		if channel != nil {
			_ = channel.Close()
			channel = nil
		}
		_, deadlineErr := s.waitForESP(nil, finalDeadline)
		if deadlineErr != nil {
			return deadlineErr
		}
	}
	if established {
		return s.publishESP(channel)
	}
	if lastErr != nil {
		return E.Cause(lastErr, "ESP did not recover during the probe window")
	}
	return E.New("ESP probe window expired")
}

func (s *gpSession) waitForESP(channel *espChannel, deadline time.Time) (bool, error) {
	if s.ctx.Err() != nil {
		return false, s.ctx.Err()
	}
	if channel != nil && channel.Ready() {
		return true, nil
	}
	delay := time.Until(deadline)
	if delay <= 0 {
		return false, nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	var established <-chan struct{}
	var done <-chan error
	if channel != nil {
		established = channel.Established()
		done = channel.Done()
	}
	select {
	case <-s.ctx.Done():
		return false, s.ctx.Err()
	case <-established:
		return true, nil
	case channelErr, open := <-done:
		if open {
			return false, channelErr
		}
		return false, E.New("ESP channel closed before establishment")
	case <-timer.C:
		return false, nil
	}
}

func (s *gpSession) publishESP(channel *espChannel) error {
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		return ErrClientClosed
	}
	if s.phase != gpSessionPhaseAwaitingESP || s.esp != channel || !channel.Ready() {
		s.access.Unlock()
		return E.New("ESP channel lost phase ownership during startup")
	}
	s.phase = gpSessionPhaseESP
	s.ready.Store(true)
	s.access.Unlock()
	s.client.setActiveTransport(s, TransportESP)
	return nil
}

func (s *gpSession) openGPST() error {
	generation, oldESP, oldGPST, err := s.claimGPSTPhase()
	if err != nil {
		return err
	}
	closeErr := closeGPTransports(oldESP, oldGPST)
	if closeErr != nil && s.client.options.Logger != nil {
		s.client.options.Logger.DebugContext(s.ctx, "Closing previous GlobalProtect transport before GPST: ", closeErr)
	}
	s.client.setActiveTransport(s, "")
	s.access.RLock()
	configuration := s.configuration
	s.access.RUnlock()
	if configuration == nil {
		return E.New("GPST start requires tunnel configuration")
	}
	if configuration.ESP != nil && configuration.ESP.Keys != nil {
		configuration.ESP.Keys.destroy()
	}
	channel, err := newGPSTChannel(s.ctx, gpstChannelConfig{
		Client:     s.client,
		Snapshot:   s.snapshot,
		TunnelPath: configuration.TunnelPath,
		MTU:        int(configuration.Configuration.MTU),
		DPD:        configuration.DPD,
		Keepalive:  configuration.Keepalive,
		Deliver: func(packetBuffer *buf.Buffer) {
			s.client.pushIncomingDataPacketContext(s.ctx, packetBuffer)
		},
	})
	if err != nil {
		return E.Cause(err, "initialize GlobalProtect GPST channel")
	}
	s.access.Lock()
	if s.closed || s.generation != generation || s.phase != gpSessionPhaseStartingGPST {
		s.access.Unlock()
		_ = channel.Close()
		return ErrClientClosed
	}
	s.gpst = channel
	s.access.Unlock()
	err = channel.Start()
	if err != nil {
		s.access.Lock()
		if s.gpst == channel {
			s.gpst = nil
		}
		s.access.Unlock()
		_ = channel.Close()
		return err
	}
	s.access.Lock()
	if s.closed || s.generation != generation || s.gpst != channel || !channel.Ready() {
		s.access.Unlock()
		_ = channel.Close()
		if s.closed {
			return ErrClientClosed
		}
		return E.New("GPST channel closed during startup")
	}
	s.phase = gpSessionPhaseGPST
	s.ready.Store(true)
	s.access.Unlock()
	s.client.setActiveTransport(s, TransportGPST)
	return nil
}

func (s *gpSession) claimGPSTPhase() (uint64, *espChannel, *gpstChannel, error) {
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		return 0, nil, nil, ErrClientClosed
	}
	s.ready.Store(false)
	s.generation++
	generation := s.generation
	oldESP := s.esp
	oldGPST := s.gpst
	s.esp = nil
	s.gpst = nil
	s.phase = gpSessionPhaseStartingGPST
	s.access.Unlock()
	return generation, oldESP, oldGPST, nil
}

func closeGPTransports(esp *espChannel, gpst *gpstChannel) error {
	var closeErr error
	if esp != nil {
		closeErr = E.Append(closeErr, esp.Close(), func(cause error) error {
			return E.Cause(cause, "close GlobalProtect ESP channel")
		})
	}
	if gpst != nil {
		closeErr = E.Append(closeErr, gpst.Close(), func(cause error) error {
			return E.Cause(cause, "close GlobalProtect GPST channel")
		})
	}
	return closeErr
}

func (s *gpSession) controlLoop() {
	defer s.waitGroup.Done()
	var hipTimer *time.Timer
	var hipTimerChannel <-chan time.Time
	s.access.RLock()
	hipDeadline := s.nextHIPCheckDeadline
	rekeyDeadline := s.rekeyDeadline
	s.access.RUnlock()
	if !hipDeadline.IsZero() {
		hipDelay := max(time.Until(hipDeadline), 0)
		hipTimer = time.NewTimer(hipDelay)
		hipTimerChannel = hipTimer.C
		defer hipTimer.Stop()
	}
	var rekeyTimer *time.Timer
	var rekeyTimerChannel <-chan time.Time
	if !rekeyDeadline.IsZero() {
		delay := max(time.Until(rekeyDeadline), 0)
		rekeyTimer = time.NewTimer(delay)
		rekeyTimerChannel = rekeyTimer.C
		defer rekeyTimer.Stop()
	}
	for {
		phase, generation, transportDone := s.activeTransportDone()
		select {
		case <-s.ctx.Done():
			return
		case transportErr, open := <-transportDone:
			if !s.ownsTransport(phase, generation) {
				continue
			}
			if !open {
				transportErr = nil
			}
			if phase == gpSessionPhaseESP {
				if E.IsMulti(transportErr, ErrProtocolNotSupported, ErrDeprecatedCryptoDisabled) {
					s.terminate(transportErr)
					return
				}
				if s.client.options.Logger != nil {
					if transportErr == nil {
						s.client.options.Logger.WarnContext(s.ctx, "ESP stopped; switching to GPST")
					} else {
						s.client.options.Logger.WarnContext(s.ctx, "ESP failed; switching to GPST: ", transportErr)
					}
				}
				err := s.openGPST()
				if err != nil {
					s.terminate(err)
					return
				}
				continue
			}
			if transportErr == nil {
				transportErr = E.New("GPST channel closed unexpectedly")
			}
			s.terminate(transportErr)
			return
		case <-hipTimerChannel:
			triggeredAt := time.Now()
			nextInterval, err := s.performPeriodicHIP()
			if err != nil {
				s.terminate(err)
				return
			}
			if nextInterval <= 0 {
				hipTimerChannel = nil
			} else {
				nextDeadline := triggeredAt.Add(nextInterval)
				nextDelay := max(time.Until(nextDeadline), 0)
				hipTimer.Reset(nextDelay)
			}
		case <-rekeyTimerChannel:
			s.terminate(&sessionRekeyError{method: cstpRekeyNewTunnel})
			return
		}
	}
}

func (s *gpSession) activeTransportDone() (gpSessionPhase, uint64, <-chan error) {
	s.access.RLock()
	defer s.access.RUnlock()
	switch s.phase {
	case gpSessionPhaseESP:
		if s.esp != nil {
			return s.phase, s.generation, s.esp.Done()
		}
	case gpSessionPhaseGPST:
		if s.gpst != nil {
			return s.phase, s.generation, s.gpst.Done()
		}
	}
	return s.phase, s.generation, nil
}

func (s *gpSession) ownsTransport(phase gpSessionPhase, generation uint64) bool {
	s.access.RLock()
	defer s.access.RUnlock()
	return !s.closed && s.phase == phase && s.generation == generation
}

func (s *gpSession) performPeriodicHIP() (time.Duration, error) {
	s.access.RLock()
	phase := s.phase
	runner := s.hipRunner
	s.access.RUnlock()
	if runner == nil {
		return 0, E.New("periodic HIP check has no runner")
	}
	if phase == gpSessionPhaseGPST {
		_, oldESP, oldGPST, err := s.claimGPSTPhase()
		if err != nil {
			return 0, err
		}
		closeErr := closeGPTransports(oldESP, oldGPST)
		if closeErr != nil && s.client.options.Logger != nil {
			s.client.options.Logger.DebugContext(s.ctx, "Close GPST for periodic GlobalProtect HIP check: ", closeErr)
		}
		s.client.setActiveTransport(s, "")
	}
	result, err := runner.Check(s.ctx)
	if err != nil {
		return 0, err
	}
	if phase == gpSessionPhaseGPST {
		err = s.openGPST()
		if err != nil {
			return 0, err
		}
	}
	return result.NextCheck, nil
}

func (s *gpSession) Done() <-chan error {
	return s.done
}

func (s *gpSession) Ready() bool {
	return s.ready.Load()
}

func (s *gpSession) TunnelConfiguration() TunnelConfiguration {
	s.access.RLock()
	defer s.access.RUnlock()
	if s.configuration == nil {
		return TunnelConfiguration{}
	}
	return cloneTunnelConfiguration(s.configuration.Configuration)
}

func (s *gpSession) WriteDataPacket(payload []byte) error {
	return s.WriteDataPackets([][]byte{payload})
}

func (s *gpSession) WriteDataPackets(payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	return s.WriteDataPacketBuffers(newPacketBuffersFrom(payloads))
}

func (s *gpSession) WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error {
	defer buf.ReleaseMulti(packetBuffers)
	s.access.RLock()
	ready := s.ready.Load()
	closed := s.closed
	phase := s.phase
	esp := s.esp
	gpst := s.gpst
	s.access.RUnlock()
	if !ready || closed {
		return ErrDataChannelNotReady
	}
	switch phase {
	case gpSessionPhaseESP:
		if esp != nil {
			return esp.WriteDataPacketBuffers(packetBuffers)
		}
	case gpSessionPhaseGPST:
		if gpst != nil {
			return gpst.WriteDataPacketBuffers(packetBuffers)
		}
	}
	return ErrDataChannelNotReady
}

func (s *gpSession) Fail(err error) {
	if err == nil {
		err = E.New("session failed")
	}
	s.terminate(err)
}

func (s *gpSession) Close() error {
	s.closeOnce.Do(func() {
		s.terminate(nil)
		s.waitGroup.Wait()
	})
	s.access.RLock()
	closeErr := s.closeErr
	s.access.RUnlock()
	return closeErr
}

func (s *gpSession) terminate(err error) {
	if E.IsMulti(err, ErrSessionRejected) {
		s.state.access.Lock()
		s.state.opaqueQuery = ""
		s.state.access.Unlock()
	}
	s.doneOnce.Do(func() {
		s.cancel()
		s.access.Lock()
		s.ready.Store(false)
		s.closed = true
		s.phase = gpSessionPhaseClosed
		s.generation++
		esp := s.esp
		gpst := s.gpst
		s.esp = nil
		s.gpst = nil
		configuration := s.configuration
		s.access.Unlock()
		s.client.stopActiveTransport(s)
		closeErr := closeGPTransports(esp, gpst)
		if configuration != nil && configuration.ESP != nil && configuration.ESP.Keys != nil {
			configuration.ESP.Keys.destroy()
		}
		if closeErr != nil {
			s.access.Lock()
			s.closeErr = closeErr
			s.access.Unlock()
			if err == nil {
				err = closeErr
			} else {
				err = E.Errors(err, closeErr)
			}
		}
		if err != nil {
			s.done <- err
		}
		close(s.done)
	})
}

var _ clientSession = (*gpSession)(nil)
