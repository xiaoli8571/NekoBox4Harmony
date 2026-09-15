//go:build windows

package quic

import (
	"errors"

	"golang.org/x/sys/windows"
)

func isNoBufferSpaceErr(err error) bool {
	// https://docs.microsoft.com/en-us/windows/win32/winsock/windows-sockets-error-codes-2
	return errors.Is(err, windows.WSAENOBUFS)
}
