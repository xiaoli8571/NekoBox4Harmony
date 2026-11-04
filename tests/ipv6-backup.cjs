// Real production Backup export/import with an in-memory persistence boundary.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require('./lib/deveco-ts.cjs').loadTs();
if (ts === null) {
  console.log(`SKIP ipv6-backup.cjs: 本机没有 DevEco Studio SDK(CI 环境),跳过 ArkTS 交叉核对`);
  process.exit(0);
}
function load(file, imports = {}) {
 const source = fs.readFileSync(path.join(root, file), 'utf8');
 const js = ts.transpileModule(source, {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 const exports = {};
 vm.runInNewContext(js, { exports, require: name => { if (!(name in imports)) throw Error(name); return imports[name]; } });
 return exports;
}
const model = load('entry/src/main/ets/model/Profile.ets');
let settings = new model.AppSettings();
let writes = 0;
/* Restore must land every section through one atomic boundary: the production
   Store.replaceBackupData writes all keys then flushes once. Counting calls here
   proves the six independent save*() writes are gone. */
let replaceCalls = 0;
const empty = async () => [];
const save = async () => { writes++; };
const replaceAll = async (s) => { settings = s; writes++; replaceCalls++; };
const backup = load('entry/src/main/ets/core/Backup.ets', {
 '../model/Profile':model,
 '../model/Store':{initStore:async()=>{},loadSettings:async()=>settings,saveSettings:async v=>{settings=v; writes++;},loadProfiles:empty,saveProfiles:save,loadGroups:empty,saveGroups:save,replaceBackupData:replaceAll,LogStore:{addLog:()=>{}}},
 '../model/RouteRule':{loadRouteRules:empty,saveRouteRules:save,loadRemoteRuleSets:empty,saveRemoteRuleSets:save},
 './Subscriptions':{listSubs:empty,saveSubs:save},
 // 明文导出路径不会调用加解密;真加密往返由 backup-crypto.cjs 覆盖。
 './BackupCrypto':{encryptBackup:async()=>{throw Error('not used');},
  decryptBackup:async()=>{throw Error('not used');},isEncryptedBackup:()=>false}
});
(async()=>{
 // 'auto' is preserved as a string for compatibility, not a supported UI mode.
 for (const mode of ['', 'auto', 'disable', 'enable', 'prefer', 'only']) {
  settings = Object.assign(new model.AppSettings(), {ipv6Mode:mode});
  const text = await backup.exportBackup({});
  settings = new model.AppSettings();
  await backup.importBackup({}, text);
  assert.equal(settings.ipv6Mode,mode);
  console.log('PASS backup export/import mode '+JSON.stringify(mode));
 }
 for (const invalid of [true, false, 1, null]) {
  const text = JSON.stringify({schemaVersion:4,profiles:[],settings:{ipv6Mode:invalid}});
  const before = writes;
  await assert.rejects(backup.importBackup({},text), /backup_bad_format/);
  assert.equal(writes,before,'invalid backup must not mutate persistence');
 }
 const legacy = JSON.stringify({schemaVersion:4,profiles:[],settings:{ipv6:true}});
 await backup.importBackup({},legacy);
 assert.equal(settings.ipv6,true);
 assert.equal(settings.ipv6Mode,undefined);
 console.log('PASS invalid modes rejected before writes; legacy backup retained');
 // One imported backup == exactly one atomic replace, never six sequential saves.
 const beforeReplace = replaceCalls;
 const beforeWrites = writes;
 await backup.importBackup({}, JSON.stringify({schemaVersion:4,profiles:[],settings:{ipv6Mode:'prefer'}}));
 assert.equal(replaceCalls - beforeReplace, 1, 'restore must use a single atomic replace');
 assert.equal(writes - beforeWrites, 1, 'restore must not write key by key');
 console.log('PASS restore commits through one atomic replace (no partial-write window)');
})().catch(e=>{console.error(e);process.exitCode=1;});
