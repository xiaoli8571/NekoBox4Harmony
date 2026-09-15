package openconnect

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"io"
	"math"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

const (
	gpstFrameHeaderSize      = 16
	gpstFrameMagic           = 0x1a2b3c4d
	gpstIPv4EtherType        = 0x0800
	gpstIPv6EtherType        = 0x86dd
	gpstMaximumStatusLine    = 1024
	gpstMinimumReceiveBuffer = 16384
)

var gpstStartMarker = [12]byte{'S', 'T', 'A', 'R', 'T', '_', 'T', 'U', 'N', 'N', 'E', 'L'}

type gpstChannelConfig struct {
	Client     *Client
	Snapshot   gpSessionSnapshot
	TunnelPath string
	MTU        int
	DPD        time.Duration
	Keepalive  time.Duration
	Deliver    func(packetBuffer *buf.Buffer)
}

type gpstChannel struct {
	ctx             context.Context
	cancel          context.CancelFunc
	config          gpstChannelConfig
	keepalive       *cstpKeepaliveState
	done            chan error
	doneOnce        sync.Once
	closeOnce       sync.Once
	lifecycleAccess sync.RWMutex
	writeAccess     sync.Mutex
	waitGroup       sync.WaitGroup
	connection      *tls.Conn
	started         bool
	closed          bool
	closeErr        error
	ready           atomic.Bool
}

func newGPSTChannel(ctx context.Context, config gpstChannelConfig) (*gpstChannel, error) {
	if config.Client == nil || config.Client.tlsConfig == nil {
		return nil, E.New("GPST channel requires an initialized client")
	}
	if config.Snapshot.serverURL == nil || config.Snapshot.serverURL.Hostname() == "" || !config.Snapshot.authenticatedAddress.IsValid() {
		return nil, E.New("GPST channel requires an authenticated gateway endpoint")
	}
	if config.TunnelPath == "" || !strings.HasPrefix(config.TunnelPath, "/") {
		return nil, E.New("GPST channel requires an absolute tunnel path")
	}
	if config.MTU <= 0 || config.MTU > math.MaxUint16 {
		return nil, E.New("invalid GPST channel MTU: ", config.MTU)
	}
	if config.DPD < 0 || config.Keepalive < 0 || config.DPD > time.Duration(math.MaxInt64/2) || config.Keepalive > time.Duration(math.MaxInt64/2) {
		return nil, E.New("invalid GPST timer interval")
	}
	channelContext, cancel := context.WithCancel(ctx)
	return &gpstChannel{
		ctx:       channelContext,
		cancel:    cancel,
		config:    config,
		keepalive: newCSTPKeepaliveState(config.DPD, config.Keepalive, 0, cstpRekeyNone),
		done:      make(chan error, 1),
	}, nil
}

func (c *gpstChannel) Start() error {
	c.lifecycleAccess.Lock()
	if c.started {
		c.lifecycleAccess.Unlock()
		return E.New("GPST channel already started")
	}
	if c.closed {
		c.lifecycleAccess.Unlock()
		return ErrClientClosed
	}
	c.started = true
	c.lifecycleAccess.Unlock()
	connection, err := c.connect()
	if err != nil {
		c.terminate(err)
		return err
	}
	c.lifecycleAccess.Lock()
	if c.closed {
		c.lifecycleAccess.Unlock()
		closeErr := connection.Close()
		if closeErr != nil && !E.IsClosed(closeErr) {
			return E.Errors(ErrClientClosed, E.Cause(closeErr, "close GPST connection after concurrent shutdown"))
		}
		return ErrClientClosed
	}
	c.connection = connection
	c.waitGroup.Add(2)
	c.ready.Store(true)
	c.lifecycleAccess.Unlock()
	go c.readLoop()
	go c.timerLoop()
	return nil
}

func (c *gpstChannel) Done() <-chan error {
	return c.done
}

func (c *gpstChannel) Ready() bool {
	return c.ready.Load()
}

func (c *gpstChannel) WriteDataPacket(payload []byte) error {
	return c.WriteDataPackets([][]byte{payload})
}

func (c *gpstChannel) WriteDataPackets(payloads [][]byte) error {
	if len(payloads) == 0 {
		return nil
	}
	packetBuffers := newPacketBuffersFrom(payloads)
	defer buf.ReleaseMulti(packetBuffers)
	return c.WriteDataPacketBuffers(packetBuffers)
}

func (c *gpstChannel) WriteDataPacketBuffers(packetBuffers []*buf.Buffer) error {
	if len(packetBuffers) == 0 {
		return nil
	}
	if !c.ready.Load() {
		return ErrDataChannelNotReady
	}
	c.writeAccess.Lock()
	c.lifecycleAccess.RLock()
	connection := c.connection
	closed := c.closed
	c.lifecycleAccess.RUnlock()
	if closed || connection == nil || !c.ready.Load() {
		c.writeAccess.Unlock()
		return ErrDataChannelNotReady
	}
	for index, packetBuffer := range packetBuffers {
		if packetBuffer.IsEmpty() {
			c.writeAccess.Unlock()
			return E.New("GPST data packet is empty")
		}
		if packetBuffer.Len() > c.config.MTU {
			c.writeAccess.Unlock()
			return E.New("GPST data packet exceeds negotiated MTU: ", packetBuffer.Len(), " > ", c.config.MTU)
		}
		var etherType uint16
		switch packetBuffer.Byte(0) >> 4 {
		case 4:
			etherType = gpstIPv4EtherType
		case 6:
			etherType = gpstIPv6EtherType
		default:
			c.writeAccess.Unlock()
			return E.New("GPST data packet has an unknown IP version")
		}
		payloadLength := packetBuffer.Len()
		packetBuffers[index] = requirePacketBufferCapacity(packetBuffer, gpstFrameHeaderSize, 0)
		header := packetBuffers[index].ExtendHeader(gpstFrameHeaderSize)
		clear(header)
		binary.BigEndian.PutUint32(header, gpstFrameMagic)
		binary.BigEndian.PutUint16(header[4:], etherType)
		binary.BigEndian.PutUint16(header[6:], uint16(payloadLength))
		binary.LittleEndian.PutUint32(header[8:], 1)
		err := writeGPSTFull(connection, packetBuffers[index].Bytes())
		if err != nil {
			c.writeAccess.Unlock()
			wrappedErr := E.Cause(err, "write GPST frame")
			c.terminate(wrappedErr)
			return wrappedErr
		}
		c.keepalive.markTransmitted()
	}
	c.writeAccess.Unlock()
	return nil
}

func (c *gpstChannel) writeFrame(etherType uint16, payload []byte) error {
	frame := appendGPSTFrame(nil, etherType, payload)
	c.writeAccess.Lock()
	c.lifecycleAccess.RLock()
	connection := c.connection
	closed := c.closed
	c.lifecycleAccess.RUnlock()
	if closed || connection == nil || !c.ready.Load() {
		c.writeAccess.Unlock()
		return ErrDataChannelNotReady
	}
	err := writeGPSTFull(connection, frame)
	c.writeAccess.Unlock()
	if err != nil {
		wrappedErr := E.Cause(err, "write GPST frame")
		c.terminate(wrappedErr)
		return wrappedErr
	}
	c.keepalive.markTransmitted()
	return nil
}

func appendGPSTFrame(frames []byte, etherType uint16, payload []byte) []byte {
	frameOffset := len(frames)
	frames = append(frames, make([]byte, gpstFrameHeaderSize+len(payload))...)
	frame := frames[frameOffset:]
	binary.BigEndian.PutUint32(frame, gpstFrameMagic)
	if etherType != 0 {
		binary.BigEndian.PutUint16(frame[4:], etherType)
		binary.BigEndian.PutUint16(frame[6:], uint16(len(payload)))
		binary.LittleEndian.PutUint32(frame[8:], 1)
		copy(frame[gpstFrameHeaderSize:], payload)
	}
	return frames
}

// /tmp/openconnect/gpst.c:gpst_connect() sends a headerless GET with only user/authcookie and requires the exact twelve-byte START_TUNNEL marker.
func (c *gpstChannel) connect() (*tls.Conn, error) {
	gatewayHostname := c.config.Snapshot.serverURL.Hostname()
	gatewayPortText := effectiveGPPort(c.config.Snapshot.serverURL)
	gatewayPort, err := strconv.ParseUint(gatewayPortText, 10, 16)
	if err != nil || gatewayPort == 0 {
		return nil, markTerminal(E.New("gateway has an invalid GPST port"))
	}
	dialer := c.config.Client.options.Dialer
	destination := M.ParseSocksaddrHostPort(c.config.Snapshot.authenticatedAddress.Unmap().String(), uint16(gatewayPort))
	rawConnection, err := dialer.DialContext(c.ctx, N.NetworkTCP, destination)
	if err != nil {
		return nil, E.Cause(err, "connect GPST TCP transport")
	}
	tlsConfig := c.config.Client.tlsConfig.Clone()
	if tlsConfig.ServerName == "" {
		tlsConfig.ServerName = gatewayHostname
	}
	tlsConfig.NextProtos = nil
	connection := tls.Client(rawConnection, tlsConfig)
	err = connection.HandshakeContext(c.ctx)
	if err != nil {
		closeErr := rawConnection.Close()
		return nil, E.Append(E.Cause(err, "perform GPST TLS handshake"), closeErr, func(cause error) error {
			return E.Cause(cause, "close failed GPST TCP transport")
		})
	}
	stopCancellation := context.AfterFunc(c.ctx, func() {
		_ = connection.Close()
	})
	defer stopCancellation()
	query := filterGPOpaqueQuery(c.config.Snapshot.opaqueQuery, map[string]struct{}{
		"user":       {},
		"authcookie": {},
	}, true)
	request := "GET " + c.config.TunnelPath + "?" + query + " HTTP/1.1\r\n\r\n"
	err = writeGPSTFull(connection, []byte(request))
	if err != nil {
		closeErr := connection.Close()
		return nil, E.Append(E.Cause(err, "write GPST tunnel request"), closeErr, func(cause error) error {
			return E.Cause(cause, "close failed GPST TLS connection")
		})
	}
	var marker [len(gpstStartMarker)]byte
	_, err = io.ReadFull(connection, marker[:])
	if err != nil {
		closeErr := connection.Close()
		return nil, E.Append(E.Cause(err, "read GPST tunnel marker"), closeErr, func(cause error) error {
			return E.Cause(cause, "close failed GPST TLS connection")
		})
	}
	if marker == gpstStartMarker {
		return connection, nil
	}
	statusCode, statusErr := readGPSTHTTPStatus(connection, marker[:])
	closeErr := connection.Close()
	if statusErr != nil {
		return nil, E.Append(statusErr, closeErr, func(cause error) error {
			return E.Cause(cause, "close failed GPST TLS connection")
		})
	}
	classifiedErr := classifyGPTunnelHTTPStatus(statusCode, "GPST")
	if classifiedErr == nil {
		classifiedErr = markTerminal(E.Extend(ErrProtocolNotSupported, "GPST endpoint returned an HTTP response instead of START_TUNNEL"))
	}
	return nil, E.Append(classifiedErr, closeErr, func(cause error) error {
		return E.Cause(cause, "close failed GPST TLS connection")
	})
}

func readGPSTHTTPStatus(connection net.Conn, prefix []byte) (int, error) {
	line := append([]byte(nil), prefix...)
	one := make([]byte, 1)
	for len(line) < gpstMaximumStatusLine && (len(line) == 0 || line[len(line)-1] != '\n') {
		_, err := io.ReadFull(connection, one)
		if err != nil {
			return 0, E.Cause(err, "read GPST HTTP status line")
		}
		line = append(line, one[0])
	}
	if len(line) == gpstMaximumStatusLine && line[len(line)-1] != '\n' {
		return 0, markTerminal(E.Extend(ErrProtocolNotSupported, "GPST HTTP status line is too long"))
	}
	fields := strings.Fields(string(line))
	if len(fields) < 2 || !strings.HasPrefix(fields[0], "HTTP/") {
		return 0, markTerminal(E.Extend(ErrProtocolNotSupported, "unexpected GlobalProtect GPST tunnel marker"))
	}
	statusCode, err := strconv.Atoi(fields[1])
	if err != nil || statusCode < 100 || statusCode > 999 {
		return 0, markTerminal(E.Extend(ErrProtocolNotSupported, "invalid GlobalProtect GPST HTTP status"))
	}
	return statusCode, nil
}

// /tmp/openconnect/gpst.c:gpst_mainloop() accepts the magic-only frame as DPD/keepalive and the two IP EtherTypes as data.
func (c *gpstChannel) readLoop() {
	defer c.waitGroup.Done()
	maximumPayloadSize := max(c.config.MTU, gpstMinimumReceiveBuffer)
	header := make([]byte, gpstFrameHeaderSize)
	for {
		c.lifecycleAccess.RLock()
		connection := c.connection
		c.lifecycleAccess.RUnlock()
		if connection == nil {
			return
		}
		_, err := io.ReadFull(connection, header)
		if err != nil {
			c.finishRead(err)
			return
		}
		magic := binary.BigEndian.Uint32(header)
		etherType := binary.BigEndian.Uint16(header[4:])
		payloadLength := int(binary.BigEndian.Uint16(header[6:]))
		one := binary.LittleEndian.Uint32(header[8:])
		zero := binary.LittleEndian.Uint32(header[12:])
		if magic != gpstFrameMagic {
			c.terminate(E.Extend(ErrProtocolNotSupported, "received unknown GPST frame magic"))
			return
		}
		if payloadLength > maximumPayloadSize {
			c.terminate(E.New("GPST frame exceeds receive limit: ", payloadLength, " > ", maximumPayloadSize))
			return
		}
		packetBuffer := newPacketBuffer(payloadLength)
		_, err = packetBuffer.ReadFullFrom(connection, payloadLength)
		if err != nil {
			packetBuffer.Release()
			c.finishRead(err)
			return
		}
		c.keepalive.markReceived()
		switch etherType {
		case 0:
			packetBuffer.Release()
			if (one != 0 || zero != 0) && c.config.Client.options.Logger != nil {
				c.config.Client.options.Logger.DebugContext(c.ctx, "Ignoring non-zero GPST DPD/keepalive trailer")
			}
		case gpstIPv4EtherType, gpstIPv6EtherType:
			if (one != 1 || zero != 0) && c.config.Client.options.Logger != nil {
				c.config.Client.options.Logger.DebugContext(c.ctx, "Accepting GPST data frame with a non-standard trailer")
			}
			if c.config.Deliver != nil {
				c.config.Deliver(packetBuffer)
			} else {
				packetBuffer.Release()
			}
		default:
			packetBuffer.Release()
			c.terminate(E.Extend(ErrProtocolNotSupported, "received unknown GPST EtherType: ", strconv.FormatUint(uint64(etherType), 16)))
			return
		}
	}
}

func (c *gpstChannel) finishRead(err error) {
	if c.ctx.Err() == nil && err != io.EOF && !E.IsClosed(err) {
		c.terminate(E.Cause(err, "read GPST frame"))
	} else {
		c.terminate(nil)
	}
}

func (c *gpstChannel) timerLoop() {
	defer c.waitGroup.Done()
	timer := time.NewTimer(c.keepalive.nextDelay(time.Now()))
	defer timer.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case now := <-timer.C:
			switch c.keepalive.action(now) {
			case cstpTimerDPD, cstpTimerKeepalive:
				err := c.writeFrame(0, nil)
				if err != nil {
					return
				}
			case cstpTimerDeadPeer:
				c.terminate(E.New("GPST dead peer detection expired"))
				return
			}
			timer.Reset(c.keepalive.nextDelay(time.Now()))
		}
	}
}

func (c *gpstChannel) Close() error {
	c.closeOnce.Do(func() {
		c.terminate(nil)
		c.waitGroup.Wait()
	})
	c.lifecycleAccess.RLock()
	closeErr := c.closeErr
	c.lifecycleAccess.RUnlock()
	return closeErr
}

func (c *gpstChannel) terminate(err error) {
	c.doneOnce.Do(func() {
		c.cancel()
		c.lifecycleAccess.Lock()
		c.ready.Store(false)
		c.closed = true
		connection := c.connection
		c.connection = nil
		c.lifecycleAccess.Unlock()
		if connection != nil {
			closeErr := connection.Close()
			if closeErr != nil && !E.IsClosed(closeErr) {
				wrappedCloseErr := E.Cause(closeErr, "close GPST TLS connection")
				c.lifecycleAccess.Lock()
				c.closeErr = wrappedCloseErr
				c.lifecycleAccess.Unlock()
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

func writeGPSTFull(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		written, err := writer.Write(data)
		if err != nil {
			return err
		}
		if written <= 0 {
			return io.ErrShortWrite
		}
		data = data[written:]
	}
	return nil
}
