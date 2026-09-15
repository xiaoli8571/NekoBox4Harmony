package openconnect

import "math"

type espReplayWindow struct {
	missing      uint64
	nextSequence uint64
}

func (w *espReplayWindow) accept(sequence uint32) bool {
	sequence64 := uint64(sequence)
	if sequence64 == w.nextSequence {
		w.missing <<= 1
		w.nextSequence++
		return true
	}
	if sequence64 > w.nextSequence {
		delta := sequence64 - w.nextSequence
		switch {
		case delta >= 64:
			w.missing = math.MaxUint64
		case delta == 63:
			w.missing = math.MaxUint64 >> 1
		default:
			w.missing <<= delta + 1
			w.missing |= (uint64(1) << delta) - 1
		}
		w.nextSequence = sequence64 + 1
		return true
	}
	delta := w.nextSequence - sequence64
	if delta == 1 || delta > 65 {
		return false
	}
	mask := uint64(1) << (delta - 2)
	if w.missing&mask == 0 {
		return false
	}
	w.missing &^= mask
	return true
}
