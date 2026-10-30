// 主机测试:内核版本串与构建能力一致性(2026-10-30 复盘)
//
// 背景:2.5.0 首包在真机上报
//   "gVisor is not included in this build, rebuild with -tags with_gvisor"
// 原因是 core/scripts/build-libsingbox-ohos.sh 的 BUILD_TAGS 缺 with_gvisor,
// 而 App 侧 ConfigBuilder.TUN_STACK 固定为 'gvisor'。同时诊断/关于页把内核版本
// 硬编码为旧串 1.14.0,导致问题被掩盖、排查时误判内核版本。
//
// 本测试把这三者绑成一条断言链,任何一处漂移都会红:
//   1. wrapper main.go 的 CGoSingBoxVersion 与 sing-box 源码版本一致
//   2. AboutPage / ToolsPage 展示的内核版本串与 main.go 一致
//   3. BUILD_TAGS 含 with_gvisor(且含 App 依赖的 quic/utls/clash_api)
//   4. ConfigBuilder.TUN_STACK 为 gvisor 时,BUILD_TAGS 必须含 with_gvisor
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');

function read(rel) {
  return fs.readFileSync(path.join(root, rel), 'utf8');
}

// ---- 1. main.go 里的内核版本串 ----
const mainGo = read('core/libsingbox14/main.go');
const versionMatch = mainGo.match(/C\.CString\("([0-9][^"]*-ohos-inproc)"\)/);
assert.ok(versionMatch, 'main.go 未找到 CGoSingBoxVersion 的版本串字面量');
const kernelVersion = versionMatch[1];
assert.match(kernelVersion, /^\d+\.\d+\.\d+/, `内核版本串格式异常: ${kernelVersion}`);

// ---- 2. 界面展示串必须与 main.go 同源 ----
// 展示串格式为 "sing-box <ver> (OHOS c-shared)",内核内部串为 "<ver>-ohos-inproc",
// 只要求版本号本体一致,允许各自的展示/内部后缀。
function versionCore(text) {
  return text.replace(/\s*\(OHOS c-shared\)\s*$/, '').replace(/-ohos-inproc$/, '').trim();
}
const kernelCore = versionCore(kernelVersion);
assert.match(kernelCore, /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$/, `内核版本本体解析异常: ${kernelCore}`);

const pages = {
  'entry/src/main/ets/pages/AboutPage.ets': /CORE_VERSION\s*=\s*'sing-box ([^']+)'/,
  'entry/src/main/ets/pages/ToolsPage.ets': /kernelVersion\s*=\s*'sing-box ([^']+)'/
};
for (const [file, re] of Object.entries(pages)) {
  const src = read(file);
  const m = src.match(re);
  assert.ok(m, `${file} 未找到内核版本展示字面量`);
  assert.equal(
    versionCore(m[1]), kernelCore,
    `${file} 展示的内核版本 ${m[1]} 与 main.go 的 ${kernelVersion} 版本号不一致`
  );
}

// ---- 3. 构建标签必须覆盖 App 侧依赖的能力 ----
const buildScript = read('core/scripts/build-libsingbox-ohos.sh');
const tagsMatch = buildScript.match(/^BUILD_TAGS="([^"]+)"/m);
assert.ok(tagsMatch, 'build-libsingbox-ohos.sh 未找到 BUILD_TAGS 定义');
const tags = tagsMatch[1].split(',').map((s) => s.trim()).filter(Boolean);
for (const required of ['with_gvisor', 'with_quic', 'with_utls', 'with_clash_api']) {
  assert.ok(tags.includes(required), `BUILD_TAGS 缺少 ${required}(当前: ${tags.join(',')})`);
}

// ---- 4. App 固定 gvisor 栈 → 内核必须带 with_gvisor ----
const configBuilder = read('entry/src/main/ets/core/ConfigBuilder.ets');
const stackMatch = configBuilder.match(/TUN_STACK\s*:\s*string\s*=\s*'([^']+)'/);
assert.ok(stackMatch, 'ConfigBuilder 未找到 TUN_STACK 常量');
if (stackMatch[1] === 'gvisor') {
  assert.ok(
    tags.includes('with_gvisor'),
    'App 侧 TUN_STACK=gvisor 但内核 BUILD_TAGS 缺 with_gvisor(运行时会报 gVisor is not included)'
  );
}

// ---- 5. sing-box 源码目录与版本串一致(防内核源码与包装层错配) ----
const wrapperGoMod = read('core/libsingbox14/go.mod');
const replaceMatch = wrapperGoMod.match(/replace github\.com\/sagernet\/sing-box => (.+)/);
if (replaceMatch) {
  const target = replaceMatch[1].trim();
  assert.match(
    target, /sing-box-1\.15/,
    `wrapper 仍指向 ${target},与内核版本串 ${kernelVersion} 不一致`
  );
}

console.log(`kernel-version: ok (${kernelVersion}, tags=${tags.join(',')}, stack=${stackMatch[1]})`);
