package openconnect

import (
	"crypto/rand"
	"encoding/binary"
	"net/netip"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	pppProtocolIPv4  = 0x0021
	pppProtocolIPv6  = 0x0057
	pppProtocolLCP   = 0xc021
	pppProtocolIPCP  = 0x8021
	pppProtocolIP6CP = 0x8057
	pppProtocolCCP   = 0x80fd
)

const (
	pppCodeConfigureRequest byte = iota + 1
	pppCodeConfigureAcknowledgement
	pppCodeConfigureNegativeAcknowledgement
	pppCodeConfigureRejection
	pppCodeTerminateRequest
	pppCodeTerminateAcknowledgement
	pppCodeCodeRejection
	pppCodeProtocolRejection
	pppCodeEchoRequest
	pppCodeEchoReply
	pppCodeDiscardRequest
)

const (
	pppLCPOptionMRU                 = 1
	pppLCPOptionAsyncMap            = 2
	pppLCPOptionAuthentication      = 3
	pppLCPOptionMagic               = 5
	pppLCPOptionProtocolCompression = 7
	pppLCPOptionAddressCompression  = 8
	pppIPCPOptionAddresses          = 1
	pppIPCPOptionCompression        = 2
	pppIPCPOptionAddress            = 3
	pppIPCPOptionPrimaryDNS         = 129
	pppIPCPOptionPrimaryNBNS        = 130
	pppIPCPOptionSecondaryDNS       = 131
	pppIPCPOptionSecondaryNBNS      = 132
	pppIP6CPOptionInterfaceID       = 1
)

const (
	pppDefaultMRU = 1500
	pppMinimumMRU = 128
)

type pppControlProtocolState struct {
	nextIdentifier          byte
	requestIdentifier       byte
	requestSent             bool
	requestAcknowledged     bool
	peerRequestAcknowledged bool
	requestAttempts         int
	lastRequestUnixNano     int64
}

type pppOption struct {
	kind  byte
	value []byte
	raw   []byte
}

type pppPeerLCPOptions struct {
	mru   uint16
	magic [4]byte
}

func parsePPPOptions(payload []byte) ([]pppOption, error) {
	var options []pppOption
	for len(payload) > 0 {
		if len(payload) < 2 {
			return nil, E.New("truncated PPP configuration option header")
		}
		optionLength := int(payload[1])
		if optionLength < 2 || optionLength > len(payload) {
			return nil, E.New("invalid PPP configuration option length: ", optionLength)
		}
		options = append(options, pppOption{
			kind:  payload[0],
			value: payload[2:optionLength],
			raw:   payload[:optionLength],
		})
		payload = payload[optionLength:]
	}
	return options, nil
}

func appendPPPOption(destination []byte, kind byte, value []byte) []byte {
	destination = append(destination, kind, byte(len(value)+2))
	return append(destination, value...)
}

func appendPPPOptionUint16(destination []byte, kind byte, value uint16) []byte {
	var encoded [2]byte
	binary.BigEndian.PutUint16(encoded[:], value)
	return appendPPPOption(destination, kind, encoded[:])
}

func appendPPPOptionUint32(destination []byte, kind byte, value uint32) []byte {
	var encoded [4]byte
	binary.BigEndian.PutUint32(encoded[:], value)
	return appendPPPOption(destination, kind, encoded[:])
}

func buildPPPControlPacket(code byte, identifier byte, payload []byte) ([]byte, error) {
	packetLength := len(payload) + 4
	if packetLength > pppMaximumPayloadLength {
		return nil, E.New("PPP control packet exceeds maximum payload length")
	}
	packet := make([]byte, packetLength)
	packet[0] = code
	packet[1] = identifier
	binary.BigEndian.PutUint16(packet[2:4], uint16(packetLength))
	copy(packet[4:], payload)
	return packet, nil
}

func parsePPPControlPacket(packet []byte) (byte, byte, []byte, error) {
	if len(packet) < 4 {
		return 0, 0, nil, E.New("PPP control packet is too short")
	}
	packetLength := int(binary.BigEndian.Uint16(packet[2:4]))
	if packetLength < 4 || packetLength > len(packet) {
		return 0, 0, nil, E.New("invalid PPP control packet length: ", packetLength)
	}
	return packet[0], packet[1], packet[4:packetLength], nil
}

func buildPPPPacketHeader(protocol uint16, protocolCompression bool, addressCompression bool) []byte {
	header := make([]byte, 0, 4)
	if protocol == pppProtocolLCP || !addressCompression {
		header = append(header, 0xff, 0x03)
	}
	if protocol <= 0xff && protocolCompression {
		header = append(header, byte(protocol))
	} else {
		header = append(header, byte(protocol>>8), byte(protocol))
	}
	return header
}

func parsePPPPacket(packet []byte) (uint16, []byte, error) {
	if len(packet) < 1 {
		return 0, nil, E.New("empty PPP packet")
	}
	position := 0
	if len(packet) >= 2 && packet[0] == 0xff && packet[1] == 0x03 {
		position = 2
	}
	if position >= len(packet) {
		return 0, nil, E.New("PPP packet is missing a protocol field")
	}
	firstProtocolByte := packet[position]
	position++
	var protocol uint16
	if firstProtocolByte&1 != 0 {
		protocol = uint16(firstProtocolByte)
	} else {
		if position >= len(packet) {
			return 0, nil, E.New("PPP packet has a truncated protocol field")
		}
		protocol = uint16(firstProtocolByte)<<8 | uint16(packet[position])
		position++
		if protocol&1 == 0 {
			return 0, nil, E.New("PPP protocol field has an invalid low bit")
		}
	}
	return protocol, packet[position:], nil
}

func randomPPPMagic() ([4]byte, error) {
	var magic [4]byte
	for magic == [4]byte{} {
		_, err := rand.Read(magic[:])
		if err != nil {
			return [4]byte{}, E.Cause(err, "generate PPP LCP magic number")
		}
	}
	return magic, nil
}

func pppIPv4FromBytes(value []byte) (netip.Addr, error) {
	if len(value) != 4 {
		return netip.Addr{}, E.New("invalid PPP IPv4 option length: ", len(value))
	}
	var address [4]byte
	copy(address[:], value)
	return netip.AddrFrom4(address), nil
}

func pppIPv6FromInterfaceID(value []byte) (netip.Addr, error) {
	if len(value) != 8 {
		return netip.Addr{}, E.New("invalid PPP IPv6 interface identifier length: ", len(value))
	}
	var address [16]byte
	address[0] = 0xfe
	address[1] = 0x80
	copy(address[8:], value)
	return netip.AddrFrom16(address), nil
}

func pppInterfaceID(address netip.Addr) [8]byte {
	var identifier [8]byte
	if !address.Is6() {
		return identifier
	}
	bytes16 := address.As16()
	copy(identifier[:], bytes16[8:])
	return identifier
}
