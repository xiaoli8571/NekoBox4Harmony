// 生成 App Pack(.app):把已签名的 HAP + pack.info + pac.json 打成 zip,再交给
// hap-sign-tool 对 .app 本身签名(外层)。产出可直接上传 AppGallery 分发。
//
// 目录/文件结构与 dist/ 里历史的 NekoBox-2.0.x-signed.app 保持一致:
//   entry-default.hap   已签名 HAP
//   pack.info           App 元信息(Tab 缩进,与历史包同格式)
//   pac.json            {"dataProcess":[],"specialAPIs":[]}
//
// 用法:
//   node scripts/build-app-pack.js --hap dist/NekoBox-2.0.3-signed.hap \
//     --out dist/NekoBox-2.0.3.app
//
// 刻意不自己实现 zip:HAP 本身是 ~15MB 且已高度压缩,交给 hap-sign-tool 的
// sign-app 处理更稳。这里只负责组装未签名的 .app 骨架。

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue;
    const k = argv[i].slice(2);
    const n = argv[i + 1];
    if (n === undefined || n.startsWith('--')) out[k] = true;
    else { out[k] = n; i++; }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const repo = path.resolve(__dirname, '..');
const hapPath = args.hap || 'dist/NekoBox-2.0.3-signed.hap';
const stageDir = path.resolve(args.stage || path.join(repo, '.app-stage'));

if (!fs.existsSync(hapPath)) {
  console.error(`ERROR: 找不到 HAP: ${hapPath}(先跑 assembleHap 并用 hap-sign-tool 签好)`);
  process.exit(1);
}

// 版本信息从 AppScope/app.json5 读,避免手写 pack.info 与实际版本漂移
const appJson = JSON.parse(
  fs.readFileSync(path.join(repo, 'AppScope', 'app.json5'), 'utf8')
).app;
const bundleName = args.bundle || appJson.bundleName;
const versionCode = args.code || appJson.versionCode;
const versionName = args.name || appJson.versionName;

const packInfo = {
  summary: {
    app: {
      bundleName: bundleName,
      bundleType: 'app',
      version: { code: versionCode, name: versionName }
    },
    modules: [
      {
        mainAbility: 'EntryAbility',
        deviceType: ['phone', 'tablet'],
        abilities: [{ name: 'EntryAbility', label: '$string:app_name' }],
        extensionAbilities: [{ name: 'VpnExtAbility' }],
        distro: {
          moduleType: 'entry',
          installationFree: false,
          deliveryWithInstall: true,
          moduleName: 'entry'
        },
        apiVersion: { compatible: 24, releaseType: 'Release', target: 24 }
      }
    ]
  },
  packages: [
    {
      deviceType: ['phone', 'tablet'],
      moduleType: 'entry',
      deliveryWithInstall: true,
      name: 'entry-default'
    }
  ]
};

// 写到暂存目录,由调用方压成 zip(Node 不自带 zip 写器,自己实现 deflate
// 容易出错,交给 zip/python 之类现成工具更稳)。
fs.mkdirSync(stageDir, { recursive: true });
fs.copyFileSync(hapPath, path.join(stageDir, 'entry-default.hap'));
// Tab 缩进:与历史 .app 里的 pack.info 排版一致,便于人工 diff
fs.writeFileSync(path.join(stageDir, 'pack.info'), JSON.stringify(packInfo, null, '\t'), 'utf8');
fs.writeFileSync(path.join(stageDir, 'pac.json'), '{"dataProcess":[],"specialAPIs":[]}', 'utf8');

console.log(`暂存目录已就绪: ${stageDir}`);
console.log(`  bundleName=${bundleName} version=${versionName}(${versionCode})`);
console.log('下一步: 把该目录压成 zip,再对 .app 跑 hap-sign-tool sign-app 签外层。');
