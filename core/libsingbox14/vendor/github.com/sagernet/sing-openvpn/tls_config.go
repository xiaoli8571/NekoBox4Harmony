package openvpn

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"os"
	"strings"

	E "github.com/sagernet/sing/common/exceptions"

	ctx509 "github.com/google/certificate-transparency-go/x509"
)

func hasTLSCredentialMaterial(values ...Material) bool {
	for _, value := range values {
		if value.IsSet() {
			return true
		}
	}
	return false
}

// Upstream add_option accepts none, optional, and require for
// --verify-client-cert.
func resolveVerifyClientCertMode(value string) (tls.ClientAuthType, error) {
	switch value {
	case "", "require":
		return tls.RequireAnyClientCert, nil
	case "optional":
		return tls.RequestClientCert, nil
	case "none":
		return tls.NoClientCert, nil
	default:
		return 0, E.New("verify-client-cert must be 'none', 'optional' or 'require', got: ", value)
	}
}

func parseTLSVersionToken(versionToken string) (uint16, error) {
	switch versionToken {
	case "":
		return 0, nil
	case "1.0":
		return tls.VersionTLS10, nil
	case "1.1":
		return tls.VersionTLS11, nil
	case "1.2":
		return tls.VersionTLS12, nil
	case "1.3":
		return tls.VersionTLS13, nil
	default:
		return 0, E.New("unknown tls-version parameter: ", versionToken)
	}
}

// Upstream options_postprocess_mutate (options.c) defaults tls-version-min
// to TLS 1.2 and rejects min > max.
func resolveTLSVersionBounds(versionMinToken string, versionMaxToken string) (uint16, uint16, error) {
	parsedMin, err := parseTLSVersionToken(versionMinToken)
	if err != nil {
		return 0, 0, err
	}
	parsedMax, err := parseTLSVersionToken(versionMaxToken)
	if err != nil {
		return 0, 0, err
	}
	if parsedMin == 0 {
		parsedMin = tls.VersionTLS12
	}
	if parsedMax != 0 && parsedMax < parsedMin {
		return 0, 0, E.New("tls-version-min bigger than tls-version-max")
	}
	return parsedMin, parsedMax, nil
}

// Upstream tls_ctx_set_cert_profile (ssl_openssl.c) accepts legacy,
// preferred, insecure, and suiteb.
func parseTLSCertProfile(profile string) (string, error) {
	switch profile {
	case "", "legacy", "preferred", "insecure", "suiteb":
		if profile == "" {
			return "legacy", nil
		}
		return profile, nil
	default:
		return "", E.New("unknown tls-cert-profile value: ", profile)
	}
}

// Upstream options_postprocess_filechecks (options.c) requires server
// cert+key, allows client CA/fingerprint-only auth, and rejects PKI
// material outside TLS mode.
func validateTLSCredentialSet(mode string, certificateAuthority Material, certificate Material, key Material, peerFingerprints []string, requireCertAndKey bool) error {
	caSet := certificateAuthority.IsSet()
	certSet := certificate.IsSet()
	keySet := key.IsSet()
	fingerprintSet := len(peerFingerprints) > 0
	if !caSet && !certSet && !keySet && !fingerprintSet {
		if mode == ModeTLS {
			if requireCertAndKey {
				return E.New("tls server requires certificate and key")
			}
			return ErrMissingCAOrPeerFingerprint
		}
		return nil
	}
	if mode != ModeTLS {
		return E.Extend(ErrOptionNotSupported, "certificate material outside tls mode")
	}
	if certSet != keySet {
		return E.New("certificate and key must both be set or both omitted")
	}
	if requireCertAndKey && !certSet {
		return E.New("tls server requires certificate and key")
	}
	return nil
}

func buildTLSClientConfiguration(options ClientOptions) (*tls.Config, error) {
	tlsOptions := options.TLS
	if tlsOptions.CRLVerify != "" {
		_, err := os.Stat(tlsOptions.CRLVerify)
		if err != nil {
			return nil, err
		}
	}
	rootCAs, err := loadCertPool(tlsOptions.CertificateAuthority)
	if err != nil {
		return nil, err
	}
	err = requireCAOrPeerFingerprint(rootCAs, tlsOptions.PeerFingerprint)
	if err != nil {
		return nil, err
	}
	certProfile, err := parseTLSCertProfile(tlsOptions.CertificateProfile)
	if err != nil {
		return nil, err
	}
	clientCertificates, err := loadOptionalClientCertificate(tlsOptions.Certificate, tlsOptions.Key, certProfile)
	if err != nil {
		return nil, err
	}
	requiredKeyUsage, err := parseRemoteCertKeyUsages(tlsOptions.RemoteCertificateKU)
	if err != nil {
		return nil, err
	}
	requiredExtUsage, err := parseRemoteCertExtKeyUsage(tlsOptions.RemoteCertificateEKU)
	if err != nil {
		return nil, err
	}
	requireKeyUsageExtension, shorthandExtUsage, err := expandRemoteCertTLS(tlsOptions.RemoteCertificateTLS, "server")
	if err != nil {
		return nil, err
	}
	requiredExtUsage = mergeExtendedKeyUsage(requiredExtUsage, shorthandExtUsage)
	tlsVersionMin, tlsVersionMax, err := resolveTLSVersionBounds(tlsOptions.VersionMin, tlsOptions.VersionMax)
	if err != nil {
		return nil, err
	}
	tlsCipherSuites, err := parseTLSCipherSuites(tlsOptions.Cipher)
	if err != nil {
		return nil, err
	}
	tlsCurvePreferences, err := parseTLSGroups(tlsOptions.Groups)
	if err != nil {
		return nil, err
	}
	tlsCipherSuites = applyCertificateProfileTLSCipherDefault(certProfile, tlsCipherSuites)
	verifier := &peerCertificateVerifier{options: peerCertificateVerifierOptions{
		Roots:                    rootCAs,
		Purpose:                  certificatePurposeSSLServer,
		VerifyName:               tlsOptions.VerifyX509Name,
		VerifyNameType:           tlsOptions.VerifyX509Type,
		PeerFingerprints:         tlsOptions.PeerFingerprint,
		CRLPath:                  tlsOptions.CRLVerify,
		RequiredKeyUsage:         requiredKeyUsage,
		RequireKeyUsageExtension: requireKeyUsageExtension,
		RequiredExtendedUsage:    requiredExtUsage,
		NSCertificateType:        tlsOptions.NSCertificateType,
		CertificateProfile:       certProfile,
	}}
	var standardRootCAs *x509.CertPool
	if rootCAs != nil {
		standardRootCAs = rootCAs.standard
	}
	return &tls.Config{
		Certificates:       clientCertificates,
		RootCAs:            standardRootCAs,
		MinVersion:         tlsVersionMin,
		MaxVersion:         tlsVersionMax,
		CipherSuites:       tlsCipherSuites,
		CurvePreferences:   tlsCurvePreferences,
		InsecureSkipVerify: true,
		VerifyPeerCertificate: func(rawCertificates [][]byte, _ [][]*x509.Certificate) error {
			verifyErr := verifier.Verify(rawCertificates)
			if verifyErr != nil && !E.IsMulti(verifyErr, ErrPeerCertificateVerification) {
				verifyErr = E.Errors(ErrPeerCertificateVerification, verifyErr)
			}
			return verifyErr
		},
	}, nil
}

// Upstream tls_ctx_load_cert_file_and_copy (ssl_openssl.c) loads a client
// certificate only when cert_file is set.
func loadOptionalClientCertificate(certificateMaterial Material, key Material, certificateProfile string) ([]tls.Certificate, error) {
	if !certificateMaterial.IsSet() && !key.IsSet() {
		return nil, nil
	}
	certificatePEM, err := loadMaterial(certificateMaterial)
	if err != nil {
		return nil, err
	}
	keyPEM, err := loadMaterial(key)
	if err != nil {
		return nil, err
	}
	parsedCertificate, err := tls.X509KeyPair(certificatePEM, keyPEM)
	if err != nil {
		return nil, err
	}
	localChain := make([]*x509.Certificate, 0, len(parsedCertificate.Certificate))
	for _, rawCertificate := range parsedCertificate.Certificate {
		certificate, parseErr := x509.ParseCertificate(rawCertificate)
		if parseErr != nil {
			return nil, parseErr
		}
		localChain = append(localChain, certificate)
	}
	err = enforceCertificateProfile(localChain, certificateProfile)
	if err != nil {
		return nil, err
	}
	return []tls.Certificate{parsedCertificate}, nil
}

func buildTLSServerConfiguration(options ServerOptions) (*tls.Config, error) {
	tlsOptions := options.TLS
	if tlsOptions.CRLVerify != "" {
		_, err := os.Stat(tlsOptions.CRLVerify)
		if err != nil {
			return nil, err
		}
	}
	rootCAs, err := loadCertPool(tlsOptions.CertificateAuthority)
	if err != nil {
		return nil, err
	}
	verifyClientCertMode, err := resolveVerifyClientCertMode(tlsOptions.VerifyClientCertificate)
	if err != nil {
		return nil, err
	}
	if verifyClientCertMode != tls.NoClientCert {
		err = requireCAOrPeerFingerprint(rootCAs, tlsOptions.PeerFingerprint)
		if err != nil {
			return nil, err
		}
	}
	certProfile, err := parseTLSCertProfile(tlsOptions.CertificateProfile)
	if err != nil {
		return nil, err
	}
	certificates, err := loadOptionalClientCertificate(tlsOptions.Certificate, tlsOptions.Key, certProfile)
	if err != nil {
		return nil, err
	}
	certificate := certificates[0]
	requiredKeyUsage, err := parseRemoteCertKeyUsages(tlsOptions.RemoteCertificateKU)
	if err != nil {
		return nil, err
	}
	requiredExtUsage, err := parseRemoteCertExtKeyUsage(tlsOptions.RemoteCertificateEKU)
	if err != nil {
		return nil, err
	}
	requireKeyUsageExtension, shorthandExtUsage, err := expandRemoteCertTLS(tlsOptions.RemoteCertificateTLS, "client")
	if err != nil {
		return nil, err
	}
	requiredExtUsage = mergeExtendedKeyUsage(requiredExtUsage, shorthandExtUsage)
	tlsVersionMin, tlsVersionMax, err := resolveTLSVersionBounds(tlsOptions.VersionMin, tlsOptions.VersionMax)
	if err != nil {
		return nil, err
	}
	tlsCipherSuites, err := parseTLSCipherSuites(tlsOptions.Cipher)
	if err != nil {
		return nil, err
	}
	tlsCurvePreferences, err := parseTLSGroups(tlsOptions.Groups)
	if err != nil {
		return nil, err
	}
	tlsCipherSuites = applyCertificateProfileTLSCipherDefault(certProfile, tlsCipherSuites)
	verifier := &peerCertificateVerifier{options: peerCertificateVerifierOptions{
		Roots:                    rootCAs,
		Purpose:                  certificatePurposeSSLClient,
		VerifyName:               tlsOptions.VerifyX509Name,
		VerifyNameType:           tlsOptions.VerifyX509Type,
		PeerFingerprints:         tlsOptions.PeerFingerprint,
		CRLPath:                  tlsOptions.CRLVerify,
		RequiredKeyUsage:         requiredKeyUsage,
		RequireKeyUsageExtension: requireKeyUsageExtension,
		RequiredExtendedUsage:    requiredExtUsage,
		NSCertificateType:        tlsOptions.NSCertificateType,
		CertificateProfile:       certProfile,
	}}
	var standardRootCAs *x509.CertPool
	if rootCAs != nil {
		standardRootCAs = rootCAs.standard
	}
	tlsConfiguration := &tls.Config{
		Certificates:     []tls.Certificate{certificate},
		ClientAuth:       verifyClientCertMode,
		ClientCAs:        standardRootCAs,
		MinVersion:       tlsVersionMin,
		MaxVersion:       tlsVersionMax,
		CipherSuites:     tlsCipherSuites,
		CurvePreferences: tlsCurvePreferences,
	}
	if verifyClientCertMode != tls.NoClientCert {
		tlsConfiguration.VerifyPeerCertificate = func(rawCertificates [][]byte, _ [][]*x509.Certificate) error {
			if verifyClientCertMode == tls.RequestClientCert && len(rawCertificates) == 0 {
				return nil
			}
			verifyErr := verifier.Verify(rawCertificates)
			if verifyErr != nil && !E.IsMulti(verifyErr, ErrPeerCertificateVerification) {
				verifyErr = E.Errors(ErrPeerCertificateVerification, verifyErr)
			}
			return verifyErr
		}
	}
	return tlsConfiguration, nil
}

func applyCertificateProfileTLSCipherDefault(profile string, cipherSuites []uint16) []uint16 {
	if profile != "suiteb" || len(cipherSuites) > 0 {
		return cipherSuites
	}
	return []uint16{
		tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
		tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
	}
}

type certificatePool struct {
	standard     *x509.CertPool
	legacy       *ctx509.CertPool
	certificates []*x509.Certificate
}

func loadCertPool(certificateAuthority Material) (*certificatePool, error) {
	if !certificateAuthority.IsSet() {
		return nil, nil
	}
	certificateAuthorityData, err := loadMaterial(certificateAuthority)
	if err != nil {
		return nil, err
	}
	standardPool := x509.NewCertPool()
	if !standardPool.AppendCertsFromPEM(certificateAuthorityData) {
		return nil, E.New("invalid certificate authority bundle")
	}
	legacyPool := ctx509.NewCertPool()
	if !legacyPool.AppendCertsFromPEM(certificateAuthorityData) {
		return nil, E.New("invalid certificate authority bundle")
	}
	var certificates []*x509.Certificate
	remaining := certificateAuthorityData
	for len(remaining) > 0 {
		pemBlock, rest := pem.Decode(remaining)
		if pemBlock == nil {
			break
		}
		remaining = rest
		if pemBlock.Type != "CERTIFICATE" {
			continue
		}
		parsedCertificates, parseErr := x509.ParseCertificates(pemBlock.Bytes)
		if parseErr != nil {
			return nil, parseErr
		}
		certificates = append(certificates, parsedCertificates...)
	}
	if len(certificates) == 0 {
		return nil, E.New("invalid certificate authority bundle")
	}
	return &certificatePool{standard: standardPool, legacy: legacyPool, certificates: certificates}, nil
}

// Upstream options_postprocess_filechecks (options.c) rejects TLS without
// CA material or peer fingerprints.
var ErrMissingCAOrPeerFingerprint = E.New("tls mode: either certificate-authority or peer-fingerprint must be configured")

func requireCAOrPeerFingerprint(roots *certificatePool, peerFingerprints []string) error {
	if roots != nil {
		return nil
	}
	if len(peerFingerprints) > 0 {
		return nil
	}
	return ErrMissingCAOrPeerFingerprint
}

// Upstream tls_get_cipher_name_pair accepts OpenSSL and IANA names for
// TLS 1.2 cipher suites.
type tlsCipherNamePair struct {
	openSSLName string
	suiteID     uint16
}

var tlsCipherTranslationTable = []tlsCipherNamePair{
	{"RC4-SHA", tls.TLS_RSA_WITH_RC4_128_SHA},
	{"DES-CBC3-SHA", tls.TLS_RSA_WITH_3DES_EDE_CBC_SHA},
	{"AES128-SHA", tls.TLS_RSA_WITH_AES_128_CBC_SHA},
	{"AES256-SHA", tls.TLS_RSA_WITH_AES_256_CBC_SHA},
	{"AES128-SHA256", tls.TLS_RSA_WITH_AES_128_CBC_SHA256},
	{"AES128-GCM-SHA256", tls.TLS_RSA_WITH_AES_128_GCM_SHA256},
	{"AES256-GCM-SHA384", tls.TLS_RSA_WITH_AES_256_GCM_SHA384},
	{"ECDHE-ECDSA-AES128-SHA", tls.TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA},
	{"ECDHE-ECDSA-AES256-SHA", tls.TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA},
	{"ECDHE-ECDSA-RC4-SHA", tls.TLS_ECDHE_ECDSA_WITH_RC4_128_SHA},
	{"ECDHE-RSA-RC4-SHA", tls.TLS_ECDHE_RSA_WITH_RC4_128_SHA},
	{"ECDHE-RSA-DES-CBC3-SHA", tls.TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA},
	{"ECDHE-RSA-AES128-SHA", tls.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA},
	{"ECDHE-RSA-AES256-SHA", tls.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA},
	{"ECDHE-ECDSA-AES128-SHA256", tls.TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256},
	{"ECDHE-RSA-AES128-SHA256", tls.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256},
	{"ECDHE-ECDSA-AES128-GCM-SHA256", tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256},
	{"ECDHE-RSA-AES128-GCM-SHA256", tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256},
	{"ECDHE-ECDSA-AES256-GCM-SHA384", tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384},
	{"ECDHE-RSA-AES256-GCM-SHA384", tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384},
	{"ECDHE-ECDSA-CHACHA20-POLY1305", tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256},
	{"ECDHE-RSA-CHACHA20-POLY1305", tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256},
}

func parseTLSCipherSuites(input string) ([]uint16, error) {
	if input == "" {
		return nil, nil
	}
	tokens := strings.Split(input, ":")
	seen := map[uint16]struct{}{}
	suiteIDs := make([]uint16, 0, len(tokens))
	for _, token := range tokens {
		if token == "" {
			return nil, E.New("tls-cipher contains an empty cipher suite")
		}
		suiteID, err := lookupTLSCipherSuite(token)
		if err != nil {
			return nil, err
		}
		_, duplicate := seen[suiteID]
		if duplicate {
			continue
		}
		seen[suiteID] = struct{}{}
		suiteIDs = append(suiteIDs, suiteID)
	}
	if len(suiteIDs) == 0 {
		return nil, E.New("tls-cipher yielded no supported TLS 1.2 cipher suites")
	}
	return suiteIDs, nil
}

func lookupTLSCipherSuite(token string) (uint16, error) {
	for _, pair := range tlsCipherTranslationTable {
		if pair.openSSLName == token || tls.CipherSuiteName(pair.suiteID) == token {
			return pair.suiteID, nil
		}
	}
	return 0, E.New("unsupported tls-cipher name: ", token)
}

// Upstream tls_ctx_set_tls_groups feeds --tls-groups into
// SSL_CTX_set1_groups_list after OpenSSL name normalization.
var tlsGroupAliases = map[string]tls.CurveID{
	"X25519":     tls.X25519,
	"CURVE25519": tls.X25519,
	"SECP256R1":  tls.CurveP256,
	"PRIME256V1": tls.CurveP256,
	"P-256":      tls.CurveP256,
	"NISTP256":   tls.CurveP256,
	"SECP384R1":  tls.CurveP384,
	"P-384":      tls.CurveP384,
	"NISTP384":   tls.CurveP384,
	"SECP521R1":  tls.CurveP521,
	"P-521":      tls.CurveP521,
	"NISTP521":   tls.CurveP521,
}

func parseTLSGroups(input string) ([]tls.CurveID, error) {
	if input == "" {
		return nil, nil
	}
	tokens := strings.Split(input, ":")
	seen := map[tls.CurveID]struct{}{}
	curveIDs := make([]tls.CurveID, 0, len(tokens))
	for _, token := range tokens {
		if token == "" {
			return nil, E.New("tls-groups contains an empty group name")
		}
		curveID, found := tlsGroupAliases[token]
		if !found {
			return nil, E.New("unsupported tls-groups name: ", token)
		}
		_, duplicate := seen[curveID]
		if duplicate {
			continue
		}
		seen[curveID] = struct{}{}
		curveIDs = append(curveIDs, curveID)
	}
	if len(curveIDs) == 0 {
		return nil, E.New("tls-groups yielded no supported curves")
	}
	return curveIDs, nil
}
