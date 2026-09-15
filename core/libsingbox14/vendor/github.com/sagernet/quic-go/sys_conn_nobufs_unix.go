//go:build unix

package quic

import (
	"errors"
	"syscall"
)

func isNoBufferSpaceErr(err error) bool {
	return errors.Is(err, syscall.ENOBUFS)
}
