package openconnect

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"math/bits"
	"net"
	"net/netip"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
)

const pulseDefaultESPAttemptPeriod = 60 * time.Second

type pulseTunnelConfiguration struct {
	configuration TunnelConfiguration
	assignedIPv4  netip.Addr
	assignedIPv6  netip.Addr
	esp           *pulseESPConfiguration
}

type pulseESPConfiguration struct {
	remote           M.Socksaddr
	keyConfiguration espKeySetConfig
	encryption       espEncryption
	authentication   espAuthentication
	port             uint16
	fallback         time.Duration
	crossFamily      bool
	replayProtection bool
	probeNextHeader  byte
}

type pulseConfigurationAccumulator struct {
	configuration     TunnelConfiguration
	assignedIPv4      netip.Addr
	assignedIPv6      netip.Addr
	ipv4Netmask       netip.Addr
	espEncryption     espEncryption
	espAuthentication espAuthentication
	espPort           uint16
	espFallback       time.Duration
	espCrossFamily    bool
	espReplay         bool
	mainSeen          bool
}

func readPulseConfiguration(
	ctx context.Context,
	client *Client,
	connection *pulseIFTConnection,
	acceptedAddress netip.Addr,
	authenticationExpires time.Time,
	idleTimeout time.Duration,
) (*pulseTunnelConfiguration, error) {
	accumulator := pulseConfigurationAccumulator{}
	accumulator.configuration.AuthenticationExpiration = authenticationExpires
	accumulator.configuration.IdleTimeout = idleTimeout
	var espConfiguration *pulseESPConfiguration
	for {
		frame, err := connection.readFrame(pulseConfigurationFrameLimit)
		if err != nil {
			destroyPulseESPConfiguration(espConfiguration)
			return nil, err
		}
		if frame.vendor != pulseVendorJuniper {
			if client.options.Logger != nil {
				client.options.Logger.DebugContext(ctx, "Ignoring Pulse configuration frame from unknown vendor: ", frame.vendor)
			}
			continue
		}
		if frame.frameType == 0x8f {
			break
		}
		if frame.frameType != 1 || len(frame.payload) < 28 {
			if client.options.Logger != nil {
				client.options.Logger.DebugContext(ctx, "Ignoring unknown Pulse configuration frame type: ", frame.frameType)
			}
			continue
		}
		if !pulseConfigurationEnvelopeValid(frame.payload) {
			destroyPulseESPConfiguration(espConfiguration)
			return nil, markTerminal(E.New("invalid Pulse configuration envelope"))
		}
		identifier := binary.BigEndian.Uint32(frame.payload[16:20])
		switch identifier {
		case 0x2c20f000, 0x2e20f000:
			err = parsePulseMainConfiguration(ctx, client, frame.payload, &accumulator)
			if err != nil {
				destroyPulseESPConfiguration(espConfiguration)
				return nil, markTerminal(E.Cause(err, "parse Pulse main configuration"))
			}
		case 0x21202400:
			if client.options.NoUDP {
				continue
			}
			newESP, responsePayload, parseErr := parsePulseESPConfiguration(frame.payload, accumulator, acceptedAddress)
			if parseErr != nil {
				if client.options.Logger != nil {
					client.options.Logger.WarnContext(ctx, "Ignoring unusable Pulse ESP configuration; using IF-T/TLS: ", parseErr)
				}
				continue
			}
			err = connection.writeFrame(pulseVendorJuniper, 1, responsePayload)
			clear(responsePayload)
			if err == nil {
				err = connection.writeFrame(pulseVendorJuniper, 5, []byte{'n', 'c', 'm', 'o', '=', '1', '\n', 0})
			}
			if err != nil {
				destroyPulseESPConfiguration(newESP)
				destroyPulseESPConfiguration(espConfiguration)
				return nil, E.Cause(err, "send Pulse ESP configuration response")
			}
			destroyPulseESPConfiguration(espConfiguration)
			espConfiguration = newESP
		default:
			if client.options.Logger != nil {
				client.options.Logger.DebugContext(ctx, "Ignoring unknown Pulse configuration identifier: ", identifier)
			}
		}
	}
	if !accumulator.mainSeen || accumulator.configuration.MTU == 0 || (!accumulator.assignedIPv4.IsValid() && !accumulator.assignedIPv6.IsValid()) {
		destroyPulseESPConfiguration(espConfiguration)
		return nil, markTerminal(E.New("server returned insufficient tunnel configuration"))
	}
	if client.options.IPv6Disabled {
		accumulator.assignedIPv6 = netip.Addr{}
		if !accumulator.assignedIPv4.IsValid() {
			destroyPulseESPConfiguration(espConfiguration)
			return nil, markTerminal(E.New("server did not provide an IPv4 tunnel address"))
		}
	}
	minimumMTU := uint32(576)
	if accumulator.assignedIPv6.IsValid() {
		minimumMTU = 1280
	}
	if accumulator.configuration.MTU < minimumMTU || accumulator.configuration.MTU > 65535 {
		destroyPulseESPConfiguration(espConfiguration)
		return nil, markTerminal(E.New("invalid Pulse tunnel MTU: ", accumulator.configuration.MTU))
	}
	if accumulator.assignedIPv4.IsValid() {
		if !accumulator.ipv4Netmask.IsValid() {
			destroyPulseESPConfiguration(espConfiguration)
			return nil, markTerminal(E.New("IPv4 configuration omitted its netmask"))
		}
		prefix, err := pulseIPv4AddressPrefix(accumulator.assignedIPv4, accumulator.ipv4Netmask)
		if err != nil {
			destroyPulseESPConfiguration(espConfiguration)
			return nil, markTerminal(err)
		}
		accumulator.configuration.Addresses = append(accumulator.configuration.Addresses, prefix)
	}
	accumulator.configuration.RemoteAddress = acceptedAddress.Unmap()
	accumulator.configuration = normalizeTunnelConfiguration(
		accumulator.configuration,
		client.options.IPv6Disabled,
	)
	return &pulseTunnelConfiguration{
		configuration: accumulator.configuration,
		assignedIPv4:  accumulator.assignedIPv4,
		assignedIPv6:  accumulator.assignedIPv6,
		esp:           espConfiguration,
	}, nil
}

func pulseConfigurationEnvelopeValid(payload []byte) bool {
	if len(payload) < 28 || binary.BigEndian.Uint32(payload[24:28]) != uint32(len(payload)) {
		return false
	}
	for offset := 0; offset < 16; offset += 4 {
		if binary.BigEndian.Uint32(payload[offset:offset+4]) != 0 {
			return false
		}
	}
	return binary.BigEndian.Uint32(payload[20:24]) == 0
}

func parsePulseMainConfiguration(
	ctx context.Context,
	client *Client,
	payload []byte,
	accumulator *pulseConfigurationAccumulator,
) error {
	identifier := binary.BigEndian.Uint32(payload[16:20])
	section := payload[28:]
	offset := 0
	if identifier == 0x2e20f000 {
		for {
			if len(section)-offset < 8 {
				return E.New("leading configuration attributes are truncated")
			}
			attributeFlag := binary.BigEndian.Uint16(section[offset : offset+2])
			attributeLength := int(binary.BigEndian.Uint16(section[offset+2 : offset+4]))
			if attributeLength < 8 || attributeLength > len(section)-offset {
				return E.New("invalid Pulse leading attribute block length: ", attributeLength)
			}
			err := parsePulseAttributeBlock(ctx, client, section[offset:offset+attributeLength], accumulator)
			if err != nil {
				return err
			}
			offset += attributeLength
			if attributeFlag == 0x2c00 {
				break
			}
		}
	}
	if len(section)-offset < 8 || binary.BigEndian.Uint16(section[offset:offset+2]) != 0x2e00 {
		return E.New("configuration omitted its routing block")
	}
	routingLength := int(binary.BigEndian.Uint16(section[offset+2 : offset+4]))
	routeCount := int(section[offset+4])
	if routingLength != routeCount*16+8 || routingLength > len(section)-offset-4 {
		return E.New("invalid Pulse routing block length: ", routingLength)
	}
	routeContent := section[offset+8 : offset+routingLength]
	for len(routeContent) > 0 {
		err := parsePulseIPv4Route(routeContent[:16], accumulator)
		if err != nil {
			return err
		}
		routeContent = routeContent[16:]
	}
	offset += routingLength
	if len(section)-offset < 8 {
		return E.New("final configuration attributes are truncated")
	}
	attributeLength := int(binary.BigEndian.Uint32(section[offset : offset+4]))
	if attributeLength != len(section)-offset {
		return E.New("final attribute block length mismatch")
	}
	err := parsePulseAttributeBlock(ctx, client, section[offset:], accumulator)
	if err != nil {
		return err
	}
	accumulator.mainSeen = true
	return nil
}

func parsePulseAttributeBlock(
	ctx context.Context,
	client *Client,
	content []byte,
	accumulator *pulseConfigurationAccumulator,
) error {
	if len(content) < 8 || binary.BigEndian.Uint32(content[4:8]) != 0x03000000 {
		return E.New("invalid Pulse attribute block header")
	}
	content = content[8:]
	for len(content) > 0 {
		if len(content) < 4 {
			return E.New("attribute stream ended inside a header")
		}
		attributeType := binary.BigEndian.Uint16(content[0:2])
		attributeLength := int(binary.BigEndian.Uint16(content[2:4]))
		if attributeLength > len(content)-4 {
			return E.New("attribute exceeds its containing block")
		}
		err := applyPulseAttribute(ctx, client, accumulator, attributeType, content[4:4+attributeLength])
		if err != nil {
			return err
		}
		content = content[4+attributeLength:]
	}
	return nil
}

func applyPulseAttribute(
	ctx context.Context,
	client *Client,
	accumulator *pulseConfigurationAccumulator,
	attributeType uint16,
	content []byte,
) error {
	switch attributeType {
	case 0x0001:
		address, err := pulseIPv4Attribute(content, "assigned IPv4 address")
		if err != nil {
			return err
		}
		if address.IsUnspecified() || address.IsMulticast() {
			return E.New("assigned IPv4 address is unusable")
		}
		accumulator.assignedIPv4 = address
	case 0x0002:
		address, err := pulseIPv4Attribute(content, "IPv4 netmask")
		if err != nil {
			return err
		}
		accumulator.ipv4Netmask = address
	case 0x0003:
		address, err := pulseIPv4Attribute(content, "DNS server")
		if err != nil {
			return err
		}
		if address.IsUnspecified() {
			return E.New("IPv4 DNS server is unspecified")
		}
		if len(accumulator.configuration.DNS) < 3 {
			accumulator.configuration.DNS = append(accumulator.configuration.DNS, address)
		}
	case 0x0004:
		address, err := pulseIPv4Attribute(content, "NBNS server")
		if err != nil {
			return err
		}
		if address.IsUnspecified() {
			return E.New("IPv4 NBNS server is unspecified")
		}
		if len(accumulator.configuration.NBNS) < 3 {
			accumulator.configuration.NBNS = append(accumulator.configuration.NBNS, address)
		}
	case 0x0008:
		if client.options.IPv6Disabled {
			return nil
		}
		if len(content) != 17 || content[16] > 128 {
			return E.New("IPv6 address attribute has invalid length or prefix")
		}
		address := netip.AddrFrom16([16]byte(content[:16]))
		if address.Is4In6() || address.IsUnspecified() || address.IsMulticast() {
			return E.New("assigned IPv6 address is unusable")
		}
		accumulator.assignedIPv6 = address
		accumulator.configuration.Addresses = append(accumulator.configuration.Addresses, netip.PrefixFrom(address, int(content[16])))
	case 0x000a:
		if client.options.IPv6Disabled {
			return nil
		}
		if len(content) != 16 {
			return E.New("IPv6 DNS attribute has invalid length")
		}
		address := netip.AddrFrom16([16]byte(content))
		if address.Is4In6() || address.IsUnspecified() {
			return E.New("IPv6 DNS server is unusable")
		}
		if len(accumulator.configuration.DNS) < 3 {
			accumulator.configuration.DNS = append(accumulator.configuration.DNS, address)
		}
	case 0x000f, 0x0010:
		if client.options.IPv6Disabled {
			return nil
		}
		if len(content) != 17 || content[16] > 128 {
			return E.New("IPv6 route attribute has invalid length or prefix")
		}
		address := netip.AddrFrom16([16]byte(content[:16]))
		if address.Is4In6() {
			return E.New("IPv6 route contains an IPv4-mapped address")
		}
		prefix := netip.PrefixFrom(address, int(content[16])).Masked()
		route := TunnelRoute{Prefix: prefix}
		if attributeType == 0x000f {
			accumulator.configuration.Routes = append(accumulator.configuration.Routes, route)
		} else {
			accumulator.configuration.ExcludedRoutes = append(accumulator.configuration.ExcludedRoutes, route)
		}
	case 0x4005:
		if len(content) != 4 {
			return E.New("MTU attribute has invalid length")
		}
		accumulator.configuration.MTU = binary.BigEndian.Uint32(content)
	case 0x4006:
		if len(content) == 0 {
			return E.New("search domain attribute is empty")
		}
		if content[len(content)-1] == 0 {
			content = content[:len(content)-1]
		}
		if len(content) > 0 {
			accumulator.configuration.SearchDomains = append(accumulator.configuration.SearchDomains, string(content))
		}
	case 0x4010:
		if len(content) != 2 {
			return E.New("ESP encryption attribute has invalid length")
		}
		switch binary.BigEndian.Uint16(content) {
		case 2:
			accumulator.espEncryption = espEncryptionAES128CBC
		case 5:
			accumulator.espEncryption = espEncryptionAES256CBC
		default:
			accumulator.espEncryption = 0
		}
	case 0x4011:
		if len(content) != 2 {
			return E.New("ESP authentication attribute has invalid length")
		}
		switch binary.BigEndian.Uint16(content) {
		case 1:
			accumulator.espAuthentication = espAuthenticationHMACMD596
		case 2:
			accumulator.espAuthentication = espAuthenticationHMACSHA196
		case 3:
			accumulator.espAuthentication = espAuthenticationHMACSHA256128
		default:
			accumulator.espAuthentication = 0
		}
	case 0x4012, 0x4013:
		if len(content) != 4 {
			return E.New("ESP lifetime attribute has invalid length")
		}
	case 0x4014:
		if len(content) != 4 {
			return E.New("ESP replay attribute has invalid length")
		}
		accumulator.espReplay = binary.BigEndian.Uint32(content) != 0
	case 0x4016:
		if len(content) != 2 {
			return E.New("ESP port attribute has invalid length")
		}
		accumulator.espPort = binary.BigEndian.Uint16(content)
	case 0x4017:
		if len(content) != 4 {
			return E.New("ESP fallback attribute has invalid length")
		}
		accumulator.espFallback = time.Duration(binary.BigEndian.Uint32(content)) * time.Second
	case 0x401a, 0x4024:
		if len(content) != 1 {
			return E.New("ESP flag attribute has invalid length")
		}
		if attributeType == 0x4024 {
			accumulator.espCrossFamily = content[0] != 0
		}
	case 0x4009, 0x4023, 0x400b, 0x401e:
	default:
		if client.options.Logger != nil {
			client.options.Logger.DebugContext(ctx, "Ignoring unknown Pulse configuration attribute: ", attributeType)
		}
	}
	return nil
}

func parsePulseIPv4Route(content []byte, accumulator *pulseConfigurationAccumulator) error {
	if len(content) != 16 || binary.BigEndian.Uint32(content[4:8]) != 0x0000ffff {
		return E.New("invalid Pulse IPv4 route entry")
	}
	start := binary.BigEndian.Uint32(content[8:12])
	end := binary.BigEndian.Uint32(content[12:16])
	hostMask := start ^ end
	mask := ^hostMask
	prefixBits := bits.OnesCount32(mask)
	var expectedMask uint32
	if prefixBits > 0 {
		expectedMask = ^uint32(0) << (32 - prefixBits)
	}
	if mask != expectedMask || start&mask != start || start|hostMask != end {
		return E.New("IPv4 route range is not a CIDR prefix")
	}
	var addressBytes [4]byte
	binary.BigEndian.PutUint32(addressBytes[:], start)
	route := TunnelRoute{Prefix: netip.PrefixFrom(netip.AddrFrom4(addressBytes), prefixBits)}
	switch binary.BigEndian.Uint32(content[0:4]) {
	case 0x07000010:
		accumulator.configuration.Routes = append(accumulator.configuration.Routes, route)
	case 0xf1000010:
		accumulator.configuration.ExcludedRoutes = append(accumulator.configuration.ExcludedRoutes, route)
	default:
		return E.New("unknown Pulse IPv4 route type")
	}
	return nil
}

func pulseIPv4Attribute(content []byte, description string) (netip.Addr, error) {
	if len(content) != 4 {
		return netip.Addr{}, E.New(description, " attribute has invalid length")
	}
	return netip.AddrFrom4([4]byte(content)), nil
}

func pulseIPv4AddressPrefix(address netip.Addr, netmask netip.Addr) (netip.Prefix, error) {
	addressBytes := address.As4()
	maskBytes := netmask.As4()
	prefixBits, bitLength := net.IPMask(maskBytes[:]).Size()
	if bitLength != 32 {
		return netip.Prefix{}, E.New("IPv4 netmask is not contiguous")
	}
	return netip.PrefixFrom(netip.AddrFrom4(addressBytes), prefixBits), nil
}

func parsePulseESPConfiguration(
	payload []byte,
	accumulator pulseConfigurationAccumulator,
	acceptedAddress netip.Addr,
) (*pulseESPConfiguration, []byte, error) {
	if !pulseESPConfigurationFrameValid(payload) {
		return nil, nil, E.New("invalid Pulse ESP configuration frame")
	}
	if len(payload) < 42+64 || accumulator.espEncryption.keyLength() == 0 || accumulator.espAuthentication.keyLength() == 0 || accumulator.espPort == 0 {
		return nil, nil, E.New("ESP configuration omitted usable algorithms, keys, or port")
	}
	encryptionKeyLength := accumulator.espEncryption.keyLength()
	authenticationKeyLength := accumulator.espAuthentication.keyLength()
	if encryptionKeyLength+authenticationKeyLength > 64 {
		return nil, nil, E.New("ESP key lengths exceed the 64-byte secret block")
	}
	serverSPI := binary.LittleEndian.Uint32(payload[36:40])
	serverEncryptionKey := append([]byte(nil), payload[42:42+encryptionKeyLength]...)
	serverAuthenticationKey := append([]byte(nil), payload[42+encryptionKeyLength:42+encryptionKeyLength+authenticationKeyLength]...)
	clientEncryptionKey := make([]byte, encryptionKeyLength)
	clientAuthenticationKey := make([]byte, authenticationKeyLength)
	defer clear(serverEncryptionKey)
	defer clear(serverAuthenticationKey)
	defer clear(clientEncryptionKey)
	defer clear(clientAuthenticationKey)
	_, err := rand.Read(clientEncryptionKey)
	if err == nil {
		_, err = rand.Read(clientAuthenticationKey)
	}
	var clientSPIBytes [4]byte
	for err == nil && binary.BigEndian.Uint32(clientSPIBytes[:]) == 0 {
		_, err = rand.Read(clientSPIBytes[:])
	}
	if err != nil {
		return nil, nil, E.Cause(err, "generate Pulse ESP client keys")
	}
	clientSPI := binary.BigEndian.Uint32(clientSPIBytes[:])
	keyConfiguration := espKeySetConfig{
		Encryption:              accumulator.espEncryption,
		Authentication:          accumulator.espAuthentication,
		DisableReplayProtection: !accumulator.espReplay,
		Outbound: espKeyMaterial{
			SPI:               serverSPI,
			EncryptionKey:     serverEncryptionKey,
			AuthenticationKey: serverAuthenticationKey,
		},
		Inbound: espKeyMaterial{
			SPI:               clientSPI,
			EncryptionKey:     clientEncryptionKey,
			AuthenticationKey: clientAuthenticationKey,
		},
	}
	keys, err := newESPKeySet(keyConfiguration)
	if err != nil {
		return nil, nil, err
	}
	keys.destroy()
	response := make([]byte, 0x34+2*(64+6))
	binary.BigEndian.PutUint32(response[0x20:0x24], 0x21202400)
	binary.BigEndian.PutUint32(response[0x28:0x2c], uint32(len(response)-0x10))
	binary.BigEndian.PutUint32(response[0x2c:0x30], uint32(len(response)-0x2c))
	binary.BigEndian.PutUint32(response[0x30:0x34], 0x01000000)
	binary.LittleEndian.PutUint32(response[0x34:0x38], clientSPI)
	binary.BigEndian.PutUint16(response[0x38:0x3a], 64)
	copy(response[0x3a:0x3a+encryptionKeyLength], clientEncryptionKey)
	copy(response[0x3a+encryptionKeyLength:0x3a+encryptionKeyLength+authenticationKeyLength], clientAuthenticationKey)
	copy(response[0x3a+64:], payload[0x24:0x24+70])
	fallback := accumulator.espFallback
	if fallback <= 0 {
		fallback = pulseDefaultESPAttemptPeriod
	}
	probeNextHeader := byte(espIPv4NextHeader)
	if acceptedAddress.Is6() {
		probeNextHeader = espIPv6NextHeader
	}
	configuration := &pulseESPConfiguration{
		remote: M.ParseSocksaddrHostPort(acceptedAddress.String(), accumulator.espPort),
		keyConfiguration: espKeySetConfig{
			Encryption:              keyConfiguration.Encryption,
			Authentication:          keyConfiguration.Authentication,
			DisableReplayProtection: keyConfiguration.DisableReplayProtection,
			Outbound: espKeyMaterial{
				SPI:               keyConfiguration.Outbound.SPI,
				EncryptionKey:     append([]byte(nil), keyConfiguration.Outbound.EncryptionKey...),
				AuthenticationKey: append([]byte(nil), keyConfiguration.Outbound.AuthenticationKey...),
			},
			Inbound: espKeyMaterial{
				SPI:               keyConfiguration.Inbound.SPI,
				EncryptionKey:     append([]byte(nil), keyConfiguration.Inbound.EncryptionKey...),
				AuthenticationKey: append([]byte(nil), keyConfiguration.Inbound.AuthenticationKey...),
			},
		},
		encryption:       accumulator.espEncryption,
		authentication:   accumulator.espAuthentication,
		port:             accumulator.espPort,
		fallback:         fallback,
		crossFamily:      accumulator.espCrossFamily,
		replayProtection: accumulator.espReplay,
		probeNextHeader:  probeNextHeader,
	}
	return configuration, append([]byte(nil), response[16:]...), nil
}

func pulseESPConfigurationFrameValid(payload []byte) bool {
	return len(payload) >= 106 && pulseConfigurationEnvelopeValid(payload) &&
		binary.BigEndian.Uint32(payload[16:20]) == 0x21202400 &&
		binary.BigEndian.Uint32(payload[28:32]) == uint32(len(payload)-28) &&
		binary.BigEndian.Uint32(payload[32:36]) == 0x01000000 &&
		binary.BigEndian.Uint16(payload[40:42]) == 64
}

func destroyPulseESPConfiguration(configuration *pulseESPConfiguration) {
	if configuration == nil {
		return
	}
	clear(configuration.keyConfiguration.Outbound.EncryptionKey)
	clear(configuration.keyConfiguration.Outbound.AuthenticationKey)
	clear(configuration.keyConfiguration.Inbound.EncryptionKey)
	clear(configuration.keyConfiguration.Inbound.AuthenticationKey)
	configuration.keyConfiguration = espKeySetConfig{}
}

func pulsePacketVersion(payload []byte) byte {
	if len(payload) == 0 {
		return 0
	}
	return payload[0] >> 4
}
