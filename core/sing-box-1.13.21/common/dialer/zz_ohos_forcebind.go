//go:build openharmony

package dialer

import (
	"os"
	"github.com/sagernet/sing/common/control"
)

func ohosForceBindFunc(alreadyBound bool, interfaceFinder control.InterfaceFinder) control.Func {
	ifname := os.Getenv("SING_BOX_BIND_IFNAME")
	if ifname == "" || alreadyBound { return nil }
	return control.BindToInterface(interfaceFinder, ifname, -1)
}
