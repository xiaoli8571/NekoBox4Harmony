//go:build openharmony

package route

// OHOS Go fork 下 runtime.GOOS 实际返回 "linux"(goos.GOOS 常量),
// 平台标识必须用 openharmony build tag;见 internal/goos/zgoos_openharmony.go。
const isOpenHarmonyRuntime = true
