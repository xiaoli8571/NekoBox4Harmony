package openvpn

import (
	"bytes"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"encoding/binary"
	"hash"
	"runtime"
	"strconv"
	"strings"

	"github.com/sagernet/sing-openvpn/proto"
	E "github.com/sagernet/sing/common/exceptions"
)

const (
	tlsKeyMethod2 = 2

	tlsIVProtoDataV2        = 1 << 1
	tlsIVProtoRequestPush   = 1 << 2
	tlsIVProtoTLSKeyExport  = 1 << 3
	tlsIVProtoAuthPendingKW = 1 << 4
	tlsIVProtoNCPP2P        = 1 << 5
	tlsIVProtoCCExitNotify  = 1 << 7
	tlsIVProtoAuthFailTemp  = 1 << 8
)

// Upstream key_method_2_write sends IV_VER in peer-info.
const tlsAdvertisedVersion = "2.6.14"

type tlsKeyMethodMessage struct {
	OptionsString string
	Username      string
	Password      string
	PeerInfo      string
	KeySource     tlsKeyMethodKeySource
}

type tlsKeyMethodKeySource struct {
	PreMaster []byte
	Random1   []byte
	Random2   []byte
}

func generateTLSKeyMethodKeySource(isClient bool) (tlsKeyMethodKeySource, error) {
	keySource := tlsKeyMethodKeySource{}
	keySource.Random1 = make([]byte, 32)
	_, err := rand.Read(keySource.Random1)
	if err != nil {
		return tlsKeyMethodKeySource{}, err
	}
	keySource.Random2 = make([]byte, 32)
	_, err = rand.Read(keySource.Random2)
	if err != nil {
		return tlsKeyMethodKeySource{}, err
	}
	if isClient {
		keySource.PreMaster = make([]byte, 48)
		_, err = rand.Read(keySource.PreMaster)
		if err != nil {
			return tlsKeyMethodKeySource{}, err
		}
	}
	return keySource, nil
}

func buildTLSOptionsStringWithMTU(protocol string, isClient bool, tlsAuthEnabled bool, compression compressionSettings, cipherName string, authName string, tunMTU uint32) string {
	if tunMTU == 0 {
		tunMTU = 1500
	}
	linkMTU := tunMTU + 50
	var builder strings.Builder
	builder.WriteString("V4,dev-type tun,link-mtu ")
	builder.WriteString(strconv.FormatUint(uint64(linkMTU), 10))
	builder.WriteString(",tun-mtu ")
	builder.WriteString(strconv.FormatUint(uint64(tunMTU), 10))
	builder.WriteString(",proto ")
	builder.WriteString(tlsProtoName(protocol, isClient))

	// Upstream options_string (options.c) writes comp-lzo for every active
	// compression context, not only for the LZO algorithm.
	if compression.framingEnabled() {
		builder.WriteString(",comp-lzo")
	}

	resolvedCipher := cipherName
	if resolvedCipher == "" {
		resolvedCipher = "AES-256-GCM"
	}
	builder.WriteString(",cipher ")
	builder.WriteString(resolvedCipher)

	resolvedAuth := authName
	if resolvedAuth == "" {
		resolvedAuth = "SHA1"
	}
	builder.WriteString(",auth ")
	builder.WriteString(resolvedAuth)

	keySize, keySizeErr := tlsCipherKeyBits(resolvedCipher)
	if keySizeErr == nil {
		builder.WriteString(",keysize ")
		builder.WriteString(keySize)
	}

	if tlsAuthEnabled {
		builder.WriteString(",tls-auth")
	}
	builder.WriteString(",key-method 2,")
	if isClient {
		builder.WriteString("tls-client")
	} else {
		builder.WriteString("tls-server")
	}
	return builder.String()
}

func buildTLSPeerInfo(options ClientOptions, requestPush bool) string {
	dataCiphers := tlsAdvertisedDataCiphers(options.DataChannel.Ciphers)
	ivProto := tlsIVProtoDataV2 | tlsIVProtoTLSKeyExport | tlsIVProtoCCExitNotify
	if requestPush {
		// Upstream key_method_2_write advertises pull-only IV_PROTO bits
		// for REQUEST_PUSH, AUTH_PENDING_KW, and AUTH_FAIL_TEMP.
		ivProto |= tlsIVProtoRequestPush
		ivProto |= tlsIVProtoAuthPendingKW
		ivProto |= tlsIVProtoAuthFailTemp
	} else {
		ivProto |= tlsIVProtoNCPP2P
	}
	var builder strings.Builder
	builder.WriteString("IV_VER=")
	builder.WriteString(tlsAdvertisedVersion)
	builder.WriteString("\n")
	builder.WriteString("IV_PLAT=")
	builder.WriteString(tlsAdvertisedPlatform(runtime.GOOS))
	builder.WriteString("\n")
	if tlsSupportsNCPv2(dataCiphers) {
		builder.WriteString("IV_NCP=2\n")
	}
	builder.WriteString("IV_CIPHERS=")
	builder.WriteString(strings.Join(dataCiphers, ":"))
	builder.WriteString("\n")
	builder.WriteString("IV_PROTO=")
	builder.WriteString(strconv.Itoa(ivProto))
	builder.WriteString("\n")
	if requestPush {
		// Upstream check_auth_pending_method (ssl_verify.c) gates
		// client-pending-auth methods on the advertised IV_SSO tokens.
		builder.WriteString("IV_SSO=webauth,openurl,crtext\n")
		tunMTU := options.DataChannel.MTU
		if tunMTU == 0 {
			tunMTU = 1500
		}
		builder.WriteString("IV_MTU=")
		builder.WriteString(strconv.FormatUint(uint64(tunMTU), 10))
		builder.WriteString("\n")
	}
	builder.WriteString("IV_LZ4=1\n")
	builder.WriteString("IV_LZ4v2=1\n")
	compression, _ := resolveCompressionSettings(options.DataChannel.Compression, options.DataChannel.CompressionLZO)
	allowCompression, _ := resolveEffectiveAllowCompressionPolicy(options.DataChannel.AllowCompression, compression)
	if allowCompression != allowCompressionStubOnly {
		builder.WriteString("IV_LZO=1\n")
	} else {
		builder.WriteString("IV_LZO_STUB=1\n")
	}
	builder.WriteString("IV_COMP_STUB=1\n")
	builder.WriteString("IV_COMP_STUBv2=1\n")
	// Upstream key_method_2_write always emits IV_TCPNL=1.
	builder.WriteString("IV_TCPNL=1\n")
	return builder.String()
}

func tlsAdvertisedPlatform(operatingSystem string) string {
	switch strings.ToLower(strings.TrimSpace(operatingSystem)) {
	case "linux":
		return "linux"
	case "darwin":
		return "mac"
	case "windows":
		return "win"
	case "freebsd":
		return "freebsd"
	case "netbsd":
		return "netbsd"
	case "openbsd":
		return "openbsd"
	case "solaris":
		return "solaris"
	case "android":
		return "android"
	case "ios":
		return "mac"
	default:
		return "linux"
	}
}

func buildTLSServerPeerInfo(options ServerOptions) string {
	ivProto := tlsIVProtoDataV2 | tlsIVProtoTLSKeyExport | tlsIVProtoCCExitNotify
	var builder strings.Builder
	builder.WriteString("IV_PROTO=")
	builder.WriteString(strconv.Itoa(ivProto))
	builder.WriteString("\n")
	serverCiphers := tlsAdvertisedDataCiphers(options.DataChannel.Ciphers)
	if tlsSupportsNCPv2(serverCiphers) {
		builder.WriteString("IV_NCP=2\n")
	}
	if len(serverCiphers) > 0 {
		builder.WriteString("IV_CIPHERS=")
		builder.WriteString(strings.Join(serverCiphers, ":"))
		builder.WriteString("\n")
	}
	return builder.String()
}

func buildTLSKeyMethod2Payload(server bool, message tlsKeyMethodMessage) ([]byte, error) {
	var payload bytes.Buffer
	err := binary.Write(&payload, binary.BigEndian, uint32(0))
	if err != nil {
		return nil, err
	}
	err = payload.WriteByte(tlsKeyMethod2)
	if err != nil {
		return nil, err
	}
	if !server {
		if len(message.KeySource.PreMaster) != 48 {
			return nil, E.New("client key source pre-master must be 48 bytes")
		}
		_, err = payload.Write(message.KeySource.PreMaster)
		if err != nil {
			return nil, err
		}
	}
	if len(message.KeySource.Random1) != 32 {
		return nil, E.New("key source random1 must be 32 bytes")
	}
	_, err = payload.Write(message.KeySource.Random1)
	if err != nil {
		return nil, err
	}
	if len(message.KeySource.Random2) != 32 {
		return nil, E.New("key source random2 must be 32 bytes")
	}
	_, err = payload.Write(message.KeySource.Random2)
	if err != nil {
		return nil, err
	}
	err = writeLengthPrefixedString(&payload, message.OptionsString)
	if err != nil {
		return nil, err
	}
	err = writeLengthPrefixedString(&payload, message.Username)
	if err != nil {
		return nil, err
	}
	err = writeLengthPrefixedString(&payload, message.Password)
	if err != nil {
		return nil, err
	}
	err = writeLengthPrefixedString(&payload, message.PeerInfo)
	if err != nil {
		return nil, err
	}
	return payload.Bytes(), nil
}

func parseTLSKeyMethod2Payload(payload []byte, server bool) (tlsKeyMethodMessage, error) {
	reader := bytes.NewReader(payload)
	var reserved uint32
	err := binary.Read(reader, binary.BigEndian, &reserved)
	if err != nil {
		return tlsKeyMethodMessage{}, err
	}
	keyMethod, err := reader.ReadByte()
	if err != nil {
		return tlsKeyMethodMessage{}, err
	}
	if keyMethod&0x0f != tlsKeyMethod2 {
		return tlsKeyMethodMessage{}, E.New("unsupported key-method")
	}
	keySource := tlsKeyMethodKeySource{}
	if !server {
		keySource.PreMaster = make([]byte, 48)
		_, err = reader.Read(keySource.PreMaster)
		if err != nil {
			return tlsKeyMethodMessage{}, err
		}
	}
	keySource.Random1 = make([]byte, 32)
	_, err = reader.Read(keySource.Random1)
	if err != nil {
		return tlsKeyMethodMessage{}, err
	}
	keySource.Random2 = make([]byte, 32)
	_, err = reader.Read(keySource.Random2)
	if err != nil {
		return tlsKeyMethodMessage{}, err
	}
	optionsString, err := readLengthPrefixedString(reader)
	if err != nil {
		return tlsKeyMethodMessage{}, err
	}
	username, err := readLengthPrefixedString(reader)
	if err != nil {
		return tlsKeyMethodMessage{}, err
	}
	password, err := readLengthPrefixedString(reader)
	if err != nil {
		return tlsKeyMethodMessage{}, err
	}
	peerInfo, err := readLengthPrefixedString(reader)
	if err != nil {
		return tlsKeyMethodMessage{}, err
	}
	return tlsKeyMethodMessage{
		OptionsString: optionsString,
		Username:      username,
		Password:      password,
		PeerInfo:      peerInfo,
		KeySource:     keySource,
	}, nil
}

func peerInfoIVProto(peerInfo string) (int, bool) {
	for line := range strings.SplitSeq(peerInfo, "\n") {
		trimmedLine := strings.TrimRight(line, "\r")
		if !strings.HasPrefix(trimmedLine, "IV_PROTO=") {
			continue
		}
		parsedValue, err := strconv.Atoi(strings.TrimPrefix(trimmedLine, "IV_PROTO="))
		if err != nil {
			return 0, false
		}
		return parsedValue, true
	}
	return 0, false
}

func peerSupportsIVProtoFlag(peerInfo string, flag int) bool {
	ivProto, found := peerInfoIVProto(peerInfo)
	if !found {
		return false
	}
	return ivProto&flag != 0
}

func peerInfoMTU(peerInfo string) (uint32, bool) {
	for line := range strings.SplitSeq(peerInfo, "\n") {
		trimmedLine := strings.TrimRight(line, "\r")
		if !strings.HasPrefix(trimmedLine, "IV_MTU=") {
			continue
		}
		parsedValue, err := strconv.ParseUint(strings.TrimPrefix(trimmedLine, "IV_MTU="), 10, 32)
		if err != nil || parsedValue == 0 {
			return 0, false
		}
		return uint32(parsedValue), true
	}
	return 0, false
}

func normalizeTLSControlMessage(payload []byte) string {
	trimmedPayload := payload
	if nullIndex := bytes.IndexByte(trimmedPayload, 0); nullIndex >= 0 {
		trimmedPayload = trimmedPayload[:nullIndex]
	}
	return strings.TrimSpace(string(trimmedPayload))
}

func tlsAdvertisedDataCiphers(dataCiphers []string) []string {
	if len(dataCiphers) == 0 {
		return []string{"AES-256-GCM", "AES-128-GCM", "CHACHA20-POLY1305"}
	}
	return append([]string(nil), dataCiphers...)
}

// Upstream check_session_cipher rejects pushed ciphers outside data-ciphers.
func tlsValidateServerPushedCipher(options ClientOptions, pushedCipher string) (string, error) {
	trimmedCipher := strings.TrimSpace(pushedCipher)
	if trimmedCipher == "" {
		return "", nil
	}
	if strings.EqualFold(options.DataChannel.FallbackCipher, trimmedCipher) {
		return options.DataChannel.FallbackCipher, nil
	}
	advertised := tlsAdvertisedDataCiphers(options.DataChannel.Ciphers)
	for _, candidate := range advertised {
		if strings.EqualFold(candidate, trimmedCipher) {
			return candidate, nil
		}
	}
	return "", E.New("negotiated cipher not allowed - ", trimmedCipher, " not in ", strings.Join(advertised, ":"))
}

func tlsSupportsNCPv2(dataCiphers []string) bool {
	hasAES128GCM := false
	hasAES256GCM := false
	for _, dataCipher := range dataCiphers {
		switch dataCipher {
		case "AES-128-GCM":
			hasAES128GCM = true
		case "AES-256-GCM":
			hasAES256GCM = true
		}
	}
	return hasAES128GCM && hasAES256GCM
}

func tlsCipherKeyBits(cipherName string) (string, error) {
	switch cipherName {
	case "AES-128-GCM", "AES-128-CBC", "AES-128-CFB", "AES-128-OFB",
		"ARIA-128-CBC", "ARIA-128-CFB", "ARIA-128-OFB",
		"CAMELLIA-128-CBC", "CAMELLIA-128-CFB", "CAMELLIA-128-OFB",
		"SEED-CBC", "SEED-CFB", "SEED-OFB", "SM4-CBC", "SM4-CFB", "SM4-OFB":
		return "128", nil
	case "AES-192-GCM", "AES-192-CBC", "AES-192-CFB", "AES-192-OFB",
		"ARIA-192-CBC", "ARIA-192-CFB", "ARIA-192-OFB",
		"CAMELLIA-192-CBC", "CAMELLIA-192-CFB", "CAMELLIA-192-OFB":
		return "192", nil
	case "AES-256-GCM", "AES-256-CBC", "AES-256-CFB", "AES-256-OFB",
		"ARIA-256-CBC", "ARIA-256-CFB", "ARIA-256-OFB",
		"CAMELLIA-256-CBC", "CAMELLIA-256-CFB", "CAMELLIA-256-OFB":
		return "256", nil
	case "CHACHA20-POLY1305":
		return "256", nil
	case "BF-CBC", "BF-CFB", "BF-OFB", "CAST5-CBC", "CAST5-CFB", "CAST5-OFB":
		return "128", nil
	case "DES-CBC", "DES-CFB", "DES-OFB":
		return "64", nil
	case "DES-EDE-CBC", "DES-EDE-CFB", "DES-EDE-OFB":
		return "128", nil
	case "DES-EDE3-CBC", "DES-EDE3-CFB", "DES-EDE3-OFB":
		return "192", nil
	case "NONE":
		return "0", nil
	default:
		return "", E.New("unsupported cipher")
	}
}

func tlsProtoName(protocol string, isClient bool) string {
	switch protocol {
	case "udp", "udp4":
		return "UDPv4"
	case "udp6":
		return "UDPv6"
	case "tcp", "tcp4":
		if isClient {
			return "TCPv4_CLIENT"
		}
		return "TCPv4_SERVER"
	case "tcp6":
		if isClient {
			return "TCPv6_CLIENT"
		}
		return "TCPv6_SERVER"
	default:
		return "UDPv4"
	}
}

func writeLengthPrefixedString(buffer *bytes.Buffer, value string) error {
	stringBytes := append([]byte(value), 0)
	if len(stringBytes) > 0xffff {
		return E.New("length-prefixed string too long")
	}
	err := binary.Write(buffer, binary.BigEndian, uint16(len(stringBytes)))
	if err != nil {
		return err
	}
	_, err = buffer.Write(stringBytes)
	return err
}

func readLengthPrefixedString(reader *bytes.Reader) (string, error) {
	var length uint16
	err := binary.Read(reader, binary.BigEndian, &length)
	if err != nil {
		return "", err
	}
	if length == 0 {
		return "", nil
	}
	stringBytes := make([]byte, int(length))
	_, err = reader.Read(stringBytes)
	if err != nil {
		return "", err
	}
	if stringBytes[len(stringBytes)-1] == 0 {
		stringBytes = stringBytes[:len(stringBytes)-1]
	}
	return string(stringBytes), nil
}

const (
	tlsPRFMasterSecretLabel  = "OpenVPN master secret"
	tlsPRFKeyExpansionLabel  = "OpenVPN key expansion"
	tlsPRFMasterSecretLength = 48
	tlsPRFKeyMaterialLength  = 256
)

func tls1PHash(newHash func() hash.Hash, secret []byte, seed []byte, outputLength int) []byte {
	if outputLength <= 0 {
		return nil
	}
	output := make([]byte, 0, outputLength)
	macSeed := hmac.New(newHash, secret)
	macSeed.Write(seed)
	iterationSeed := macSeed.Sum(nil)
	for len(output) < outputLength {
		outputMAC := hmac.New(newHash, secret)
		outputMAC.Write(iterationSeed)
		outputMAC.Write(seed)
		output = append(output, outputMAC.Sum(nil)...)
		if len(output) >= outputLength {
			break
		}
		nextSeedMAC := hmac.New(newHash, secret)
		nextSeedMAC.Write(iterationSeed)
		iterationSeed = nextSeedMAC.Sum(nil)
	}
	return output[:outputLength]
}

func openvpnTLS1PRF(secret []byte, seed []byte, outputLength int) []byte {
	halfLength := len(secret) / 2
	splitLength := halfLength + (len(secret) & 1)
	firstSecretHalf := secret[:splitLength]
	secondSecretHalf := secret[halfLength : halfLength+splitLength]
	md5Output := tls1PHash(md5.New, firstSecretHalf, seed, outputLength)
	sha1Output := tls1PHash(sha1.New, secondSecretHalf, seed, outputLength)
	for i := range md5Output {
		md5Output[i] ^= sha1Output[i]
	}
	return md5Output
}

func openvpnPRF(secret []byte, label string, clientSeed, serverSeed, clientSessionID, serverSessionID []byte, outputLength int) []byte {
	seedSize := len(label) + len(clientSeed) + len(serverSeed) + len(clientSessionID) + len(serverSessionID)
	combinedSeed := make([]byte, 0, seedSize)
	combinedSeed = append(combinedSeed, label...)
	combinedSeed = append(combinedSeed, clientSeed...)
	combinedSeed = append(combinedSeed, serverSeed...)
	combinedSeed = append(combinedSeed, clientSessionID...)
	combinedSeed = append(combinedSeed, serverSessionID...)
	return openvpnTLS1PRF(secret, combinedSeed, outputLength)
}

func deriveTLSKeyMaterialPRF(clientPreMaster, clientRandom1, serverRandom1, clientRandom2, serverRandom2 []byte, clientSessionID, serverSessionID proto.SessionID) []byte {
	master := openvpnPRF(clientPreMaster, tlsPRFMasterSecretLabel, clientRandom1, serverRandom1, nil, nil, tlsPRFMasterSecretLength)
	keyMaterial := openvpnPRF(master, tlsPRFKeyExpansionLabel, clientRandom2, serverRandom2, clientSessionID[:], serverSessionID[:], tlsPRFKeyMaterialLength)
	for i := range master {
		master[i] = 0
	}
	return keyMaterial
}
