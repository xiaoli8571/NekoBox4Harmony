import io

p = 'core/scripts/build-libsingbox-ohos.sh'
lines = io.open(p, encoding='utf-8').read().split('\n')

# 定位起止(按内容断言,不靠硬编码行号)
start = None
end = None
for i, line in enumerate(lines):
    if line.startswith('# sing-tun netlink 订阅改 best-effort'):
        start = i
    if start is not None and line.strip() == 'fi' and i > start:
        end = i
        break
assert start is not None and end is not None, 'sing-tun patch block not found'
assert 'perl -0pi -e' in lines[start + 1], 'unexpected block layout'
assert 'monitor_linux_default_openharmony.go' in '\n'.join(lines[start:end + 1])

new_block = """# sing-tun netlink / 默认接口探测的 HarmonyOS 补丁(幂等,见 scripts/patch-singtun-ohos.py)。
# 0.9.7 起上游把 netlink 订阅改成 unix.Socket 直连,旧的 perl 正则匹配不到,
# 因此改为独立补丁器:按内容断言 + fail-closed。
python "$ROOT/scripts/patch-singtun-ohos.py" "$STPDIR" || { echo "ERROR: sing-tun OHOS patch failed"; exit 1; }
grep -q 'netlink monitor disabled on OpenHarmony' "$STPDIR/monitor_linux.go" || { echo "ERROR: sing-tun netlink early-return missing"; exit 1; }
grep -q 'isOpenHarmonyRuntime' "$STPDIR/zz_ohos_monitor_openharmony.go" || { echo "ERROR: sing-tun platform const missing"; exit 1; }
""".split('\n')

lines[start:end + 1] = new_block
io.open(p, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))

# .so 标记检查同步:旧标记 "route subscribe" 已不存在(上游改写),换成新标记
s = io.open(p, encoding='utf-8').read()
old = 'grep -aqF "route subscribe" "$SO"     || { echo "ERROR: .so lacks sing-tun netlink patch marker"; exit 1; }'
assert old in s, 'so marker check missing'
s = s.replace(old, 'grep -aqF "netlink monitor disabled on OpenHarmony" "$SO" || { echo "ERROR: .so lacks sing-tun netlink patch marker"; exit 1; }', 1)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('build script updated')
