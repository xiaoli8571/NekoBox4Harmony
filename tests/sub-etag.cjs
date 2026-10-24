// ETag/304 锁死回归(2026-09-27)——B3,阻断级。
//
// 根因:updateSubscription 曾在**解析之前**把 ETag/Last-Modified 落盘。若那一次
// 响应正文是机场错误页/限流/劫持(解析出 0 节点并抛错),校验器却已记住;之后每次
// 自动更新都带 If-None-Match 拿到 304 → 走「内容未变」分支 → 永远保留 0 个节点,
// 而且 UI 一直显示「更新成功」。用户表现为「导入订阅解析不到节点,重试多少次都没用」。
//
// 本测试用源码断言 + 一个可执行的 HTTP 状态机,验证:
//  1. 校验器落盘发生在 parsed.length > 0 之后(而不是之前);
//  2. 304 分支对本订阅 0 节点的情况有强制重下的兜底;
//  3. 旧代码顺序(先落盘后解析)会真的把状态机锁死 —— 红测试对照。
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
// W17 起更新事务搬至 core/SubscriptionRepository.ets(Subscriptions.updateSubscription 只做委托);
// 断言意图不变:校验器只能在解析成功后落盘,304 对 0 节点订阅强制重下。
const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/SubscriptionRepository.ets'), 'utf8');
const subsSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/Subscriptions.ets'), 'utf8');

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + (detail !== undefined ? ' — ' + detail : '')); }
}

check('updateSubscription delegates to the transaction repository',
  subsSrc.includes('SubscriptionRepository.runUpdate(url)'));

const fetchStart = src.indexOf('private static async fetchAndParse');
const commitStart = src.indexOf('private static async commitUpdate');
check('transaction phases located', fetchStart > 0 && commitStart > fetchStart);
const fetchFn = src.slice(fetchStart, commitStart);
const commitFn = src.slice(commitStart);

// ---- 1. 校验器落盘必须晚于「解析出节点」的判断 ----
// fetchAndParse(锁外)遇到 0 节点直接抛错,函数内不写任何 sub.etag/sub.lastModified;
// 落盘只发生在 commitUpdate(sub.etag = prep.etag),而 commitUpdate 只可能在
// fetchAndParse 成功返回 prep 之后被调用 —— 结构上保证「先解析成功,后落盘」。
const zeroAt = fetchFn.indexOf('if (parsed.length === 0)');
check('the 0-node guard exists in the fetch/parse phase', zeroAt > 0);
check('0 nodes throws with a diagnosable message',
  fetchFn.indexOf('throw new Error(subFailureText(') > 0);
check('no validator persistence in the fetch/parse phase',
  !/sub\.etag\s*=/.test(fetchFn) && !/sub\.lastModified\s*=/.test(fetchFn));
check('validators are persisted only in the commit phase',
  commitFn.includes('sub.etag = prep.etag') && commitFn.includes('sub.lastModified = prep.lastModified'));

// ---- 2. 304 分支必须有「本订阅 0 节点则强制重下」的兜底 ----
const guardAt = fetchFn.indexOf('fetched.notModified && ownedBefore === 0');
check('304 branch re-fetches when this subscription owns no nodes', guardAt > 0);
check('the re-fetch drops the validators (sends no If-None-Match)',
  guardAt > 0 && fetchFn.indexOf("customUA, '', ''") > guardAt);
check("ownedBefore counts this subscription existing nodes",
  /ownedBefore\s*=\s*existing\.filter\(\(p: Profile\)\s*=>\s*p\.subUrl\s*===\s*url\)\.length/.test(fetchFn));

// ---- 3. 抛错路径不得留下已落盘的校验器(执行对照见下) ----

// ---- 4. 红测试对照:把状态机显式跑一遍,证明旧顺序会锁死 ----
// 服务端:带 ETag。若客户端发 If-None-Match 就回 304,否则回「错误页 + ETag」。
function makeServer() {
  const state = { served: 0 };
  return {
    state,
    respond(headers) {
      // 返回 {code, body}
      if (headers['if-none-match'] === '"v1"') return { code: 304, body: '' };
      state.served++;
      return { code: 200, body: '<html>error page from provider</html>' };
    }
  };
}

// 旧逻辑:先落盘校验器,再解析 → 第一次失败后永久 304
function oldFlow(server, store) {
  const r1 = server.respond({});
  if (r1.code === 200) store.etag = '"v1"';       // ← 提前落盘(旧行为)
  const parsed = 0;                                // 正文是错误页 → 0 节点 → 抛错
  if (parsed === 0) throw new Error('no nodes');
  return 'ok';
}

// 新逻辑:解析成功后才落盘 + 0 节点时脱掉校验器重下
function newFlow(server, store) {
  const ownedBefore = 0;
  let r1 = server.respond(store.etag ? { 'if-none-match': store.etag } : {});
  if (r1.code === 304 && ownedBefore === 0 && store.etag) {
    r1 = server.respond({});                       // ← 强制重下
  }
  if (r1.code === 304) return 'notModified';
  const parsed = 0;                                 // 错误页仍然解析不出节点
  if (parsed === 0) {
    // 关键:这里不写 store.etag
    throw new Error('no nodes');
  }
  store.etag = '"v1"';
  return 'ok';
}

const s1 = makeServer(), store1 = { etag: '' };
let oldErr = null;
try { oldFlow(s1, store1); } catch (e) { oldErr = e.message; }
check('old flow: first attempt fails', oldErr === 'no nodes');
check('old flow: validator was wrongly persisted', store1.etag === '"v1"');
// 第二次:带 If-None-Match → 304 → 旧代码当成「内容未变」,永远 0 节点
const r2 = s1.respond({ 'if-none-match': store1.etag });
check('old flow: second attempt gets 304 and is stuck at 0 nodes', r2.code === 304);

const s2 = makeServer(), store2 = { etag: '' };
let newErr = null;
try { newFlow(s2, store2); } catch (e) { newErr = e.message; }
check('new flow: first attempt fails', newErr === 'no nodes');
check('new flow: validator NOT persisted on failure', store2.etag === '');
// 第二次:没有校验器 → 走全量请求 → 不会被 304 锁死
const r3 = s2.respond(store2.etag ? { 'if-none-match': store2.etag } : {});
check('new flow: second attempt is a full request, not 304', r3.code === 200);

console.log(`\n${pass} etag/304 checks passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
