package openvpn

import (
	"context"
	"sync/atomic"

	"github.com/sagernet/sing/common/buf"
)

type clientDataPlane struct {
	framing                    atomic.Pointer[dataChannelFraming]
	incomingPacketDropLog      droppedPacketLog
	outgoingPacketDropLog      droppedPacketLog
	allowCompressionPolicy     allowCompressionPolicy
	compression                compressionSettings
	incomingDataPackets        *dataPacketQueue[*buf.Buffer]
	droppedIncomingDataPackets atomic.Uint64
}

func (c *Client) ReadDataPacket(ctx context.Context) ([]byte, error) {
	packetBuffer, err := c.ReadDataPacketBuffer(ctx)
	if err != nil {
		return nil, err
	}
	payload := append([]byte(nil), packetBuffer.Bytes()...)
	packetBuffer.Release()
	return payload, nil
}

func (c *Client) ReadDataPackets(ctx context.Context) ([]*buf.Buffer, error) {
	return c.readDataPackets(ctx, 0)
}

func (c *Client) ReadDataPacketBuffer(ctx context.Context) (*buf.Buffer, error) {
	packetBuffers, err := c.readDataPackets(ctx, 1)
	if err != nil {
		return nil, err
	}
	return packetBuffers[0], nil
}

func (c *Client) readDataPackets(ctx context.Context, maxPackets int) ([]*buf.Buffer, error) {
	readErr := c.currentDataReadError()
	if readErr != nil {
		return nil, readErr
	}
	for {
		select {
		case <-c.lifecycle.dataReadDone:
			return nil, c.currentDataReadError()
		default:
		}
		packetBuffers := c.dataPlane.incomingDataPackets.Pop(maxPackets, nil)
		if len(packetBuffers) > 0 {
			return packetBuffers, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-c.lifecycle.dataReadDone:
			return nil, c.currentDataReadError()
		case <-c.dataPlane.incomingDataPackets.Wake():
		}
	}
}

func (c *Client) WriteDataPacket(packet []byte) error {
	return c.WriteDataPackets([][]byte{packet})
}

func (c *Client) WriteDataPackets(packets [][]byte) error {
	if len(packets) == 0 {
		return nil
	}
	session := c.readySession()
	if session == nil {
		return ErrDataChannelNotReady
	}
	return session.WriteDataPackets(packets)
}

func (c *Client) WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error {
	if len(packetBuffers) == 0 {
		return nil
	}
	session := c.readySession()
	if session == nil {
		buf.ReleaseMulti(packetBuffers)
		return ErrDataChannelNotReady
	}
	return session.WriteDataPacketBuffers(packetBuffers)
}

func (c *Client) DroppedIncomingDataPackets() uint64 {
	return c.dataPlane.droppedIncomingDataPackets.Load()
}

// fragment_outgoing (fragment.c) reports the datagram it cannot frame through
// D_FRAG_ERRORS and zeroes its buffer, which drops that datagram alone.
func (c *Client) outgoingDataPayloadBatches(payloads [][]byte, codec dataCodec, packetHeaderSize int, outerTransportOverhead int) [][][]byte {
	dataFraming := c.dataPlane.framing.Load()
	dataChannelOptions := c.options.DataChannel
	clamp := calculateMSSClamp(
		dataChannelOptions.MSSFix,
		dataChannelOptions.MSSFixMode,
		dataFraming,
		codec,
		packetHeaderSize,
		outerTransportOverhead,
	)
	outgoingPayloadBatches := make([][][]byte, len(payloads))
	if dataFraming == nil {
		for i, payload := range payloads {
			outgoingPayloadBatches[i] = [][]byte{append([]byte{}, clamp.Apply(payload)...)}
		}
		return outgoingPayloadBatches
	}
	fragmentSize := 0
	if dataChannelOptions.Fragment > 0 {
		fragmentSize = calculateDataPayloadBudget(int(dataChannelOptions.Fragment), codec, packetHeaderSize, 4)
	}
	for i, payload := range payloads {
		outgoingPayloads, encodeErr := dataFraming.Encode(clamp.Apply(payload), fragmentSize)
		if encodeErr != nil {
			c.dataPlane.outgoingPacketDropLog.Log(encodeErr)
			continue
		}
		outgoingPayloadBatches[i] = outgoingPayloads
	}
	return outgoingPayloadBatches
}

func (c *Client) outgoingDataBufferBatches(payloads []*buf.Buffer, codec dataCodec, packetHeaderSize int, outerTransportOverhead int) [][]*buf.Buffer {
	dataFraming := c.dataPlane.framing.Load()
	dataChannelOptions := c.options.DataChannel
	clamp := calculateMSSClamp(
		dataChannelOptions.MSSFix,
		dataChannelOptions.MSSFixMode,
		dataFraming,
		codec,
		packetHeaderSize,
		outerTransportOverhead,
	)
	outgoingPayloadBatches := make([][]*buf.Buffer, len(payloads))
	if dataFraming == nil {
		for i, payload := range payloads {
			clamp.ApplyInPlace(payload.Bytes())
			outgoingPayloadBatches[i] = []*buf.Buffer{payload}
		}
		return outgoingPayloadBatches
	}
	fragmentSize := 0
	if dataChannelOptions.Fragment > 0 {
		fragmentSize = calculateDataPayloadBudget(int(dataChannelOptions.Fragment), codec, packetHeaderSize, 4)
	}
	for i, payload := range payloads {
		outgoingPayloads, encodeErr := dataFraming.Encode(clamp.Apply(payload.Bytes()), fragmentSize)
		headroom := payload.Start()
		payload.Release()
		if encodeErr != nil {
			c.dataPlane.outgoingPacketDropLog.Log(encodeErr)
			continue
		}
		outgoingPayloadBuffers := make([]*buf.Buffer, len(outgoingPayloads))
		for j, outgoingPayload := range outgoingPayloads {
			outgoingPayloadBuffer := buf.NewSize(headroom + len(outgoingPayload) + tlsDataAEADTagSize)
			outgoingPayloadBuffer.Resize(headroom, 0)
			_, _ = outgoingPayloadBuffer.Write(outgoingPayload)
			outgoingPayloadBuffers[j] = outgoingPayloadBuffer
		}
		outgoingPayloadBatches[i] = outgoingPayloadBuffers
	}
	return outgoingPayloadBatches
}

func calculateDataPayloadBudget(packetSize int, codec dataCodec, packetHeaderSize int, fixedPayloadSize int) int {
	minimumPacketLength := packetHeaderSize + codec.EncodedLength(fixedPayloadSize)
	if minimumPacketLength >= packetSize {
		return packetSize - minimumPacketLength
	}
	minimumPayloadSize := 1
	maximumPayloadSize := packetSize
	for minimumPayloadSize < maximumPayloadSize {
		candidatePayloadSize := minimumPayloadSize + (maximumPayloadSize-minimumPayloadSize+1)/2
		encodedPacketLength := packetHeaderSize + codec.EncodedLength(fixedPayloadSize+candidatePayloadSize)
		if encodedPacketLength <= packetSize {
			minimumPayloadSize = candidatePayloadSize
		} else {
			maximumPayloadSize = candidatePayloadSize - 1
		}
	}
	return minimumPayloadSize
}

func (c *Client) decodeIncomingDataFraming(payload []byte) ([]byte, bool, error) {
	dataFraming := c.dataPlane.framing.Load()
	if dataFraming == nil {
		return payload, true, nil
	}
	return dataFraming.Decode(payload)
}

func (c *Client) decodeIncomingDataFramingBuffer(payload *buf.Buffer) (*buf.Buffer, bool, error) {
	dataFraming := c.dataPlane.framing.Load()
	if dataFraming == nil {
		return payload, true, nil
	}
	decodedBytes, complete, err := dataFraming.Decode(payload.Bytes())
	payload.Release()
	if err != nil || !complete {
		return nil, complete, err
	}
	return newDataPacketBuffer(c.options.DataChannel.PacketHeadroom, decodedBytes), true, nil
}

func (c *Client) handleIncomingDataPayloads(payloads [][]byte, codec dataCodec, packetHeaderSize int, outerTransportOverhead int) {
	if len(payloads) == 0 {
		return
	}
	dataChannelOptions := c.options.DataChannel
	clamp := calculateMSSClamp(
		dataChannelOptions.MSSFix,
		dataChannelOptions.MSSFixMode,
		c.dataPlane.framing.Load(),
		codec,
		packetHeaderSize,
		outerTransportOverhead,
	)
	clampedPayloads := make([][]byte, 0, len(payloads))
	for _, payload := range payloads {
		clampedPayloads = append(clampedPayloads, clamp.Apply(payload))
	}
	c.pushIncomingDataPackets(clampedPayloads)
}

func (c *Client) handleIncomingDataBuffers(payloads []*buf.Buffer, codec dataCodec, packetHeaderSize int, outerTransportOverhead int) {
	if len(payloads) == 0 {
		return
	}
	dataChannelOptions := c.options.DataChannel
	clamp := calculateMSSClamp(
		dataChannelOptions.MSSFix,
		dataChannelOptions.MSSFixMode,
		c.dataPlane.framing.Load(),
		codec,
		packetHeaderSize,
		outerTransportOverhead,
	)
	for _, payload := range payloads {
		clamp.ApplyInPlace(payload.Bytes())
	}
	c.pushIncomingDataBuffers(payloads)
}

func newDataPacketBuffer(headroom int, packet []byte) *buf.Buffer {
	if headroom < 0 {
		headroom = 0
	}
	packetBuffer := buf.NewSize(headroom + len(packet))
	packetBuffer.Advance(headroom)
	_, _ = packetBuffer.Write(packet)
	return packetBuffer
}

func (c *Client) pushIncomingDataPackets(packets [][]byte) {
	if len(packets) == 0 {
		return
	}
	packetBuffers := make([]*buf.Buffer, 0, len(packets))
	for _, packet := range packets {
		if len(packet) == 0 {
			continue
		}
		packetBuffers = append(packetBuffers, newDataPacketBuffer(c.options.DataChannel.PacketHeadroom, packet))
	}
	dropped := c.dataPlane.incomingDataPackets.PushBatch(packetBuffers, func(packetBuffer *buf.Buffer) {
		packetBuffer.Release()
	})
	if dropped > 0 {
		c.dataPlane.droppedIncomingDataPackets.Add(dropped)
	}
}

func (c *Client) pushIncomingDataBuffers(packetBuffers []*buf.Buffer) {
	if len(packetBuffers) == 0 {
		return
	}
	dropped := c.dataPlane.incomingDataPackets.PushBatch(packetBuffers, func(packetBuffer *buf.Buffer) {
		packetBuffer.Release()
	})
	if dropped > 0 {
		c.dataPlane.droppedIncomingDataPackets.Add(dropped)
	}
}
