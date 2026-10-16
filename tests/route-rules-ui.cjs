// Source-level + behavioral regression guard for the route-rules page ForEach keys.
// Bug: the remote rule-set list used a bare `item.id` key, so updateRemoteRuleSet's
// in-place mutations (type/outbound/enabled) never changed the key — ForEach kept the
// stale child and the 「域名规则/IP 规则」「直连/代理」buttons appeared dead (highlight stuck).
// Pure static parse of RouteRulesPage.ets (no device / no UI runtime), then the extracted
// key generators are executed to assert the exact invalidation contract ForEach relies on.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/RouteRulesPage.ets'), 'utf8');

// Extract the key generator `(item, index) => ...` that closes the ForEach starting at `marker`.
// It is the first line-leading `}, (params) => expr)` after the marker; params may be typed
// (`item: RemoteRuleSet`), and the template literal may sit on the following line.
function keyFn(source, marker) {
  const at = source.indexOf(marker);
  assert.ok(at >= 0, `missing ForEach marker: ${marker}`);
  const m = source.slice(at).match(/\n[ \t]*\}, \(([^)]*)\) =>[\s\n]*(`[^`]+`|[^\n]+)\)/);
  assert.ok(m, `no key generator found after ${marker}`);
  const params = m[1].split(',').map(p => p.trim().split(':')[0].trim());
  return new Function(...params, `return ${m[2]}`);
}

const remoteKey = keyFn(src, 'ForEach(this.remoteRuleSets');
const rs = { id: 'r1', name: 'cn', url: 'https://x/list.srs', type: 'site', outbound: 'direct', enabled: true, lastError: '', updatedAt: 1 };

// Every field the card renders from and the buttons mutate must change the key,
// otherwise ForEach reuses the stale child and the button highlight freezes.
assert.notEqual(remoteKey(rs, 0), remoteKey({ ...rs, type: 'ip' }, 0), 'type change must invalidate the card (IP 规则 button)');
assert.notEqual(remoteKey(rs, 0), remoteKey({ ...rs, outbound: 'proxy' }, 0), 'outbound change must invalidate the card (代理 button)');
assert.notEqual(remoteKey(rs, 0), remoteKey({ ...rs, enabled: false }, 0), 'enabled change must invalidate the card');
assert.notEqual(remoteKey(rs, 0), remoteKey({ ...rs, lastError: 'boom' }, 0), 'lastError change must invalidate the card');
assert.notEqual(remoteKey(rs, 0), remoteKey(rs, 1), 'index change (↑↓ reorder) must invalidate the card');
console.log('PASS remote rule-set key invalidates on type/outbound/enabled/lastError/index');

// Anti-regression: name/url/updatedAt change on EVERY keystroke (updateRemoteRuleSet also
// stamps updatedAt per call). Including them in the key would rebuild the whole card —
// TextInputs included — per keystroke, losing input focus. They must stay out of the key.
assert.equal(
  remoteKey(rs, 0),
  remoteKey({ ...rs, name: 'other', url: 'https://y/list.srs', updatedAt: Date.now() }, 0),
  'typing name/url must NOT change the key (per-keystroke rebuild loses input focus)');
console.log('PASS remote rule-set key ignores name/url/updatedAt (typing stays focused)');

// The custom-rules list had the same bug (missing outbound) and was fixed with a
// cover-everything key; guard it against regressions too.
const ruleKey = keyFn(src, 'ForEach(this.rules');
const rule = { remark: 'r', type: 'site', outbound: 'proxy', enabled: true, network: 'any', packagesEnabled: false, packages: '', appLabel: '' };
assert.notEqual(ruleKey(rule, 0), ruleKey({ ...rule, outbound: 'direct' }, 0), 'rule.outbound must be part of the rules key');
assert.notEqual(ruleKey(rule, 0), ruleKey(rule, 1), 'rules key must include index');
console.log('PASS custom-rules key still covers outbound + index (historic fix kept)');
