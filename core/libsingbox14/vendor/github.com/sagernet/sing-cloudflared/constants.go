package cloudflared

import (
	"github.com/sagernet/sing-cloudflared/internal/config"
	"github.com/sagernet/sing-cloudflared/internal/transport"
)

const (
	ProtocolQUIC  = transport.ProtocolQUIC
	ProtocolHTTP2 = transport.ProtocolHTTP2

	DatagramVersionV2 = "v2"
	DatagramVersionV3 = "v3"
)

type ConfigUpdateResult = config.UpdateResult
