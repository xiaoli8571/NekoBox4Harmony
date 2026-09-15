package openconnect

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type pppEncapsulation uint8

const (
	pppEncapsulationF5 pppEncapsulation = iota + 1
	pppEncapsulationF5HDLC
	pppEncapsulationFortinet
)

const (
	pppF5Magic               = 0xf500
	pppFortinetMagic         = 0x5050
	pppHDLCFlag              = 0x7e
	pppHDLCEscape            = 0x7d
	pppHDLCInitialFCS        = 0xffff
	pppHDLCGoodFCS           = 0xf0b8
	pppMaximumPayloadLength  = 65535
	pppMaximumWireFrameSize  = 2*pppMaximumPayloadLength + 6
	pppHDLCControlEscapeMask = uint32(0xffffffff)
)

type pppFrameDecoder struct {
	encapsulation pppEncapsulation
	pending       []byte
}

func newPPPFrameDecoder(encapsulation pppEncapsulation) (*pppFrameDecoder, error) {
	switch encapsulation {
	case pppEncapsulationF5, pppEncapsulationF5HDLC, pppEncapsulationFortinet:
		return &pppFrameDecoder{encapsulation: encapsulation}, nil
	default:
		return nil, E.Extend(ErrProtocolNotSupported, "PPP encapsulation: ", encapsulation)
	}
}

func (d *pppFrameDecoder) Push(content []byte) ([]*buf.Buffer, error) {
	if len(content) == 0 {
		return nil, nil
	}
	if len(d.pending)+len(content) > pppMaximumWireFrameSize {
		return nil, E.New("PPP receive buffer exceeds maximum wire frame size")
	}
	d.pending = append(d.pending, content...)
	switch d.encapsulation {
	case pppEncapsulationF5:
		return d.decodeF5()
	case pppEncapsulationF5HDLC:
		return d.decodeHDLC()
	case pppEncapsulationFortinet:
		return d.decodeFortinet()
	default:
		return nil, E.Extend(ErrProtocolNotSupported, "PPP encapsulation: ", d.encapsulation)
	}
}

func (d *pppFrameDecoder) decodeF5() ([]*buf.Buffer, error) {
	var frames []*buf.Buffer
	for len(d.pending) >= 4 {
		if binary.BigEndian.Uint16(d.pending[:2]) != pppF5Magic {
			buf.ReleaseMulti(frames)
			return nil, E.New("invalid F5 PPP frame magic: ", framePreview(d.pending))
		}
		payloadLength := int(binary.BigEndian.Uint16(d.pending[2:4]))
		frameLength := 4 + payloadLength
		if len(d.pending) < frameLength {
			break
		}
		if payloadLength > 0 {
			frames = append(frames, newPacketBufferFrom(d.pending[4:frameLength]))
		}
		d.pending = d.pending[frameLength:]
	}
	d.compact()
	return frames, nil
}

func (d *pppFrameDecoder) decodeFortinet() ([]*buf.Buffer, error) {
	var frames []*buf.Buffer
	for len(d.pending) >= 6 {
		totalLength := int(binary.BigEndian.Uint16(d.pending[:2]))
		if binary.BigEndian.Uint16(d.pending[2:4]) != pppFortinetMagic {
			buf.ReleaseMulti(frames)
			return nil, E.New("invalid Fortinet PPP frame magic: ", framePreview(d.pending))
		}
		payloadLength := int(binary.BigEndian.Uint16(d.pending[4:6]))
		if totalLength != payloadLength+6 {
			buf.ReleaseMulti(frames)
			return nil, E.New("invalid Fortinet PPP frame length: ", framePreview(d.pending))
		}
		if len(d.pending) < totalLength {
			break
		}
		if payloadLength > 0 {
			frames = append(frames, newPacketBufferFrom(d.pending[6:totalLength]))
		}
		d.pending = d.pending[totalLength:]
	}
	d.compact()
	return frames, nil
}

func (d *pppFrameDecoder) decodeHDLC() ([]*buf.Buffer, error) {
	var frames []*buf.Buffer
	for len(d.pending) > 0 {
		start := 0
		if d.pending[0] == pppHDLCFlag {
			for start < len(d.pending) && d.pending[start] == pppHDLCFlag {
				start++
			}
			if start == len(d.pending) {
				d.pending = d.pending[len(d.pending)-1:]
				break
			}
		}
		endOffset := bytes.IndexByte(d.pending[start:], pppHDLCFlag)
		if endOffset < 0 {
			break
		}
		end := start + endOffset
		frame, valid := decodePPPHDLCFrameBuffer(d.pending[start:end])
		if valid {
			frames = append(frames, frame)
		}
		d.pending = d.pending[end:]
	}
	d.compact()
	return frames, nil
}

func (d *pppFrameDecoder) compact() {
	if len(d.pending) == 0 {
		d.pending = nil
	}
}

func (d *pppFrameDecoder) Discard() int {
	dropped := len(d.pending)
	d.pending = nil
	return dropped
}

func framePreview(content []byte) string {
	const previewLength = 64
	if len(content) > previewLength {
		return hex.EncodeToString(content[:previewLength]) + "..."
	}
	return hex.EncodeToString(content)
}

func encodePPPFrame(encapsulation pppEncapsulation, payload []byte, asyncMap uint32) ([]byte, error) {
	if len(payload) == 0 || len(payload) > pppMaximumPayloadLength {
		return nil, E.New("invalid PPP payload length: ", len(payload))
	}
	switch encapsulation {
	case pppEncapsulationF5:
		frame := make([]byte, 4+len(payload))
		binary.BigEndian.PutUint16(frame[:2], pppF5Magic)
		binary.BigEndian.PutUint16(frame[2:4], uint16(len(payload)))
		copy(frame[4:], payload)
		return frame, nil
	case pppEncapsulationF5HDLC:
		return encodePPPHDLCFrame(payload, asyncMap), nil
	case pppEncapsulationFortinet:
		if len(payload) > pppMaximumPayloadLength-6 {
			return nil, E.New("PPP payload exceeds frame length field")
		}
		frame := make([]byte, 6+len(payload))
		binary.BigEndian.PutUint16(frame[:2], uint16(len(frame)))
		binary.BigEndian.PutUint16(frame[2:4], pppFortinetMagic)
		binary.BigEndian.PutUint16(frame[4:6], uint16(len(payload)))
		copy(frame[6:], payload)
		return frame, nil
	default:
		return nil, E.Extend(ErrProtocolNotSupported, "PPP encapsulation: ", encapsulation)
	}
}

func encodePPPHDLCFrame(payload []byte, asyncMap uint32) []byte {
	fcs := uint16(pppHDLCInitialFCS)
	for _, value := range payload {
		fcs = updatePPPHDLCFCS(fcs, value)
	}
	fcs ^= 0xffff
	content := make([]byte, 0, 2*len(payload)+6)
	content = append(content, pppHDLCFlag)
	for _, value := range payload {
		content = appendPPPHDLCByte(content, value, asyncMap)
	}
	content = appendPPPHDLCByte(content, byte(fcs), asyncMap)
	content = appendPPPHDLCByte(content, byte(fcs>>8), asyncMap)
	content = append(content, pppHDLCFlag)
	return content
}

func decodePPPHDLCFrameBuffer(encoded []byte) (*buf.Buffer, bool) {
	decoded := newPacketBuffer(len(encoded))
	escaped := false
	for _, value := range encoded {
		if escaped {
			_ = decoded.WriteByte(value ^ 0x20)
			escaped = false
			continue
		}
		if value == pppHDLCEscape {
			escaped = true
			continue
		}
		_ = decoded.WriteByte(value)
	}
	if escaped {
		decoded.Release()
		return nil, false
	}
	if decoded.Len() < 3 {
		decoded.Release()
		return nil, false
	}
	fcs := uint16(pppHDLCInitialFCS)
	for _, value := range decoded.Bytes() {
		fcs = updatePPPHDLCFCS(fcs, value)
	}
	if fcs != pppHDLCGoodFCS {
		decoded.Release()
		return nil, false
	}
	decoded.Truncate(decoded.Len() - 2)
	return decoded, true
}

func appendPPPHDLCByte(destination []byte, value byte, asyncMap uint32) []byte {
	needsEscape := value == pppHDLCEscape || value == pppHDLCFlag
	if value < 0x20 && asyncMap&(uint32(1)<<value) != 0 {
		needsEscape = true
	}
	if needsEscape {
		return append(destination, pppHDLCEscape, value^0x20)
	}
	return append(destination, value)
}

func updatePPPHDLCFCS(fcs uint16, value byte) uint16 {
	fcs ^= uint16(value)
	for range 8 {
		if fcs&1 != 0 {
			fcs = fcs>>1 ^ 0x8408
		} else {
			fcs >>= 1
		}
	}
	return fcs
}
