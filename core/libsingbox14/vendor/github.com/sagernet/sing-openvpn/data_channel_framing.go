package openvpn

import (
	"math/rand/v2"
	"sync"
	"time"
)

type dataChannelFraming struct {
	compression                compressionSettings
	compressOutbound           bool
	fragmentSize               int
	lzoAdaptiveDisabled        bool
	lzoAdaptiveNext            time.Time
	lzoAdaptiveTotalBytes      int
	lzoAdaptiveCompressedBytes int

	access                   sync.Mutex
	outgoingSequence         int
	incomingBySequence       map[int]*incomingFragmentBuffer
	incomingBytes            int
	incomingSequence         int
	incomingSequenceSet      bool
	reassemblyTimeout        time.Duration
	reassemblyMaxBytes       int
	reassemblyMaxPacketBytes int
}

func newDataChannelFraming(compression compressionSettings, fragment uint32, allowCompression allowCompressionPolicy) *dataChannelFraming {
	fragmentSize := int(fragment)
	if !compression.framingEnabled() && fragmentSize <= 0 {
		return nil
	}
	return &dataChannelFraming{
		compression:              compression,
		compressOutbound:         compression.compressesOutbound(allowCompression),
		fragmentSize:             fragmentSize,
		outgoingSequence:         int(rand.Uint32() & openVPNFragmentSequenceMask),
		incomingBySequence:       make(map[int]*incomingFragmentBuffer),
		reassemblyTimeout:        openVPNFragmentReassemblyTimeout,
		reassemblyMaxBytes:       openVPNFragmentReassemblyMaxBytes,
		reassemblyMaxPacketBytes: openVPNFragmentReassemblyMaxPacketBytes,
	}
}

func (f *dataChannelFraming) payloadOverhead() int {
	if f == nil {
		return 0
	}
	overhead := f.compression.framingOverhead()
	if f.fragmentSize > 0 {
		overhead += 4
	}
	return overhead
}

func (f *dataChannelFraming) Encode(payload []byte, fragmentSize int) ([][]byte, error) {
	if f == nil {
		return [][]byte{append([]byte{}, payload...)}, nil
	}

	framedPayload := append([]byte{}, payload...)
	switch f.compression.algorithm {
	case compressionAlgorithmStub:
		framedPayload = applyStubCompressionFrame(framedPayload, f.compression.swap)
	case compressionAlgorithmLZ4:
		// Upstream lz4_compress emits the swapped no-compress stub when the
		// payload is not compressed.
		framedPayload = applyStubCompressionFrame(framedPayload, true)
	case compressionAlgorithmLZO:
		framedPayload = f.encodeLZOFrame(framedPayload)
	case compressionAlgorithmStubV2, compressionAlgorithmLZ4V2:
		framedPayload = escapeV2StubCompression(framedPayload)
	}

	if f.fragmentSize <= 0 {
		return [][]byte{framedPayload}, nil
	}
	return f.encodeFragments(framedPayload, fragmentSize)
}

func (f *dataChannelFraming) Decode(payload []byte) ([]byte, bool, error) {
	if f == nil {
		return append([]byte{}, payload...), true, nil
	}

	framedPayload := append([]byte{}, payload...)
	if f.fragmentSize > 0 {
		reassembledPayload, complete, err := f.decodeFragment(framedPayload)
		if err != nil || !complete {
			return nil, complete, err
		}
		framedPayload = reassembledPayload
	}

	switch f.compression.algorithm {
	case compressionAlgorithmStub:
		unframedPayload, err := unframeStubCompression(framedPayload, f.compression.swap)
		if err != nil {
			return nil, false, err
		}
		framedPayload = unframedPayload
	case compressionAlgorithmLZO:
		unframedPayload, err := decodeLZOFrame(framedPayload)
		if err != nil {
			return nil, false, err
		}
		framedPayload = unframedPayload
	case compressionAlgorithmLZ4:
		unframedPayload, err := decodeLZ4V1Frame(framedPayload)
		if err != nil {
			return nil, false, err
		}
		framedPayload = unframedPayload
	case compressionAlgorithmStubV2, compressionAlgorithmLZ4V2:
		unwrappedPayload, err := f.unwrapV2Compression(framedPayload)
		if err != nil {
			return nil, false, err
		}
		framedPayload = unwrappedPayload
	}

	return append([]byte{}, framedPayload...), true, nil
}
