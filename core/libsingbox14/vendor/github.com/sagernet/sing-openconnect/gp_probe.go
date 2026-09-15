package openconnect

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"net/netip"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	gpProbeIdentifier   = 0x4747
	gpIPv4ProbeSize     = 44
	gpIPv6ProbeSize     = 64
	gpICMPHeaderSize    = 8
	gpIPv4HeaderSize    = 20
	gpIPv6HeaderSize    = 40
	gpICMPEchoRequest   = 8
	gpICMPEchoReply     = 0
	gpICMPv6EchoRequest = 128
	gpICMPv6EchoReply   = 129
)

var gpProbePayload = [16]byte{'m', 'o', 'n', 'i', 't', 'o', 'r', 0, 0, 'p', 'a', 'n', ' ', 'h', 'a', ' '}

type gpProbe struct {
	assigned netip.Addr
	magic    netip.Addr
}

func (p gpProbe) build(sequence uint16) ([]byte, error) {
	assigned := p.assigned.Unmap()
	magic := p.magic.Unmap()
	if !assigned.IsValid() || !magic.IsValid() || assigned.Is6() != magic.Is6() {
		return nil, E.New("ESP probe requires matching assigned and magic addresses")
	}
	if assigned.Is6() {
		return p.buildIPv6(sequence, assigned, magic), nil
	}
	return p.buildIPv4(sequence, assigned, magic), nil
}

func (p gpProbe) buildIPv4(sequence uint16, assigned netip.Addr, magic netip.Addr) []byte {
	packet := make([]byte, gpIPv4ProbeSize)
	packet[0] = 0x45
	binary.BigEndian.PutUint16(packet[2:], gpIPv4ProbeSize)
	binary.BigEndian.PutUint16(packet[4:], gpProbeIdentifier)
	binary.BigEndian.PutUint16(packet[6:], 0x4000)
	packet[8] = 64
	packet[9] = 1
	assignedBytes := assigned.As4()
	magicBytes := magic.As4()
	copy(packet[12:16], assignedBytes[:])
	copy(packet[16:20], magicBytes[:])
	binary.BigEndian.PutUint16(packet[10:], gpInternetChecksum(packet[:gpIPv4HeaderSize], 0))
	icmp := packet[gpIPv4HeaderSize:]
	icmp[0] = gpICMPEchoRequest
	binary.BigEndian.PutUint16(icmp[4:], gpProbeIdentifier)
	binary.BigEndian.PutUint16(icmp[6:], sequence)
	copy(icmp[gpICMPHeaderSize:], gpProbePayload[:])
	binary.BigEndian.PutUint16(icmp[2:], gpInternetChecksum(icmp, 0))
	return packet
}

func (p gpProbe) buildIPv6(sequence uint16, assigned netip.Addr, magic netip.Addr) []byte {
	packet := make([]byte, gpIPv6ProbeSize)
	packet[0] = 0x60
	binary.BigEndian.PutUint16(packet[4:], uint16(gpICMPHeaderSize+len(gpProbePayload)))
	packet[6] = 58
	packet[7] = 128
	assignedBytes := assigned.As16()
	magicBytes := magic.As16()
	copy(packet[8:24], assignedBytes[:])
	copy(packet[24:40], magicBytes[:])
	icmp := packet[gpIPv6HeaderSize:]
	icmp[0] = gpICMPv6EchoRequest
	identifier := make([]byte, 2)
	_, err := rand.Read(identifier)
	if err != nil {
		binary.BigEndian.PutUint16(identifier, gpProbeIdentifier)
	}
	copy(icmp[4:6], identifier)
	binary.BigEndian.PutUint16(icmp[6:], sequence)
	copy(icmp[gpICMPHeaderSize:], gpProbePayload[:])
	pseudoSum := gpChecksumWords(packet[8:40], 0)
	pseudoSum += uint32(len(icmp))
	pseudoSum += 58
	binary.BigEndian.PutUint16(icmp[2:], gpInternetChecksum(icmp, pseudoSum))
	return packet
}

func (p gpProbe) matches(packet []byte) bool {
	magic := p.magic.Unmap()
	if !magic.IsValid() || len(packet) == 0 {
		return false
	}
	switch packet[0] >> 4 {
	case 4:
		if !magic.Is4() || len(packet) < gpIPv4HeaderSize+1 || packet[9] != 1 {
			return false
		}
		magicBytes := magic.As4()
		if !bytes.Equal(packet[12:16], magicBytes[:]) {
			return false
		}
		headerSize := int(packet[0]&0x0f) * 4
		payloadOffset := headerSize + gpICMPHeaderSize
		return headerSize >= gpIPv4HeaderSize && len(packet) >= payloadOffset+len(gpProbePayload) &&
			packet[headerSize] == gpICMPEchoReply && bytes.Equal(packet[payloadOffset:payloadOffset+len(gpProbePayload)], gpProbePayload[:])
	case 6:
		if !magic.Is6() || len(packet) < gpIPv6HeaderSize+1 || packet[6] != 58 {
			return false
		}
		magicBytes := magic.As16()
		payloadOffset := gpIPv6HeaderSize + gpICMPHeaderSize
		return bytes.Equal(packet[8:24], magicBytes[:]) && len(packet) >= payloadOffset+len(gpProbePayload) &&
			packet[gpIPv6HeaderSize] == gpICMPv6EchoReply && bytes.Equal(packet[payloadOffset:payloadOffset+len(gpProbePayload)], gpProbePayload[:])
	default:
		return false
	}
}

func gpInternetChecksum(data []byte, initial uint32) uint16 {
	sum := gpChecksumWords(data, initial)
	for sum > 0xffff {
		sum = sum>>16 + sum&0xffff
	}
	return ^uint16(sum)
}

func gpChecksumWords(data []byte, initial uint32) uint32 {
	sum := initial
	for len(data) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(data))
		data = data[2:]
	}
	if len(data) == 1 {
		sum += uint32(data[0]) << 8
	}
	return sum
}
