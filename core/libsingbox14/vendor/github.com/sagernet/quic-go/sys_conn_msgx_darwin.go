//go:build darwin

package quic

import (
	"io"
	"net"
	"net/netip"
	"os"
	"strconv"
	"sync"
	"syscall"
	"unsafe"

	"github.com/sagernet/quic-go/internal/protocol"
	"golang.org/x/net/ipv4"
	"golang.org/x/sys/unix"
)

const batchSize = 8

// msghdrX mirrors XNU's struct msghdr_x (bsd/sys/socket_private.h): a struct msghdr followed
// by the size_t that recvmsg_x reports the received length in. Go's Msghdr carries the same
// trailing padding as the C struct, so DataLen lands at offset 48 either way.
type msghdrX struct {
	Msg     unix.Msghdr
	DataLen uint64
}

// An unimplemented syscall number answers ENOSYS; a count of zero is rejected with EINVAL
// before Sequoia and accepted as a no-op after, so only ENOSYS tells the two apart.
func isMsgXAvailable(rawConn syscall.RawConn) bool {
	var errno unix.Errno
	err := rawConn.Control(func(fd uintptr) {
		//nolint:staticcheck
		_, _, errno = unix.RawSyscall6(unix.SYS_SENDMSG_X, fd, 0, 0, 0, 0, 0)
	})
	return err == nil && errno != unix.ENOSYS
}

// The GSO capability here means the send path accepts a multi-segment buffer, which sendmsg_x
// serves by sending its segments as a batch of datagrams; darwin has no kernel offload.
func isGSOEnabled(rawConn syscall.RawConn, connected bool) bool {
	disabled, err := strconv.ParseBool(os.Getenv("QUIC_GO_DISABLE_GSO"))
	if err == nil && disabled {
		return false
	}
	if msgxRequiresConnectedSocket && !connected {
		return false
	}
	return isMsgXAvailable(rawConn)
}

type msgXReader struct {
	rawConn   syscall.RawConn
	connected bool
	hdrs      []msghdrX
	iovs      []unix.Iovec
	names     []unix.RawSockaddrInet6
}

func newBatchReader(rawConn syscall.RawConn, connected bool) batchConn {
	if msgxRequiresConnectedSocket && !connected {
		return nil
	}
	if !isMsgXAvailable(rawConn) {
		return nil
	}
	return &msgXReader{
		rawConn:   rawConn,
		connected: connected,
		hdrs:      make([]msghdrX, batchSize),
		iovs:      make([]unix.Iovec, batchSize),
		names:     make([]unix.RawSockaddrInet6, batchSize),
	}
}

func (r *msgXReader) ReadBatch(ms []ipv4.Message, _ int) (int, error) {
	count := min(len(ms), len(r.hdrs))
	if count == 0 {
		return 0, nil
	}
	for i := range count {
		buffer := ms[i].Buffers[0]
		r.iovs[i] = unix.Iovec{Base: &buffer[0]}
		r.iovs[i].SetLen(len(buffer))
		r.hdrs[i] = msghdrX{}
		r.hdrs[i].Msg.Iov = &r.iovs[i]
		r.hdrs[i].Msg.Iovlen = 1
		if !r.connected {
			r.hdrs[i].Msg.Name = (*byte)(unsafe.Pointer(&r.names[i]))
			r.hdrs[i].Msg.Namelen = unix.SizeofSockaddrInet6
		}
		if oob := ms[i].OOB; len(oob) > 0 {
			r.hdrs[i].Msg.Control = &oob[0]
			r.hdrs[i].Msg.SetControllen(len(oob))
		}
	}
	var (
		n     uintptr
		errno unix.Errno
	)
	err := r.rawConn.Read(func(fd uintptr) bool {
		for {
			//nolint:staticcheck
			n, _, errno = unix.RawSyscall6(unix.SYS_RECVMSG_X, fd,
				uintptr(unsafe.Pointer(&r.hdrs[0])), uintptr(count), unix.MSG_DONTWAIT, 0, 0)
			if errno == unix.EINTR {
				continue
			}
			return errno != unix.EAGAIN
		}
	})
	if err != nil {
		return 0, err
	}
	if errno != 0 {
		return 0, os.NewSyscallError("recvmsg_x", errno)
	}
	numMsgs := int(n)
	for i := range numMsgs {
		ms[i].N = int(r.hdrs[i].DataLen)
		ms[i].NN = int(r.hdrs[i].Msg.Controllen)
		ms[i].Flags = int(r.hdrs[i].Msg.Flags)
		if r.connected {
			ms[i].Addr = nil
			continue
		}
		ms[i].Addr = udpAddrFromRawSockaddr(&r.names[i])
	}
	return numMsgs, nil
}

func udpAddrFromRawSockaddr(name *unix.RawSockaddrInet6) *net.UDPAddr {
	if name.Family == unix.AF_INET {
		name4 := (*unix.RawSockaddrInet4)(unsafe.Pointer(name))
		return &net.UDPAddr{
			IP:   netip.AddrFrom4(name4.Addr).AsSlice(),
			Port: portFromRawSockaddr(&name4.Port),
		}
	}
	return &net.UDPAddr{
		IP:   netip.AddrFrom16(name.Addr).AsSlice(),
		Port: portFromRawSockaddr(&name.Port),
		Zone: interfaceZone(name.Scope_id),
	}
}

func portFromRawSockaddr(port *uint16) int {
	portBytes := (*[2]byte)(unsafe.Pointer(port))
	return int(portBytes[0])<<8 | int(portBytes[1])
}

var interfaceZones sync.Map // uint32 -> string

func interfaceZone(index uint32) string {
	if index == 0 {
		return ""
	}
	cached, loaded := interfaceZones.Load(index)
	if loaded {
		return cached.(string)
	}
	zone := strconv.FormatUint(uint64(index), 10)
	iface, err := net.InterfaceByIndex(int(index))
	if err == nil {
		zone = iface.Name
	}
	interfaceZones.Store(index, zone)
	return zone
}

type msgXWriter struct {
	rawConn syscall.RawConn
}

func newSegmentWriter(rawConn syscall.RawConn) segmentWriter {
	return &msgXWriter{rawConn: rawConn}
}

type msgXWriteState struct {
	hdrs     []msghdrX
	iovs     []unix.Iovec
	storage4 unix.RawSockaddrInet4
	storage6 unix.RawSockaddrInet6
}

var msgXWritePool = sync.Pool{New: func() any {
	const segments = protocol.MaxLargePacketBufferSize/protocol.MinInitialPacketSize + 1
	return &msgXWriteState{
		hdrs: make([]msghdrX, segments),
		iovs: make([]unix.Iovec, segments),
	}
}}

func (w *msgXWriter) WriteSegments(b []byte, segmentSize int, sockaddr unix.Sockaddr, oob []byte) (int, error) {
	count := (len(b) + segmentSize - 1) / segmentSize
	state := msgXWritePool.Get().(*msgXWriteState)
	defer msgXWritePool.Put(state)
	if cap(state.hdrs) < count {
		state.hdrs = make([]msghdrX, count)
		state.iovs = make([]unix.Iovec, count)
	}
	hdrs := state.hdrs[:count]
	iovs := state.iovs[:count]
	var (
		name    *byte
		nameLen uint32
	)
	switch sa := sockaddr.(type) {
	case *unix.SockaddrInet4:
		state.storage4 = unix.RawSockaddrInet4{
			Len:    unix.SizeofSockaddrInet4,
			Family: unix.AF_INET,
			Addr:   sa.Addr,
		}
		setRawSockaddrPort(&state.storage4.Port, sa.Port)
		name = (*byte)(unsafe.Pointer(&state.storage4))
		nameLen = unix.SizeofSockaddrInet4
	case *unix.SockaddrInet6:
		state.storage6 = unix.RawSockaddrInet6{
			Len:      unix.SizeofSockaddrInet6,
			Family:   unix.AF_INET6,
			Addr:     sa.Addr,
			Scope_id: sa.ZoneId,
		}
		setRawSockaddrPort(&state.storage6.Port, sa.Port)
		name = (*byte)(unsafe.Pointer(&state.storage6))
		nameLen = unix.SizeofSockaddrInet6
	}
	for i := range count {
		segment := b[i*segmentSize : min((i+1)*segmentSize, len(b))]
		iovs[i] = unix.Iovec{Base: &segment[0]}
		iovs[i].SetLen(len(segment))
		hdrs[i] = msghdrX{}
		hdrs[i].Msg.Name = name
		hdrs[i].Msg.Namelen = nameLen
		hdrs[i].Msg.Iov = &iovs[i]
		hdrs[i].Msg.Iovlen = 1
		if len(oob) > 0 {
			hdrs[i].Msg.Control = &oob[0]
			hdrs[i].Msg.SetControllen(len(oob))
		}
	}
	var (
		sent    int
		sendErr unix.Errno
	)
	// The kernel stops at the first message it cannot send. It reports the number of messages
	// it did send and leaves the error behind unless that number is zero, so resuming at sent
	// is what surfaces the error.
	err := w.rawConn.Write(func(fd uintptr) bool {
		for sent < count {
			//nolint:staticcheck
			n, _, errno := unix.RawSyscall6(unix.SYS_SENDMSG_X, fd,
				uintptr(unsafe.Pointer(&hdrs[sent])), uintptr(count-sent), 0, 0, 0)
			switch {
			case errno == unix.EINTR:
			case errno == unix.EAGAIN:
				return false
			case errno != 0:
				sendErr = errno
				return true
			case n == 0:
				return true
			default:
				sent += int(n)
			}
		}
		return true
	})
	written := min(sent*segmentSize, len(b))
	if err != nil {
		return written, err
	}
	if sendErr != 0 {
		return written, os.NewSyscallError("sendmsg_x", sendErr)
	}
	if sent < count {
		return written, io.ErrShortWrite
	}
	return written, nil
}

func setRawSockaddrPort(rawPort *uint16, port int) {
	portBytes := (*[2]byte)(unsafe.Pointer(rawPort))
	portBytes[0] = byte(port >> 8)
	portBytes[1] = byte(port)
}
