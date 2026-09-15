package openconnect

import (
	"crypto/tls"
	"encoding/binary"
	"net"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	certificateDTLSHandshakeHeaderLength    = 12
	certificateDTLSHandshakeClientHello     = 1
	certificateDTLSHandshakeServerHello     = 2
	certificateDTLSHandshakeHelloVerify     = 3
	certificateDTLSHandshakeCertificate     = 11
	certificateDTLSHandshakeServerKey       = 12
	certificateDTLSHandshakeCertRequest     = 13
	certificateDTLSHandshakeServerHelloDone = 14
	certificateDTLSHandshakeCertVerify      = 15
	certificateDTLSHandshakeClientKey       = 16
	certificateDTLSHandshakeFinished        = 20
	certificateDTLSMaximumHandshakeMessages = 64
	certificateDTLSMaximumReassemblyBytes   = 32 * 1024 * 1024
)

type certificateDTLSHandshakeMessage struct {
	messageType byte
	sequence    uint16
	body        []byte
}

type certificateDTLSHandshakeFragment struct {
	messageType byte
	totalLength int
	body        []byte
	received    []bool
	complete    bool
}

type certificateDTLSHandshakeReassembler struct {
	fragments map[uint16]*certificateDTLSHandshakeFragment
	messages  map[uint16]certificateDTLSHandshakeMessage
	bytes     int
}

func buildCertificateDTLSClientHello(
	clientRandom []byte,
	cookie []byte,
	cipherSuites []certificateDTLS10Cipher,
	curves []uint16,
	serverName string,
	sequence uint16,
) ([]byte, error) {
	if len(clientRandom) != 32 || len(cookie) > 255 {
		return nil, E.New("invalid certificate DTLS 1.0 ClientHello parameters")
	}
	body := make([]byte, 0, 128+len(cookie)+len(serverName))
	body = append(body, byte(certificateDTLSVersion10>>8), byte(certificateDTLSVersion10&0xff))
	body = append(body, clientRandom...)
	body = append(body, 0)
	body = append(body, byte(len(cookie)))
	body = append(body, cookie...)
	body = append(body, byte(len(cipherSuites)*2>>8), byte(len(cipherSuites)*2))
	for _, cipherSuite := range cipherSuites {
		body = append(body, byte(cipherSuite.id>>8), byte(cipherSuite.id))
	}
	body = append(body, 1, 0)
	extensions := buildCertificateDTLSClientExtensions(serverName, curves)
	body = append(body, byte(len(extensions)>>8), byte(len(extensions)))
	body = append(body, extensions...)
	return marshalCertificateDTLSHandshake(certificateDTLSHandshakeClientHello, sequence, body), nil
}

func buildCertificateDTLSClientExtensions(serverName string, curves []uint16) []byte {
	extensions := make([]byte, 0, 64+len(serverName))
	if serverName != "" && net.ParseIP(serverName) == nil {
		serverNameBytes := []byte(serverName)
		dataLength := 5 + len(serverNameBytes)
		extensions = append(extensions, 0, 0, byte(dataLength>>8), byte(dataLength))
		extensions = append(extensions, byte((len(serverNameBytes)+3)>>8), byte(len(serverNameBytes)+3), 0)
		extensions = append(extensions, byte(len(serverNameBytes)>>8), byte(len(serverNameBytes)))
		extensions = append(extensions, serverNameBytes...)
	}
	curveDataLength := 2 + len(curves)*2
	extensions = append(extensions, 0, 10, byte(curveDataLength>>8), byte(curveDataLength))
	extensions = append(extensions, byte(len(curves)*2>>8), byte(len(curves)*2))
	for _, curve := range curves {
		extensions = append(extensions, byte(curve>>8), byte(curve))
	}
	extensions = append(extensions, 0, 11, 0, 2, 1, 0)
	extensions = append(extensions, 0xff, 0x01, 0, 1, 0)
	return extensions
}

func parseCertificateDTLSHelloVerify(body []byte) ([]byte, error) {
	if len(body) < 3 || binary.BigEndian.Uint16(body[:2]) != certificateDTLSVersion10 {
		return nil, E.New("invalid certificate DTLS 1.0 HelloVerify version")
	}
	cookieLength := int(body[2])
	if cookieLength == 0 || len(body) != 3+cookieLength {
		return nil, E.New("invalid certificate DTLS 1.0 HelloVerify cookie")
	}
	return append([]byte(nil), body[3:]...), nil
}

func parseCertificateDTLSServerHello(
	body []byte,
	offeredCipherSuites []certificateDTLS10Cipher,
) ([]byte, certificateDTLS10Cipher, error) {
	if len(body) < 38 || binary.BigEndian.Uint16(body[:2]) != certificateDTLSVersion10 {
		return nil, certificateDTLS10Cipher{}, E.New("invalid certificate DTLS 1.0 ServerHello")
	}
	serverRandom := append([]byte(nil), body[2:34]...)
	sessionLength := int(body[34])
	position := 35 + sessionLength
	if len(body) < position+3 {
		return nil, certificateDTLS10Cipher{}, E.New("truncated certificate DTLS 1.0 ServerHello")
	}
	selectedCipher := binary.BigEndian.Uint16(body[position : position+2])
	position += 2
	var cipherSuite certificateDTLS10Cipher
	found := false
	for _, offeredCipher := range offeredCipherSuites {
		if offeredCipher.id == selectedCipher {
			cipherSuite = offeredCipher
			found = true
			break
		}
	}
	if !found {
		return nil, certificateDTLS10Cipher{}, E.New("certificate DTLS 1.0 server selected unoffered cipher: ", selectedCipher)
	}
	if body[position] != 0 {
		return nil, certificateDTLS10Cipher{}, E.New("certificate DTLS 1.0 server selected unsupported compression: ", body[position])
	}
	position++
	if position < len(body) {
		if len(body)-position < 2 {
			return nil, certificateDTLS10Cipher{}, E.New("truncated certificate DTLS 1.0 ServerHello extensions")
		}
		extensionsLength := int(binary.BigEndian.Uint16(body[position : position+2]))
		if len(body) != position+2+extensionsLength {
			return nil, certificateDTLS10Cipher{}, E.New("invalid certificate DTLS 1.0 ServerHello extensions")
		}
	}
	return serverRandom, cipherSuite, nil
}

func parseCertificateDTLSCertificate(body []byte) ([][]byte, error) {
	if len(body) < 3 {
		return nil, E.New("short certificate DTLS 1.0 Certificate message")
	}
	totalLength := readUint24(body[:3])
	if totalLength == 0 || len(body) != 3+totalLength {
		return nil, E.New("invalid certificate DTLS 1.0 certificate chain length")
	}
	position := 3
	var rawCertificates [][]byte
	for position < len(body) {
		if len(body)-position < 3 {
			return nil, E.New("truncated certificate DTLS 1.0 certificate length")
		}
		certificateLength := readUint24(body[position : position+3])
		position += 3
		if certificateLength == 0 || len(body)-position < certificateLength {
			return nil, E.New("truncated certificate DTLS 1.0 certificate")
		}
		rawCertificates = append(rawCertificates, append([]byte(nil), body[position:position+certificateLength]...))
		position += certificateLength
	}
	return rawCertificates, nil
}

type certificateDTLSCertificateRequest struct {
	certificateTypes []byte
	acceptableCAs    [][]byte
}

func parseCertificateDTLSCertificateRequest(body []byte) (certificateDTLSCertificateRequest, error) {
	if len(body) < 1 {
		return certificateDTLSCertificateRequest{}, E.New("short certificate DTLS 1.0 CertificateRequest")
	}
	certificateTypesLength := int(body[0])
	position := 1 + certificateTypesLength
	if len(body) < position+2 {
		return certificateDTLSCertificateRequest{}, E.New("truncated certificate DTLS 1.0 CertificateRequest types")
	}
	request := certificateDTLSCertificateRequest{
		certificateTypes: append([]byte(nil), body[1:position]...),
	}
	authoritiesLength := int(binary.BigEndian.Uint16(body[position : position+2]))
	position += 2
	if len(body)-position != authoritiesLength {
		return certificateDTLSCertificateRequest{}, E.New("invalid certificate DTLS 1.0 CertificateRequest authority length")
	}
	for position < len(body) {
		if len(body)-position < 2 {
			return certificateDTLSCertificateRequest{}, E.New("truncated certificate DTLS 1.0 CertificateRequest authority")
		}
		authorityLength := int(binary.BigEndian.Uint16(body[position : position+2]))
		position += 2
		if authorityLength == 0 || len(body)-position < authorityLength {
			return certificateDTLSCertificateRequest{}, E.New("invalid certificate DTLS 1.0 CertificateRequest authority")
		}
		request.acceptableCAs = append(request.acceptableCAs, append([]byte(nil), body[position:position+authorityLength]...))
		position += authorityLength
	}
	return request, nil
}

func marshalCertificateDTLSCertificate(certificate *tls.Certificate) []byte {
	if certificate == nil || len(certificate.Certificate) == 0 {
		return []byte{0, 0, 0}
	}
	totalLength := 0
	for _, rawCertificate := range certificate.Certificate {
		totalLength += 3 + len(rawCertificate)
	}
	body := make([]byte, 3, 3+totalLength)
	putUint24(body[:3], totalLength)
	for _, rawCertificate := range certificate.Certificate {
		length := []byte{0, 0, 0}
		putUint24(length, len(rawCertificate))
		body = append(body, length...)
		body = append(body, rawCertificate...)
	}
	return body
}

func (h *certificateDTLS10Handshake) writeUnencryptedHandshake(message []byte) error {
	records, err := h.marshalUnencryptedHandshakeRecords(message)
	if err != nil {
		return err
	}
	err = writeLegacyDTLSFlight(h.conn, records)
	for _, record := range records {
		clear(record)
	}
	return err
}

func (h *certificateDTLS10Handshake) marshalUnencryptedHandshakeRecords(message []byte) ([][]byte, error) {
	if len(message) < certificateDTLSHandshakeHeaderLength {
		return nil, E.New("short outbound certificate DTLS 1.0 handshake message")
	}
	totalLength := readUint24(message[1:4])
	if len(message) != certificateDTLSHandshakeHeaderLength+totalLength {
		return nil, E.New("invalid outbound certificate DTLS 1.0 handshake message length")
	}
	maximumFragmentLength := totalLength
	if h.mtu > 0 {
		maximumFragmentLength = h.mtu - legacyDTLSRecordHeaderLength - certificateDTLSHandshakeHeaderLength
		if maximumFragmentLength <= 0 {
			return nil, E.New("certificate DTLS 1.0 MTU cannot carry a handshake fragment")
		}
	}
	if totalLength == 0 {
		maximumFragmentLength = 0
	}
	var records [][]byte
	completed := false
	defer func() {
		if !completed {
			for _, record := range records {
				clear(record)
			}
		}
	}()
	for fragmentOffset := 0; fragmentOffset < totalLength || fragmentOffset == 0; {
		fragmentLength := maximumFragmentLength
		if remaining := totalLength - fragmentOffset; fragmentLength > remaining {
			fragmentLength = remaining
		}
		fragment := make([]byte, certificateDTLSHandshakeHeaderLength+fragmentLength)
		fragment[0] = message[0]
		copy(fragment[1:6], message[1:6])
		putUint24(fragment[6:9], fragmentOffset)
		putUint24(fragment[9:12], fragmentLength)
		copy(fragment[12:], message[certificateDTLSHandshakeHeaderLength+fragmentOffset:certificateDTLSHandshakeHeaderLength+fragmentOffset+fragmentLength])
		record, err := h.marshalUnencryptedRecord(fragment, legacyDTLSContentHandshake)
		clear(fragment)
		if err != nil {
			return nil, err
		}
		if h.mtu > 0 && len(record) > h.mtu {
			clear(record)
			return nil, E.New("certificate DTLS 1.0 handshake record exceeds negotiated MTU")
		}
		records = append(records, record)
		fragmentOffset += fragmentLength
		if totalLength == 0 {
			break
		}
	}
	completed = true
	return records, nil
}

func (h *certificateDTLS10Handshake) marshalUnencryptedRecord(payload []byte, contentType byte) ([]byte, error) {
	if h.clientRecordSequence > legacyDTLSMaxSequence {
		return nil, E.New("certificate DTLS 1.0 handshake record sequence exhausted")
	}
	record, err := marshalLegacyDTLSRecord(legacyDTLSRecord{
		contentType: contentType,
		epoch:       0,
		sequence:    h.clientRecordSequence,
		payload:     payload,
	}, h.suite)
	if err != nil {
		return nil, err
	}
	h.clientRecordSequence++
	return record, nil
}

func (h *certificateDTLS10Handshake) readUnencryptedHandshakeDatagram() error {
	datagram := make([]byte, 64*1024)
	defer clear(datagram)
	n, err := h.conn.Read(datagram)
	if err != nil {
		return err
	}
	records, err := parseLegacyDTLSRecords(datagram[:n], h.suite)
	if err != nil {
		return err
	}
	for _, record := range records {
		if record.epoch != 0 {
			continue
		}
		switch record.contentType {
		case legacyDTLSContentHandshake:
			err = h.reassembler.add(record.payload)
			if err != nil {
				return err
			}
		case legacyDTLSContentAlert:
			alertDescription := -1
			if len(record.payload) == 2 {
				alertDescription = int(record.payload[1])
			}
			return E.New("certificate DTLS 1.0 peer sent handshake alert: ", alertDescription)
		case legacyDTLSContentCCS:
			return E.New("certificate DTLS 1.0 peer sent early ChangeCipherSpec")
		}
	}
	return nil
}

func newCertificateDTLSHandshakeReassembler() *certificateDTLSHandshakeReassembler {
	return &certificateDTLSHandshakeReassembler{
		fragments: make(map[uint16]*certificateDTLSHandshakeFragment),
		messages:  make(map[uint16]certificateDTLSHandshakeMessage),
	}
}

func (r *certificateDTLSHandshakeReassembler) take(sequence uint16) (certificateDTLSHandshakeMessage, bool) {
	message, loaded := r.messages[sequence]
	if !loaded {
		return certificateDTLSHandshakeMessage{}, false
	}
	delete(r.messages, sequence)
	r.bytes -= len(message.body)
	return message, true
}

func (r *certificateDTLSHandshakeReassembler) destroy() {
	for _, fragment := range r.fragments {
		clear(fragment.body)
		fragment.body = nil
		fragment.received = nil
	}
	for sequence, message := range r.messages {
		clear(message.body)
		delete(r.messages, sequence)
	}
	r.fragments = nil
	r.messages = nil
	r.bytes = 0
}

func (r *certificateDTLSHandshakeReassembler) add(payload []byte) error {
	for len(payload) > 0 {
		if len(payload) < certificateDTLSHandshakeHeaderLength {
			return E.New("short certificate DTLS 1.0 handshake fragment header")
		}
		messageType := payload[0]
		totalLength := readUint24(payload[1:4])
		sequence := binary.BigEndian.Uint16(payload[4:6])
		fragmentOffset := readUint24(payload[6:9])
		fragmentLength := readUint24(payload[9:12])
		if totalLength > 16*1024*1024 || fragmentOffset > totalLength || fragmentLength > totalLength-fragmentOffset ||
			len(payload) < certificateDTLSHandshakeHeaderLength+fragmentLength {
			return E.New("invalid certificate DTLS 1.0 handshake fragment")
		}
		completedMessage, completed := r.messages[sequence]
		if completed {
			if completedMessage.messageType != messageType || len(completedMessage.body) != totalLength ||
				!equalBytes(completedMessage.body[fragmentOffset:fragmentOffset+fragmentLength], payload[certificateDTLSHandshakeHeaderLength:certificateDTLSHandshakeHeaderLength+fragmentLength]) {
				return E.New("conflicting completed certificate DTLS 1.0 handshake fragment")
			}
			payload = payload[certificateDTLSHandshakeHeaderLength+fragmentLength:]
			continue
		}
		fragment := r.fragments[sequence]
		if fragment == nil {
			if len(r.fragments)+len(r.messages) >= certificateDTLSMaximumHandshakeMessages {
				return E.New("certificate DTLS 1.0 handshake has too many messages")
			}
			allocationBytes := totalLength * 2
			if allocationBytes > certificateDTLSMaximumReassemblyBytes-r.bytes {
				return E.New("certificate DTLS 1.0 handshake reassembly exceeds memory limit")
			}
			fragment = &certificateDTLSHandshakeFragment{
				messageType: messageType,
				totalLength: totalLength,
				body:        make([]byte, totalLength),
				received:    make([]bool, totalLength),
			}
			r.fragments[sequence] = fragment
			r.bytes += allocationBytes
		}
		if fragment.messageType != messageType || fragment.totalLength != totalLength {
			return E.New("conflicting certificate DTLS 1.0 handshake fragments")
		}
		fragmentBody := payload[certificateDTLSHandshakeHeaderLength : certificateDTLSHandshakeHeaderLength+fragmentLength]
		for i, value := range fragmentBody {
			position := fragmentOffset + i
			if fragment.received[position] && fragment.body[position] != value {
				return E.New("overlapping certificate DTLS 1.0 handshake fragments differ")
			}
			fragment.body[position] = value
			fragment.received[position] = true
		}
		if !fragment.complete {
			fragment.complete = true
			for _, received := range fragment.received {
				if !received {
					fragment.complete = false
					break
				}
			}
			if fragment.complete {
				r.messages[sequence] = certificateDTLSHandshakeMessage{
					messageType: messageType,
					sequence:    sequence,
					body:        fragment.body,
				}
				fragment.body = nil
				fragment.received = nil
				delete(r.fragments, sequence)
				r.bytes -= totalLength
			}
		}
		payload = payload[certificateDTLSHandshakeHeaderLength+fragmentLength:]
	}
	return nil
}

func marshalCertificateDTLSHandshake(messageType byte, sequence uint16, body []byte) []byte {
	message := make([]byte, certificateDTLSHandshakeHeaderLength+len(body))
	message[0] = messageType
	putUint24(message[1:4], len(body))
	binary.BigEndian.PutUint16(message[4:6], sequence)
	putUint24(message[6:9], 0)
	putUint24(message[9:12], len(body))
	copy(message[12:], body)
	return message
}

func parseCompleteCertificateDTLSHandshake(payload []byte) (certificateDTLSHandshakeMessage, error) {
	if len(payload) < certificateDTLSHandshakeHeaderLength {
		return certificateDTLSHandshakeMessage{}, E.New("short certificate DTLS 1.0 handshake message")
	}
	totalLength := readUint24(payload[1:4])
	fragmentOffset := readUint24(payload[6:9])
	fragmentLength := readUint24(payload[9:12])
	if fragmentOffset != 0 || fragmentLength != totalLength || len(payload) != certificateDTLSHandshakeHeaderLength+totalLength {
		return certificateDTLSHandshakeMessage{}, E.New("fragmented certificate DTLS 1.0 encrypted handshake message")
	}
	return certificateDTLSHandshakeMessage{
		messageType: payload[0],
		sequence:    binary.BigEndian.Uint16(payload[4:6]),
		body:        append([]byte(nil), payload[12:]...),
	}, nil
}
