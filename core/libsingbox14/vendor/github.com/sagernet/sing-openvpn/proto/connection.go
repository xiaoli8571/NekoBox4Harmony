package proto

import (
	"encoding/binary"
	"io"
	"math"
	"net"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/sagernet/sing/common"
	"github.com/sagernet/sing/common/buf"
	"github.com/sagernet/sing/common/bufio"
	E "github.com/sagernet/sing/common/exceptions"
	N "github.com/sagernet/sing/common/network"
)

// Upstream io_wait (forward.c) is the only thing that ever waits on the link:
// process_outgoing_link writes what the event loop already found writable and
// hands whatever the link refuses to check_status, so no caller of the link
// carries a write timeout of its own and the link exposes none.
type PacketConnection interface {
	ReadPacket() ([]byte, error)
	ReadPackets() ([]*buf.Buffer, error)
	WritePacket(packet []byte) error
	WritePackets(packets [][]byte) (int, error)
	WritePacketBuffers(packetBuffers []*buf.Buffer) (int, error)
	SetReadDeadline(deadline time.Time) error
	ConnectionOriented() bool
	Close() error
	LocalAddr() net.Addr
	RemoteAddr() net.Addr
}

const (
	packetConnectionBatchSize  = 64
	streamPacketLengthSize     = 2
	streamPacketReadBufferSize = buf.UDPBufferSize
	streamPacketMaxEmptyReads  = 100
)

var (
	ErrPacketTooLarge = E.New("packet too large")

	// stream_buf_added (socket.c) refuses an encapsulated length below 1 with a
	// link error that restarts the connection.
	ErrBadEncapsulatedPacketLength = E.New("bad encapsulated packet length from peer")
)

func NewPacketConnection(connection net.Conn, protocol string) (PacketConnection, error) {
	switch {
	case strings.HasPrefix(protocol, "tcp"):
		streamConnection := &streamPacketConnection{connection: connection}
		_, streamConnection.vectorisedWrites = connection.(syscall.Conn)
		return streamConnection, nil
	case strings.HasPrefix(protocol, "udp"):
		packetConnection := &datagramPacketConnection{connection: connection}
		unboundConnection := bufio.NewUnbindPacketConn(connection)
		packetConnection.batchReader, _ = bufio.CreateConnectedPacketBatchReadWaiter(unboundConnection)
		if packetConnection.batchReader != nil {
			packetConnection.batchReader.InitializeReadWaiter(N.ReadWaitOptions{
				MTU:       math.MaxUint16,
				BatchSize: packetConnectionBatchSize,
			})
		}
		packetConnection.batchWriter, _ = bufio.CreateConnectedPacketBatchWriter(unboundConnection)
		return packetConnection, nil
	default:
		return nil, E.New("unsupported protocol")
	}
}

// Upstream stream_buf (socket.c) owns everything a connection-oriented link
// read ever took from the socket: link_socket_read appends one read to the
// bytes the reads before it left in stream_buf.buf, stream_buf_added hands an
// encapsulated packet up only once its length prefix and its whole body are
// there, and stream_buf_read_setup carries what did not form a packet, together
// with the excess of the packet it did form, into the next read. A read which
// ends inside a packet -- between the length prefix and the body, or inside the
// body -- therefore keeps every byte it consumed, whatever error ended it.
type streamPacketConnection struct {
	connection       net.Conn
	vectorisedWrites bool
	readAccess       sync.Mutex
	writeAccess      sync.Mutex
	readBuffer       []byte
	readStart        int
	readEnd          int
	readErr          error
}

func (c *streamPacketConnection) ReadPacket() ([]byte, error) {
	c.readAccess.Lock()
	defer c.readAccess.Unlock()
	bufferedPacket, err := c.readPacketLocked()
	if err != nil {
		return nil, err
	}
	packet := make([]byte, len(bufferedPacket))
	copy(packet, bufferedPacket)
	return packet, nil
}

func (c *streamPacketConnection) ReadPackets() ([]*buf.Buffer, error) {
	c.readAccess.Lock()
	defer c.readAccess.Unlock()
	bufferedPacket, err := c.readPacketLocked()
	if err != nil {
		return nil, err
	}
	packetBuffers := make([]*buf.Buffer, 0, packetConnectionBatchSize)
	packetBuffer := buf.NewSize(len(bufferedPacket))
	common.Must1(packetBuffer.Write(bufferedPacket))
	packetBuffers = append(packetBuffers, packetBuffer)
	for len(packetBuffers) < packetConnectionBatchSize {
		bufferedPacket, err = c.bufferedPacketLocked()
		if err != nil {
			return packetBuffers, err
		}
		if bufferedPacket == nil {
			break
		}
		packetBuffer = buf.NewSize(len(bufferedPacket))
		common.Must1(packetBuffer.Write(bufferedPacket))
		packetBuffers = append(packetBuffers, packetBuffer)
	}
	return packetBuffers, nil
}

func (c *streamPacketConnection) readPacketLocked() ([]byte, error) {
	emptyReads := 0
	for {
		bufferedPacket, err := c.bufferedPacketLocked()
		if err != nil {
			return nil, err
		}
		if bufferedPacket != nil {
			return bufferedPacket, nil
		}
		if c.readErr != nil {
			err = c.readErr
			c.readErr = nil
			return nil, err
		}
		readBytes := c.fillLocked()
		if readBytes > 0 || c.readErr != nil {
			emptyReads = 0
			continue
		}
		emptyReads++
		if emptyReads >= streamPacketMaxEmptyReads {
			return nil, io.ErrNoProgress
		}
	}
}

func (c *streamPacketConnection) bufferedPacketLocked() ([]byte, error) {
	if c.readEnd-c.readStart < streamPacketLengthSize {
		return nil, nil
	}
	packetLength := int(binary.BigEndian.Uint16(c.readBuffer[c.readStart:]))
	if packetLength == 0 {
		return nil, ErrBadEncapsulatedPacketLength
	}
	packetEnd := c.readStart + streamPacketLengthSize + packetLength
	if c.readEnd < packetEnd {
		return nil, nil
	}
	bufferedPacket := c.readBuffer[c.readStart+streamPacketLengthSize : packetEnd]
	c.readStart = packetEnd
	if c.readStart == c.readEnd {
		c.readStart = 0
		c.readEnd = 0
	}
	return bufferedPacket, nil
}

func (c *streamPacketConnection) fillLocked() int {
	pendingLength := c.readEnd - c.readStart
	requiredCapacity := streamPacketReadBufferSize
	if pendingLength >= streamPacketLengthSize {
		requiredCapacity = max(requiredCapacity,
			streamPacketLengthSize+int(binary.BigEndian.Uint16(c.readBuffer[c.readStart:])))
	}
	switch {
	case len(c.readBuffer) < requiredCapacity:
		grownBuffer := make([]byte, requiredCapacity)
		copy(grownBuffer, c.readBuffer[c.readStart:c.readEnd])
		c.readBuffer = grownBuffer
		c.readStart = 0
		c.readEnd = pendingLength
	case c.readStart > 0:
		copy(c.readBuffer, c.readBuffer[c.readStart:c.readEnd])
		c.readStart = 0
		c.readEnd = pendingLength
	}
	readBytes, err := c.connection.Read(c.readBuffer[c.readEnd:])
	if readBytes > 0 {
		c.readEnd += readBytes
	}
	c.readErr = err
	return readBytes
}

func (c *streamPacketConnection) WritePacket(packet []byte) error {
	_, err := c.WritePackets([][]byte{packet})
	return err
}

func (c *streamPacketConnection) WritePackets(packets [][]byte) (int, error) {
	c.writeAccess.Lock()
	defer c.writeAccess.Unlock()
	packetCount := len(packets)
	var validationErr error
	for i, packet := range packets {
		if len(packet) > math.MaxUint16 {
			packetCount = i
			validationErr = ErrPacketTooLarge
			break
		}
	}
	if packetCount == 0 {
		return 0, validationErr
	}
	totalLength := 0
	frameCount := 0
	for _, packet := range packets[:packetCount] {
		if len(packet) == 0 {
			continue
		}
		totalLength += streamPacketLengthSize + len(packet)
		frameCount++
	}
	if frameCount == 0 {
		return packetCount, validationErr
	}
	packetBatch := make([]byte, totalLength)
	frameLengths := make([]int, 0, frameCount)
	framePacketIndexes := make([]int, 0, frameCount)
	offset := 0
	for i, packet := range packets[:packetCount] {
		if len(packet) == 0 {
			continue
		}
		binary.BigEndian.PutUint16(packetBatch[offset:], uint16(len(packet)))
		offset += streamPacketLengthSize
		copy(packetBatch[offset:], packet)
		offset += len(packet)
		frameLengths = append(frameLengths, streamPacketLengthSize+len(packet))
		framePacketIndexes = append(framePacketIndexes, i)
	}
	writtenPackets, writeErr := c.writeFramesLocked(net.Buffers{packetBatch}, frameLengths, framePacketIndexes, packetCount)
	if writeErr != nil {
		return writtenPackets, writeErr
	}
	return writtenPackets, validationErr
}

func (c *streamPacketConnection) WritePacketBuffers(packetBuffers []*buf.Buffer) (int, error) {
	c.writeAccess.Lock()
	defer c.writeAccess.Unlock()
	packetCount := len(packetBuffers)
	var validationErr error
	for i, packetBuffer := range packetBuffers {
		if packetBuffer.Len() > math.MaxUint16 {
			packetCount = i
			validationErr = ErrPacketTooLarge
			break
		}
	}
	if packetCount == 0 {
		buf.ReleaseMulti(packetBuffers)
		return 0, validationErr
	}
	writeBuffers := make([]*buf.Buffer, 0, packetCount)
	frames := make(net.Buffers, 0, packetCount)
	frameLengths := make([]int, 0, packetCount)
	framePacketIndexes := make([]int, 0, packetCount)
	for i, packetBuffer := range packetBuffers[:packetCount] {
		if packetBuffer.IsEmpty() {
			packetBuffer.Release()
			continue
		}
		if packetBuffer.Start() < streamPacketLengthSize {
			newPacketBuffer := buf.NewSize(streamPacketLengthSize + packetBuffer.Len())
			newPacketBuffer.Resize(streamPacketLengthSize, 0)
			common.Must1(newPacketBuffer.Write(packetBuffer.Bytes()))
			packetBuffer.Release()
			packetBuffer = newPacketBuffer
		}
		packetLength := packetBuffer.Len()
		binary.BigEndian.PutUint16(packetBuffer.ExtendHeader(streamPacketLengthSize), uint16(packetLength))
		writeBuffers = append(writeBuffers, packetBuffer)
		frames = append(frames, packetBuffer.Bytes())
		frameLengths = append(frameLengths, streamPacketLengthSize+packetLength)
		framePacketIndexes = append(framePacketIndexes, i)
	}
	buf.ReleaseMulti(packetBuffers[packetCount:])
	if len(frames) == 0 {
		return packetCount, validationErr
	}
	writtenPackets, writeErr := c.writeFramesLocked(frames, frameLengths, framePacketIndexes, packetCount)
	buf.ReleaseMulti(writeBuffers)
	if writeErr != nil {
		return writtenPackets, writeErr
	}
	return writtenPackets, validationErr
}

// Upstream link_socket_write_tcp (socket.c) prepends the encapsulated length and
// hands the whole frame to one send, so a frame it begins is a frame it finishes.
// stream_buf_added on the peer completes the body the prefix announced from
// whatever arrives next and takes the next length from wherever that body ends,
// so bytes that stop inside a frame are completed there from the packet written
// behind them and every length the peer reads afterwards comes from the middle of
// a packet: it authenticates and drops what it decodes until one of those lengths
// falls outside its buffer and ends the connection as a link error.  Nothing can
// finish the frame once the socket has failed, so the link ends with it here,
// while bytes that stopped on a frame boundary leave the peer aligned and cost it
// only the packets that never left -- what a refused write costs upstream.
func (c *streamPacketConnection) writeFramesLocked(frames net.Buffers, frameLengths []int, framePacketIndexes []int, packetCount int) (int, error) {
	totalLength := 0
	for _, frameLength := range frameLengths {
		totalLength += frameLength
	}
	if !c.vectorisedWrites && len(frames) > 1 {
		packetBatch := make([]byte, 0, totalLength)
		for _, frame := range frames {
			packetBatch = append(packetBatch, frame...)
		}
		frames = net.Buffers{packetBatch}
	}
	writtenLength, writeErr := frames.WriteTo(c.connection)
	writtenBytes := int(writtenLength)
	if writeErr == nil && writtenBytes < totalLength {
		writeErr = io.ErrShortWrite
	}
	if writeErr == nil {
		return packetCount, nil
	}
	writtenFrames := 0
	framedBytes := 0
	for _, frameLength := range frameLengths {
		if framedBytes+frameLength > writtenBytes {
			break
		}
		framedBytes += frameLength
		writtenFrames++
	}
	if framedBytes < writtenBytes {
		writeErr = E.Errors(writeErr, c.connection.Close())
	}
	if writtenFrames == len(frameLengths) {
		return packetCount, writeErr
	}
	return framePacketIndexes[writtenFrames], writeErr
}

func (c *streamPacketConnection) SetReadDeadline(deadline time.Time) error {
	return c.connection.SetReadDeadline(deadline)
}

func (c *streamPacketConnection) ConnectionOriented() bool {
	return true
}

func (c *streamPacketConnection) Close() error {
	return c.connection.Close()
}

func (c *streamPacketConnection) LocalAddr() net.Addr {
	return c.connection.LocalAddr()
}

func (c *streamPacketConnection) RemoteAddr() net.Addr {
	return c.connection.RemoteAddr()
}

// Upstream process_outgoing_link (forward.c) hands the link_socket_write result
// to check_status, which only logs it: a datagram the link refuses is dropped
// and the socket, the key state and the session all stay up.
type datagramPacketConnection struct {
	connection  net.Conn
	readAccess  sync.Mutex
	batchReader N.ConnectedPacketBatchReadWaiter
	batchWriter N.ConnectedPacketBatchWriter
}

func (c *datagramPacketConnection) ReadPacket() ([]byte, error) {
	c.readAccess.Lock()
	defer c.readAccess.Unlock()
	return c.readPacket()
}

func (c *datagramPacketConnection) readPacket() ([]byte, error) {
	packetBuffer := make([]byte, math.MaxUint16)
	packetLength, err := c.connection.Read(packetBuffer)
	if err != nil {
		return nil, err
	}
	packet := make([]byte, packetLength)
	copy(packet, packetBuffer[:packetLength])
	return packet, nil
}

func (c *datagramPacketConnection) ReadPackets() ([]*buf.Buffer, error) {
	c.readAccess.Lock()
	defer c.readAccess.Unlock()
	if c.batchReader != nil {
		packetBuffers, _, err := c.batchReader.WaitReadConnectedPackets()
		return packetBuffers, err
	}
	packet, err := c.readPacket()
	if err != nil {
		return nil, err
	}
	return []*buf.Buffer{buf.As(packet)}, nil
}

func (c *datagramPacketConnection) WritePacket(packet []byte) error {
	_, err := c.WritePackets([][]byte{packet})
	return err
}

func (c *datagramPacketConnection) WritePackets(packets [][]byte) (int, error) {
	packetCount := len(packets)
	var validationErr error
	for i, packet := range packets {
		if len(packet) > math.MaxUint16 {
			packetCount = i
			validationErr = ErrPacketTooLarge
			break
		}
	}
	if packetCount == 0 {
		return 0, validationErr
	}
	if c.batchWriter != nil {
		packetBuffers := make([]*buf.Buffer, packetCount)
		for i, packet := range packets[:packetCount] {
			packetBuffers[i] = buf.As(packet)
		}
		err := c.batchWriter.WriteConnectedPacketBatch(packetBuffers)
		if err != nil {
			return 0, err
		}
		return packetCount, validationErr
	}
	for i, packet := range packets[:packetCount] {
		_, err := c.connection.Write(packet)
		if err != nil {
			return i, err
		}
	}
	return packetCount, validationErr
}

func (c *datagramPacketConnection) WritePacketBuffers(packetBuffers []*buf.Buffer) (int, error) {
	packetCount := len(packetBuffers)
	var validationErr error
	for i, packetBuffer := range packetBuffers {
		if packetBuffer.Len() > math.MaxUint16 {
			packetCount = i
			validationErr = ErrPacketTooLarge
			break
		}
	}
	if packetCount == 0 {
		buf.ReleaseMulti(packetBuffers)
		return 0, validationErr
	}
	writeBuffers := packetBuffers[:packetCount]
	buf.ReleaseMulti(packetBuffers[packetCount:])
	if c.batchWriter != nil {
		err := c.batchWriter.WriteConnectedPacketBatch(writeBuffers)
		if err != nil {
			return 0, err
		}
		return packetCount, validationErr
	}
	for i, packetBuffer := range writeBuffers {
		_, err := c.connection.Write(packetBuffer.Bytes())
		packetBuffer.Release()
		if err != nil {
			buf.ReleaseMulti(writeBuffers[i+1:])
			return i, err
		}
	}
	return packetCount, validationErr
}

func (c *datagramPacketConnection) SetReadDeadline(deadline time.Time) error {
	return c.connection.SetReadDeadline(deadline)
}

func (c *datagramPacketConnection) ConnectionOriented() bool {
	return false
}

func (c *datagramPacketConnection) Close() error {
	return c.connection.Close()
}

func (c *datagramPacketConnection) LocalAddr() net.Addr {
	return c.connection.LocalAddr()
}

func (c *datagramPacketConnection) RemoteAddr() net.Addr {
	return c.connection.RemoteAddr()
}
