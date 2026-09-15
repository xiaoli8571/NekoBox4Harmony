package openvpn

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/md5"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/hex"
	"encoding/pem"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	E "github.com/sagernet/sing/common/exceptions"

	ctx509 "github.com/google/certificate-transparency-go/x509"
)

type peerCertificateVerifierOptions struct {
	Roots                    *certificatePool
	Purpose                  certificatePurpose
	VerifyName               string
	VerifyNameType           string
	PeerFingerprints         []string
	CRLPath                  string
	RequiredKeyUsage         []uint
	RequireKeyUsageExtension bool
	RequiredExtendedUsage    []asn1.ObjectIdentifier
	NSCertificateType        string
	CertificateProfile       string
}

type peerCertificateVerifier struct {
	options peerCertificateVerifierOptions
}

func (v *peerCertificateVerifier) Verify(rawCertificates [][]byte) error {
	if len(rawCertificates) == 0 {
		return E.New("missing peer certificate")
	}
	peerCertificates := make([]*x509.Certificate, 0, len(rawCertificates))
	for _, rawCertificate := range rawCertificates {
		peerCertificate, err := x509.ParseCertificate(rawCertificate)
		if err != nil {
			return err
		}
		peerCertificates = append(peerCertificates, peerCertificate)
	}
	// Upstream loads no trust store when --peer-fingerprint replaces --ca, and
	// verify_callback then answers every X509_verify_cert error with success:
	// issuer lookup, chain signatures, each validity window, the store purpose,
	// the security level --tls-cert-profile sets and the revocation state all
	// stop being enforced, leaving only what verify_cert reads off the peer
	// certificate itself.
	if v.options.Roots == nil && len(v.options.PeerFingerprints) > 0 {
		return v.verifyPeerCertificate(peerCertificates[0])
	}
	verifiedChain, err := v.verifyCertificateChain(rawCertificates, peerCertificates)
	if err != nil {
		return err
	}
	err = enforceCertificateProfile(verifiedChain, v.options.CertificateProfile)
	if err != nil {
		return err
	}
	err = v.verifyPeerCertificate(peerCertificates[0])
	if err != nil {
		return err
	}
	return verifyAgainstCRL(verifiedChain, v.options.CRLPath)
}

func (v *peerCertificateVerifier) verifyCertificateChain(rawCertificates [][]byte, peerCertificates []*x509.Certificate) ([]*x509.Certificate, error) {
	var verifiedChains [][]*x509.Certificate
	var err error
	switch v.options.CertificateProfile {
	case "insecure":
		verifiedChains, err = verifyInsecureCertificateChain(rawCertificates, v.options.Roots)
	case "legacy":
		verifiedChains, err = verifyLegacyCertificateChain(rawCertificates, v.options.Roots)
	default:
		intermediates := x509.NewCertPool()
		for _, peerCertificate := range peerCertificates[1:] {
			intermediates.AddCert(peerCertificate)
		}
		verifyOptions := x509.VerifyOptions{
			Roots:         v.options.Roots.standard,
			Intermediates: intermediates,
			KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
		}
		verifiedChains, err = peerCertificates[0].Verify(verifyOptions)
	}
	if err != nil {
		return nil, err
	}
	verifiedChains, err = filterChainsByCertificatePurpose(verifiedChains, v.options.Purpose)
	if err != nil {
		return nil, err
	}
	return verifiedChains[0], nil
}

// Upstream verify_cert derives these from the peer certificate alone, outside
// the chain verification that --peer-fingerprint without --ca disables.
func (v *peerCertificateVerifier) verifyPeerCertificate(peerCertificate *x509.Certificate) error {
	err := verifyX509NameMatch(peerCertificate, v.options.VerifyName, v.options.VerifyNameType)
	if err != nil {
		return err
	}
	err = verifyPeerFingerprint(peerCertificate, v.options.PeerFingerprints)
	if err != nil {
		return err
	}
	err = verifyRequiredKeyUsage(peerCertificate, v.options.RequiredKeyUsage)
	if err != nil {
		return err
	}
	if v.options.RequireKeyUsageExtension {
		err = verifyKeyUsageExtensionPresent(peerCertificate)
		if err != nil {
			return err
		}
	}
	err = verifyRequiredExtendedKeyUsage(peerCertificate, v.options.RequiredExtendedUsage)
	if err != nil {
		return err
	}
	return verifyNSCertType(peerCertificate, v.options.NSCertificateType)
}

var insecureCertificateValidationKey struct {
	once sync.Once
	key  *rsa.PrivateKey
	err  error
}

func verifyInsecureCertificateChain(rawCertificates [][]byte, roots *certificatePool) ([][]*x509.Certificate, error) {
	peerCertificates := make([]*x509.Certificate, 0, len(rawCertificates))
	for _, rawCertificate := range rawCertificates {
		peerCertificate, err := x509.ParseCertificate(rawCertificate)
		if err != nil {
			return nil, err
		}
		peerCertificates = append(peerCertificates, peerCertificate)
	}
	insecureCertificateValidationKey.once.Do(func() {
		insecureCertificateValidationKey.key, insecureCertificateValidationKey.err = rsa.GenerateKey(rand.Reader, 2048)
	})
	if insecureCertificateValidationKey.err != nil {
		return nil, insecureCertificateValidationKey.err
	}
	validationKey := insecureCertificateValidationKey.key
	originalBySynthetic := make(map[*x509.Certificate]*x509.Certificate, len(peerCertificates)+len(roots.certificates))
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
		syntheticCertificate := &cloned
		originalBySynthetic[syntheticCertificate] = original
		return syntheticCertificate, nil
	}
	syntheticPeerCertificates := make([]*x509.Certificate, 0, len(peerCertificates))
	for _, peerCertificate := range peerCertificates {
		syntheticCertificate, err := cloneCertificate(peerCertificate)
		if err != nil {
			return nil, err
		}
		syntheticPeerCertificates = append(syntheticPeerCertificates, syntheticCertificate)
	}
	syntheticIntermediates := x509.NewCertPool()
	for _, intermediate := range syntheticPeerCertificates[1:] {
		syntheticIntermediates.AddCert(intermediate)
	}
	syntheticRoots := x509.NewCertPool()
	for _, root := range roots.certificates {
		syntheticRoot, err := cloneCertificate(root)
		if err != nil {
			return nil, err
		}
		syntheticRoots.AddCert(syntheticRoot)
	}
	syntheticChains, err := syntheticPeerCertificates[0].Verify(x509.VerifyOptions{
		Roots:         syntheticRoots,
		Intermediates: syntheticIntermediates,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
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
				return nil, E.New("unmapped certificate in verified chain")
			}
			chain = append(chain, originalCertificate)
		}
		validSignatures := true
		for certificateIndex := 0; certificateIndex+1 < len(chain); certificateIndex++ {
			signatureErr = verifyInsecureCertificateSignature(chain[certificateIndex], chain[certificateIndex+1])
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

func verifyInsecureCertificateSignature(certificate *x509.Certificate, parent *x509.Certificate) error {
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

func enforceCertificateProfile(verifiedChain []*x509.Certificate, profile string) error {
	if profile == "" {
		profile = "legacy"
	}
	for _, chainCertificate := range verifiedChain {
		err := enforceCertificateProfilePublicKey(chainCertificate, profile)
		if err != nil {
			return err
		}
		err = enforceCertificateProfileSignatureAlgorithm(chainCertificate, profile)
		if err != nil {
			return err
		}
	}
	return nil
}

func enforceCertificateProfilePublicKey(peerCertificate *x509.Certificate, profile string) error {
	if profile == "insecure" {
		return nil
	}
	if profile == "suiteb" {
		publicKey, loaded := peerCertificate.PublicKey.(*ecdsa.PublicKey)
		if !loaded {
			return E.New("tls-cert-profile suiteb requires ECDSA certificates")
		}
		curveBits := publicKey.Curve.Params().BitSize
		if curveBits != 256 && curveBits != 384 {
			return E.New("tls-cert-profile suiteb requires ECDSA P-256 or P-384")
		}
		return nil
	}
	switch publicKey := peerCertificate.PublicKey.(type) {
	case *rsa.PublicKey:
		minimumBits := 1024
		if profile == "preferred" {
			minimumBits = 2048
		}
		if publicKey.N.BitLen() < minimumBits {
			return E.New("tls-cert-profile ", profile, " rejects RSA key smaller than ", minimumBits, " bits")
		}
	}
	return nil
}

func enforceCertificateProfileSignatureAlgorithm(peerCertificate *x509.Certificate, profile string) error {
	if profile == "insecure" {
		return nil
	}
	signatureAlgorithm := peerCertificate.SignatureAlgorithm
	if profile == "suiteb" {
		if signatureAlgorithm != x509.ECDSAWithSHA256 && signatureAlgorithm != x509.ECDSAWithSHA384 {
			return E.New("tls-cert-profile suiteb requires ECDSA with SHA-256 or SHA-384")
		}
		return nil
	}
	switch signatureAlgorithm {
	case x509.MD2WithRSA, x509.MD5WithRSA:
		return E.New("tls-cert-profile ", profile, " rejects insecure signature algorithm")
	case x509.SHA1WithRSA, x509.DSAWithSHA1, x509.ECDSAWithSHA1:
		if profile == "preferred" {
			return E.New("tls-cert-profile preferred rejects SHA-1 signature algorithm")
		}
	}
	return nil
}

func verifyLegacyCertificateChain(rawCertificates [][]byte, roots *certificatePool) ([][]*x509.Certificate, error) {
	peerCertificate, err := ctx509.ParseCertificate(rawCertificates[0])
	if err != nil {
		return nil, err
	}
	intermediates := ctx509.NewCertPool()
	for _, rawCertificate := range rawCertificates[1:] {
		intermediate, parseErr := ctx509.ParseCertificate(rawCertificate)
		if parseErr != nil {
			return nil, parseErr
		}
		intermediates.AddCert(intermediate)
	}
	verifyOptions := ctx509.VerifyOptions{
		Roots:         roots.legacy,
		Intermediates: intermediates,
		KeyUsages:     []ctx509.ExtKeyUsage{ctx509.ExtKeyUsageAny},
	}
	legacyChains, err := peerCertificate.Verify(verifyOptions)
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

// Upstream verify_peer_cert (ssl_verify.c) matches --verify-x509-name subject
// against the rendered subject, and name / name-prefix against the username
// taken from the --x509-username-field attribute.
func verifyX509NameMatch(peerCertificate *x509.Certificate, expectedName string, verifyType string) error {
	if expectedName == "" || peerCertificate == nil {
		return nil
	}
	switch verifyType {
	case "", "subject":
		subject, err := formatCertificateSubject(peerCertificate.RawSubject)
		if err != nil {
			return err
		}
		if subject != expectedName {
			return ErrPeerCertificateName
		}
	case "name":
		username, err := certificateUsername(peerCertificate.RawSubject, commonNameAttributeOID)
		if err != nil {
			return err
		}
		if username != expectedName {
			return ErrPeerCertificateName
		}
	case "name-prefix":
		username, err := certificateUsername(peerCertificate.RawSubject, commonNameAttributeOID)
		if err != nil {
			return err
		}
		if !strings.HasPrefix(username, expectedName) {
			return ErrPeerCertificateName
		}
	default:
		return E.New("unknown X.509 name type: ", verifyType)
	}
	return nil
}

// Upstream x509_verify_cert_ku compares --remote-cert-ku against the
// OpenSSL MSB-first key usage layout.
func verifyRequiredKeyUsage(peerCertificate *x509.Certificate, requiredKeyUsage []uint) error {
	if len(requiredKeyUsage) == 0 || requiredKeyUsage[0] == 0 {
		return nil
	}
	openSSLKeyUsage, present, err := reconstructOpenSSLKeyUsage(peerCertificate)
	if err != nil {
		return err
	}
	if !present {
		return ErrPeerCertificateKeyUsage
	}
	for _, candidateKeyUsage := range requiredKeyUsage {
		if candidateKeyUsage != 0 && openSSLKeyUsage&candidateKeyUsage == candidateKeyUsage {
			return nil
		}
	}
	return ErrPeerCertificateKeyUsage
}

// Upstream x509_verify_cert_ku reads id-ce-keyUsage MSB-first and applies
// the low-byte fixup to build the OpenSSL key usage mask.
func reconstructOpenSSLKeyUsage(peerCertificate *x509.Certificate) (uint, bool, error) {
	for _, extension := range peerCertificate.Extensions {
		if !extension.Id.Equal(keyUsageExtensionOID) {
			continue
		}
		var bitString asn1.BitString
		_, err := asn1.Unmarshal(extension.Value, &bitString)
		if err != nil {
			return 0, false, err
		}
		var openSSLKeyUsage uint
		for i := range 8 {
			if bitString.At(i) == 1 {
				openSSLKeyUsage |= 1 << (7 - i)
			}
		}
		if openSSLKeyUsage&0xff == 0 {
			openSSLKeyUsage >>= 8
		}
		return openSSLKeyUsage, true, nil
	}
	return 0, false, nil
}

// Upstream x509_verify_cert_ku treats OPENVPN_KU_REQUIRED as "extension
// present, bits checked by TLS library".
func verifyKeyUsageExtensionPresent(peerCertificate *x509.Certificate) error {
	if !certificateHasKeyUsageExtension(peerCertificate) {
		return ErrPeerCertificateKeyUsage
	}
	return nil
}

func certificateHasKeyUsageExtension(certificate *x509.Certificate) bool {
	return slices.ContainsFunc(certificate.Extensions, func(extension pkix.Extension) bool {
		return extension.Id.Equal(keyUsageExtensionOID)
	})
}

var keyUsageExtensionOID = asn1.ObjectIdentifier{2, 5, 29, 15}

var netscapeCertTypeExtensionOID = asn1.ObjectIdentifier{2, 16, 840, 1, 113730, 1, 1}

// OpenSSL NS_SSL_CLIENT / NS_SSL_SERVER, read MSB-first.
const (
	netscapeCertTypeSSLClient = 0x80
	netscapeCertTypeSSLServer = 0x40
)

// Upstream x509_verify_ns_cert_type delegates --ns-cert-type to
// X509_check_purpose with X509_PURPOSE_SSL_CLIENT / X509_PURPOSE_SSL_SERVER.
func verifyNSCertType(peerCertificate *x509.Certificate, requirement string) error {
	var purpose certificatePurpose
	switch requirement {
	case "":
		return nil
	case "server":
		purpose = certificatePurposeSSLServer
	case "client":
		purpose = certificatePurposeSSLClient
	default:
		return E.New("ns-cert-type must be 'server' or 'client', got: ", requirement)
	}
	matched, err := checkCertificatePurpose(peerCertificate, purpose, false)
	if err != nil {
		return err
	}
	if !matched {
		return ErrPeerCertificateNSCertType
	}
	return nil
}

func verifyRequiredExtendedKeyUsage(peerCertificate *x509.Certificate, requiredExtendedUsage []asn1.ObjectIdentifier) error {
	if len(requiredExtendedUsage) == 0 {
		return nil
	}
	certificateExtendedUsage, err := readCertificateExtendedKeyUsage(peerCertificate)
	if err != nil {
		return err
	}
	for _, expectedExtendedUsage := range requiredExtendedUsage {
		matched := slices.ContainsFunc(certificateExtendedUsage, expectedExtendedUsage.Equal)
		if !matched {
			return ErrPeerCertificateExtUsage
		}
	}
	return nil
}

var extendedKeyUsageExtensionOID = asn1.ObjectIdentifier{2, 5, 29, 37}

func readCertificateExtendedKeyUsage(peerCertificate *x509.Certificate) ([]asn1.ObjectIdentifier, error) {
	for _, extension := range peerCertificate.Extensions {
		if !extension.Id.Equal(extendedKeyUsageExtensionOID) {
			continue
		}
		var usages []asn1.ObjectIdentifier
		_, err := asn1.Unmarshal(extension.Value, &usages)
		return usages, err
	}
	return nil, nil
}

// Upstream tls_ctx_reload_crl loads every CRL in the --crl-verify file into
// the store and sets CRL_CHECK | CRL_CHECK_ALL, so OpenSSL check_revocation
// runs check_cert at every chain depth including the trust anchor.
func verifyAgainstCRL(chain []*x509.Certificate, crlPath string) error {
	if crlPath == "" {
		return nil
	}
	revocationLists, err := loadRevocationLists(crlPath)
	if err != nil {
		return err
	}
	if len(chain) == 0 {
		return ErrCRLUnavailable
	}
	now := time.Now()
	for depth := range chain {
		err = checkChainDepthAgainstCRL(chain, depth, revocationLists, now)
		if err != nil {
			return err
		}
	}
	return nil
}

// Upstream OpenSSL check_cert scores every CRL issued by the certificate's
// issuer, prefers one inside its validity window, and only then runs check_crl
// and cert_crl on the winner; a depth with no scoring CRL is
// X509_V_ERR_UNABLE_TO_GET_CRL.
func checkChainDepthAgainstCRL(chain []*x509.Certificate, depth int, revocationLists []*x509.RevocationList, now time.Time) error {
	certificate := chain[depth]
	issuerDepth := depth
	if depth < len(chain)-1 {
		issuerDepth = depth + 1
	}
	var selectedList *x509.RevocationList
	var selectedSigner *x509.Certificate
	var selectedWithinValidity bool
	for _, revocationList := range revocationLists {
		if !bytes.Equal(revocationList.RawIssuer, certificate.RawIssuer) {
			continue
		}
		signer := findCRLSignerInChain(chain[issuerDepth:], revocationList.RawIssuer)
		if signer == nil {
			continue
		}
		withinValidity := revocationListValidityError(revocationList, now) == nil
		outscoresSelected := selectedList == nil || withinValidity && !selectedWithinValidity
		if !outscoresSelected {
			continue
		}
		selectedList = revocationList
		selectedSigner = signer
		selectedWithinValidity = withinValidity
	}
	if selectedList == nil {
		return ErrCRLUnavailable
	}
	if certificateHasKeyUsageExtension(selectedSigner) && selectedSigner.KeyUsage&x509.KeyUsageCRLSign == 0 {
		return ErrCRLIssuerKeyUsage
	}
	err := revocationListValidityError(selectedList, now)
	if err != nil {
		return err
	}
	err = selectedList.CheckSignatureFrom(selectedSigner)
	if err != nil {
		return ErrCRLSignatureInvalid
	}
	for _, revokedEntry := range selectedList.RevokedCertificateEntries {
		if revokedEntry.SerialNumber == nil || certificate.SerialNumber == nil {
			continue
		}
		if revokedEntry.SerialNumber.Cmp(certificate.SerialNumber) == 0 {
			return ErrPeerCertificateRevoked
		}
	}
	return nil
}

// Upstream OpenSSL check_crl_time rejects a CRL whose lastUpdate is in the
// future or whose nextUpdate has passed.
func revocationListValidityError(revocationList *x509.RevocationList, now time.Time) error {
	if now.Before(revocationList.ThisUpdate) {
		return ErrCRLExpired
	}
	if !revocationList.NextUpdate.IsZero() && now.After(revocationList.NextUpdate) {
		return ErrCRLExpired
	}
	return nil
}

// Upstream OpenSSL check_crl resolves the CRL issuer at the next chain depth
// and, failing that, anywhere above it in the chain.
func findCRLSignerInChain(chain []*x509.Certificate, rawIssuer []byte) *x509.Certificate {
	for _, candidate := range chain {
		if bytes.Equal(candidate.RawSubject, rawIssuer) {
			return candidate
		}
	}
	return nil
}

// Upstream tls_ctx_reload_crl reads PEM CRL blocks in a loop until the buffer
// is exhausted, so a --crl-verify file holds one CRL per issuing CA.
func loadRevocationLists(crlPath string) ([]*x509.RevocationList, error) {
	crlBytes, err := os.ReadFile(crlPath)
	if err != nil {
		return nil, err
	}
	var revocationLists []*x509.RevocationList
	remaining := crlBytes
	for len(remaining) > 0 {
		pemBlock, rest := pem.Decode(remaining)
		if pemBlock == nil {
			break
		}
		remaining = rest
		if pemBlock.Type != "X509 CRL" && pemBlock.Type != "CRL" {
			continue
		}
		revocationList, parseErr := x509.ParseRevocationList(pemBlock.Bytes)
		if parseErr != nil {
			return nil, parseErr
		}
		revocationLists = append(revocationLists, revocationList)
	}
	if len(revocationLists) == 0 {
		revocationList, parseErr := x509.ParseRevocationList(crlBytes)
		if parseErr != nil {
			return nil, parseErr
		}
		revocationLists = append(revocationLists, revocationList)
	}
	return revocationLists, nil
}

func parseRemoteCertKeyUsages(values []string) ([]uint, error) {
	if len(values) == 0 {
		return nil, nil
	}
	parsedValues := make([]uint, 0, len(values))
	for _, value := range values {
		if value == "" {
			return nil, E.New("empty key usage hex")
		}
		parsed, err := parseHexKeyUsage(value)
		if err != nil {
			return nil, err
		}
		parsedValues = append(parsedValues, parsed)
	}
	return parsedValues, nil
}

// Upstream add_option parses --remote-cert-ku with sscanf("%x").
func parseHexKeyUsage(value string) (uint, error) {
	if value == "" {
		return 0, E.New("empty key usage hex")
	}
	parsed, err := strconv.ParseUint(value, 16, strconv.IntSize)
	if err != nil {
		return 0, err
	}
	return uint(parsed), nil
}

func parseRemoteCertExtKeyUsage(value string) ([]asn1.ObjectIdentifier, error) {
	if value == "" {
		return nil, nil
	}
	if knownUsage, loaded := openSSLKeyPurposeNames[value]; loaded {
		return []asn1.ObjectIdentifier{knownUsage}, nil
	}
	usage, err := parseObjectIdentifier(value)
	if err != nil {
		return nil, E.New("unsupported remote-cert-eku value: ", value)
	}
	return []asn1.ObjectIdentifier{usage}, nil
}

// Upstream add_option expands --remote-cert-tls into KU-required plus EKU.
func expandRemoteCertTLS(mode string, peerRole string) (bool, []asn1.ObjectIdentifier, error) {
	if mode == "" {
		return false, nil, nil
	}
	switch mode {
	case "server":
		_ = peerRole
		return true, []asn1.ObjectIdentifier{serverAuthOID}, nil
	case "client":
		return true, []asn1.ObjectIdentifier{clientAuthOID}, nil
	default:
		return false, nil, E.New("remote-cert-tls must be 'client' or 'server', got: ", mode)
	}
}

func mergeExtendedKeyUsage(existing []asn1.ObjectIdentifier, additional []asn1.ObjectIdentifier) []asn1.ObjectIdentifier {
	if len(additional) == 0 {
		return existing
	}
	if len(existing) == 0 {
		return additional
	}
	merged := make([]asn1.ObjectIdentifier, 0, len(existing)+len(additional))
	merged = append(merged, existing...)
	for _, addition := range additional {
		if !slices.ContainsFunc(merged, addition.Equal) {
			merged = append(merged, addition)
		}
	}
	return merged
}

var (
	serverAuthOID          = asn1.ObjectIdentifier{1, 3, 6, 1, 5, 5, 7, 3, 1}
	clientAuthOID          = asn1.ObjectIdentifier{1, 3, 6, 1, 5, 5, 7, 3, 2}
	openSSLKeyPurposeNames = map[string]asn1.ObjectIdentifier{
		"server":                            serverAuthOID,
		"client":                            clientAuthOID,
		"TLS Web Server Authentication":     serverAuthOID,
		"TLS Web Client Authentication":     clientAuthOID,
		"Code Signing":                      {1, 3, 6, 1, 5, 5, 7, 3, 3},
		"E-mail Protection":                 {1, 3, 6, 1, 5, 5, 7, 3, 4},
		"IPSec End System":                  {1, 3, 6, 1, 5, 5, 7, 3, 5},
		"IPSec Tunnel":                      {1, 3, 6, 1, 5, 5, 7, 3, 6},
		"IPSec User":                        {1, 3, 6, 1, 5, 5, 7, 3, 7},
		"Time Stamping":                     {1, 3, 6, 1, 5, 5, 7, 3, 8},
		"OCSP Signing":                      {1, 3, 6, 1, 5, 5, 7, 3, 9},
		"Any Extended Key Usage":            {2, 5, 29, 37, 0},
		"Microsoft Server Gated Crypto":     {1, 3, 6, 1, 4, 1, 311, 10, 3, 3},
		"Netscape Server Gated Crypto":      {2, 16, 840, 1, 113730, 4, 1},
		"Microsoft Commercial Code Signing": {1, 3, 6, 1, 4, 1, 311, 2, 1, 22},
		"Microsoft Individual Code Signing": {1, 3, 6, 1, 4, 1, 311, 2, 1, 21},
	}
)

func parseObjectIdentifier(value string) (asn1.ObjectIdentifier, error) {
	parts := strings.Split(value, ".")
	if len(parts) < 2 {
		return nil, E.New("invalid object identifier")
	}
	identifier := make(asn1.ObjectIdentifier, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			return nil, E.New("invalid object identifier")
		}
		component, err := strconv.Atoi(part)
		if err != nil || component < 0 {
			return nil, E.New("invalid object identifier")
		}
		identifier = append(identifier, component)
	}
	if identifier[0] > 2 || identifier[0] < 2 && identifier[1] > 39 {
		return nil, E.New("invalid object identifier")
	}
	return identifier, nil
}

// Upstream verify_cert compares the SHA256 digest of the certificate at
// verify_hash_depth, which --peer-fingerprint pins to the leaf.
func verifyPeerFingerprint(peerCertificate *x509.Certificate, expectedFingerprints []string) error {
	if len(expectedFingerprints) == 0 {
		return nil
	}
	actualFingerprint := computeCertificateFingerprint(peerCertificate.Raw)
	if slices.Contains(expectedFingerprints, actualFingerprint) {
		return nil
	}
	return E.New("peer fingerprint mismatch")
}

func computeCertificateFingerprint(rawCertificate []byte) string {
	digest := sha256.Sum256(rawCertificate)
	return hex.EncodeToString(digest[:])
}
