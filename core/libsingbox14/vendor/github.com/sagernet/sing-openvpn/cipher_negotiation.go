package openvpn

import (
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

// Upstream options_string_extract_option (ssl.c) translates the legacy
// "[null-cipher]" sentinel to "none".
func extractRemoteCipherName(optionsString string) string {
	for rawToken := range strings.SplitSeq(optionsString, ",") {
		trimmedToken := strings.TrimSpace(rawToken)
		const prefix = "cipher "
		if !strings.HasPrefix(trimmedToken, prefix) {
			continue
		}
		cipherValue := strings.TrimSpace(trimmedToken[len(prefix):])
		if cipherValue == "[null-cipher]" {
			return "none"
		}
		return cipherValue
	}
	return ""
}

// Upstream check_pull_client_ncp (ssl_ncp.c) runs when the server pushed no
// cipher: tls_poor_mans_ncp adopts the peer OptionsString cipher only while
// data-ciphers lists it, data-ciphers-fallback applies only while the peer
// announced no cipher at all, and every other outcome aborts the session.
func selectPulledCipher(options ClientOptions, remoteCipherName string) (string, error) {
	advertisedCiphers := tlsAdvertisedDataCiphers(options.DataChannel.Ciphers)
	trimmedRemote := strings.TrimSpace(remoteCipherName)
	if trimmedRemote != "" {
		for _, candidate := range advertisedCiphers {
			if strings.EqualFold(candidate, trimmedRemote) {
				return candidate, nil
			}
		}
		return "", E.Extend(
			ErrCipherNegotiationFailed,
			"peer cipher ", trimmedRemote,
			" not in data-ciphers ", strings.Join(advertisedCiphers, ":"),
			"; add it to --data-ciphers or reconfigure the server",
		)
	}
	if options.DataChannel.FallbackCipher != "" {
		return options.DataChannel.FallbackCipher, nil
	}
	return "", E.Extend(
		ErrCipherNegotiationFailed,
		"server pushed no cipher and announced none in its options string",
		"; set data-ciphers-fallback to connect to this server",
	)
}

// Upstream get_p2p_ncp_cipher (ssl_ncp.c) negotiates from IV_CIPHERS alone, in
// the order of the TLS server's list and without consulting the peer
// OptionsString cipher, and do_deferred_p2p_ncp (init.c) keeps a session whose
// intersection is empty only while data-ciphers-fallback carries it.
func selectP2PCipher(options ClientOptions, peerInfo string) (string, error) {
	localCiphers := tlsAdvertisedDataCiphers(options.DataChannel.Ciphers)
	peerCiphers, _ := peerInfoIVCipherList(peerInfo)
	for _, peerCipher := range peerCiphers {
		for _, localCipher := range localCiphers {
			if strings.EqualFold(peerCipher, localCipher) {
				return localCipher, nil
			}
		}
	}
	if options.DataChannel.FallbackCipher != "" {
		return options.DataChannel.FallbackCipher, nil
	}
	return "", E.Extend(
		ErrCipherNegotiationFailed,
		"peer announced no data cipher shared with data-ciphers ",
		strings.Join(localCiphers, ":"),
		"; set data-ciphers-fallback to connect to this peer",
	)
}
