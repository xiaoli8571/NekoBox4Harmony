package winsetupapi

import (
	"errors"
	"fmt"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/sys/windows"
)

const (
	applicationErrorMask = 0x20000000
	errorSeverityError   = 0xC0000000
	facilitySetupAPI     = 15
)

// setupapi reports its own failures through GetLastError as
// APPLICATION_ERROR_MASK|ERROR_SEVERITY_ERROR|code, while the message text is
// registered under HRESULT_FROM_SETUPAPI(code) (winerror.h): FormatMessage
// resolves nothing for the value GetLastError returns, neither from the system
// table nor from setupapi.dll itself.
func Cause(cause error, message ...any) error {
	var errno windows.Errno
	found := errors.As(cause, &errno)
	if !found || uint32(errno)&(applicationErrorMask|errorSeverityError) != applicationErrorMask|errorSeverityError {
		return E.Cause(cause, message...)
	}
	hresult := uint32(errno)&0xFFFF | facilitySetupAPI<<16 | 0x80000000
	detail := fmt.Sprintf("0x%08x", hresult)
	var buffer [512]uint16
	length, err := windows.FormatMessage(
		windows.FORMAT_MESSAGE_FROM_SYSTEM|windows.FORMAT_MESSAGE_IGNORE_INSERTS,
		0, hresult, 0, buffer[:], nil,
	)
	for length > 0 && (buffer[length-1] == '\r' || buffer[length-1] == '\n') {
		length--
	}
	if err == nil && length > 0 {
		detail += ": " + windows.UTF16ToString(buffer[:length])
	}
	return E.Cause(&hresultError{errno, detail}, message...)
}

type hresultError struct {
	errno   windows.Errno
	message string
}

func (e *hresultError) Error() string {
	return e.message
}

func (e *hresultError) Unwrap() error {
	return e.errno
}
