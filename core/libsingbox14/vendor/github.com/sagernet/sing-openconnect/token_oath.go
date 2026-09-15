package openconnect

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base32"
	"encoding/binary"
	"hash"
	"math"
	"net/url"
	"strconv"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	oathAlgorithmSHA1   = "SHA1"
	oathAlgorithmSHA256 = "SHA256"
	oathAlgorithmSHA512 = "SHA512"
)

type oathConfiguration struct {
	secret     []byte
	algorithm  string
	digits     int
	period     uint64
	counter    uint64
	hasCounter bool
}

type softwareTokenGenerator struct {
	options       *TokenOptions
	attempts      int
	tokenUnixTime int64
	period        uint64
}

func newSoftwareTokenGenerator(options *TokenOptions) *softwareTokenGenerator {
	if options == nil || options.Mode == TokenModeOIDC {
		return nil
	}
	return &softwareTokenGenerator{options: options}
}

func (g *softwareTokenGenerator) CanGenerate(message string) bool {
	if g == nil || g.options == nil {
		return false
	}
	return g.canGenerate(message)
}

func (g *softwareTokenGenerator) Generate(ctx context.Context, message string) (string, error) {
	if g == nil || g.options == nil {
		return "", E.New("software token is not configured")
	}
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	default:
	}
	if !g.canGenerate(message) {
		return "", E.New("automatic software token attempt limit reached")
	}
	switch g.options.Mode {
	case TokenModeTOTP:
		configuration, err := parseOATHConfiguration(g.options.Secret, TokenModeTOTP)
		if err != nil {
			return "", err
		}
		generationTime, err := g.generationTime(configuration.period)
		if err != nil {
			return "", err
		}
		code, err := generateOATHCode(configuration, uint64(generationTime)/configuration.period)
		if err != nil {
			return "", err
		}
		g.recordGeneration(generationTime, configuration.period)
		return code, nil
	case TokenModeHOTP:
		code, err := generateHOTPCodeAndPersist(ctx, g.options)
		if err != nil {
			return "", err
		}
		g.attempts++
		return code, nil
	case TokenModeSToken:
		generationTime, err := g.generationTime(g.period)
		if err != nil {
			return "", err
		}
		code, period, err := generateSTokenCode(g.options, time.Unix(generationTime, 0))
		if err != nil {
			return "", err
		}
		g.recordGeneration(generationTime, period)
		return code, nil
	default:
		return "", E.New("unsupported openconnect software token mode: ", g.options.Mode)
	}
}

func (g *softwareTokenGenerator) canGenerate(message string) bool {
	if g.attempts == 0 {
		return true
	}
	if g.attempts != 1 {
		return false
	}
	switch g.options.Mode {
	case TokenModeTOTP, TokenModeHOTP:
		return true
	case TokenModeSToken:
		return strings.Contains(strings.ToLower(message), "next tokencode")
	default:
		return false
	}
}

func (g *softwareTokenGenerator) generationTime(period uint64) (int64, error) {
	if g.attempts == 0 {
		return time.Now().Unix(), nil
	}
	if period > math.MaxInt64 || g.tokenUnixTime > math.MaxInt64-int64(period) {
		return 0, E.New("software token period exceeds the supported time range")
	}
	return g.tokenUnixTime + int64(period), nil
}

func (g *softwareTokenGenerator) recordGeneration(generationTime int64, period uint64) {
	if g.attempts == 0 {
		g.tokenUnixTime = generationTime
		g.period = period
	}
	g.attempts++
}

func parseOATHConfiguration(secret string, mode string) (oathConfiguration, error) {
	trimmedSecret := strings.TrimSpace(secret)
	if strings.HasPrefix(strings.ToLower(trimmedSecret), "otpauth://") {
		return parseOTPAuthConfiguration(trimmedSecret, mode)
	}
	decodedSecret, err := decodeOATHBase32Secret(trimmedSecret)
	if err != nil {
		return oathConfiguration{}, err
	}
	return oathConfiguration{
		secret:    decodedSecret,
		algorithm: oathAlgorithmSHA1,
		digits:    6,
		period:    30,
	}, nil
}

func parseOTPAuthConfiguration(secret string, mode string) (oathConfiguration, error) {
	parsedURI, err := url.Parse(secret)
	if err != nil {
		return oathConfiguration{}, E.Cause(err, "parse otpauth software token URI")
	}
	if !strings.EqualFold(parsedURI.Scheme, "otpauth") {
		return oathConfiguration{}, E.New("invalid software token URI scheme: ", parsedURI.Scheme)
	}
	uriMode := strings.ToLower(parsedURI.Host)
	if uriMode != mode {
		return oathConfiguration{}, E.New("otpauth software token type ", uriMode, " does not match configured mode ", mode)
	}
	query, err := url.ParseQuery(parsedURI.RawQuery)
	if err != nil {
		return oathConfiguration{}, E.Cause(err, "parse otpauth software token parameters")
	}
	decodedSecret, err := decodeOATHBase32Secret(oathQueryValue(query, "secret"))
	if err != nil {
		return oathConfiguration{}, err
	}
	configuration := oathConfiguration{
		secret:    decodedSecret,
		algorithm: oathAlgorithmSHA1,
		digits:    6,
		period:    30,
	}
	algorithm := oathQueryValue(query, "algorithm")
	if algorithm != "" {
		switch {
		case strings.EqualFold(algorithm, oathAlgorithmSHA1):
			configuration.algorithm = oathAlgorithmSHA1
		case strings.EqualFold(algorithm, oathAlgorithmSHA256):
			configuration.algorithm = oathAlgorithmSHA256
		case strings.EqualFold(algorithm, oathAlgorithmSHA512):
			configuration.algorithm = oathAlgorithmSHA512
		default:
			return oathConfiguration{}, E.New("unsupported otpauth HMAC algorithm: ", algorithm)
		}
	}
	digits := oathQueryValue(query, "digits")
	if digits != "" {
		parsedDigits, parseErr := strconv.Atoi(digits)
		if parseErr != nil {
			return oathConfiguration{}, E.Cause(parseErr, "parse otpauth token digits")
		}
		if parsedDigits != 6 && parsedDigits != 8 {
			return oathConfiguration{}, E.New("unsupported otpauth token digit count: ", parsedDigits)
		}
		configuration.digits = parsedDigits
	}
	period := oathQueryValue(query, "period")
	if period != "" {
		parsedPeriod, parseErr := strconv.ParseUint(period, 10, 64)
		if parseErr != nil {
			return oathConfiguration{}, E.Cause(parseErr, "parse otpauth token period")
		}
		if parsedPeriod == 0 {
			return oathConfiguration{}, E.New("otpauth token period must be positive")
		}
		if parsedPeriod > math.MaxInt64 {
			return oathConfiguration{}, E.New("otpauth token period exceeds the supported time range")
		}
		configuration.period = parsedPeriod
	}
	counter := oathQueryValue(query, "counter")
	if counter != "" {
		parsedCounter, parseErr := strconv.ParseUint(counter, 10, 64)
		if parseErr != nil {
			return oathConfiguration{}, E.Cause(parseErr, "parse otpauth token counter")
		}
		configuration.counter = parsedCounter
		configuration.hasCounter = true
	}
	return configuration, nil
}

func oathQueryValue(query url.Values, name string) string {
	for queryName, values := range query {
		if strings.EqualFold(queryName, name) && len(values) > 0 {
			return values[0]
		}
	}
	return ""
}

func decodeOATHBase32Secret(secret string) ([]byte, error) {
	trimmedSecret := strings.TrimSpace(secret)
	if len(trimmedSecret) >= len("base32:") && strings.EqualFold(trimmedSecret[:len("base32:")], "base32:") {
		trimmedSecret = trimmedSecret[len("base32:"):]
	}
	trimmedSecret = strings.ToUpper(strings.TrimSpace(trimmedSecret))
	trimmedSecret = strings.TrimRight(trimmedSecret, "=")
	if trimmedSecret == "" {
		return nil, E.New("OATH software token requires a base32 secret")
	}
	decodedSecret, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(trimmedSecret)
	if err != nil {
		return nil, E.Cause(err, "decode openconnect OATH base32 secret")
	}
	if len(decodedSecret) == 0 {
		return nil, E.New("OATH software token secret is empty")
	}
	return decodedSecret, nil
}

func generateHOTPCodeAndPersist(ctx context.Context, options *TokenOptions) (string, error) {
	if options.UpdateCounter == nil {
		return "", E.New("HOTP token requires an update counter callback")
	}
	configuration, err := parseOATHConfiguration(options.Secret, TokenModeHOTP)
	if err != nil {
		return "", err
	}
	counter := options.Counter
	if counter == 0 && configuration.hasCounter {
		counter = configuration.counter
	}
	code, err := generateOATHCode(configuration, counter)
	if err != nil {
		return "", err
	}
	if counter == math.MaxUint64 {
		return "", E.New("HOTP counter is exhausted")
	}
	nextCounter := counter + 1
	err = options.UpdateCounter(ctx, nextCounter)
	if err != nil {
		return "", E.Cause(err, "persist openconnect HOTP counter ", nextCounter)
	}
	options.Counter = nextCounter
	return code, nil
}

func generateOATHCode(configuration oathConfiguration, counter uint64) (string, error) {
	var hashFunction func() hash.Hash
	switch configuration.algorithm {
	case oathAlgorithmSHA1:
		hashFunction = sha1.New
	case oathAlgorithmSHA256:
		hashFunction = sha256.New
	case oathAlgorithmSHA512:
		hashFunction = sha512.New
	default:
		return "", E.New("unsupported OATH HMAC algorithm: ", configuration.algorithm)
	}
	message := [8]byte{}
	binary.BigEndian.PutUint64(message[:], counter)
	messageAuthenticationCode := hmac.New(hashFunction, configuration.secret)
	_, err := messageAuthenticationCode.Write(message[:])
	if err != nil {
		return "", E.Cause(err, "compute OATH HMAC")
	}
	digest := messageAuthenticationCode.Sum(nil)
	offset := int(digest[len(digest)-1] & 0x0f)
	binaryCode := binary.BigEndian.Uint32(digest[offset:offset+4]) & 0x7fffffff
	modulus := uint32(1)
	for i := 0; i < configuration.digits; i++ {
		modulus *= 10
	}
	code := strconv.FormatUint(uint64(binaryCode%modulus), 10)
	return strings.Repeat("0", configuration.digits-len(code)) + code, nil
}
