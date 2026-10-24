// 通知栏文本格式化回归:运行时长 h:mm:ss / mm:ss 边界 + 非法值兜底。
// 生产代码直接加载(DevEco SDK 的 typescript 转译 + Node 桩),不是副本。
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
    console
  });
  return exports;
}

const { formatUptimeText } = load('entry/src/main/ets/utils/NotifyText.ets');

const cases = [
  // [毫秒, 期望文本, 说明]
  [0, '00:00', '刚连上'],
  [999, '00:00', '不足 1 秒向下取整'],
  [1000, '00:01', '1 秒'],
  [59000, '00:59', '59 秒'],
  [60000, '01:00', '整 1 分钟'],
  [3599000, '59:59', '差 1 秒到 1 小时:仍走 mm:ss'],
  [3600000, '1:00:00', '整 1 小时:切 h:mm:ss'],
  [3661000, '1:01:01', '1 小时 1 分 1 秒'],
  [36000000, '10:00:00', '10 小时:小时位不补零'],
  [-5000, '00:00', '负值(时钟回拨/未初始化)兜底'],
  [Number.NaN, '00:00', 'NaN 兜底']
];

let pass = 0;
const fails = [];
for (const [ms, want, why] of cases) {
  const got = formatUptimeText(ms);
  if (got === want) {
    pass++;
  } else {
    fails.push(`formatUptimeText(${ms}) = ${JSON.stringify(got)}, 期望 ${JSON.stringify(want)} —— ${why}`);
  }
}

// 单调性:时间递增不可能让文本回退到更小的"总秒数"表示(抽样)
function toSeconds(text) {
  const parts = text.split(':').map((v) => parseInt(v, 10));
  return parts.length === 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts[0] * 60 + parts[1];
}
let prev = -1;
for (let s = 0; s <= 7200; s += 7) {
  const text = formatUptimeText(s * 1000);
  const sec = toSeconds(text);
  if (sec !== s) {
    fails.push(`抽样 ${s}s → ${text} 反解 ${sec}s 不一致`);
    break;
  }
  if (sec < prev) {
    fails.push(`样本非单调:${s}s 之后回到 ${sec}s`);
    break;
  }
  prev = sec;
}
if (fails.length === 0) {
  pass++;
}

console.log(fails.length === 0 ? 'PASS' : fails.map((f) => `FAIL  ${f}`).join('\n'));
console.log(`\n${pass} 组通过, ${fails.length} 组失败`);
if (fails.length > 0) {
  process.exitCode = 1;
} else {
  console.log('ALL notify-text tests passed');
}
