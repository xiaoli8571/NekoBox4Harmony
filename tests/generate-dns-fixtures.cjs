// Generate DNS blocks from production ETS, not hand-authored approximations.
// Only transport endpoints are isolated: loopback UDP, no proxy detour.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'..');
const sdk=process.env.DEVECO_SDK_HOME||'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts=require(path.join(sdk,'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
function load(file,imports={}) {
 const exports={};
 const js=ts.transpileModule(fs.readFileSync(path.join(root,file),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 vm.runInNewContext(js,{exports,require:n=>{if(!(n in imports))throw Error(n);return imports[n];}});
 return exports;
}
const model=load('entry/src/main/ets/model/Profile.ets');
const builder=load('entry/src/main/ets/core/ConfigBuilder.ets',{'../model/Profile':model,'../utils/TrafficStats':{CLASH_API_PORT:9090},'../model/RouteRule':{}});
const fixtures=[];
for(const mode of ['disable','enable','prefer','only']) for(const fake of [false,true]) {
 const p=Object.assign(new model.Profile(),{server:'example.invalid'});
 const s=Object.assign(new model.AppSettings(),{ipv6Mode:mode,fakeDns:fake,remoteDns:'127.0.0.1',directDns:'127.0.0.1'});
 const rules=['direct','proxy','reject'].map(outbound=>({enabled:true,domains:'full:'+outbound+'.parity.test',ip:'',source:'',port:'',sourcePort:'',network:'',protocol:'',packages:'',config:'',outbound}));
 const generated=JSON.parse(builder.buildCoreConfig(p,s,'','','','',rules));
 for(const server of generated.dns.servers) delete server.detour;
 fixtures.push({name:mode+'-fake-'+fake,config:{log:{level:'panic'},dns:generated.dns,outbounds:[{type:'direct',tag:'direct'}],route:{final:'direct',auto_detect_interface:false}}});
}
fs.writeFileSync(path.join(__dirname,'hostprobe/fixtures/production-dns.json'),JSON.stringify(fixtures,null,2)+'\n');
console.log('Generated '+fixtures.length+' production DNS fixtures (transport detours isolated; DNS rules untouched).');
