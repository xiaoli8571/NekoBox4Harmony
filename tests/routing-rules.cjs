// RoutingRules typed model / manifest / validation tests (P4/W13, plan §7.3/§7.4/§8.5/§12.3-2).
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

function load(file, imports = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: (n) => { if (!(n in imports)) throw Error(n); return imports[n]; } });
  return exports;
}

const probe = load('entry/src/main/ets/model/ProbeResult.ets', {});
const rr = load('entry/src/main/ets/model/RoutingRules.ets', { './ProbeResult': probe });

const T = rr; // shorthand
const codes = (list) => list.map((i) => i.code);
// vm 里的对象/数组来自另一个 realm，deepStrictEqual 会因原型不同而失败：先转成本 realm 的普通值
const plain = (v) => JSON.parse(JSON.stringify(v));

// 1. parse: 新格式行(自描述 type/payload)字段原样保留
{
  const rows = [
    { id: 'r1', type: 'domain_suffix', payload: 'Example.COM', outbound: 'proxy', enabled: true },
    { id: 'r2', type: 'ip_cidr', payload: '10.0.0.0/8', outbound: 'direct', enabled: false }
  ];
  const rules = T.parseRules(rows);
  assert.equal(rules.length, 2);
  assert.equal(rules[0].id, 'r1');
  assert.equal(rules[0].type, 'domain_suffix');
  assert.equal(rules[0].payload, 'example.com'); // 规范化小写
  assert.equal(rules[0].outbound, 'proxy');
  assert.equal(rules[0].order, 0);
  assert.equal(rules[1].order, 1);
  assert.equal(rules[1].enabled, false);
  assert.deepEqual(plain(rules[0].legacyRow), {});
  console.log('PASS parse new-format rows keeps id/type/outbound/order, normalizes payload');
}

// 2. parse: 旧单类型行(type/value)迁移为类型化主条件
{
  const rules = T.parseRules([
    { type: 'domain', value: 'a.com' },
    { type: 'domain_keyword', value: 'kw' },
    { type: 'geoip', value: 'cn' },
    { type: 'geosite', value: 'cn' },
    { type: 'domain_suffix', value: 'b.com, C.COM' }
  ]);
  assert.equal(rules[0].type, 'domain');
  assert.equal(rules[0].payload, 'a.com');
  assert.equal(rules[1].type, 'domain_keyword');
  assert.equal(rules[2].type, 'geoip');
  assert.equal(rules[2].payload, 'cn');
  assert.equal(rules[3].type, 'rule_set');
  assert.equal(rules[3].payload, 'cn'); // 旧 geosite 单类型无前缀 → 归一成规则集 id
  assert.equal(rules[4].type, 'domain_suffix');
  assert.equal(rules[4].payload, 'b.com,c.com');
  console.log('PASS parse legacy single-type rows (type/value) → typed primary condition');
}

// 3. parse: 旧多字段 AND 行 → 主条件 + legacyRow 保留其余条件
{
  const raw = [{
    domains: 'a.com, full:b.com, keyword:kw, regexp:^x.*$, geosite:cn',
    ip: 'geoip:private, 1.2.3.0/24',
    port: '80, 1000:2000',
    network: 'tcp',
    outbound: 'proxy',
    remark: '旧规则',
    unsupportedOnPlatform: true,
    unsupportedReason: '平台不支持'
  }];
  const r = T.parseRules(raw)[0];
  assert.equal(r.type, 'domain_suffix'); // 后缀优先
  assert.equal(r.payload, 'a.com');
  assert.equal(r.outbound, 'proxy');
  assert.equal(r.unsupportedOnPlatform, true);
  assert.equal(r.unsupportedReason, '平台不支持');
  assert.equal(r.legacyRow['ip'], 'geoip:private, 1.2.3.0/24');
  assert.equal(r.legacyRow['port'], '80, 1000:2000');
  assert.equal(r.legacyRow['network'], 'tcp');
  assert.equal(r.legacyRow['remark'], '旧规则');
  console.log('PASS parse legacy AND row keeps every untouched condition in legacyRow');
}

// 4. parse: packages 行 → LEGACY_PACKAGE_TYPE，unsupportedOnPlatform 如实保留
{
  const marked = T.parseRules([{
    domains: 'x.com', packages: 'com.a,com.b', packagesEnabled: true,
    unsupportedOnPlatform: true, unsupportedReason: 'OHOS 无进程名匹配'
  }])[0];
  assert.equal(marked.type, 'package');
  assert.equal(marked.payload, 'com.a,com.b');
  assert.equal(marked.unsupportedOnPlatform, true);
  assert.equal(marked.unsupportedReason, 'OHOS 无进程名匹配');
  const unmarked = T.parseRules([{ packages: 'com.c' }])[0];
  assert.equal(unmarked.type, 'package');
  assert.equal(unmarked.unsupportedOnPlatform, false); // 原文没有标记 → 不编造
  console.log('PASS parse packages rows → package type, unsupportedOnPlatform preserved as stored');
}

// 5. parse: 无 id 行的稳定 ID(确定性 + 唯一)
{
  const rows = [
    { domains: 'a.com', outbound: 'proxy' },
    { domains: 'a.com', outbound: 'proxy' }, // 完全相同 → 追加序号
    { domains: 'b.com', outbound: 'proxy' }
  ];
  const first = T.parseRules(rows).map((r) => r.id);
  const second = T.parseRules(rows).map((r) => r.id);
  assert.deepEqual(first, second); // 稳定
  assert.equal(new Set(first).size, 3); // 唯一
  assert.ok(first[0].startsWith('rule_'));
  console.log('PASS parse derives deterministic, unique ids for rows without id');
}

// 6. toRawRows: 类型化规则往返(id/type/payload/outbound/enabled/order/source 不丢)
{
  const input = [
    { id: 'k1', type: 'domain_suffix', payload: 'a.com', outbound: 'direct', enabled: true },
    { id: 'k2', type: 'ip_cidr', payload: '10.0.0.0/8', outbound: 'block', enabled: false, ruleSource: 'preset' }
  ];
  const rules = T.parseRules(input);
  const rows = T.toRawRows(rules);
  const again = T.parseRules(rows);
  assert.equal(again[0].id, 'k1');
  assert.equal(again[0].type, 'domain_suffix');
  assert.equal(again[0].payload, 'a.com');
  assert.equal(again[0].outbound, 'direct');
  assert.equal(again[0].enabled, true);
  assert.equal(again[0].order, 0);
  assert.equal(again[1].id, 'k2');
  assert.equal(again[1].outbound, 'block'); // reject → block 归一后再写回 reject
  assert.equal(rows[1]['outbound'], 'reject');
  assert.equal(again[1].source, 'preset');
  assert.equal(again[1].enabled, false);
  console.log('PASS toRawRows round-trip keeps typed fields (reject↔block, ruleSource)');
}

// 7. toRawRows: 旧行高级条件不丢；远程规则集引用不落进 domains
{
  const raw = [{
    domains: 'a.com', ip: '1.2.3.0/24', port: '80, 1000:2000',
    network: 'tcp', protocol: 'tls', source: '192.168.0.0/16', outbound: 'proxy'
  }];
  const rule = T.parseRules(raw)[0];
  const row = T.toRawRows([rule])[0];
  assert.equal(row['domains'], 'a.com');
  assert.equal(row['ip'], '1.2.3.0/24');
  assert.equal(row['port'], '80,1000:2000');
  assert.equal(row['network'], 'tcp');
  assert.equal(row['protocol'], 'tls');
  assert.equal(row['source'], '192.168.0.0/16');
  const again = T.parseRules([row])[0];
  assert.equal(again.type, 'domain_suffix');
  assert.equal(again.payload, 'a.com');
  assert.equal(again.legacyRow['ip'], '1.2.3.0/24');
  assert.equal(again.legacyRow['network'], 'tcp');

  // 远程规则集 id：旧内核只认 geosite:/geoip: 前缀，裸 id 不能写进 domains
  const remoteRule = T.parseRules([{ id: 'r9', type: 'rule_set', payload: 'remote_1' }])[0];
  const remoteRow = T.toRawRows([remoteRule])[0];
  assert.equal(remoteRow['domains'], undefined);
  assert.equal(remoteRow['ruleSetRefs'], 'remote_1');
  const remoteAgain = T.parseRules([remoteRow])[0];
  assert.equal(remoteAgain.type, 'rule_set');
  assert.equal(remoteAgain.payload, 'remote_1');
  console.log('PASS toRawRows keeps legacy AND conditions and routes remote ids to ruleSetRefs');
}

// 8. validate: empty_payload
{
  const rules = T.parseRules([
    { id: 'e1', type: 'domain_suffix', payload: '  ', outbound: 'proxy' },
    { id: 'e2', type: 'domain_suffix', payload: 'a.com', outbound: 'proxy' }
  ]);
  const result = T.validateRules(rules, []);
  assert.ok(codes(result.errors).includes('empty_payload'));
  assert.equal(result.errors.filter((i) => i.code === 'empty_payload').length, 1);
  console.log('PASS validate flags empty_payload');
}

// 9. validate: invalid_cidr (IPv4 前缀越界/坏地址/IPv6 非法与合法)
{
  const mk = (id, payload) => ({ id, type: 'ip_cidr', payload, outbound: 'proxy' });
  const rules = T.parseRules([
    mk('c1', '999.1.1.1/33'),
    mk('c2', 'fe80::gg/64'),
    mk('c3', '10.0.0.0/8'),
    mk('c4', '2001:db8::/32'),
    mk('c5', '1.2.3.4') // 裸 IP 合法
  ]);
  const result = T.validateRules(rules, []);
  const cidrIssues = result.errors.filter((i) => i.code === 'invalid_cidr');
  assert.equal(cidrIssues.length, 2);
  assert.deepEqual(plain(cidrIssues.map((i) => i.ruleId).sort()), ['c1', 'c2']);
  console.log('PASS validate invalid_cidr for IPv4/IPv6 (valid ones untouched, bare IP ok)');
}

// 10. validate: invalid_port (1-65535, 区间方向/开区间)
{
  const mk = (id, payload) => ({ id, type: 'port', payload, outbound: 'proxy' });
  const bad = T.validateRules(T.parseRules([
    mk('p1', '0'),
    mk('p2', '65536'),
    mk('p3', 'abc'),
    mk('p4', '3000:2000'),
    mk('p5', '70000:80000')
  ]), []);
  assert.equal(bad.errors.filter((i) => i.code === 'invalid_port').length, 5);
  const good = T.validateRules(T.parseRules([
    mk('p6', '80'),
    mk('p7', '1000:2000'),
    mk('p8', ':443'),
    mk('p9', '8080:')
  ]), []);
  assert.equal(good.errors.filter((i) => i.code === 'invalid_port').length, 0);
  console.log('PASS validate invalid_port (1-65535, range direction, open ranges)');
}

// 11. validate: invalid_regex 捕获异常；正规则保留大小写
{
  const rules = T.parseRules([
    { id: 'g1', type: 'domain_regex', payload: '[a-', outbound: 'proxy' },
    { id: 'g2', type: 'domain_regex', payload: '^X.*$', outbound: 'proxy' }
  ]);
  assert.equal(rules[1].payload, '^X.*$'); // 正则不转小写
  const result = T.validateRules(rules, []);
  const issues = result.errors.filter((i) => i.code === 'invalid_regex');
  assert.equal(issues.length, 1);
  assert.equal(issues[0].ruleId, 'g1');
  assert.ok(issues[0].detail.length > '正则不可编译：'.length); // 带原生错误信息
  console.log('PASS validate invalid_regex catches compile error and keeps regex case');
}

// 12. validate: dup_rule (同 type+payload+outbound，规范化后比较)
{
  const rules = T.parseRules([
    { id: 'd1', type: 'domain_suffix', payload: 'a.com', outbound: 'proxy' },
    { id: 'd2', type: 'domain_suffix', payload: 'A.COM', outbound: 'proxy' },
    { id: 'd3', type: 'domain_suffix', payload: 'a.com', outbound: 'direct' }
  ]);
  const result = T.validateRules(rules, []);
  const dups = result.errors.filter((i) => i.code === 'dup_rule');
  assert.equal(dups.length, 1);
  assert.equal(dups[0].ruleId, 'd2');
  assert.ok(dups[0].detail.includes('d1'));
  console.log('PASS validate dup_rule (normalized payload, outbound must also match)');
}

// 13. validate: geosite_missing (rule_set / geoip 引用)
{
  const rules = T.parseRules([
    { id: 's1', type: 'rule_set', payload: 'geosite:cn', outbound: 'direct' },
    { id: 's2', type: 'rule_set', payload: 'remote_9', outbound: 'proxy' },
    { id: 's3', type: 'geoip', payload: 'cn', outbound: 'direct' },
    { id: 's4', type: 'geoip', payload: 'private', outbound: 'direct' }
  ]);
  const missing = T.validateRules(rules, ['geosite:cn']);
  const issues = missing.errors.filter((i) => i.code === 'geosite_missing');
  assert.deepEqual(plain(issues.map((i) => i.ruleId).sort()), ['s2', 's3']);
  const ok = T.validateRules(rules.slice(0, 1).concat(rules.slice(3)), ['geosite:cn', 'geoip:cn']);
  assert.equal(ok.errors.filter((i) => i.code === 'geosite_missing').length, 0);
  console.log('PASS validate geosite_missing for rule_set/geoip references (private exempt)');
}

// 14. detectOverlap: suffix 包含 / keyword 子串 / IPv4 网段包含 / 不同类不报
{
  const mk = (id, payload) => ({ id, type: 'domain_suffix', payload, outbound: 'proxy' });
  const suffix = T.detectOverlap(T.parseRules([mk('w1', 'a.com'), mk('w2', 'sub.a.com')]));
  assert.equal(suffix.length, 1);
  assert.equal(suffix[0].ruleId, 'w2');
  assert.ok(suffix[0].detail.includes('w1'));
  assert.equal(suffix[0].code, 'overlap');

  const identical = T.detectOverlap(T.parseRules([mk('i1', 'a.com'), mk('i2', 'a.com')]));
  assert.equal(identical.length, 1); // 相同值只报一次

  const kw = T.detectOverlap(T.parseRules([
    { id: 'k1', type: 'domain_keyword', payload: 'google', outbound: 'proxy' },
    { id: 'k2', type: 'domain_keyword', payload: 'googleapis', outbound: 'proxy' }
  ]));
  assert.equal(kw.length, 1);
  assert.equal(kw[0].ruleId, 'k2');

  const ip = T.detectOverlap(T.parseRules([
    { id: 'n1', type: 'ip_cidr', payload: '10.0.0.0/8', outbound: 'proxy' },
    { id: 'n2', type: 'ip_cidr', payload: '10.1.0.0/16', outbound: 'proxy' },
    { id: 'n3', type: 'ip_cidr', payload: '192.168.0.0/16', outbound: 'proxy' },
    { id: 'n4', type: 'geoip', payload: 'cn', outbound: 'proxy' }
  ]));
  assert.equal(ip.length, 1);
  assert.equal(ip[0].ruleId, 'n2');

  const none = T.detectOverlap(T.parseRules([mk('x1', 'a.com'), mk('x2', 'b.com')]));
  assert.equal(none.length, 0);
  console.log('PASS detectOverlap: suffix containment, keyword substring, IPv4 CIDR, dedupe');
}

// 15. compileManifest: 排除禁用/unsupported/package，排序，规范化，hash 稳定
{
  const rows = [
    { id: 'm1', type: 'domain_suffix', payload: ' B.COM , b.com, A.com ', outbound: 'proxy', enabled: true },
    { id: 'm2', type: 'domain_suffix', payload: 'c.com', outbound: 'proxy', enabled: false },
    { id: 'm3', type: 'domain_suffix', payload: 'd.com', outbound: 'proxy', enabled: true, unsupportedOnPlatform: true },
    { id: 'm4', type: 'package', payload: 'com.x', outbound: 'proxy', enabled: true },
    { id: 'm5', type: 'ip_cidr', payload: '10.0.0.0/8', outbound: 'direct', enabled: true }
  ];
  const rules = T.parseRules(rows);
  rules[0].order = 2;
  rules[4].order = 1;
  const manifest = T.compileManifest(rules);
  assert.equal(manifest.items.length, 2);
  assert.deepEqual(plain(manifest.items.map((i) => i.ruleId)), ['m5', 'm1']); // 按 order
  assert.equal(manifest.items[1].payload, 'b.com,a.com'); // 小写+去重+保序
  assert.equal(manifest.generatedAt > 0, true);
  assert.ok(/^[0-9a-f]{8}$/.test(manifest.hash));

  const stable = T.compileManifest(rules);
  assert.equal(stable.hash, manifest.hash); // 稳定
  rules[0].payload = 'z.com';
  const changed = T.compileManifest(rules);
  assert.notEqual(changed.hash, manifest.hash); // 敏感
  console.log('PASS compileManifest excludes disabled/unsupported/package, sorts by order, stable hash');
}

// 16. toKernelItems: 字段名与 ConfigBuilder.buildCustomRule 同口径
{
  const rules = T.parseRules([
    { id: 'f1', type: 'domain', payload: 'a.com', outbound: 'proxy' },
    { id: 'f2', type: 'domain_suffix', payload: 'b.com', outbound: 'proxy' },
    { id: 'f3', type: 'domain_keyword', payload: 'kw', outbound: 'proxy' },
    { id: 'f4', type: 'domain_regex', payload: '^X.*$', outbound: 'proxy' },
    { id: 'f5', type: 'ip_cidr', payload: '10.0.0.0/8', outbound: 'direct' },
    { id: 'f6', type: 'geoip', payload: 'private', outbound: 'direct' },
    { id: 'f7', type: 'rule_set', payload: 'geosite:cn', outbound: 'direct' },
    { id: 'f8', type: 'port', payload: '80,1000:2000', outbound: 'proxy' },
    { id: 'f9', type: 'network', payload: 'TCP', outbound: 'proxy' },
    { id: 'f10', type: 'domain_suffix', payload: 'blocked.com', outbound: 'block' }
  ]);
  const items = T.toKernelItems(T.compileManifest(rules));
  const byId = {};
  items.forEach((it, idx) => { byId[rules[idx].id] = it; });
  assert.deepEqual(plain(byId['f1']['domain']), ['a.com']);
  assert.deepEqual(plain(byId['f2']['domain_suffix']), ['b.com']);
  assert.deepEqual(plain(byId['f3']['domain_keyword']), ['kw']);
  assert.deepEqual(plain(byId['f4']['domain_regex']), ['^X.*$']);
  assert.deepEqual(plain(byId['f5']['ip_cidr']), ['10.0.0.0/8']);
  assert.equal(byId['f5']['outbound'], 'direct');
  assert.equal(byId['f6']['ip_is_private'], true);
  assert.equal(byId['f6']['rule_set'], undefined);
  assert.deepEqual(plain(byId['f7']['rule_set']), ['geosite:cn']);
  assert.deepEqual(plain(byId['f8']['port']), [80]);
  assert.deepEqual(plain(byId['f8']['port_range']), ['1000:2000']);
  assert.equal(byId['f9']['network'], 'tcp');
  assert.equal(byId['f10']['action'], 'reject');
  assert.equal(byId['f10']['outbound'], undefined);
  console.log('PASS toKernelItems matches ConfigBuilder field names (domain…port_range, reject→action)');
}

// 17. toKernelItems: 旧 AND 条件合并进同一条内核规则(不放宽匹配范围)
{
  const rule = T.parseRules([{
    domains: 'a.com', ip: '1.2.3.0/24', port: '80', network: 'tcp',
    protocol: 'tls', source: '192.168.0.0/16', outbound: 'proxy'
  }])[0];
  const items = T.toKernelItems(T.compileManifest([rule]));
  assert.equal(items.length, 1);
  const item = items[0];
  assert.deepEqual(plain(item['domain_suffix']), ['a.com']);
  assert.deepEqual(plain(item['ip_cidr']), ['1.2.3.0/24']);
  assert.deepEqual(plain(item['port']), [80]);
  assert.equal(item['network'], 'tcp');
  assert.deepEqual(plain(item['protocol']), ['tls']);
  assert.deepEqual(plain(item['source_ip_cidr']), ['192.168.0.0/16']);
  assert.equal(item['outbound'], 'proxy');
  console.log('PASS toKernelItems keeps legacy AND conditions in one kernel rule (no broadening)');
}

// 18. normalizePayload 各分支
{
  assert.equal(T.normalizePayload('domain_suffix', ' A.Com , b.com,a.com '), 'a.com,b.com');
  assert.equal(T.normalizePayload('domain_regex', ' ^X.*$ , ^Y$ '), '^X.*$,^Y$'); // 保留大小写
  assert.equal(T.normalizePayload('ip_cidr', ' 10.0.0.0/8 ,  2001:DB8::/32 '), '10.0.0.0/8,2001:db8::/32');
  assert.equal(T.normalizePayload('port', '0080, 0100:0200'), '80,100:200');
  assert.equal(T.normalizePayload('network', ' TCP '), 'tcp');
  assert.equal(T.normalizePayload('rule_set', ' GeoSite:CN '), 'geosite:cn');
  assert.equal(T.normalizePayload('process_name', ' com.A , com.A'), 'com.A');
  console.log('PASS normalizePayload trims/dedupes/lowercases by type, regex case preserved');
}

// 19. DNS 投影校验
{
  const directRule = T.parseRules([{ id: 'q1', type: 'domain_suffix', payload: 'a.com', outbound: 'direct' }])[0];
  const proxyRule = T.parseRules([{ id: 'q2', type: 'domain_suffix', payload: 'b.com', outbound: 'proxy' }])[0];
  const base = { dnsRouting: true, fakeDns: false, directDns: 'tls://223.5.5.5', remoteDns: 'https://1.1.1.1/dns-query' };

  // A. 直连 DNS 用域名 → 自举回环警告
  const loop = T.validateDnsProjection([directRule], Object.assign({}, base, { directDns: 'https://dns.google/dns-query' }));
  assert.equal(loop.filter((i) => i.code === 'dns_loop_risk').length, 1);
  assert.equal(loop[0].ruleId, '');
  assert.ok(loop[0].detail.includes('1223-1226'));
  const noLoop = T.validateDnsProjection([directRule], base);
  assert.equal(noLoop.filter((i) => i.code === 'dns_loop_risk').length, 0);

  // B. dnsRouting=false：直连规则的域名仍走 remote(如实提示)
  const off = T.validateDnsProjection([directRule, proxyRule], Object.assign({}, base, { dnsRouting: false }));
  const offIssues = off.filter((i) => i.code === 'dns_routing_off');
  assert.equal(offIssues.length, 1); // 只对直连规则提示
  assert.equal(offIssues[0].ruleId, 'q1');
  assert.ok(offIssues[0].detail.includes('938'));

  // C. 有 DNS 无法表达的条件 → DNS 规则更宽
  const broadRule = T.parseRules([{
    id: 'q3', domains: 'c.com', port: '443', network: 'tcp', outbound: 'proxy'
  }])[0];
  const broad = T.validateDnsProjection([broadRule], base);
  const broadIssues = broad.filter((i) => i.code === 'dns_projection_broader');
  assert.equal(broadIssues.length, 1);
  assert.equal(broadIssues[0].ruleId, 'q3');
  assert.ok(broadIssues[0].detail.includes('938-1016'));

  // D. 纯 IP 条件规则没有 DNS 投影
  const ipRule = T.parseRules([{ id: 'q4', type: 'ip_cidr', payload: '10.0.0.0/8', outbound: 'direct' }])[0];
  const missing = T.validateDnsProjection([ipRule], base);
  assert.equal(missing.filter((i) => i.code === 'dns_projection_missing').length, 1);

  // 干净规则：无问题
  const clean = T.validateDnsProjection([directRule, proxyRule], base);
  assert.equal(clean.length, 0);
  console.log('PASS DNS projection: loop risk / routing off / broader / missing, clean rule silent');
}

// 20. legacyHandlingOptions + newRuleId
{
  assert.deepEqual(plain(T.legacyHandlingOptions()), ['pause', 'convert', 'delete']);
  const ids = new Set();
  for (let i = 0; i < 200; i++) {
    ids.add(T.newRuleId('domain_suffix'));
  }
  assert.equal(ids.size, 200);
  ids.forEach((id) => assert.ok(id.startsWith('rule_')));
  console.log('PASS legacyHandlingOptions pause/convert/delete; newRuleId unique 200/200');
}

// 21. validateRules: legacyCount 统计待处理旧规则
{
  const rules = T.parseRules([
    { id: 'l1', type: 'package', payload: 'com.a', outbound: 'proxy' },
    { id: 'l2', type: 'domain_suffix', payload: 'a.com', outbound: 'proxy', unsupportedOnPlatform: true },
    { id: 'l3', type: 'domain_suffix', payload: 'b.com', outbound: 'proxy' }
  ]);
  const result = T.validateRules(rules, []);
  assert.equal(result.legacyCount, 2);
  assert.equal(result.errors.filter((i) => i.code === 'empty_payload').length, 0); // 旧规则不刷错误
  console.log('PASS validateRules counts legacy package/unsupported rules separately');
}

console.log('\nALL routing-rules checks passed');
