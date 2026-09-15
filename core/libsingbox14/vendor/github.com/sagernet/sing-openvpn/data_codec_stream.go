package openvpn

import (
	"crypto/cipher"
	"crypto/hmac"
	"encoding/binary"
	"hash"
	"strings"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

type tlsStreamCipherMode uint8

const (
	tlsStreamCipherModeCFB tlsStreamCipherMode = iota
	tlsStreamCipherModeOFB
)

type tlsStreamDataCodec struct {
	sendCipherBlock cipher.Block
	sendHMACKey     []byte
	receiveCipher   cipher.Block
	receiveHMACKey  []byte
	hashFactory     func() hash.Hash
	hmacSize        int
	mode            tlsStreamCipherMode
	sendTimestamp   uint32
	replayWindow    *replayWindow
}

func (c *tlsStreamDataCodec) EncodedLength(payloadLength int) int {
	return c.hmacSize + c.sendCipherBlock.BlockSize() + payloadLength
}

func newTLSStreamDataCodec(keyMaterial []byte, server bool, cipherName string, authName string, replayWindowSize uint32, replayWindowTime time.Duration) (dataCodec, error) {
	if len(keyMaterial) < 256 {
		return nil, E.New("invalid tls key material")
	}
	mode, cbcCipherName, cipherKeySize, err := tlsStreamCipherSpec(cipherName)
	if err != nil {
		return nil, err
	}
	keySlots := splitStaticKeyMaterial(keyMaterial)
	sendSlot, receiveSlot := tlsDataKeySlots(keySlots, server)
	hashFactory, hmacSize, err := staticHMACFactory(authName)
	if err != nil {
		return nil, err
	}
	sendCipherBlock, err := newStaticCipherBlock(cbcCipherName, sendSlot.cipherKey, cipherKeySize)
	if err != nil {
		return nil, err
	}
	receiveCipherBlock, err := newStaticCipherBlock(cbcCipherName, receiveSlot.cipherKey, cipherKeySize)
	if err != nil {
		return nil, err
	}
	var sendHMACKey []byte
	var receiveHMACKey []byte
	if hmacSize > 0 {
		sendHMACKey = append([]byte{}, sendSlot.hmacKey[:hmacSize]...)
		receiveHMACKey = append([]byte{}, receiveSlot.hmacKey[:hmacSize]...)
	}
	return &tlsStreamDataCodec{
		sendCipherBlock: sendCipherBlock,
		sendHMACKey:     sendHMACKey,
		receiveCipher:   receiveCipherBlock,
		receiveHMACKey:  receiveHMACKey,
		hashFactory:     hashFactory,
		hmacSize:        hmacSize,
		mode:            mode,
		sendTimestamp:   uint32(time.Now().Unix()),
		replayWindow:    newReplayWindow(replayWindowSize, replayWindowTime),
	}, nil
}

func tlsStreamCipherSpec(cipherName string) (tlsStreamCipherMode, string, int, error) {
	var mode tlsStreamCipherMode
	var cbcCipherName string
	if strings.HasSuffix(cipherName, "-CFB") {
		mode = tlsStreamCipherModeCFB
		cbcCipherName = strings.TrimSuffix(cipherName, "-CFB") + "-CBC"
	} else if strings.HasSuffix(cipherName, "-OFB") {
		mode = tlsStreamCipherModeOFB
		cbcCipherName = strings.TrimSuffix(cipherName, "-OFB") + "-CBC"
	} else {
		return 0, "", 0, E.New("unsupported tls stream cipher")
	}
	cipherKeySize, err := staticCipherKeySize(cbcCipherName)
	if err != nil {
		return 0, "", 0, E.New("unsupported tls stream cipher")
	}
	return mode, cbcCipherName, cipherKeySize, nil
}

func (c *tlsStreamDataCodec) Encode(packetID uint32, aadPrefix []byte, payload []byte) ([]byte, error) {
	_ = aadPrefix
	if packetID == 0 {
		return nil, E.New("invalid data packet id")
	}
	initializationVector := make([]byte, c.sendCipherBlock.BlockSize())
	binary.BigEndian.PutUint32(initializationVector[:4], packetID)
	binary.BigEndian.PutUint32(initializationVector[4:8], c.sendTimestamp)
	cipherPayload := make([]byte, len(payload))
	c.stream(c.sendCipherBlock, initializationVector, true).XORKeyStream(cipherPayload, payload)
	protectedPayload := make([]byte, 0, len(initializationVector)+len(cipherPayload))
	protectedPayload = append(protectedPayload, initializationVector...)
	protectedPayload = append(protectedPayload, cipherPayload...)
	if c.hmacSize == 0 {
		return protectedPayload, nil
	}
	mac := hmac.New(c.hashFactory, c.sendHMACKey)
	mac.Write(protectedPayload)
	return append(mac.Sum(nil), protectedPayload...), nil
}

func (c *tlsStreamDataCodec) EncodeBuffer(packetID uint32, aadPrefix []byte, payload *buf.Buffer) (*buf.Buffer, error) {
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

func (c *tlsStreamDataCodec) Decode(aadPrefix []byte, payload []byte) (uint32, []byte, error) {
	_ = aadPrefix
	protectedPayload := payload
	if c.hmacSize > 0 {
		if len(protectedPayload) < c.hmacSize {
			return 0, nil, E.New("invalid tls stream data packet")
		}
		receivedMAC := protectedPayload[:c.hmacSize]
		protectedPayload = protectedPayload[c.hmacSize:]
		mac := hmac.New(c.hashFactory, c.receiveHMACKey)
		mac.Write(protectedPayload)
		if !hmac.Equal(receivedMAC, mac.Sum(nil)) {
			return 0, nil, E.New("invalid tls stream data packet hmac")
		}
	}
	blockSize := c.receiveCipher.BlockSize()
	if len(protectedPayload) <= blockSize {
		return 0, nil, E.New("invalid tls stream data packet")
	}
	initializationVector := protectedPayload[:blockSize]
	packetID := binary.BigEndian.Uint32(initializationVector[:4])
	packetTimestamp := binary.BigEndian.Uint32(initializationVector[4:8])
	cipherPayload := protectedPayload[blockSize:]
	decodedPayload := make([]byte, len(cipherPayload))
	c.stream(c.receiveCipher, initializationVector, false).XORKeyStream(decodedPayload, cipherPayload)
	if c.replayWindow != nil && !c.replayWindow.AcceptLongForm(packetID, packetTimestamp) {
		return 0, nil, E.New("replayed tls stream data packet")
	}
	return packetID, decodedPayload, nil
}

func (c *tlsStreamDataCodec) DecodeBuffer(aadPrefix []byte, payload []byte, headroom int) (uint32, *buf.Buffer, error) {
	packetID, decodedPayload, err := c.Decode(aadPrefix, payload)
	if err != nil {
		return 0, nil, err
	}
	return packetID, newDataPacketBuffer(headroom, decodedPayload), nil
}

func (c *tlsStreamDataCodec) stream(block cipher.Block, initializationVector []byte, encrypt bool) cipher.Stream {
	if c.mode == tlsStreamCipherModeOFB {
		//nolint:staticcheck // OpenVPN retained CFB/OFB compatibility requires this mode.
		return cipher.NewOFB(block, initializationVector)
	}
	if encrypt {
		//nolint:staticcheck // OpenVPN retained CFB/OFB compatibility requires this mode.
		return cipher.NewCFBEncrypter(block, initializationVector)
	}
	//nolint:staticcheck // OpenVPN retained CFB/OFB compatibility requires this mode.
	return cipher.NewCFBDecrypter(block, initializationVector)
}
