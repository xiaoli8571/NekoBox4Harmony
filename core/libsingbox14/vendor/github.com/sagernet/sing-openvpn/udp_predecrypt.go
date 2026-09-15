package openvpn

import (
	"net"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	E "github.com/sagernet/sing/common/exceptions"
)

type udpPreDecryptVerdict uint8

const (
	udpPreDecryptDrop udpPreDecryptVerdict = iota
	udpPreDecryptChallenge
	udpPreDecryptAccept
)

type udpPreDecryptResult struct {
	verdict         udpPreDecryptVerdict
	packet          *proto.Packet
	protection      tlsControlProtection
	challenge       []byte
	serverSessionID proto.SessionID
	clientSessionID proto.SessionID
	directReset     bool
}

// Upstream tls_pre_decrypt_lite admits only key-state zero packets which
// can participate in the initial three-way exchange reach static-key crypto.
func isPossibleUDPPreDecryptPacket(rawPacket []byte) bool {
	if len(rawPacket) < tlsControlHeaderLength || rawPacket[0]&0x07 != 0 {
		return false
	}
	var clientSessionID proto.SessionID
	copy(clientSessionID[:], rawPacket[1:tlsControlHeaderLength])
	if clientSessionID == (proto.SessionID{}) {
		return false
	}
	switch proto.Opcode(rawPacket[0] >> 3) {
	case proto.OpcodeControlHardResetClientV2,
		proto.OpcodeControlHardResetClientV3,
		proto.OpcodeControlV1,
		proto.OpcodeAcknowledgmentV1,
		proto.OpcodeControlWKCv1:
		return true
	default:
		return false
	}
}

func (s *tlsServer) preDecryptUDPPacket(rawPacket []byte, peerAddress net.Addr, now time.Time) (udpPreDecryptResult, error) {
	packet, protection, earlyNegotiation, err := s.decodeUDPPreDecryptPacket(rawPacket)
	if err != nil {
		return udpPreDecryptResult{verdict: udpPreDecryptDrop}, err
	}
	if packet.KeyID != 0 || packet.LocalSessionID == (proto.SessionID{}) {
		return udpPreDecryptResult{verdict: udpPreDecryptDrop}, E.New("invalid UDP pre-decrypt identity")
	}

	switch packet.Opcode {
	case proto.OpcodeControlHardResetClientV2, proto.OpcodeControlHardResetClientV3:
		err = validateInitialClientReset(packet)
		if err != nil {
			return udpPreDecryptResult{verdict: udpPreDecryptDrop}, err
		}
		// Upstream charges its --connect-freq-initial budget to initial resets only,
		// leaving every later pre-decrypt opcode unmetered.
		if !s.resourcePolicy.allowInitialPacket(now) {
			return udpPreDecryptResult{verdict: udpPreDecryptDrop}, E.New("initial packet rate limit exceeded")
		}
		if packet.Opcode == proto.OpcodeControlHardResetClientV3 && !earlyNegotiation {
			if s.parent.options.TLS.CryptV2ForceCookie {
				return udpPreDecryptResult{verdict: udpPreDecryptDrop}, E.New("tls-crypt-v2 client does not support stateless cookie negotiation")
			}
			// Upstream defaults to allow-noncookie for compatibility with clients
			// which cannot resend the wrapped client key.  The decoded first reset
			// and its per-client tls-crypt key become the new session's initial
			// state instead of issuing a stateless cookie challenge.
			return udpPreDecryptResult{
				verdict:     udpPreDecryptAccept,
				packet:      packet,
				protection:  protection,
				directReset: true,
			}, nil
		}
		serverSessionID := s.sessionIDHMACSigner.deriveSessionIDAt(packet.LocalSessionID, peerAddress, now.Unix(), 0)
		challengePacket := &proto.Packet{
			Opcode:            proto.OpcodeControlHardResetServerV2,
			KeyID:             0,
			LocalSessionID:    serverSessionID,
			AcknowledgmentIDs: []proto.PacketID{packet.ID},
			RemoteSessionID:   packet.LocalSessionID,
			ID:                0,
		}
		if packet.Opcode == proto.OpcodeControlHardResetClientV3 {
			challengePacket.Payload = []byte{
				0x00, tlsCryptV2TLVTypeEarlyNegotiationFlags,
				0x00, 0x02,
				0x00, tlsCryptV2EarlyNegotiationFlagResendWKC,
			}
		}
		challenge, encodeErr := encodeUDPPreDecryptPacket(challengePacket, protection)
		if encodeErr != nil {
			return udpPreDecryptResult{verdict: udpPreDecryptDrop}, encodeErr
		}
		return udpPreDecryptResult{
			verdict:         udpPreDecryptChallenge,
			challenge:       challenge,
			serverSessionID: serverSessionID,
			clientSessionID: packet.LocalSessionID,
		}, nil

	case proto.OpcodeControlV1, proto.OpcodeAcknowledgmentV1, proto.OpcodeControlWKCv1:
		if len(packet.AcknowledgmentIDs) == 0 || packet.RemoteSessionID == (proto.SessionID{}) {
			return udpPreDecryptResult{verdict: udpPreDecryptDrop}, E.New("missing UDP session-id cookie")
		}
		if !s.sessionIDHMACSigner.validateAt(packet.LocalSessionID, peerAddress, packet.RemoteSessionID, now.Unix()) {
			return udpPreDecryptResult{verdict: udpPreDecryptDrop}, E.New("invalid UDP session-id cookie")
		}
		seedUDPProtectionAfterChallenge(protection)
		return udpPreDecryptResult{
			verdict:         udpPreDecryptAccept,
			packet:          packet,
			protection:      protection,
			serverSessionID: packet.RemoteSessionID,
			clientSessionID: packet.LocalSessionID,
		}, nil
	default:
		return udpPreDecryptResult{verdict: udpPreDecryptDrop}, E.New("invalid UDP pre-decrypt opcode")
	}
}

func (s *tlsServer) decodeUDPPreDecryptPacket(rawPacket []byte) (*proto.Packet, tlsControlProtection, bool, error) {
	opcode := proto.Opcode(rawPacket[0] >> 3)
	protection := s.staticProtection.newSessionProtection()
	packetBytes, err := protection.decodeIncomingControlPacket(rawPacket)
	if err != nil {
		return nil, tlsControlProtection{}, false, err
	}
	packet, err := proto.ParsePacket(packetBytes)
	if err != nil {
		return nil, tlsControlProtection{}, false, err
	}
	if packet.Opcode != opcode {
		return nil, tlsControlProtection{}, false, E.New("UDP pre-decrypt opcode mismatch")
	}
	earlyNegotiation := opcode == proto.OpcodeControlHardResetClientV3 && tlsCryptV2ResetAnnouncesEarlyNegotiation(rawPacket)
	return packet, protection, earlyNegotiation, nil
}

func encodeUDPPreDecryptPacket(packet *proto.Packet, protection tlsControlProtection) ([]byte, error) {
	rawPacket, err := packet.Bytes()
	if err != nil {
		return nil, err
	}
	return protection.encodeOutgoingControlPacket(rawPacket), nil
}

// Upstream session_skip_to_pre_start starts the admitted key_state's reliable
// stream at packet-id 1 and its tls-auth/tls-crypt wrapper at packet-id 2 after
// the stateless challenge consumed protected packet-id 1.
func seedUDPProtectionAfterChallenge(protection tlsControlProtection) {
	if protection.auth != nil {
		protection.auth.sendState.seedNextID(1)
	}
	if protection.crypt != nil {
		protection.crypt.sendState.seedNextID(1)
	}
}
