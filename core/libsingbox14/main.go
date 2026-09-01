// NekoBox4Harmony — sing-box 内核进程内包装层 (sing-box 1.11 API).
//
// 编译为 HarmonyOS c-shared 库(libsingbox.so),由 NAPI 侧 dlopen 调用:
//   CGoSetTunFd(fd)              — 注入 @ohos.net.vpnExtension 创建的 TUN fd
//   CGoStartSingBox(configPath)  — 读取并应用配置,启动内核;成功返回 "",失败返回错误文本
//   CGoStopSingBox()             — 停止内核
//   CGoSingBoxVersion()          — 版本字符串
//
// TUN fd 通过环境变量 SING_BOX_TUN_FD 交给 sing-tun(补丁:sing-tun 对非零
// FileDescriptor 直接使用该 fd,不触碰 /dev/net/tun 与 netlink)。
// 日志走配置里的 log.output 文件,由日志页轮询读取。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	E "github.com/sagernet/sing/common/exceptions"
)

var (
	mu       sync.Mutex
	tunFd    int
	bindIfname string
	instance *box.Box
	cancel   context.CancelFunc
	running  bool
)

func cErr(err error) *C.char {
	if err == nil {
		return C.CString("")
	}
	return C.CString(err.Error())
}

//export CGoSetTunFd
func CGoSetTunFd(fd C.int) {
	mu.Lock()
	defer mu.Unlock()
	tunFd = int(fd)
}

//export CGoSetBindIfname
func CGoSetBindIfname(ifname *C.char) {
	mu.Lock()
	defer mu.Unlock()
	bindIfname = C.GoString(ifname)
}

//export CGoStartSingBox
func CGoStartSingBox(configPath *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return C.CString("sing-box already running")
	}
	cfgPath := C.GoString(configPath)
	content, err := os.ReadFile(cfgPath)
	if err != nil {
		return cErr(E.Cause(err, "read config"))
	}
	// 1.11: registry context 由 box.Context + include 各 Registry 构造
	// (include.Context 是 1.12+ 才有的 API,1.11 内核编译不过)。
	ctx := box.Context(context.Background(),
		include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry())
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return cErr(E.Cause(err, "parse config"))
	}
	if tunFd > 0 {
		os.Setenv("SING_BOX_TUN_FD", strconv.Itoa(tunFd))
	} else {
		os.Unsetenv("SING_BOX_TUN_FD")
	}
	if bindIfname != "" {
		os.Setenv("SING_BOX_BIND_IFNAME", bindIfname)
		// 预解析接口 index(启动时一次完成,拨号热路径直接用 index 绑定)
		if iface, ifErr := net.InterfaceByName(bindIfname); ifErr == nil && iface != nil {
			os.Setenv("SING_BOX_BIND_IFINDEX", strconv.Itoa(iface.Index))
		} else {
			os.Unsetenv("SING_BOX_BIND_IFINDEX")
		}
	} else {
		os.Unsetenv("SING_BOX_BIND_IFNAME")
		os.Unsetenv("SING_BOX_BIND_IFINDEX")
	}
	runCtx, cancelFunc := context.WithCancel(ctx)
	newInstance, err := box.New(box.Options{Context: runCtx, Options: options})
	if err != nil {
		cancelFunc()
		return cErr(E.Cause(err, "create service"))
	}
	if err = newInstance.Start(); err != nil {
		newInstance.Close()
		cancelFunc()
		startErrMsg := E.Cause(err, "start service").Error()
		if logData, logErr := os.ReadFile(filepath.Join(filepath.Dir(cfgPath), "singbox.log")); logErr == nil && len(logData) > 0 {
			tail := string(logData)
			if len(tail) > 1500 {
				tail = tail[len(tail)-1500:]
			}
			startErrMsg += " || " + tail
		}
		return C.CString(startErrMsg)
	}
	instance = newInstance
	cancel = cancelFunc
	running = true
	return C.CString("")
}

//export CGoStopSingBox
func CGoStopSingBox() *C.char {
	mu.Lock()
	defer mu.Unlock()
	if !running || instance == nil {
		return C.CString("")
	}
	cancel()
	err := instance.Close()
	instance = nil
	cancel = nil
	running = false
	return cErr(err)
}

//export CGoSingBoxVersion
func CGoSingBoxVersion() *C.char {
	return C.CString("1.11.9-ohos-inproc")
}

func main() {}
