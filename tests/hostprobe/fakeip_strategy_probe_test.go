package parityprobe

import (
	"strings"
	"testing"
)

// CORE-03 kernel contract: which strategy knobs the 1.14 schema accepts for the
// FakeIP server / its selecting rule. Android's legacy 1.11 form put
// strategy="ipv4_only" on the dns-fake server (ConfigBuilder.kt:719); 1.14
// typed transports do not accept it, so this test documents the exact boundary
// instead of silently emitting a field the kernel rejects.
func TestFakeIPStrategySchemaShape(t *testing.T) {
	type probe struct {
		name     string
		server   string
		rule     string
		accepted bool
		reason   string
	}
	cases := []probe{
		{
			name:     "both ranges without strategy",
			server:   `{"type":"fakeip","tag":"fake","inet4_range":"198.18.0.0/15","inet6_range":"fc00::/18"}`,
			rule:     `{"inbound":["tun-in"],"query_type":["A","AAAA"],"server":"fake","disable_cache":true}`,
			accepted: true,
		},
		{
			name:     "server-level legacy strategy",
			server:   `{"type":"fakeip","tag":"fake","inet4_range":"198.18.0.0/15","strategy":"ipv4_only"}`,
			rule:     `{"inbound":["tun-in"],"query_type":["A","AAAA"],"server":"fake","disable_cache":true}`,
			accepted: false,
			reason:   "unknown field",
		},
		{
			name:     "rule-level legacy strategy",
			server:   `{"type":"fakeip","tag":"fake","inet4_range":"198.18.0.0/15","inet6_range":"fc00::/18"}`,
			rule:     `{"inbound":["tun-in"],"query_type":["A","AAAA"],"server":"fake","strategy":"ipv4_only"}`,
			accepted: false,
			reason:   "deprecated",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := `{
			  "log":{"level":"panic"},
			  "dns":{
			    "servers":[{"type":"udp","tag":"remote","server":"192.0.2.10"},` + c.server + `],
			    "rules":[` + c.rule + `],
			    "final":"remote"
			  },
			  "inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":19999}],
			  "outbounds":[{"type":"direct","tag":"direct"}],
			  "route":{"rules":[],"final":"direct","auto_detect_interface":false}
			}`
			// startBoxRaw returns parse errors instead of failing the test,
			// which is required to assert schema-level rejection.
			err := startBoxRaw(t, cfg)
			if c.accepted && err != nil {
				t.Fatalf("expected the kernel to accept this shape, got: %v", err)
			}
			if !c.accepted {
				if err == nil {
					t.Fatalf("expected rejection, but the kernel accepted the shape")
				}
				if !strings.Contains(err.Error(), c.reason) {
					t.Fatalf("expected rejection mentioning %q, got: %v", c.reason, err)
				}
				t.Logf("CONFIRMED unsupported in 1.14: %v", err)
			}
		})
	}
}
