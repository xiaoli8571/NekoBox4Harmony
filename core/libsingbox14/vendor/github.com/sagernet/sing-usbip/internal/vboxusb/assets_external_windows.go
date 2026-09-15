//go:build windows && with_external_usbip_drivers

package vboxusb

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"runtime"

	"github.com/sagernet/sing-usbip/driverassets"
	E "github.com/sagernet/sing/common/exceptions"
)

func assetFiles() ([]assetFile, error) {
	driverPackage, supported := driverassets.VBoxUSB[runtime.GOARCH]
	if !supported {
		return nil, nil
	}
	executablePath, err := os.Executable()
	if err != nil {
		return nil, E.Cause(err, "vboxusb: locate executable")
	}
	directory := filepath.Dir(executablePath)
	files := make([]assetFile, 0, len(driverPackage.Files))
	for _, file := range driverPackage.Files {
		assetPath := filepath.Join(directory, file.Name)
		content, readErr := os.ReadFile(assetPath)
		if readErr != nil {
			return nil, E.Cause(readErr, "vboxusb: read ", assetPath)
		}
		digest := sha256.Sum256(content)
		if hex.EncodeToString(digest[:]) != file.SHA256 {
			return nil, E.New("vboxusb: ", assetPath, " does not match the VBoxUSB ", driverPackage.Version, " digest")
		}
		files = append(files, assetFile{file.Name, content})
	}
	return files, nil
}
