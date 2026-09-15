package main

import (
	"context"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter/certificate"
	"github.com/sagernet/sing-box/adapter/endpoint"
	"github.com/sagernet/sing-box/adapter/inbound"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/adapter/service"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/dns/transport"
	"github.com/sagernet/sing-box/dns/transport/dhcp"
	"github.com/sagernet/sing-box/dns/transport/fakeip"
	"github.com/sagernet/sing-box/dns/transport/hosts"
	"github.com/sagernet/sing-box/dns/transport/local"
	"github.com/sagernet/sing-box/dns/transport/quic"
	_ "github.com/sagernet/sing-box/experimental/clashapi"
	"github.com/sagernet/sing-box/protocol/direct"
	"github.com/sagernet/sing-box/protocol/http"
	"github.com/sagernet/sing-box/protocol/hysteria"
	"github.com/sagernet/sing-box/protocol/hysteria2"
	"github.com/sagernet/sing-box/protocol/mixed"
	"github.com/sagernet/sing-box/protocol/shadowsocks"
	"github.com/sagernet/sing-box/protocol/shadowtls"
	"github.com/sagernet/sing-box/protocol/socks"
	"github.com/sagernet/sing-box/protocol/ssh"
	"github.com/sagernet/sing-box/protocol/trojan"
	"github.com/sagernet/sing-box/protocol/tuic"
	"github.com/sagernet/sing-box/protocol/tun"
	"github.com/sagernet/sing-box/protocol/vless"
	"github.com/sagernet/sing-box/protocol/vmess"
	"github.com/sagernet/sing-box/protocol/wireguard"
	_ "github.com/sagernet/sing-box/transport/v2raygrpc"
	_ "github.com/sagernet/sing-box/transport/v2rayhttp"
	_ "github.com/sagernet/sing-box/transport/v2rayhttpupgrade"
	_ "github.com/sagernet/sing-box/transport/v2rayquic"
	_ "github.com/sagernet/sing-box/transport/v2raywebsocket"
)

// leanContext installs only the registries required by NekoBox4Harmony's
// generated configurations. Keeping this wrapper-local avoids changing the
// vendored upstream registry and lets the linker discard unsupported families.
func leanContext(ctx context.Context) context.Context {
	inboundRegistry := inbound.NewRegistry()
	tun.RegisterInbound(inboundRegistry)
	mixed.RegisterInbound(inboundRegistry)

	outboundRegistry := outbound.NewRegistry()
	direct.RegisterOutbound(outboundRegistry)
	shadowsocks.RegisterOutbound(outboundRegistry)
	vmess.RegisterOutbound(outboundRegistry)
	vless.RegisterOutbound(outboundRegistry)
	trojan.RegisterOutbound(outboundRegistry)
	hysteria.RegisterOutbound(outboundRegistry)
	hysteria2.RegisterOutbound(outboundRegistry)
	tuic.RegisterOutbound(outboundRegistry)
	http.RegisterOutbound(outboundRegistry)
	socks.RegisterOutbound(outboundRegistry)
	ssh.RegisterOutbound(outboundRegistry)
	shadowtls.RegisterOutbound(outboundRegistry)

	endpointRegistry := endpoint.NewRegistry()
	wireguard.RegisterEndpoint(endpointRegistry)

	dnsRegistry := dns.NewTransportRegistry()
	transport.RegisterTCP(dnsRegistry)
	transport.RegisterUDP(dnsRegistry)
	transport.RegisterTLS(dnsRegistry)
	transport.RegisterHTTPS(dnsRegistry)
	quic.RegisterTransport(dnsRegistry)
	quic.RegisterHTTP3Transport(dnsRegistry)
	local.RegisterTransport(dnsRegistry)
	hosts.RegisterTransport(dnsRegistry)
	fakeip.RegisterTransport(dnsRegistry)
	dhcp.RegisterTransport(dnsRegistry)

	return box.Context(
		ctx,
		inboundRegistry,
		outboundRegistry,
		endpointRegistry,
		dnsRegistry,
		service.NewRegistry(),
		certificate.NewRegistry(),
	)
}
