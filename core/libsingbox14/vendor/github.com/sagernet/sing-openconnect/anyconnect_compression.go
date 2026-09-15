package openconnect

import (
	"bytes"
	"encoding/binary"
	"io"
	"sync"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"

	"github.com/klauspost/compress/flate"
	"github.com/pierrec/lz4/v4"
)

const (
	anyConnectMinimumCompressionSize = 40
	anyConnectDeflateWindowSize      = 1 << 12
)

type anyConnectCompression uint8

const (
	anyConnectCompressionNone anyConnectCompression = iota
	anyConnectCompressionLZ4
	anyConnectCompressionLZS
	anyConnectCompressionDeflate
)

type anyConnectDeflateState struct {
	outgoingBuffer   bytes.Buffer
	outgoingWriter   *flate.Writer
	outgoingChecksum uint32
	incomingSource   anyConnectDeflateSource
	incomingReader   io.ReadCloser
	incomingChecksum uint32
}

type anyConnectDeflateSource struct {
	content  []byte
	position int
}

var (
	anyConnectLZ4CompressorPool = sync.Pool{
		New: func() any {
			return new(lz4.Compressor)
		},
	}
	errAnyConnectDeflateInputExhausted = E.New("truncated deflate packet")
)

func parseAnyConnectCompression(
	value string,
	headerName string,
	compressionDisabled bool,
	compressionMode string,
	allowDeflate bool,
) (anyConnectCompression, error) {
	if value == "" {
		return anyConnectCompressionNone, nil
	}
	if compressionDisabled {
		return anyConnectCompressionNone, E.Extend(ErrProtocolNotSupported, headerName, " selected compression while compression is disabled: ", value)
	}
	switch value {
	case "oc-lz4":
		return anyConnectCompressionLZ4, nil
	case "lzs":
		return anyConnectCompressionLZS, nil
	case "deflate":
		if allowDeflate && compressionMode == CompressionModeAll {
			return anyConnectCompressionDeflate, nil
		}
	}
	return anyConnectCompressionNone, E.Extend(ErrProtocolNotSupported, "unsupported ", headerName, ": ", value)
}

func (c anyConnectCompression) String() string {
	switch c {
	case anyConnectCompressionLZ4:
		return "oc-lz4"
	case anyConnectCompressionLZS:
		return "lzs"
	case anyConnectCompressionDeflate:
		return "deflate"
	default:
		return "none"
	}
}

func compressAnyConnectStatelessPacket(compression anyConnectCompression, payload []byte) (*buf.Buffer, bool) {
	if len(payload) < anyConnectMinimumCompressionSize ||
		compression != anyConnectCompressionLZ4 && compression != anyConnectCompressionLZS {
		return nil, false
	}
	compressedPacket := newPacketBuffer(len(payload))
	var written int
	var err error
	switch compression {
	case anyConnectCompressionLZ4:
		compressor := anyConnectLZ4CompressorPool.Get().(*lz4.Compressor)
		written, err = compressor.CompressBlock(payload, compressedPacket.FreeBytes())
		anyConnectLZ4CompressorPool.Put(compressor)
	case anyConnectCompressionLZS:
		written, err = compressLZS(compressedPacket.FreeBytes(), payload)
	default:
		compressedPacket.Release()
		return nil, false
	}
	if err != nil || written <= 0 || written > len(payload) {
		compressedPacket.Release()
		return nil, false
	}
	compressedPacket.Extend(written)
	return compressedPacket, true
}

func decompressAnyConnectStatelessPacket(
	compression anyConnectCompression,
	payload []byte,
	maximumPayloadSize int,
) (*buf.Buffer, error) {
	decompressedPacket := newPacketBuffer(maximumPayloadSize)
	var written int
	var err error
	switch compression {
	case anyConnectCompressionLZ4:
		written, err = lz4.UncompressBlock(payload, decompressedPacket.FreeBytes())
	case anyConnectCompressionLZS:
		written, err = decompressLZS(decompressedPacket.FreeBytes(), payload)
	default:
		err = E.New("unsupported stateless compression: ", compression.String())
	}
	if err != nil {
		decompressedPacket.Release()
		return nil, err
	}
	if written <= 0 {
		decompressedPacket.Release()
		return nil, E.New("decompressed ", compression.String(), " packet is empty")
	}
	decompressedPacket.Extend(written)
	return decompressedPacket, nil
}

func newAnyConnectDeflateState() (*anyConnectDeflateState, error) {
	state := &anyConnectDeflateState{
		outgoingChecksum: 1,
		incomingChecksum: 1,
	}
	writer, err := flate.NewWriterWindow(&state.outgoingBuffer, anyConnectDeflateWindowSize)
	if err != nil {
		return nil, E.Cause(err, "create deflate compressor")
	}
	state.outgoingWriter = writer
	state.incomingReader = flate.NewReader(&state.incomingSource)
	return state, nil
}

func (s *anyConnectDeflateState) compress(payload []byte) (*buf.Buffer, error) {
	s.outgoingBuffer.Reset()
	written, err := s.outgoingWriter.Write(payload)
	if err != nil {
		return nil, E.Cause(err, "compress deflate packet")
	}
	if written != len(payload) {
		return nil, E.New("short deflate input: wrote ", written, " of ", len(payload), " bytes")
	}
	err = s.outgoingWriter.Flush()
	if err != nil {
		return nil, E.Cause(err, "flush deflate packet")
	}
	s.outgoingChecksum = updateAdler32(s.outgoingChecksum, payload)
	compressedSize := s.outgoingBuffer.Len() + 4
	if compressedSize > cstpMaximumPayloadSize {
		return nil, E.New("compressed deflate packet exceeds CSTP wire limit: ", compressedSize)
	}
	compressedPacket := newPacketBuffer(compressedSize)
	_, _ = compressedPacket.Write(s.outgoingBuffer.Bytes())
	checksum := compressedPacket.Extend(4)
	binary.BigEndian.PutUint32(checksum, s.outgoingChecksum)
	return compressedPacket, nil
}

func (s *anyConnectDeflateState) decompress(payload []byte, maximumPayloadSize int) (*buf.Buffer, error) {
	if len(payload) < 4 {
		return nil, E.New("deflate packet is missing its Adler-32 checksum")
	}
	s.incomingSource.append(payload[:len(payload)-4])
	decompressedPacket := newPacketBuffer(maximumPayloadSize + 1)
	expectedSize := 0
	for expectedSize == 0 || decompressedPacket.Len() < expectedSize {
		destination := decompressedPacket.FreeBytes()
		if expectedSize > 0 && len(destination) > expectedSize-decompressedPacket.Len() {
			destination = destination[:expectedSize-decompressedPacket.Len()]
		}
		written, err := s.incomingReader.Read(destination)
		if written > 0 {
			decompressedPacket.Extend(written)
		}
		if err != nil {
			decompressedPacket.Release()
			return nil, E.Cause(err, "decompress deflate packet")
		}
		if written == 0 {
			decompressedPacket.Release()
			return nil, E.New("deflate decompressor made no progress")
		}
		if expectedSize == 0 {
			expectedSize, err = anyConnectIPPacketSize(decompressedPacket.Bytes())
			if err != nil {
				decompressedPacket.Release()
				return nil, err
			}
			if expectedSize > maximumPayloadSize {
				decompressedPacket.Release()
				return nil, E.New("decompressed deflate packet exceeds receive limit: ", expectedSize)
			}
			if decompressedPacket.Len() > expectedSize {
				decompressedPacket.Release()
				return nil, E.New("decompressed deflate packet exceeds its IP length: ", decompressedPacket.Len(), " > ", expectedSize)
			}
		}
	}
	s.incomingChecksum = updateAdler32(s.incomingChecksum, decompressedPacket.Bytes())
	expectedChecksum := binary.BigEndian.Uint32(payload[len(payload)-4:])
	actualChecksum := s.incomingChecksum
	if actualChecksum != expectedChecksum {
		decompressedPacket.Release()
		return nil, E.New("deflate Adler-32 mismatch: expected ", expectedChecksum, ", got ", actualChecksum)
	}
	return decompressedPacket, nil
}

func updateAdler32(checksum uint32, payload []byte) uint32 {
	const modulus = 65521
	low := checksum & 0xffff
	high := checksum >> 16
	for len(payload) > 0 {
		blockSize := min(len(payload), 5552)
		for _, value := range payload[:blockSize] {
			low += uint32(value)
			high += low
		}
		low %= modulus
		high %= modulus
		payload = payload[blockSize:]
	}
	return high<<16 | low
}

func anyConnectIPPacketSize(payload []byte) (int, error) {
	if len(payload) == 0 {
		return 0, nil
	}
	switch payload[0] >> 4 {
	case 4:
		if len(payload) < 4 {
			return 0, nil
		}
		packetSize := int(binary.BigEndian.Uint16(payload[2:4]))
		if packetSize < 20 {
			return 0, E.New("invalid decompressed IPv4 packet length: ", packetSize)
		}
		return packetSize, nil
	case 6:
		if len(payload) < 6 {
			return 0, nil
		}
		packetSize := 40 + int(binary.BigEndian.Uint16(payload[4:6]))
		if packetSize < 40 {
			return 0, E.New("invalid decompressed IPv6 packet length: ", packetSize)
		}
		return packetSize, nil
	default:
		return 0, E.New("invalid decompressed IP version: ", payload[0]>>4)
	}
}

func (r *anyConnectDeflateSource) append(content []byte) {
	if r.position == len(r.content) {
		r.content = append(r.content[:0], content...)
		r.position = 0
		return
	}
	remaining := append([]byte(nil), r.content[r.position:]...)
	r.content = append(remaining, content...)
	r.position = 0
}

func (r *anyConnectDeflateSource) Read(destination []byte) (int, error) {
	if r.position == len(r.content) {
		return 0, errAnyConnectDeflateInputExhausted
	}
	written := copy(destination, r.content[r.position:])
	r.position += written
	return written, nil
}

func (r *anyConnectDeflateSource) ReadByte() (byte, error) {
	if r.position == len(r.content) {
		return 0, errAnyConnectDeflateInputExhausted
	}
	value := r.content[r.position]
	r.position++
	return value, nil
}
