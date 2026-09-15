package openvpn

import (
	"slices"
	"strconv"
	"strings"
	"sync"

	E "github.com/sagernet/sing/common/exceptions"
)

type clientTunnelState struct {
	access                   sync.RWMutex
	configuration            TunnelConfiguration
	authToken                string
	authTokenUser            string
	pulledOptionsReceived    bool
	modernDNSConfigured      bool
	modernSearchDomains      []string
	deferInitialEvent        bool
	pullFilterRejection      string
	compressionPushRejection string
	dispatcher               clientTunnelConfigurationDispatcher
}

type clientTunnelConfigurationDispatcher struct {
	events  []TunnelConfigurationEvent
	wake    chan struct{}
	started bool
	stopped bool
}

func (c *Client) TunnelConfiguration() TunnelConfiguration {
	c.tunnel.access.RLock()
	defer c.tunnel.access.RUnlock()
	return cloneTunnelConfiguration(c.tunnel.configuration)
}

func (c *Client) emitTunnelConfigurationEvent(reason TunnelConfigurationEventReason) {
	if c.options.OnTunnelConfiguration == nil {
		return
	}
	c.tunnel.access.Lock()
	configurationSnapshot := cloneTunnelConfiguration(c.tunnel.configuration)
	eventQueued := c.enqueueTunnelConfigurationEventLocked(TunnelConfigurationEvent{
		Reason:        reason,
		Configuration: configurationSnapshot,
	})
	c.tunnel.access.Unlock()
	if eventQueued {
		c.signalTunnelConfigurationEvent()
	}
}

func (c *Client) startTunnelConfigurationDispatcher() {
	if c.options.OnTunnelConfiguration == nil {
		return
	}
	c.tunnel.access.Lock()
	if c.tunnel.dispatcher.started || c.tunnel.dispatcher.stopped {
		c.tunnel.access.Unlock()
		return
	}
	c.tunnel.dispatcher.started = true
	c.tunnel.access.Unlock()
	go c.runTunnelConfigurationDispatcher()
}

func (c *Client) enqueueTunnelConfigurationEventLocked(event TunnelConfigurationEvent) bool {
	if c.options.OnTunnelConfiguration == nil || c.tunnel.dispatcher.stopped {
		return false
	}
	c.tunnel.dispatcher.events = append(c.tunnel.dispatcher.events, event)
	return true
}

func (c *Client) signalTunnelConfigurationEvent() {
	select {
	case c.tunnel.dispatcher.wake <- struct{}{}:
	default:
	}
}

func (c *Client) runTunnelConfigurationDispatcher() {
	for {
		c.tunnel.access.Lock()
		if c.tunnel.dispatcher.stopped {
			c.tunnel.dispatcher.events = nil
			c.tunnel.access.Unlock()
			return
		}
		if len(c.tunnel.dispatcher.events) == 0 {
			c.tunnel.access.Unlock()
			<-c.tunnel.dispatcher.wake
			continue
		}
		event := c.tunnel.dispatcher.events[0]
		c.tunnel.dispatcher.events[0] = TunnelConfigurationEvent{}
		c.tunnel.dispatcher.events = c.tunnel.dispatcher.events[1:]
		c.tunnel.access.Unlock()
		err := c.options.OnTunnelConfiguration(event)
		if err != nil {
			c.failSessionForTunnelConfiguration(err)
		}
	}
}

func (c *Client) failSessionForTunnelConfiguration(err error) {
	failure := E.Cause(err, "apply tunnel configuration")
	if c.options.Logger != nil {
		c.options.Logger.WarnContext(c.options.Context, failure)
	}
	c.lifecycle.access.Lock()
	session := c.lifecycle.currentSession
	c.lifecycle.access.Unlock()
	if session != nil {
		session.Fail(failure)
	}
}

func (c *Client) stopTunnelConfigurationDispatcher() {
	c.tunnel.access.Lock()
	c.tunnel.dispatcher.stopped = true
	c.tunnel.dispatcher.events = nil
	c.tunnel.access.Unlock()
	c.signalTunnelConfigurationEvent()
}

type pushedOptionsApplyResult struct {
	pullFilterRejection      string
	compressionPushRejection string
}

func (c *Client) applyPushedOptions(options pushedOptions) pushedOptionsApplyResult {
	c.tunnel.access.Lock()
	c.tunnel.pullFilterRejection = options.pullFilterRejection
	c.tunnel.compressionPushRejection = ""
	isInitialPulledOptions := !c.tunnel.pulledOptionsReceived
	deferInitialTunnelEvent := isInitialPulledOptions && c.tunnel.deferInitialEvent
	eventReason := TunnelConfigurationEventInitial
	if !isInitialPulledOptions {
		eventReason = TunnelConfigurationEventRenegotiation
	}
	if options.kind == pushOptionsKindUpdate {
		eventReason = TunnelConfigurationEventPushUpdate
	}
	c.tunnel.pulledOptionsReceived = true
	updatedConfiguration := cloneTunnelConfiguration(c.tunnel.configuration)
	c.tunnel.modernSearchDomains = appendUniqueStringValues(c.tunnel.modernSearchDomains, options.modernSearchDomains)
	if options.PingRestartEnabled != options.PingExitSet {
		if options.PingRestartEnabled {
			updatedConfiguration.PingExit = 0
		} else {
			updatedConfiguration.PingRestart = 0
		}
	}
	if options.Topology != "" {
		updatedConfiguration.Topology = options.Topology
	}
	parseErrors := slices.Clone(options.parseErrors)
	pushedLocalIPv4 := options.localAddressByFamily(true)
	if len(pushedLocalIPv4) > 0 {
		localIPv4, vpnGateway := pushedLocalAddressPrefixes(pushedLocalIPv4)
		updatedConfiguration.LocalIPv4 = localIPv4
		updatedConfiguration.VPNGateway = vpnGateway
	}
	pushedLocalIPv6 := options.localAddressByFamily(false)
	if len(pushedLocalIPv6) > 0 {
		localIPv6, vpnGatewayIPv6 := pushedLocalAddressPrefixes(pushedLocalIPv6)
		updatedConfiguration.LocalIPv6 = localIPv6
		updatedConfiguration.VPNGatewayIPv6 = vpnGatewayIPv6
	}
	if options.TunMTU > 0 {
		updatedConfiguration.TunMTU = options.TunMTU
	}
	if !c.options.Pull.RouteNoPull {
		if options.modernDNS && !c.tunnel.modernDNSConfigured {
			updatedConfiguration.DNS = nil
			updatedConfiguration.SearchDomains = slices.Clone(c.tunnel.modernSearchDomains)
			updatedConfiguration.DNSRoutes = nil
			updatedConfiguration.DHCPOptions = filterOpenVPNNonDNSDHCPOptions(updatedConfiguration.DHCPOptions)
			c.tunnel.modernDNSConfigured = true
		}
		if c.tunnel.modernDNSConfigured {
			updatedConfiguration.DNS = appendUniqueAddresses(updatedConfiguration.DNS, pushedAddresses(options.modernDNSAddresses))
			updatedConfiguration.DNSServers = mergeTunnelDNSServers(updatedConfiguration.DNSServers, options.DNSServers)
			updatedConfiguration.SearchDomains = appendUniqueStringValues(updatedConfiguration.SearchDomains, options.modernSearchDomains)
			updatedConfiguration.DHCPOptions = appendUniqueStringValues(updatedConfiguration.DHCPOptions, filterOpenVPNNonDNSDHCPOptions(options.DHCPOptions))
		} else {
			updatedConfiguration.DNS = appendUniqueAddresses(updatedConfiguration.DNS, pushedAddresses(options.DNS))
			updatedConfiguration.DHCPOptions = appendUniqueStringValues(updatedConfiguration.DHCPOptions, options.DHCPOptions)
			updatedConfiguration.SearchDomains = appendUniqueStringValues(updatedConfiguration.SearchDomains, options.SearchDomains)
			updatedConfiguration.DNSRoutes = appendUniqueStringValues(updatedConfiguration.DNSRoutes, options.DNSRoutes)
		}
		if options.BlockIPv6 {
			updatedConfiguration.BlockIPv6 = true
		}
		if options.BlockOutsideDNS {
			updatedConfiguration.BlockOutsideDNS = true
		}
		if options.RouteMetricSet {
			updatedConfiguration.RouteMetric = options.RouteMetric
		}
	}
	if options.PingIntervalEnabled {
		updatedConfiguration.PingInterval = options.PingInterval
	}
	if options.PingRestartEnabled {
		updatedConfiguration.PingRestart = options.PingRestart
	}
	if options.AuthToken != "" {
		updatedConfiguration.AuthToken = options.AuthToken
		c.tunnel.authToken = options.AuthToken
	}
	if options.AuthTokenUser != "" {
		updatedConfiguration.AuthTokenUser = options.AuthTokenUser
		c.tunnel.authTokenUser = options.AuthTokenUser
	}
	if options.ExplicitExitNotifySet {
		updatedConfiguration.ExplicitExitNotify = options.ExplicitExitNotify
	}
	if options.PeerID != nil {
		peerIDValue := *options.PeerID
		updatedConfiguration.PeerID = &peerIDValue
	}
	if options.SelectedCipher != "" {
		updatedConfiguration.SelectedCipher = options.SelectedCipher
	}
	if options.SelectedAuth != "" {
		updatedConfiguration.SelectedAuth = options.SelectedAuth
	}
	if len(options.ProtocolFlags) > 0 {
		updatedConfiguration.ProtocolFlags = slices.Clone(options.ProtocolFlags)
	}
	if options.KeyDerivation != "" {
		updatedConfiguration.KeyDerivation = options.KeyDerivation
	}
	if options.InactiveTimeoutSet {
		updatedConfiguration.InactiveTimeout = options.InactiveTimeout
		updatedConfiguration.InactiveMinimumBytes = options.InactiveMinimumBytes
	}
	if options.SessionTimeoutSet {
		updatedConfiguration.SessionTimeout = options.SessionTimeout
	}
	if options.PingExitSet {
		updatedConfiguration.PingExit = options.PingExit
	}
	if options.PingTimerRemote {
		updatedConfiguration.PingTimerRemote = true
	}
	if options.RouteGateway.IsValid() || options.RouteGatewayVPN {
		effectiveRouteGateway := options.routeGateway(updatedConfiguration.VPNGateway, updatedConfiguration.Topology)
		if effectiveRouteGateway.IsValid() {
			updatedConfiguration.RouteGateway = effectiveRouteGateway
		} else {
			parseErrors = append(parseErrors, pushedOptionParseError{
				Name:  "route-gateway",
				Value: options.routeGatewayFilterValue(),
				Err:   errInvalidPushedRouteGateway,
			})
		}
	}
	if !c.options.Pull.RouteNoPull {
		updatedConfiguration.IPv4Routes = appendUniqueTunnelRoutes(updatedConfiguration.IPv4Routes, pushedTunnelRoutes(options.routesByFamily(true), updatedConfiguration.RouteMetric))
		updatedConfiguration.IPv6Routes = appendUniqueTunnelRoutes(updatedConfiguration.IPv6Routes, pushedTunnelRoutes(options.routesByFamily(false), updatedConfiguration.RouteMetric))
		for _, excludedRoute := range options.excludedRoutes {
			if excludedRoute.Route.Prefix.Addr().Is4() {
				updatedConfiguration.ExcludedIPv4Routes = appendUniqueTunnelRoutes(updatedConfiguration.ExcludedIPv4Routes, []TunnelRoute{excludedRoute.Route})
			} else {
				updatedConfiguration.ExcludedIPv6Routes = appendUniqueTunnelRoutes(updatedConfiguration.ExcludedIPv6Routes, []TunnelRoute{excludedRoute.Route})
			}
		}
		if options.RedirectGateway {
			updatedConfiguration.RedirectGateway = options.RedirectGateway
			updatedConfiguration.RedirectGatewayFlags = slices.Clone(options.RedirectGatewayFlags)
		}
		if options.RedirectPrivate {
			updatedConfiguration.RedirectPrivate = true
		}
	}
	// OpenVPN 2.6 init_route and init_route_ipv6 resolve omitted gateways only
	// after route-gateway and pulled ifconfig endpoints are available.
	ipv4RouteGateway := updatedConfiguration.RouteGateway
	if !ipv4RouteGateway.Is4() {
		ipv4RouteGateway = updatedConfiguration.VPNGateway
	}
	fillTunnelRouteGateways(updatedConfiguration.IPv4Routes, ipv4RouteGateway)
	fillTunnelRouteGateways(updatedConfiguration.IPv6Routes, updatedConfiguration.VPNGatewayIPv6)
	c.tunnel.configuration = updatedConfiguration
	if isInitialPulledOptions {
		c.maybeReconfigureDataFramingFromPushedOptions(options)
	}
	c.warnPushedOptionParseErrors(parseErrors)
	configurationSnapshot := cloneTunnelConfiguration(c.tunnel.configuration)
	eventQueued := false
	if !deferInitialTunnelEvent {
		eventQueued = c.enqueueTunnelConfigurationEventLocked(TunnelConfigurationEvent{
			Reason:        eventReason,
			Configuration: configurationSnapshot,
		})
	}
	applyResult := pushedOptionsApplyResult{
		pullFilterRejection:      c.tunnel.pullFilterRejection,
		compressionPushRejection: c.tunnel.compressionPushRejection,
	}
	c.tunnel.access.Unlock()
	if eventQueued {
		c.signalTunnelConfigurationEvent()
	}
	return applyResult
}

func mergeTunnelDNSServers(destination []TunnelDNSServer, servers []TunnelDNSServer) []TunnelDNSServer {
	merged := cloneTunnelDNSServers(destination)
	for _, server := range servers {
		server.Addresses = slices.Clone(server.Addresses)
		server.ResolveDomains = slices.Clone(server.ResolveDomains)
		serverIndex := slices.IndexFunc(merged, func(existing TunnelDNSServer) bool {
			return existing.Priority == server.Priority
		})
		if serverIndex < 0 {
			merged = append(merged, server)
			continue
		}
		merged[serverIndex] = server
	}
	slices.SortFunc(merged, func(left TunnelDNSServer, right TunnelDNSServer) int {
		return left.Priority - right.Priority
	})
	return merged
}

func (c *Client) setInitialTunnelEventDeferred(deferred bool) {
	c.tunnel.access.Lock()
	c.tunnel.deferInitialEvent = deferred
	c.tunnel.access.Unlock()
}

func (c *Client) clearAuthToken() bool {
	stagedUsername := c.loadStagedCredentials().username
	c.tunnel.access.Lock()
	tokenConfiguration := TunnelConfiguration{
		AuthToken:     c.tunnel.authToken,
		AuthTokenUser: c.tunnel.authTokenUser,
	}
	_, _, tokenDefined := resolveAuthTokenCredentials(c.options, tokenConfiguration, stagedUsername)
	c.tunnel.authToken = ""
	c.tunnel.authTokenUser = ""
	c.tunnel.configuration.AuthToken = ""
	c.tunnel.configuration.AuthTokenUser = ""
	c.tunnel.access.Unlock()
	return tokenDefined
}

func (c *Client) maybeReconfigureDataFramingFromPushedOptions(options pushedOptions) {
	if len(options.CompressionDirectives) == 0 {
		return
	}
	// Upstream apply_push_options (options.c) replays every pushed compress
	// and comp-lzo directive through add_option in wire order, on top of the
	// compression state the local configuration already established.
	pushedCompression := c.dataPlane.compression
	rejectionParts := make([]string, 0, len(options.CompressionDirectives))
	for _, directive := range options.CompressionDirectives {
		rejectionPart := directive.Name
		if directive.Value != "" {
			rejectionPart += " " + directive.Value
		}
		rejectionParts = append(rejectionParts, rejectionPart)
		err := pushedCompression.apply(directive)
		if err != nil {
			c.tunnel.compressionPushRejection = strings.Join(rejectionParts, "; ")
			return
		}
	}
	// Upstream check_compression_settings_valid (comp.c) rejects the merged
	// compression state whenever it is non-stub under --allow-compression no.
	if c.dataPlane.allowCompressionPolicy == allowCompressionStubOnly && pushedCompression.nonStubEnabled() {
		c.tunnel.compressionPushRejection = strings.Join(rejectionParts, "; ")
		return
	}
	if pushedCompression == c.dataPlane.compression {
		return
	}
	c.dataPlane.framing.Store(newDataChannelFraming(pushedCompression, c.options.DataChannel.Fragment, c.dataPlane.allowCompressionPolicy))
}

func (c *Client) warnPushedOptionParseErrors(parseErrors []pushedOptionParseError) {
	var ignoredOptions []string
	for _, parseErr := range parseErrors {
		if parseErr.Err == nil {
			continue
		}
		if c.options.Pull.RouteNoPull && routeNoPullBlocksOption(parseErr.Name) {
			continue
		}
		ignoredOptions = append(ignoredOptions, parseErr.Name+" "+strconv.Quote(parseErr.Value)+": "+parseErr.Err.Error())
	}
	if len(ignoredOptions) > 0 && c.options.Logger != nil {
		c.options.Logger.WarnContext(c.options.Context, "ignored pushed options: ", strings.Join(ignoredOptions, "; "))
	}
}

func routeNoPullBlocksOption(optionName string) bool {
	switch optionName {
	case "route", "route-ipv6", "route-metric", "redirect-gateway", "redirect-private", "dns", "dhcp-option", "block-ipv6", "block-outside-dns":
		return true
	default:
		return false
	}
}

func appendUniqueStringValues(destination []string, values []string) []string {
	if len(values) == 0 {
		return destination
	}
	mergedValues := slices.Clone(destination)
	seenValues := make(map[string]struct{}, len(mergedValues))
	for _, value := range mergedValues {
		seenValues[value] = struct{}{}
	}
	for _, value := range values {
		_, exists := seenValues[value]
		if exists {
			continue
		}
		seenValues[value] = struct{}{}
		mergedValues = append(mergedValues, value)
	}
	return mergedValues
}

func (c *Client) PullFilterRejection() string {
	c.tunnel.access.RLock()
	defer c.tunnel.access.RUnlock()
	return c.tunnel.pullFilterRejection
}

func (c *Client) CompressionPushRejection() string {
	c.tunnel.access.RLock()
	defer c.tunnel.access.RUnlock()
	return c.tunnel.compressionPushRejection
}
