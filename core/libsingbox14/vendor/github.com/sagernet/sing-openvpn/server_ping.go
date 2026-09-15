package openvpn

import (
	"context"
	"sync"
	"time"
)

type tlsServerPinger struct {
	session *tlsServerSession

	access sync.Mutex

	lastInboundTime  time.Time
	lastOutboundTime time.Time
	pingInterval     time.Duration
	pingRestart      time.Duration
}

func (p *tlsServerPinger) markActivity(inbound bool, outbound bool) {
	p.access.Lock()
	defer p.access.Unlock()
	now := time.Now()
	if inbound {
		p.lastInboundTime = now
	}
	if outbound {
		p.lastOutboundTime = now
	}
}

func (p *tlsServerPinger) snapshotActivity() (time.Time, time.Time) {
	p.access.Lock()
	defer p.access.Unlock()
	return p.lastInboundTime, p.lastOutboundTime
}

func (p *tlsServerPinger) runLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		lastInbound, lastOutbound := p.snapshotActivity()
		now := time.Now()
		if shouldExitForPingTimeout(lastInbound, now, p.pingRestart) {
			_ = p.session.Close()
			return
		}
		// Upstream check_ping_send_dowork (ping.c) only queues the keepalive on
		// the link, so a failed link write leaves the session to --ping-restart
		// above, which measures inbound silence alone.
		if p.pingInterval > 0 && now.Sub(lastOutbound) >= p.pingInterval {
			messages := p.session.dataChannelMessages()
			if messages != nil {
				messages.sendPing()
			}
		}
	}
}
