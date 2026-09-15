package openvpn

import (
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"

	E "github.com/sagernet/sing/common/exceptions"
)

type tlsClientCertificateIdentity struct {
	commonName string
	hashes     [][sha256.Size]byte
}

func clientCertificateIdentity(connection *tls.Conn) *tlsClientCertificateIdentity {
	if connection == nil {
		return nil
	}
	certificates := connection.ConnectionState().PeerCertificates
	if len(certificates) == 0 {
		return nil
	}
	identity := &tlsClientCertificateIdentity{
		commonName: certificates[0].Subject.CommonName,
		hashes:     make([][sha256.Size]byte, len(certificates)),
	}
	for certificateIndex, certificate := range certificates {
		identity.hashes[certificateIndex] = sha256.Sum256(certificate.Raw)
	}
	return identity
}

func equalClientCertificateIdentity(left *tlsClientCertificateIdentity, right *tlsClientCertificateIdentity) bool {
	if left == nil || right == nil {
		return left == right
	}
	if left.commonName != right.commonName || len(left.hashes) != len(right.hashes) {
		return false
	}
	for hashIndex := range left.hashes {
		if left.hashes[hashIndex] != right.hashes[hashIndex] {
			return false
		}
	}
	return true
}

func (s *tlsServerSession) lockInitialCertificateIdentity(connection *tls.Conn) {
	s.lockedCertificateIdentity.Store(clientCertificateIdentity(connection))
	s.clientCertificateIdentitySet = true
}

func (s *tlsServerSession) verifyLockedCertificateIdentity(connection *tls.Conn) error {
	currentIdentity := clientCertificateIdentity(connection)
	if !s.clientCertificateIdentitySet || !equalClientCertificateIdentity(s.lockedCertificateIdentity.Load(), currentIdentity) {
		return E.Extend(ErrPeerCertificateVerification, "client certificate identity changed during renegotiation")
	}
	return nil
}

func (s *tlsServerSession) authenticatedIdentityKey() string {
	if certificateIdentity := s.lockedCertificateIdentity.Load(); certificateIdentity != nil {
		if certificateIdentity.commonName != "" {
			return "x509-cn:" + certificateIdentity.commonName
		}
		if len(certificateIdentity.hashes) > 0 {
			return "x509-sha256:" + hex.EncodeToString(certificateIdentity.hashes[0][:])
		}
	}
	if s.authenticatedUsernameSet {
		return "username:" + s.authenticatedUsername
	}
	return ""
}
