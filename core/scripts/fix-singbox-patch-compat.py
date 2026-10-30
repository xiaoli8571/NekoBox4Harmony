#!/usr/bin/env python3
"""让 OHOS 补丁适配上游 API 漂移(幂等)。

补丁本身是 perl 正则注入的,上游把同名符号换了"载体"时会注入出编译不过的代码
(1.14 → 1.15 真实踩到的两处):

1. ``common/urltest``:1.15 新增 ``URLTestWithOptions``,``urlTest`` 变成 5 参;
   补丁里只改写了 ``ctx`` 版调用,1.15 新加的 mux 预热调用
   ``urlTest(warmContext, link, detour)`` 仍是 3 参 → 编译报 "not enough arguments"。
2. ``common/dialer``:1.14 监听侧 Control 挂在局部变量 ``listener``(类型
   ``*listener.Listener``);1.15 改成 ``listenConfig``(``listener`` 在那里已经是
   包名),补丁注入的 ``listener.Control = ...`` 变成 "undefined: listener.Control"。

两处都在编译期就能发现,但要修在补丁层而不是源码层,否则每次重建都会退化。

用法:python fix-singbox-patch-compat.py <sing-box 源码目录>
"""
import io
import os
import re
import sys


def read(path):
    with io.open(path, encoding='utf-8') as fh:
        return fh.read()


def write(path, text):
    with io.open(path, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)


def fix_urltest(root):
    path = os.path.join(root, 'common', 'urltest', 'urltest.go')
    if not os.path.isfile(path):
        return False
    src = read(path)
    if 'func URLTestWithOptions' not in src:
        return False  # 补丁 7 未生效或旧版无 options 形态,无需处理
    # 只补 3 参调用(5 参已带 options 的不动);默认走 HEAD,与补丁语义一致
    new, count = re.subn(r'urlTest\((\w+), link, detour\)',
                         r'urlTest(\1, link, detour, options, http.MethodHead)', src)
    if count > 0:
        write(path, new)
        print('==> compat: %d 处 3 参 urlTest 调用补齐 options/method' % count)
    return count > 0


def _write_rule_consts(root):
    """package rule 自己的平台常量(const 不跨包可见,route 包里那份用不了)。"""
    write(os.path.join(root, 'route', 'rule', 'zz_ohos_rule_openharmony.go'),
          '//go:build openharmony\n\npackage rule\n\n// OHOS: 平台常量(见 route/zz_ohos_openharmony.go 说明)。\nconst isOpenHarmonyRuntime = true\n')
    write(os.path.join(root, 'route', 'rule', 'zz_ohos_rule_other.go'),
          '//go:build !openharmony\n\npackage rule\n\nconst isOpenHarmonyRuntime = false\n')


def patch_ruleset_watcher(root):
    """1.15 新增:本地 rule-set 文件用 fswatch 监听变更。

    鸿蒙沙箱对被监视目录无 inotify 权限,``Start()`` 会打
    ``ERROR watch rule-set file: fswatch: watch ...: permission denied``。
    本地规则集本身已在建对象时同步加载成功,监听只是热更新便利功能;
    这里在 openharmony 上跳过 watcher 创建(应用侧更新规则集后重连内核即生效),
    消除启动期噪音错误。
    """
    path = os.path.join(root, 'route', 'rule', 'rule_set_local.go')
    if not os.path.isfile(path):
        return False
    src = read(path)
    marker = 'OHOS: 沙箱内 fswatch'
    if marker in src:
        # 已注入过:常量文件可能因上次中断缺失 → 仍然幂等补齐
        _write_rule_consts(root)
        return False
    anchor = '\t\twatcher, err := fswatch.NewWatcher(fswatch.Options{'
    if anchor not in src:
        print('==> compat: rule_set_local.go 无 fswatch 锚点(上游已变),跳过', file=sys.stderr)
        return False
    inject = (
        '\t\t// ' + marker + '(inotify) 对被监控目录无权限,Start() 会持续打 ERROR;\n'
        '\t\t// 本地规则集已在建对象时同步加载完成,热更新不是必需能力。\n'
        '\t\tif isOpenHarmonyRuntime {\n'
        '\t\t\treturn ruleSet, nil\n'
        '\t\t}\n'
        + anchor
    )
    write(path, src.replace(anchor, inject, 1))
    _write_rule_consts(root)
    print('==> compat: rule-set 文件监听在 openharmony 上禁用')
    return True


def fix_dialer_listen_control(root):
    path = os.path.join(root, 'common', 'dialer', 'default.go')
    if not os.path.isfile(path):
        return False
    src = read(path)
    if 'listenConfig.Control' not in src:
        return False  # 1.14 形态:listener.Control 是合法的,保持原样
    old = '\t\t\tlistener.Control = control.Append(listener.Control, forceBind)'
    if old not in src:
        return False
    new = '\t\t\tlistenConfig.Control = control.Append(listenConfig.Control, forceBind)'
    write(path, src.replace(old, new, 1))
    print('==> compat: OHOS forceBind 改注入 listenConfig.Control(1.15 载体)')
    return True


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    if not os.path.isdir(root):
        print('ERROR: %s not a directory' % root, file=sys.stderr)
        return 1
    fix_urltest(root)
    fix_dialer_listen_control(root)
    patch_ruleset_watcher(root)

    # 校验:补丁产物里不允许残留编译不过的旧载体
    dialer = os.path.join(root, 'common', 'dialer', 'default.go')
    if os.path.isfile(dialer):
        text = read(dialer)
        if 'listenConfig.Control' in text and 'listener.Control = control.Append(listener.Control, forceBind)' in text:
            print('ERROR: listener.Control forceBind 残留', file=sys.stderr)
            return 1
    urltest = os.path.join(root, 'common', 'urltest', 'urltest.go')
    if os.path.isfile(urltest):
        text = read(urltest)
        for match in re.finditer(r'urlTest\((\w+), link, detour\)', text):
            print('ERROR: urlTest 3 参调用残留: %s' % match.group(0), file=sys.stderr)
            return 1
    print('==> sing-box OHOS patch compat OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
