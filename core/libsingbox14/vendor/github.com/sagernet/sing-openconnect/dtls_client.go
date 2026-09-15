package openconnect

import (
	"context"
	"crypto/tls"
	"net"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"

	"github.com/pion/dtls/v3"
	dtlsnet "github.com/pion/dtls/v3/pkg/net"
	"github.com/pion/dtls/v3/pkg/protocol/handshake"
)

const (
	anyConnectDTLSExporterLabel = "EXPORTER-openconnect-psk"
	anyConnectDTLSPSKIdentity   = "psk"
	anyConnectDTLSHandshake     = 15 * time.Second
)

type cstpDTLSNegotiation struct {
	Address             string
	CipherSuite         string
	DTLS12              bool
	SessionID           []byte
	AppID               []byte
	MasterSecret        []byte
	DPD                 time.Duration
	Keepalive           time.Duration
	Rekey               time.Duration
	RekeyMethod         string
	TLSConnection       *tls.Conn
	Dialer              N.Dialer
	MTU                 int
	MinimumMTU          int
	AllowInsecureCrypto bool
	Compression         anyConnectCompression
	Logger              logger.ContextLogger
	RequestRekey        func(method string) error
}

type anyConnectDTLSSessionStore struct {
	session dtls.Session
}

func (s *anyConnectDTLSSessionStore) Set(_ []byte, session dtls.Session) error {
	s.session = dtls.Session{
		ID:     append([]byte(nil), session.ID...),
		Secret: append([]byte(nil), session.Secret...),
	}
	return nil
}

func (s *anyConnectDTLSSessionStore) Get(_ []byte) (dtls.Session, error) {
	return dtls.Session{
		ID:     append([]byte(nil), s.session.ID...),
		Secret: append([]byte(nil), s.session.Secret...),
	}, nil
}

func (s *anyConnectDTLSSessionStore) Del(_ []byte) error {
	return nil
}

func (c *anyConnectDTLSChannel) connect() (net.Conn, error) {
	if c.negotiation.Address == "" {
		return nil, E.New("DTLS: server did not provide a UDP address")
	}
	dialer := c.negotiation.Dialer
	if dialer == nil {
		dialer = N.SystemDialer
	}
	udpConn, err := dialer.DialContext(c.ctx, N.NetworkUDP, M.ParseSocksaddr(c.negotiation.Address))
	if err != nil {
		return nil, E.Cause(err, "connect DTLS UDP transport")
	}

	if isAnyConnectLegacyDTLS(c.negotiation.CipherSuite, c.negotiation.DTLS12) {
		legacyConn, legacyErr := c.connectLegacy(udpConn)
		if legacyErr != nil {
			closeErr := udpConn.Close()
			if E.IsClosed(closeErr) {
				closeErr = nil
			}
			return nil, E.Errors(legacyErr, closeErr)
		}
		return legacyConn, nil
	}

	packetConn := dtlsnet.PacketConnFromConn(udpConn)
	var dtlsConn *dtls.Conn
	if c.negotiation.CipherSuite == "PSK-NEGOTIATE" {
		dtlsConn, err = c.connectModernPSK(packetConn, udpConn.RemoteAddr())
	} else {
		dtlsConn, err = c.connectInjectedResume(packetConn, udpConn.RemoteAddr())
	}
	if err != nil {
		closeErr := udpConn.Close()
		if E.IsClosed(closeErr) {
			closeErr = nil
		}
		return nil, E.Errors(err, closeErr)
	}
	return dtlsConn, nil
}

func (c *anyConnectDTLSChannel) connectModernPSK(packetConn net.PacketConn, remoteAddress net.Addr) (*dtls.Conn, error) {
	if c.negotiation.TLSConnection == nil {
		return nil, E.Extend(ErrProtocolNotSupported, "DTLS PSK negotiation requires the live CSTP TLS connection")
	}
	if len(c.negotiation.AppID) > 32 {
		return nil, E.Extend(ErrProtocolNotSupported, "DTLS X-DTLS-App-ID exceeds the ClientHello SessionID limit: ", len(c.negotiation.AppID))
	}

	// Upstream start_dtls_psk_handshake derives this key from the live CSTP session and sets ClientHello.SessionID only when X-DTLS-App-ID is present.
	connectionState := c.negotiation.TLSConnection.ConnectionState()
	psk, err := connectionState.ExportKeyingMaterial(anyConnectDTLSExporterLabel, nil, 32)
	if err != nil {
		return nil, E.Cause(err, "export DTLS PSK from CSTP TLS session")
	}
	options := []dtls.ClientOption{
		dtls.WithPSK(func([]byte) ([]byte, error) {
			return psk, nil
		}),
		dtls.WithPSKIdentityHint([]byte(anyConnectDTLSPSKIdentity)),
		dtls.WithCipherSuites(
			dtls.TLS_PSK_WITH_CHACHA20_POLY1305_SHA256,
			dtls.TLS_PSK_WITH_AES_128_GCM_SHA256,
			dtls.TLS_PSK_WITH_AES_128_CCM,
			dtls.TLS_PSK_WITH_AES_128_CCM_8,
			dtls.TLS_PSK_WITH_AES_256_CCM_8,
			dtls.TLS_PSK_WITH_AES_128_CBC_SHA256,
		),
		dtls.WithFlightInterval(250 * time.Millisecond),
	}
	if len(c.negotiation.AppID) > 0 {
		applicationID := append([]byte(nil), c.negotiation.AppID...)
		options = append(options, dtls.WithClientHelloMessageHook(func(message handshake.MessageClientHello) handshake.Message {
			message.SessionID = append([]byte(nil), applicationID...)
			return &message
		}))
	}
	dtlsConn, err := dtls.ClientWithOptions(packetConn, remoteAddress, options...)
	if err != nil {
		return nil, E.Cause(err, "create modern PSK DTLS client")
	}
	err = c.handshake(dtlsConn)
	if err != nil {
		closeErr := dtlsConn.Close()
		if E.IsClosed(closeErr) {
			closeErr = nil
		}
		return nil, E.Errors(E.Cause(err, "establish modern PSK DTLS"), closeErr)
	}
	return dtlsConn, nil
}

func (c *anyConnectDTLSChannel) connectInjectedResume(packetConn net.PacketConn, remoteAddress net.Addr) (*dtls.Conn, error) {
	cipherSuite, pskCipher, customCipherSuite, err := anyConnectDTLS12CipherSuite(
		c.negotiation.CipherSuite,
		c.negotiation.DTLS12,
	)
	if err != nil {
		return nil, err
	}
	if len(c.negotiation.SessionID) != 32 {
		return nil, E.Extend(ErrProtocolNotSupported, "DTLS abbreviated resumption requires a 32-byte X-DTLS-Session-ID, got ", len(c.negotiation.SessionID))
	}
	if len(c.negotiation.MasterSecret) != 48 {
		return nil, E.Extend(ErrProtocolNotSupported, "DTLS abbreviated resumption requires a 48-byte master secret, got ", len(c.negotiation.MasterSecret))
	}

	// Upstream start_dtls_resume_handshake injects the CSTP-provided master secret and Session-ID, disables extensions, and requires abbreviated resumption.
	sessionStore := &anyConnectDTLSSessionStore{session: dtls.Session{
		ID:     append([]byte(nil), c.negotiation.SessionID...),
		Secret: append([]byte(nil), c.negotiation.MasterSecret...),
	}}
	options := []dtls.ClientOption{
		dtls.WithSessionStore(sessionStore),
		dtls.WithExtendedMasterSecret(dtls.DisableExtendedMasterSecret),
		dtls.WithFlightInterval(250 * time.Millisecond),
		dtls.WithClientHelloMessageHook(func(message handshake.MessageClientHello) handshake.Message {
			message.Extensions = nil
			message.CipherSuiteIDs = []uint16{uint16(cipherSuite)}
			return &message
		}),
	}
	if customCipherSuite != nil {
		options = append(options, dtls.WithCustomCipherSuites(func() []dtls.CipherSuite {
			return []dtls.CipherSuite{customCipherSuite}
		}))
	} else {
		options = append(options, dtls.WithCipherSuites(cipherSuite))
	}
	if pskCipher {
		masterSecret := append([]byte(nil), c.negotiation.MasterSecret...)
		options = append(options,
			dtls.WithPSK(func([]byte) ([]byte, error) {
				return masterSecret, nil
			}),
			dtls.WithPSKIdentityHint([]byte(anyConnectDTLSPSKIdentity)),
		)
	}
	dtlsConn, err := dtls.ClientWithOptions(packetConn, remoteAddress, options...)
	if err != nil {
		return nil, E.Cause(err, "create injected-resumption DTLS client")
	}
	err = c.handshake(dtlsConn)
	if err != nil {
		closeErr := dtlsConn.Close()
		if E.IsClosed(closeErr) {
			closeErr = nil
		}
		return nil, E.Errors(E.Cause(err, "establish injected-resumption DTLS"), closeErr)
	}
	state, loaded := dtlsConn.ConnectionState()
	if !loaded || !equalBytes(state.SessionID, c.negotiation.SessionID) || state.CipherSuiteID != cipherSuite {
		closeErr := dtlsConn.Close()
		if E.IsClosed(closeErr) {
			closeErr = nil
		}
		return nil, E.Errors(E.New("DTLS server did not accept the required abbreviated session resumption"), closeErr)
	}
	return dtlsConn, nil
}

func (c *anyConnectDTLSChannel) handshake(dtlsConn *dtls.Conn) error {
	handshakeCtx, cancel := context.WithTimeout(c.ctx, anyConnectDTLSHandshake)
	defer cancel()
	return dtlsConn.HandshakeContext(handshakeCtx)
}

func equalBytes(left []byte, right []byte) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}
