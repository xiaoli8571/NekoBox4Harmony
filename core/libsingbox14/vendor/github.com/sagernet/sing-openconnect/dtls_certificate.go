package openconnect

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"net"
	"sync"
	"syscall"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"

	"github.com/pion/dtls/v3"
	pionelliptic "github.com/pion/dtls/v3/pkg/crypto/elliptic"
	dtlsnet "github.com/pion/dtls/v3/pkg/net"
)

const (
	certificateDTLSHandshakeTimeout = 15 * time.Second
	certificateDTLSFlightInterval   = 250 * time.Millisecond
	certificateDTLSVersion10        = 0xfeff
	certificateDTLSVersion12        = 0xfefd
)

type certificateDTLSNegotiation struct {
	Address           string
	ServerName        string
	TLSConfig         *tls.Config
	Dialer            N.Dialer
	MTU               int
	LegacyVersion     bool
	AllowLegacyCrypto bool
}

type certificateDTLSConn struct {
	net.Conn
	version     uint16
	cipherSuite uint16
	dataMTU     int
}

func (c *certificateDTLSConn) Version() uint16 {
	return c.version
}

func (c *certificateDTLSConn) CipherSuite() uint16 {
	return c.cipherSuite
}

func (c *certificateDTLSConn) DataMTU() int {
	return c.dataMTU
}

func (c *certificateDTLSConn) Write(payload []byte) (int, error) {
	if c.dataMTU > 0 && len(payload) > c.dataMTU {
		return 0, E.Extend(syscall.EMSGSIZE, "certificate DTLS payload is ", len(payload), " bytes for data MTU ", c.dataMTU)
	}
	return c.Conn.Write(payload)
}

func connectCertificateDTLS(ctx context.Context, negotiation certificateDTLSNegotiation) (*certificateDTLSConn, error) {
	if negotiation.Address == "" {
		return nil, E.New("certificate DTLS server did not provide a UDP address")
	}
	if negotiation.LegacyVersion && !negotiation.AllowLegacyCrypto {
		return nil, E.Extend(ErrDeprecatedCryptoDisabled, "DTLS 1.0")
	}
	dialer := negotiation.Dialer
	if dialer == nil {
		dialer = N.SystemDialer
	}
	udpConn, err := dialer.DialContext(ctx, N.NetworkUDP, M.ParseSocksaddr(negotiation.Address))
	if err != nil {
		return nil, E.Cause(err, "connect certificate DTLS UDP transport")
	}
	if negotiation.LegacyVersion {
		legacyConn, cipherSuite, connectErr := connectCertificateDTLS10(ctx, udpConn, negotiation)
		if connectErr != nil {
			closeErr := udpConn.Close()
			if E.IsClosed(closeErr) {
				closeErr = nil
			}
			return nil, E.Errors(connectErr, closeErr)
		}
		return &certificateDTLSConn{
			Conn:        legacyConn,
			version:     certificateDTLSVersion10,
			cipherSuite: cipherSuite,
			dataMTU:     certificateDTLSCBCDataMTU(negotiation.MTU),
		}, nil
	}

	dtlsConn, connectErr := connectCertificateDTLS12(ctx, udpConn, negotiation)
	if connectErr != nil {
		closeErr := udpConn.Close()
		if E.IsClosed(closeErr) {
			closeErr = nil
		}
		return nil, E.Errors(connectErr, closeErr)
	}
	state, loaded := dtlsConn.ConnectionState()
	if !loaded {
		closeErr := dtlsConn.Close()
		if E.IsClosed(closeErr) {
			closeErr = nil
		}
		return nil, E.Errors(E.New("certificate DTLS 1.2 connection has no negotiated state"), closeErr)
	}
	return &certificateDTLSConn{
		Conn:        dtlsConn,
		version:     certificateDTLSVersion12,
		cipherSuite: uint16(state.CipherSuiteID),
		dataMTU:     certificateDTLS12DataMTU(negotiation.MTU, state.CipherSuiteID),
	}, nil
}

func connectCertificateDTLS12(
	ctx context.Context,
	udpConn net.Conn,
	negotiation certificateDTLSNegotiation,
) (*dtls.Conn, error) {
	tlsConfig := &tls.Config{}
	if negotiation.TLSConfig != nil {
		tlsConfig = cloneTLSConfig(negotiation.TLSConfig)
	}
	if tlsConfig.MinVersion > tls.VersionTLS12 || tlsConfig.MaxVersion != 0 && tlsConfig.MaxVersion < tls.VersionTLS12 {
		return nil, E.Extend(ErrProtocolNotSupported, "TLS version policy excludes certificate DTLS 1.2")
	}
	serverName := tlsConfig.ServerName
	if serverName == "" {
		serverName = negotiation.ServerName
	}
	options := []dtls.ClientOption{
		dtls.WithFlightInterval(certificateDTLSFlightInterval),
		dtls.WithInsecureSkipVerify(true),
	}
	if serverName != "" {
		options = append(options, dtls.WithServerName(serverName))
	}
	if negotiation.MTU > 0 {
		handshakeMTU := certificateDTLSPionHandshakeMTU(negotiation.MTU)
		if handshakeMTU <= 0 {
			return nil, E.New("certificate DTLS MTU is too small: ", negotiation.MTU)
		}
		options = append(options, dtls.WithMTU(handshakeMTU))
	}
	if len(tlsConfig.Certificates) > 0 {
		options = append(options, dtls.WithCertificates(tlsConfig.Certificates...))
	}
	if len(tlsConfig.NextProtos) > 0 {
		options = append(options, dtls.WithSupportedProtocols(tlsConfig.NextProtos...))
	}
	if tlsConfig.KeyLogWriter != nil {
		options = append(options, dtls.WithKeyLogWriter(tlsConfig.KeyLogWriter))
	}
	curves, err := certificateDTLS12Curves(tlsConfig.CurvePreferences)
	if err != nil {
		return nil, err
	}
	if len(curves) > 0 {
		options = append(options, dtls.WithEllipticCurves(curves...))
	}
	if tlsConfig.GetClientCertificate != nil {
		options = append(options, dtls.WithGetClientCertificate(func(request *dtls.CertificateRequestInfo) (*tls.Certificate, error) {
			// Pion v3.1.5 flight5Generate copies only CertificateAuthoritiesNames into CertificateRequestInfo;
			// the peer's SignatureHashAlgorithms are not exposed by its callback API.
			certificate, certificateErr := tlsConfig.GetClientCertificate(&tls.CertificateRequestInfo{
				AcceptableCAs:    cloneByteSlices(request.AcceptableCAs),
				SignatureSchemes: nil,
				Version:          tls.VersionTLS12,
			})
			if certificateErr != nil {
				return nil, E.Cause(certificateErr, "select certificate DTLS client certificate")
			}
			return certificate, nil
		}))
	}
	cipherSuites, err := certificateDTLS12CipherSuites(tlsConfig.CipherSuites)
	if err != nil {
		return nil, err
	}
	if len(cipherSuites) > 0 {
		options = append(options, dtls.WithCipherSuites(cipherSuites...))
	}

	var verificationAccess sync.Mutex
	var peerCertificates []*x509.Certificate
	var verifiedChains [][]*x509.Certificate
	options = append(options, dtls.WithVerifyPeerCertificate(func(rawCertificates [][]byte, _ [][]*x509.Certificate) error {
		parsedCertificates, chains, verifyErr := verifyCertificateDTLSChain(tlsConfig, serverName, rawCertificates)
		if verifyErr != nil {
			return verifyErr
		}
		verificationAccess.Lock()
		peerCertificates = parsedCertificates
		verifiedChains = cloneCertificateChains(chains)
		verificationAccess.Unlock()
		if tlsConfig.VerifyPeerCertificate != nil {
			verifyErr = tlsConfig.VerifyPeerCertificate(cloneByteSlices(rawCertificates), cloneCertificateChains(chains))
			if verifyErr != nil {
				return E.Cause(verifyErr, "verify certificate DTLS peer certificate")
			}
		}
		return nil
	}))
	if tlsConfig.VerifyConnection != nil {
		options = append(options, dtls.WithVerifyConnection(func(state *dtls.State) error {
			verificationAccess.Lock()
			connectionState := tls.ConnectionState{
				Version:                    tls.VersionTLS12,
				HandshakeComplete:          false,
				CipherSuite:                uint16(state.CipherSuiteID),
				NegotiatedProtocol:         state.NegotiatedProtocol,
				NegotiatedProtocolIsMutual: true,
				ServerName:                 serverName,
				PeerCertificates:           append([]*x509.Certificate(nil), peerCertificates...),
				VerifiedChains:             cloneCertificateChains(verifiedChains),
			}
			verificationAccess.Unlock()
			verifyErr := tlsConfig.VerifyConnection(connectionState)
			if verifyErr != nil {
				return E.Cause(verifyErr, "verify certificate DTLS connection")
			}
			return nil
		}))
	}

	packetConn := dtlsnet.PacketConnFromConn(udpConn)
	dtlsConn, err := dtls.ClientWithOptions(packetConn, udpConn.RemoteAddr(), options...)
	if err != nil {
		return nil, E.Cause(err, "create certificate DTLS 1.2 client")
	}
	handshakeCtx, cancel := context.WithTimeout(ctx, certificateDTLSHandshakeTimeout)
	defer cancel()
	err = dtlsConn.HandshakeContext(handshakeCtx)
	if err != nil {
		closeErr := dtlsConn.Close()
		if E.IsClosed(closeErr) {
			closeErr = nil
		}
		return nil, E.Errors(E.Cause(err, "establish certificate DTLS 1.2"), closeErr)
	}
	return dtlsConn, nil
}

func certificateDTLS12Curves(configured []tls.CurveID) ([]pionelliptic.Curve, error) {
	if len(configured) == 0 {
		return nil, nil
	}
	curves := make([]pionelliptic.Curve, 0, len(configured))
	for _, curve := range configured {
		switch curve {
		case tls.X25519:
			curves = append(curves, pionelliptic.X25519)
		case tls.CurveP256:
			curves = append(curves, pionelliptic.P256)
		case tls.CurveP384:
			curves = append(curves, pionelliptic.P384)
		}
	}
	if len(curves) == 0 {
		return nil, E.Extend(ErrProtocolNotSupported, "configured TLS curves have no certificate DTLS 1.2 equivalent")
	}
	return curves, nil
}

func certificateDTLSPionHandshakeMTU(mtu int) int {
	// Pion v3.1.5 fragmentHandshake splits only the handshake body at Config.MTU, then adds the 12-byte handshake header, 13-byte record header, and record-protection overhead.
	return mtu - 77
}

func certificateDTLS12CipherSuites(configured []uint16) ([]dtls.CipherSuiteID, error) {
	if len(configured) == 0 {
		return []dtls.CipherSuiteID{
			dtls.TLS_ECDHE_ECDSA_WITH_AES_128_CCM,
			dtls.TLS_ECDHE_ECDSA_WITH_AES_128_CCM_8,
			dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
			dtls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
			dtls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
			dtls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
			dtls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
			dtls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
			dtls.TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA,
			dtls.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
		}, nil
	}
	result := make([]dtls.CipherSuiteID, 0, len(configured))
	for _, cipherSuite := range configured {
		switch dtls.CipherSuiteID(cipherSuite) {
		case dtls.TLS_ECDHE_ECDSA_WITH_AES_128_CCM,
			dtls.TLS_ECDHE_ECDSA_WITH_AES_128_CCM_8,
			dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
			dtls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
			dtls.TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA,
			dtls.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
			dtls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
			dtls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
			dtls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
			dtls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:
			result = append(result, dtls.CipherSuiteID(cipherSuite))
		}
	}
	if len(result) == 0 {
		return nil, E.Extend(ErrProtocolNotSupported, "configured TLS cipher suites have no certificate DTLS 1.2 equivalent")
	}
	return result, nil
}

func verifyCertificateDTLSChain(
	tlsConfig *tls.Config,
	serverName string,
	rawCertificates [][]byte,
) ([]*x509.Certificate, [][]*x509.Certificate, error) {
	certificates := make([]*x509.Certificate, 0, len(rawCertificates))
	for _, rawCertificate := range rawCertificates {
		certificate, parseErr := x509.ParseCertificate(rawCertificate)
		if parseErr != nil {
			return nil, nil, E.Cause(parseErr, "parse certificate DTLS peer certificate")
		}
		certificates = append(certificates, certificate)
	}
	if len(certificates) == 0 {
		return nil, nil, E.New("certificate DTLS peer did not provide a certificate")
	}
	if tlsConfig.InsecureSkipVerify {
		return certificates, nil, nil
	}
	roots := tlsConfig.RootCAs
	if roots == nil {
		systemRoots, rootsErr := x509.SystemCertPool()
		if rootsErr != nil {
			return nil, nil, E.Cause(rootsErr, "load certificate DTLS system roots")
		}
		roots = systemRoots
	}
	intermediates := x509.NewCertPool()
	for _, certificate := range certificates[1:] {
		intermediates.AddCert(certificate)
	}
	currentTime := time.Now()
	if tlsConfig.Time != nil {
		currentTime = tlsConfig.Time()
	}
	chains, verifyErr := certificates[0].Verify(x509.VerifyOptions{
		DNSName:       serverName,
		Roots:         roots,
		Intermediates: intermediates,
		CurrentTime:   currentTime,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	})
	if verifyErr != nil {
		return nil, nil, E.Cause(verifyErr, "verify certificate DTLS server certificate")
	}
	return certificates, chains, nil
}

func cloneCertificateChains(chains [][]*x509.Certificate) [][]*x509.Certificate {
	result := make([][]*x509.Certificate, len(chains))
	for i, chain := range chains {
		result[i] = append([]*x509.Certificate(nil), chain...)
	}
	return result
}

func certificateDTLS12DataMTU(mtu int, cipherSuite dtls.CipherSuiteID) int {
	if mtu <= 0 {
		return 0
	}
	switch cipherSuite {
	case dtls.TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA, dtls.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA:
		return certificateDTLSCBCDataMTU(mtu)
	case dtls.TLS_ECDHE_ECDSA_WITH_AES_128_CCM_8:
		return mtu - 13 - 8 - 8
	case dtls.TLS_ECDHE_ECDSA_WITH_AES_128_CCM:
		return mtu - 13 - 8 - 16
	default:
		return mtu - 13 - 8 - 16
	}
}

func certificateDTLSCBCDataMTU(mtu int) int {
	if mtu <= 29 {
		return 0
	}
	dataMTU := ((mtu - 29) / 16 * 16) - 21
	if dataMTU < 0 {
		return 0
	}
	return dataMTU
}
