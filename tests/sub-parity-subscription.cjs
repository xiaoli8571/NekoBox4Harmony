// 订阅解析 / 更新流程与 Android NekoBoxForAndroid 1.4.2 的逐项等价回归(2026-10-23)
//
// 期望值全部从 Android 源码推导,每条断言都注明出处(文件:行):
//   app/src/main/java/io/nekohasekai/sagernet/group/RawUpdater.kt
//   app/src/main/java/io/nekohasekai/sagernet/group/GroupUpdater.kt
//   app/src/main/java/moe/matsuri/nb4a/Protocols.kt
//   app/src/main/java/io/nekohasekai/sagernet/ktx/{Formats,Nets,Utils}.kt
//   app/src/main/java/moe/matsuri/nb4a/utils/Util.kt
//   app/src/main/java/io/nekohasekai/sagernet/fmt/{hysteria,shadowsocks,trojan_go}/*.kt
//
// 跑法:cd NekoBox4Harmony; $env:DEVECO_SDK_HOME='...'; node tests/sub-parity-subscription.cjs
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
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

const utilStub = {
  Base64Helper: class {
    decodeSync(s) { return new Uint8Array(Buffer.from(s, 'base64')); }
    encodeToStringSync(b) { return Buffer.from(b).toString('base64'); }
  },
  TextDecoder: { create: () => ({ decodeToString: a => Buffer.from(a).toString('utf8') }) },
  TextEncoder: class { encodeInto(s) { return new Uint8Array(Buffer.from(s, 'utf8')); } }
};
utilStub.default = utilStub;

const httpStub = {
  createHttp: () => ({ request: async () => { throw new Error('no network in parity tests'); } }),
  RequestMethod: { GET: 'GET' },
  HttpDataType: { STRING: 0 },
  HttpProtocol: { HTTP1_1: 'HTTP/1.1' }
};
httpStub.default = httpStub;

const model = load('entry/src/main/ets/model/Profile.ets');
const yaml = load('entry/src/main/ets/utils/ClashYaml.ets');
const sub = load('entry/src/main/ets/utils/Subscription.ets', {
  '@ohos.net.http': httpStub, '@ohos.util': utilStub, '../model/Profile': model, './ClashYaml': yaml
});

// Subscriptions 侧:只需要纯函数与 listSubs(不跑 updateSubscription,避免网络/存储)
const prefs = {};
const storeStub = {
  initStore: async () => {},
  loadProfiles: async () => [],
  saveProfiles: async () => {},
  mutateProfiles: async () => {},
  loadSettings: async () => ({ subAllowInsecure: false, ipv6Mode: '' }),
  readPrefString: async (key, dflt) => (prefs[key] !== undefined ? prefs[key] : dflt),
  writePrefString: async (key, value) => { prefs[key] = value; },
  ensureGroupByName: async n => n,
  loadGroups: async () => [],
  saveGroups: async () => {},
  LogStore: { addLog: () => {} }
};
const linkStub = {
  parseShareText: () => [],
  ShareSkipReport: class {}
};
// LinkParser 的真实实现用于 WireGuard/base64 用例
const link = load('entry/src/main/ets/utils/LinkParser.ets', {
  '@ohos.util': utilStub, '../model/Profile': model,
  './Subscription': { parseSingBoxConfig: sub.parseSingBoxConfig, parseSingleOutboundJson: sub.parseSingleOutboundJson }
});
const providersStub = {
  parseClashProxiesWithProviders: async () => ({ profiles: [], skipped: 0, skippedNames: [], note: '' }),
  parseClashGroups: () => []
};
const subs = load('entry/src/main/ets/core/Subscriptions.ets', {
  '@ohos.app.ability.common': { default: {} },
  '@ohos.net.connection': { getAddressesByName: async () => [] },
  '../model/Profile': model,
  '../model/Store': storeStub,
  '../utils/Subscription': sub,
  '../utils/ClashProviders': providersStub,
  '../utils/LinkParser': linkStub,
  // W17:updateSubscription 委托 SubscriptionRepository(本套件只测纯函数,不跑事务)
  './SubscriptionRepository': {
    SubscriptionRepository: { runUpdate: async () => { throw new Error('transaction not exercised in parity tests'); } }
  }
});

let count = 0;
async function test(name, fn) {
  try {
    await fn();
    count++;
    console.log('PASS ' + name);
  } catch (e) {
    console.log('FAIL ' + name);
    console.log('     ' + (e && e.message ? e.message : e));
    process.exitCode = 1;
  }
}

function clash(yaml) {
  return sub.parseClashProxies(yaml);
}

function one(yaml) {
  const r = clash(yaml);
  assert.equal(r.profiles.length, 1, 'expected 1 profile, got ' + r.profiles.length + ' note=' + r.note);
  return r.profiles[0];
}

(async () => {
  // ===== 0. 常量 =====
  await test('default UA is Android USER_AGENT literally (Nets.kt:66, nb4a.properties:2)', () => {
    assert.equal(sub.SUB_UA, 'NekoBox/Android/1.4.2 (Prefer ClashMeta Format)');
  });

  // ===== 1. Clash: vmess (RawUpdater.kt:325-490) =====
  await test('clash vmess: uuid/alterId/cipher/tls/ws transport (RawUpdater.kt:310-460)', () => {
    const p = one(`proxies:
  - name: VM
    type: vmess
    server: vm.example.com
    port: 443
    uuid: 11111111-2222-3333-4444-555555555555
    alterId: 2
    cipher: aes-128-gcm
    tls: true
    network: ws
    ws-opts:
      path: /ray
      headers:
        Host: cdn.example.com
`);
    assert.equal(p.type, 'vmess');
    assert.equal(p.uuid, '11111111-2222-3333-4444-555555555555');
    assert.equal(p.alterId, 2);
    assert.equal(p.security, 'aes-128-gcm');
    assert.equal(p.tls, true);
    assert.equal(p.transport, 'ws');
    assert.equal(p.path, '/ray');
    assert.equal(p.host, 'cdn.example.com');
    // "Fix ent" 第 1 条:isTLS && sni 空 && host 非空非 IP → sni = host
    assert.equal(p.sni, 'cdn.example.com', 'Fix ent (RawUpdater.kt:665-667)');
  });

  await test('clash vmess: network h2 maps to http, unknown network stays default (RawUpdater.kt:386-392)', () => {
    const h2 = one(`proxies:
  - {name: H2, type: vmess, server: h2.example.com, port: 443, uuid: u, network: h2, h2-opts: {path: /h2, host: [a.example.com, b.example.com]}}
`);
    assert.equal(h2.transport, 'http');
    assert.equal(h2.path, '/h2');
    assert.equal(h2.host, 'a.example.com\nb.example.com', 'List joinToString("\\n") (RawUpdater.kt:432-435)');
    const quic = one(`proxies:
  - {name: Q, type: vmess, server: q.example.com, port: 443, uuid: u, network: quic}
`);
    // Android 只认 h2/http/ws/grpc,其它取值不写回 bean.type(默认 tcp)
    assert.equal(quic.transport, '');
  });

  // ===== 2. Clash: vless + REALITY 指纹回退链 (RawUpdater.kt:310-313,669-672) =====
  await test('clash vless: alterId=-1, xtls-rprx-vision only (RawUpdater.kt:310-313,340-346)', () => {
    const p = one(`proxies:
  - name: VL
    type: vless
    server: vl.example.com
    port: 443
    uuid: u-uuid
    flow: xtls-rprx-vision
    tls: true
    servername: sni.example.com
`);
    assert.equal(p.type, 'vless');
    assert.equal(p.alterId, -1);
    assert.equal(p.flow, 'xtls-rprx-vision');
    const other = one(`proxies:
  - {name: VL2, type: vless, server: vl2.example.com, port: 443, uuid: u, flow: something-else, tls: true}
`);
    assert.equal(other.flow, '', 'flow 不含 xtls-rprx-vision 时不写 (RawUpdater.kt:343-345)');
  });

  await test('clash REALITY: fingerprint fallback chain (RawUpdater.kt:669-672)', () => {
    const y = fp => `proxies:
  - name: R
    type: vless
    server: r.example.com
    port: 443
    uuid: u
    tls: true
    ${fp}
    reality-opts:
      public-key: PUBKEY
      short-id: abcd
`;
    // 无 global 指纹 → chrome
    const p1 = one(y(''));
    assert.equal(p1.realityPublicKey, 'PUBKEY');
    assert.equal(p1.realityShortId, 'abcd');
    assert.equal(p1.fingerprint, 'chrome');
    assert.equal(p1.tls, true, 'reality-opts 会把 security 置 tls (RawUpdater.kt:372-384)');
    // 显式 client-fingerprint 优先
    const p2 = one(y('client-fingerprint: firefox'));
    assert.equal(p2.fingerprint, 'firefox');
    // global-client-fingerprint 次之(Android 从 YAML 根读,RawUpdater.kt:241)
    const r3 = sub.parseClashProxies('global-client-fingerprint: safari\n' + y(''));
    assert.equal(r3.profiles[0].fingerprint, 'safari');
    // 没有 pubkey 时不回退指纹
    const noPub = one(`proxies:
  - {name: R2, type: vless, server: r2.example.com, port: 443, uuid: u, reality-opts: {short-id: x}}
`);
    assert.equal(noPub.fingerprint, '');
  });

  // ===== 3. Clash: trojan (RawUpdater.kt:356-363) =====
  await test('clash trojan: tls defaults on, tls:false turns it off (RawUpdater.kt:356-359)', () => {
    const on = one(`proxies:
  - {name: T, type: trojan, server: t.example.com, port: 443, password: pw, sni: t-sni.example.com}
`);
    assert.equal(on.type, 'trojan');
    assert.equal(on.password, 'pw');
    assert.equal(on.tls, true);
    assert.equal(on.sni, 't-sni.example.com');
    const off = one(`proxies:
  - {name: T2, type: trojan, server: t2.example.com, port: 443, password: pw, tls: false, sni: s}
`);
    assert.equal(off.tls, false);
  });

  // ===== 4. Clash: ss plugin 拼接 (RawUpdater.kt:272-305) =====
  await test('clash ss obfs plugin -> obfs-local;obfs=...;obfs-host=... (RawUpdater.kt:277-283)', () => {
    const p = one(`proxies:
  - name: SS
    type: ss
    server: ss.example.com
    port: 8388
    cipher: aes-256-gcm
    password: pw
    plugin: obfs
    plugin-opts:
      mode: http
      host: bing.com
`);
    assert.equal(p.type, 'shadowsocks');
    assert.equal(p.method, 'aes-256-gcm');
    assert.equal(p.ssPlugin, 'obfs-local');
    assert.equal(p.ssPluginOpts, 'obfs=http;obfs-host=bing.com');
  });

  await test('clash ss v2ray-plugin: tls only when mode=="true" (RawUpdater.kt:285-294)', () => {
    const p = one(`proxies:
  - name: SS2
    type: ss
    server: ss2.example.com
    port: 8388
    cipher: aes-256-gcm
    password: pw
    plugin: v2ray-plugin
    plugin-opts: {mode: websocket, tls: true, host: h.example.com, path: /ws}
`);
    assert.equal(p.ssPlugin, 'v2ray-plugin');
    // mode != "true" → 不追加 tls(Android 的上游怪癖,逐字复刻)
    assert.ok(!/(^|;)tls(;|$)/.test(p.ssPluginOpts), 'opts=' + p.ssPluginOpts);
    assert.ok(p.ssPluginOpts.indexOf('host=h.example.com') >= 0);
  });

  // ===== 5. Clash: anytls 键名归一化 (RawUpdater.kt:494-517) =====
  await test('clash anytls: underscores normalized to dashes (RawUpdater.kt:498)', () => {
    const p = one(`proxies:
  - name: A
    type: anytls
    server: a.example.com
    port: 443
    password: pw
    client_fingerprint: firefox
    skip_cert_verify: true
    sni: a-sni.example.com
`);
    assert.equal(p.type, 'anytls');
    assert.equal(p.password, 'pw');
    assert.equal(p.fingerprint, 'firefox');
    assert.equal(p.allowInsecure, true);
    assert.equal(p.sni, 'a-sni.example.com');
  });

  // ===== 6. Clash: hysteria1 / hysteria2 (RawUpdater.kt:519-604) =====
  await test('clash hysteria1: port->serverPorts, up/down units, auth-str (RawUpdater.kt:528-570)', () => {
    const p = one(`proxies:
  - name: H1
    type: hysteria
    server: h1.example.com
    port: 443
    auth-str: secret
    up: 30 Mbps
    down: "80"
    obfs: xplus
    alpn: [h3]
`);
    assert.equal(p.type, 'hysteria');
    assert.equal(p.password, 'secret');
    assert.equal(p.upMbps, 30, 'substringBefore(" ").toIntOrNull() (RawUpdater.kt:553-555)');
    assert.equal(p.downMbps, 80);
    assert.equal(p.serverPorts, '443');
    assert.equal(p.obfs, 'xplus');
    assert.equal(p.tls, true);
    assert.equal(p.alpn, 'h3');
  });

  await test('clash hysteria2: up/down default 0, alpn ignored (RawUpdater.kt:572-604)', () => {
    const p = one(`proxies:
  - name: H2
    type: hysteria2
    server: h2.example.com
    port: 443
    password: pw
    obfs-password: ob
    alpn: [h3, h2]
`);
    assert.equal(p.type, 'hysteria2');
    assert.equal(p.password, 'pw');
    assert.equal(p.obfs, 'ob');
    assert.equal(p.upMbps, 0, 'hysteria2 兜底是 0 而不是 hysteria1 的 100 (RawUpdater.kt:593-597)');
    assert.equal(p.downMbps, 0);
    assert.equal(p.alpn, '', 'hysteria2 分支不处理 alpn (RawUpdater.kt:572-604)');
  });

  // ===== 7. Clash: tuic ip 分支 (RawUpdater.kt:608-654) =====
  await test('clash tuic: ip overrides server and SNI is NOT backfilled (Android bug, RawUpdater.kt:649-654)', () => {
    const p = one(`proxies:
  - name: TU
    type: tuic
    server: tu.example.com
    port: 443
    uuid: u
    password: pw
    ip: 1.2.3.4
`);
    assert.equal(p.type, 'tuic');
    assert.equal(p.server, '1.2.3.4', 'ip 覆盖 serverAddress');
    assert.equal(p.sni, '', 'Android 判的是改写后的 serverAddress,永假 → 不回填 SNI');
    assert.equal(p.congestionControl, 'cubic', 'TuicBean 默认 cubic (TuicBean.java:42)');
    assert.equal(p.udpRelayMode, 'native');
  });

  await test('clash tuic: token key overrides password (RawUpdater.kt:617-624)', () => {
    const p = one(`proxies:
  - {name: TU2, type: tuic, server: tu2.example.com, port: 443, uuid: u, token: tok}
`);
    assert.equal(p.password, 'tok');
  });

  // ===== 8. Clash: 未知类型静默丢弃;鸿蒙超集类型保留 =====
  await test('unknown clash type is silently dropped and counted as skipped (no default branch)', () => {
    const r = clash(`proxies:
  - {name: X, type: ssr, server: x.example.com, port: 1234, password: p}
  - {name: OK, type: socks5, server: ok.example.com, port: 1080}
`);
    assert.equal(r.profiles.length, 1, 'only socks5 survives');
    assert.equal(r.profiles[0].name, 'OK');
    assert.equal(r.skipped, 1, 'unknown type counted in skipped');
  });

  await test('harmony superset: snell/ssh/wireguard/shadowtls clash types still import (documented deviation)', () => {
    for (const t of ['snell', 'ssh', 'shadowtls']) {
      const r = clash(`proxies:\n  - {name: ${t}, type: ${t}, server: s.example.com, port: 443, password: p}\n`);
      assert.equal(r.profiles.length, 1, t + ' should import');
    }
  });

  // ===== 9. sing-box JSON: outbounds 跳过名单 + ConfigBean 保真 (RawUpdater.kt:768-788) =====
  await test('sing-box outbounds: skip only dns/block/direct/selector/urltest (RawUpdater.kt:772-776)', () => {
    const cfg = {
      outbounds: [
        { type: 'dns', tag: 'dns-out' },
        { type: 'block', tag: 'block' },
        { type: 'direct', tag: 'direct' },
        { type: 'selector', tag: 'sel' },
        { type: 'urltest', tag: 'auto' },
        { type: '', tag: 'empty' },
        { type: 'group', tag: 'grp', outbounds: ['a'] },
        { type: 'wireguard', tag: 'wg', server: 'wg.example.com', server_port: 51820 },
        { type: 'shadowsocks', tag: 'ss', server: 'ss.example.com', server_port: 8388, method: 'aes-128-gcm', password: 'p' }
      ]
    };
    const r = sub.parseSingBoxConfig(JSON.stringify(cfg));
    const names = r.profiles.map(p => p.name).sort().join(',');
    assert.equal(names, 'grp,ss,wg', 'group/wireguard must be kept (Android keeps them as ConfigBean)');
    assert.equal(r.skipped, 6, 'dns/block/direct/selector/urltest/empty-type skipped');
  });

  await test('sing-box outbound of unknown type is kept as CUSTOM with pretty JSON (ConfigBean)', () => {
    const cfg = {
      outbounds: [
        { type: 'tuic', tag: 'TU', server: '1.2.3.4', server_port: 443, uuid: 'u', password: 'p' },
        { type: 'socks', tag: 'SK', server: 's.example.com', server_port: 1080 }
      ]
    };
    const r = sub.parseSingBoxConfig(JSON.stringify(cfg));
    const tuic = r.profiles.find(p => p.name === 'TU');
    assert.equal(tuic.type, 'tuic');
    const socks = r.profiles.find(p => p.name === 'SK');
    if (socks !== undefined) {
      // 已知类型走结构化映射;socks 不在结构化映射里 → CUSTOM 保留整份 JSON
      assert.ok(socks.type === 'socks' || socks.type === 'custom');
    }
    // 关键:无论结构化与否,原始 JSON 必须能被还原(Android ConfigBean.config)
    const custom = r.profiles.find(p => p.type === 'custom');
    if (custom !== undefined) {
      const parsed = JSON.parse(custom.customOutbound);
      assert.ok(parsed.type !== undefined, 'customOutbound 必须是完整出站 JSON');
      assert.ok(custom.customOutbound.indexOf('\n  ') > 0, 'toStringPretty() 两空格缩进');
    }
  });

  // ===== 10. sing-box JSON: 数组递归 (RawUpdater.kt:797-804) =====
  await test('JSON array recurses into each object (isJsonObjectValid)', () => {
    const arr = [
      { server: 'ss.example.com', server_port: 8388, method: 'aes-128-gcm', password: 'p', remarks: 'R1' },
      { remote_addr: 'tg.example.com', remote_port: 443, password: ['pw1', 'pw2'] },
      { outbounds: [{ type: 'shadowsocks', tag: 'inner', server: 'i.example.com', server_port: 1, method: 'aes-128-gcm', password: 'p' }] }
    ];
    const r = sub.parseSingBoxConfig(JSON.stringify(arr));
    assert.equal(r.profiles.length, 3, 'names=' + r.profiles.map(p => p.name).join(','));
    assert.equal(r.profiles[0].type, 'shadowsocks');
    assert.equal(r.profiles[0].name, 'R1');
    assert.equal(r.profiles[1].type, 'trojan', 'remote_addr → trojan-go (RawUpdater.kt:764-766)');
    assert.equal(r.profiles[2].name, 'inner');
  });

  // ===== 11. 裸 ss JSON (ShadowsocksFmt.kt:95-108) =====
  await test('bare ss JSON: remarks/plugin/plugin_opts (ShadowsocksFmt.kt:95-108)', () => {
    const r = sub.parseSingBoxConfig(JSON.stringify({
      server: 'ss.example.com', server_port: 8388, method: 'aes-128-gcm',
      password: 'pw', remarks: 'Bare', plugin: 'obfs-local', plugin_opts: 'obfs=http'
    }));
    assert.equal(r.profiles.length, 1);
    assert.equal(r.profiles[0].name, 'Bare');
    assert.equal(r.profiles[0].method, 'aes-128-gcm');
    assert.equal(r.profiles[0].ssPlugin, 'obfs-local');
    assert.equal(r.profiles[0].ssPluginOpts, 'obfs=http');
  });

  // ===== 12. 裸 hysteria1 JSON (HysteriaFmt.kt:167-203) =====
  await test('bare hysteria1 JSON: server split + auth_str + sni (HysteriaFmt.kt:171-195)', () => {
    // Android 分支 1 的进入条件是 `has("server") && (has("up") || has("up_mbps"))`
    // (RawUpdater.kt:756-758)——没有 up/up_mbps 的对象不会走 hysteria1 分支。
    const r = sub.parseSingBoxConfig(JSON.stringify({
      server: 'h.example.com:8443', up_mbps: 30, down_mbps: 80, auth_str: 'sec',
      server_name: 'sni.example.com'
    }));
    assert.equal(r.profiles.length, 1);
    const p = r.profiles[0];
    assert.equal(p.type, 'hysteria');
    assert.equal(p.server, 'h.example.com');
    assert.equal(p.serverPorts, '8443');
    assert.equal(p.serverPort, 8443);
    assert.equal(p.upMbps, 30);
    assert.equal(p.downMbps, 80);
    assert.equal(p.password, 'sec');
    assert.equal(p.sni, 'sni.example.com');
  });

  await test('bare hysteria1 JSON: up_mbps absent keeps bean defaults 10/50 (HysteriaBean.java:69-70)', () => {
    // 只有 `up`(clash 风格)存在、up_mbps 缺失 → getIntNya("up_mbps") 为 null → 默认 10/50
    const r = sub.parseSingBoxConfig(JSON.stringify({ server: 'h2.example.com:8443', up: 1 }));
    assert.equal(r.profiles.length, 1);
    assert.equal(r.profiles[0].upMbps, 10);
    assert.equal(r.profiles[0].downMbps, 50);
  });

  // ===== 13. trojan-go JSON: 死代码怪癖 (TrojanGoFmt.kt:134-162) =====
  await test('trojan-go JSON: only remote_addr/port/password take effect (optJSONArray dead code)', () => {
    const r = sub.parseSingBoxConfig(JSON.stringify({
      remote_addr: 'tg.example.com', remote_port: 8443, password: ['pw1', 'pw2'],
      ssl: { sni: 'should-be-ignored.example.com' }
    }));
    assert.equal(r.profiles.length, 1);
    const p = r.profiles[0];
    assert.equal(p.type, 'trojan');
    assert.equal(p.server, 'tg.example.com');
    assert.equal(p.serverPort, 8443);
    assert.equal(p.password, 'pw1', 'password 是 List 时取 [0] (TrojanGoFmt.kt:142-145)');
    assert.equal(p.sni, '', 'optJSONArray("ssl") 对对象返回 null → sni 未被读取(Android 原样怪癖)');
  });

  // ===== 14. WireGuard .conf (RawUpdater.kt:716-749) =====
  await test('WireGuard conf: multi Address lines joined, peer endpoint split at last colon', () => {
    const conf = `[Interface]
PrivateKey = privkey=
Address = 10.0.0.2/32
Address = fd00::2/128
MTU = 1280

[Peer]
PublicKey = pubkey=
PresharedKey = psk=
Endpoint = wg.example.com:51820
`;
    const profiles = link.parseShareText(conf);
    assert.equal(profiles.length, 1);
    assert.equal(profiles[0].type, 'wireguard');
    assert.equal(profiles[0].server, 'wg.example.com');
    assert.equal(profiles[0].serverPort, 51820);
    assert.equal(profiles[0].privateKey, 'privkey=');
    assert.equal(profiles[0].peerPublicKey, 'pubkey=');
    assert.equal(profiles[0].preSharedKey, 'psk=');
    assert.equal(profiles[0].wgMtu, 1280);
    assert.ok(profiles[0].localAddress.indexOf('10.0.0.2/32') >= 0, 'localAddress=' + profiles[0].localAddress);
    assert.ok(profiles[0].localAddress.indexOf('fd00::2/128') >= 0, '第二行 Address 不能丢');
  });

  // ===== 15. base64url (Util.kt:63-84 decodeBase64UrlSafe) =====
  await test('base64url subscription decodes - _ without padding', () => {
    const plain = 'vmess://' + Buffer.from(JSON.stringify({
      v: '2', ps: 'b64', add: 'b.example.com', port: '443', id: 'u', aid: '0', net: 'ws', path: '/p', tls: 'tls'
    })).toString('base64');
    const encoded = Buffer.from(plain).toString('base64')
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    const profiles = link.parseShareText(encoded);
    assert.equal(profiles.length, 1, 'decoded 0 profiles');
    assert.equal(profiles[0].name, 'b64');
    assert.equal(profiles[0].server, 'b.example.com');
  });

  // ===== 16. content-disposition / userinfo =====
  await test('decodeFilename handles RFC5987 (Util.kt:194-199)', () => {
    assert.equal(sub.decodeFilename(`attachment; filename*=UTF-8''%E6%9C%BA%E5%9C%BA%E4%B8%80`), '机场一');
    assert.equal(sub.decodeFilename('attachment; filename="plain.txt"'), '', '只有 filename* 形式才取');
    assert.equal(sub.decodeFilename(''), '');
  });

  await test('Subscription-Userinfo parses upload/download/total/expire', () => {
    const info = sub.parseSubUserInfo('upload=100; download=200; total=1000; expire=1700000000');
    assert.equal(info.upload, 100);
    assert.equal(info.download, 200);
    assert.equal(info.total, 1000);
    assert.equal(info.expire, 1700000000);
  });

  // ===== 17. dedup key / duplicate 名单 (Protocols.kt:20-39, RawUpdater.kt:109-131) =====
  await test('dedup key = serverAddress + serverPort + javaClass (no separator)', () => {
    const p = new model.Profile();
    p.type = 'shadowsocks';
    p.server = 'a.example.com';
    p.serverPort = 8388;
    assert.equal(sub.dedupKeyOf(p),
      'a.example.com' + '8388' + 'class io.nekohasekai.sagernet.fmt.shadowsocks.ShadowsocksBean');
    const vm = new model.Profile();
    vm.type = 'vmess';
    vm.server = 'x';
    vm.serverPort = 1;
    const vl = new model.Profile();
    vl.type = 'vless';
    vl.server = 'x';
    vl.serverPort = 1;
    assert.equal(sub.dedupKeyOf(vm), sub.dedupKeyOf(vl), 'vmess/vless 共用 VMessBean → 同键');
    const custom = new model.Profile();
    custom.type = 'custom';
    custom.customOutbound = '{"type":"x"}';
    assert.equal(sub.dedupKeyOf(custom), '{"type":"x"}', 'ConfigBean.hash = config');
  });

  await test('dedup keeps first occurrence and builds Android duplicate list', () => {
    const mk = (name, server, port) => {
      const p = new model.Profile();
      p.type = 'shadowsocks';
      p.name = name;
      p.server = server;
      p.serverPort = port;
      return p;
    };
    const out = subs.dedupProfiles([
      mk('A', 's1', 1), mk('B', 's2', 2), mk('A2', 's1', 1), mk('C', 's1', 1)
    ]);
    assert.equal(out.profiles.map(p => p.name).join(','), 'A,B', 'LinkedHashSet 保留首次出现');
    // index = 首次出现的下标(0);同一键只在第一次重复时记原始名
    assert.equal(out.duplicates.join(','), 'A (0),A2 (0),C (0)');
  });

  // ===== 18. 重名改名 (RawUpdater.kt:90-103) =====
  await test('name collision rename matches Android replace-all algorithm', () => {
    const mk = name => {
      const p = new model.Profile();
      p.name = name;
      return p;
    };
    const list = [mk('HK'), mk('HK'), mk('HK'), mk('HK (1)')];
    subs.renameCollisions(list);
    assert.deepEqual(list.map(p => p.name), ['HK', 'HK (1)', 'HK (2)', 'HK (1) (1)']);
  });

  // ===== 19. rewriteAddress / forceResolve (GroupUpdater.kt:92-120) =====
  await test('forceResolve rewriteAddress: ipv4 first by default, ipv6 first when PREFER/ONLY', () => {
    const mk = type => {
      const p = new model.Profile();
      p.type = type;
      p.server = 'example.com';
      p.sni = '';
      p.tls = true;
      return p;
    };
    const v4 = mk('trojan');
    subs.applyRewriteAddress(v4, ['2001:db8::1', '1.2.3.4'], false);
    assert.equal(v4.server, '1.2.3.4');
    assert.equal(v4.sni, 'example.com', 'TrojanBean 无条件回填 sni (GroupUpdater.kt:107-109)');
    const v6 = mk('trojan');
    subs.applyRewriteAddress(v6, ['2001:db8::1', '1.2.3.4'], true);
    assert.equal(v6.server, '2001:db8::1');
  });

  await test('forceResolve rewriteAddress: tuic/anytls get IP but no SNI backfill', () => {
    for (const t of ['tuic', 'anytls', 'socks', 'ssh']) {
      const p = new model.Profile();
      p.type = t;
      p.server = 'example.com';
      p.sni = '';
      p.tls = true;
      subs.applyRewriteAddress(p, ['9.9.9.9'], false);
      assert.equal(p.server, '9.9.9.9');
      assert.equal(p.sni, '', t + ' 不在 Android 的 when 分支里 → 不回填');
    }
  });

  await test('forceResolve rewriteAddress: vmess only when TLS, http only when isTLS', () => {
    const vm = new model.Profile();
    vm.type = 'vmess';
    vm.server = 'example.com';
    vm.tls = false;
    subs.applyRewriteAddress(vm, ['1.1.1.1'], false);
    assert.equal(vm.sni, '', 'security != tls → 不回填');
    const http = new model.Profile();
    http.type = 'http';
    http.server = 'example.com';
    http.tls = true;
    subs.applyRewriteAddress(http, ['1.1.1.1'], false);
    assert.equal(http.sni, 'example.com');
  });

  // ===== 20. 订阅默认值 / 间隔迁移 (SubscriptionBean.java:105-123) =====
  await test('SubInfo defaults: autoUpdate=false, interval=1440 minutes (SubscriptionBean.java:113-114)', async () => {
    prefs['subscriptions'] = '[]';
    const items = await subs.listSubs();
    assert.equal(items.length, 0);
    const fresh = new subs.SubInfo();
    assert.equal(fresh.autoUpdate, false);
    assert.equal(fresh.updateIntervalMinutes, 1440);
    assert.equal(fresh.deduplication, false);
    assert.equal(fresh.forceResolve, false);
    assert.equal(fresh.updateWhenConnectedOnly, false);
    assert.equal(fresh.userAgent, '');
  });

  await test('legacy hourly interval migrates to minutes (x60)', async () => {
    prefs['subscriptions'] = JSON.stringify([
      { url: 'https://a.example/sub', name: 'A', updateIntervalHours: 12, lastUpdate: 1000 },
      { url: 'https://b.example/sub', name: 'B', updateIntervalMinutes: 90, lastUpdate: 1000 }
    ]);
    const items = await subs.listSubs();
    assert.equal(items[0].updateIntervalMinutes, 720, '12h → 720min');
    assert.equal(items[0].nextUpdateAt, 1000 + 720 * 60 * 1000);
    assert.equal(items[1].updateIntervalMinutes, 90, 'minute value wins');
    assert.equal(items[1].updateIntervalHours, 2, 'legacy mirror for old backups');
  });

  await test('saveSubSettings clamps interval to >=15 minutes without upper bound', async () => {
    prefs['subscriptions'] = JSON.stringify([{ url: 'https://a.example/sub', name: 'A' }]);
    await subs.saveSubSettings('https://a.example/sub', { updateIntervalMinutes: 5 });
    let items = await subs.listSubs();
    assert.equal(items[0].updateIntervalMinutes, 15, 'SubscriptionUpdater.kt:36 下限 15');
    await subs.saveSubSettings('https://a.example/sub', { updateIntervalMinutes: 10080 });
    items = await subs.listSubs();
    assert.equal(items[0].updateIntervalMinutes, 10080, '无上限(Android 只钳下限)');
  });

  // ===== 21. 更新结果反馈 (GroupInterfaceAdapter.kt:29-82) =====
  function res(over) {
    return Object.assign({
      added: 0, removed: 0, total: 0, notModified: false, skipped: 0, skippedNames: [], note: '',
      changed: 0, addedNames: [], updatedNames: [], deletedNames: [], duplicateNames: []
    }, over);
  }

  await test('feedback: changed==0 and no duplicate -> "no difference" (GroupInterfaceAdapter.kt:38-44)', () => {
    assert.equal(subs.subUpdateHasChanges(res()), false);
  });

  await test('feedback: any change or duplicate -> "updated N proxies" (GroupInterfaceAdapter.kt:45)', () => {
    assert.equal(subs.subUpdateHasChanges(res({ changed: 3 })), true);
    assert.equal(subs.subUpdateHasChanges(res({ duplicateNames: ['D (0)'] })), true);
  });

  await test('diff body: four sections in Added/Updated/Deleted/Duplicate order with blank lines', () => {
    const text = subs.subUpdateFeedbackText(res({
      changed: 4,
      addedNames: ['A1', 'A2'],
      updatedNames: ['U1'],
      deletedNames: ['D1'],
      duplicateNames: ['DUP (0)']
    }));
    // Android 段内 \n join、段间空行、末尾 trim
    assert.equal(text,
      'Added:\nA1\nA2\n\nUpdated:\nU1\n\nDeleted:\nD1\n\nDuplicate:\nDUP (0)');
  });

  await test('diff body: empty sections are skipped at the body level (空段省略)', () => {
    const bodies = subs.subUpdateDiffBodies(['A'], [], [], []);
    assert.equal(bodies.added, 'A');
    assert.equal(bodies.updated, '');
    assert.equal(bodies.deleted, '');
    assert.equal(bodies.duplicate, '');
    // 完整正文里空段只留段头(Android 字面:`"Updated:\n" + "" + "\n\n"` 会留下 3 个换行)
    const text = subs.subUpdateFeedbackText(res({ changed: 1, addedNames: ['A'], deletedNames: ['D'] }));
    assert.equal(text, 'Added:\nA\n\nUpdated:\n\n\nDeleted:\nD\n\nDuplicate:');
  });

  await test('diff body: "old => new" only when names differ (GroupInterfaceAdapter.kt:57-63)', () => {
    // Android 侧 updated[displayName] = name,key 恒等于 value → 只打一次
    const same = subs.subUpdateFeedbackText(res({ changed: 1, updatedNames: ['HK'] }));
    assert.ok(same.indexOf('HK => HK') < 0, 'key==value 时不打箭头:' + same);
    assert.ok(same.indexOf('Updated:\nHK') >= 0);
    // 防御:若将来传入 "old => new" 形式,原样保留
    const arrow = subs.subUpdateFeedbackText(res({ changed: 1, updatedNames: ['old => new'] }));
    assert.ok(arrow.indexOf('old => new') >= 0);
  });

  // ===== 22. 直连更新确认 (GroupUpdater.kt:142-148) =====
  await test('confirm: http:// always asks when not connected', () => {
    assert.equal(subs.needDirectUpdateConfirm('http://a.example/sub', null, false), true);
    assert.equal(subs.needDirectUpdateConfirm('http://a.example/sub', null, true), false);
  });

  await test('confirm: https:// only with updateWhenConnectedOnly and not connected', () => {
    assert.equal(subs.needDirectUpdateConfirm('https://a.example/sub', null, false), false);
    const flagOn = { updateWhenConnectedOnly: true };
    assert.equal(subs.needDirectUpdateConfirm('https://a.example/sub', flagOn, false), true);
    assert.equal(subs.needDirectUpdateConfirm('https://a.example/sub', flagOn, true), false);
    const flagOff = { updateWhenConnectedOnly: false };
    assert.equal(subs.needDirectUpdateConfirm('https://a.example/sub', flagOff, false), false);
  });

  await test('confirm: http:// still asks when connected? no — Android gates on !isConnected', () => {
    assert.equal(subs.needDirectUpdateConfirm('http://a.example/sub', { updateWhenConnectedOnly: true }, true), false);
  });

  // ===== 23. parseProxies: 空格切分 + 取数量多者 (Formats.kt:107-108,230-239) =====
  await test('share text: multiple links on one line are all imported (space split wins)', () => {
    const a = 'trojan://pw1@a.example.com:443#A';
    const b = 'trojan://pw2@b.example.com:443#B';
    const profiles = link.parseShareText(`${a} ${b}`);
    assert.equal(profiles.length, 2, '一行两个链接 → 2 个节点');
    assert.equal(profiles.map(p => p.name).join(','), 'A,B');
  });

  await test('share text: link names containing spaces stay intact (line split wins on tie)', () => {
    // 按行那份能完整解析(名字里有空格),按空格那份会被切坏 → 数量相等 → 取按行那份
    const one = 'trojan://pw@c.example.com:443#My%20Fast%20Node';
    const profiles = link.parseShareText(`${one}\n${one}`);
    assert.equal(profiles.length, 2);
    // 名字里带空格的裸文本:按空格切出 3 段(1 成功 + 2 失败),两份数量相等 →
    // 取按行那份,名字原样保留(Android 字面行为,Formats.kt:230-239)
    const weird = 'trojan://pw@d.example.com:443#name with space';
    const r = link.parseShareText(`${weird}\n${one}`);
    assert.equal(r.length, 2);
    assert.equal(r[0].name, 'name with space', '相等时按行那份胜出');
    assert.equal(r[1].name, 'My Fast Node');
  });

  // ===== 24. trojan-go:// 分享链接 (TrojanGoFmt.kt:12-44) =====
  await test('trojan-go:// maps to trojan with sni/ws host/path (TrojanGoFmt.kt:12-44)', () => {
    const profiles = link.parseShareText(
      'trojan-go://mypw@tg.example.com:443?sni=sni.example.com&type=ws&host=cdn.example.com&path=%2Fws#GoNode');
    assert.equal(profiles.length, 1);
    const p = profiles[0];
    assert.equal(p.type, 'trojan', '无 trojan-go 类型 → 映射为 trojan(原始形态协议一致)');
    assert.equal(p.server, 'tg.example.com');
    assert.equal(p.serverPort, 443);
    assert.equal(p.password, 'mypw');
    assert.equal(p.sni, 'sni.example.com');
    assert.equal(p.tls, true);
    assert.equal(p.transport, 'ws');
    assert.equal(p.host, 'cdn.example.com');
    assert.equal(p.path, '/ws');
    assert.equal(p.name, 'GoNode');
  });

  await test('trojan-go:// without type leaves transport default (Android only ws branch writes it)', () => {
    const profiles = link.parseShareText('trojan-go://pw@tg2.example.com:8443#Plain');
    assert.equal(profiles.length, 1);
    assert.equal(profiles[0].transport, '');
    assert.equal(profiles[0].serverPort, 8443);
  });

  // ===== 25. naive+:// 不可实现,必须如实上报跳过 (BoxInstance.kt:70-73) =====
  await test('naive+ link is reported as skipped, not silently dropped', () => {
    const report = { skipped: 0, names: [] };
    const r = link.parseShareText('naive+https://u:p@n.example.com:443?sni=x#N', report);
    assert.equal(r.length, 0);
    assert.equal(report.skipped, 1);
    assert.ok(report.names[0].indexOf('naive+') >= 0, 'hint=' + report.names[0]);
  });

  console.log(`\n${count} Android-parity checks passed`);
})();
