package openconnect

import (
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"hash"
	"sync/atomic"

	E "github.com/sagernet/sing/common/exceptions"

	"github.com/pion/dtls/v3"
	pioncipher "github.com/pion/dtls/v3/pkg/crypto/ciphersuite"
	"github.com/pion/dtls/v3/pkg/crypto/clientcertificate"
	"github.com/pion/dtls/v3/pkg/crypto/prf"
	"github.com/pion/dtls/v3/pkg/protocol/recordlayer"
)

const (
	tlsRSAWithAES128CBCSHA    dtls.CipherSuiteID = 0x002f
	tlsDHERSAWithAES128CBCSHA dtls.CipherSuiteID = 0x0033
	tlsRSAWithAES256CBCSHA    dtls.CipherSuiteID = 0x0035
	tlsDHERSAWithAES256CBCSHA dtls.CipherSuiteID = 0x0039
	tlsRSAWithAES128GCMSHA256 dtls.CipherSuiteID = 0x009c
	tlsRSAWithAES256GCMSHA384 dtls.CipherSuiteID = 0x009d
)

type anyConnectPionRecordCipher interface {
	Encrypt(packet *recordlayer.RecordLayer, raw []byte) ([]byte, error)
	Decrypt(header recordlayer.Header, raw []byte) ([]byte, error)
}

type anyConnectPionCipherSuite struct {
	id           dtls.CipherSuiteID
	name         string
	keyLength    int
	cbc          bool
	hashFunction func() hash.Hash
	protection   atomic.Value
}

func (c *anyConnectPionCipherSuite) String() string {
	return c.name
}

func (c *anyConnectPionCipherSuite) ID() dtls.CipherSuiteID {
	return c.id
}

func (c *anyConnectPionCipherSuite) CertificateType() clientcertificate.Type {
	return clientcertificate.RSASign
}

func (c *anyConnectPionCipherSuite) HashFunc() func() hash.Hash {
	return c.hashFunction
}

func (c *anyConnectPionCipherSuite) AuthenticationType() dtls.CipherSuiteAuthenticationType {
	return dtls.CipherSuiteAuthenticationTypeCertificate
}

func (c *anyConnectPionCipherSuite) KeyExchangeAlgorithm() dtls.CipherSuiteKeyExchangeAlgorithm {
	return dtls.CipherSuiteKeyExchangeAlgorithmNone
}

func (c *anyConnectPionCipherSuite) ECC() bool {
	return false
}

func (c *anyConnectPionCipherSuite) Init(masterSecret, clientRandom, serverRandom []byte, isClient bool) error {
	macLength := 0
	ivLength := 4
	if c.cbc {
		macLength = sha1.Size
		ivLength = 16
	}
	// Upstream gnutls_dtls_ciphers uses the TLS 1.2 PRF selected by the suite while its CBC record MAC remains SHA-1.
	keys, err := prf.GenerateEncryptionKeys(
		masterSecret,
		clientRandom,
		serverRandom,
		macLength,
		c.keyLength,
		ivLength,
		c.hashFunction,
	)
	if err != nil {
		return E.Cause(err, "derive Cisco DTLS 1.2 abbreviated-session keys")
	}
	var protection anyConnectPionRecordCipher
	if c.cbc {
		if isClient {
			protection, err = pioncipher.NewCBC(
				keys.ClientWriteKey,
				keys.ClientWriteIV,
				keys.ClientMACKey,
				keys.ServerWriteKey,
				keys.ServerWriteIV,
				keys.ServerMACKey,
				sha1.New,
			)
		} else {
			protection, err = pioncipher.NewCBC(
				keys.ServerWriteKey,
				keys.ServerWriteIV,
				keys.ServerMACKey,
				keys.ClientWriteKey,
				keys.ClientWriteIV,
				keys.ClientMACKey,
				sha1.New,
			)
		}
	} else if isClient {
		protection, err = pioncipher.NewGCM(
			keys.ClientWriteKey,
			keys.ClientWriteIV,
			keys.ServerWriteKey,
			keys.ServerWriteIV,
		)
	} else {
		protection, err = pioncipher.NewGCM(
			keys.ServerWriteKey,
			keys.ServerWriteIV,
			keys.ClientWriteKey,
			keys.ClientWriteIV,
		)
	}
	if err != nil {
		return E.Cause(err, "initialize Cisco DTLS 1.2 record protection")
	}
	c.protection.Store(protection)
	return nil
}

func (c *anyConnectPionCipherSuite) IsInitialized() bool {
	return c.protection.Load() != nil
}

func (c *anyConnectPionCipherSuite) Encrypt(packet *recordlayer.RecordLayer, raw []byte) ([]byte, error) {
	value := c.protection.Load()
	protection, loaded := value.(anyConnectPionRecordCipher)
	if !loaded {
		return nil, E.New("Cisco DTLS 1.2 cipher suite is not initialized")
	}
	return protection.Encrypt(packet, raw)
}

func (c *anyConnectPionCipherSuite) Decrypt(header recordlayer.Header, raw []byte) ([]byte, error) {
	value := c.protection.Load()
	protection, loaded := value.(anyConnectPionRecordCipher)
	if !loaded {
		return nil, E.New("Cisco DTLS 1.2 cipher suite is not initialized")
	}
	return protection.Decrypt(header, raw)
}

func anyConnectDTLS12CipherSuite(
	name string,
	dtls12 bool,
) (dtls.CipherSuiteID, bool, dtls.CipherSuite, error) {
	var customCipherSuiteID dtls.CipherSuiteID
	var keyLength int
	cbc := false
	hashFunction := sha256.New
	switch name {
	case "DHE-RSA-AES128-SHA":
		if dtls12 {
			customCipherSuiteID = tlsDHERSAWithAES128CBCSHA
			keyLength = 16
			cbc = true
		}
	case "DHE-RSA-AES256-SHA":
		if dtls12 {
			customCipherSuiteID = tlsDHERSAWithAES256CBCSHA
			keyLength = 32
			cbc = true
		}
	case "AES128-SHA":
		if dtls12 {
			customCipherSuiteID = tlsRSAWithAES128CBCSHA
			keyLength = 16
			cbc = true
		}
	case "AES256-SHA":
		if dtls12 {
			customCipherSuiteID = tlsRSAWithAES256CBCSHA
			keyLength = 32
			cbc = true
		}
	case "ECDHE-RSA-AES128-GCM-SHA256":
		if dtls12 {
			return dtls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, false, nil, nil
		}
	case "ECDHE-RSA-AES256-GCM-SHA384":
		if dtls12 {
			return dtls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384, false, nil, nil
		}
	case "AES128-GCM-SHA256", "OC-DTLS1_2-AES128-GCM":
		customCipherSuiteID = tlsRSAWithAES128GCMSHA256
		keyLength = 16
	case "AES256-GCM-SHA384", "OC-DTLS1_2-AES256-GCM":
		customCipherSuiteID = tlsRSAWithAES256GCMSHA384
		keyLength = 32
		hashFunction = sha512.New384
	case "OC2-DTLS1_2-CHACHA20-POLY1305":
		return dtls.TLS_PSK_WITH_CHACHA20_POLY1305_SHA256, true, nil, nil
	}
	if customCipherSuiteID != 0 {
		cipherSuite := &anyConnectPionCipherSuite{
			id:           customCipherSuiteID,
			name:         name,
			keyLength:    keyLength,
			cbc:          cbc,
			hashFunction: hashFunction,
		}
		return customCipherSuiteID, false, cipherSuite, nil
	}
	if !dtls12 {
		return 0, false, nil, E.Extend(ErrProtocolNotSupported, "DTLS cipher requires an unrecognized Cisco DTLS 0.9 mode: ", name)
	}
	return 0, false, nil, E.Extend(ErrProtocolNotSupported, "Cisco DTLS 1.2 abbreviated-resumption cipher ", name)
}
