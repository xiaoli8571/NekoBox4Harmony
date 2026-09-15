package openvpn

import (
	"time"

	E "github.com/sagernet/sing/common/exceptions"

	"github.com/anchore/go-lzo"
	"github.com/pierrec/lz4/v4"
)

const (
	openVPNLZOCompressByte    = 0x66
	openVPNLZ4CompressByte    = 0x69
	openVPNNoCompressByte     = 0xfa
	openVPNNoCompressByteSwap = 0xfb

	openVPNCompressV2IndicatorByte = 0x50
	openVPNCompressV2SubTypeNone   = 0x00
	openVPNCompressV2SubTypeLZ4    = 0x01

	openVPNLZOMaxDecompressedSize = 1 << 16
	openVPNLZ4MaxDecompressedSize = 1 << 16
	openVPNCompressionThreshold   = 100

	openVPNLZOAdaptiveSampleDuration = 2 * time.Second
	openVPNLZOAdaptiveOffDuration    = 60 * time.Second
	openVPNLZOAdaptiveMinimumBytes   = 1000
	openVPNLZOAdaptiveSavePercent    = 5
)

func (f *dataChannelFraming) encodeLZOFrame(payload []byte) []byte {
	if !f.compressOutbound || len(payload) < openVPNCompressionThreshold || !f.lzoCompressionEnabled(time.Now()) {
		return append([]byte{openVPNNoCompressByte}, payload...)
	}
	compressedPayload := compressLZOBlock(payload)
	if f.compression.adaptive {
		f.recordLZOCompression(len(payload), len(compressedPayload))
	}
	if len(compressedPayload) >= len(payload) {
		return append([]byte{openVPNNoCompressByte}, payload...)
	}
	return append([]byte{openVPNLZOCompressByte}, compressedPayload...)
}

// Upstream lzo_decompress (lzo.c) accepts only the plain no-compress marker
// and the LZO marker; every other head byte drops the packet.
func decodeLZOFrame(framedPayload []byte) ([]byte, error) {
	if len(framedPayload) == 0 {
		return nil, E.New("missing compression marker")
	}
	switch framedPayload[0] {
	case openVPNNoCompressByte:
		return framedPayload[1:], nil
	case openVPNLZOCompressByte:
		return decompressLZOBlock(framedPayload[1:])
	default:
		return nil, E.New("invalid lzo compression marker")
	}
}

// Upstream lz4_decompress (lz4.c) unswaps the head byte and accepts only the
// swapped no-compress marker and the LZ4 marker.
func decodeLZ4V1Frame(framedPayload []byte) ([]byte, error) {
	if len(framedPayload) == 0 {
		return nil, E.New("missing compression marker")
	}
	switch framedPayload[0] {
	case openVPNNoCompressByteSwap:
		return unswapV1FrameHead(framedPayload), nil
	case openVPNLZ4CompressByte:
		return decompressLZ4V1Frame(framedPayload)
	default:
		return nil, E.New("invalid lz4 compression marker")
	}
}

func (f *dataChannelFraming) lzoCompressionEnabled(now time.Time) bool {
	if !f.compression.adaptive {
		return true
	}
	f.access.Lock()
	defer f.access.Unlock()
	if f.lzoAdaptiveNext.IsZero() || !now.Before(f.lzoAdaptiveNext) {
		if f.lzoAdaptiveDisabled {
			f.lzoAdaptiveDisabled = false
			f.lzoAdaptiveNext = now.Add(openVPNLZOAdaptiveSampleDuration)
		} else if f.lzoAdaptiveTotalBytes > openVPNLZOAdaptiveMinimumBytes &&
			f.lzoAdaptiveTotalBytes-f.lzoAdaptiveCompressedBytes <
				f.lzoAdaptiveTotalBytes/(100/openVPNLZOAdaptiveSavePercent) {
			f.lzoAdaptiveDisabled = true
			f.lzoAdaptiveNext = now.Add(openVPNLZOAdaptiveOffDuration)
		} else {
			f.lzoAdaptiveNext = now.Add(openVPNLZOAdaptiveSampleDuration)
		}
		f.lzoAdaptiveTotalBytes = 0
		f.lzoAdaptiveCompressedBytes = 0
	}
	return !f.lzoAdaptiveDisabled
}

func (f *dataChannelFraming) recordLZOCompression(totalBytes int, compressedBytes int) {
	f.access.Lock()
	f.lzoAdaptiveTotalBytes += totalBytes
	f.lzoAdaptiveCompressedBytes += compressedBytes
	f.access.Unlock()
}

func decompressLZOBlock(compressedBlock []byte) ([]byte, error) {
	if len(compressedBlock) == 0 {
		return nil, E.New("empty lzo block")
	}
	decompressedBuffer := make([]byte, openVPNLZOMaxDecompressedSize)
	decompressedLength, err := lzo.Decompress(compressedBlock, decompressedBuffer)
	if err != nil {
		return nil, E.Cause(err, "decompress lzo block")
	}
	if decompressedLength <= 0 {
		return nil, E.New("lzo block decompression produced empty output")
	}
	return append([]byte{}, decompressedBuffer[:decompressedLength]...), nil
}

// Upstream compv2_escape_data_ifneeded escapes a leading 0x50 indicator.
func escapeV2StubCompression(payload []byte) []byte {
	if len(payload) == 0 || payload[0] != openVPNCompressV2IndicatorByte {
		return payload
	}
	escaped := make([]byte, 2+len(payload))
	escaped[0] = openVPNCompressV2IndicatorByte
	escaped[1] = openVPNCompressV2SubTypeNone
	copy(escaped[2:], payload)
	return escaped
}

// Upstream compv2/compress-lz4 decode subtype 0x00 as uncompressed and
// subtype 0x01 as an LZ4 block.
func (f *dataChannelFraming) unwrapV2Compression(payload []byte) ([]byte, error) {
	if len(payload) == 0 || payload[0] != openVPNCompressV2IndicatorByte {
		return payload, nil
	}
	if len(payload) < 2 {
		return nil, E.New("truncated v2 compression header")
	}
	switch payload[1] {
	case openVPNCompressV2SubTypeNone:
		return payload[2:], nil
	case openVPNCompressV2SubTypeLZ4:
		if f.compression.algorithm != compressionAlgorithmLZ4V2 {
			return nil, E.New("compressed lz4 v2 payload is not supported")
		}
		return decompressLZ4Block(payload[2:])
	default:
		return nil, E.New("invalid v2 compression sub-type")
	}
}

// Upstream stub_compress (compstub.c) moves the head byte to the tail and
// writes the swapped marker under COMP_F_SWAP, and prepends the plain marker
// otherwise.
func applyStubCompressionFrame(payload []byte, swap bool) []byte {
	if !swap {
		return append([]byte{openVPNNoCompressByte}, payload...)
	}
	if len(payload) == 0 {
		return []byte{openVPNNoCompressByteSwap}
	}
	framedPayload := make([]byte, len(payload)+1)
	framedPayload[0] = openVPNNoCompressByteSwap
	copy(framedPayload[1:], payload[1:])
	framedPayload[len(payload)] = payload[0]
	return framedPayload
}

// Upstream stub_decompress (compstub.c) accepts only the marker matching the
// configured COMP_F_SWAP framing.
func unframeStubCompression(framedPayload []byte, swap bool) ([]byte, error) {
	if len(framedPayload) == 0 {
		return nil, E.New("missing compression marker")
	}
	if !swap {
		if framedPayload[0] != openVPNNoCompressByte {
			return nil, E.New("invalid compression stub marker")
		}
		return framedPayload[1:], nil
	}
	if framedPayload[0] != openVPNNoCompressByteSwap {
		return nil, E.New("invalid compression stub marker")
	}
	return unswapV1FrameHead(framedPayload), nil
}

// Upstream lz4_decompress restores the swapped head byte from the tail.
func unswapV1FrameHead(framedPayload []byte) []byte {
	if len(framedPayload) <= 1 {
		return []byte{}
	}
	payloadLength := len(framedPayload) - 1
	unswapped := make([]byte, payloadLength)
	copy(unswapped[1:], framedPayload[1:payloadLength])
	unswapped[0] = framedPayload[payloadLength]
	return unswapped
}

// Upstream lz4_decompress unswaps before calling LZ4_decompress_safe.
func decompressLZ4V1Frame(framedPayload []byte) ([]byte, error) {
	if len(framedPayload) < 2 {
		return nil, E.New("truncated lz4 v1 payload")
	}
	blockLength := len(framedPayload) - 1
	compressedBlock := make([]byte, blockLength)
	copy(compressedBlock[1:], framedPayload[1:blockLength])
	compressedBlock[0] = framedPayload[blockLength]
	return decompressLZ4Block(compressedBlock)
}

// Upstream lz4_decompress caps output at frame->buf.payload_size.
func decompressLZ4Block(compressedBlock []byte) ([]byte, error) {
	if len(compressedBlock) == 0 {
		return nil, E.New("empty lz4 block")
	}
	decompressedBuffer := make([]byte, openVPNLZ4MaxDecompressedSize)
	decompressedLength, decompressErr := lz4.UncompressBlock(compressedBlock, decompressedBuffer)
	if decompressErr != nil {
		return nil, E.New("lz4 block decompression failed")
	}
	if decompressedLength <= 0 {
		return nil, E.New("lz4 block decompression produced empty output")
	}
	return append([]byte{}, decompressedBuffer[:decompressedLength]...), nil
}
