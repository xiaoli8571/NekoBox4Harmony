// On iOS both directions misbehave in the Network Extension (recvmsg_x on
// unconnected UDP sockets delivers no data, connected sockets stop passing
// traffic after a rebind), so msgx is macOS only until it can be debugged
// on a device.

//go:build darwin && !ios

package conn

import (
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"

	M "github.com/sagernet/sing/common/metadata"
	"golang.org/x/net/ipv6"
	"golang.org/x/sys/unix"
)

const supportsMsgX = true

const msgXBatchSize = IdealBatchSize

// msghdrX mirrors XNU's struct msghdr_x used by sendmsg_x/recvmsg_x.
// The "no support for address or ancillary data" comment in uipc_syscalls.c
// has been stale since 10.11, which replaced the EINVAL with a fall back to a
// per-message sendit(); msg_name has been honoured ever since, as has the
// per-message source address recvmsg_x fills in (copyout_maddr). A connected
// socket is still worth having: only then does sendmsg_x reach the kernel's
// batched send path (sendit_x -> sosend_list, Sequoia and later), which is
// worth about 2.7x over carrying an address per message. utun cannot use the
// send side at all (no ctl_send_list in if_utun.c).
type msghdrX struct {
	Msg     unix.Msghdr
	DataLen uint32
}

type msgXState struct {
	singlePeer  atomic.Bool
	disabled    atomic.Bool // permanent fallback to the generic paths
	connected4  atomic.Bool
	connected6  atomic.Bool
	endpoint    atomic.Pointer[StdNetEndpoint]
	connectLock sync.Mutex
}

// reset clears per-socket state; must be called when the bind (re)opens,
// as the connected state belongs to the previous sockets.
func (m *msgXState) reset() {
	m.disabled.Store(false)
	m.connected4.Store(false)
	m.connected6.Store(false)
	m.endpoint.Store(nil)
}

func (m *msgXState) connectedFlag(isV6 bool) *atomic.Bool {
	if isV6 {
		return &m.connected6
	}
	return &m.connected4
}

// SetSinglePeerMode lets the bind connect its sockets, which is what puts
// sendmsg_x on the kernel's batched send path. Only safe when the bind serves
// exactly one peer with a fixed endpoint: the kernel will drop datagrams from
// any other source, so peer roaming stops working. A second destination turns
// it back off by itself.
func (s *StdNetBind) SetSinglePeerMode() {
	s.msgx.singlePeer.Store(true)
}

// The socket family decides the address family: a v4-mapped destination is
// routed to the v6 socket by Send, and has to stay mapped there.
func sockaddrFromAddrPort(addrPort netip.AddrPort, isV6 bool, storage4 *unix.RawSockaddrInet4, storage6 *unix.RawSockaddrInet6) (*byte, uint32) {
	port := addrPort.Port()<<8 | addrPort.Port()>>8
	if !isV6 {
		*storage4 = unix.RawSockaddrInet4{
			Len:    unix.SizeofSockaddrInet4,
			Family: unix.AF_INET,
			Port:   port,
			Addr:   addrPort.Addr().Unmap().As4(),
		}
		return (*byte)(unsafe.Pointer(storage4)), unix.SizeofSockaddrInet4
	}
	*storage6 = unix.RawSockaddrInet6{
		Len:    unix.SizeofSockaddrInet6,
		Family: unix.AF_INET6,
		Port:   port,
		Addr:   addrPort.Addr().As16(),
	}
	return (*byte)(unsafe.Pointer(storage6)), unix.SizeofSockaddrInet6
}

// ensureConnected connects the family socket to the single peer on first use.
// A false return only means the caller has to address every message itself;
// msgx as a whole is given up on only when the socket is left connected to a
// peer we are no longer sending to.
func (s *StdNetBind) ensureConnected(rawConn syscall.RawConn, isV6 bool, destination netip.AddrPort) bool {
	if !s.msgx.singlePeer.Load() {
		return false
	}
	connected := s.msgx.connectedFlag(isV6)
	if connected.Load() {
		if s.msgx.endpoint.Load().AddrPort == destination {
			return true
		}
		s.msgx.connectLock.Lock()
		defer s.msgx.connectLock.Unlock()
		if !connected.Load() {
			return false
		}
		s.msgx.singlePeer.Store(false)
		var disconnected bool
		controlErr := rawConn.Control(func(fd uintptr) {
			addr := unix.RawSockaddrAny{}
			addr.Addr.Family = unix.AF_UNSPEC
			//nolint:staticcheck
			_, _, _ = unix.Syscall(unix.SYS_CONNECT, fd, uintptr(unsafe.Pointer(&addr)), unix.SizeofSockaddrAny)
			// The association is torn down and EINVAL reported for the address
			// family all the same, so the errno says nothing and only the peer
			// name tells us whether the socket is free again.
			_, peerErr := unix.Getpeername(int(fd))
			disconnected = peerErr == unix.ENOTCONN
		})
		if controlErr != nil || !disconnected {
			s.msgx.disabled.Store(true)
			return false
		}
		connected.Store(false)
		return false
	}
	s.msgx.connectLock.Lock()
	defer s.msgx.connectLock.Unlock()
	if connected.Load() {
		return s.msgx.endpoint.Load().AddrPort == destination
	}
	if !s.msgx.singlePeer.Load() {
		return false
	}
	var (
		storage4   unix.RawSockaddrInet4
		storage6   unix.RawSockaddrInet6
		connectErr unix.Errno
	)
	name, nameLen := sockaddrFromAddrPort(destination, isV6, &storage4, &storage6)
	controlErr := rawConn.Control(func(fd uintptr) {
		//nolint:staticcheck
		_, _, connectErr = unix.Syscall(unix.SYS_CONNECT, fd, uintptr(unsafe.Pointer(name)), uintptr(nameLen))
	})
	if controlErr != nil || connectErr != 0 {
		s.msgx.singlePeer.Store(false)
		return false
	}
	s.msgx.endpoint.Store(&StdNetEndpoint{AddrPort: destination})
	connected.Store(true)
	return true
}

type sendMsgXState struct {
	hdrs     []msghdrX
	iovs     []unix.Iovec
	storage4 unix.RawSockaddrInet4
	storage6 unix.RawSockaddrInet6
}

var sendMsgXPool = sync.Pool{New: func() any {
	return &sendMsgXState{
		hdrs: make([]msghdrX, IdealBatchSize),
		iovs: make([]unix.Iovec, IdealBatchSize),
	}
}}

// sendMsgX sends msgs with a single syscall, over a connected socket when the
// bind has one and by addressing every message otherwise. handled == false
// means nothing was sent and the caller must use the generic path; msgs are
// never partially consumed in that case.
func (s *StdNetBind) sendMsgX(conn *net.UDPConn, msgs []ipv6.Message) (bool, error) {
	var (
		rawConn syscall.RawConn
		isV6    bool
	)
	s.mu.Lock()
	if conn == s.ipv6 {
		rawConn = s.ipv6RC
		isV6 = true
	} else {
		rawConn = s.ipv4RC
	}
	s.mu.Unlock()
	if rawConn == nil || s.msgx.disabled.Load() {
		return false, nil
	}
	destination := M.AddrPortFromNet(msgs[0].Addr)
	state := sendMsgXPool.Get().(*sendMsgXState)
	defer sendMsgXPool.Put(state)
	var (
		name    *byte
		nameLen uint32
	)
	if !s.ensureConnected(rawConn, isV6, destination) {
		if s.msgx.disabled.Load() {
			return false, nil
		}
		name, nameLen = sockaddrFromAddrPort(destination, isV6, &state.storage4, &state.storage6)
	}
	for i := range msgs {
		buffer := msgs[i].Buffers[0]
		state.iovs[i] = unix.Iovec{Base: &buffer[0]}
		state.iovs[i].SetLen(len(buffer))
		state.hdrs[i] = msghdrX{}
		state.hdrs[i].Msg.Name = name
		state.hdrs[i].Msg.Namelen = nameLen
		state.hdrs[i].Msg.Iov = &state.iovs[i]
		state.hdrs[i].Msg.Iovlen = 1
	}
	var sent int
	for sent < len(msgs) {
		var (
			n     uintptr
			errno unix.Errno
		)
		writeErr := rawConn.Write(func(fd uintptr) bool {
			//nolint:staticcheck
			n, _, errno = unix.RawSyscall6(unix.SYS_SENDMSG_X, fd,
				uintptr(unsafe.Pointer(&state.hdrs[sent])), uintptr(len(msgs)-sent), unix.MSG_DONTWAIT, 0, 0)
			return errno != unix.EAGAIN
		})
		if writeErr != nil {
			return true, writeErr
		}
		if errno != 0 {
			if sent == 0 {
				// The syscall is refusing this socket entirely (sandbox,
				// disconnected by the system, ...): disable and let the
				// caller resend everything on the generic path.
				s.msgx.disabled.Store(true)
				return false, nil
			}
			return true, errno
		}
		sent += int(n)
	}
	return true, nil
}

type receiveMsgXState struct {
	hdrs     []msghdrX
	iovs     []unix.Iovec
	names    []unix.RawSockaddrInet6
	fallback bool
}

func (s *StdNetBind) receiveSingle(conn *net.UDPConn, bufs [][]byte, sizes []int, eps []Endpoint) (int, error) {
	n, _, _, addr, err := conn.ReadMsgUDPAddrPort(bufs[0], nil)
	if err != nil {
		return 0, err
	}
	sizes[0] = n
	if n > 3 {
		bufs[0][1] = 0
		bufs[0][2] = 0
		bufs[0][3] = 0
	}
	eps[0] = &StdNetEndpoint{AddrPort: addr}
	return 1, nil
}

func (s *StdNetBind) makeReceiveMsgX(conn *net.UDPConn, isV6 bool) (ReceiveFunc, error) {
	rawConn, err := conn.SyscallConn()
	if err != nil {
		return nil, err
	}
	state := &receiveMsgXState{
		hdrs:  make([]msghdrX, msgXBatchSize),
		iovs:  make([]unix.Iovec, msgXBatchSize),
		names: make([]unix.RawSockaddrInet6, msgXBatchSize),
	}
	return func(bufs [][]byte, sizes []int, eps []Endpoint) (int, error) {
		if state.fallback || s.msgx.disabled.Load() {
			return s.receiveSingle(conn, bufs, sizes, eps)
		}
		// The endpoint is stored before the flag is raised, so reading the flag
		// first never pairs a connected socket with a stale endpoint.
		var connectedEndpoint *StdNetEndpoint
		if s.msgx.connectedFlag(isV6).Load() {
			connectedEndpoint = s.msgx.endpoint.Load()
		}
		count := len(bufs)
		if count > msgXBatchSize {
			count = msgXBatchSize
		}
		for i := 0; i < count; i++ {
			state.iovs[i] = unix.Iovec{Base: &bufs[i][0]}
			state.iovs[i].SetLen(len(bufs[i]))
			state.hdrs[i] = msghdrX{}
			if connectedEndpoint == nil {
				state.hdrs[i].Msg.Name = (*byte)(unsafe.Pointer(&state.names[i]))
				state.hdrs[i].Msg.Namelen = unix.SizeofSockaddrInet6
			}
			state.hdrs[i].Msg.Iov = &state.iovs[i]
			state.hdrs[i].Msg.Iovlen = 1
		}
		var (
			n     uintptr
			errno unix.Errno
		)
		readErr := rawConn.Read(func(fd uintptr) bool {
			//nolint:staticcheck
			n, _, errno = unix.RawSyscall6(unix.SYS_RECVMSG_X, fd,
				uintptr(unsafe.Pointer(&state.hdrs[0])), uintptr(count), unix.MSG_DONTWAIT, 0, 0)
			return errno != unix.EAGAIN
		})
		if readErr != nil {
			return 0, readErr
		}
		if errno != 0 {
			// recvmsg_x is refusing this socket (sandbox, protocol, ...):
			// serve this and all future calls with a plain single read so
			// the receive routine keeps running.
			state.fallback = true
			return s.receiveSingle(conn, bufs, sizes, eps)
		}
		numMsgs := int(n)
		for i := 0; i < numMsgs; i++ {
			sizes[i] = int(state.hdrs[i].DataLen)
			if sizes[i] > 3 {
				bufs[i][1] = 0
				bufs[i][2] = 0
				bufs[i][3] = 0
			}
			if connectedEndpoint != nil {
				eps[i] = connectedEndpoint
				continue
			}
			var addrPort netip.AddrPort
			name := &state.names[i]
			if name.Family == unix.AF_INET6 {
				port := name.Port<<8 | name.Port>>8
				addrPort = netip.AddrPortFrom(netip.AddrFrom16(name.Addr).Unmap(), port)
			} else {
				name4 := (*unix.RawSockaddrInet4)(unsafe.Pointer(name))
				port := name4.Port<<8 | name4.Port>>8
				addrPort = netip.AddrPortFrom(netip.AddrFrom4(name4.Addr), port)
			}
			eps[i] = &StdNetEndpoint{AddrPort: addrPort}
		}
		return numMsgs, nil
	}, nil
}
