package openvpn

import (
	"net"
	"strings"

	M "github.com/sagernet/sing/common/metadata"
)

func calculateMSSClamp(mssFix uint32, mssFixMode string, dataFraming *dataChannelFraming, codec dataCodec, packetHeaderSize int, outerTransportOverhead int) mssClamp {
	if mssFix == 0 {
		return mssClamp{}
	}
	if mssFixMode == MSSFixModeFixed {
		return mssClamp{enabled: true, maximumSegmentSize: uint16(mssFix - ipv4HeaderMinLength - tcpHeaderMinLength)}
	}
	if mssFixMode == MSSFixModeMTU {
		packetHeaderSize += outerTransportOverhead
	}
	payloadBudget := calculateDataPayloadBudget(
		int(mssFix),
		codec,
		packetHeaderSize,
		ipv4HeaderMinLength+tcpHeaderMinLength+dataFraming.payloadOverhead(),
	)
	return mssClamp{enabled: true, maximumSegmentSize: uint16(payloadBudget)}
}

func openVPNOuterTransportOverhead(protocol string, remoteAddress net.Addr) int {
	ipHeaderSize := ipv4HeaderMinLength
	remoteIP := M.SocksaddrFromNet(remoteAddress).Addr.Unmap()
	if remoteIP.Is6() || (!remoteIP.IsValid() && strings.HasSuffix(protocol, "6")) {
		ipHeaderSize = ipv6HeaderLength
	}
	if strings.HasPrefix(protocol, "tcp") {
		return ipHeaderSize + tcpHeaderMinLength
	}
	return ipHeaderSize + udpHeaderLength
}
