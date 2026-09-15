package openvpn

import E "github.com/sagernet/sing/common/exceptions"

type allowCompressionPolicy int

const (
	allowCompressionStubOnly allowCompressionPolicy = iota
	allowCompressionAsymmetric
	// OpenVPN 2.7 maps explicit "yes" to asymmetric mode. Keep outbound
	// compression here only for explicitly requested legacy compatibility.
	allowCompressionYes
)

// Upstream options_postprocess_mutate (options.c) rejects bad
// --allow-compression tokens.
var ErrInvalidAllowCompression = E.New("invalid allow-compression value")

// Upstream options_postprocess_mutate (options.c) flags
// --allow-compression no with non-stub compression.
var ErrAllowCompressionConflict = E.New("allow-compression no conflicts with statically enabled compression")

func parseAllowCompressionPolicy(value string) (allowCompressionPolicy, error) {
	switch value {
	case "", "no":
		return allowCompressionStubOnly, nil
	case "asym":
		return allowCompressionAsymmetric, nil
	case "yes":
		return allowCompressionYes, nil
	}
	return 0, ErrInvalidAllowCompression
}

func resolveEffectiveAllowCompressionPolicy(allowCompression string, settings compressionSettings) (allowCompressionPolicy, error) {
	if allowCompression == "" {
		if settings.nonStubEnabled() {
			return allowCompressionAsymmetric, nil
		}
		return allowCompressionStubOnly, nil
	}
	policy, err := parseAllowCompressionPolicy(allowCompression)
	if err != nil {
		return 0, err
	}
	if policy == allowCompressionStubOnly && settings.nonStubEnabled() {
		return 0, ErrAllowCompressionConflict
	}
	return policy, nil
}
