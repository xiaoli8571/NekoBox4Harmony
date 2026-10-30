#!/usr/bin/env python3
"""OHOS: gVisor fdbased.IsSocketFD 的 fstat 探测容错。

背景(真机实测,2026-10-30):
  HarmonyOS VPN 扩展拿到的 TUN fd 是系统注入的匿名 fd,SELinux 不允许对它做
  fstat(返回 EPERM)。而 gVisor 的 fdbased 层用 fstat 判断"这个 fd 是不是
  AF_PACKET socket":
      gvisor/pkg/tcpip/link/fdbased/endpoint.go: IsSocketFD()
  探测失败会让整个 gVisor 栈创建失败,sing-box 报:
      post-start inbound/tun[tun-in]: starting tun stack:
      unix.Fstat(61,...) failed: permission denied
  真机表现:VPN 连上约 0.3 秒后被回滚断开(用户看到的「无法启动」)。

补丁策略:
  fstat 失败时按"非 socket"(即 TUN 设备)继续。该探测只用于决定是否走
  AF_PACKET fanout 分支,TUN fd 本来就不是 socket,因此语义正确;Linux 等
  平台上 fstat 正常,行为不变。

幂等 + fail-closed:
  重复执行安全;目标源码形态与预期不符时非零退出,避免静默失效。
"""

import io
import os
import sys

MARKER = '[OHOS-FSTAT-TOLERANT]'
REL = 'vendor/github.com/sagernet/gvisor/pkg/tcpip/link/fdbased/endpoint.go'

ORIG = '''func IsSocketFD(fd int) (bool, error) {
\tvar stat unix.Stat_t
\tif err := unix.Fstat(fd, &stat); err != nil {
\t\treturn false, fmt.Errorf("unix.Fstat(%v,...) failed: %v", fd, err)
\t}
\treturn (stat.Mode & unix.S_IFSOCK) == unix.S_IFSOCK, nil
}'''

PATCHED = '''func IsSocketFD(fd int) (bool, error) {
\tvar stat unix.Stat_t
\tif err := unix.Fstat(fd, &stat); err != nil {
\t\t// [OHOS-FSTAT-TOLERANT] HarmonyOS 的 VPN 扩展 TUN fd 由系统注入,SELinux
\t\t// 拒绝对它 fstat(EPERM)。该探测只用于区分 AF_PACKET socket 与 TUN 设备;
\t\t// 失败时按"非 socket"继续,fdbased 走 TUN 路径,避免整栈启动被误判失败。
\t\treturn false, nil
\t}
\treturn (stat.Mode & unix.S_IFSOCK) == unix.S_IFSOCK, nil
}'''


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: patch-gvisor-ohos-fstat.py <wrapper-dir>', file=sys.stderr)
        return 2
    path = os.path.join(sys.argv[1], REL.replace('/', os.sep))
    if not os.path.isfile(path):
        print('ERROR: gvisor endpoint.go not found: %s' % path, file=sys.stderr)
        return 1

    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        src = f.read()

    if MARKER in src:
        if PATCHED not in src:
            print('ERROR: marker present but patched body missing (manual edit?)', file=sys.stderr)
            return 1
        print('gvisor OHOS fstat tolerance: already applied')
        return 0

    if ORIG not in src:
        print('ERROR: IsSocketFD body changed upstream; patch needs update', file=sys.stderr)
        return 1
    if src.count(ORIG) != 1:
        print('ERROR: IsSocketFD body not unique (%d matches)' % src.count(ORIG), file=sys.stderr)
        return 1

    out = src.replace(ORIG, PATCHED, 1)
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(out)

    if MARKER not in out:
        print('ERROR: write verification failed', file=sys.stderr)
        return 1
    print('gvisor OHOS fstat tolerance: applied -> %s' % REL)
    return 0


if __name__ == '__main__':
    sys.exit(main())
