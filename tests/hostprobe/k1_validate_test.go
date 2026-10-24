package parityprobe

// K1 无副作用校验导出(libsingbox14 的 CGoCheckConfigV1 / CGoValidateSRSFileV1)
// 的主机侧语义验证 —— W05。
//
// 设计依据:docs/p0-baseline/kernel-capabilities.md §2.2。两个导出都只做**纯解析**:
//   CGoCheckConfigV1     = os.ReadFile + leanContext + json.UnmarshalExtendedContext
//   CGoValidateSRSFileV1 = os.Open + srs.Read(f, recover=false)
// 本文件逐条验证这两个调用的行为边界 —— 尤其"坏配置/坏 SRS 必须报错、好文件必须通过"。
//
// 重要:本文件**不启动 box**(不 box.New / 不 Start / 无 TUN / 不开监听 / 不联网)。
// 只调 schema 解析器与 .srs 解析器,因此可安全地在 CI/本机直接跑。

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/common/srs"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
)

// parseKernelConfig 与 CGoCheckConfigV1 的内核侧调用完全一致(leanProbeContext
// 镜像 leanContext)。只解析,不建实例。
func parseKernelConfig(t *testing.T, configJSON string) error {
	t.Helper()
	ctx := leanProbeContext(context.Background())
	_, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	return err
}

// 功能审计里的真实坏节点形状:server_port 写成字符串 "invalid"。
// 这一层就拦住,批量检测前即可把坏节点单独报错(REQ-10 静态字段检查的上游)。
func TestK1CheckConfigRejectsInvalidServerPort(t *testing.T) {
	cfg := `{"outbounds":[{"type":"socks","server":"1.2.3.4","server_port":"invalid"}]}`
	if err := parseKernelConfig(t, cfg); err == nil {
		t.Fatal("schema parser accepted server_port \"invalid\" —— CGoCheckConfigV1 将无法拦截坏节点")
	}
}

// 合法配置必须通过(否则校验导出会把好节点全判红)。
func TestK1CheckConfigAcceptsValidConfig(t *testing.T) {
	cfg := `{
  "log": {"level": "error"},
  "outbounds": [
    {"type": "socks", "tag": "socks-out", "server": "1.2.3.4", "server_port": 1080},
    {"type": "direct", "tag": "direct"}
  ]
}`
	if err := parseKernelConfig(t, cfg); err != nil {
		t.Fatalf("schema parser rejected a valid config: %v", err)
	}
}

// 其它 schema 类型错误也必须在这一层被拒(证明校验不是只认一个字段)。
func TestK1CheckConfigRejectsSchemaTypeErrors(t *testing.T) {
	cases := map[string]string{
		"inbounds-not-array":  `{"inbounds":{}}`,
		"outbound-type-bool":  `{"outbounds":[{"type":true}]}`,
		"route-rule-bad-type": `{"route":{"rules":"nope"}}`,
		"bad-json-syntax":     `{"outbounds":[}`,
	}
	for name, cfg := range cases {
		t.Run(name, func(t *testing.T) {
			if err := parseKernelConfig(t, cfg); err == nil {
				t.Fatalf("schema parser accepted invalid config %q", cfg)
			}
		})
	}
}

func srsFixturePath(t *testing.T) string {
	t.Helper()
	path := filepath.Join("fixtures", "geosite-cn.srs")
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("缺少 .srs 语料 %s: %v", path, err)
	}
	return path
}

// 真实 SRS 必须解析通过,并且确实读出了规则(不是只过了魔数就空手返回)。
func TestK1ValidateSrsAcceptsRealFixture(t *testing.T) {
	path := srsFixturePath(t)
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	compat, err := srs.Read(f, false)
	if err != nil {
		t.Fatalf("srs.Read rejected the real fixture %s: %v", path, err)
	}
	if len(compat.Options.Rules) == 0 {
		t.Fatal("srs.Read returned no rules for the real fixture —— 校验形同虚设")
	}
}

// 损坏文件必须报错:随机字节、截断的真实 SRS、错魔数、过高版本、空文件。
func TestK1ValidateSrsRejectsCorruptedFiles(t *testing.T) {
	realSRS, err := os.ReadFile(srsFixturePath(t))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	write := func(name string, data []byte) string {
		t.Helper()
		path := filepath.Join(dir, name)
		if err = os.WriteFile(path, data, 0o644); err != nil {
			t.Fatal(err)
		}
		return path
	}

	// 取真实文件的前 40% 作为"截断"样本(截在 zlib 流中间)。
	truncated := realSRS[:len(realSRS)*2/5]

	cases := map[string][]byte{
		"empty":           {},
		"random-bytes":    []byte("this is definitely not a rule-set file, just text"),
		"wrong-magic":     append([]byte("SRS"[0:2]), byte('X'), 0x05, 0x78, 0xda),
		"future-version":  append(append([]byte{}, realSRS[:3]...), 0xFF, 0x78, 0xda),
		"truncated":       truncated,
		"magic-only":      []byte{'S', 'R', 'S'},
		"zlib-garbage":    []byte{'S', 'R', 'S', 0x05, 0x00, 0x00, 0x00, 0x00},
		"json-not-binary": []byte(`{"version":3,"rules":[]}`),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			path := write(name+".srs", data)
			f, openErr := os.Open(path)
			if openErr != nil {
				t.Fatal(openErr)
			}
			defer f.Close()
			if _, readErr := srs.Read(f, false); readErr == nil {
				t.Fatalf("srs.Read accepted corrupted input %q (len=%d)", name, len(data))
			}
		})
	}
}

// 不存在的文件:导出必须先 os.Open 失败并上抛(NAPI 侧拿到 err: 文本)。
func TestK1ValidateSrsMissingFile(t *testing.T) {
	if f, err := os.Open(filepath.Join(t.TempDir(), "nope.srs")); err == nil {
		f.Close()
		t.Fatal("os.Open unexpectedly succeeded for a missing file")
	}
}

// 源码级守卫:两个导出必须保持"无副作用"契约 ——
// 一旦有人在函数体里加了 box.New / Start / 环境变量 / 写文件,这里就红。
// (内核层无法在主机纯 Go 测试里直接跑 c-shared 导出,故用源码断言兜住回归。)
func TestK1ExportBodiesStaySideEffectFree(t *testing.T) {
	source, err := os.ReadFile(filepath.Join("..", "..", "core", "libsingbox14", "main.go"))
	if err != nil {
		t.Fatalf("读取 core/libsingbox14/main.go 失败: %v", err)
	}
	text := string(source)

	bodies := map[string]string{}
	for _, name := range []string{"CGoCheckConfigV1", "CGoValidateSRSFileV1"} {
		start := strings.Index(text, "func "+name+"(")
		if start < 0 {
			t.Fatalf("main.go 里找不到 %s 的实现", name)
		}
		rest := text[start:]
		end := strings.Index(rest, "\n}\n")
		if end < 0 {
			t.Fatalf("%s 函数体未闭合", name)
		}
		bodies[name] = rest[:end]
	}

	for name, body := range bodies {
		for _, forbidden := range []string{
			"box.New(",        // 规则集下载 / 日志文件 / 缓存文件都发生在 New 里
			".Start()",        // 启动实例
			"os.Setenv",       // 污染 UI 进程内测速会话的环境变量
			"os.Unsetenv",     //
			"SING_BOX_TUN_FD", // 不得碰 TUN fd 注入
			"SING_BOX_BIND_IFNAME",
			"os.Create",     // 不得写文件
			"os.WriteFile",  //
			"os.MkdirAll",   //
			"startTestBox(", // 不得复用测速会话
			"CGoStartSingBox(",
		} {
			if strings.Contains(body, forbidden) {
				t.Errorf("%s 体内出现禁用调用 %q —— 该导出必须无副作用", name, forbidden)
			}
		}
	}

	// 正向锚点:必须真的走 leanContext + 上游解析器 / srs.Read,防止被空实现替换。
	if !strings.Contains(bodies["CGoCheckConfigV1"], "leanContext(") ||
		!strings.Contains(bodies["CGoCheckConfigV1"], "UnmarshalExtendedContext[option.Options]") {
		t.Error("CGoCheckConfigV1 未使用 leanContext + json.UnmarshalExtendedContext 解析")
	}
	if !strings.Contains(bodies["CGoValidateSRSFileV1"], "srs.Read(") {
		t.Error("CGoValidateSRSFileV1 未使用 srs.Read 解析")
	}
	// 两个导出都必须带 //export 指令(cgo 生成 .dynsym 入口的前提)。
	for _, name := range []string{"CGoCheckConfigV1", "CGoValidateSRSFileV1"} {
		if !strings.Contains(text, "//export "+name+"\n") {
			t.Errorf("main.go 缺少 //export %s", name)
		}
	}
}
