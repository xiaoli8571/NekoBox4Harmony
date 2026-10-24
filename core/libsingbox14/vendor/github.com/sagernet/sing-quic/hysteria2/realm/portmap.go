package realm

import (
	"context"
	"net/netip"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"

	"github.com/libp2p/go-nat"
)

const (
	defaultPortMappingTimeout  = 10 * time.Second
	defaultPortMappingLifetime = 10 * time.Minute
	portMappingDescription     = "hysteria-realm"
	portMappingProtocol        = "udp"
)

type PortMappingOptions struct {
	Timeout  time.Duration
	Lifetime time.Duration
}

type PortMapper struct {
	gateway      nat.NAT
	logger       logger.Logger
	internalPort int
	timeout      time.Duration
	lifetime     time.Duration

	access       sync.Mutex
	externalAddr netip.AddrPort
}

func NewPortMapper(ctx context.Context, logger logger.Logger, internalPort uint16, options PortMappingOptions) (*PortMapper, error) {
	if internalPort == 0 {
		return nil, E.New("invalid internal port")
	}
	timeout := options.Timeout
	if timeout <= 0 {
		timeout = defaultPortMappingTimeout
	}
	lifetime := options.Lifetime
	if lifetime <= 0 {
		lifetime = defaultPortMappingLifetime
	}
	discoverCtx, cancel := context.WithTimeout(ctx, timeout)
	gateway, err := nat.DiscoverGateway(discoverCtx)
	cancel()
	if err != nil {
		return nil, E.Cause(err, "discover gateway")
	}
	mapper := &PortMapper{
		gateway:      gateway,
		logger:       logger,
		internalPort: int(internalPort),
		timeout:      timeout,
		lifetime:     lifetime,
	}
	_, err = mapper.Renew(ctx)
	if err != nil {
		return nil, err
	}
	logger.Info("port mapping added via ", gateway.Type(), ", external address: ", mapper.ExternalAddr())
	return mapper, nil
}

func (m *PortMapper) Renew(ctx context.Context) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, m.timeout)
	defer cancel()
	externalPort, err := m.gateway.AddPortMapping(ctx, portMappingProtocol, m.internalPort, portMappingDescription, m.lifetime)
	if err != nil {
		return false, E.Cause(err, "add port mapping")
	}
	externalIP, err := m.gateway.GetExternalAddress()
	if err != nil {
		return false, E.Cause(err, "get external address")
	}
	address, valid := netip.AddrFromSlice(externalIP)
	if !valid || address.IsUnspecified() || address.IsLoopback() {
		return false, E.New("gateway returned unusable external address: ", externalIP.String())
	}
	externalAddr := netip.AddrPortFrom(address.Unmap(), uint16(externalPort))
	m.access.Lock()
	changed := externalAddr != m.externalAddr
	m.externalAddr = externalAddr
	m.access.Unlock()
	return changed, nil
}

func (m *PortMapper) ExternalAddr() netip.AddrPort {
	m.access.Lock()
	defer m.access.Unlock()
	return m.externalAddr
}

func (m *PortMapper) KeepAlive(done <-chan struct{}) {
	ticker := time.NewTicker(m.lifetime / 2)
	defer ticker.Stop()
	failing := false
	for {
		select {
		case <-done:
			err := m.Close()
			if err != nil {
				m.logger.Debug(E.Cause(err, "remove port mapping"))
			}
			return
		case <-ticker.C:
			changed, err := m.Renew(context.Background())
			if err != nil {
				if !failing {
					failing = true
					m.logger.Warn(E.Cause(err, "renew port mapping"))
				}
				continue
			}
			if failing {
				failing = false
				m.logger.Info("port mapping recovered, external address: ", m.ExternalAddr())
			} else if changed {
				m.logger.Info("port mapping external address changed: ", m.ExternalAddr())
			}
		}
	}
}

func (m *PortMapper) Close() error {
	ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
	defer cancel()
	return m.gateway.DeletePortMapping(ctx, portMappingProtocol, m.internalPort)
}
