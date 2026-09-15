package congestion

import (
	"math"
	"time"

	"github.com/sagernet/quic-go/congestion"
	"github.com/sagernet/quic-go/monotime"
)

const (
	MinPacingDelay      = time.Millisecond
	TimerGranularity    = time.Millisecond
	maxBurstSizePackets = 10
)

// The pacer implements a token bucket pacing algorithm.
type pacer struct {
	budgetAtLastSent     congestion.ByteCount
	maxDatagramSize      congestion.ByteCount
	lastSentTime         monotime.Time
	getAdjustedBandwidth func() uint64 // in bytes/s
}

func newPacer(initialMaxDatagramSize congestion.ByteCount, getBandwidth func() Bandwidth) *pacer {
	p := &pacer{
		maxDatagramSize: initialMaxDatagramSize,
		getAdjustedBandwidth: func() uint64 {
			// Bandwidth is in bits/s. We need the value in bytes/s.
			bw := uint64(getBandwidth() / BytesPerSecond)
			// Use a slightly higher value than the actual measured bandwidth.
			// RTT variations then won't result in under-utilization of the congestion window.
			// Ultimately, this will  result in sending packets as acknowledgments are received rather than when timers fire,
			// provided the congestion window is fully utilized and acknowledgments arrive at regular intervals.
			return bw * 5 / 4
		},
	}
	p.budgetAtLastSent = p.maxBurstSize()
	return p
}

func (p *pacer) SentPacket(sendTime monotime.Time, size congestion.ByteCount) {
	budget := p.Budget(sendTime)
	if size > budget {
		p.budgetAtLastSent = 0
	} else {
		p.budgetAtLastSent = budget - size
	}
	p.lastSentTime = sendTime
}

func (p *pacer) Budget(now monotime.Time) congestion.ByteCount {
	if p.lastSentTime.IsZero() {
		return p.maxBurstSize()
	}
	delta := now.Sub(p.lastSentTime)
	var added congestion.ByteCount
	if delta > 0 {
		added = p.timeScaledBandwidth(uint64(delta.Nanoseconds()))
	}
	budget := p.budgetAtLastSent + added
	if added > 0 && budget < p.budgetAtLastSent {
		budget = MaxByteCount
	}
	return Min(p.maxBurstSize(), budget)
}

func (p *pacer) maxBurstSize() congestion.ByteCount {
	return Max(
		p.timeScaledBandwidth(uint64((MinPacingDelay + TimerGranularity).Nanoseconds())),
		maxBurstSizePackets*p.maxDatagramSize,
	)
}

// timeScaledBandwidth calculates the number of bytes that may be sent within
// a given time interval (ns nanoseconds), based on the current bandwidth estimate.
// It caps the scaled value to the maximum allowed burst and handles overflows.
func (p *pacer) timeScaledBandwidth(ns uint64) congestion.ByteCount {
	bw := p.getAdjustedBandwidth()
	if bw == 0 {
		return 0
	}
	maxBurst := maxBurstSizePackets * p.maxDatagramSize
	if ns > math.MaxUint64/bw {
		return maxBurst
	}
	return congestion.ByteCount(bw * ns / 1e9)
}

// TimeUntilSend returns when the next packet should be sent.
// It returns the zero value of monotime.Time if a packet can be sent immediately.
func (p *pacer) TimeUntilSend() monotime.Time {
	if p.budgetAtLastSent >= p.maxDatagramSize {
		return monotime.Time(0)
	}
	bw := p.getAdjustedBandwidth()
	if bw == 0 {
		return p.lastSentTime.Add(MinPacingDelay)
	}
	diff := 1e9 * uint64(p.maxDatagramSize-p.budgetAtLastSent)
	// We might need to round up this value.
	// Otherwise, we might have a budget (slightly) smaller than the datagram size when the timer expires.
	d := diff / bw
	// this is effectively a math.Ceil, but using only integer math
	if diff%bw > 0 {
		d++
	}
	return p.lastSentTime.Add(Max(MinPacingDelay, time.Duration(d)*time.Nanosecond))
}

func (p *pacer) SetMaxDatagramSize(s congestion.ByteCount) {
	p.maxDatagramSize = s
}
