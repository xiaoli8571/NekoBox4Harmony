// Executes actual Store save/load against an in-memory Preferences boundary.
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
const model=load('entry/src/main/ets/model/Profile.ets');
const data=new Map();
const prefs={get:async(k,d)=>data.has(k)?data.get(k):d,put:async(k,v)=>data.set(k,v),flush:async()=>{}};
const store=load('entry/src/main/ets/model/Store.ets',{
 './Profile':model,
 '@ohos.data.preferences':{default:{getPreferences:async()=>prefs}},
 '@ohos.events.emitter':{default:{emit:()=>{}}}
});
(async()=>{
 await store.initStore({});
 for(const value of ['bogus',true,7,null,{},[]]) {
  const s=Object.assign(new model.AppSettings(),{ipv6Mode:value,ipv6:true,clashApiSecret:'test-only'});
  await store.saveSettings(s);
  assert.equal(JSON.parse(data.get('settings')).ipv6Mode,'','invalid mode must be normalized before persistence');
  assert.equal((await store.loadSettings()).ipv6Mode,'');
 }
 for(const mode of ['', 'disable','enable','prefer','only']) {
  const s=Object.assign(new model.AppSettings(),{ipv6Mode:mode,ipv6:true,clashApiSecret:'test-only'});
  await store.saveSettings(s);
  assert.equal((await store.loadSettings()).ipv6Mode,mode);
 }
 data.set('settings',JSON.stringify({ipv6:true,clashApiSecret:'test-only'}));
 const legacy=await store.loadSettings();
 assert.equal(legacy.ipv6,true); assert.equal(legacy.ipv6Mode,'');
 data.set('settings',JSON.stringify({ipv6Mode:'bogus',ipv6:true,clashApiSecret:'test-only'}));
 assert.equal((await store.loadSettings()).ipv6Mode,'');
 console.log('PASS real Store save/load: invalid types normalized, valid modes retained, legacy boolean preserved');
 const routes=load('entry/src/main/ets/model/RouteRule.ets',{'./Store':store});
 const route=new routes.RouteRule(); route.protocol='http,tls\nquic'; route.port='443';
 await routes.saveRouteRules([route]);
 const loaded=await routes.loadRouteRules();
 assert.equal(loaded.length,1);
 assert.equal(loaded[0].protocol,'http,tls\nquic');
 assert.equal(loaded[0].port,'443');
 console.log('PASS real RouteRule save/load preserves multiple protocols and other AND fields');
 // End-to-end: whatever Store persists must be directly consumable by the
 // production ConfigBuilder (invalid mode normalized away, not just stored).
 const builder=load('entry/src/main/ets/core/ConfigBuilder.ets',{
  '../model/Profile':model,'../utils/TrafficStats':{CLASH_API_PORT:9090},'../model/RouteRule':routes
 });
 for(const bad of ['bogus',true]) {
  const p=new model.Profile(); p.server='example.invalid';
  const s=Object.assign(new model.AppSettings(),{ipv6Mode:bad,ipv6:true,clashApiSecret:'t'});
  await store.saveSettings(s);
  const reloaded=await store.loadSettings();
  const generated=JSON.parse(builder.buildCoreConfig(p,reloaded,'','','','',''));
  assert.equal(generated.dns.strategy,bad==='bogus'||bad===true?'prefer_ipv4':undefined,
   'normalized disable mode must yield ipv4_only');
  assert.deepEqual(generated.inbounds.find(x=>x.tag==='tun-in').address,['172.19.0.1/30','fdfe:dcba:9876::1/126'],
   'legacy ipv6:true must map to dual stack after normalization');
  console.log('PASS end-to-end store->configbuilder invalid mode '+JSON.stringify(bad)+' treated as legacy enable');
 }
})().catch(e=>{console.error(e);process.exitCode=1;});
