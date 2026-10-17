// 订阅解析回归(2026-09-27)——用户实测「导入订阅解析不到节点」。
// 用与 tests/parity-config.cjs 相同的 SDK transpiler 跑生产 ETS 源码,不复制被测算法。
// 覆盖两个已确认的解析缺口:
//   A. proxy-providers:provider-only 的 Clash 订阅(顶层无 proxies,只有 proxy-providers
//      远程节点集)此前直接判为「不支持」→ 0 节点;v2rayN/Clash.Meta/Hiddify 都能导入。
//   B. base64 硬折行:机场订阅正文常含换行/空格,Base64Helper 严格解码整段失败。
// provider 端点用本地 HTTP server 桩(不发真实网络请求到机场)。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const http = require('node:http');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

function load(file, imports = {}, extraGlobals = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const exports = {};
  const ctx = Object.assign({
    exports, module: { exports },
    require: name => {
      if (!(name in imports)) throw new Error('Unexpected import: ' + name);
      return imports[name];
    }
  }, extraGlobals);
  vm.runInNewContext(js, ctx, { filename: file });
  return exports;
}

// ArkTS 运行时桩:Base64Helper / TextDecoder 用 Node 原生实现。
// 注意 transpileModule 会把 `import util from '@ohos.util'` 编译成
// util_1.default.X —— 所以必须挂 default 导出,否则 util 是 undefined。
const utilStub = {
  Base64Helper: class {
    decodeSync(s) { return new Uint8Array(Buffer.from(s, 'base64')); }
    encodeToStringSync(b) { return Buffer.from(b).toString('base64'); }
  },
  TextDecoder: { create: () => ({ decodeToString: a => Buffer.from(a).toString('utf8') }) },
  TextEncoder: class { encodeInto(s) { return new Uint8Array(Buffer.from(s, 'utf8')); } }
};
utilStub.default = utilStub;

// LinkParser 本就 import Subscription(解析单出站 JSON),而 Subscription 不 import
// LinkParser —— 这是项目原有的单向依赖,不是本轮引入的循环。加载 LinkParser 时
// 需要一个 Subscription 代理,里面用到的那两个函数在调用时才求值。
let subRef = null;
const subProxy = {
  parseSingBoxConfig: (...a) => subRef.parseSingBoxConfig(...a),
  parseSingleOutboundJson: (...a) => subRef.parseSingleOutboundJson(...a)
};

const model = load('entry/src/main/ets/model/Profile.ets');
const yaml = load('entry/src/main/ets/utils/ClashYaml.ets');
const link = load('entry/src/main/ets/utils/LinkParser.ets', {
  '@ohos.util': utilStub, '../model/Profile': model, './Subscription': subProxy
});

// Subscription 需要真正的 http 客户端才能拉 provider:把 @ohos.net.http 接到 Node http。
// 同样需要 default 导出(import http from '@ohos.net.http' -> http_1.default)。
const nodeHttp = {
  createHttp: () => makeNodeHttp(),
  RequestMethod: { GET: 'GET', POST: 'POST', PUT: 'PUT', DELETE: 'DELETE' },
  HttpDataType: { STRING: 0, ARRAY_BUFFER: 1, OBJECT: 2 },
  HttpProtocol: { HTTP1_1: 'HTTP/1.1', HTTP2: 'h2' }
};
nodeHttp.default = nodeHttp;
function makeNodeHttp() {
  return {
    async request(url, opts = {}) {
      return new Promise((resolve, reject) => {
        const headers = opts.header || {};
        const u = new URL(url);
        const req = http.request({
          hostname: u.hostname, port: u.port, path: u.pathname + u.search,
          method: opts.method || 'GET', headers
        }, res => {
          const chunks = [];
          res.on('data', c => chunks.push(c));
          res.on('end', () => {
            const body = Buffer.concat(chunks);
            resolve({
              responseCode: res.statusCode,
              header: res.headers,
              result: opts.expectDataType === 2 /* ARRAY_BUFFER */ ? body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength) : body.toString('utf8')
            });
          });
        });
        req.on('error', reject);
        req.end();
      });
    },
    destroy() {}
  };
}

const sub = load('entry/src/main/ets/utils/Subscription.ets', {
  '@ohos.net.http': nodeHttp,
  '../model/Profile': model,
  './ClashYaml': yaml
});

subRef = sub;

// 依赖方向必须是单向的:ClashProviders -> {Subscription, LinkParser, ClashYaml}。
// 若把 provider 逻辑塞回 Subscription.ets,就会形成
// Subscription -> LinkParser -> Subscription 循环导入。
const providers = load('entry/src/main/ets/utils/ClashProviders.ets', {
  '../model/Profile': model,
  './ClashYaml': yaml,
  './Subscription': sub,
  './LinkParser': link
});

let count = 0;
function test(name, run) {
  return Promise.resolve().then(run).then(() => { count++; console.log('PASS ' + name); },
    e => { console.log('FAIL ' + name + ' — ' + e.message); process.exitCode = 1; });
}

// ---- 本地 provider 端点 ----
let server, baseUrl;
function serve(body) {
  return new Promise(resolve => {
    const handler = (req, res) => { res.writeHead(200, { 'Content-Type': 'text/yaml' }); res.end(body); };
    if (server) { server.removeAllListeners('request'); }
    else {
      server = http.createServer();
      server.listen(0, '127.0.0.1', () => { baseUrl = `http://127.0.0.1:${server.address().port}/provider.yaml`; });
    }
    server.on('request', handler);
    setTimeout(resolve, 120);
  });
}

const PROVIDER_YAML = `proxies:
  - name: HK-01
    type: ss
    server: hk.example.com
    port: 8388
    cipher: aes-256-gcm
    password: secret1
  - name: JP-01
    type: trojan
    server: jp.example.com
    port: 443
    password: secret2
    sni: jp.example.com
  - name: HK-01
    type: vless
    server: dup.example.com
    port: 443
    uuid: 11111111-1111-1111-1111-111111111111
`;

(async () => {
  await serve(PROVIDER_YAML);
  const providerUrl = baseUrl;

  // 先单独验证 Node http shim:否则 provider 用例的失败会被误读成产品缺陷
  await test('node http shim can fetch a provider body', async () => {
    const body = await sub.fetchTextUrl(providerUrl, false, '');
    assert.ok(/proxies:/.test(body), body.substring(0, 80));
  });

  // ===== A. proxy-providers =====

  await test('provider-only yaml is recognized as Clash YAML', () => {
    const y = `proxy-providers:\n  airport:\n    type: http\n    url: ${providerUrl}\n`;
    assert.equal(sub.looksLikeClashYaml(y), true);
  });

  await test('provider-only yaml without provider following yields clash_provider_only', () => {
    const y = `proxy-providers:\n  airport:\n    type: http\n    url: ${providerUrl}\n`;
    const r = sub.parseClashProxies(y);
    assert.equal(r.note, 'clash_provider_only');
    assert.equal(r.profiles.length, 0);
  });

  let fetched;
  await test('provider nodes are fetched and parsed', async () => {
    const y = `proxy-providers:\n  airport:\n    type: http\n    url: ${providerUrl}\n`;
    fetched = await providers.parseClashProxiesWithProviders(y, false, '');
    assert.ok(fetched.profiles.length >= 3,
      `expected 3 provider nodes, got ${fetched.profiles.length}: ` +
      JSON.stringify(fetched.profiles.map(p => p.name)) + ' note=' + fetched.note);
    assert.equal(fetched.note, '', fetched.note);
  });

  await test('provider node types are preserved', () => {
    // vm 跨上下文数组不能用 deepEqual(原型不同),逐项比。
    const t = fetched.profiles.map(p => p.type);
    assert.equal(t.length, 3);
    assert.equal(t[0], 'shadowsocks');
    assert.equal(t[1], 'trojan');
    assert.equal(t[2], 'vless');
  });

  await test('provider node fields survive parsing (port/cipher/password)', () => {
    const p = fetched.profiles[0];
    assert.equal(p.serverPort, 8388);
    assert.equal(p.method, 'aes-256-gcm');
    assert.equal(p.password, 'secret1');
    assert.equal(fetched.profiles[1].sni, 'jp.example.com');
  });

  await test('duplicate node names across providers get a suffix', () => {
    assert.equal(fetched.profiles[2].name, 'HK-01-airport');
  });

  await test('inline proxies keep the original path (no provider fetch)', async () => {
    const inline = `proxies:\n  - name: INLINE\n    type: ss\n    server: a.com\n    port: 443\n    cipher: aes-256-gcm\n    password: p\n`;
    const r = await providers.parseClashProxiesWithProviders(inline, false, '');
    assert.equal(r.profiles.length, 1);
    assert.equal(r.profiles[0].name, 'INLINE');
    assert.equal(r.note, '');
  });

  await test('unreachable provider reports a diagnosable note', async () => {
    const dead = `proxy-providers:\n  airport:\n    type: http\n    url: http://127.0.0.1:1/nope.yaml\n`;
    const r = await providers.parseClashProxiesWithProviders(dead, false, '');
    assert.equal(r.note, 'clash_provider_all_failed', r.note);
  });

  await test('base64 share link inside a provider is imported', async () => {
    // SIP002:ss://base64(method:password)@host:port#name
    const userinfo = Buffer.from('aes-256-gcm:secret').toString('base64');
    const ssLink = 'ss://' + userinfo + '@1.2.3.4:8388#Link-Node';
    await serve(ssLink);
    const y = `proxy-providers:\n  airport:\n    type: http\n    url: ${baseUrl}\n`;
    const r = await providers.parseClashProxiesWithProviders(y, false, '');
    assert.equal(r.profiles.length, 1, JSON.stringify(r.profiles.map(p => p.name)));
    assert.equal(r.profiles[0].name, 'Link-Node');
  });

  await test('provider-only subscription end-to-end produces nodes (was 0 before)', async () => {
    await serve(PROVIDER_YAML);
    const y = `proxy-providers:\n  airport:\n    type: http\n    url: ${baseUrl}\n`;
    const r = await providers.parseClashProxiesWithProviders(y, false, '');
    assert.ok(r.profiles.length >= 3, 'provider subscription must yield nodes');
  });

  // ===== B. base64 硬折行 / 空白容错 =====
  const userinfo = Buffer.from('aes-256-gcm:secret').toString('base64');
  const nodeLine = 'ss://' + userinfo + '@hk.example.com:8388#%F0%9F%87%AD%F0%9F%87%B0%20HK';
  const b64 = Buffer.from(nodeLine, 'utf8').toString('base64');

  await test('baseline base64 subscription still parses', () => {
    assert.equal(link.parseShareText(b64).length, 1);
  });

  await test('base64 with hard newlines decodes', () => {
    const r = link.parseShareText(b64.replace(/(.{60})/g, '$1\n'));
    assert.equal(r.length, 1);
    assert.equal(r[0].server, 'hk.example.com');
    assert.equal(r[0].serverPort, 8388);
  });

  await test('base64 with embedded spaces decodes', () => {
    assert.equal(link.parseShareText(b64.replace(/(.{40})/g, '$1  ')).length, 1);
  });

  await test('base64 without padding decodes', () => {
    assert.equal(link.parseShareText(b64.replace(/=+$/, '')).length, 1);
  });

  await test('emoji node name survives UTF-8 round trip', () => {
    const r = link.parseShareText(b64.replace(/(.{60})/g, '$1\n'));
    assert.ok(r[0].name.includes('HK'), r[0].name);
  });


  // ===== C. B5: base64 包裹的 WireGuard .conf / sing-box JSON 不该被丢弃 =====
  await test('base64-wrapped WireGuard .conf is imported (was discarded)', () => {
    const conf = [
      '[Interface]',
      'PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBiYXNlNjQga2V5MDAwMDA=',
      'Address = 10.7.0.2/32',
      '',
      '[Peer]',
      'PublicKey = cHVibGljIGtleSBoZXJlIDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=',
      'Endpoint = 1.2.3.4:51820',
      'AllowedIPs = 0.0.0.0/0'
    ].join('\n');
    const r = link.parseShareText(Buffer.from(conf, 'utf8').toString('base64'));
    assert.equal(r.length, 1, 'expected the WG endpoint to be parsed, got ' + r.length);
    assert.equal(r[0].type, 'wireguard');
    assert.equal(r[0].server, '1.2.3.4');
  });

  await test('base64-wrapped sing-box JSON is imported', () => {
    const cfg = JSON.stringify({
      outbounds: [{
        type: 'trojan', tag: 'TJ', server: 't.example.com', server_port: 443, password: 'pw'
      }]
    });
    const r = link.parseShareText(Buffer.from(cfg, 'utf8').toString('base64'));
    assert.equal(r.length, 1, 'expected the outbound to be parsed, got ' + r.length);
    assert.equal(r[0].name, 'TJ');
  });

  await test('plain text that is not base64 is not mangled into nodes', () => {
    // 机场的「不支持本站协议」提示:不得因为宽松解码被当成节点
    const r = link.parseShareText('您的客户端不支持本站协议,请使用 Clash 客户端');
    assert.equal(r.length, 0, 'plain text must not produce profiles, got ' + JSON.stringify(r.map(p => p.name)));
  });

  // ===== D. B6: 分享链接跳过项必须上报 =====
  await test('unsupported share links are reported as skipped with hints', () => {
    const body = [
      'ssr://c29tZS1zc3ItcGF5bG9hZA',
      'ssr://YW5vdGhlci1zc3ItcGF5bG9hZA',
      'trojan://pw@ok.example.com:443#GOOD'
    ].join('\n');
    const report = { skipped: 0, names: [] };
    const r = link.parseShareText(body, report);
    assert.equal(r.length, 1, 'only the trojan line should parse');
    assert.equal(r[0].name, 'GOOD');
    assert.equal(report.skipped, 2, 'both ssr lines must be counted, got ' + report.skipped);
    assert.equal(report.names.length, 2);
    assert.ok(report.names.every(n => n.indexOf('ssr://') === 0), report.names.join(','));
  });

  await test('no-report callers keep the old signature (back-compat)', () => {
    const r = link.parseShareText('ssr://c29tZQ');
    assert.equal(r.length, 0);
  });

  // ===== E. D1/D2: sing-box JSON 的 transport / multiplex / tls =====
  await test('sing-box JSON keeps transport (was dropped -> bare TCP)', () => {
    const cfg = JSON.stringify({
      outbounds: [{
        type: 'vless', tag: 'WS', server: 'w.example.com', server_port: 443,
        uuid: '11111111-1111-1111-1111-111111111111',
        transport: { type: 'ws', path: '/ray', headers: { Host: 'cdn.example.com' } }
      }]
    });
    const r = sub.parseSingBoxConfig(cfg);
    assert.equal(r.profiles.length, 1, JSON.stringify(r.profiles));
    const p = r.profiles[0];
    assert.equal(p.transport, 'ws', 'transport lost: ' + p.transport);
    assert.equal(p.path, '/ray', 'path lost: ' + p.path);
    assert.equal(p.host, 'cdn.example.com', 'host lost: ' + p.host);
  });

  await test('sing-box JSON keeps multiplex and packet_encoding', () => {
    const cfg = JSON.stringify({
      outbounds: [{
        type: 'vless', tag: 'MUX', server: 'm.example.com', server_port: 443,
        uuid: '11111111-1111-1111-1111-111111111111',
        multiplex: { enabled: true, protocol: 'smux', max_streams: 4 },
        packet_encoding: 'xudp'
      }]
    });
    const p = sub.parseSingBoxConfig(cfg).profiles[0];
    assert.equal(p.mux, true, 'mux lost');
    assert.equal(p.muxProtocol, 'smux');
    assert.equal(p.muxMaxStreams, 4);
    assert.equal(p.packetEncoding, 'xudp');
  });

  await test('sing-box JSON legacy network/ws_path fields are honoured', () => {
    const cfg = JSON.stringify({
      outbounds: [{
        type: 'vmess', tag: 'LEG', server: 'l.example.com', server_port: 443,
        uuid: '11111111-1111-1111-1111-111111111111',
        network: 'ws', ws_path: '/old', ws_headers: { Host: 'old.example.com' }
      }]
    });
    const p = sub.parseSingBoxConfig(cfg).profiles[0];
    assert.equal(p.transport, 'ws', 'legacy network lost: ' + p.transport);
    assert.equal(p.path, '/old', 'legacy ws_path lost: ' + p.path);
  });

  await test('TLS-by-design protocols are TLS even when the JSON omits tls', () => {
    for (const [type, extra] of [
      ['trojan', { password: 'pw' }],
      ['hysteria2', { password: 'pw' }],
      ['tuic', { uuid: '11111111-1111-1111-1111-111111111111', password: 'pw' }],
      ['anytls', { password: 'pw' }],
      ['shadowtls', { password: 'pw', version: 3 }]
    ]) {
      const cfg = JSON.stringify({
        outbounds: [Object.assign({ type, tag: type, server: 'x.example.com', server_port: 443 }, extra)]
      });
      const r = sub.parseSingBoxConfig(cfg);
      assert.equal(r.profiles.length, 1, type + ' should parse');
      assert.equal(r.profiles[0].tls, true, type + ' must default to TLS, got ' + r.profiles[0].tls);
    }
  });

  // ===== F. D3/D4: Clash 侧 hysteria 带宽与端口跳跃 =====
  await test('hysteria v1 bandwidth with units is parsed (was NaN -> 0)', () => {
    const yaml = 'proxies:\n  - name: HY1\n    type: hysteria\n    server: h.example.com\n    port: 443\n    auth-str: pw\n    up: "30 Mbps"\n    down: "200 Mbps"\n';
    const r = sub.parseClashProxies(yaml);
    assert.equal(r.profiles.length, 1);
    assert.equal(r.profiles[0].upMbps, 30, 'up lost: ' + r.profiles[0].upMbps);
    assert.equal(r.profiles[0].downMbps, 200, 'down lost: ' + r.profiles[0].downMbps);
  });

  await test('hysteria2 port hopping as a YAML sequence is parsed (was dropped)', () => {
    const yaml = 'proxies:\n  - name: HY2\n    type: hysteria2\n    server: h.example.com\n    port: 443\n    password: pw\n    ports:\n      - 1000-2000\n      - 3000\n    hop-interval: 25\n';
    const r = sub.parseClashProxies(yaml);
    assert.equal(r.profiles.length, 1, JSON.stringify(r.profiles));
    const p = r.profiles[0];
    assert.ok(p.serverPorts && p.serverPorts.indexOf('1000-2000') >= 0,
      'serverPorts lost: ' + JSON.stringify(p.serverPorts));
    assert.ok(p.serverPorts.indexOf('3000') >= 0, 'second port lost: ' + p.serverPorts);
    assert.equal(p.hopInterval, 25);
  });

  await test('hysteria2 port hopping as a scalar still works', () => {
    const yaml = 'proxies:\n  - name: HY2S\n    type: hysteria2\n    server: h.example.com\n    port: 443\n    password: pw\n    ports: "1000-2000,3000"\n';
    const p = sub.parseClashProxies(yaml).profiles[0];
    assert.ok(p.serverPorts.indexOf('1000-2000') >= 0, p.serverPorts);
  });

  // ===== G. E1/D5: YAML 指令行与 sing-box JSON 结构判定 =====
  await test('YAML directive line no longer truncates the document', () => {
    const yaml = '%YAML 1.2\n---\nproxies:\n  - name: D\n    type: ss\n    server: d.example.com\n    port: 8388\n    cipher: aes-256-gcm\n    password: p\n';
    const r = sub.parseClashProxies(yaml);
    assert.equal(r.profiles.length, 1, 'got ' + r.profiles.length + ' note=' + r.note);
    assert.equal(r.profiles[0].name, 'D');
  });

  await test('endpoints-only sing-box config is recognized', () => {
    assert.equal(sub.looksLikeSingBoxJson('{"endpoints":[{"type":"wireguard","tag":"WG"}]}'), true);
  });

  await test('arbitrary JSON mentioning outbounds is not misread as sing-box', () => {
    assert.equal(sub.looksLikeSingBoxJson('{"note":"see outbounds doc"}'), false);
  });


  // ===== H. D6: Clash proxy-groups -> ProfileGroup =====
  await test('clash proxy-groups are parsed with members', () => {
    const yaml = [
      'proxies:',
      '  - name: A',
      '    type: ss',
      '    server: a.example.com',
      '    port: 8388',
      '    cipher: aes-256-gcm',
      '    password: p',
      '  - name: B',
      '    type: ss',
      '    server: b.example.com',
      '    port: 8389',
      '    cipher: aes-256-gcm',
      '    password: p',
      'proxy-groups:',
      '  - name: HK',
      '    type: select',
      '    proxies:',
      '      - A',
      '      - B',
      '      - DIRECT',
      '  - name: AUTO',
      '    type: url-test',
      '    proxies:',
      '      - A',
      ''
    ].join('\n');
    const gs = providers.parseClashGroups(yaml);
    assert.equal(gs.length, 2, 'groups=' + gs.length);
    assert.equal(gs[0].name, 'HK');
    assert.equal(gs[0].type, 'select');
    assert.equal(gs[0].members.length, 2, 'DIRECT must be dropped, got ' + gs[0].members.length);
    assert.equal(gs[1].type, 'url-test');
  });

  await test('groups with no real members are dropped', () => {
    const yaml = 'proxies: []\nproxy-groups:\n  - name: EMPTY\n    type: select\n    proxies:\n      - DIRECT\n      - REJECT\n';
    assert.equal(providers.parseClashGroups(yaml).length, 0);
  });

  await test('unsupported group types are skipped', () => {
    const yaml = 'proxies: []\nproxy-groups:\n  - name: RELAY\n    type: relay\n    proxies:\n      - DIRECT\n  - name: FALLBACK\n    type: fallback\n    proxies:\n      - DIRECT\n';
    assert.equal(providers.parseClashGroups(yaml).length, 0);
  });

  await test('groups do not break node parsing (independent of proxies)', () => {
    const yaml = [
      'proxies:',
      '  - name: A',
      '    type: trojan',
      '    server: a.example.com',
      '    port: 443',
      '    password: p',
      'proxy-groups:',
      '  - name: G',
      '    type: select',
      '    proxies: [A]',
      ''
    ].join('\n');
    const r = sub.parseClashProxies(yaml);
    assert.equal(r.profiles.length, 1, 'node parse must be unaffected by proxy-groups');
    assert.equal(r.profiles[0].name, 'A');
  });

  // ===== I. E4/E5: query 里的 '+' 是字面字符,不是空格 =====
  await test('plus sign in a password is preserved (was turned into a space)', () => {
    // trojan 口令含 '+';旧实现 replace(/\+/g,'%20') 会把它变成空格。
    // 期望:字面 '+' 保持 '+',%2B(转义的 '+')解码为 '+' —— 两者都不该变成空格。
    const shareLink = 'trojan://pa+ss%2Bword@t.example.com:443#T';
    const r = link.parseShareText(shareLink);
    assert.equal(r.length, 1, JSON.stringify(r.map(p => p.name)));
    assert.equal(r[0].password, 'pa+ss+word', 'got ' + JSON.stringify(r[0].password));
    assert.ok(r[0].password.indexOf(' ') < 0, 'password must not contain a space');
  });

  await test('plus sign in a node name is preserved', () => {
    const shareLink = 'trojan://pw@t.example.com:443#HK%2B01';
    const r = link.parseShareText(shareLink);
    assert.equal(r.length, 1);
    assert.equal(r[0].name, 'HK+01', 'got ' + JSON.stringify(r[0].name));
  });

  await test('percent-encoded query values still decode', () => {
    const shareLink = 'trojan://pw@t.example.com:443?sni=a%2Eb%2Ecom#T';
    const r = link.parseShareText(shareLink);
    assert.equal(r.length, 1);
    assert.equal(r[0].sni, 'a.b.com', 'got ' + r[0].sni);
  });


  await test('clash yaml type socks5 imports as socks (clash convention)', () => {
    const y = 'proxies:\n  - name: S5\n    type: socks5\n    server: s.example.com\n    port: 1080\n    username: u\n    password: p\n';
    const r = sub.parseClashProxies(y);
    assert.equal(r.profiles.length, 1, 'got ' + r.profiles.length + ' note=' + r.note);
    assert.equal(r.profiles[0].type, 'socks', 'got ' + r.profiles[0].type);
    assert.equal(r.profiles[0].username, 'u');
    assert.equal(r.profiles[0].password, 'p');
  });

  await test('clash yaml type socks (legacy spelling) still imports', () => {
    const y = 'proxies:\n  - name: S4\n    type: socks\n    server: s.example.com\n    port: 1080\n';
    const r = sub.parseClashProxies(y);
    assert.equal(r.profiles.length, 1, 'got ' + r.profiles.length + ' note=' + r.note);
    assert.equal(r.profiles[0].type, 'socks');
  });

  await test('socks5 share link imports with credentials', () => {
    const r = link.parseShareText('socks5://u5:p5@s.example.com:1180#S5Link');
    assert.equal(r.length, 1);
    assert.equal(r[0].type, 'socks', 'got ' + r[0].type);
    assert.equal(r[0].username, 'u5');
    assert.equal(r[0].password, 'p5');
  });

  if (server) server.close();
  console.log(`\n${count} subscription checks passed`);
})();