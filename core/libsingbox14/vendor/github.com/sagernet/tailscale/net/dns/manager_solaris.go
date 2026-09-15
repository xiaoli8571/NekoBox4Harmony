// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package dns

import (
	"github.com/sagernet/tailscale/control/controlknobs"
	"github.com/sagernet/tailscale/health"
	"github.com/sagernet/tailscale/types/logger"
	"github.com/sagernet/tailscale/util/eventbus"
	"github.com/sagernet/tailscale/util/syspolicy/policyclient"
)

func NewOSConfigurator(logf logger.Logf, health *health.Tracker, bus *eventbus.Bus, _ policyclient.Client, _ *controlknobs.Knobs, iface string) (OSConfigurator, error) {
	return newDirectManager(logf, health, bus), nil
}
