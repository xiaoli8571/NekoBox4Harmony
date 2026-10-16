// Clash YAML 解析器回归测试(Node 22.6+ 可直接跑 .ts,无需编译步骤)。
//
//   node --experimental-strip-types scripts/test/clashyaml.test.ts
//
// ⚠️ ClashYaml.ts 是 entry/src/main/ets/utils/ClashYaml.ets 的**副本**
// (ArkTS 不能直接被 Node 执行)。改了真身请同步过来:
//   cp entry/src/main/ets/utils/ClashYaml.ets scripts/test/ClashYaml.ts
//
// 这套用例不是摆设:解析器第一版有个 `parseMap` 只更新 next 不推进 i 的
// 缩进游标,结果**任何带 ws-opts/grpc-opts 的节点都会吞掉它后面的所有节点**,
// 整份 Clash 订阅只导入第一个 —— 真机上表现为"订阅导入一个都不成功",
// 而编译期完全无感。下面第 3 组就是它的回归用例。
import { parseYaml } from './ClashYaml.ts';

let pass = 0, fail = 0;
function check(label: string, cond: boolean, detail = '') {
  if (cond) { pass++; console.log(`ok    ${label}`); }
  else { fail++; console.log(`FAIL  ${label} ${detail}`); }
}
function proxies(y: string) {
  const r = parseYaml(y);
  const p = r.get('proxies');
  return (p && p.isSeq()) ? p.items : [];
}
function s(n: any, k: string, d = '<null>') { const v = n.get(k); return v ? v.scalar : d; }

// 1. 注释:行尾 / 整行 / 引号内 / 端口
{
  const ps = proxies(`proxies:
  - name: a # 注释
    server: s.com   # 另一个
    port: 443 # 端口注释
  # 整行注释
  - name: b
    server: t.com
    port: 8443
    password: "has#hash"
`);
  check('注释: 数量', ps.length === 2, `got ${ps.length}`);
  check('注释: 端口带注释仍为数字', s(ps[0], 'port') === '443', s(ps[0], 'port'));
  check('注释: 引号内 # 保留', s(ps[1], 'password') === 'has#hash', s(ps[1], 'password'));
  check('注释: 名字不含注释', s(ps[0], 'name') === 'a', s(ps[0], 'name'));
}
// 2. 锚点 / 别名 / 合并键
{
  const ps = proxies(`tmpl: &ws
  path: /default
  headers:
    Host: d.com
base: &base
  udp: true
proxies:
  - name: a
    server: s.com
    port: 443
    ws-opts: *ws
  - <<: *base
    name: b
    server: t.com
    port: 8443
`);
  check('锚点: 数量', ps.length === 2, `got ${ps.length}`);
  const wo = ps[0].get('ws-opts');
  check('锚点: 别名解析出 path', wo !== null && wo.get('path')?.scalar === '/default');
  const h = wo ? wo.get('headers') : null;
  check('锚点: 别名深层 headers.Host', h !== null && h.get('Host')?.scalar === 'd.com');
  check('合并键: << 作为首键生效', ps[1].get('udp') !== null && s(ps[1], 'udp') === 'true');
  check('合并键: 自身键保留', s(ps[1], 'name') === 'b', s(ps[1], 'name'));
}
// 3. 流式集合
{
  const ps = proxies(`proxies:
  - name: a
    server: s.com
    port: 443
    alpn: [h2, http/1.1]
    smux: {protocol: h2mux, max-streams: 8}
    reality-opts: {public-key: pk, short-id: ""}
`);
  check('流式: 列表', ps[0].get('alpn')?.items.length === 2);
  check('流式: 嵌套 map', s(ps[0].get('smux'), 'protocol') === 'h2mux');
  check('流式: public-key', s(ps[0].get('reality-opts'), 'public-key') === 'pk');
}
// 4. proxy-groups 是同缩进序列,不能吞掉 proxies
{
  const r = parseYaml(`proxies:
  - name: a
    server: s.com
    port: 443
proxy-groups:
  - name: G
    type: select
    proxies:
      - a
      - b
rules:
  - MATCH,G
`);
  check('结构: proxies 数量', (r.get('proxies') as any)?.items.length === 1);
  const g = r.get('proxy-groups');
  check('结构: proxy-groups 独立', g !== null && g.items.length === 1);
  check('结构: 组内成员', (g?.items[0].get('proxies') as any)?.items.length === 2);
  check('结构: rules 独立', r.get('rules') !== null && r.get('rules')!.items.length === 1);
}
// 5. 名字里含 ": "
{
  const ps = proxies(`proxies:
  - name: "HK: 01 特别版"
    server: s.com
    port: 443
`);
  check('怪值: 名字含冒号', s(ps[0], 'name') === 'HK: 01 特别版', s(ps[0], 'name'));
}
// 6. 序列顶格 + IPv6
{
  const ps = proxies(`proxies:
- name: a
  type: trojan
  server: "[2001:db8::1]"
  port: 443
`);
  check('顶格序列: 数量', ps.length === 1, `got ${ps.length}`);
  check('顶格序列: IPv6 保留', s(ps[0], 'server') === '[2001:db8::1]', s(ps[0], 'server'));
}
// 7. 空 proxies / 只有 provider
{
  const r = parseYaml(`proxy-providers:\n  x:\n    url: https://e.com\n`);
  check('空: 无 proxies 返回 null', r.get('proxies') === null);
}
// 8. 块标量
{
  const ps = proxies(`proxies:
  - name: a
    server: s.com
    port: 443
    note: |
      line1
      line2
  - name: b
    server: t.com
    port: 443
`);
  check('块标量: 不吞后续节点', ps.length === 2, `got ${ps.length}`);
  check('块标量: 内容', (ps[0].get('note')?.scalar || '').includes('line2'));
}
console.log(`\npass=${pass} fail=${fail}`);
if (fail > 0) process.exit(1);
