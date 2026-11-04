// Real production BackupCrypto round-trip against a faithful OHOS crypto shim.
// The shim implements the documented CryptoArchitectureKit contracts with
// node:crypto (PBKDF2-SHA256 -> AES-256-GCM), so envelope shape, tag handling,
// password verification and tamper detection are all exercised for real.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const nodeCrypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const ts = require('./lib/deveco-ts.cjs').loadTs();
if (ts === null) {
  console.log('SKIP backup-crypto.cjs: 本机没有 DevEco Studio SDK(CI 环境),跳过 ArkTS 交叉核对');
  process.exit(0);
}
function load(file, imports = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
  const exports = {};
  // canIUse 是 ArkTS 运行时全局;测试里按"能力齐备"注入,不支持的路径另测。
  const sandbox = { exports, canIUse: () => true,
    require: name => { if (!(name in imports)) throw Error(name); return imports[name]; } };
  vm.runInNewContext(js, sandbox);
  return exports;
}

const u8 = a => Uint8Array.from(a);
const cryptoFramework = {
  CryptoMode: { ENCRYPT_MODE: 0, DECRYPT_MODE: 1 },
  createRandom: () => ({ generateRandomSync: n => ({ data: u8(nodeCrypto.randomBytes(n)) }) }),
  createKdf: () => ({
    generateSecret: async spec => ({
      data: u8(nodeCrypto.pbkdf2Sync(
        typeof spec.password === 'string' ? spec.password : Buffer.from(spec.password),
        Buffer.from(spec.salt), spec.iterations, spec.keySize, 'sha256'))
    })
  }),
  createSymKeyGenerator: () => ({ convertKey: async blob => ({ key: Buffer.from(blob.data) }) }),
  createCipher: () => {
    let state = null;
    return {
      init: async (mode, key, spec) => {
        state = { mode, key: key.key, spec };
      },
      // GCM in OHOS appends the 16-byte tag to the ciphertext.
      doFinal: async blob => {
        if (state.mode === 0) {
          const c = nodeCrypto.createCipheriv('aes-256-gcm', state.key, Buffer.from(state.spec.iv.data));
          const body = Buffer.concat([c.update(Buffer.from(blob.data)), c.final()]);
          return { data: u8(Buffer.concat([body, c.getAuthTag()])) };
        }
        const d = nodeCrypto.createDecipheriv('aes-256-gcm', state.key, Buffer.from(state.spec.iv.data));
        d.setAuthTag(Buffer.from(state.spec.authTag.data));
        return { data: u8(Buffer.concat([d.update(Buffer.from(blob.data)), d.final()])) };
      }
    };
  }
};
const util = {
  Base64Helper: class { encodeToStringSync(b) { return Buffer.from(b).toString('base64'); }
    decodeSync(s) { return u8(Buffer.from(s, 'base64')); } },
  TextEncoder: class { encodeInto(s) { return u8(Buffer.from(s, 'utf8')); } },
  TextDecoder: { create: () => ({ decodeToString(b) { return Buffer.from(b).toString('utf8'); } }) }
};

// ETS 里是 default import,转成 CommonJS 后取 .default,所以 mock 需要包一层。
const crypto = load('entry/src/main/ets/core/BackupCrypto.ets', {
  '@ohos.security.cryptoFramework': { default: cryptoFramework },
  '@ohos.util': { default: util }
});

const PLAIN = JSON.stringify({ schemaVersion: 4, profiles: [{ name: '节点', password: 'p@ss' }] });
async function main() {
  // 1. 加密 -> 解封 往返
  const sealed = await crypto.encryptBackup(PLAIN, 'correct horse battery');
  assert.equal(crypto.isEncryptedBackup(sealed), true, 'envelope must be detected');
  assert.equal(await crypto.decryptBackup(sealed, 'correct horse battery'), PLAIN);
  const env = JSON.parse(sealed);
  assert.equal(env.format, 'nekobox-backup-encrypted');
  assert.equal(env.kdf, 'PBKDF2|SHA256');
  assert.equal(env.cipher, 'AES256|GCM|NoPadding');
  assert.ok(env.salt && env.iv && env.tag && env.payload, 'envelope carries salt/iv/tag/payload');
  assert.equal(Buffer.from(env.payload, 'base64').includes('p@ss'), false, 'ciphertext must not leak the password');
  console.log('PASS 加密备份可解封且密文不含明文口令');

  // 2. 明文备份不算信封(旧文件继续可用)
  assert.equal(crypto.isEncryptedBackup(PLAIN), false);
  assert.equal(crypto.isEncryptedBackup('not json'), false);
  console.log('PASS 旧版明文备份不被误判为信封');

  // 3. 口令错 / 口令太短 / 篡改
  await assert.rejects(crypto.decryptBackup(sealed, 'wrong password'), /backup_crypto_bad_password/);
  await assert.rejects(crypto.encryptBackup(PLAIN, 'short'), /backup_password_too_short/);
  const tampered = JSON.parse(sealed);
  const body = Buffer.from(tampered.payload, 'base64');
  body[0] = body[0] ^ 0xff;
  tampered.payload = body.toString('base64');
  await assert.rejects(crypto.decryptBackup(JSON.stringify(tampered), 'correct horse battery'),
    /backup_crypto_bad_password/);
  console.log('PASS 口令错误/过短/密文篡改都被拒绝');

  // 4. 每次加密都用新盐新 IV
  const second = await crypto.encryptBackup(PLAIN, 'correct horse battery');
  assert.notEqual(JSON.parse(second).salt, env.salt);
  assert.notEqual(JSON.parse(second).iv, env.iv);
  assert.notEqual(second, sealed);
  console.log('PASS 相同口令两次导出得到不同密文(随机盐/IV)');

  // 5. Backup.importBackup 端到端:信封能被解开并走进既有恢复路径
  const model = load('entry/src/main/ets/model/Profile.ets');
  let settings = new model.AppSettings();
  const empty = async () => [];
  const save = async () => {};
  const backup = load('entry/src/main/ets/core/Backup.ets', {
    '../model/Profile': model,
    '../model/Store': { initStore: async () => {}, loadSettings: async () => settings,
      saveSettings: async v => { settings = v; }, loadProfiles: empty, saveProfiles: save,
      loadGroups: empty, saveGroups: save,
      replaceBackupData: async (s) => { settings = s; }, LogStore: { addLog: () => {} } },
    '../model/RouteRule': { loadRouteRules: empty, saveRouteRules: save,
      loadRemoteRuleSets: empty, saveRemoteRuleSets: save },
    './Subscriptions': { listSubs: empty, saveSubs: save },
    './BackupCrypto': crypto
  });
  const payload = JSON.stringify({ schemaVersion: 4, profiles: [], settings: { ipv6Mode: 'prefer' } });
  const sealedPayload = await crypto.encryptBackup(payload, 'correct horse battery');
  await backup.importBackup({}, sealedPayload, 'correct horse battery');
  assert.equal(settings.ipv6Mode, 'prefer', 'encrypted backup must restore through the normal path');
  console.log('PASS 加密备份经 importBackup 正常恢复');

  // 5b. 设备无加密框架:必须明确"不支持",绝不静默降级成明文
  {
    const noCrypto = load('entry/src/main/ets/core/BackupCrypto.ets', {
      '@ohos.security.cryptoFramework': { default: cryptoFramework },
      '@ohos.util': { default: util }
    });
    // 同一份源码,换一个 canIUse=false 的沙箱
    const src = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/BackupCrypto.ets'), 'utf8');
    const js = ts.transpileModule(src, {compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
    const exp = {};
    vm.runInNewContext(js, { exports: exp, canIUse: () => false,
      require: name => ({'@ohos.security.cryptoFramework': { default: cryptoFramework },
        '@ohos.util': { default: util } })[name] });
    await assert.rejects(exp.encryptBackup(PLAIN, 'correct horse battery'),
      /backup_crypto_unsupported/, '无加密框架时不得导出明文');
    await assert.rejects(exp.decryptBackup(sealed, 'correct horse battery'),
      /backup_crypto_unsupported/);
    assert.ok(noCrypto !== undefined);
    console.log('PASS 无 CryptoFramework 设备:明确报不支持,不静默降级明文');
  }

  // 6. 加密备份缺口令:明确报错,不落到 JSON.parse 的模糊错误
  await assert.rejects(backup.importBackup({}, sealedPayload), /backup_encrypted_needs_password/);
  console.log('PASS 加密备份缺口令时给出专用错误码');
}
main().catch(e => { console.error(e); process.exitCode = 1; });
