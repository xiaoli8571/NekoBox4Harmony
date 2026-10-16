// Regression guard for the 2026-10-14 report "URL Test 失败: HTTP 401".
//
// Store.loadSettings auto-generates clashApiSecret when it is empty, and
// ConfigBuilder writes it into experimental.clash_api.secret -> the core's clash
// API always requires `Authorization: Bearer <secret>`. The URL Test path
// (/proxies/proxy/delay) was the one caller that hand-rolled its request without
// that header, so the core answered 401 and the toast showed exactly that.
//
// These assertions execute the real production functions against a fake
// @ohos.net.http boundary, so dropping the header again fails the suite.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
function load(file, imports={}) {
 const source=fs.readFileSync(path.join(root,file),'utf8');
 const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 const exports={};
 vm.runInNewContext(js,{exports,require:n=>{if(!(n in imports)) throw Error(n);return imports[n];}});
 return exports;
}
// Fake http boundary: records the outgoing request so the header can be inspected.
function makeHttp(reply) {
 const seen = { url: '', opts: null, destroyed: 0 };
 const http = {
  RequestMethod: { GET: 'GET', PUT: 'PUT', DELETE: 'DELETE' },
  HttpDataType: { STRING: 'string' },
  createHttp: () => ({
   request: async (url, opts) => { seen.url = url; seen.opts = opts; return reply; },
   destroy: () => { seen.destroyed++; }
  })
 };
 return { http, seen };
}
const auth = load('entry/src/main/ets/utils/ClashAuth.ets');
// 1. header construction
assert.equal('Authorization' in auth.clashApiHeaders(''), false,
 'an empty secret must not emit an Authorization header (no-auth installs keep working)');
assert.equal(auth.clashApiHeaders('s3cret')['Authorization'], 'Bearer s3cret');
console.log('PASS clashApiHeaders emits Bearer only when a secret exists');
// 2. the 401 message must point at the cause, other codes stay plain
const hint = auth.clashApiErrorMessage(401, 'URL Test 失败');
assert.ok(hint.startsWith('URL Test 失败: HTTP 401'), 'message still leads with what failed');
assert.ok(hint.includes('密钥'), '401 message must name the secret/port as the suspect');
assert.equal(auth.clashApiErrorMessage(500, 'URL Test 失败'), 'URL Test 失败: HTTP 500');
console.log('PASS 401/403 carry an actionable hint while other statuses stay verbatim');

(async () => {
 // 3. the URL Test path sends the secret and parses the delay
 const ok = makeHttp({ responseCode: 200, result: '{"delay":42}' });
 const clash = load('entry/src/main/ets/utils/ClashApi.ets', {
  '@ohos.net.http': { default: ok.http },
  './TrafficStats': { CLASH_API_PORT: 19290 },
  './ClashAuth': auth
 });
 const delay = await clash.fetchCurrentProxyDelay(1000, 19290,
  'https://www.gstatic.com/generate_204', 's3cret');
 assert.equal(delay, 42);
 assert.equal(ok.seen.opts.header['Authorization'], 'Bearer s3cret',
  'URL Test must authenticate, otherwise the core answers 401');
 assert.equal(ok.seen.url, 'http://127.0.0.1:19290/proxies/proxy/delay'
  + '?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=1000');
 assert.equal(ok.seen.destroyed, 1, 'http client must be released');
 console.log('PASS URL Test authenticates and returns the core delay');

 // 4. the exact reported failure stays diagnosable
 const denied = makeHttp({ responseCode: 401, result: '' });
 const clash401 = load('entry/src/main/ets/utils/ClashApi.ets', {
  '@ohos.net.http': { default: denied.http },
  './TrafficStats': { CLASH_API_PORT: 19290 },
  './ClashAuth': auth
 });
 await assert.rejects(() => clash401.fetchCurrentProxyDelay(1000, 19290, 'https://x/y', 's3cret'),
  (e) => e.message.includes('HTTP 401') && e.message.includes('密钥'));
 console.log('PASS a 401 surfaces with the auth hint instead of a bare status code');

 // 5. no-secret installs still send no Authorization header
 const anon = makeHttp({ responseCode: 200, result: '{"delay":7}' });
 const clashAnon = load('entry/src/main/ets/utils/ClashApi.ets', {
  '@ohos.net.http': { default: anon.http },
  './TrafficStats': { CLASH_API_PORT: 19290 },
  './ClashAuth': auth
 });
 assert.equal(await clashAnon.fetchCurrentProxyDelay(1000, 19290, 'https://x/y', ''), 7);
 assert.equal('Authorization' in anon.seen.opts.header, false);
 console.log('PASS empty secret keeps the legacy unauthenticated request');

 // 6. selector hot switch keeps both headers
 const put = makeHttp({ responseCode: 204, result: '' });
 const clashPut = load('entry/src/main/ets/utils/ClashApi.ets', {
  '@ohos.net.http': { default: put.http },
  './TrafficStats': { CLASH_API_PORT: 19290 },
  './ClashAuth': auth
 });
 assert.equal(await clashPut.selectProxy('proxy', 'node-a', 19290, 's3cret'), true);
 assert.equal(put.seen.opts.method, 'PUT');
 assert.equal(put.seen.opts.header['Authorization'], 'Bearer s3cret');
 assert.equal(put.seen.opts.header['Content-Type'], 'application/json');
 console.log('PASS selector hot switch sends auth + content-type');

 // 7. traffic polling (same boundary, different consumer) authenticates too
 const traffic = makeHttp({ responseCode: 200, result: '{"uploadTotal":11,"downloadTotal":22}' });
 const stats = load('entry/src/main/ets/utils/TrafficStats.ets', {
  '@ohos.net.http': { default: traffic.http },
  './ClashAuth': auth
 });
 // vm-realm objects fail assert.deepEqual ("same structure but not reference-equal"), compare serialized
 assert.equal(JSON.stringify(await stats.fetchTrafficTotals(19290, 's3cret')),
  JSON.stringify({ up: 11, down: 22 }));
 assert.equal(traffic.seen.opts.header['Authorization'], 'Bearer s3cret');
 const trafficDenied = makeHttp({ responseCode: 401, result: '' });
 const statsDenied = load('entry/src/main/ets/utils/TrafficStats.ets', {
  '@ohos.net.http': { default: trafficDenied.http },
  './ClashAuth': auth
 });
 assert.equal(await statsDenied.fetchTrafficTotals(19290, 's3cret'), null,
  'traffic polling degrades to null, it must not throw');
 console.log('PASS traffic polling authenticates and degrades safely on 401');
 console.log('ALL CLASH-AUTH TESTS PASSED');
})().catch((e) => { console.error('FAIL', e && e.message ? e.message : e); process.exit(1); });
