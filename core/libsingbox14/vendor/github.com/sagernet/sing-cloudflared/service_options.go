package cloudflared

import (
	"context"
	"time"

	"github.com/sagernet/sing/common/logger"
	N "github.com/sagernet/sing/common/network"
)

type ServiceOptions struct {
	Logger           logger.ContextLogger
	ConnectionDialer N.Dialer
	ControlDialer    N.Dialer
	TunnelDialer     N.Dialer
	ControlResolver  Resolver
	TunnelResolver   Resolver
	ICMPHandler      ICMPHandler
	ConnContext      func(context.Context) context.Context
	Token            string
	HAConnections    int
	Protocol         string
	PostQuantum      bool
	EdgeIPVersion    int
	DatagramVersion  string
	GracePeriod      time.Duration
	Region           string
	ClientVersion    string
}
