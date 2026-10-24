//go:build windows && with_external_usbip_drivers

package usbipvhci

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
	driverPackage, supported := driverassets.VHCI[runtime.GOARCH]
	if !supported {
		return nil, nil
	}
	executablePath, err := os.Executable()
	if err != nil {
		return nil, E.Cause(err, "usbipvhci: locate executable")
	}
	directory := filepath.Dir(executablePath)
	files := make([]assetFile, 0, len(driverPackage.Files))
	for _, file := range driverPackage.Files {
		assetPath := filepath.Join(directory, file.Name)
		content, readErr := os.ReadFile(assetPath)
		if readErr != nil {
			return nil, E.Cause(readErr, "usbipvhci: read ", assetPath)
		}
		digest := sha256.Sum256(content)
		if hex.EncodeToString(digest[:]) != file.SHA256 {
			return nil, E.New("usbipvhci: ", assetPath, " does not match the usbip-win2 ", driverPackage.Version, " digest")
		}
		files = append(files, assetFile{file.Name, content})
	}
	return files, nil
}
