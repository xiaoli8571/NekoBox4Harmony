package openvpn

import (
	"net"
	"os"
	"sync"
	"time"

	"github.com/sagernet/sing/common/buf"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

// One listener carries every peer of the server, so nothing a single peer
// decides may reach it: a deadline armed for one peer's write would bound the
// writes of all the others and outlive the write it was meant for.
type udpPacketWriter struct {
	listener     net.PacketConn
	batchWriter  N.PacketBatchWriter
	destinations []M.Socksaddr
	writeAccess  sync.Mutex
}

type udpPeerPacketConnection struct {
	writer          *udpPacketWriter
	localAddress    net.Addr
	remoteAccess    sync.RWMutex
	remoteAddress   net.Addr
	readAddress     net.Addr
	readAccess      sync.Mutex
	incomingAccess  sync.Mutex
	incomingPackets *dataPacketQueue[udpPeerPacket]
	closeOnce       sync.Once
	closed          chan struct{}
	deadlineAccess  sync.Mutex
	readDeadline    time.Time
}

type udpPeerPacket struct {
	buffer        *buf.Buffer
	remoteAddress net.Addr
}

func (c *udpPeerPacketConnection) ReadPacket() ([]byte, error) {
	c.readAccess.Lock()
	defer c.readAccess.Unlock()
	packets, err := c.waitIncomingPackets(1)
	if err != nil {
		return nil, err
	}
	packet := packets[0]
	c.setReadAddress(packet.remoteAddress)
	payload := append([]byte{}, packet.buffer.Bytes()...)
	packet.buffer.Release()
	packets[0].buffer = nil
	return payload, nil
}

func (c *udpPeerPacketConnection) waitIncomingPackets(maxPackets int) ([]udpPeerPacket, error) {
	for {
		readDeadline, hasDeadline := c.currentReadDeadline()
		var timeout time.Duration
		if hasDeadline {
			timeout = time.Until(readDeadline)
			if timeout <= 0 {
				return nil, os.ErrDeadlineExceeded
			}
		}
		select {
		case <-c.closed:
			return nil, net.ErrClosed
		default:
		}
		packets := c.incomingPackets.Pop(maxPackets, func(firstPacket udpPeerPacket, packet udpPeerPacket) bool {
			return equalPacketSource(firstPacket.remoteAddress, packet.remoteAddress)
		})
		if len(packets) > 0 {
			return packets, nil
		}
		if hasDeadline {
			timer := time.NewTimer(timeout)
			select {
			case <-c.incomingPackets.Wake():
				timer.Stop()
			case <-c.closed:
				timer.Stop()
				return nil, net.ErrClosed
			case <-timer.C:
				return nil, os.ErrDeadlineExceeded
			}
			continue
		}
		select {
		case <-c.incomingPackets.Wake():
		case <-c.closed:
			return nil, net.ErrClosed
		}
	}
}

func (c *udpPeerPacketConnection) ReadPackets() ([]*buf.Buffer, error) {
	c.readAccess.Lock()
	defer c.readAccess.Unlock()
	packets, err := c.waitIncomingPackets(dataPacketBatchSize)
	if err != nil {
		return nil, err
	}
	c.setReadAddress(packets[0].remoteAddress)
	packetBuffers := make([]*buf.Buffer, len(packets))
	for i := range packets {
		packetBuffers[i] = packets[i].buffer
	}
	return packetBuffers, nil
}

func (c *udpPeerPacketConnection) WritePacket(packet []byte) error {
	_, err := c.WritePackets([][]byte{packet})
	return err
}

func (c *udpPeerPacketConnection) WritePackets(packets [][]byte) (int, error) {
	return c.writer.writePackets(c, packets)
}

func (c *udpPeerPacketConnection) WritePacketBuffers(packetBuffers []*buf.Buffer) (int, error) {
	return c.writer.writePacketBuffers(c, packetBuffers)
}

func (c *udpPeerPacketConnection) SetReadDeadline(deadline time.Time) error {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	c.readDeadline = deadline
	return nil
}

func (c *udpPeerPacketConnection) ConnectionOriented() bool {
	return false
}

func (c *udpPeerPacketConnection) Close() error {
	c.closeOnce.Do(func() {
		c.incomingAccess.Lock()
		close(c.closed)
		c.incomingPackets.Drain(func(packet udpPeerPacket) {
			packet.buffer.Release()
		})
		c.incomingAccess.Unlock()
	})
	return nil
}

func (c *udpPeerPacketConnection) LocalAddr() net.Addr {
	return c.localAddress
}

func (c *udpPeerPacketConnection) RemoteAddr() net.Addr {
	c.remoteAccess.RLock()
	defer c.remoteAccess.RUnlock()
	return c.remoteAddress
}

func (c *udpPeerPacketConnection) pushPackets(packets []udpPeerPacket) uint64 {
	if len(packets) == 0 {
		return 0
	}
	releasePacket := func(packet udpPeerPacket) {
		packet.buffer.Release()
	}
	c.incomingAccess.Lock()
	defer c.incomingAccess.Unlock()
	select {
	case <-c.closed:
		for _, packet := range packets {
			releasePacket(packet)
		}
		return uint64(len(packets))
	default:
	}
	return c.incomingPackets.PushBatchDropNew(packets, releasePacket)
}

func (c *udpPeerPacketConnection) setReadAddress(remoteAddress net.Addr) {
	c.remoteAccess.Lock()
	c.readAddress = remoteAddress
	c.remoteAccess.Unlock()
}

func (c *udpPeerPacketConnection) floatCandidateAddress() net.Addr {
	c.remoteAccess.RLock()
	defer c.remoteAccess.RUnlock()
	if c.readAddress == nil || equalPacketSource(c.readAddress, c.remoteAddress) {
		return nil
	}
	return c.readAddress
}

func equalPacketSource(left net.Addr, right net.Addr) bool {
	if left == nil || right == nil {
		return left == right
	}
	leftUDP, leftIsUDP := left.(*net.UDPAddr)
	rightUDP, rightIsUDP := right.(*net.UDPAddr)
	if leftIsUDP && rightIsUDP {
		return leftUDP.Port == rightUDP.Port && leftUDP.Zone == rightUDP.Zone && leftUDP.IP.Equal(rightUDP.IP)
	}
	return left.Network() == right.Network() && left.String() == right.String()
}

func (c *udpPeerPacketConnection) setRemoteAddress(remoteAddress net.Addr) {
	c.remoteAccess.Lock()
	c.remoteAddress = remoteAddress
	c.remoteAccess.Unlock()
}

func (c *udpPeerPacketConnection) currentReadDeadline() (time.Time, bool) {
	c.deadlineAccess.Lock()
	defer c.deadlineAccess.Unlock()
	return c.readDeadline, !c.readDeadline.IsZero()
}

func (w *udpPacketWriter) writePackets(peer *udpPeerPacketConnection, packets [][]byte) (int, error) {
	w.writeAccess.Lock()
	defer w.writeAccess.Unlock()
	remoteAddress := peer.RemoteAddr()
	if remoteAddress == nil {
		return 0, net.ErrClosed
	}
	if w.batchWriter != nil && len(packets) > 0 {
		packetBuffers := make([]*buf.Buffer, len(packets))
		destination := M.SocksaddrFromNet(remoteAddress)
		destinations := make([]M.Socksaddr, len(packets))
		for i, packet := range packets {
			packetBuffers[i] = buf.As(packet)
			destinations[i] = destination
		}
		writeErr := w.batchWriter.WritePacketBatch(packetBuffers, destinations)
		if writeErr != nil {
			return 0, writeErr
		}
		return len(packets), nil
	}
	for i, packet := range packets {
		_, writeErr := w.listener.WriteTo(packet, remoteAddress)
		if writeErr != nil {
			return i, writeErr
		}
	}
	return len(packets), nil
}

func (w *udpPacketWriter) writePacketBuffers(peer *udpPeerPacketConnection, packetBuffers []*buf.Buffer) (int, error) {
	w.writeAccess.Lock()
	defer w.writeAccess.Unlock()
	remoteAddress := peer.RemoteAddr()
	if remoteAddress == nil {
		buf.ReleaseMulti(packetBuffers)
		return 0, net.ErrClosed
	}
	if w.batchWriter != nil && len(packetBuffers) > 0 {
		destination := M.SocksaddrFromNet(remoteAddress)
		destinations := w.destinations
		if cap(destinations) < len(packetBuffers) {
			destinations = make([]M.Socksaddr, len(packetBuffers))
		} else {
			destinations = destinations[:len(packetBuffers)]
		}
		for i := range destinations {
			destinations[i] = destination
		}
		writeErr := w.batchWriter.WritePacketBatch(packetBuffers, destinations)
		clear(destinations)
		w.destinations = destinations[:0]
		if writeErr != nil {
			return 0, writeErr
		}
		return len(packetBuffers), nil
	}
	for i, packetBuffer := range packetBuffers {
		_, writeErr := w.listener.WriteTo(packetBuffer.Bytes(), remoteAddress)
		packetBuffer.Release()
		if writeErr != nil {
			buf.ReleaseMulti(packetBuffers[i+1:])
			return i, writeErr
		}
	}
	return len(packetBuffers), nil
}

func (w *udpPacketWriter) writePacketTo(packet []byte, remoteAddress net.Addr) error {
	if remoteAddress == nil {
		return net.ErrClosed
	}
	w.writeAccess.Lock()
	defer w.writeAccess.Unlock()
	_, writeErr := w.listener.WriteTo(packet, remoteAddress)
	return writeErr
}
