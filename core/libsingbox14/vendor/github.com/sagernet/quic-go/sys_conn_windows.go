//go:build windows

package quic

import (
	"net"
	"net/netip"
	"syscall"

	"golang.org/x/sys/windows"
)

func newConn(pc net.PacketConn, sysConn syscall.RawConn, supportsDF bool) (*basicConn, error) {
	return &basicConn{PacketConn: pc, supportsDF: supportsDF}, nil
}

func newConnectedConn(c net.Conn, sysConn syscall.RawConn, supportsDF bool) (*basicConnectedConn, error) {
	return &basicConnectedConn{Conn: c, remoteAddr: c.RemoteAddr(), supportsDF: supportsDF}, nil
}

// x/sys/windows does not define SO_TYPE (winsock2.h).
const _SO_TYPE = 0x1008

func isDatagramSocket(c syscall.RawConn) bool {
	var socketType int
	var serr error
	err := c.Control(func(fd uintptr) {
		socketType, serr = windows.GetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, _SO_TYPE)
	})
	return err == nil && serr == nil && socketType == windows.SOCK_DGRAM
}

func setReadBufferSize(c syscall.RawConn, bytes int) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_RCVBUF, bytes)
	})
	if err != nil {
		return err
	}
	return serr
}

func setWriteBufferSize(c syscall.RawConn, bytes int) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		serr = windows.SetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_SNDBUF, bytes)
	})
	if err != nil {
		return err
	}
	return serr
}

func inspectReadBuffer(c syscall.RawConn) (int, error) {
	var size int
	var serr error
	if err := c.Control(func(fd uintptr) {
		size, serr = windows.GetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_RCVBUF)
	}); err != nil {
		return 0, err
	}
	return size, serr
}

func inspectWriteBuffer(c syscall.RawConn) (int, error) {
	var size int
	var serr error
	if err := c.Control(func(fd uintptr) {
		size, serr = windows.GetsockoptInt(windows.Handle(fd), windows.SOL_SOCKET, windows.SO_SNDBUF)
	}); err != nil {
		return 0, err
	}
	return size, serr
}

type packetInfo struct {
	addr netip.Addr
}

func (i *packetInfo) OOB() []byte { return nil }
