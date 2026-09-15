package openconnect

import (
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/binary"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	legacyDTLSRecordHeaderLength = 13
	legacyDTLSContentCCS         = 20
	legacyDTLSContentAlert       = 21
	legacyDTLSContentHandshake   = 22
	legacyDTLSContentApplication = 23
	legacyDTLSMaxSequence        = 0x0000ffffffffffff
	legacyDTLSMACLength          = sha1.Size
	legacyDTLSCloseGracePeriod   = time.Second
	legacyDTLSReadBufferSize     = 64 * 1024
)

type legacyDTLSSuite struct {
	label       string
	version     uint16
	newBlock    func(key []byte) (cipher.Block, error)
	blockLength int
}

type legacyDTLSKeys struct {
	clientMACKey []byte
	serverMACKey []byte
	clientKey    []byte
	serverKey    []byte
}

func deriveLegacyDTLSKeys(
	suite legacyDTLSSuite,
	keyLength int,
	masterSecret []byte,
	clientRandom []byte,
	serverRandom []byte,
) (legacyDTLSKeys, error) {
	keyMaterialLength := (2 * legacyDTLSMACLength) + (2 * keyLength) + (2 * suite.blockLength)
	seed := make([]byte, 0, len(serverRandom)+len(clientRandom))
	seed = append(seed, serverRandom...)
	seed = append(seed, clientRandom...)
	keyMaterial, err := tls10PRF(masterSecret, "key expansion", seed, keyMaterialLength)
	if err != nil {
		return legacyDTLSKeys{}, E.Cause(err, "derive ", suite.label, " record keys")
	}
	defer clear(keyMaterial)
	offset := 0
	clientMACKey := append([]byte(nil), keyMaterial[offset:offset+legacyDTLSMACLength]...)
	offset += legacyDTLSMACLength
	serverMACKey := append([]byte(nil), keyMaterial[offset:offset+legacyDTLSMACLength]...)
	offset += legacyDTLSMACLength
	clientKey := append([]byte(nil), keyMaterial[offset:offset+keyLength]...)
	offset += keyLength
	serverKey := append([]byte(nil), keyMaterial[offset:offset+keyLength]...)
	return legacyDTLSKeys{
		clientMACKey: clientMACKey,
		serverMACKey: serverMACKey,
		clientKey:    clientKey,
		serverKey:    serverKey,
	}, nil
}

func (k *legacyDTLSKeys) destroy() {
	clear(k.clientMACKey)
	clear(k.serverMACKey)
	clear(k.clientKey)
	clear(k.serverKey)
	k.clientMACKey = nil
	k.serverMACKey = nil
	k.clientKey = nil
	k.serverKey = nil
}

type legacyDTLSRecord struct {
	contentType byte
	epoch       uint16
	sequence    uint64
	payload     []byte
}

type legacyDTLSReplayWindow struct {
	initialized bool
	maximum     uint64
	bitmap      uint64
}

func (w *legacyDTLSReplayWindow) accept(sequence uint64) bool {
	if !w.initialized {
		w.initialized = true
		w.maximum = sequence
		w.bitmap = 1
		return true
	}
	if sequence > w.maximum {
		shift := sequence - w.maximum
		if shift >= 64 {
			w.bitmap = 1
		} else {
			w.bitmap = (w.bitmap << shift) | 1
		}
		w.maximum = sequence
		return true
	}
	difference := w.maximum - sequence
	if difference >= 64 {
		return false
	}
	mask := uint64(1) << difference
	if w.bitmap&mask != 0 {
		return false
	}
	w.bitmap |= mask
	return true
}

type legacyDTLSConn struct {
	suite          legacyDTLSSuite
	underlying     net.Conn
	keys           legacyDTLSKeys
	strict         bool
	closeAlert     bool
	mtu            int
	keyAccess      sync.RWMutex
	writeAccess    sync.Mutex
	readAccess     sync.Mutex
	readBuffer     []byte
	readQueue      [][]byte
	writeSequence  uint64
	replay         legacyDTLSReplayWindow
	finalFlight    [][]byte
	serverFinished []byte
	closed         atomic.Bool
}

func (c *legacyDTLSConn) Read(buffer []byte) (int, error) {
	c.readAccess.Lock()
	defer c.readAccess.Unlock()
	if c.readBuffer == nil {
		c.readBuffer = make([]byte, legacyDTLSReadBufferSize)
	}
	for len(c.readQueue) == 0 {
		n, err := c.underlying.Read(c.readBuffer)
		if err != nil {
			return 0, err
		}
		records, err := parseLegacyDTLSRecords(c.readBuffer[:n], c.suite)
		if err != nil {
			if c.strict {
				return 0, err
			}
			continue
		}
		for _, record := range records {
			switch record.contentType {
			case legacyDTLSContentApplication:
				c.keyAccess.RLock()
				plaintext, decryptErr := decryptLegacyDTLSRecord(record, c.keys.serverKey, c.keys.serverMACKey, c.suite)
				c.keyAccess.RUnlock()
				if decryptErr != nil {
					if c.strict {
						return 0, decryptErr
					}
					continue
				}
				if !c.replay.accept(record.sequence) {
					clear(plaintext)
					continue
				}
				c.readQueue = append(c.readQueue, plaintext)
			case legacyDTLSContentHandshake:
				if record.epoch != 1 {
					continue
				}
				c.keyAccess.RLock()
				plaintext, decryptErr := decryptLegacyDTLSRecord(record, c.keys.serverKey, c.keys.serverMACKey, c.suite)
				c.keyAccess.RUnlock()
				if decryptErr != nil || !equalBytes(plaintext, c.serverFinished) {
					clear(plaintext)
					continue
				}
				clear(plaintext)
				// Upstream dtls_try_handshake documents that unsolicited final CCS retransmits upset ASA; resend only after an authenticated duplicate server Finished.
				c.writeAccess.Lock()
				writeErr := writeLegacyDTLSFlight(c.underlying, c.finalFlight)
				c.writeAccess.Unlock()
				if writeErr != nil {
					return 0, E.Cause(writeErr, "retransmit ", c.suite.label, " final handshake flight")
				}
			case legacyDTLSContentAlert:
				if c.strict {
					if record.epoch == 1 {
						c.keyAccess.RLock()
						_, decryptErr := decryptLegacyDTLSRecord(record, c.keys.serverKey, c.keys.serverMACKey, c.suite)
						c.keyAccess.RUnlock()
						if decryptErr != nil {
							return 0, decryptErr
						}
					}
					return 0, E.New(c.suite.label, " peer sent an alert")
				}
				if record.epoch != 1 {
					continue
				}
				c.keyAccess.RLock()
				plaintext, decryptErr := decryptLegacyDTLSRecord(record, c.keys.serverKey, c.keys.serverMACKey, c.suite)
				c.keyAccess.RUnlock()
				if decryptErr != nil {
					continue
				}
				if len(plaintext) == 2 && plaintext[1] == 0 {
					clear(plaintext)
					return 0, io.EOF
				}
				alertDescription := -1
				if len(plaintext) == 2 {
					alertDescription = int(plaintext[1])
				}
				clear(plaintext)
				return 0, E.New(c.suite.label, " peer sent alert: ", alertDescription)
			case legacyDTLSContentCCS:
			default:
				if c.strict {
					return 0, E.New("unknown ", c.suite.label, " record type: ", record.contentType)
				}
			}
		}
	}
	payload := c.readQueue[0]
	if len(buffer) < len(payload) {
		return 0, io.ErrShortBuffer
	}
	c.readQueue[0] = nil
	c.readQueue = c.readQueue[1:]
	n := copy(buffer, payload)
	clear(payload)
	return n, nil
}

func (c *legacyDTLSConn) Write(payload []byte) (int, error) {
	c.writeAccess.Lock()
	defer c.writeAccess.Unlock()
	if c.closed.Load() {
		return 0, net.ErrClosed
	}
	if c.writeSequence > legacyDTLSMaxSequence {
		return 0, E.New(c.suite.label, " record sequence exhausted")
	}
	record := legacyDTLSRecord{
		contentType: legacyDTLSContentApplication,
		epoch:       1,
		sequence:    c.writeSequence,
		payload:     payload,
	}
	c.keyAccess.RLock()
	encoded, err := encryptLegacyDTLSRecord(record, c.keys.clientKey, c.keys.clientMACKey, c.suite)
	c.keyAccess.RUnlock()
	if err != nil {
		return 0, err
	}
	if c.mtu > 0 && len(encoded) > c.mtu {
		return 0, E.Extend(syscall.EMSGSIZE, c.suite.label, " record is ", len(encoded), " bytes for MTU ", c.mtu)
	}
	n, err := c.underlying.Write(encoded)
	if err != nil {
		return 0, E.Cause(err, "write ", c.suite.label, " datagram")
	}
	if n != len(encoded) {
		return 0, E.New("short ", c.suite.label, " datagram write: wrote ", n, " of ", len(encoded), " bytes")
	}
	c.writeSequence++
	return len(payload), nil
}

func (c *legacyDTLSConn) Close() error {
	if c.closed.Swap(true) {
		return nil
	}
	var alertErr error
	if c.closeAlert {
		_ = c.underlying.SetWriteDeadline(time.Now().Add(legacyDTLSCloseGracePeriod))
		forcedCloseDone := make(chan struct{})
		forcedClose := time.AfterFunc(legacyDTLSCloseGracePeriod, func() {
			_ = c.underlying.Close()
			close(forcedCloseDone)
		})
		c.writeAccess.Lock()
		if !forcedClose.Stop() {
			<-forcedCloseDone
		}
		c.keyAccess.RLock()
		alertRecord, encryptErr := encryptLegacyDTLSRecord(legacyDTLSRecord{
			contentType: legacyDTLSContentAlert,
			epoch:       1,
			sequence:    c.writeSequence,
			payload:     []byte{1, 0},
		}, c.keys.clientKey, c.keys.clientMACKey, c.suite)
		c.keyAccess.RUnlock()
		alertErr = encryptErr
		if alertErr == nil {
			alertErr = writeLegacyDTLSDatagram(c.underlying, alertRecord)
		}
		c.writeAccess.Unlock()
	}
	closeErr := c.underlying.Close()
	if E.IsClosed(closeErr) {
		closeErr = nil
	}
	c.readAccess.Lock()
	c.writeAccess.Lock()
	c.keyAccess.Lock()
	c.keys.destroy()
	for _, datagram := range c.finalFlight {
		clear(datagram)
	}
	c.finalFlight = nil
	clear(c.serverFinished)
	c.serverFinished = nil
	c.readQueue = nil
	clear(c.readBuffer)
	c.readBuffer = nil
	c.keyAccess.Unlock()
	c.writeAccess.Unlock()
	c.readAccess.Unlock()
	return E.Errors(alertErr, closeErr)
}

func (c *legacyDTLSConn) LocalAddr() net.Addr {
	return c.underlying.LocalAddr()
}

func (c *legacyDTLSConn) RemoteAddr() net.Addr {
	return c.underlying.RemoteAddr()
}

func (c *legacyDTLSConn) SetDeadline(deadline time.Time) error {
	return c.underlying.SetDeadline(deadline)
}

func (c *legacyDTLSConn) SetReadDeadline(deadline time.Time) error {
	return c.underlying.SetReadDeadline(deadline)
}

func (c *legacyDTLSConn) SetWriteDeadline(deadline time.Time) error {
	return c.underlying.SetWriteDeadline(deadline)
}

func parseLegacyDTLSRecords(datagram []byte, suite legacyDTLSSuite) ([]legacyDTLSRecord, error) {
	records := make([]legacyDTLSRecord, 0, 3)
	for len(datagram) > 0 {
		if len(datagram) < legacyDTLSRecordHeaderLength {
			return nil, E.New("short ", suite.label, " record header: ", len(datagram), " bytes")
		}
		if binary.BigEndian.Uint16(datagram[1:3]) != suite.version {
			return nil, E.New("unexpected ", suite.label, " record version: ", binary.BigEndian.Uint16(datagram[1:3]))
		}
		payloadLength := int(binary.BigEndian.Uint16(datagram[11:13]))
		recordLength := legacyDTLSRecordHeaderLength + payloadLength
		if len(datagram) < recordLength {
			return nil, E.New("truncated ", suite.label, " record payload")
		}
		records = append(records, legacyDTLSRecord{
			contentType: datagram[0],
			epoch:       binary.BigEndian.Uint16(datagram[3:5]),
			sequence:    readUint48(datagram[5:11]),
			payload:     datagram[legacyDTLSRecordHeaderLength:recordLength:recordLength],
		})
		datagram = datagram[recordLength:]
	}
	return records, nil
}

func marshalLegacyDTLSRecord(record legacyDTLSRecord, suite legacyDTLSSuite) ([]byte, error) {
	if record.sequence > legacyDTLSMaxSequence {
		return nil, E.New(suite.label, " record sequence exceeds 48 bits")
	}
	if len(record.payload) > 65535 {
		return nil, E.New(suite.label, " record payload is too large: ", len(record.payload))
	}
	encoded := make([]byte, legacyDTLSRecordHeaderLength+len(record.payload))
	encoded[0] = record.contentType
	binary.BigEndian.PutUint16(encoded[1:3], suite.version)
	binary.BigEndian.PutUint16(encoded[3:5], record.epoch)
	putUint48(encoded[5:11], record.sequence)
	binary.BigEndian.PutUint16(encoded[11:13], uint16(len(record.payload)))
	copy(encoded[13:], record.payload)
	return encoded, nil
}

func encryptLegacyDTLSRecord(record legacyDTLSRecord, key []byte, macKey []byte, suite legacyDTLSSuite) ([]byte, error) {
	block, err := suite.newBlock(key)
	if err != nil {
		return nil, E.Cause(err, "initialize ", suite.label, " record cipher")
	}
	mac, err := legacyDTLSRecordMAC(record, record.payload, macKey, suite)
	if err != nil {
		return nil, err
	}
	defer clear(mac)
	plaintext := make([]byte, 0, len(record.payload)+len(mac)+suite.blockLength)
	plaintext = append(plaintext, record.payload...)
	plaintext = append(plaintext, mac...)
	paddingLength := suite.blockLength - (len(plaintext) % suite.blockLength)
	paddingValue := byte(paddingLength - 1)
	for range paddingLength {
		plaintext = append(plaintext, paddingValue)
	}
	iv := make([]byte, suite.blockLength)
	_, err = rand.Read(iv)
	if err != nil {
		clear(plaintext)
		return nil, E.Cause(err, "generate ", suite.label, " record IV")
	}
	defer clear(iv)
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(plaintext, plaintext)
	record.payload = append(iv, plaintext...)
	encoded, err := marshalLegacyDTLSRecord(record, suite)
	clear(plaintext)
	return encoded, err
}

func decryptLegacyDTLSRecord(record legacyDTLSRecord, key []byte, macKey []byte, suite legacyDTLSSuite) ([]byte, error) {
	if record.epoch != 1 {
		return nil, E.New("encrypted ", suite.label, " record has unexpected epoch: ", record.epoch)
	}
	minimumCiphertextLength := ((legacyDTLSMACLength + suite.blockLength) / suite.blockLength) * suite.blockLength
	if len(record.payload) < suite.blockLength+minimumCiphertextLength || (len(record.payload)-suite.blockLength)%suite.blockLength != 0 {
		return nil, E.New("invalid ", suite.label, " CBC record length: ", len(record.payload))
	}
	block, err := suite.newBlock(key)
	if err != nil {
		return nil, E.Cause(err, "initialize ", suite.label, " record cipher")
	}
	iv := record.payload[:suite.blockLength]
	plaintext := record.payload[suite.blockLength:]
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(plaintext, plaintext)
	paddingLength := int(plaintext[len(plaintext)-1]) + 1
	paddingValue := byte(paddingLength - 1)
	paddingValid := subtle.ConstantTimeLessOrEq(paddingLength, len(plaintext)-legacyDTLSMACLength)
	checkLength := min(256, len(plaintext))
	for i := range checkLength {
		insidePadding := subtle.ConstantTimeLessOrEq(i+1, paddingLength)
		matching := subtle.ConstantTimeByteEq(plaintext[len(plaintext)-1-i], paddingValue)
		paddingValid &= subtle.ConstantTimeSelect(insidePadding, matching, 1)
	}
	safePaddingLength := subtle.ConstantTimeSelect(paddingValid, paddingLength, 1)
	payloadLength := len(plaintext) - safePaddingLength - legacyDTLSMACLength
	payload := plaintext[:payloadLength]
	receivedMAC := plaintext[payloadLength : payloadLength+legacyDTLSMACLength]
	record.payload = payload
	expectedMAC, err := legacyDTLSRecordMAC(record, payload, macKey, suite)
	if err != nil {
		clear(plaintext)
		return nil, err
	}
	macValid := subtle.ConstantTimeCompare(receivedMAC, expectedMAC)
	clear(expectedMAC)
	if paddingValid&macValid != 1 {
		clear(plaintext)
		return nil, E.New("invalid ", suite.label, " record authentication")
	}
	return payload, nil
}

func legacyDTLSRecordMAC(record legacyDTLSRecord, payload []byte, key []byte, suite legacyDTLSSuite) ([]byte, error) {
	header := make([]byte, legacyDTLSRecordHeaderLength)
	binary.BigEndian.PutUint16(header[0:2], record.epoch)
	putUint48(header[2:8], record.sequence)
	header[8] = record.contentType
	binary.BigEndian.PutUint16(header[9:11], suite.version)
	binary.BigEndian.PutUint16(header[11:13], uint16(len(payload)))
	mac := hmac.New(sha1.New, key)
	_, err := mac.Write(header)
	if err != nil {
		return nil, E.Cause(err, "write ", suite.label, " record MAC header")
	}
	_, err = mac.Write(payload)
	if err != nil {
		return nil, E.Cause(err, "write ", suite.label, " record MAC payload")
	}
	return mac.Sum(nil), nil
}

func writeLegacyDTLSDatagram(conn net.Conn, datagram []byte) error {
	n, err := conn.Write(datagram)
	if err != nil {
		return err
	}
	if n != len(datagram) {
		return E.New("short legacy DTLS datagram write: wrote ", n, " of ", len(datagram), " bytes")
	}
	return nil
}

func writeLegacyDTLSFlight(conn net.Conn, flight [][]byte) error {
	for _, datagram := range flight {
		err := writeLegacyDTLSDatagram(conn, datagram)
		if err != nil {
			return err
		}
	}
	return nil
}

func putUint48(destination []byte, value uint64) {
	destination[0] = byte(value >> 40)
	destination[1] = byte(value >> 32)
	destination[2] = byte(value >> 24)
	destination[3] = byte(value >> 16)
	destination[4] = byte(value >> 8)
	destination[5] = byte(value)
}

func readUint48(source []byte) uint64 {
	return uint64(source[0])<<40 |
		uint64(source[1])<<32 |
		uint64(source[2])<<24 |
		uint64(source[3])<<16 |
		uint64(source[4])<<8 |
		uint64(source[5])
}
