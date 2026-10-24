// W07:分应用策略校验(§8.2/§8.4 / REQ-13)。
// 走真实模块:用 DevEco SDK 的 typescript 转译生产 .ets,vm 里 stub 依赖后执行,
// 不重写被测逻辑(与 tests/ipv6-store.cjs、tests/per-app.cjs 同一模式)。
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
  vm.runInNewContext(js, { exports, require: n => { if (!(n in imports)) throw Error(n); return imports[n]; } });
  return exports;
}
const readSource = file => fs.readFileSync(path.join(root, file), 'utf8');

const pa = load('entry/src/main/ets/model/PerApp.ets');
const policy = load('entry/src/main/ets/model/PerAppPolicy.ets', { './PerApp': pa });

const entries = list => JSON.stringify(list.map(item => {
  if (typeof item === 'string') {
    return { bundleName: item, label: '', enabled: true };
  }
  return { bundleName: item.name, label: '', enabled: item.enabled !== false };
}));
const evaluate = (mode, json, api = 23) => policy.evaluatePerAppPolicy(mode, json, api);
const countPkgs = n => Array.from({ length: n }, (_, i) => `com.example.app${i}`);

// 纯函数约束:不得引入平台 API / I/O(两个调用点各自负责读 deviceInfo)
{
  const src = readSource('entry/src/main/ets/model/PerAppPolicy.ets');
  for (const bad of ['@ohos', '@kit', 'from \'fs\'', 'Preferences', 'deviceInfo']) {
    assert.ok(!src.includes(bad), `policy module must stay pure, found ${bad}`);
  }
}
console.log('PASS policy module is a platform-free pure module');

// ---------- §8.2 基础矩阵 ----------
{
  const empty = '[]';
  const offEmpty = evaluate('off', empty, 23);
  assert.equal(offEmpty.mode, 'off');
  assert.equal(offEmpty.blocked, false, 'off + empty must be allowed');
  assert.equal(offEmpty.blockReason, '');
  assert.equal(offEmpty.count, 0);
  assert.equal(JSON.stringify(offEmpty.effectivePackages), '[]');

  const offList = evaluate('off', entries([{ name: 'com.example.a' }, { name: 'com.example.b' }]), 23);
  assert.equal(offList.blocked, false, 'off + any list must be allowed (§8.2 rule 1)');
  assert.equal(offList.count, 2);

  const excludeEmpty = evaluate('exclude', empty, 23);
  assert.equal(excludeEmpty.blocked, false, 'exclude + empty must be allowed');
  assert.equal(excludeEmpty.count, 0, 'empty exclusion list means "nothing excluded"');

  const excludeList = evaluate('exclude', entries([{ name: 'com.example.a' }]), 23);
  assert.equal(excludeList.blocked, false);
  assert.equal(JSON.stringify(excludeList.effectivePackages), JSON.stringify(['com.example.a']));

  const includeEmpty = evaluate('include', empty, 23);
  assert.equal(includeEmpty.blocked, true, 'include + empty must be blocked (audit P1)');
  assert.equal(includeEmpty.blockReason, 'include_empty', 'blockReason must be the machine token');
  assert.equal(includeEmpty.count, 0);
  assert.equal(JSON.stringify(includeEmpty.effectivePackages), '[]', 'blocked result must not hand out a list');

  // 未勾选的条目不算"已选择":include + 全未勾选仍是空名单
  const includeUnchecked = evaluate('include', entries([{ name: 'com.example.a', enabled: false }]), 23);
  assert.equal(includeUnchecked.blocked, true);
  assert.equal(includeUnchecked.blockReason, 'include_empty');

  const includeOne = evaluate('include', entries([{ name: 'com.example.one', enabled: true }, { name: 'com.example.off', enabled: false }]), 23);
  assert.equal(includeOne.blocked, false);
  assert.equal(includeOne.count, 1);
  assert.equal(JSON.stringify(includeOne.effectivePackages), JSON.stringify(['com.example.one']),
    'only checked packages may be applied');

  // 非法/空 JSON 都按空名单处理(脏数据不能绕过 include 门控)
  for (const junk of ['', '   ', 'not-json', '{}', 'null']) {
    const r = evaluate('include', junk, 23);
    assert.equal(r.blocked, true, `include + junk ${JSON.stringify(junk)} must be blocked`);
    assert.equal(r.blockReason, 'include_empty');
  }
}
console.log('PASS §8.2: off/exclude allow empty lists, include+empty is blocked (include_empty)');

// ---------- §8.4 上限:API<23 → 64,API>=23 → 256 ----------
{
  assert.equal(policy.perAppListLimit(22), 64);
  assert.equal(policy.perAppListLimit(0), 64);
  assert.equal(policy.perAppListLimit(23), 256);
  assert.equal(policy.perAppListLimit(24), 256);

  // 边界:正好 64 允许,65 超限(API 22)
  const at64 = evaluate('include', entries(countPkgs(64)), 22);
  assert.equal(at64.limit, 64);
  assert.equal(at64.blocked, false, 'exactly at the limit must be allowed');
  assert.equal(at64.count, 64);
  assert.equal(at64.effectivePackages.length, 64);

  const at65 = evaluate('include', entries(countPkgs(65)), 22);
  assert.equal(at65.limit, 64);
  assert.equal(at65.blocked, true, '65 > 64 must be blocked on API 22');
  assert.equal(at65.blockReason, 'over_limit');
  assert.equal(at65.count, 65, 'count must locate the real total (not a truncated 64)');
  assert.equal(JSON.stringify(at65.effectivePackages), '[]', 'over-limit must not be silently truncated');

  // 同一份 65 个名单在 API 23 上允许(limit 256)
  const at65Api23 = evaluate('include', entries(countPkgs(65)), 23);
  assert.equal(at65Api23.limit, 256);
  assert.equal(at65Api23.blocked, false);
  assert.equal(at65Api23.effectivePackages.length, 65);

  // 边界:正好 256 允许,257 超限(API 23)
  const at256 = evaluate('include', entries(countPkgs(256)), 23);
  assert.equal(at256.limit, 256);
  assert.equal(at256.blocked, false);
  assert.equal(at256.effectivePackages.length, 256);

  const at257 = evaluate('include', entries(countPkgs(257)), 23);
  assert.equal(at257.limit, 256);
  assert.equal(at257.blocked, true, '257 > 256 must be blocked on API 23');
  assert.equal(at257.blockReason, 'over_limit');
  assert.equal(at257.count, 257, 'count must expose 257, not the truncated 256');

  // exclude 同样受容量约束:超限显式阻止,不截断后照常连接
  const excludeOver = evaluate('exclude', entries(countPkgs(65)), 22);
  assert.equal(excludeOver.blocked, true);
  assert.equal(excludeOver.blockReason, 'over_limit');

  // off 不附加名单(§8.2 第 1 条):超限列表仍允许连接,不会静默截断下发
  const offOver = evaluate('off', entries(countPkgs(65)), 22);
  assert.equal(offOver.blocked, false, 'off + any list is always allowed');
  assert.equal(offOver.count, 65);
}
console.log('PASS §8.4: API<23 limits to 64, API>=23 to 256; over-limit blocked as over_limit with real count');

// ---------- 重复/非法包名:过滤 + 进 dropped,不扩大范围 ----------
{
  const dupJson = JSON.stringify([
    { bundleName: 'com.example.dup', label: '', enabled: true },
    { bundleName: 'com.example.dup', label: '', enabled: true },
    { bundleName: 'com.example.solo', label: '', enabled: true },
  ]);
  const dupResult = evaluate('include', dupJson, 23);
  assert.equal(dupResult.blocked, false);
  assert.equal(dupResult.count, 2, 'duplicates must collapse to one (not expand the list)');
  assert.equal(JSON.stringify(dupResult.effectivePackages), JSON.stringify(['com.example.dup', 'com.example.solo']));
  assert.ok(dupResult.dropped.includes('com.example.dup'), 'duplicate name must be reported in dropped');

  const mixed = JSON.stringify([
    { bundleName: 'com.example.good', label: '', enabled: true },
    { bundleName: 'com.tencent-wechat', label: 'hyphen', enabled: true }, // 非法:含 '-'
    { bundleName: 'wechat', label: 'no dot', enabled: true },             // 非法:无点
    { bundleName: 'com.example.good', label: 'again', enabled: true },    // 重复
  ]);
  const mixedResult = evaluate('include', mixed, 23);
  assert.equal(mixedResult.blocked, false);
  assert.equal(mixedResult.count, 1);
  assert.equal(JSON.stringify(mixedResult.effectivePackages), JSON.stringify(['com.example.good']),
    'malformed names must never reach the effective list (system rejects the whole list)');
  assert.ok(mixedResult.dropped.includes('com.tencent-wechat'), 'malformed name is reported in dropped');
  assert.ok(mixedResult.dropped.includes('wechat'), 'malformed name is reported in dropped');
  assert.ok(mixedResult.dropped.includes('com.example.good'), 'duplicate good name is reported in dropped');

  // 勾选项全是非法包名 → 生效名单为空,同判空名单(不是"全部应用")
  const allBad = evaluate('include', entries([{ name: 'com.tencent-wechat' }, { name: 'wechat' }]), 23);
  assert.equal(allBad.blocked, true);
  assert.equal(allBad.blockReason, 'include_empty');
  assert.equal(allBad.dropped.length, 2);

  // 重复项不会被算成 dropped 之外的"额外范围":超限判定只数有效去重项
  const dupOver = JSON.parse(JSON.stringify(countPkgs(65).map(name => ({ bundleName: name, label: '', enabled: true }))));
  for (let i = 0; i < 40; i++) { dupOver.push({ bundleName: dupOver[i].bundleName, label: '', enabled: true }); }
  const dupOverResult = evaluate('include', JSON.stringify(dupOver), 22);
  assert.equal(dupOverResult.count, 65, 'duplicates must not inflate the effective count');
  assert.equal(dupOverResult.blocked, true);
  assert.equal(dupOverResult.blockReason, 'over_limit');
}
console.log('PASS duplicate/malformed bundle names are filtered, reported in dropped, and never expand the list');

// ---------- 非法模式归一到 off ----------
{
  for (const bogus of ['bogus', '', 'INCLUDE', 'Include', 'onn', 'off ', null, 7, undefined]) {
    const r = policy.evaluatePerAppPolicy(bogus, entries([{ name: 'com.example.a' }]), 23);
    assert.equal(r.mode, 'off', `unknown mode ${JSON.stringify(bogus)} must normalize to off`);
    assert.equal(r.blocked, false);
  }
  // 合法模式原样保留
  for (const ok of ['off', 'exclude', 'include']) {
    assert.equal(policy.evaluatePerAppPolicy(ok, '[]', 23).mode, ok);
  }
}
console.log('PASS unknown per-app modes normalize to off (same rule as Store.saveSettings)');

// ---------- 阻断文案:两侧共用,含数量定位 ----------
{
  const includeEmpty = evaluate('include', '[]', 23);
  const emptyMsg = policy.perAppBlockMessage(includeEmpty);
  assert.ok(emptyMsg.includes('至少选择一个有效应用'), 'include_empty message must tell the user to pick one');
  const over = evaluate('include', entries(countPkgs(65)), 22);
  const overMsg = policy.perAppBlockMessage(over);
  assert.ok(overMsg.includes('65'), 'over_limit message must show the real count');
  assert.ok(overMsg.includes('64'), 'over_limit message must show the limit');
}
console.log('PASS shared block messages mention the required action and the real counts');

// ---------- 生产接线:两侧必须 import 并调用同一纯函数(防"只写不接") ----------
{
  const uiSrc = readSource('entry/src/main/ets/core/VpnService.ets');
  const extSrc = readSource('entry/src/main/ets/vpnext/VpnExtAbility.ets');
  for (const [label, src] of [['VpnService.ets', uiSrc], ['VpnExtAbility.ets', extSrc]]) {
    assert.ok(/import\s*\{[^}]*evaluatePerAppPolicy[^}]*\}\s*from\s*'\.\.\/model\/PerAppPolicy'/.test(src),
      `${label} must import evaluatePerAppPolicy from model/PerAppPolicy`);
    assert.ok(src.includes('evaluatePerAppPolicy('), `${label} must actually call evaluatePerAppPolicy`);
    assert.ok(src.includes('currentSdkApiLevel()'), `${label} must derive the limit from sdkApiVersion`);
  }

  // UI 侧:策略校验必须在 startVpnExtensionAbility 之前(拦截时不启动扩展)
  const uiPolicyAt = uiSrc.indexOf('evaluatePerAppPolicy(');
  const uiStartAt = uiSrc.indexOf('startVpnExtensionAbility(');
  assert.ok(uiPolicyAt >= 0 && uiStartAt > uiPolicyAt, 'UI policy check must run before starting the extension');
  assert.ok(uiSrc.includes('connect_failed:'), 'UI block must publish a connect_failed status (existing convention)');
  assert.ok(uiSrc.includes('clearPendingProfileId()'), 'UI block must drop the pending start request');

  // 扩展侧:策略校验必须在创建 TUN 之前,且旧"静默降级全应用"日志已移除
  const extPolicyAt = extSrc.indexOf('evaluatePerAppPolicy(');
  const tunAt = extSrc.indexOf('this.vpnConnection.create(config)');
  assert.ok(extPolicyAt >= 0 && tunAt > extPolicyAt, 'extension policy check must run before TUN creation');
  assert.ok(!/LogStore\.addLog\('[^']*全部应用按路由规则处理/.test(extSrc),
    'the silent "all apps" fallback log statement must be gone (a historical comment may remain)');
  assert.ok(extSrc.includes('trustedApplications'), 'include mode must still write trustedApplications');
  assert.ok(extSrc.includes('blockedApplications'), 'exclude mode must still write blockedApplications');
  // Want 分支的 CSV 必须先转成 entries JSON,与读盘分支执行同一判定
  assert.ok(extSrc.includes('serializeEntries(entriesFromLegacyList('),
    'extension must feed Want CSV through the same entries-JSON evaluation as the disk branch');
}
console.log('PASS both production call sites import and call the shared pure policy function');

console.log('ALL PER-APP POLICY CHECKS PASSED');
