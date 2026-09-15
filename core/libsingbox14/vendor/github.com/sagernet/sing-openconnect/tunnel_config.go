package openconnect

import (
	"net/netip"
	"slices"
	"time"
)

const minimumIPv6MTU = 1280

type TunnelConfigurationEventReason string

const (
	TunnelConfigurationEventInitial         TunnelConfigurationEventReason = "initial"
	TunnelConfigurationEventReestablishment TunnelConfigurationEventReason = "reestablishment"
	TunnelConfigurationEventRekey           TunnelConfigurationEventReason = "rekey"
	TunnelConfigurationEventPathMTU         TunnelConfigurationEventReason = "path-mtu"
)

type TunnelConfiguration struct {
	MTU                        uint32
	RemoteAddress              netip.Addr
	Addresses                  []netip.Prefix
	Routes                     []TunnelRoute
	ExcludedRoutes             []TunnelRoute
	DNS                        []netip.Addr
	NBNS                       []netip.Addr
	SearchDomains              []string
	SplitDNS                   []string
	SplitDNSRules              []TunnelSplitDNSRule
	ProxyAutoConfigURL         string
	Banner                     string
	TunnelAllDNS               bool
	ClientBypassProtocol       bool
	IdleTimeout                time.Duration
	AuthenticationExpiration   time.Time
	defaultIPv4RouteSuppressed bool
	defaultIPv6RouteSuppressed bool
}

type TunnelSplitDNSRule struct {
	Domains []string
	Servers []netip.Addr
}

type TunnelRoute struct {
	Prefix  netip.Prefix
	Gateway netip.Addr
	Metric  int
}

type TunnelConfigurationEvent struct {
	Reason        TunnelConfigurationEventReason
	Configuration TunnelConfiguration
}

func cloneTunnelConfiguration(configuration TunnelConfiguration) TunnelConfiguration {
	configuration.Addresses = append([]netip.Prefix(nil), configuration.Addresses...)
	configuration.Routes = append([]TunnelRoute(nil), configuration.Routes...)
	configuration.ExcludedRoutes = append([]TunnelRoute(nil), configuration.ExcludedRoutes...)
	configuration.DNS = append([]netip.Addr(nil), configuration.DNS...)
	configuration.NBNS = append([]netip.Addr(nil), configuration.NBNS...)
	configuration.SearchDomains = append([]string(nil), configuration.SearchDomains...)
	configuration.SplitDNS = append([]string(nil), configuration.SplitDNS...)
	configuration.SplitDNSRules = append([]TunnelSplitDNSRule(nil), configuration.SplitDNSRules...)
	for ruleIndex := range configuration.SplitDNSRules {
		configuration.SplitDNSRules[ruleIndex].Domains = append([]string(nil), configuration.SplitDNSRules[ruleIndex].Domains...)
		configuration.SplitDNSRules[ruleIndex].Servers = append([]netip.Addr(nil), configuration.SplitDNSRules[ruleIndex].Servers...)
	}
	return configuration
}

func normalizeTunnelConfiguration(configuration TunnelConfiguration, ipv6Disabled bool) TunnelConfiguration {
	configuration = cloneTunnelConfiguration(configuration)
	if ipv6Disabled {
		configuration.Addresses = slices.DeleteFunc(configuration.Addresses, func(prefix netip.Prefix) bool {
			return prefix.Addr().Is6()
		})
		configuration.Routes = slices.DeleteFunc(configuration.Routes, func(route TunnelRoute) bool {
			return route.Prefix.Addr().Is6()
		})
		configuration.ExcludedRoutes = slices.DeleteFunc(configuration.ExcludedRoutes, func(route TunnelRoute) bool {
			return route.Prefix.Addr().Is6()
		})
		configuration.DNS = slices.DeleteFunc(configuration.DNS, netip.Addr.Is6)
		configuration.NBNS = slices.DeleteFunc(configuration.NBNS, netip.Addr.Is6)
		filteredRules := configuration.SplitDNSRules[:0]
		for _, rule := range configuration.SplitDNSRules {
			rule.Servers = slices.DeleteFunc(rule.Servers, netip.Addr.Is6)
			if len(rule.Servers) > 0 {
				filteredRules = append(filteredRules, rule)
			}
		}
		configuration.SplitDNSRules = filteredRules
	}
	hasIPv4Address := false
	hasIPv6Address := false
	for _, address := range configuration.Addresses {
		if address.Addr().Unmap().Is4() {
			hasIPv4Address = true
		} else if address.Addr().Is6() {
			hasIPv6Address = true
		}
	}
	hasIPv4Route := false
	hasIPv6Route := false
	for _, route := range configuration.Routes {
		if route.Prefix.Addr().Unmap().Is4() {
			hasIPv4Route = true
		} else if route.Prefix.Addr().Is6() {
			hasIPv6Route = true
		}
	}
	if hasIPv4Address && !hasIPv4Route && !configuration.defaultIPv4RouteSuppressed {
		configuration.Routes = append(configuration.Routes, TunnelRoute{Prefix: netip.PrefixFrom(netip.IPv4Unspecified(), 0)})
	}
	if hasIPv6Address && !hasIPv6Route && !configuration.defaultIPv6RouteSuppressed {
		configuration.Routes = append(configuration.Routes, TunnelRoute{Prefix: netip.PrefixFrom(netip.IPv6Unspecified(), 0)})
	}
	return configuration
}
