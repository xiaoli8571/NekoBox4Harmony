package quic

import (
	"io"
	"net"
	"syscall"
	"time"

	"github.com/sagernet/quic-go/internal/monotime"
	"github.com/sagernet/quic-go/internal/protocol"
	"github.com/sagernet/quic-go/internal/utils"
)

type connCapabilities struct {
	// This connection has the Don't Fragment (DF) bit set.
	// This means it makes to run DPLPMTUD.
	DF bool
	// GSO (Generic Segmentation Offload) supported
	GSO bool
	// ECN (Explicit Congestion Notifications) supported
	ECN bool
}

// rawConn is a connection that allow reading of a receivedPackeh.
type rawConn interface {
	ReadPacket() (receivedPacket, error)
	// WritePacket writes a packet on the wire.
	// gsoSize is the size of a single packet, or 0 to disable GSO.
	// It is invalid to set gsoSize if capabilities.GSO is not set.
	WritePacket(b []byte, addr net.Addr, packetInfoOOB []byte, gsoSize uint16, ecn protocol.ECN) (int, error)
	LocalAddr() net.Addr
	SetReadDeadline(time.Time) error
	io.Closer

	capabilities() connCapabilities
}

// OOBCapablePacketConn is a connection that allows the reading of ECN bits from the IP header.
//
// Deprecated: all optimizations are now driven by the file descriptor alone; a conn only needs
// to implement syscall.Conn to enable them.
type OOBCapablePacketConn interface {
	net.PacketConn
	SyscallConn() (syscall.RawConn, error)
	SetReadBuffer(int) error
	ReadMsgUDP(b, oob []byte) (n, oobn, flags int, addr *net.UDPAddr, err error)
	WriteMsgUDP(b, oob []byte, addr *net.UDPAddr) (n, oobn int, err error)
}

var _ OOBCapablePacketConn = &net.UDPConn{}

// IOActivityConn is implemented by conns passed to the Transport that observe their own I/O.
// On the optimized path, reads and writes go through the file descriptor and bypass the conn's
// own methods; these callbacks are invoked instead, once per syscall: onRead with the size of
// the first packet of a received batch, onWrite with the size of the whole send buffer.
type IOActivityConn interface {
	IOActivityFuncs() (onRead func(size int), onWrite func(size int))
}

func wrapConn(pc net.PacketConn) (rawConn, error) {
	var sysConn syscall.RawConn
	syscallConn, isSyscallConn := pc.(syscall.Conn)
	if isSyscallConn {
		var err error
		sysConn, err = syscallConn.SyscallConn()
		if err != nil {
			sysConn = nil
		}
	}
	if sysConn == nil {
		utils.DefaultLogger.Infof("PacketConn is not a syscall.Conn. Disabling optimizations possible on UDP connections.")
		// Assume DF is set so that DPLPMTUD keeps working; the socket behind a
		// non-syscall conn is expected to have been configured by its owner.
		return &basicConn{PacketConn: pc, supportsDF: true}, nil
	}
	_ = setReceiveBuffer(sysConn)
	_ = setSendBuffer(sysConn)
	supportsDF := true
	if isDatagramSocket(sysConn) {
		var err error
		supportsDF, err = setDF(sysConn)
		if err != nil {
			return nil, err
		}
	}
	conn, err := newConn(pc, sysConn, supportsDF)
	if err != nil {
		utils.DefaultLogger.Infof("Failed to enable receive optimizations on the socket: %s. Disabling optimizations possible on UDP connections.", err)
		return &basicConn{PacketConn: pc, supportsDF: supportsDF}, nil
	}
	return conn, nil
}

// wrapNetConn is the counterpart of wrapConn for a connected packet-oriented net.Conn,
// as passed to [DialConn] and [DialEarlyConn].
func wrapNetConn(c net.Conn) (rawConn, error) {
	var sysConn syscall.RawConn
	syscallConn, isSyscallConn := c.(syscall.Conn)
	if isSyscallConn {
		var err error
		sysConn, err = syscallConn.SyscallConn()
		if err != nil {
			sysConn = nil
		}
	}
	if sysConn == nil {
		utils.DefaultLogger.Infof("Conn is not a syscall.Conn. Disabling optimizations possible on UDP connections.")
		// Assume DF is set so that DPLPMTUD keeps working; the socket behind a
		// non-syscall conn is expected to have been configured by its owner.
		return &basicConnectedConn{Conn: c, remoteAddr: c.RemoteAddr(), supportsDF: true}, nil
	}
	_ = setReceiveBuffer(sysConn)
	_ = setSendBuffer(sysConn)
	supportsDF := true
	if isDatagramSocket(sysConn) {
		var err error
		supportsDF, err = setDF(sysConn)
		if err != nil {
			return nil, err
		}
	}
	conn, err := newConnectedConn(c, sysConn, supportsDF)
	if err != nil {
		utils.DefaultLogger.Infof("Failed to enable receive optimizations on the socket: %s. Disabling optimizations possible on UDP connections.", err)
		return &basicConnectedConn{Conn: c, remoteAddr: c.RemoteAddr(), supportsDF: supportsDF}, nil
	}
	return conn, nil
}

// The basicConn is the most trivial implementation of a rawConn.
// It reads a single packet from the underlying net.PacketConn.
// It is used when
// * the net.PacketConn is not a OOBCapablePacketConn, and
// * when the OS doesn't support OOB.
type basicConn struct {
	net.PacketConn
	supportsDF bool
}

var _ rawConn = &basicConn{}

func (c *basicConn) ReadPacket() (receivedPacket, error) {
	buffer := getPacketBuffer()
	// The packet size should not exceed protocol.MaxPacketBufferSize bytes
	// If it does, we only read a truncated packet, which will then end up undecryptable
	buffer.Data = buffer.Data[:protocol.MaxPacketBufferSize]
	n, addr, err := c.ReadFrom(buffer.Data)
	if err != nil {
		buffer.Release()
		return receivedPacket{}, err
	}
	return receivedPacket{
		remoteAddr: addr,
		rcvTime:    monotime.Now(),
		data:       buffer.Data[:n],
		buffer:     buffer,
	}, nil
}

func (c *basicConn) WritePacket(b []byte, addr net.Addr, _ []byte, gsoSize uint16, ecn protocol.ECN) (n int, err error) {
	if gsoSize != 0 {
		panic("cannot use GSO with a basicConn")
	}
	if ecn != protocol.ECNUnsupported {
		panic("cannot use ECN with a basicConn")
	}
	return c.WriteTo(b, addr)
}

func (c *basicConn) capabilities() connCapabilities { return connCapabilities{DF: c.supportsDF} }

// The basicConnectedConn is the rawConn for a connected conn whose file descriptor is not
// accessible. The remote address is fixed, so packets go through net.Conn's Read and Write.
type basicConnectedConn struct {
	net.Conn
	remoteAddr net.Addr
	supportsDF bool
}

var _ rawConn = &basicConnectedConn{}

func (c *basicConnectedConn) ReadPacket() (receivedPacket, error) {
	buffer := getPacketBuffer()
	// The packet size should not exceed protocol.MaxPacketBufferSize bytes
	// If it does, we only read a truncated packet, which will then end up undecryptable
	buffer.Data = buffer.Data[:protocol.MaxPacketBufferSize]
	n, err := c.Read(buffer.Data)
	if err != nil {
		buffer.Release()
		return receivedPacket{}, err
	}
	return receivedPacket{
		remoteAddr: c.remoteAddr,
		rcvTime:    monotime.Now(),
		data:       buffer.Data[:n],
		buffer:     buffer,
	}, nil
}

func (c *basicConnectedConn) WritePacket(b []byte, _ net.Addr, _ []byte, gsoSize uint16, ecn protocol.ECN) (int, error) {
	if gsoSize != 0 {
		panic("cannot use GSO with a basicConnectedConn")
	}
	if ecn != protocol.ECNUnsupported {
		panic("cannot use ECN with a basicConnectedConn")
	}
	return c.Write(b)
}

func (c *basicConnectedConn) ReadFrom(p []byte) (int, net.Addr, error) {
	n, err := c.Read(p)
	if err != nil {
		return n, nil, err
	}
	return n, c.remoteAddr, nil
}

func (c *basicConnectedConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	return c.Write(p)
}

func (c *basicConnectedConn) capabilities() connCapabilities {
	return connCapabilities{DF: c.supportsDF}
}
