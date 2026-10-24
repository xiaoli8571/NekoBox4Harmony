// P6/W21 UI 静态守卫(§13/§24.2-6):读源码比对,防"中文兜底/无障碍/热区/等宽/双栏接线"回潮。
// 纯静态:不 VM 转译,只做注释剥离后的文本断言;与 settings-schema/i18n-keys 的读源码手法同源。
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');

const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');

/** 剥离 // 行注释与块注释,再去掉 LogStore/addLog 日志行(内部日志保留中文是既有约定) */
function stripCommentsAndLogs(src) {
  const out = [];
  let inBlock = false;
  for (const rawLine of src.split('\n')) {
    let line = rawLine;
    if (inBlock) {
      const end = line.indexOf('*/');
      if (end < 0) {
        continue;
      }
      line = line.slice(end + 2);
      inBlock = false;
    }
    // 行内块注释开头
    const bs = line.indexOf('/*');
    if (bs >= 0) {
      const be = line.indexOf('*/', bs);
      if (be >= 0) {
        line = line.slice(0, bs) + line.slice(be + 2);
      } else {
        line = line.slice(0, bs);
        inBlock = true;
      }
    }
    const ls = line.indexOf('//');
    if (ls >= 0) {
      line = line.slice(0, ls);
    }
    if (/LogStore\.addLog|\.addLog\(|persistPerApp\(/.test(line)) {
      line = '';
    }
    out.push(line);
  }
  return out.join('\n');
}

// ---------- 1. P5/P6 收口页面:代码区无中文兜底(注释/日志除外) ----------
{
  const files = [
    'entry/src/main/ets/pages/SubscriptionPage.ets',
    'entry/src/main/ets/pages/ConnectionsPage.ets',
    'entry/src/main/ets/pages/LogPage.ets',
    'entry/src/main/ets/pages/SubDetailPage.ets',
    'entry/src/main/ets/pages/SettingsPage.ets',
    'entry/src/main/ets/model/SubscriptionList.ets',
    'entry/src/main/ets/model/ConnectionView.ets',
    'entry/src/main/ets/model/LogView.ets'
    // SettingsSchema 不在本名单:它的中文全在 `keywords` 检索词(§12.1),显示层由
    // tests/i18n-keys.cjs 的 labelToken→资源键断言守着(模型只产 token)。
  ];
  for (const f of files) {
    const code = stripCommentsAndLogs(read(f));
    const chinese = code.match(/[\u4e00-\u9fff]+/g) || [];
    const hits = chinese;
    assert.equal(hits.length, 0, `${f}: 代码区出现中文兜底(应为资源键): ${hits.slice(0, 5).join(',')}`);
  }
  console.log('PASS 收口页面/模型:代码区无中文兜底(注释与内部日志除外)');
}

// ---------- 2. GlowIconButton 无障碍参数 + Index 顶栏接线 ----------
{
  const btn = read('entry/src/main/ets/common/components/GlowIconButton.ets');
  assert.ok(/@Param a11yText: ResourceStr/.test(btn), 'GlowIconButton 需暴露 a11yText');
  assert.ok(/@Param a11yReason: ResourceStr/.test(btn), 'GlowIconButton 需暴露 a11yReason');
  assert.ok(/\.accessibilityText\(this\.a11yTextString\(\)\)/.test(btn), 'GlowIconButton 需把 a11yText 接到 accessibilityText');
  const idx = read('entry/src/main/ets/pages/Index.ets');
  assert.ok(/a11yText: this\.actionA11yLabel\(action\.id\)/.test(idx), 'Index 顶栏动作需传无障碍名称');
  assert.ok(/a11yReason: action\.enabled \? '' : this\.actionReasonLabel\(action\.disabledReason\)/.test(idx),
    'Index 顶栏禁用动作需传禁用原因(§13.3)');
  assert.ok(/nav_reason_no_profiles/.test(idx), '禁用原因映射用 nav_reason_* 资源键');
  console.log('PASS 顶栏图标:无障碍名称 + 禁用原因接线');
}

// ---------- 3. 44×44 热区(§13.1:视觉可小,热区不缩小) ----------
{
  const sub = read('entry/src/main/ets/pages/SubscriptionPage.ets');
  assert.ok(/\.responseRegion\(\{ x: -8, y: -8, width: 44, height: 44 \}\)/.test(sub),
    '订阅行 28 高按钮需 responseRegion 扩到 44×44');
  const detail = read('entry/src/main/ets/pages/SubDetailPage.ets');
  assert.ok(/responseRegion/.test(detail), '订阅详情「转为手动」26 高按钮需扩热区');
  const idx = read('entry/src/main/ets/pages/Index.ets');
  assert.ok(/\.width\(44\)[\s\S]{0,80}\.height\(44\)/.test(idx), '顶栏图标槽保持 44×44');
  console.log('PASS 44×44 热区:小按钮 responseRegion 扩展');
}

// ---------- 4. 等宽数字(§13.1:延迟/速率等宽,列表不抖) ----------
{
  const idx = read('entry/src/main/ets/pages/Index.ets');
  assert.ok(/latencyToken\)[\s\S]{0,120}fontFamily\('monospace'\)/.test(idx), '节点行延迟需等宽数字');
  const conn = read('entry/src/main/ets/pages/ConnectionsPage.ets');
  assert.ok(/formatBytes\(c\.up\)[\s\S]{0,200}monospace/.test(conn), '连接行速率/字节需等宽');
  assert.ok(/traffic_speed_total[\s\S]{0,300}monospace/.test(conn), '连接页汇总速率需等宽');
  const sub = read('entry/src/main/ets/pages/SubscriptionPage.ets');
  assert.ok(/trafficText\(row\)[\s\S]{0,150}fontFamily\('monospace'\)/.test(sub), '订阅行流量需等宽');
  console.log('PASS 等宽数字:延迟/速率/流量');
}

// ---------- 5. 节点页侧边详情栏已撤(2026-10-24 真机用户反馈,防回潮) ----------
{
  const idx = read('entry/src/main/ets/pages/Index.ets');
  assert.equal(/nodeDetailPane|twoPaneEnabled|paneState|ResponsiveLayout/.test(idx), false,
    '节点页不得再有侧边详情栏/双栏接线(用户真机反馈明确不要)');
  assert.equal(require('node:fs').existsSync(path.join(root, 'entry/src/main/ets/model/ResponsiveLayout.ets')), false,
    'ResponsiveLayout 模型已随双栏撤回删除,不得回潮');
  assert.equal(/Button\(this\.primaryActionText\(\)\)/.test(idx), false,
    '状态卡不得再放「连接」主按钮(启动/断开统一走大电源键)');
  console.log('PASS 节点页单列布局:侧栏与状态卡连接按钮已撤');
}

// ---------- 6. 长文本/IPv6 不拼 undefined:连接视图守卫仍在 + 模板串不塞 Resource ----------
{
  const model = read('entry/src/main/ets/model/ConnectionView.ets');
  assert.ok(/s === 'undefined' \|\| s === 'null' \? '' : s/.test(model),
    'ConnectionView.str 需继续把 "undefined"/"null" 归一为空串');
  // P6 复审修过的回归点:startTimeText 的返回值进模板串拼接,必须声明 string
  // (Resource 进模板串会渲染成 [object Object],§24.2-6)
  const conn = read('entry/src/main/ets/pages/ConnectionsPage.ets');
  assert.ok(/private startTimeText\(item: ClashConnItem\): string/.test(conn),
    'ConnectionsPage.startTimeText 必须返回 string(其值进模板串)');
  console.log('PASS undefined 守卫 + 模板串不塞 Resource');
}

console.log('\nALL p6-ui-static checks passed');
