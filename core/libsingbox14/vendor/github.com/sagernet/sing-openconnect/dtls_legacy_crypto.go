package openconnect

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/des"
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha1"
	"hash"

	E "github.com/sagernet/sing/common/exceptions"
)

const anyConnectLegacyMasterSecretLength = 48

type anyConnectLegacyCipher struct {
	name        string
	id          uint16
	keyLength   int
	blockLength int
	newBlock    func(key []byte) (cipher.Block, error)
}

func (c anyConnectLegacyCipher) suite() legacyDTLSSuite {
	return legacyDTLSSuite{
		label:       "Cisco DTLS 0.9",
		version:     uint16(anyConnectLegacyVersionMajor)<<8 | uint16(anyConnectLegacyVersionMinor),
		newBlock:    c.newBlock,
		blockLength: c.blockLength,
	}
}

func anyConnectLegacyCipherForName(name string, allowInsecureCrypto bool) (anyConnectLegacyCipher, error) {
	switch name {
	case "DHE-RSA-AES128-SHA":
		return anyConnectLegacyCipher{
			name:        name,
			id:          0x0033,
			keyLength:   16,
			blockLength: aes.BlockSize,
			newBlock:    aes.NewCipher,
		}, nil
	case "DHE-RSA-AES256-SHA":
		return anyConnectLegacyCipher{
			name:        name,
			id:          0x0039,
			keyLength:   32,
			blockLength: aes.BlockSize,
			newBlock:    aes.NewCipher,
		}, nil
	case "AES128-SHA":
		return anyConnectLegacyCipher{
			name:        name,
			id:          0x002f,
			keyLength:   16,
			blockLength: aes.BlockSize,
			newBlock:    aes.NewCipher,
		}, nil
	case "AES256-SHA":
		return anyConnectLegacyCipher{
			name:        name,
			id:          0x0035,
			keyLength:   32,
			blockLength: aes.BlockSize,
			newBlock:    aes.NewCipher,
		}, nil
	case "DES-CBC3-SHA":
		if !allowInsecureCrypto {
			return anyConnectLegacyCipher{}, E.Extend(ErrDeprecatedCryptoDisabled, "DTLS cipher ", name)
		}
		return anyConnectLegacyCipher{
			name:        name,
			id:          0x000a,
			keyLength:   24,
			blockLength: des.BlockSize,
			newBlock:    des.NewTripleDESCipher,
		}, nil
	case "DES-CBC-SHA":
		if !allowInsecureCrypto {
			return anyConnectLegacyCipher{}, E.Extend(ErrDeprecatedCryptoDisabled, "DTLS cipher ", name)
		}
		return anyConnectLegacyCipher{
			name:        name,
			id:          0x0009,
			keyLength:   8,
			blockLength: des.BlockSize,
			newBlock:    des.NewCipher,
		}, nil
	default:
		return anyConnectLegacyCipher{}, E.Extend(ErrProtocolNotSupported, "Cisco DTLS 0.9 cipher ", name)
	}
}

func anyConnectLegacyFinished(masterSecret []byte, label string, transcript []byte) ([]byte, error) {
	md5Hash := md5.New()
	_, err := md5Hash.Write(transcript)
	if err != nil {
		return nil, E.Cause(err, "hash Cisco DTLS 0.9 MD5 handshake transcript")
	}
	sha1Hash := sha1.New()
	_, err = sha1Hash.Write(transcript)
	if err != nil {
		return nil, E.Cause(err, "hash Cisco DTLS 0.9 SHA-1 handshake transcript")
	}
	handshakeHash := append(md5Hash.Sum(nil), sha1Hash.Sum(nil)...)
	return tls10PRF(masterSecret, label, handshakeHash, 12)
}

func tls10PRF(secret []byte, label string, seed []byte, outputLength int) ([]byte, error) {
	labeledSeed := make([]byte, 0, len(label)+len(seed))
	labeledSeed = append(labeledSeed, label...)
	labeledSeed = append(labeledSeed, seed...)
	halfLength := (len(secret) + 1) / 2
	md5Output, err := tls10PHash(secret[:halfLength], labeledSeed, outputLength, md5.New)
	if err != nil {
		return nil, err
	}
	sha1Output, err := tls10PHash(secret[len(secret)-halfLength:], labeledSeed, outputLength, sha1.New)
	if err != nil {
		return nil, err
	}
	for i := range md5Output {
		md5Output[i] ^= sha1Output[i]
	}
	return md5Output, nil
}

func tls10PHash(secret []byte, seed []byte, outputLength int, hashFunction func() hash.Hash) ([]byte, error) {
	result := make([]byte, 0, outputLength)
	a := append([]byte(nil), seed...)
	for len(result) < outputLength {
		mac := hmac.New(hashFunction, secret)
		_, err := mac.Write(a)
		if err != nil {
			return nil, E.Cause(err, "advance TLS 1.0 PRF")
		}
		a = mac.Sum(nil)
		mac = hmac.New(hashFunction, secret)
		_, err = mac.Write(a)
		if err != nil {
			return nil, E.Cause(err, "write TLS 1.0 PRF round state")
		}
		_, err = mac.Write(seed)
		if err != nil {
			return nil, E.Cause(err, "write TLS 1.0 PRF seed")
		}
		result = append(result, mac.Sum(nil)...)
	}
	return result[:outputLength], nil
}
