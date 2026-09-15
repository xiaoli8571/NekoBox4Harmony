package openvpn

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/des"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/binary"
	"encoding/hex"
	"hash"
	"strings"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"

	"github.com/RyuaNerin/go-krypto/aria"
	"github.com/RyuaNerin/go-krypto/seed"
	camellia "github.com/dgryski/go-camellia"
	"github.com/tjfoc/gmsm/sm4"
	"golang.org/x/crypto/blowfish"  //nolint:staticcheck // OpenVPN BF-CBC compatibility requires Blowfish.
	"golang.org/x/crypto/cast5"     //nolint:staticcheck // OpenVPN CAST5-CBC compatibility requires CAST5.
	"golang.org/x/crypto/ripemd160" //nolint:staticcheck // OpenVPN RIPEMD160 authentication compatibility requires RIPEMD-160.
)

type staticKeyDataCodec struct {
	sendCipherBlock   cipher.Block
	sendHMACKey       []byte
	receiveCandidates []staticKeyDecodeCandidate
	hashFactory       func() hash.Hash
	hmacSize          int
	sendTimestamp     uint32
	replayWindow      *replayWindow
}

func (c *staticKeyDataCodec) EncodedLength(payloadLength int) int {
	plainLength := 8 + payloadLength
	protectedLength := plainLength
	if c.sendCipherBlock != nil {
		blockSize := c.sendCipherBlock.BlockSize()
		protectedLength = blockSize + ((plainLength/blockSize)+1)*blockSize
	}
	return c.hmacSize + protectedLength
}

type staticKeyDecodeCandidate struct {
	cipherBlock cipher.Block
	hmacKey     []byte
}

type staticKeySlot struct {
	cipherKey []byte
	hmacKey   []byte
}

func (c *staticKeyDataCodec) Encode(packetID uint32, aadPrefix []byte, payload []byte) ([]byte, error) {
	_ = aadPrefix
	if packetID == 0 {
		return nil, E.New("invalid static key packet id")
	}
	plainPayload := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint32(plainPayload[:4], packetID)
	binary.BigEndian.PutUint32(plainPayload[4:8], c.sendTimestamp)
	copy(plainPayload[8:], payload)
	protectedPayload := plainPayload
	if c.sendCipherBlock != nil {
		blockSize := c.sendCipherBlock.BlockSize()
		paddedPayload, err := pkcs7Pad(plainPayload, blockSize)
		if err != nil {
			return nil, err
		}
		initializationVector := make([]byte, blockSize)
		_, err = rand.Read(initializationVector)
		if err != nil {
			return nil, err
		}
		cipherPayload := make([]byte, len(paddedPayload))
		cipher.NewCBCEncrypter(c.sendCipherBlock, initializationVector).CryptBlocks(cipherPayload, paddedPayload)
		protectedPayload = make([]byte, len(initializationVector)+len(cipherPayload))
		copy(protectedPayload, initializationVector)
		copy(protectedPayload[len(initializationVector):], cipherPayload)
	}
	if c.hmacSize > 0 {
		mac := hmac.New(c.hashFactory, c.sendHMACKey)
		mac.Write(protectedPayload)
		macValue := mac.Sum(nil)
		encodedPacket := make([]byte, len(macValue)+len(protectedPayload))
		copy(encodedPacket, macValue)
		copy(encodedPacket[len(macValue):], protectedPayload)
		return encodedPacket, nil
	}
	encodedPacket := make([]byte, len(protectedPayload))
	copy(encodedPacket, protectedPayload)
	return encodedPacket, nil
}

func (c *staticKeyDataCodec) EncodeBuffer(packetID uint32, aadPrefix []byte, payload *buf.Buffer) (*buf.Buffer, error) {
	encodedPayload, err := c.Encode(packetID, aadPrefix, payload.Bytes())
	if err != nil {
		payload.Release()
		return nil, err
	}
	encodedBuffer := buf.NewSize(payload.Start() + len(encodedPayload))
	encodedBuffer.Resize(payload.Start(), 0)
	_, _ = encodedBuffer.Write(encodedPayload)
	payload.Release()
	return encodedBuffer, nil
}

func (c *staticKeyDataCodec) Decode(aadPrefix []byte, payload []byte) (uint32, []byte, error) {
	_ = aadPrefix
	var decodeError error
	for _, candidate := range c.receiveCandidates {
		packetID, packetTimestamp, decodedPayload, err := c.decodeWithCandidate(payload, candidate)
		if err == nil {
			if c.replayWindow != nil && !c.replayWindow.AcceptLongForm(packetID, packetTimestamp) {
				return 0, nil, E.New("replayed static key data packet")
			}
			return packetID, decodedPayload, nil
		}
		decodeError = err
	}
	if decodeError == nil {
		return 0, nil, E.New("invalid static key payload")
	}
	return 0, nil, decodeError
}

func (c *staticKeyDataCodec) DecodeBuffer(aadPrefix []byte, payload []byte, headroom int) (uint32, *buf.Buffer, error) {
	packetID, decodedPayload, err := c.Decode(aadPrefix, payload)
	if err != nil {
		return 0, nil, err
	}
	return packetID, newDataPacketBuffer(headroom, decodedPayload), nil
}

func (c *staticKeyDataCodec) decodeWithCandidate(payload []byte, candidate staticKeyDecodeCandidate) (uint32, uint32, []byte, error) {
	protectedPayload := payload
	if c.hmacSize > 0 {
		if len(protectedPayload) < c.hmacSize {
			return 0, 0, nil, E.New("invalid static key payload")
		}
		receivedMAC := protectedPayload[:c.hmacSize]
		protectedPayload = protectedPayload[c.hmacSize:]
		mac := hmac.New(c.hashFactory, candidate.hmacKey)
		mac.Write(protectedPayload)
		expectedMAC := mac.Sum(nil)
		if !hmac.Equal(receivedMAC, expectedMAC) {
			return 0, 0, nil, E.New("invalid static key payload hmac")
		}
	}
	plainPayload := protectedPayload
	if candidate.cipherBlock != nil {
		blockSize := candidate.cipherBlock.BlockSize()
		if len(protectedPayload) < blockSize*2 || len(protectedPayload)%blockSize != 0 {
			return 0, 0, nil, E.New("invalid static key payload")
		}
		initializationVector := protectedPayload[:blockSize]
		cipherPayload := protectedPayload[blockSize:]
		decodedPayload := make([]byte, len(cipherPayload))
		cipher.NewCBCDecrypter(candidate.cipherBlock, initializationVector).CryptBlocks(decodedPayload, cipherPayload)
		unpaddedPayload, err := pkcs7Unpad(decodedPayload, blockSize)
		if err != nil {
			return 0, 0, nil, err
		}
		plainPayload = unpaddedPayload
	}
	if len(plainPayload) < 8 {
		return 0, 0, nil, E.New("invalid static key payload")
	}
	packetID := binary.BigEndian.Uint32(plainPayload[:4])
	if packetID == 0 {
		return 0, 0, nil, E.New("invalid static key packet id")
	}
	packetTimestamp := binary.BigEndian.Uint32(plainPayload[4:8])
	decodedPayload := make([]byte, len(plainPayload)-8)
	copy(decodedPayload, plainPayload[8:])
	return packetID, packetTimestamp, decodedPayload, nil
}

func newStaticKeyDataCodec(staticKey Material, keyDirection int, cipherName string, authName string, replayWindowSize uint32, replayWindowTime time.Duration) (dataCodec, error) {
	staticKeyMaterial, err := loadStaticKeyMaterialFromSource(staticKey)
	if err != nil {
		return nil, err
	}
	cipherKeySize, err := staticCipherKeySize(cipherName)
	if err != nil {
		return nil, err
	}
	hashFactory, hmacSize, err := staticHMACFactory(authName)
	if err != nil {
		return nil, err
	}
	keySlots := splitStaticKeyMaterial(staticKeyMaterial)
	sendSlotIndex, receiveSlotIndex, receiveFallbackIndex := resolveStaticKeyDirection(keyDirection)
	sendSlot := keySlots[sendSlotIndex]
	receiveSlot := keySlots[receiveSlotIndex]
	sendCipherBlock, err := newStaticCipherBlock(cipherName, sendSlot.cipherKey, cipherKeySize)
	if err != nil {
		return nil, err
	}
	receiveCipherBlock, err := newStaticCipherBlock(cipherName, receiveSlot.cipherKey, cipherKeySize)
	if err != nil {
		return nil, err
	}
	var sendHMACKey []byte
	var receiveHMACKey []byte
	if hmacSize > 0 {
		sendHMACKey = make([]byte, hmacSize)
		copy(sendHMACKey, sendSlot.hmacKey[:hmacSize])
		receiveHMACKey = make([]byte, hmacSize)
		copy(receiveHMACKey, receiveSlot.hmacKey[:hmacSize])
	}
	receiveCandidates := []staticKeyDecodeCandidate{
		{
			cipherBlock: receiveCipherBlock,
			hmacKey:     receiveHMACKey,
		},
	}
	if receiveFallbackIndex >= 0 && receiveFallbackIndex != receiveSlotIndex {
		fallbackSlot := keySlots[receiveFallbackIndex]
		fallbackCipherBlock, fallbackCipherErr := newStaticCipherBlock(cipherName, fallbackSlot.cipherKey, cipherKeySize)
		if fallbackCipherErr != nil {
			return nil, fallbackCipherErr
		}
		var fallbackHMACKey []byte
		if hmacSize > 0 {
			fallbackHMACKey = make([]byte, hmacSize)
			copy(fallbackHMACKey, fallbackSlot.hmacKey[:hmacSize])
		}
		receiveCandidates = append(receiveCandidates, staticKeyDecodeCandidate{
			cipherBlock: fallbackCipherBlock,
			hmacKey:     fallbackHMACKey,
		})
	}
	return &staticKeyDataCodec{
		sendCipherBlock:   sendCipherBlock,
		sendHMACKey:       sendHMACKey,
		receiveCandidates: receiveCandidates,
		hashFactory:       hashFactory,
		hmacSize:          hmacSize,
		sendTimestamp:     uint32(time.Now().Unix()),
		replayWindow:      newReplayWindow(replayWindowSize, replayWindowTime),
	}, nil
}

func resolveStaticKeyDirection(keyDirection int) (int, int, int) {
	if keyDirection == 1 || keyDirection == 2 {
		return 1, 0, 1
	}
	if keyDirection < 0 {
		return 0, 0, 1
	}
	return 0, 1, 0
}

func splitStaticKeyMaterial(staticKeyMaterial []byte) []staticKeySlot {
	return []staticKeySlot{
		{
			cipherKey: append([]byte{}, staticKeyMaterial[0:64]...),
			hmacKey:   append([]byte{}, staticKeyMaterial[64:128]...),
		},
		{
			cipherKey: append([]byte{}, staticKeyMaterial[128:192]...),
			hmacKey:   append([]byte{}, staticKeyMaterial[192:256]...),
		},
	}
}

func staticCipherKeySize(cipherName string) (int, error) {
	switch cipherName {
	case "BF-CBC":
		return 16, nil
	case "DES-CBC":
		return 8, nil
	case "DES-EDE-CBC":
		return 16, nil
	case "DES-EDE3-CBC":
		return 24, nil
	case "CAST5-CBC":
		return 16, nil
	case "AES-128-CBC":
		return 16, nil
	case "AES-192-CBC":
		return 24, nil
	case "AES-256-CBC":
		return 32, nil
	case "ARIA-128-CBC", "CAMELLIA-128-CBC", "SEED-CBC", "SM4-CBC":
		return 16, nil
	case "ARIA-192-CBC", "CAMELLIA-192-CBC":
		return 24, nil
	case "ARIA-256-CBC", "CAMELLIA-256-CBC":
		return 32, nil
	case "NONE":
		return 0, nil
	default:
		return 0, E.New("unsupported static key cipher")
	}
}

func newStaticCipherBlock(cipherName string, keyMaterial []byte, keySize int) (cipher.Block, error) {
	if cipherName == "NONE" {
		return nil, nil
	}
	if keySize <= 0 || keySize > len(keyMaterial) {
		return nil, E.New("invalid static key cipher key size")
	}
	cipherKey := make([]byte, keySize)
	copy(cipherKey, keyMaterial[:keySize])
	switch cipherName {
	case "BF-CBC":
		return blowfish.NewCipher(cipherKey)
	case "DES-CBC":
		return des.NewCipher(cipherKey)
	case "DES-EDE-CBC":
		expandedCipherKey := make([]byte, 24)
		copy(expandedCipherKey, cipherKey)
		copy(expandedCipherKey[16:], cipherKey[:8])
		return des.NewTripleDESCipher(expandedCipherKey)
	case "DES-EDE3-CBC":
		return des.NewTripleDESCipher(cipherKey)
	case "CAST5-CBC":
		return cast5.NewCipher(cipherKey)
	case "AES-128-CBC", "AES-192-CBC", "AES-256-CBC":
		return aes.NewCipher(cipherKey)
	case "ARIA-128-CBC", "ARIA-192-CBC", "ARIA-256-CBC":
		return aria.NewCipher(cipherKey)
	case "CAMELLIA-128-CBC", "CAMELLIA-192-CBC", "CAMELLIA-256-CBC":
		return camellia.New(cipherKey)
	case "SEED-CBC":
		return seed.NewCipher(cipherKey)
	case "SM4-CBC":
		return sm4.NewCipher(cipherKey)
	default:
		return nil, E.New("unsupported static key cipher")
	}
}

func staticHMACFactory(authName string) (func() hash.Hash, int, error) {
	switch authName {
	case "", "SHA1":
		return sha1.New, sha1.Size, nil
	case "SHA224":
		return sha256.New224, sha256.Size224, nil
	case "SHA256":
		return sha256.New, sha256.Size, nil
	case "SHA384":
		return sha512.New384, sha512.Size384, nil
	case "SHA512":
		return sha512.New, sha512.Size, nil
	case "RIPEMD160":
		return ripemd160.New, ripemd160.Size, nil
	case "MD5":
		return md5.New, md5.Size, nil
	case "NONE":
		return nil, 0, nil
	default:
		return nil, 0, E.New("unsupported static key auth")
	}
}

func pkcs7Pad(payload []byte, blockSize int) ([]byte, error) {
	if blockSize <= 0 {
		return nil, E.New("invalid block size")
	}
	paddingSize := blockSize - (len(payload) % blockSize)
	if paddingSize == 0 {
		paddingSize = blockSize
	}
	paddedPayload := make([]byte, len(payload)+paddingSize)
	copy(paddedPayload, payload)
	for i := len(payload); i < len(paddedPayload); i++ {
		paddedPayload[i] = byte(paddingSize)
	}
	return paddedPayload, nil
}

func pkcs7Unpad(payload []byte, blockSize int) ([]byte, error) {
	if blockSize <= 0 || len(payload) == 0 || len(payload)%blockSize != 0 {
		return nil, E.New("invalid static key payload padding")
	}
	paddingSize := int(payload[len(payload)-1])
	if paddingSize <= 0 || paddingSize > blockSize || paddingSize > len(payload) {
		return nil, E.New("invalid static key payload padding")
	}
	paddingStart := len(payload) - paddingSize
	for i := paddingStart; i < len(payload); i++ {
		if payload[i] != byte(paddingSize) {
			return nil, E.New("invalid static key payload padding")
		}
	}
	unpaddedPayload := make([]byte, paddingStart)
	copy(unpaddedPayload, payload[:paddingStart])
	return unpaddedPayload, nil
}

func loadStaticKeyMaterialFromSource(staticKey Material) ([]byte, error) {
	staticKeyContent, err := loadMaterial(staticKey)
	if err != nil {
		return nil, err
	}
	if len(staticKeyContent) == 0 {
		return nil, ErrMissingStaticKey
	}
	if len(staticKeyContent) == 256 {
		return append([]byte(nil), staticKeyContent...), nil
	}

	staticKeyText := string(staticKeyContent)
	const beginMarker = "-----BEGIN OpenVPN Static key V1-----"
	const endMarker = "-----END OpenVPN Static key V1-----"
	beginIndex := strings.Index(staticKeyText, beginMarker)
	if beginIndex >= 0 {
		staticKeyText = staticKeyText[beginIndex+len(beginMarker):]
		endIndex := strings.Index(staticKeyText, endMarker)
		if endIndex < 0 {
			return nil, E.New("invalid static key end marker")
		}
		staticKeyText = staticKeyText[:endIndex]
	}
	hexFields := strings.Fields(staticKeyText)
	hexContent := strings.Join(hexFields, "")
	if len(hexContent) != 512 {
		return nil, E.New("static key must contain exactly 256 bytes")
	}
	decodedStaticKey, err := hex.DecodeString(hexContent)
	if err != nil {
		return nil, err
	}
	return decodedStaticKey, nil
}
