package openconnect

import (
	"crypto"
	"crypto/aes"
	"crypto/ecdh"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"slices"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	tlsECDHERSAWithAES128CBCSHA uint16 = 0xc013
	tlsECDHERSAWithAES256CBCSHA uint16 = 0xc014
)

type certificateDTLS10Cipher struct {
	id        uint16
	keyLength int
	ecdhe     bool
}

func certificateDTLS10Suite() legacyDTLSSuite {
	return legacyDTLSSuite{
		label:       "certificate DTLS 1.0",
		version:     certificateDTLSVersion10,
		newBlock:    aes.NewCipher,
		blockLength: aes.BlockSize,
	}
}

func certificateDTLS10CipherSuites(configured []uint16) ([]certificateDTLS10Cipher, error) {
	available := map[uint16]certificateDTLS10Cipher{
		tlsECDHERSAWithAES128CBCSHA:    {id: tlsECDHERSAWithAES128CBCSHA, keyLength: 16, ecdhe: true},
		tlsECDHERSAWithAES256CBCSHA:    {id: tlsECDHERSAWithAES256CBCSHA, keyLength: 32, ecdhe: true},
		uint16(tlsRSAWithAES128CBCSHA): {id: uint16(tlsRSAWithAES128CBCSHA), keyLength: 16},
		uint16(tlsRSAWithAES256CBCSHA): {id: uint16(tlsRSAWithAES256CBCSHA), keyLength: 32},
	}
	if len(configured) == 0 {
		return []certificateDTLS10Cipher{
			available[tlsECDHERSAWithAES128CBCSHA],
			available[tlsECDHERSAWithAES256CBCSHA],
			available[uint16(tlsRSAWithAES128CBCSHA)],
			available[uint16(tlsRSAWithAES256CBCSHA)],
		}, nil
	}
	result := make([]certificateDTLS10Cipher, 0, len(configured))
	for _, configuredCipher := range configured {
		cipherSuite, exists := available[configuredCipher]
		if exists {
			result = append(result, cipherSuite)
		}
	}
	if len(result) == 0 {
		return nil, E.Extend(ErrProtocolNotSupported, "configured TLS cipher suites have no F5 DTLS 1.0 equivalent")
	}
	return result, nil
}

func certificateDTLS10Curves(configured []tls.CurveID) ([]uint16, error) {
	if len(configured) == 0 {
		return []uint16{23, 24, 25}, nil
	}
	curves := make([]uint16, 0, len(configured))
	for _, curve := range configured {
		switch curve {
		case tls.CurveP256:
			curves = append(curves, 23)
		case tls.CurveP384:
			curves = append(curves, 24)
		case tls.CurveP521:
			curves = append(curves, 25)
		}
	}
	if len(curves) == 0 {
		return nil, E.Extend(ErrProtocolNotSupported, "configured TLS curves have no F5 DTLS 1.0 equivalent")
	}
	return curves, nil
}

func verifyCertificateDTLS10Peer(
	tlsConfig *tls.Config,
	serverName string,
	rawCertificates [][]byte,
	cipherSuite uint16,
) ([]*x509.Certificate, [][]*x509.Certificate, error) {
	certificates, verifiedChains, err := verifyCertificateDTLSChain(tlsConfig, serverName, rawCertificates)
	if err != nil {
		return nil, nil, err
	}
	if tlsConfig.VerifyPeerCertificate != nil {
		err = tlsConfig.VerifyPeerCertificate(cloneByteSlices(rawCertificates), cloneCertificateChains(verifiedChains))
		if err != nil {
			return nil, nil, E.Cause(err, "verify certificate DTLS 1.0 peer certificate callback")
		}
	}
	if tlsConfig.VerifyConnection != nil {
		err = tlsConfig.VerifyConnection(tls.ConnectionState{
			Version:                    tls.VersionTLS11,
			HandshakeComplete:          false,
			CipherSuite:                cipherSuite,
			NegotiatedProtocolIsMutual: true,
			ServerName:                 serverName,
			PeerCertificates:           append([]*x509.Certificate(nil), certificates...),
			VerifiedChains:             cloneCertificateChains(verifiedChains),
		})
		if err != nil {
			return nil, nil, E.Cause(err, "verify certificate DTLS 1.0 connection")
		}
	}
	return certificates, verifiedChains, nil
}

func (h *certificateDTLS10Handshake) buildClientKeyExchange() ([]byte, []byte, error) {
	leaf := h.flight.peerCertificates[0]
	rsaPublicKey, isRSA := leaf.PublicKey.(*rsa.PublicKey)
	if !isRSA {
		return nil, nil, E.Extend(ErrProtocolNotSupported, "DTLS 1.0 requires an RSA server certificate")
	}
	if !h.flight.cipherSuite.ecdhe {
		preMasterSecret := make([]byte, 48)
		binary.BigEndian.PutUint16(preMasterSecret[:2], certificateDTLSVersion10)
		_, err := rand.Read(preMasterSecret[2:])
		if err != nil {
			clear(preMasterSecret)
			return nil, nil, E.Cause(err, "generate certificate DTLS 1.0 RSA premaster secret")
		}
		encrypted, err := rsa.EncryptPKCS1v15(rand.Reader, rsaPublicKey, preMasterSecret)
		if err != nil {
			clear(preMasterSecret)
			return nil, nil, E.Cause(err, "encrypt certificate DTLS 1.0 RSA premaster secret")
		}
		body := make([]byte, 2+len(encrypted))
		binary.BigEndian.PutUint16(body[:2], uint16(len(encrypted)))
		copy(body[2:], encrypted)
		clear(encrypted)
		return preMasterSecret, body, nil
	}

	body := h.flight.serverKeyExchange
	if len(body) < 4 || body[0] != 3 {
		return nil, nil, E.New("invalid certificate DTLS 1.0 ECDHE ServerKeyExchange")
	}
	curveID := binary.BigEndian.Uint16(body[1:3])
	curveOffered := slices.Contains(h.offeredCurves, curveID)
	if !curveOffered {
		return nil, nil, E.New("certificate DTLS 1.0 server selected unoffered curve: ", curveID)
	}
	var curve ecdh.Curve
	switch curveID {
	case 23:
		curve = ecdh.P256()
	case 24:
		curve = ecdh.P384()
	case 25:
		curve = ecdh.P521()
	default:
		return nil, nil, E.Extend(ErrProtocolNotSupported, "DTLS 1.0 ECDHE named curve ", curveID)
	}
	publicKeyLength := int(body[3])
	if publicKeyLength == 0 || len(body) < 4+publicKeyLength+2 {
		return nil, nil, E.New("truncated certificate DTLS 1.0 ECDHE ServerKeyExchange")
	}
	parameters := body[:4+publicKeyLength]
	signatureLength := int(binary.BigEndian.Uint16(body[4+publicKeyLength : 6+publicKeyLength]))
	if signatureLength == 0 || len(body) != 6+publicKeyLength+signatureLength {
		return nil, nil, E.New("invalid certificate DTLS 1.0 ECDHE ServerKeyExchange signature")
	}
	signedInput := make([]byte, 0, len(h.clientRandom)+len(h.flight.serverRandom)+len(parameters))
	signedInput = append(signedInput, h.clientRandom...)
	signedInput = append(signedInput, h.flight.serverRandom...)
	signedInput = append(signedInput, parameters...)
	md5Digest := md5.Sum(signedInput)
	sha1Digest := sha1.Sum(signedInput)
	digest := make([]byte, 0, len(md5Digest)+len(sha1Digest))
	digest = append(digest, md5Digest[:]...)
	digest = append(digest, sha1Digest[:]...)
	clear(signedInput)
	err := rsa.VerifyPKCS1v15(rsaPublicKey, crypto.MD5SHA1, digest, body[6+publicKeyLength:])
	clear(digest)
	if err != nil {
		return nil, nil, E.Cause(err, "verify certificate DTLS 1.0 ECDHE ServerKeyExchange")
	}
	peerPublicKey, err := curve.NewPublicKey(body[4 : 4+publicKeyLength])
	if err != nil {
		return nil, nil, E.Cause(err, "parse certificate DTLS 1.0 ECDHE public key")
	}
	privateKey, err := curve.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, E.Cause(err, "generate certificate DTLS 1.0 ECDHE key")
	}
	preMasterSecret, err := privateKey.ECDH(peerPublicKey)
	if err != nil {
		return nil, nil, E.Cause(err, "derive certificate DTLS 1.0 ECDHE premaster secret")
	}
	publicKey := privateKey.PublicKey().Bytes()
	clientKeyExchange := make([]byte, 1+len(publicKey))
	clientKeyExchange[0] = byte(len(publicKey))
	copy(clientKeyExchange[1:], publicKey)
	clear(publicKey)
	return preMasterSecret, clientKeyExchange, nil
}

func (h *certificateDTLS10Handshake) selectClientCertificate() (*tls.Certificate, error) {
	rsaAccepted := slices.Contains(h.flight.certificateTypes, 1)
	if !rsaAccepted {
		return new(tls.Certificate), nil
	}
	if h.tlsConfig.GetClientCertificate != nil {
		certificate, err := h.tlsConfig.GetClientCertificate(&tls.CertificateRequestInfo{
			AcceptableCAs:    cloneByteSlices(h.flight.acceptableCAs),
			SignatureSchemes: []tls.SignatureScheme{tls.PKCS1WithSHA1},
			Version:          tls.VersionTLS11,
		})
		if err != nil {
			return nil, E.Cause(err, "select certificate DTLS 1.0 client certificate")
		}
		return certificate, nil
	}
	for i := range h.tlsConfig.Certificates {
		certificate := &h.tlsConfig.Certificates[i]
		_, isRSA := certificateDTLSRSASigner(certificate)
		if isRSA && certificateDTLSCertificateMatchesCA(certificate, h.flight.acceptableCAs) {
			return certificate, nil
		}
	}
	return new(tls.Certificate), nil
}

func certificateDTLSCertificateMatchesCA(certificate *tls.Certificate, acceptableCAs [][]byte) bool {
	if len(acceptableCAs) == 0 {
		return true
	}
	for i, rawCertificate := range certificate.Certificate {
		parsedCertificate := certificate.Leaf
		if i != 0 || parsedCertificate == nil {
			var err error
			parsedCertificate, err = x509.ParseCertificate(rawCertificate)
			if err != nil {
				continue
			}
		}
		for _, acceptableCA := range acceptableCAs {
			if equalBytes(parsedCertificate.RawIssuer, acceptableCA) {
				return true
			}
		}
	}
	return false
}

func signCertificateDTLS10Transcript(certificate *tls.Certificate, transcript []byte) ([]byte, error) {
	signer, isRSA := certificateDTLSRSASigner(certificate)
	if !isRSA {
		return nil, E.Extend(ErrProtocolNotSupported, "DTLS 1.0 client certificate requires an RSA key")
	}
	md5Digest := md5.Sum(transcript)
	sha1Digest := sha1.Sum(transcript)
	digest := make([]byte, 0, len(md5Digest)+len(sha1Digest))
	digest = append(digest, md5Digest[:]...)
	digest = append(digest, sha1Digest[:]...)
	signature, err := signer.Sign(rand.Reader, digest, crypto.MD5SHA1)
	clear(digest)
	if err != nil {
		return nil, E.Cause(err, "sign certificate DTLS 1.0 CertificateVerify")
	}
	body := make([]byte, 2+len(signature))
	binary.BigEndian.PutUint16(body[:2], uint16(len(signature)))
	copy(body[2:], signature)
	clear(signature)
	return body, nil
}

func certificateDTLSRSASigner(certificate *tls.Certificate) (crypto.Signer, bool) {
	if certificate == nil {
		return nil, false
	}
	signer, isSigner := certificate.PrivateKey.(crypto.Signer)
	if !isSigner {
		return nil, false
	}
	_, isRSA := signer.Public().(*rsa.PublicKey)
	return signer, isRSA
}

func certificateDTLS10Finished(masterSecret []byte, label string, transcript []byte) ([]byte, error) {
	md5Digest := md5.Sum(transcript)
	sha1Digest := sha1.Sum(transcript)
	handshakeHash := make([]byte, 0, len(md5Digest)+len(sha1Digest))
	handshakeHash = append(handshakeHash, md5Digest[:]...)
	handshakeHash = append(handshakeHash, sha1Digest[:]...)
	verifyData, err := tls10PRF(masterSecret, label, handshakeHash, 12)
	clear(handshakeHash)
	return verifyData, err
}
