//go:build linux

package usbip

import (
	"runtime"
	"slices"
	"sync"
	"unsafe"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/unix"
)

// usbfs ioctl encoding (include/uapi/asm-generic/ioctl.h). Request numbers are
// derived from the Go struct sizes so the 32/64-bit pointer width is matched
// automatically; the structs below use uintptr for the kernel's void* fields,
// which gives them the same natural alignment as the C ABI on every arch.
const (
	usbfsIocNRShift   = 0
	usbfsIocTypeShift = 8
	usbfsIocSizeShift = 16
	usbfsIocDirShift  = 30

	usbfsIocNone  = 0
	usbfsIocWrite = 1
	usbfsIocRead  = 2
)

func usbfsIOC(dir, nr, size uintptr) uintptr {
	return dir<<usbfsIocDirShift |
		uintptr('U')<<usbfsIocTypeShift |
		nr<<usbfsIocNRShift |
		size<<usbfsIocSizeShift
}

const (
	usbfsURBTypeISO       = 0
	usbfsURBTypeInterrupt = 1
	usbfsURBTypeControl   = 2
	usbfsURBTypeBulk      = 3
)

type usbfsURB struct {
	Type            uint8
	Endpoint        uint8
	Status          int32
	Flags           uint32
	Buffer          uintptr
	BufferLength    int32
	ActualLength    int32
	StartFrame      int32
	NumberOfPackets int32
	ErrorCount      int32
	SigNr           uint32
	UserContext     uintptr
}

type usbfsDisconnectClaim struct {
	Interface uint32
	Flags     uint32
	Driver    [256]byte
}

var (
	usbfsSubmitURB          = usbfsIOC(usbfsIocRead, 10, unsafe.Sizeof(usbfsURB{}))
	usbfsDiscardURB         = usbfsIOC(usbfsIocNone, 11, 0)
	usbfsReapURBNDelay      = usbfsIOC(usbfsIocWrite, 13, unsafe.Sizeof(uintptr(0)))
	usbfsClaimInterface     = usbfsIOC(usbfsIocRead, 15, unsafe.Sizeof(uint32(0)))
	usbfsReleaseInterface   = usbfsIOC(usbfsIocRead, 16, unsafe.Sizeof(uint32(0)))
	usbfsDisconnectAndClaim = usbfsIOC(usbfsIocRead, 27, unsafe.Sizeof(usbfsDisconnectClaim{}))
)

func usbfsIoctl(fd int, request uintptr, arg unsafe.Pointer) error {
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), request, uintptr(arg))
	if errno != 0 {
		return errno
	}
	return nil
}

func claimInterfaces(fd int, count int, capture bool) ([]uint32, error) {
	if count == 0 {
		count = 1
	}
	var claimed []uint32
	release := func() {
		for _, num := range claimed {
			value := num
			_ = usbfsIoctl(fd, usbfsReleaseInterface, unsafe.Pointer(&value))
		}
	}
	for i := 0; i < count; i++ {
		number := uint32(i)
		var err error
		if capture {
			request := usbfsDisconnectClaim{Interface: number}
			err = usbfsIoctl(fd, usbfsDisconnectAndClaim, unsafe.Pointer(&request))
		} else {
			value := number
			err = usbfsIoctl(fd, usbfsClaimInterface, unsafe.Pointer(&value))
		}
		if err != nil {
			release()
			return nil, E.Cause(err, "claim interface ", i)
		}
		claimed = append(claimed, number)
	}
	return claimed, nil
}

type usbfsTransfer struct {
	urb         usbfsURB
	buffer      []byte
	control     bool
	directionIn bool
	done        chan URBResponse
	pinner      runtime.Pinner
}

// usbfsEngine drives a locally-opened device via the usbfs async URB interface
// (SUBMITURB/REAPURBNDELAY/DISCARDURB) so AbortEndpoint can cancel in-flight IN
// transfers, which the userspace session relies on for unlink. A single reaper
// goroutine poll()s the device fd only while transfers are outstanding — the
// kernel reports POLLERR while no URB is queued, so polling an idle fd would
// busy-loop. Isochronous transfers are not implemented and fail with EIO.
type usbfsEngine struct {
	fd      int
	claimed []uint32

	access  sync.Mutex
	closed  bool
	pending map[uintptr]*usbfsTransfer

	wake   chan struct{}
	stop   chan struct{}
	reaped chan struct{}
}

func newUsbfsEngine(fd int, claimed []uint32) *usbfsEngine {
	engine := &usbfsEngine{
		fd:      fd,
		claimed: claimed,
		pending: make(map[uintptr]*usbfsTransfer),
		wake:    make(chan struct{}, 1),
		stop:    make(chan struct{}),
		reaped:  make(chan struct{}),
	}
	go engine.reap()
	return engine
}

func (e *usbfsEngine) Submit(request URBRequest) URBResponse {
	command := request.Command
	if command.NumberOfPackets > 0 {
		return URBResponse{Status: usbipStatusEIO, Error: E.New("isochronous transfers are not supported on linux usbfs")}
	}
	transfer := &usbfsTransfer{done: make(chan URBResponse, 1)}
	if command.Header.Endpoint == 0 {
		transfer.control = true
		transfer.directionIn = command.Setup[0]&0x80 != 0
		transfer.buffer = make([]byte, 8+len(request.Buffer))
		copy(transfer.buffer[:8], command.Setup[:])
		copy(transfer.buffer[8:], request.Buffer)
		transfer.urb.Type = usbfsURBTypeControl
		transfer.urb.Endpoint = 0
	} else {
		transfer.directionIn = request.Endpoint&0x80 != 0
		transfer.urb.Endpoint = request.Endpoint
		transfer.urb.Type = usbfsURBTypeBulk
		if command.Interval > 0 {
			transfer.urb.Type = usbfsURBTypeInterrupt
		}
		if transfer.directionIn {
			transfer.buffer = make([]byte, len(request.Buffer))
		} else {
			transfer.buffer = request.Buffer
		}
	}

	transfer.pinner.Pin(&transfer.urb)
	if len(transfer.buffer) > 0 {
		transfer.pinner.Pin(&transfer.buffer[0])
		transfer.urb.Buffer = uintptr(unsafe.Pointer(&transfer.buffer[0]))
	}
	transfer.urb.BufferLength = int32(len(transfer.buffer))
	key := uintptr(unsafe.Pointer(&transfer.urb))

	e.access.Lock()
	if e.closed {
		e.access.Unlock()
		transfer.pinner.Unpin()
		return URBResponse{Status: usbipStatusECONNRESET, Error: E.New("device closed")}
	}
	e.pending[key] = transfer
	e.access.Unlock()
	select {
	case e.wake <- struct{}{}:
	default:
	}

	err := usbfsIoctl(e.fd, usbfsSubmitURB, unsafe.Pointer(&transfer.urb))
	if err != nil {
		e.access.Lock()
		delete(e.pending, key)
		e.access.Unlock()
		transfer.pinner.Unpin()
		return URBResponse{Status: usbipStatusEIO, Error: err}
	}

	response := <-transfer.done
	transfer.pinner.Unpin()
	return response
}

func (e *usbfsEngine) AbortEndpoint(endpoint uint8) error {
	e.access.Lock()
	var targets []*usbfsTransfer
	for _, transfer := range e.pending {
		if transfer.urb.Endpoint == endpoint {
			targets = append(targets, transfer)
		}
	}
	e.access.Unlock()
	for _, transfer := range targets {
		_ = usbfsIoctl(e.fd, usbfsDiscardURB, unsafe.Pointer(&transfer.urb))
	}
	return nil
}

func (e *usbfsEngine) Close() error {
	e.access.Lock()
	if e.closed {
		e.access.Unlock()
		return nil
	}
	e.closed = true
	for _, transfer := range e.pending {
		_ = usbfsIoctl(e.fd, usbfsDiscardURB, unsafe.Pointer(&transfer.urb))
	}
	e.access.Unlock()

	close(e.stop)
	<-e.reaped

	for _, number := range e.claimed {
		value := number
		_ = usbfsIoctl(e.fd, usbfsReleaseInterface, unsafe.Pointer(&value))
	}
	_ = unix.Close(e.fd)

	e.access.Lock()
	for key, transfer := range e.pending {
		delete(e.pending, key)
		transfer.done <- URBResponse{Status: usbipStatusECONNRESET, Error: E.New("device closed")}
	}
	e.access.Unlock()
	return nil
}

func (e *usbfsEngine) reap() {
	defer close(e.reaped)
	pollFds := []unix.PollFd{{Fd: int32(e.fd), Events: unix.POLLOUT}}
	for {
		e.access.Lock()
		closed := e.closed
		idle := len(e.pending) == 0
		e.access.Unlock()
		if closed {
			return
		}
		if idle {
			select {
			case <-e.wake:
			case <-e.stop:
				return
			}
			continue
		}
		pollFds[0].Revents = 0
		count, err := unix.Poll(pollFds, 250)
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			return
		}
		if count == 0 {
			continue
		}
		e.drainCompleted()
		if pollFds[0].Revents&(unix.POLLHUP|unix.POLLNVAL) != 0 {
			return
		}
	}
}

func (e *usbfsEngine) drainCompleted() {
	for {
		var key uintptr
		err := usbfsIoctl(e.fd, usbfsReapURBNDelay, unsafe.Pointer(&key))
		if err != nil {
			return
		}
		e.access.Lock()
		transfer := e.pending[key]
		if transfer != nil {
			delete(e.pending, key)
		}
		e.access.Unlock()
		if transfer != nil {
			transfer.done <- e.buildResponse(transfer)
		}
	}
}

func (e *usbfsEngine) buildResponse(transfer *usbfsTransfer) URBResponse {
	response := URBResponse{
		Status:       transfer.urb.Status,
		ActualLength: transfer.urb.ActualLength,
	}
	if !transfer.directionIn || transfer.urb.ActualLength <= 0 {
		return response
	}
	actual := int(transfer.urb.ActualLength)
	offset := 0
	if transfer.control {
		offset = 8
	}
	if offset+actual <= len(transfer.buffer) {
		response.Buffer = slices.Clone(transfer.buffer[offset : offset+actual])
	}
	return response
}
