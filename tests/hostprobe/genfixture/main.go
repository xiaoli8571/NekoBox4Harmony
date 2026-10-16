// Command genfixture writes the binary .srs fixture used by parityprobe.
// Run once: go run ./genfixture  (from tests/hostprobe)
package main

import (
	"os"

	"github.com/sagernet/sing-box/common/srs"
	"github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json/badoption"
)

func main() {
	// Minimal domain-suffix headless rule; mirrors what geosite.Compile
	// would emit for RuleTypeDomainSuffix entries (libcore copies these
	// fields 1:1 into DefaultHeadlessRule).
	ruleSet := option.PlainRuleSet{
		Rules: []option.HeadlessRule{{
			Type:           constant.RuleTypeDefault,
			DefaultOptions: option.DefaultHeadlessRule{
				DomainSuffix: badoption.Listable[string]{"example.org"},
			},
		}},
	}
	if err := os.MkdirAll("fixtures", 0o755); err != nil {
		panic(err)
	}
	f, err := os.Create("fixtures/geosite-cn.srs")
	if err != nil {
		panic(err)
	}
	defer f.Close()
	if err := srs.Write(f, ruleSet, constant.RuleSetVersionCurrent); err != nil {
		panic(err)
	}
}
