package openconnect

import (
	"context"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type pulseSession struct {
	ctx           context.Context
	cancel        context.CancelFunc
	client        *Client
	state         *pulseSessionState
	access        sync.RWMutex
	connection    *pulseIFTConnection
	configuration *pulseTunnelConfiguration
	esp           *espChannel
	espKeys       *espKeySet
	espGeneration uint64
	espSuppressed bool
	done          chan error
	doneOnce      sync.Once
	closeOnce     sync.Once
	waitGroup     sync.WaitGroup
	started       bool
	closed        bool
	closeErr      error
	terminalErr   error
	ready         atomic.Bool
}

func newPulseSession(ctx context.Context, client *Client, state *pulseSessionState) *pulseSession {
	sessionContext, cancel := context.WithCancel(ctx)
	return &pulseSession{
		ctx:    sessionContext,
		cancel: cancel,
		client: client,
		state:  state,
		done:   make(chan error, 1),
	}
}

func (s *pulseSession) Start() error {
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
	s.access.Unlock()
	connection, err := s.state.takeLiveConnection(s)
	if err != nil {
		s.terminate(err)
		return err
	}
	if connection == nil {
		connection, err = s.reconnectWithCookie()
		if err != nil {
			s.terminate(err)
			return err
		}
	}
	snapshot := s.state.snapshot()
	configuration, err := readPulseConfiguration(
		s.ctx,
		s.client,
		connection,
		snapshot.acceptedAddress,
		snapshot.authenticationExpires,
		snapshot.idleTimeout,
	)
	clear(snapshot.cookie)
	if err != nil {
		_ = connection.Close()
		s.terminate(err)
		return err
	}
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		_ = connection.Close()
		destroyPulseConfiguration(configuration)
		return ErrClientClosed
	}
	s.connection = connection
	s.configuration = configuration
	s.ready.Store(true)
	s.waitGroup.Add(1)
	s.access.Unlock()
	s.client.setActiveTransport(s, TransportIFT)
	go s.readLoop(connection)
	s.launchESP()
	return nil
}

func (s *pulseSession) reconnectWithCookie() (*pulseIFTConnection, error) {
	snapshot := s.state.snapshot()
	defer clear(snapshot.cookie)
	authentication := newPulseReconnectAuthentication(s.state, snapshot)
	obtained, request, err := authentication.Advance(s.ctx, nil)
	if err != nil {
		_ = authentication.Close()
		if E.IsMulti(err, ErrSessionRejected) {
			s.state.rejectCookie()
		}
		return nil, err
	}
	if request != nil || obtained == nil {
		_ = authentication.Close()
		s.state.rejectCookie()
		return nil, ErrSessionRejected
	}
	result, loaded := obtained.(*pulseSessionState)
	if !loaded || result == nil {
		_ = authentication.Close()
		return nil, E.Extend(ErrProtocolNotSupported, "cookie reconnect returned an invalid session")
	}
	connection, err := s.state.installReconnect(result, s)
	if err != nil {
		_ = result.Close()
		return nil, err
	}
	return connection, nil
}

func (s *pulseSession) readLoop(connection *pulseIFTConnection) {
	defer s.waitGroup.Done()
	for {
		s.access.RLock()
		configuration := s.configuration
		closed := s.closed
		s.access.RUnlock()
		if closed || configuration == nil {
			return
		}
		maximumPayloadLength := max(pulseAuthenticationFrameLimit, int(configuration.configuration.MTU))
		maximumLength := maximumPayloadLength + pulseIFTHeaderSize
		frame, err := connection.readFrameBuffer(maximumLength)
		if err != nil {
			if s.ctx.Err() == nil {
				s.terminate(err)
			}
			return
		}
		if frame.vendor != pulseVendorJuniper {
			frame.packetBuffer.Release()
			if s.client.options.Logger != nil {
				s.client.options.Logger.DebugContext(s.ctx, "Ignoring Pulse tunnel frame from unknown vendor: ", frame.vendor)
			}
			continue
		}
		switch frame.frameType {
		case 4:
			version := pulsePacketVersion(frame.packetBuffer.Bytes())
			if version != 4 && version != 6 {
				frame.packetBuffer.Release()
				if s.client.options.Logger != nil {
					s.client.options.Logger.DebugContext(s.ctx, "Ignoring Pulse data frame with unknown IP version")
				}
				continue
			}
			if !pulseConfigurationAllowsIPVersion(configuration, version) {
				frame.packetBuffer.Release()
				if s.client.options.Logger != nil {
					s.client.options.Logger.WarnContext(s.ctx, "Ignoring Pulse data frame for an unassigned IP family")
				}
				continue
			}
			s.client.pushIncomingDataPacketContext(s.ctx, frame.packetBuffer)
		case 1:
			if !pulseESPConfigurationFrameValid(frame.packetBuffer.Bytes()) {
				frame.packetBuffer.Release()
				if s.client.options.Logger != nil {
					s.client.options.Logger.DebugContext(s.ctx, "Ignoring Pulse ESP rekey frame with an invalid fixed header")
				}
				continue
			}
			err = s.handleESPRekey(frame.packetBuffer.Bytes())
			frame.packetBuffer.Release()
			if err != nil {
				s.suppressESP()
				if s.client.options.Logger != nil {
					s.client.options.Logger.WarnContext(s.ctx, "ESP rekey failed; continuing over IF-T/TLS: ", err)
				}
			}
		case 0x93:
			err = parsePulseFatalError(frame.packetBuffer.Bytes())
			frame.packetBuffer.Release()
			s.terminate(err)
			return
		case 0x96:
			frame.packetBuffer.Release()
			if s.client.options.Logger != nil {
				s.client.options.Logger.DebugContext(s.ctx, "Received Pulse license information")
			}
			s.triggerESPProbe()
		default:
			frame.packetBuffer.Release()
			if s.client.options.Logger != nil {
				s.client.options.Logger.DebugContext(s.ctx, "Ignoring unknown Pulse tunnel frame type: ", frame.frameType)
			}
		}
	}
}

func (s *pulseSession) handleESPRekey(payload []byte) error {
	if s.client.options.NoUDP {
		return nil
	}
	s.access.RLock()
	configuration := s.configuration
	var previousESPConfiguration *pulseESPConfiguration
	accumulator := pulseConfigurationAccumulator{}
	if configuration != nil && configuration.esp != nil {
		previousESPConfiguration = configuration.esp
		accumulator = pulseConfigurationAccumulator{
			espEncryption:     previousESPConfiguration.encryption,
			espAuthentication: previousESPConfiguration.authentication,
			espPort:           previousESPConfiguration.port,
			espFallback:       previousESPConfiguration.fallback,
			espCrossFamily:    previousESPConfiguration.crossFamily,
			espReplay:         previousESPConfiguration.replayProtection,
		}
	}
	s.access.RUnlock()
	if previousESPConfiguration == nil {
		return E.New("server requested ESP rekey without an active ESP configuration")
	}
	snapshot := s.state.snapshot()
	acceptedAddress := snapshot.acceptedAddress
	clear(snapshot.cookie)
	newConfiguration, responsePayload, err := parsePulseESPConfiguration(payload, accumulator, acceptedAddress)
	if err != nil {
		return err
	}
	defer clear(responsePayload)
	s.access.Lock()
	if s.configuration != configuration || s.configuration.esp != previousESPConfiguration || s.closed || s.connection == nil {
		s.access.Unlock()
		destroyPulseESPConfiguration(newConfiguration)
		return ErrClientClosed
	}
	keys := s.espKeys
	if keys == nil {
		keys, err = newESPKeySet(newConfiguration.keyConfiguration)
	} else {
		err = keys.install(newConfiguration.keyConfiguration)
	}
	if err != nil {
		s.access.Unlock()
		destroyPulseESPConfiguration(newConfiguration)
		return E.Cause(err, "install Pulse ESP rekey")
	}
	s.espKeys = keys
	channel := s.esp
	connection := s.connection
	s.configuration.esp = newConfiguration
	s.espSuppressed = false
	s.access.Unlock()
	destroyPulseESPConfiguration(previousESPConfiguration)
	err = connection.writeFrame(pulseVendorJuniper, 1, responsePayload)
	if err != nil {
		return E.Cause(err, "send Pulse ESP rekey response")
	}
	if channel == nil {
		s.launchESP()
	}
	return nil
}

func parsePulseFatalError(payload []byte) error {
	message := strings.TrimSuffix(string(payload), "\n")
	if !strings.HasPrefix(message, "errorType=") {
		return markTerminal(E.New("server sent a malformed fatal error"))
	}
	reasonContent, encodedMessage, found := strings.Cut(message, " errorString=")
	if !found {
		return markTerminal(E.New("server sent a malformed fatal error"))
	}
	reasonText := strings.TrimPrefix(reasonContent, "errorType=")
	reason, err := strconv.ParseUint(reasonText, 10, 32)
	if err != nil {
		return markTerminal(E.Cause(err, "parse Pulse fatal error reason"))
	}
	decodedMessage, err := url.QueryUnescape(encodedMessage)
	if err != nil {
		decodedMessage = encodedMessage
	}
	return markTerminal(E.New("fatal error ", reason, ": ", decodedMessage))
}

func (s *pulseSession) Done() <-chan error {
	return s.done
}

func (s *pulseSession) WriteDataPacket(payload []byte) error {
	return s.WriteDataPackets([][]byte{payload})
}

func (s *pulseSession) WriteDataPackets(payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	return s.WriteDataPacketBuffers(newPacketBuffersFrom(payloads))
}

func (s *pulseSession) WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error {
	defer buf.ReleaseMulti(packetBuffers)
	s.access.RLock()
	connection := s.connection
	esp := s.esp
	closed := s.closed
	mtu := 0
	configurationAllowsIPv4 := false
	configurationAllowsIPv6 := false
	espAllowsIPv4 := false
	espAllowsIPv6 := false
	if s.configuration != nil {
		mtu = int(s.configuration.configuration.MTU)
		configurationAllowsIPv4 = pulseConfigurationAllowsIPVersion(s.configuration, 4)
		configurationAllowsIPv6 = pulseConfigurationAllowsIPVersion(s.configuration, 6)
		espAllowsIPv4 = pulseESPAllowsIPVersion(s.configuration.esp, 4)
		espAllowsIPv6 = pulseESPAllowsIPVersion(s.configuration.esp, 6)
	}
	s.access.RUnlock()
	if closed || !s.ready.Load() || connection == nil || mtu == 0 {
		return ErrDataChannelNotReady
	}
	var pendingPacketBuffers []*buf.Buffer
	flushPending := func() error {
		if len(pendingPacketBuffers) == 0 {
			return nil
		}
		err := connection.writeFrameBuffers(pulseVendorJuniper, 4, pendingPacketBuffers)
		pendingPacketBuffers = nil
		if err != nil {
			wrappedErr := E.Cause(err, "write Pulse IF-T/TLS data packet")
			s.terminate(wrappedErr)
			return wrappedErr
		}
		return nil
	}
	for index, packetBuffer := range packetBuffers {
		version := pulsePacketVersion(packetBuffer.Bytes())
		configurationAllowsVersion := version == 4 && configurationAllowsIPv4 || version == 6 && configurationAllowsIPv6
		espAllowsVersion := version == 4 && espAllowsIPv4 || version == 6 && espAllowsIPv6
		var validationErr error
		if packetBuffer.IsEmpty() || packetBuffer.Len() > mtu {
			validationErr = E.New("data packet has invalid length: ", packetBuffer.Len())
		} else if version != 4 && version != 6 {
			validationErr = E.New("data packet has unknown IP version")
		} else if !configurationAllowsVersion {
			validationErr = E.New("data packet uses an unassigned IP family")
		}
		if validationErr != nil {
			err := flushPending()
			if err != nil {
				return err
			}
			return validationErr
		}
		if esp != nil && esp.Ready() && espAllowsVersion {
			err := flushPending()
			if err != nil {
				return err
			}
			fallbackPacketBuffer := newPacketBufferFrom(packetBuffer.Bytes())
			err = esp.WriteDataPacketBuffers(packetBuffers[index : index+1])
			if err == nil {
				fallbackPacketBuffer.Release()
				continue
			}
			packetBuffers[index].Release()
			packetBuffers[index] = fallbackPacketBuffer
			if s.client.options.Logger != nil {
				s.client.options.Logger.WarnContext(s.ctx, "ESP write failed; retrying over IF-T/TLS: ", err)
			}
			s.client.setActiveTransport(s, TransportIFT)
		}
		packetBuffers[index] = requirePacketBufferCapacity(packetBuffers[index], pulseIFTHeaderSize, 0)
		pendingPacketBuffers = append(pendingPacketBuffers, packetBuffers[index])
	}
	return flushPending()
}

func (s *pulseSession) Fail(err error) {
	if err == nil {
		err = E.New("session failed")
	}
	s.terminate(err)
}

func (s *pulseSession) Close() error {
	s.closeOnce.Do(func() {
		s.access.RLock()
		connection := s.connection
		terminalErr := s.terminalErr
		s.access.RUnlock()
		if connection != nil && terminalErr == nil {
			err := connection.writeFrame(pulseVendorJuniper, 0x89, nil)
			if err == nil {
				s.state.recordGracefulBye()
			} else if !E.IsClosedOrCanceled(err) {
				s.access.Lock()
				s.closeErr = E.Append(s.closeErr, err, func(cause error) error {
					return E.Cause(cause, "send Pulse close frame")
				})
				s.access.Unlock()
			}
		}
		s.terminate(nil)
		s.waitGroup.Wait()
	})
	s.access.RLock()
	closeErr := s.closeErr
	s.access.RUnlock()
	return closeErr
}

func (s *pulseSession) Ready() bool {
	return s.ready.Load()
}

func (s *pulseSession) TunnelConfiguration() TunnelConfiguration {
	s.access.RLock()
	defer s.access.RUnlock()
	if s.configuration == nil {
		return TunnelConfiguration{}
	}
	return cloneTunnelConfiguration(s.configuration.configuration)
}

func (s *pulseSession) terminate(err error) {
	s.doneOnce.Do(func() {
		s.ready.Store(false)
		s.cancel()
		s.access.Lock()
		s.closed = true
		s.terminalErr = err
		s.espGeneration++
		esp := s.esp
		espKeys := s.espKeys
		s.esp = nil
		s.espKeys = nil
		connection := s.connection
		s.connection = nil
		configuration := s.configuration
		s.configuration = nil
		s.access.Unlock()
		s.client.stopActiveTransport(s)
		if esp != nil {
			espCloseErr := esp.Close()
			if espCloseErr != nil && !E.IsClosed(espCloseErr) {
				s.access.Lock()
				s.closeErr = E.Append(s.closeErr, espCloseErr, func(cause error) error {
					return E.Cause(cause, "close Pulse ESP channel")
				})
				storedCloseErr := s.closeErr
				s.access.Unlock()
				if err == nil {
					err = storedCloseErr
				} else {
					err = E.Errors(err, storedCloseErr)
				}
			}
		}
		if espKeys != nil {
			espKeys.destroy()
		}
		if connection != nil {
			closeErr := connection.Close()
			if closeErr != nil && !E.IsClosed(closeErr) {
				s.access.Lock()
				s.closeErr = E.Append(s.closeErr, closeErr, func(cause error) error {
					return E.Cause(cause, "close Pulse IF-T/TLS connection")
				})
				storedCloseErr := s.closeErr
				s.access.Unlock()
				if err == nil {
					err = storedCloseErr
				} else {
					err = E.Errors(err, storedCloseErr)
				}
			}
		}
		destroyPulseConfiguration(configuration)
		s.state.detachSession(s)
		if err != nil {
			s.done <- err
		}
		close(s.done)
	})
}

func (s *pulseSession) launchESP() {
	s.access.Lock()
	if s.closed || s.configuration == nil || s.configuration.esp == nil || s.espSuppressed || s.client.options.NoUDP {
		s.access.Unlock()
		return
	}
	s.waitGroup.Add(1)
	s.access.Unlock()
	go func() {
		defer s.waitGroup.Done()
		s.startESP()
	}()
}

func (s *pulseSession) startESP() {
	s.access.Lock()
	if s.closed || s.esp != nil || s.configuration == nil || s.configuration.esp == nil || s.espSuppressed {
		s.access.Unlock()
		return
	}
	espConfiguration := s.configuration.esp
	retryInterval := espConfiguration.fallback
	dpdInterval := espConfiguration.fallback
	if s.client.options.DPDInterval > 0 {
		dpdInterval = s.client.options.DPDInterval
	}
	keys := s.espKeys
	if keys == nil {
		var err error
		keys, err = newESPKeySet(espConfiguration.keyConfiguration)
		if err != nil {
			s.access.Unlock()
			if s.client.options.Logger != nil {
				s.client.options.Logger.WarnContext(s.ctx, "Unable to initialize Pulse ESP keys; using IF-T/TLS: ", err)
			}
			return
		}
		s.espKeys = keys
	}
	s.espGeneration++
	generation := s.espGeneration
	probe := pulseESPProbe{}
	channel, err := newESPChannel(s.ctx, espChannelConfig{
		Dialer:                s.client.options.Dialer,
		Remote:                espConfiguration.remote,
		Keys:                  keys,
		MTU:                   int(s.configuration.configuration.MTU),
		DPD:                   dpdInterval,
		Logger:                s.client.options.Logger,
		BuildProbe:            probe.build,
		IsProbeResponse:       probe.matches,
		ProbeNextHeader:       espConfiguration.probeNextHeader,
		AcceptLZO:             true,
		PreserveKeysOnFailure: true,
		Deliver: func(packetBuffer *buf.Buffer) {
			s.deliverESP(generation, packetBuffer)
		},
	})
	if err != nil {
		s.espKeys = nil
		s.access.Unlock()
		keys.destroy()
		if s.client.options.Logger != nil {
			s.client.options.Logger.WarnContext(s.ctx, "Unable to initialize Pulse ESP channel; using IF-T/TLS: ", err)
		}
		return
	}
	s.esp = channel
	s.waitGroup.Add(1)
	s.access.Unlock()
	startErr := channel.Start()
	go s.monitorESP(channel, generation, retryInterval, startErr)
}

func (s *pulseSession) monitorESP(
	channel *espChannel,
	generation uint64,
	retryInterval time.Duration,
	startErr error,
) {
	defer s.waitGroup.Done()
	if startErr != nil {
		s.finishESPAttempt(channel, generation, retryInterval, startErr)
		return
	}
	for {
		for range 5 {
			if !s.ownsESP(channel, generation) {
				return
			}
			err := channel.SendProbe()
			if err != nil {
				s.finishESPAttempt(channel, generation, retryInterval, err)
				return
			}
			probeTimer := time.NewTimer(time.Second)
			select {
			case <-s.ctx.Done():
				probeTimer.Stop()
				return
			case <-channel.Established():
				probeTimer.Stop()
				s.monitorEstablishedESP(channel, generation, retryInterval)
				return
			case channelErr, open := <-channel.Done():
				probeTimer.Stop()
				if !open {
					channelErr = E.New("ESP channel closed before establishment")
				}
				s.finishESPAttempt(channel, generation, retryInterval, channelErr)
				return
			case <-probeTimer.C:
			}
		}
		retryTimer := time.NewTimer(retryInterval)
		select {
		case <-s.ctx.Done():
			retryTimer.Stop()
			return
		case <-channel.Established():
			retryTimer.Stop()
			s.monitorEstablishedESP(channel, generation, retryInterval)
			return
		case channelErr, open := <-channel.Done():
			retryTimer.Stop()
			if !open {
				channelErr = E.New("ESP channel closed before establishment")
			}
			s.finishESPAttempt(channel, generation, retryInterval, channelErr)
			return
		case <-retryTimer.C:
		}
	}
}

func (s *pulseSession) monitorEstablishedESP(channel *espChannel, generation uint64, retryInterval time.Duration) {
	s.access.RLock()
	if s.closed || s.esp != channel || s.espGeneration != generation || !channel.Ready() {
		s.access.RUnlock()
		return
	}
	s.client.setActiveTransport(s, TransportESP)
	s.access.RUnlock()
	if s.client.options.Logger != nil {
		s.client.options.Logger.InfoContext(s.ctx, "ESP channel established")
	}
	select {
	case <-s.ctx.Done():
		return
	case channelErr, open := <-channel.Done():
		if !open {
			channelErr = E.New("ESP channel closed unexpectedly")
		}
		s.finishESPAttempt(channel, generation, retryInterval, channelErr)
	}
}

func (s *pulseSession) finishESPAttempt(
	channel *espChannel,
	generation uint64,
	retryInterval time.Duration,
	err error,
) {
	s.access.Lock()
	if s.closed || s.esp != channel || s.espGeneration != generation {
		s.access.Unlock()
		return
	}
	s.esp = nil
	s.espGeneration++
	s.access.Unlock()
	s.client.setActiveTransport(s, TransportIFT)
	_ = channel.Close()
	if err != nil && s.client.options.Logger != nil {
		s.client.options.Logger.WarnContext(s.ctx, "ESP stopped; using IF-T/TLS until retry: ", err)
	}
	retryTimer := time.NewTimer(retryInterval)
	select {
	case <-s.ctx.Done():
		retryTimer.Stop()
		return
	case <-retryTimer.C:
		s.launchESP()
	}
}

func (s *pulseSession) ownsESP(channel *espChannel, generation uint64) bool {
	s.access.RLock()
	defer s.access.RUnlock()
	return !s.closed && s.esp == channel && s.espGeneration == generation
}

func (s *pulseSession) triggerESPProbe() {
	s.access.RLock()
	channel := s.esp
	suppressed := s.espSuppressed
	s.access.RUnlock()
	if suppressed {
		return
	}
	if channel == nil {
		s.launchESP()
		return
	}
	if channel.Ready() {
		return
	}
	err := channel.SendProbe()
	if err != nil && s.client.options.Logger != nil {
		s.client.options.Logger.DebugContext(s.ctx, "ESP re-probe failed: ", err)
	}
}

func (s *pulseSession) suppressESP() {
	s.access.Lock()
	if s.closed || s.configuration == nil || s.configuration.esp == nil {
		s.access.Unlock()
		return
	}
	channel := s.esp
	keys := s.espKeys
	s.esp = nil
	s.espKeys = nil
	s.espGeneration++
	s.espSuppressed = true
	destroyPulseESPConfiguration(s.configuration.esp)
	s.access.Unlock()
	s.client.setActiveTransport(s, TransportIFT)
	if channel != nil {
		err := channel.Close()
		if err != nil && !E.IsClosedOrCanceled(err) && s.client.options.Logger != nil {
			s.client.options.Logger.DebugContext(s.ctx, "Unable to close suppressed Pulse ESP channel: ", err)
		}
	}
	if keys != nil {
		keys.destroy()
	}
}

func (s *pulseSession) deliverESP(generation uint64, packetBuffer *buf.Buffer) {
	if packetBuffer.IsEmpty() {
		packetBuffer.Release()
		return
	}
	version := pulsePacketVersion(packetBuffer.Bytes())
	s.access.RLock()
	allowed := !s.closed && generation == s.espGeneration && s.configuration != nil &&
		pulseConfigurationAllowsIPVersion(s.configuration, version) &&
		pulseESPAllowsIPVersion(s.configuration.esp, version)
	s.access.RUnlock()
	if !allowed {
		packetBuffer.Release()
		if s.client.options.Logger != nil {
			s.client.options.Logger.WarnContext(s.ctx, "Ignoring Pulse ESP packet for an unavailable IP family")
		}
		return
	}
	s.client.pushIncomingDataPacketContext(s.ctx, packetBuffer)
}

func pulseESPAllowsIPVersion(configuration *pulseESPConfiguration, version byte) bool {
	if configuration == nil || (version != 4 && version != 6) {
		return false
	}
	if configuration.crossFamily {
		return true
	}
	if configuration.remote.Addr.Is6() {
		return version == 6
	}
	return version == 4
}

type pulseESPProbe struct{}

func (pulseESPProbe) build(uint16) ([]byte, error) {
	return []byte{0}, nil
}

func (pulseESPProbe) matches(payload []byte) bool {
	return len(payload) == 1 && payload[0] == 0
}

func pulseConfigurationAllowsIPVersion(configuration *pulseTunnelConfiguration, version byte) bool {
	switch version {
	case 4:
		return configuration.assignedIPv4.IsValid()
	case 6:
		return configuration.assignedIPv6.IsValid()
	default:
		return false
	}
}

func destroyPulseConfiguration(configuration *pulseTunnelConfiguration) {
	if configuration == nil {
		return
	}
	destroyPulseESPConfiguration(configuration.esp)
}

var _ clientSession = (*pulseSession)(nil)
