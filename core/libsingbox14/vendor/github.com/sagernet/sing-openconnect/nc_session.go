package openconnect

import (
	"context"
	"encoding/binary"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	ncESPProbeInterval = time.Second
	ncESPProbeLimit    = 5
	ncESPDisableWait   = 2 * time.Second
)

type ncSession struct {
	ctx              context.Context
	cancel           context.CancelFunc
	client           *Client
	state            *ncSessionState
	snapshot         ncSessionSnapshot
	localHostname    string
	access           sync.RWMutex
	espControlAccess sync.Mutex
	connection       *ncONCPConnection
	configuration    *ncTunnelConfiguration
	esp              *espChannel
	done             chan error
	doneOnce         sync.Once
	closeOnce        sync.Once
	waitGroup        sync.WaitGroup
	started          bool
	closed           bool
	attached         bool
	terminalErr      error
	closeErr         error
	ready            atomic.Bool
	espEnabled       atomic.Bool
}

func (s *ncSession) Start() error {
	s.access.Lock()
	if s.started {
		ready := s.ready.Load()
		s.access.Unlock()
		if ready {
			return nil
		}
		return ErrClientClosed
	}
	if s.closed {
		s.access.Unlock()
		return ErrClientClosed
	}
	s.started = true
	s.access.Unlock()
	err := s.state.attachSession(s)
	if err != nil {
		s.terminate(err)
		return err
	}
	s.access.Lock()
	s.attached = true
	s.access.Unlock()
	connection, configuration, err := openNCONCPConnection(s.ctx, s.client, s.snapshot, s.localHostname)
	if err != nil {
		s.terminate(err)
		return err
	}
	acceptedAddress := configuration.configuration.RemoteAddress
	if acceptedAddress.IsValid() {
		s.snapshot.acceptedAddress = acceptedAddress
		s.state.access.Lock()
		s.state.acceptedAddress = acceptedAddress
		s.state.access.Unlock()
	}
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		_ = connection.Close()
		destroyNCTunnelConfiguration(configuration)
		return ErrClientClosed
	}
	s.connection = connection
	s.configuration = configuration
	s.ready.Store(true)
	s.waitGroup.Add(2)
	s.access.Unlock()
	s.client.setActiveTransport(s, TransportONCP)
	go s.readLoop(connection)
	go s.controlLoop()
	return nil
}

func (s *ncSession) readLoop(connection *ncONCPConnection) {
	defer s.waitGroup.Done()
	for {
		messageType, packetBuffer, err := connection.readKMP()
		if err != nil {
			if s.ctx.Err() == nil {
				s.terminate(err)
			}
			return
		}
		switch messageType {
		case ncONCPKMPData:
			err = s.deliverTLSData(packetBuffer)
		case ncONCPKMPESP:
			err = s.handleESPRekey(packetBuffer.Bytes())
			packetBuffer.Release()
		case ncONCPKMPControl:
			err = s.handleServerESPControl(packetBuffer.Bytes())
			packetBuffer.Release()
		default:
			packetBuffer.Release()
			err = markTerminal(E.Extend(ErrProtocolNotSupported, "oNCP received unknown KMP ", messageType))
		}
		if err != nil {
			s.terminate(err)
			return
		}
	}
}

func (s *ncSession) controlLoop() {
	defer s.waitGroup.Done()
	esp := s.startInitialESP()
	probeCount := 0
	var probeTicker *time.Ticker
	var probeChannel <-chan time.Time
	var established <-chan struct{}
	var espDone <-chan error
	if esp != nil {
		probeCount = 1
		probeTicker = time.NewTicker(ncESPProbeInterval)
		probeChannel = probeTicker.C
		established = esp.Established()
		espDone = esp.Done()
	}
	if probeTicker != nil {
		defer probeTicker.Stop()
	}
	var tnccTimer *time.Timer
	var tnccChannel <-chan time.Time
	tnccInterval := s.state.tnccInterval()
	if tnccInterval > 0 {
		tnccTimer = time.NewTimer(tnccInterval)
		tnccChannel = tnccTimer.C
	}
	if tnccTimer != nil {
		defer tnccTimer.Stop()
	}
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-established:
			err := s.enableESP(esp)
			if err != nil {
				s.terminate(err)
				return
			}
			established = nil
			probeChannel = nil
			if probeTicker != nil {
				probeTicker.Stop()
			}
		case espErr, open := <-espDone:
			if !open {
				espErr = nil
			}
			err := s.fallbackFromESP(esp, espErr)
			if err != nil {
				s.terminate(err)
				return
			}
			s.client.setActiveTransport(s, TransportONCP)
			esp = nil
			established = nil
			espDone = nil
			probeChannel = nil
			if probeTicker != nil {
				probeTicker.Stop()
			}
		case <-probeChannel:
			if esp == nil || esp.Ready() {
				probeChannel = nil
				continue
			}
			if probeCount >= ncESPProbeLimit {
				_ = esp.Close()
				continue
			}
			err := esp.SendProbe()
			if err != nil {
				_ = esp.Close()
				continue
			}
			probeCount++
		case <-tnccChannel:
			err := s.state.runPeriodicTNCC(s.ctx)
			if err != nil {
				s.terminate(E.Cause(err, "run periodic Network Connect TNCC check"))
				return
			}
			tnccInterval = s.state.tnccInterval()
			if tnccInterval > 0 {
				tnccTimer.Reset(tnccInterval)
				tnccChannel = tnccTimer.C
			} else {
				tnccChannel = nil
			}
		}
	}
}

func (s *ncSession) startInitialESP() *espChannel {
	if s.client.options.NoUDP || s.snapshot.acceptedAddress.Is6() {
		return nil
	}
	s.access.RLock()
	configuration := s.configuration
	s.access.RUnlock()
	if configuration == nil || configuration.esp == nil || configuration.esp.keys == nil {
		return nil
	}
	espConfiguration := configuration.esp
	channel, err := newESPChannel(s.ctx, espChannelConfig{
		Dialer:          s.client.options.Dialer,
		Remote:          espConfiguration.remote,
		Keys:            espConfiguration.keys,
		MTU:             int(configuration.configuration.MTU),
		DPD:             espConfiguration.dpd,
		Logger:          s.client.options.Logger,
		Deliver:         s.deliverESPData,
		ProbeNextHeader: espIPv4NextHeader,
		AcceptLZO:       true,
		BuildProbe: func(_ uint16) ([]byte, error) {
			return []byte{0}, nil
		},
		IsProbeResponse: func(payload []byte) bool {
			return len(payload) == 1 && payload[0] == 0
		},
	})
	if err == nil {
		err = channel.Start()
	}
	if err == nil {
		err = channel.SendProbe()
	}
	if err != nil {
		if channel != nil {
			_ = channel.Close()
		} else {
			espConfiguration.keys.destroy()
		}
		s.access.Lock()
		if s.configuration == configuration {
			s.configuration.esp = nil
		}
		s.access.Unlock()
		if s.client.options.Logger != nil {
			s.client.options.Logger.WarnContext(s.ctx, "ESP startup failed; using oNCP/TLS: ", err)
		}
		return nil
	}
	s.access.Lock()
	if s.closed || s.configuration != configuration {
		s.access.Unlock()
		_ = channel.Close()
		return nil
	}
	s.esp = channel
	s.access.Unlock()
	return channel
}

func (s *ncSession) enableESP(channel *espChannel) error {
	if channel == nil || !channel.Ready() {
		return E.New("ESP channel was not established")
	}
	s.espControlAccess.Lock()
	defer s.espControlAccess.Unlock()
	s.access.RLock()
	connection := s.connection
	owned := s.esp == channel && !s.closed
	s.access.RUnlock()
	if !owned || connection == nil {
		return ErrClientClosed
	}
	message, err := encodeNCONCPESPControl(true)
	if err != nil {
		return err
	}
	err = connection.writeRecord(message)
	clear(message)
	if err != nil {
		return E.Cause(err, "enable Network Connect ESP over oNCP")
	}
	s.espEnabled.Store(true)
	s.client.setActiveTransport(s, TransportESP)
	return nil
}

func (s *ncSession) fallbackFromESP(channel *espChannel, channelErr error) error {
	s.espControlAccess.Lock()
	defer s.espControlAccess.Unlock()
	wasEnabled := s.espEnabled.Swap(false)
	s.access.RLock()
	connection := s.connection
	s.access.RUnlock()
	if wasEnabled && connection != nil {
		message, err := encodeNCONCPESPControl(false)
		if err != nil {
			return err
		}
		err = connection.writeRecord(message)
		clear(message)
		if err != nil {
			return E.Cause(err, "disable failed Network Connect ESP over oNCP")
		}
	}
	s.access.Lock()
	if s.esp == channel {
		s.esp = nil
		if s.configuration != nil {
			s.configuration.esp = nil
		}
	}
	s.access.Unlock()
	if channelErr != nil && s.client.options.Logger != nil {
		s.client.options.Logger.WarnContext(s.ctx, "ESP failed; using oNCP/TLS: ", channelErr)
	}
	return nil
}

func (s *ncSession) handleESPRekey(payload []byte) error {
	s.access.RLock()
	configuration := s.configuration
	channel := s.esp
	s.access.RUnlock()
	if configuration == nil || configuration.esp == nil || configuration.esp.keys == nil || channel == nil {
		if s.client.options.Logger != nil {
			s.client.options.Logger.DebugContext(s.ctx, "Ignoring Network Connect ESP KMP 302 without an active ESP channel")
		}
		return nil
	}
	espConfiguration := configuration.esp
	compression := byte(0)
	if espConfiguration.compression {
		compression = 1
	}
	parameters := ncESPParameters{
		encryption:       espConfiguration.encryption,
		authentication:   espConfiguration.authentication,
		compression:      compression,
		replayProtection: espConfiguration.replayProtection,
		port:             espConfiguration.port,
		dpd:              espConfiguration.dpd,
	}
	parameters, err := parseNCONCPESPParameters(payload, parameters)
	if err != nil {
		if s.client.options.Logger != nil {
			s.client.options.Logger.WarnContext(s.ctx, "ESP rekey was unusable; using oNCP/TLS: ", err)
		}
		_ = channel.Close()
		return nil
	}
	if s.client.options.DPDInterval > 0 {
		parameters.dpd = s.client.options.DPDInterval
	}
	defer parameters.clear()
	if parameters.port != espConfiguration.port {
		if s.client.options.Logger != nil {
			s.client.options.Logger.WarnContext(s.ctx, "ESP rekey changed the UDP port; using oNCP/TLS")
		}
		_ = channel.Close()
		return nil
	}
	keyConfiguration, response, err := buildNCONCPESPKeyConfiguration(parameters)
	if err != nil {
		if s.client.options.Logger != nil {
			s.client.options.Logger.WarnContext(s.ctx, "ESP rekey keys were unusable; using oNCP/TLS: ", err)
		}
		_ = channel.Close()
		return nil
	}
	defer clearNCONCPESPKeyConfiguration(&keyConfiguration)
	defer clear(response)
	s.espControlAccess.Lock()
	defer s.espControlAccess.Unlock()
	s.access.RLock()
	connection := s.connection
	owned := s.configuration == configuration && s.esp == channel && !s.closed
	s.access.RUnlock()
	if !owned || connection == nil {
		return ErrClientClosed
	}
	wasEnabled := s.espEnabled.Swap(false)
	if wasEnabled {
		s.client.setActiveTransport(s, TransportONCP)
	}
	err = espConfiguration.keys.install(keyConfiguration)
	if err != nil {
		if s.client.options.Logger != nil {
			s.client.options.Logger.WarnContext(s.ctx, "ESP rekey installation failed; using oNCP/TLS: ", err)
		}
		_ = channel.Close()
		return nil
	}
	err = connection.writeRecord(response)
	if err != nil {
		return E.Cause(err, "send Network Connect ESP KMP 302 response")
	}
	s.access.Lock()
	espConfiguration.encryption = parameters.encryption
	espConfiguration.authentication = parameters.authentication
	espConfiguration.compression = parameters.compression == 1
	espConfiguration.replayProtection = parameters.replayProtection
	espConfiguration.dpd = parameters.dpd
	s.access.Unlock()
	if wasEnabled && channel.Ready() {
		s.espEnabled.Store(true)
		s.client.setActiveTransport(s, TransportESP)
	}
	return nil
}

func (s *ncSession) handleServerESPControl(payload []byte) error {
	if len(payload) != 13 || binary.BigEndian.Uint16(payload[0:2]) != 6 || binary.BigEndian.Uint32(payload[2:6]) != 7 || binary.BigEndian.Uint16(payload[6:8]) != 1 || binary.BigEndian.Uint32(payload[8:12]) != 1 {
		return markTerminal(E.New("ESP KMP 303 control payload is invalid"))
	}
	if payload[12] != 0 {
		return nil
	}
	s.espControlAccess.Lock()
	wasEnabled := s.espEnabled.Swap(false)
	s.access.Lock()
	channel := s.esp
	s.esp = nil
	if s.configuration != nil {
		s.configuration.esp = nil
	}
	s.access.Unlock()
	s.espControlAccess.Unlock()
	if wasEnabled {
		s.client.setActiveTransport(s, TransportONCP)
	}
	if channel != nil {
		return channel.Close()
	}
	return nil
}

func (s *ncSession) deliverTLSData(packetBuffer *buf.Buffer) error {
	s.access.RLock()
	configuration := s.configuration
	s.access.RUnlock()
	if configuration == nil {
		packetBuffer.Release()
		return ErrDataChannelNotReady
	}
	payload := packetBuffer.Bytes()
	for len(payload) > 0 {
		packetLength, err := validateNCONCPIPv4Packet(payload, false)
		if err != nil {
			packetBuffer.Release()
			return markTerminal(err)
		}
		if packetLength > len(payload) {
			packetBuffer.Release()
			return markTerminal(E.New("oNCP KMP 300 contains a truncated IPv4 packet"))
		}
		if packetLength == packetBuffer.Len() {
			s.client.pushIncomingDataPacketContext(s.ctx, packetBuffer)
			return nil
		}
		s.client.pushIncomingDataPacketContext(s.ctx, newPacketBufferFrom(payload[:packetLength]))
		payload = payload[packetLength:]
	}
	packetBuffer.Release()
	return nil
}

func (s *ncSession) deliverESPData(packetBuffer *buf.Buffer) {
	if !s.espEnabled.Load() {
		packetBuffer.Release()
		return
	}
	_, err := validateNCONCPIPv4Packet(packetBuffer.Bytes(), true)
	if err != nil {
		packetBuffer.Release()
		if s.client.options.Logger != nil {
			s.client.options.Logger.DebugContext(s.ctx, "Ignoring invalid Network Connect ESP IPv4 packet: ", err)
		}
		return
	}
	s.client.pushIncomingDataPacketContext(s.ctx, packetBuffer)
}

func validateNCONCPIPv4Packet(payload []byte, exact bool) (int, error) {
	if len(payload) < 20 || payload[0]>>4 != 4 {
		return 0, E.Extend(ErrProtocolNotSupported, "oNCP supports IPv4 packets only")
	}
	headerLength := int(payload[0]&0x0f) * 4
	packetLength := int(binary.BigEndian.Uint16(payload[2:4]))
	if headerLength < 20 || packetLength < headerLength || packetLength > len(payload) {
		return 0, E.New("oNCP IPv4 packet length is invalid")
	}
	if exact && packetLength != len(payload) {
		return 0, E.New("ESP IPv4 packet has trailing bytes")
	}
	return packetLength, nil
}

func (s *ncSession) Done() <-chan error {
	return s.done
}

func (s *ncSession) Ready() bool {
	return s.ready.Load()
}

func (s *ncSession) TunnelConfiguration() TunnelConfiguration {
	s.access.RLock()
	defer s.access.RUnlock()
	if s.configuration == nil {
		return TunnelConfiguration{}
	}
	return cloneTunnelConfiguration(s.configuration.configuration)
}

func (s *ncSession) WriteDataPacket(payload []byte) error {
	return s.WriteDataPackets([][]byte{payload})
}

func (s *ncSession) WriteDataPackets(payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	return s.WriteDataPacketBuffers(newPacketBuffersFrom(payloads))
}

func (s *ncSession) WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error {
	defer buf.ReleaseMulti(packetBuffers)
	s.access.RLock()
	connection := s.connection
	configuration := s.configuration
	esp := s.esp
	closed := s.closed
	s.access.RUnlock()
	if closed || !s.ready.Load() || connection == nil || configuration == nil {
		return ErrDataChannelNotReady
	}
	validPacketBuffers := packetBuffers
	var validationErr error
	for index, packetBuffer := range packetBuffers {
		packetLength, err := validateNCONCPIPv4Packet(packetBuffer.Bytes(), true)
		if err != nil {
			validPacketBuffers = packetBuffers[:index]
			validationErr = err
			break
		}
		if packetLength > int(configuration.configuration.MTU) {
			validPacketBuffers = packetBuffers[:index]
			validationErr = E.New("oNCP IPv4 packet exceeds negotiated MTU: ", packetLength)
			break
		}
	}
	if len(validPacketBuffers) == 0 {
		return validationErr
	}
	if s.espEnabled.Load() && esp != nil && esp.Ready() {
		err := esp.WriteDataPacketBuffers(validPacketBuffers)
		if err != nil {
			return err
		}
		return validationErr
	}
	err := connection.writeKMPPacketBuffers(ncONCPKMPData, validPacketBuffers)
	if err != nil {
		wrappedErr := E.Cause(err, "write Network Connect oNCP KMP 300 data packet")
		s.terminate(wrappedErr)
		return wrappedErr
	}
	return validationErr
}

func (s *ncSession) Fail(err error) {
	if err == nil {
		err = E.New("oNCP session failed")
	}
	s.terminate(err)
}

func (s *ncSession) Close() error {
	s.closeOnce.Do(func() {
		s.access.RLock()
		connection := s.connection
		terminalErr := s.terminalErr
		s.access.RUnlock()
		if connection != nil && terminalErr == nil && s.espEnabled.Load() {
			s.espControlAccess.Lock()
			s.espEnabled.Store(false)
			deadlineErr := connection.SetWriteDeadline(time.Now().Add(ncESPDisableWait))
			message, encodeErr := encodeNCONCPESPControl(false)
			var writeErr error
			if deadlineErr == nil && encodeErr == nil {
				writeErr = connection.writeRecord(message)
			}
			clear(message)
			clearDeadlineErr := connection.SetWriteDeadline(time.Time{})
			s.espControlAccess.Unlock()
			s.access.Lock()
			s.closeErr = E.Append(s.closeErr, deadlineErr, func(cause error) error {
				return E.Cause(cause, "set Network Connect ESP disable deadline")
			})
			s.closeErr = E.Append(s.closeErr, encodeErr, func(cause error) error {
				return E.Cause(cause, "encode Network Connect ESP disable control")
			})
			s.closeErr = E.Append(s.closeErr, writeErr, func(cause error) error {
				return E.Cause(cause, "send Network Connect ESP disable control")
			})
			s.closeErr = E.Append(s.closeErr, clearDeadlineErr, func(cause error) error {
				return E.Cause(cause, "clear Network Connect ESP disable deadline")
			})
			s.access.Unlock()
		}
		s.terminate(nil)
		s.waitGroup.Wait()
	})
	s.access.RLock()
	closeErr := s.closeErr
	s.access.RUnlock()
	return closeErr
}

func (s *ncSession) terminate(err error) {
	s.doneOnce.Do(func() {
		s.ready.Store(false)
		s.espEnabled.Store(false)
		s.cancel()
		s.access.Lock()
		s.closed = true
		s.terminalErr = err
		connection := s.connection
		s.connection = nil
		configuration := s.configuration
		s.configuration = nil
		esp := s.esp
		s.esp = nil
		attached := s.attached
		s.attached = false
		s.access.Unlock()
		s.client.stopActiveTransport(s)
		if connection != nil {
			closeErr := connection.Close()
			if closeErr != nil && !E.IsClosed(closeErr) {
				s.access.Lock()
				s.closeErr = E.Append(s.closeErr, closeErr, func(cause error) error {
					return E.Cause(cause, "close Network Connect oNCP TLS connection")
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
		if esp != nil {
			closeErr := esp.Close()
			if closeErr != nil {
				s.access.Lock()
				s.closeErr = E.Append(s.closeErr, closeErr, func(cause error) error {
					return E.Cause(cause, "close Network Connect ESP channel")
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
		destroyNCTunnelConfiguration(configuration)
		if attached {
			s.state.detachSession(s)
		}
		if err != nil {
			s.done <- err
		}
		close(s.done)
	})
}

var _ clientSession = (*ncSession)(nil)
