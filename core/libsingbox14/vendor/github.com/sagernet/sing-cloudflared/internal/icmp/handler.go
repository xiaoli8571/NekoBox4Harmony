package icmp

import (
	"net/netip"

	"github.com/sagernet/sing-tun"
)

type RouteHandler interface {
	RouteICMPFlow(source netip.Addr, destination netip.Addr) (tun.Port, error)
}
