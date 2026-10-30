//go:build openharmony

package tun

// OHOS: 平台常量(build tag 隔离)。OHOS Go fork 的 runtime.GOOS 返回 "linux",
// 只有 build tag 能区分出鸿蒙。netlink 相关早退见 monitor_linux.go / 
// monitor_linux_default_openharmony.go。
const isOpenHarmonyRuntime = true
