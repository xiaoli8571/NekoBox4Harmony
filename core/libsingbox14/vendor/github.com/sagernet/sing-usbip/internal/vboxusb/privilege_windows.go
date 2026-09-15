//go:build windows

package vboxusb

import (
	"errors"
	"sync"
	"unsafe"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/windows"
)

func EnableLoadDriverPrivilege() error {
	loadDriverPrivOnce.Do(func() {
		loadDriverPrivErr = enableLoadDriverPrivilege()
	})
	return loadDriverPrivErr
}

var (
	loadDriverPrivOnce sync.Once
	loadDriverPrivErr  error
)

func enableLoadDriverPrivilege() error {
	var token windows.Token
	err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_ADJUST_PRIVILEGES|windows.TOKEN_QUERY, &token)
	if err != nil {
		return E.Cause(err, "vboxusb: open process token")
	}
	defer token.Close()

	privName, _ := windows.UTF16PtrFromString("SeLoadDriverPrivilege")
	var luid windows.LUID
	err = windows.LookupPrivilegeValue(nil, privName, &luid)
	if err != nil {
		return E.Cause(err, "vboxusb: lookup SeLoadDriverPrivilege")
	}

	tp := windows.Tokenprivileges{
		PrivilegeCount: 1,
		Privileges: [1]windows.LUIDAndAttributes{{
			Luid:       luid,
			Attributes: windows.SE_PRIVILEGE_ENABLED,
		}},
	}
	err = windows.AdjustTokenPrivileges(token, false, &tp, 0, nil, nil)
	if err != nil {
		return E.Cause(err, "vboxusb: adjust token privileges")
	}
	// AdjustTokenPrivileges reports success even when the token does not
	// hold the privilege (ERROR_NOT_ALL_ASSIGNED, which the x/sys
	// wrapper drops when the call returns nonzero).
	enabled, err := tokenPrivilegeEnabled(token, luid)
	if err != nil {
		return E.Cause(err, "vboxusb: query token privileges")
	}
	if !enabled {
		return E.New("vboxusb: SeLoadDriverPrivilege was not granted; sing-usbip requires Administrator")
	}
	return nil
}

func tokenPrivilegeEnabled(token windows.Token, luid windows.LUID) (bool, error) {
	bufferSize := uint32(unsafe.Sizeof(windows.Tokenprivileges{}))
	for {
		buffer := make([]byte, bufferSize)
		err := windows.GetTokenInformation(token, windows.TokenPrivileges, &buffer[0], uint32(len(buffer)), &bufferSize)
		if err != nil {
			if errors.Is(err, windows.ERROR_INSUFFICIENT_BUFFER) {
				continue
			}
			return false, err
		}
		privileges := (*windows.Tokenprivileges)(unsafe.Pointer(&buffer[0]))
		for _, attributes := range privileges.AllPrivileges() {
			if attributes.Luid == luid {
				return attributes.Attributes&windows.SE_PRIVILEGE_ENABLED != 0, nil
			}
		}
		return false, nil
	}
}
