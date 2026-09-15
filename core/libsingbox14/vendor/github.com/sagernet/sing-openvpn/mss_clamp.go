package openvpn

import (
	"encoding/binary"
	"math/bits"
)

const (
	ipHeaderVersionIPv4 = 4
	ipHeaderVersionIPv6 = 6
	ipv4HeaderMinLength = 20
	ipv6HeaderLength    = 40
	ipProtocolTCP       = 6

	udpHeaderLength = 8

	tcpHeaderMinLength = 20
	tcpChecksumOffset  = 16
	tcpFlagSYN         = 0x02
	tcpOptionKindEnd   = 0
	tcpOptionKindNOP   = 1
	tcpOptionKindMSS   = 2
	tcpMSSOptionLength = 4
)

// Upstream gates mss_fixup on the --mssfix option value rather than on the computed frame.mss_fix,
// and casts that signed budget to uint16_t in mss_fixup_ipv4; mss_fixup_ipv6 casts maxmss-20 the
// same way, so the cap is always expressed as an IPv4 MSS.
type mssClamp struct {
	enabled            bool
	maximumSegmentSize uint16
}

func (c mssClamp) Apply(packet []byte) []byte {
	if !c.enabled {
		return packet
	}
	clonedPacket := append([]byte{}, packet...)
	if !c.ApplyInPlace(clonedPacket) {
		return packet
	}
	return clonedPacket
}

func (c mssClamp) ApplyInPlace(packet []byte) bool {
	if !c.enabled {
		return false
	}
	effectiveMaxSegmentSize := c.maximumSegmentSize
	if len(packet) >= 1 && packet[0]>>4 == ipHeaderVersionIPv6 {
		effectiveMaxSegmentSize -= ipv6HeaderLength - ipv4HeaderMinLength
	}
	tcpSegment := locateTCPSYNSegment(packet)
	if tcpSegment == nil {
		return false
	}
	return clampTCPSYNSegmentMSS(tcpSegment, effectiveMaxSegmentSize)
}

func locateTCPSYNSegment(packet []byte) []byte {
	if len(packet) < 1 {
		return nil
	}
	var ipHeaderLength int
	switch packet[0] >> 4 {
	case ipHeaderVersionIPv4:
		if len(packet) < ipv4HeaderMinLength {
			return nil
		}
		if int(binary.BigEndian.Uint16(packet[2:4])) != len(packet) || binary.BigEndian.Uint16(packet[6:8])&0x3fff != 0 {
			return nil
		}
		ihl := int(packet[0]&0x0f) * 4
		if ihl < ipv4HeaderMinLength || ihl > len(packet) {
			return nil
		}
		if packet[9] != ipProtocolTCP {
			return nil
		}
		ipHeaderLength = ihl
	case ipHeaderVersionIPv6:
		if len(packet) < ipv6HeaderLength {
			return nil
		}
		if int(binary.BigEndian.Uint16(packet[4:6]))+ipv6HeaderLength != len(packet) {
			return nil
		}
		if packet[6] != ipProtocolTCP {
			return nil
		}
		ipHeaderLength = ipv6HeaderLength
	default:
		return nil
	}
	tcpSegment := packet[ipHeaderLength:]
	if len(tcpSegment) < tcpHeaderMinLength {
		return nil
	}
	if tcpSegment[13]&tcpFlagSYN == 0 {
		return nil
	}
	return tcpSegment
}

func clampTCPSYNSegmentMSS(tcpSegment []byte, maxSegmentSize uint16) bool {
	dataOffset := int(tcpSegment[12]>>4) * 4
	if dataOffset < tcpHeaderMinLength || dataOffset > len(tcpSegment) {
		return false
	}
	clamped := false
	optionOffset := tcpHeaderMinLength
	for optionOffset < dataOffset {
		kind := tcpSegment[optionOffset]
		if kind == tcpOptionKindEnd {
			break
		}
		if kind == tcpOptionKindNOP {
			optionOffset++
			continue
		}
		if optionOffset+1 >= dataOffset {
			break
		}
		optionLength := int(tcpSegment[optionOffset+1])
		if optionLength < 2 || optionOffset+optionLength > dataOffset {
			break
		}
		if kind != tcpOptionKindMSS || optionLength != tcpMSSOptionLength {
			optionOffset += optionLength
			continue
		}
		valueOffset := optionOffset + 2
		advertisedMSS := binary.BigEndian.Uint16(tcpSegment[valueOffset : valueOffset+2])
		if advertisedMSS > maxSegmentSize {
			binary.BigEndian.PutUint16(tcpSegment[valueOffset:valueOffset+2], maxSegmentSize)
			updateTCPChecksumForFieldRewrite(tcpSegment, valueOffset, advertisedMSS, maxSegmentSize)
			clamped = true
		}
		optionOffset += optionLength
	}
	return clamped
}

func updateTCPChecksumForFieldRewrite(tcpSegment []byte, fieldOffset int, previousValue uint16, updatedValue uint16) {
	if fieldOffset%2 != 0 {
		previousValue = bits.ReverseBytes16(previousValue)
		updatedValue = bits.ReverseBytes16(updatedValue)
	}
	currentChecksum := binary.BigEndian.Uint16(tcpSegment[tcpChecksumOffset : tcpChecksumOffset+2])
	updatedChecksum := incrementallyUpdateChecksum16(currentChecksum, previousValue, updatedValue)
	binary.BigEndian.PutUint16(tcpSegment[tcpChecksumOffset:tcpChecksumOffset+2], updatedChecksum)
}

func incrementallyUpdateChecksum16(currentChecksum uint16, oldWord uint16, newWord uint16) uint16 {
	sum := uint32(^currentChecksum) + uint32(^oldWord) + uint32(newWord)
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return ^uint16(sum)
}
