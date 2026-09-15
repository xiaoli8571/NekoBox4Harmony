package openconnect

import (
	"sync/atomic"
	"time"
)

type cstpTimerAction uint8

const (
	cstpTimerNone cstpTimerAction = iota
	cstpTimerDPD
	cstpTimerDeadPeer
	cstpTimerKeepalive
	cstpTimerRekey
)

type cstpKeepaliveState struct {
	dpd          time.Duration
	keepalive    time.Duration
	rekey        time.Duration
	rekeyMethod  cstpRekeyMethod
	origin       time.Time
	lastRekey    time.Duration
	lastTransmit atomic.Int64
	lastReceive  atomic.Int64
	lastDPD      time.Duration
}

func newCSTPKeepaliveState(dpd time.Duration, keepalive time.Duration, rekey time.Duration, rekeyMethod cstpRekeyMethod) *cstpKeepaliveState {
	return &cstpKeepaliveState{
		dpd:         dpd,
		keepalive:   keepalive,
		rekey:       rekey,
		rekeyMethod: rekeyMethod,
		origin:      time.Now(),
	}
}

func (s *cstpKeepaliveState) markReceived() {
	s.lastReceive.Store(int64(time.Since(s.origin)))
}

func (s *cstpKeepaliveState) markTransmitted() {
	s.lastTransmit.Store(int64(time.Since(s.origin)))
}

// Upstream keepalive_action sends DPD after one idle DPD period, retries no sooner than half a period, and declares the peer dead after two periods.
func (s *cstpKeepaliveState) action(now time.Time) cstpTimerAction {
	elapsed := now.Sub(s.origin)
	if s.rekeyMethod != cstpRekeyNone && s.rekey > 0 && elapsed >= s.lastRekey+s.rekey {
		s.lastRekey = elapsed
		return cstpTimerRekey
	}
	lastReceive := time.Duration(s.lastReceive.Load())
	if s.dpd > 0 {
		if elapsed > lastReceive+2*s.dpd {
			return cstpTimerDeadPeer
		}
		due := lastReceive + s.dpd
		if s.lastDPD > lastReceive {
			due = s.lastDPD + s.dpd/2
		}
		if elapsed >= due {
			s.lastDPD = elapsed
			return cstpTimerDPD
		}
	}
	lastTransmit := time.Duration(s.lastTransmit.Load())
	if s.keepalive > 0 && elapsed >= lastTransmit+s.keepalive {
		return cstpTimerKeepalive
	}
	return cstpTimerNone
}

func (s *cstpKeepaliveState) nextDelay(now time.Time) time.Duration {
	elapsed := now.Sub(s.origin)
	deadlines := make([]time.Duration, 0, 4)
	if s.rekeyMethod != cstpRekeyNone && s.rekey > 0 {
		deadlines = append(deadlines, s.lastRekey+s.rekey)
	}
	if s.dpd > 0 {
		lastReceive := time.Duration(s.lastReceive.Load())
		dpdDeadline := lastReceive + s.dpd
		if s.lastDPD > lastReceive {
			dpdDeadline = s.lastDPD + s.dpd/2
		}
		deadlines = append(deadlines, dpdDeadline, lastReceive+2*s.dpd)
	}
	if s.keepalive > 0 {
		deadlines = append(deadlines, time.Duration(s.lastTransmit.Load())+s.keepalive)
	}
	if len(deadlines) == 0 {
		return time.Hour
	}
	next := deadlines[0]
	for _, deadline := range deadlines[1:] {
		if deadline < next {
			next = deadline
		}
	}
	delay := next - elapsed
	if delay <= 0 {
		return time.Millisecond
	}
	return delay
}
