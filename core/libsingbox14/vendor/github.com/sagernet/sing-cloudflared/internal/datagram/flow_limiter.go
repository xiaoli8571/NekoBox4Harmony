package datagram

import "sync"

type FlowLimiter struct {
	access sync.Mutex
	active uint64
}

func (l *FlowLimiter) Acquire(limit uint64) bool {
	if limit == 0 {
		return true
	}
	l.access.Lock()
	defer l.access.Unlock()
	if l.active >= limit {
		return false
	}
	l.active++
	return true
}

func (l *FlowLimiter) Release(limit uint64) {
	if limit == 0 {
		return
	}
	l.access.Lock()
	defer l.access.Unlock()
	if l.active > 0 {
		l.active--
	}
}
