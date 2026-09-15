package transport

import (
	"crypto/x509"
	_ "embed"
	"sync"

	E "github.com/sagernet/sing/common/exceptions"
)

//go:embed cloudflare_ca.pem
var cloudflareRootCAPEM []byte

var cloudflareRootCertPoolValue = sync.OnceValues(func() (*x509.CertPool, error) {
	pool, err := x509.SystemCertPool()
	if err != nil {
		pool = x509.NewCertPool()
	}
	if !pool.AppendCertsFromPEM(cloudflareRootCAPEM) {
		return nil, E.New("failed to parse embedded Cloudflare root CAs")
	}
	return pool, nil
})

var CloudflareRootCertPool = LoadCloudflareRootCertPool

func LoadCloudflareRootCertPool() (*x509.CertPool, error) {
	return cloudflareRootCertPoolValue()
}
