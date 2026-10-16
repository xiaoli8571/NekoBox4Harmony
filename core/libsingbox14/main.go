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
	testMu        sync.RWMutex
	testInstance  *box.Box
	testCancel    context.CancelFunc
	testBindIface string
)

func cErr(err error) *C.char {
	if err == nil {
		return C.CString("")
	}
	return C.CString(err.Error())
}

// clearTestBind 撤销测速会话的网卡绑定。
// 调用方必须已持有 testMu 写锁(本函数不再自行加锁,避免 RWMutex 不可重入导致死锁)。
// 测速实例与 VPN 主实例分处两个进程(UI / VPN 扩展),因此这里的进程级
// 环境变量不会影响正在运行的隧道。
func clearTestBind() {
	os.Unsetenv("SING_BOX_BIND_IFNAME")
	testBindIface = ""
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
	ctx := leanContext(context.Background())
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

// startTestBox 启动测速实例的公共实现。bindIfname 非空时把测速出站 socket
// 绑到该物理网卡(SO_BINDTODEVICE),使测速流量绕开正在运行的隧道,直接测到
// 节点本身;空串则沿用旧行为(测速流量会被 TUN 捕获,叠加当前节点的隧道开销)。
func startTestBox(configPath string, bindIfname string) *C.char {
	testMu.Lock()
	defer testMu.Unlock()
	if testInstance != nil {
		return C.CString("") // 已有测试会话,直接复用
	}
	content, err := os.ReadFile(configPath)
	if err != nil {
		return cErr(E.Cause(err, "read test config"))
	}
	ctx := leanContext(context.Background())
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return cErr(E.Cause(err, "parse test config"))
	}
	// 测试实例不带任何入站(clash/cache 也要求配置侧省略,避免与运行中实例抢资源)。
	// Endpoints 必须保留:WireGuard 节点与含 WireGuard 跳点的链依赖 endpoint tag,
	// 清空会导致这些配置的测速引用找不到目标;WireGuard endpoint 使用随机本地
	// 端口,与运行中的主实例不冲突。
	options.Inbounds = nil
	options.Experimental = nil
	os.Unsetenv("SING_BOX_TUN_FD")
	if bindIfname != "" {
		os.Setenv("SING_BOX_BIND_IFNAME", bindIfname)
		testBindIface = bindIfname
	} else {
		os.Unsetenv("SING_BOX_BIND_IFNAME")
		testBindIface = ""
	}
	runCtx, cancelFunc := context.WithCancel(ctx)
	newInstance, err := box.New(box.Options{Context: runCtx, Options: options})
	if err != nil {
		cancelFunc()
		clearTestBind()
		return cErr(E.Cause(err, "create test service"))
	}
	if err = newInstance.Start(); err != nil {
		newInstance.Close()
		cancelFunc()
		clearTestBind()
		return cErr(E.Cause(err, "start test service"))
	}
	testInstance = newInstance
	testCancel = cancelFunc
	return C.CString("")
}

//export CGoTestStartSingBox
// 旧签名(单参),保留给尚未重编 .so 的 NAPI 侧回退路径。
func CGoTestStartSingBox(configPath *C.char) *C.char {
	return startTestBox(C.GoString(configPath), "")
}

//export CGoTestStartSingBoxV2
// 新签名:比旧的多一个 bindIfname。NAPI 侧优先 dlsym 这个 V2 符号,
// 找不到才回退到旧的单参版本 —— 这样改了导出签名不会把老 .so 打成崩。
func CGoTestStartSingBoxV2(configPath *C.char, bindIfname *C.char) *C.char {
	return startTestBox(C.GoString(configPath), C.GoString(bindIfname))
}

// proxyTest 对指定出站做一次真连接探测的公共实现。
func proxyTest(tagStr string, link string, timeoutMs C.int, expect2xx bool) *C.char {
	testMu.RLock()
	inst := testInstance
	testMu.RUnlock()
	if inst == nil {
		return C.CString("err:test session not started")
	}
	outbound, loaded := inst.Outbound().Outbound(tagStr)
	if !loaded {
		return C.CString("err:outbound not found: " + tagStr)
	}
	ctx := leanContext(context.Background())
	timeout := time.Duration(int(timeoutMs)) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	ctx, cancelCtx := context.WithTimeout(ctx, timeout)
	defer cancelCtx()
	probeOpts := urltest.DefaultURLTestOptions()
	probeOpts.Expect2xx = expect2xx
	ms, err := urltest.URLTestWithOptions(ctx, link, outbound, probeOpts)
	if err != nil {
		return C.CString("err:" + err.Error())
	}
	return C.CString(strconv.Itoa(int(ms)))
}

//export CGoTestProxySingBox
// 旧签名(三参),保留给尚未重编 .so 的 NAPI 侧回退路径。
// 注意这条路径下 urltest.URLTest 走的是上游实现:不校验状态码、只发 HEAD。
func CGoTestProxySingBox(tag *C.char, testURL *C.char, timeoutMs C.int) *C.char {
	return proxyTest(C.GoString(tag), C.GoString(testURL), timeoutMs, false)
}

//export CGoTestProxySingBoxV2
// expectStatus: "any" 时不校验状态码,否则仅 2xx 判定通过(防"假绿")。
func CGoTestProxySingBoxV2(tag *C.char, testURL *C.char, timeoutMs C.int, expectStatus *C.char) *C.char {
	return proxyTest(C.GoString(tag), C.GoString(testURL), timeoutMs, C.GoString(expectStatus) != "any")
}

//export CGoTestStopSingBox
func CGoTestStopSingBox() *C.char {
	testMu.Lock()
	defer testMu.Unlock()
	// 无论如何都要撤销网卡绑定,否则下一次不带绑定的测速会继承上一次的设置
	clearTestBind()
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
