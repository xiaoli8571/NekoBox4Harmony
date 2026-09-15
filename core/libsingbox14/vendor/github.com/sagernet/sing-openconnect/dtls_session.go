package openconnect

import (
	"context"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type anyConnectDTLSChannel struct {
	ctx             context.Context
	cancel          context.CancelFunc
	negotiation     cstpDTLSNegotiation
	deliver         func(*buf.Buffer)
	done            chan error
	doneOnce        sync.Once
	access          sync.RWMutex
	writeAccess     sync.Mutex
	waitGroup       sync.WaitGroup
	conn            net.Conn
	started         bool
	closed          bool
	closeErr        error
	ready           atomic.Bool
	lastReceived    atomic.Int64
	lastTransmitted atomic.Int64
	lastDPD         atomic.Int64
	lastRekey       atomic.Int64
	detectedMTU     atomic.Int64
}

func newAnyConnectDTLS(
	ctx context.Context,
	negotiation cstpDTLSNegotiation,
	deliver func(*buf.Buffer),
) *anyConnectDTLSChannel {
	channelCtx, cancel := context.WithCancel(ctx)
	return &anyConnectDTLSChannel{
		ctx:         channelCtx,
		cancel:      cancel,
		negotiation: negotiation,
		deliver:     deliver,
		done:        make(chan error, 1),
	}
}

func (c *anyConnectDTLSChannel) Start() error {
	c.access.Lock()
	if c.started {
		c.access.Unlock()
		return E.New("DTLS channel already started")
	}
	if c.closed {
		c.access.Unlock()
		return E.New("DTLS channel is closed")
	}
	c.started = true
	c.access.Unlock()

	conn, err := c.connect()
	if err != nil {
		c.terminate(err)
		return err
	}
	detectedMTU, err := detectAnyConnectDTLSMTU(c.ctx, conn, c.negotiation.MinimumMTU, c.negotiation.MTU)
	if err != nil {
		closeErr := conn.Close()
		if E.IsClosed(closeErr) {
			closeErr = nil
		}
		err = E.Errors(err, closeErr)
		c.terminate(err)
		return err
	}
	if detectedMTU > 0 {
		c.detectedMTU.Store(int64(detectedMTU))
	}
	now := time.Now().UnixNano()
	c.access.Lock()
	if c.closed {
		c.access.Unlock()
		closeErr := conn.Close()
		if closeErr != nil {
			return E.Cause(closeErr, "close DTLS channel after concurrent shutdown")
		}
		return E.New("DTLS channel closed during startup")
	}
	timersConfigured := c.negotiation.DPD > 0 || c.negotiation.Keepalive > 0 ||
		c.negotiation.Rekey > 0 && c.negotiation.RekeyMethod != "" && c.negotiation.RekeyMethod != "none"
	workerCount := 1
	if timersConfigured {
		workerCount++
	}
	c.conn = conn
	c.waitGroup.Add(workerCount)
	c.ready.Store(true)
	c.lastReceived.Store(now)
	c.lastTransmitted.Store(now)
	c.lastRekey.Store(now)
	c.access.Unlock()

	go c.readLoop()
	if timersConfigured {
		go c.timerLoop()
	}
	return nil
}

func (c *anyConnectDTLSChannel) Ready() bool {
	return c.ready.Load()
}

func (c *anyConnectDTLSChannel) DetectedMTU() int {
	return int(c.detectedMTU.Load())
}

func (c *anyConnectDTLSChannel) WriteDataPacket(payload []byte) error {
	packetBuffer := newPacketBufferFrom(payload)
	defer packetBuffer.Release()
	return c.WriteDataPacketBuffer(&packetBuffer)
}

func (c *anyConnectDTLSChannel) WriteDataPacketBuffer(packetBuffer **buf.Buffer) error {
	packetType := cstpPacketData
	outgoingBuffer := packetBuffer
	var compressedPacket *buf.Buffer
	compressedPacket, compressed := compressAnyConnectStatelessPacket(c.negotiation.Compression, (*packetBuffer).Bytes())
	if compressed {
		outgoingBuffer = &compressedPacket
		packetType = cstpPacketCompressed
	}
	*outgoingBuffer = requirePacketBufferCapacity(*outgoingBuffer, 1, 0)
	header := (*outgoingBuffer).ExtendHeader(1)
	header[0] = packetType
	err := c.writePacket((*outgoingBuffer).Bytes())
	(*outgoingBuffer).Advance(1)
	if compressedPacket != nil {
		compressedPacket.Release()
	}
	return err
}

func (c *anyConnectDTLSChannel) writePacket(packet []byte) error {
	c.writeAccess.Lock()
	defer c.writeAccess.Unlock()
	if !c.ready.Load() {
		return E.New("DTLS channel is not ready")
	}
	c.access.RLock()
	conn := c.conn
	c.access.RUnlock()
	if conn == nil {
		return E.New("DTLS channel has no active connection")
	}
	n, err := conn.Write(packet)
	if err != nil {
		wrappedErr := E.Cause(err, "write DTLS packet")
		c.terminate(wrappedErr)
		return wrappedErr
	}
	if n != len(packet) {
		shortWriteErr := E.New("short DTLS packet write: wrote ", n, " of ", len(packet), " bytes")
		c.terminate(shortWriteErr)
		return shortWriteErr
	}
	c.lastTransmitted.Store(time.Now().UnixNano())
	return nil
}

func (c *anyConnectDTLSChannel) readLoop() {
	defer c.waitGroup.Done()
	maximumPayloadSize := max(16384, c.negotiation.MTU)
	bufferSize := maximumPayloadSize + 1
	for {
		c.access.RLock()
		conn := c.conn
		c.access.RUnlock()
		if conn == nil {
			return
		}
		packetBuffer := newPacketBuffer(bufferSize)
		n, err := conn.Read(packetBuffer.FreeBytes())
		if err != nil {
			packetBuffer.Release()
			if c.ctx.Err() == nil && err != io.EOF {
				c.terminate(E.Cause(err, "read DTLS packet"))
			} else {
				c.terminate(nil)
			}
			return
		}
		if n == 0 {
			packetBuffer.Release()
			continue
		}
		packetBuffer.Extend(n)
		c.lastReceived.Store(time.Now().UnixNano())
		switch packetBuffer.Byte(0) {
		case cstpPacketData:
			packetBuffer.Advance(1)
			if c.deliver != nil {
				c.deliver(packetBuffer)
			} else {
				packetBuffer.Release()
			}
		case cstpPacketDPDRequest:
			packetBuffer.Release()
			err = c.writePacket([]byte{cstpPacketDPDResponse})
			if err != nil {
				return
			}
		case cstpPacketDPDResponse, cstpPacketKeepalive:
			packetBuffer.Release()
		case cstpPacketCompressed:
			if c.negotiation.Compression == anyConnectCompressionNone {
				packetBuffer.Release()
				c.terminate(E.Extend(ErrProtocolNotSupported, "received compressed DTLS packet without negotiated compression"))
				return
			}
			packetBuffer.Advance(1)
			decompressedPacket, decompressErr := decompressAnyConnectStatelessPacket(c.negotiation.Compression, packetBuffer.Bytes(), maximumPayloadSize)
			packetBuffer.Release()
			if decompressErr != nil {
				if c.negotiation.Logger != nil {
					c.negotiation.Logger.DebugContext(c.ctx, "Ignoring invalid ", c.negotiation.Compression.String(), "-compressed DTLS packet: ", decompressErr)
				}
				continue
			}
			if c.deliver != nil {
				c.deliver(decompressedPacket)
			} else {
				decompressedPacket.Release()
			}
		default:
			packetBuffer.Release()
			// Upstream dtls_mainloop ignores unknown packet types because some OpenSSL versions return out-of-order record garbage in non-blocking mode.
		}
	}
}

func (c *anyConnectDTLSChannel) Close() error {
	c.terminate(nil)
	c.waitGroup.Wait()
	c.access.RLock()
	closeErr := c.closeErr
	c.access.RUnlock()
	return closeErr
}

func (c *anyConnectDTLSChannel) Done() <-chan error {
	return c.done
}

func (c *anyConnectDTLSChannel) terminate(err error) {
	c.doneOnce.Do(func() {
		c.access.Lock()
		c.ready.Store(false)
		c.closed = true
		conn := c.conn
		c.conn = nil
		c.access.Unlock()
		c.cancel()
		if conn != nil {
			closeErr := conn.Close()
			if closeErr != nil && !E.IsClosed(closeErr) {
				wrappedCloseErr := E.Cause(closeErr, "close DTLS connection")
				c.access.Lock()
				c.closeErr = wrappedCloseErr
				c.access.Unlock()
				if err == nil {
					err = wrappedCloseErr
				} else {
					err = E.Errors(err, wrappedCloseErr)
				}
			}
		}
		if err != nil {
			c.done <- err
		}
		close(c.done)
	})
}
