package openvpn

import (
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"encoding/binary"
	"hash"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type tlsCBCDataCodec struct {
	sendCipherBlock cipher.Block
	sendHMACKey     []byte
	receiveCipher   cipher.Block
	receiveHMACKey  []byte
	hashFactory     func() hash.Hash
	hmacSize        int
	replayWindow    *replayWindow
}

func (c *tlsCBCDataCodec) EncodedLength(payloadLength int) int {
	plainLength := 4 + payloadLength
	protectedLength := plainLength
	if c.sendCipherBlock != nil {
		blockSize := c.sendCipherBlock.BlockSize()
		protectedLength = blockSize + ((plainLength/blockSize)+1)*blockSize
	}
	return c.hmacSize + protectedLength
}

func newTLSCBCDataCodec(keyMaterial []byte, server bool, cipherName string, authName string, replayWindowSize uint32, replayWindowTime time.Duration) (dataCodec, error) {
	if len(keyMaterial) < 256 {
		return nil, E.New("invalid tls key material")
	}
	keySlots := splitStaticKeyMaterial(keyMaterial)
	sendSlot, receiveSlot := tlsDataKeySlots(keySlots, server)
	cipherKeySize, err := staticCipherKeySize(cipherName)
	if err != nil {
		return nil, err
	}
	hashFactory, hmacSize, err := staticHMACFactory(authName)
	if err != nil {
		return nil, err
	}
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
		sendHMACKey = append([]byte{}, sendSlot.hmacKey[:hmacSize]...)
		receiveHMACKey = append([]byte{}, receiveSlot.hmacKey[:hmacSize]...)
	}
	return &tlsCBCDataCodec{
		sendCipherBlock: sendCipherBlock,
		sendHMACKey:     sendHMACKey,
		receiveCipher:   receiveCipherBlock,
		receiveHMACKey:  receiveHMACKey,
		hashFactory:     hashFactory,
		hmacSize:        hmacSize,
		replayWindow:    newReplayWindow(replayWindowSize, replayWindowTime),
	}, nil
}

func (c *tlsCBCDataCodec) Encode(packetID uint32, aadPrefix []byte, payload []byte) ([]byte, error) {
	_ = aadPrefix
	if packetID == 0 {
		return nil, E.New("invalid data packet id")
	}
	plainPayload := make([]byte, 4+len(payload))
	binary.BigEndian.PutUint32(plainPayload[:4], packetID)
	copy(plainPayload[4:], payload)

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
		protectedPayload = append(initializationVector, cipherPayload...)
	}
	if c.hmacSize > 0 {
		mac := hmac.New(c.hashFactory, c.sendHMACKey)
		mac.Write(protectedPayload)
		macValue := mac.Sum(nil)
		return append(macValue, protectedPayload...), nil
	}
	return protectedPayload, nil
}

func (c *tlsCBCDataCodec) EncodeBuffer(packetID uint32, aadPrefix []byte, payload *buf.Buffer) (*buf.Buffer, error) {
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

func (c *tlsCBCDataCodec) Decode(aadPrefix []byte, payload []byte) (uint32, []byte, error) {
	_ = aadPrefix
	protectedPayload := payload
	if c.hmacSize > 0 {
		if len(protectedPayload) < c.hmacSize {
			return 0, nil, E.New("invalid tls data packet")
		}
		receivedMAC := protectedPayload[:c.hmacSize]
		protectedPayload = protectedPayload[c.hmacSize:]
		mac := hmac.New(c.hashFactory, c.receiveHMACKey)
		mac.Write(protectedPayload)
		expectedMAC := mac.Sum(nil)
		if !hmac.Equal(receivedMAC, expectedMAC) {
			return 0, nil, E.New("invalid tls data packet hmac")
		}
	}
	plainPayload := protectedPayload
	if c.receiveCipher != nil {
		blockSize := c.receiveCipher.BlockSize()
		if len(protectedPayload) < blockSize*2 || len(protectedPayload)%blockSize != 0 {
			return 0, nil, E.New("invalid tls data packet")
		}
		initializationVector := protectedPayload[:blockSize]
		cipherPayload := protectedPayload[blockSize:]
		decodedPayload := make([]byte, len(cipherPayload))
		cipher.NewCBCDecrypter(c.receiveCipher, initializationVector).CryptBlocks(decodedPayload, cipherPayload)
		unpaddedPayload, err := pkcs7Unpad(decodedPayload, blockSize)
		if err != nil {
			return 0, nil, err
		}
		plainPayload = unpaddedPayload
	}
	if len(plainPayload) < 4 {
		return 0, nil, E.New("invalid tls data packet")
	}
	packetID := binary.BigEndian.Uint32(plainPayload[:4])
	if c.replayWindow != nil && !c.replayWindow.Accept(packetID) {
		return 0, nil, E.New("replayed tls data packet")
	}
	return packetID, append([]byte{}, plainPayload[4:]...), nil
}

func (c *tlsCBCDataCodec) DecodeBuffer(aadPrefix []byte, payload []byte, headroom int) (uint32, *buf.Buffer, error) {
	packetID, decodedPayload, err := c.Decode(aadPrefix, payload)
	if err != nil {
		return 0, nil, err
	}
	return packetID, newDataPacketBuffer(headroom, decodedPayload), nil
}
