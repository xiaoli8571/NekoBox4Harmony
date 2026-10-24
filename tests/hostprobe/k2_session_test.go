package parityprobe

// K2 会话化测速导出(CGoTest*V3)的主机侧验证 —— W09。
//
// 方案依据:docs/p0-baseline/kernel-capabilities.md §3.2(最小 K2:会话取消、
// 迟到回调、旧实例隔离)。核心不变式:**旧任务不会停止或污染新任务**。
//
// 测试策略:
//   1. 注册表状态机(nekobox/sessionstate)是零依赖纯包,这里直接 import 生产
//      代码,用可注入的 fakeCloser 驱动全部路径 —— 不启动真实 box、不联网。
//   2. V3 导出本身是 c-shared 包里的 cgo 函数,主机纯 Go 测试无法直接调用;
//      因此对 main.go / build 脚本 / NAPI / CoreManager 做源码级契约守卫
//      (与 k1_validate_test.go 同款手法),防止签名漂移或白名单漏列。

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"nekobox/sessionstate"
)

// fakeCloser 是可注入的假会话句柄:注册表只需要 Close()。
type fakeCloser struct {
	mu      sync.Mutex
	closed  bool
	closeCh chan struct{}
	err     error
}

func newFakeCloser() *fakeCloser {
	return &fakeCloser{closeCh: make(chan struct{})}
}

func (f *fakeCloser) Close() error {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
	select {
	case <-f.closeCh:
	default:
		close(f.closeCh)
	}
	return f.err
}

func (f *fakeCloser) isClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

// waitState 轮询 Info(id).State 直至达到目标(处理跨 goroutine 的时序)。
func waitState(t *testing.T, reg *sessionstate.Registry, id, want string) sessionstate.Info {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if info, ok := reg.Info(id); ok && info.State == want {
			return info
		}
		time.Sleep(5 * time.Millisecond)
	}
	info, ok := reg.Info(id)
	if ok {
		t.Fatalf("session %s 一直未进入 %s 状态(当前 %s)", id, want, info.State)
	}
	t.Fatalf("session %s 消失,未能进入 %s 状态", id, want)
	return sessionstate.Info{}
}

// ---- 注册表:未知会话 / 幂等 stop ----

func TestK2UnknownSessionSemantics(t *testing.T) {
	reg := sessionstate.New()

	// 未知 session 的 proxy → not found
	_, _, err := reg.BeginProbe("ghost", "tag-a")
	if err == nil || !strings.Contains(err.Error(), "session ghost not found") {
		t.Fatalf("未知会话的 probe 应返回 not found,得到: %v", err)
	}
	// 未知 session 的 info → ""(ok=false)
	if _, ok := reg.Info("ghost"); ok {
		t.Fatal("未知会话的 Info 不应命中")
	}
	// 未知 session 的 stop → 幂等成功 + 墓碑
	if err := reg.Stop("ghost"); err != nil {
		t.Fatalf("未知会话的 stop 应返回成功(幂等),得到: %v", err)
	}
	info, ok := reg.Info("ghost")
	if !ok || info.State != sessionstate.StateClosed || !info.Tombstone {
		t.Fatalf("stop 未知会话后应记墓碑,得到 ok=%v %+v", ok, info)
	}
	if got := reg.ActiveSessions(); got != "" {
		t.Fatalf("活动会话应为空,得到 %q", got)
	}
}

func TestK2StopIsIdempotent(t *testing.T) {
	reg := sessionstate.New()
	// 未知 id:重复 stop 全部幂等成功(每次都会补记墓碑)
	for i := 0; i < 3; i++ {
		if err := reg.Stop("idempotent"); err != nil {
			t.Fatalf("重复 stop #%d 应为幂等成功,得到: %v", i+1, err)
		}
	}
	// 真实会话:正常 stop 后再 stop 也必须幂等成功
	fake := newFakeCloser()
	if _, err := reg.Start("idem-real", func() (sessionstate.Closer, error) { return fake, nil }); err != nil {
		t.Fatalf("真实会话启动失败: %v", err)
	}
	if err := reg.Stop("idem-real"); err != nil {
		t.Fatalf("第一次 stop: %v", err)
	}
	if err := reg.Stop("idem-real"); err != nil {
		t.Fatalf("第二次 stop 应幂等成功,得到: %v", err)
	}
	if !fake.isClosed() {
		t.Fatal("会话实例应已关闭")
	}
}

// ---- 注册表:完整生命周期 ----

func TestK2SessionLifecycle(t *testing.T) {
	reg := sessionstate.New()
	fake := newFakeCloser()
	creates := 0
	if _, err := reg.Start("run1", func() (sessionstate.Closer, error) {
		creates++
		return fake, nil
	}); err != nil {
		t.Fatalf("启动失败: %v", err)
	}
	if creates != 1 {
		t.Fatalf("create 应只被调用一次,实际 %d 次", creates)
	}
	if got := reg.ActiveSessions(); got != "run1" {
		t.Fatalf("ActiveSessions 应为 run1,得到 %q", got)
	}
	handle, probeCtx, err := reg.BeginProbe("run1", "node-a")
	if err != nil {
		t.Fatalf("probe 应该可以开始: %v", err)
	}
	if handle != sessionstate.Closer(fake) || probeCtx == nil {
		t.Fatal("BeginProbe 应回传会话句柄与 context")
	}
	info, ok := reg.Info("run1")
	if !ok || info.State != sessionstate.StateActive || info.Probes != 1 || info.LastTag != "node-a" || info.Tombstone {
		t.Fatalf("active 会话快照不符: ok=%v %+v", ok, info)
	}

	// stop 返回时实例必须已关闭("stop 完成并确认"语义)
	if err := reg.Stop("run1"); err != nil {
		t.Fatalf("stop 失败: %v", err)
	}
	if !fake.isClosed() {
		t.Fatal("stop 返回前实例必须已关闭")
	}
	info, ok = reg.Info("run1")
	if !ok || info.State != sessionstate.StateClosed || !info.Tombstone {
		t.Fatalf("stop 后应为 closed+墓碑: ok=%v %+v", ok, info)
	}
	if _, _, err := reg.BeginProbe("run1", "tag-b"); err == nil ||
		!strings.Contains(err.Error(), "session run1 not found") {
		t.Fatalf("关闭后的 probe 应 not found,得到: %v", err)
	}
}

// ---- 注册表:串行语义 ----

func TestK2DuplicateAndSerialStartRejected(t *testing.T) {
	reg := sessionstate.New()
	fake := newFakeCloser()
	if _, err := reg.Start("a", func() (sessionstate.Closer, error) { return fake, nil }); err != nil {
		t.Fatal(err)
	}
	calls := 0
	_, err := reg.Start("a", func() (sessionstate.Closer, error) {
		calls++
		return newFakeCloser(), nil
	})
	if err == nil || !strings.Contains(err.Error(), "session a already active") {
		t.Fatalf("同 id 重复 start 应报 already active,得到: %v", err)
	}
	if calls != 0 {
		t.Fatalf("拒绝路径不得调用 create,实际 %d 次", calls)
	}
	_, err = reg.Start("b", func() (sessionstate.Closer, error) { return newFakeCloser(), nil })
	if err == nil || !strings.Contains(err.Error(), "another test session a is active") {
		t.Fatalf("其他会话在跑应报 another test session <id> is active,得到: %v", err)
	}
	if got := reg.ActiveSessions(); got != "a" {
		t.Fatalf("活动会话应仍为 a,得到 %q", got)
	}
}

func TestK2StartRejectedWhileAnotherStopping(t *testing.T) {
	reg := sessionstate.New()
	block := make(chan struct{})
	first := &fakeCloser{closeCh: make(chan struct{})}
	firstClose := make(chan struct{})
	// Close 阻塞,模拟内核关闭耗时
	blockedCloser := &blockingCloser{inner: first, gate: block, done: firstClose}
	if _, err := reg.Start("slow", func() (sessionstate.Closer, error) { return blockedCloser, nil }); err != nil {
		t.Fatal(err)
	}
	stopDone := make(chan error, 1)
	go func() { stopDone <- reg.Stop("slow") }()
	waitState(t, reg, "slow", sessionstate.StateStopping)

	for _, id := range []string{"slow", "next"} {
		calls := 0
		_, err := reg.Start(id, func() (sessionstate.Closer, error) {
			calls++
			return newFakeCloser(), nil
		})
		want := "session slow is stopping"
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("stopping 期间 start(%s) 应报 %q,得到: %v", id, want, err)
		}
		if calls != 0 {
			t.Fatalf("stopping 期间的 start 不得调用 create,实际 %d 次", calls)
		}
	}
	close(block) // 放行 Close
	if err := <-stopDone; err != nil {
		t.Fatalf("stop 应成功: %v", err)
	}
	if !first.isClosed() {
		t.Fatal("被阻塞的 closer 应已真正关闭")
	}
}

// blockingCloser 在 Close() 里等待 gate,用来把 Stop 卡在 "stopping" 状态。
type blockingCloser struct {
	inner *fakeCloser
	gate  chan struct{}
	done  chan struct{}
}

func (b *blockingCloser) Close() error {
	<-b.gate
	err := b.inner.Close()
	close(b.done)
	return err
}

// ---- 注册表:墓碑与迟到 start(§6.5 核心不变式) ----

func TestK2TombstonedIDBlocksLateStart(t *testing.T) {
	reg := sessionstate.New()
	// stop 一个从未存在的会话 → 墓碑
	if err := reg.Stop("late"); err != nil {
		t.Fatal(err)
	}
	calls := 0
	_, err := reg.Start("late", func() (sessionstate.Closer, error) {
		calls++
		return newFakeCloser(), nil
	})
	if err == nil || !strings.Contains(err.Error(), "session late cancelled during start") {
		t.Fatalf("墓碑 id 的迟到 start 应被拒,得到: %v", err)
	}
	if calls != 0 {
		t.Fatalf("墓碑路径不得创建实例,实际 %d 次", calls)
	}
	// 正常 stop 后同 id 也一样
	fake := newFakeCloser()
	if _, err = reg.Start("late2", func() (sessionstate.Closer, error) { return fake, nil }); err != nil {
		t.Fatal(err)
	}
	if err = reg.Stop("late2"); err != nil {
		t.Fatal(err)
	}
	calls = 0
	_, err = reg.Start("late2", func() (sessionstate.Closer, error) {
		calls++
		return newFakeCloser(), nil
	})
	if err == nil || !strings.Contains(err.Error(), "cancelled during start") {
		t.Fatalf("stop 过的 id 不得复活,得到: %v", err)
	}
	if calls != 0 {
		t.Fatalf("墓碑路径不得创建实例,实际 %d 次", calls)
	}
}

// TestK2StopDuringStartClosesLateInstance 是"迟到 start 被立即关闭"的直接证据:
// stop 在 create() 运行期间到达 → 新实例创建成功后立即关闭、id 入墓碑、
// start 返回 cancelled 文本、stop 在实例真正关闭之后才返回 ""。
func TestK2StopDuringStartClosesLateInstance(t *testing.T) {
	reg := sessionstate.New()
	fake := newFakeCloser()
	entered := make(chan struct{})
	release := make(chan struct{})
	startErr := make(chan error, 1)

	go func() {
		_, err := reg.Start("late-run", func() (sessionstate.Closer, error) {
			close(entered)
			<-release // 模拟 box.New/Start 耗时
			return fake, nil
		})
		startErr <- err
	}()
	<-entered

	stopDone := make(chan error, 1)
	go func() { stopDone <- reg.Stop("late-run") }()
	waitState(t, reg, "late-run", sessionstate.StateStopping)

	close(release) // 创建完成
	if err := <-startErr; err == nil ||
		!strings.Contains(err.Error(), "session late-run cancelled during start") {
		t.Fatalf("迟到 start 应返回 cancelled 文本,得到: %v", err)
	}
	if err := <-stopDone; err != nil {
		t.Fatalf("stop 应成功且发生在关闭之后: %v", err)
	}
	if !fake.isClosed() {
		t.Fatal("迟到创建成功的实例必须立即关闭,不得留在注册表")
	}
	if got := reg.ActiveSessions(); got != "" {
		t.Fatalf("取消的会话不得留在注册表,ActiveSessions=%q", got)
	}
	info, ok := reg.Info("late-run")
	if !ok || info.State != sessionstate.StateClosed || !info.Tombstone {
		t.Fatalf("取消后的 id 应为 closed+墓碑: ok=%v %+v", ok, info)
	}
	// 同 id 再 start 仍被拒(墓碑)
	calls := 0
	if _, err := reg.Start("late-run", func() (sessionstate.Closer, error) {
		calls++
		return newFakeCloser(), nil
	}); err == nil || !strings.Contains(err.Error(), "cancelled during start") || calls != 0 {
		t.Fatalf("墓碑 id 不得复活: err=%v calls=%d", err, calls)
	}
}

// ---- 注册表:stop 必须取消进行中的探测 ----

func TestK2StopCancelsInFlightProbe(t *testing.T) {
	reg := sessionstate.New()
	if _, err := reg.Start("p", func() (sessionstate.Closer, error) { return newFakeCloser(), nil }); err != nil {
		t.Fatal(err)
	}
	_, probeCtx, err := reg.BeginProbe("p", "node")
	if err != nil {
		t.Fatal(err)
	}
	probeCtx, cancel := context.WithCancel(probeCtx)
	defer cancel()
	if err := reg.Stop("p"); err != nil {
		t.Fatal(err)
	}
	select {
	case <-probeCtx.Done():
		// 探测 context 必须在 stop 时被取消
	case <-time.After(2 * time.Second):
		t.Fatal("stop 未取消进行中探测的 context")
	}
}

// ---- 注册表:sessionId 校验 ----

func TestK2SessionIDValidation(t *testing.T) {
	reg := sessionstate.New()
	bad := []string{
		"",
		"   ",
		strings.Repeat("x", sessionstate.MaxSessionIDLen+1),
		"a\x00b",
		"line\nbreak",
	}
	for _, id := range bad {
		if _, _, err := reg.BeginProbe(id, "t"); err == nil {
			t.Fatalf("非法 id %q 的 probe 应被拒", id)
		}
		if err := reg.Stop(id); err == nil {
			t.Fatalf("非法 id %q 的 stop 应被拒", id)
		}
		calls := 0
		if _, err := reg.Start(id, func() (sessionstate.Closer, error) {
			calls++
			return newFakeCloser(), nil
		}); err == nil || calls != 0 {
			t.Fatalf("非法 id %q 的 start 应被拒且不创建: err=%v calls=%d", id, err, calls)
		}
	}
	good := "run-20261024-1"
	if _, err := reg.Start(good, func() (sessionstate.Closer, error) { return newFakeCloser(), nil }); err != nil {
		t.Fatalf("合法 id 不应被拒: %v", err)
	}
}

// ---- 注册表:墓碑集合有界(长寿命 UI 进程防泄漏) ----

func TestK2TombstoneSetIsBounded(t *testing.T) {
	reg := sessionstate.New()
	total := sessionstate.MaxTombstones + 20
	for i := 0; i < total; i++ {
		if err := reg.Stop(fmt.Sprintf("tomb-%04d", i)); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok := reg.Info("tomb-0000"); ok {
		t.Fatal("最老的墓碑应被裁剪")
	}
	if _, ok := reg.Info(fmt.Sprintf("tomb-%04d", total-1)); !ok {
		t.Fatal("最新墓碑应保留")
	}
}

// ---- V3 导出与接线的源码级契约守卫 ----

func TestK2V3ExportsContract(t *testing.T) {
	mainGo, err := os.ReadFile(filepath.Join("..", "..", "core", "libsingbox14", "main.go"))
	if err != nil {
		t.Fatalf("读取 main.go 失败: %v", err)
	}
	text := string(mainGo)

	// V3 五导出必须带 //export 且签名与契约一致(export 指令与 func 之间允许
	// 有文档注释行,分开断言)。
	v3Sigs := []string{
		"func CGoTestStartSingBoxV3(sessionId *C.char, configPath *C.char, bindIfname *C.char) *C.char",
		"func CGoTestProxySingBoxV3(sessionId *C.char, tag *C.char, testURL *C.char, timeoutMs C.int, expectStatus *C.char) *C.char",
		"func CGoTestStopSingBoxV3(sessionId *C.char) *C.char",
		"func CGoTestSessionInfoV3(sessionId *C.char) *C.char",
		"func CGoTestActiveSessionsV3() *C.char",
	}
	for _, want := range v3Sigs {
		if !strings.Contains(text, want) {
			t.Errorf("main.go 缺少 V3 导出契约:\n%s", want)
		}
	}
	for _, name := range []string{
		"CGoTestStartSingBoxV3", "CGoTestProxySingBoxV3", "CGoTestStopSingBoxV3",
		"CGoTestSessionInfoV3", "CGoTestActiveSessionsV3",
	} {
		if !strings.Contains(text, "//export "+name+"\n") {
			t.Errorf("main.go 缺少 //export %s", name)
		}
	}

	// 旧导出一律不动(签名逐字比对,含 legacy/V2 与 K1)。
	oldSigs := []string{
		"func CGoSetTunFd(fd C.int)",
		"func CGoStartSingBox(configPath *C.char) *C.char",
		"func CGoStopSingBox() *C.char",
		"func CGoSingBoxVersion() *C.char",
		"func CGoTestStartSingBox(configPath *C.char) *C.char",
		"func CGoTestStartSingBoxV2(configPath *C.char, bindIfname *C.char) *C.char",
		"func CGoTestProxySingBox(tag *C.char, testURL *C.char, timeoutMs C.int) *C.char",
		"func CGoTestProxySingBoxV2(tag *C.char, testURL *C.char, timeoutMs C.int, expectStatus *C.char) *C.char",
		"func CGoTestStopSingBox() *C.char",
		"func CGoCheckConfigV1(configPath *C.char) *C.char",
		"func CGoValidateSRSFileV1(path *C.char) *C.char",
	}
	for _, want := range oldSigs {
		if !strings.Contains(text, want) {
			t.Errorf("旧导出签名被改动(必须原样保留): %s", want)
		}
	}

	// V3 不得复用旧单例机制(互不干扰)。
	for _, name := range []string{"CGoTestStartSingBoxV3", "CGoTestProxySingBoxV3", "CGoTestStopSingBoxV3"} {
		start := strings.Index(text, "func "+name+"(")
		if start < 0 {
			t.Fatalf("找不到 %s", name)
		}
		rest := text[start:]
		end := strings.Index(rest, "\n}\n")
		if end < 0 {
			t.Fatalf("%s 函数体未闭合", name)
		}
		body := stripGoComments(rest[:end])
		for _, forbidden := range []string{"testInstance", "testMu", "startTestBox(", "proxyTest(", "clearTestBind("} {
			if strings.Contains(body, forbidden) {
				t.Errorf("%s 不得触碰旧单例机制(%s)", name, forbidden)
			}
		}
	}

	// 反向隔离:旧的 CGoTestStopSingBox 只能停旧单例,绝不能碰 V3 会话注册表。
	oldStopStart := strings.Index(text, "func CGoTestStopSingBox() *C.char {")
	if oldStopStart < 0 {
		t.Fatal("找不到旧 CGoTestStopSingBox 实现")
	}
	oldStopBody := stripGoComments(text[oldStopStart:])
	if end := strings.Index(oldStopBody, "\n}\n"); end >= 0 {
		oldStopBody = oldStopBody[:end]
	}
	if strings.Contains(oldStopBody, "testSessions") {
		t.Error("旧 CGoTestStopSingBox 不得触碰 V3 会话注册表(只允许停旧单例)")
	}
	if !strings.Contains(oldStopBody, "testInstance") {
		t.Error("旧 CGoTestStopSingBox 应仍只操作旧单例 testInstance")
	}
}

func TestK2BuildAndBridgeWiring(t *testing.T) {
	repo := filepath.Join("..", "..")

	// 构建脚本 exports.map 必须白名单 V3 符号(否则 dlsym 静默失败)。
	script, err := os.ReadFile(filepath.Join(repo, "core", "scripts", "build-libsingbox-ohos.sh"))
	if err != nil {
		t.Fatalf("读取构建脚本失败: %v", err)
	}
	for _, sym := range []string{
		"CGoTestStartSingBoxV3;", "CGoTestProxySingBoxV3;", "CGoTestStopSingBoxV3;",
		"CGoTestSessionInfoV3;", "CGoTestActiveSessionsV3;",
	} {
		if !strings.Contains(string(script), sym) {
			t.Errorf("exports.map 白名单缺少 %s", sym)
		}
	}

	// NAPI 桥:5 个 native 方法 + dlsym + 注册。
	napi, err := os.ReadFile(filepath.Join(repo, "entry", "src", "main", "cpp", "napi_init.cpp"))
	if err != nil {
		t.Fatalf("读取 napi_init.cpp 失败: %v", err)
	}
	napiText := string(napi)
	for _, want := range []string{
		`dlsym(handle, "CGoTestStartSingBoxV3")`,
		`dlsym(handle, "CGoTestProxySingBoxV3")`,
		`dlsym(handle, "CGoTestStopSingBoxV3")`,
		`dlsym(handle, "CGoTestSessionInfoV3")`,
		`dlsym(handle, "CGoTestActiveSessionsV3")`,
		`"testStartNativeV3"`,
		`"testProxyNativeV3"`,
		`"testStopNativeV3"`,
		`"testSessionInfoNativeV3"`,
		`"testActiveSessionsNative"`,
		`"v3"`,
		`"unsupported"`,
	} {
		if !strings.Contains(napiText, want) {
			t.Errorf("napi_init.cpp 缺少 K2 接线: %s", want)
		}
	}

	// CoreManager:5 个 Promise 包装。
	core, err := os.ReadFile(filepath.Join(repo, "entry", "src", "main", "ets", "core", "CoreManager.ets"))
	if err != nil {
		t.Fatalf("读取 CoreManager.ets 失败: %v", err)
	}
	coreText := string(core)
	for _, want := range []string{
		"static testStartV3(", "static testProxyV3(", "static testStopV3(",
		"static testSessionInfoV3(", "static testActiveSessions(",
	} {
		if !strings.Contains(coreText, want) {
			t.Errorf("CoreManager.ets 缺少 K2 包装: %s", want)
		}
	}
}

// stripGoComments 去掉以 // 开头的行,避免注释里的词触发守卫误报。
func stripGoComments(s string) string {
	var b strings.Builder
	for _, line := range strings.Split(s, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "//") {
			continue
		}
		b.WriteString(line)
		b.WriteString("\n")
	}
	return b.String()
}
