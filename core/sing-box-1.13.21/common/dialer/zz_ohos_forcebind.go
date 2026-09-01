//go:build openharmony

package dialer

import (
	"os"
	"strconv"
	"syscall"

	"github.com/sagernet/sing/common/control"
	"golang.org/x/sys/unix"
)

// OpenHarmony 防回环(内核级,主保险):
// VPN 扩展进程内 cgo 线程创建的 socket 会被 HarmonyOS 的 VPN 策略路由捞回 TUN
// (blockedApplications/protectProcessNet 都拦不住内核线程的包)。
// 唯一可靠出口:每个出站 socket 绑定物理网卡,绑定后的包直接从物理口发出。
//
// 绑定实现只用 SO_BINDTOIFINDEX(普通权限可用);
// 绝不使用 SO_BINDTODEVICE(需要 CAP_NET_RAW,应用沙箱返回 EPERM)。
// index 由扩展侧启动时解析一次(SING_BOX_BIND_IFINDEX)。
func ohosForceBindFunc(alreadyBound bool, interfaceFinder control.InterfaceFinder) control.Func {
	if true { return nil } // EXPERIMENT-1.7.5: forcebind disabled to isolate EPERM source
	_ = interfaceFinder
	if alreadyBound {
		return nil
	}
	if idxStr := os.Getenv("SING_BOX_BIND_IFINDEX"); idxStr != "" {
		if idx, err := strconv.Atoi(idxStr); err == nil && idx > 0 {
			return func(network, address string, conn syscall.RawConn) error {
				return control.Raw(conn, func(fd uintptr) error {
					return unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_BINDTOIFINDEX, idx)
				})
			}
		}
	}
	return nil
}
