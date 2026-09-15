package openconnect

import (
	"context"
	"crypto/tls"
	"time"

	"github.com/sagernet/sing/common/logger"
	N "github.com/sagernet/sing/common/network"
)

const (
	TokenModeTOTP   = "totp"
	TokenModeHOTP   = "hotp"
	TokenModeSToken = "stoken"
	TokenModeOIDC   = "oidc"

	CompressionModeStateless = "stateless"
	CompressionModeAll       = "all"
)

type TokenOptions struct {
	Mode          string
	Secret        string
	SecretPath    string
	PIN           string
	Password      string
	DeviceID      string
	Counter       uint64
	UpdateCounter func(ctx context.Context, counter uint64) error
}

type CSDOptions struct {
	WrapperPath string
}

type HIPOptions struct {
	WrapperPath string
}

type TNCCOptions struct {
	WrapperPath                  string
	DeviceID                     string
	UserAgent                    string
	MachineIdentificationEnabled bool
	Certificates                 []Material
}

type FortinetHostCheckOptions struct {
	HostCheck           string
	CheckVirtualDesktop string
}

type FormEntry struct {
	FormID        string
	SubmissionKey string
	Name          string
	Value         string
	Promote       bool
}

type MobileOptions struct {
	PlatformVersion string
	DeviceType      string
	DeviceUniqueID  string
}

type ClientTLSOptions struct {
	Config                           *tls.Config
	ServerName                       string
	SystemTrustDisabled              bool
	CertificateExpiryWarning         time.Duration
	CertificateExpiryWarningDisabled bool
	PeerFingerprints                 []string
	CertificateAuthority             Material
	Certificate                      Material
	Key                              Material
	KeyPassword                      string
	MCACertificate                   Material
	MCAKey                           Material
	MCAKeyPassword                   string
}

type ClientOptions struct {
	Context                        context.Context
	Server                         string
	Flavor                         string
	Username                       string
	Password                       string
	AuthGroup                      string
	Cookie                         string
	Token                          *TokenOptions
	ReportedOS                     string
	UserAgent                      string
	Version                        string
	LocalHostname                  string
	Mobile                         *MobileOptions
	CSD                            *CSDOptions
	HIP                            *HIPOptions
	TNCC                           *TNCCOptions
	FortinetHostCheck              *FortinetHostCheckOptions
	NoUDP                          bool
	DTLSLocalPort                  uint16
	DTLSCipherSuites               string
	DTLS12CipherSuites             string
	CompressionDisabled            bool
	CompressionMode                string
	IPv6Disabled                   bool
	HTTPKeepAliveDisabled          bool
	XMLPostDisabled                bool
	ExternalAuthDisabled           bool
	PasswordAuthenticationDisabled bool
	AllowInsecureCrypto            bool
	PFS                            bool
	MTU                            uint32
	BaseMTU                        uint32
	QueueLength                    uint32
	DPDInterval                    time.Duration
	ReconnectTimeout               time.Duration
	TrojanInterval                 time.Duration
	TLSConfig                      ClientTLSOptions
	FormEntries                    []FormEntry
	Dialer                         N.Dialer
	Logger                         logger.ContextLogger
	OnTunnelConfiguration          func(event TunnelConfigurationEvent) error
}
