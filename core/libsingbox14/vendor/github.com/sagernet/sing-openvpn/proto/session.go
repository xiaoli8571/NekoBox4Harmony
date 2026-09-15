package proto

import (
	"crypto/rand"
	"math"
	"sync"

	E "github.com/sagernet/sing/common/exceptions"
)

type NegotiationState int

const (
	NegotiationStateInitial      NegotiationState = 1
	NegotiationStatePreStart     NegotiationState = 2
	NegotiationStateStart        NegotiationState = 3
	NegotiationStateControlReady NegotiationState = 6
)

var (
	ErrMissingRemoteSessionID = E.New("missing remote session id")
	ErrPacketIDExpired        = E.New("packet id expired")
	ErrInvalidOpcode          = E.New("invalid opcode for packet creation")
)

type SessionManager struct {
	access               sync.Mutex
	keyID                uint8
	localSessionID       SessionID
	remoteSessionID      SessionID
	hasRemoteSessionID   bool
	localControlPacketID PacketID
	localDataPacketID    PacketID
	negotiationState     NegotiationState
}

func NewSessionManager() (*SessionManager, error) {
	var localSessionID SessionID
	_, err := rand.Read(localSessionID[:])
	if err != nil {
		return nil, err
	}
	return NewSessionManagerWithLocalID(localSessionID), nil
}

func NewSessionManagerWithLocalID(localSessionID SessionID) *SessionManager {
	return &SessionManager{
		keyID:                0,
		localSessionID:       localSessionID,
		localControlPacketID: 1,
		localDataPacketID:    1,
		negotiationState:     NegotiationStateInitial,
	}
}

func (m *SessionManager) LocalSessionID() SessionID {
	m.access.Lock()
	defer m.access.Unlock()
	return m.localSessionID
}

func (m *SessionManager) RemoteSessionID() (SessionID, bool) {
	m.access.Lock()
	defer m.access.Unlock()
	return m.remoteSessionID, m.hasRemoteSessionID
}

// Upstream reliable_ack_read validates RemoteSessionID only when ACKs exist.
func (m *SessionManager) ValidateIncomingRemoteSessionID(packet *Packet) bool {
	if packet == nil {
		return false
	}
	if len(packet.AcknowledgmentIDs) == 0 {
		return true
	}
	var unsetSessionID SessionID
	if packet.RemoteSessionID == unsetSessionID {
		return false
	}
	m.access.Lock()
	defer m.access.Unlock()
	return packet.RemoteSessionID == m.localSessionID
}

func (m *SessionManager) ValidateIncomingLocalSessionID(packet *Packet) bool {
	if packet == nil {
		return false
	}
	m.access.Lock()
	defer m.access.Unlock()
	return m.hasRemoteSessionID && packet.LocalSessionID == m.remoteSessionID
}

func (m *SessionManager) SetRemoteSessionID(remoteSessionID SessionID) {
	m.access.Lock()
	defer m.access.Unlock()
	m.remoteSessionID = remoteSessionID
	m.hasRemoteSessionID = true
}

func (m *SessionManager) CurrentKeyID() uint8 {
	m.access.Lock()
	defer m.access.Unlock()
	return m.keyID
}

const KeyIDMaxValue = 7

func NextKeyID(keyID uint8) uint8 {
	if keyID >= KeyIDMaxValue {
		return 1
	}
	keyID++
	if keyID == 0 {
		return 1
	}
	return keyID
}

// Upstream key_state_init gives each soft-reset key_state fresh packet IDs.
func (m *SessionManager) NewRenegotiationSessionManager(keyID uint8) *SessionManager {
	m.access.Lock()
	defer m.access.Unlock()
	renegotiated := &SessionManager{
		keyID:                keyID,
		localSessionID:       m.localSessionID,
		localControlPacketID: 1,
		localDataPacketID:    1,
		negotiationState:     NegotiationStateStart,
	}
	if m.hasRemoteSessionID {
		renegotiated.remoteSessionID = m.remoteSessionID
		renegotiated.hasRemoteSessionID = true
	}
	return renegotiated
}

// Upstream session_move_pre_start sends P_CONTROL_SOFT_RESET_V1 as the
// initial reliable packet for the new key_state.
func (m *SessionManager) NewSoftResetPacket() (*Packet, error) {
	m.access.Lock()
	defer m.access.Unlock()
	if !m.hasRemoteSessionID {
		return nil, ErrMissingRemoteSessionID
	}
	return &Packet{
		Opcode:          OpcodeControlSoftResetV1,
		KeyID:           m.keyID,
		LocalSessionID:  m.localSessionID,
		RemoteSessionID: m.remoteSessionID,
		ID:              0,
	}, nil
}

func (m *SessionManager) NegotiationState() NegotiationState {
	m.access.Lock()
	defer m.access.Unlock()
	return m.negotiationState
}

func (m *SessionManager) SetNegotiationState(state NegotiationState) {
	m.access.Lock()
	defer m.access.Unlock()
	m.negotiationState = state
}

func (m *SessionManager) NewHardResetServerV2Packet(acknowledgmentIDs []PacketID) (*Packet, error) {
	m.access.Lock()
	defer m.access.Unlock()
	packet := &Packet{
		Opcode:            OpcodeControlHardResetServerV2,
		KeyID:             m.keyID,
		LocalSessionID:    m.localSessionID,
		AcknowledgmentIDs: append([]PacketID(nil), acknowledgmentIDs...),
		ID:                0,
	}
	if len(packet.AcknowledgmentIDs) > 0 {
		if !m.hasRemoteSessionID {
			return nil, ErrMissingRemoteSessionID
		}
		packet.RemoteSessionID = m.remoteSessionID
	}
	return packet, nil
}

func (m *SessionManager) NewAcknowledgmentPacket(acknowledgmentIDs []PacketID) (*Packet, error) {
	m.access.Lock()
	defer m.access.Unlock()
	if !m.hasRemoteSessionID {
		return nil, ErrMissingRemoteSessionID
	}
	return &Packet{
		Opcode:            OpcodeAcknowledgmentV1,
		KeyID:             m.keyID,
		LocalSessionID:    m.localSessionID,
		AcknowledgmentIDs: append([]PacketID(nil), acknowledgmentIDs...),
		RemoteSessionID:   m.remoteSessionID,
	}, nil
}

func (m *SessionManager) NextLocalControlPacketID() PacketID {
	m.access.Lock()
	defer m.access.Unlock()
	return m.localControlPacketID
}

func (m *SessionManager) NewControlPacket(opcode Opcode, payload []byte) (*Packet, error) {
	if !opcode.IsControl() {
		return nil, ErrInvalidOpcode
	}
	m.access.Lock()
	defer m.access.Unlock()
	if m.localControlPacketID == math.MaxUint32 {
		return nil, ErrPacketIDExpired
	}
	packetID := m.localControlPacketID
	m.localControlPacketID++
	packet := NewPacket(opcode, m.keyID, payload)
	packet.LocalSessionID = m.localSessionID
	packet.ID = packetID
	if m.hasRemoteSessionID {
		packet.RemoteSessionID = m.remoteSessionID
	}
	return packet, nil
}

func (m *SessionManager) NewDataPacketIDs(opcode Opcode, count int) ([]PacketID, error) {
	if !opcode.IsData() {
		return nil, ErrInvalidOpcode
	}
	if count == 0 {
		return nil, nil
	}
	m.access.Lock()
	availablePacketIDs := uint64(math.MaxUint32) - uint64(m.localDataPacketID)
	if count < 0 || uint64(count) > availablePacketIDs {
		m.access.Unlock()
		return nil, ErrPacketIDExpired
	}
	firstPacketID := m.localDataPacketID
	m.localDataPacketID += PacketID(count)
	m.access.Unlock()
	packetIDs := make([]PacketID, count)
	for i := range count {
		packetIDs[i] = firstPacketID + PacketID(i)
	}
	return packetIDs, nil
}
