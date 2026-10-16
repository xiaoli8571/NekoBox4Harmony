// User-Agent 回退(E7)—— 不少机场按 UA 分流不同格式:
// 只认 clash.meta 的返回 Clash YAML,只认 v2rayN/sing-box 的返回 base64 或 JSON。
// 单一 UA 命中不对就表现为「解析不到节点」,用户只能去订阅设置手工试错。
// 本测试验证:回退列表存在、默认 UA 不在回退列表里(否则会自我重复请求)、
// 回退被限制在「已用 UA 之外」且不参与 provider-only 分支。
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const sub = fs.readFileSync(path.join(root, 'entry/src/main/ets/utils/Subscription.ets'), 'utf8');
const core = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/Subscriptions.ets'), 'utf8');

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + (detail !== undefined ? ' — ' + detail : '')); }
}

const uaMatch = sub.match(/export const SUB_UA\s*=\s*'([^']+)'/);
const fbMatch = sub.match(/export const SUB_UA_FALLBACKS[\s\S]*?\[([\s\S]*?)\]/);
check('SUB_UA is exported', !!uaMatch, uaMatch && uaMatch[1]);
check('SUB_UA_FALLBACKS is exported', !!fbMatch);

const defaultUa = uaMatch ? uaMatch[1] : '';
const fallbacks = fbMatch ? (fbMatch[1].match(/'([^']+)'/g) || []).map(s => s.replace(/'/g, '')) : [];
check('fallback list is non-empty', fallbacks.length >= 2, fallbacks.length + ': ' + fallbacks.join(','));
check('fallback list does not repeat the default UA', fallbacks.indexOf(defaultUa) < 0,
  fallbacks.join(','));
check('fallback list has no internal duplicates',
  new Set(fallbacks).size === fallbacks.length, fallbacks.join(','));
check('fallback list covers both YAML and base64/JSON clients',
  fallbacks.some(u => /clash|stash/i.test(u)) && fallbacks.some(u => /v2rayn|sing-box/i.test(u)),
  fallbacks.join(','));

// ---- 调用侧:回退必须在 0 节点时才触发,且跳过已用 UA ----
check('core imports the fallback list', /SUB_UA_FALLBACKS/.test(core));
check('core imports SUB_UA for the "tried UA" message', /SUB_UA/.test(core));
const loopAt = core.indexOf('for (const ua of SUB_UA_FALLBACKS)');
check('core iterates the fallback list', loopAt > 0);
check('core skips the UA it already used', core.indexOf('if (ua === usedUa)') > 0);
check('fallback is gated on parsing 0 nodes',
  /if \(parsed\.length === 0 && note !== 'clash_provider_only'\)/.test(core),
  'gating line not found');
check('fallback is skipped for provider-only (providers were already followed)',
  core.indexOf("note !== 'clash_provider_only'") > 0);
check('empty or identical bodies are skipped (no pointless reparse)',
  /altContent\.trim\(\)\.length === 0 \|\| altContent === content/.test(core));
check('a successful fallback replaces the parsed result', /parsed = alt\.profiles;/.test(core));
check('the fallback UA is logged for diagnosis', /LogStore\.addLog\(`\[sub\]/.test(core));
check('failure message names the UA that was tried', /已尝试的 User-Agent/.test(core));

// ---- 请求次数上限:失败路径最多 1 + len(fallbacks) 次 ----
console.log(`  (max requests on a failing update: 1 + ${fallbacks.length} = ${1 + fallbacks.length})`);
check('fallback count is bounded (<= 4 extra requests)', fallbacks.length <= 4, fallbacks.length);

console.log(`\n${pass} user-agent fallback checks passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
