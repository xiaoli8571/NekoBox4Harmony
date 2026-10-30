#!/usr/bin/env python3
"""direct outbound fetchMyAddresses 判空补丁(HarmonyOS 必需)。

为什么必须
----------
``route/network.go`` 补丁 2 让 ``auto_detect_interface=false`` 时不去建
InterfaceMonitor,于是 ``h.network.InterfaceMonitor()`` 返回 nil;上游 1.14 起
``direct.Start(StartStatePostStart)`` 会无条件调 ``h.fetchMyAddresses()``,
里面直接对 nil 接口调方法 → 内核 SIGSEGV。上游 ``dhcp.go`` 里同样做了判空,
这里对齐同一语义。

历史坑
------
原实现是一行 perl ``s/func \\(h \\*Outbound\\) fetchMyAddresses\\(\\) \\{\\n/\\1 .../``,
替换串里的 ``\\1`` 前面**没有捕获组**,perl 会把它当空串 → 函数签名被删掉,
产出 ``syntax error: non-declaration statement outside function body``。
本脚本改为"插入不消费",并对已被吃掉的签名做自愈。

用法:python patch-singbox-direct-nilguard.py <sing-box 源码目录>
"""
import io
import os
import sys

SIGNATURE = 'func (h *Outbound) fetchMyAddresses() {\n'
COMMENT = '\t// OHOS: auto_detect_interface=false 时 InterfaceMonitor 为 nil(route/network.go 补丁 2 早退),\n'
GUARD = (
    COMMENT
    + '\t// nil 接口调方法直接 SIGSEGV;上游 dhcp.go 也做了同样的判空。\n'
    + '\tif h.network.InterfaceMonitor() == nil {\n'
    + '\t\treturn\n'
    + '\t}\n'
)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    path = os.path.join(root, 'protocol', 'direct', 'outbound.go')
    if not os.path.isfile(path):
        print('ERROR: %s missing' % path, file=sys.stderr)
        return 1
    with io.open(path, encoding='utf-8') as fh:
        src = fh.read()

    if COMMENT in src and SIGNATURE + COMMENT not in src:
        # 自愈:上一次用坏掉的 perl 跑过,签名被吃掉 → 补回来
        src = src.replace(COMMENT, SIGNATURE + COMMENT, 1)
        print('==> direct: 修复被吃掉的 fetchMyAddresses() 签名')

    if COMMENT not in src:
        if SIGNATURE not in src:
            print('ERROR: fetchMyAddresses() signature missing upstream', file=sys.stderr)
            return 1
        src = src.replace(SIGNATURE, SIGNATURE + GUARD, 1)

    if SIGNATURE + COMMENT not in src:
        print('ERROR: direct nil-guard patch did not apply', file=sys.stderr)
        return 1

    with io.open(path, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(src)
    print('==> direct: fetchMyAddresses nil-guard OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
