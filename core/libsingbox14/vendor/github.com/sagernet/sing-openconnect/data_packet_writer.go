package openconnect

import (
	"context"
	"sync"

	"github.com/sagernet/sing/common/buf"
)

type outboundDataPacket struct {
	session      clientSession
	packetBuffer *buf.Buffer
	completion   *outboundDataPacketCompletion
}

type outboundDataPacketCompletion struct {
	access    sync.Mutex
	remaining int
	err       error
	done      chan struct{}
}

func (c *outboundDataPacketCompletion) complete(err error) {
	c.access.Lock()
	if c.err == nil && err != nil {
		c.err = err
	}
	c.remaining--
	if c.remaining == 0 {
		close(c.done)
	}
	c.access.Unlock()
}

func (c *outboundDataPacketCompletion) failed() bool {
	c.access.Lock()
	defer c.access.Unlock()
	return c.err != nil
}

func (c *outboundDataPacketCompletion) wait() error {
	<-c.done
	c.access.Lock()
	defer c.access.Unlock()
	return c.err
}

func (c *Client) enqueueOutboundDataPacketBuffers(session clientSession, packetBuffers []*buf.Buffer) error {
	completion := &outboundDataPacketCompletion{
		remaining: len(packetBuffers),
		done:      make(chan struct{}),
	}
	packets := make([]outboundDataPacket, len(packetBuffers))
	for index, packetBuffer := range packetBuffers {
		packets[index] = outboundDataPacket{
			session:      session,
			packetBuffer: packetBuffer,
			completion:   completion,
		}
	}
	enqueued := 0
	for enqueued < len(packets) {
		select {
		case c.outgoingDataPacketSlots <- struct{}{}:
		case <-c.outgoingDataPacketClosed:
			failUnqueuedOutboundDataPackets(packets[enqueued:], ErrClientClosed)
			return completion.wait()
		}
		pushed := c.outgoingDataPackets.PushBatch(context.Background(), packets[enqueued:enqueued+1])
		if pushed == 0 {
			<-c.outgoingDataPacketSlots
			failUnqueuedOutboundDataPackets(packets[enqueued:], ErrClientClosed)
			return completion.wait()
		}
		enqueued++
	}
	return completion.wait()
}

func (c *Client) runOutgoingDataPacketWriter() {
	defer close(c.outgoingDataPacketWriterDone)
	for {
		packets := c.outgoingDataPackets.Pop(0)
		if len(packets) == 0 {
			if c.outgoingDataPackets.Closed() {
				return
			}
			<-c.outgoingDataPackets.Wake()
			continue
		}
		if c.outgoingDataPackets.Closed() {
			c.failQueuedOutboundDataPackets(packets, ErrClientClosed)
			continue
		}
		for len(packets) > 0 {
			completion := packets[0].completion
			count := 1
			for count < len(packets) && packets[count].completion == completion {
				count++
			}
			c.writeQueuedOutboundDataPackets(packets[:count])
			packets = packets[count:]
		}
	}
}

func (c *Client) writeQueuedOutboundDataPackets(packets []outboundDataPacket) {
	completion := packets[0].completion
	if completion.failed() {
		for _, packet := range packets {
			packet.packetBuffer.Release()
			completion.complete(nil)
			<-c.outgoingDataPacketSlots
		}
		return
	}
	packetBuffers := make([]*buf.Buffer, len(packets))
	for index, packet := range packets {
		packetBuffers[index] = packet.packetBuffer
	}
	err := packets[0].session.WriteDataPacketBuffers(packetBuffers)
	for range packets {
		completion.complete(err)
		<-c.outgoingDataPacketSlots
	}
}

func (c *Client) failQueuedOutboundDataPackets(packets []outboundDataPacket, err error) {
	for _, packet := range packets {
		packet.packetBuffer.Release()
		packet.completion.complete(err)
		<-c.outgoingDataPacketSlots
	}
}

func failUnqueuedOutboundDataPackets(packets []outboundDataPacket, err error) {
	for _, packet := range packets {
		packet.packetBuffer.Release()
		packet.completion.complete(err)
	}
}
