package openvpn

import (
	"strings"

	E "github.com/sagernet/sing/common/exceptions"
)

type compressionAlgorithm int

const (
	compressionAlgorithmNone compressionAlgorithm = iota
	compressionAlgorithmStub
	compressionAlgorithmLZO
	compressionAlgorithmLZ4
	compressionAlgorithmStubV2
	compressionAlgorithmLZ4V2
)

type compressionSettings struct {
	algorithm  compressionAlgorithm
	swap       bool
	adaptive   bool
	asymmetric bool
}

type compressionDirective struct {
	Name  string
	Value string
}

const (
	compressionDirectiveCompress = "compress"
	compressionDirectiveLZO      = "comp-lzo"
)

// Upstream add_option (options.c) folds --compress and --comp-lzo into the
// single comp.alg/comp.flags pair, so a later directive overrides an earlier
// one and every branch leaves the flags it does not name untouched.
func (settings *compressionSettings) apply(directive compressionDirective) error {
	switch directive.Name {
	case compressionDirectiveCompress:
		switch directive.Value {
		case "", "stub":
			settings.algorithm = compressionAlgorithmStub
			settings.swap = true
		case "stub-v2":
			settings.algorithm = compressionAlgorithmStubV2
		case "lzo":
			settings.algorithm = compressionAlgorithmLZO
			settings.adaptive = false
			settings.swap = false
		case "lz4":
			settings.algorithm = compressionAlgorithmLZ4
			settings.swap = true
		case "lz4-v2":
			settings.algorithm = compressionAlgorithmLZ4V2
		case "migrate", "none", "no", "disabled", "off":
			*settings = compressionSettings{}
		default:
			return E.Extend(ErrCompressionNotSupported, directive.Name, " ", directive.Value)
		}
	case compressionDirectiveLZO:
		// Upstream add_option (options.c) clears COMP_F_SWAP for every
		// --comp-lzo variant before selecting the algorithm.
		settings.swap = false
		switch directive.Value {
		case "", "adaptive":
			settings.algorithm = compressionAlgorithmLZO
			settings.adaptive = true
			settings.asymmetric = false
		case "yes":
			settings.algorithm = compressionAlgorithmLZO
			settings.adaptive = false
			settings.asymmetric = false
		case "asym":
			settings.algorithm = compressionAlgorithmLZO
			settings.adaptive = false
			settings.asymmetric = true
		case "no":
			settings.algorithm = compressionAlgorithmStub
			settings.adaptive = false
		case "none", "disabled", "off":
			*settings = compressionSettings{}
		default:
			return E.Extend(ErrCompressionNotSupported, directive.Name, " ", directive.Value)
		}
	default:
		return E.Extend(ErrCompressionNotSupported, directive.Name)
	}
	return nil
}

// Upstream comp_enabled (comp.h) reports whether a compression context is
// built at all, which decides both the framing byte and the OCC options
// string entry.
func (settings compressionSettings) framingEnabled() bool {
	return settings.algorithm != compressionAlgorithmNone
}

// Upstream comp_non_stub_enabled (comp.h) treats COMP_ALG_UNDEF,
// COMP_ALG_STUB and COMP_ALGV2_UNCOMPRESSED as stub compression.
func (settings compressionSettings) nonStubEnabled() bool {
	switch settings.algorithm {
	case compressionAlgorithmLZO, compressionAlgorithmLZ4, compressionAlgorithmLZ4V2:
		return true
	default:
		return false
	}
}

// Upstream COMP_PREFIX_LEN (comp.h) covers the head byte the v1 framing
// algorithms always carry; the v2 algorithms prepend their indicator only
// when the payload has to be escaped.
func (settings compressionSettings) framingOverhead() int {
	switch settings.algorithm {
	case compressionAlgorithmStub, compressionAlgorithmLZO, compressionAlgorithmLZ4:
		return 1
	default:
		return 0
	}
}

// Upstream lzo_compression_enabled (lzo.c) compresses only under
// COMP_F_ALLOW_COMPRESS; the other algorithms are decompress-only here.
func (settings compressionSettings) compressesOutbound(allowCompression allowCompressionPolicy) bool {
	return settings.algorithm == compressionAlgorithmLZO &&
		!settings.asymmetric &&
		allowCompression == allowCompressionYes
}

func resolveCompressionSettings(compression string, compressionLZO string) (compressionSettings, error) {
	var settings compressionSettings
	compressValue := strings.TrimSpace(compression)
	if compressValue != "" {
		err := settings.apply(compressionDirective{Name: compressionDirectiveCompress, Value: compressValue})
		if err != nil {
			return compressionSettings{}, err
		}
	}
	compressionLZOValue := strings.TrimSpace(compressionLZO)
	if compressionLZOValue != "" {
		err := settings.apply(compressionDirective{Name: compressionDirectiveLZO, Value: compressionLZOValue})
		if err != nil {
			return compressionSettings{}, err
		}
	}
	return settings, nil
}
