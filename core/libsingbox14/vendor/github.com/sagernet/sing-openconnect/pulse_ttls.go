package openconnect

import (
	"encoding/binary"
	"io"
	"net"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	pulseTTLSMaximumFragment = 8192
	pulseTTLSFlagLength      = 0x80
	pulseTTLSFlagMore        = 0x40
	pulseTTLSFlagStart       = 0x20
)

type pulseTTLSConn struct {
	outer          *pulseIFTConnection
	exchangeAccess sync.Mutex
	stateAccess    sync.Mutex
	identifier     byte
	sendBuffer     []byte
	receiveBuffer  []byte
	messageLeft    uint32
	closed         bool
}

func (c *pulseTTLSConn) Read(destination []byte) (int, error) {
	if len(destination) == 0 {
		return 0, nil
	}
	c.exchangeAccess.Lock()
	defer c.exchangeAccess.Unlock()
	c.stateAccess.Lock()
	if c.closed {
		c.stateAccess.Unlock()
		return 0, ErrClientClosed
	}
	c.stateAccess.Unlock()
	if len(c.receiveBuffer) == 0 {
		if c.messageLeft == 0 {
			err := c.flushPending()
			if err != nil {
				return 0, err
			}
		}
		err := c.receiveNextFragment()
		if err != nil {
			return 0, err
		}
	}
	n := copy(destination, c.receiveBuffer)
	clear(c.receiveBuffer[:n])
	c.receiveBuffer = c.receiveBuffer[n:]
	return n, nil
}

func (c *pulseTTLSConn) receiveNextFragment() error {
	continuing := c.messageLeft > 0
	if continuing {
		err := c.writeTTLSFrame(0, nil, 0)
		if err != nil {
			return E.Cause(err, "acknowledge Pulse EAP-TTLS fragment")
		}
	}
	frame, err := c.outer.readFrame(pulseAuthenticationFrameLimit)
	if err != nil {
		return err
	}
	packet, err := parsePulseAuthenticationEAP(frame)
	if err != nil {
		return E.Cause(err, "parse Pulse EAP-TTLS fragment")
	}
	if packet.typeValue != pulseEAPTypeTTLS || len(packet.payload) < 1 {
		return E.New("unexpected Pulse EAP-TTLS packet")
	}
	c.identifier = packet.identifier
	flags := packet.payload[0]
	if flags&0x3f != 0 {
		return E.New("unsupported Pulse EAP-TTLS flags: ", flags)
	}
	fragment := packet.payload[1:]
	if continuing {
		if flags&pulseTTLSFlagLength != 0 {
			return E.New("continued Pulse EAP-TTLS fragment repeated the length flag")
		}
		if len(fragment) == 0 || uint32(len(fragment)) > c.messageLeft {
			return E.New("invalid continued Pulse EAP-TTLS fragment length: ", len(fragment))
		}
		if flags&pulseTTLSFlagMore != 0 {
			if uint32(len(fragment)) >= c.messageLeft {
				return E.New("non-final Pulse EAP-TTLS fragment consumed the complete message")
			}
		} else if uint32(len(fragment)) != c.messageLeft {
			return E.New("final Pulse EAP-TTLS fragment length mismatch")
		}
		c.messageLeft -= uint32(len(fragment))
	} else if flags&pulseTTLSFlagMore != 0 {
		if flags&pulseTTLSFlagLength == 0 || len(fragment) < 5 {
			return E.New("initial fragmented Pulse EAP-TTLS packet omitted its total length")
		}
		totalLength := binary.BigEndian.Uint32(fragment[:4])
		fragment = fragment[4:]
		if totalLength > pulseConfigurationFrameLimit || totalLength <= uint32(len(fragment)) || len(fragment) == 0 {
			return E.New("invalid Pulse EAP-TTLS fragmented message length: ", totalLength)
		}
		c.messageLeft = totalLength - uint32(len(fragment))
	} else if flags&pulseTTLSFlagLength != 0 {
		if len(fragment) < 4 {
			return E.New("EAP-TTLS length flag omitted its value")
		}
		totalLength := binary.BigEndian.Uint32(fragment[:4])
		fragment = fragment[4:]
		if totalLength > pulseConfigurationFrameLimit || totalLength != uint32(len(fragment)) || len(fragment) == 0 {
			return E.New("EAP-TTLS unfragmented message length mismatch")
		}
	} else if len(fragment) == 0 {
		return E.New("empty Pulse EAP-TTLS data packet")
	}
	c.receiveBuffer = append(c.receiveBuffer[:0], fragment...)
	return nil
}

func (c *pulseTTLSConn) Write(content []byte) (int, error) {
	if len(content) == 0 {
		return 0, nil
	}
	c.exchangeAccess.Lock()
	defer c.exchangeAccess.Unlock()
	c.stateAccess.Lock()
	if c.closed {
		c.stateAccess.Unlock()
		return 0, ErrClientClosed
	}
	c.stateAccess.Unlock()
	if len(c.sendBuffer) > pulseConfigurationFrameLimit-len(content) {
		return 0, E.New("EAP-TTLS pending output exceeds ", pulseConfigurationFrameLimit, " bytes")
	}
	c.sendBuffer = append(c.sendBuffer, content...)
	return len(content), nil
}

func (c *pulseTTLSConn) flush() error {
	c.exchangeAccess.Lock()
	defer c.exchangeAccess.Unlock()
	c.stateAccess.Lock()
	closed := c.closed
	c.stateAccess.Unlock()
	if closed {
		return ErrClientClosed
	}
	if len(c.receiveBuffer) > 0 || c.messageLeft > 0 {
		return E.New("cannot flush Pulse EAP-TTLS output with pending input")
	}
	return c.flushPending()
}

func (c *pulseTTLSConn) flushPending() error {
	if len(c.sendBuffer) == 0 {
		return nil
	}
	content := c.sendBuffer
	c.sendBuffer = nil
	completeContent := content
	defer clear(completeContent)
	firstFragment := true
	for len(content) > pulseTTLSMaximumFragment {
		flags := byte(pulseTTLSFlagMore)
		totalLength := uint32(0)
		if firstFragment {
			flags |= pulseTTLSFlagLength
			totalLength = uint32(len(completeContent))
			firstFragment = false
		}
		err := c.writeTTLSFrame(flags, content[:pulseTTLSMaximumFragment], totalLength)
		if err != nil {
			return err
		}
		content = content[pulseTTLSMaximumFragment:]
		frame, err := c.outer.readFrame(pulseAuthenticationFrameLimit)
		if err != nil {
			return E.Cause(err, "read Pulse EAP-TTLS fragment acknowledgement")
		}
		packet, err := parsePulseAuthenticationEAP(frame)
		if err != nil {
			return E.Cause(err, "parse Pulse EAP-TTLS fragment acknowledgement")
		}
		if packet.typeValue != pulseEAPTypeTTLS || len(packet.payload) != 1 || packet.payload[0] != 0 {
			return E.New("invalid Pulse EAP-TTLS fragment acknowledgement")
		}
		c.identifier = packet.identifier
	}
	err := c.writeTTLSFrame(0, content, 0)
	if err != nil {
		return err
	}
	return nil
}

func (c *pulseTTLSConn) writeTTLSFrame(flags byte, fragment []byte, totalLength uint32) error {
	payloadLength := 1 + len(fragment)
	if flags&pulseTTLSFlagLength != 0 {
		payloadLength += 4
	}
	payload := make([]byte, 0, payloadLength)
	payload = append(payload, flags)
	if flags&pulseTTLSFlagLength != 0 {
		var encodedLength [4]byte
		binary.BigEndian.PutUint32(encodedLength[:], totalLength)
		payload = append(payload, encodedLength[:]...)
	}
	payload = append(payload, fragment...)
	packet, err := buildPulseEAP(pulseEAPResponse, c.identifier, pulseEAPTypeTTLS, 0, payload)
	clear(payload)
	if err != nil {
		return err
	}
	authenticationPayload := buildPulseAuthenticationPayload(packet)
	clear(packet)
	err = c.outer.writeFrame(pulseVendorTCG, pulseIFTClientAuthResponse, authenticationPayload)
	clear(authenticationPayload)
	return err
}

func (c *pulseTTLSConn) Close() error {
	c.exchangeAccess.Lock()
	defer c.exchangeAccess.Unlock()
	c.stateAccess.Lock()
	c.closed = true
	clear(c.sendBuffer)
	c.sendBuffer = nil
	clear(c.receiveBuffer)
	c.receiveBuffer = nil
	c.messageLeft = 0
	c.stateAccess.Unlock()
	return nil
}

func (c *pulseTTLSConn) LocalAddr() net.Addr {
	return c.outer.LocalAddr()
}

func (c *pulseTTLSConn) RemoteAddr() net.Addr {
	return c.outer.RemoteAddr()
}

func (c *pulseTTLSConn) SetDeadline(deadline time.Time) error {
	return c.outer.SetDeadline(deadline)
}

func (c *pulseTTLSConn) SetReadDeadline(deadline time.Time) error {
	return c.outer.SetReadDeadline(deadline)
}

func (c *pulseTTLSConn) SetWriteDeadline(deadline time.Time) error {
	return c.outer.SetWriteDeadline(deadline)
}

func writePulseInnerEAP(w io.Writer, packet []byte) error {
	attributeLength := 8 + len(packet)
	if attributeLength > 0x00ffffff {
		return E.New("inner EAP-Message AVP is too large: ", attributeLength)
	}
	content := make([]byte, attributeLength)
	binary.BigEndian.PutUint32(content[0:4], pulseAVPEAPMessage)
	binary.BigEndian.PutUint32(content[4:8], uint32(pulseAVPFlagMandatory)<<24|uint32(attributeLength))
	copy(content[8:], packet)
	err := writePulseBytes(w, content)
	clear(content)
	return err
}

func readPulseInnerEAP(r io.Reader) (pulseEAPPacket, error) {
	header := make([]byte, 8)
	_, err := io.ReadFull(r, header)
	if err != nil {
		return pulseEAPPacket{}, E.Cause(err, "read Pulse inner EAP-Message AVP header")
	}
	if binary.BigEndian.Uint32(header[0:4]) != pulseAVPEAPMessage || header[4]&pulseAVPFlagVendor != 0 {
		return pulseEAPPacket{}, E.New("unexpected Pulse inner EAP-TTLS AVP")
	}
	attributeLength := int(binary.BigEndian.Uint32(header[4:8]) & 0x00ffffff)
	if attributeLength < 8 || attributeLength > pulseAuthenticationFrameLimit {
		return pulseEAPPacket{}, E.New("invalid Pulse inner EAP-Message AVP length: ", attributeLength)
	}
	content := make([]byte, attributeLength-8)
	_, err = io.ReadFull(r, content)
	if err != nil {
		clear(content)
		return pulseEAPPacket{}, E.Cause(err, "read Pulse inner EAP-Message AVP")
	}
	packet, err := parsePulseEAP(content)
	if err != nil {
		clear(content)
		return pulseEAPPacket{}, E.Cause(err, "parse Pulse inner EAP packet")
	}
	if packet.code != pulseEAPRequest || packet.typeValue != pulseEAPExpandedJuniper || packet.subtype != 1 {
		clear(content)
		return pulseEAPPacket{}, E.New("unexpected Pulse inner EAP packet type")
	}
	packet.payload = append([]byte(nil), packet.payload...)
	clear(content)
	return packet, nil
}

var _ net.Conn = (*pulseTTLSConn)(nil)
