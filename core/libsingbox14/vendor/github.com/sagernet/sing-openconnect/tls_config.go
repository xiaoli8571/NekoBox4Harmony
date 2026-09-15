package openconnect

import (
	"crypto"
	"crypto/md5" //nolint:gosec // OpenConnect's insecure compatibility mode retains MD5-signed server certificate support.
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"slices"
	"strings"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"

	ctx509 "github.com/google/certificate-transparency-go/x509"
	"github.com/youmark/pkcs8"
)

type mcaIdentity struct {
	Certificate [][]byte
	Signer      crypto.Signer
}

type peerFingerprint struct {
	algorithm     string
	encoded       string
	caseSensitive bool
}

type legacyTLSRoots struct {
	pool         *ctx509.CertPool
	certificates []*x509.Certificate
}

func buildClientTLS(options ClientOptions) (*tls.Config, *mcaIdentity, error) {
	tlsOptions := options.TLSConfig
	for name, material := range map[string]Material{
		"certificate authority": tlsOptions.CertificateAuthority,
		"client certificate":    tlsOptions.Certificate,
		"client key":            tlsOptions.Key,
		"MCA certificate":       tlsOptions.MCACertificate,
		"MCA key":               tlsOptions.MCAKey,
	} {
		err := material.Validate(name)
		if err != nil {
			return nil, nil, err
		}
	}
	configuration := &tls.Config{}
	if tlsOptions.Config != nil {
		configuration = cloneTLSConfig(tlsOptions.Config)
	}
	var legacyRootCAs *legacyTLSRoots
	if options.AllowInsecureCrypto {
		legacyRootCAs = &legacyTLSRoots{}
		if configuration.RootCAs == nil && !tlsOptions.SystemTrustDisabled {
			systemLegacyRootCAs, systemLegacyRootErr := ctx509.SystemCertPool()
			if systemLegacyRootErr == nil {
				legacyRootCAs.pool = systemLegacyRootCAs
			}
		}
		if legacyRootCAs.pool == nil {
			legacyRootCAs.pool = ctx509.NewCertPool()
		}
	}
	configuredCipherSuites := len(configuration.CipherSuites) > 0
	if tlsOptions.ServerName != "" {
		configuration.ServerName = tlsOptions.ServerName
	}
	if tlsOptions.SystemTrustDisabled && configuration.RootCAs == nil {
		configuration.RootCAs = x509.NewCertPool()
	}
	if tlsOptions.CertificateAuthority.IsSet() {
		certificateAuthority, err := loadMaterial(tlsOptions.CertificateAuthority)
		if err != nil {
			return nil, nil, E.Cause(err, "load TLS certificate authority")
		}
		rootCAs := configuration.RootCAs
		if rootCAs == nil && !tlsOptions.SystemTrustDisabled {
			rootCAs, err = x509.SystemCertPool()
			if err != nil {
				return nil, nil, E.Cause(err, "load system certificate authorities")
			}
		} else if rootCAs != nil {
			rootCAs = rootCAs.Clone()
		}
		if rootCAs == nil {
			rootCAs = x509.NewCertPool()
		}
		if !rootCAs.AppendCertsFromPEM(certificateAuthority) {
			return nil, nil, E.Extend(ErrInvalidTLSMaterial, "certificate authority")
		}
		if legacyRootCAs != nil && !legacyRootCAs.pool.AppendCertsFromPEM(certificateAuthority) {
			return nil, nil, E.Extend(ErrInvalidTLSMaterial, "certificate authority")
		}
		if legacyRootCAs != nil {
			legacyRootCAs.certificates = append(legacyRootCAs.certificates, parseTLSRootCertificates(certificateAuthority)...)
		}
		configuration.RootCAs = rootCAs
	}
	clientCertificate, err := loadOptionalCertificate(tlsOptions.Certificate, tlsOptions.Key, tlsOptions.KeyPassword, "client")
	if err != nil {
		return nil, nil, err
	}
	if clientCertificate != nil {
		configuration.Certificates = append(configuration.Certificates, *clientCertificate)
	}
	mcaCertificate, err := loadOptionalCertificate(tlsOptions.MCACertificate, tlsOptions.MCAKey, tlsOptions.MCAKeyPassword, "MCA")
	if err != nil {
		return nil, nil, err
	}
	var identity *mcaIdentity
	if mcaCertificate != nil {
		signer, isSigner := mcaCertificate.PrivateKey.(crypto.Signer)
		if !isSigner {
			return nil, nil, E.Extend(ErrInvalidTLSMaterial, "MCA private key is not a signer")
		}
		identity = &mcaIdentity{
			Certificate: cloneByteSlices(mcaCertificate.Certificate),
			Signer:      signer,
		}
	}
	certificateExpiryWarning := tlsOptions.CertificateExpiryWarning
	if certificateExpiryWarning == 0 && !tlsOptions.CertificateExpiryWarningDisabled {
		certificateExpiryWarning = defaultCertificateExpiryWarning
	}
	for i := range configuration.Certificates {
		warnTLSClientCertificateExpiry(options, &configuration.Certificates[i], "client certificate", certificateExpiryWarning, tlsOptions.CertificateExpiryWarningDisabled)
	}
	if mcaCertificate != nil {
		warnTLSClientCertificateExpiry(options, mcaCertificate, "MCA certificate", certificateExpiryWarning, tlsOptions.CertificateExpiryWarningDisabled)
	}
	if options.AllowInsecureCrypto {
		if configuration.MinVersion == 0 {
			configuration.MinVersion = tls.VersionTLS10
		}
	} else if configuration.MinVersion != 0 && configuration.MinVersion < tls.VersionTLS12 ||
		configuration.MaxVersion != 0 && configuration.MaxVersion < tls.VersionTLS12 {
		return nil, nil, E.Extend(ErrDeprecatedCryptoDisabled, "TLS versions below 1.2")
	}
	if options.AllowInsecureCrypto {
		if len(configuration.CipherSuites) == 0 {
			configuration.CipherSuites = openConnectCipherSuites(true, options.PFS)
		}
	} else {
		if slices.ContainsFunc(configuration.CipherSuites, isDeprecatedTLSCipherSuite) {
			return nil, nil, ErrDeprecatedCryptoDisabled
		}
		if len(configuration.CipherSuites) == 0 {
			configuration.CipherSuites = openConnectCipherSuites(false, options.PFS)
		}
	}
	if options.PFS && len(configuration.CipherSuites) > 0 {
		configuration.CipherSuites = filterPFSCipherSuites(configuration.CipherSuites)
		if configuredCipherSuites && len(configuration.CipherSuites) == 0 {
			return nil, nil, E.New("PFS excludes every configured TLS cipher suite")
		}
	}
	fingerprints, err := parsePeerFingerprints(tlsOptions.PeerFingerprints)
	if err != nil {
		return nil, nil, err
	}
	if len(fingerprints) > 0 || options.AllowInsecureCrypto && !configuration.InsecureSkipVerify {
		installPeerVerification(configuration, fingerprints, options.AllowInsecureCrypto, legacyRootCAs)
	}
	return configuration, identity, nil
}

func parseTLSRootCertificates(content []byte) []*x509.Certificate {
	var certificates []*x509.Certificate
	for len(content) > 0 {
		block, remaining := pem.Decode(content)
		if block == nil {
			break
		}
		content = remaining
		if block.Type != "CERTIFICATE" || len(block.Headers) != 0 {
			continue
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			continue
		}
		certificates = append(certificates, certificate)
	}
	return certificates
}

func warnTLSClientCertificateExpiry(options ClientOptions, certificate *tls.Certificate, name string, warning time.Duration, warningDisabled bool) {
	if options.Logger == nil || certificate == nil || len(certificate.Certificate) == 0 {
		return
	}
	leaf := certificate.Leaf
	if leaf == nil {
		var err error
		leaf, err = x509.ParseCertificate(certificate.Certificate[0])
		if err != nil {
			options.Logger.WarnContext(options.Context, "Unable to inspect ", name, " expiry: ", err)
			return
		}
	}
	currentTime := time.Now()
	if options.TLSConfig.Config != nil && options.TLSConfig.Config.Time != nil {
		currentTime = options.TLSConfig.Config.Time()
	}
	if currentTime.After(leaf.NotAfter) {
		options.Logger.WarnContext(options.Context, name, " expired at ", leaf.NotAfter.UTC().Format(time.RFC3339))
	} else if !warningDisabled && leaf.NotAfter.Before(currentTime.Add(warning)) {
		options.Logger.WarnContext(options.Context, name, " expires soon at ", leaf.NotAfter.UTC().Format(time.RFC3339))
	}
}

func parsePeerFingerprints(values []string) ([]peerFingerprint, error) {
	result := make([]peerFingerprint, 0, len(values))
	for _, value := range values {
		fingerprint, err := parsePeerFingerprint(value)
		if err != nil {
			return nil, err
		}
		result = append(result, fingerprint)
	}
	return result, nil
}

func parsePeerFingerprint(value string) (peerFingerprint, error) {
	algorithm := "certificate-sha1"
	encoded := value
	maximumLength := sha1.Size * 2
	caseSensitive := false
	switch {
	case strings.HasPrefix(value, "sha1:"):
		algorithm = "spki-sha1"
		encoded = value[len("sha1:"):]
	case strings.HasPrefix(value, "sha256:"):
		algorithm = "spki-sha256"
		encoded = value[len("sha256:"):]
		maximumLength = sha256.Size * 2
	case strings.HasPrefix(value, "pin-sha256:"):
		algorithm = "spki-sha256"
		encoded = value[len("pin-sha256:"):]
		maximumLength = base64.StdEncoding.EncodedLen(sha256.Size)
		caseSensitive = true
	case strings.Contains(value, ":"):
		return peerFingerprint{}, E.New("unsupported server certificate fingerprint: ", value)
	}
	if len(encoded) < 4 || len(encoded) > maximumLength {
		return peerFingerprint{}, E.New("invalid server certificate fingerprint: ", value)
	}
	if caseSensitive {
		for i := 0; i < len(encoded); i++ {
			character := encoded[i]
			if character >= 'a' && character <= 'z' ||
				character >= 'A' && character <= 'Z' ||
				character >= '0' && character <= '9' || character == '+' || character == '/' {
				continue
			}
			if character != '=' || i < len(encoded)-2 {
				return peerFingerprint{}, E.New("invalid server certificate fingerprint: ", value)
			}
		}
	} else {
		for i := 0; i < len(encoded); i++ {
			character := encoded[i]
			if character >= 'a' && character <= 'f' || character >= 'A' && character <= 'F' || character >= '0' && character <= '9' {
				continue
			}
			return peerFingerprint{}, E.New("invalid server certificate fingerprint: ", value)
		}
		encoded = strings.ToLower(encoded)
	}
	if len(encoded) == maximumLength && caseSensitive {
		decoded, err := base64.StdEncoding.Strict().DecodeString(encoded)
		if err != nil || len(decoded) != sha256.Size {
			return peerFingerprint{}, E.New("invalid server certificate fingerprint: ", value)
		}
	}
	if encoded == "" {
		return peerFingerprint{}, E.New("invalid server certificate fingerprint: ", value)
	}
	return peerFingerprint{algorithm: algorithm, encoded: encoded, caseSensitive: caseSensitive}, nil
}

func installPeerVerification(configuration *tls.Config, fingerprints []peerFingerprint, allowLegacy bool, legacyRootCAs *legacyTLSRoots) {
	configuredInsecureSkipVerify := configuration.InsecureSkipVerify
	configuredVerifyPeerCertificate := configuration.VerifyPeerCertificate
	configuredVerifyConnection := configuration.VerifyConnection
	configuration.InsecureSkipVerify = true
	configuration.VerifyPeerCertificate = nil
	configuration.VerifyConnection = func(state tls.ConnectionState) error {
		if len(state.PeerCertificates) == 0 {
			return markTerminal(E.New("TLS peer did not provide a certificate"))
		}
		if len(fingerprints) > 0 && !peerCertificateMatchesAnyFingerprint(state.PeerCertificates[0], fingerprints) {
			return markTerminal(E.New("TLS peer certificate does not match any configured fingerprint"))
		}
		var verifiedChains [][]*x509.Certificate
		if !configuredInsecureSkipVerify {
			var err error
			verifiedChains, err = verifyTLSConnectionState(configuration, state, allowLegacy, legacyRootCAs)
			if err != nil && len(fingerprints) == 0 {
				return markTerminal(err)
			}
		}
		if !state.DidResume && configuredVerifyPeerCertificate != nil {
			rawCertificates := make([][]byte, len(state.PeerCertificates))
			for i, certificate := range state.PeerCertificates {
				rawCertificates[i] = append([]byte(nil), certificate.Raw...)
			}
			err := configuredVerifyPeerCertificate(rawCertificates, verifiedChains)
			if err != nil {
				return err
			}
		}
		if configuredVerifyConnection != nil {
			state.VerifiedChains = verifiedChains
			return configuredVerifyConnection(state)
		}
		return nil
	}
}

func verifyTLSConnectionState(configuration *tls.Config, state tls.ConnectionState, allowLegacy bool, legacyRootCAs *legacyTLSRoots) ([][]*x509.Certificate, error) {
	roots := configuration.RootCAs
	if roots == nil {
		var err error
		roots, err = x509.SystemCertPool()
		if err != nil {
			return nil, err
		}
	}
	intermediates := x509.NewCertPool()
	for _, certificate := range state.PeerCertificates[1:] {
		intermediates.AddCert(certificate)
	}
	var currentTime time.Time
	if configuration.Time != nil {
		currentTime = configuration.Time()
	}
	serverName := state.ServerName
	if serverName == "" {
		serverName = configuration.ServerName
	}
	if serverName == "" {
		return nil, E.New("TLS server name is unavailable for certificate verification")
	}
	verifiedChains, err := state.PeerCertificates[0].Verify(x509.VerifyOptions{
		CurrentTime:   currentTime,
		DNSName:       serverName,
		Intermediates: intermediates,
		Roots:         roots,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	})
	if err == nil || !allowLegacy {
		return verifiedChains, err
	}
	hasSHA1 := slices.ContainsFunc(state.PeerCertificates, func(certificate *x509.Certificate) bool {
		switch certificate.SignatureAlgorithm {
		case x509.SHA1WithRSA, x509.DSAWithSHA1, x509.ECDSAWithSHA1:
			return true
		default:
			return false
		}
	})
	hasMD5 := slices.ContainsFunc(state.PeerCertificates, func(certificate *x509.Certificate) bool {
		return certificate.SignatureAlgorithm == x509.MD5WithRSA
	})
	if !hasSHA1 && !hasMD5 {
		return verifiedChains, err
	}
	discoveredRootCAs := discoverLegacyTLSRootCAs(state.PeerCertificates, roots, currentTime)
	rootCertificates := append([]*x509.Certificate(nil), legacyRootCAs.certificates...)
	if discoveredRootCAs != nil {
		rootCertificates = append(rootCertificates, discoveredRootCAs.certificates...)
	}
	if len(rootCertificates) > 0 {
		insecureChains, insecureErr := verifyInsecureTLSCertificateChain(state.PeerCertificates, rootCertificates, currentTime, serverName)
		if insecureErr == nil {
			return insecureChains, nil
		}
		if hasMD5 {
			return nil, insecureErr
		}
	}
	if hasMD5 {
		return nil, E.New("MD5 certificate chain requires configured certificate authority material or a peer-provided verifiable trust anchor")
	}
	legacyChains, legacyErr := verifyLegacyTLSConnectionState(state.PeerCertificates, legacyRootCAs, discoveredRootCAs, currentTime, serverName)
	if legacyErr != nil {
		return nil, legacyErr
	}
	return legacyChains, nil
}

var insecureTLSCertificateValidationKey struct {
	once sync.Once
	key  *rsa.PrivateKey
	err  error
}

func verifyInsecureTLSCertificateChain(
	peerCertificates []*x509.Certificate,
	rootCertificates []*x509.Certificate,
	currentTime time.Time,
	serverName string,
) ([][]*x509.Certificate, error) {
	insecureTLSCertificateValidationKey.once.Do(func() {
		insecureTLSCertificateValidationKey.key, insecureTLSCertificateValidationKey.err = rsa.GenerateKey(rand.Reader, 2048)
	})
	if insecureTLSCertificateValidationKey.err != nil {
		return nil, insecureTLSCertificateValidationKey.err
	}
	validationKey := insecureTLSCertificateValidationKey.key
	originalBySynthetic := make(map[*x509.Certificate]*x509.Certificate, len(peerCertificates)+len(rootCertificates))
	cloneCertificate := func(original *x509.Certificate) (*x509.Certificate, error) {
		cloned := *original
		cloned.PublicKeyAlgorithm = x509.RSA
		cloned.PublicKey = &validationKey.PublicKey
		cloned.SignatureAlgorithm = x509.SHA256WithRSA
		digest := sha256.Sum256(cloned.RawTBSCertificate)
		signature, err := rsa.SignPKCS1v15(nil, validationKey, crypto.SHA256, digest[:])
		if err != nil {
			return nil, err
		}
		cloned.Signature = signature
		originalBySynthetic[&cloned] = original
		return &cloned, nil
	}
	syntheticPeerCertificates := make([]*x509.Certificate, 0, len(peerCertificates))
	for _, peerCertificate := range peerCertificates {
		syntheticCertificate, cloneErr := cloneCertificate(peerCertificate)
		if cloneErr != nil {
			return nil, cloneErr
		}
		syntheticPeerCertificates = append(syntheticPeerCertificates, syntheticCertificate)
	}
	syntheticIntermediates := x509.NewCertPool()
	for _, intermediate := range syntheticPeerCertificates[1:] {
		syntheticIntermediates.AddCert(intermediate)
	}
	syntheticRoots := x509.NewCertPool()
	for _, root := range rootCertificates {
		syntheticRoot, cloneErr := cloneCertificate(root)
		if cloneErr != nil {
			return nil, cloneErr
		}
		syntheticRoots.AddCert(syntheticRoot)
	}
	syntheticChains, err := syntheticPeerCertificates[0].Verify(x509.VerifyOptions{
		CurrentTime:   currentTime,
		DNSName:       serverName,
		Roots:         syntheticRoots,
		Intermediates: syntheticIntermediates,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	})
	if err != nil {
		return nil, err
	}
	verifiedChains := make([][]*x509.Certificate, 0, len(syntheticChains))
	var signatureErr error
	for _, syntheticChain := range syntheticChains {
		chain := make([]*x509.Certificate, 0, len(syntheticChain))
		for _, syntheticCertificate := range syntheticChain {
			originalCertificate := originalBySynthetic[syntheticCertificate]
			if originalCertificate == nil {
				return nil, E.New("unmapped certificate in compatibility chain")
			}
			chain = append(chain, originalCertificate)
		}
		validSignatures := true
		for i := 0; i+1 < len(chain); i++ {
			signatureErr = verifyInsecureTLSCertificateSignature(chain[i], chain[i+1])
			if signatureErr != nil {
				validSignatures = false
				break
			}
		}
		if validSignatures {
			verifiedChains = append(verifiedChains, chain)
		}
	}
	if len(verifiedChains) == 0 {
		return nil, signatureErr
	}
	return verifiedChains, nil
}

func verifyInsecureTLSCertificateSignature(certificate *x509.Certificate, parent *x509.Certificate) error {
	if certificate.SignatureAlgorithm == x509.MD5WithRSA {
		parentPublicKey, loaded := parent.PublicKey.(*rsa.PublicKey)
		if !loaded {
			return x509.ErrUnsupportedAlgorithm
		}
		digest := md5.Sum(certificate.RawTBSCertificate)
		return rsa.VerifyPKCS1v15(parentPublicKey, crypto.MD5, digest[:], certificate.Signature)
	}
	legacyCertificate, err := ctx509.ParseCertificate(certificate.Raw)
	if err != nil {
		return err
	}
	legacyParent, err := ctx509.ParseCertificate(parent.Raw)
	if err != nil {
		return err
	}
	return legacyCertificate.CheckSignatureFrom(legacyParent)
}

func verifyLegacyTLSConnectionState(
	peerCertificates []*x509.Certificate,
	legacyRootCAs *legacyTLSRoots,
	discoveredRootCAs *legacyTLSRoots,
	currentTime time.Time,
	serverName string,
) ([][]*x509.Certificate, error) {
	legacyPeerCertificate, err := ctx509.ParseCertificate(peerCertificates[0].Raw)
	if err != nil {
		return nil, err
	}
	legacyIntermediates := ctx509.NewCertPool()
	for _, peerCertificate := range peerCertificates[1:] {
		legacyIntermediate, parseErr := ctx509.ParseCertificate(peerCertificate.Raw)
		if parseErr != nil {
			return nil, parseErr
		}
		legacyIntermediates.AddCert(legacyIntermediate)
	}
	verifyOptions := ctx509.VerifyOptions{
		CurrentTime:   currentTime,
		DNSName:       serverName,
		Intermediates: legacyIntermediates,
		Roots:         legacyRootCAs.pool,
		KeyUsages:     []ctx509.ExtKeyUsage{ctx509.ExtKeyUsageServerAuth},
	}
	legacyChains, err := legacyPeerCertificate.Verify(verifyOptions)
	if err != nil {
		if discoveredRootCAs != nil {
			verifyOptions.Roots = discoveredRootCAs.pool
			legacyChains, err = legacyPeerCertificate.Verify(verifyOptions)
		}
	}
	if err != nil {
		return nil, err
	}
	verifiedChains := make([][]*x509.Certificate, 0, len(legacyChains))
	for _, legacyChain := range legacyChains {
		verifiedChain := make([]*x509.Certificate, 0, len(legacyChain))
		for _, legacyCertificate := range legacyChain {
			certificate, parseErr := x509.ParseCertificate(legacyCertificate.Raw)
			if parseErr != nil {
				return nil, parseErr
			}
			verifiedChain = append(verifiedChain, certificate)
		}
		verifiedChains = append(verifiedChains, verifiedChain)
	}
	return verifiedChains, nil
}

func discoverLegacyTLSRootCAs(peerCertificates []*x509.Certificate, roots *x509.CertPool, currentTime time.Time) *legacyTLSRoots {
	legacyRoots := &legacyTLSRoots{pool: ctx509.NewCertPool()}
	discoveredRoots := make(map[string]struct{})
	for i := 1; i < len(peerCertificates); i++ {
		intermediates := x509.NewCertPool()
		for _, peerCertificate := range peerCertificates[i+1:] {
			intermediates.AddCert(peerCertificate)
		}
		chains, err := peerCertificates[i].Verify(x509.VerifyOptions{
			CurrentTime:   currentTime,
			Intermediates: intermediates,
			Roots:         roots,
			KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
		})
		if err != nil {
			continue
		}
		for _, chain := range chains {
			root := chain[len(chain)-1]
			legacyRoot, parseErr := ctx509.ParseCertificate(root.Raw)
			if parseErr != nil {
				continue
			}
			legacyRoots.pool.AddCert(legacyRoot)
			rootKey := string(root.Raw)
			if _, loaded := discoveredRoots[rootKey]; !loaded {
				discoveredRoots[rootKey] = struct{}{}
				legacyRoots.certificates = append(legacyRoots.certificates, root)
			}
		}
	}
	if len(legacyRoots.certificates) == 0 {
		return nil
	}
	return legacyRoots
}

func peerCertificateMatchesAnyFingerprint(certificate *x509.Certificate, fingerprints []peerFingerprint) bool {
	certificateSHA1 := sha1.Sum(certificate.Raw)
	spkiSHA1 := sha1.Sum(certificate.RawSubjectPublicKeyInfo)
	spkiSHA256 := sha256.Sum256(certificate.RawSubjectPublicKeyInfo)
	matched := 0
	for _, fingerprint := range fingerprints {
		var actual string
		switch fingerprint.algorithm {
		case "certificate-sha1":
			actual = hex.EncodeToString(certificateSHA1[:])
		case "spki-sha1":
			actual = hex.EncodeToString(spkiSHA1[:])
		case "spki-sha256":
			if fingerprint.caseSensitive {
				actual = base64.StdEncoding.EncodeToString(spkiSHA256[:])
			} else {
				actual = hex.EncodeToString(spkiSHA256[:])
			}
		}
		matched |= subtle.ConstantTimeCompare([]byte(actual[:len(fingerprint.encoded)]), []byte(fingerprint.encoded))
	}
	return matched == 1
}

func cloneTLSConfig(configuration *tls.Config) *tls.Config {
	cloned := configuration.Clone()
	cloned.Certificates = cloneTLSCertificates(cloned.Certificates)
	cloned.CipherSuites = append([]uint16(nil), cloned.CipherSuites...)
	cloned.CurvePreferences = append([]tls.CurveID(nil), cloned.CurvePreferences...)
	cloned.NextProtos = append([]string(nil), cloned.NextProtos...)
	cloned.EncryptedClientHelloConfigList = append([]byte(nil), cloned.EncryptedClientHelloConfigList...)
	if cloned.RootCAs != nil {
		cloned.RootCAs = cloned.RootCAs.Clone()
	}
	return cloned
}

// Go crypto/tls (*Conn).getClientCertificate calls GetClientCertificate when configured; otherwise it selects the first configured chain accepted by CertificateRequestInfo.SupportsCertificate and returns an empty certificate when none match.
func wrapTLSClientCertificateSelection(configuration *tls.Config, record func(certificate *tls.Certificate)) {
	configuredCallback := configuration.GetClientCertificate
	configuredCertificates := configuration.Certificates
	configuration.GetClientCertificate = func(request *tls.CertificateRequestInfo) (*tls.Certificate, error) {
		var selectedCertificate *tls.Certificate
		var err error
		if configuredCallback != nil {
			selectedCertificate, err = configuredCallback(request)
		} else {
			for _, configuredCertificate := range configuredCertificates {
				supportErr := request.SupportsCertificate(&configuredCertificate)
				if supportErr != nil {
					continue
				}
				selectedCertificate = &configuredCertificate
				break
			}
			if selectedCertificate == nil {
				selectedCertificate = new(tls.Certificate)
			}
		}
		if err == nil {
			record(selectedCertificate)
		}
		return selectedCertificate, err
	}
}

func loadOptionalCertificate(certificateMaterial Material, keyMaterial Material, password string, name string) (*tls.Certificate, error) {
	if certificateMaterial.IsSet() != keyMaterial.IsSet() {
		return nil, E.Extend(ErrInvalidTLSMaterial, name, " certificate and key must both be set")
	}
	if !certificateMaterial.IsSet() {
		return nil, nil
	}
	certificatePEM, err := loadMaterial(certificateMaterial)
	if err != nil {
		return nil, E.Cause(err, "load ", name, " certificate")
	}
	keyPEM, err := loadMaterial(keyMaterial)
	if err != nil {
		return nil, E.Cause(err, "load ", name, " key")
	}
	keyPEM, err = decryptPrivateKeyPEM(keyPEM, password)
	if err != nil {
		return nil, E.Cause(err, "decrypt ", name, " key")
	}
	certificate, err := tls.X509KeyPair(certificatePEM, keyPEM)
	if err != nil {
		return nil, E.Cause(err, "parse ", name, " certificate and key")
	}
	return &certificate, nil
}

func decryptPrivateKeyPEM(content []byte, password string) ([]byte, error) {
	rest := content
	result := make([]byte, 0, len(content))
	for len(rest) > 0 {
		block, remaining := pem.Decode(rest)
		if block == nil {
			if len(result) == 0 {
				return content, nil
			}
			result = append(result, rest...)
			break
		}
		rest = remaining
		if block.Type == "ENCRYPTED PRIVATE KEY" {
			if password == "" {
				return nil, E.New("encrypted PKCS#8 private key requires a password")
			}
			privateKey, err := parseEncryptedPKCS8PrivateKey(block.Bytes, password)
			if err != nil {
				return nil, E.Cause(err, "decrypt PKCS#8 private key")
			}
			decrypted, err := x509.MarshalPKCS8PrivateKey(privateKey)
			if err != nil {
				return nil, E.Cause(err, "marshal decrypted PKCS#8 private key")
			}
			block.Type = "PRIVATE KEY"
			block.Bytes = decrypted
			block.Headers = nil
		}
		// Go crypto/x509 exposes RFC 1423 PEM decryption for legacy gateway client keys only through this deprecated API.
		//nolint:staticcheck
		if x509.IsEncryptedPEMBlock(block) {
			if password == "" {
				return nil, E.New("encrypted private key requires a password")
			}
			// Go crypto/x509 exposes RFC 1423 PEM decryption for legacy gateway client keys only through this deprecated API.
			//nolint:staticcheck
			decrypted, err := x509.DecryptPEMBlock(block, []byte(password))
			if err != nil {
				return nil, err
			}
			block.Bytes = decrypted
			block.Headers = nil
		}
		result = append(result, pem.EncodeToMemory(block)...)
	}
	return result, nil
}

func parseEncryptedPKCS8PrivateKey(content []byte, password string) (privateKey any, err error) {
	defer func() {
		panicValue := recover()
		if panicValue != nil {
			privateKey = nil
			err = E.New("invalid encrypted PKCS#8 private key: ", panicValue)
		}
	}()
	privateKey, err = pkcs8.ParsePKCS8PrivateKey(content, []byte(password))
	return
}

func openConnectCipherSuites(allowInsecure bool, pfs bool) []uint16 {
	result := []uint16{
		tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
		tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
		tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
		tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
		tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
		tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
		tls.TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA,
		tls.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
		tls.TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA,
		tls.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
		tls.TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256,
		tls.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256,
		tls.TLS_RSA_WITH_AES_128_GCM_SHA256,
		tls.TLS_RSA_WITH_AES_256_GCM_SHA384,
		tls.TLS_RSA_WITH_AES_128_CBC_SHA,
		tls.TLS_RSA_WITH_AES_256_CBC_SHA,
		tls.TLS_RSA_WITH_AES_128_CBC_SHA256,
	}
	if allowInsecure {
		result = append(result,
			tls.TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA,
			tls.TLS_ECDHE_ECDSA_WITH_RC4_128_SHA,
			tls.TLS_ECDHE_RSA_WITH_RC4_128_SHA,
			tls.TLS_RSA_WITH_3DES_EDE_CBC_SHA,
			tls.TLS_RSA_WITH_RC4_128_SHA,
		)
	}
	if pfs {
		result = filterPFSCipherSuites(result)
	}
	return result
}

func isDeprecatedTLSCipherSuite(cipherSuite uint16) bool {
	switch cipherSuite {
	case tls.TLS_RSA_WITH_RC4_128_SHA,
		tls.TLS_RSA_WITH_3DES_EDE_CBC_SHA,
		tls.TLS_ECDHE_ECDSA_WITH_RC4_128_SHA,
		tls.TLS_ECDHE_RSA_WITH_RC4_128_SHA,
		tls.TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA:
		return true
	default:
		return false
	}
}

func filterPFSCipherSuites(cipherSuites []uint16) []uint16 {
	filtered := make([]uint16, 0, len(cipherSuites))
	for _, cipherSuite := range cipherSuites {
		switch cipherSuite {
		case tls.TLS_RSA_WITH_RC4_128_SHA,
			tls.TLS_RSA_WITH_3DES_EDE_CBC_SHA,
			tls.TLS_RSA_WITH_AES_128_CBC_SHA,
			tls.TLS_RSA_WITH_AES_256_CBC_SHA,
			tls.TLS_RSA_WITH_AES_128_CBC_SHA256,
			tls.TLS_RSA_WITH_AES_128_GCM_SHA256,
			tls.TLS_RSA_WITH_AES_256_GCM_SHA384:
			continue
		default:
			filtered = append(filtered, cipherSuite)
		}
	}
	return filtered
}

func cloneTLSCertificates(certificates []tls.Certificate) []tls.Certificate {
	cloned := make([]tls.Certificate, len(certificates))
	for i := range certificates {
		cloned[i] = certificates[i]
		cloned[i].Certificate = cloneByteSlices(certificates[i].Certificate)
		cloned[i].SupportedSignatureAlgorithms = append([]tls.SignatureScheme(nil), certificates[i].SupportedSignatureAlgorithms...)
		cloned[i].OCSPStaple = append([]byte(nil), certificates[i].OCSPStaple...)
		cloned[i].SignedCertificateTimestamps = cloneByteSlices(certificates[i].SignedCertificateTimestamps)
		cloned[i].Leaf = nil
	}
	return cloned
}

func cloneByteSlices(values [][]byte) [][]byte {
	cloned := make([][]byte, len(values))
	for i := range values {
		cloned[i] = append([]byte(nil), values[i]...)
	}
	return cloned
}
