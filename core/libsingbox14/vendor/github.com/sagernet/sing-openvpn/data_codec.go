package openvpn

import (
	"time"

	"github.com/sagernet/sing/common/buf"
)

type dataCodec interface {
	Encode(packetID uint32, aadPrefix []byte, payload []byte) ([]byte, error)
	EncodeBuffer(packetID uint32, aadPrefix []byte, payload *buf.Buffer) (*buf.Buffer, error)
	Decode(aadPrefix []byte, payload []byte) (uint32, []byte, error)
	DecodeBuffer(aadPrefix []byte, payload []byte, headroom int) (uint32, *buf.Buffer, error)
	EncodedLength(payloadLength int) int
}

func newTLSDataCodec(keyMaterial []byte, server bool, cipherName string, authName string, replayWindowSize uint32, replayWindowTime time.Duration) (dataCodec, error) {
	replayWindowSize, replayWindowTime = dataReplayWindowParameters(replayWindowSize, replayWindowTime)
	switch cipherName {
	case "AES-128-GCM", "AES-192-GCM", "AES-256-GCM":
		return newTLSGCMDataCodec(keyMaterial, server, cipherName, replayWindowSize, replayWindowTime)
	case "CHACHA20-POLY1305":
		return newTLSChaCha20Poly1305DataCodec(keyMaterial, server, replayWindowSize, replayWindowTime)
	default:
		_, _, _, streamCipherErr := tlsStreamCipherSpec(cipherName)
		if streamCipherErr == nil {
			return newTLSStreamDataCodec(keyMaterial, server, cipherName, authName, replayWindowSize, replayWindowTime)
		}
		return newTLSCBCDataCodec(keyMaterial, server, cipherName, authName, replayWindowSize, replayWindowTime)
	}
}

// Upstream options.c initializes replay_window to DEFAULT_SEQ_BACKTRACK for
// every transport and no code path narrows it by protocol, so TCP peers run the
// same sliding window as UDP peers. The "This mode is used with TCP" note on the
// non-backtrack branch of packet_id_test predates that and no longer describes
// any reachable upstream configuration.
func dataReplayWindowParameters(replayWindowSize uint32, replayWindowTime time.Duration) (uint32, time.Duration) {
	if replayWindowSize == 0 {
		replayWindowSize = defaultReplayWindowSize
	}
	if replayWindowTime == 0 {
		replayWindowTime = defaultReplayWindowTime
	}
	return replayWindowSize, replayWindowTime
}

func tlsDataKeySlots(keySlots []staticKeySlot, server bool) (staticKeySlot, staticKeySlot) {
	if server {
		return keySlots[1], keySlots[0]
	}
	return keySlots[0], keySlots[1]
}
