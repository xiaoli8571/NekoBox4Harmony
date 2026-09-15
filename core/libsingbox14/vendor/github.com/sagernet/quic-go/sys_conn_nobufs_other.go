//go:build !unix && !windows

package quic

func isNoBufferSpaceErr(error) bool {
	// to be implemented for more specific platforms
	return false
}
