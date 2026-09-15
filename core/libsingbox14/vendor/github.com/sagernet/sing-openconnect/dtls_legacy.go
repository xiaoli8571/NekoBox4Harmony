package openconnect

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"net"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	anyConnectLegacyVersionMajor          = 0x01
	anyConnectLegacyVersionMinor          = 0x00
	anyConnectLegacyHandshakeHeaderLength = 12
	anyConnectLegacyHandshakeClientHello  = 1
	anyConnectLegacyHandshakeServerHello  = 2
	anyConnectLegacyHandshakeHelloVerify  = 3
	anyConnectLegacyHandshakeFinished     = 20
	anyConnectLegacyHandshakeRetries      = 6
)

type anyConnectLegacyHandshakeMessage struct {
	messageType byte
	sequence    uint16
	body        []byte
}

type anyConnectLegacyServerFlight struct {
	serverRandom     []byte
	serverHelloBody  []byte
	keys             legacyDTLSKeys
	keysReady        bool
	changeCipherSeen bool
	serverFinished   []byte
}

type anyConnectLegacyInitialResponse struct {
	cookie        []byte
	serverRecords []legacyDTLSRecord
}

func isAnyConnectLegacyDTLS(cipherSuite string, dtls12 bool) bool {
	if dtls12 {
		return false
	}
	switch cipherSuite {
	case "DHE-RSA-AES128-SHA", "DHE-RSA-AES256-SHA", "AES128-SHA", "AES256-SHA", "DES-CBC3-SHA", "DES-CBC-SHA":
		return true
	default:
		return false
	}
}

func (c *anyConnectDTLSChannel) connectLegacy(underlying net.Conn) (net.Conn, error) {
	if len(c.negotiation.SessionID) != 32 {
		return nil, E.Extend(ErrProtocolNotSupported, "Cisco DTLS 0.9 requires a 32-byte X-DTLS-Session-ID, got ", len(c.negotiation.SessionID))
	}
	if len(c.negotiation.MasterSecret) != anyConnectLegacyMasterSecretLength {
		return nil, E.Extend(ErrProtocolNotSupported, "Cisco DTLS 0.9 requires a 48-byte master secret, got ", len(c.negotiation.MasterSecret))
	}
	cipherSuite, err := anyConnectLegacyCipherForName(
		c.negotiation.CipherSuite,
		c.negotiation.AllowInsecureCrypto,
	)
	if err != nil {
		return nil, err
	}

	deadline := time.Now().Add(anyConnectDTLSHandshake)
	ctxDeadline, hasDeadline := c.ctx.Deadline()
	if hasDeadline && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	err = underlying.SetDeadline(deadline)
	if err != nil {
		return nil, E.Cause(err, "set Cisco DTLS 0.9 handshake deadline")
	}
	clientRandom := make([]byte, 32)
	binary.BigEndian.PutUint32(clientRandom[:4], uint32(time.Now().Unix()))
	_, err = rand.Read(clientRandom[4:])
	if err != nil {
		return nil, E.Cause(err, "generate Cisco DTLS 0.9 ClientHello random")
	}

	// Upstream bad_dtls_test.c validates the pre-RFC 0x0100 record version, HelloVerify cookie exchange, body-only Finished transcript, and three-byte CCS.
	initialResponse, err := exchangeAnyConnectLegacyInitialResponse(
		c.ctx,
		underlying,
		clientRandom,
		c.negotiation.SessionID,
		cipherSuite,
		deadline,
	)
	if err != nil {
		return nil, err
	}
	recordSequence := uint64(1)
	if len(initialResponse.serverRecords) > 0 {
		recordSequence = 0
	}
	serverHelloSequence := uint16(1)
	if len(initialResponse.serverRecords) > 0 {
		serverHelloSequence = 0
	}
	clientHello, clientHelloBody, err := buildAnyConnectLegacyClientHello(
		clientRandom,
		c.negotiation.SessionID,
		initialResponse.cookie,
		cipherSuite,
		recordSequence,
	)
	if err != nil {
		return nil, err
	}
	serverFlight, nextRecordSequence, err := exchangeAnyConnectLegacyServerFlight(
		c.ctx,
		underlying,
		clientHello,
		clientHelloBody,
		c.negotiation.SessionID,
		c.negotiation.MasterSecret,
		clientRandom,
		cipherSuite,
		deadline,
		initialResponse.serverRecords,
		serverHelloSequence,
	)
	if err != nil {
		return nil, err
	}
	transcript := make([]byte, 0, len(clientHelloBody)+len(serverFlight.serverHelloBody)+12)
	transcript = append(transcript, clientHelloBody...)
	transcript = append(transcript, serverFlight.serverHelloBody...)
	transcript = append(transcript, serverFlight.serverFinished...)
	clientVerifyData, err := anyConnectLegacyFinished(c.negotiation.MasterSecret, "client finished", transcript)
	if err != nil {
		return nil, err
	}
	clientFinished := buildAnyConnectLegacyHandshakeMessage(
		anyConnectLegacyHandshakeFinished,
		serverHelloSequence+2,
		clientVerifyData,
	)
	changeCipherRecord, err := marshalLegacyDTLSRecord(legacyDTLSRecord{
		contentType: legacyDTLSContentCCS,
		epoch:       0,
		sequence:    nextRecordSequence,
		payload: []byte{
			1,
			byte((serverHelloSequence + 1) >> 8),
			byte(serverHelloSequence + 1),
		},
	}, cipherSuite.suite())
	if err != nil {
		return nil, err
	}
	finishedRecord, err := encryptLegacyDTLSRecord(legacyDTLSRecord{
		contentType: legacyDTLSContentHandshake,
		epoch:       1,
		sequence:    0,
		payload:     clientFinished,
	}, serverFlight.keys.clientKey, serverFlight.keys.clientMACKey, cipherSuite.suite())
	if err != nil {
		return nil, err
	}
	// Upstream sends CCS and the encrypted Finished as records of a single datagram.
	finalFlight := append(changeCipherRecord, finishedRecord...)
	err = writeLegacyDTLSDatagram(underlying, finalFlight)
	if err != nil {
		return nil, E.Cause(err, "send Cisco DTLS 0.9 final handshake flight")
	}
	err = underlying.SetDeadline(time.Time{})
	if err != nil {
		return nil, E.Cause(err, "clear Cisco DTLS 0.9 handshake deadline")
	}
	return &legacyDTLSConn{
		suite:         cipherSuite.suite(),
		underlying:    underlying,
		keys:          serverFlight.keys,
		strict:        true,
		writeSequence: 1,
		finalFlight:   [][]byte{finalFlight},
		serverFinished: buildAnyConnectLegacyHandshakeMessage(
			anyConnectLegacyHandshakeFinished,
			serverHelloSequence+2,
			serverFlight.serverFinished,
		),
	}, nil
}

func exchangeAnyConnectLegacyInitialResponse(
	ctx context.Context,
	conn net.Conn,
	clientRandom []byte,
	sessionID []byte,
	cipherSuite anyConnectLegacyCipher,
	deadline time.Time,
) (anyConnectLegacyInitialResponse, error) {
	clientHello, _, err := buildAnyConnectLegacyClientHello(clientRandom, sessionID, nil, cipherSuite, 0)
	if err != nil {
		return anyConnectLegacyInitialResponse{}, err
	}
	retryInterval := 250 * time.Millisecond
	for range anyConnectLegacyHandshakeRetries {
		err = writeLegacyDTLSDatagram(conn, clientHello)
		if err != nil {
			return anyConnectLegacyInitialResponse{}, E.Cause(err, "send initial Cisco DTLS 0.9 ClientHello")
		}
		attemptDeadline := time.Now().Add(retryInterval)
		if attemptDeadline.After(deadline) {
			attemptDeadline = deadline
		}
		err = conn.SetReadDeadline(attemptDeadline)
		if err != nil {
			return anyConnectLegacyInitialResponse{}, E.Cause(err, "set Cisco DTLS 0.9 initial-response deadline")
		}
		datagram := make([]byte, 64*1024)
		n, readErr := conn.Read(datagram)
		if readErr != nil {
			if ctx.Err() != nil {
				return anyConnectLegacyInitialResponse{}, E.Cause(ctx.Err(), "wait for Cisco DTLS 0.9 initial response")
			}
			if timeoutErr, timeout := readErr.(net.Error); timeout && timeoutErr.Timeout() {
				retryInterval *= 2
				continue
			}
			return anyConnectLegacyInitialResponse{}, E.Cause(readErr, "read Cisco DTLS 0.9 initial response")
		}
		records, parseErr := parseLegacyDTLSRecords(datagram[:n], cipherSuite.suite())
		if parseErr != nil {
			return anyConnectLegacyInitialResponse{}, parseErr
		}
		for _, record := range records {
			if record.contentType != legacyDTLSContentHandshake || record.epoch != 0 {
				continue
			}
			message, messageErr := parseAnyConnectLegacyHandshakeMessage(record.payload)
			if messageErr != nil {
				return anyConnectLegacyInitialResponse{}, messageErr
			}
			switch message.messageType {
			case anyConnectLegacyHandshakeHelloVerify:
				if message.sequence != 0 {
					return anyConnectLegacyInitialResponse{}, E.New("Cisco DTLS 0.9 HelloVerify has unexpected handshake sequence: ", message.sequence)
				}
				cookie, cookieErr := parseAnyConnectLegacyHelloVerify(message.body)
				if cookieErr != nil {
					return anyConnectLegacyInitialResponse{}, cookieErr
				}
				return anyConnectLegacyInitialResponse{cookie: cookie}, nil
			case anyConnectLegacyHandshakeServerHello:
				return anyConnectLegacyInitialResponse{serverRecords: records}, nil
			}
		}
	}
	return anyConnectLegacyInitialResponse{}, E.New("Cisco DTLS 0.9 peer did not answer the ClientHello")
}

func exchangeAnyConnectLegacyServerFlight(
	ctx context.Context,
	conn net.Conn,
	clientHello []byte,
	clientHelloBody []byte,
	sessionID []byte,
	masterSecret []byte,
	clientRandom []byte,
	cipherSuite anyConnectLegacyCipher,
	deadline time.Time,
	initialRecords []legacyDTLSRecord,
	serverHelloSequence uint16,
) (anyConnectLegacyServerFlight, uint64, error) {
	nextRecordSequence := uint64(1)
	flight := anyConnectLegacyServerFlight{}
	if len(initialRecords) > 0 {
		complete, err := processAnyConnectLegacyServerRecords(
			initialRecords,
			&flight,
			clientHelloBody,
			sessionID,
			masterSecret,
			clientRandom,
			cipherSuite,
			serverHelloSequence,
		)
		if err != nil {
			return anyConnectLegacyServerFlight{}, 0, err
		}
		if complete {
			return flight, nextRecordSequence, nil
		}
	}
	retryInterval := 250 * time.Millisecond
	var err error
	for attempt := range anyConnectLegacyHandshakeRetries {
		if attempt > 0 || len(initialRecords) == 0 {
			encodedClientHello := append([]byte(nil), clientHello...)
			putUint48(encodedClientHello[5:11], nextRecordSequence)
			nextRecordSequence++
			err = writeLegacyDTLSDatagram(conn, encodedClientHello)
			if err != nil {
				return anyConnectLegacyServerFlight{}, 0, E.Cause(err, "send Cisco DTLS 0.9 ClientHello")
			}
		}
		attemptDeadline := time.Now().Add(retryInterval)
		if attemptDeadline.After(deadline) {
			attemptDeadline = deadline
		}
		err = conn.SetReadDeadline(attemptDeadline)
		if err != nil {
			return anyConnectLegacyServerFlight{}, 0, E.Cause(err, "set Cisco DTLS 0.9 server-flight deadline")
		}
		for {
			datagram := make([]byte, 64*1024)
			n, readErr := conn.Read(datagram)
			if readErr != nil {
				if ctx.Err() != nil {
					return anyConnectLegacyServerFlight{}, 0, E.Cause(ctx.Err(), "wait for Cisco DTLS 0.9 server flight")
				}
				if timeoutErr, timeout := readErr.(net.Error); timeout && timeoutErr.Timeout() {
					break
				}
				return anyConnectLegacyServerFlight{}, 0, E.Cause(readErr, "read Cisco DTLS 0.9 server flight")
			}
			records, parseErr := parseLegacyDTLSRecords(datagram[:n], cipherSuite.suite())
			if parseErr != nil {
				return anyConnectLegacyServerFlight{}, 0, parseErr
			}
			complete, processErr := processAnyConnectLegacyServerRecords(
				records,
				&flight,
				clientHelloBody,
				sessionID,
				masterSecret,
				clientRandom,
				cipherSuite,
				serverHelloSequence,
			)
			if processErr != nil {
				return anyConnectLegacyServerFlight{}, 0, processErr
			}
			if complete {
				return flight, nextRecordSequence, nil
			}
		}
		retryInterval *= 2
	}
	return anyConnectLegacyServerFlight{}, 0, E.New("Cisco DTLS 0.9 abbreviated handshake did not complete")
}

func processAnyConnectLegacyServerRecords(
	records []legacyDTLSRecord,
	flight *anyConnectLegacyServerFlight,
	clientHelloBody []byte,
	sessionID []byte,
	masterSecret []byte,
	clientRandom []byte,
	cipherSuite anyConnectLegacyCipher,
	serverHelloSequence uint16,
) (bool, error) {
	for _, record := range records {
		switch record.contentType {
		case legacyDTLSContentHandshake:
			if record.epoch == 0 {
				message, err := parseAnyConnectLegacyHandshakeMessage(record.payload)
				if err != nil {
					return false, err
				}
				if message.messageType == anyConnectLegacyHandshakeHelloVerify {
					continue
				}
				if message.messageType != anyConnectLegacyHandshakeServerHello {
					return false, E.New("unexpected Cisco DTLS 0.9 handshake message: ", message.messageType)
				}
				if message.sequence != serverHelloSequence {
					return false, E.New("Cisco DTLS 0.9 ServerHello has unexpected handshake sequence: ", message.sequence)
				}
				serverRandom, err := parseAnyConnectLegacyServerHello(message.body, sessionID, cipherSuite.id)
				if err != nil {
					return false, err
				}
				flight.serverRandom = serverRandom
				flight.serverHelloBody = message.body
				flight.keys, err = deriveLegacyDTLSKeys(cipherSuite.suite(), cipherSuite.keyLength, masterSecret, clientRandom, serverRandom)
				if err != nil {
					return false, err
				}
				flight.keysReady = true
			} else if record.epoch == 1 {
				if !flight.keysReady {
					return false, E.New("Cisco DTLS 0.9 sent encrypted Finished before ServerHello")
				}
				plaintext, err := decryptLegacyDTLSRecord(record, flight.keys.serverKey, flight.keys.serverMACKey, cipherSuite.suite())
				if err != nil {
					return false, E.Cause(err, "decrypt Cisco DTLS 0.9 server Finished")
				}
				message, err := parseAnyConnectLegacyHandshakeMessage(plaintext)
				if err != nil {
					return false, err
				}
				if message.messageType != anyConnectLegacyHandshakeFinished || len(message.body) != 12 {
					return false, E.New("invalid Cisco DTLS 0.9 server Finished")
				}
				if message.sequence != serverHelloSequence+2 {
					return false, E.New("Cisco DTLS 0.9 server Finished has unexpected handshake sequence: ", message.sequence)
				}
				transcript := append(append([]byte(nil), clientHelloBody...), flight.serverHelloBody...)
				expected, err := anyConnectLegacyFinished(masterSecret, "server finished", transcript)
				if err != nil {
					return false, err
				}
				if !equalBytes(message.body, expected) {
					return false, E.New("Cisco DTLS 0.9 server Finished verification failed")
				}
				flight.serverFinished = append([]byte(nil), message.body...)
			}
		case legacyDTLSContentCCS:
			expectedChangeCipher := []byte{
				1,
				byte((serverHelloSequence + 1) >> 8),
				byte(serverHelloSequence + 1),
			}
			if record.epoch != 0 || !equalBytes(record.payload, expectedChangeCipher) {
				return false, E.New("invalid Cisco DTLS 0.9 ChangeCipherSpec")
			}
			flight.changeCipherSeen = true
		case legacyDTLSContentAlert:
			return false, E.New("Cisco DTLS 0.9 peer sent an alert during handshake")
		default:
			return false, E.New("unexpected Cisco DTLS 0.9 server-flight record: ", record.contentType)
		}
	}
	return flight.keysReady && flight.changeCipherSeen && len(flight.serverFinished) == 12, nil
}

func buildAnyConnectLegacyClientHello(
	clientRandom []byte,
	sessionID []byte,
	cookie []byte,
	cipherSuite anyConnectLegacyCipher,
	recordSequence uint64,
) ([]byte, []byte, error) {
	if len(clientRandom) != 32 || len(sessionID) > 255 || len(cookie) > 255 {
		return nil, nil, E.New("invalid Cisco DTLS 0.9 ClientHello parameters")
	}
	body := make([]byte, 0, 75+len(cookie))
	body = append(body, anyConnectLegacyVersionMajor, anyConnectLegacyVersionMinor)
	body = append(body, clientRandom...)
	body = append(body, byte(len(sessionID)))
	body = append(body, sessionID...)
	body = append(body, byte(len(cookie)))
	body = append(body, cookie...)
	body = append(body, 0, 2, byte(cipherSuite.id>>8), byte(cipherSuite.id))
	body = append(body, 1, 0)
	body = append(body, 0, 0)
	handshakeMessage := buildAnyConnectLegacyHandshakeMessage(anyConnectLegacyHandshakeClientHello, 0, body)
	record, err := marshalLegacyDTLSRecord(legacyDTLSRecord{
		contentType: legacyDTLSContentHandshake,
		epoch:       0,
		sequence:    recordSequence,
		payload:     handshakeMessage,
	}, cipherSuite.suite())
	if err != nil {
		return nil, nil, err
	}
	return record, body, nil
}

func parseAnyConnectLegacyHelloVerify(body []byte) ([]byte, error) {
	if len(body) < 3 || body[0] != anyConnectLegacyVersionMajor || body[1] != anyConnectLegacyVersionMinor {
		return nil, E.New("invalid Cisco DTLS 0.9 HelloVerify version")
	}
	cookieLength := int(body[2])
	if len(body) != 3+cookieLength || cookieLength == 0 {
		return nil, E.New("invalid Cisco DTLS 0.9 HelloVerify cookie")
	}
	return append([]byte(nil), body[3:]...), nil
}

func parseAnyConnectLegacyServerHello(body []byte, sessionID []byte, cipherSuite uint16) ([]byte, error) {
	if len(body) < 38 || body[0] != anyConnectLegacyVersionMajor || body[1] != anyConnectLegacyVersionMinor {
		return nil, E.New("invalid Cisco DTLS 0.9 ServerHello version")
	}
	serverRandom := append([]byte(nil), body[2:34]...)
	sessionLength := int(body[34])
	position := 35
	if len(body) < position+sessionLength+3 || !equalBytes(body[position:position+sessionLength], sessionID) {
		return nil, E.New("Cisco DTLS 0.9 server did not accept the injected Session-ID")
	}
	position += sessionLength
	selectedCipher := binary.BigEndian.Uint16(body[position : position+2])
	position += 2
	if selectedCipher != cipherSuite {
		return nil, E.New("Cisco DTLS 0.9 server selected unexpected cipher: ", selectedCipher)
	}
	if body[position] != 0 {
		return nil, E.New("Cisco DTLS 0.9 server selected unsupported compression: ", body[position])
	}
	position++
	if position < len(body) {
		if len(body)-position < 2 {
			return nil, E.New("truncated Cisco DTLS 0.9 ServerHello extensions")
		}
		extensionsLength := int(binary.BigEndian.Uint16(body[position : position+2]))
		if len(body) != position+2+extensionsLength {
			return nil, E.New("invalid Cisco DTLS 0.9 ServerHello extensions")
		}
	}
	return serverRandom, nil
}

func buildAnyConnectLegacyHandshakeMessage(messageType byte, sequence uint16, body []byte) []byte {
	message := make([]byte, anyConnectLegacyHandshakeHeaderLength+len(body))
	message[0] = messageType
	putUint24(message[1:4], len(body))
	binary.BigEndian.PutUint16(message[4:6], sequence)
	putUint24(message[6:9], 0)
	putUint24(message[9:12], len(body))
	copy(message[12:], body)
	return message
}

func parseAnyConnectLegacyHandshakeMessage(payload []byte) (anyConnectLegacyHandshakeMessage, error) {
	if len(payload) < anyConnectLegacyHandshakeHeaderLength {
		return anyConnectLegacyHandshakeMessage{}, E.New("short Cisco DTLS 0.9 handshake header")
	}
	bodyLength := readUint24(payload[1:4])
	fragmentOffset := readUint24(payload[6:9])
	fragmentLength := readUint24(payload[9:12])
	if fragmentOffset != 0 || fragmentLength != bodyLength || len(payload) != anyConnectLegacyHandshakeHeaderLength+bodyLength {
		return anyConnectLegacyHandshakeMessage{}, E.New("fragmented or truncated Cisco DTLS 0.9 handshake message")
	}
	return anyConnectLegacyHandshakeMessage{
		messageType: payload[0],
		sequence:    binary.BigEndian.Uint16(payload[4:6]),
		body:        append([]byte(nil), payload[12:]...),
	}, nil
}

func putUint24(destination []byte, value int) {
	destination[0] = byte(value >> 16)
	destination[1] = byte(value >> 8)
	destination[2] = byte(value)
}

func readUint24(source []byte) int {
	return int(source[0])<<16 | int(source[1])<<8 | int(source[2])
}
