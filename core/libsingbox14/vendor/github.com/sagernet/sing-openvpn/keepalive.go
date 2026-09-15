package openvpn

import (
	"bytes"
	"sync"
)

var openVPNDataChannelPingPayload = []byte{
	0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb,
	0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48,
}

// Upstream occ.c uses this 16-byte OCC magic.
var openVPNOCCMagic = []byte{
	0x28, 0x7f, 0x34, 0x6b, 0xd4, 0xef, 0x7a, 0x81,
	0x2d, 0x56, 0xb8, 0xd3, 0xaf, 0xc5, 0x45, 0x9c,
}

const (
	openVPNOCCRequest byte = 0
	openVPNOCCReply   byte = 1
	openVPNOCCExit    byte = 6
)

// Upstream occ_send_exit_msg/process_received_occ_msg use OCC_EXIT.
var openVPNDataChannelExitNotifyPayload = append(append([]byte{}, openVPNOCCMagic...), openVPNOCCExit)

func occOpcode(payload []byte) int {
	if !bytes.HasPrefix(payload, openVPNOCCMagic) {
		return -1
	}
	if len(payload) < len(openVPNOCCMagic)+1 {
		return -1
	}
	return int(payload[len(openVPNOCCMagic)])
}

// Upstream process_received_occ_msg writes a trailing NUL in OCC_REPLY.
func buildOCCReplyPayload(optionsString string) []byte {
	payload := make([]byte, 0, len(openVPNOCCMagic)+1+len(optionsString)+1)
	payload = append(payload, openVPNOCCMagic...)
	payload = append(payload, openVPNOCCReply)
	payload = append(payload, []byte(optionsString)...)
	payload = append(payload, 0)
	return payload
}

// Upstream process_received_occ_msg replies only to OCC_REQUEST.
func buildOCCResponseForIncoming(incomingPayload []byte, localOptionsString string) ([]byte, bool) {
	switch occOpcode(incomingPayload) {
	case int(openVPNOCCRequest):
		if localOptionsString == "" {
			return nil, false
		}
		return buildOCCReplyPayload(localOptionsString), true
	default:
		return nil, false
	}
}

// Upstream never emits a keepalive or an OCC message from the code that decides
// to send it: check_ping_send_dowork (ping.c) and process_received_occ_msg
// (occ.c) only stamp the instance's single outgoing slot, and
// process_outgoing_link (forward.c) writes it whenever the link takes it.  The
// coarse timers in check_coarse_timers and the packet processing in
// process_incoming_link therefore keep running while the link holds a packet,
// and a message the link refuses is charged to check_status alone: it never
// stops a timer and never ends the instance.  occ_op likewise holds one message
// at a time, so a newer one replaces the one still waiting.
type dataChannelMessageSender struct {
	writeDataPacket func(payload []byte) error

	access      sync.Mutex
	closed      bool
	pingPending bool
	occMessage  []byte

	wake    chan struct{}
	closing chan struct{}
}

func startDataChannelMessageSender(writeDataPacket func(payload []byte) error) *dataChannelMessageSender {
	sender := &dataChannelMessageSender{
		writeDataPacket: writeDataPacket,
		wake:            make(chan struct{}, 1),
		closing:         make(chan struct{}),
	}
	go sender.runLoop()
	return sender
}

func (s *dataChannelMessageSender) sendPing() {
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		return
	}
	s.pingPending = true
	s.access.Unlock()
	s.signal()
}

func (s *dataChannelMessageSender) sendOCCMessage(payload []byte) {
	if len(payload) == 0 {
		return
	}
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		return
	}
	s.occMessage = payload
	s.access.Unlock()
	s.signal()
}

func (s *dataChannelMessageSender) shutdown() {
	s.access.Lock()
	if s.closed {
		s.access.Unlock()
		return
	}
	s.closed = true
	s.pingPending = false
	s.occMessage = nil
	s.access.Unlock()
	close(s.closing)
}

func (s *dataChannelMessageSender) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *dataChannelMessageSender) takePendingMessage() ([]byte, bool) {
	s.access.Lock()
	defer s.access.Unlock()
	if s.closed {
		return nil, false
	}
	if s.pingPending {
		s.pingPending = false
		return openVPNDataChannelPingPayload, true
	}
	if s.occMessage != nil {
		occMessage := s.occMessage
		s.occMessage = nil
		return occMessage, true
	}
	return nil, false
}

func (s *dataChannelMessageSender) runLoop() {
	for {
		select {
		case <-s.closing:
			return
		case <-s.wake:
		}
		for {
			message, hasMessage := s.takePendingMessage()
			if !hasMessage {
				break
			}
			_ = s.writeDataPacket(message)
		}
	}
}
