// ClashApi client tests (P4/W15, plan §9.2/§9.4).
// Transport is injected; the default @ohos.net.http boundary is stubbed like
// tests/clash-auth.cjs so headers/paths/bodies are asserted on real code paths.
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

const auth = load('entry/src/main/ets/utils/ClashAuth.ets');

// Fake @ohos.net.http boundary: records url/opts, can reply or throw.
function makeHttp(behavior) {
  const seen = { url: '', opts: null, destroyed: 0 };
  const http = {
    RequestMethod: { GET: 'GET', PUT: 'PUT', POST: 'POST', DELETE: 'DELETE' },
    HttpDataType: { STRING: 'string' },
    createHttp: () => ({
      request: async (url, opts) => {
        seen.url = url;
        seen.opts = opts;
        if (typeof behavior === 'function') {
          return behavior(url, opts);
        }
        if (behavior instanceof Error) {
          throw behavior;
        }
        return behavior;
      },
      destroy: () => { seen.destroyed++; }
    })
  };
  return { http, seen };
}

const api = load('entry/src/main/ets/core/ClashApi.ets', {
  '@ohos.net.http': { default: makeHttp({ responseCode: 200, result: '{}' }).http },
  '../utils/ClashAuth': auth
});

const cfg = (over = {}) => Object.assign({ port: 19290, secret: 's3cret', timeoutMs: 5000 }, over);

(async () => {
  // 1. Bearer header construction (empty secret → no header)
  assert.deepEqual(Object.keys(api.buildRequestHeaders(cfg()))[0], 'Authorization');
  assert.equal(api.buildRequestHeaders(cfg())['Authorization'], 'Bearer s3cret');
  assert.equal('Authorization' in api.buildRequestHeaders(cfg({ secret: '' })), false);
  console.log('PASS buildRequestHeaders: Bearer only when secret exists');

  // 2. availability: 200 → available
  const calls = [];
  const stub = () => async (p, m, b, c) => { calls.push({ p, m, b, c }); return { status: 200, body: '{"version":"1.14.0"}' }; };
  const client = new api.ClashApi(stub());
  const avail = await client.checkAvailability(cfg());
  assert.equal(avail.available, true);
  assert.equal(avail.reason, '');
  assert.equal(calls[0].p, '/version');
  assert.equal(calls[0].m, 'GET');
  assert.equal(calls[0].b, null);
  console.log('PASS checkAvailability ok: GET /version, no body');

  // 3. availability: 401/403 → unauthorized, 500 → http_error
  assert.equal((await new api.ClashApi(async () => ({ status: 401, body: '' })).checkAvailability(cfg())).reason, 'unauthorized');
  assert.equal((await new api.ClashApi(async () => ({ status: 403, body: '' })).checkAvailability(cfg())).reason, 'unauthorized');
  assert.equal((await new api.ClashApi(async () => ({ status: 500, body: '' })).checkAvailability(cfg())).reason, 'http_error');
  console.log('PASS checkAvailability maps 401/403→unauthorized, 500→http_error');

  // 4. availability: transport failures → timeout / refused (no thrown exception)
  assert.equal((await new api.ClashApi(async () => ({ status: 0, errorKind: 'timeout' })).checkAvailability(cfg())).reason, 'timeout');
  assert.equal((await new api.ClashApi(async () => ({ status: 0, errorKind: 'refused' })).checkAvailability(cfg())).reason, 'refused');
  assert.equal((await new api.ClashApi(async () => { throw new Error('connect failed 2300007'); }).checkAvailability(cfg())).reason, 'refused');
  assert.equal((await new api.ClashApi(async () => { throw new Error('2300028 timeout'); }).checkAvailability(cfg())).reason, 'timeout');
  console.log('PASS checkAvailability maps transport errorKind/throw → timeout/refused');

  // 5. availability: port<=0 is "disabled" and never touches transport
  let touched = 0;
  const disabledClient = new api.ClashApi(async () => { touched++; return { status: 200, body: '' }; });
  const disabled = await disabledClient.checkAvailability(cfg({ port: 0 }));
  assert.equal(disabled.available, false);
  assert.equal(disabled.reason, 'disabled');
  assert.equal(touched, 0);
  console.log('PASS checkAvailability port<=0 → disabled without HTTP call');

  // 6. getProxies parses {"proxies": {...}} incl. group now/all and synthetic GLOBAL
  const proxiesBody = JSON.stringify({
    proxies: {
      GLOBAL: { type: 'Fallback', name: 'GLOBAL', now: 'proxy', all: ['proxy'] },
      proxy: { type: 'Selector', name: 'proxy', now: 'profile-a', all: ['profile-a', 'profile-b'] },
      'profile-a': { type: 'Shadowsocks', name: 'profile-a', udp: true }
    }
  });
  const proxies = await new api.ClashApi(async () => ({ status: 200, body: proxiesBody })).getProxies(cfg());
  assert.equal(proxies.ok, true);
  assert.equal(proxies.reason, '');
  assert.equal(proxies.proxies.size, 3);
  const group = proxies.proxies.get('proxy');
  assert.equal(group.type, 'Selector');
  assert.equal(group.now, 'profile-a');
  assert.deepEqual(JSON.parse(JSON.stringify(group.all)), ['profile-a', 'profile-b']);
  const node = proxies.proxies.get('profile-a');
  assert.equal(node.now, '');
  assert.deepEqual(JSON.parse(JSON.stringify(node.all)), []);
  console.log('PASS getProxies parses tag/type/now/all (nodes have no now/all)');

  // 7. getProxies failures: 401 / 500 / bad JSON / missing wrapper
  assert.equal((await new api.ClashApi(async () => ({ status: 401, body: '' })).getProxies(cfg())).reason, 'unauthorized');
  assert.equal((await new api.ClashApi(async () => ({ status: 500, body: '' })).getProxies(cfg())).reason, 'http_error');
  assert.equal((await new api.ClashApi(async () => ({ status: 200, body: 'not json' })).getProxies(cfg())).reason, 'parse_error');
  assert.equal((await new api.ClashApi(async () => ({ status: 200, body: '{"x":1}' })).getProxies(cfg())).reason, 'parse_error');
  console.log('PASS getProxies reports unauthorized/http_error/parse_error without throwing');

  // 8. getProxy hits /proxies/<encoded tag>, kernel returns a bare object
  let lastPath = '';
  const one = await new api.ClashApi(async (p) => {
    lastPath = p;
    return { status: 200, body: JSON.stringify({ type: 'Selector', name: 'proxy', now: 'profile-a', all: ['profile-a'] }) };
  }).getProxy(cfg(), 'proxy');
  assert.equal(lastPath, '/proxies/proxy');
  assert.equal(one.ok, true);
  assert.equal(one.proxies.get('proxy').now, 'profile-a');
  // tag needs URL encoding (group ids may contain spaces/unicode)
  let encPath = '';
  await new api.ClashApi(async (p) => { encPath = p; return { status: 200, body: '{"name":"a b"}' }; }).getProxy(cfg(), 'a b');
  assert.equal(encPath, '/proxies/a%20b');
  assert.equal((await new api.ClashApi(async () => ({ status: 404, body: '' })).getProxy(cfg(), 'nope')).reason, 'not_found');
  console.log('PASS getProxy encodes tag and maps 404→not_found');

  // 9. selectProxy: PUT path + exact JSON body {"name": member}
  let put = { p: '', m: '', b: '', c: null };
  const select = await new api.ClashApi(async (p, m, b, c) => {
    put = { p, m, b, c };
    return { status: 204, body: '' };
  }).selectProxy(cfg({ timeoutMs: 3000 }), 'proxy', 'profile-a');
  assert.equal(put.p, '/proxies/proxy');
  assert.equal(put.m, 'PUT');
  assert.equal(put.b, '{"name":"profile-a"}');
  assert.equal(put.c.timeoutMs, 3000);
  assert.equal(select.ok, true);
  assert.equal(select.reason, '');
  console.log('PASS selectProxy sends PUT /proxies/<group> with {"name":<member>}');

  // 10. selectProxy status mapping: 200/204 ok, 400 rejected, 401 unauthorized, 500 http_error
  const sel = (status) => new api.ClashApi(async () => ({ status, body: '' }));
  assert.equal((await sel(200).selectProxy(cfg(), 'proxy', 'm')).ok, true);
  assert.equal((await sel(204).selectProxy(cfg(), 'proxy', 'm')).ok, true);
  assert.equal((await sel(400).selectProxy(cfg(), 'proxy', 'm')).reason, 'rejected');
  assert.equal((await sel(401).selectProxy(cfg(), 'proxy', 'm')).reason, 'unauthorized');
  assert.equal((await sel(500).selectProxy(cfg(), 'proxy', 'm')).reason, 'http_error');
  assert.equal((await new api.ClashApi(async () => ({ status: 0, errorKind: 'timeout' })).selectProxy(cfg(), 'proxy', 'm')).reason, 'timeout');
  assert.equal((await new api.ClashApi(async () => ({ status: 0, errorKind: 'refused' })).selectProxy(cfg(), 'proxy', 'm')).reason, 'refused');
  console.log('PASS selectProxy maps 204/200 ok, 400 rejected, 401/500/timeout/refused honestly');

  // 11. selectProxy must NOT verify implicitly (only one PUT call; §9.2-3 verify is the caller's job)
  let selectCalls = 0;
  const noVerify = await new api.ClashApi(async (p, m) => { selectCalls++; return { status: 204, body: '' }; })
    .selectProxy(cfg(), 'proxy', 'profile-a');
  assert.equal(noVerify.ok, true);
  assert.equal(selectCalls, 1);
  assert.equal('now' in noVerify, false);
  console.log('PASS selectProxy returns only ok/reason (verification stays with verifyNow)');

  // 12. defaultTransport: real request shape via the @ohos.net.http boundary
  const okHttp = makeHttp({ responseCode: 200, result: '{"hello":"clash"}' });
  const realApi = load('entry/src/main/ets/core/ClashApi.ets', {
    '@ohos.net.http': { default: okHttp.http }, '../utils/ClashAuth': auth
  });
  const resp = await realApi.ClashApi.defaultTransport('/proxies', 'GET', null, cfg());
  assert.equal(resp.status, 200);
  assert.equal(resp.body, '{"hello":"clash"}');
  assert.equal(okHttp.seen.url, 'http://127.0.0.1:19290/proxies');
  assert.equal(okHttp.seen.opts.method, 'GET');
  assert.equal(okHttp.seen.opts.header['Authorization'], 'Bearer s3cret');
  assert.equal(okHttp.seen.opts.readTimeout, 5000);
  assert.equal(okHttp.seen.destroyed, 1);
  console.log('PASS defaultTransport hits 127.0.0.1:<port>, sends Bearer, destroys client');

  // 13. defaultTransport: JSON content type + body for PUT; no Authorization when secret empty
  const putHttp = makeHttp({ responseCode: 204, result: '' });
  const putApi = load('entry/src/main/ets/core/ClashApi.ets', {
    '@ohos.net.http': { default: putHttp.http }, '../utils/ClashAuth': auth
  });
  await putApi.ClashApi.defaultTransport('/proxies/proxy', 'PUT', '{"name":"m"}', cfg({ secret: '' }));
  assert.equal(putHttp.seen.opts.method, 'PUT');
  assert.equal(putHttp.seen.opts.extraData, '{"name":"m"}');
  assert.equal(putHttp.seen.opts.header['Content-Type'], 'application/json');
  assert.equal('Authorization' in putHttp.seen.opts.header, false);
  console.log('PASS defaultTransport sets Content-Type for PUT and omits Authorization on empty secret');

  // 14. defaultTransport: connect errors become errorKind, never thrown
  const timeoutHttp = makeHttp(new Error('timeout 2300028'));
  const timeoutApi = load('entry/src/main/ets/core/ClashApi.ets', {
    '@ohos.net.http': { default: timeoutHttp.http }, '../utils/ClashAuth': auth
  });
  const timeoutResp = await timeoutApi.ClashApi.defaultTransport('/proxies', 'GET', null, cfg());
  assert.equal(timeoutResp.status, 0);
  assert.equal(timeoutResp.errorKind, 'timeout');
  const refusedHttp = makeHttp(new Error('connect failed 2300007'));
  const refusedApi = load('entry/src/main/ets/core/ClashApi.ets', {
    '@ohos.net.http': { default: refusedHttp.http }, '../utils/ClashAuth': auth
  });
  assert.equal((await refusedApi.ClashApi.defaultTransport('/proxies', 'GET', null, cfg())).errorKind, 'refused');
  console.log('PASS defaultTransport classifies timeout/refused into errorKind');

  console.log('\nALL clash-api checks passed');
})();
