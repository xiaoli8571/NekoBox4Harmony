package proto

import (
	"bytes"
	"encoding/binary"
	"io"
	"math"

	E "github.com/sagernet/sing/common/exceptions"
)

type Opcode uint8

const (
	OpcodeControlHardResetClientV1 Opcode = iota + 1
	OpcodeControlHardResetServerV1
	OpcodeControlSoftResetV1
	OpcodeControlV1
	OpcodeAcknowledgmentV1
	OpcodeDataV1
	OpcodeControlHardResetClientV2
	OpcodeControlHardResetServerV2
	OpcodeDataV2
	OpcodeControlHardResetClientV3
	OpcodeControlWKCv1
)

func (o Opcode) String() string {
	switch o {
	case OpcodeControlHardResetClientV1:
		return "P_CONTROL_HARD_RESET_CLIENT_V1"
	case OpcodeControlHardResetServerV1:
		return "P_CONTROL_HARD_RESET_SERVER_V1"
	case OpcodeControlSoftResetV1:
		return "P_CONTROL_SOFT_RESET_V1"
	case OpcodeControlV1:
		return "P_CONTROL_V1"
	case OpcodeAcknowledgmentV1:
		return "P_ACK_V1"
	case OpcodeDataV1:
		return "P_DATA_V1"
	case OpcodeControlHardResetClientV2:
		return "P_CONTROL_HARD_RESET_CLIENT_V2"
	case OpcodeControlHardResetServerV2:
		return "P_CONTROL_HARD_RESET_SERVER_V2"
	case OpcodeDataV2:
		return "P_DATA_V2"
	case OpcodeControlHardResetClientV3:
		return "P_CONTROL_HARD_RESET_CLIENT_V3"
	case OpcodeControlWKCv1:
		return "P_CONTROL_WKC_V1"
	default:
		return "P_UNKNOWN"
	}
}

func (o Opcode) IsControl() bool {
	switch o {
	case OpcodeControlHardResetClientV1,
		OpcodeControlHardResetServerV1,
		OpcodeControlSoftResetV1,
		OpcodeControlV1,
		OpcodeControlHardResetClientV2,
		OpcodeControlHardResetServerV2,
		OpcodeControlHardResetClientV3,
		OpcodeControlWKCv1:
		return true
	default:
		return false
	}
}

func (o Opcode) IsData() bool {
	switch o {
	case OpcodeDataV1, OpcodeDataV2:
		return true
	default:
		return false
	}
}

const (
	SessionIDLength = 8
	PacketIDLength  = 4
)

type (
	SessionID [SessionIDLength]byte
	PacketID  uint32
	PeerID    [3]byte
)

type Packet struct {
	Opcode            Opcode
	KeyID             uint8
	PeerID            PeerID
	LocalSessionID    SessionID
	AcknowledgmentIDs []PacketID
	RemoteSessionID   SessionID
	ID                PacketID
	Payload           []byte
}

var (
	ErrPacketTooShort  = E.New("packet too short")
	ErrPacketParse     = E.New("packet parse error")
	ErrPacketSerialize = E.New("packet serialize error")
)

func NewPacket(opcode Opcode, keyID uint8, payload []byte) *Packet {
	return &Packet{
		Opcode:            opcode,
		KeyID:             keyID,
		AcknowledgmentIDs: nil,
		Payload:           bytes.Clone(payload),
	}
}

func ParsePacket(rawPacket []byte) (*Packet, error) {
	if len(rawPacket) < 1 {
		return nil, ErrPacketTooShort
	}
	opcode := Opcode(rawPacket[0] >> 3)
	keyID := rawPacket[0] & 0x07

	packet := &Packet{
		Opcode: opcode,
		KeyID:  keyID,
	}
	packetBody := rawPacket[1:]
	if opcode == OpcodeDataV2 {
		if len(packetBody) < 3 {
			return nil, ErrPacketTooShort
		}
		copy(packet.PeerID[:], packetBody[:3])
		packetBody = packetBody[3:]
	}
	if opcode.IsControl() || opcode == OpcodeAcknowledgmentV1 {
		return parseControlOrAcknowledgmentPacket(packet, packetBody)
	}
	packet.Payload = append(packet.Payload, packetBody...)
	return packet, nil
}

func ParsePacketView(rawPacket []byte) (*Packet, error) {
	if len(rawPacket) < 1 {
		return nil, ErrPacketTooShort
	}
	opcode := Opcode(rawPacket[0] >> 3)
	if !opcode.IsData() {
		return ParsePacket(rawPacket)
	}
	packet := &Packet{
		Opcode: opcode,
		KeyID:  rawPacket[0] & 0x07,
	}
	packetBody := rawPacket[1:]
	if opcode == OpcodeDataV2 {
		if len(packetBody) < 3 {
			return nil, ErrPacketTooShort
		}
		copy(packet.PeerID[:], packetBody[:3])
		packetBody = packetBody[3:]
	}
	packet.Payload = packetBody
	return packet, nil
}

func parseControlOrAcknowledgmentPacket(packet *Packet, packetBody []byte) (*Packet, error) {
	if len(packetBody) < len(packet.LocalSessionID)+1 {
		return nil, ErrPacketTooShort
	}
	packetReader := bytes.NewReader(packetBody)
	_, err := io.ReadFull(packetReader, packet.LocalSessionID[:])
	if err != nil {
		return nil, E.Extend(ErrPacketParse, "read local session id: ", err)
	}
	acknowledgmentCount, err := packetReader.ReadByte()
	if err != nil {
		return nil, E.Extend(ErrPacketParse, "read acknowledgment count: ", err)
	}
	packet.AcknowledgmentIDs = make([]PacketID, int(acknowledgmentCount))
	for acknowledgmentIndex := 0; acknowledgmentIndex < len(packet.AcknowledgmentIDs); acknowledgmentIndex++ {
		var acknowledgmentValue uint32
		err = binary.Read(packetReader, binary.BigEndian, &acknowledgmentValue)
		if err != nil {
			return nil, E.Extend(ErrPacketParse, "read acknowledgment id: ", err)
		}
		packet.AcknowledgmentIDs[acknowledgmentIndex] = PacketID(acknowledgmentValue)
	}
	if len(packet.AcknowledgmentIDs) > 0 {
		_, err = io.ReadFull(packetReader, packet.RemoteSessionID[:])
		if err != nil {
			return nil, E.Extend(ErrPacketParse, "read remote session id: ", err)
		}
	}
	if packet.Opcode != OpcodeAcknowledgmentV1 {
		var packetID uint32
		err = binary.Read(packetReader, binary.BigEndian, &packetID)
		if err != nil {
			return nil, E.Extend(ErrPacketParse, "read packet id: ", err)
		}
		packet.ID = PacketID(packetID)
	}
	if packetReader.Len() > 0 {
		packet.Payload = make([]byte, packetReader.Len())
		_, err = io.ReadFull(packetReader, packet.Payload)
		if err != nil {
			return nil, E.Extend(ErrPacketParse, "read payload: ", err)
		}
	}
	return packet, nil
}

func (p *Packet) Bytes() ([]byte, error) {
	var packetBuffer bytes.Buffer
	packetBuffer.WriteByte((uint8(p.Opcode) << 3) | (p.KeyID & 0x07))

	if p.Opcode == OpcodeDataV2 {
		packetBuffer.Write(p.PeerID[:])
		packetBuffer.Write(p.Payload)
		return packetBuffer.Bytes(), nil
	}

	if p.Opcode.IsControl() || p.Opcode == OpcodeAcknowledgmentV1 {
		packetBuffer.Write(p.LocalSessionID[:])
		if len(p.AcknowledgmentIDs) > math.MaxUint8 {
			return nil, E.Extend(ErrPacketSerialize, "too many acknowledgments")
		}
		packetBuffer.WriteByte(uint8(len(p.AcknowledgmentIDs)))
		for _, acknowledgmentID := range p.AcknowledgmentIDs {
			err := binary.Write(&packetBuffer, binary.BigEndian, uint32(acknowledgmentID))
			if err != nil {
				return nil, E.Extend(ErrPacketSerialize, "write acknowledgment id: ", err)
			}
		}
		if len(p.AcknowledgmentIDs) > 0 {
			packetBuffer.Write(p.RemoteSessionID[:])
		}
		if p.Opcode != OpcodeAcknowledgmentV1 {
			err := binary.Write(&packetBuffer, binary.BigEndian, uint32(p.ID))
			if err != nil {
				return nil, E.Extend(ErrPacketSerialize, "write packet id: ", err)
			}
		}
		packetBuffer.Write(p.Payload)
		return packetBuffer.Bytes(), nil
	}

	packetBuffer.Write(p.Payload)
	return packetBuffer.Bytes(), nil
}
