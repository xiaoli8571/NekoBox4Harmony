package ipnlocal

import (
	"github.com/sagernet/tailscale/net/dns/resolver"
	"github.com/sagernet/tailscale/wgengine"
)

func (b *LocalBackend) ExportEngine() wgengine.Engine {
	return b.e
}

func (b *LocalBackend) ExportMagicDNSHosts() resolver.MagicDNSHosts {
	return magicDNSHosts{b}
}

func (b *LocalBackend) SetExternalSSHHostKeys(keys []string) {
	b.mu.Lock()
	b.externalSSHHostKeys = keys
	if b.hostinfo != nil {
		b.hostinfo.SSH_HostKeys = keys
	}
	b.mu.Unlock()
	b.doSetHostinfoFilterServices()
}
