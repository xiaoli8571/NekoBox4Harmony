package openvpn

import (
	"sync"
	"time"
)

const (
	defaultServerMaxClients                    = 1024
	defaultServerInitialConnectFrequency       = 100
	defaultServerInitialConnectFrequencyPeriod = 10 * time.Second
)

type serverResourcePolicy struct {
	access sync.Mutex

	maxClients int

	connectFrequency       int
	connectFrequencyPeriod time.Duration
	connectWindowStart     time.Time
	connectWindowCount     int

	initialConnectFrequency       int
	initialConnectFrequencyPeriod time.Duration
	initialWindowStart            time.Time
	initialWindowCount            int

	instances int
}

type serverResourceReservation struct {
	policy *serverResourcePolicy
}

func newServerResourcePolicy(options ServerOptions) *serverResourcePolicy {
	maxClients := options.Resources.MaxClients
	if maxClients == 0 {
		maxClients = defaultServerMaxClients
	}
	initialConnectFrequency := options.Resources.InitialConnectFrequency
	initialConnectFrequencyPeriod := options.Resources.InitialConnectFrequencyPeriod
	if initialConnectFrequencyPeriod == 0 {
		initialConnectFrequency = defaultServerInitialConnectFrequency
		initialConnectFrequencyPeriod = defaultServerInitialConnectFrequencyPeriod
	}
	return &serverResourcePolicy{
		maxClients:                    maxClients,
		connectFrequency:              options.Resources.ConnectFrequency,
		connectFrequencyPeriod:        options.Resources.ConnectFrequencyPeriod,
		initialConnectFrequency:       initialConnectFrequency,
		initialConnectFrequencyPeriod: initialConnectFrequencyPeriod,
	}
}

func (p *serverResourcePolicy) allowInitialPacket(now time.Time) bool {
	p.access.Lock()
	defer p.access.Unlock()
	if p.initialWindowStart.IsZero() || now.Sub(p.initialWindowStart) > p.initialConnectFrequencyPeriod {
		p.initialWindowStart = now
		p.initialWindowCount = 0
	}
	p.initialWindowCount++
	return p.initialWindowCount <= p.initialConnectFrequency
}

func (p *serverResourcePolicy) refundInitialPacket() {
	p.access.Lock()
	defer p.access.Unlock()
	if p.initialWindowCount > 0 {
		p.initialWindowCount--
	}
}

func (p *serverResourcePolicy) allowNewConnection(now time.Time) bool {
	p.access.Lock()
	defer p.access.Unlock()
	if p.connectFrequencyPeriod == 0 {
		return true
	}
	if p.connectWindowStart.IsZero() || now.Sub(p.connectWindowStart) >= p.connectFrequencyPeriod {
		p.connectWindowStart = now
		p.connectWindowCount = 0
	}
	p.connectWindowCount++
	return p.connectWindowCount <= p.connectFrequency
}

func (p *serverResourcePolicy) reserveInstance() *serverResourceReservation {
	p.access.Lock()
	defer p.access.Unlock()
	if p.instances >= p.maxClients {
		return nil
	}
	p.instances++
	return &serverResourceReservation{policy: p}
}

func (r *serverResourceReservation) release() {
	r.policy.access.Lock()
	r.policy.instances--
	r.policy.access.Unlock()
}
