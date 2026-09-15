//go:build !linux && !(darwin && cgo) && !windows

package usbip

import (
	"context"

	E "github.com/sagernet/sing/common/exceptions"
)

type ServerService struct{}

func NewServerService(ctx context.Context, options ServerOptions) (*ServerService, error) {
	return nil, E.New("usbip-server service is only supported on Linux, Windows, and macOS with CGO")
}

func (s *ServerService) Start() error {
	return nil
}

func (s *ServerService) Close() error {
	return nil
}

type ClientService struct{}

func NewClientService(ctx context.Context, options ClientOptions) (*ClientService, error) {
	return nil, E.New("usbip-client service is only supported on Linux, Windows, and macOS with CGO")
}

func (c *ClientService) Start() error {
	return nil
}

func (c *ClientService) Close() error {
	return nil
}
