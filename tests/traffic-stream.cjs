// P1 单流量生产者守卫:扩展用内核 /traffic WebSocket 作为唯一流量来源,
// UI 不再自己轮询 /connections,速率条也从首页抽成独立组件。
//
// 这些断言都是**源码级**的(不是运行时):旧实现的问题是"UI 与通知各开一个
// 1s 定时器 + 全量解析连接列表",一旦有人在 Index 里把 startSpeedPoller 加回来,
// 或者把 vpnUpSpeed 重新挂回 Index(@StorageLink),整个首页就会再次每秒重建。
// 用静态断言把这两条路堵死。
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');

const ext = read('entry/src/main/ets/vpnext/VpnExtAbility.ets');
assert.match(ext, /private async startTrafficStream\(\)/, '扩展必须由 startTrafficStream 驱动流量');
assert.match(ext, /new TrafficStream\(\)/, '扩展必须使用 TrafficStream(内核 /traffic WebSocket)');
assert.ok(!/notificationTrafficTimer/.test(ext), '旧的 setInterval 轮询字段必须删除');
assert.ok(!/setInterval\(/.test(ext), '扩展进程不得再用定时器轮询 /connections');
assert.match(ext, /private async resyncTraffic\(/, 'WebSocket 每次打开要用 /connections 快照重对齐累计值');
assert.match(ext, /private handleClearTrafficCommand\(/, '清除流量统计要经命令通道同步通知基准');
console.log('PASS 扩展是唯一流量生产者(无 setInterval 轮询)');

const stream = read('entry/src/main/ets/vpnext/TrafficStream.ets');
assert.match(stream, /ws:\/\/127\.0\.0\.1:\$\{this\.port\}\/traffic/, '必须连内核 /traffic WebSocket');
assert.match(stream, /Math\.min\(10000/, '断线重连必须指数退避且封顶');
assert.match(stream, /callbacks\.onOpen\(\)/, '连接建立要回调 onOpen 触发 resync');
console.log('PASS TrafficStream: /traffic 端点 + 退避重连 + onOpen 重对齐');

const ipc = read('entry/src/main/ets/core/VpnIpc.ets');
assert.match(ipc, /payload\['rawUp'\]/, '流量事件必须带原始累计 up(供 UI 写基准)');
assert.match(ipc, /payload\['rawDown'\]/, '流量事件必须带原始累计 down');
const ability = read('entry/src/main/ets/entryability/EntryAbility.ets');
assert.match(ability, /vpnRawTotalUp/, 'EntryAbility 必须把原始累计写进 AppStorage');
assert.match(ability, /vpnRawTotalDown/);
console.log('PASS 流量事件携带 rawUp/rawDown 并落到 AppStorage');

const index = read('entry/src/main/ets/pages/Index.ets');
assert.ok(!/startSpeedPoller/.test(index), 'Index 不得再自己轮询 /connections');
assert.ok(!/speedTimer/.test(index), 'Index 不得保留旧的速率定时器');
assert.ok(!/@StorageLink\('vpnUpSpeed'\)/.test(index), '速率条抽成 StatsBar 后,首页不应因 1s 速率重建');
assert.match(index, /StatsBar\(\{/, '首页必须渲染抽出的 StatsBar 组件');
assert.match(index, /vpnRawTotalUp/, '清除流量统计必须用扩展推送的原始累计值');
console.log('PASS 首页不再轮询/订阅速率(只渲染 StatsBar)');

const bar = read('entry/src/main/ets/common/components/StatsBar.ets');
assert.match(bar, /@StorageLink\('vpnUpSpeed'\)/, 'StatsBar 自己订阅速率');
assert.match(bar, /backdropBlur\(20\)/, '底栏半透明模糊口径不得回退');
assert.match(bar, /private statusDisplay\(\)/, 'StatsBar 自带状态文案映射');
console.log('PASS StatsBar 独立组件(自订阅速率 + 保留半透明观感)');

console.log('\nALL traffic-stream checks passed');
