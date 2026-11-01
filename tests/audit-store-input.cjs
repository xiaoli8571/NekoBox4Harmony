// Execute production Store against malformed persisted/imported data, not a copied model.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:/Program Files/Huawei/DevEco Studio/sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
function load(file, imports = {}) {
  const exports = {};
  const js = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  vm.runInNewContext(js, { exports, console: {info(){}}, require: n => { if (!(n in imports)) throw Error(n); return imports[n]; } });
  return exports;
}
const models = load('entry/src/main/ets/model/Profile.ets');
const perApp = load('entry/src/main/ets/model/PerApp.ets');
const data = new Map([['defaults_fix_v3', '1']]);
const pref = {get: async (k,d) => data.has(k) ? data.get(k) : d, put: async (k,v) => data.set(k,v), flush: async()=>{}};
const store = load('entry/src/main/ets/model/Store.ets', {
  './Profile': models, './PerApp': perApp,
  '@ohos.data.preferences': {default: {getPreferences: async()=>pref}},
  '@ohos.events.emitter': {default: {emit(){}, EventPriority:{LOW:0}}}
});
(async()=>{
  await store.initStore({});
  data.set('settings', JSON.stringify({ testUrl: 3, clashApiSecret: 99, perAppEntries: true,
    mtu: 'broken', mixedPort: {}, testConcurrent: 2.7, autoConnect: 'false', unexpected: 'discard' }));
  const s = await store.loadSettings();
  assert.equal(s.testUrl, 'http://cp.cloudflare.com/');
  assert.equal(typeof s.clashApiSecret, 'string');
  assert.ok(s.clashApiSecret.length > 0);
  assert.equal(s.mtu, 1400);
  assert.equal(s.mixedPort, 2080);
  assert.equal(s.testConcurrent, 2);
  assert.equal(s.autoConnect, false);
  assert.equal(s.unexpected, undefined);
  console.log('PASS malformed persisted settings retain typed defaults and bounded integer concurrency');
  data.set('profiles', JSON.stringify([{id:'good',name:'Good',server:'example.invalid', subGroupIds:['g',4],serverPort:'bad'}, null, 2, 'bad']));
  const profiles = await store.loadProfiles();
  assert.equal(profiles.length,1);
  assert.equal(profiles[0].id,'good');
  assert.equal(profiles[0].serverPort,443);
  assert.equal(JSON.stringify(profiles[0].subGroupIds),'["g"]');
  profiles[0].subGroupIds.push('mutation');
  assert.equal(JSON.stringify((await store.loadProfiles())[0].subGroupIds),'["g"]');
  console.log('PASS bad records isolated; valid profile retained; array cache does not alias callers');
  data.set('profiles', JSON.stringify('not-an-array'));
  assert.equal((await store.loadProfiles()).length,0);
  data.set('profile_groups',JSON.stringify([null,7,{id:'g',name:'Group',sortOrder:'invalid'}]));
  const groups=await store.loadGroups();
  assert.equal(groups.length,1); assert.equal(groups[0].sortOrder,0);
  console.log('PASS malformed collection roots and group entries rejected without fake defaults');
})().catch(e=>{console.error(e);process.exitCode=1;});
