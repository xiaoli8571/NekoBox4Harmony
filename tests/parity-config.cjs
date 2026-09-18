// Runs production ETS model/config code using the installed SDK transpiler.
// No network, VPN, device or file-store operations are performed.
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
  vm.runInNewContext(js, { exports, require: name => {
    if (!(name in imports)) throw new Error('Unexpected import: ' + name);
    return imports[name];
  } }, { filename: file });
  return exports;
}
const model = load('entry/src/main/ets/model/Profile.ets');
const builder = load('entry/src/main/ets/core/ConfigBuilder.ets', {
  '../model/Profile': model, '../utils/TrafficStats': { CLASH_API_PORT: 9090 }, '../model/RouteRule': {}
});
const plain = value => JSON.parse(JSON.stringify(value));
const rule = fields => ({ domains: '', ip: '', source: '', port: '', sourcePort: '', network: '', protocol: '', packages: '', config: '', outbound: 'direct', enabled: true, ...fields });
let count = 0;
function test(name, run) { run(); count++; console.log('PASS ' + name); }
test('destination mixed single ports and ranges', () => assert.deepEqual(plain(builder.buildCustomRule(rule({ port: '80,443,1000:2000' }))), { port: [80,443], port_range: ['1000:2000'], outbound: 'direct' }));
test('source ranges remain ranges', () => assert.deepEqual(plain(builder.buildCustomRule(rule({ sourcePort: '53\n8000:9000' }))), { source_port: [53], source_port_range: ['8000:9000'], outbound: 'direct' }));
test('open port ranges', () => assert.deepEqual(plain(builder.buildCustomRule(rule({ port: ':1024,49152:' }))).port_range, [':1024','49152:']));
test('invalid tokens do not become valid ports', () => assert.equal(builder.buildCustomRule(rule({ port: '80oops,65536,-1,9000:8000' })), null));
test('CRLF and duplicate ports', () => assert.deepEqual(plain(builder.buildCustomRule(rule({ port: '80\r\n443,80' }))).port, [80,443]));
test('protocol list keeps HTTP and TLS within one AND rule', () => {
  const result = plain(builder.buildCustomRule(rule({ protocol: 'http, tls\r\ndns', port: '443' })));
  assert.deepEqual(result.protocol, ['http', 'tls', 'dns']);
  assert.deepEqual(result.port, [443]);
  assert.equal(result.outbound, 'direct');
});

// CORE-07: deep merge semantics from Android Util.kt:129-158.
test('rule config deep-merges nested objects and supports +key/key+ lists', () => {
  const result = plain(builder.buildCustomRule(rule({
    domains: 'full:merge.example.org',
    config: JSON.stringify({
      domain_suffix: ['kept.example.org'],
      'domain_suffix+': ['appended.example.org'],
      '+domain_suffix': ['prepended.example.org'],
      source_ip_cidr: ['10.0.0.0/8'],
      nested: { a: 1, deep: { x: 1 } }
    })
  })));
  assert.deepEqual(result.domain_suffix, ['prepended.example.org', 'kept.example.org', 'appended.example.org']);
  assert.deepEqual(result.source_ip_cidr, ['10.0.0.0/8']);
  assert.deepEqual(result.nested, { a: 1, deep: { x: 1 } });
  assert.equal(result.outbound, 'direct');
});
test('profile extra deep-merges into generated outbound subobjects', () => {
  const p = new model.Profile(); p.type = 'trojan'; p.server = 'example.invalid'; p.password = 'pw';
  p.mux = true;                                         // generator must emit a multiplex block first
  p.extra = JSON.stringify({ multiplex: { max_streams: 4, padding: false, custom: 'kept' }, server: 'override.example.org' });
  const o = plain(builder.buildOutbound(p, new model.AppSettings()));
  assert.equal(o.server, 'override.example.org');       // scalar override
  assert.equal(o.multiplex.protocol, 'h2mux');           // generated sibling field survives deep merge
  assert.equal(o.multiplex.max_streams, 4);              // extra wins inside nested object
  assert.equal(o.multiplex.padding, false);
  assert.equal(o.multiplex.custom, 'kept');              // new key from extra lands inside mux block
});
test('global custom config deep-merges preserving generated subfields', () => {
  const c = config({ globalCustomConfig: JSON.stringify({ route: { final: 'proxy' }, dns: { independent_cache: true } }) });
  assert.equal(c.route.final, 'proxy');
  assert.ok(Array.isArray(c.route.rules) && c.route.rules.length > 0); // generated rules survive
  assert.equal(c.dns.independent_cache, true);
  assert.ok(Array.isArray(c.dns.servers));
});
test('showBottomBar default and backup validation', () => {
  assert.equal(new model.AppSettings().showBottomBar, false);
  const backup = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/Backup.ets'), 'utf8');
  assert.match(backup, /'profileTrafficStatistics', 'showBottomBar'/);
});
test('StatsBar and FAB consume the persistent setting', () => {
  const index = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
  assert.match(index, /if \(this.isRunning && \(this.activeTab === 0 \|\| this.settings.showBottomBar\)\)/);
  assert.match(index, /if \(this.activeTab === 0 \|\| this.settings.showBottomBar\) \{\s*this.fabButton\(\)/);
});
test('resource keys are unique and bilingual', () => {
  const keys = locale => JSON.parse(fs.readFileSync(path.join(root, `entry/src/main/resources/${locale}/element/string.json`), 'utf8')).string.map(x => x.name);
  const base = keys('base'); const en = keys('en_US');
  assert.equal(new Set(base).size, base.length); assert.equal(new Set(en).size, en.length);
  assert.deepEqual(base.sort(), en.sort()); assert.ok(base.includes('show_bottom_bar'));
});
function config(settings = {}, rules = []) {
  const p = new model.Profile(); p.server = 'example.invalid';
  const s = Object.assign(new model.AppSettings(), settings);
  return JSON.parse(builder.buildCoreConfig(p, s, '', '', '/test/site.srs', '/test/ip.srs', rules));
}
test('user route precedes private bypass and multicast rejection', () => {
  const c = config({mode:'rule', bypassLan:true}, [rule({ip:'192.168.1.0/24',outbound:'proxy'})]);
  const rules = c.route.rules;
  const user = rules.findIndex(r => r.ip_cidr?.includes('192.168.1.0/24'));
  const lan = rules.findIndex(r => r.ip_is_private === true && r.outbound === 'direct');
  const multicast = rules.findIndex(r => r.action === 'reject' && r.ip_cidr?.includes('224.0.0.0/3'));
  assert.ok(user >= 0 && lan > user && multicast > lan, JSON.stringify(rules,null,2));
  // Android's two address fields are AND, not an invented source/destination OR.
  assert.deepEqual(rules[multicast].ip_cidr, ['224.0.0.0/3','ff00::/8']);
  assert.deepEqual(rules[multicast].source_ip_cidr, ['224.0.0.0/3','ff00::/8']);
  assert.equal(rules[multicast].outbound, undefined);
});
test('multicast rejection is independent of private bypass toggle', () => {
  const rules = config({mode:'rule',bypassLan:false}).route.rules;
  assert.ok(!rules.some(r => r.ip_is_private));
  assert.ok(rules.some(r => r.action === 'reject' && r.ip_cidr?.includes('224.0.0.0/3')));
});
test('auto DNS never reaches the core as auto', () => {
  const c = config({ remoteDnsStrategy: 'auto', directDnsStrategy: 'auto', serverDnsStrategy: 'auto' });
  assert.equal(c.dns.strategy, 'ipv4_only');
  assert.equal(c.dns.rules.find(x => x.server === 'local').strategy, 'ipv4_only');
  // Server auto is a FIXED prefer_ipv4 (Android SingBoxOptionsUtil.domainStrategy
  // "server" branch), unlike remote/direct which fall back to IPv6Mode.
  assert.equal(c.route.default_domain_resolver.strategy, 'prefer_ipv4');
});
test('server resolver stays prefer_ipv4 across every IPv6 mode', () => {
  for (const mode of ['disable', 'enable', 'prefer', 'only']) {
    assert.equal(config({ ipv6Mode: mode }).route.default_domain_resolver.strategy, 'prefer_ipv4', mode);
  }
  // An explicit server strategy is still honoured.
  assert.equal(config({ serverDnsStrategy: 'ipv6_only' }).route.default_domain_resolver.strategy, 'ipv6_only');
});
test('dual stack auto prefers IPv4', () => assert.equal(config({ ipv6: true }).dns.strategy, 'prefer_ipv4'));
test('explicit DNS choices are retained', () => {
  const c = config({ remoteDnsStrategy: 'ipv6_only', directDnsStrategy: 'prefer_ipv6', serverDnsStrategy: 'ipv4_only' });
  assert.equal(c.dns.strategy, 'ipv6_only');
  assert.equal(c.dns.rules.find(x => x.server === 'local').strategy, 'prefer_ipv6');
  assert.equal(c.route.default_domain_resolver.strategy, 'ipv4_only');
});
test('resolve precedes IP rules and follows DNS hijack', () => {
  const c = config({ resolveDestination: true }, [rule({ ip: '203.0.113.0/24' })]);
  const rules = c.route.rules; const resolve = rules.findIndex(x => x.action === 'resolve');
  assert.ok(resolve > rules.findIndex(x => x.action === 'hijack-dns'));
  assert.ok(resolve < rules.findIndex(x => x.ip_cidr));
  assert.equal(rules[resolve].strategy, 'ipv4_only');
});
test('resolve strategy follows IPv6Mode, not the remote DNS setting', () => {
  // Android genDomainStrategy(ConfigBuilder.kt:148-155) depends only on the mode.
  assert.equal(config({ resolveDestination: true, ipv6Mode: 'prefer' }).route.rules
    .find(x => x.action === 'resolve').strategy, 'prefer_ipv6');
  assert.equal(config({ resolveDestination: true, ipv6Mode: 'only' }).route.rules
    .find(x => x.action === 'resolve').strategy, 'ipv6_only');
  assert.equal(config({ resolveDestination: true, ipv6Mode: 'prefer', remoteDnsStrategy: 'ipv4_only' })
    .route.rules.find(x => x.action === 'resolve').strategy, 'prefer_ipv6');
});
test('disabled resolve emits no resolve action', () => assert.ok(!config().route.rules.some(x => x.action === 'resolve')));

// CORE-01: user geosite:/geoip: references must be paired with same-tag definitions.
function ruleWithDomains(fields) { return rule(Object.assign({ domains: fields }, {})); }
test('geosite:cn reference gets a same-tag local definition', () => {
  const c = config({}, [rule({ domains: 'geosite:cn' })]);
  const tags = c.route.rule_set.map(d => d.tag);
  assert.ok(tags.includes('geosite:cn'), `expected geosite:cn definition, got ${tags}`);
  assert.ok(c.route.rules.some(x => Array.isArray(x.rule_set) && x.rule_set.includes('geosite:cn')));
});
test('geoip:cn reference gets a same-tag local definition', () => {
  const c = config({}, [rule({ ip: 'geoip:cn' })]);
  const tags = c.route.rule_set.map(d => d.tag);
  assert.ok(tags.includes('geoip:cn'), `expected geoip:cn definition, got ${tags}`);
});
test('geosite:cn and geoip:cn map to distinct asset files', () => {
  const c = config({}, [rule({ domains: 'geosite:cn' }), rule({ ip: 'geoip:cn' })]);
  const byTag = Object.fromEntries(c.route.rule_set.map(d => [d.tag, d.path]));
  assert.notEqual(byTag['geosite:cn'], byTag['geoip:cn']);
  assert.equal(byTag['geosite:cn'], '/test/site.srs');
  assert.equal(byTag['geoip:cn'], '/test/ip.srs');
});
test('unsupported region reference is rejected, not silently dangling', () => {
  const p = new model.Profile(); p.server = 'example.invalid';
  const s = new model.AppSettings();
  assert.throws(() => builder.buildCoreConfig(p, s, '', '', '/test/site.srs', '/test/ip.srs',
    [rule({ domains: 'geosite:ir' })]), /未支持的规则集引用/);
});
test('references survive repeated builds (no stale accumulation)', () => {
  config({}, [rule({ domains: 'geosite:cn' })]);
  const c = config({}, [rule({ ip: 'geoip:cn' })]);
  const tags = c.route.rule_set.map(d => d.tag);
  assert.ok(!tags.includes('geosite:cn'), `stale geosite:cn leaked across builds: ${tags}`);
  assert.ok(tags.includes('geoip:cn'));
});
test('no geo assets means references are rejected rather than dangling', () => {
  const p = new model.Profile(); p.server = 'example.invalid';
  const s = new model.AppSettings();
  assert.throws(() => builder.buildCoreConfig(p, s, '', '', '', '',
    [rule({ domains: 'geosite:cn' })]), /未支持的规则集引用/);
});

// CORE-02: user rules must participate in DNS routing.
test('direct user rule drives its domains to the local DNS server', () => {
  const c = config({}, [rule({ domains: 'full:test.example.org', outbound: 'direct' })]);
  const dnsRule = c.dns.rules.find(x => Array.isArray(x.domain) && x.domain.includes('test.example.org'));
  assert.ok(dnsRule, 'expected a DNS rule carrying the user domain');
  assert.equal(dnsRule.server, 'local');
});
test('proxy user rule resolves through remote DNS', () => {
  const c = config({}, [rule({ domains: 'full:proxy.example.org', outbound: 'proxy' })]);
  const dnsRule = c.dns.rules.find(x => Array.isArray(x.domain) && x.domain.includes('proxy.example.org'));
  assert.ok(dnsRule, 'expected a DNS rule carrying the user domain');
  assert.equal(dnsRule.server, 'remote');
});
test('reject user rule yields NXDOMAIN predefined action', () => {
  const c = config({}, [rule({ domains: 'full:blocked.example.org', outbound: 'reject' })]);
  const dnsRule = c.dns.rules.find(x => Array.isArray(x.domain) && x.domain.includes('blocked.example.org'));
  assert.ok(dnsRule, 'expected a DNS rule carrying the user domain');
  assert.equal(dnsRule.action, 'predefined');
  assert.equal(dnsRule.rcode, 3);
});
test('FakeIP fallback is restricted to tun-in and ordered after user rules', () => {
  const c = config({ fakeDns: true }, [rule({ domains: 'full:fake.example.org', outbound: 'proxy' })]);
  const rules = c.dns.rules;
  const fallbackIdx = rules.findIndex(x => x.server === 'fake' && !Array.isArray(x.inbound) === false && x.inbound && x.inbound.includes('tun-in') && !x.domain);
  assert.ok(fallbackIdx >= 0, 'expected a tun-in FakeIP fallback rule');
  const userIdx = rules.findIndex(x => Array.isArray(x.domain) && x.domain.includes('fake.example.org'));
  assert.ok(userIdx < fallbackIdx, 'user rule must precede FakeIP fallback');
  assert.ok(rules.every(x => x.server !== 'fake' || (x.inbound && x.inbound.includes('tun-in'))), 'no fake rule may leak to mixed');
});
test('dnsRouting off removes user DNS rules', () => {
  const c = config({ dnsRouting: false }, [rule({ domains: 'full:test.example.org', outbound: 'direct' })]);
  assert.ok(!c.dns.rules.some(x => Array.isArray(x.domain) && x.domain.includes('test.example.org')));
});

// CORE-04: sniff route/override map to distinct kernel actions, mixed included.
test('sniff route mode: sniff action without override, tun and mixed covered', () => {
  const c = config({ sniffMode: 'route', mixedPort: 2080 });
  const sniff = c.route.rules.find(x => x.action === 'sniff');
  assert.ok(sniff, 'expected a sniff rule');
  assert.deepEqual(sniff.inbound.sort(), ['mixed-in', 'tun-in']);
  assert.notEqual(sniff.override_destination, true);
});
test('sniff override mode sets override_destination', () => {
  const c = config({ sniffMode: 'override', mixedPort: 2080 });
  const sniff = c.route.rules.find(x => x.action === 'sniff');
  assert.equal(sniff.override_destination, true);
  assert.deepEqual(sniff.inbound.sort(), ['mixed-in', 'tun-in']);
});
test('sniff off emits no sniff rule', () => {
  const c = config({ sniffMode: 'off' });
  assert.ok(!c.route.rules.some(x => x.action === 'sniff'));
});

// CORE-03: FakeDNS shape must match Android ConfigBuilder.kt:710-724.
test('FakeDNS always configures both ranges regardless of IPv6 mode', () => {
  for (const mode of ['disable', 'enable', 'prefer', 'only']) {
    const c = config({ fakeDns: true, ipv6Mode: mode });
    const fake = c.dns.servers.find(x => x.type === 'fakeip');
    assert.equal(fake.inet4_range, '198.18.0.0/15', mode);
    assert.equal(fake.inet6_range, 'fc00::/18', mode);
  }
});
test('FakeDNS fallback rule carries disable_cache like Android', () => {
  const c = config({ fakeDns: true });
  const fallback = c.dns.rules.find(x => x.server === 'fake' && !x.domain);
  assert.equal(fallback.disable_cache, true);
  assert.deepEqual(fallback.inbound, ['tun-in']);
});
test('no fakeip server or rule when FakeDNS is off', () => {
  const c = config({ fakeDns: false });
  assert.ok(!c.dns.servers.some(x => x.type === 'fakeip'));
  assert.ok(!c.dns.rules.some(x => x.server === 'fake'));
});
console.log(`${count} checks passed (host production-code tests; not device/UI verification).`);
