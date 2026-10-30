import fs from '@ohos.file.fs';
import zlib from '@ohos.zlib';
import common from '@ohos.app.ability.common';
import { LogStore } from '../model/Store';

/**
 * yacd 面板资源管理:把 HAP 内置的 rawfile/yacd.zip 解压到沙箱,
 * 路径交给 sing-box clash_api.external_ui,Dashboard 即可访问 /ui。
 */

const RAWFILE_NAME = 'yacd.zip';
/* 已知子目录名(仅用作提示;真实发现靠 dumpSubdirWithIndex:zip 内实测叫 `Yacd-meta-gh-pages`,
   大小写与本表不一致,Linux 沙箱文件系统区分大小写 ⇒ 固定表匹配失败 → external_ui 为空 → /ui 404) */
const CANDIDATE_SUBDIRS: Array<string> = ['yacd-gh-pages', 'yacd', 'gh-pages', 'yacd-meta'];

/** 在一层目录里找含 index.html 的子目录(大小写无关且不依赖固定名单) */
function findSubdirWithIndex(baseDir: string): string {
  let names: Array<string> = [];
  try {
    names = fs.listFileSync(baseDir);
  } catch (e) {
    return '';
  }
  for (const name of names) {
    if (fileExists(`${baseDir}/${name}/index.html`)) {
      return `${baseDir}/${name}`;
    }
    /* 再下探一层:有些打包方式是 <base>/yacd/<hash>/index.html */
    if (fileExists(`${baseDir}/${name}`)) {
      const deeper = findSubdirWithIndexOneLevel(`${baseDir}/${name}`);
      if (deeper.length > 0) {
        return deeper;
      }
    }
  }
  /* 名单兵底(理论上不会走到) */
  for (const name of CANDIDATE_SUBDIRS) {
    if (fileExists(`${baseDir}/${name}/index.html`)) {
      return `${baseDir}/${name}`;
    }
  }
  return '';
}

function findSubdirWithIndexOneLevel(dir: string): string {
  let names: Array<string> = [];
  try {
    names = fs.listFileSync(dir);
  } catch (e) {
    return '';
  }
  for (const name of names) {
    if (fileExists(`${dir}/${name}/index.html`)) {
      return `${dir}/${name}`;
    }
  }
  return '';
}

function fileExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (e) {
    return false;
  }
}

/** 确保面板已解压,返回含 index.html 的目录(失败返回空串,Dashboard 走降级提示) */
export async function ensureYacdExtracted(context: common.Context): Promise<string> {
  const baseDir = `${context.cacheDir}/yacd-ui`;
  const marker = `${context.cacheDir}/yacd-ui-path.txt`;
  // 复用上次解压结果
  if (fileExists(marker)) {
    try {
      const file = fs.openSync(marker, fs.OpenMode.READ_ONLY);
      let previous = '';
      try {
        const size = fs.statSync(file.fd).size;
        const buf = new ArrayBuffer(size);
        fs.readSync(file.fd, buf, { length: size });
        const bytes = new Uint8Array(buf);
        for (let i = 0; i < bytes.length; i++) {
          previous += String.fromCharCode(bytes[i]);
        }
      } finally {
        fs.closeSync(file);
      }
      const trimmed = previous.trim();
      if (trimmed.length > 0 && fileExists(`${trimmed}/index.html`)) {
        return trimmed;
      }
    } catch (e) {
      // 重新解压
    }
  }
  try {
    const resourceMgr = context.resourceManager;
    const content = await resourceMgr.getRawFileContent(RAWFILE_NAME);
    if (content.byteLength < 1000) {
      LogStore.addLog('[ui] yacd.zip 资源异常,Dashboard 将无法加载面板');
      return '';
    }
    const zipPath = `${context.cacheDir}/yacd.zip`;
    const zipFile = fs.openSync(zipPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(zipFile.fd, content.buffer);
    } finally {
      fs.closeSync(zipFile);
    }
    if (fileExists(baseDir)) {
      fs.rmdirSync(baseDir);
    }
    fs.mkdirSync(baseDir, true);
    const unzipOpts: zlib.Options = {};
    await zlib.unzipFile(zipPath, baseDir, unzipOpts);
    let uiDir = baseDir;
    if (!fileExists(`${baseDir}/index.html`)) {
      const found = findSubdirWithIndex(baseDir);
      if (found.length === 0) {
        LogStore.addLog('[ui] yacd 解压后未找到 index.html,Dashboard 无法加载面板');
        return '';
      }
      uiDir = found;
    }
    const markerFile = fs.openSync(marker, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(markerFile.fd, uiDir);
    } finally {
      fs.closeSync(markerFile);
    }
    return uiDir;
  } catch (e) {
    LogStore.addLog(`[ui] yacd 解压失败: ${e instanceof Error ? e.message : `${e}`}`);
    return '';
  }
}
