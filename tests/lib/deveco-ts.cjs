// DevEco 自带 TypeScript 的按需加载器。
//
// 为什么需要它:47 个 Node 套件靠 DevEco Studio 里的 ets-loader typescript 把生产
// ArkTS 转译成 CJS 再跑(见各测试头部注释)。CI(GitHub Actions windows-latest)上
// 没有 DevEco Studio,原来直接 require 那个绝对路径会抛 MODULE_NOT_FOUND,
// 把 46 个套件连带整条 CI 拖红 —— 而设计意图(见 .github/workflows/ci.yml 注释)
// 是「SDK 存在才做交叉核对,缺失就跳过」。
//
// 约定:loadTs() 返回 null 表示本机没有 SDK,调用方必须打印 SKIP 并以 0 退出,
// 不能当成失败。
const fs = require('node:fs');
const path = require('node:path');

/** DevEco Studio 里 ets-loader 的 typescript.js 绝对路径(可被 DEVECO_SDK_HOME 覆盖) */
function tsPath() {
  const sdk = process.env.DEVECO_SDK_HOME || 'C:/Program Files/Huawei/DevEco Studio/sdk';
  return path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js');
}

/** 取得到就返回 ts 模块,取不到返回 null(调用方按 SKIP 处理) */
function loadTs() {
  const p = tsPath();
  if (!fs.existsSync(p)) {
    return null;
  }
  return require(p);
}

module.exports = { loadTs, tsPath };
