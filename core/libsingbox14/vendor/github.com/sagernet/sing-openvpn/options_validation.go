package openvpn

import (
	"strconv"
	"strings"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
)

func validateMode(mode string) (string, error) {
	switch mode {
	case ModeTLS, ModeStaticKey:
		return mode, nil
	default:
		return "", ErrUnsupportedMode
	}
}

func validateImplementedClientOptions(options ClientOptions) error {
	dataChannelOptions := options.DataChannel
	tlsOptions := options.TLS
	timingOptions := options.Timing
	if options.KeyDirection < -1 || options.KeyDirection > 1 {
		return E.New("ClientOptions.KeyDirection must be -1, 0, or 1")
	}
	err := validateClientMaterialSources(options)
	if err != nil {
		return err
	}
	err = validateClientDurationOptions(options)
	if err != nil {
		return err
	}
	err = validateDataChannelNames(
		"ClientOptions.DataChannel",
		dataChannelOptions.Cipher,
		dataChannelOptions.Ciphers,
		dataChannelOptions.FallbackCipher,
		dataChannelOptions.Auth,
	)
	if err != nil {
		return err
	}
	err = validateDataChannelPolicy("ClientOptions.DataChannel", dataChannelOptions.MSSFix, dataChannelOptions.MSSFixDisabled, dataChannelOptions.MSSFixMode, dataChannelOptions.ReplayWindow, dataChannelOptions.ReplayWindowTime)
	if err != nil {
		return err
	}
	if options.Mode == ModeStaticKey {
		if dataChannelOptions.Cipher == "" {
			return E.New("ClientOptions.DataChannel.Cipher is required in static_key mode")
		}
		_, err = staticCipherKeySize(dataChannelOptions.Cipher)
		if err != nil {
			return E.New("ClientOptions.DataChannel.Cipher is not supported in static_key mode: ", dataChannelOptions.Cipher)
		}
		if len(dataChannelOptions.Ciphers) > 0 || dataChannelOptions.FallbackCipher != "" {
			return E.Extend(ErrOptionNotSupported, "data_ciphers in static_key mode; use Cipher")
		}
	}
	err = validateTLSOptionNames(
		"ClientOptions.TLS",
		tlsOptions.VerifyX509Type,
		tlsOptions.PeerFingerprint,
		tlsOptions.RemoteCertificateKU,
		tlsOptions.RemoteCertificateEKU,
		tlsOptions.RemoteCertificateTLS,
		tlsOptions.NSCertificateType,
		tlsOptions.VersionMin,
		tlsOptions.VersionMax,
		tlsOptions.CertificateProfile,
		tlsOptions.Cipher,
		tlsOptions.Groups,
	)
	if err != nil {
		return err
	}
	err = validateTLSCredentialSet(
		options.Mode,
		tlsOptions.CertificateAuthority,
		tlsOptions.Certificate,
		tlsOptions.Key,
		tlsOptions.PeerFingerprint,
		false,
	)
	if err != nil {
		return err
	}
	err = validateClientPolicyOptions(options)
	if err != nil {
		return err
	}
	if options.Mode == ModeTLS && options.StaticKey.IsSet() {
		return E.Extend(ErrOptionNotSupported, "static_key in tls mode")
	}
	if options.Mode == ModeStaticKey && hasTLSCredentialMaterial(
		tlsOptions.CertificateAuthority,
		tlsOptions.Certificate,
		tlsOptions.Key,
		tlsOptions.Auth,
		tlsOptions.Crypt,
		tlsOptions.CryptV2,
	) {
		return E.Extend(ErrOptionNotSupported, "TLS material in static_key mode")
	}
	if options.Mode == ModeStaticKey && (tlsOptions.VerifyX509Name != "" || tlsOptions.VerifyX509Type != "" ||
		len(tlsOptions.PeerFingerprint) > 0 || tlsOptions.CRLVerify != "" || len(tlsOptions.RemoteCertificateKU) > 0 ||
		tlsOptions.RemoteCertificateEKU != "" || tlsOptions.RemoteCertificateTLS != "" || tlsOptions.NSCertificateType != "" ||
		tlsOptions.VersionMin != "" || tlsOptions.VersionMax != "" || tlsOptions.CertificateProfile != "" ||
		tlsOptions.Cipher != "" || tlsOptions.Groups != "" ||
		timingOptions.TLSTimeout != 0 || timingOptions.HandWindow != 0 || timingOptions.RenegotiationBytes != 0 ||
		timingOptions.RenegotiationPackets != 0) {
		return E.Extend(ErrOptionNotSupported, "TLS options in static_key mode")
	}
	tlsAuthSet := tlsOptions.Auth.IsSet()
	tlsCryptSet := tlsOptions.Crypt.IsSet()
	tlsCryptV2Set := tlsOptions.CryptV2.IsSet()
	if tlsAuthSet && tlsCryptSet {
		return E.Extend(ErrOptionNotSupported, "tls_auth+tls_crypt")
	}
	if tlsAuthSet && tlsCryptV2Set {
		return E.Extend(ErrOptionNotSupported, "tls_auth+tls_crypt_v2")
	}
	if tlsCryptSet && tlsCryptV2Set {
		return E.Extend(ErrOptionNotSupported, "tls_crypt+tls_crypt_v2")
	}
	return nil
}

func validateClientPolicyOptions(options ClientOptions) error {
	if options.Tunnel.DevType != "" && options.Tunnel.DevType != "tun" {
		return E.New("ClientOptions.Tunnel.DevType must be tun")
	}
	switch options.Tunnel.Topology {
	case "", "net30", "p2p", "subnet":
	default:
		return E.New("ClientOptions.Tunnel.Topology must be net30, p2p, or subnet")
	}
	switch options.Authentication.AuthRetry {
	case "", "none", "nointeract", "interact":
	default:
		return E.New("ClientOptions.Authentication.AuthRetry must be none, nointeract, or interact")
	}
	for filterIndex, filter := range options.Pull.Filters {
		switch filter.Action {
		case "accept", "ignore", "reject":
		default:
			return E.New("ClientOptions.Pull.Filters[", filterIndex, "].Action must be accept, ignore, or reject")
		}
		if filter.Text == "" {
			return E.New("ClientOptions.Pull.Filters[", filterIndex, "].Text must not be empty")
		}
	}
	if options.DataChannel.Fragment > 0 && options.DataChannel.Fragment < 68 {
		return E.New("ClientOptions.DataChannel.Fragment must be zero or at least 68")
	}
	return nil
}

func validateDataChannelNames(optionsName string, cipherName string, dataCiphers []string, fallbackCipher string, authName string) error {
	err := validateDataCipherName(optionsName+".Cipher", cipherName)
	if err != nil {
		return err
	}
	for cipherIndex, dataCipher := range dataCiphers {
		if dataCipher == "" {
			return E.New(optionsName, ".Ciphers[", cipherIndex, "] must not be empty")
		}
		err = validateDataCipherName(optionsName+".Ciphers["+strconv.Itoa(cipherIndex)+"]", dataCipher)
		if err != nil {
			return err
		}
	}
	err = validateDataCipherName(optionsName+".FallbackCipher", fallbackCipher)
	if err != nil {
		return err
	}
	switch authName {
	case "", "SHA1", "SHA224", "SHA256", "SHA384", "SHA512", "RIPEMD160", "MD5", "NONE":
		return nil
	default:
		return E.New(optionsName, ".Auth must use a canonical OpenVPN digest name")
	}
}

func validateDataCipherName(name string, cipherName string) error {
	switch cipherName {
	case "", "BF-CBC", "DES-CBC", "DES-EDE-CBC", "DES-EDE3-CBC", "CAST5-CBC",
		"AES-128-CBC", "AES-192-CBC", "AES-256-CBC",
		"ARIA-128-CBC", "ARIA-192-CBC", "ARIA-256-CBC",
		"CAMELLIA-128-CBC", "CAMELLIA-192-CBC", "CAMELLIA-256-CBC",
		"SEED-CBC", "SM4-CBC",
		"AES-128-GCM", "AES-192-GCM", "AES-256-GCM", "CHACHA20-POLY1305", "NONE":
		return nil
	default:
		_, _, _, streamCipherErr := tlsStreamCipherSpec(cipherName)
		if streamCipherErr == nil {
			return nil
		}
		return E.New(name, " must use a canonical OpenVPN cipher name")
	}
}

func validateTLSOptionNames(optionsName string, verifyX509Type string, peerFingerprints []string, remoteCertKU []string, remoteCertEKU string, remoteCertTLS string, nsCertType string, versionMin string, versionMax string, certProfile string, tlsCipher string, tlsGroups string) error {
	switch verifyX509Type {
	case "", "subject", "name", "name-prefix":
	default:
		return E.New(optionsName, ".VerifyX509Type must be subject, name, or name-prefix")
	}
	for fingerprintIndex, fingerprint := range peerFingerprints {
		if len(fingerprint) != 64 || !isLowerHex(fingerprint) {
			return E.New(optionsName, ".PeerFingerprint[", fingerprintIndex, "] must be canonical lowercase hex")
		}
	}
	_, err := parseRemoteCertKeyUsages(remoteCertKU)
	if err != nil {
		return err
	}
	_, err = parseRemoteCertExtKeyUsage(remoteCertEKU)
	if err != nil {
		return err
	}
	_, _, err = expandRemoteCertTLS(remoteCertTLS, "")
	if err != nil {
		return err
	}
	switch nsCertType {
	case "", "server", "client":
	default:
		return E.New(optionsName, ".NSCertificateType must be server or client")
	}
	_, _, err = resolveTLSVersionBounds(versionMin, versionMax)
	if err != nil {
		return err
	}
	_, err = parseTLSCertProfile(certProfile)
	if err != nil {
		return err
	}
	_, err = parseTLSCipherSuites(tlsCipher)
	if err != nil {
		return err
	}
	_, err = parseTLSGroups(tlsGroups)
	return err
}

func isLowerHex(value string) bool {
	for _, character := range value {
		if (character < '0' || character > '9') && (character < 'a' || character > 'f') {
			return false
		}
	}
	return true
}

func validateImplementedServerOptions(options ServerOptions) error {
	dataChannelOptions := options.DataChannel
	tlsOptions := options.TLS
	if options.KeyDirection < -1 || options.KeyDirection > 1 {
		return E.New("ServerOptions.KeyDirection must be -1, 0, or 1")
	}
	err := validateServerMaterialSources(options)
	if err != nil {
		return err
	}
	err = validateServerDurationOptions(options)
	if err != nil {
		return err
	}
	err = validateDataChannelNames(
		"ServerOptions.DataChannel",
		dataChannelOptions.Cipher,
		dataChannelOptions.Ciphers,
		dataChannelOptions.FallbackCipher,
		dataChannelOptions.Auth,
	)
	if err != nil {
		return err
	}
	err = validateDataChannelPolicy("ServerOptions.DataChannel", dataChannelOptions.MSSFix, dataChannelOptions.MSSFixDisabled, dataChannelOptions.MSSFixMode, dataChannelOptions.ReplayWindow, dataChannelOptions.ReplayWindowTime)
	if err != nil {
		return err
	}
	err = validateTLSOptionNames(
		"ServerOptions.TLS",
		tlsOptions.VerifyX509Type,
		tlsOptions.PeerFingerprint,
		tlsOptions.RemoteCertificateKU,
		tlsOptions.RemoteCertificateEKU,
		tlsOptions.RemoteCertificateTLS,
		tlsOptions.NSCertificateType,
		tlsOptions.VersionMin,
		tlsOptions.VersionMax,
		tlsOptions.CertificateProfile,
		tlsOptions.Cipher,
		tlsOptions.Groups,
	)
	if err != nil {
		return err
	}
	err = validateTLSCredentialSet(
		options.Mode,
		tlsOptions.CertificateAuthority,
		tlsOptions.Certificate,
		tlsOptions.Key,
		tlsOptions.PeerFingerprint,
		true,
	)
	if err != nil {
		return err
	}
	err = validateServerTransportOptions(options)
	if err != nil {
		return err
	}
	err = validateServerResourceOptions(options)
	if err != nil {
		return err
	}
	err = validateServerTunnelOptions(options)
	if err != nil {
		return err
	}
	if options.Mode == ModeTLS && options.StaticKey.IsSet() {
		return E.Extend(ErrOptionNotSupported, "static_key in tls server mode")
	}
	if options.Mode == ModeTLS && options.DataChannel.Cipher != "" {
		return E.Extend(ErrOptionNotSupported, "DataChannel.Cipher in tls server mode; use Ciphers or FallbackCipher")
	}
	if options.Mode == ModeStaticKey {
		if !options.StaticKey.IsSet() {
			return ErrMissingStaticKey
		}
		if dataChannelOptions.Cipher == "" {
			return E.New("ServerOptions.DataChannel.Cipher is required in static_key mode")
		}
		_, err = staticCipherKeySize(dataChannelOptions.Cipher)
		if err != nil {
			return E.New("ServerOptions.DataChannel.Cipher is not supported in static_key mode: ", dataChannelOptions.Cipher)
		}
		if hasTLSCredentialMaterial(tlsOptions.CertificateAuthority, tlsOptions.Certificate, tlsOptions.Key, tlsOptions.Auth, tlsOptions.Crypt, tlsOptions.CryptV2) {
			return E.Extend(ErrOptionNotSupported, "TLS material in static_key server mode")
		}
		if tlsOptions.VerifyX509Name != "" || tlsOptions.VerifyX509Type != "" || len(tlsOptions.PeerFingerprint) > 0 || tlsOptions.CRLVerify != "" || len(tlsOptions.RemoteCertificateKU) > 0 || tlsOptions.RemoteCertificateEKU != "" || tlsOptions.RemoteCertificateTLS != "" || tlsOptions.NSCertificateType != "" || tlsOptions.VersionMin != "" || tlsOptions.VersionMax != "" || tlsOptions.CertificateProfile != "" || tlsOptions.Cipher != "" || tlsOptions.Groups != "" {
			return E.Extend(ErrOptionNotSupported, "TLS options in static_key server mode")
		}
		if options.Authentication.Authenticator != nil || options.Authentication.DuplicateCN {
			return E.Extend(ErrOptionNotSupported, "authentication in static_key server mode")
		}
		if options.Timing.RenegotiationInterval != 0 || options.Timing.RenegotiationDisabled || options.Timing.RenegotiationBytes != 0 || options.Timing.RenegotiationPackets != 0 || options.Timing.HandWindow != 0 {
			return E.Extend(ErrOptionNotSupported, "TLS timing in static_key server mode")
		}
		if len(options.Push.Routes) > 0 || len(options.Push.DNS) > 0 || len(options.Push.DNSServers) > 0 || len(options.Push.SearchDomains) > 0 || len(options.Push.DHCPOptions) > 0 || options.Push.BlockOutsideDNS || options.Push.PingIntervalEnabled || options.Push.PingInterval > 0 || options.Push.PingRestartEnabled || options.Push.PingRestart > 0 || options.Push.RedirectGateway || len(options.Push.RedirectGatewayFlags) > 0 {
			return E.Extend(ErrOptionNotSupported, "push options in static_key server mode")
		}
		if len(options.DataChannel.Ciphers) > 0 || options.DataChannel.FallbackCipher != "" {
			return E.Extend(ErrOptionNotSupported, "data_ciphers in static_key server mode; use Cipher")
		}
	}
	tlsAuthSet := tlsOptions.Auth.IsSet()
	tlsCryptSet := tlsOptions.Crypt.IsSet()
	tlsCryptV2Set := tlsOptions.CryptV2.IsSet()
	if tlsOptions.CryptV2ForceCookie && !tlsCryptV2Set {
		return E.New("ServerOptions.TLS.CryptV2ForceCookie requires tls-crypt-v2")
	}
	if tlsAuthSet && tlsCryptSet {
		return E.Extend(ErrOptionNotSupported, "tls_auth+tls_crypt")
	}
	if tlsAuthSet && tlsCryptV2Set {
		return E.Extend(ErrOptionNotSupported, "tls_auth+tls_crypt_v2")
	}
	if tlsCryptSet && tlsCryptV2Set {
		return E.Extend(ErrOptionNotSupported, "tls_crypt+tls_crypt_v2")
	}
	return nil
}

func validateDataChannelPolicy(optionsName string, mssFix uint32, mssFixDisabled bool, mssFixMode string, replayWindow uint32, replayWindowTime time.Duration) error {
	if mssFix > 0 && mssFixDisabled {
		return E.New(optionsName, ".MSSFix conflicts with MSSFixDisabled")
	}
	if mssFixDisabled && mssFixMode != "" {
		return E.New(optionsName, ".MSSFixMode conflicts with MSSFixDisabled")
	}
	if mssFix == 0 && mssFixMode != "" {
		return E.New(optionsName, ".MSSFixMode requires MSSFix")
	}
	switch mssFixMode {
	case "", MSSFixModeMTU, MSSFixModeFixed:
	default:
		return E.New(optionsName, ".MSSFixMode must be mtu or fixed")
	}
	if replayWindow > maxReplayWindowSize {
		return E.New(optionsName, ".ReplayWindow must not exceed ", maxReplayWindowSize)
	}
	if replayWindowTime < 0 || replayWindowTime > maxReplayWindowTime {
		return E.New(optionsName, ".ReplayWindowTime must be between 0s and ", maxReplayWindowTime)
	}
	if replayWindowTime%time.Second != 0 {
		return E.New(optionsName, ".ReplayWindowTime must use whole seconds")
	}
	return nil
}

func validateServerResourceOptions(options ServerOptions) error {
	resourceOptions := options.Resources
	if resourceOptions.MaxClients < 0 {
		return E.New("ServerOptions.Resources.MaxClients must not be negative")
	}
	if resourceOptions.MaxClients >= peerIDMaxValue {
		return E.New("ServerOptions.Resources.MaxClients must be less than ", peerIDMaxValue)
	}
	if options.Mode == ModeStaticKey && resourceOptions.MaxClients > 1 {
		return E.New("ServerOptions.Resources.MaxClients must not exceed 1 in static_key mode")
	}
	if resourceOptions.ConnectFrequency < 0 {
		return E.New("ServerOptions.Resources.ConnectFrequency must not be negative")
	}
	if resourceOptions.ConnectFrequency > 0 && resourceOptions.ConnectFrequencyPeriod <= 0 {
		return E.New("ServerOptions.Resources.ConnectFrequency requires ConnectFrequencyPeriod")
	}
	if resourceOptions.ConnectFrequencyPeriod < 0 {
		return E.New("ServerOptions.Resources.ConnectFrequencyPeriod must not be negative")
	}
	if resourceOptions.ConnectFrequencyPeriod > 0 && !strings.HasPrefix(options.Transport.Protocol, "udp") {
		return E.New("ServerOptions.Resources.ConnectFrequency is only supported by UDP servers")
	}
	if resourceOptions.InitialConnectFrequency < 0 {
		return E.New("ServerOptions.Resources.InitialConnectFrequency must not be negative")
	}
	if resourceOptions.InitialConnectFrequency > 0 && resourceOptions.InitialConnectFrequencyPeriod <= 0 {
		return E.New("ServerOptions.Resources.InitialConnectFrequency requires InitialConnectFrequencyPeriod")
	}
	if resourceOptions.InitialConnectFrequencyPeriod < 0 {
		return E.New("ServerOptions.Resources.InitialConnectFrequencyPeriod must not be negative")
	}
	return nil
}

func validateClientDurationOptions(options ClientOptions) error {
	timingOptions := options.Timing
	if timingOptions.RenegotiationDisabled && timingOptions.RenegotiationInterval > 0 {
		return E.New("ClientOptions.Timing.RenegotiationInterval conflicts with RenegotiationDisabled")
	}
	err := validateDurationOption("ClientOptions.Timing.RenegotiationInterval", timingOptions.RenegotiationInterval)
	if err != nil {
		return err
	}
	err = validatePingDurationOption("ClientOptions.Timing.PingInterval", timingOptions.PingInterval)
	if err != nil {
		return err
	}
	err = validatePingDurationOption("ClientOptions.Timing.PingRestart", timingOptions.PingRestart)
	if err != nil {
		return err
	}
	if timingOptions.PingRestartDisabled && timingOptions.PingRestart > 0 {
		return E.New("ClientOptions.Timing.PingRestart conflicts with PingRestartDisabled")
	}
	err = validateDurationOption("ClientOptions.Timing.TLSTimeout", timingOptions.TLSTimeout)
	if err != nil {
		return err
	}
	return validateDurationOption("ClientOptions.Timing.HandWindow", timingOptions.HandWindow)
}

func validateServerDurationOptions(options ServerOptions) error {
	timingOptions := options.Timing
	if timingOptions.RenegotiationDisabled && timingOptions.RenegotiationInterval > 0 {
		return E.New("ServerOptions.Timing.RenegotiationInterval conflicts with RenegotiationDisabled")
	}
	err := validateDurationOption("ServerOptions.Timing.RenegotiationInterval", timingOptions.RenegotiationInterval)
	if err != nil {
		return err
	}
	err = validateDurationOption("ServerOptions.Timing.HandWindow", timingOptions.HandWindow)
	if err != nil {
		return err
	}
	err = validatePingDurationOption("ServerOptions.Timing.PingInterval", timingOptions.PingInterval)
	if err != nil {
		return err
	}
	err = validatePingDurationOption("ServerOptions.Timing.PingRestart", timingOptions.PingRestart)
	if err != nil {
		return err
	}
	err = validatePingDurationOption("ServerOptions.Push.PingInterval", options.Push.PingInterval)
	if err != nil {
		return err
	}
	return validatePingDurationOption("ServerOptions.Push.PingRestart", options.Push.PingRestart)
}

func validatePingDurationOption(name string, value time.Duration) error {
	err := validateDurationOption(name, value)
	if err != nil {
		return err
	}
	if value%time.Second != 0 {
		return E.New(name, " must use whole seconds")
	}
	return nil
}

func validateDurationOption(name string, value time.Duration) error {
	if value < 0 {
		return E.New(name, " must not be negative")
	}
	if value > 0 && value < time.Second {
		return E.New(name, " must be zero or at least 1s")
	}
	return nil
}

func validateServerTunnelOptions(options ServerOptions) error {
	switch options.Tunnel.Topology {
	case "", "net30", "p2p", "subnet":
	default:
		return E.New("ServerOptions.Tunnel.Topology must be net30, p2p, or subnet")
	}
	if options.Tunnel.VPNGateway.IsValid() && !options.Tunnel.VPNGateway.Is4() {
		return E.New("ServerOptions.Tunnel.VPNGateway must be IPv4")
	}
	if options.Tunnel.VPNGatewayIPv6.IsValid() && !options.Tunnel.VPNGatewayIPv6.Is6() {
		return E.New("ServerOptions.Tunnel.VPNGatewayIPv6 must be IPv6")
	}
	if options.Mode == ModeStaticKey {
		if len(options.Tunnel.LocalAddress) == 0 {
			return E.New("ServerOptions.Tunnel.LocalAddress is required in static_key mode")
		}
		var hasIPv4 bool
		var hasIPv6 bool
		for _, address := range options.Tunnel.LocalAddress {
			if !address.IsValid() {
				return E.New("ServerOptions.Tunnel.LocalAddress contains an invalid prefix")
			}
			hasIPv4 = hasIPv4 || address.Addr().Is4()
			hasIPv6 = hasIPv6 || address.Addr().Is6()
		}
		if hasIPv4 && !options.Tunnel.VPNGateway.IsValid() {
			return E.New("ServerOptions.Tunnel.VPNGateway is required for IPv4 static_key mode")
		}
		if hasIPv6 && !options.Tunnel.VPNGatewayIPv6.IsValid() {
			return E.New("ServerOptions.Tunnel.VPNGatewayIPv6 is required for IPv6 static_key mode")
		}
		if options.Tunnel.VPNGateway.IsValid() && !hasIPv4 {
			return E.New("ServerOptions.Tunnel.VPNGateway requires an IPv4 LocalAddress in static_key mode")
		}
		if options.Tunnel.VPNGatewayIPv6.IsValid() && !hasIPv6 {
			return E.New("ServerOptions.Tunnel.VPNGatewayIPv6 requires an IPv6 LocalAddress in static_key mode")
		}
	}
	seenDNSPriorities := make(map[int]struct{}, len(options.Push.DNSServers))
	for searchDomainIndex, searchDomain := range options.Push.SearchDomains {
		if !validateTunnelDNSDomain(searchDomain) {
			return E.New("ServerOptions.Push.SearchDomains[", searchDomainIndex, "] contains invalid characters")
		}
	}
	for serverIndex, server := range options.Push.DNSServers {
		if server.Priority < 0 || server.Priority > 127 {
			return E.New("ServerOptions.Push.DNSServers[", serverIndex, "].Priority must be between 0 and 127")
		}
		if _, exists := seenDNSPriorities[server.Priority]; exists {
			return E.New("ServerOptions.Push.DNSServers contains duplicate priority ", server.Priority)
		}
		seenDNSPriorities[server.Priority] = struct{}{}
		if len(server.Addresses) == 0 {
			return E.New("ServerOptions.Push.DNSServers[", serverIndex, "] must contain at least one address")
		}
		if len(server.Addresses) > maxTunnelDNSServerAddresses {
			return E.New("ServerOptions.Push.DNSServers[", serverIndex, "] must not contain more than ", maxTunnelDNSServerAddresses, " addresses")
		}
		for addressIndex, address := range server.Addresses {
			if !address.Addr().IsValid() {
				return E.New("ServerOptions.Push.DNSServers[", serverIndex, "].Addresses[", addressIndex, "] is invalid")
			}
		}
		for domainIndex, domain := range server.ResolveDomains {
			if !validateTunnelDNSDomain(domain) {
				return E.New("ServerOptions.Push.DNSServers[", serverIndex, "].ResolveDomains[", domainIndex, "] contains invalid characters")
			}
		}
		if server.SNI != "" && !validateTunnelDNSDomain(server.SNI) {
			return E.New("ServerOptions.Push.DNSServers[", serverIndex, "].SNI contains invalid characters")
		}
		switch server.DNSSEC {
		case "", "yes", "optional", "no":
		default:
			return E.New("ServerOptions.Push.DNSServers[", serverIndex, "].DNSSEC must be yes, optional, or no")
		}
		switch server.Transport {
		case "", "plain", "dot", "doh":
		default:
			return E.New("ServerOptions.Push.DNSServers[", serverIndex, "].Transport must be plain, dot, or doh")
		}
	}
	return nil
}

func validateTunnelDNSDomain(domain string) bool {
	if domain == "" {
		return false
	}
	for index := 0; index < len(domain); index++ {
		character := domain[index]
		if (character >= 'A' && character <= 'Z') ||
			(character >= 'a' && character <= 'z') ||
			(character >= '0' && character <= '9') ||
			character == '.' || character == '-' || character == '_' || character >= 0x80 {
			continue
		}
		return false
	}
	return true
}

func validateClientMaterialSources(options ClientOptions) error {
	for _, source := range []struct {
		name     string
		material Material
	}{
		{"certificate-authority", options.TLS.CertificateAuthority},
		{"certificate", options.TLS.Certificate},
		{"key", options.TLS.Key},
		{"tls-auth", options.TLS.Auth},
		{"tls-crypt", options.TLS.Crypt},
		{"tls-crypt-v2", options.TLS.CryptV2},
		{"static-key", options.StaticKey},
	} {
		err := source.material.Validate(source.name)
		if err != nil {
			return err
		}
	}
	return nil
}

func validateServerMaterialSources(options ServerOptions) error {
	for _, source := range []struct {
		name     string
		material Material
	}{
		{"certificate-authority", options.TLS.CertificateAuthority},
		{"certificate", options.TLS.Certificate},
		{"key", options.TLS.Key},
		{"tls-auth", options.TLS.Auth},
		{"tls-crypt", options.TLS.Crypt},
		{"tls-crypt-v2", options.TLS.CryptV2},
		{"static-key", options.StaticKey},
	} {
		err := source.material.Validate(source.name)
		if err != nil {
			return err
		}
	}
	return nil
}

func resolveTransportProtocol(protocol string) (string, string, error) {
	switch protocol {
	case "udp":
		return protocol, "udp", nil
	case "udp4":
		return protocol, "udp4", nil
	case "udp6":
		return protocol, "udp6", nil
	case "tcp":
		return protocol, "tcp", nil
	case "tcp4":
		return protocol, "tcp4", nil
	case "tcp6":
		return protocol, "tcp6", nil
	}
	return "", "", ErrUnsupportedProtocol
}

func validateServerTransportOptions(options ServerOptions) error {
	if strings.ContainsAny(options.Transport.ListenAddress, " \t\r\n") {
		return E.New("ServerOptions.Transport.ListenAddress must not contain whitespace")
	}
	injectedCount := 0
	if options.Transport.Listener != nil {
		injectedCount++
	}
	if options.Transport.PacketConn != nil {
		injectedCount++
	}
	if injectedCount > 1 {
		return E.Extend(ErrOptionNotSupported, "multiple server transports")
	}
	if options.Mode == ModeTLS && options.Transport.RemoteAddress != "" {
		return E.New("ServerOptions.Transport.RemoteAddress is only used by UDP static_key mode")
	}
	if strings.HasPrefix(options.Transport.Protocol, "tcp") {
		if options.Transport.PacketConn != nil {
			return E.Extend(ErrOptionNotSupported, "packet transport in tcp mode")
		}
		if options.Mode == ModeStaticKey && options.Transport.RemoteAddress != "" {
			return E.New("ServerOptions.Transport.RemoteAddress is only used by UDP static_key mode")
		}
		return nil
	}
	if options.Transport.Listener != nil {
		return E.Extend(ErrOptionNotSupported, "stream transport in udp mode")
	}
	if options.Mode == ModeStaticKey && options.Transport.RemoteAddress == "" {
		return E.New("ServerOptions.Transport.RemoteAddress is required by UDP static_key mode")
	}
	return nil
}
