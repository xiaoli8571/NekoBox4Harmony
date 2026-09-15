package openvpn

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/pem"
	"hash"
	"sync"
	"time"

	"github.com/sagernet/sing-openvpn/proto"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	tlsControlHeaderLength        = 1 + 8
	tlsControlPacketIDLength      = 8
	tlsCryptTagLength             = sha256.Size
	tlsCryptBlockLength           = aes.BlockSize
	tlsCryptV2ClientPEMType       = "OpenVPN tls-crypt-v2 client key"
	tlsCryptV2ServerPEMType       = "OpenVPN tls-crypt-v2 server key"
	tlsCryptV2ClientKeyDataLength = 256
	tlsCryptV2ServerKeyLength     = 128
	tlsCryptKeyDirectionNormal    = 0
	tlsCryptKeyDirectionInverse   = 1

	tlsCryptV2EarlyNegotiationStart         = 0x0f000000
	tlsCryptV2TLVTypeEarlyNegotiationFlags  = 0x0001
	tlsCryptV2EarlyNegotiationFlagResendWKC = 0x0001
)

// Upstream struct tls_wrap_ctx carries the tls-crypt-v2 server key next to the
// control channel keys, so read_control_auth can unwrap the client key of a
// P_CONTROL_HARD_RESET_CLIENT_V3 or P_CONTROL_WKC_V1 packet on any path that
// authenticates a control packet.
type tlsControlProtection struct {
	auth             *controlAuthCodec
	crypt            *controlCryptCodec
	cryptV2ServerKey []byte
}

// Upstream keeps tls-auth/tls-crypt packet-id and replay state local to each key_state.
func (p tlsControlProtection) newSessionProtection() tlsControlProtection {
	return tlsControlProtection{
		auth:             p.auth.newSessionCodec(),
		crypt:            p.crypt.newSessionCodec(),
		cryptV2ServerKey: p.cryptV2ServerKey,
	}
}

// Upstream calc_control_channel_frame_overhead books tls_crypt_buf_overhead for
// a TLS_WRAP_CRYPT session, which counts a cipher block the CTR mode stream
// never spends, and the HMAC plus the long form packet id for a TLS_WRAP_AUTH
// one.
func (p tlsControlProtection) controlPacketOverhead() int {
	if p.crypt != nil || len(p.cryptV2ServerKey) > 0 {
		return tlsControlPacketIDLength + tlsCryptTagLength + tlsCryptBlockLength
	}
	if p.auth != nil {
		return p.auth.digestSize + tlsControlPacketIDLength
	}
	return 0
}

func (p tlsControlProtection) encodeOutgoingControlPacket(rawPacket []byte) []byte {
	if p.crypt != nil {
		return p.crypt.encodeControlPacket(rawPacket)
	}
	if p.auth != nil {
		return p.auth.encodeControlPacket(rawPacket)
	}
	return rawPacket
}

// Upstream read_control_auth strips the appended wrapped client key before the
// remainder of the packet is authenticated, whatever state the session is in.
func (p *tlsControlProtection) decodeIncomingControlPacket(rawPacket []byte) ([]byte, error) {
	if len(rawPacket) < tlsControlHeaderLength {
		return nil, E.New("invalid tls control packet")
	}
	packetBytes := rawPacket
	opcode := proto.Opcode(rawPacket[0] >> 3)
	if opcode == proto.OpcodeControlHardResetClientV3 || opcode == proto.OpcodeControlWKCv1 {
		strippedPacket, err := p.extractTLSCryptV2ClientKey(rawPacket)
		if err != nil {
			return nil, err
		}
		packetBytes = strippedPacket
	}
	if p.crypt != nil {
		decodedPacket, decoded := p.crypt.decodeControlPacket(packetBytes)
		if !decoded {
			return nil, E.New("invalid tls-crypt packet")
		}
		return decodedPacket, nil
	}
	if p.auth != nil {
		decodedPacket, decoded := p.auth.decodeControlPacket(packetBytes)
		if !decoded {
			return nil, E.New("invalid tls-auth packet")
		}
		return decodedPacket, nil
	}
	// A tls-crypt-v2 server holds no control channel key until a wrapped client
	// key arrives, so upstream tls_crypt_unwrap rejects every other packet.
	if len(p.cryptV2ServerKey) > 0 {
		return nil, E.New("missing tls-crypt-v2 wrapped client key")
	}
	return packetBytes, nil
}

// Upstream tls_crypt_v2_extract_client_key ignores the wrapped key of a resent
// packet once the control channel keys are set up and returns the remaining
// packet, which turns a resent P_CONTROL_WKC_V1 into a plain P_CONTROL_V1.
func (p *tlsControlProtection) extractTLSCryptV2ClientKey(rawPacket []byte) ([]byte, error) {
	if len(p.cryptV2ServerKey) == 0 {
		return nil, E.New("peer wants tls-crypt-v2 but no server key is present")
	}
	if len(rawPacket) < tlsControlHeaderLength+2 {
		return nil, E.New("invalid tls-crypt-v2 packet")
	}
	wrappedKeyLength := int(binary.BigEndian.Uint16(rawPacket[len(rawPacket)-2:]))
	if wrappedKeyLength < tlsCryptTagLength+2 || wrappedKeyLength > len(rawPacket)-tlsControlHeaderLength {
		return nil, E.New("invalid tls-crypt-v2 wrapped key")
	}
	packetBytes := rawPacket[:len(rawPacket)-wrappedKeyLength]
	if p.crypt != nil {
		return packetBytes, nil
	}
	clientKeyMaterial, err := unwrapTLSCryptV2ClientKey(rawPacket[len(rawPacket)-wrappedKeyLength:], p.cryptV2ServerKey)
	if err != nil {
		return nil, err
	}
	cryptCodec, err := newControlCryptCodecFromMaterial(clientKeyMaterial, tlsCryptKeyDirectionNormal)
	if err != nil {
		return nil, err
	}
	p.crypt = cryptCodec
	return packetBytes, nil
}

type tlsPacketIDState struct {
	access    sync.Mutex
	nextID    uint32
	timestamp uint32
}

func (s *tlsPacketIDState) seedNextID(nextID uint32) {
	s.access.Lock()
	defer s.access.Unlock()
	s.nextID = nextID
	if s.timestamp == 0 {
		s.timestamp = uint32(time.Now().Unix())
	}
}

// Upstream packet_id_send_update holds the long-form timestamp stable
// until the sequence counter wraps.
func (s *tlsPacketIDState) next() [tlsControlPacketIDLength]byte {
	s.access.Lock()
	defer s.access.Unlock()
	if s.timestamp == 0 {
		s.timestamp = uint32(time.Now().Unix())
	}
	if s.nextID == 0xFFFFFFFF {
		currentTime := uint32(time.Now().Unix())
		if currentTime > s.timestamp {
			s.timestamp = currentTime
		}
		s.nextID = 0
	}
	s.nextID++
	var packetID [tlsControlPacketIDLength]byte
	binary.BigEndian.PutUint32(packetID[:4], s.nextID)
	binary.BigEndian.PutUint32(packetID[4:], s.timestamp)
	return packetID
}

type controlAuthCodec struct {
	sendKey      []byte
	receiveKeys  [][]byte
	sendState    tlsPacketIDState
	receiveState *replayWindow
	hashFactory  func() hash.Hash
	digestSize   int
}

func (c *controlAuthCodec) newSessionCodec() *controlAuthCodec {
	if c == nil {
		return nil
	}
	receiveKeys := make([][]byte, len(c.receiveKeys))
	for index, receiveKey := range c.receiveKeys {
		receiveKeys[index] = append([]byte(nil), receiveKey...)
	}
	return &controlAuthCodec{
		sendKey:      append([]byte(nil), c.sendKey...),
		receiveKeys:  receiveKeys,
		receiveState: newReplayWindow(defaultReplayWindowSize, defaultReplayWindowTime),
		hashFactory:  c.hashFactory,
		digestSize:   c.digestSize,
	}
}

func newControlAuthCodecWithAuth(staticKey Material, keyDirection int, authName string) (*controlAuthCodec, error) {
	staticKeyMaterial, err := loadStaticKeyMaterialFromSource(staticKey)
	if err != nil {
		return nil, err
	}
	hashFactory, digestSize, err := staticHMACFactory(authName)
	if err != nil {
		return nil, err
	}
	if hashFactory == nil || digestSize <= 0 {
		return nil, E.New("tls-auth requires a non-NONE auth algorithm")
	}
	keySlots := splitStaticKeyMaterial(staticKeyMaterial)
	sendSlotIndex, receiveSlotIndex, receiveFallbackIndex := resolveStaticKeyDirection(keyDirection)
	sendKey := append([]byte{}, keySlots[sendSlotIndex].hmacKey[:digestSize]...)
	receiveKeys := [][]byte{
		append([]byte{}, keySlots[receiveSlotIndex].hmacKey[:digestSize]...),
	}
	if receiveFallbackIndex >= 0 && receiveFallbackIndex != receiveSlotIndex {
		receiveKeys = append(receiveKeys, append([]byte{}, keySlots[receiveFallbackIndex].hmacKey[:digestSize]...))
	}
	return &controlAuthCodec{
		sendKey:      sendKey,
		receiveKeys:  receiveKeys,
		receiveState: newReplayWindow(defaultReplayWindowSize, defaultReplayWindowTime),
		hashFactory:  hashFactory,
		digestSize:   digestSize,
	}, nil
}

func (c *controlAuthCodec) encodeControlPacket(rawPacket []byte) []byte {
	if c == nil || len(rawPacket) < tlsControlHeaderLength {
		return append([]byte{}, rawPacket...)
	}
	packetID := c.sendState.next()
	authInput := make([]byte, 0, len(packetID)+len(rawPacket))
	authInput = append(authInput, packetID[:]...)
	authInput = append(authInput, rawPacket...)
	mac := hmac.New(c.hashFactory, c.sendKey)
	mac.Write(authInput)
	digest := mac.Sum(nil)

	encodedPacket := make([]byte, 0, len(rawPacket)+len(digest)+len(packetID))
	encodedPacket = append(encodedPacket, rawPacket[:tlsControlHeaderLength]...)
	encodedPacket = append(encodedPacket, digest...)
	encodedPacket = append(encodedPacket, packetID[:]...)
	encodedPacket = append(encodedPacket, rawPacket[tlsControlHeaderLength:]...)
	return encodedPacket
}

func (c *controlAuthCodec) decodeControlPacket(rawPacket []byte) ([]byte, bool) {
	if c == nil || len(rawPacket) < tlsControlHeaderLength+c.digestSize+tlsControlPacketIDLength {
		return nil, false
	}
	header := rawPacket[:tlsControlHeaderLength]
	receivedDigest := rawPacket[tlsControlHeaderLength : tlsControlHeaderLength+c.digestSize]
	packetIDBytes := rawPacket[tlsControlHeaderLength+c.digestSize : tlsControlHeaderLength+c.digestSize+tlsControlPacketIDLength]
	body := rawPacket[tlsControlHeaderLength+c.digestSize+tlsControlPacketIDLength:]

	authInput := make([]byte, 0, len(packetIDBytes)+len(header)+len(body))
	authInput = append(authInput, packetIDBytes...)
	authInput = append(authInput, header...)
	authInput = append(authInput, body...)
	for _, receiveKey := range c.receiveKeys {
		mac := hmac.New(c.hashFactory, receiveKey)
		mac.Write(authInput)
		expectedDigest := mac.Sum(nil)
		if !hmac.Equal(receivedDigest, expectedDigest) {
			continue
		}
		packetID := binary.BigEndian.Uint32(packetIDBytes[:4])
		packetTimestamp := binary.BigEndian.Uint32(packetIDBytes[4:])
		if c.receiveState != nil && !c.receiveState.AcceptLongForm(packetID, packetTimestamp) {
			return nil, false
		}
		decodedPacket := make([]byte, 0, len(header)+len(body))
		decodedPacket = append(decodedPacket, header...)
		decodedPacket = append(decodedPacket, body...)
		return decodedPacket, true
	}
	return nil, false
}

type controlCryptCodec struct {
	sendEncryptBlock  cipher.Block
	sendAuthKey       []byte
	receiveCandidates []controlCryptCandidate
	sendState         tlsPacketIDState
	receiveState      *replayWindow
}

func (c *controlCryptCodec) newSessionCodec() *controlCryptCodec {
	if c == nil {
		return nil
	}
	receiveCandidates := make([]controlCryptCandidate, len(c.receiveCandidates))
	for index, candidate := range c.receiveCandidates {
		receiveCandidates[index] = controlCryptCandidate{
			encryptBlock: candidate.encryptBlock,
			authKey:      append([]byte(nil), candidate.authKey...),
		}
	}
	return &controlCryptCodec{
		sendEncryptBlock:  c.sendEncryptBlock,
		sendAuthKey:       append([]byte(nil), c.sendAuthKey...),
		receiveCandidates: receiveCandidates,
		receiveState:      newReplayWindow(defaultReplayWindowSize, defaultReplayWindowTime),
	}
}

type controlCryptCandidate struct {
	encryptBlock cipher.Block
	authKey      []byte
}

// Upstream tls_crypt_init_key derives tls-crypt direction from TLS role.
func newControlCryptCodec(staticKey Material, keyDirection int) (*controlCryptCodec, error) {
	staticKeyMaterial, err := loadStaticKeyMaterialFromSource(staticKey)
	if err != nil {
		return nil, err
	}
	return newControlCryptCodecFromMaterial(staticKeyMaterial, keyDirection)
}

func newControlCryptCodecFromMaterial(staticKeyMaterial []byte, keyDirection int) (*controlCryptCodec, error) {
	keySlots := splitStaticKeyMaterial(staticKeyMaterial)
	sendSlotIndex, receiveSlotIndex, receiveFallbackIndex := resolveStaticKeyDirection(keyDirection)

	sendEncryptBlock, sendAuthKey, err := newControlCryptKeys(keySlots[sendSlotIndex])
	if err != nil {
		return nil, err
	}
	receiveCandidates := make([]controlCryptCandidate, 0, 2)
	receiveEncryptBlock, receiveAuthKey, err := newControlCryptKeys(keySlots[receiveSlotIndex])
	if err != nil {
		return nil, err
	}
	receiveCandidates = append(receiveCandidates, controlCryptCandidate{
		encryptBlock: receiveEncryptBlock,
		authKey:      receiveAuthKey,
	})
	if receiveFallbackIndex >= 0 && receiveFallbackIndex != receiveSlotIndex {
		fallbackEncryptBlock, fallbackAuthKey, fallbackErr := newControlCryptKeys(keySlots[receiveFallbackIndex])
		if fallbackErr != nil {
			return nil, fallbackErr
		}
		receiveCandidates = append(receiveCandidates, controlCryptCandidate{
			encryptBlock: fallbackEncryptBlock,
			authKey:      fallbackAuthKey,
		})
	}
	return &controlCryptCodec{
		sendEncryptBlock:  sendEncryptBlock,
		sendAuthKey:       sendAuthKey,
		receiveCandidates: receiveCandidates,
		receiveState:      newReplayWindow(defaultReplayWindowSize, defaultReplayWindowTime),
	}, nil
}

func newControlCryptKeys(keySlot staticKeySlot) (cipher.Block, []byte, error) {
	encryptKey := append([]byte{}, keySlot.cipherKey[:32]...)
	encryptBlock, err := aes.NewCipher(encryptKey)
	if err != nil {
		return nil, nil, err
	}
	authKey := append([]byte{}, keySlot.hmacKey[:32]...)
	return encryptBlock, authKey, nil
}

func (c *controlCryptCodec) encodeControlPacket(rawPacket []byte) []byte {
	if c == nil || len(rawPacket) < tlsControlHeaderLength {
		return append([]byte{}, rawPacket...)
	}
	header := rawPacket[:tlsControlHeaderLength]
	body := rawPacket[tlsControlHeaderLength:]
	packetID := c.sendState.next()

	mac := hmac.New(sha256.New, c.sendAuthKey)
	mac.Write(header)
	mac.Write(packetID[:])
	mac.Write(body)
	tag := mac.Sum(nil)

	ciphertext := make([]byte, len(body))
	cipher.NewCTR(c.sendEncryptBlock, tag[:aes.BlockSize]).XORKeyStream(ciphertext, body)

	encodedPacket := make([]byte, 0, len(header)+len(packetID)+len(tag)+len(ciphertext))
	encodedPacket = append(encodedPacket, header...)
	encodedPacket = append(encodedPacket, packetID[:]...)
	encodedPacket = append(encodedPacket, tag...)
	encodedPacket = append(encodedPacket, ciphertext...)
	return encodedPacket
}

func (c *controlCryptCodec) decodeControlPacket(rawPacket []byte) ([]byte, bool) {
	if c == nil || len(rawPacket) < tlsControlHeaderLength+tlsControlPacketIDLength+tlsCryptTagLength {
		return nil, false
	}
	header := rawPacket[:tlsControlHeaderLength]
	packetIDBytes := rawPacket[tlsControlHeaderLength : tlsControlHeaderLength+tlsControlPacketIDLength]
	receivedTag := rawPacket[tlsControlHeaderLength+tlsControlPacketIDLength : tlsControlHeaderLength+tlsControlPacketIDLength+tlsCryptTagLength]
	ciphertext := rawPacket[tlsControlHeaderLength+tlsControlPacketIDLength+tlsCryptTagLength:]

	for _, candidate := range c.receiveCandidates {
		plaintext := make([]byte, len(ciphertext))
		cipher.NewCTR(candidate.encryptBlock, receivedTag[:aes.BlockSize]).XORKeyStream(plaintext, ciphertext)

		mac := hmac.New(sha256.New, candidate.authKey)
		mac.Write(header)
		mac.Write(packetIDBytes)
		mac.Write(plaintext)
		expectedTag := mac.Sum(nil)
		if !hmac.Equal(receivedTag, expectedTag) {
			continue
		}
		packetID := binary.BigEndian.Uint32(packetIDBytes[:4])
		packetTimestamp := binary.BigEndian.Uint32(packetIDBytes[4:])
		if c.receiveState != nil && !c.receiveState.AcceptLongForm(packetID, packetTimestamp) {
			return nil, false
		}
		decodedPacket := make([]byte, 0, len(header)+len(plaintext))
		decodedPacket = append(decodedPacket, header...)
		decodedPacket = append(decodedPacket, plaintext...)
		return decodedPacket, true
	}
	return nil, false
}

// Upstream mudp.c reads the tls-crypt packet id of a V3 reset and treats the
// EARLY_NEG_START marker in its most significant byte as the client announcing
// that it can resend the wrapped client key.
func tlsCryptV2ResetAnnouncesEarlyNegotiation(rawPacket []byte) bool {
	if len(rawPacket) < tlsControlHeaderLength+4 {
		return false
	}
	packetID := binary.BigEndian.Uint32(rawPacket[tlsControlHeaderLength : tlsControlHeaderLength+4])
	return packetID&tlsCryptV2EarlyNegotiationStart == tlsCryptV2EarlyNegotiationStart
}

func tlsCryptV2ServerRequestsWrappedClientKeyResend(payload []byte) (bool, error) {
	flags, err := parseTLSCryptV2EarlyNegotiationFlags(payload)
	if err != nil {
		return false, err
	}
	return flags&tlsCryptV2EarlyNegotiationFlagResendWKC != 0, nil
}

func parseTLSCryptV2EarlyNegotiationFlags(payload []byte) (uint16, error) {
	remainingPayload := payload
	var flags uint16
	for len(remainingPayload) > 0 {
		if len(remainingPayload) < 4 {
			return 0, E.New("malformed tls-crypt-v2 early negotiation")
		}
		tlvType := binary.BigEndian.Uint16(remainingPayload[:2])
		tlvLength := int(binary.BigEndian.Uint16(remainingPayload[2:4]))
		remainingPayload = remainingPayload[4:]
		if len(remainingPayload) < tlvLength {
			return 0, E.New("malformed tls-crypt-v2 early negotiation")
		}
		tlvValue := remainingPayload[:tlvLength]
		remainingPayload = remainingPayload[tlvLength:]
		if tlvType != tlsCryptV2TLVTypeEarlyNegotiationFlags {
			continue
		}
		if tlvLength != 2 {
			return 0, E.New("malformed tls-crypt-v2 early negotiation")
		}
		flags |= binary.BigEndian.Uint16(tlvValue)
	}
	return flags, nil
}

func appendTLSCryptV2WrappedClientKey(rawPacket []byte, wrappedClientKey []byte, opcode proto.Opcode) []byte {
	if len(wrappedClientKey) > 0 && (opcode == proto.OpcodeControlHardResetClientV3 || opcode == proto.OpcodeControlWKCv1) {
		return append(rawPacket, wrappedClientKey...)
	}
	return rawPacket
}

func loadTLSCryptV2ClientKey(staticKey Material) ([]byte, []byte, error) {
	keyBytes, err := loadNamedPEMBytes(staticKey, tlsCryptV2ClientPEMType)
	if err != nil {
		return nil, nil, err
	}
	if len(keyBytes) < tlsCryptV2ClientKeyDataLength {
		return nil, nil, E.New("invalid tls-crypt-v2 client key")
	}
	keyMaterial := append([]byte{}, keyBytes[:tlsCryptV2ClientKeyDataLength]...)
	wrappedClientKey := append([]byte{}, keyBytes[tlsCryptV2ClientKeyDataLength:]...)
	if len(wrappedClientKey) == 0 {
		return nil, nil, E.New("missing wrapped tls-crypt-v2 client key")
	}
	return keyMaterial, wrappedClientKey, nil
}

func loadTLSCryptV2ServerKey(staticKey Material) ([]byte, error) {
	keyBytes, err := loadNamedPEMBytes(staticKey, tlsCryptV2ServerPEMType)
	if err != nil {
		return nil, err
	}
	if len(keyBytes) < tlsCryptV2ServerKeyLength {
		return nil, E.New("invalid tls-crypt-v2 server key")
	}
	return append([]byte{}, keyBytes[:tlsCryptV2ServerKeyLength]...), nil
}

func unwrapTLSCryptV2ClientKey(wrappedClientKey []byte, serverKey []byte) ([]byte, error) {
	if len(serverKey) < tlsCryptV2ServerKeyLength {
		return nil, E.New("invalid tls-crypt-v2 server key")
	}
	if len(wrappedClientKey) < tlsCryptTagLength+2 {
		return nil, E.New("invalid tls-crypt-v2 wrapped key")
	}
	netLength := binary.BigEndian.Uint16(wrappedClientKey[len(wrappedClientKey)-2:])
	if int(netLength) != len(wrappedClientKey) {
		return nil, E.New("invalid tls-crypt-v2 wrapped key length")
	}

	encryptBlock, err := aes.NewCipher(serverKey[:32])
	if err != nil {
		return nil, err
	}
	authKey := serverKey[64:96]
	tag := wrappedClientKey[:tlsCryptTagLength]
	ciphertext := wrappedClientKey[tlsCryptTagLength : len(wrappedClientKey)-2]
	plaintext := make([]byte, len(ciphertext))
	cipher.NewCTR(encryptBlock, tag[:aes.BlockSize]).XORKeyStream(plaintext, ciphertext)

	mac := hmac.New(sha256.New, authKey)
	mac.Write(wrappedClientKey[len(wrappedClientKey)-2:])
	mac.Write(plaintext)
	expectedTag := mac.Sum(nil)
	if !hmac.Equal(tag, expectedTag) {
		return nil, E.New("tls-crypt-v2 client key authentication failed")
	}
	if len(plaintext) < tlsCryptV2ClientKeyDataLength {
		return nil, E.New("tls-crypt-v2 plaintext too short")
	}
	clientKeyMaterial := append([]byte{}, plaintext[:tlsCryptV2ClientKeyDataLength]...)
	return clientKeyMaterial, nil
}

func loadNamedPEMBytes(input Material, expectedType string) ([]byte, error) {
	if !input.IsSet() {
		return nil, ErrMissingStaticKey
	}
	pemBytes, err := loadMaterial(input)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil || block.Type != expectedType {
		return nil, E.New("invalid pem content")
	}
	return append([]byte{}, block.Bytes...), nil
}
