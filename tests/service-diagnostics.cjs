// 主机测试:服务可用性诊断判定(对齐 OwnBox ServiceDiagnosticsManager)
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

function load(file) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: () => { throw new Error('no imports expected'); } });
  return exports;
}

const D = load('entry/src/main/ets/core/ServiceDiagnostics.ets');

function probe(url, ok, status, body) {
  return D.ProbeResult.of(url, ok, status, body, ok ? '' : 'http_error');
}
const trace = (ip, loc) => `fl=1\nh=cloudflare\nip=${ip}\nts=1\nloc=${loc}\n`;

// ---------- 1. 服务清单:13 项、id 唯一、分类合法 ----------
{
  const defs = D.serviceDefs();
  assert.equal(defs.length, 13, '13 项服务(与 OwnBox createInitialList 同集合)');
  const ids = defs.map((d) => d.id);
  assert.equal(new Set(ids).size, 13, 'id 必须唯一');
  const cats = new Set([D.CAT_AI, D.CAT_STREAMING, D.CAT_COMMON]);
  for (const d of defs) {
    assert.ok(cats.has(d.category), `${d.id} 分类必须合法`);
    assert.ok(d.url.startsWith('https://'), `${d.id} 必须 https`);
  }
  assert.equal(D.servicesOfCategory(D.CAT_ALL).length, 13, 'all 返回全量');
  assert.equal(D.servicesOfCategory(D.CAT_AI).length, 3, 'AI 3 项');
  assert.equal(D.servicesOfCategory(D.CAT_STREAMING).length, 6, '流媒体 6 项');
  assert.equal(D.servicesOfCategory(D.CAT_COMMON).length, 4, '常用 4 项');
  console.log('PASS serviceDefs: 13 / ai=3 streaming=6 common=4');
}

// ---------- 2. 探测计划 ----------
{
  assert.equal(D.probeUrlsFor('google').length, 1);
  assert.equal(D.probeUrlsFor('chatgpt').length, 3, 'chatgpt 三步校验');
  assert.equal(D.probeUrlsFor('netflix').length, 3, 'netflix 三个 title');
  const bili = D.probeUrlsFor('bilibili');
  assert.equal(bili.length, 2, 'bilibili 主 + 港澳');
  assert.ok(bili[1].includes('ep_id=183799'), '第二请求是港澳专属内容');
  assert.equal(D.probeUrlsFor('nope').length, 1, '未知 id 返回主 URL 占位');
  assert.equal(D.probeUrlsFor('nope')[0], '', '未知 id 无 URL');
  console.log('PASS probeUrlsFor: 多步校验服务的请求顺序');
}

// ---------- 3. trace 解析与地区归一 ----------
{
  assert.equal(D.traceField(trace('1.2.3.4', 'JP'), 'ip'), '1.2.3.4');
  assert.equal(D.traceField(trace('1.2.3.4', 'jp'), 'loc'), 'jp');
  assert.equal(D.traceField('', 'loc'), '');
  assert.equal(D.traceField('noseparator', 'loc'), '');
  assert.equal(D.traceField('  loc = JP  ', 'loc'), '', '不容错空格键(与 cloudflare 实际格式一致)');

  assert.equal(D.normalizeRegion('jp'), 'JP');
  assert.equal(D.normalizeRegion('CHN'), 'CN');
  assert.equal(D.normalizeRegion('HKG'), 'HK');
  assert.equal(D.normalizeRegion('PRK'), 'KP');
  assert.equal(D.normalizeRegion('uk'), 'GB');
  assert.equal(D.normalizeRegion('  '), '');
  console.log('PASS traceField/normalizeRegion');
}

// ---------- 4. 国旗与 IP 打码 ----------
{
  assert.equal(D.countryFlag('JP'), '🇯🇵');
  assert.equal(D.countryFlag('us'), '🇺🇸');
  assert.equal(D.countryFlag('HKG'), '🇭🇰');
  assert.equal(D.countryFlag(''), '🌐');
  assert.equal(D.countryFlag('X'), '🌐');
  assert.equal(D.countryFlag('1A'), '🌐');

  assert.equal(D.maskIp('1.2.3.4'), '1.2.*.*');
  assert.equal(D.maskIp('2001:db8:1:2:3:4:5:6'), '2001:db8:****:****');
  assert.equal(D.maskIp(''), '');
  assert.equal(D.maskIp('weird'), 'weird');
  console.log('PASS countryFlag/maskIp');
}

// ---------- 5. 各服务判定 ----------
{
  // 无响应 → unavailable
  assert.equal(D.classify('google', [probe('u', false, 0, '')], 5).state, D.STATE_UNAVAILABLE);
  // 空 probes 也不炸
  assert.equal(D.classify('google', [], 5).state, D.STATE_UNAVAILABLE);

  // 纯连通类
  for (const id of ['google', 'github', 'disney']) {
    assert.equal(D.classify(id, [probe('u', true, 200, 'ok')], 1).state, D.STATE_AVAILABLE);
  }

  // claude:黑名单地区受限,白名单可用,无 loc 不可用
  assert.equal(D.classify('claude', [probe('u', true, 200, trace('1.1.1.1', 'HK'))], 1).state,
    D.STATE_RESTRICTED);
  assert.equal(D.classify('claude', [probe('u', true, 200, trace('1.1.1.1', 'HK'))], 1).region, 'HK');
  assert.equal(D.classify('claude', [probe('u', true, 200, trace('1.1.1.1', 'JP'))], 1).state,
    D.STATE_AVAILABLE);
  assert.equal(D.classify('claude', [probe('u', true, 200, 'garbage')], 1).state,
    D.STATE_UNAVAILABLE);

  // chatgpt:disallowed isp / 被封 / compliance 不支持国家
  assert.equal(D.classify('chatgpt', [
    probe('u0', true, 200, '{"error":"Disallowed ISP"}'),
    probe('u1', true, 200, trace('1.1.1.1', 'JP')),
    probe('u2', true, 200, '{}')
  ], 1).state, D.STATE_RESTRICTED);
  assert.equal(D.classify('chatgpt', [
    probe('u0', true, 200, 'Sorry, you have been blocked'),
    probe('u1', true, 200, trace('1.1.1.1', 'JP')),
    probe('u2', true, 200, '{}')
  ], 1).state, D.STATE_UNAVAILABLE);
  assert.equal(D.classify('chatgpt', [
    probe('u0', true, 200, 'ok'),
    probe('u1', true, 200, trace('1.1.1.1', 'JP')),
    probe('u2', true, 200, '{"unsupported_country":true}')
  ], 1).state, D.STATE_RESTRICTED);
  const gptOk = D.classify('chatgpt', [
    probe('u0', true, 200, 'Request is not allowed'),
    probe('u1', true, 200, trace('1.1.1.1', 'SG')),
    probe('u2', true, 200, '{}')
  ], 1);
  assert.equal(gptOk.state, D.STATE_AVAILABLE);
  assert.equal(gptOk.region, 'SG');

  // gemini:页面里 ,2,1,200,"CHN" 标记
  assert.equal(D.classify('gemini', [probe('u', true, 200, 'x,2,1,200,"CHN",y')], 1).state,
    D.STATE_RESTRICTED);
  assert.equal(D.classify('gemini', [probe('u', true, 200, 'x,2,1,200,"USA",y')], 1).state,
    D.STATE_AVAILABLE);
  assert.equal(D.classify('gemini', [probe('u', true, 200, 'no marker')], 1).state,
    D.STATE_AVAILABLE);

  // youtube:countryCode + premium 文案
  const yt = D.classify('youtube', [probe('u', true, 200,
    '{"countryCode":"JP","premium":true}')], 1);
  assert.equal(yt.state, D.STATE_AVAILABLE);
  assert.equal(yt.region, 'JP');
  assert.equal(D.classify('youtube', [probe('u', true, 200,
    '{"GL":"DE"} Premium is not available in your country')], 1).state, D.STATE_RESTRICTED);

  // netflix:任一 title 可达即可
  assert.equal(D.classify('netflix', [
    probe('t1', false, 404, ''),
    probe('t2', true, 200, '<html>'),
    probe('t3', false, 404, '')
  ], 1).state, D.STATE_AVAILABLE);
  assert.equal(D.classify('netflix', [
    probe('t1', false, 404, ''), probe('t2', false, 404, ''), probe('t3', false, 404, '')
  ], 1).state, D.STATE_UNAVAILABLE);

  // prime / spotify
  assert.equal(D.classify('prime', [probe('u', true, 200, 'var isServiceRestricted = true')], 1).state,
    D.STATE_RESTRICTED);
  assert.equal(D.classify('spotify', [probe('u', true, 200, 'not available in your country')], 1).state,
    D.STATE_RESTRICTED);
  assert.equal(D.classify('spotify', [probe('u', true, 200, '{"countries":[]}')], 1).state,
    D.STATE_AVAILABLE);

  // tiktok:region 提取 + 拒绝文案
  const tt = D.classify('tiktok', [probe('u', true, 200,
    '{"webapp.app-context":{"language":"en","region":"US"}}')], 1);
  assert.equal(tt.state, D.STATE_AVAILABLE);
  assert.equal(tt.region, 'US');
  assert.equal(D.classify('tiktok', [probe('u', true, 200, 'Access Denied')], 1).state,
    D.STATE_RESTRICTED);

  // discord:country_code
  const dc = D.classify('discord', [probe('u', true, 200, '{"country_code":"JP"}')], 1);
  assert.equal(dc.state, D.STATE_AVAILABLE);
  assert.equal(dc.region, 'JP');

  // bilibili:主站可用=CN;地区限制但港澳可用=HK;都不行=受限
  const b1 = D.classify('bilibili', [probe('m', true, 200, '{"code":0}'), probe('h', false, 0, '')], 1);
  assert.equal(b1.state, D.STATE_AVAILABLE);
  assert.equal(b1.region, 'CN');
  const b2 = D.classify('bilibili', [probe('m', true, 200, '{"code":-10403}'), probe('h', true, 200, '{"code":0}')], 1);
  assert.equal(b2.state, D.STATE_AVAILABLE);
  assert.equal(b2.region, 'HK');
  const b3 = D.classify('bilibili', [probe('m', true, 200, '{"code":-10403}'), probe('h', true, 200, '{"code":-10403}')], 1);
  assert.equal(b3.state, D.STATE_RESTRICTED);
  assert.equal(D.classify('bilibili', [probe('m', true, 200, '{"code":-999}')], 1).state,
    D.STATE_UNAVAILABLE);
  console.log('PASS classify: 13 项服务的判定分支');
}

// ---------- 6. 汇总与排序 ----------
{
  const s = D.summarize([D.STATE_AVAILABLE, D.STATE_AVAILABLE, D.STATE_RESTRICTED,
    D.STATE_UNAVAILABLE, D.STATE_TESTING, D.STATE_IDLE]);
  assert.equal(s.total, 6);
  assert.equal(s.available, 2);
  assert.equal(s.restricted, 1);
  assert.equal(s.unavailable, 1);
  assert.equal(s.testing, 1);
  assert.equal(s.idle, 1);
  assert.equal(D.summarize([]).total, 0);

  assert.ok(D.stateRank(D.STATE_UNAVAILABLE) < D.stateRank(D.STATE_RESTRICTED));
  assert.ok(D.stateRank(D.STATE_RESTRICTED) < D.stateRank(D.STATE_AVAILABLE));
  assert.ok(D.stateRank(D.STATE_AVAILABLE) < D.stateRank(D.STATE_IDLE));
  console.log('PASS summarize/stateRank');
}

console.log('\nALL service-diagnostics checks passed');
