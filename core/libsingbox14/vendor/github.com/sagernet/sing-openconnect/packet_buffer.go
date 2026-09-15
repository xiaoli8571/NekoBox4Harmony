package openconnect

import (
	"io"
	"net"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

const PacketHeadroom = espFixedHeaderSize

func newPacketBuffer(payloadSize int) *buf.Buffer {
	packetBuffer := buf.NewSize(PacketHeadroom + payloadSize)
	packetBuffer.Resize(PacketHeadroom, 0)
	return packetBuffer
}

func newPacketBufferFrom(payload []byte) *buf.Buffer {
	packetBuffer := newPacketBuffer(len(payload))
	_, _ = packetBuffer.Write(payload)
	return packetBuffer
}

func newPacketBuffersFrom(payloads [][]byte) []*buf.Buffer {
	packetBuffers := make([]*buf.Buffer, len(payloads))
	for index, payload := range payloads {
		packetBuffers[index] = newPacketBufferFrom(payload)
	}
	return packetBuffers
}

func requirePacketBufferCapacity(packetBuffer *buf.Buffer, headroom int, rearRoom int) *buf.Buffer {
	if packetBuffer.Start() >= headroom && packetBuffer.FreeLen() >= rearRoom {
		return packetBuffer
	}
	headroom = max(headroom, PacketHeadroom)
	newBuffer := buf.NewSize(headroom + packetBuffer.Len() + rearRoom)
	newBuffer.Resize(headroom, 0)
	_, _ = newBuffer.Write(packetBuffer.Bytes())
	packetBuffer.Release()
	return newBuffer
}

func writeByteSequence(w io.Writer, content [][]byte) error {
	expected := 0
	for _, data := range content {
		expected += len(data)
	}
	buffers := net.Buffers(content)
	written, err := buffers.WriteTo(w)
	if err != nil {
		return err
	}
	if written != int64(expected) {
		return E.New("short byte sequence write: wrote ", written, " of ", expected, " bytes")
	}
	return nil
}
