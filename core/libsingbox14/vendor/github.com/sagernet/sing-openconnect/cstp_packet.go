package openconnect

import (
	"bytes"
	"encoding/binary"
	"io"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	cstpPacketData         byte = 0
	cstpPacketDPDRequest   byte = 3
	cstpPacketDPDResponse  byte = 4
	cstpPacketDisconnect   byte = 5
	cstpPacketKeepalive    byte = 7
	cstpPacketCompressed   byte = 8
	cstpPacketTerminate    byte = 9
	cstpHeaderSize              = 8
	cstpMaximumPayloadSize      = 65535
)

var cstpPacketMagic = [4]byte{'S', 'T', 'F', 1}

// Upstream cstp.c defines CSTP records as STF\x01, a big-endian payload length, packet type, zero reserved byte, and payload.
func writeCSTPPacket(w io.Writer, packetType byte, payload []byte) error {
	packetBuffer := newPacketBufferFrom(payload)
	defer packetBuffer.Release()
	return writeCSTPPacketBuffer(w, packetType, &packetBuffer)
}

func writeCSTPPacketBuffer(w io.Writer, packetType byte, packetBuffer **buf.Buffer) error {
	payloadSize := (*packetBuffer).Len()
	if payloadSize > cstpMaximumPayloadSize {
		return E.New("CSTP payload exceeds 65535 bytes: ", payloadSize)
	}
	*packetBuffer = requirePacketBufferCapacity(*packetBuffer, cstpHeaderSize, 0)
	header := (*packetBuffer).ExtendHeader(cstpHeaderSize)
	copy(header, cstpPacketMagic[:])
	binary.BigEndian.PutUint16(header[4:6], uint16(payloadSize))
	header[6] = packetType
	header[7] = 0
	packet := (*packetBuffer).Bytes()
	written := 0
	for written < len(packet) {
		n, err := w.Write(packet[written:])
		if err != nil {
			return E.Cause(err, "write CSTP packet")
		}
		if n <= 0 {
			return E.New("short CSTP packet write: wrote ", written, " of ", len(packet), " bytes")
		}
		written += n
	}
	return nil
}

// Upstream cstp_mainloop rejects malformed magic, a nonzero reserved byte, and records whose TLS read length differs from the advertised payload length.
func readCSTPPacket(r io.Reader, maximumPayloadSize int) (byte, *buf.Buffer, error) {
	header := make([]byte, cstpHeaderSize)
	_, err := io.ReadFull(r, header)
	if err != nil {
		return 0, nil, E.Cause(err, "read CSTP packet header")
	}
	if !bytes.Equal(header[:4], cstpPacketMagic[:]) || header[7] != 0 {
		return 0, nil, E.Extend(ErrProtocolNotSupported, "invalid CSTP packet header")
	}
	payloadSize := int(binary.BigEndian.Uint16(header[4:6]))
	if maximumPayloadSize > 0 && payloadSize > maximumPayloadSize {
		return 0, nil, E.Extend(ErrProtocolNotSupported, "CSTP payload exceeds receive limit: ", payloadSize)
	}
	packetBuffer := newPacketBuffer(payloadSize)
	_, err = packetBuffer.ReadFullFrom(r, payloadSize)
	if err != nil {
		packetBuffer.Release()
		return 0, nil, E.Cause(err, "read CSTP packet payload")
	}
	return header[6], packetBuffer, nil
}

// Upstream cstp_bye prefixes the printable reason with the Cisco 0xb0 disconnect reason byte.
func writeCSTPDisconnect(w io.Writer, reason string) error {
	payload := append([]byte{0xb0}, []byte(reason)...)
	return writeCSTPPacket(w, cstpPacketDisconnect, payload)
}
