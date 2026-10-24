//go:build linux || (darwin && cgo) || windows

package usbip

import (
	"context"
	"fmt"
	"net"
	"strings"
	"time"
)

type clientTarget struct {
	fixedBusID string
	match      DeviceMatch
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

func closeConnOnContextDone(ctx context.Context, conn net.Conn) func() {
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-done:
		}
	}()
	return func() {
		close(done)
	}
}

func describeMatch(m DeviceMatch) string {
	var parts []string
	if m.BusID != "" {
		parts = append(parts, "busid="+m.BusID)
	}
	if m.VendorID != 0 {
		parts = append(parts, fmt.Sprintf("vendor_id=0x%04x", uint16(m.VendorID)))
	}
	if m.ProductID != 0 {
		parts = append(parts, fmt.Sprintf("product_id=0x%04x", uint16(m.ProductID)))
	}
	if m.Serial != "" {
		parts = append(parts, "serial="+m.Serial)
	}
	return "{" + strings.Join(parts, ",") + "}"
}
