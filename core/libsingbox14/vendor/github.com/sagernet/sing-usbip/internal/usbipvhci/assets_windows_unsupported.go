//go:build windows && !amd64 && !arm64 && !with_external_usbip_drivers

package usbipvhci

func assetFiles() ([]assetFile, error) { return nil, nil }
