package parityprobe

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	routerule "github.com/sagernet/sing-box/route/rule"
	"github.com/sagernet/sing/common/json"
	M "github.com/sagernet/sing/common/metadata"
)

type auditDialer struct{}

func (auditDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	return (&net.Dialer{}).DialContext(ctx, network, destination.String())
}

func (auditDialer) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	return net.ListenPacket("udp", "127.0.0.1:0")
}

// Test the real kernel probe against local HTTP servers, including error pages
// that TCPing cannot distinguish from a usable proxy route.
func TestAuditURLTestResponsePolicy(t *testing.T) {
	for _, code := range []int{200, 204, 302, 403, 404, 500} {
		for _, strict := range []bool{false, true} {
			t.Run(fmt.Sprintf("status-%d-strict-%v", code, strict), func(t *testing.T) {
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.WriteHeader(code)
				}))
				defer server.Close()
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				_, err := urltest.URLTestWithOptions(ctx, server.URL, auditDialer{}, urltest.URLTestOptions{
					Expect2xx: strict, AllowGetFallback: true,
				})
				wantError := strict && (code < 200 || code >= 300)
				if (err != nil) != wantError {
					t.Fatalf("error = %v, want error = %v", err, wantError)
				}
			})
		}
	}
}

func TestAuditURLTestHeadFallback(t *testing.T) {
	for _, code := range []int{405, 501} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
			methods := make(chan string, 2)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				methods <- r.Method
				if r.Method == http.MethodHead {
					w.WriteHeader(code)
				} else {
					w.WriteHeader(http.StatusNoContent)
				}
			}))
			defer server.Close()
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if _, err := urltest.URLTest(ctx, server.URL, auditDialer{}); err != nil {
				t.Fatal(err)
			}
			if <-methods != "HEAD" || <-methods != "GET" {
				t.Fatal("HEAD rejection must retry with GET")
			}
		})
	}
}

// This is a documented unresolved failure mode, not an assertion of graceful
// fallback: a new remote SRS has no cache and a failed first download blocks start.
func TestAuditUncachedRemoteRuleFailureBlocksStart(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()
	config := fmt.Sprintf(`{
		"log":{"level":"panic"},
		"dns":{"servers":[{"type":"udp","tag":"local","server":"127.0.0.1"}],"final":"local"},
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"auto_detect_interface":false,"final":"direct",
		"rule_set":[{"type":"remote","tag":"remote_audit","format":"binary","url":%q,"download_detour":"direct"}],
		"rules":[{"rule_set":["remote_audit"],"outbound":"direct"}]}
	}`, server.URL)
	err := startBoxRaw(t, config)
	if err == nil || !strings.Contains(err.Error(), "initial rule-set") || !strings.Contains(err.Error(), "503") {
		t.Fatalf("expected uncached initial download to prevent startup, got %v", err)
	}
	t.Logf("CONFIRMED remaining issue: %v", err)
}

func TestAuditInvalidOutboundPreventsBatchStart(t *testing.T) {
	good := `{"type":"socks","tag":"t0","server":"127.0.0.1","server_port":1080}`
	bad := `{"type":"socks","tag":"t1","server":"127.0.0.1","server_port":"invalid"}`
	config := func(outbounds string) string {
		return `{"log":{"level":"panic"},"dns":{"servers":[{"type":"udp","tag":"probe","server":"127.0.0.1"}],"final":"probe"},"outbounds":[` + outbounds + `],"route":{"final":"t0","auto_detect_interface":false}}`
	}
	if err := startBoxRaw(t, config(good)); err != nil {
		t.Fatalf("valid node should start alone: %v", err)
	}
	err := startBoxRaw(t, config(good+","+bad))
	if err == nil || !strings.Contains(err.Error(), "server_port") {
		t.Fatalf("expected invalid peer configuration to reject the whole batch, got %v", err)
	}
	t.Logf("CONFIRMED remaining batch-isolation issue: %v", err)
}

// The current builder intentionally retains Android's two fields on one rule.
// Verify what that actually means, without asserting it is source-or-destination.
func TestAuditDocumentedMulticastAndSemantics(t *testing.T) {
	ctx := leanProbeContext(context.Background())
	options, err := json.UnmarshalExtendedContext[option.Rule](ctx, []byte(`{
		"ip_cidr":["224.0.0.0/3","ff00::/8"],
		"source_ip_cidr":["224.0.0.0/3","ff00::/8"],"action":"reject"
	}`))
	if err != nil {
		t.Fatal(err)
	}
	r, err := routerule.NewRule(ctx, log.NewNOPFactory().Logger(), options, false)
	if err != nil {
		t.Fatal(err)
	}
	for _, source := range []string{"192.0.2.1:5353", "224.0.0.2:5353"} {
		metadata := &adapter.InboundContext{
			Source: M.ParseSocksaddr(source), Destination: M.ParseSocksaddr("224.0.0.1:5353"),
		}
		want := strings.HasPrefix(source, "224.")
		if r.Match(metadata) != want {
			t.Fatalf("source %s: expected source AND destination match = %v", source, want)
		}
	}
}
