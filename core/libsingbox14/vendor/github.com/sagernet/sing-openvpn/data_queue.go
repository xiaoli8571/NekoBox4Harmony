package openvpn

import (
	"context"
	"sync"
	"sync/atomic"

	"github.com/sagernet/sing/common/logger"
)

const (
	dataPacketBatchSize     = 64
	dataPacketQueueCapacity = 512
)

type dataPacketQueue[T any] struct {
	access sync.Mutex
	items  []T
	head   int
	length int
	wake   chan struct{}
}

func newDataPacketQueueWithCapacity[T any](capacity int) *dataPacketQueue[T] {
	return &dataPacketQueue[T]{
		items: make([]T, capacity),
		wake:  make(chan struct{}, 1),
	}
}

func (q *dataPacketQueue[T]) PushBatch(items []T, release func(T)) uint64 {
	if len(items) == 0 {
		return 0
	}
	q.access.Lock()
	wasEmpty := q.length == 0
	var dropped uint64
	for _, item := range items {
		if q.length == len(q.items) {
			droppedItem := q.items[q.head]
			var zero T
			q.items[q.head] = zero
			q.head = (q.head + 1) % len(q.items)
			q.length--
			dropped++
			if release != nil {
				release(droppedItem)
			}
		}
		tail := (q.head + q.length) % len(q.items)
		q.items[tail] = item
		q.length++
	}
	q.access.Unlock()
	if wasEmpty {
		q.signal()
	}
	return dropped
}

func (q *dataPacketQueue[T]) PushBatchDropNew(items []T, release func(T)) uint64 {
	if len(items) == 0 {
		return 0
	}
	q.access.Lock()
	wasEmpty := q.length == 0
	acceptedCount := min(len(items), len(q.items)-q.length)
	for _, item := range items[:acceptedCount] {
		tail := (q.head + q.length) % len(q.items)
		q.items[tail] = item
		q.length++
	}
	q.access.Unlock()
	for _, item := range items[acceptedCount:] {
		if release != nil {
			release(item)
		}
	}
	if wasEmpty && acceptedCount > 0 {
		q.signal()
	}
	return uint64(len(items) - acceptedCount)
}

func (q *dataPacketQueue[T]) Pop(max int, sameRun func(T, T) bool) []T {
	q.access.Lock()
	count := q.length
	if max > 0 {
		count = min(count, max)
	}
	if count == 0 {
		q.access.Unlock()
		return nil
	}
	if sameRun != nil && count > 1 {
		firstItem := q.items[q.head]
		for i := 1; i < count; i++ {
			index := (q.head + i) % len(q.items)
			if !sameRun(firstItem, q.items[index]) {
				count = i
				break
			}
		}
	}
	items := make([]T, count)
	for i := range count {
		index := (q.head + i) % len(q.items)
		items[i] = q.items[index]
		var zero T
		q.items[index] = zero
	}
	q.head = (q.head + count) % len(q.items)
	q.length -= count
	hasMore := q.length > 0
	q.access.Unlock()
	if hasMore {
		q.signal()
	}
	return items
}

func (q *dataPacketQueue[T]) Wake() <-chan struct{} {
	return q.wake
}

func (q *dataPacketQueue[T]) Drain(release func(T)) {
	for _, item := range q.Pop(0, nil) {
		if release != nil {
			release(item)
		}
	}
}

func (q *dataPacketQueue[T]) signal() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

const droppedPacketLogInterval = 256

type droppedPacketLog struct {
	logger  logger.ContextLogger
	ctx     context.Context
	dropped atomic.Uint64
}

func (l *droppedPacketLog) Log(err error) {
	if l.logger == nil {
		return
	}
	droppedCount := l.dropped.Add(1)
	if droppedCount == 1 {
		l.logger.WarnContext(l.ctx, "dropped invalid data packet: ", err)
	} else if droppedCount%droppedPacketLogInterval == 0 {
		l.logger.DebugContext(l.ctx, "dropped ", droppedCount, " invalid data packets, most recent: ", err)
	}
}

func (l *droppedPacketLog) LogMessage(message ...any) {
	if l.logger == nil {
		return
	}
	droppedCount := l.dropped.Add(1)
	if droppedCount == 1 {
		logArguments := append([]any{"dropped invalid data packet: "}, message...)
		l.logger.WarnContext(l.ctx, logArguments...)
	} else if droppedCount%droppedPacketLogInterval == 0 {
		logArguments := append([]any{"dropped ", droppedCount, " invalid data packets, most recent: "}, message...)
		l.logger.DebugContext(l.ctx, logArguments...)
	}
}

func (l *droppedPacketLog) Reset() {
	l.dropped.Store(0)
}
