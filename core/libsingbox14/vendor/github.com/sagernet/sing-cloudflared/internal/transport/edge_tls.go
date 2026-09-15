package transport

import (
	"crypto/tls"
	"crypto/x509"
)

const (
	X25519MLKEM768PQKex = tls.CurveID(0x11ec)
	FeaturePostQuantum  = "postquantum"
)

func NewEdgeTLSConfig(rootCAs *x509.CertPool, serverName string, nextProtos []string) *tls.Config {
	return &tls.Config{
		RootCAs:          rootCAs,
		ServerName:       serverName,
		NextProtos:       nextProtos,
		CurvePreferences: []tls.CurveID{tls.CurveP256},
	}
}

func ApplyPostQuantumCurvePreferences(config *tls.Config, features []string) {
	if config == nil || !HasFeature(features, FeaturePostQuantum) {
		return
	}
	config.CurvePreferences = []tls.CurveID{X25519MLKEM768PQKex}
}

func HasFeature(features []string, target string) bool {
	for _, feature := range features {
		if feature == target {
			return true
		}
	}
	return false
}
