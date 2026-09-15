package openvpn

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"sync"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/crypto/chacha20poly1305"
)

const tlsDataAEADTagSize = 16

type tlsGCMDataCodec struct {
	sendAEAD              cipher.AEAD
	sendIVSuffix          []byte
	sendBufferAccess      sync.Mutex
	sendNonce             [32]byte
	sendAdditionalData    [8]byte
	receiveAEAD           cipher.AEAD
	receiveIVSuffix       []byte
	receiveBufferAccess   sync.Mutex
	receiveNonce          [32]byte
	receiveAdditionalData [8]byte
	replayWindow          *replayWindow
}

func (c *tlsGCMDataCodec) EncodedLength(payloadLength int) int {
	return 4 + tlsDataAEADTagSize + payloadLength
}

func newTLSGCMDataCodec(keyMaterial []byte, server bool, cipherName string, replayWindowSize uint32, replayWindowTime time.Duration) (dataCodec, error) {
	if len(keyMaterial) < 256 {
		return nil, E.New("invalid tls key material")
	}
	keySlots := splitStaticKeyMaterial(keyMaterial)
	sendSlot, receiveSlot := tlsDataKeySlots(keySlots, server)
	var keySize int
	switch cipherName {
	case "AES-128-GCM":
		keySize = 16
	case "AES-192-GCM":
		keySize = 24
	case "AES-256-GCM":
		keySize = 32
	default:
		return nil, E.New("unsupported gcm cipher")
	}
	sendBlock, err := aes.NewCipher(sendSlot.cipherKey[:keySize])
	if err != nil {
		return nil, err
	}
	receiveBlock, err := aes.NewCipher(receiveSlot.cipherKey[:keySize])
	if err != nil {
		return nil, err
	}
	sendAEAD, err := cipher.NewGCM(sendBlock)
	if err != nil {
		return nil, err
	}
	receiveAEAD, err := cipher.NewGCM(receiveBlock)
	if err != nil {
		return nil, err
	}
	return &tlsGCMDataCodec{
		sendAEAD:        sendAEAD,
		sendIVSuffix:    append([]byte{}, sendSlot.hmacKey[:8]...),
		receiveAEAD:     receiveAEAD,
		receiveIVSuffix: append([]byte{}, receiveSlot.hmacKey[:8]...),
		replayWindow:    newReplayWindow(replayWindowSize, replayWindowTime),
	}, nil
}

func newTLSChaCha20Poly1305DataCodec(keyMaterial []byte, server bool, replayWindowSize uint32, replayWindowTime time.Duration) (dataCodec, error) {
	if len(keyMaterial) < 256 {
		return nil, E.New("invalid tls key material")
	}
	keySlots := splitStaticKeyMaterial(keyMaterial)
	sendSlot, receiveSlot := tlsDataKeySlots(keySlots, server)
	sendAEAD, err := chacha20poly1305.New(sendSlot.cipherKey[:chacha20poly1305.KeySize])
	if err != nil {
		return nil, err
	}
	receiveAEAD, err := chacha20poly1305.New(receiveSlot.cipherKey[:chacha20poly1305.KeySize])
	if err != nil {
		return nil, err
	}
	return &tlsGCMDataCodec{
		sendAEAD:        sendAEAD,
		sendIVSuffix:    append([]byte{}, sendSlot.hmacKey[:8]...),
		receiveAEAD:     receiveAEAD,
		receiveIVSuffix: append([]byte{}, receiveSlot.hmacKey[:8]...),
		replayWindow:    newReplayWindow(replayWindowSize, replayWindowTime),
	}, nil
}

func (c *tlsGCMDataCodec) Encode(packetID uint32, aadPrefix []byte, payload []byte) ([]byte, error) {
	if packetID == 0 {
		return nil, E.New("invalid data packet id")
	}
	nonce := make([]byte, c.sendAEAD.NonceSize())
	binary.BigEndian.PutUint32(nonce[:4], packetID)
	copy(nonce[4:], c.sendIVSuffix)

	packetIDBytes := make([]byte, 4)
	binary.BigEndian.PutUint32(packetIDBytes, packetID)
	additionalData := make([]byte, 0, len(aadPrefix)+len(packetIDBytes))
	additionalData = append(additionalData, aadPrefix...)
	additionalData = append(additionalData, packetIDBytes...)
	ciphertext := c.sendAEAD.Seal(nil, nonce, payload, additionalData)
	if len(ciphertext) < tlsDataAEADTagSize {
		return nil, E.New("invalid gcm ciphertext")
	}
	tag := ciphertext[len(ciphertext)-tlsDataAEADTagSize:]
	encryptedPayload := ciphertext[:len(ciphertext)-tlsDataAEADTagSize]
	encodedPacket := make([]byte, 0, len(packetIDBytes)+len(tag)+len(encryptedPayload))
	encodedPacket = append(encodedPacket, packetIDBytes...)
	encodedPacket = append(encodedPacket, tag...)
	encodedPacket = append(encodedPacket, encryptedPayload...)
	return encodedPacket, nil
}

func (c *tlsGCMDataCodec) EncodeBuffer(packetID uint32, aadPrefix []byte, payload *buf.Buffer) (*buf.Buffer, error) {
	c.sendBufferAccess.Lock()
	defer c.sendBufferAccess.Unlock()
	if packetID == 0 {
		payload.Release()
		return nil, E.New("invalid data packet id")
	}
	const encodedHeaderSize = 4 + tlsDataAEADTagSize
	if payload.Start() < encodedHeaderSize || payload.FreeLen() < tlsDataAEADTagSize {
		headroom := max(payload.Start(), encodedHeaderSize)
		newPayload := buf.NewSize(headroom + payload.Len() + tlsDataAEADTagSize)
		newPayload.Resize(headroom, 0)
		_, _ = newPayload.Write(payload.Bytes())
		payload.Release()
		payload = newPayload
	}
	nonce := c.sendNonce[:c.sendAEAD.NonceSize()]
	binary.BigEndian.PutUint32(nonce[:4], packetID)
	copy(nonce[4:], c.sendIVSuffix)
	copy(c.sendAdditionalData[:], aadPrefix)
	binary.BigEndian.PutUint32(c.sendAdditionalData[len(aadPrefix):], packetID)
	additionalData := c.sendAdditionalData[:len(aadPrefix)+4]
	plainPayload := payload.Bytes()
	plainPayloadLength := len(plainPayload)
	sealedPayload := c.sendAEAD.Seal(plainPayload[:0], nonce, plainPayload, additionalData)
	if len(sealedPayload) != plainPayloadLength+tlsDataAEADTagSize {
		payload.Release()
		return nil, E.New("invalid gcm ciphertext")
	}
	payload.Truncate(len(sealedPayload))
	tag := sealedPayload[plainPayloadLength:]
	encodedHeader := payload.ExtendHeader(encodedHeaderSize)
	binary.BigEndian.PutUint32(encodedHeader[:4], packetID)
	copy(encodedHeader[4:], tag)
	payload.Truncate(encodedHeaderSize + plainPayloadLength)
	return payload, nil
}

func (c *tlsGCMDataCodec) Decode(aadPrefix []byte, payload []byte) (uint32, []byte, error) {
	if len(payload) < 4+tlsDataAEADTagSize {
		return 0, nil, E.New("invalid gcm payload")
	}
	packetID := binary.BigEndian.Uint32(payload[:4])
	tag := payload[4 : 4+tlsDataAEADTagSize]
	ciphertext := payload[4+tlsDataAEADTagSize:]

	nonce := make([]byte, c.receiveAEAD.NonceSize())
	binary.BigEndian.PutUint32(nonce[:4], packetID)
	copy(nonce[4:], c.receiveIVSuffix)

	sealedPayload := make([]byte, 0, len(ciphertext)+len(tag))
	sealedPayload = append(sealedPayload, ciphertext...)
	sealedPayload = append(sealedPayload, tag...)
	packetIDBytes := make([]byte, 4)
	binary.BigEndian.PutUint32(packetIDBytes, packetID)
	additionalData := make([]byte, 0, len(aadPrefix)+len(packetIDBytes))
	additionalData = append(additionalData, aadPrefix...)
	additionalData = append(additionalData, packetIDBytes...)
	decodedPayload, err := c.receiveAEAD.Open(nil, nonce, sealedPayload, additionalData)
	if err != nil {
		return 0, nil, err
	}
	if c.replayWindow != nil && !c.replayWindow.Accept(packetID) {
		return 0, nil, E.New("replayed gcm packet")
	}
	return packetID, decodedPayload, nil
}

func (c *tlsGCMDataCodec) DecodeBuffer(aadPrefix []byte, payload []byte, headroom int) (uint32, *buf.Buffer, error) {
	c.receiveBufferAccess.Lock()
	defer c.receiveBufferAccess.Unlock()
	if len(payload) < 4+tlsDataAEADTagSize {
		return 0, nil, E.New("invalid gcm payload")
	}
	packetID := binary.BigEndian.Uint32(payload[:4])
	var tag [tlsDataAEADTagSize]byte
	copy(tag[:], payload[4:4+tlsDataAEADTagSize])
	ciphertextLength := len(payload) - 4 - tlsDataAEADTagSize
	copy(payload[4:], payload[4+tlsDataAEADTagSize:])
	copy(payload[4+ciphertextLength:], tag[:])
	sealedPayload := payload[4 : 4+ciphertextLength+tlsDataAEADTagSize]
	nonce := c.receiveNonce[:c.receiveAEAD.NonceSize()]
	binary.BigEndian.PutUint32(nonce[:4], packetID)
	copy(nonce[4:], c.receiveIVSuffix)
	copy(c.receiveAdditionalData[:], aadPrefix)
	binary.BigEndian.PutUint32(c.receiveAdditionalData[len(aadPrefix):], packetID)
	additionalData := c.receiveAdditionalData[:len(aadPrefix)+4]
	if headroom < 0 {
		headroom = 0
	}
	decodedBuffer := buf.NewSize(headroom + ciphertextLength)
	decodedBuffer.Resize(headroom, 0)
	decodedPayload, err := c.receiveAEAD.Open(decodedBuffer.FreeBytes()[:0], nonce, sealedPayload, additionalData)
	if err != nil {
		decodedBuffer.Release()
		return 0, nil, err
	}
	decodedBuffer.Truncate(len(decodedPayload))
	if c.replayWindow != nil && !c.replayWindow.Accept(packetID) {
		decodedBuffer.Release()
		return 0, nil, E.New("replayed gcm packet")
	}
	return packetID, decodedBuffer, nil
}
