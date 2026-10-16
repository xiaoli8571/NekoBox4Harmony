package parityprobe

// Geo 规则集回归(2026-09-27)
//
// 背景:设置页的 GeoSite库/GeoIP库下载全部 404,根因是 GeoAssets 请求了上游早已
// 停止发布的 .db,而 sing-geosite/sing-geoip 的 rule-set 分支只提供 .srs。
// 修好下载还不够——必须证明本项目实际使用的内核(1.14)能加载 .srs 生成的
// local rule_set 定义,否则只是把 404 换成了启动失败。
//
// 该测试用真实的 sing-box 1.14 内核校验 schema 并实际加载两份 .srs。

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 真实 .srs 语料:由 tests/geo-srs.cjs 确认的同一上游地址下载。
// 不入库(体积大),缺失时跳过并提示,避免 CI 因网络失败而红。
const (
	geoSiteURL = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
	geoIPURL   = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
)

func fetchGeoAsset(t *testing.T, url string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, filepath.Base(url))

	client := &http.Client{Timeout: 90 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		t.Skipf("网络不可用,跳过 .srs 端到端校验: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Skipf("上游 %s 返回 HTTP %d,跳过", url, resp.StatusCode)
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err = io.Copy(f, resp.Body); err != nil {
		t.Fatal(err)
	}
	return path
}

// 生成的配置与 ConfigBuilder.buildGeoRuleSet 同形:local + binary + path。
// Windows 临时目录含反斜杠,直接拼进 JSON 会变成非法转义,统一转成正斜杠。
// DNS/入站沿用 tests/hostprobe 既有 fixture 的最小可用形状(lean 构建没有
// `local` DNS transport,也不需要真实 TUN:本测试只关心 rule_set 的加载与匹配)。
func geoRuleSetConfig(tag string, path string) string {
	jsonPath := filepath.ToSlash(path)
	return `{
  "log": {"level": "error"},
  "dns": {
    "servers": [{"tag": "local", "type": "udp", "server": "127.0.0.1"}],
    "rules": [{"outbound": "any", "server": "local"}],
    "final": "local"
  },
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {
    "rules": [{"rule_set": ["` + tag + `"], "outbound": "direct"}],
    "rule_set": [{"type": "local", "tag": "` + tag + `", "format": "binary", "path": "` + jsonPath + `"}],
    "final": "direct",
    "auto_detect_interface": false
  },
  "experimental": {"cache_file": {"enabled": false}}
}`
}

// 核心回归:内核必须能加载真实 .srs(此前 .db 从未成功下载过,
// 所以这条路径在生产上从未被真正执行过)。
func TestRealSRSGeoRuleSetsLoad(t *testing.T) {
	sitePath := fetchGeoAsset(t, geoSiteURL)
	ipPath := fetchGeoAsset(t, geoIPURL)

	for _, tc := range []struct {
		tag  string
		path string
	}{
		{"geosite_cn", sitePath},
		{"geoip_cn", ipPath},
	} {
		t.Run(tc.tag, func(t *testing.T) {
			if err := startBoxRaw(t, geoRuleSetConfig(tc.tag, tc.path)); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// 回归:旧 .db 路径必须真的失败,证明「404 后换了格式」不是蒙对了。
// 内核对 .db 既无 source 也无 binary 格式推断(ruleSetDefaultFormat 只认
// .json/.srs),显式 format:"binary" 时会因为魔数不匹配而报错。
func TestLegacyDBGeoFileIsRejected(t *testing.T) {
	dir := t.TempDir()
	// 造一个内容像 .db(实际是 JSON 文本)的假库
	fake := filepath.Join(dir, "geosite-cn.db")
	if err := os.WriteFile(fake, []byte(`{"version":3,"rules":[]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := `{
  "log": {"level": "error"},
  "dns": {
    "servers": [{"tag": "local", "type": "udp", "server": "127.0.0.1"}],
    "rules": [{"outbound": "any", "server": "local"}],
    "final": "local"
  },
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {
    "rules": [{"rule_set": ["geosite_cn"], "outbound": "direct"}],
    "rule_set": [{"type": "local", "tag": "geosite_cn", "format": "binary", "path": "` + filepath.ToSlash(fake) + `"}],
    "final": "direct",
    "auto_detect_interface": false
  },
  "experimental": {"cache_file": {"enabled": false}}
}`
	if err := startBoxRaw(t, cfg); err == nil {
		t.Fatal("expected the fake .db rule-set to be rejected, but the kernel accepted it")
	}
}
