// Portions of the RSA SecurID implementation are derived from libstoken
// commit 837e843e8850d14a5d49d799b066d61d04fd649a, src/securid.c.
// It follows securid_mac, v2_decode_token, v2_decrypt_seed, v3_decode_token,
// v3_decrypt_seed, and securid_compute_tokencode.
// Copyright 2012 Kevin Cernekee. libstoken is licensed LGPL-2.1-or-later.
package openconnect

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"slices"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"

	"golang.org/x/crypto/pbkdf2"
)

const (
	securIDPasswordProtection = uint16(1 << 13)
	securIDDeviceProtection   = uint16(1 << 12)
	securIDTimeDerivedSeeds   = uint16(1 << 9)
	securIDDigitShift         = 6
	securIDDigitMask          = uint16(0x07 << securIDDigitShift)
	securIDPINModeShift       = 3
	securIDPINModeMask        = uint16(0x03 << securIDPINModeShift)
	securIDIntervalMask       = uint16(0x03)
	securID128Bit             = uint16(1 << 14)
	securIDV3AddPINOff        = byte(0x1f)
)

var (
	securIDV3Key0  = [16]byte{0xd0, 0x14, 0x43, 0x3c, 0x6d, 0x17, 0x9f, 0xeb, 0xda, 0x09, 0xab, 0xfc, 0x32, 0x49, 0x63, 0x4c}
	securIDV3Key1  = [16]byte{0x3b, 0xaf, 0xff, 0x4d, 0x91, 0x8d, 0x89, 0xb6, 0x81, 0x60, 0xde, 0x44, 0x4e, 0x05, 0xc0, 0xdd}
	securIDV2Magic = [6]byte{0xd8, 0xf5, 0x32, 0x53, 0x82, 0x89}
)

type securIDToken struct {
	version           int
	serial            string
	flags             uint16
	smartphone        bool
	encryptedSeed     [aes.BlockSize]byte
	decryptedSeed     [aes.BlockSize]byte
	decryptedSeedHash uint16
	deviceIDHash      uint16
	v3                *securIDV3Token
}

type securIDV3Token struct {
	version                   byte
	passwordLocked            byte
	deviceLocked              byte
	nonceDeviceHash           [sha256.Size]byte
	nonceDevicePasswordHash   [sha256.Size]byte
	nonce                     [aes.BlockSize]byte
	encryptedPayload          [176]byte
	messageAuthenticationCode [sha256.Size]byte
}

// OpenConnect's stoken integration calls stoken_compute_tokencode without the libstoken CLI's securid_check_exp gate.
func generateSTokenCode(options *TokenOptions, now time.Time) (string, uint64, error) {
	token, err := parseSecurIDToken(options.Secret)
	if err != nil {
		return "", 0, err
	}
	err = decryptSecurIDToken(&token, options.Password, options.DeviceID)
	if err != nil {
		return "", 0, err
	}
	usesPIN := ((token.flags & securIDPINModeMask) >> securIDPINModeShift) >= 2
	if usesPIN {
		err = validateSecurIDPIN(options.PIN)
		if err != nil {
			return "", 0, err
		}
	}
	code, err := computeSecurIDTokenCode(token, options.PIN, usesPIN, now)
	if err != nil {
		return "", 0, err
	}
	if !usesPIN {
		code = options.PIN + code
	}
	period := uint64(60)
	if token.flags&securIDIntervalMask == 0 {
		period = 30
	}
	return code, period, nil
}

func parseSecurIDToken(secret string) (securIDToken, error) {
	trimmedSecret := strings.TrimSpace(secret)
	lowerSecret := strings.ToLower(trimmedSecret)
	if strings.Contains(lowerSecret, "<?xml") {
		return securIDToken{}, E.New("RSA SecurID SDTID/XML provisioning is not supported; provide an encoded CTF token string")
	}
	if strings.HasPrefix(trimmedSecret, "@") || strings.HasPrefix(trimmedSecret, "/") || strings.HasPrefix(lowerSecret, "version ") || strings.Contains(lowerSecret, "\nversion ") {
		return securIDToken{}, E.New("RSA SecurID stoken rcfiles and token file paths are not supported; provide the encoded token contents")
	}
	tokenText := trimmedSecret
	markerOffset := indexFold(trimmedSecret, "ctfData=3D")
	if markerOffset >= 0 {
		tokenText = trimmedSecret[markerOffset+len("ctfData=3D"):]
	} else {
		markerOffset = indexFold(trimmedSecret, "ctfData=")
		if markerOffset >= 0 {
			tokenText = trimmedSecret[markerOffset+len("ctfData="):]
		}
	}
	parameterEnd := strings.IndexByte(tokenText, '&')
	if parameterEnd >= 0 {
		tokenText = tokenText[:parameterEnd]
	}
	decodedTokenText, err := decodeSecurIDPercentEncoding(strings.TrimSpace(tokenText))
	if err != nil {
		return securIDToken{}, err
	}
	if decodedTokenText == "" {
		return securIDToken{}, E.New("RSA SecurID token string is empty")
	}
	smartphone := strings.HasPrefix(lowerSecret, "com.rsa.securid.iphone://ctf") ||
		strings.HasPrefix(lowerSecret, "com.rsa.securid://ctf") ||
		strings.HasPrefix(lowerSecret, "http://127.0.0.1/securid/ctf")
	if decodedTokenText[0] == '1' || decodedTokenText[0] == '2' {
		return parseSecurIDV2Token(decodedTokenText, smartphone)
	}
	if decodedTokenText[0] == 'A' || decodedTokenText[0] == 'B' {
		return parseSecurIDV3Token(decodedTokenText)
	}
	return securIDToken{}, E.New("unsupported RSA SecurID token format; supported CTF versions are 1, 2, 3, and 4")
}

func parseSecurIDV2Token(tokenText string, smartphone bool) (securIDToken, error) {
	numericToken := make([]byte, 0, len(tokenText))
	for i := 0; i < len(tokenText); i++ {
		character := tokenText[i]
		if character >= '0' && character <= '9' {
			numericToken = append(numericToken, character)
			continue
		}
		if character == '-' {
			continue
		}
		break
	}
	if len(numericToken) < 81 || len(numericToken) > 85 {
		return securIDToken{}, E.New("invalid RSA SecurID version 1/2 token length: ", len(numericToken))
	}
	providedChecksumBits, err := decodeSecurIDNumericBits(numericToken[len(numericToken)-5:], 15)
	if err != nil {
		return securIDToken{}, err
	}
	providedChecksum := readSecurIDBits(providedChecksumBits, 0, 15)
	computedChecksum, err := computeSecurIDShortMAC(numericToken[:len(numericToken)-5])
	if err != nil {
		return securIDToken{}, err
	}
	if uint16(providedChecksum) != computedChecksum {
		return securIDToken{}, E.New("RSA SecurID version 1/2 token checksum verification failed")
	}
	payloadBits, err := decodeSecurIDNumericBits(numericToken[13:13+63], 189)
	if err != nil {
		return securIDToken{}, err
	}
	token := securIDToken{
		version:           int(numericToken[0] - '0'),
		serial:            string(numericToken[1:13]),
		flags:             uint16(readSecurIDBits(payloadBits, 128, 16)),
		smartphone:        smartphone,
		decryptedSeedHash: uint16(readSecurIDBits(payloadBits, 159, 15)),
		deviceIDHash:      uint16(readSecurIDBits(payloadBits, 174, 15)),
	}
	copy(token.encryptedSeed[:], payloadBits[:aes.BlockSize])
	return token, nil
}

func parseSecurIDV3Token(tokenText string) (securIDToken, error) {
	decodedToken, err := base64.StdEncoding.DecodeString(tokenText)
	if err != nil {
		decodedToken, err = base64.RawStdEncoding.DecodeString(tokenText)
	}
	if err != nil {
		return securIDToken{}, E.Cause(err, "decode RSA SecurID version 3/4 token")
	}
	if len(decodedToken) != 291 {
		return securIDToken{}, E.New("invalid RSA SecurID version 3/4 token length: ", len(decodedToken))
	}
	if decodedToken[0] != 3 && decodedToken[0] != 4 {
		return securIDToken{}, E.New("unsupported RSA SecurID CTF version: ", decodedToken[0])
	}
	v3Token := &securIDV3Token{
		version:        decodedToken[0],
		passwordLocked: decodedToken[1],
		deviceLocked:   decodedToken[2],
	}
	copy(v3Token.nonceDeviceHash[:], decodedToken[3:35])
	copy(v3Token.nonceDevicePasswordHash[:], decodedToken[35:67])
	copy(v3Token.nonce[:], decodedToken[67:83])
	copy(v3Token.encryptedPayload[:], decodedToken[83:259])
	copy(v3Token.messageAuthenticationCode[:], decodedToken[259:291])
	flags := uint16(0)
	if v3Token.passwordLocked != 0 {
		flags |= securIDPasswordProtection
	}
	if v3Token.deviceLocked != 0 {
		flags |= securIDDeviceProtection
	}
	return securIDToken{
		version: int(v3Token.version),
		flags:   flags,
		v3:      v3Token,
	}, nil
}

func decryptSecurIDToken(token *securIDToken, password string, deviceID string) error {
	if token.flags&securIDPasswordProtection != 0 {
		if password == "" {
			return E.New("RSA SecurID token requires a password")
		}
		if len(password) > 40 {
			return E.New("RSA SecurID token password exceeds 40 bytes")
		}
	} else {
		password = ""
	}
	if token.flags&securIDDeviceProtection != 0 {
		if deviceID == "" {
			return E.New("RSA SecurID token requires a device ID")
		}
	} else {
		deviceID = ""
	}
	if token.v3 != nil {
		return decryptSecurIDV3Token(token, password, deviceID)
	}
	return decryptSecurIDV2Token(token, password, deviceID)
}

func decryptSecurIDV2Token(token *securIDToken, password string, deviceID string) error {
	keyHash, computedDeviceIDHash, err := generateSecurIDV2KeyHash(*token, password, deviceID)
	if err != nil {
		return err
	}
	if token.flags&securIDDeviceProtection != 0 && computedDeviceIDHash != token.deviceIDHash {
		return E.New("RSA SecurID token device ID verification failed")
	}
	block, err := aes.NewCipher(keyHash[:])
	if err != nil {
		return E.Cause(err, "initialize RSA SecurID seed cipher")
	}
	block.Decrypt(token.decryptedSeed[:], token.encryptedSeed[:])
	computedSeedHash, err := computeSecurIDShortMAC(token.decryptedSeed[:])
	if err != nil {
		return err
	}
	if computedSeedHash != token.decryptedSeedHash {
		return E.New("RSA SecurID token password or device ID verification failed")
	}
	return nil
}

func generateSecurIDV2KeyHash(token securIDToken, password string, deviceID string) ([aes.BlockSize]byte, uint16, error) {
	deviceIDLength := 32
	if token.smartphone {
		deviceIDLength = 40
	}
	keyMaterial := make([]byte, 40+40+6+1)
	position := copy(keyMaterial, password)
	deviceIDStart := position
	consumedDeviceIDCharacters := 0
	for i := 0; i < len(deviceID); i++ {
		consumedDeviceIDCharacters++
		if consumedDeviceIDCharacters > deviceIDLength {
			break
		}
		character := deviceID[i]
		if token.version == 1 && character >= '0' && character <= '9' {
			continue
		}
		if token.version >= 2 && !isASCIIHexDigit(character) {
			continue
		}
		keyMaterial[position] = toASCIIUpper(character)
		position++
	}
	computedDeviceIDHash, err := computeSecurIDShortMAC(keyMaterial[deviceIDStart : deviceIDStart+deviceIDLength])
	if err != nil {
		return [aes.BlockSize]byte{}, 0, err
	}
	copy(keyMaterial[position:], securIDV2Magic[:])
	keyHash, err := computeSecurIDMAC(keyMaterial[:position+len(securIDV2Magic)])
	if err != nil {
		return [aes.BlockSize]byte{}, 0, err
	}
	return keyHash, computedDeviceIDHash, nil
}

func decryptSecurIDV3Token(token *securIDToken, password string, rawDeviceID string) error {
	v3Token := token.v3
	deviceID := scrubSecurIDV3DeviceID(rawDeviceID)
	computedDeviceHash := computeSecurIDV3Hash("", deviceID, v3Token.nonce)
	if subtle.ConstantTimeCompare(computedDeviceHash[:], v3Token.nonceDeviceHash[:]) != 1 {
		return E.New("RSA SecurID token device ID verification failed")
	}
	computedDevicePasswordHash := computeSecurIDV3Hash(password, deviceID, v3Token.nonce)
	if subtle.ConstantTimeCompare(computedDevicePasswordHash[:], v3Token.nonceDevicePasswordHash[:]) != 1 {
		return E.New("RSA SecurID token password verification failed")
	}
	messageAuthenticationKey := deriveSecurIDV3Key(password, deviceID, v3Token.nonce, securIDV3Key0, v3Token.version)
	messageAuthenticationCode := hmac.New(sha256.New, messageAuthenticationKey)
	serializedToken := serializeSecurIDV3Token(*v3Token)
	_, err := messageAuthenticationCode.Write(serializedToken[:259])
	if err != nil {
		return E.Cause(err, "compute RSA SecurID version 3/4 token HMAC")
	}
	computedMessageAuthenticationCode := messageAuthenticationCode.Sum(nil)
	if subtle.ConstantTimeCompare(computedMessageAuthenticationCode, v3Token.messageAuthenticationCode[:]) != 1 {
		return E.New("RSA SecurID version 3/4 token integrity verification failed")
	}
	decryptionKey := deriveSecurIDV3Key(password, deviceID, v3Token.nonce, securIDV3Key1, v3Token.version)
	block, err := aes.NewCipher(decryptionKey)
	if err != nil {
		return E.Cause(err, "initialize RSA SecurID version 3/4 payload cipher")
	}
	payload := make([]byte, len(v3Token.encryptedPayload))
	decrypter := cipher.NewCBCDecrypter(block, v3Token.nonce[:])
	decrypter.CryptBlocks(payload, v3Token.encryptedPayload[:])
	if payload[12] != 0 || strings.IndexByte(string(payload[:12]), 0) >= 0 || !isASCIIDigits(payload[:12]) {
		return E.New("invalid RSA SecurID version 3/4 serial number")
	}
	if payload[35] < 1 || payload[35] > 8 {
		return E.New("invalid RSA SecurID version 3/4 tokencode digit count: ", payload[35])
	}
	token.serial = string(payload[:12])
	copy(token.decryptedSeed[:], payload[16:32])
	token.flags |= securIDTimeDerivedSeeds | securID128Bit
	token.flags |= uint16(payload[35]-1) << securIDDigitShift
	if payload[36] != securIDV3AddPINOff {
		token.flags |= uint16(2 << securIDPINModeShift)
	}
	if payload[37] == 60 {
		token.flags |= 1
	}
	return nil
}

func computeSecurIDV3Hash(password string, deviceID string, nonce [aes.BlockSize]byte) [sha256.Size]byte {
	passwordLength := len(password)
	input := make([]byte, aes.BlockSize+48+passwordLength)
	copy(input, nonce[:])
	copy(input[aes.BlockSize:aes.BlockSize+48], deviceID)
	copy(input[aes.BlockSize+48:], password)
	return sha256.Sum256(input)
}

func deriveSecurIDV3Key(password string, deviceID string, nonce [aes.BlockSize]byte, keyID [aes.BlockSize]byte, version byte) []byte {
	input := make([]byte, 48+aes.BlockSize+aes.BlockSize+len(password))
	copy(input, password)
	copy(input[len(password):len(password)+48], deviceID)
	copy(input[len(password)+48:len(password)+48+aes.BlockSize], keyID[:])
	copy(input[len(password)+48+aes.BlockSize:], nonce[:])
	if version == 3 {
		halvedInput := make([]byte, len(input)/2)
		for i := 1; i < len(input); i += 2 {
			halvedInput[i/2] = input[i]
		}
		input = halvedInput
	}
	return pbkdf2.Key(input, nonce[:], 1000, sha256.Size, sha256.New)
}

func serializeSecurIDV3Token(token securIDV3Token) [291]byte {
	serialized := [291]byte{}
	serialized[0] = token.version
	serialized[1] = token.passwordLocked
	serialized[2] = token.deviceLocked
	copy(serialized[3:35], token.nonceDeviceHash[:])
	copy(serialized[35:67], token.nonceDevicePasswordHash[:])
	copy(serialized[67:83], token.nonce[:])
	copy(serialized[83:259], token.encryptedPayload[:])
	copy(serialized[259:291], token.messageAuthenticationCode[:])
	return serialized
}

func scrubSecurIDV3DeviceID(deviceID string) string {
	scrubbedDeviceID := make([]byte, 0, 48)
	for i := 0; i < len(deviceID) && len(scrubbedDeviceID) < 48; i++ {
		character := deviceID[i]
		if (character >= '0' && character <= '9') || (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') {
			scrubbedDeviceID = append(scrubbedDeviceID, toASCIIUpper(character))
		}
	}
	return string(scrubbedDeviceID)
}

func computeSecurIDTokenCode(token securIDToken, pin string, applyPIN bool, now time.Time) (string, error) {
	utcTime := now.UTC()
	bcdTime := [8]byte{}
	writeSecurIDBCD(bcdTime[0:2], utcTime.Year())
	writeSecurIDBCD(bcdTime[2:3], int(utcTime.Month()))
	writeSecurIDBCD(bcdTime[3:4], utcTime.Day())
	writeSecurIDBCD(bcdTime[4:5], utcTime.Hour())
	interval := 60
	if token.flags&securIDIntervalMask == 0 {
		interval = 30
	}
	minuteMask := 3
	if interval == 30 {
		minuteMask = 1
	}
	writeSecurIDBCD(bcdTime[5:6], utcTime.Minute()&^minuteMask)
	key0 := buildSecurIDTimeKey(bcdTime[:2], token.serial)
	err := encryptSecurIDBlock(token.decryptedSeed[:], key0[:], key0[:])
	if err != nil {
		return "", err
	}
	key1 := buildSecurIDTimeKey(bcdTime[:3], token.serial)
	err = encryptSecurIDBlock(key0[:], key1[:], key1[:])
	if err != nil {
		return "", err
	}
	key0 = buildSecurIDTimeKey(bcdTime[:4], token.serial)
	err = encryptSecurIDBlock(key1[:], key0[:], key0[:])
	if err != nil {
		return "", err
	}
	key1 = buildSecurIDTimeKey(bcdTime[:5], token.serial)
	err = encryptSecurIDBlock(key0[:], key1[:], key1[:])
	if err != nil {
		return "", err
	}
	key0 = buildSecurIDTimeKey(bcdTime[:8], token.serial)
	err = encryptSecurIDBlock(key1[:], key0[:], key0[:])
	if err != nil {
		return "", err
	}
	offset := (utcTime.Minute() & 3) << 2
	if interval == 30 {
		offset = ((utcTime.Minute() & 1) << 3) | boolToInt(utcTime.Second() >= 30)<<2
	}
	codeValue := uint32(key0[offset])<<24 |
		uint32(key0[offset+1])<<16 |
		uint32(key0[offset+2])<<8 |
		uint32(key0[offset+3])
	digits := int((token.flags&securIDDigitMask)>>securIDDigitShift) + 1
	code := make([]byte, digits)
	for i := digits - 1; i >= 0; i-- {
		digit := byte(codeValue % 10)
		codeValue /= 10
		pinOffset := digits - 1 - i
		if applyPIN && pinOffset < len(pin) {
			digit += pin[len(pin)-1-pinOffset] - '0'
		}
		code[i] = digit%10 + '0'
	}
	return string(code), nil
}

func buildSecurIDTimeKey(bcdTime []byte, serial string) [aes.BlockSize]byte {
	key := [aes.BlockSize]byte{}
	for i := range 8 {
		key[i] = 0xaa
	}
	copy(key[:8], bcdTime)
	for i := 12; i < aes.BlockSize; i++ {
		key[i] = 0xbb
	}
	for i := 4; i < 12; i += 2 {
		key[8+(i-4)/2] = (serial[i]-'0')<<4 | (serial[i+1] - '0')
	}
	return key
}

func writeSecurIDBCD(destination []byte, value int) {
	for index := range slices.Backward(destination) {
		destination[index] = byte(value % 10)
		value /= 10
		destination[index] |= byte(value%10) << 4
		value /= 10
	}
}

func computeSecurIDShortMAC(input []byte) (uint16, error) {
	messageAuthenticationCode, err := computeSecurIDMAC(input)
	if err != nil {
		return 0, err
	}
	return uint16(messageAuthenticationCode[0])<<7 | uint16(messageAuthenticationCode[1])>>1, nil
}

func computeSecurIDMAC(input []byte) ([aes.BlockSize]byte, error) {
	work := [aes.BlockSize]byte{}
	for i := range work {
		work[i] = 0xff
	}
	padding := [aes.BlockSize]byte{}
	bitLength := len(input) * 8
	for i := aes.BlockSize - 1; bitLength > 0; i-- {
		padding[i] = byte(bitLength)
		bitLength >>= 8
	}
	remaining := input
	odd := false
	for len(remaining) > aes.BlockSize {
		err := encryptSecurIDThenXOR(remaining[:aes.BlockSize], work[:])
		if err != nil {
			return [aes.BlockSize]byte{}, err
		}
		remaining = remaining[aes.BlockSize:]
		odd = !odd
	}
	lastBlock := [aes.BlockSize]byte{}
	copy(lastBlock[:], remaining)
	err := encryptSecurIDThenXOR(lastBlock[:], work[:])
	if err != nil {
		return [aes.BlockSize]byte{}, err
	}
	if odd {
		zero := [aes.BlockSize]byte{}
		err = encryptSecurIDThenXOR(zero[:], work[:])
		if err != nil {
			return [aes.BlockSize]byte{}, err
		}
	}
	err = encryptSecurIDThenXOR(padding[:], work[:])
	if err != nil {
		return [aes.BlockSize]byte{}, err
	}
	result := work
	err = encryptSecurIDThenXOR(work[:], result[:])
	if err != nil {
		return [aes.BlockSize]byte{}, err
	}
	return result, nil
}

func encryptSecurIDThenXOR(key []byte, work []byte) error {
	encrypted := [aes.BlockSize]byte{}
	err := encryptSecurIDBlock(key, work, encrypted[:])
	if err != nil {
		return err
	}
	for i := range work {
		work[i] ^= encrypted[i]
	}
	return nil
}

func encryptSecurIDBlock(key []byte, input []byte, output []byte) error {
	block, err := aes.NewCipher(key)
	if err != nil {
		return E.Cause(err, "initialize RSA SecurID AES cipher")
	}
	block.Encrypt(output, input)
	return nil
}

func decodeSecurIDNumericBits(input []byte, bitCount int) ([]byte, error) {
	if len(input)*3 < bitCount {
		return nil, E.New("RSA SecurID numeric token does not contain ", bitCount, " bits")
	}
	output := make([]byte, (bitCount+7)/8)
	for bitPosition := range bitCount {
		digit := input[bitPosition/3]
		if digit < '0' || digit > '9' {
			return nil, E.New("invalid character in RSA SecurID numeric token")
		}
		value := (digit - '0') & 0x07
		valueBit := 2 - bitPosition%3
		if value&(1<<valueBit) != 0 {
			output[bitPosition/8] |= 1 << (7 - bitPosition%8)
		}
	}
	return output, nil
}

func readSecurIDBits(input []byte, start int, bitCount int) uint32 {
	value := uint32(0)
	for bitPosition := start; bitPosition < start+bitCount; bitPosition++ {
		value <<= 1
		if input[bitPosition/8]&(1<<(7-bitPosition%8)) != 0 {
			value |= 1
		}
	}
	return value
}

func decodeSecurIDPercentEncoding(input string) (string, error) {
	decoded := make([]byte, 0, len(input))
	for i := 0; i < len(input); i++ {
		if input[i] != '%' {
			decoded = append(decoded, input[i])
			continue
		}
		if i+2 >= len(input) || !isASCIIHexDigit(input[i+1]) || !isASCIIHexDigit(input[i+2]) {
			return "", E.New("invalid percent encoding in RSA SecurID token")
		}
		decoded = append(decoded, hexByte(input[i+1], input[i+2]))
		i += 2
	}
	return string(decoded), nil
}

func indexFold(value string, substring string) int {
	return strings.Index(strings.ToLower(value), strings.ToLower(substring))
}

func isASCIIHexDigit(character byte) bool {
	return (character >= '0' && character <= '9') ||
		(character >= 'A' && character <= 'F') ||
		(character >= 'a' && character <= 'f')
}

func isASCIIDigits(value []byte) bool {
	for _, character := range value {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

func toASCIIUpper(character byte) byte {
	if character >= 'a' && character <= 'z' {
		return character - ('a' - 'A')
	}
	return character
}

func hexByte(high byte, low byte) byte {
	return hexNibble(high)<<4 | hexNibble(low)
}

func hexNibble(character byte) byte {
	if character >= '0' && character <= '9' {
		return character - '0'
	}
	return toASCIIUpper(character) - 'A' + 10
}

func validateSecurIDPIN(pin string) error {
	if len(pin) < 4 || len(pin) > 8 {
		return E.New("RSA SecurID token PIN must contain 4 to 8 digits")
	}
	for i := 0; i < len(pin); i++ {
		if pin[i] < '0' || pin[i] > '9' {
			return E.New("RSA SecurID token PIN must contain only digits")
		}
	}
	return nil
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
