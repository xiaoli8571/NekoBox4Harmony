package openconnect

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/textproto"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing/common/buf"
	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
)

const (
	ncONCPConnectTimeout        = 30 * time.Second
	ncONCPMaximumHTTPStatusLine = 8 * 1024
	ncONCPMaximumHTTPHeaders    = 64 * 1024
	ncONCPMaximumKMPPayload     = 65535
	ncONCPMaximumInitialRecords = 4096
	ncONCPMaximumInitialPending = 1024 * 1024
	ncONCPKMPHeaderSize         = 20
	ncONCPKMPData               = uint16(300)
	ncONCPKMPConfiguration      = uint16(301)
	ncONCPKMPESP                = uint16(302)
	ncONCPKMPControl            = uint16(303)
	ncONCPDefaultESPDPD         = 60 * time.Second
)

var (
	ncONCPAuthenticationHead = []byte{0x00, 0x04, 0x00, 0x00, 0x00}
	ncONCPAuthenticationTail = []byte{0xbb, 0x01, 0x00, 0x00, 0x00, 0x00}
	ncONCPKMPHead            = []byte{0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
	ncONCPKMPTail            = []byte{0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
	ncONCPKMPTailOutgoing    = []byte{0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00}
)

type ncONCPConnection struct {
	net.Conn
	reader      *bufio.Reader
	writeAccess sync.Mutex
	pending     *buf.Buffer
}

type ncTunnelConfiguration struct {
	configuration TunnelConfiguration
	assignedIPv4  netip.Addr
	esp           *ncESPConfiguration
}

type ncESPConfiguration struct {
	remote           M.Socksaddr
	keys             *espKeySet
	encryption       espEncryption
	authentication   espAuthentication
	compression      bool
	replayProtection bool
	port             uint16
	dpd              time.Duration
}

type ncESPParameters struct {
	encryption       espEncryption
	authentication   espAuthentication
	compression      byte
	replayProtection bool
	port             uint16
	dpd              time.Duration
	serverSPI        uint32
	serverSecret     []byte
}

// /tmp/openconnect/oncp.c:oncp_connect opens a pinned TLS connection, sends a bodyless HTTP request declaring Content-Length 256, and retains the connection as the oNCP byte stream.
func openNCONCPConnection(
	ctx context.Context,
	client *Client,
	snapshot ncSessionSnapshot,
	localHostname string,
) (*ncONCPConnection, *ncTunnelConfiguration, error) {
	serverPort, err := ncURLPort(snapshot.serverURL)
	if err != nil {
		return nil, nil, markTerminal(err)
	}
	destinationHost := snapshot.serverURL.Hostname()
	if snapshot.acceptedAddress.IsValid() {
		destinationHost = snapshot.acceptedAddress.String()
	}
	destination := M.ParseSocksaddrHostPort(destinationHost, serverPort)
	dialer := client.options.Dialer
	rawConnection, err := dialer.DialContext(ctx, N.NetworkTCP, destination)
	if err != nil {
		return nil, nil, E.Cause(err, "connect Network Connect oNCP TCP transport")
	}
	if !snapshot.acceptedAddress.IsValid() {
		snapshot.acceptedAddress = parseAnyConnectRemoteAddress(rawConnection.RemoteAddr())
	}
	if !snapshot.acceptedAddress.IsValid() {
		_ = rawConnection.Close()
		return nil, nil, markTerminal(E.New("oNCP endpoint did not expose an accepted IP address"))
	}
	setupComplete := false
	defer func() {
		if !setupComplete {
			_ = rawConnection.Close()
		}
	}()
	stopCancellation := context.AfterFunc(ctx, func() {
		_ = rawConnection.Close()
	})
	defer stopCancellation()
	deadline := time.Now().Add(ncONCPConnectTimeout)
	contextDeadline, hasDeadline := ctx.Deadline()
	if hasDeadline && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	err = rawConnection.SetDeadline(deadline)
	if err != nil {
		return nil, nil, E.Cause(err, "set Network Connect oNCP connection deadline")
	}
	tlsConfiguration := client.tlsConfig.Clone()
	if tlsConfiguration.ServerName == "" {
		tlsConfiguration.ServerName = snapshot.serverURL.Hostname()
	}
	tlsConfiguration.NextProtos = []string{"http/1.1"}
	tlsConnection := tls.Client(rawConnection, tlsConfiguration)
	err = tlsConnection.HandshakeContext(ctx)
	if err != nil {
		return nil, nil, E.Cause(err, "handshake Network Connect oNCP TLS transport")
	}
	connection := &ncONCPConnection{Conn: tlsConnection, reader: bufio.NewReader(tlsConnection)}
	request, err := buildNCONCPRequest(client, snapshot)
	if err != nil {
		return nil, nil, markTerminal(err)
	}
	err = connection.writeBytes(request)
	if err != nil {
		return nil, nil, err
	}
	statusCode, responseHeader, err := readNCONCPHTTPHeader(connection.reader)
	if err != nil {
		return nil, nil, E.Cause(err, "read Network Connect oNCP HTTP response")
	}
	if snapshot.jar != nil {
		cookieURL := cloneNCURL(snapshot.serverURL)
		cookieURL.Path = "/dana/js"
		cookieURL.RawPath = ""
		cookieURL.RawQuery = "prot=1&svc=4"
		cookieURL.Fragment = ""
		snapshot.jar.SetCookies(cookieURL, (&http.Response{Header: responseHeader}).Cookies())
	}
	if statusCode == http.StatusFound || (statusCode >= 400 && statusCode < 500) {
		return nil, nil, ErrSessionRejected
	}
	if statusCode != http.StatusOK {
		statusErr := E.New("oNCP endpoint returned HTTP ", statusCode)
		return nil, nil, markTerminal(E.Errors(ErrProtocolNotSupported, statusErr))
	}
	authenticationPacket, err := encodeNCONCPAuthenticationPacket(localHostname)
	if err != nil {
		return nil, nil, markTerminal(err)
	}
	err = connection.writeBytes(authenticationPacket)
	if err != nil {
		return nil, nil, err
	}
	configurationMessage, pendingPackets, err := connection.readInitialConfiguration()
	if err != nil {
		return nil, nil, err
	}
	configuration, response, err := parseNCONCPInitialConfiguration(client, snapshot.acceptedAddress, configurationMessage)
	clear(configurationMessage)
	if err != nil {
		return nil, nil, err
	}
	err = connection.writeRecord(response)
	clear(response)
	if err != nil {
		destroyNCTunnelConfiguration(configuration)
		return nil, nil, err
	}
	err = tlsConnection.SetDeadline(time.Time{})
	if err != nil {
		destroyNCTunnelConfiguration(configuration)
		return nil, nil, E.Cause(err, "clear Network Connect oNCP connection deadline")
	}
	if len(pendingPackets) > 0 {
		connection.pending = newPacketBufferFrom(pendingPackets)
		clear(pendingPackets)
	}
	setupComplete = true
	return connection, configuration, nil
}

func buildNCONCPRequest(client *Client, snapshot ncSessionSnapshot) ([]byte, error) {
	targetURL := cloneNCURL(snapshot.serverURL)
	targetURL.Path = "/dana/js"
	targetURL.RawPath = ""
	targetURL.RawQuery = "prot=1&svc=4"
	targetURL.Fragment = ""
	cookies := snapshot.jar.Cookies(targetURL)
	hasDSID := false
	encodedCookies := make([]string, 0, len(cookies)+1)
	for _, cookie := range cookies {
		if cookie.Name == "DSID" {
			hasDSID = true
		}
		encoded := cookie.String()
		if encoded != "" {
			encodedCookies = append(encodedCookies, encoded)
		}
	}
	if !hasDSID {
		encodedCookies = append(encodedCookies, (&http.Cookie{Name: "DSID", Value: snapshot.dsid}).String())
	}
	if len(encodedCookies) == 0 {
		return nil, E.New("oNCP request has no cookies")
	}
	var request strings.Builder
	request.WriteString("POST /dana/js?prot=1&svc=4 HTTP/1.1\r\nConnection: close\r\nHost: ")
	request.WriteString(snapshot.serverURL.Host)
	request.WriteString("\r\nUser-Agent: ")
	request.WriteString(ncUserAgent(client))
	request.WriteString("\r\nCookie: ")
	request.WriteString(strings.Join(encodedCookies, "; "))
	request.WriteString("\r\nNCP-Version: 3\r\nContent-Length: 256\r\n\r\n")
	return []byte(request.String()), nil
}

func encodeNCONCPAuthenticationPacket(localHostname string) ([]byte, error) {
	packetLength := len(ncONCPAuthenticationHead) + 2 + len(localHostname) + len(ncONCPAuthenticationTail)
	if packetLength > ncONCPMaximumKMPPayload || len(localHostname) > ncONCPMaximumKMPPayload {
		return nil, E.New("oNCP local hostname is too long")
	}
	packet := make([]byte, 2, packetLength+2)
	binary.LittleEndian.PutUint16(packet, uint16(packetLength))
	packet = append(packet, ncONCPAuthenticationHead...)
	hostnameLength := make([]byte, 2)
	binary.LittleEndian.PutUint16(hostnameLength, uint16(len(localHostname)))
	packet = append(packet, hostnameLength...)
	packet = append(packet, localHostname...)
	packet = append(packet, ncONCPAuthenticationTail...)
	return packet, nil
}

func (c *ncONCPConnection) readInitialConfiguration() ([]byte, []byte, error) {
	record, err := c.readRecord()
	if err != nil {
		return nil, nil, err
	}
	if len(record) < 1 {
		return nil, nil, markTerminal(E.New("oNCP hostname response is empty"))
	}
	if record[0] != 0 {
		return nil, nil, markTerminal(E.New("oNCP hostname response returned error ", record[0]))
	}
	configurationBytes := append([]byte(nil), record[1:]...)
	var pendingPackets []byte
	recordCount := 1
	for {
		if len(configurationBytes) >= ncONCPKMPHeaderSize {
			messageType, payloadLength, validationErr := parseNCONCPKMPHeader(configurationBytes[:ncONCPKMPHeaderSize], false)
			if validationErr != nil {
				clear(configurationBytes)
				return nil, nil, validationErr
			}
			if messageType != ncONCPKMPConfiguration {
				clear(configurationBytes)
				return nil, nil, markTerminal(E.New("oNCP expected KMP 301, received ", messageType))
			}
			totalLength := ncONCPKMPHeaderSize + payloadLength
			if len(configurationBytes) >= totalLength {
				configurationMessage := append([]byte(nil), configurationBytes[:totalLength]...)
				if len(configurationBytes) > totalLength {
					pendingPackets = append(pendingPackets, configurationBytes[totalLength:]...)
				}
				clear(configurationBytes)
				return configurationMessage, pendingPackets, nil
			}
		}
		record, err = c.readRecord()
		if err != nil {
			clear(configurationBytes)
			return nil, nil, err
		}
		recordCount++
		if recordCount > ncONCPMaximumInitialRecords {
			clear(configurationBytes)
			clear(pendingPackets)
			return nil, nil, markTerminal(E.New("oNCP initial configuration used too many records"))
		}
		if isNCONCPStandaloneDataRecord(record) {
			if len(pendingPackets)+len(record) > ncONCPMaximumInitialPending {
				clear(configurationBytes)
				clear(pendingPackets)
				return nil, nil, markTerminal(E.New("oNCP queued too much data during initial configuration"))
			}
			pendingPackets = append(pendingPackets, record...)
			continue
		}
		if len(configurationBytes)+len(record) > ncONCPKMPHeaderSize+ncONCPMaximumKMPPayload {
			clear(configurationBytes)
			return nil, nil, markTerminal(E.New("oNCP initial configuration is too large"))
		}
		configurationBytes = append(configurationBytes, record...)
	}
}

func (c *ncONCPConnection) readKMP() (uint16, *buf.Buffer, error) {
	for c.pending == nil || c.pending.Len() < ncONCPKMPHeaderSize {
		record, err := c.readRecordBuffer()
		if err != nil {
			c.releasePending()
			return 0, nil, err
		}
		c.appendPending(record)
	}
	messageType, payloadLength, err := parseNCONCPKMPHeader(c.pending.To(ncONCPKMPHeaderSize), false)
	if err != nil {
		c.releasePending()
		return 0, nil, err
	}
	totalLength := ncONCPKMPHeaderSize + payloadLength
	for c.pending.Len() < totalLength {
		record, readErr := c.readRecordBuffer()
		if readErr != nil {
			c.releasePending()
			return 0, nil, readErr
		}
		c.appendPending(record)
	}
	if c.pending.Len() == totalLength {
		packetBuffer := c.pending
		c.pending = nil
		packetBuffer.Advance(ncONCPKMPHeaderSize)
		return messageType, packetBuffer, nil
	}
	packetBuffer := newPacketBuffer(payloadLength)
	_, _ = packetBuffer.Write(c.pending.Range(ncONCPKMPHeaderSize, totalLength))
	c.pending.Advance(totalLength)
	return messageType, packetBuffer, nil
}

func (c *ncONCPConnection) releasePending() {
	if c.pending != nil {
		c.pending.Release()
		c.pending = nil
	}
}

func (c *ncONCPConnection) appendPending(record *buf.Buffer) {
	if c.pending == nil {
		c.pending = record
		return
	}
	c.pending = requirePacketBufferCapacity(c.pending, 0, record.Len())
	_, _ = c.pending.Write(record.Bytes())
	record.Release()
}

func (c *ncONCPConnection) readRecord() ([]byte, error) {
	lengthBytes := make([]byte, 2)
	_, err := io.ReadFull(c.reader, lengthBytes)
	if err != nil {
		return nil, E.Cause(err, "read Network Connect oNCP record length")
	}
	length := int(binary.LittleEndian.Uint16(lengthBytes))
	if length == 0 {
		reason := make([]byte, 1)
		_, err = io.ReadFull(c.reader, reason)
		if err != nil {
			return nil, E.Cause(err, "read Network Connect oNCP termination reason")
		}
		reasonErr := E.New("oNCP server terminated the session with reason ", reason[0])
		if reason[0] == 1 {
			return nil, E.Errors(ErrSessionRejected, reasonErr)
		}
		return nil, reasonErr
	}
	record := make([]byte, length)
	_, err = io.ReadFull(c.reader, record)
	if err != nil {
		clear(record)
		return nil, E.Cause(err, "read Network Connect oNCP record")
	}
	return record, nil
}

func (c *ncONCPConnection) readRecordBuffer() (*buf.Buffer, error) {
	lengthBytes := make([]byte, 2)
	_, err := io.ReadFull(c.reader, lengthBytes)
	if err != nil {
		return nil, E.Cause(err, "read Network Connect oNCP record length")
	}
	length := int(binary.LittleEndian.Uint16(lengthBytes))
	if length == 0 {
		reason := make([]byte, 1)
		_, err = io.ReadFull(c.reader, reason)
		if err != nil {
			return nil, E.Cause(err, "read Network Connect oNCP termination reason")
		}
		reasonErr := E.New("oNCP server terminated the session with reason ", reason[0])
		if reason[0] == 1 {
			return nil, E.Errors(ErrSessionRejected, reasonErr)
		}
		return nil, reasonErr
	}
	packetBuffer := newPacketBuffer(length)
	_, err = packetBuffer.ReadFullFrom(c.reader, length)
	if err != nil {
		packetBuffer.Release()
		return nil, E.Cause(err, "read Network Connect oNCP record")
	}
	return packetBuffer, nil
}

func (c *ncONCPConnection) writeRecord(content []byte) error {
	if len(content) == 0 || len(content) > ncONCPMaximumKMPPayload {
		return E.New("oNCP record has invalid length: ", len(content))
	}
	record := make([]byte, 2, len(content)+2)
	binary.LittleEndian.PutUint16(record, uint16(len(content)))
	record = append(record, content...)
	err := c.writeBytes(record)
	clear(record)
	return err
}

func (c *ncONCPConnection) writeKMPPacketBuffers(messageType uint16, packetBuffers []*buf.Buffer) error {
	validPacketBuffers := packetBuffers
	var validationErr error
	for index, packetBuffer := range packetBuffers {
		payloadLength := packetBuffer.Len()
		if payloadLength > ncONCPMaximumKMPPayload {
			validPacketBuffers = packetBuffers[:index]
			validationErr = E.New("oNCP KMP payload is too large: ", payloadLength)
			break
		}
		messageLength := ncONCPKMPHeaderSize + payloadLength
		if messageLength > ncONCPMaximumKMPPayload {
			validPacketBuffers = packetBuffers[:index]
			validationErr = E.New("oNCP record has invalid length: ", messageLength)
			break
		}
		packetBuffers[index] = requirePacketBufferCapacity(packetBuffer, 2+ncONCPKMPHeaderSize, 0)
		header := packetBuffers[index].ExtendHeader(2 + ncONCPKMPHeaderSize)
		binary.LittleEndian.PutUint16(header[:2], uint16(messageLength))
		copy(header[2:8], ncONCPKMPHead)
		binary.BigEndian.PutUint16(header[8:10], messageType)
		copy(header[10:20], ncONCPKMPTailOutgoing)
		binary.BigEndian.PutUint16(header[20:22], uint16(payloadLength))
	}
	if len(validPacketBuffers) == 0 {
		return validationErr
	}
	c.writeAccess.Lock()
	err := writeByteSequence(c.Conn, buf.ToSliceMulti(validPacketBuffers))
	c.writeAccess.Unlock()
	if err != nil {
		return E.Cause(err, "write Network Connect oNCP bytes")
	}
	return validationErr
}

func (c *ncONCPConnection) writeBytes(content []byte) error {
	c.writeAccess.Lock()
	defer c.writeAccess.Unlock()
	for len(content) > 0 {
		n, err := c.Conn.Write(content)
		if err != nil {
			return E.Cause(err, "write Network Connect oNCP bytes")
		}
		if n <= 0 || n > len(content) {
			return E.New("oNCP write made invalid progress: ", n)
		}
		content = content[n:]
	}
	return nil
}

func parseNCONCPKMPHeader(header []byte, outgoing bool) (uint16, int, error) {
	if len(header) < ncONCPKMPHeaderSize || !bytes.Equal(header[:6], ncONCPKMPHead) {
		return 0, 0, markTerminal(E.New("oNCP KMP header is invalid"))
	}
	expectedTail := ncONCPKMPTail
	if outgoing {
		expectedTail = ncONCPKMPTailOutgoing
	}
	if !bytes.Equal(header[8:18], expectedTail) {
		messageType := binary.BigEndian.Uint16(header[6:8])
		legacyDataTail := messageType == ncONCPKMPData && header[8] == 0 && bytes.Equal(header[9:18], ncONCPKMPTail[1:])
		if !legacyDataTail {
			return 0, 0, markTerminal(E.New("oNCP KMP constants are invalid"))
		}
	}
	return binary.BigEndian.Uint16(header[6:8]), int(binary.BigEndian.Uint16(header[18:20])), nil
}

func encodeNCONCPKMP(messageType uint16, payload []byte) ([]byte, error) {
	if len(payload) > ncONCPMaximumKMPPayload {
		return nil, E.New("oNCP KMP payload is too large: ", len(payload))
	}
	message := make([]byte, ncONCPKMPHeaderSize, ncONCPKMPHeaderSize+len(payload))
	copy(message[:6], ncONCPKMPHead)
	binary.BigEndian.PutUint16(message[6:8], messageType)
	copy(message[8:18], ncONCPKMPTailOutgoing)
	binary.BigEndian.PutUint16(message[18:20], uint16(len(payload)))
	message = append(message, payload...)
	return message, nil
}

func encodeNCONCPTLV(identifier uint16, content []byte) []byte {
	encoded := make([]byte, 6, 6+len(content))
	binary.BigEndian.PutUint16(encoded[0:2], identifier)
	binary.BigEndian.PutUint32(encoded[2:6], uint32(len(content)))
	return append(encoded, content...)
}

func parseNCONCPInitialConfiguration(
	client *Client,
	acceptedAddress netip.Addr,
	message []byte,
) (*ncTunnelConfiguration, []byte, error) {
	messageType, payloadLength, err := parseNCONCPKMPHeader(message, false)
	if err != nil {
		return nil, nil, err
	}
	if messageType != ncONCPKMPConfiguration || payloadLength != len(message)-ncONCPKMPHeaderSize {
		return nil, nil, markTerminal(E.New("oNCP initial KMP 301 length is invalid"))
	}
	configuration, espParameters, err := parseNCONCPConfigurationPayload(message[ncONCPKMPHeaderSize:])
	if err != nil {
		return nil, nil, err
	}
	configuration.configuration.RemoteAddress = acceptedAddress.Unmap()
	configuration.configuration = normalizeTunnelConfiguration(
		configuration.configuration,
		client.options.IPv6Disabled,
	)
	responsePayload := encodeNCONCPMTUControlPayload(configuration.configuration.MTU)
	response, err := encodeNCONCPKMP(ncONCPKMPControl, responsePayload)
	clear(responsePayload)
	if err != nil {
		destroyNCTunnelConfiguration(configuration)
		espParameters.clear()
		return nil, nil, err
	}
	if !client.options.NoUDP && acceptedAddress.Is4() {
		espConfiguration, espResponse, espErr := prepareNCONCPESP(acceptedAddress, espParameters)
		if espErr == nil && espConfiguration != nil {
			configuration.esp = espConfiguration
			response = append(response, espResponse...)
			clear(espResponse)
		} else if espErr != nil && client.options.Logger != nil {
			client.options.Logger.WarnContext(client.options.Context, "Ignoring unusable Network Connect ESP configuration; using oNCP/TLS: ", espErr)
		}
	}
	if configuration.esp != nil && client.options.DPDInterval > 0 {
		configuration.esp.dpd = client.options.DPDInterval
	}
	espParameters.clear()
	return configuration, response, nil
}

func parseNCONCPConfigurationPayload(payload []byte) (*ncTunnelConfiguration, ncESPParameters, error) {
	configuration := &ncTunnelConfiguration{}
	var espParameters ncESPParameters
	success := false
	defer func() {
		if !success {
			espParameters.clear()
		}
	}()
	var assignedIPv4 netip.Addr
	var netmask netip.Addr
	offset := 0
	for offset < len(payload) {
		if len(payload)-offset < 6 {
			return nil, espParameters, markTerminal(E.New("oNCP configuration has a truncated group"))
		}
		group := binary.BigEndian.Uint16(payload[offset : offset+2])
		groupLengthValue := binary.BigEndian.Uint32(payload[offset+2 : offset+6])
		offset += 6
		if uint64(groupLengthValue) > uint64(len(payload)-offset) {
			return nil, espParameters, markTerminal(E.New("oNCP configuration group length is invalid"))
		}
		groupLength := int(groupLengthValue)
		groupEnd := offset + groupLength
		for offset < groupEnd {
			if groupEnd-offset < 6 {
				return nil, espParameters, markTerminal(E.New("oNCP configuration has a truncated attribute"))
			}
			attribute := binary.BigEndian.Uint16(payload[offset : offset+2])
			attributeLengthValue := binary.BigEndian.Uint32(payload[offset+2 : offset+6])
			offset += 6
			if uint64(attributeLengthValue) > uint64(groupEnd-offset) {
				return nil, espParameters, markTerminal(E.New("oNCP configuration attribute length is invalid"))
			}
			attributeLength := int(attributeLengthValue)
			content := payload[offset : offset+attributeLength]
			err := applyNCONCPConfigurationAttribute(configuration, &espParameters, &assignedIPv4, &netmask, group, attribute, content)
			if err != nil {
				return nil, espParameters, markTerminal(err)
			}
			offset += attributeLength
		}
	}
	if !assignedIPv4.IsValid() || !netmask.IsValid() || configuration.configuration.MTU < 576 || configuration.configuration.MTU > 65535 {
		return nil, espParameters, markTerminal(E.New("oNCP server returned insufficient IPv4 tunnel configuration"))
	}
	prefix, err := ncIPv4Prefix(assignedIPv4, netmask)
	if err != nil {
		return nil, espParameters, markTerminal(err)
	}
	configuration.assignedIPv4 = assignedIPv4
	configuration.configuration.Addresses = []netip.Prefix{prefix}
	success = true
	return configuration, espParameters, nil
}

func parseNCONCPESPParameters(payload []byte, parameters ncESPParameters) (ncESPParameters, error) {
	configuration := &ncTunnelConfiguration{}
	var assignedIPv4 netip.Addr
	var netmask netip.Addr
	offset := 0
	for offset < len(payload) {
		if len(payload)-offset < 6 {
			parameters.clear()
			return ncESPParameters{}, markTerminal(E.New("ESP KMP 302 has a truncated group"))
		}
		group := binary.BigEndian.Uint16(payload[offset : offset+2])
		groupLengthValue := binary.BigEndian.Uint32(payload[offset+2 : offset+6])
		offset += 6
		if (group != 7 && group != 8) || uint64(groupLengthValue) > uint64(len(payload)-offset) {
			parameters.clear()
			return ncESPParameters{}, markTerminal(E.New("ESP KMP 302 group is invalid"))
		}
		groupLength := int(groupLengthValue)
		groupEnd := offset + groupLength
		for offset < groupEnd {
			if groupEnd-offset < 6 {
				parameters.clear()
				return ncESPParameters{}, markTerminal(E.New("ESP KMP 302 has a truncated attribute"))
			}
			attribute := binary.BigEndian.Uint16(payload[offset : offset+2])
			attributeLengthValue := binary.BigEndian.Uint32(payload[offset+2 : offset+6])
			offset += 6
			if uint64(attributeLengthValue) > uint64(groupEnd-offset) {
				parameters.clear()
				return ncESPParameters{}, markTerminal(E.New("ESP KMP 302 attribute length is invalid"))
			}
			attributeLength := int(attributeLengthValue)
			content := payload[offset : offset+attributeLength]
			err := applyNCONCPConfigurationAttribute(configuration, &parameters, &assignedIPv4, &netmask, group, attribute, content)
			if err != nil {
				parameters.clear()
				return ncESPParameters{}, markTerminal(err)
			}
			offset += attributeLength
		}
	}
	return parameters, nil
}

func applyNCONCPConfigurationAttribute(
	configuration *ncTunnelConfiguration,
	espParameters *ncESPParameters,
	assignedIPv4 *netip.Addr,
	netmask *netip.Addr,
	group uint16,
	attribute uint16,
	content []byte,
) error {
	switch uint32(group)<<16 | uint32(attribute) {
	case 1<<16 | 1:
		address, err := ncIPv4Attribute(content, "assigned IPv4 address")
		if err != nil {
			return err
		}
		*assignedIPv4 = address
	case 1<<16 | 2:
		address, err := ncIPv4Attribute(content, "IPv4 netmask")
		if err != nil {
			return err
		}
		*netmask = address
	case 2<<16 | 1:
		address, err := ncIPv4Attribute(content, "DNS server")
		if err != nil {
			return err
		}
		if len(configuration.configuration.DNS) < 3 {
			configuration.configuration.DNS = append(configuration.configuration.DNS, address)
		}
	case 2<<16 | 2:
		domain := strings.TrimSpace(string(content))
		if domain != "" {
			configuration.configuration.SearchDomains = append(configuration.configuration.SearchDomains, domain)
		}
	case 3<<16 | 3, 3<<16 | 4:
		prefix, err := ncIPv4Route(content)
		if err != nil {
			return err
		}
		route := TunnelRoute{Prefix: prefix}
		if attribute == 3 {
			configuration.configuration.Routes = append(configuration.configuration.Routes, route)
		} else {
			configuration.configuration.ExcludedRoutes = append(configuration.configuration.ExcludedRoutes, route)
		}
	case 4<<16 | 1:
		address, err := ncIPv4Attribute(content, "NBNS server")
		if err != nil {
			return err
		}
		if len(configuration.configuration.NBNS) < 3 {
			configuration.configuration.NBNS = append(configuration.configuration.NBNS, address)
		}
	case 6<<16 | 2:
		if len(content) != 4 {
			return E.New("oNCP MTU attribute has invalid length")
		}
		configuration.configuration.MTU = binary.BigEndian.Uint32(content)
	case 7<<16 | 1:
		if len(content) != 4 {
			return E.New("ESP SPI attribute has invalid length")
		}
		espParameters.serverSPI = binary.BigEndian.Uint32(content)
	case 7<<16 | 2:
		if len(content) != 64 {
			return E.New("ESP secret attribute has invalid length")
		}
		clear(espParameters.serverSecret)
		espParameters.serverSecret = append(espParameters.serverSecret[:0], content...)
	case 8<<16 | 1:
		if len(content) != 1 {
			return E.New("ESP encryption attribute has invalid length")
		}
		switch content[0] {
		case 2:
			espParameters.encryption = espEncryptionAES128CBC
		case 5:
			espParameters.encryption = espEncryptionAES256CBC
		default:
			espParameters.encryption = 0
		}
	case 8<<16 | 2:
		if len(content) != 1 {
			return E.New("ESP authentication attribute has invalid length")
		}
		switch content[0] {
		case 1:
			espParameters.authentication = espAuthenticationHMACMD596
		case 2:
			espParameters.authentication = espAuthenticationHMACSHA196
		case 3:
			espParameters.authentication = espAuthenticationHMACSHA256128
		default:
			espParameters.authentication = 0
		}
	case 8<<16 | 3:
		if len(content) != 1 {
			return E.New("ESP compression attribute has invalid length")
		}
		espParameters.compression = content[0]
	case 8<<16 | 4:
		if len(content) != 2 {
			return E.New("ESP port attribute has invalid length")
		}
		espParameters.port = binary.BigEndian.Uint16(content)
	case 8<<16 | 9:
		if len(content) != 4 {
			return E.New("ESP fallback attribute has invalid length")
		}
		espParameters.dpd = time.Duration(binary.BigEndian.Uint32(content)) * time.Second
	case 8<<16 | 10:
		if len(content) != 4 {
			return E.New("ESP replay protection attribute has invalid length")
		}
		espParameters.replayProtection = binary.BigEndian.Uint32(content) != 0
	}
	return nil
}

func ncIPv4Attribute(content []byte, description string) (netip.Addr, error) {
	if len(content) != 4 {
		return netip.Addr{}, E.New("oNCP ", description, " attribute has invalid length")
	}
	address := netip.AddrFrom4([4]byte(content))
	return address, nil
}

func ncIPv4Route(content []byte) (netip.Prefix, error) {
	if len(content) != 8 {
		return netip.Prefix{}, E.New("oNCP IPv4 route has invalid length")
	}
	address := netip.AddrFrom4([4]byte(content[:4]))
	netmask := netip.AddrFrom4([4]byte(content[4:]))
	return ncIPv4Prefix(address, netmask)
}

func ncIPv4Prefix(address netip.Addr, netmask netip.Addr) (netip.Prefix, error) {
	if !address.Is4() || !netmask.Is4() {
		return netip.Prefix{}, E.New("oNCP IPv4 prefix has a non-IPv4 value")
	}
	maskBytes := netmask.As4()
	mask := net.IPMask(maskBytes[:])
	ones, bits := mask.Size()
	if ones < 0 || bits != 32 {
		return netip.Prefix{}, E.New("oNCP IPv4 netmask is not contiguous")
	}
	return netip.PrefixFrom(address, ones), nil
}

func encodeNCONCPMTUControlPayload(mtu uint32) []byte {
	mtuBytes := make([]byte, 4)
	binary.BigEndian.PutUint32(mtuBytes, mtu)
	attribute := encodeNCONCPTLV(2, mtuBytes)
	return encodeNCONCPTLV(6, attribute)
}

func encodeNCONCPESPControl(enable bool) ([]byte, error) {
	value := byte(0)
	if enable {
		value = 1
	}
	attribute := encodeNCONCPTLV(1, []byte{value})
	payload := encodeNCONCPTLV(6, attribute)
	message, err := encodeNCONCPKMP(ncONCPKMPControl, payload)
	clear(payload)
	return message, err
}

func prepareNCONCPESP(
	acceptedAddress netip.Addr,
	parameters ncESPParameters,
) (*ncESPConfiguration, []byte, error) {
	keyConfiguration, response, err := buildNCONCPESPKeyConfiguration(parameters)
	if err != nil {
		return nil, nil, err
	}
	keys, err := newESPKeySet(keyConfiguration)
	clearNCONCPESPKeyConfiguration(&keyConfiguration)
	if err != nil {
		clear(response)
		return nil, nil, err
	}
	dpd := parameters.dpd
	if dpd <= 0 {
		dpd = ncONCPDefaultESPDPD
	}
	return &ncESPConfiguration{
		remote:           M.ParseSocksaddrHostPort(acceptedAddress.String(), parameters.port),
		keys:             keys,
		encryption:       parameters.encryption,
		authentication:   parameters.authentication,
		compression:      parameters.compression == 1,
		replayProtection: parameters.replayProtection,
		port:             parameters.port,
		dpd:              dpd,
	}, response, nil
}

func buildNCONCPESPKeyConfiguration(parameters ncESPParameters) (espKeySetConfig, []byte, error) {
	if parameters.encryption.keyLength() == 0 || parameters.authentication.keyLength() == 0 || parameters.port == 0 || parameters.serverSPI == 0 || len(parameters.serverSecret) != 64 {
		return espKeySetConfig{}, nil, E.New("ESP parameters are incomplete or use unknown algorithms")
	}
	if parameters.compression > 1 {
		return espKeySetConfig{}, nil, E.Extend(ErrProtocolNotSupported, "ESP compression type is ", parameters.compression)
	}
	encryptionKeyLength := parameters.encryption.keyLength()
	authenticationKeyLength := parameters.authentication.keyLength()
	if encryptionKeyLength+authenticationKeyLength > len(parameters.serverSecret) {
		return espKeySetConfig{}, nil, E.New("ESP secret block is too short")
	}
	serverEncryptionKey := append([]byte(nil), parameters.serverSecret[:encryptionKeyLength]...)
	serverAuthenticationKey := append([]byte(nil), parameters.serverSecret[encryptionKeyLength:encryptionKeyLength+authenticationKeyLength]...)
	clientEncryptionKey := make([]byte, encryptionKeyLength)
	clientAuthenticationKey := make([]byte, authenticationKeyLength)
	_, err := rand.Read(clientEncryptionKey)
	if err == nil {
		_, err = rand.Read(clientAuthenticationKey)
	}
	var clientSPIBytes [4]byte
	for err == nil && binary.BigEndian.Uint32(clientSPIBytes[:]) == 0 {
		_, err = rand.Read(clientSPIBytes[:])
	}
	if err != nil {
		clear(serverEncryptionKey)
		clear(serverAuthenticationKey)
		clear(clientEncryptionKey)
		clear(clientAuthenticationKey)
		return espKeySetConfig{}, nil, E.Cause(err, "generate Network Connect ESP client keys")
	}
	clientSPI := binary.BigEndian.Uint32(clientSPIBytes[:])
	keyConfiguration := espKeySetConfig{
		Encryption:              parameters.encryption,
		Authentication:          parameters.authentication,
		DisableReplayProtection: !parameters.replayProtection,
		Outbound: espKeyMaterial{
			SPI:               parameters.serverSPI,
			EncryptionKey:     serverEncryptionKey,
			AuthenticationKey: serverAuthenticationKey,
		},
		Inbound: espKeyMaterial{
			SPI:               clientSPI,
			EncryptionKey:     clientEncryptionKey,
			AuthenticationKey: clientAuthenticationKey,
		},
	}
	response, err := encodeNCONCPESPResponse(clientSPI, clientEncryptionKey, clientAuthenticationKey)
	if err != nil {
		clearNCONCPESPKeyConfiguration(&keyConfiguration)
		return espKeySetConfig{}, nil, err
	}
	return keyConfiguration, response, nil
}

func encodeNCONCPESPResponse(clientSPI uint32, encryptionKey []byte, authenticationKey []byte) ([]byte, error) {
	secret := make([]byte, 64)
	copy(secret, encryptionKey)
	copy(secret[len(encryptionKey):], authenticationKey)
	spiBytes := make([]byte, 4)
	binary.BigEndian.PutUint32(spiBytes, clientSPI)
	attributes := encodeNCONCPTLV(1, spiBytes)
	attributes = append(attributes, encodeNCONCPTLV(2, secret)...)
	clear(secret)
	payload := encodeNCONCPTLV(7, attributes)
	clear(attributes)
	message, err := encodeNCONCPKMP(ncONCPKMPESP, payload)
	clear(payload)
	return message, err
}

func isNCONCPStandaloneDataRecord(record []byte) bool {
	if len(record) < ncONCPKMPHeaderSize+20 {
		return false
	}
	messageType, payloadLength, err := parseNCONCPKMPHeader(record[:ncONCPKMPHeaderSize], false)
	if err != nil {
		return false
	}
	return messageType == ncONCPKMPData && payloadLength+ncONCPKMPHeaderSize == len(record) && record[ncONCPKMPHeaderSize]>>4 == 4
}

func readNCONCPHTTPHeader(reader *bufio.Reader) (int, http.Header, error) {
	statusLine, err := readNCONCPHTTPLine(reader, ncONCPMaximumHTTPStatusLine)
	if err != nil {
		return 0, nil, err
	}
	fields := strings.Fields(statusLine)
	if len(fields) < 2 || !strings.HasPrefix(fields[0], "HTTP/") {
		return 0, nil, markTerminal(E.New("oNCP HTTP status line is invalid"))
	}
	statusCode, err := strconv.Atoi(fields[1])
	if err != nil || statusCode < 100 || statusCode > 999 {
		return 0, nil, markTerminal(E.New("oNCP HTTP status code is invalid"))
	}
	var encodedHeaders strings.Builder
	for {
		remaining := ncONCPMaximumHTTPHeaders - encodedHeaders.Len()
		if remaining <= 0 {
			return 0, nil, markTerminal(E.New("oNCP HTTP headers are too large"))
		}
		line, lineErr := readNCONCPHTTPLine(reader, remaining)
		if lineErr != nil {
			return 0, nil, lineErr
		}
		if line == "" {
			break
		}
		encodedHeaders.WriteString(line)
		encodedHeaders.WriteString("\r\n")
	}
	encodedHeaders.WriteString("\r\n")
	mimeHeader, err := textproto.NewReader(bufio.NewReader(strings.NewReader(encodedHeaders.String()))).ReadMIMEHeader()
	if err != nil {
		return 0, nil, markTerminal(E.Cause(err, "parse Network Connect oNCP HTTP headers"))
	}
	return statusCode, http.Header(mimeHeader), nil
}

func readNCONCPHTTPLine(reader *bufio.Reader, maximum int) (string, error) {
	var line strings.Builder
	for {
		fragment, err := reader.ReadSlice('\n')
		if line.Len()+len(fragment) > maximum {
			return "", markTerminal(E.New("oNCP HTTP line is too long"))
		}
		line.Write(fragment)
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			return "", err
		}
		return strings.TrimSuffix(strings.TrimSuffix(line.String(), "\n"), "\r"), nil
	}
}

func destroyNCTunnelConfiguration(configuration *ncTunnelConfiguration) {
	if configuration == nil {
		return
	}
	if configuration.esp != nil && configuration.esp.keys != nil {
		configuration.esp.keys.destroy()
	}
	configuration.esp = nil
}

func (p *ncESPParameters) clear() {
	clear(p.serverSecret)
	*p = ncESPParameters{}
}

func clearNCONCPESPKeyConfiguration(configuration *espKeySetConfig) {
	clear(configuration.Outbound.EncryptionKey)
	clear(configuration.Outbound.AuthenticationKey)
	clear(configuration.Inbound.EncryptionKey)
	clear(configuration.Inbound.AuthenticationKey)
	*configuration = espKeySetConfig{}
}
