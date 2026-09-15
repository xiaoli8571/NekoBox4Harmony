package openconnect

import (
	"context"
	"io"
	"math"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"

	"github.com/anchore/go-lzo"
)

const espChannelTimerResolution = 250 * time.Millisecond

type espChannelConfig struct {
	Dialer                       N.Dialer
	Remote                       M.Socksaddr
	Keys                         *espKeySet
	MTU                          int
	DPD                          time.Duration
	Logger                       logger.ContextLogger
	BuildProbe                   func(sequence uint16) ([]byte, error)
	IsProbeResponse              func(payload []byte) bool
	Deliver                      func(packetBuffer *buf.Buffer)
	ProbeNextHeader              byte
	AcceptLZO                    bool
	PreserveKeysOnFailure        bool
	PreserveKeysOnStartupFailure bool
}

type espChannel struct {
	ctx             context.Context
	cancel          context.CancelFunc
	config          espChannelConfig
	done            chan error
	established     chan struct{}
	doneOnce        sync.Once
	establishedOnce sync.Once
	access          sync.RWMutex
	writeAccess     sync.Mutex
	waitGroup       sync.WaitGroup
	conn            net.Conn
	probeSequence   uint16
	started         bool
	closed          bool
	closeErr        error
	ready           atomic.Bool
	lastReceived    atomic.Int64
	lastDPD         atomic.Int64
}

func newESPChannel(ctx context.Context, config espChannelConfig) (*espChannel, error) {
	if config.Keys == nil {
		return nil, E.New("ESP channel requires keys")
	}
	if !config.Remote.IsValid() || config.Remote.Port == 0 {
		return nil, E.New("ESP channel requires a valid UDP remote address")
	}
	if config.MTU <= 0 || config.MTU > 65535 {
		return nil, E.New("invalid ESP channel MTU: ", config.MTU)
	}
	if config.DPD < 0 {
		return nil, E.New("invalid ESP DPD interval: ", config.DPD)
	}
	if config.DPD > time.Duration(math.MaxInt64/2) {
		return nil, E.New("ESP DPD interval is too large: ", config.DPD)
	}
	if config.BuildProbe == nil || config.IsProbeResponse == nil {
		return nil, E.New("ESP channel requires probe callbacks")
	}
	channelContext, cancel := context.WithCancel(ctx)
	return &espChannel{
		ctx:         channelContext,
		cancel:      cancel,
		config:      config,
		done:        make(chan error, 1),
		established: make(chan struct{}),
	}, nil
}

func (c *espChannel) Start() error {
	c.access.Lock()
	if c.started {
		c.access.Unlock()
		return E.New("ESP channel already started")
	}
	if c.closed {
		c.access.Unlock()
		return ErrClientClosed
	}
	c.started = true
	c.access.Unlock()
	conn, err := c.config.Dialer.DialContext(c.ctx, N.NetworkUDP, c.config.Remote)
	if err != nil {
		wrappedErr := E.Cause(err, "connect ESP UDP transport")
		c.terminate(wrappedErr)
		return wrappedErr
	}
	c.access.Lock()
	if c.closed {
		c.access.Unlock()
		closeErr := conn.Close()
		if closeErr != nil && !E.IsClosed(closeErr) {
			return E.Errors(ErrClientClosed, E.Cause(closeErr, "close ESP UDP transport after concurrent shutdown"))
		}
		return ErrClientClosed
	}
	workerCount := 1
	if c.config.DPD > 0 {
		workerCount++
	}
	c.waitGroup.Add(workerCount)
	c.conn = conn
	c.access.Unlock()
	go c.readLoop()
	if c.config.DPD > 0 {
		go c.timerLoop()
	}
	return nil
}

func (c *espChannel) Ready() bool {
	return c.ready.Load()
}

func (c *espChannel) Established() <-chan struct{} {
	return c.established
}

func (c *espChannel) Done() <-chan error {
	return c.done
}

func (c *espChannel) SendProbe() error {
	c.writeAccess.Lock()
	defer c.writeAccess.Unlock()
	payload, err := c.config.BuildProbe(c.probeSequence)
	if err != nil {
		return E.Cause(err, "build ESP probe")
	}
	c.probeSequence++
	return c.writePayload(payload, c.config.ProbeNextHeader, false)
}

func (c *espChannel) WriteDataPacket(payload []byte) error {
	return c.WriteDataPackets([][]byte{payload})
}

func (c *espChannel) WriteDataPackets(payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	packetBuffers := newPacketBuffersFrom(payloads)
	defer buf.ReleaseMulti(packetBuffers)
	return c.WriteDataPacketBuffers(packetBuffers)
}

func (c *espChannel) WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error {
	if len(packetBuffers) == 0 {
		return nil
	}
	c.writeAccess.Lock()
	defer c.writeAccess.Unlock()
	for index, packetBuffer := range packetBuffers {
		if packetBuffer.Len() > c.config.MTU {
			return E.New("ESP data packet exceeds negotiated MTU: ", packetBuffer.Len(), " > ", c.config.MTU)
		}
		err := c.writePayloadBuffer(&packetBuffers[index], 0, true)
		if err != nil {
			return err
		}
	}
	return nil
}

func (c *espChannel) writePayload(payload []byte, nextHeader byte, requireEstablished bool) error {
	packetBuffer := newPacketBufferFrom(payload)
	defer packetBuffer.Release()
	return c.writePayloadBuffer(&packetBuffer, nextHeader, requireEstablished)
}

func (c *espChannel) writePayloadBuffer(packetBuffer **buf.Buffer, nextHeader byte, requireEstablished bool) error {
	if requireEstablished && !c.ready.Load() {
		return ErrDataChannelNotReady
	}
	c.access.RLock()
	conn := c.conn
	closed := c.closed
	c.access.RUnlock()
	if closed {
		return ErrClientClosed
	}
	if conn == nil {
		return ErrDataChannelNotReady
	}
	err := c.config.Keys.sealBuffer(packetBuffer, nextHeader)
	if err != nil {
		if E.IsMulti(err, errESPSequenceExhausted, errESPKeysDestroyed) {
			c.terminate(err)
		}
		return err
	}
	datagram := (*packetBuffer).Bytes()
	n, err := conn.Write(datagram)
	if err != nil {
		wrappedErr := E.Cause(err, "write ESP UDP datagram")
		c.terminate(wrappedErr)
		return wrappedErr
	}
	if n != len(datagram) {
		shortWriteErr := E.New("short ESP UDP write: wrote ", n, " of ", len(datagram), " bytes")
		c.terminate(shortWriteErr)
		return shortWriteErr
	}
	return nil
}

func (c *espChannel) readLoop() {
	defer c.waitGroup.Done()
	bufferSize := max(c.config.MTU+256, 2048)
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
				c.terminate(E.Cause(err, "read ESP UDP datagram"))
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
		nextHeader, openErr := c.config.Keys.openBuffer(packetBuffer)
		if openErr != nil {
			packetBuffer.Release()
			if c.config.Logger != nil {
				c.config.Logger.DebugContext(c.ctx, "Ignoring invalid ESP UDP datagram: ", openErr)
			}
			continue
		}
		now := time.Now().UnixNano()
		c.lastReceived.Store(now)
		if nextHeader == espLZONextHeader && !c.config.AcceptLZO {
			packetBuffer.Release()
			c.terminate(E.Extend(ErrProtocolNotSupported, "received LZO-compressed ESP payload"))
			return
		}
		if c.config.IsProbeResponse(packetBuffer.Bytes()) {
			c.establishedOnce.Do(func() {
				c.access.Lock()
				defer c.access.Unlock()
				if c.closed {
					return
				}
				c.ready.Store(true)
				close(c.established)
			})
			packetBuffer.Release()
			continue
		}
		if nextHeader == espLZONextHeader {
			decompressedPacketBuffer := newPacketBuffer(c.config.MTU)
			decompressedLength, decompressErr := lzo.Decompress(packetBuffer.Bytes(), decompressedPacketBuffer.FreeBytes())
			if decompressErr != nil {
				packetBuffer.Release()
				decompressedPacketBuffer.Release()
				if c.config.Logger != nil {
					c.config.Logger.DebugContext(c.ctx, "Ignoring invalid LZO-compressed ESP payload: ", E.Cause(decompressErr, "decompress ESP LZO1X payload"))
				}
				continue
			}
			decompressedPacketBuffer.Extend(decompressedLength)
			packetBuffer.Release()
			packetBuffer = decompressedPacketBuffer
		}
		if c.ready.Load() && c.config.Deliver != nil {
			c.config.Deliver(packetBuffer)
		} else {
			packetBuffer.Release()
		}
	}
}

func (c *espChannel) timerLoop() {
	defer c.waitGroup.Done()
	ticker := time.NewTicker(espChannelTimerResolution)
	defer ticker.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case now := <-ticker.C:
			err := c.processDPD(now)
			if err != nil {
				c.terminate(err)
				return
			}
		}
	}
}

func (c *espChannel) processDPD(now time.Time) error {
	if !c.ready.Load() {
		return nil
	}
	lastReceivedNanoseconds := c.lastReceived.Load()
	lastReceived := time.Unix(0, lastReceivedNanoseconds)
	if now.After(lastReceived.Add(2 * c.config.DPD)) {
		return E.New("ESP dead peer detection expired after ", 2*c.config.DPD)
	}
	lastDPDNanoseconds := c.lastDPD.Load()
	due := lastReceived.Add(c.config.DPD)
	if lastDPDNanoseconds > lastReceivedNanoseconds {
		due = time.Unix(0, lastDPDNanoseconds).Add(c.config.DPD / 2)
	}
	if now.Before(due) {
		return nil
	}
	c.lastDPD.Store(now.UnixNano())
	err := c.SendProbe()
	if err != nil {
		return E.Cause(err, "send ESP dead peer detection probe")
	}
	return nil
}

func (c *espChannel) Close() error {
	c.terminate(nil)
	c.waitGroup.Wait()
	c.access.RLock()
	closeErr := c.closeErr
	c.access.RUnlock()
	return closeErr
}

func (c *espChannel) terminate(err error) {
	c.doneOnce.Do(func() {
		c.cancel()
		c.access.Lock()
		wasReady := c.ready.Load()
		associationTerminal := E.IsMulti(err, errESPSequenceExhausted, errESPKeysDestroyed)
		preserveKeys := err != nil && !associationTerminal && (c.config.PreserveKeysOnFailure || c.config.PreserveKeysOnStartupFailure && !wasReady)
		c.ready.Store(false)
		c.closed = true
		conn := c.conn
		c.conn = nil
		c.access.Unlock()
		if conn != nil {
			closeErr := conn.Close()
			if closeErr != nil && !E.IsClosed(closeErr) {
				wrappedCloseErr := E.Cause(closeErr, "close ESP UDP transport")
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
		if !preserveKeys {
			c.config.Keys.destroy()
		}
		if err != nil {
			c.done <- err
		}
		close(c.done)
	})
}
