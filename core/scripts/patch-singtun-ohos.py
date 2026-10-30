#!/usr/bin/env python3
"""sing-tun 的 HarmonyOS 补丁(幂等,按内容断言,不依赖上游行号)。

背景
----
sing-tun 的 monitor 代码按 GOOS 分文件,而 OHOS Go fork 把 `_linux.go` 也纳入
`GOOS=openharmony` 的构建(``<fork>/src/go/build/build.go`` 里
``if ctxt.GOOS == "openharmony" && name == "linux"``),所以 Linux 分支的 netlink
代码在鸿蒙上**确实会被编译**。

HarmonyOS 沙箱内 netlink 订阅必然失败。sing-tun 0.9.0 用高阶封装
(``netlink.RouteSubscribe``),失败只返回错误;0.9.7 起改成 ``unix.Socket`` 直连
netlink,失败会直接让 TUN 启动中断。因此这里做两件事:

1. ``networkUpdateMonitor.Start()`` 开头早退:openharmony 上不碰 netlink,
   只保留定时 loop(不产生任何更新事件,等价于"没有网卡变更通知")。
2. ``defaultInterfaceMonitor.checkUpdate()`` 在 openharmony 上直接返回
   ``ErrNoRoute``:避免 ``netlink.RouteListFiltered`` 在沙箱里报错/卡住。

平台判定必须用 build tag 常量,不能用 ``runtime.GOOS`` —— OHOS Go fork 的
``runtime.GOOS`` 返回 "linux",分不出鸿蒙。

用法:python patch-singtun-ohos.py <sing-tun 源码目录>
退出码非 0 表示补丁没打上(构建脚本 fail-closed)。
"""
import io
import os
import sys

MARKER = 'netlink monitor disabled on OpenHarmony'

OPENHARMONY_CONST = """//go:build openharmony

package tun

// OHOS: 平台常量(build tag 隔离)。OHOS Go fork 的 runtime.GOOS 返回 "linux",
// 只有 build tag 能区分出鸿蒙。netlink 相关早退见 monitor_linux.go / 
// monitor_linux_default_openharmony.go。
const isOpenHarmonyRuntime = true
"""

OTHER_CONST = """//go:build !openharmony

package tun

const isOpenHarmonyRuntime = false
"""

NO_ROUTE_OVERRIDE = """//go:build openharmony

package tun

// OHOS: 沙箱内 netlink.RouteListFiltered 不可用,默认接口探测直接"没有默认路由";
// 实际防回环由 sing-box 侧 route.default_interface(设置页实验项)负责。
func (m *defaultInterfaceMonitor) checkUpdate() error {
	return ErrNoRoute
}
"""


def read(path):
    with io.open(path, encoding='utf-8') as fh:
        return fh.read()


def write(path, text):
    with io.open(path, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else '.'
    monitor = os.path.join(d, 'monitor_linux.go')
    if not os.path.isfile(monitor):
        print('ERROR: %s missing' % monitor, file=sys.stderr)
        return 1

    src = read(monitor)
    if MARKER not in src:
        anchor = 'func (m *networkUpdateMonitor) Start() error {\n'
        if anchor not in src:
            print('ERROR: networkUpdateMonitor.Start() anchor missing', file=sys.stderr)
            return 1
        inject = anchor + (
            '\t// OHOS: ' + MARKER + ' —— 沙箱里 netlink 订阅必然失败,\n'
            '\t// 0.9.7 起用 unix.Socket 直连,失败会直接中断 TUN 启动;\n'
            '\t// 平台判定用 openharmony build tag 常量(runtime.GOOS 在 fork 上是 "linux")。\n'
            '\tif isOpenHarmonyRuntime {\n'
            '\t\tm.logger.Debug("' + MARKER + '")\n'
            '\t\tgo m.loopUpdate(time.Second)\n'
            '\t\treturn nil\n'
            '\t}\n'
        )
        src = src.replace(anchor, inject, 1)
        write(monitor, src)

    if MARKER not in read(monitor):
        print('ERROR: netlink early-return patch did not apply', file=sys.stderr)
        return 1

    write(os.path.join(d, 'zz_ohos_monitor_openharmony.go'), OPENHARMONY_CONST)
    write(os.path.join(d, 'zz_ohos_monitor_other.go'), OTHER_CONST)

    default_monitor = os.path.join(d, 'monitor_linux_default.go')
    if os.path.isfile(default_monitor):
        text = read(default_monitor)
        if 'netlink.RouteListFiltered' in text:
            if '!openharmony' not in text:
                text = text.replace('//go:build linux && !android',
                                    '//go:build linux && !android && !openharmony', 1)
                write(default_monitor, text)
            write(os.path.join(d, 'monitor_linux_default_openharmony.go'), NO_ROUTE_OVERRIDE)
        if '!openharmony' not in read(default_monitor):
            print('ERROR: default interface monitor not excluded on openharmony', file=sys.stderr)
            return 1

    print('==> sing-tun OHOS patch applied (netlink early-return + default iface disabled)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
