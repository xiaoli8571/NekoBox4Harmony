#!/usr/bin/env node
/**
 * NekoBox for Harmony —— 打包 MCP server(stdio,零依赖手写 JSON-RPC)
 *
 * 为什么手写而不用 @modelcontextprotocol/sdk:本机全局/本仓库都没有该 SDK,
 * 离线装不了;MCP stdio 协议就是「换行分隔的 JSON-RPC 2.0」,手写 200 行足够稳,
 * 也不会因为 SDK 版本升级把打包链弄坏。
 *
 * 一切动作都对应仓库里"已验证过"的命令,不发明新流程:
 *   build  → node hvigorw.js ... assembleHap|assembleApp
 *   sign   → scripts/sign-release-agc.ps1(AGC 双层签名 + 双层验签 + 指纹断言)
 *   install→ hdc install -r
 *   test   → node tests/*.cjs
 *
 * 口令处理(重要):绝不允许把口令写进仓库。
 *   解析顺序:调用参数 password → 环境变量 AGC_KEY_PASSWORD → ~/.nekobox-pack/secret.json
 *   pack_store_password 只能写到 ~/.nekobox-pack/(仓库外),且拒绝写进项目目录。
 */

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';

const REPO = process.env.NEKBOX_REPO || path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '../..');
const DEVECO_SDK_HOME = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const JAVA_HOME = process.env.JAVA_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\jbr';
const HDC = process.env.HDC || path.join(DEVECO_SDK_HOME, 'default', 'openharmony', 'toolchains', 'hdc.exe');
const SECRET_DIR = path.join(os.homedir(), '.nekobox-pack');
const SECRET_FILE = path.join(SECRET_DIR, 'secret.json');
const AGENT_DIR = process.env.AGC_CERT_DIR || 'C:\\Worker\\AGC通用证书';

const childEnv = () => ({
  ...process.env,
  DEVECO_SDK_HOME,
  JAVA_HOME,
  PATH: `${path.join(JAVA_HOME, 'bin')}${path.delimiter}${process.env.PATH || ''}`,
});

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, {
    cwd: opts.cwd || REPO,
    env: { ...childEnv(), ...(opts.env || {}) },
    encoding: 'utf8',
    shell: false,
    timeout: opts.timeoutMs ?? 30 * 60 * 1000,
    maxBuffer: 64 * 1024 * 1024,
  });
  const out = `${r.stdout || ''}${r.stderr || ''}`;
  return { code: r.status ?? (r.error ? -1 : 0), out, error: r.error ? String(r.error.message) : '' };
}

const tail = (s, n = 40) => s.split(/\r?\n/).filter(Boolean).slice(-n).join('\n');
const sha256 = (file) => createHash('sha256').update(fs.readFileSync(file)).digest('hex');

function readVersion() {
  const txt = fs.readFileSync(path.join(REPO, 'AppScope/app.json5'), 'utf8');
  return {
    versionName: (txt.match(/"versionName":\s*"([^"]+)"/) || [])[1] || '',
    versionCode: Number((txt.match(/"versionCode":\s*(\d+)/) || [])[1] || 0),
  };
}

function resolvePassword(explicit) {
  if (explicit && String(explicit).trim()) return { password: String(explicit).trim(), source: 'argument' };
  if (process.env.AGC_KEY_PASSWORD) return { password: process.env.AGC_KEY_PASSWORD, source: 'env:AGC_KEY_PASSWORD' };
  try {
    const j = JSON.parse(fs.readFileSync(SECRET_FILE, 'utf8'));
    if (j && j.agcKeyPassword) return { password: j.agcKeyPassword, source: SECRET_FILE };
  } catch { /* 没有就不是错误 */ }
  return { password: '', source: 'none' };
}

function distArtifacts() {
  const dir = path.join(REPO, 'dist');
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir)
    .filter((f) => /\.(hap|app)$/i.test(f))
    .map((f) => {
      const p = path.join(dir, f);
      const st = fs.statSync(p);
      return { file: f, bytes: st.size, mtime: st.mtime.toISOString(), sha256: sha256(p) };
    })
    .sort((a, b) => (a.mtime < b.mtime ? 1 : -1));
}

/** 读 HAP 里的 module.json(打包元信息),用于验收版本/构建模式/内核一致性 */
function hapMeta(hapPath) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nx-hap-'));
  try {
    const unzip = run('unzip', ['-o', '-q', hapPath, 'module.json', 'libs/arm64-v8a/libsingbox.so', '-d', tmp], { timeoutMs: 120000 });
    if (unzip.code !== 0) return { error: tail(unzip.out, 5) };
    const meta = JSON.parse(fs.readFileSync(path.join(tmp, 'module.json'), 'utf8')).app || {};
    const soPath = path.join(tmp, 'libs/arm64-v8a/libsingbox.so');
    return {
      versionName: meta.versionName,
      versionCode: meta.versionCode,
      buildMode: meta.buildMode,
      debug: meta.debug,
      minAPIVersion: meta.minAPIVersion,
      kernelSha256: fs.existsSync(soPath) ? sha256(soPath) : null,
    };
  } catch (e) {
    return { error: String(e.message || e) };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

const tools = [
  {
    name: 'pack_env',
    description: '检查打包环境:SDK/JBR/hdc/签名材料/口令来源/当前版本/设备连接。只读。',
    inputSchema: { type: 'object', properties: {} },
    handler: () => {
      const v = readVersion();
      const pw = resolvePassword();
      const t = run(HDC, ['list', 'targets'], { timeoutMs: 60000 });
      const certFiles = fs.existsSync(AGENT_DIR) ? fs.readdirSync(AGENT_DIR).filter((f) => /\.(p12|cer|p7b)$/i.test(f)) : [];
      return {
        repo: REPO,
        versionName: v.versionName,
        versionCode: v.versionCode,
        devecoSdk: { path: DEVECO_SDK_HOME, exists: fs.existsSync(DEVECO_SDK_HOME) },
        javaHome: { path: JAVA_HOME, exists: fs.existsSync(JAVA_HOME) },
        hdc: { path: HDC, exists: fs.existsSync(HDC) },
        devices: t.out.split(/\r?\n/).map((s) => s.trim()).filter((s) => s && !/^\[/.test(s)),
        certDir: AGENT_DIR,
        certFiles,
        passwordSource: pw.source,
        passwordAvailable: !!pw.password,
        artifactCount: distArtifacts().length,
      };
    },
  },
  {
    name: 'pack_store_password',
    description: `把 AGC 签名口令存到仓库外的 ${SECRET_FILE}(0600 尽力而为),供后续 pack_sign 免手输。绝不写入项目目录。`,
    inputSchema: {
      type: 'object',
      properties: { password: { type: 'string', description: 'AGC 密钥库口令(password 字段会原样保存到用户目录)' } },
      required: ['password'],
    },
    handler: ({ password }) => {
      if (!password) throw new Error('password 不能为空');
      fs.mkdirSync(SECRET_DIR, { recursive: true });
      fs.writeFileSync(SECRET_FILE, JSON.stringify({ agcKeyPassword: password, updatedAt: new Date().toISOString() }, null, 2), { mode: 0o600 });
      return { stored: SECRET_FILE, outsideRepo: !SECRET_FILE.startsWith(REPO) };
    },
  },
  {
    name: 'pack_set_version',
    description: '统一写版本号:AppScope/app.json5(versionName+versionCode)+ 根/entry oh-package.json5。',
    inputSchema: {
      type: 'object',
      properties: {
        versionName: { type: 'string', description: '如 2.4.0' },
        versionCode: { type: 'number', description: '如 2400000;省略则由 versionName 推导 major*1e6+minor*1e4+patch*1e2' },
      },
      required: ['versionName'],
    },
    handler: ({ versionName, versionCode }) => {
      const [maj, min, pat] = String(versionName).split('.').map((n) => parseInt(n, 10) || 0);
      const code = Number(versionCode) || maj * 1000000 + min * 10000 + pat * 100;
      const appPath = path.join(REPO, 'AppScope/app.json5');
      let app = fs.readFileSync(appPath, 'utf8');
      app = app.replace(/"versionCode":\s*\d+/, `"versionCode": ${code}`).replace(/"versionName":\s*"[^"]+"/, `"versionName": "${versionName}"`);
      fs.writeFileSync(appPath, app);
      const touched = [appPath];
      for (const rel of ['oh-package.json5', 'entry/oh-package.json5']) {
        const p = path.join(REPO, rel);
        if (!fs.existsSync(p)) continue;
        let t = fs.readFileSync(p, 'utf8');
        t = t.replace(/"version":\s*"[^"]+"/, `"version": "${versionName}"`);
        fs.writeFileSync(p, t);
        touched.push(p);
      }
      return { versionName, versionCode: code, touched: touched.map((p) => path.relative(REPO, p)) };
    },
  },
  {
    name: 'pack_build',
    description: '编译。target=hap(module 模式)|app(project 模式,含 HAP)。mode=debug|release。',
    inputSchema: {
      type: 'object',
      properties: {
        target: { type: 'string', enum: ['hap', 'app'], description: '默认 hap' },
        mode: { type: 'string', enum: ['debug', 'release'], description: '默认 release' },
      },
    },
    handler: ({ target = 'hap', mode = 'release' }) => {
      const args = target === 'app'
        ? ['hvigorw.js', '--mode', 'project', '-p', 'product=default', '-p', `buildMode=${mode}`, 'assembleApp', '--no-daemon']
        : ['hvigorw.js', '--mode', 'module', '-p', 'product=default', '-p', `buildMode=${mode}`, 'assembleHap', '--no-daemon'];
      const r = run(process.execPath, args, { timeoutMs: 45 * 60 * 1000 });
      const ok = /BUILD SUCCESSFUL/.test(r.out);
      if (!ok) throw new Error(`构建失败(code=${r.code})\n${tail(r.out, 30)}`);
      const outputs = {};
      const hapUnsigned = path.join(REPO, 'entry/build/default/outputs/default/entry-default-unsigned.hap');
      const appUnsigned = path.join(REPO, 'build/outputs/default/NekoBox4Harmony-default-unsigned.app');
      if (fs.existsSync(hapUnsigned)) outputs.hapUnsigned = { path: path.relative(REPO, hapUnsigned), bytes: fs.statSync(hapUnsigned).size, meta: hapMeta(hapUnsigned) };
      if (fs.existsSync(appUnsigned)) outputs.appUnsigned = { path: path.relative(REPO, appUnsigned), bytes: fs.statSync(appUnsigned).size };
      return { target, mode, buildLog: tail(r.out, 6), outputs };
    },
  },
  {
    name: 'pack_sign',
    description: 'AGC 双层签名已构建的 unsigned .app(同时产出 inner HAP),产物写 dist/,含双层验签。',
    inputSchema: {
      type: 'object',
      properties: { password: { type: 'string', description: '可选;省略则用 env/secret 文件' } },
    },
    handler: ({ password }) => {
      const pw = resolvePassword(password);
      if (!pw.password) throw new Error('没有口令:传 password、设 AGC_KEY_PASSWORD,或先调 pack_store_password');
      const shell = run('where', ['pwsh'], { timeoutMs: 20000 }).code === 0 ? 'pwsh' : 'powershell';
      const r = run(shell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(REPO, 'scripts/sign-release-agc.ps1')], {
        env: { AGC_KEY_PASSWORD: pw.password },
        timeoutMs: 30 * 60 * 1000,
      });
      if (r.code !== 0) throw new Error(`签名失败(code=${r.code})\n${tail(r.out, 25)}`);
      const v = readVersion();
      const signedHap = path.join(REPO, 'dist', `NekoBox-${v.versionName}-release-signed.hap`);
      const signedApp = path.join(REPO, 'dist', `NekoBox-${v.versionName}-release-signed.app`);
      return {
        passwordSource: pw.source,
        fingerprints: r.out.split(/\r?\n/).filter((l) => /release cert fingerprints|confirmed/.test(l)).map((l) => l.trim()),
        hap: fs.existsSync(signedHap) ? { file: path.basename(signedHap), bytes: fs.statSync(signedHap).size, sha256: sha256(signedHap), meta: hapMeta(signedHap) } : null,
        app: fs.existsSync(signedApp) ? { file: path.basename(signedApp), bytes: fs.statSync(signedApp).size, sha256: sha256(signedApp) } : null,
      };
    },
  },
  {
    name: 'pack_release',
    description: '一条龙:可选改版本 → assembleHap(release) → assembleApp(release) → AGC 双层签名 → 汇总 dist 产物与校验。',
    inputSchema: {
      type: 'object',
      properties: {
        versionName: { type: 'string', description: '可选;给了就先 pack_set_version' },
        versionCode: { type: 'number' },
        password: { type: 'string', description: '可选;省略则用 env/secret 文件' },
        skipHap: { type: 'boolean', description: '跳过单独的 assembleHap(assembleApp 内部已含 HAP)' },
      },
    },
    handler: ({ versionName, versionCode, password, skipHap }) => {
      const steps = [];
      if (versionName) steps.push({ step: 'set_version', ...tools.find((t) => t.name === 'pack_set_version').handler({ versionName, versionCode }) });
      if (!skipHap) steps.push({ step: 'build_hap', ...tools.find((t) => t.name === 'pack_build').handler({ target: 'hap', mode: 'release' }) });
      steps.push({ step: 'build_app', ...tools.find((t) => t.name === 'pack_build').handler({ target: 'app', mode: 'release' }) });
      steps.push({ step: 'sign', ...tools.find((t) => t.name === 'pack_sign').handler({ password }) });
      const v = readVersion();
      const kernel = (() => {
        const p = path.join(REPO, 'entry/libs/arm64-v8a/libsingbox.so');
        return fs.existsSync(p) ? sha256(p) : null;
      })();
      return { version: v, kernelSha256: kernel, steps, artifacts: distArtifacts() };
    },
  },
  {
    name: 'pack_install',
    description: 'hdc 安装到已连接设备。source=debug(entry-default-signed.hap,本机调试证书)|unsigned(未签 HAP)|dist 文件名。',
    inputSchema: {
      type: 'object',
      properties: {
        source: { type: 'string', description: 'debug|unsigned|release-signed-hap|release-signed-app|任意 dist 内文件名' },
        device: { type: 'string', description: '可选 target id(hdc list targets)' },
      },
    },
    handler: ({ source = 'debug', device }) => {
      const v = readVersion();
      const map = {
        debug: 'entry/build/default/outputs/default/entry-default-signed.hap',
        unsigned: 'entry/build/default/outputs/default/entry-default-unsigned.hap',
        'release-signed-hap': `dist/NekoBox-${v.versionName}-release-signed.hap`,
        'release-signed-app': `dist/NekoBox-${v.versionName}-release-signed.app`,
        'unsigned-hap': `dist/NekoBox4Harmony-${v.versionName}-unsigned.hap`,
        'unsigned-app': `dist/NekoBox4Harmony-${v.versionName}-unsigned.app`,
      };
      const rel = map[source] || (source.includes('/') || source.includes('\\') ? source : `dist/${source}`);
      const abs = path.isAbsolute(rel) ? rel : path.join(REPO, rel);
      if (!fs.existsSync(abs)) throw new Error(`找不到安装包: ${abs}`);
      const args = device ? ['-t', device, 'install', '-r', abs] : ['install', '-r', abs];
      const r = run(HDC, args, { timeoutMs: 10 * 60 * 1000 });
      const ok = /successfully/i.test(r.out);
      if (!ok) throw new Error(`安装失败(code=${r.code})\n${tail(r.out, 12)}`);
      return { installed: path.relative(REPO, abs), bytes: fs.statSync(abs).size, device: device || '(default)', log: tail(r.out, 4) };
    },
  },
  {
    name: 'pack_test',
    description: '跑 Node 测试套件。suite=all|单个套件名(如 ruleset-repository)。',
    inputSchema: {
      type: 'object',
      properties: { suite: { type: 'string', description: '默认 all(跳过 *generate-*)' } },
    },
    handler: ({ suite = 'all' }) => {
      const dir = path.join(REPO, 'tests');
      const files = suite === 'all'
        ? fs.readdirSync(dir).filter((f) => f.endsWith('.cjs') && !f.includes('generate-')).map((f) => path.join(dir, f))
        : [path.join(dir, suite.endsWith('.cjs') ? suite : `${suite}.cjs`)];
      const failed = [];
      for (const f of files) {
        const r = run(process.execPath, [f], { timeoutMs: 10 * 60 * 1000 });
        if (r.code !== 0) failed.push({ suite: path.basename(f), tail: tail(r.out, 12) });
      }
      return { ran: files.length, failed: failed.length, failures: failed };
    },
  },
  {
    name: 'pack_artifacts',
    description: '列出 dist/ 产物(size/sha256/版本元信息)。只读。',
    inputSchema: { type: 'object', properties: {} },
    handler: () => ({ version: readVersion(), artifacts: distArtifacts() }),
  },
];

// ---------------------------------------------------------------- JSON-RPC / MCP
const write = (msg) => process.stdout.write(`${JSON.stringify(msg)}\n`);
const ok = (id, result) => write({ jsonrpc: '2.0', id, result });
const err = (id, code, message) => write({ jsonrpc: '2.0', id, error: { code, message } });

function handle(msg) {
  const { id, method, params } = msg || {};
  if (method === 'initialize') {
    return ok(id, {
      protocolVersion: '2024-11-05',
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: 'nekobox-pack', version: '1.0.0' },
      instructions: `NekoBox for Harmony 打包:MCP 入口。仓库 ${REPO}。典型顺序:pack_env → pack_set_version → pack_release → pack_install。口令可用 pack_store_password 存在 ~/.nekobox-pack/secret.json(仓库外)。`,
    });
  }
  if (method === 'notifications/initialized' || method === 'initialized') return undefined;
  if (method === 'ping') return ok(id, {});
  if (method === 'tools/list') {
    return ok(id, { tools: tools.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })) });
  }
  if (method === 'tools/call') {
    const name = params?.name;
    const tool = tools.find((t) => t.name === name);
    if (!tool) return err(id, -32602, `unknown tool: ${name}`);
    try {
      const result = tool.handler(params?.arguments || {});
      return ok(id, { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }], isError: false });
    } catch (e) {
      return ok(id, { content: [{ type: 'text', text: `ERROR: ${e.message || e}` }], isError: true });
    }
  }
  if (method === 'resources/list') return ok(id, { resources: [] });
  if (method === 'prompts/list') return ok(id, { prompts: [] });
  if (id !== undefined && id !== null) return err(id, -32601, `method not found: ${method}`);
  return undefined;
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  const s = line.trim();
  if (!s) return;
  let msg;
  try { msg = JSON.parse(s); } catch { return err(null, -32700, 'parse error'); }
  try { handle(msg); } catch (e) { if (msg?.id != null) err(msg.id, -32603, String(e.message || e)); }
});
