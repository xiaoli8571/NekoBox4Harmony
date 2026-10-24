// ProbeRunner(P2/W09 §6.3-§6.6 检测运行器)行为测试:注入桥接,不联网、不碰内核。
// 覆盖:V3 正常批 / 二分隔离 / 启动预算耗尽 / legacy 环境失败 / 逐节点 TCP 回退 /
//       取消 / 写盘失败 / path 三分支 / 桥接超时 / runId 迟到回调守卫 /
//       V2 串行路径 / stop 确认(sessionInfo) / 目录不可写环境失败。
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
  vm.runInNewContext(js, {
    exports,
    require: (n) => { if (!(n in imports)) throw Error(`unexpected require: ${n}`); return imports[n]; },
    setTimeout, clearTimeout, console
  });
  return exports;
}

const model = load('entry/src/main/ets/model/ProbeResult.ets');
const coordMod = load('entry/src/main/ets/core/ProbeCoordinator.ets', {
  '../model/ProbeResult': model
});
const storeMod = load('entry/src/main/ets/core/ProbeStore.ets', {
  '@ohos.file.fs': { default: {} },
  '@ohos.app.ability.common': {},
  './SnapshotStore': { SnapshotStore: { ensureDir() {}, readText() { return ''; }, writeTextAtomic() { return true; }, exists() { return false; }, removeFile() {} } },
  '../model/Store': { LogStore: { addLog() {} } }
});
const runnerMod = load('entry/src/main/ets/core/ProbeRunner.ets', {
  '../model/ProbeResult': model,
  './ProbeCoordinator': coordMod,
  './ProbeStore': storeMod
});
const { ProbeRunner, ProbeRunnerDeps, ProbeRoundOptions, ProbeBatchConfig, ProbeTcpResult, ProbeDirProbe } = runnerMod;
const { ProbeTarget, ProbeEnv } = coordMod;

const mkTarget = (id, chain = '') => {
  const t = new ProbeTarget();
  t.profileId = id;
  t.profileName = `节点${id}`;
  t.profileConfigHash = `hash-${id}`;
  t.chainKey = chain;
  return t;
};

const mkEnv = (over = {}) => Object.assign(new ProbeEnv(), {
  method: model.PROBE_METHOD_HTTP,
  target: 'http://cp.cloudflare.com/',
  timeoutMs: 5000,
  concurrency: 5,
  samples: 1,
  retries: 0,
  expectedStatus: 'any',
  bypassVpn: false
}, over);

/**
 * 注入式桥接桩:记录全部调用;cfg 各字段在调用时动态读取,可在用例中途覆写。
 * writeConfig 返回的"路径"携带配置 JSON,便于 onStart 判断本批含哪些节点。
 */
function makeHarness(cfgIn = {}) {
  const cfg = cfgIn;
  const calls = {
    caps: 0, starts: [], proxies: [], stops: [], stopsNoId: 0, info: [],
    active: 0, writes: [], tcpPings: [], saves: [], marks: [], logs: [], emits: []
  };
  const bridge = {
    caps: async () => { calls.caps += 1; return cfg.caps === undefined ? 'v3' : cfg.caps; },
    startV3: async (sid, configPath, bind) => {
      calls.starts.push({ v3: true, sid, configPath, bind });
      if (cfg.onStart) return cfg.onStart(sid, configPath, bind);
      return '';
    },
    proxyV3: async (sid, tag, url, timeoutMs, expect) => {
      calls.proxies.push({ v3: true, sid, tag, url, timeoutMs, expect });
      if (cfg.onProxyV3) return await cfg.onProxyV3(sid, tag, url, timeoutMs, expect);
      return '42';
    },
    stopV3: async (sid) => {
      calls.stops.push(sid);
      if (cfg.onStopV3) return cfg.onStopV3(sid);
      return '';
    },
    sessionInfoV3: async (sid) => {
      calls.info.push(sid);
      if (cfg.onInfo) return cfg.onInfo(sid);
      return '';
    },
    activeSessions: async () => { calls.active += 1; return cfg.activeSessions === undefined ? '' : cfg.activeSessions; },
    start: async (configPath, bind) => {
      calls.starts.push({ v3: false, sid: null, configPath, bind });
      if (cfg.onStartLegacy) return cfg.onStartLegacy(configPath, bind);
      return '';
    },
    proxy: async (tag, url, timeoutMs, expect) => {
      calls.proxies.push({ v3: false, sid: null, tag, url, timeoutMs, expect });
      if (cfg.onProxy) return await cfg.onProxy(tag, url, timeoutMs, expect);
      return '42';
    },
    stop: async () => {
      calls.stopsNoId += 1;
      if (cfg.onStopLegacy) return cfg.onStopLegacy();
      return '';
    }
  };
  const deps = new ProbeRunnerDeps();
  deps.bridge = bridge;
  deps.buildBatch = (batch) => {
    const out = new ProbeBatchConfig();
    out.json = JSON.stringify({ ids: batch.map((t) => t.profileId) });
    out.tags = batch.map((t) => (cfg.tagOf ? cfg.tagOf(t.profileId) : `tag-${t.profileId}`));
    return out;
  };
  deps.writeConfig = (json) => {
    calls.writes.push(json);
    return `test/${calls.writes.length}.json:${json}`;
  };
  deps.tcpPing = async (profileId) => {
    calls.tcpPings.push(profileId);
    if (cfg.onTcpPing) return cfg.onTcpPing(profileId);
    return Object.assign(new ProbeTcpResult(), { ok: true, latencyMs: 9 });
  };
  deps.saveRun = async (run) => {
    calls.saves.push(run);
    return cfg.saveOk === undefined ? true : cfg.saveOk;
  };
  deps.markUnsaved = async (runId) => { calls.marks.push(runId); };
  deps.isVpnRunning = () => cfg.vpnRunning === true;
  deps.probeDir = () => {
    const p = new ProbeDirProbe();
    if (cfg.dirWritable === false) {
      p.writable = false;
      p.error = cfg.dirError || 'EACCES: write probe.json: disk full';
    }
    return p;
  };
  deps.log = (line) => { calls.logs.push(line); };
  const runner = new ProbeRunner(new coordMod.ProbeCoordinator(), deps);
  const run = async (targets, env, optsOver = {}) => {
    const opts = Object.assign(new ProbeRoundOptions(), {
      source: model.PROBE_SOURCE_MANUAL,
      bindIfname: '',
      allowTcpFallbackPerNode: false,
      onResult: (r) => { calls.emits.push(r); }
    }, optsOver);
    return runner.runProbeRound(targets, env, opts);
  };
  return { runner, deps, calls, cfg, run };
}

const byId = (results, id) => results.find((r) => r.profileId === id);

(async () => {
  // ---------------- 1. V3 正常批:全绿 + sessionId 一致 ----------------
  {
    const h = makeHarness({ caps: 'v3' });
    const targets = [mkTarget('a'), mkTarget('b'), mkTarget('c')];
    const out = await h.run(targets, mkEnv(), {});
    assert.equal(out.error, '', 'normal round must not be busy');
    assert.equal(out.capability, 'native-v3');
    assert.equal(out.saved, true, 'saved run');
    assert.equal(out.summary.success, 3);
    assert.equal(out.results.length, 3);
    for (const r of out.results) {
      assert.equal(r.state, model.PROBE_STATE_SUCCESS);
      assert.equal(r.latencyMs, 42, 'latency parsed from bridge');
      assert.equal(r.methodActual, model.PROBE_METHOD_HTTP);
      assert.equal(r.coreCapability, model.PROBE_CAP_NATIVE_V3);
      assert.equal(r.path, model.PROBE_PATH_UNBOUND_UNKNOWN);
    }
    assert.equal(h.calls.caps, 1, 'caps probed once');
    assert.equal(h.calls.starts.length, 1);
    assert.equal(h.calls.proxies.length, 3);
    assert.equal(h.calls.stops.length, 1);
    const sid = h.calls.starts[0].sid;
    assert.ok(sid.length > 0);
    assert.equal(sid, out.sessionId, 'outcome sessionId matches start');
    for (const p of h.calls.proxies) assert.equal(p.sid, sid, 'proxy uses round sessionId');
    assert.equal(h.calls.stops[0], sid, 'stop uses round sessionId');
    assert.ok(h.calls.saves.length === 1 && h.calls.saves[0].runId === out.runId);
    console.log('PASS 1 v3 normal batch: all success, session id consistent');
  }

  // ---------------- 2. 批内 1 个坏节点 → 二分隔离,好节点保持 HTTP ----------------
  {
    const h = makeHarness({
      caps: 'v3',
      onStart: (sid, configPath) => (configPath.indexOf('bad') >= 0 ? 'err:start failed: bad chain outbound' : '')
    });
    const targets = [mkTarget('good1'), mkTarget('good2'), mkTarget('bad')];
    const out = await h.run(targets, mkEnv(), {});
    const bad = byId(out.results, 'bad');
    const good1 = byId(out.results, 'good1');
    const good2 = byId(out.results, 'good2');
    assert.equal(good1.state, model.PROBE_STATE_SUCCESS, 'good node stays success');
    assert.equal(good2.state, model.PROBE_STATE_SUCCESS, 'good node stays success');
    assert.equal(good1.methodActual, model.PROBE_METHOD_HTTP, 'good node stays http (no TCP fallback)');
    assert.equal(bad.state, model.PROBE_STATE_FAILED);
    assert.equal(bad.errorCode, 'batch_start_failed');
    assert.ok(bad.errorDetail.includes('bad chain outbound'), 'bad node keeps kernel text');
    assert.equal(out.summary.failed, 1);
    assert.equal(out.saved, true);
    assert.ok(h.calls.proxies.every((p) => p.tag !== 'tag-bad'), 'bad node never probed');
    assert.equal(h.calls.proxies.length, 2, 'good nodes probed');
    console.log('PASS 2 binary isolation: bad node failed with kernel text, good nodes untouched');
  }

  // ---------------- 3. 启动预算耗尽 → 如实 unfinished,不回退 TCP ----------------
  {
    const h = makeHarness({ caps: 'v3', onStart: () => 'err:boom' });
    const targets = [mkTarget('a'), mkTarget('b'), mkTarget('c')];
    const out = await h.run(targets, mkEnv(), { maxStarts: 2 });
    assert.equal(out.unfinished, 3, 'all unfinished counted truthfully');
    for (const r of out.results) {
      assert.equal(r.state, model.PROBE_STATE_CANCELLED);
      assert.equal(r.errorCode, 'attempt_budget_exhausted');
      assert.equal(r.participated, model.PROBE_PARTICIPATED_NO);
      assert.notEqual(r.methodActual, model.PROBE_METHOD_TCPING, 'never silently switches to TCPing');
    }
    assert.equal(h.calls.proxies.length, 0, 'no probing without a confirmed session');
    assert.equal(out.saved, true, 'saved part is still saved');
    assert.equal(h.calls.saves.length, 1);
    console.log('PASS 3 attempt budget exhausted: unfinished truthful, no TCP fallback, saved=true');
  }

  // ---------------- 4. legacy 内核 → 整轮不启动,notApplicable,tcpingOption ----------------
  {
    const h = makeHarness({ caps: 'legacy' });
    const targets = [mkTarget('a'), mkTarget('b')];
    const out = await h.run(targets, mkEnv(), {});
    assert.equal(out.capability, model.PROBE_CAP_LEGACY);
    assert.equal(out.envError, 'core_unsupported');
    assert.equal(out.tcpingOption, true, 'UI offers TCPing alternative');
    assert.equal(out.degraded, true);
    assert.ok(out.degradeReason.includes('内核'), 'degrade reason explains capability gap');
    assert.equal(h.calls.starts.length, 0, 'legacy never starts a session');
    assert.equal(h.calls.proxies.length, 0);
    for (const r of out.results) {
      assert.equal(r.state, model.PROBE_STATE_NOT_APPLICABLE, 'environment issue, not bad node');
      assert.equal(r.errorCode, 'core_unsupported');
    }
    assert.equal(out.summary.failed, 0);
    assert.equal(out.saved, true);
    const envLogs = h.calls.logs.filter((l) => l.includes('环境级失败'));
    assert.equal(envLogs.length, 1, 'environment failure reported exactly once');
    console.log('PASS 4 legacy caps: round not started, notApplicable nodes, tcpingOption=true');
  }

  // ---------------- 5. 逐节点 TCP 回退:只影响失败节点,来源永久标明 ----------------
  {
    const h = makeHarness({
      caps: 'v3',
      onProxyV3: async (sid, tag) => (tag === 'tag-bad' ? 'err:i/o timeout' : '42'),
      onTcpPing: () => Object.assign(new ProbeTcpResult(), { ok: true, latencyMs: 9 })
    });
    const out = await h.run([mkTarget('ok'), mkTarget('bad')], mkEnv(), { allowTcpFallbackPerNode: true });
    const ok = byId(out.results, 'ok');
    const bad = byId(out.results, 'bad');
    assert.equal(ok.methodActual, model.PROBE_METHOD_HTTP, 'successful node keeps http');
    assert.equal(ok.latencyMs, 42);
    assert.equal(bad.methodActual, model.PROBE_METHOD_TCPING, 'failed node falls back per node');
    assert.equal(bad.degradedReason, 'http_fallback_tcping');
    assert.equal(bad.state, model.PROBE_STATE_SUCCESS);
    assert.equal(bad.latencyMs, 9);
    assert.deepEqual(h.calls.tcpPings, ['bad'], 'only failed node gets TCPing');
    assert.equal(out.degraded, true, 'summary must disclose TCP origin');
    // 开关关闭时:失败节点保持 http 失败,绝不回退
    const h2 = makeHarness({ caps: 'v3', onProxyV3: async (sid, tag) => (tag === 'tag-bad' ? 'err:i/o timeout' : '42') });
    const out2 = await h2.run([mkTarget('ok'), mkTarget('bad')], mkEnv(), {});
    assert.equal(byId(out2.results, 'bad').methodActual, model.PROBE_METHOD_HTTP);
    assert.equal(byId(out2.results, 'bad').state, model.PROBE_STATE_FAILED);
    assert.equal(h2.calls.tcpPings.length, 0);
    console.log('PASS 5 per-node TCP fallback only for failed nodes with permanent marker');
  }

  // ---------------- 6. 取消:在飞结果接收,未执行取消,stop 一次 ----------------
  {
    let armed = false;
    const h = makeHarness({
      caps: 'v3',
      onProxyV3: async (sid, tag) => {
        if (tag === 'tag-n1') {
          armed = true;
          return '10';
        }
        return '20';
      }
    });
    const targets = [mkTarget('n1'), mkTarget('n2'), mkTarget('n3')];
    const out = await h.run(targets, mkEnv({ concurrency: 1 }), { isCancelled: () => armed });
    const n1 = byId(out.results, 'n1');
    assert.equal(n1.state, model.PROBE_STATE_SUCCESS, 'in-flight probe completes and is accepted');
    for (const id of ['n2', 'n3']) {
      const r = byId(out.results, id);
      assert.equal(r.state, model.PROBE_STATE_CANCELLED, `${id} cancelled`);
      assert.equal(r.participated, model.PROBE_PARTICIPATED_NO, `${id} not participated`);
    }
    assert.equal(h.calls.stops.length, 1, 'stop called exactly once');
    assert.equal(h.calls.stops[0], out.sessionId, 'stop uses correct sessionId');
    assert.ok(h.calls.proxies.every((p) => p.sid === out.sessionId));
    assert.equal(h.calls.proxies.length, 1, 'cancel stops dequeuing new nodes');
    assert.equal(out.saved, true);
    console.log('PASS 6 cancel: in-flight accepted, queued cancelled/not participated, one confirmed stop');
  }

  // ---------------- 7. 写盘失败 → saved=false + unsaved ----------------
  {
    const h = makeHarness({ caps: 'v3', saveOk: false });
    const out = await h.run([mkTarget('a')], mkEnv(), {});
    assert.equal(out.saved, false, 'never pretends saved');
    assert.equal(out.results[0].state, model.PROBE_STATE_UNSAVED);
    assert.deepEqual(h.calls.marks, [out.runId], 'storage layer told about unsaved run');
    console.log('PASS 7 saveRun failure: outcome.saved=false, state=unsaved, markUnsaved called');
  }

  // ---------------- 8. path 三分支 ----------------
  {
    let h = makeHarness({ caps: 'v3' });
    let out = await h.run([mkTarget('a')], mkEnv({ bypassVpn: true }), { bindIfname: 'wlan0' });
    assert.equal(out.path, model.PROBE_PATH_DIRECT_BOUND);
    assert.equal(out.results[0].path, model.PROBE_PATH_DIRECT_BOUND);
    assert.equal(h.calls.starts[0].bind, 'wlan0', 'bind forwarded to kernel');

    h = makeHarness({ caps: 'v3', vpnRunning: true });
    out = await h.run([mkTarget('a')], mkEnv({ bypassVpn: false }), {});
    assert.equal(out.path, model.PROBE_PATH_CURRENT_TUNNEL);

    h = makeHarness({ caps: 'v3', vpnRunning: false });
    out = await h.run([mkTarget('a')], mkEnv({ bypassVpn: false }), {});
    assert.equal(out.path, model.PROBE_PATH_UNBOUND_UNKNOWN);

    h = makeHarness({ caps: 'v3' });
    out = await h.run([mkTarget('a')], mkEnv({ bypassVpn: true }), { bindIfname: '' });
    assert.equal(out.path, model.PROBE_PATH_UNBOUND_UNKNOWN, 'bypass without confirmed bind never fakes direct');
    console.log('PASS 8 path branches: directBound / currentTunnel / unboundUnknown');
  }

  // ---------------- 9. 桥接超时:该节点失败带超时原文,不污染其它节点 ----------------
  {
    const h = makeHarness({
      caps: 'v3',
      onProxyV3: async (sid, tag) => {
        if (tag === 'tag-hang') {
          return new Promise(() => {}); // 永不 settle:模拟 native 挂死
        }
        return '42';
      }
    });
    const out = await h.run([mkTarget('hang'), mkTarget('ok')], mkEnv(), { bridgeTimeoutMs: 80 });
    const hang = byId(out.results, 'hang');
    const ok = byId(out.results, 'ok');
    assert.equal(ok.state, model.PROBE_STATE_SUCCESS, 'other node unaffected');
    assert.equal(hang.state, model.PROBE_STATE_FAILED);
    assert.ok(hang.errorDetail.toLowerCase().includes('timeout'), 'timeout detail kept');
    assert.equal(hang.latencyMs, -1);
    assert.equal(out.unfinished, 0, 'timeout node is failed, not unfinished');
    console.log('PASS 9 bridge timeout: failed node keeps timeout detail, round continues');
  }

  // ---------------- 10. runId/generation 守卫:迟到回调不写入本轮 ----------------
  {
    const h = makeHarness({ caps: 'v3' });
    const r1 = await h.run([mkTarget('a')], mkEnv(), {});
    const runId1 = r1.runId;
    const gen1 = r1.generation;
    let staleAccepted = null;
    h.cfg.onProxyV3 = async (sid, tag) => {
      const stale = new model.ProbeResult();
      stale.runId = runId1; // 上一轮的迟到回调
      stale.profileId = 'a';
      stale.state = model.PROBE_STATE_SUCCESS;
      stale.latencyMs = 999;
      stale.methodRequested = model.PROBE_METHOD_HTTP;
      stale.methodActual = model.PROBE_METHOD_HTTP;
      staleAccepted = h.runner.ingestResult(stale);
      return '42';
    };
    const r2 = await h.run([mkTarget('a')], mkEnv(), {});
    assert.equal(staleAccepted, false, 'late prior-round callback must be rejected');
    assert.equal(r2.generation, gen1 + 1, 'generation increments per round');
    const a = byId(r2.results, 'a');
    assert.equal(a.state, model.PROBE_STATE_SUCCESS);
    assert.equal(a.latencyMs, 42, 'current round result untouched');
    assert.equal(a.runId, r2.runId);
    console.log('PASS 10 runId/generation guard: late callback dropped, current round intact');
  }

  // ---------------- 11. V2 内核:旧导出串行路径 ----------------
  {
    const h = makeHarness({ caps: 'v2' });
    const out = await h.run([mkTarget('a'), mkTarget('b')], mkEnv(), {});
    assert.equal(out.capability, model.PROBE_CAP_NATIVE_V2);
    assert.equal(out.summary.success, 2);
    assert.equal(h.calls.starts.length, 1, 'legacy start used');
    assert.equal(h.calls.starts[0].v3, false, 'V2 path does not call V3 exports');
    assert.equal(h.calls.proxies.length, 2);
    assert.equal(h.calls.proxies[0].v3, false);
    assert.equal(h.calls.stops.length, 0, 'no V3 stop on V2 path');
    assert.equal(h.calls.stopsNoId, 2, 'pre-stop guard + final stop');
    assert.equal(out.results[0].coreCapability, model.PROBE_CAP_NATIVE_V2);
    console.log('PASS 11 v2 capability: legacy exports used serially, generation guard in place');
  }

  // ---------------- 12. stop 确认(sessionInfoV3) ----------------
  {
    // 12a: stop 报错但会话已 closed → 确认通过,节点照常
    {
      const h = makeHarness({ caps: 'v3', onStopV3: () => 'err:stop bridge timeout', onInfo: () => '{"state":"closed"}' });
      const out = await h.run([mkTarget('a'), mkTarget('b')], mkEnv(), {});
      assert.equal(out.summary.success, 2, 'closed session counts as confirmed');
      assert.equal(out.unfinished, 0);
    }
    // 12b: 停止不可确认 → 禁止下一批,剩余节点 unfinished(session_stop_unconfirmed)
    let stopCalls = 0;
    const h = makeHarness({
      caps: 'v3',
      onStart: (sid, configPath) => (configPath.indexOf('bad') >= 0 ? 'err:start failed: bad chain outbound' : ''),
      onStopV3: () => { stopCalls += 1; return stopCalls === 1 ? '' : 'err:stop bridge timeout'; },
      onInfo: () => '{"state":"stopping"}'
    });
    const out = await h.run([mkTarget('g1'), mkTarget('g2'), mkTarget('bad')], mkEnv(), {});
    const g1 = byId(out.results, 'g1');
    assert.equal(g1.state, model.PROBE_STATE_SUCCESS, 'probed nodes keep their results');
    const bad = byId(out.results, 'bad');
    assert.equal(bad.state, model.PROBE_STATE_CANCELLED, 'unconfirmed stop forbids further batches');
    assert.equal(bad.errorCode, 'session_stop_unconfirmed');
    assert.equal(out.unfinished, 1);
    console.log('PASS 12 stop confirmation: closed=confirmed, stopping=forbid next batch');
  }

  // ---------------- 13. 目录不可写 → 环境级失败,带原文 ----------------
  {
    const h = makeHarness({ caps: 'v3', dirWritable: false, dirError: 'write probe.json: disk full' });
    const out = await h.run([mkTarget('a')], mkEnv(), {});
    assert.equal(out.envError, 'test_dir_unwritable');
    assert.equal(out.tcpingOption, true);
    assert.equal(out.results[0].state, model.PROBE_STATE_NOT_APPLICABLE);
    assert.ok(out.degradeReason.includes('disk full'), 'original error text kept for the user');
    assert.equal(h.calls.starts.length, 0, 'env failure never starts a session');
    console.log('PASS 13 unwritable test dir: environment failure with original error text');
  }

  console.log('\nALL probe-runner checks passed');
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
