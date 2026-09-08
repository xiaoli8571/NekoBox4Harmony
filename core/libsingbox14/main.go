// NekoBox4Harmony — sing-box 内核进程内包装层(1.14 API)。
//
// 编译为 HarmonyOS c-shared 库(libsingbox.so),由 NAPI 层 dlopen 调用:
//   CGoSetTunFd(fd)              — 注入 @ohos.net.vpnExtension 创建的 TUN fd
//   CGoStartSingBox(configPath)  — 读取并应用配置,启动内核;成功返回 "",失败返回错误文本
//   CGoStopSingBox()             — 停止内核
//   CGoSingBoxVersion()          — 版本字符串
//
// TUN fd 通过环境变量 SING_BOX_TUN_FD 交给 sing-tun(补丁:sing-tun 对非零
// FileDescriptor 直接使用该 fd,不触碰 /dev/net/tun 或 netlink)。
// 日志落配置里的 log.output 文件,由日志页轮读读取。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	box "github.com/sagernet/sing-box"
	urltest "github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	E "github.com/sagernet/sing/common/exceptions"
)

var (
	mu       sync.Mutex
	tunFd    int
	instance *box.Box
	cancel   context.CancelFunc
	running  bool
)

// URL 测速会话(由 UI 进程使用,与主实例互不影响;读写锁支持并发测多个 tag)
var (
	testMu       sync.RWMutex
	testInstance *box.Box
	testCancel   context.CancelFunc
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
	cfgPath := C.GoString(configPath)
	content, err := os.ReadFile(cfgPath)
	if err != nil {
		return cErr(E.Cause(err, "read config"))
	}
	ctx := include.Context(context.Background())
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return cErr(E.Cause(err, "parse config"))
	}
	if tunFd > 0 {
		os.Setenv("SING_BOX_TUN_FD", strconv.Itoa(tunFd))
	} else {
		os.Unsetenv("SING_BOX_TUN_FD")
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

//export CGoTestStartSingBox
func CGoTestStartSingBox(configPath *C.char) *C.char {
	testMu.Lock()
	defer testMu.Unlock()
	if testInstance != nil {
		return C.CString("") // 已有测试会话,直接复用
	}
	content, err := os.ReadFile(C.GoString(configPath))
	if err != nil {
		return cErr(E.Cause(err, "read test config"))
	}
	ctx := include.Context(context.Background())
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return cErr(E.Cause(err, "parse test config"))
	}
	// 测试实例不带任何入站(clash/cache 也要求配置侧省略,避免与运行中实例抢资源)
	options.Inbounds = nil
	options.Endpoints = nil
	options.Experimental = nil
	os.Unsetenv("SING_BOX_TUN_FD")
	runCtx, cancelFunc := context.WithCancel(ctx)
	newInstance, err := box.New(box.Options{Context: runCtx, Options: options})
	if err != nil {
		cancelFunc()
		return cErr(E.Cause(err, "create test service"))
	}
	if err = newInstance.Start(); err != nil {
		newInstance.Close()
		cancelFunc()
		return cErr(E.Cause(err, "start test service"))
	}
	testInstance = newInstance
	testCancel = cancelFunc
	return C.CString("")
}

//export CGoTestProxySingBox
func CGoTestProxySingBox(tag *C.char, testURL *C.char, timeoutMs C.int) *C.char {
	testMu.RLock()
	inst := testInstance
	testMu.RUnlock()
	if inst == nil {
		return C.CString("err:test session not started")
	}
	tagStr := C.GoString(tag)
	outbound, loaded := inst.Outbound().Outbound(tagStr)
	if !loaded {
		return C.CString("err:outbound not found: " + tagStr)
	}
	ctx := include.Context(context.Background())
	timeout := time.Duration(int(timeoutMs)) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	ctx, cancelCtx := context.WithTimeout(ctx, timeout)
	defer cancelCtx()
	ms, err := urltest.URLTest(ctx, C.GoString(testURL), outbound)
	if err != nil {
		return C.CString("err:" + err.Error())
	}
	return C.CString(strconv.Itoa(int(ms)))
}

//export CGoTestStopSingBox
func CGoTestStopSingBox() *C.char {
	testMu.Lock()
	defer testMu.Unlock()
	if testInstance == nil {
		return C.CString("")
	}
	if testCancel != nil {
		testCancel()
	}
	err := testInstance.Close()
	testInstance = nil
	testCancel = nil
	return cErr(err)
}

//export CGoSingBoxVersion
func CGoSingBoxVersion() *C.char {
	return C.CString("1.14.0-ohos-inproc")
}

func main() {}
