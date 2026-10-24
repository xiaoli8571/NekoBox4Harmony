// 节点测试(TCPing / URL Test)与 Android NekoBoxForAndroid 1.4.2 的 1:1 语义回归。
//
// 每条断言都能从 Android 源码推导(证据见 docs/PARITY-LATENCY-TEST.md):
//   - 并发默认 5            DataStore.kt:159 connectionTestConcurrent
//   - TCPing 固定 3000      ConfigurationFragment.kt:748/754
//   - TCPing 过滤协议       :702-713 canTCPing
//   - 域名先解析取首个地址   :722-732 getAllByName()[0]
//   - 解析失败 status 2     :734-739 connection_test_domain_not_found
//   - 错误四分类            :773-793 timeout/refused/unreachable/其它
//   - URL Test 不筛协议     :843
//   - URL Test 失败 status 3 + 原文  :860-862
//   - genFriendlyMsg        Protocols.kt:53-66
//   - 取消后已测结果仍可落库 :807-823
//
// 生产代码直接加载(DevEco SDK 的 typescript 转译 + Node 桩),不是复制的逻辑副本。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';

function load(file, imports = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const ts = loadTs();
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(js, {
    exports,
    require: (n) => {
      if (!(n in imports)) throw Error(n);
      return imports[n];
    },
    // LatencyTester 的桥接兜底超时用真实定时器(host 定时器,行为与 OHOS 一致)
    setTimeout,
    clearTimeout,
    console
  });
  return exports;
}

let cachedTs = null;
function loadTs() {
  if (cachedTs === null) {
    cachedTs = require(path.join(sdk,
      'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
  }
  return cachedTs;
}

const model = load('entry/src/main/ets/model/Profile.ets');
const { Profile, AppSettings, ProfileType } = model;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------- 桩工厂

// P2/W09:URL Test 的编排已搬进 core/ProbeRunner(纯编排 + 可注入桥接)。
// 这里加载**真实的** ProbeResult / ProbeCoordinator / ProbeRunner,只桩掉平台边界
// (CoreManager/ConfigBuilder/socket/connection)与结果存储(ProbeStore.saveRun).
const probeModel = load('entry/src/main/ets/model/ProbeResult.ets');
const coordMod = load('entry/src/main/ets/core/ProbeCoordinator.ets', {
  '../model/ProbeResult': probeModel
});
const probeStoreDto = load('entry/src/main/ets/core/ProbeStore.ets', {
  '@ohos.file.fs': { default: {} },
  '@ohos.app.ability.common': {},
  './SnapshotStore': {
    SnapshotStore: {
      ensureDir() {}, readText() { return ''; }, writeTextAtomic() { return true; },
      exists() { return false; }, removeFile() {}
    }
  },
  '../model/Store': { LogStore: { addLog() {} } }
});

function makeHarness(opts = {}) {
  const calls = {
    start: [], proxy: [], stop: 0, caps: 0, configs: [], sockets: [],
    saves: [], markUnsaved: []
  };
  const core = {
    writeTestConfigFile: (_ctx, json) => {
      if (opts.writeError) throw new Error('disk full');
      calls.configs.push(json);
      return '/core/test.json';
    },
    testLogFilePath: () => '/core/test.log',
    testStart: async (p, bind) => {
      calls.start.push({ path: p, bind: bind === undefined ? '' : bind });
      return opts.startErr !== undefined ? opts.startErr : '';
    },
    testProxy: async (tag, url, timeoutMs, expectStatus) => {
      calls.proxy.push({ tag, url, timeoutMs, expectStatus });
      return opts.proxy !== undefined ? opts.proxy(tag, url, timeoutMs, expectStatus) : '42';
    },
    testStop: async () => {
      calls.stop++;
      return '';
    },
    testCaps: async () => {
      calls.caps++;
      return opts.caps !== undefined ? opts.caps : 'v2';
    }
  };
  const builder = {
    buildLatencyTestConfig: (targets, all, s, logPath, groups) => {
      calls.buildTargets = targets.map((p) => p.id);
      return {
        json: JSON.stringify({ outbounds: targets.map((_p, i) => `t${i}`) }),
        tags: (opts.tagsFor !== undefined ? opts.tagsFor(targets) : targets.map((_p, i) => `t${i}`))
      };
    },
    LatencyTestConfig: class {
      constructor() {
        this.json = '';
        this.tags = [];
      }
    }
  };
  const resolveCalls = [];
  const connection = {
    getAddressesByName: async (host) => {
      resolveCalls.push(host);
      return opts.resolve !== undefined ? opts.resolve(host) : [{ address: '1.2.3.4' }];
    },
    getDefaultNet: async () => ({ netId: 100 }),
    getConnectionProperties: async () => ({ interfaceName: 'wlan0' })
  };
  const socketCalls = [];
  const socket = {
    constructTCPSocketInstance: () => {
      const inst = {
        bind: async (o) => {
          socketCalls.push({ op: 'bind', arg: o });
        },
        connect: async (o) => {
          socketCalls.push({ op: 'connect', arg: o });
          if (opts.connect !== undefined) {
            return opts.connect(o);
          }
        },
        close: () => {
          socketCalls.push({ op: 'close' });
        }
      };
      calls.sockets.push(inst);
      return inst;
    }
  };
  // 存储桩:saveRun 默认成功并把整轮快照留给断言(节点状态/结果都在里面)
  const storeStub = Object.assign({}, probeStoreDto);
  storeStub.ProbeStore = {
    init() {},
    saveRun: async (run) => {
      calls.saves.push(run);
      return opts.saveOk === undefined ? true : opts.saveOk;
    },
    markUnsaved: async (runId) => {
      calls.markUnsaved.push(runId);
    }
  };
  const runnerMod = load('entry/src/main/ets/core/ProbeRunner.ets', {
    '../model/ProbeResult': probeModel,
    './ProbeCoordinator': coordMod,
    './ProbeStore': storeStub
  });
  const tester = load('entry/src/main/ets/utils/LatencyTester.ets', {
    '@ohos.net.socket': { default: socket },
    '@ohos.net.connection': { default: connection },
    '@ohos.app.ability.common': { default: {} },
    '../model/Profile': model,
    '../core/ConfigBuilder': builder,
    '../core/CoreManager': { CoreManager: core },
    '../model/Store': { LogStore: { addLog: () => {} } },
    '../model/ProbeResult': probeModel,
    '../core/ProbeCoordinator': coordMod,
    '../core/ProbeRunner': runnerMod
  });
  return { tester, calls, core, socketCalls, resolveCalls, runnerMod, probeModel };
}

function profile(id, type, server = 'example.com', port = 443) {
  const p = new Profile();
  p.id = id;
  p.name = id;
  p.type = type;
  p.server = server;
  p.serverPort = port;
  return p;
}

function settings(over = {}) {
  const s = new AppSettings();
  Object.assign(s, over);
  s.clashApiSecret = 'test-secret';
  return s;
}

// ---------------------------------------------------------------- 断言

(async () => {
  // 1. 默认值 1:1 对齐 Android
  {
    const s = new AppSettings();
    assert.equal(s.testUrl, 'http://cp.cloudflare.com/', 'Constants.kt:3 CONNECTION_TEST_URL');
    assert.equal(s.testConcurrent, 5, 'DataStore.kt:159 connectionTestConcurrent = 5');
    assert.equal(s.testRetries, 0, 'Android 不重试(单次探测)');
    assert.equal(s.testSamples, 1, 'Android 不取样');
    assert.equal(s.testExpectStatus, 'any', 'libneko 不看 HTTP 状态码');
    assert.equal(s.testTimeoutMs, 5000, 'UrlTest.kt:9 timeout = 5000');
    assert.equal(s.latencyTestMode, 'url', 'Android 主入口是 URL Test');
    assert.equal(s.testBypassTunnel, true, 'Android TestInstance 在 UI 进程天然直出');
    console.log('PASS defaults match Android literals (url/concurrency/retries/samples/expect/timeout)');
  }

  // 2. canTCPing 协议表(AbstractBean.java:51 默认 true + 5 个 override=false)
  {
    const h = makeHarness();
    const falseTypes = [ProfileType.HYSTERIA, ProfileType.HYSTERIA2, ProfileType.TUIC,
      ProfileType.WIREGUARD, ProfileType.CUSTOM, ProfileType.CHAIN];
    const trueTypes = [ProfileType.SHADOWSOCKS, ProfileType.VMESS, ProfileType.VLESS,
      ProfileType.TROJAN, ProfileType.HTTP, ProfileType.SOCKS, ProfileType.SSH,
      ProfileType.ANYTLS, ProfileType.SHADOWTLS, ProfileType.SNELL];
    for (const t of falseTypes) {
      assert.equal(h.tester.canTCPing(profile('x', t)), false, `${t} must not be TCPing-able`);
    }
    for (const t of trueTypes) {
      assert.equal(h.tester.canTCPing(profile('x', t)), true, `${t} must be TCPing-able`);
    }
    console.log('PASS canTCPing protocol table matches Android overrides');
  }

  // 3. genFriendlyMsg(Protocols.kt:53-66)
  {
    const h = makeHarness();
    assert.equal(h.tester.genFriendlyMsg('i/o timeout'), 'timeout');
    assert.equal(h.tester.genFriendlyMsg('context deadline exceeded'), 'timeout');
    assert.equal(h.tester.genFriendlyMsg('connect: connection refused'), 'refused');
    assert.equal(h.tester.genFriendlyMsg('write: closed pipe'), 'refused');
    assert.equal(h.tester.genFriendlyMsg('something odd'), null, 'unmapped stays raw');
    console.log('PASS genFriendlyMsg maps timeout/deadline and refused/closed-pipe only');
  }

  // 4. TCPing 错误四分类(:773-793)
  {
    const h = makeHarness();
    assert.equal(h.tester.classifyConnectError('operation timeout').status, 2);
    assert.equal(h.tester.classifyConnectError('operation timeout').error, 'timeout');
    assert.equal(h.tester.classifyConnectError('connect ECONNREFUSED 1.2.3.4:443').error, 'refused');
    assert.equal(h.tester.classifyConnectError('network is unreachable').error, 'unreachable');
    const other = h.tester.classifyConnectError('2300007 Couldn\'t connect to server');
    assert.equal(other.status, 3, 'unclassified errors keep status 3');
    assert.equal(other.error, '2300007 Couldn\'t connect to server', 'raw text is preserved');
    console.log('PASS TCPing error classification: timeout/refused/unreachable/raw->status 3');
  }

  // 5. TCPing 成功:先解析域名、取**第一个**地址、固定 3000ms
  {
    // [0] 是 IPv6 → 必须用它(Android getAllByName()[0] 不挑 v4)
    const h = makeHarness({ resolve: () => [{ address: '::1' }, { address: '1.2.3.4' }] });
    const results = [];
    const n = await h.tester.testProfiles([profile('a', ProfileType.SHADOWSOCKS, 'node.example', 8443)],
      (r) => results.push(r), 5, 0, 1);
    assert.equal(n, 1);
    assert.deepEqual(h.resolveCalls, ['node.example'], 'domain must be resolved before connecting');
    const connect = h.socketCalls.find((c) => c.op === 'connect');
    assert.equal(connect.arg.address.address, '::1', 'must take the first resolved address like getAllByName()[0]');
    assert.equal(connect.arg.address.family, 2);
    assert.equal(connect.arg.timeout, 3000, 'ConfigurationFragment.kt:754 connect timeout is 3000');
    assert.equal(connect.arg.address.port, 8443);
    assert.equal(results.length, 2, 'status 0 (testing) then final');
    assert.equal(results[0].status, 0, 'node is marked testing before the probe (:721)');
    assert.equal(results[1].status, 1);
    assert.ok(results[1].ping >= 0);
    console.log('PASS TCPing resolves first address, 3000ms timeout, marks status 0 then 1');
  }

  // 6. 解析不出 → status 2 + domain_not_found,且不建 socket(:734-739)
  {
    for (const resolve of [() => [], () => { throw new Error('dns fail'); }]) {
      const h = makeHarness({ resolve });
      const results = [];
      await h.tester.testProfiles([profile('a', ProfileType.SHADOWSOCKS)], (r) => results.push(r), 5, 0, 1);
      assert.equal(results[results.length - 1].status, 2);
      assert.equal(results[results.length - 1].error, 'domain_not_found');
      assert.equal(h.socketCalls.length, 0, 'no socket is created when the domain cannot be resolved');
    }
    console.log('PASS unresolvable domain -> status 2 domain_not_found, no connection attempt');
  }

  // 7. 连接错误分类落到结果上
  {
    const cases = [
      ['boom timeout', 2, 'timeout'],
      ['connect refused', 2, 'refused'],
      ['host unreachable', 2, 'unreachable'],
      ['2300007 Couldn\'t connect to server', 3, '2300007 Couldn\'t connect to server']
    ];
    for (const [message, status, error] of cases) {
      const h = makeHarness({ connect: () => { throw message; } });
      const results = [];
      await h.tester.testProfiles([profile('a', ProfileType.SHADOWSOCKS, '1.2.3.4')], (r) => results.push(r), 5, 0, 1);
      const last = results[results.length - 1];
      assert.equal(last.status, status, `${message} -> status ${status}`);
      assert.equal(last.error, error);
    }
    console.log('PASS TCPing failures carry Android status/error semantics');
  }

  // 8. TCPing 过滤 canTCPing=false 的协议(:702-713)
  {
    const h = makeHarness();
    const list = [
      profile('ss', ProfileType.SHADOWSOCKS, '1.1.1.1'),
      profile('hy2', ProfileType.HYSTERIA2, '1.1.1.2'),
      profile('tuic', ProfileType.TUIC, '1.1.1.3'),
      profile('wg', ProfileType.WIREGUARD, '1.1.1.4'),
      profile('custom', ProfileType.CUSTOM, '1.1.1.5'),
      profile('chain', ProfileType.CHAIN, '1.1.1.6')
    ];
    const results = [];
    const tested = await h.tester.testProfiles(list, (r) => results.push(r), 5, 0, 1);
    assert.equal(tested, 1, 'only the shadowsocks node is TCPing-able');
    assert.deepEqual(results.map((r) => r.id), ['ss', 'ss']);
    console.log('PASS TCPing skips hysteria/tuic/wireguard/custom/chain like canTCPing()');
  }

  // 9. URL Test 不筛协议(:843);每节点先 status 0 再落最终态
  {
    const h = makeHarness();
    const list = [
      profile('ss', ProfileType.SHADOWSOCKS),
      profile('hy2', ProfileType.HYSTERIA2),
      profile('tuic', ProfileType.TUIC),
      profile('wg', ProfileType.WIREGUARD)
    ];
    const results = [];
    const report = await h.tester.urlTestProfiles(list, list, settings(), {}, (r) => results.push(r), 5, []);
    assert.equal(report.degraded, false);
    assert.equal(h.calls.proxy.length, 4, 'URL Test must probe every node regardless of protocol');
    assert.deepEqual(h.calls.proxy.map((c) => c.tag).sort(), ['t0', 't1', 't2', 't3']);
    for (const id of ['ss', 'hy2', 'tuic', 'wg']) {
      const own = results.filter((r) => r.id === id);
      assert.equal(own.length, 2, `${id}: testing + final`);
      assert.equal(own[0].status, 0);
      assert.equal(own[1].status, 1);
      assert.equal(own[1].ping, 42);
    }
    console.log('PASS URL Test probes all protocols, marks status 0 then 1 with the probed latency');
  }

  // 10. 并发 = 5(DataStore.kt:159),整批共用一个测试会话(D-1)
  {
    let inFlight = 0;
    let maxInFlight = 0;
    const h = makeHarness({
      proxy: async () => {
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        await sleep(5);
        inFlight--;
        return '10';
      }
    });
    const list = [];
    for (let i = 0; i < 13; i++) list.push(profile(`p${i}`, ProfileType.TROJAN));
    const report = await h.tester.urlTestProfiles(list, list, settings(), {}, () => {}, 5, []);
    assert.equal(maxInFlight, 5, 'worker pool must cap at connectionTestConcurrent = 5');
    assert.equal(report.tested, 13);
    assert.equal(h.calls.start.length, 1, 'batch session: one testStart for the whole run (see D-1)');
    assert.equal(h.calls.stop, 2, 'pre-stop (stale-session guard) + one final testStop');
    assert.equal(h.calls.caps, 1);
    console.log('PASS URL Test runs 5 workers over one batch session (start/probe/stops counted)');
  }

  // 11. URL Test 失败 = status 3 + 内核原文(:860-862),展示期才映射
  {
    const h = makeHarness({ proxy: async () => 'err:i/o timeout' });
    const results = [];
    await h.tester.urlTestProfiles([profile('a', ProfileType.TROJAN)], [], settings(), {}, (r) => results.push(r), 5, []);
    const last = results[results.length - 1];
    assert.equal(last.status, 3, 'URL Test failures are status 3 (Android catch-all)');
    assert.equal(last.error, 'i/o timeout', 'raw kernel text is preserved, no premature localization');
    assert.equal(h.tester.genFriendlyMsg(last.error), 'timeout', 'display layer maps it to Timeout');
    console.log('PASS URL Test failure keeps status 3 + raw text (friendly mapping happens at display)');
  }

  // 12. 探测参数取自设置:URL / 超时 / 期望状态
  {
    const h = makeHarness();
    await h.tester.urlTestProfiles([profile('a', ProfileType.TROJAN)], [], settings(), {}, () => {}, 5, []);
    const call = h.calls.proxy[0];
    assert.equal(call.url, 'http://cp.cloudflare.com/', 'UrlTest.kt:8 link = connectionTestURL');
    assert.equal(call.timeoutMs, 5000, 'UrlTest.kt:9 timeout = 5000');
    assert.equal(call.expectStatus, 'any', 'default must not check status codes (libneko behaviour)');

    const h2 = makeHarness();
    await h2.tester.urlTestProfiles([profile('a', ProfileType.TROJAN)], [],
      settings({ testTimeoutMs: 1234, testExpectStatus: '2xx', testUrl: 'https://example.com/x' }),
      {}, () => {}, 5, []);
    assert.equal(h2.calls.proxy[0].timeoutMs, 1234, 'the harmony-only timeout knob still applies (superset)');
    assert.equal(h2.calls.proxy[0].expectStatus, '2xx');
    assert.equal(h2.calls.proxy[0].url, 'https://example.com/x');
    console.log('PASS URL Test probe receives link/timeout/expect-status; defaults equal Android');
  }

  // 13. 取消:停止取新节点,但已报告结果保留(调用方据此落库,:807-823)
  {
    const h = makeHarness({ proxy: async () => { await sleep(2); return '20'; } });
    const list = [];
    for (let i = 0; i < 40; i++) list.push(profile(`p${i}`, ProfileType.TROJAN));
    const results = [];
    let checks = 0;
    const report = await h.tester.urlTestProfiles(list, list, settings(), {},
      (r) => results.push(r), 5, [], () => {
        checks++;
        return checks > 8;
      });
    const finals = results.filter((r) => r.status !== 0);
    assert.ok(finals.length >= 1, 'already-measured nodes stay reported after cancel');
    assert.ok(finals.length < 40, 'cancel must stop dequeuing new nodes');
    assert.equal(report.degraded, false);
    assert.equal(h.calls.stop, 2, 'the batch session is still closed on cancel (pre-stop + final)');
    console.log('PASS cancel stops dequeuing and keeps measured results (persistable)');
  }

  // 14. 批量启动失败 → 二分隔离(方案 §6.4/C3:整批静默回退 TCPing 已删除)
  //     单节点目标被隔离为坏节点:status=3 + 内核原文;会话没起来所以不探测;
  //     这是**节点级**问题,不是环境级降级。
  {
    const h = makeHarness({ startErr: 'err:create test service' });
    const results = [];
    const list = [profile('a', ProfileType.SHADOWSOCKS, '1.2.3.4')];
    const report = await h.tester.urlTestProfiles(list, [], settings(), {}, (r) => results.push(r), 5, []);
    assert.equal(report.degraded, false, '节点级失败不是环境级降级(旧"已回退 TCPing"语义作废)');
    assert.equal(report.tcpingOption, false, '节点问题不提供"改用 TCPing"入口');
    assert.equal(report.tested, 1, '被隔离的节点仍计入本轮参与数');
    assert.equal(h.calls.proxy.length, 0, '会话未起,自然没有探测(也不再回退 TCPing)');
    assert.equal(h.calls.start.length, 1, '单节点只启动一次(失败后不再重试启动)');
    assert.equal(h.calls.stop, 2, '开测前守卫 + 启动失败后关闭可能迟到创建的会话(§6.5)');
    const last = results[results.length - 1];
    assert.equal(last.status, 3, '隔离节点 = status 3(异常)');
    assert.equal(last.error, 'create test service', 'errorDetail 保留内核原文');
    assert.equal(h.calls.saves.length, 1, '隔离结果照常落盘:坏节点要能被记住');
    const saved = h.calls.saves[0].results[0];
    assert.equal(saved.state, 'failed');
    assert.equal(saved.errorCode, 'batch_start_failed');
    assert.equal(saved.methodActual, 'http', '健康/隔离节点都不会被悄悄改成 TCP');
    console.log('PASS batch start failure isolated to the bad node (§6.4: no batch-wide TCP fallback)');
  }

  // 15. 配置写盘失败 = 环境级失败(方案 §6.4/C3):整轮不启动、节点 notApplicable、
  //     tcpingOption=true、原因如实带原文;同样不再整批回退 TCPing。
  {
    const h = makeHarness({ writeError: true });
    const list = [profile('a', ProfileType.SHADOWSOCKS, '1.2.3.4')];
    const results = [];
    const report = await h.tester.urlTestProfiles(list, list, settings(), {}, (r) => results.push(r));
    assert.equal(report.degraded, true, '环境级失败必须显式告知用户');
    assert.equal(report.tcpingOption, true, 'UI 提供"改用 TCPing 检测支持的节点"(§6.4-7)');
    assert.match(report.degradeReason, /disk full/, '原始错误文本如实透出');
    assert.match(report.degradeReason, /配置|目录/, '并说明是配置/目录问题');
    assert.equal(h.calls.start.length, 0, '整轮不启动测速实例');
    assert.equal(h.calls.proxy.length, 0, '也没有任何探测(不回退 TCPing)');
    assert.equal(results.length, 0, '没有节点结论:不覆盖界面上的旧值');
    assert.equal(report.saved, true, '环境级失败这一轮也写盘(供 P3 展示"未检测"原因)');
    assert.equal(h.calls.saves.length, 1);
    const saved = h.calls.saves[0];
    assert.equal(saved.results.length, 1);
    assert.equal(saved.results[0].state, 'notApplicable', '环境问题不标成坏节点');
    assert.equal(saved.results[0].errorCode, 'test_dir_unwritable');
    console.log('PASS config write failure is environment-level with TCPing option (§6.4/C3)');
  }

  {
    const h = makeHarness({ tagsFor: (targets) => targets.map((p, i) => (p.id === 'bad' ? '' : `t${i}`)) });
    const list = [profile('bad', ProfileType.TROJAN), profile('good', ProfileType.TROJAN)];
    const results = [];
    await h.tester.urlTestProfiles(list, list, settings(), {}, (r) => results.push(r), 5, []);
    const bad = results.filter((r) => r.id === 'bad');
    const good = results.filter((r) => r.id === 'good');
    assert.equal(bad[bad.length - 1].status, 3, 'unbuildable node is red on its own');
    assert.equal(bad[bad.length - 1].error, 'outbound build failed');
    assert.equal(good[good.length - 1].status, 1, 'other nodes still get measured');
    assert.equal(h.calls.proxy.length, 1, 'only the buildable node is probed');
    console.log('PASS a node with an unbuildable outbound fails alone, the batch continues');
  }

  // 16. Store:旧数据(latencyMs)迁移到 status/ping/error
  {
    const data = new Map();
    const prefs = {
      get: async (k, d) => (data.has(k) ? data.get(k) : d),
      put: async (k, v) => data.set(k, v),
      flush: async () => {}
    };
    const perApp = load('entry/src/main/ets/model/PerApp.ets');
    const store = load('entry/src/main/ets/model/Store.ets', {
      './Profile': model,
      './PerApp': perApp,
      '@ohos.data.preferences': { default: { getPreferences: async () => prefs } },
      '@ohos.events.emitter': { default: { emit: () => {}, EventPriority: { LOW: 0 } } }
    });
    await store.initStore({});
    data.set('profiles', JSON.stringify([
      { id: 'ok', latencyMs: 88 },
      { id: 'dead', latencyMs: -1 },
      { id: 'fresh', latencyMs: 0 },
      { id: 'native', status: 1, ping: 50, latencyMs: 0 }
    ]));
    const loaded = await store.loadProfiles();
    const byId = new Map(loaded.map((p) => [p.id, p]));
    assert.equal(byId.get('ok').status, 1, 'legacy >0 -> status 1');
    assert.equal(byId.get('ok').ping, 88);
    assert.equal(byId.get('dead').status, 3, 'legacy -1 -> status 3');
    assert.equal(byId.get('dead').error, 'timeout');
    assert.equal(byId.get('dead').latencyMs, -1, 'derived latency stays -1 for sorting/badges');
    assert.equal(byId.get('fresh').status, 0);
    assert.equal(byId.get('native').latencyMs, 50, 'derived value is rebuilt from status/ping');

    // 17. 存回来仍是三件套(Editor/订阅更新/备份都依赖这个持久化形状)
    byId.get('ok').status = 2;
    byId.get('ok').error = 'refused';
    byId.get('ok').latencyMs = -1;
    await store.saveProfiles(loaded);
    const again = new Map((await store.loadProfiles()).map((p) => [p.id, p]));
    assert.equal(again.get('ok').status, 2);
    assert.equal(again.get('ok').error, 'refused');
    assert.equal(again.get('ok').latencyMs, -1);
    console.log('PASS Store migrates legacy latencyMs and round-trips status/ping/error');

    // 18. 设置项:不再把 5 迁成 10、不再改写 testUrl、缺省值走 Android 口径
    const defaults = await store.loadSettings();
    assert.equal(defaults.testConcurrent, 5);
    assert.equal(defaults.testUrl, 'http://cp.cloudflare.com/');
    assert.equal(defaults.testRetries, 0);
    assert.equal(defaults.testExpectStatus, 'any');

    const legacy = (over) => JSON.stringify(Object.assign({ clashApiSecret: 't' }, over));
    for (const [raw, expected] of [
      [{ testConcurrent: 5 }, 5],
      [{ testConcurrent: 0 }, 5],
      [{ testConcurrent: 99 }, 5],
      [{ testConcurrent: 8 }, 8]
    ]) {
      data.set('settings', legacy(raw));
      assert.equal((await store.loadSettings()).testConcurrent, expected,
        `testConcurrent ${raw.testConcurrent} -> ${expected}`);
    }
    data.set('settings', legacy({ testUrl: 'http://www.gstatic.com/generate_204' }));
    assert.equal((await store.loadSettings()).testUrl, 'http://www.gstatic.com/generate_204',
      'stored URLs are never rewritten (Android default change has no migration)');
    data.set('settings', legacy({ testUrl: '   ' }));
    assert.equal((await store.loadSettings()).testUrl, 'http://cp.cloudflare.com/');
    data.set('settings', legacy({ testRetries: 2, testExpectStatus: '2xx' }));
    const kept = await store.loadSettings();
    assert.equal(kept.testRetries, 2, 'user-set retries survive');
    assert.equal(kept.testExpectStatus, '2xx', 'user-set status check survives');
    console.log('PASS settings defaults/migration match Android (no 5->10, no URL rewrite)');
  }

  console.log('ALL LATENCY-PARITY TESTS PASSED');
})().catch((e) => {
  console.error('FAIL', e && e.stack ? e.stack : e);
  process.exit(1);
});
