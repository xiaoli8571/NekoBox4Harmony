// 规则集「启动零网络」守卫(方案 docs/REMOTE_RULESET_ARCHITECTURE_REFACTOR_PLAN.md A1~A5)。
//
// 背景:P1 = 订阅里的远程规则集在 sing-box 里是 type:'remote',内核启动时自己下载,
// GitHub/DNS/TLS/URL 任一失败 → 整份配置校验失败 → VPN 起不来。方案要求:
//   1) buildCoreConfig 输出里 type:'remote' 的 rule_set **必须为 0**;
//   2) 不可用的规则集(无缓存/校验失败)整条跳过(定义与引用一起跳),不能留悬空引用
//      —— 否则内核报 rule-set not found,等价于把启动失败从网络搬到了配置层;
//   3) 启动链路(扩展进程)先 prepareResources 再 buildCoreConfig,VPN 建 TUN 前过 config check;
//   4) PreparedResource 保持纯数据(零 import),ConfigBuilder 才能无副作用被单测执行。
//
// 这是静态 + 执行双保险:执行断言走 production ConfigBuilder(SDK 转译),
// 静态断言守住 VpnExtAbility 的调用顺序(它依赖 @ohos.* 无法在 Node 里跑)。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

function load(file, imports = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(js, {
    exports,
    require: name => {
      if (!(name in imports)) throw new Error('Unexpected import: ' + name);
      return imports[name];
    }
  }, { filename: file });
  return exports;
}

const model = load('entry/src/main/ets/model/Profile.ets');
const prepared = load('entry/src/main/ets/core/PreparedResource.ets');
const builder = load('entry/src/main/ets/core/ConfigBuilder.ets', {
  '../model/Profile': model,
  '../utils/TrafficStats': { CLASH_API_PORT: 9090 },
  '../model/RouteRule': {},
  './PreparedResource': prepared
});

let pass = 0, fail = 0;
function check(label, cond, detail) {
  if (cond) { pass++; console.log(`PASS ${label}`); }
  else { fail++; console.log(`FAIL ${label}${detail ? ' :: ' + detail : ''}`); }
}

function ruleSet(tag, extra = {}) {
  return Object.assign({
    tag, resourceId: tag.replace(/^remote_/, ''), path: `/data/storage/el2/base/files/rulesets/${tag}.srs`,
    format: 'binary', available: true, verified: true, fromCache: true, state: 'ready', reason: '',
    error: '', outbound: 'proxy', failurePolicy: 'block', cachedAt: 0, downloaded: false
  }, extra);
}

function build(settings, preparedRuleSets) {
  const p = new model.Profile();
  p.type = 'trojan';
  p.server = 'example.invalid';
  p.password = 'pw';
  const s = Object.assign(new model.AppSettings(), { mode: 'rule' }, settings);
  return JSON.parse(builder.buildCoreConfig(p, s, '', '', '/data/geo/site.srs', '/data/geo/ip.srs',
    [], preparedRuleSets));
}

// ① 三态混合:可用 binary / 可用 source / 不可用 —— 只出 local,且不可用那条连引用都不留
{
  const sets = [
    ruleSet('remote_a'),
    ruleSet('remote_b', { format: 'source', path: '/data/storage/el2/base/files/rulesets/remote_b.json' }),
    ruleSet('remote_c', { available: false, path: '', state: 'unavailable', reason: 'no-cache' })
  ];
  const c = build({}, sets);
  const defs = c.route.rule_set || [];
  const remote = defs.filter(d => d.type === 'remote');
  check('混合输入:定义里没有 type:remote', remote.length === 0, JSON.stringify(defs));
  check('混合输入:可用规则集是 local + 绝对路径',
    defs.some(d => d.tag === 'remote_a' && d.type === 'local' && d.format === 'binary' && d.path.endsWith('remote_a.srs')),
    JSON.stringify(defs));
  check('混合输入:源格式保留 format:source',
    defs.some(d => d.tag === 'remote_b' && d.format === 'source'));
  check('混合输入:不可用规则集既不定义也不被引用',
    !defs.some(d => d.tag === 'remote_c') &&
    !c.route.rules.some(r => (r.rule_set || []).includes('remote_c')));
  check('混合输入:可用规则集有对应引用与出站',
    c.route.rules.some(r => (r.rule_set || []).includes('remote_a') && r.outbound === 'proxy'));
  check('混合输入:老字段 initial_path/update_interval 不再出现',
    !defs.some(d => 'initial_path' in d || 'update_interval' in d || 'url' in d));
}

// ② 全部不可用(最坏情况:GitHub 全挂)⇒ 配置仍然合法:无规则集定义、无悬空引用
{
  const c = build({}, [ruleSet('remote_x', { available: false, path: '', state: 'unavailable' })]);
  const defs = c.route.rule_set || [];
  check('全部不可用:只剩 geo 本地定义',
    defs.every(d => d.type === 'local') && !defs.some(d => d.tag === 'remote_x'), JSON.stringify(defs));
  check('全部不可用:没有指向 remote_x 的规则',
    !c.route.rules.some(r => (r.rule_set || []).includes('remote_x')));
  check('全部不可用:配置仍是可序列化的对象', typeof c.route.final === 'string');
}

// ③ geo 也走 local(方案 A4 的完整口径)
{
  const c = build({}, []);
  const geo = (c.route.rule_set || []).filter(d => d.tag === 'geosite_cn' || d.tag === 'geoip_cn');
  check('geo 规则集两条都是 local binary + path',
    geo.length === 2 && geo.every(d => d.type === 'local' && d.format === 'binary' && d.path.startsWith('/data/geo/')),
    JSON.stringify(geo));
  check('config 全文没有 "type":"remote" 的 rule_set',
    !(c.route.rule_set || []).some(d => d.type === 'remote'));
}

// ④ 纯 direct 模式(不带 geo)不应凭空造规则集
{
  const p = new model.Profile();
  p.type = 'trojan'; p.server = 'example.invalid'; p.password = 'pw';
  const s = Object.assign(new model.AppSettings(), { mode: 'direct' });
  const c = JSON.parse(builder.buildCoreConfig(p, s, '', '', '', '', [], [], '', [], []));
  check('direct 模式无 rule_set 定义', !c.route.rule_set || c.route.rule_set.length === 0,
    JSON.stringify(c.route.rule_set));
}

// ⑤ 静态守卫:代码里不再有把 rule_set 定义成 remote 的写法
{
  const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/ConfigBuilder.ets'), 'utf8');
  check('ConfigBuilder 无 type=remote 的 rule_set 生成',
    !/definition\['type'\]\s*=\s*'remote'/.test(src) && !/\['type'\]\s*=\s*'remote'/.test(src));
  check('buildGeoRuleSet 输出 local',
    /function buildGeoRuleSet\([\s\S]{0,400}?['"]type['"]\]\s*=\s*'local'/.test(src));
  const preparedSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/PreparedResource.ets'), 'utf8');
  check('PreparedResource 零 import(纯数据契约)', !/^\s*import\s/m.test(preparedSrc));
}

// ⑥ 静态守卫:扩展进程启动顺序 prepareResources → buildCoreConfig → config check → 建 TUN
{
  const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/vpnext/VpnExtAbility.ets'), 'utf8');
  const iPrepare = src.indexOf('ResourceResolver.prepareResources');
  const iBuild = src.indexOf('buildCoreConfig(');
  const iGateCall = src.indexOf('await this.checkConfigGate(');
  const iTun = src.indexOf('createVpnConnection');
  check('扩展进程先准备资源再 buildCoreConfig', iPrepare >= 0 && iPrepare < iBuild,
    `prepare=${iPrepare} build=${iBuild}`);
  check('建 TUN 前有 config check 闸门', iGateCall >= 0 && iGateCall < iTun,
    `gate=${iGateCall} tun=${iTun}`);
  check('有 prepareResources 之后的日志复盘文案', /\[vpn\] 规则集/.test(src));
  check('没有遗留 geoAssetVersion / initial_path 拼装', !/geoAssetVersion|initial_path/.test(src));
}

// ⑦ 静态守卫:UI 侧预校验同口径(只读快照,不下载)
{
  const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
  check('Index.checkConfigBeforeConnect 用 ResourceResolver.snapshot 且不下载',
    /ResourceResolver\.snapshot\(/.test(src) && !/ensureResource\(/.test(src));
  check('Index 不再直接拼 geo 路径给 buildCoreConfig',
    !/geoSitePath\(this\.context\)/.test(src));
}

// ⑧ 方案 §7 会话资源稳定：启动成功后固定资源文件，断开时解除
{
  const repo = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/RuleSetRepository.ets'), 'utf8');
  check('RuleSetRepository 提供会话资源固定 API',
    /static pinSessionFiles\(/.test(repo) && /static releaseSessionFiles\(/.test(repo));
  check('GC 不会删掉被固定的会话文件',
    /isPinned\(/.test(repo) && /isPinned\(path\)/.test(repo));
  const vpn = fs.readFileSync(path.join(root, 'entry/src/main/ets/vpnext/VpnExtAbility.ets'), 'utf8');
  const iPin = vpn.indexOf('ResourceResolver.pinSessionFiles(');
  const iStart = vpn.indexOf('CoreManager.startCore(');
  check('会话固定发生在启动内核之前', iPin >= 0 && iPin < iStart, `pin=${iPin} start=${iStart}`);
  check('teardown 解除会话固定',
    vpn.indexOf('ResourceResolver.releaseSessionFiles()') > vpn.indexOf('private async doTeardown('));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
