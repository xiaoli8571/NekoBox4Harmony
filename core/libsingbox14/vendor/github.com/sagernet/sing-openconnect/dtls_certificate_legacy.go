package openconnect

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"net"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const certificateDTLSHandshakeRetries = 7

type certificateDTLS10ServerFlight struct {
	serverRandom         []byte
	cipherSuite          certificateDTLS10Cipher
	peerCertificates     []*x509.Certificate
	verifiedChains       [][]*x509.Certificate
	serverKeyExchange    []byte
	certificateRequested bool
	certificateTypes     []byte
	acceptableCAs        [][]byte
	complete             bool
}

type certificateDTLS10Handshake struct {
	ctx                     context.Context
	conn                    net.Conn
	suite                   legacyDTLSSuite
	tlsConfig               *tls.Config
	serverName              string
	mtu                     int
	deadline                time.Time
	clientRandom            []byte
	clientRecordSequence    uint64
	clientHandshakeSequence uint16
	serverHandshakeSequence uint16
	transcript              []byte
	reassembler             *certificateDTLSHandshakeReassembler
	flight                  certificateDTLS10ServerFlight
	clientCertificate       *tls.Certificate
	offeredCurves           []uint16
}

func connectCertificateDTLS10(
	ctx context.Context,
	udpConn net.Conn,
	negotiation certificateDTLSNegotiation,
) (net.Conn, uint16, error) {
	tlsConfig := &tls.Config{}
	if negotiation.TLSConfig != nil {
		tlsConfig = cloneTLSConfig(negotiation.TLSConfig)
	}
	if tlsConfig.MinVersion > tls.VersionTLS11 || tlsConfig.MaxVersion != 0 && tlsConfig.MaxVersion < tls.VersionTLS11 {
		return nil, 0, E.Extend(ErrProtocolNotSupported, "TLS version policy excludes F5 DTLS 1.0")
	}
	serverName := tlsConfig.ServerName
	if serverName == "" {
		serverName = negotiation.ServerName
	}
	deadline := time.Now().Add(certificateDTLSHandshakeTimeout)
	ctxDeadline, hasDeadline := ctx.Deadline()
	if hasDeadline && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	clientRandom := make([]byte, 32)
	binary.BigEndian.PutUint32(clientRandom[:4], uint32(time.Now().Unix()))
	_, err := rand.Read(clientRandom[4:])
	if err != nil {
		return nil, 0, E.Cause(err, "generate certificate DTLS 1.0 ClientHello random")
	}
	handshake := &certificateDTLS10Handshake{
		ctx:          ctx,
		conn:         udpConn,
		suite:        certificateDTLS10Suite(),
		tlsConfig:    tlsConfig,
		serverName:   serverName,
		mtu:          negotiation.MTU,
		deadline:     deadline,
		clientRandom: clientRandom,
		reassembler:  newCertificateDTLSHandshakeReassembler(),
	}
	legacyConn, err := handshake.connect()
	if err != nil {
		return nil, 0, err
	}
	return legacyConn, handshake.flight.cipherSuite.id, nil
}

func (h *certificateDTLS10Handshake) connect() (net.Conn, error) {
	defer func() {
		clear(h.transcript)
		h.transcript = nil
		clear(h.flight.serverKeyExchange)
		h.flight.serverKeyExchange = nil
		clear(h.flight.certificateTypes)
		h.flight.certificateTypes = nil
		h.offeredCurves = nil
		for _, authority := range h.flight.acceptableCAs {
			clear(authority)
		}
		h.flight.acceptableCAs = nil
		h.reassembler.destroy()
	}()
	cipherSuites, err := certificateDTLS10CipherSuites(h.tlsConfig.CipherSuites)
	if err != nil {
		return nil, err
	}
	curves, err := certificateDTLS10Curves(h.tlsConfig.CurvePreferences)
	if err != nil {
		return nil, err
	}
	h.offeredCurves = append([]uint16(nil), curves...)
	clientHello, err := buildCertificateDTLSClientHello(
		h.clientRandom,
		nil,
		cipherSuites,
		curves,
		h.serverName,
		h.clientHandshakeSequence,
	)
	if err != nil {
		return nil, err
	}
	serverHello, cookie, err := h.exchangeInitialClientHello(clientHello)
	if err != nil {
		return nil, err
	}
	if len(cookie) > 0 {
		h.clientHandshakeSequence++
		h.reassembler.destroy()
		h.reassembler = newCertificateDTLSHandshakeReassembler()
		clientHello, err = buildCertificateDTLSClientHello(
			h.clientRandom,
			cookie,
			cipherSuites,
			curves,
			h.serverName,
			h.clientHandshakeSequence,
		)
		if err != nil {
			return nil, err
		}
	} else {
		h.serverHandshakeSequence = serverHello.sequence
	}
	h.transcript = append(h.transcript, clientHello...)
	err = h.exchangeServerFlight(clientHello, cipherSuites)
	if err != nil {
		return nil, err
	}
	preMasterSecret, clientKeyExchange, err := h.buildClientKeyExchange()
	if err != nil {
		return nil, err
	}
	defer clear(preMasterSecret)
	defer clear(clientKeyExchange)
	seed := make([]byte, 0, len(h.clientRandom)+len(h.flight.serverRandom))
	seed = append(seed, h.clientRandom...)
	seed = append(seed, h.flight.serverRandom...)
	masterSecret, err := tls10PRF(preMasterSecret, "master secret", seed, 48)
	if err != nil {
		return nil, E.Cause(err, "derive certificate DTLS 1.0 master secret")
	}
	defer clear(masterSecret)
	keys, err := deriveLegacyDTLSKeys(h.suite, h.flight.cipherSuite.keyLength, masterSecret, h.clientRandom, h.flight.serverRandom)
	if err != nil {
		return nil, err
	}
	keysTransferred := false
	defer func() {
		if !keysTransferred {
			keys.destroy()
		}
	}()
	finalFlight, err := h.buildFinalFlight(masterSecret, keys, clientKeyExchange)
	if err != nil {
		return nil, err
	}
	finalFlightTransferred := false
	defer func() {
		if !finalFlightTransferred {
			for _, datagram := range finalFlight {
				clear(datagram)
			}
		}
	}()
	serverFinished, err := h.exchangeServerFinished(finalFlight, masterSecret, keys)
	if err != nil {
		return nil, err
	}
	serverFinishedTransferred := false
	defer func() {
		if !serverFinishedTransferred {
			clear(serverFinished)
		}
	}()
	err = h.conn.SetDeadline(time.Time{})
	if err != nil {
		return nil, E.Cause(err, "clear certificate DTLS 1.0 handshake deadline")
	}
	keysTransferred = true
	finalFlightTransferred = true
	serverFinishedTransferred = true
	return &legacyDTLSConn{
		suite:          h.suite,
		underlying:     h.conn,
		keys:           keys,
		closeAlert:     true,
		mtu:            h.mtu,
		writeSequence:  1,
		finalFlight:    finalFlight,
		serverFinished: serverFinished,
	}, nil
}

func (h *certificateDTLS10Handshake) exchangeInitialClientHello(
	clientHello []byte,
) (certificateDTLSHandshakeMessage, []byte, error) {
	retryInterval := certificateDTLSFlightInterval
	for range certificateDTLSHandshakeRetries {
		err := h.writeUnencryptedHandshake(clientHello)
		if err != nil {
			return certificateDTLSHandshakeMessage{}, nil, E.Cause(err, "send initial certificate DTLS 1.0 ClientHello")
		}
		attemptDeadline := h.attemptDeadline(retryInterval)
		err = h.conn.SetReadDeadline(attemptDeadline)
		if err != nil {
			return certificateDTLSHandshakeMessage{}, nil, E.Cause(err, "set certificate DTLS 1.0 initial-response deadline")
		}
		for time.Now().Before(attemptDeadline) {
			readErr := h.readUnencryptedHandshakeDatagram()
			if readErr != nil {
				if h.ctx.Err() != nil {
					return certificateDTLSHandshakeMessage{}, nil, E.Cause(h.ctx.Err(), "wait for certificate DTLS 1.0 initial response")
				}
				if E.IsTimeout(readErr) {
					break
				}
				return certificateDTLSHandshakeMessage{}, nil, readErr
			}
			for _, message := range h.reassembler.messages {
				switch message.messageType {
				case certificateDTLSHandshakeHelloVerify:
					cookie, parseErr := parseCertificateDTLSHelloVerify(message.body)
					if parseErr != nil {
						return certificateDTLSHandshakeMessage{}, nil, parseErr
					}
					return certificateDTLSHandshakeMessage{}, cookie, nil
				case certificateDTLSHandshakeServerHello:
					return message, nil, nil
				}
			}
		}
		retryInterval *= 2
	}
	return certificateDTLSHandshakeMessage{}, nil, E.New("certificate DTLS 1.0 peer did not answer ClientHello")
}

func (h *certificateDTLS10Handshake) exchangeServerFlight(
	clientHello []byte,
	offeredCipherSuites []certificateDTLS10Cipher,
) error {
	retryInterval := certificateDTLSFlightInterval
	for attempt := range certificateDTLSHandshakeRetries {
		if attempt > 0 || len(h.reassembler.messages) == 0 {
			err := h.writeUnencryptedHandshake(clientHello)
			if err != nil {
				return E.Cause(err, "send certificate DTLS 1.0 cookie ClientHello")
			}
		}
		attemptDeadline := h.attemptDeadline(retryInterval)
		err := h.conn.SetReadDeadline(attemptDeadline)
		if err != nil {
			return E.Cause(err, "set certificate DTLS 1.0 server-flight deadline")
		}
		for {
			complete, processErr := h.processAvailableServerMessages(offeredCipherSuites)
			if processErr != nil {
				return processErr
			}
			if complete {
				return nil
			}
			readErr := h.readUnencryptedHandshakeDatagram()
			if readErr != nil {
				if h.ctx.Err() != nil {
					return E.Cause(h.ctx.Err(), "wait for certificate DTLS 1.0 server flight")
				}
				if E.IsTimeout(readErr) {
					break
				}
				return readErr
			}
		}
		retryInterval *= 2
	}
	return E.New("certificate DTLS 1.0 server flight did not complete")
}

func (h *certificateDTLS10Handshake) processAvailableServerMessages(
	offeredCipherSuites []certificateDTLS10Cipher,
) (bool, error) {
	if h.serverHandshakeSequence == 0 {
		for sequence, message := range h.reassembler.messages {
			if message.messageType == certificateDTLSHandshakeServerHello {
				h.serverHandshakeSequence = sequence
				break
			}
		}
	}
	for {
		message, exists := h.reassembler.take(h.serverHandshakeSequence)
		if !exists {
			return false, nil
		}
		h.serverHandshakeSequence++
		switch message.messageType {
		case certificateDTLSHandshakeHelloVerify:
			continue
		case certificateDTLSHandshakeServerHello:
			serverRandom, cipherSuite, err := parseCertificateDTLSServerHello(message.body, offeredCipherSuites)
			if err != nil {
				return false, err
			}
			h.flight.serverRandom = serverRandom
			h.flight.cipherSuite = cipherSuite
		case certificateDTLSHandshakeCertificate:
			rawCertificates, err := parseCertificateDTLSCertificate(message.body)
			if err != nil {
				return false, err
			}
			certificates, chains, err := verifyCertificateDTLS10Peer(h.tlsConfig, h.serverName, rawCertificates, h.flight.cipherSuite.id)
			if err != nil {
				return false, err
			}
			h.flight.peerCertificates = certificates
			h.flight.verifiedChains = chains
		case certificateDTLSHandshakeServerKey:
			h.flight.serverKeyExchange = append([]byte(nil), message.body...)
		case certificateDTLSHandshakeCertRequest:
			request, err := parseCertificateDTLSCertificateRequest(message.body)
			if err != nil {
				return false, err
			}
			h.flight.certificateRequested = true
			h.flight.certificateTypes = request.certificateTypes
			h.flight.acceptableCAs = request.acceptableCAs
		case certificateDTLSHandshakeServerHelloDone:
			if len(message.body) != 0 || len(h.flight.serverRandom) != 32 || len(h.flight.peerCertificates) == 0 {
				return false, E.New("incomplete certificate DTLS 1.0 server flight")
			}
			if h.flight.cipherSuite.ecdhe && len(h.flight.serverKeyExchange) == 0 {
				return false, E.New("certificate DTLS 1.0 ECDHE server omitted ServerKeyExchange")
			}
			if !h.flight.cipherSuite.ecdhe && len(h.flight.serverKeyExchange) != 0 {
				return false, E.New("certificate DTLS 1.0 RSA server sent unsupported ServerKeyExchange")
			}
			h.flight.complete = true
		default:
			return false, E.New("unexpected certificate DTLS 1.0 handshake message: ", message.messageType)
		}
		h.transcript = append(h.transcript, marshalCertificateDTLSHandshake(message.messageType, message.sequence, message.body)...)
		if h.flight.complete {
			return true, nil
		}
	}
}

func (h *certificateDTLS10Handshake) buildFinalFlight(
	masterSecret []byte,
	keys legacyDTLSKeys,
	clientKeyExchange []byte,
) ([][]byte, error) {
	var finalFlight [][]byte
	completed := false
	defer func() {
		if !completed {
			for _, datagram := range finalFlight {
				clear(datagram)
			}
		}
	}()
	if h.flight.certificateRequested {
		certificate, err := h.selectClientCertificate()
		if err != nil {
			return nil, err
		}
		h.clientCertificate = certificate
		certificateBody := marshalCertificateDTLSCertificate(certificate)
		certificateMessage := marshalCertificateDTLSHandshake(
			certificateDTLSHandshakeCertificate,
			h.clientHandshakeSequence+1,
			certificateBody,
		)
		h.clientHandshakeSequence++
		h.transcript = append(h.transcript, certificateMessage...)
		records, err := h.marshalUnencryptedHandshakeRecords(certificateMessage)
		clear(certificateBody)
		clear(certificateMessage)
		if err != nil {
			return nil, err
		}
		finalFlight = append(finalFlight, records...)
	}
	clientKeyMessage := marshalCertificateDTLSHandshake(
		certificateDTLSHandshakeClientKey,
		h.clientHandshakeSequence+1,
		clientKeyExchange,
	)
	h.clientHandshakeSequence++
	h.transcript = append(h.transcript, clientKeyMessage...)
	clientKeyRecords, err := h.marshalUnencryptedHandshakeRecords(clientKeyMessage)
	clear(clientKeyMessage)
	if err != nil {
		return nil, err
	}
	finalFlight = append(finalFlight, clientKeyRecords...)

	clientCertificate := h.clientCertificate
	if clientCertificate != nil && len(clientCertificate.Certificate) > 0 {
		certificateVerifyBody, signErr := signCertificateDTLS10Transcript(clientCertificate, h.transcript)
		if signErr != nil {
			return nil, signErr
		}
		certificateVerifyMessage := marshalCertificateDTLSHandshake(
			certificateDTLSHandshakeCertVerify,
			h.clientHandshakeSequence+1,
			certificateVerifyBody,
		)
		h.clientHandshakeSequence++
		h.transcript = append(h.transcript, certificateVerifyMessage...)
		certificateVerifyRecords, marshalErr := h.marshalUnencryptedHandshakeRecords(certificateVerifyMessage)
		clear(certificateVerifyBody)
		clear(certificateVerifyMessage)
		if marshalErr != nil {
			return nil, marshalErr
		}
		finalFlight = append(finalFlight, certificateVerifyRecords...)
	}
	changeCipherRecord, err := h.marshalUnencryptedRecord([]byte{1}, legacyDTLSContentCCS)
	if err != nil {
		return nil, err
	}
	finalFlight = append(finalFlight, changeCipherRecord)
	clientVerifyData, err := certificateDTLS10Finished(masterSecret, "client finished", h.transcript)
	if err != nil {
		return nil, err
	}
	clientFinished := marshalCertificateDTLSHandshake(
		certificateDTLSHandshakeFinished,
		h.clientHandshakeSequence+1,
		clientVerifyData,
	)
	h.clientHandshakeSequence++
	clear(clientVerifyData)
	finishedRecord, err := encryptLegacyDTLSRecord(legacyDTLSRecord{
		contentType: legacyDTLSContentHandshake,
		epoch:       1,
		sequence:    0,
		payload:     clientFinished,
	}, keys.clientKey, keys.clientMACKey, h.suite)
	if err != nil {
		return nil, err
	}
	if h.mtu > 0 && len(finishedRecord) > h.mtu {
		clear(finishedRecord)
		return nil, E.New("certificate DTLS 1.0 Finished record exceeds negotiated MTU")
	}
	finalFlight = append(finalFlight, finishedRecord)
	h.transcript = append(h.transcript, clientFinished...)
	clear(clientFinished)
	completed = true
	return finalFlight, nil
}

func (h *certificateDTLS10Handshake) exchangeServerFinished(
	finalFlight [][]byte,
	masterSecret []byte,
	keys legacyDTLSKeys,
) ([]byte, error) {
	expectedVerifyData, err := certificateDTLS10Finished(masterSecret, "server finished", h.transcript)
	if err != nil {
		return nil, err
	}
	defer clear(expectedVerifyData)
	datagram := make([]byte, 64*1024)
	defer clear(datagram)
	retryInterval := certificateDTLSFlightInterval
	changeCipherSeen := false
	for range certificateDTLSHandshakeRetries {
		err = writeLegacyDTLSFlight(h.conn, finalFlight)
		if err != nil {
			return nil, E.Cause(err, "send certificate DTLS 1.0 final flight")
		}
		attemptDeadline := h.attemptDeadline(retryInterval)
		err = h.conn.SetReadDeadline(attemptDeadline)
		if err != nil {
			return nil, E.Cause(err, "set certificate DTLS 1.0 server Finished deadline")
		}
		for {
			n, readErr := h.conn.Read(datagram)
			if readErr != nil {
				if h.ctx.Err() != nil {
					return nil, E.Cause(h.ctx.Err(), "wait for certificate DTLS 1.0 server Finished")
				}
				if E.IsTimeout(readErr) {
					break
				}
				return nil, E.Cause(readErr, "read certificate DTLS 1.0 server Finished")
			}
			records, parseErr := parseLegacyDTLSRecords(datagram[:n], h.suite)
			if parseErr != nil {
				return nil, parseErr
			}
			for _, record := range records {
				switch record.contentType {
				case legacyDTLSContentCCS:
					if record.epoch != 0 || !equalBytes(record.payload, []byte{1}) {
						return nil, E.New("invalid certificate DTLS 1.0 server ChangeCipherSpec")
					}
					changeCipherSeen = true
				case legacyDTLSContentHandshake:
					if record.epoch == 0 {
						continue
					}
					if record.epoch != 1 || !changeCipherSeen {
						return nil, E.New("certificate DTLS 1.0 server sent Finished before ChangeCipherSpec")
					}
					plaintext, decryptErr := decryptLegacyDTLSRecord(record, keys.serverKey, keys.serverMACKey, h.suite)
					if decryptErr != nil {
						return nil, E.Cause(decryptErr, "decrypt certificate DTLS 1.0 server Finished")
					}
					message, messageErr := parseCompleteCertificateDTLSHandshake(plaintext)
					if messageErr != nil {
						return nil, messageErr
					}
					if message.messageType != certificateDTLSHandshakeFinished || len(message.body) != 12 ||
						!equalBytes(message.body, expectedVerifyData) {
						return nil, E.New("certificate DTLS 1.0 server Finished verification failed")
					}
					return append([]byte(nil), plaintext...), nil
				case legacyDTLSContentAlert:
					alert := record.payload
					if record.epoch == 1 {
						var decryptErr error
						alert, decryptErr = decryptLegacyDTLSRecord(record, keys.serverKey, keys.serverMACKey, h.suite)
						if decryptErr != nil {
							return nil, decryptErr
						}
					}
					alertDescription := -1
					if len(alert) == 2 {
						alertDescription = int(alert[1])
					}
					return nil, E.New("certificate DTLS 1.0 peer sent handshake alert: ", alertDescription)
				}
			}
		}
		retryInterval *= 2
	}
	return nil, E.New("certificate DTLS 1.0 server Finished did not arrive")
}

func (h *certificateDTLS10Handshake) attemptDeadline(interval time.Duration) time.Time {
	deadline := time.Now().Add(interval)
	if deadline.After(h.deadline) {
		return h.deadline
	}
	return deadline
}
