package openconnect

import (
	"context"
	"sync"
)

type dataPacketQueue[T any] struct {
	access   sync.Mutex
	items    []T
	head     int
	length   int
	notEmpty chan struct{}
	notFull  chan struct{}
	closed   bool
}

func newDataPacketQueue[T any](capacity int) *dataPacketQueue[T] {
	return &dataPacketQueue[T]{
		items:    make([]T, capacity),
		notEmpty: make(chan struct{}),
		notFull:  make(chan struct{}),
	}
}

func (q *dataPacketQueue[T]) PushBatch(ctx context.Context, items []T) int {
	pushed := 0
	for pushed < len(items) {
		q.access.Lock()
		if q.closed || ctx.Err() != nil {
			q.access.Unlock()
			return pushed
		}
		if q.length < len(q.items) {
			wasEmpty := q.length == 0
			tail := (q.head + q.length) % len(q.items)
			q.items[tail] = items[pushed]
			q.length++
			pushed++
			if wasEmpty {
				q.signalNotEmptyLocked()
			}
			q.access.Unlock()
			continue
		}
		notFull := q.notFull
		q.access.Unlock()
		select {
		case <-ctx.Done():
			return pushed
		case <-notFull:
		}
	}
	return pushed
}

func (q *dataPacketQueue[T]) Pop(maximumItems int) []T {
	q.access.Lock()
	count := q.length
	if maximumItems > 0 {
		count = min(count, maximumItems)
	}
	if count == 0 {
		q.access.Unlock()
		return nil
	}
	items := make([]T, count)
	for index := range count {
		itemIndex := (q.head + index) % len(q.items)
		items[index] = q.items[itemIndex]
		var zero T
		q.items[itemIndex] = zero
	}
	q.head = (q.head + count) % len(q.items)
	q.length -= count
	q.signalNotFullLocked()
	q.access.Unlock()
	return items
}

func (q *dataPacketQueue[T]) Wake() <-chan struct{} {
	q.access.Lock()
	defer q.access.Unlock()
	if q.length > 0 || q.closed {
		ready := make(chan struct{})
		close(ready)
		return ready
	}
	return q.notEmpty
}

func (q *dataPacketQueue[T]) Closed() bool {
	q.access.Lock()
	defer q.access.Unlock()
	return q.closed
}

func (q *dataPacketQueue[T]) Close() {
	q.access.Lock()
	if !q.closed {
		q.closed = true
		q.signalNotEmptyLocked()
		q.signalNotFullLocked()
	}
	q.access.Unlock()
}

func (q *dataPacketQueue[T]) Drain(release func(T)) {
	for _, item := range q.Pop(0) {
		if release != nil {
			release(item)
		}
	}
}

func (q *dataPacketQueue[T]) signalNotEmptyLocked() {
	close(q.notEmpty)
	q.notEmpty = make(chan struct{})
}

func (q *dataPacketQueue[T]) signalNotFullLocked() {
	close(q.notFull)
	q.notFull = make(chan struct{})
}
