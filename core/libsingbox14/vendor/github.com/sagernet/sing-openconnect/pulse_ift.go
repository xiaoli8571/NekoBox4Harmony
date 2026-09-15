package openconnect

import (
	"bufio"
	"encoding/binary"
	"io"
	"net"
	"sync"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	pulseVendorTCG      = 0x5597
	pulseVendorJuniper  = 0x0a4c
	pulseVendorJuniper2 = 0x0583

	pulseIFTVersionRequest        = 1
	pulseIFTVersionResponse       = 2
	pulseIFTClientAuthChallenge   = 5
	pulseIFTClientAuthResponse    = 6
	pulseIFTClientAuthSuccess     = 7
	pulseIFTAuthenticationJuniper = pulseVendorJuniper<<8 | 1

	pulseEAPRequest  = 1
	pulseEAPResponse = 2
	pulseEAPSuccess  = 3
	pulseEAPFailure  = 4

	pulseEAPTypeIdentity = 1
	pulseEAPTypeGTC      = 6
	pulseEAPTypeTLS      = 0x0d
	pulseEAPTypeTTLS     = 0x15
	pulseEAPTypeExpanded = 0xfe

	pulseEAPExpandedJuniper = pulseEAPTypeExpanded<<24 | pulseVendorJuniper
	pulseAVPEAPMessage      = 79

	pulseAVPFlagVendor    = 0x80
	pulseAVPFlagMandatory = 0x40

	pulseIFTHeaderSize             = 16
	pulseAuthenticationFrameLimit  = 16 * 1024
	pulseConfigurationFrameLimit   = 1024 * 1024
	pulseMaximumAuthenticationStep = 64
)

type pulseIFTFrame struct {
	vendor    uint32
	frameType uint32
	sequence  uint32
	payload   []byte
}

type pulseIFTBufferFrame struct {
	vendor       uint32
	frameType    uint32
	sequence     uint32
	packetBuffer *buf.Buffer
}

type pulseIFTConnection struct {
	net.Conn
	reader      *bufio.Reader
	writeAccess sync.Mutex
	sequence    uint32
}

func (c *pulseIFTConnection) readFrame(maximumLength int) (pulseIFTFrame, error) {
	bufferFrame, err := c.readFrameBuffer(maximumLength)
	if err != nil {
		return pulseIFTFrame{}, err
	}
	payload := append([]byte(nil), bufferFrame.packetBuffer.Bytes()...)
	bufferFrame.packetBuffer.Release()
	return pulseIFTFrame{
		vendor:    bufferFrame.vendor,
		frameType: bufferFrame.frameType,
		sequence:  bufferFrame.sequence,
		payload:   payload,
	}, nil
}

func (c *pulseIFTConnection) readFrameBuffer(maximumLength int) (pulseIFTBufferFrame, error) {
	if maximumLength < pulseIFTHeaderSize {
		return pulseIFTBufferFrame{}, E.New("invalid Pulse IF-T frame limit: ", maximumLength)
	}
	header := make([]byte, pulseIFTHeaderSize)
	_, err := io.ReadFull(c.reader, header)
	if err != nil {
		return pulseIFTBufferFrame{}, E.Cause(err, "read Pulse IF-T header")
	}
	totalLength := binary.BigEndian.Uint32(header[8:12])
	if totalLength < pulseIFTHeaderSize || totalLength > uint32(maximumLength) {
		return pulseIFTBufferFrame{}, E.New("invalid Pulse IF-T frame length: ", totalLength)
	}
	packetBuffer := newPacketBuffer(int(totalLength) - pulseIFTHeaderSize)
	_, err = packetBuffer.ReadFullFrom(c.reader, int(totalLength)-pulseIFTHeaderSize)
	if err != nil {
		packetBuffer.Release()
		return pulseIFTBufferFrame{}, E.Cause(err, "read Pulse IF-T payload")
	}
	return pulseIFTBufferFrame{
		vendor:       binary.BigEndian.Uint32(header[0:4]),
		frameType:    binary.BigEndian.Uint32(header[4:8]),
		sequence:     binary.BigEndian.Uint32(header[12:16]),
		packetBuffer: packetBuffer,
	}, nil
}

func (c *pulseIFTConnection) writeFrame(vendor uint32, frameType uint32, payload []byte) error {
	return c.writeFrames(vendor, frameType, [][]byte{payload})
}

func (c *pulseIFTConnection) writeFrames(vendor uint32, frameType uint32, payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	packetBuffers := newPacketBuffersFrom(payloads)
	defer buf.ReleaseMulti(packetBuffers)
	return c.writeFrameBuffers(vendor, frameType, packetBuffers)
}

func (c *pulseIFTConnection) writeFrameBuffers(vendor uint32, frameType uint32, packetBuffers []*buf.Buffer) error {
	if len(packetBuffers) == 0 {
		return nil
	}
	c.writeAccess.Lock()
	defer c.writeAccess.Unlock()
	for index, packetBuffer := range packetBuffers {
		payloadLength := packetBuffer.Len()
		if uint64(payloadLength)+pulseIFTHeaderSize > uint64(^uint32(0)) {
			return E.New("IF-T payload is too large: ", payloadLength)
		}
		packetBuffers[index] = requirePacketBufferCapacity(packetBuffer, pulseIFTHeaderSize, 0)
		header := packetBuffers[index].ExtendHeader(pulseIFTHeaderSize)
		binary.BigEndian.PutUint32(header[0:4], vendor)
		binary.BigEndian.PutUint32(header[4:8], frameType)
		binary.BigEndian.PutUint32(header[8:12], uint32(pulseIFTHeaderSize+payloadLength))
		binary.BigEndian.PutUint32(header[12:16], c.sequence)
		c.sequence++
	}
	err := writeByteSequence(c.Conn, buf.ToSliceMulti(packetBuffers))
	if err != nil {
		return E.Cause(err, "write Pulse protocol bytes")
	}
	return nil
}

func writePulseBytes(w io.Writer, content []byte) error {
	for len(content) > 0 {
		n, err := w.Write(content)
		if err != nil {
			return E.Cause(err, "write Pulse protocol bytes")
		}
		if n <= 0 || n > len(content) {
			return E.New("invalid Pulse protocol write length: ", n)
		}
		content = content[n:]
	}
	return nil
}

type pulseEAPPacket struct {
	code       byte
	identifier byte
	typeValue  uint32
	subtype    uint32
	payload    []byte
}

func parsePulseEAP(content []byte) (pulseEAPPacket, error) {
	if len(content) < 4 {
		return pulseEAPPacket{}, E.New("EAP packet is shorter than its header")
	}
	packetLength := int(binary.BigEndian.Uint16(content[2:4]))
	if packetLength != len(content) {
		return pulseEAPPacket{}, E.New("EAP length mismatch: ", packetLength, " != ", len(content))
	}
	packet := pulseEAPPacket{code: content[0], identifier: content[1]}
	if packet.code == pulseEAPSuccess || packet.code == pulseEAPFailure {
		if len(content) != 4 {
			return pulseEAPPacket{}, E.New("terminal EAP packet has a payload")
		}
		return packet, nil
	}
	if len(content) < 5 {
		return pulseEAPPacket{}, E.New("EAP packet omitted its type")
	}
	packet.typeValue = uint32(content[4])
	packet.payload = content[5:]
	if content[4] == pulseEAPTypeExpanded {
		if len(content) < 12 {
			return pulseEAPPacket{}, E.New("expanded EAP packet is too short")
		}
		packet.typeValue = binary.BigEndian.Uint32(content[4:8])
		packet.subtype = binary.BigEndian.Uint32(content[8:12])
		packet.payload = content[12:]
	}
	return packet, nil
}

func buildPulseEAP(code byte, identifier byte, typeValue byte, subtype uint32, payload []byte) ([]byte, error) {
	headerLength := 5
	if typeValue == pulseEAPTypeExpanded {
		headerLength = 12
	}
	if len(payload) > int(^uint16(0))-headerLength {
		return nil, E.New("EAP payload is too large: ", len(payload))
	}
	content := make([]byte, headerLength+len(payload))
	content[0] = code
	content[1] = identifier
	binary.BigEndian.PutUint16(content[2:4], uint16(len(content)))
	if typeValue == pulseEAPTypeExpanded {
		binary.BigEndian.PutUint32(content[4:8], pulseEAPExpandedJuniper)
		binary.BigEndian.PutUint32(content[8:12], subtype)
	} else {
		content[4] = typeValue
	}
	copy(content[headerLength:], payload)
	return content, nil
}

func parsePulseAuthenticationEAP(frame pulseIFTFrame) (pulseEAPPacket, error) {
	if frame.vendor&0x00ffffff != pulseVendorTCG || frame.frameType != pulseIFTClientAuthChallenge {
		return pulseEAPPacket{}, E.New("unexpected Pulse IF-T authentication frame")
	}
	if len(frame.payload) < 4 || binary.BigEndian.Uint32(frame.payload[:4]) != pulseIFTAuthenticationJuniper {
		return pulseEAPPacket{}, E.New("IF-T authentication frame omitted Juniper/1 auth type")
	}
	packet, err := parsePulseEAP(frame.payload[4:])
	if err != nil {
		return pulseEAPPacket{}, E.Cause(err, "parse Pulse IF-T EAP packet")
	}
	if packet.code != pulseEAPRequest {
		return pulseEAPPacket{}, E.New("unexpected Pulse EAP code: ", packet.code)
	}
	return packet, nil
}

func buildPulseAuthenticationPayload(packet []byte) []byte {
	payload := make([]byte, 4+len(packet))
	binary.BigEndian.PutUint32(payload[:4], pulseIFTAuthenticationJuniper)
	copy(payload[4:], packet)
	return payload
}

type pulseAVP struct {
	code   uint32
	vendor uint32
	flags  byte
	data   []byte
}

func parsePulseAVPs(content []byte) ([]pulseAVP, error) {
	var attributes []pulseAVP
	for len(content) > 0 {
		if len(content) < 8 {
			return nil, E.New("AVP stream ended inside a header")
		}
		code := binary.BigEndian.Uint32(content[0:4])
		flags := content[4]
		attributeLength := int(binary.BigEndian.Uint32(content[4:8]) & 0x00ffffff)
		headerLength := 8
		if flags&pulseAVPFlagVendor != 0 {
			headerLength = 12
		}
		if attributeLength < headerLength || attributeLength > len(content) {
			return nil, E.New("invalid Pulse AVP length: ", attributeLength)
		}
		alignedLength := (attributeLength + 3) &^ 3
		if alignedLength > len(content) {
			return nil, E.New("AVP padding exceeds its packet")
		}
		attribute := pulseAVP{code: code, flags: flags}
		if headerLength == 12 {
			attribute.vendor = binary.BigEndian.Uint32(content[8:12])
		}
		attribute.data = append([]byte(nil), content[headerLength:attributeLength]...)
		attributes = append(attributes, attribute)
		content = content[alignedLength:]
	}
	return attributes, nil
}

func appendPulseAVP(destination []byte, code uint32, vendor uint32, data []byte) ([]byte, error) {
	headerLength := 8
	flags := byte(pulseAVPFlagMandatory)
	if vendor != 0 {
		headerLength = 12
		flags |= pulseAVPFlagVendor
	}
	attributeLength := headerLength + len(data)
	if attributeLength > 0x00ffffff {
		return nil, E.New("AVP is too large: ", attributeLength)
	}
	alignedLength := (attributeLength + 3) &^ 3
	start := len(destination)
	destination = append(destination, make([]byte, alignedLength)...)
	binary.BigEndian.PutUint32(destination[start:start+4], code)
	binary.BigEndian.PutUint32(destination[start+4:start+8], uint32(flags)<<24|uint32(attributeLength))
	if vendor != 0 {
		binary.BigEndian.PutUint32(destination[start+8:start+12], vendor)
	}
	copy(destination[start+headerLength:start+attributeLength], data)
	return destination, nil
}
