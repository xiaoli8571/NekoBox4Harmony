package wgengine

import (
	"github.com/sagernet/tailscale/net/dns"
	"github.com/sagernet/tailscale/net/tstun"
	"github.com/sagernet/tailscale/wgengine/filter"
	"github.com/sagernet/tailscale/wgengine/router"
	"github.com/sagernet/tailscale/wgengine/wgcfg"
)

type ExportedUserspaceEngine interface {
	SetOnReconfigListener(listener ReconfigListener)
	GetFilter() *filter.Filter
	InputPackets(packets [][]byte) ([][]byte, error)
	SetReturnPath(returnPath tstun.ReturnPath) error
}

type ReconfigListener = func(cfg *wgcfg.Config, routerCfg *router.Config, dnsCfg *dns.Config)

type reconfigArgs struct {
	cfg       *wgcfg.Config
	routerCfg *router.Config
	dnsCfg    *dns.Config
}

// SetOnReconfigListener installs the listener and, when a Reconfig
// already happened (such as the synchronous install of the on-disk
// cached netmap during backend start), replays the last configuration
// so the listener never misses the initial state.
func (e *userspaceEngine) SetOnReconfigListener(listener ReconfigListener) {
	e.wgLock.Lock()
	defer e.wgLock.Unlock()
	e.onReconfig = listener
	if listener != nil && e.onReconfigArgs != nil {
		listener(e.onReconfigArgs.cfg, e.onReconfigArgs.routerCfg, e.onReconfigArgs.dnsCfg)
	}
}

// notifyOnReconfigLocked runs on every Reconfig call, including the
// ErrNoChanges path: listeners use it as a "netmap-derived state may
// have changed" tick (such as SSH policy re-evaluation), not only as a
// config-diff signal, and deduplicate changes themselves.
func (e *userspaceEngine) notifyOnReconfigLocked(cfg *wgcfg.Config, routerCfg *router.Config, dnsCfg *dns.Config) {
	e.onReconfigArgs = &reconfigArgs{cfg: cfg.Clone(), routerCfg: routerCfg.Clone(), dnsCfg: dnsCfg.Clone()}
	if e.onReconfig != nil {
		e.onReconfig(cfg, routerCfg, dnsCfg)
	}
}

func (e *userspaceEngine) InputPackets(packets [][]byte) ([][]byte, error) {
	return e.tundev.InputPackets(packets)
}

func (e *userspaceEngine) SetReturnPath(returnPath tstun.ReturnPath) error {
	return e.tundev.SetReturnPath(returnPath)
}
