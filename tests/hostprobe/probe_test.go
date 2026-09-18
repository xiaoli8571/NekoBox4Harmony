package parityprobe

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter/certificate"
	"github.com/sagernet/sing-box/adapter/endpoint"
	"github.com/sagernet/sing-box/adapter/inbound"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/adapter/service"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/dns/transport"
	"github.com/sagernet/sing-box/dns/transport/fakeip"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/direct"
	"github.com/sagernet/sing-box/protocol/mixed"
	"github.com/sagernet/sing-box/protocol/socks"
	"github.com/sagernet/sing-box/protocol/group"
	routerule "github.com/sagernet/sing-box/route/rule"
	"github.com/sagernet/sing/common/json"
)

// leanContext mirrors core/libsingbox14/lean_context.go with the minimum
// registries needed by the probe configs (mixed inbound, direct outbound,
// UDP + fakeip DNS transports). No CGo, no TUN, no network dialing.
func leanProbeContext(ctx context.Context) context.Context {
	inboundRegistry := inbound.NewRegistry()
	mixed.RegisterInbound(inboundRegistry)
	outboundRegistry := outbound.NewRegistry()
	direct.RegisterOutbound(outboundRegistry)
	socks.RegisterOutbound(outboundRegistry)
	group.RegisterSelector(outboundRegistry)
	endpointRegistry := endpoint.NewRegistry()
	dnsRegistry := dns.NewTransportRegistry()
	transport.RegisterUDP(dnsRegistry)
	fakeip.RegisterTransport(dnsRegistry)
	return box.Context(ctx, inboundRegistry, outboundRegistry, endpointRegistry,
		dnsRegistry, service.NewRegistry(), certificate.NewRegistry())
}

func startBox(t *testing.T, configJSON string) error {
	t.Helper()
	ctx := leanProbeContext(context.Background())
	opt, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		t.Fatalf("config parse failed: %v", err)
	}
	_ = opt
	instance, err := box.New(box.Options{Context: ctx, Options: opt})
	if err != nil {
		return err
	}
	defer instance.Close()
	return instance.Start()
}

func startBoxRaw(t *testing.T, configJSON string) error {
	t.Helper()
	ctx := leanProbeContext(context.Background())
	opt, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		return err
	}
	_ = opt
	instance, err := box.New(box.Options{Context: ctx, Options: opt})
	if err != nil {
		return err
	}
	defer instance.Close()
	return instance.Start()
}

// CORE-01: dangling rule-set reference must fail at start.
func TestRuleSetReferenceWithoutDefinitionFails(t *testing.T) {
	err := startBoxRaw(t, probeConfig(""))
	if err == nil {
		t.Fatal("expected kernel start failure for dangling geosite:cn reference, got nil")
	}
	if !strings.Contains(err.Error(), "rule-set not found") {
		t.Fatalf("expected 'rule-set not found', got: %v", err)
	}
	t.Logf("CONFIRMED kernel rejects dangling reference: %v", err)
}

// CORE-01 fix contract: same-tag local definition starts cleanly.
func TestRuleSetReferenceWithDefinitionStarts(t *testing.T) {
	dir := t.TempDir()
	srsPath := filepath.Join(dir, "geosite-cn.srs")
	if err := os.WriteFile(srsPath, minimalSRS(t), 0o644); err != nil {
		t.Fatal(err)
	}
	def := `{"type":"local","tag":"geosite:cn","format":"binary","path":"` + strings.ReplaceAll(srsPath, `\`, `\\`) + `"}`
	if err := startBox(t, probeConfig(def)); err != nil {
		t.Fatalf("expected clean start with matching definition, got: %v", err)
	}
}

// CORE-02 fix contract: the generated DNS config shape (user rules + fakeip
// fallback + predefined reject) must be accepted by the real kernel schema.
func TestUserDnsRulesAndFakeipFallbackAccepted(t *testing.T) {
	cfg := `{
	  "log":{"level":"panic"},
	  "dns":{
	    "servers":[
	      {"type":"udp","tag":"remote","server":"192.0.2.10"},
	      {"type":"udp","tag":"local","server":"192.0.2.11"},
	      {"type":"fakeip","tag":"fake","inet4_range":"198.18.0.0/15"}
	    ],
	    "rules":[
	      {"domain":["test.example.org"],"server":"local"},
	      {"domain":["blocked.example.org"],"action":"predefined","rcode":3},
	      {"domain":["fake.example.org"],"server":"fake","inbound":["tun-in"]},
	      {"inbound":["tun-in"],"query_type":["A","AAAA"],"server":"fake"}
	    ],
	    "final":"remote"
	  },
	  "inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":19999}],
	  "outbounds":[{"type":"direct","tag":"direct"}],
	  "route":{"rules":[],"final":"direct","auto_detect_interface":false}
	}`
	if err := startBox(t, cfg); err != nil {
		t.Fatalf("kernel rejected CORE-02 config shape: %v", err)
	}
}

// CORE-04 red test: the sniff rule action must accept override_destination
// (Android trafficSniffing=override needs it). Before the kernel patch the
// strict schema rejects the unknown field; after, it parses and starts.
func TestSniffOverrideDestinationAccepted(t *testing.T) {
	cfg := `{
	  "log":{"level":"panic"},
	  "dns":{"servers":[{"type":"udp","tag":"local","server":"192.0.2.11"}],"final":"local"},
	  "inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":19999}],
	  "outbounds":[{"type":"direct","tag":"direct"}],
	  "route":{"rules":[{"inbound":["mixed-in"],"action":"sniff","override_destination":true}],"final":"direct","auto_detect_interface":false}
	}`
	if err := startBox(t, cfg); err != nil {
		t.Fatalf("kernel rejected override_destination sniff action: %v", err)
	}
}

// Verify parsed JSON reaches the runtime action, not merely the schema.
func TestSniffOverrideRuntimeWiring(t *testing.T) {
	for _, value := range []string{"false", "true"} {
		t.Run(value, func(t *testing.T) {
			ctx := leanProbeContext(context.Background())
			options, err := json.UnmarshalExtendedContext[option.RuleAction](ctx,
				[]byte(`{"action":"sniff","override_destination":`+value+`}`))
			if err != nil { t.Fatal(err) }
			action, err := routerule.NewRuleAction(ctx, nil, options)
			if err != nil { t.Fatal(err) }
			sniff, ok := action.(*routerule.RuleActionSniff)
			if !ok { t.Fatalf("unexpected action type %T", action) }
			if sniff.OverrideDestination != (value == "true") {
				t.Fatalf("runtime override = %v, JSON = %s", sniff.OverrideDestination, value)
			}
		})
	}
}

func probeConfig(ruleSetDefs string) string {
	defs := ""
	if ruleSetDefs != "" {
		defs = `,"rule_set":[` + ruleSetDefs + `]`
	}
	return `{
	  "log":{"level":"panic"},
	  "dns":{"servers":[{"type":"udp","tag":"local","server":"223.5.5.5"}],"final":"local"},
	  "inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":19999}],
	  "outbounds":[{"type":"direct","tag":"direct"}],
	  "route":{"rules":[{"rule_set":["geosite:cn"],"outbound":"direct"}],"final":"direct","auto_detect_interface":false` + defs + `}
	}`
}

func minimalSRS(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("fixtures/geosite-cn.srs")
	if err != nil {
		t.Fatalf("fixture missing (run: go run ./genfixture): %v", err)
	}
	return data
}
