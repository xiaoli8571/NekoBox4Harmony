package config

import (
	"context"
	"net"
	"net/netip"
	"sort"

	E "github.com/sagernet/sing/common/exceptions"
	M "github.com/sagernet/sing/common/metadata"
)

type CompiledIPRule struct {
	prefix netip.Prefix
	ports  []int
	allow  bool
}

type IPRulePolicy struct {
	rules []CompiledIPRule
}

func NewIPRulePolicy(rawRules []IPRule) (*IPRulePolicy, error) {
	policy := &IPRulePolicy{
		rules: make([]CompiledIPRule, 0, len(rawRules)),
	}
	for _, rawRule := range rawRules {
		if rawRule.Prefix == "" {
			return nil, E.New("ip_rule prefix cannot be blank")
		}
		prefix, err := netip.ParsePrefix(rawRule.Prefix)
		if err != nil {
			return nil, E.Cause(err, "parse ip_rule prefix")
		}
		ports := append([]int(nil), rawRule.Ports...)
		sort.Ints(ports)
		for _, port := range ports {
			if port < 1 || port > 65535 {
				return nil, E.New("invalid ip_rule port: ", port)
			}
		}
		policy.rules = append(policy.rules, CompiledIPRule{
			prefix: prefix,
			ports:  ports,
			allow:  rawRule.Allow,
		})
	}
	return policy, nil
}

func (p *IPRulePolicy) Allow(ctx context.Context, destination M.Socksaddr) (bool, error) {
	if p == nil {
		return false, nil
	}
	ipAddr, err := ResolvePolicyDestination(ctx, destination)
	if err != nil {
		return false, err
	}
	port := int(destination.Port)
	for _, rule := range p.rules {
		if !rule.prefix.Contains(ipAddr) {
			continue
		}
		if len(rule.ports) == 0 {
			return rule.allow, nil
		}
		portIndex := sort.SearchInts(rule.ports, port)
		if portIndex < len(rule.ports) && rule.ports[portIndex] == port {
			return rule.allow, nil
		}
	}
	return false, nil
}

func ResolvePolicyDestination(ctx context.Context, destination M.Socksaddr) (netip.Addr, error) {
	if destination.IsIP() {
		return destination.Unwrap().Addr, nil
	}
	if !M.IsDomainName(destination.Fqdn) {
		return netip.Addr{}, E.New("destination is neither IP nor FQDN")
	}
	ipAddrs, err := net.DefaultResolver.LookupIPAddr(ctx, destination.Fqdn)
	if err != nil {
		return netip.Addr{}, E.Cause(err, "resolve destination")
	}
	if len(ipAddrs) == 0 {
		return netip.Addr{}, E.New("resolved destination is empty")
	}
	resolvedAddr, ok := netip.AddrFromSlice(ipAddrs[0].IP)
	if !ok {
		return netip.Addr{}, E.New("resolved destination is invalid")
	}
	return resolvedAddr.Unmap(), nil
}
