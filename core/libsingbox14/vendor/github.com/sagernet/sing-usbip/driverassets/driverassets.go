// Package driverassets is also consumed by the sing-box daemon build, which
// stages the asset files next to the daemon executable and builds with the
// with_external_usbip_drivers tag.
package driverassets

//go:generate go run ./generate

const (
	VBoxUSBVersion   = "7.2.14.24565"
	VHCIAMD64Version = "0.9.7.7"
	VHCIARM64Version = "0.9.7.5"
)

type File struct {
	Name   string
	SHA256 string
}

type Package struct {
	Version string
	Files   []File
}
