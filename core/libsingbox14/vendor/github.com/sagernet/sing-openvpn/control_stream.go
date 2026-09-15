package openvpn

import (
	"crypto/tls"
	"os"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

// Upstream send_control_channel_string_dowork and tls_rec_payload (ssl.c) both
// address session->key[KS_PRIMARY], and key_state_soft_reset installs the key
// state a soft reset creates there before it is negotiated, moving the previous
// one to KS_LAME_DUCK.  tls_send_payload parks a control channel message in
// key_state.paybuf while KS_PRIMARY has not reached S_ACTIVE and tls_process
// flushes it once it does; tls_rec_payload hands out no plaintext until then and
// never reads the retired key state's plaintext_read_buf again.
type tlsPrimaryControlStream struct {
	access      sync.Mutex
	writeAccess sync.Mutex
	channel     *tlsControlChannel
	sequence    uint64
	handover    uint64
	installed   bool
	changed     chan struct{}
}

const primaryControlStreamPollInterval = time.Second

func (s *tlsPrimaryControlStream) changedLocked() chan struct{} {
	if s.changed == nil {
		s.changed = make(chan struct{})
	}
	return s.changed
}

func (s *tlsPrimaryControlStream) signalLocked() {
	if s.changed != nil {
		close(s.changed)
		s.changed = nil
	}
}

func (s *tlsPrimaryControlStream) install(channel *tlsControlChannel, sequence uint64) {
	if channel == nil {
		return
	}
	s.access.Lock()
	defer s.access.Unlock()
	if s.installed && sequence < s.sequence {
		return
	}
	s.channel = channel
	s.sequence = sequence
	s.installed = true
	if s.handover <= sequence {
		s.handover = 0
	}
	s.signalLocked()
}

func (s *tlsPrimaryControlStream) beginHandover(sequence uint64) {
	s.access.Lock()
	defer s.access.Unlock()
	if sequence <= s.sequence || sequence <= s.handover {
		return
	}
	s.handover = sequence
	s.signalLocked()
}

func (s *tlsPrimaryControlStream) abortHandover(sequence uint64) {
	s.access.Lock()
	defer s.access.Unlock()
	if s.handover != sequence {
		return
	}
	s.handover = 0
	s.signalLocked()
}

func (s *tlsPrimaryControlStream) snapshot() (*tls.Conn, uint64, chan struct{}) {
	s.access.Lock()
	defer s.access.Unlock()
	if s.handover != 0 || !s.installed {
		return nil, 0, s.changedLocked()
	}
	return s.channel.connection(), s.sequence, s.changedLocked()
}

func (s *tlsPrimaryControlStream) isCurrent(sequence uint64) bool {
	s.access.Lock()
	defer s.access.Unlock()
	return s.handover == 0 && s.installed && s.sequence == sequence
}

func (s *tlsPrimaryControlStream) currentChannel() *tlsControlChannel {
	s.access.Lock()
	defer s.access.Unlock()
	return s.channel
}

func awaitPrimaryControlStream(changed chan struct{}, deadline time.Time) error {
	timeout := time.Until(deadline)
	if timeout <= 0 {
		return os.ErrDeadlineExceeded
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-changed:
		return nil
	case <-timer.C:
		return os.ErrDeadlineExceeded
	}
}

func (s *tlsPeerSession) primaryControlChannel() *tlsControlChannel {
	return s.controlStream.currentChannel()
}

func (s *tlsPeerSession) readControlChannelRecord(deadline time.Time) ([]byte, error) {
	for {
		connection, sequence, changed := s.controlStream.snapshot()
		if connection == nil {
			waitErr := awaitPrimaryControlStream(changed, deadline)
			if waitErr != nil {
				return nil, waitErr
			}
			continue
		}
		readDeadline := deadline
		pollDeadline := time.Now().Add(primaryControlStreamPollInterval)
		if pollDeadline.Before(readDeadline) {
			readDeadline = pollDeadline
		}
		record, err := readTLSControlRecord(connection, readDeadline)
		if err != nil {
			if !E.IsTimeout(err) || !time.Now().Before(deadline) {
				return nil, err
			}
			continue
		}
		if !s.controlStream.isCurrent(sequence) {
			continue
		}
		return record, nil
	}
}

func (s *tlsPeerSession) writeControlChannelPayload(payload []byte, deadline time.Time) error {
	s.controlStream.writeAccess.Lock()
	defer s.controlStream.writeAccess.Unlock()
	for {
		connection, _, changed := s.controlStream.snapshot()
		if connection != nil {
			_, err := connection.Write(payload)
			return err
		}
		waitErr := awaitPrimaryControlStream(changed, deadline)
		if waitErr != nil {
			return waitErr
		}
	}
}
