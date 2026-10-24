// Package sessionstate implements the K2 test-session registry and state machine
// used by libsingbox14's V3 CGo exports (CGoTestStart/Proxy/Stop/SessionInfo/
// ActiveSessions V3).
//
// Why a separate module: the registry must be unit-testable on the host
// (tests/hostprobe/k2_session_test.go) without cgo, without sing-box and
// without starting a real box. Keeping it a zero-dependency module lets the
// host probe import exactly this code instead of a copy, so the tests cannot
// drift from the shipping implementation. It is deliberately free of any
// sing-box import: the kernel wrapper supplies an opaque Closer.
//
// State machine (single active session, serial semantics):
//
//	(start)  -> starting --create ok--> active --stop--> stopping --> closed
//	               |                       ^
//	               +--create failed--> closed (entry removed, retryable)
//	               +--stop during create--> closed + tombstone (late start refused)
//
// Concurrency contract:
//   - the registry mutex is only held for short, non-blocking critical
//     sections; create()/Close()/probes always run outside it;
//   - Stop returns only after the underlying instance has been closed (or
//     after a concurrent start aborted), never before;
//   - a stopped id becomes a tombstone so a late start for that id never
//     creates a new instance (docs/p0-baseline/kernel-capabilities.md §3.2).
package sessionstate

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// Session states reported by Info and CGoTestSessionInfoV3.
const (
	StateStarting = "starting"
	StateActive   = "active"
	StateStopping = "stopping"
	StateClosed   = "closed"
)

// MaxSessionIDLen bounds the session id length accepted from ArkTS.
const MaxSessionIDLen = 128

// MaxTombstones bounds how many closed session ids stay queryable. The UI uses
// one id per test run; without a bound the map would grow for the lifetime of
// the (long-lived) UI process.
const MaxTombstones = 64

// Closer is the only thing the registry needs from an underlying test
// instance (the kernel wrapper supplies its box handle).
type Closer interface {
	Close() error
}

// Info is the snapshot returned by Registry.Info and marshalled by
// CGoTestSessionInfoV3. Field names match the ArkTS-side contract.
type Info struct {
	SessionID string `json:"sessionId"`
	State     string `json:"state"`
	StartedAt int64  `json:"startedAt"`
	Probes    int64  `json:"probes"`
	LastTag   string `json:"lastTag"`
	Tombstone bool   `json:"tombstone"`
}

type session struct {
	id        string
	state     string
	startedAt int64
	// seq is a monotonic creation counter; tombstone pruning orders by it
	// because several sessions can share the same millisecond timestamp.
	seq       int64
	probes    int64
	lastTag   string
	tombstone bool

	handle    Closer
	ctx       context.Context
	cancel    context.CancelFunc
	closeErr  error
	closed    chan struct{}
	closedOne sync.Once
}

// Registry is the K2 session registry. The zero value is not usable; call New.
type Registry struct {
	mu       sync.Mutex
	sessions map[string]*session
	seq      int64
	now      func() time.Time
}

// New returns an empty registry.
func New() *Registry {
	return &Registry{
		sessions: make(map[string]*session),
		now:      time.Now,
	}
}

// ValidateID rejects session ids that are empty (or blank), too long or contain
// control characters (they end up in log lines and in the info JSON).
func ValidateID(id string) error {
	if strings.TrimSpace(id) == "" {
		return fmt.Errorf("session id is empty")
	}
	if len(id) > MaxSessionIDLen {
		return fmt.Errorf("session id is too long (max %d bytes)", MaxSessionIDLen)
	}
	for _, r := range id {
		if r < 0x20 || r == 0x7f {
			return fmt.Errorf("session id contains control characters")
		}
	}
	return nil
}

func errAlreadyActive(id string) error { return fmt.Errorf("session %s already active", id) }
func errIsStopping(id string) error    { return fmt.Errorf("session %s is stopping", id) }
func errOtherActive(id string) error   { return fmt.Errorf("another test session %s is active", id) }
func errCancelled(id string) error     { return fmt.Errorf("session %s cancelled during start", id) }
func errNotFound(id string) error      { return fmt.Errorf("session %s not found", id) }

// Start registers id and runs create() to build the underlying test instance.
//
// It returns nil only after the instance is active. If a Stop for the same id
// arrives while create() is running, create() is still allowed to finish, but
// the freshly built instance is closed immediately, the id is tombstoned and
// the error "session <id> cancelled during start" is returned — the cancelled
// session never becomes visible to probes.
func (r *Registry) Start(id string, create func() (Closer, error)) (Closer, error) {
	if err := ValidateID(id); err != nil {
		return nil, err
	}
	if create == nil {
		return nil, fmt.Errorf("session %s: create callback is nil", id)
	}

	r.mu.Lock()
	if s, ok := r.sessions[id]; ok {
		switch s.state {
		case StateStarting, StateActive:
			r.mu.Unlock()
			return nil, errAlreadyActive(id)
		case StateStopping:
			r.mu.Unlock()
			return nil, errIsStopping(id)
		default: // closed / tombstone: never resurrect a stopped id
			r.mu.Unlock()
			return nil, errCancelled(id)
		}
	}
	// Serial semantics: at most one live test session. Report the blocker by
	// id so the caller can log which run owns the kernel.
	for otherID, other := range r.sessions {
		if otherID == id || other.state == StateClosed {
			continue
		}
		if other.state == StateStopping {
			r.mu.Unlock()
			return nil, errIsStopping(otherID)
		}
		r.mu.Unlock()
		return nil, errOtherActive(otherID)
	}

	ctx, cancel := context.WithCancel(context.Background())
	r.seq++
	s := &session{
		id:        id,
		state:     StateStarting,
		startedAt: r.now().UnixMilli(),
		seq:       r.seq,
		ctx:       ctx,
		cancel:    cancel,
		closed:    make(chan struct{}),
	}
	r.sessions[id] = s
	r.mu.Unlock()

	// Slow part (config parse + box.New + box.Start) runs without the lock so
	// Stop can observe the "starting" entry and cancel it.
	handle, createErr := create()

	r.mu.Lock()
	if createErr != nil {
		// A failed creation leaves nothing behind: drop the entry so the same
		// id can be retried after the config is fixed, and wake a waiting Stop.
		delete(r.sessions, id)
		s.state = StateClosed
		s.closeErr = createErr
		s.signalClosed()
		r.mu.Unlock()
		return nil, createErr
	}
	if s.state == StateStopping {
		// Stop landed during create(): close the new instance before it ever
		// becomes visible, tombstone the id, then unblock the waiting Stop.
		s.state = StateStopping // keep stopping while we close outside the lock
		r.mu.Unlock()
		closeErr := handle.Close()
		r.mu.Lock()
		s.closeErr = closeErr
		s.tombstone = true
		r.markClosedLocked(s)
		r.mu.Unlock()
		return nil, errCancelled(id)
	}
	s.handle = handle
	s.state = StateActive
	r.mu.Unlock()
	return handle, nil
}

// Stop closes the session and returns only after the instance is gone.
//
// Idempotent: stopping an unknown, already-closed or already-tombstoned id
// returns nil ("" for the exporter) and records a tombstone, so a late Start
// for that id can never create an instance afterwards.
// The returned error is the underlying Close error, if any.
func (r *Registry) Stop(id string) error {
	if err := ValidateID(id); err != nil {
		return err
	}

	r.mu.Lock()
	s, ok := r.sessions[id]
	if !ok {
		// Unknown id: idempotent success, but poison the id for late starts.
		r.tombstoneLocked(id)
		r.mu.Unlock()
		return nil
	}
	switch s.state {
	case StateClosed:
		r.mu.Unlock()
		return nil
	case StateStarting:
		// create() is in flight: cancel the session context (no probe can be
		// running yet) and wait for start to close whatever it built.
		s.state = StateStopping
		s.cancel()
		closed := s.closed
		r.mu.Unlock()
		<-closed
		r.mu.Lock()
		err := s.closeErr
		r.mu.Unlock()
		return err
	case StateActive:
		s.state = StateStopping
		s.cancel() // abort in-flight probes as fast as their context allows
		handle := s.handle
		r.mu.Unlock()
		var closeErr error
		if handle != nil {
			closeErr = handle.Close()
		}
		r.mu.Lock()
		s.closeErr = closeErr
		s.tombstone = true
		r.markClosedLocked(s)
		r.mu.Unlock()
		return closeErr
	default: // StateStopping: another Stop is already closing it
		closed := s.closed
		r.mu.Unlock()
		<-closed
		r.mu.Lock()
		err := s.closeErr
		r.mu.Unlock()
		return err
	}
}

// BeginProbe validates that id is active, accounts the probe and hands back the
// instance handle plus the session context (cancelled by Stop). Callers must
// not hold registry locks while probing.
func (r *Registry) BeginProbe(id string, tag string) (Closer, context.Context, error) {
	if err := ValidateID(id); err != nil {
		return nil, nil, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.sessions[id]
	if !ok || s.state != StateActive || s.handle == nil || s.ctx == nil {
		return nil, nil, errNotFound(id)
	}
	s.probes++
	s.lastTag = tag
	return s.handle, s.ctx, nil
}

// Info returns a snapshot for id. ok is false for ids this registry has never
// seen (the exporter maps that to ""). Closed ids keep reporting
// state=closed + tombstone=true.
func (r *Registry) Info(id string) (Info, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.sessions[id]
	if !ok {
		return Info{}, false
	}
	return Info{
		SessionID: s.id,
		State:     s.state,
		StartedAt: s.startedAt,
		Probes:    s.probes,
		LastTag:   s.lastTag,
		Tombstone: s.tombstone,
	}, true
}

// ActiveIDs lists currently active session ids (at most one under the serial
// rule). Sorted for deterministic output/diagnostics.
func (r *Registry) ActiveIDs() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	ids := make([]string, 0, 1)
	for id, s := range r.sessions {
		if s.state == StateActive {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids
}

// ActiveSessions returns the comma-joined form used by CGoTestActiveSessionsV3.
func (r *Registry) ActiveSessions() string {
	return strings.Join(r.ActiveIDs(), ",")
}

// signalClosed wakes everyone waiting for the instance to be gone. Idempotent.
func (s *session) signalClosed() {
	s.closedOne.Do(func() { close(s.closed) })
}

// markClosedLocked moves s to closed, wakes waiters and bounds the tombstone set.
func (r *Registry) markClosedLocked(s *session) {
	s.state = StateClosed
	s.handle = nil
	s.signalClosed()
	r.pruneLocked()
}

// tombstoneLocked records id as stopped-and-closed so a late Start of that id is
// refused instead of creating a new (orphan) instance.
func (r *Registry) tombstoneLocked(id string) {
	if _, ok := r.sessions[id]; ok {
		return
	}
	r.seq++
	r.sessions[id] = &session{
		id:        id,
		state:     StateClosed,
		startedAt: r.now().UnixMilli(),
		seq:       r.seq,
		tombstone: true,
		closed:    make(chan struct{}),
	}
	r.sessions[id].signalClosed()
	r.pruneLocked()
}

// pruneLocked drops the oldest closed entries beyond MaxTombstones. Active,
// starting and stopping entries are never pruned.
func (r *Registry) pruneLocked() {
	var closedIDs []string
	for id, s := range r.sessions {
		if s.state == StateClosed {
			closedIDs = append(closedIDs, id)
		}
	}
	if len(closedIDs) <= MaxTombstones {
		return
	}
	sort.Slice(closedIDs, func(i, j int) bool {
		return r.sessions[closedIDs[i]].seq < r.sessions[closedIDs[j]].seq
	})
	for _, id := range closedIDs[:len(closedIDs)-MaxTombstones] {
		delete(r.sessions, id)
	}
}
