//go:build windows && !amd64 && !arm64 && !with_external_usbip_drivers

package vboxusb

func assetFiles() ([]assetFile, error) { return nil, nil }
