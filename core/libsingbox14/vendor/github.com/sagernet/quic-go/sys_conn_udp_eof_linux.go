//go:build linux

package quic

import "syscall"

func isUDPEOF(syscall.RawConn) bool {
	return false
}
