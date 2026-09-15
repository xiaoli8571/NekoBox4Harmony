package openconnect

import (
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const anyConnectDTLSTimerResolution = 250 * time.Millisecond

var errAnyConnectDTLSRekey = E.New("DTLS SSL rekey due")

func (c *anyConnectDTLSChannel) timerLoop() {
	defer c.waitGroup.Done()
	ticker := time.NewTicker(anyConnectDTLSTimerResolution)
	defer ticker.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case now := <-ticker.C:
			err := c.processTimers(now)
			if err != nil {
				c.terminate(err)
				return
			}
		}
	}
}

func (c *anyConnectDTLSChannel) processTimers(now time.Time) error {
	nowNanoseconds := now.UnixNano()
	if c.negotiation.Rekey > 0 && c.negotiation.RekeyMethod != "" && c.negotiation.RekeyMethod != "none" {
		lastRekey := time.Unix(0, c.lastRekey.Load())
		if !now.Before(lastRekey.Add(c.negotiation.Rekey)) {
			c.lastRekey.Store(nowNanoseconds)
			if c.negotiation.RequestRekey == nil {
				return E.New("DTLS rekey is due but the CSTP session supplied no rekey callback for method: ", c.negotiation.RekeyMethod)
			}
			err := c.negotiation.RequestRekey(c.negotiation.RekeyMethod)
			if err != nil {
				return E.Cause(err, "request DTLS rekey using method ", c.negotiation.RekeyMethod)
			}
		}
	}

	lastReceived := time.Unix(0, c.lastReceived.Load())
	if c.negotiation.DPD > 0 {
		if now.After(lastReceived.Add(2 * c.negotiation.DPD)) {
			return E.New("DTLS dead peer detection expired after ", 2*c.negotiation.DPD)
		}
		lastDPDNanoseconds := c.lastDPD.Load()
		lastDPD := time.Unix(0, lastDPDNanoseconds)
		outstanding := lastDPDNanoseconds > c.lastReceived.Load()
		due := lastReceived.Add(c.negotiation.DPD)
		if outstanding {
			due = lastDPD.Add(c.negotiation.DPD / 2)
		}
		if !now.Before(due) {
			c.lastDPD.Store(nowNanoseconds)
			err := c.writePacket([]byte{cstpPacketDPDRequest})
			if err != nil {
				return err
			}
		}
	}

	lastTransmitted := time.Unix(0, c.lastTransmitted.Load())
	if c.negotiation.Keepalive > 0 && !now.Before(lastTransmitted.Add(c.negotiation.Keepalive)) {
		err := c.writePacket([]byte{cstpPacketKeepalive})
		if err != nil {
			return err
		}
	}
	return nil
}
