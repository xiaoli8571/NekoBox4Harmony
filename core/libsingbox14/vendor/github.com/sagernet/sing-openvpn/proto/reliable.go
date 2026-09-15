package proto

import (
	"slices"
	"sort"
	"sync"
	"time"
)

const (
	ReliableSendBufferSize          = 6
	ReliableReceiveBufferSize       = 12
	MaximumAcknowledgmentsPerPacket = 4
	AcknowledgmentSetCapacity       = 8
	InitialRetransmissionTimeout    = 2 * time.Second
	MaximumRetransmissionTimeout    = 60 * time.Second
	RecommendedSenderWakeupPeriod   = 60 * time.Second
	FastRetransmissionACKThreshold  = 3
)

type inFlightPacket struct {
	packet                   *Packet
	retransmissionDeadline   time.Time
	higherPacketAcknowledges int
	retransmissionCount      int
}

func (p *inFlightPacket) scheduleForRetransmission(now time.Time) {
	p.retransmissionCount++
	retransmissionInterval := InitialRetransmissionTimeout * time.Duration(1<<max(0, p.retransmissionCount-1))
	retransmissionInterval = min(retransmissionInterval, MaximumRetransmissionTimeout)
	p.retransmissionDeadline = now.Add(retransmissionInterval)
}

type OutgoingReliableState struct {
	access                  sync.Mutex
	inFlightPackets         []*inFlightPacket
	pendingAcknowledgmentID map[PacketID]struct{}
}

func NewOutgoingReliableState() *OutgoingReliableState {
	return &OutgoingReliableState{
		inFlightPackets:         make([]*inFlightPacket, 0, ReliableSendBufferSize),
		pendingAcknowledgmentID: make(map[PacketID]struct{}),
	}
}

// Upstream write_outgoing_tls_ciphertext takes the send buffer slot with
// reliable_get_buf_output_sequenced, reliable_mark_active_outgoing spends the
// control packet id on that slot and write_control_auth then moves the
// acknowledgment ids out of the pending list into the packet, all without
// releasing the reliable layer in between: no packet id is spent for a packet
// the send buffer cannot hold, and no acknowledgment id leaves the pending list
// for a packet which is never built.  A full send buffer returns no packet and
// takes nothing.
func (s *OutgoingReliableState) InsertOutgoingPacket(
	maximumAcknowledgments int,
	newPacket func(acknowledgmentIDs []PacketID) (*Packet, error),
) (*Packet, error) {
	s.access.Lock()
	defer s.access.Unlock()
	if len(s.inFlightPackets) >= ReliableSendBufferSize {
		return nil, nil
	}
	acknowledgmentIDs := s.takeAcknowledgmentIDsLocked(maximumAcknowledgments)
	packet, err := newPacket(acknowledgmentIDs)
	if err != nil {
		s.returnAcknowledgmentIDsLocked(acknowledgmentIDs)
		return nil, err
	}
	s.inFlightPackets = append(s.inFlightPackets, &inFlightPacket{packet: packet})
	sort.SliceStable(s.inFlightPackets, func(leftIndex, rightIndex int) bool {
		return s.inFlightPackets[leftIndex].packet.ID < s.inFlightPackets[rightIndex].packet.ID
	})
	return packet, nil
}

func (s *OutgoingReliableState) OnIncomingPacket(packet *Packet) {
	s.access.Lock()
	defer s.access.Unlock()

	if packet.Opcode != OpcodeAcknowledgmentV1 && len(s.pendingAcknowledgmentID) < AcknowledgmentSetCapacity {
		s.pendingAcknowledgmentID[packet.ID] = struct{}{}
	}
	for _, acknowledgedID := range packet.AcknowledgmentIDs {
		for packetIndex := 0; packetIndex < len(s.inFlightPackets); packetIndex++ {
			trackedPacket := s.inFlightPackets[packetIndex]
			if acknowledgedID == trackedPacket.packet.ID {
				lastIndex := len(s.inFlightPackets) - 1
				s.inFlightPackets[packetIndex], s.inFlightPackets[lastIndex] = s.inFlightPackets[lastIndex], s.inFlightPackets[packetIndex]
				s.inFlightPackets = s.inFlightPackets[:lastIndex]
				packetIndex--
				continue
			}
			if acknowledgedID > trackedPacket.packet.ID {
				trackedPacket.higherPacketAcknowledges++
			}
		}
	}
	sort.SliceStable(s.inFlightPackets, func(leftIndex, rightIndex int) bool {
		return s.inFlightPackets[leftIndex].packet.ID < s.inFlightPackets[rightIndex].packet.ID
	})
}

// Upstream reliable_ack_outstanding, which calc_control_channel_frame_overhead
// reads to size a control packet without consuming anything.
func (s *OutgoingReliableState) PendingAcknowledgmentCount() int {
	s.access.Lock()
	defer s.access.Unlock()
	return len(s.pendingAcknowledgmentID)
}

// Upstream reliable_ack_write, which removes exactly the ids it wrote into the
// packet buffer write_control_auth hands to the link.
func (s *OutgoingReliableState) TakeAcknowledgmentIDs(maximumCount int) []PacketID {
	s.access.Lock()
	defer s.access.Unlock()
	return s.takeAcknowledgmentIDsLocked(maximumCount)
}

// A packet which never reached the link acknowledges nothing, so the ids it
// took belong back on the pending list.
func (s *OutgoingReliableState) ReturnAcknowledgmentIDs(acknowledgmentIDs []PacketID) {
	s.access.Lock()
	defer s.access.Unlock()
	s.returnAcknowledgmentIDsLocked(acknowledgmentIDs)
}

func (s *OutgoingReliableState) takeAcknowledgmentIDsLocked(maximumCount int) []PacketID {
	if maximumCount <= 0 || len(s.pendingAcknowledgmentID) == 0 {
		return nil
	}
	acknowledgmentIDs := make([]PacketID, 0, len(s.pendingAcknowledgmentID))
	for pendingID := range s.pendingAcknowledgmentID {
		acknowledgmentIDs = append(acknowledgmentIDs, pendingID)
	}
	slices.Sort(acknowledgmentIDs)
	if len(acknowledgmentIDs) > maximumCount {
		acknowledgmentIDs = acknowledgmentIDs[:maximumCount]
	}
	for _, acknowledgedID := range acknowledgmentIDs {
		delete(s.pendingAcknowledgmentID, acknowledgedID)
	}
	return acknowledgmentIDs
}

func (s *OutgoingReliableState) returnAcknowledgmentIDsLocked(acknowledgmentIDs []PacketID) {
	for _, acknowledgmentID := range acknowledgmentIDs {
		_, pending := s.pendingAcknowledgmentID[acknowledgmentID]
		if !pending && len(s.pendingAcknowledgmentID) >= AcknowledgmentSetCapacity {
			return
		}
		s.pendingAcknowledgmentID[acknowledgmentID] = struct{}{}
	}
}

func (s *OutgoingReliableState) HasInFlightPackets() bool {
	s.access.Lock()
	defer s.access.Unlock()
	return len(s.inFlightPackets) > 0
}

func (s *OutgoingReliableState) PacketsReadyToSend(now time.Time) []*Packet {
	s.access.Lock()
	defer s.access.Unlock()

	var readyPackets []*Packet
	for _, readyPacket := range s.inFlightPackets {
		if readyPacket.retransmissionDeadline.IsZero() ||
			!readyPacket.retransmissionDeadline.After(now) ||
			readyPacket.higherPacketAcknowledges >= FastRetransmissionACKThreshold {
			readyPacket.scheduleForRetransmission(now)
			readyPackets = append(readyPackets, readyPacket.packet)
		}
	}
	return readyPackets
}

type IncomingReliableState struct {
	access         sync.Mutex
	pendingPackets []*Packet
	bufferedID     map[PacketID]struct{}
	lastConsumedID PacketID
}

func NewIncomingReliableState() *IncomingReliableState {
	return &IncomingReliableState{
		pendingPackets: make([]*Packet, 0, ReliableReceiveBufferSize),
		bufferedID:     make(map[PacketID]struct{}),
	}
}

func (s *IncomingReliableState) TryInsertIncomingPacket(packet *Packet) bool {
	s.access.Lock()
	defer s.access.Unlock()
	if packet.ID <= s.lastConsumedID {
		return false
	}
	if _, buffered := s.bufferedID[packet.ID]; buffered {
		return false
	}
	nextExpectedID := s.lastConsumedID + 1
	if packet.ID-nextExpectedID >= ReliableReceiveBufferSize {
		return false
	}
	if len(s.pendingPackets) >= ReliableReceiveBufferSize {
		return false
	}
	s.pendingPackets = append(s.pendingPackets, packet)
	s.bufferedID[packet.ID] = struct{}{}
	return true
}

func (s *IncomingReliableState) NextOrderedSequence() []*Packet {
	s.access.Lock()
	defer s.access.Unlock()
	sort.SliceStable(s.pendingPackets, func(leftIndex, rightIndex int) bool {
		return s.pendingPackets[leftIndex].ID < s.pendingPackets[rightIndex].ID
	})

	var readyPackets []*Packet
	var retainedPackets []*Packet
	lastConsumedID := s.lastConsumedID
	for _, packet := range s.pendingPackets {
		if packet.ID == lastConsumedID+1 {
			readyPackets = append(readyPackets, packet)
			delete(s.bufferedID, packet.ID)
			lastConsumedID = packet.ID
			continue
		}
		if packet.ID > lastConsumedID+1 {
			retainedPackets = append(retainedPackets, packet)
		}
	}
	s.pendingPackets = retainedPackets
	s.lastConsumedID = lastConsumedID
	return readyPackets
}
