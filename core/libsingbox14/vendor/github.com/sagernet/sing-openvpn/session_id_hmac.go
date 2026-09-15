package openvpn

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"net"

	"github.com/sagernet/sing-openvpn/proto"
)

const (
	defaultHandshakeWindowSeconds = 60
	sessionIDHMACPastBuckets      = 2
	sessionIDHMACFutureBuckets    = 1
)

type sessionIDHMACSigner struct {
	hmacKey    [sha256.Size]byte
	handwindow int64
}

func newSessionIDHMACSigner() (*sessionIDHMACSigner, error) {
	signer := &sessionIDHMACSigner{handwindow: defaultHandshakeWindowSeconds}
	_, err := rand.Read(signer.hmacKey[:])
	if err != nil {
		return nil, err
	}
	return signer, nil
}

func (s *sessionIDHMACSigner) deriveSessionIDAt(clientSessionID proto.SessionID, peerAddress net.Addr, currentTime int64, offset int64) proto.SessionID {
	bucket := uint32(currentTime/((s.handwindow+1)/2)) + uint32(offset)
	mac := hmac.New(sha256.New, s.hmacKey[:])
	var bucketBytes [4]byte
	binary.BigEndian.PutUint32(bucketBytes[:], bucket)
	_, _ = mac.Write(bucketBytes[:])
	_, _ = mac.Write(sessionIDHMACAddress(peerAddress))
	mac.Write(clientSessionID[:])
	digest := mac.Sum(nil)
	var derivedSessionID proto.SessionID
	copy(derivedSessionID[:], digest[:len(derivedSessionID)])
	return derivedSessionID
}

func sessionIDHMACAddress(peerAddress net.Addr) []byte {
	if peerAddress == nil {
		return nil
	}
	udpAddress, isUDP := peerAddress.(*net.UDPAddr)
	if !isUDP {
		network := []byte(peerAddress.Network())
		address := []byte(peerAddress.String())
		encoded := make([]byte, 4+len(network)+len(address))
		binary.BigEndian.PutUint16(encoded[:2], uint16(len(network)))
		copy(encoded[2:], network)
		offset := 2 + len(network)
		binary.BigEndian.PutUint16(encoded[offset:offset+2], uint16(len(address)))
		copy(encoded[offset+2:], address)
		return encoded
	}

	ipAddress := udpAddress.IP
	addressFamily := byte(6)
	if ipv4Address := ipAddress.To4(); ipv4Address != nil {
		addressFamily = 4
		ipAddress = ipv4Address
	} else {
		ipAddress = ipAddress.To16()
	}
	zone := []byte(udpAddress.Zone)
	encoded := make([]byte, 1+len(ipAddress)+2+2+len(zone))
	encoded[0] = addressFamily
	copy(encoded[1:], ipAddress)
	offset := 1 + len(ipAddress)
	binary.BigEndian.PutUint16(encoded[offset:offset+2], uint16(udpAddress.Port))
	offset += 2
	binary.BigEndian.PutUint16(encoded[offset:offset+2], uint16(len(zone)))
	copy(encoded[offset+2:], zone)
	return encoded
}

func (s *sessionIDHMACSigner) validateAt(expectedClientSessionID proto.SessionID, peerAddress net.Addr, serverSessionID proto.SessionID, currentTime int64) bool {
	for offset := int64(-sessionIDHMACPastBuckets); offset <= sessionIDHMACFutureBuckets; offset++ {
		expected := s.deriveSessionIDAt(expectedClientSessionID, peerAddress, currentTime, offset)
		if hmac.Equal(expected[:], serverSessionID[:]) {
			return true
		}
	}
	return false
}
