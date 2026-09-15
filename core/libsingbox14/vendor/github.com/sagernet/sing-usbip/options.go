package usbip

import (
	"context"
	"net"

	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

type ListenFunc func(ctx context.Context) (net.Listener, error)

type DeviceMatch struct {
	BusID     string
	VendorID  uint16
	ProductID uint16
	Serial    string
}

func (m DeviceMatch) IsZero() bool {
	return m.BusID == "" && m.VendorID == 0 && m.ProductID == 0 && m.Serial == ""
}

type ServerOptions struct {
	Logger        logger.ContextLogger
	Devices       []DeviceMatch
	Listen        ListenFunc
	ListenAddress M.Socksaddr
}

type ClientOptions struct {
	Logger        logger.ContextLogger
	Dialer        N.Dialer
	ServerAddress M.Socksaddr
	Devices       []DeviceMatch
}
