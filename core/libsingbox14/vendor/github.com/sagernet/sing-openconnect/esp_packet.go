package openconnect

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5" //nolint:gosec // OpenConnect negotiates HMAC-MD5-96 for ESP.
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/binary"
	"hash"
	"math"
	"sync"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	espFixedHeaderSize = 8 + aes.BlockSize
	espIPv4NextHeader  = 4
	espLZONextHeader   = 5
	espIPv6NextHeader  = 41
)

var (
	errESPInvalidDatagram      = E.New("invalid ESP datagram")
	errESPAuthenticationFailed = E.New("ESP authentication failed")
	errESPReplay               = E.New("ESP replay rejected")
	errESPSequenceExhausted    = E.New("ESP sequence exhausted")
	errESPKeysDestroyed        = E.New("ESP keys are destroyed")
)

type espEncryption uint8

const (
	espEncryptionAES128CBC espEncryption = iota + 1
	espEncryptionAES256CBC
)

func (e espEncryption) keyLength() int {
	switch e {
	case espEncryptionAES128CBC:
		return 16
	case espEncryptionAES256CBC:
		return 32
	default:
		return 0
	}
}

type espAuthentication uint8

const (
	espAuthenticationHMACMD596 espAuthentication = iota + 1
	espAuthenticationHMACSHA196
	espAuthenticationHMACSHA256128
)

func (a espAuthentication) keyLength() int {
	switch a {
	case espAuthenticationHMACMD596:
		return md5.Size
	case espAuthenticationHMACSHA196:
		return sha1.Size
	case espAuthenticationHMACSHA256128:
		return sha256.Size
	default:
		return 0
	}
}

func (a espAuthentication) icvLength() int {
	switch a {
	case espAuthenticationHMACMD596, espAuthenticationHMACSHA196:
		return 12
	case espAuthenticationHMACSHA256128:
		return 16
	default:
		return 0
	}
}

func (a espAuthentication) hash() func() hash.Hash {
	switch a {
	case espAuthenticationHMACMD596:
		return md5.New //nolint:gosec // OpenConnect negotiates HMAC-MD5-96 for ESP.
	case espAuthenticationHMACSHA196:
		return sha1.New
	case espAuthenticationHMACSHA256128:
		return sha256.New
	default:
		return nil
	}
}

type espKeyMaterial struct {
	SPI               uint32
	EncryptionKey     []byte
	AuthenticationKey []byte
}

type espKeySetConfig struct {
	Encryption              espEncryption
	Authentication          espAuthentication
	Outbound                espKeyMaterial
	Inbound                 espKeyMaterial
	DisableReplayProtection bool
}

type espSecurityAssociation struct {
	encryption        espEncryption
	authentication    espAuthentication
	spi               uint32
	encryptionKey     []byte
	authenticationKey []byte
	block             cipher.Block
	mac               hash.Hash
	icv               [sha256.Size]byte
	sequence          uint64
	replay            espReplayWindow
	iv                [aes.BlockSize]byte
	valid             bool
}

func newESPSecurityAssociation(
	encryption espEncryption,
	authentication espAuthentication,
	material espKeyMaterial,
	outbound bool,
) (espSecurityAssociation, error) {
	encryptionKeyLength := encryption.keyLength()
	if encryptionKeyLength == 0 {
		return espSecurityAssociation{}, E.New("unknown ESP encryption algorithm: ", encryption)
	}
	authenticationKeyLength := authentication.keyLength()
	if authenticationKeyLength == 0 {
		return espSecurityAssociation{}, E.New("unknown ESP authentication algorithm: ", authentication)
	}
	if material.SPI == 0 {
		return espSecurityAssociation{}, E.New("ESP SPI is zero")
	}
	if len(material.EncryptionKey) != encryptionKeyLength {
		return espSecurityAssociation{}, E.New("invalid ESP encryption key length: ", len(material.EncryptionKey), " != ", encryptionKeyLength)
	}
	if len(material.AuthenticationKey) != authenticationKeyLength {
		return espSecurityAssociation{}, E.New("invalid ESP authentication key length: ", len(material.AuthenticationKey), " != ", authenticationKeyLength)
	}
	association := espSecurityAssociation{
		encryption:        encryption,
		authentication:    authentication,
		spi:               material.SPI,
		encryptionKey:     append([]byte(nil), material.EncryptionKey...),
		authenticationKey: append([]byte(nil), material.AuthenticationKey...),
		valid:             true,
	}
	block, err := aes.NewCipher(association.encryptionKey)
	if err != nil {
		association.destroy()
		return espSecurityAssociation{}, E.Cause(err, "initialize ESP cipher")
	}
	association.block = block
	association.mac = hmac.New(authentication.hash(), association.authenticationKey)
	if outbound {
		_, err = rand.Read(association.iv[:])
		if err != nil {
			association.destroy()
			return espSecurityAssociation{}, E.Cause(err, "generate initial ESP IV")
		}
	}
	return association, nil
}

func (a *espSecurityAssociation) destroy() {
	clear(a.encryptionKey)
	clear(a.authenticationKey)
	clear(a.iv[:])
	*a = espSecurityAssociation{}
}

type espKeySet struct {
	outboundAccess          sync.Mutex
	inboundAccess           sync.Mutex
	outbound                espSecurityAssociation
	currentInbound          espSecurityAssociation
	previousInbound         espSecurityAssociation
	previousLimit           uint64
	disableReplayProtection bool
	destroyed               bool
}

func newESPKeySet(config espKeySetConfig) (*espKeySet, error) {
	outbound, err := newESPSecurityAssociation(config.Encryption, config.Authentication, config.Outbound, true)
	if err != nil {
		return nil, E.Cause(err, "initialize outbound ESP security association")
	}
	inbound, err := newESPSecurityAssociation(config.Encryption, config.Authentication, config.Inbound, false)
	if err != nil {
		outbound.destroy()
		return nil, E.Cause(err, "initialize inbound ESP security association")
	}
	return &espKeySet{
		outbound:                outbound,
		currentInbound:          inbound,
		disableReplayProtection: config.DisableReplayProtection,
	}, nil
}

func (s *espKeySet) install(config espKeySetConfig) error {
	outbound, err := newESPSecurityAssociation(config.Encryption, config.Authentication, config.Outbound, true)
	if err != nil {
		return E.Cause(err, "initialize replacement outbound ESP security association")
	}
	inbound, err := newESPSecurityAssociation(config.Encryption, config.Authentication, config.Inbound, false)
	if err != nil {
		outbound.destroy()
		return E.Cause(err, "initialize replacement inbound ESP security association")
	}
	s.outboundAccess.Lock()
	defer s.outboundAccess.Unlock()
	s.inboundAccess.Lock()
	defer s.inboundAccess.Unlock()
	if s.destroyed {
		outbound.destroy()
		inbound.destroy()
		return errESPKeysDestroyed
	}
	s.outbound.destroy()
	s.previousInbound.destroy()
	s.previousInbound = s.currentInbound
	s.previousLimit = s.currentInbound.replay.nextSequence + 32
	s.outbound = outbound
	s.currentInbound = inbound
	s.disableReplayProtection = config.DisableReplayProtection
	return nil
}

func (s *espKeySet) sealBuffer(packetBuffer **buf.Buffer, nextHeader byte) error {
	s.outboundAccess.Lock()
	defer s.outboundAccess.Unlock()
	if s.destroyed || !s.outbound.valid {
		return errESPKeysDestroyed
	}
	payload := (*packetBuffer).Bytes()
	if nextHeader == 0 {
		if len(payload) == 0 {
			return E.Extend(errESPInvalidDatagram, "empty ESP payload")
		}
		switch payload[0] >> 4 {
		case 4:
			nextHeader = espIPv4NextHeader
		case 6:
			nextHeader = espIPv6NextHeader
		default:
			return E.Extend(errESPInvalidDatagram, "unknown inner IP version")
		}
	}
	if nextHeader != espIPv4NextHeader && nextHeader != espIPv6NextHeader && nextHeader != espLZONextHeader {
		return E.Extend(errESPInvalidDatagram, "unknown next header: ", nextHeader)
	}
	if s.outbound.sequence > math.MaxUint32 {
		return errESPSequenceExhausted
	}
	icvLength := s.outbound.authentication.icvLength()
	paddingLength := aes.BlockSize - 1 - (len(payload)+1)%aes.BlockSize
	ciphertextLength := len(payload) + paddingLength + 2
	// /tmp/openconnect/esp.c:construct_esp_packet() appends ESP padding, pad length, and next header before encrypt_esp_packet() appends the ICV.
	*packetBuffer = requirePacketBufferCapacity(*packetBuffer, espFixedHeaderSize, paddingLength+2+icvLength)
	header := (*packetBuffer).ExtendHeader(espFixedHeaderSize)
	datagram := (*packetBuffer).Bytes()
	binary.BigEndian.PutUint32(datagram, s.outbound.spi)
	binary.BigEndian.PutUint32(datagram[4:], uint32(s.outbound.sequence))
	s.outbound.sequence++
	copy(header[8:espFixedHeaderSize], s.outbound.iv[:])
	trailer := (*packetBuffer).Extend(paddingLength + 2)
	for i := range paddingLength {
		trailer[i] = byte(i + 1)
	}
	trailer[len(trailer)-2] = byte(paddingLength)
	trailer[len(trailer)-1] = nextHeader
	datagram = (*packetBuffer).Bytes()
	ciphertext := datagram[espFixedHeaderSize : espFixedHeaderSize+ciphertextLength]
	encrypter := cipher.NewCBCEncrypter(s.outbound.block, s.outbound.iv[:])
	encrypter.CryptBlocks(ciphertext, ciphertext)
	s.outbound.mac.Reset()
	_, _ = s.outbound.mac.Write(datagram[:espFixedHeaderSize+ciphertextLength])
	fullICV := s.outbound.mac.Sum(s.outbound.icv[:0])
	copy((*packetBuffer).Extend(icvLength), fullICV[:icvLength])
	chainInput := fullICV[len(fullICV)-aes.BlockSize:]
	lastCiphertext := ciphertext[len(ciphertext)-aes.BlockSize:]
	var nextIVInput [aes.BlockSize]byte
	for i := range nextIVInput {
		nextIVInput[i] = chainInput[i] ^ lastCiphertext[i]
	}
	// /tmp/openconnect/openssl-esp.c:encrypt_esp_packet() feeds the final full-HMAC block through the live CBC state to obtain the next explicit IV.
	s.outbound.block.Encrypt(s.outbound.iv[:], nextIVInput[:])
	clear(nextIVInput[:])
	return nil
}

func (s *espKeySet) openBuffer(packetBuffer *buf.Buffer) (byte, error) {
	s.inboundAccess.Lock()
	defer s.inboundAccess.Unlock()
	if s.destroyed || !s.currentInbound.valid {
		return 0, errESPKeysDestroyed
	}
	datagram := packetBuffer.Bytes()
	if len(datagram) < 8 {
		return 0, errESPInvalidDatagram
	}
	spi := binary.BigEndian.Uint32(datagram)
	sequence := binary.BigEndian.Uint32(datagram[4:])
	association := &s.currentInbound
	if spi != association.spi {
		if !s.previousInbound.valid || spi != s.previousInbound.spi ||
			uint64(sequence)+s.currentInbound.replay.nextSequence >= s.previousLimit {
			return 0, errESPInvalidDatagram
		}
		association = &s.previousInbound
	}
	icvLength := association.authentication.icvLength()
	if len(datagram) < espFixedHeaderSize+aes.BlockSize+icvLength {
		return 0, errESPInvalidDatagram
	}
	ciphertextLength := len(datagram) - espFixedHeaderSize - icvLength
	if ciphertextLength%aes.BlockSize != 0 {
		return 0, errESPInvalidDatagram
	}
	association.mac.Reset()
	_, _ = association.mac.Write(datagram[:len(datagram)-icvLength])
	expectedICV := association.mac.Sum(association.icv[:0])
	if !hmac.Equal(expectedICV[:icvLength], datagram[len(datagram)-icvLength:]) {
		return 0, errESPAuthenticationFailed
	}
	// /tmp/openconnect/esp-seqno.c:verify_packet_seqno always evaluates the receive window and makes esp_replay_protect control only whether a replay result is rejected.
	replayAccepted := association.replay.accept(sequence)
	if !replayAccepted && !s.disableReplayProtection {
		return 0, errESPReplay
	}
	plaintext := datagram[espFixedHeaderSize : espFixedHeaderSize+ciphertextLength]
	decrypter := cipher.NewCBCDecrypter(association.block, datagram[8:espFixedHeaderSize])
	decrypter.CryptBlocks(plaintext, plaintext)
	paddingLength := int(plaintext[len(plaintext)-2])
	if len(plaintext) <= paddingLength+2 {
		clear(plaintext)
		return 0, errESPInvalidDatagram
	}
	payloadLength := len(plaintext) - paddingLength - 2
	for i := range paddingLength {
		if plaintext[payloadLength+i] != byte(i+1) {
			clear(plaintext)
			return 0, errESPInvalidDatagram
		}
	}
	nextHeader := plaintext[len(plaintext)-1]
	if nextHeader != espIPv4NextHeader && nextHeader != espIPv6NextHeader && nextHeader != espLZONextHeader {
		clear(plaintext)
		return 0, errESPInvalidDatagram
	}
	packetBuffer.Advance(espFixedHeaderSize)
	packetBuffer.Truncate(payloadLength)
	return nextHeader, nil
}

func (s *espKeySet) destroy() {
	s.outboundAccess.Lock()
	defer s.outboundAccess.Unlock()
	s.inboundAccess.Lock()
	defer s.inboundAccess.Unlock()
	if s.destroyed {
		return
	}
	s.destroyed = true
	s.outbound.destroy()
	s.currentInbound.destroy()
	s.previousInbound.destroy()
	s.previousLimit = 0
}
