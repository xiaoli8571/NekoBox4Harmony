// NekoBox4Harmony — sing-box 1.4 进程内包装层。
//
// 编译为 HarmonyOS c-shared 库(libsingbox.so),由 NAPI 侧 dlopen 调用:
//   CGoSetTunFd(fd)              — 注入 @ohos.net.vpnExtension 创建的 TUN fd
//   CGoStartSingBox(configPath)  — 读取并应用配置,启动内核;成功返回 "",失败返回错误文本
//   CGoStopSingBox()             — 停止内核
//   CGoSingBoxVersion()          — 版本字符串
//
// TUN fd 通过环境变量 SING_BOX_TUN_FD 交给 sing-tun(见 core/patches/001-tun-fd-env.patch,
// sing-tun 对非零 FileDescriptor 直接使用该 fd 并跳过 netlink 配置)。
// 日志走配置里的 log.output 文件,由 ArkTS 侧轮询读取。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"os"
	"strconv"
	"sync"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/option"
	E "github.com/sagernet/sing/common/exceptions"
)

var (
	mu       sync.Mutex
	tunFd    int
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

//export CGoStartSingBox
func CGoStartSingBox(configPath *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return C.CString("sing-box already running")
	}
	content, err := os.ReadFile(C.GoString(configPath))
	if err != nil {
		return cErr(E.Cause(err, "read config"))
	}
	var options option.Options
	if err = options.UnmarshalJSON(content); err != nil {
		return cErr(E.Cause(err, "parse config"))
	}
	if tunFd > 0 {
		os.Setenv("SING_BOX_TUN_FD", strconv.Itoa(tunFd))
	} else {
		os.Unsetenv("SING_BOX_TUN_FD")
	}
	ctx, cancelFunc := context.WithCancel(context.Background())
	newInstance, err := box.New(box.Options{Context: ctx, Options: options})
	if err != nil {
		cancelFunc()
		return cErr(E.Cause(err, "create service"))
	}
	if err = newInstance.Start(); err != nil {
		newInstance.Close()
		cancelFunc()
		return cErr(E.Cause(err, "start service"))
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
	return C.CString("1.5.5-ohos-inproc")
}

func main() {}
