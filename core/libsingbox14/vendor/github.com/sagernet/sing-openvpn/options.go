package openvpn

import (
	"context"
	"net"
	"net/netip"
	"os"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/common/logger"
)

const (
	ModeTLS       = "tls"
	ModeStaticKey = "static_key"
)

type PullFilter struct {
	Action string
	Text   string
}

type Remote struct {
	Host     string
	Port     uint16
	Protocol string
}

type TunnelRoute struct {
	Prefix  netip.Prefix
	Gateway netip.Addr
	Metric  int
}

type TunnelDNSServer struct {
	Priority       int
	Addresses      []netip.AddrPort
	ResolveDomains []string
	DNSSEC         string
	Transport      string
	SNI            string
}

const maxTunnelDNSServerAddresses = 8

type TunnelConfigurationEventReason string

const (
	TunnelConfigurationEventInitial       TunnelConfigurationEventReason = "initial"
	TunnelConfigurationEventPushUpdate    TunnelConfigurationEventReason = "push_update"
	TunnelConfigurationEventRenegotiation TunnelConfigurationEventReason = "renegotiation"
)

type TunnelConfigurationEvent struct {
	Reason        TunnelConfigurationEventReason
	Configuration TunnelConfiguration
}

type UserPassAuthenticator func(ctx context.Context, username string, password string) error

type ClientTransportOptions struct {
	Remotes                     []Remote
	RemoteRandom                bool
	DialContext                 func(ctx context.Context, network string, address string) (net.Conn, error)
	DialContextWithAddressIndex func(ctx context.Context, network string, address string, addressIndex int) (net.Conn, error)
	Protocol                    string
	ExplicitExitNotify          uint32
}

type ClientDataChannelOptions struct {
	MTU              uint32
	MSSFix           uint32
	MSSFixDisabled   bool
	MSSFixMode       string
	Fragment         uint32
	Cipher           string
	Ciphers          []string
	FallbackCipher   string
	Auth             string
	Compression      string
	CompressionLZO   string
	AllowCompression string
	ReplayWindow     uint32
	ReplayWindowTime time.Duration
	PacketHeadroom   int
}

type ClientTLSOptions struct {
	CertificateAuthority Material
	Certificate          Material
	Key                  Material
	Auth                 Material
	Crypt                Material
	CryptV2              Material
	VerifyX509Name       string
	VerifyX509Type       string
	PeerFingerprint      []string
	CRLVerify            string
	RemoteCertificateKU  []string
	RemoteCertificateEKU string
	RemoteCertificateTLS string
	NSCertificateType    string
	VersionMin           string
	VersionMax           string
	CertificateProfile   string
	Cipher               string
	Groups               string
}

type ClientAuthenticationOptions struct {
	Username            string
	Password            string
	AuthRetry           string
	StaticChallenge     string
	StaticChallengeEcho bool
}

type ClientPullOptions struct {
	Enabled     bool
	Filters     []PullFilter
	RouteNoPull bool
}

type ClientTunnelOptions struct {
	DevType              string
	Topology             string
	RedirectGateway      bool
	RedirectGatewayFlags []string
	RedirectPrivate      bool
	RouteMetric          int
	BlockIPv6            bool
	BlockOutsideDNS      bool
	RouteGateway         netip.Addr
	Routes               []TunnelRoute
	DHCPOptions          []string
	LocalAddress         []netip.Prefix
	VPNGateway           netip.Addr
	VPNGatewayIPv6       netip.Addr
}

type ClientTimingOptions struct {
	RenegotiationInterval time.Duration
	RenegotiationDisabled bool
	RenegotiationBytes    uint64
	RenegotiationPackets  uint64
	PingInterval          time.Duration
	PingRestart           time.Duration
	PingRestartDisabled   bool
	TLSTimeout            time.Duration
	HandWindow            time.Duration
}

type ClientOptions struct {
	Context               context.Context
	Mode                  string
	Transport             ClientTransportOptions
	DataChannel           ClientDataChannelOptions
	TLS                   ClientTLSOptions
	Authentication        ClientAuthenticationOptions
	Pull                  ClientPullOptions
	Tunnel                ClientTunnelOptions
	Timing                ClientTimingOptions
	StaticKey             Material
	KeyDirection          int
	OnTunnelConfiguration func(event TunnelConfigurationEvent) error
	Logger                logger.ContextLogger
}

type ServerTransportOptions struct {
	ListenAddress string
	RemoteAddress string
	Listener      net.Listener
	PacketConn    net.PacketConn
	Protocol      string
}

type ServerResourceOptions struct {
	MaxClients                    int
	ConnectFrequency              int
	ConnectFrequencyPeriod        time.Duration
	InitialConnectFrequency       int
	InitialConnectFrequencyPeriod time.Duration
}

type ServerDataChannelOptions struct {
	MTU              uint32
	MSSFix           uint32
	MSSFixDisabled   bool
	MSSFixMode       string
	Cipher           string
	Ciphers          []string
	FallbackCipher   string
	Auth             string
	ReplayWindow     uint32
	ReplayWindowTime time.Duration
	PacketHeadroom   int
}

type ServerTLSOptions struct {
	CertificateAuthority    Material
	Certificate             Material
	Key                     Material
	Auth                    Material
	Crypt                   Material
	CryptV2                 Material
	CryptV2ForceCookie      bool
	VerifyClientCertificate string
	VerifyX509Name          string
	VerifyX509Type          string
	PeerFingerprint         []string
	CRLVerify               string
	RemoteCertificateKU     []string
	RemoteCertificateEKU    string
	RemoteCertificateTLS    string
	NSCertificateType       string
	VersionMin              string
	VersionMax              string
	CertificateProfile      string
	Cipher                  string
	Groups                  string
}

type ServerAuthenticationOptions struct {
	Authenticator UserPassAuthenticator
	DuplicateCN   bool
}

type ServerTimingOptions struct {
	RenegotiationInterval time.Duration
	RenegotiationDisabled bool
	RenegotiationBytes    uint64
	RenegotiationPackets  uint64
	HandWindow            time.Duration
	PingInterval          time.Duration
	PingRestart           time.Duration
}

type ServerTunnelOptions struct {
	AddressPools   []netip.Prefix
	Topology       string
	LocalAddress   []netip.Prefix
	VPNGateway     netip.Addr
	VPNGatewayIPv6 netip.Addr
}

type ServerPushOptions struct {
	Routes               []netip.Prefix
	DNS                  []netip.Addr
	DNSServers           []TunnelDNSServer
	SearchDomains        []string
	DHCPOptions          []string
	BlockOutsideDNS      bool
	PingInterval         time.Duration
	PingIntervalEnabled  bool
	PingRestart          time.Duration
	PingRestartEnabled   bool
	RedirectGateway      bool
	RedirectGatewayFlags []string
}

type ServerOptions struct {
	Context        context.Context
	Mode           string
	Transport      ServerTransportOptions
	Resources      ServerResourceOptions
	DataChannel    ServerDataChannelOptions
	TLS            ServerTLSOptions
	Authentication ServerAuthenticationOptions
	Timing         ServerTimingOptions
	Tunnel         ServerTunnelOptions
	Push           ServerPushOptions
	StaticKey      Material
	KeyDirection   int
	Logger         logger.ContextLogger
}

type TunnelConfiguration struct {
	DevType              string
	Topology             string
	TunMTU               uint32
	LocalIPv4            []netip.Prefix
	LocalIPv6            []netip.Prefix
	VPNGateway           netip.Addr
	VPNGatewayIPv6       netip.Addr
	IPv4Routes           []TunnelRoute
	IPv6Routes           []TunnelRoute
	ExcludedIPv4Routes   []TunnelRoute
	ExcludedIPv6Routes   []TunnelRoute
	DNS                  []netip.Addr
	DNSServers           []TunnelDNSServer
	DHCPOptions          []string
	SearchDomains        []string
	DNSRoutes            []string
	BlockIPv6            bool
	BlockOutsideDNS      bool
	RedirectGateway      bool
	RedirectGatewayFlags []string
	RedirectPrivate      bool
	RouteMetric          int
	RouteGateway         netip.Addr
	PingInterval         time.Duration
	PingRestart          time.Duration
	AuthToken            string
	AuthTokenUser        string
	ExplicitExitNotify   uint32
	PeerID               *uint32
	SelectedCipher       string
	SelectedAuth         string
	ProtocolFlags        []string
	KeyDerivation        string
	InactiveTimeout      time.Duration
	InactiveMinimumBytes uint64
	SessionTimeout       time.Duration
	PingExit             time.Duration
	PingTimerRemote      bool
}

var ErrMaterialSourceConflict = E.New("material path and content are both set")

type Material struct {
	Path    string
	Content []byte
}

func (m Material) Validate(name string) error {
	if m.Path != "" && len(m.Content) > 0 {
		return E.Extend(ErrMaterialSourceConflict, name)
	}
	return nil
}

func (m Material) IsSet() bool {
	return m.Path != "" || len(m.Content) > 0
}

func loadMaterial(material Material) ([]byte, error) {
	err := material.Validate("material")
	if err != nil {
		return nil, err
	}
	if len(material.Content) > 0 {
		return append([]byte(nil), material.Content...), nil
	}
	if material.Path == "" {
		return nil, nil
	}
	fileContent, err := os.ReadFile(material.Path)
	if err != nil {
		return nil, err
	}
	return fileContent, nil
}
