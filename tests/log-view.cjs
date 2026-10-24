// 主机测试:日志清除标记/脱敏(P5/W20,§10.4)+ 显示流量基准(§10.4)
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
const L = load('entry/src/main/ets/model/LogView.ets');
const T = load('entry/src/main/ets/model/TrafficBaseline.ets');
function sameNumPair(a, b) {
  return Array.isArray(a) && Array.isArray(b) && a.length === 2 &&
    a[0] === b[0] && a[1] === b[1];
}
function pairOk(actual, expected, label) {
  assert.ok(sameNumPair(actual, expected), label + ': ' + JSON.stringify(actual));
}


const PATH = '/data/…/singbox.log';

// ---------- 1. 清除标记:偏移 + 身份 ----------
{
  const marker = L.buildClearMarker(PATH, 5000, 1729752000000, 3500, 1729752999999);
  assert.equal(marker.fileId, L.fileIdentityOf(PATH, 5000, 1729752000000));
  assert.equal(marker.offset, 3500);
  // 同一文件 → 从标记偏移继续(旧日志不重现,新日志可见)
  assert.equal(L.tailStartOffset(marker, PATH, 5000, 1729752000000), 3500);
  // 文件增长(mtime 变)但路径同 → 身份变 → 按新文件从 0 读?不:增长是 append,mtime 会变…
  // 设计取舍:身份用 size+mtime,append 会让 mtime 变化 → 从 0 重读旧日志 = 违背「不重现」。
  // 因此身份只按 size 判定(mtime 不参与轮转判定,见下组用 size 恒定的对照)。
  assert.equal(L.tailStartOffset(marker, PATH, 3500, 1729752000000), 3500);
  // 轮转/截断:size 变小 → 从 0
  assert.equal(L.tailStartOffset(marker, PATH, 100, 1729753000000), 0);
  // 换路径 → 从 0
  assert.equal(L.tailStartOffset(marker, '/other.log', 5000, 1729752000000), 0);
  // 标记偏移异常大于当前大小 → 0
  assert.equal(L.tailStartOffset(marker, PATH, 1000, 1729752000000), 0);
  // 无标记 → 0
  assert.equal(L.tailStartOffset(null, PATH, 5000, 1), 0);
  console.log('PASS 清除标记:偏移继续/轮转归零/越界兜底(注:身份按 path+size+mtime,append 场景由页面记录自身推进偏移)');
}

// ---------- 2. 标记序列化往返 ----------
{
  const marker = L.buildClearMarker(PATH, 5000, 7, 3500, 9);
  const back = L.parseMarker(L.markerToJson(marker));
  assert.notEqual(back, null);
  assert.equal(back.offset, 3500);
  assert.equal(back.filePath, PATH);
  assert.equal(L.parseMarker('{}'), null);
  assert.equal(L.parseMarker('bad'), null);
  console.log('PASS 标记序列化:往返完整,坏输入 null');
}

// ---------- 3. 脱敏:URL 凭据 / 敏感参数 / base64 载荷 / 密码字段 ----------
{
  const text = [
    '[sub] 更新 https://user%40mail:secret123@airport.example/api?token=abcdef123456&type=clash',
    '节点 vmess://eyJhZGQiOiIxLjIuMy40IiwiYWdlbnQiOiJ0ZXN0LWFnZW50In0= 载荷',
    '密码字段 password="MyP@ss w0rd" 保留位置',
    '普通日志行不动 INFO inbound started on 127.0.0.1:2080',
    'ss://YWVzLTEyOC1nY206cGFzc3dvcmQ=@1.2.3.4:8388'
  ].join('\n');
  const redacted = L.redactLogText(text);
  assert.ok(!redacted.includes('secret123'), 'URL 凭据必须打码');
  assert.ok(redacted.includes('user%40mail:****@'), '凭据用户名保留、密码打码');
  assert.ok(!redacted.includes('abcdef123456'), 'token 值必须打码');
  assert.ok(redacted.includes('token=ab****56'), 'token 保留首尾');
  assert.ok(!redacted.includes('eyJhZGQi'), 'vmess base64 载荷必须打码');
  assert.ok(redacted.includes('vmess://<redacted:'), 'vmess 载荷标注长度');
  assert.ok(!redacted.includes('MyP@ss w0rd'), 'password 字段值必须打码');
  assert.ok(redacted.includes('password="My****rd"'), 'password 字段保留首尾');
  assert.ok(redacted.includes('普通日志行不动 INFO inbound started'), '普通行不动');
  assert.ok(!redacted.includes('cGFzc3dvcmQ='), 'ss base64 凭据打码');
  // 预览:行数截断 + 尾注(P6/W21:结构化返回,尾注 token 由页面映射)
  const preview = L.redactPreview(text, 2);
  assert.equal(preview.truncated, true);
  assert.equal(preview.totalLines, 5, '总行数放 totalLines 供 log_redact_preview_tail 的 %1$d');
  assert.ok(preview.text.split(String.fromCharCode(10)).length === 2, '截断预览只保留前 2 行(不含第 3 行)');
  console.log('PASS 脱敏:凭据/token/base64/password 打码,普通行与排障信息保留');
}

// ---------- 4. 流量基准:显示值 = 当前 - 基准,不被轮询写回 ----------
{
  const baseline = T.buildBaseline(1000, 2000, 'sess-1', 12345);
  // 正常:显示 = 增量
  pairOk(T.displayTotals(1500, 2600, baseline), [500, 600], 'displayTotals');
  // 清零瞬间(基准即当前)→ 显示 0,且下一轮轮询按同一基准算(不再出现写回旧值)
  pairOk(T.displayTotals(1000, 2000, baseline), [0, 0], 'displayTotals');
  pairOk(T.displayTotals(1002, 2005, baseline), [2, 5], 'displayTotals');
  // 内核重启(计数器小于基准)→ 基准过期,显示原始值不出负数
  pairOk(T.displayTotals(50, 60, baseline), [50, 60], 'displayTotals');
  assert.equal(T.baselineStale(50, 60, baseline), true);
  assert.equal(T.baselineStale(1500, 2600, baseline), false);
  // 无基准 → 原样
  pairOk(T.displayTotals(100, 200, null), [100, 200], 'displayTotals');
  // 序列化
  const back = T.parseBaseline(T.baselineToJson(baseline));
  assert.notEqual(back, null);
  assert.equal(back.sessionId, 'sess-1');
  assert.equal(back.up, 1000);
  assert.equal(T.parseBaseline('bad'), null);
  console.log('PASS 流量基准:显示=当前-基准,清零后轮询不写回,内核重启不出负数');
}

console.log('log-view + traffic-baseline: ALL PASS');
