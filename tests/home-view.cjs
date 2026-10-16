// Executes the real home-view logic (collapse persistence + subscription view selection).
// Regression guard for m02331 (collapse lost after page switch) and for the
// ''(ungrouped) entry that must survive the JSON/legacy serialization formats.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
function load(file, imports={}) {
 const source=fs.readFileSync(path.join(root,file),'utf8');
 const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 const exports={};
 vm.runInNewContext(js,{exports,require:n=>{if(!(n in imports)) throw Error(n);return imports[n];}});
 return exports;
}
const hv=load('entry/src/main/ets/model/HomeView.ets');
// JSON array format (2.1.5+): the '' entry is the ungrouped group id and must survive.
assert.equal(JSON.stringify(hv.parseCollapsedIds('["g1",""]')),JSON.stringify(['g1','']));
console.log('PASS parse JSON collapse list keeps the empty (ungrouped) id');
assert.equal(JSON.stringify(hv.parseCollapsedIds('[]')),JSON.stringify([]));
// legacy '|' format from 2.0.x/2.1.0 builds
assert.equal(JSON.stringify(hv.parseCollapsedIds('g1|g2')),JSON.stringify(['g1','g2']));
assert.equal(JSON.stringify(hv.parseCollapsedIds('g1|')),JSON.stringify(['g1','']));
console.log('PASS legacy pipe-separated collapse state still parses (trailing empty id kept)');
assert.equal(JSON.stringify(hv.parseCollapsedIds('')),JSON.stringify([]));
// malformed JSON must not throw, falls back to the legacy splitter
assert.equal(JSON.stringify(hv.parseCollapsedIds('[g1')),JSON.stringify(['[g1']));
// non-string entries are dropped rather than leaking into the id list
assert.equal(JSON.stringify(hv.parseCollapsedIds('["g1",7,null]')),JSON.stringify(['g1']));
console.log('PASS malformed/foreign collapse payloads degrade safely');
// round-trip through the production serializer
const round=hv.parseCollapsedIds(hv.serializeCollapsedIds(['a','','b']));
assert.equal(JSON.stringify(round),JSON.stringify(['a','','b']));
console.log('PASS collapse state round-trips through the production serializer');
// toggling is pure (input untouched) and idempotent in pairs
const before=['g1'];
const added=hv.toggleCollapsed(before,'g2');
assert.equal(JSON.stringify(before),JSON.stringify(['g1']),'toggleCollapsed must not mutate its input');
assert.equal(JSON.stringify(added),JSON.stringify(['g1','g2']));
assert.equal(JSON.stringify(hv.toggleCollapsed(added,'g2')),JSON.stringify(['g1']));
assert.equal(JSON.stringify(hv.toggleCollapsed(['g1'],'')),JSON.stringify(['g1','']),'ungrouped id must be toggleable');
console.log('PASS toggleCollapsed is pure and handles the ungrouped id');
// bottom subscription selector resolution
const subs=['https://a/sub','https://b/sub'];
assert.equal(hv.resolveSelectedSub('https://b/sub','https://a/sub',subs),'https://b/sub','persisted selection wins');
assert.equal(hv.resolveSelectedSub('','https://b/sub',subs),'https://b/sub','falls back to the running subscription');
assert.equal(hv.resolveSelectedSub('https://gone/sub','https://gone/sub',subs),'https://a/sub','stale persisted+active values fall back to the first subscription');
assert.equal(hv.resolveSelectedSub('','',subs),'https://a/sub');
assert.equal(hv.resolveSelectedSub('','',[]),'','no subscriptions means the manual view');
console.log('PASS subscription selector resolution (persisted > active > first > manual)');
// per-view node filtering: '' is the manual (non-subscription) view
assert.equal(hv.inSubView('https://a/sub','https://a/sub'),true);
assert.equal(hv.inSubView('https://b/sub','https://a/sub'),false);
assert.equal(hv.inSubView('','https://a/sub'),false,'manually imported nodes must not leak into a subscription view');
assert.equal(hv.inSubView('',''),true,'manual view shows exactly the non-subscription nodes');
assert.equal(hv.inSubView('https://a/sub',''),false,'subscription nodes must not leak into the manual view');
console.log('PASS subscription views are disjoint from the manual view');
