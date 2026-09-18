// CORE-03 IPv6 four-mode parity tests. Run: node tests/ipv6-modes.cjs
// These load the real production ETS modules; failures here are release
// blockers until the model/config/vpn layers all speak the same modes.
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
let count = 0;
function test(name, run) { run(); count++; console.log('PASS ' + name); }
function config(settings = {}) {
  const p = new model.Profile(); p.server = 'example.invalid';
  const s = Object.assign(new model.AppSettings(), settings);
  return JSON.parse(builder.buildCoreConfig(p, s, '', '', '/test/site.srs', '/test/ip.srs', []));
}
const IPV6_MODES = ['disable', 'enable', 'prefer', 'only'];

test('model exposes ipv6Mode (legacy empty derives from boolean) and validates', () => {
  const s = new model.AppSettings();
  assert.equal(s.ipv6Mode, '');
  assert.equal(builder.effectiveIpv6Mode(s), 'disable'); // legacy false → disable
  const legacyOn = new model.AppSettings(); legacyOn.ipv6 = true;
  assert.equal(builder.effectiveIpv6Mode(legacyOn), 'enable');
  // Actual export/import validation runs in ipv6-backup.cjs below.
});
test('mode DISABLE: v4-only core TUN, ipv4_only DNS defaults', () => {
  const c = config({ ipv6Mode: 'disable' });
  assert.deepEqual(c.inbounds.find(x => x.tag === 'tun-in').address, ['172.19.0.1/30']);
  assert.equal(c.dns.strategy, 'ipv4_only');
});
test('mode ENABLE: dual stack TUN, prefer_ipv4 DNS defaults', () => {
  const c = config({ ipv6Mode: 'enable' });
  assert.deepEqual(c.inbounds.find(x => x.tag === 'tun-in').address, ['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
  assert.equal(c.dns.strategy, 'prefer_ipv4');
});
test('mode PREFER: dual stack TUN, prefer_ipv6 DNS defaults', () => {
  const c = config({ ipv6Mode: 'prefer' });
  assert.deepEqual(c.inbounds.find(x => x.tag === 'tun-in').address, ['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
  assert.equal(c.dns.strategy, 'prefer_ipv6');
});
test('mode ONLY: v6-only core TUN, ipv6_only DNS defaults', () => {
  const c = config({ ipv6Mode: 'only' });
  assert.deepEqual(c.inbounds.find(x => x.tag === 'tun-in').address, ['fdfe:dcba:9876::1/126']);
  assert.equal(c.dns.strategy, 'ipv6_only');
});
test('explicit user DNS strategies beat mode defaults', () => {
  const c = config({ ipv6Mode: 'prefer', remoteDnsStrategy: 'ipv4_only' });
  assert.equal(c.dns.strategy, 'ipv4_only');
});
test('legacy boolean ipv6 maps: true=enable, false=disable, never persisted conflicts', () => {
  const c1 = config({ ipv6: true });
  assert.equal(c1.dns.strategy, 'prefer_ipv4');
  const c2 = config({ ipv6: false });
  assert.equal(c2.dns.strategy, 'ipv4_only');
});
test('settings page offers the four Android modes', () => {
  const page = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/SettingsPage.ets'), 'utf8');
  assert.match(page, /ipv6Mode/);
  assert.match(page, /IPV6_MODES/); // four-mode selector present
  const base = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/resources/base/element/string.json'), 'utf8')).string;
  assert.ok(base.some(x => x.name === 'ipv6_modes'));
  assert.ok(base.some(x => x.name === 'ipv6_mode_prefer'));
  const en = JSON.parse(fs.readFileSync(path.join(root, 'entry/src/main/resources/en_US/element/string.json'), 'utf8')).string;
  assert.ok(en.some(x => x.name === 'ipv6_modes'));
});
test('platform VPN keeps IPv4 in every mode, IPv6 only when not DISABLE', () => {
  // Android VpnService.kt:100-124 keeps the IPv4 address, DNS and default route
  // unconditionally; the IPv6 address/route appear for any non-DISABLE mode.
  const vpn = fs.readFileSync(path.join(root, 'entry/src/main/ets/vpnext/VpnExtAbility.ets'), 'utf8');
  assert.match(vpn, /linkAddr\('172\.19\.0\.1', 30\)/);
  assert.match(vpn, /const dualStackOrV6Only = ipv6Mode !== 'disable'/);
  assert.match(vpn, /isIPv4Accepted: true/);
  assert.match(vpn, /isIPv6Accepted: dualStackOrV6Only/);
  // The platform layer must not repeat the core-only "ONLY drops IPv4" rule.
  assert.ok(!/ipv6Mode !== 'only'/.test(vpn), 'platform VPN must not drop IPv4 for ONLY');
  assert.ok(!/addresses\.push\(linkAddr\('172\.19\.0\.1'/.test(vpn), 'IPv4 address must be unconditional');
});
console.log(`${count} checks passed (host production-code tests; not device/UI verification).`);
require('./ipv6-backup.cjs');
