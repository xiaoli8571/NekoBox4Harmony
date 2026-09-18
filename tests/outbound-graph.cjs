// Production builder graph checks. No copied graph algorithm.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
const sdk=process.env.DEVECO_SDK_HOME||'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts=require(path.join(sdk,'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
function load(file,imports={}) { const exports={}; vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root,file),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,{exports,console,require:n=>{if(!(n in imports))throw Error(n);return imports[n];}});return exports; }
const model=load('entry/src/main/ets/model/Profile.ets');
const builder=load('entry/src/main/ets/core/ConfigBuilder.ets',{'../model/Profile':model,'../utils/TrafficStats':{CLASH_API_PORT:9090},'../model/RouteRule':{}});
const p=(id,fields={})=>Object.assign(new model.Profile(),{id,type:'socks',server:'127.0.0.1',serverPort:1080,name:'same'},fields);
const group=(id,fields={})=>Object.assign(new model.ProfileGroup(),{id},fields);
const rule=id=>({enabled:true,outbound:'profile:'+id,domains:'full:target.test',ip:'',source:'',port:'',sourcePort:'',network:'',protocol:'',packages:'',config:''});
const settings=Object.assign(new model.AppSettings(),{sniffMode:'off',remoteDns:'127.0.0.1',directDns:'127.0.0.1'});
const build=(selected,all,groups=[],rules=[])=>JSON.parse(builder.buildCoreConfig(selected,settings,'','','','',rules,[],'',all,groups));
const nodes=c=>[...c.outbounds,...(c.endpoints||[])];
function pathFrom(c,tag){const list=[];const seen=new Set();while(tag){assert.ok(!seen.has(tag),'detour cycle');seen.add(tag);const n=nodes(c).find(x=>x.tag===tag);assert.ok(n,'dangling '+tag);list.push(n.server||n.peers?.[0]?.address);tag=n.detour;}return list;}
function check(c){const tags=nodes(c).map(x=>x.tag);assert.equal(new Set(tags).size,tags.length);for(const n of nodes(c)){if(n.detour)pathFrom(c,n.tag);if(n.type==='selector'){assert.ok(tags.includes(n.default));for(const t of n.outbounds)assert.ok(tags.includes(t));}}for(const r of c.route.rules)if(r.outbound)assert.ok(tags.includes(r.outbound));}
let n=0;const test=(name,fn)=>{fn();n++;console.log('PASS '+name);};
const f=p('f',{server:'front.test'}),l=p('l',{server:'landing.test'}),a=p('a',{groupId:'g',server:'a.test'}),b=p('b',{groupId:'other',server:'b.test'});
const groups=[group('g',{frontProxy:'f',landingProxy:'l'}),group('other',{frontProxy:'f'})];
test('root group wrappers follow physical front-selected-landing order',()=>{const c=build(a,[a,f,l],groups);check(c);assert.deepEqual(pathFrom(c,'proxy'),['landing.test','a.test','front.test']);});
test('rule target builds its own group graph and emits no builtin proxy DNS rule',()=>{const c=build(a,[a,b,f,l],groups,[rule('b')]);check(c);const r=c.route.rules.find(x=>x.domain?.includes('target.test'));assert.deepEqual(pathFrom(c,r.outbound),['b.test','front.test']);assert.ok(!c.dns.rules.some(x=>x.domain?.includes('target.test')));});
test('active profile reference aliases proxy',()=>{const c=build(a,[a,f,l],groups,[rule('a')]);assert.equal(c.route.rules.find(x=>x.domain?.includes('target.test')).outbound,'proxy');});
test('selector has current-group members only and selected default',()=>{const c1=p('c',{groupId:'g',server:'c.test'});const c=build(a,[a,b,c1,f,l],[group('g',{isSelector:true})],[rule('c')]);check(c);const sel=c.outbounds.find(x=>x.tag==='proxy');assert.equal(sel.type,'selector');assert.equal(sel.outbounds.length,2);assert.deepEqual(pathFrom(c,sel.default),['a.test']);assert.ok(sel.outbounds.includes(c.route.rules.find(x=>x.domain?.includes('target.test')).outbound));});
test('recursive chains preserve physical order and do not reapply hop groups',()=>{const inner=p('inner',{type:'chain',chainIds:'a,b'}),outer=p('outer',{type:'chain',chainIds:'f,inner',groupId:'g2'});const c=build(outer,[outer,inner,a,b,f,l],[...groups,group('g2',{landingProxy:'l'})]);check(c);assert.deepEqual(pathFrom(c,'proxy'),['landing.test','b.test','a.test','front.test']);});
test('missing/cyclic chain fails instead of silently shortening path',()=>{const x=p('x',{type:'chain',chainIds:'missing'});assert.throws(()=>build(x,[x]),/missing|不存在/);x.chainIds='x';assert.throws(()=>build(x,[x]),/cycle|循环/);});
test('missing rule reference is skipped rather than silently sent through proxy',()=>{const c=build(a,[a,f,l],groups,[rule('missing')]);check(c);assert.ok(!c.route.rules.some(x=>x.domain?.includes('target.test')));});
test('latency graph retains wrappers but excludes selector and resolves server hostnames',()=>{
 const result=builder.buildLatencyTestConfig([a],[a,f,l],settings,'',[group('g',{isSelector:true,frontProxy:'f',landingProxy:'l'})]);
 const c=JSON.parse(result.json);
 assert.deepEqual(Array.from(result.tags),['t0']);
 assert.deepEqual(pathFrom(c,'t0'),['landing.test','a.test','front.test']);
 assert.ok(!c.outbounds.some(x=>x.type==='selector'));
 assert.deepEqual(c.route.rules,[]);
 const resolver=c.route.default_domain_resolver.server;
 assert.ok(c.dns.servers.some(x=>x.tag===resolver));
 check(c);
});
test('production wrapper registers selector just as host probe does',()=>{
 const source=fs.readFileSync(path.join(root,'core/libsingbox14/lean_context.go'),'utf8');
 assert.match(source,/group\.RegisterSelector\(outboundRegistry\)/);
});
const fixtures=[
 {name:'wrapped-rule-target',config:build(a,[a,b,f,l],groups,[rule('b')])},
 {name:'selector-target',config:build(a,[a,p('c',{groupId:'g'}),f,l],[group('g',{isSelector:true,frontProxy:'f',landingProxy:'l'})],[rule('c')])}
];
// Isolate platform TUN and persistence only. Preserve all generated routes,
// DNS, outbounds, selector references and detours for actual kernel startup.
for(const fixture of fixtures){delete fixture.config.inbounds;delete fixture.config.experimental;}
fs.writeFileSync(path.join(__dirname,'hostprobe/fixtures/production-graphs.json'),JSON.stringify(fixtures,null,2)+'\n');
console.log(n+' production graph checks passed; not device hot-switch verification.');
