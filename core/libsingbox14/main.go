// NekoBox4Harmony — sing-box 内核进程内包装层(1.14 API)。
//
// 编译为 HarmonyOS c-shared 库(libsingbox.so),由 NAPI 层 dlopen 调用:
//   CGoSetTunFd(fd)              — 注入 @ohos.net.vpnExtension 创建的 TUN fd
//   CGoStartSingBox(configPath)  — 读取并应用配置,启动内核;成功返回 "",失败返回错误文本
//   CGoStopSingBox()             — 停止内核
//   CGoSingBoxVersion()          — 版本字符串
//   CGoCheckConfigV1(configPath) — 只解析配置 schema,不启动(无副作用,K1)
//   CGoValidateSRSFileV1(path)   — 只解析本地 .srs 规则集(无副作用,K1)
//   CGoTestStartSingBoxV3(sessionId, configPath, bindIfname)          — K2 带会话测速
//   CGoTestProxySingBoxV3(sessionId, tag, url, timeoutMs, expectStatus)
//   CGoTestStopSingBoxV3(sessionId)   — 关闭会话,返回 "" 时实例必已关闭
//   CGoTestSessionInfoV3(sessionId)   — 会话快照 JSON
//   CGoTestActiveSessionsV3()         — 当前 active 的 sessionId
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
	stdjson "encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/common/srs"
	urltest "github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	E "github.com/sagernet/sing/common/exceptions"

	"nekobox/sessionstate"
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

// ---- K1:无副作用校验导出(docs/p0-baseline/kernel-capabilities.md §2.2) ----
//
// 这两个导出只做纯解析,与 CGoStartSingBox / startTestBox 完全隔离:
//   - 不调用 box.New / Start(规则集下载、日志文件、缓存文件都是 box.New 的副作用);
//   - 不读写 SING_BOX_TUN_FD / SING_BOX_BIND_IFNAME 等任何环境变量(否则会
//     污染 UI 进程内正在进行的测速会话);
//   - 不写任何文件。
// 成功返回 "",失败返回 err 文本(与 CGoStartSingBox 的 cErr 风格一致)。

//export CGoCheckConfigV1
// 配置 schema 校验:与 CGoStartSingBox 的解析步骤同款(leanContext +
// json.UnmarshalExtendedContext),把它抽成独立导出,批量检测前即可逐节点
// 拦下 schema 类型错误(如 server_port:"invalid")。不启动任何实例。
func CGoCheckConfigV1(configPath *C.char) *C.char {
	content, err := os.ReadFile(C.GoString(configPath))
	if err != nil {
		return cErr(E.Cause(err, "read config"))
	}
	ctx := leanContext(context.Background())
	_, err = json.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return cErr(E.Cause(err, "parse config"))
	}
	return cErr(nil)
}

//export CGoValidateSRSFileV1
// SRS 规则集内容校验:读本地文件 → srs.Read(recover=false) 纯解析,
// 校验魔数、版本与完整规则(比"只认 SR 魔数"强)。不写文件、不联网。
func CGoValidateSRSFileV1(path *C.char) *C.char {
	f, err := os.Open(C.GoString(path))
	if err != nil {
		return cErr(E.Cause(err, "open rule-set file"))
	}
	defer f.Close()
	if _, err = srs.Read(f, false); err != nil {
		return cErr(E.Cause(err, "parse rule-set file"))
	}
	return cErr(nil)
}

// ---- K2:带 sessionId 的测速会话(V3,docs/p0-baseline/kernel-capabilities.md §3.2) ----
//
// V3 与旧单例(V2/legacy)完全独立:
//   - V3 使用独立的会话注册表(nekobox/sessionstate),不碰 testInstance/testMu;
//   - 旧的 CGoTestStopSingBox 只停旧单例,不会停止任何 V3 会话;反之,
//     CGoTestStopSingBoxV3 也不停旧单例 —— 两套会话互不干扰;
//   - 迟到 start 防护:stop 在创建期间到达时,新实例创建成功后立即被关闭,
//     且该 sessionId 被记为墓碑,后续同 id 的 start 直接拒绝。
var testSessions = sessionstate.New()

// testBoxHandle 是 K2 会话持有的内核实例句柄(注册表只需要 Close)。
type testBoxHandle struct {
	box    *box.Box
	cancel context.CancelFunc
}

func (h *testBoxHandle) Close() error {
	if h.cancel != nil {
		h.cancel()
	}
	return h.box.Close()
}

// createTestBox 为 K2 会话创建测速实例(与旧 startTestBox 同形,但不动旧单例):
// inbounds/experimental 清空、无 TUN。bindIfname 非空时只在**创建窗口**内设置
// SING_BOX_BIND_IFNAME(forcebind 钩子在 box.New 构造 dialer 时读取环境变量),
// 创建结束立即恢复原值 —— 不把进程级环境变量留在会话生命周期里,避免与
// 旧单例 / VPN 主实例的绑定设置互相覆盖。
func createTestBox(configPath string, bindIfname string) (sessionstate.Closer, error) {
	content, err := os.ReadFile(configPath)
	if err != nil {
		return nil, E.Cause(err, "read test config")
	}
	ctx := leanContext(context.Background())
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, content)
	if err != nil {
		return nil, E.Cause(err, "parse test config")
	}
	// 与旧测速会话一致:不带任何入站;Endpoints 保留(WireGuard 链依赖)。
	options.Inbounds = nil
	options.Experimental = nil
	prevTun, hadTun := os.LookupEnv("SING_BOX_TUN_FD")
	prevBind, hadBind := os.LookupEnv("SING_BOX_BIND_IFNAME")
	defer func() {
		restoreEnv("SING_BOX_TUN_FD", prevTun, hadTun)
		restoreEnv("SING_BOX_BIND_IFNAME", prevBind, hadBind)
	}()
	os.Unsetenv("SING_BOX_TUN_FD")
	if bindIfname != "" {
		os.Setenv("SING_BOX_BIND_IFNAME", bindIfname)
	} else {
		os.Unsetenv("SING_BOX_BIND_IFNAME")
	}
	runCtx, cancelFunc := context.WithCancel(ctx)
	newInstance, err := box.New(box.Options{Context: runCtx, Options: options})
	if err != nil {
		cancelFunc()
		return nil, E.Cause(err, "create test service")
	}
	if err = newInstance.Start(); err != nil {
		newInstance.Close()
		cancelFunc()
		return nil, E.Cause(err, "start test service")
	}
	return &testBoxHandle{box: newInstance, cancel: cancelFunc}, nil
}

func restoreEnv(key string, value string, had bool) {
	if had {
		os.Setenv(key, value)
	} else {
		os.Unsetenv(key)
	}
}

//export CGoTestStartSingBoxV3
// 以 sessionId 建立测试会话。成功返回 "";同 sessionId 已 active/starting →
// "session <id> already active";其他会话在跑 → "another test session <id> is
// active"(串行语义);有会话正在关闭 → "session <id> is stopping";该 id 已被
// stop 过(墓碑)→ "session <id> cancelled during start";stop 在创建期间到达 →
// 新实例创建成功后立即关闭,返回同样的 cancelled 文本。
func CGoTestStartSingBoxV3(sessionId *C.char, configPath *C.char, bindIfname *C.char) *C.char {
	id := C.GoString(sessionId)
	cfgPath := C.GoString(configPath)
	bind := C.GoString(bindIfname)
	_, err := testSessions.Start(id, func() (sessionstate.Closer, error) {
		return createTestBox(cfgPath, bind)
	})
	return cErr(err)
}

//export CGoTestProxySingBoxV3
// 只在该会话内探测。会话不存在/已关闭/正在停止 → "session <id> not found";
// 正在启动 → "session <id> is starting"。返回延迟毫秒数字字符串或 "err:..."
// (与 V2 同构)。stop 会取消会话 context,进行中的探测尽快以错误返回。
func CGoTestProxySingBoxV3(sessionId *C.char, tag *C.char, testURL *C.char, timeoutMs C.int, expectStatus *C.char) *C.char {
	id := C.GoString(sessionId)
	tagStr := C.GoString(tag)
	link := C.GoString(testURL)
	expect2xx := C.GoString(expectStatus) != "any"
	handle, probeCtx, err := testSessions.BeginProbe(id, tagStr)
	if err != nil {
		return C.CString("err:" + err.Error())
	}
	inst, ok := handle.(*testBoxHandle)
	if !ok || inst == nil || inst.box == nil {
		return C.CString("err:invalid session handle")
	}
	outbound, loaded := inst.box.Outbound().Outbound(tagStr)
	if !loaded {
		return C.CString("err:outbound not found: " + tagStr)
	}
	timeout := time.Duration(int(timeoutMs)) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	probeCtx, cancelProbe := context.WithTimeout(probeCtx, timeout)
	defer cancelProbe()
	probeOpts := urltest.DefaultURLTestOptions()
	probeOpts.Expect2xx = expect2xx
	ms, err := urltest.URLTestWithOptions(probeCtx, link, outbound, probeOpts)
	if err != nil {
		return C.CString("err:" + err.Error())
	}
	return C.CString(strconv.Itoa(int(ms)))
}

//export CGoTestStopSingBoxV3
// 停止并关闭该会话;返回 "" 时实例必已关闭(确认语义)。未知/已停止的
// sessionId 返回 ""(幂等)并记为墓碑 —— 迟到的同 id start 会被拒绝。
// 进行中的探测会因会话 context 被取消而尽快返回错误。
func CGoTestStopSingBoxV3(sessionId *C.char) *C.char {
	return cErr(testSessions.Stop(C.GoString(sessionId)))
}

//export CGoTestSessionInfoV3
// 返回会话快照 JSON:
//   {"sessionId","state":"starting|active|stopping|closed","startedAt":0,
//    "probes":0,"lastTag":"","tombstone":true|false}
// 未知会话返回 ""(与错误区分:空串=未知)。已关闭(含墓碑)的 id 仍返回
// closed+tombstone 快照,便于诊断。
func CGoTestSessionInfoV3(sessionId *C.char) *C.char {
	info, ok := testSessions.Info(C.GoString(sessionId))
	if !ok {
		return C.CString("")
	}
	data, err := stdjson.Marshal(info)
	if err != nil {
		return C.CString("")
	}
	return C.CString(string(data))
}

//export CGoTestActiveSessionsV3
// 返回当前 active 的 sessionId(逗号分隔;串行语义下最多一个)。诊断/测试断言用。
func CGoTestActiveSessionsV3() *C.char {
	return C.CString(testSessions.ActiveSessions())
}

//export CGoSingBoxVersion
func CGoSingBoxVersion() *C.char {
	return C.CString("1.14.0-ohos-inproc")
}

func main() {}
