// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

// Package featureknob provides a facility to control whether features
// can run based on either an envknob or running OS / distro.
package featureknob

import (
	"errors"

	"github.com/sagernet/tailscale/version/distro"
)

// CanRunTailscaleSSH reports whether serving a Tailscale SSH server is
// supported for the current os/distro.
func CanRunTailscaleSSH() error {
	return nil
}

// CanUseExitNode reports whether using an exit node is supported for the
// current os/distro.
func CanUseExitNode() error {
	switch dist := distro.Get(); dist {
	case distro.Synology, // see https://github.com/tailscale/tailscale/issues/1995
		distro.QNAP:
		return errors.New("Tailscale exit nodes cannot be used on " + string(dist))
	}
	return nil
}
