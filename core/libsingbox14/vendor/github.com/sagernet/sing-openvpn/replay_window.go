package openvpn

import (
	"sync"
	"time"
)

// Upstream DEFAULT_SEQ_BACKTRACK/MAX_SEQ_BACKTRACK bound --replay-window.
const (
	defaultReplayWindowSize = 64
	maxReplayWindowSize     = 65536
	defaultReplayWindowTime = 15 * time.Second
	maxReplayWindowTime     = 600 * time.Second
)

type replayWindow struct {
	access           sync.Mutex
	windowSize       uint32
	initialized      bool
	highestID        uint32
	highestTimestamp uint32
	bitmap           []uint64
	arrivalTimes     []time.Time
	minimumID        uint32
	timeWindow       time.Duration
}

// Upstream --replay-window 0 accepts only strictly monotonic packet IDs.
func newReplayWindow(windowSize uint32, timeWindow time.Duration) *replayWindow {
	wordCount := int((uint64(windowSize) + 63) / 64)
	return &replayWindow{
		windowSize:   windowSize,
		bitmap:       make([]uint64, wordCount),
		arrivalTimes: make([]time.Time, windowSize),
		timeWindow:   timeWindow,
	}
}

func (w *replayWindow) Accept(packetID uint32) bool {
	if packetID == 0 {
		return false
	}
	w.access.Lock()
	defer w.access.Unlock()
	return w.acceptLocked(packetID)
}

// Upstream packet_id_test rejects long-form timestamp backtracking and
// resets the sequence window when the timestamp advances.
func (w *replayWindow) AcceptLongForm(packetID uint32, timestamp uint32) bool {
	if packetID == 0 {
		return false
	}
	w.access.Lock()
	defer w.access.Unlock()
	if !w.initialized {
		if w.windowSize == 0 && timestamp > 0 && packetID != 1 {
			return false
		}
		w.initializeLocked(packetID, timestamp)
		return true
	}
	if timestamp < w.highestTimestamp {
		return false
	}
	if timestamp > w.highestTimestamp {
		if w.windowSize == 0 && packetID != 1 {
			return false
		}
		w.initializeLocked(packetID, timestamp)
		return true
	}
	return w.acceptLocked(packetID)
}

func (w *replayWindow) acceptLocked(packetID uint32) bool {
	if !w.initialized {
		w.initializeLocked(packetID, 0)
		return true
	}
	if w.windowSize == 0 {
		if packetID != w.highestID+1 {
			return false
		}
		w.highestID = packetID
		return true
	}
	w.reapLocked()
	if packetID > w.highestID {
		shift := packetID - w.highestID
		if shift >= w.windowSize {
			for i := range w.bitmap {
				w.bitmap[i] = 0
			}
		} else {
			shiftReplayBitmap(w.bitmap, shift)
			shiftReplayTimes(w.arrivalTimes, shift)
		}
		if shift >= w.windowSize {
			for i := range w.arrivalTimes {
				w.arrivalTimes[i] = time.Time{}
			}
		}
		w.bitmap[0] |= 1
		w.arrivalTimes[0] = time.Now()
		w.highestID = packetID
		return true
	}
	if packetID < w.minimumID {
		return false
	}
	offset := w.highestID - packetID
	if offset >= w.windowSize {
		return false
	}
	wordIndex := offset / 64
	bitIndex := offset % 64
	packetMask := uint64(1) << bitIndex
	if w.bitmap[wordIndex]&packetMask != 0 {
		return false
	}
	w.bitmap[wordIndex] |= packetMask
	w.arrivalTimes[offset] = time.Now()
	return true
}

func (w *replayWindow) initializeLocked(packetID uint32, timestamp uint32) {
	w.initialized = true
	w.highestTimestamp = timestamp
	w.highestID = packetID
	w.minimumID = 0
	for i := range w.bitmap {
		w.bitmap[i] = 0
	}
	for i := range w.arrivalTimes {
		w.arrivalTimes[i] = time.Time{}
	}
	if w.windowSize > 0 {
		w.bitmap[0] = 1
		w.arrivalTimes[0] = time.Now()
	}
}

func (w *replayWindow) reapLocked() {
	if w.timeWindow <= 0 {
		return
	}
	cutoff := time.Now().Add(-w.timeWindow)
	for offset, arrivalTime := range w.arrivalTimes {
		if arrivalTime.IsZero() || !arrivalTime.Before(cutoff) {
			continue
		}
		minimumID := w.highestID - uint32(offset) + 1
		if minimumID > w.minimumID {
			w.minimumID = minimumID
		}
		return
	}
}

func shiftReplayBitmap(bitmap []uint64, shift uint32) {
	wordShift := shift / 64
	bitShift := shift % 64
	wordCount := len(bitmap)
	for targetIndex := wordCount - 1; targetIndex >= 0; targetIndex-- {
		sourceIndex := targetIndex - int(wordShift)
		var result uint64
		if sourceIndex >= 0 {
			result = bitmap[sourceIndex] << bitShift
			if bitShift > 0 && sourceIndex-1 >= 0 {
				result |= bitmap[sourceIndex-1] >> (64 - bitShift)
			}
		}
		bitmap[targetIndex] = result
	}
}

func shiftReplayTimes(arrivalTimes []time.Time, shift uint32) {
	if shift == 0 || len(arrivalTimes) == 0 {
		return
	}
	if shift >= uint32(len(arrivalTimes)) {
		for i := range arrivalTimes {
			arrivalTimes[i] = time.Time{}
		}
		return
	}
	copy(arrivalTimes[shift:], arrivalTimes[:len(arrivalTimes)-int(shift)])
	for i := range int(shift) {
		arrivalTimes[i] = time.Time{}
	}
}
