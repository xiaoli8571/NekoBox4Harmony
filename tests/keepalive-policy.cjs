// 后台保活策略(2026-10-23 整改)回归:传输期长时任务 + 被杀自愈决策的纯函数。
//
// 每条断言都能从 SDK/逆向证据推导(取证见 docs/REA-FLCLASH-KEEPALIVE.md):
//   - TASK_KEEPING 在 phone/tablet 必需受限 ACL KEEP_BACKGROUND_RUNNING_SYSTEM
//     (backgroundTaskManager.d.ts BackgroundTaskMode.MODE_TASK_KEEPING 注释)⇒ 会话不保活
//   - DATA_TRANSFER "10 分钟无进度通知(live view)将被取消"
//     (d.ts MODE_DATA_TRANSFER 注释)⇒ 只有真实传输才允许持有,且需在 8 分钟告警线内收尾
//   - 被杀自愈对齐 FlClash AppCrashWatcher 语义(hiAppEvent APP_KILLED + 持久化运行态),
//     决策规则:上次被杀 && 现在没连 && 有 profileId ⇒ 按设置重连或询问
//
// 生产代码直接加载(DevEco SDK 的 typescript 转译 + Node 桩),不是复制的逻辑副本。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';

let cachedTs = null;
function loadTs() {
  if (cachedTs === null) {
    cachedTs = require(path.join(sdk,
      'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
  }
  return cachedTs;
}

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
    setTimeout,
    clearTimeout,
    console
  });
  return exports;
}

const policy = load('entry/src/main/ets/core/KeepAlivePolicy.ets');

const results = [];
function check(name, fn) {
  try {
    fn();
    results.push(`PASS  ${name}`);
  } catch (e) {
    results.push(`FAIL  ${name}: ${e.message}`);
    process.exitCode = 1;
  }
}

// ── 1. 只有真实数据传输允许持有 DATA_TRANSFER 长时任务 ──
check('subscription 允许持有', () => {
  assert.equal(policy.shouldHoldTransfer('subscription'), true);
});
check('geo 允许持有', () => {
  assert.equal(policy.shouldHoldTransfer('geo'), true);
});
check('session(VPN 会话)拒绝 —— 会话保活不合法', () => {
  assert.equal(policy.shouldHoldTransfer('session'), false);
});
check('未知/空场景拒绝', () => {
  assert.equal(policy.shouldHoldTransfer(''), false);
  assert.equal(policy.shouldHoldTransfer('whatever'), false);
});
check('内部标签不含 dataTransfer/taskKeeping 字面量(避免误用 SDK 枚举当场景名)', () => {
  assert.equal(policy.TRANSFER_REASONS.includes('dataTransfer'), false);
  assert.equal(policy.TRANSFER_REASONS.includes('taskKeeping'), false);
});

// ── 2. 8 分钟告警线 < 10 分钟系统取消线(SDK:无进度通知 10 分钟取消) ──
check('TRANSFER_WARN_MS 严格小于 TRANSFER_CANCEL_MS(留 2 分钟余量)', () => {
  assert.ok(policy.TRANSFER_WARN_MS < policy.TRANSFER_CANCEL_MS);
  assert.equal(policy.TRANSFER_CANCEL_MS - policy.TRANSFER_WARN_MS, 2 * 60 * 1000);
});
check('7 分 59 秒未到告警线', () => {
  assert.equal(policy.transferNeedsWarn(8 * 60 * 1000 - 1000), false);
});
check('8 分钟整已到告警线', () => {
  assert.equal(policy.transferNeedsWarn(8 * 60 * 1000), true);
});
check('10 分钟剩余安全窗口为 0', () => {
  assert.equal(policy.transferRemainingMs(10 * 60 * 1000), 0);
  assert.ok(policy.transferRemainingMs(0) > 0);
});

// ── 3. 被杀自愈决策(FlClash AppCrashWatcher 同语义) ──
check('上次被杀+未连接+开自动连接 ⇒ 直接重连', () => {
  assert.equal(policy.killRecoveryAction(true, false, 'profile-1', true), 'reconnect');
});
check('上次被杀+未连接+关自动连接 ⇒ 询问', () => {
  assert.equal(policy.killRecoveryAction(true, false, 'profile-1', false), 'prompt');
});
check('上次被杀+现在已连接 ⇒ 不动作(autoConnect 场景已自行处理)', () => {
  assert.equal(policy.killRecoveryAction(true, true, 'profile-1', true), 'none');
  assert.equal(policy.killRecoveryAction(true, true, 'profile-1', false), 'none');
});
check('上次干净退出 ⇒ 不动作', () => {
  assert.equal(policy.killRecoveryAction(false, false, 'profile-1', true), 'none');
  assert.equal(policy.killRecoveryAction(false, false, 'profile-1', false), 'none');
});
check('被杀但无 profileId ⇒ 不动作(无从恢复)', () => {
  assert.equal(policy.killRecoveryAction(true, false, '', true), 'none');
  assert.equal(policy.killRecoveryAction(true, false, '', false), 'none');
});

// ── 4. 被杀标记的持久化编码(纯字符串,进程死亡后 Preferences 仍在) ──
check('encode/decode 往返一致', () => {
  const raw = policy.encodeKillState(true, 'profile-42', 1761187200000);
  const s = policy.decodeKillState(raw);
  assert.equal(s.alive, true);
  assert.equal(s.profileId, 'profile-42');
  assert.equal(s.updatedAt, 1761187200000);
});
check('干净退出编码 alive=0', () => {
  const raw = policy.encodeKillState(false, 'profile-42', 1761187200000);
  assert.equal(policy.decodeKillState(raw).alive, false);
});
check('空串/坏数据一律按干净退出处理(不误触发恢复)', () => {
  for (const bad of ['', 'garbage', '1|p', 'x|y|z|extra']) {
    assert.equal(policy.decodeKillState(bad).alive, false, `bad input: ${JSON.stringify(bad)}`);
  }
});
check('profileId 含竖线会被拆错段 ⇒ 按坏数据处理(不误触发)', () => {
  // encode 不会产生这种输入(节点 id 为 uuid),防御性断言
  const s = policy.decodeKillState('1|a|b|c');
  assert.equal(s.alive, false);
});
check('updatedAt 为 NaN 时按 0 处理', () => {
  const s = policy.decodeKillState('1|p|not-a-number');
  assert.equal(s.updatedAt, 0);
  assert.equal(s.alive, true);
});

console.log(results.join('\n'));
console.log(`\n${results.filter((r) => r.startsWith('PASS')).length} passed, ` +
  `${results.filter((r) => r.startsWith('FAIL')).length} failed`);
if (process.exitCode !== 1) {
  console.log('ALL keepalive-policy tests passed');
}
