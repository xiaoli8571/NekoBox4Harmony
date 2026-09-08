//go:build openharmony

package dialer

import (
	"os"

	"github.com/sagernet/sing/common/control"
)

// OpenHarmony 防回环(内核级,主保险):
// VPN 扩展进程内 cgo 线程创建的 socket 会被 HarmonyOS 的 VPN 策略路由捞回 TUN
// (blockedApplications/protectProcessNet 都拦不住内核线程的包)。
// 唯一可靠出口:每个出站 socket 强制 SO_BINDTODEVICE 绑定物理网卡,
// 绑定后的包直接从物理口发出,策略路由不再适用。
// 物理网卡名由扩展侧写入环境变量 SING_BOX_BIND_IFNAME(如 wlan0)。
func ohosForceBindFunc(alreadyBound bool, interfaceFinder control.InterfaceFinder) control.Func {
	ifname := os.Getenv("SING_BOX_BIND_IFNAME")
	if ifname == "" || alreadyBound {
		return nil
	}
	return control.BindToInterface(interfaceFinder, ifname, -1)
}
