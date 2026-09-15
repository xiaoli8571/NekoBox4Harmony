package openconnect

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
)

const (
	pppDefaultTunnelMTU         = 1400
	pppDefaultBaseMTU           = 1406
	pppDefaultNegotiationPeriod = 3 * time.Second
	pppDefaultNegotiationTries  = 10
	pppDefaultEchoFailures      = 3
)

func calculatePPPTunnelMTU(requestedMTU uint32, baseMTU uint32, outerIPv6 bool, encapsulation pppEncapsulation) uint32 {
	mtu := int(requestedMTU)
	if baseMTU == 0 {
		baseMTU = pppDefaultBaseMTU
	}
	if baseMTU < minimumIPv6MTU {
		baseMTU = minimumIPv6MTU
	}
	if mtu == 0 {
		outerIPHeaderSize := 20
		if outerIPv6 {
			outerIPHeaderSize = 40
		}
		mtu = int(baseMTU) - outerIPHeaderSize - 20
	}
	overhead := 5
	switch encapsulation {
	case pppEncapsulationF5:
		overhead += 4 + 1
	case pppEncapsulationF5HDLC:
		overhead += 4 + 1
	case pppEncapsulationFortinet:
		overhead += 6 + 2 + 2
	}
	mtu -= overhead
	if encapsulation == pppEncapsulationF5HDLC {
		mtu -= mtu >> 5
	}
	return uint32(mtu)
}

var (
	errPPPPeerDead       = E.New("PPP peer did not answer LCP echo requests")
	errPPPPeerTerminated = E.New("PPP peer terminated the link")
)

type pppCarrierConfig struct {
	Connection         net.Conn
	Datagram           bool
	MTU                uint32
	NegotiationTimeout time.Duration
}

type pppLinkConfig struct {
	Logger                 logger.ContextLogger
	Carrier                pppCarrierConfig
	Encapsulation          pppEncapsulation
	WantIPv4               bool
	WantIPv6               bool
	IPv4Address            netip.Prefix
	IPv6Address            netip.Prefix
	LockAddresses          bool
	MTU                    uint32
	RequestIPv4NameServers bool
	NegotiationPeriod      time.Duration
	NegotiationAttempts    int
	EchoInterval           time.Duration
	EchoFailures           int
	Deliver                func(*buf.Buffer)
}

type pppLinkPhase uint8

const (
	pppLinkPhaseEstablishing pppLinkPhase = iota
	pppLinkPhaseNetwork
	pppLinkPhaseTerminating
	pppLinkPhaseClosed
)

type pppCarrier struct {
	connection  net.Conn
	datagram    bool
	generation  uint64
	decoder     *pppFrameDecoder
	writeFailed bool
}

type pppOutboundPacket struct {
	generation          uint64
	protocol            uint16
	payload             []byte
	packetBuffer        **buf.Buffer
	protocolCompression bool
	addressCompression  bool
	asyncMap            uint32
}

type pppLink struct {
	ctx                         context.Context
	cancel                      context.CancelFunc
	config                      pppLinkConfig
	carrierAccess               sync.RWMutex
	carrier                     *pppCarrier
	lifecycleAccess             sync.Mutex
	access                      sync.Mutex
	writeAccess                 sync.Mutex
	configurationAccess         sync.RWMutex
	configuration               TunnelConfiguration
	lcp                         pppControlProtocolState
	ipcp                        pppControlProtocolState
	ip6cp                       pppControlProtocolState
	phase                       pppLinkPhase
	localMRU                    uint16
	peerMRU                     uint16
	localMagic                  [4]byte
	localMagicEnabled           bool
	requestAsyncMap             bool
	requestProtocolCompression  bool
	requestAddressCompression   bool
	localAsyncMap               uint32
	outboundProtocolCompression bool
	outboundAddressCompression  bool
	requestMRU                  bool
	addressesLocked             bool
	networkPending              bool
	wantIPv4                    bool
	wantIPv6                    bool
	localIPv4                   netip.Addr
	peerIPv4                    netip.Addr
	localIPv6                   netip.Addr
	peerIPv6                    netip.Addr
	nameServerRequests          map[byte]netip.Addr
	lastReceived                time.Time
	pendingEcho                 bool
	pendingEchoIdentifier       byte
	pendingEchoSent             time.Time
	missedEchoReplies           int
	readyWait                   chan struct{}
	readyWaitOnce               sync.Once
	termAcknowledged            chan struct{}
	termAcknowledgedOnce        sync.Once
	done                        chan error
	doneOnce                    sync.Once
	closeOnce                   sync.Once
	waitGroup                   sync.WaitGroup
	started                     bool
	closed                      bool
	closeErr                    error
	ready                       atomic.Bool
}

func newPPPLink(ctx context.Context, config pppLinkConfig) (*pppLink, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if config.Carrier.Connection == nil {
		return nil, markTerminal(E.New("PPP link requires a carrier connection"))
	}
	if !config.WantIPv4 && !config.WantIPv6 {
		return nil, markTerminal(E.New("PPP link requires IPv4 or IPv6"))
	}
	if config.IPv4Address.IsValid() && !config.IPv4Address.Addr().Is4() {
		return nil, markTerminal(E.New("PPP link IPv4 address is not IPv4"))
	}
	if config.IPv6Address.IsValid() && !config.IPv6Address.Addr().Is6() {
		return nil, markTerminal(E.New("PPP link IPv6 address is not IPv6"))
	}
	if config.MTU == 0 {
		config.MTU = pppDefaultTunnelMTU
	}
	maximumMTU := pppMaximumTunnelMTU(config.Encapsulation)
	if config.MTU < pppMinimumMRU || config.MTU > maximumMTU {
		return nil, markTerminal(E.New("PPP tunnel MTU is outside the supported range: ", config.MTU))
	}
	if config.NegotiationPeriod <= 0 {
		config.NegotiationPeriod = pppDefaultNegotiationPeriod
	}
	if config.NegotiationAttempts <= 0 {
		config.NegotiationAttempts = pppDefaultNegotiationTries
	}
	if config.EchoFailures <= 0 {
		config.EchoFailures = pppDefaultEchoFailures
	}
	decoder, err := newPPPFrameDecoder(config.Encapsulation)
	if err != nil {
		return nil, err
	}
	magic, err := randomPPPMagic()
	if err != nil {
		return nil, markTerminal(err)
	}
	linkContext, cancel := context.WithCancel(ctx)
	link := &pppLink{
		ctx:                linkContext,
		cancel:             cancel,
		config:             config,
		localMRU:           uint16(config.MTU),
		peerMRU:            pppDefaultMRU,
		localMagic:         magic,
		localMagicEnabled:  true,
		localIPv4:          config.IPv4Address.Addr(),
		localIPv6:          config.IPv6Address.Addr(),
		wantIPv4:           config.WantIPv4,
		wantIPv6:           config.WantIPv6,
		nameServerRequests: make(map[byte]netip.Addr),
		readyWait:          make(chan struct{}),
		termAcknowledged:   make(chan struct{}),
		done:               make(chan error, 1),
		phase:              pppLinkPhaseEstablishing,
		lastReceived:       time.Now(),
		addressesLocked:    config.LockAddresses,
	}
	link.requestProtocolCompression = config.Encapsulation != pppEncapsulationFortinet
	link.requestAddressCompression = config.Encapsulation != pppEncapsulationFortinet
	link.requestAsyncMap = config.Encapsulation == pppEncapsulationF5HDLC
	link.requestMRU = true
	if config.RequestIPv4NameServers {
		link.nameServerRequests[pppIPCPOptionPrimaryDNS] = netip.IPv4Unspecified()
		link.nameServerRequests[pppIPCPOptionPrimaryNBNS] = netip.IPv4Unspecified()
		link.nameServerRequests[pppIPCPOptionSecondaryDNS] = netip.IPv4Unspecified()
		link.nameServerRequests[pppIPCPOptionSecondaryNBNS] = netip.IPv4Unspecified()
	}
	link.carrier = &pppCarrier{
		connection: config.Carrier.Connection,
		datagram:   config.Carrier.Datagram,
		generation: 1,
		decoder:    decoder,
	}
	return link, nil
}

func (l *pppLink) Start() error {
	l.access.Lock()
	if l.closed || l.phase == pppLinkPhaseTerminating {
		l.access.Unlock()
		return ErrClientClosed
	}
	if l.started {
		readyWait := l.readyWait
		l.access.Unlock()
		return l.waitUntilReady(readyWait)
	}
	l.started = true
	readyWait := l.readyWait
	request, err := l.buildConfigurationRequestLocked(pppProtocolLCP, time.Now())
	var carrier *pppCarrier
	if err == nil {
		l.carrierAccess.RLock()
		carrier = l.carrier
		l.carrierAccess.RUnlock()
		l.waitGroup.Add(2)
	}
	l.access.Unlock()
	if err != nil {
		err = markTerminal(err)
		l.terminate(err)
		return err
	}
	go l.readLoop(carrier)
	go l.timerLoop()
	err = l.writeOutbound(request)
	if err != nil {
		if !l.terminateCarrier(request.generation, err, pppLinkPhaseEstablishing) {
			// The read side may have already terminated the carrier with a more
			// specific protocol error while this initial write was completing.
			return l.waitUntilReady(readyWait)
		}
		return err
	}
	return l.waitUntilReadyWithCarrierError(readyWait, carrier)
}

func (l *pppLink) SwitchCarrier(config pppCarrierConfig) error {
	if config.Connection == nil {
		return markTerminal(E.New("PPP carrier switch requires a connection"))
	}
	decoder, err := newPPPFrameDecoder(l.config.Encapsulation)
	if err != nil {
		return err
	}
	if config.MTU != 0 && (config.MTU < pppMinimumMRU || config.MTU > pppMaximumTunnelMTU(l.config.Encapsulation)) {
		return markTerminal(E.New("PPP takeover MTU is outside the supported range: ", config.MTU))
	}
	l.lifecycleAccess.Lock()
	l.access.Lock()
	if !l.started || l.closed {
		l.access.Unlock()
		l.lifecycleAccess.Unlock()
		return ErrClientClosed
	}
	if l.phase != pppLinkPhaseNetwork {
		l.access.Unlock()
		l.lifecycleAccess.Unlock()
		return ErrDataChannelNotReady
	}
	if config.MTU != 0 {
		l.localMRU = uint16(config.MTU)
		l.config.MTU = config.MTU
	}
	l.resetNegotiationLocked()
	readyWait := l.readyWait
	l.carrierAccess.Lock()
	oldCarrier := l.carrier
	newCarrier := &pppCarrier{
		connection: config.Connection,
		datagram:   config.Datagram,
		generation: oldCarrier.generation + 1,
		decoder:    decoder,
	}
	l.carrier = newCarrier
	l.carrierAccess.Unlock()
	request, buildErr := l.buildConfigurationRequestLocked(pppProtocolLCP, time.Now())
	if buildErr == nil {
		l.waitGroup.Add(1)
	}
	l.access.Unlock()
	l.lifecycleAccess.Unlock()
	closeErr := closePPPCarrierConnection(oldCarrier.connection)
	if closeErr != nil {
		l.access.Lock()
		l.closeErr = E.Append(l.closeErr, closeErr, func(cause error) error {
			return E.Cause(cause, "close previous PPP carrier")
		})
		l.access.Unlock()
	}
	if buildErr != nil {
		buildErr = markTerminal(buildErr)
		l.terminate(buildErr)
		return buildErr
	}
	go l.readLoop(newCarrier)
	err = l.writeOutbound(request)
	if err != nil {
		if !l.terminateCarrier(request.generation, err, pppLinkPhaseEstablishing) {
			return l.waitUntilReady(readyWait)
		}
		return err
	}
	return l.waitUntilReadyWithTimeout(readyWait, newCarrier.generation, config.NegotiationTimeout)
}

func pppMaximumTunnelMTU(encapsulation pppEncapsulation) uint32 {
	maximumMTU := uint32(pppMaximumPayloadLength - 4)
	if encapsulation == pppEncapsulationFortinet {
		maximumMTU -= 6
	}
	return maximumMTU
}

// crypto/tls.Conn.Close sends close_notify before closing its underlying transport, so carrier cleanup must first interrupt pending I/O.
func closePPPCarrierConnection(connection net.Conn) error {
	deadlineErr := connection.SetDeadline(time.Now())
	if E.IsClosed(deadlineErr) {
		deadlineErr = nil
	}
	if deadlineErr != nil {
		deadlineErr = E.Cause(deadlineErr, "set PPP carrier close deadline")
	}
	closeErr := connection.Close()
	if E.IsClosed(closeErr) || E.IsTimeout(closeErr) {
		closeErr = nil
	}
	return E.Errors(deadlineErr, closeErr)
}

func (l *pppLink) waitUntilReady(readyWait <-chan struct{}) error {
	select {
	case <-readyWait:
		return nil
	case err, loaded := <-l.done:
		if loaded && err != nil {
			return err
		}
		return ErrClientClosed
	}
}

func (l *pppLink) waitUntilReadyWithCarrierError(readyWait <-chan struct{}, carrier *pppCarrier) error {
	provider, loaded := carrier.connection.(pppCarrierErrorProvider)
	if !loaded {
		return l.waitUntilReady(readyWait)
	}
	classificationReady := provider.pppCarrierErrorReady()
	for {
		select {
		case <-readyWait:
			return nil
		case err, doneLoaded := <-l.done:
			if doneLoaded && err != nil {
				return err
			}
			return ErrClientClosed
		case <-classificationReady:
			classificationErr, classified := provider.pppCarrierError()
			if classified && classificationErr != nil {
				l.terminateCarrier(carrier.generation, classificationErr, pppLinkPhaseEstablishing)
				return classificationErr
			}
			classificationReady = nil
		}
	}
}

func (l *pppLink) waitUntilReadyWithTimeout(
	readyWait <-chan struct{},
	generation uint64,
	timeout time.Duration,
) error {
	if timeout <= 0 {
		return l.waitUntilReady(readyWait)
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-readyWait:
		return nil
	case err, loaded := <-l.done:
		if loaded && err != nil {
			return err
		}
		return ErrClientClosed
	case <-timer.C:
		timeoutErr := E.New("PPP carrier negotiation timed out")
		if l.terminateCarrier(generation, timeoutErr, pppLinkPhaseEstablishing) {
			return timeoutErr
		}
		return l.waitUntilReady(readyWait)
	}
}

func (l *pppLink) Done() <-chan error {
	return l.done
}

func (l *pppLink) Ready() bool {
	return l.ready.Load()
}

func (l *pppLink) TunnelConfiguration() TunnelConfiguration {
	l.configurationAccess.RLock()
	defer l.configurationAccess.RUnlock()
	return cloneTunnelConfiguration(l.configuration)
}

func (l *pppLink) WriteDataPacket(payload []byte) error {
	return l.WriteDataPackets([][]byte{payload})
}

func (l *pppLink) WriteDataPackets(payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	return l.WriteDataPacketBuffers(newPacketBuffersFrom(payloads))
}

func (l *pppLink) WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error {
	defer buf.ReleaseMulti(packetBuffers)
	if !l.ready.Load() {
		return ErrDataChannelNotReady
	}
	l.access.Lock()
	if l.closed || l.phase != pppLinkPhaseNetwork {
		l.access.Unlock()
		return ErrDataChannelNotReady
	}
	mtu := min(int(l.localMRU), int(l.peerMRU))
	packets := make([]pppOutboundPacket, 0, len(packetBuffers))
	var validationErr error
	for index, packetBuffer := range packetBuffers {
		if packetBuffer.IsEmpty() {
			validationErr = E.New("empty PPP data packet")
			break
		}
		if packetBuffer.Len() > mtu {
			validationErr = E.New("PPP data packet exceeds negotiated MTU: ", packetBuffer.Len(), " > ", mtu)
			break
		}
		var protocol uint16
		switch packetBuffer.Byte(0) >> 4 {
		case 4:
			if !l.wantIPv4 {
				validationErr = E.Extend(ErrProtocolNotSupported, "PPP IPv4 data on an IPv6-only link")
			}
			protocol = pppProtocolIPv4
		case 6:
			if !l.wantIPv6 {
				validationErr = E.Extend(ErrProtocolNotSupported, "PPP IPv6 data on an IPv4-only link")
			}
			protocol = pppProtocolIPv6
		default:
			validationErr = E.New("PPP data packet has an invalid IP version")
		}
		if validationErr != nil {
			break
		}
		packets = append(packets, l.outboundPacketBufferLocked(protocol, &packetBuffers[index]))
	}
	l.access.Unlock()
	if len(packets) == 0 {
		return validationErr
	}
	err := l.writeOutbounds(packets)
	if err != nil && !E.IsMulti(err, ErrDataChannelNotReady) {
		if !l.terminateCarrier(packets[0].generation, err, pppLinkPhaseNetwork) {
			return ErrDataChannelNotReady
		}
	}
	if err != nil {
		return err
	}
	return validationErr
}

func (l *pppLink) Fail(err error) {
	if err == nil {
		err = E.New("PPP link failed")
	}
	l.terminate(err)
}

func (l *pppLink) Close() error {
	l.closeOnce.Do(func() {
		l.lifecycleAccess.Lock()
		l.access.Lock()
		if l.closed {
			l.access.Unlock()
			l.lifecycleAccess.Unlock()
			l.waitGroup.Wait()
			return
		}
		l.phase = pppLinkPhaseTerminating
		l.ready.Store(false)
		l.access.Unlock()
		l.carrierAccess.RLock()
		carrier := l.carrier
		datagram := carrier != nil && carrier.datagram
		l.carrierAccess.RUnlock()
		l.lifecycleAccess.Unlock()
		attempts := 1
		if datagram {
			attempts = 3
		}
		var err error
		for i := 0; i < attempts; i++ {
			l.access.Lock()
			if l.closed {
				l.access.Unlock()
				break
			}
			l.lcp.nextIdentifier++
			identifier := l.lcp.nextIdentifier
			control, buildErr := buildPPPControlPacket(pppCodeTerminateRequest, identifier, nil)
			packet := l.outboundPacketLocked(pppProtocolLCP, control)
			l.access.Unlock()
			if buildErr != nil {
				err = buildErr
				break
			}
			contended := !l.writeAccess.TryLock()
			if contended {
				deadlineErr := carrier.connection.SetWriteDeadline(time.Now().Add(100 * time.Millisecond))
				if deadlineErr != nil {
					closeErr := carrier.connection.Close()
					err = E.Cause(deadlineErr, "interrupt blocked PPP carrier write")
					if closeErr != nil && !E.IsClosed(closeErr) {
						err = E.Errors(err, E.Cause(closeErr, "close blocked PPP carrier"))
					}
					break
				}
				l.writeAccess.Lock()
			}
			if contended && carrier.writeFailed {
				closeErr := carrier.connection.Close()
				l.writeAccess.Unlock()
				if closeErr != nil && !E.IsClosed(closeErr) {
					err = E.Cause(closeErr, "close PPP carrier after interrupted write")
				}
				break
			}
			deadlineErr := carrier.connection.SetWriteDeadline(time.Now().Add(time.Second))
			if deadlineErr == nil {
				err = l.writeOutboundLocked(packet)
			} else {
				err = E.Cause(deadlineErr, "set PPP termination write deadline")
			}
			l.writeAccess.Unlock()
			if err != nil {
				break
			}
			timer := time.NewTimer(time.Second)
			acknowledged := false
			select {
			case <-l.termAcknowledged:
				acknowledged = true
				if !timer.Stop() {
					<-timer.C
				}
			case <-timer.C:
			case <-l.done:
				if !timer.Stop() {
					<-timer.C
				}
			}
			if acknowledged {
				break
			}
		}
		l.terminate(nil)
		l.waitGroup.Wait()
		if err != nil && !E.IsClosed(err) {
			l.access.Lock()
			l.closeErr = E.Append(l.closeErr, err, func(cause error) error {
				return E.Cause(cause, "terminate PPP link")
			})
			l.access.Unlock()
		}
	})
	l.access.Lock()
	closeErr := l.closeErr
	l.access.Unlock()
	return closeErr
}

func (l *pppLink) readLoop(carrier *pppCarrier) {
	defer l.waitGroup.Done()
	buffer := make([]byte, pppMaximumWireFrameSize)
	for {
		n, err := carrier.connection.Read(buffer)
		if n > 0 {
			frames, decodeErr := carrier.decoder.Push(buffer[:n])
			if carrier.datagram {
				dropped := carrier.decoder.Discard()
				if l.config.Logger != nil {
					if decodeErr != nil {
						l.config.Logger.WarnContext(l.ctx, "dropped invalid PPP datagram: ", decodeErr)
					} else if dropped > 0 {
						l.config.Logger.DebugContext(l.ctx, "dropped truncated PPP frame remainder: ", dropped, " bytes")
					}
				}
			} else if decodeErr != nil {
				l.terminateCarrier(carrier.generation, markTerminal(E.Cause(decodeErr, "decode PPP carrier frame")),
					pppLinkPhaseEstablishing, pppLinkPhaseNetwork)
				return
			}
			for index, frame := range frames {
				handleErr := l.handleFrame(carrier.generation, frame)
				if handleErr != nil {
					buf.ReleaseMulti(frames[index+1:])
					phases := []pppLinkPhase{pppLinkPhaseEstablishing, pppLinkPhaseNetwork}
					if E.IsMulti(handleErr, errPPPPeerTerminated) {
						phases = append(phases, pppLinkPhaseTerminating)
					}
					l.terminateCarrier(carrier.generation, handleErr, phases...)
					return
				}
			}
		}
		if err != nil {
			if !l.isCurrentCarrier(carrier) || l.ctx.Err() != nil {
				return
			}
			if err == io.EOF || E.IsClosed(err) {
				l.terminateCarrier(carrier.generation, E.New("PPP carrier closed"),
					pppLinkPhaseEstablishing, pppLinkPhaseNetwork)
			} else {
				l.terminateCarrier(carrier.generation, E.Cause(err, "read PPP carrier"),
					pppLinkPhaseEstablishing, pppLinkPhaseNetwork)
			}
			return
		}
		if n == 0 {
			if !l.isCurrentCarrier(carrier) || l.ctx.Err() != nil {
				return
			}
			l.terminateCarrier(carrier.generation, E.New("PPP carrier returned an empty read"),
				pppLinkPhaseEstablishing, pppLinkPhaseNetwork)
			return
		}
	}
}

func (l *pppLink) isCurrentCarrier(carrier *pppCarrier) bool {
	l.carrierAccess.RLock()
	current := l.carrier == carrier
	l.carrierAccess.RUnlock()
	return current
}

func (l *pppLink) writeOutbound(packet pppOutboundPacket) error {
	return l.writeOutbounds([]pppOutboundPacket{packet})
}

func (l *pppLink) writeOutbounds(packets []pppOutboundPacket) error {
	if len(packets) == 0 {
		return nil
	}
	l.writeAccess.Lock()
	defer l.writeAccess.Unlock()
	return l.writeOutboundsLocked(packets)
}

func (l *pppLink) writeOutboundLocked(packet pppOutboundPacket) error {
	return l.writeOutboundsLocked([]pppOutboundPacket{packet})
}

func (l *pppLink) writeOutboundsLocked(packets []pppOutboundPacket) error {
	l.carrierAccess.RLock()
	carrier := l.carrier
	if carrier == nil || carrier.generation != packets[0].generation {
		l.carrierAccess.RUnlock()
		return ErrDataChannelNotReady
	}
	connection := carrier.connection
	datagram := carrier.datagram
	l.carrierAccess.RUnlock()
	frames := make([][]byte, 0, len(packets))
	var encodeErr error
	for _, packet := range packets {
		if packet.generation != carrier.generation {
			encodeErr = ErrDataChannelNotReady
			break
		}
		var frame []byte
		frame, encodeErr = encodePPPOutboundPacket(l.config.Encapsulation, packet)
		if encodeErr != nil {
			encodeErr = markTerminal(encodeErr)
			break
		}
		frames = append(frames, frame)
	}
	if len(frames) == 0 {
		return encodeErr
	}
	if datagram {
		for _, frame := range frames {
			n, writeErr := connection.Write(frame)
			if writeErr != nil {
				carrier.writeFailed = true
				if !l.isCurrentCarrier(carrier) {
					return ErrDataChannelNotReady
				}
				return E.Cause(writeErr, "write PPP datagram")
			}
			if n != len(frame) {
				carrier.writeFailed = true
				if !l.isCurrentCarrier(carrier) {
					return ErrDataChannelNotReady
				}
				return E.New("short PPP datagram write: wrote ", n, " of ", len(frame), " bytes")
			}
		}
		if !l.isCurrentCarrier(carrier) {
			return ErrDataChannelNotReady
		}
		return encodeErr
	}
	writeErr := writeByteSequence(connection, frames)
	if writeErr != nil {
		carrier.writeFailed = true
		if !l.isCurrentCarrier(carrier) {
			return ErrDataChannelNotReady
		}
		return E.Cause(writeErr, "write PPP stream frame")
	}
	if !l.isCurrentCarrier(carrier) {
		return ErrDataChannelNotReady
	}
	return encodeErr
}

func encodePPPOutboundPacket(encapsulation pppEncapsulation, packet pppOutboundPacket) ([]byte, error) {
	if packet.packetBuffer != nil {
		return encodePPPOutboundPacketBuffer(encapsulation, packet)
	}
	if packet.protocol == 0 || len(packet.payload) == 0 {
		return nil, E.New("invalid empty PPP outbound packet")
	}
	header := buildPPPPacketHeader(packet.protocol, packet.protocolCompression, packet.addressCompression)
	payload := make([]byte, 0, len(header)+len(packet.payload))
	payload = append(payload, header...)
	payload = append(payload, packet.payload...)
	return encodePPPFrame(encapsulation, payload, packet.asyncMap)
}

func encodePPPOutboundPacketBuffer(encapsulation pppEncapsulation, packet pppOutboundPacket) ([]byte, error) {
	if packet.protocol == 0 || packet.packetBuffer == nil || *packet.packetBuffer == nil || (*packet.packetBuffer).IsEmpty() {
		return nil, E.New("invalid empty PPP outbound packet")
	}
	header := buildPPPPacketHeader(packet.protocol, packet.protocolCompression, packet.addressCompression)
	switch encapsulation {
	case pppEncapsulationF5:
		payloadLength := len(header) + (*packet.packetBuffer).Len()
		*packet.packetBuffer = requirePacketBufferCapacity(*packet.packetBuffer, 4+len(header), 0)
		copy((*packet.packetBuffer).ExtendHeader(len(header)), header)
		frameHeader := (*packet.packetBuffer).ExtendHeader(4)
		binary.BigEndian.PutUint16(frameHeader[:2], pppF5Magic)
		binary.BigEndian.PutUint16(frameHeader[2:4], uint16(payloadLength))
	case pppEncapsulationF5HDLC:
		*packet.packetBuffer = encodePPPHDLCFrameBuffer(*packet.packetBuffer, header, packet.asyncMap)
	case pppEncapsulationFortinet:
		payloadLength := len(header) + (*packet.packetBuffer).Len()
		if payloadLength > pppMaximumPayloadLength-6 {
			return nil, E.New("PPP payload exceeds frame length field")
		}
		*packet.packetBuffer = requirePacketBufferCapacity(*packet.packetBuffer, 6+len(header), 0)
		copy((*packet.packetBuffer).ExtendHeader(len(header)), header)
		frameHeader := (*packet.packetBuffer).ExtendHeader(6)
		binary.BigEndian.PutUint16(frameHeader[:2], uint16(6+payloadLength))
		binary.BigEndian.PutUint16(frameHeader[2:4], pppFortinetMagic)
		binary.BigEndian.PutUint16(frameHeader[4:6], uint16(payloadLength))
	default:
		return nil, E.Extend(ErrProtocolNotSupported, "PPP encapsulation: ", encapsulation)
	}
	return (*packet.packetBuffer).Bytes(), nil
}

func encodePPPHDLCFrameBuffer(packetBuffer *buf.Buffer, header []byte, asyncMap uint32) *buf.Buffer {
	maximumFrameLength := 2*(len(header)+packetBuffer.Len()) + 6
	frameBuffer := newPacketBuffer(maximumFrameLength)
	_ = frameBuffer.WriteByte(pppHDLCFlag)
	fcs := uint16(pppHDLCInitialFCS)
	for _, value := range header {
		fcs = updatePPPHDLCFCS(fcs, value)
		writePPPHDLCBufferByte(frameBuffer, value, asyncMap)
	}
	for _, value := range packetBuffer.Bytes() {
		fcs = updatePPPHDLCFCS(fcs, value)
		writePPPHDLCBufferByte(frameBuffer, value, asyncMap)
	}
	fcs ^= 0xffff
	writePPPHDLCBufferByte(frameBuffer, byte(fcs), asyncMap)
	writePPPHDLCBufferByte(frameBuffer, byte(fcs>>8), asyncMap)
	_ = frameBuffer.WriteByte(pppHDLCFlag)
	packetBuffer.Release()
	return frameBuffer
}

func writePPPHDLCBufferByte(destination *buf.Buffer, value byte, asyncMap uint32) {
	needsEscape := value == pppHDLCEscape || value == pppHDLCFlag
	if value < 0x20 && asyncMap&(uint32(1)<<value) != 0 {
		needsEscape = true
	}
	if needsEscape {
		_ = destination.WriteByte(pppHDLCEscape)
		_ = destination.WriteByte(value ^ 0x20)
	} else {
		_ = destination.WriteByte(value)
	}
}

func (l *pppLink) terminate(err error) {
	l.lifecycleAccess.Lock()
	l.terminateLocked(err)
	l.lifecycleAccess.Unlock()
}

func (l *pppLink) terminateCarrier(generation uint64, err error, phases ...pppLinkPhase) bool {
	l.lifecycleAccess.Lock()
	l.access.Lock()
	phaseMatches := slices.Contains(phases, l.phase)
	l.carrierAccess.RLock()
	carrier := l.carrier
	current := carrier != nil && carrier.generation == generation
	l.carrierAccess.RUnlock()
	shouldTerminate := !l.closed && phaseMatches && current
	l.access.Unlock()
	if shouldTerminate {
		l.terminateLocked(err)
	}
	l.lifecycleAccess.Unlock()
	return shouldTerminate
}

func (l *pppLink) terminateLocked(err error) {
	l.doneOnce.Do(func() {
		l.cancel()
		l.access.Lock()
		l.ready.Store(false)
		l.closed = true
		l.phase = pppLinkPhaseClosed
		l.access.Unlock()
		l.carrierAccess.Lock()
		carrier := l.carrier
		l.carrier = nil
		l.carrierAccess.Unlock()
		var closeErr error
		if carrier != nil {
			closeErr = closePPPCarrierConnection(carrier.connection)
		}
		if closeErr != nil {
			l.access.Lock()
			l.closeErr = E.Append(l.closeErr, closeErr, func(cause error) error {
				return E.Cause(cause, "close PPP carrier")
			})
			l.access.Unlock()
			if err == nil {
				err = closeErr
			} else {
				err = E.Errors(err, closeErr)
			}
		}
		if err != nil {
			l.done <- err
		}
		close(l.done)
	})
}
