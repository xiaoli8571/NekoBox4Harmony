//go:build darwin || freebsd

package quic

import (
	"syscall"

	"golang.org/x/sys/unix"
)

func isUDPEOF(conn syscall.RawConn) bool {
	var isEOF bool
	conn.Control(func(fd uintptr) {
		kqueue, err := unix.Kqueue()
		if err != nil {
			return
		}
		defer unix.Close(kqueue)
		changes := make([]unix.Kevent_t, 1)
		unix.SetKevent(&changes[0], int(fd), unix.EVFILT_READ, unix.EV_ADD)
		events := make([]unix.Kevent_t, 1)
		n, err := unix.Kevent(kqueue, changes, events, &unix.Timespec{})
		isEOF = err == nil && n == 1 && events[0].Flags&unix.EV_EOF != 0
	})
	return isEOF
}
