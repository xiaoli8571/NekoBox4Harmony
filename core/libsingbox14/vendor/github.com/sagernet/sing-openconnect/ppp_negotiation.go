package openconnect

import (
	"encoding/binary"
	"net/netip"
	"sync"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

func (l *pppLink) resetNegotiationLocked() {
	l.lcp = pppControlProtocolState{}
	l.ipcp = pppControlProtocolState{}
	l.ip6cp = pppControlProtocolState{}
	l.phase = pppLinkPhaseEstablishing
	l.peerMRU = pppDefaultMRU
	l.localAsyncMap = 0
	l.requestMRU = true
	l.requestAsyncMap = l.config.Encapsulation == pppEncapsulationF5HDLC
	l.requestProtocolCompression = l.config.Encapsulation != pppEncapsulationFortinet
	l.requestAddressCompression = l.config.Encapsulation != pppEncapsulationFortinet
	l.localMagicEnabled = true
	l.outboundProtocolCompression = false
	l.outboundAddressCompression = false
	l.pendingEcho = false
	l.missedEchoReplies = 0
	l.networkPending = false
	l.lastReceived = time.Now()
	l.ready.Store(false)
	l.readyWait = make(chan struct{})
	l.readyWaitOnce = sync.Once{}
	l.termAcknowledged = make(chan struct{})
	l.termAcknowledgedOnce = sync.Once{}
}

func (l *pppLink) controlStateLocked(protocol uint16) (*pppControlProtocolState, error) {
	switch protocol {
	case pppProtocolLCP:
		return &l.lcp, nil
	case pppProtocolIPCP:
		return &l.ipcp, nil
	case pppProtocolIP6CP:
		return &l.ip6cp, nil
	default:
		return nil, E.New("unsupported PPP control protocol: ", protocol)
	}
}

func (l *pppLink) buildConfigurationRequestLocked(protocol uint16, now time.Time) (pppOutboundPacket, error) {
	state, err := l.controlStateLocked(protocol)
	if err != nil {
		return pppOutboundPacket{}, err
	}
	var payload []byte
	switch protocol {
	case pppProtocolLCP:
		if l.requestMRU {
			payload = appendPPPOptionUint16(payload, pppLCPOptionMRU, l.localMRU)
		}
		if l.requestAsyncMap {
			payload = appendPPPOptionUint32(payload, pppLCPOptionAsyncMap, l.localAsyncMap)
		}
		if l.localMagicEnabled {
			l.localMagic, err = randomPPPMagic()
			if err != nil {
				return pppOutboundPacket{}, err
			}
			payload = appendPPPOption(payload, pppLCPOptionMagic, l.localMagic[:])
		}
		if l.requestProtocolCompression {
			payload = appendPPPOption(payload, pppLCPOptionProtocolCompression, nil)
		}
		if l.requestAddressCompression {
			payload = appendPPPOption(payload, pppLCPOptionAddressCompression, nil)
		}
	case pppProtocolIPCP:
		var address [4]byte
		if l.localIPv4.Is4() {
			address = l.localIPv4.As4()
		}
		payload = appendPPPOption(payload, pppIPCPOptionAddress, address[:])
		for _, kind := range []byte{
			pppIPCPOptionPrimaryDNS,
			pppIPCPOptionPrimaryNBNS,
			pppIPCPOptionSecondaryDNS,
			pppIPCPOptionSecondaryNBNS,
		} {
			addressValue, requested := l.nameServerRequests[kind]
			if !requested {
				continue
			}
			address = [4]byte{}
			if addressValue.Is4() {
				address = addressValue.As4()
			}
			payload = appendPPPOption(payload, kind, address[:])
		}
	case pppProtocolIP6CP:
		identifier := pppInterfaceID(l.localIPv6)
		payload = appendPPPOption(payload, pppIP6CPOptionInterfaceID, identifier[:])
	}
	state.nextIdentifier++
	state.requestIdentifier = state.nextIdentifier
	state.requestSent = true
	state.requestAcknowledged = false
	state.requestAttempts++
	state.lastRequestUnixNano = now.UnixNano()
	control, err := buildPPPControlPacket(pppCodeConfigureRequest, state.requestIdentifier, payload)
	if err != nil {
		return pppOutboundPacket{}, err
	}
	return l.outboundPacketLocked(protocol, control), nil
}

func (l *pppLink) outboundPacketLocked(protocol uint16, payload []byte) pppOutboundPacket {
	l.carrierAccess.RLock()
	carrier := l.carrier
	var generation uint64
	if carrier != nil {
		generation = carrier.generation
	}
	l.carrierAccess.RUnlock()
	asyncMap := l.localAsyncMap
	if protocol == pppProtocolLCP {
		asyncMap = pppHDLCControlEscapeMask
	}
	return pppOutboundPacket{
		generation:          generation,
		protocol:            protocol,
		payload:             append([]byte(nil), payload...),
		protocolCompression: l.outboundProtocolCompression,
		addressCompression:  l.outboundAddressCompression,
		asyncMap:            asyncMap,
	}
}

func (l *pppLink) outboundPacketBufferLocked(protocol uint16, packetBuffer **buf.Buffer) pppOutboundPacket {
	l.carrierAccess.RLock()
	carrier := l.carrier
	var generation uint64
	if carrier != nil {
		generation = carrier.generation
	}
	l.carrierAccess.RUnlock()
	asyncMap := l.localAsyncMap
	if protocol == pppProtocolLCP {
		asyncMap = pppHDLCControlEscapeMask
	}
	return pppOutboundPacket{
		generation:          generation,
		protocol:            protocol,
		packetBuffer:        packetBuffer,
		protocolCompression: l.outboundProtocolCompression,
		addressCompression:  l.outboundAddressCompression,
		asyncMap:            asyncMap,
	}
}

func (l *pppLink) handleFrame(generation uint64, frame *buf.Buffer) error {
	defer func() {
		if frame != nil {
			frame.Release()
		}
	}()
	l.access.Lock()
	if l.closed {
		l.access.Unlock()
		return nil
	}
	l.carrierAccess.RLock()
	carrier := l.carrier
	currentGeneration := uint64(0)
	if carrier != nil {
		currentGeneration = carrier.generation
	}
	l.carrierAccess.RUnlock()
	if generation != currentGeneration {
		l.access.Unlock()
		return nil
	}
	protocol, payload, err := parsePPPPacket(frame.Bytes())
	if err != nil {
		l.access.Unlock()
		return markTerminal(E.Cause(err, "parse PPP packet"))
	}
	l.lastReceived = time.Now()
	l.pendingEcho = false
	l.missedEchoReplies = 0
	var outbound []pppOutboundPacket
	var delivered *buf.Buffer
	peerTerminated := false
	switch protocol {
	case pppProtocolLCP, pppProtocolIPCP, pppProtocolIP6CP:
		if protocol == pppProtocolIPCP && !l.wantIPv4 {
			outbound, err = l.protocolRejectionLocked(protocol, payload)
		} else if protocol == pppProtocolIP6CP && !l.wantIPv6 {
			outbound, err = l.protocolRejectionLocked(protocol, payload)
		} else {
			outbound, peerTerminated, err = l.handleControlPacketLocked(protocol, payload)
		}
	case pppProtocolIPv4, pppProtocolIPv6:
		if l.phase == pppLinkPhaseNetwork {
			frame.Advance(frame.Len() - len(payload))
			delivered = frame
			frame = nil
		}
	default:
		outbound, err = l.protocolRejectionLocked(protocol, payload)
	}
	l.access.Unlock()
	if err != nil {
		if E.IsMulti(err, ErrSessionRejected, ErrProtocolNotSupported) {
			return err
		}
		return markTerminal(err)
	}
	for _, packet := range outbound {
		err = l.writeOutbound(packet)
		if err != nil {
			if peerTerminated {
				return E.Errors(errPPPPeerTerminated, err)
			}
			return err
		}
	}
	l.lifecycleAccess.Lock()
	l.access.Lock()
	l.carrierAccess.RLock()
	carrier = l.carrier
	currentGeneration = 0
	if carrier != nil {
		currentGeneration = carrier.generation
	}
	l.carrierAccess.RUnlock()
	deliverAllowed := generation == currentGeneration && !l.closed
	if deliverAllowed && l.networkPending {
		l.phase = pppLinkPhaseNetwork
		l.networkPending = false
		l.ready.Store(true)
		l.addressesLocked = true
		l.readyWaitOnce.Do(func() {
			close(l.readyWait)
		})
	}
	l.access.Unlock()
	if deliverAllowed && delivered != nil && l.config.Deliver != nil {
		l.config.Deliver(delivered)
		delivered = nil
	}
	l.lifecycleAccess.Unlock()
	if delivered != nil {
		delivered.Release()
	}
	if peerTerminated {
		return errPPPPeerTerminated
	}
	return nil
}

func (l *pppLink) protocolRejectionLocked(protocol uint16, payload []byte) ([]pppOutboundPacket, error) {
	maximumPayload := min(len(payload)+2, max(int(l.peerMRU)-10, 2))
	rejected := make([]byte, maximumPayload)
	binary.BigEndian.PutUint16(rejected[:2], protocol)
	copy(rejected[2:], payload)
	l.lcp.nextIdentifier++
	control, err := buildPPPControlPacket(pppCodeProtocolRejection, l.lcp.nextIdentifier, rejected)
	if err != nil {
		return nil, err
	}
	return []pppOutboundPacket{l.outboundPacketLocked(pppProtocolLCP, control)}, nil
}

func (l *pppLink) handleControlPacketLocked(protocol uint16, packet []byte) ([]pppOutboundPacket, bool, error) {
	code, identifier, payload, err := parsePPPControlPacket(packet)
	if err != nil {
		return nil, false, E.Cause(err, "parse PPP control packet")
	}
	switch code {
	case pppCodeConfigureRequest:
		outbound, handleErr := l.handleConfigurationRequestLocked(protocol, identifier, payload)
		return outbound, false, handleErr
	case pppCodeConfigureAcknowledgement:
		state, stateErr := l.controlStateLocked(protocol)
		if stateErr != nil {
			return nil, false, stateErr
		}
		state.requestAcknowledged = true
		if protocol == pppProtocolLCP {
			l.outboundProtocolCompression = l.requestProtocolCompression
			l.outboundAddressCompression = l.requestAddressCompression
		}
		outbound, advanceErr := l.advanceNegotiationLocked(time.Now())
		return outbound, false, advanceErr
	case pppCodeConfigureNegativeAcknowledgement, pppCodeConfigureRejection:
		outbound, handleErr := l.handleConfigurationNakOrRejectLocked(protocol, identifier, code, payload)
		return outbound, false, handleErr
	case pppCodeTerminateRequest:
		control, buildErr := buildPPPControlPacket(pppCodeTerminateAcknowledgement, identifier, nil)
		if buildErr != nil {
			return nil, false, buildErr
		}
		l.phase = pppLinkPhaseTerminating
		return []pppOutboundPacket{l.outboundPacketLocked(protocol, control)}, true, nil
	case pppCodeTerminateAcknowledgement:
		if l.phase == pppLinkPhaseTerminating {
			l.termAcknowledgedOnce.Do(func() {
				close(l.termAcknowledged)
			})
		}
		return nil, false, nil
	case pppCodeEchoRequest:
		if protocol != pppProtocolLCP {
			return nil, false, E.New("PPP echo request arrived on a non-LCP protocol")
		}
		if !l.lcp.requestAcknowledged || !l.lcp.peerRequestAcknowledged {
			return nil, false, nil
		}
		replyPayload := make([]byte, max(4, len(payload)))
		copy(replyPayload[4:], payload[min(4, len(payload)):])
		if l.localMagicEnabled {
			copy(replyPayload[:4], l.localMagic[:])
		}
		control, buildErr := buildPPPControlPacket(pppCodeEchoReply, identifier, replyPayload)
		if buildErr != nil {
			return nil, false, buildErr
		}
		return []pppOutboundPacket{l.outboundPacketLocked(pppProtocolLCP, control)}, false, nil
	case pppCodeEchoReply:
		if protocol != pppProtocolLCP {
			return nil, false, E.New("PPP echo reply arrived on a non-LCP protocol")
		}
		if l.pendingEcho && identifier == l.pendingEchoIdentifier {
			l.pendingEcho = false
			l.missedEchoReplies = 0
		}
		return nil, false, nil
	case pppCodeDiscardRequest:
		return nil, false, nil
	case pppCodeProtocolRejection:
		if protocol != pppProtocolLCP || len(payload) < 2 {
			return nil, false, E.New("invalid PPP Protocol-Reject packet")
		}
		rejectedProtocol := binary.BigEndian.Uint16(payload[:2])
		switch rejectedProtocol {
		case pppProtocolIPCP:
			l.wantIPv4 = false
		case pppProtocolIP6CP:
			l.wantIPv6 = false
		default:
			return nil, false, nil
		}
		if !l.wantIPv4 && !l.wantIPv6 {
			return nil, false, E.Extend(ErrProtocolNotSupported, "PPP peer rejected every requested network control protocol")
		}
		outbound, advanceErr := l.advanceNegotiationLocked(time.Now())
		return outbound, false, advanceErr
	case pppCodeCodeRejection:
		return nil, false, E.Extend(ErrProtocolNotSupported, "PPP peer sent Code-Reject")
	default:
		return nil, false, E.Extend(ErrProtocolNotSupported, "PPP control code: ", code)
	}
}

func (l *pppLink) handleConfigurationRequestLocked(protocol uint16, identifier byte, payload []byte) ([]pppOutboundPacket, error) {
	state, err := l.controlStateLocked(protocol)
	if err != nil {
		return nil, err
	}
	options, err := parsePPPOptions(payload)
	if err != nil {
		return nil, err
	}
	var rejected []byte
	var negativeAcknowledgement []byte
	peerOptions := pppPeerLCPOptions{mru: pppDefaultMRU}
	peerIPv4 := netip.Addr{}
	peerIPv6 := netip.Addr{}
	for _, option := range options {
		switch protocol {
		case pppProtocolLCP:
			switch option.kind {
			case pppLCPOptionMRU:
				if len(option.value) != 2 {
					rejected = append(rejected, option.raw...)
					continue
				}
				mru := binary.BigEndian.Uint16(option.value)
				if mru < pppMinimumMRU {
					negativeAcknowledgement = appendPPPOptionUint16(negativeAcknowledgement, option.kind, pppMinimumMRU)
					continue
				}
				peerOptions.mru = mru
			case pppLCPOptionAsyncMap:
				if len(option.value) != 4 {
					rejected = append(rejected, option.raw...)
					continue
				}
			case pppLCPOptionMagic:
				if len(option.value) != 4 {
					rejected = append(rejected, option.raw...)
					continue
				}
				copy(peerOptions.magic[:], option.value)
				if l.localMagicEnabled && peerOptions.magic == l.localMagic {
					newMagic, magicErr := randomPPPMagic()
					if magicErr != nil {
						return nil, magicErr
					}
					negativeAcknowledgement = appendPPPOption(negativeAcknowledgement, option.kind, newMagic[:])
				}
			case pppLCPOptionProtocolCompression:
				if len(option.value) != 0 {
					rejected = append(rejected, option.raw...)
					continue
				}
			case pppLCPOptionAddressCompression:
				if len(option.value) != 0 {
					rejected = append(rejected, option.raw...)
					continue
				}
			case pppLCPOptionAuthentication:
				rejected = append(rejected, option.raw...)
			default:
				rejected = append(rejected, option.raw...)
			}
		case pppProtocolIPCP:
			switch option.kind {
			case pppIPCPOptionAddresses:
				if len(option.value) != 8 {
					rejected = append(rejected, option.raw...)
				}
			case pppIPCPOptionAddress:
				address, parseErr := pppIPv4FromBytes(option.value)
				if parseErr != nil {
					rejected = append(rejected, option.raw...)
				} else {
					peerIPv4 = address
				}
			case pppIPCPOptionCompression:
				rejected = append(rejected, option.raw...)
			default:
				rejected = append(rejected, option.raw...)
			}
		case pppProtocolIP6CP:
			if option.kind != pppIP6CPOptionInterfaceID {
				rejected = append(rejected, option.raw...)
				continue
			}
			address, parseErr := pppIPv6FromInterfaceID(option.value)
			if parseErr != nil {
				rejected = append(rejected, option.raw...)
			} else {
				peerIPv6 = address
			}
		}
	}
	var outbound []pppOutboundPacket
	if len(rejected) != 0 {
		control, buildErr := buildPPPControlPacket(pppCodeConfigureRejection, identifier, rejected)
		if buildErr != nil {
			return nil, buildErr
		}
		outbound = append(outbound, l.outboundPacketLocked(protocol, control))
	}
	if len(negativeAcknowledgement) != 0 {
		control, buildErr := buildPPPControlPacket(pppCodeConfigureNegativeAcknowledgement, identifier, negativeAcknowledgement)
		if buildErr != nil {
			return nil, buildErr
		}
		outbound = append(outbound, l.outboundPacketLocked(protocol, control))
	}
	if len(rejected) == 0 && len(negativeAcknowledgement) == 0 {
		control, buildErr := buildPPPControlPacket(pppCodeConfigureAcknowledgement, identifier, payload)
		if buildErr != nil {
			return nil, buildErr
		}
		outbound = append(outbound, l.outboundPacketLocked(protocol, control))
		state.peerRequestAcknowledged = true
		switch protocol {
		case pppProtocolLCP:
			l.peerMRU = peerOptions.mru
		case pppProtocolIPCP:
			l.peerIPv4 = peerIPv4
		case pppProtocolIP6CP:
			l.peerIPv6 = peerIPv6
		}
		advanced, advanceErr := l.advanceNegotiationLocked(time.Now())
		if advanceErr != nil {
			return nil, advanceErr
		}
		outbound = append(outbound, advanced...)
	}
	return outbound, nil
}

func (l *pppLink) handleConfigurationNakOrRejectLocked(protocol uint16, identifier byte, code byte, payload []byte) ([]pppOutboundPacket, error) {
	state, err := l.controlStateLocked(protocol)
	if err != nil {
		return nil, err
	}
	if identifier != state.requestIdentifier {
		return nil, nil
	}
	options, err := parsePPPOptions(payload)
	if err != nil {
		return nil, err
	}
	protocolDisabled := false
	for _, option := range options {
		switch protocol {
		case pppProtocolLCP:
			switch option.kind {
			case pppLCPOptionMRU:
				if len(option.value) != 2 {
					return nil, E.New("invalid LCP MRU Nak/Reject")
				}
				l.requestMRU = false
			case pppLCPOptionAsyncMap:
				if len(option.value) != 4 {
					return nil, E.New("invalid LCP async-map Nak/Reject")
				}
				l.localAsyncMap = pppHDLCControlEscapeMask
				l.requestAsyncMap = false
			case pppLCPOptionMagic:
				if len(option.value) != 4 {
					return nil, E.New("invalid LCP magic Nak/Reject")
				}
				if code == pppCodeConfigureRejection {
					l.localMagicEnabled = false
				}
			case pppLCPOptionProtocolCompression:
				if len(option.value) != 0 {
					return nil, E.New("invalid LCP protocol-compression Nak/Reject")
				}
				l.requestProtocolCompression = false
				l.outboundProtocolCompression = false
			case pppLCPOptionAddressCompression:
				if len(option.value) != 0 {
					return nil, E.New("invalid LCP address-compression Nak/Reject")
				}
				l.requestAddressCompression = false
				l.outboundAddressCompression = false
			default:
				return nil, E.New("PPP peer Nak/Rejected an unknown LCP option: ", option.kind)
			}
		case pppProtocolIPCP:
			switch option.kind {
			case pppIPCPOptionAddress:
				address, parseErr := pppIPv4FromBytes(option.value)
				if parseErr != nil || code == pppCodeConfigureRejection || address.IsUnspecified() {
					return nil, E.New("PPP peer rejected the IPv4 address negotiation")
				}
				if l.addressesLocked && l.localIPv4.IsValid() && address != l.localIPv4 {
					return nil, E.Extend(ErrSessionRejected, "PPP peer changed the proposed IPv4 address: ", l.localIPv4, " -> ", address)
				}
				l.localIPv4 = address
			case pppIPCPOptionPrimaryDNS, pppIPCPOptionPrimaryNBNS, pppIPCPOptionSecondaryDNS, pppIPCPOptionSecondaryNBNS:
				if code == pppCodeConfigureRejection {
					delete(l.nameServerRequests, option.kind)
					continue
				}
				address, parseErr := pppIPv4FromBytes(option.value)
				if parseErr != nil || address.IsUnspecified() {
					return nil, E.New("PPP peer returned an invalid IPv4 name server option: ", option.kind)
				}
				l.nameServerRequests[option.kind] = address
			default:
				return nil, E.New("PPP peer Nak/Rejected an unknown IPCP option: ", option.kind)
			}
		case pppProtocolIP6CP:
			if option.kind != pppIP6CPOptionInterfaceID {
				return nil, E.New("PPP peer Nak/Rejected an unknown IP6CP option: ", option.kind)
			}
			if code == pppCodeConfigureRejection {
				l.wantIPv6 = false
				protocolDisabled = true
				continue
			}
			address, parseErr := pppIPv6FromInterfaceID(option.value)
			if parseErr != nil {
				return nil, parseErr
			}
			if pppInterfaceID(address) == [8]byte{} {
				l.wantIPv6 = false
				protocolDisabled = true
				continue
			}
			if l.addressesLocked && l.localIPv6.IsValid() && pppInterfaceID(address) != pppInterfaceID(l.localIPv6) {
				return nil, E.Extend(ErrSessionRejected, "PPP peer changed the proposed IPv6 interface identifier")
			}
			if !l.localIPv6.IsValid() {
				l.localIPv6 = address
			} else {
				localBytes := l.localIPv6.As16()
				offeredBytes := address.As16()
				copy(localBytes[8:], offeredBytes[8:])
				l.localIPv6 = netip.AddrFrom16(localBytes)
			}
		}
	}
	if protocolDisabled {
		return l.advanceNegotiationLocked(time.Now())
	}
	if state.requestAttempts >= l.config.NegotiationAttempts {
		return nil, E.New("PPP control protocol negotiation attempts exhausted: ", protocol)
	}
	request, err := l.buildConfigurationRequestLocked(protocol, time.Now())
	if err != nil {
		return nil, err
	}
	return []pppOutboundPacket{request}, nil
}

func (l *pppLink) advanceNegotiationLocked(now time.Time) ([]pppOutboundPacket, error) {
	var outbound []pppOutboundPacket
	if !l.lcp.requestAcknowledged || !l.lcp.peerRequestAcknowledged {
		return nil, nil
	}
	if !l.wantIPv4 && !l.wantIPv6 {
		return nil, E.Extend(ErrProtocolNotSupported, "PPP peer rejected every requested network control protocol")
	}
	if l.wantIPv4 && !l.ipcp.requestSent {
		request, err := l.buildConfigurationRequestLocked(pppProtocolIPCP, now)
		if err != nil {
			return nil, err
		}
		outbound = append(outbound, request)
	}
	if l.wantIPv6 && !l.ip6cp.requestSent {
		request, err := l.buildConfigurationRequestLocked(pppProtocolIP6CP, now)
		if err != nil {
			return nil, err
		}
		outbound = append(outbound, request)
	}
	if l.wantIPv4 && (!l.ipcp.requestAcknowledged || !l.ipcp.peerRequestAcknowledged) {
		return outbound, nil
	}
	if l.wantIPv6 && (!l.ip6cp.requestAcknowledged || !l.ip6cp.peerRequestAcknowledged) {
		return outbound, nil
	}
	if l.wantIPv4 && (!l.localIPv4.Is4() || l.localIPv4.IsUnspecified()) {
		return nil, E.New("PPP IPv4 negotiation completed without a local address")
	}
	if l.wantIPv6 && (!l.localIPv6.Is6() || pppInterfaceID(l.localIPv6) == [8]byte{}) {
		return nil, E.New("PPP IPv6 negotiation completed without a local address")
	}
	l.networkPending = true
	configuration := TunnelConfiguration{MTU: uint32(min(int(l.localMRU), int(l.peerMRU)))}
	if l.wantIPv4 {
		prefixBits := 32
		if l.config.IPv4Address.IsValid() {
			prefixBits = l.config.IPv4Address.Bits()
		}
		configuration.Addresses = append(configuration.Addresses, netip.PrefixFrom(l.localIPv4, prefixBits))
	}
	if l.wantIPv6 {
		prefixBits := 64
		if l.config.IPv6Address.IsValid() {
			prefixBits = l.config.IPv6Address.Bits()
		}
		configuration.Addresses = append(configuration.Addresses, netip.PrefixFrom(l.localIPv6, prefixBits))
	}
	for _, kind := range []byte{pppIPCPOptionPrimaryDNS, pppIPCPOptionSecondaryDNS} {
		address, found := l.nameServerRequests[kind]
		if found && address.Is4() && !address.IsUnspecified() {
			configuration.DNS = append(configuration.DNS, address)
		}
	}
	for _, kind := range []byte{pppIPCPOptionPrimaryNBNS, pppIPCPOptionSecondaryNBNS} {
		address, found := l.nameServerRequests[kind]
		if found && address.Is4() && !address.IsUnspecified() {
			configuration.NBNS = append(configuration.NBNS, address)
		}
	}
	l.configurationAccess.Lock()
	l.configuration = configuration
	l.configurationAccess.Unlock()
	return outbound, nil
}

func (l *pppLink) timerLoop() {
	defer l.waitGroup.Done()
	period := l.config.NegotiationPeriod / 4
	if period <= 0 || period > 250*time.Millisecond {
		period = 250 * time.Millisecond
	}
	if l.config.EchoInterval > 0 && l.config.EchoInterval/4 < period {
		period = l.config.EchoInterval / 4
	}
	if period <= 0 {
		period = 10 * time.Millisecond
	}
	ticker := time.NewTicker(period)
	defer ticker.Stop()
	for {
		select {
		case <-l.ctx.Done():
			l.terminate(l.ctx.Err())
			return
		case now := <-ticker.C:
			l.carrierAccess.RLock()
			carrier := l.carrier
			generation := uint64(0)
			if carrier != nil {
				generation = carrier.generation
			}
			l.carrierAccess.RUnlock()
			outbound, err := l.handleTimer(now)
			if err != nil {
				terminated := false
				if E.IsMulti(err, errPPPPeerDead) {
					terminated = l.terminateCarrier(generation, err, pppLinkPhaseNetwork)
				} else {
					terminated = l.terminateCarrier(generation, markTerminal(err),
						pppLinkPhaseEstablishing, pppLinkPhaseNetwork)
				}
				if terminated {
					return
				}
				continue
			}
			for _, packet := range outbound {
				err = l.writeOutbound(packet)
				if err != nil {
					if E.IsMulti(err, ErrDataChannelNotReady) {
						break
					}
					if l.terminateCarrier(packet.generation, err,
						pppLinkPhaseEstablishing, pppLinkPhaseNetwork) {
						return
					}
					break
				}
			}
		}
	}
}

func (l *pppLink) handleTimer(now time.Time) ([]pppOutboundPacket, error) {
	l.access.Lock()
	defer l.access.Unlock()
	if l.closed || l.phase == pppLinkPhaseTerminating {
		return nil, nil
	}
	var outbound []pppOutboundPacket
	for _, protocol := range []uint16{pppProtocolLCP, pppProtocolIPCP, pppProtocolIP6CP} {
		if protocol == pppProtocolIPCP && !l.wantIPv4 {
			continue
		}
		if protocol == pppProtocolIP6CP && !l.wantIPv6 {
			continue
		}
		state, err := l.controlStateLocked(protocol)
		if err != nil {
			return nil, err
		}
		if !state.requestSent || state.requestAcknowledged {
			continue
		}
		lastRequest := time.Unix(0, state.lastRequestUnixNano)
		if now.Sub(lastRequest) < l.config.NegotiationPeriod {
			continue
		}
		if state.requestAttempts >= l.config.NegotiationAttempts {
			return nil, E.New("PPP control protocol negotiation timed out: ", protocol)
		}
		request, buildErr := l.buildConfigurationRequestLocked(protocol, now)
		if buildErr != nil {
			return nil, buildErr
		}
		outbound = append(outbound, request)
	}
	if l.phase != pppLinkPhaseNetwork || l.config.EchoInterval <= 0 {
		return outbound, nil
	}
	if l.pendingEcho {
		if now.Sub(l.pendingEchoSent) < l.config.EchoInterval {
			return outbound, nil
		}
		l.missedEchoReplies++
		if l.missedEchoReplies >= l.config.EchoFailures {
			return nil, errPPPPeerDead
		}
	} else if now.Sub(l.lastReceived) < l.config.EchoInterval {
		return outbound, nil
	}
	l.lcp.nextIdentifier++
	l.pendingEchoIdentifier = l.lcp.nextIdentifier
	l.pendingEcho = true
	l.pendingEchoSent = now
	payload := make([]byte, 4)
	if l.localMagicEnabled {
		copy(payload, l.localMagic[:])
	}
	control, err := buildPPPControlPacket(pppCodeEchoRequest, l.pendingEchoIdentifier, payload)
	if err != nil {
		return nil, err
	}
	outbound = append(outbound, l.outboundPacketLocked(pppProtocolLCP, control))
	return outbound, nil
}
