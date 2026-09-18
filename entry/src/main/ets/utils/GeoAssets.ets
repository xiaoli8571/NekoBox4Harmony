import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import picker from '@ohos.file.picker';
import common from '@ohos.app.ability.common';

/**
 * GeoIP/GeoSite 数据管理:下载 sing-geosite/sing-geoip 的 cn 分类库到应用沙箱,
 * 规则模式下自动启用 geosite:cn / geoip:cn 直连分流。
 */

export const GEO_SITE_FILE = 'geosite-cn.db';
export const GEO_IP_FILE = 'geoip-cn.db';

const URLS_SITE: Array<string> = [
  'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.db',
  'https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.db',
  'https://mirror.ghproxy.com/https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.db',
  'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.db'
];
const URLS_IP: Array<string> = [
  'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.db',
  'https://fastly.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.db',
  'https://mirror.ghproxy.com/https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.db',
  'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.db'
];

export function geoDir(context: common.Context): string {
  return `${context.filesDir}/geo`;
}

export function geoSitePath(context: common.Context): string {
  return `${geoDir(context)}/${GEO_SITE_FILE}`;
}

export function geoIpPath(context: common.Context): string {
  return `${geoDir(context)}/${GEO_IP_FILE}`;
}

export function geoReady(context: common.Context): boolean {
  try {
    const siteOk = fs.accessSync(geoSitePath(context)) && fs.statSync(geoSitePath(context)).size > 100 * 1024;
    const ipOk = fs.accessSync(geoIpPath(context)) && fs.statSync(geoIpPath(context)).size > 100 * 1024;
    return siteOk && ipOk;
  } catch (e) {
    return false;
  }
}

async function downloadTo(url: string, path: string): Promise<void> {
  const client = http.createHttp();
  try {
    const resp = await client.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: 15000,
      readTimeout: 30000,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    });
    if (resp.responseCode !== 200) {
      throw new Error(`HTTP ${resp.responseCode}`);
    }
    const data = resp.result as ArrayBuffer;
    if (data.byteLength < 100 * 1024) {
      throw new Error('文件过小,内容可疑');
    }
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data);
    } finally {
      fs.closeSync(file);
    }
  } finally {
    client.destroy();
  }
}

async function downloadFirstAvailable(urls: Array<string>, path: string): Promise<void> {
  let lastErr: Error = new Error('无可用下载源');
  for (const url of urls) {
    try {
      await downloadTo(url, path);
      return;
    } catch (e) {
      lastErr = e instanceof Error ? e : new Error(`${e}`);
    }
  }
  throw lastErr;
}

export async function downloadGeoAssets(context: common.Context): Promise<void> {
  const dir = geoDir(context);
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }
  await downloadFirstAvailable(URLS_SITE, geoSitePath(context));
  await downloadFirstAvailable(URLS_IP, geoIpPath(context));
}

/** 单库资产信息(对齐安卓 AssetsActivity 列表行:名称/大小/版本标记) */
export interface GeoAssetInfo {
  kind: string;        // 'site' | 'ip'
  fileName: string;    // 沙箱内文件名
  size: number;        // 字节,0 = 未下载
  version: string;     // .version.txt 内容;缺省 'Unknown'
}

export function geoAssetInfos(context: common.Context): Array<GeoAssetInfo> {
  const out: Array<GeoAssetInfo> = [];
  const defs: Array<[string, string, string]> = [
    ['site', GEO_SITE_FILE, 'geosite-cn'],
    ['ip', GEO_IP_FILE, 'geoip-cn']
  ];
  for (const def of defs) {
    const info: GeoAssetInfo = { kind: def[0], fileName: def[1], size: 0, version: 'Unknown' };
    try {
      const path = `${geoDir(context)}/${def[1]}`;
      if (fs.accessSync(path)) {
        info.size = fs.statSync(path).size;
      }
    } catch (e) {
      // 未下载
    }
    try {
      const versionPath = `${geoDir(context)}/${def[2]}.version.txt`;
      if (fs.accessSync(versionPath)) {
        const v = fs.readTextSync(versionPath).trim();
        if (v.length > 0) {
          info.version = v;
        }
      }
    } catch (e) {
      // 无版本文件
    }
    out.push(info);
  }
  return out;
}

/** 单独更新一个库(对齐安卓资产列表点击单库更新) */
export async function downloadGeoAsset(context: common.Context, kind: string): Promise<void> {
  const dir = geoDir(context);
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }
  if (kind === 'site') {
    await downloadFirstAvailable(URLS_SITE, geoSitePath(context));
  } else {
    await downloadFirstAvailable(URLS_IP, geoIpPath(context));
  }
}

/** 删除一个库及其版本标记(对齐安卓资产左滑删除);缺库时内核自动跳过对应 cn 分流 */
export function deleteGeoAsset(context: common.Context, kind: string): void {
  const path = kind === 'site' ? geoSitePath(context) : geoIpPath(context);
  const versionPath = `${geoDir(context)}/${kind === 'site' ? 'geosite-cn' : 'geoip-cn'}.version.txt`;
  if (fs.accessSync(path)) {
    fs.unlinkSync(path);
  }
  try {
    if (fs.accessSync(versionPath)) {
      fs.unlinkSync(versionPath);
    }
  } catch (e) {
    // 版本文件清理失败不影响删除结果
  }
}

/**
 * 导入用户自选的 geo .db 文件(对齐安卓 AssetsActivity 的 action_import_file):
 * 文件名必须是 geoip.db / geosite.db(内核按名查找),否则拒绝;
 * 覆盖现有同名库,并写 .version.txt 标记为 Custom。
 * 返回导入后的目标路径,失败抛错;用户取消返回 null。
 */
export async function importGeoAssetFromFile(context: common.Context): Promise<string | null> {
  const documentPicker = new picker.DocumentViewPicker(context);
  const options: picker.DocumentSelectOptions = {
    fileSuffixFilters: ['.db'],
    maxSelectNumber: 1
  };
  const uris: Array<string> = await documentPicker.select(options);
  if (uris.length === 0) {
    return null;
  }
  const srcUri = uris[0];
  // 选择器返回的 URI 末段即用户可读文件名(内核按 geoip.db/geosite.db 名查找)
  const rawName = srcUri.split('/').pop() ?? '';
  const fileName = decodeURIComponent(rawName);
  const lower = fileName.toLowerCase();
  const isSite = lower === 'geosite.db';
  const isIp = lower === 'geoip.db';
  if (!isSite && !isIp) {
    throw new Error(`文件名必须是 geoip.db 或 geosite.db(当前: ${fileName})`);
  }
  const dir = geoDir(context);
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }
  const targetPath = isSite ? geoSitePath(context) : geoIpPath(context);
  const sizeOk = copyUriToPath(srcUri, targetPath);
  if (!sizeOk) {
    fs.unlinkSync(targetPath);
    throw new Error(`导入的 ${fileName} 大小可疑,内容不完整`);
  }
  // 版本标记(对齐安卓 .version.txt = Custom)
  const versionPath = `${dir}/${isSite ? 'geosite-cn' : 'geoip-cn'}.version.txt`;
  const vf = fs.openSync(versionPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    fs.writeSync(vf.fd, 'Custom');
  } finally {
    fs.closeSync(vf);
  }
  return targetPath;
}

/** 复制选择器 URI 到沙箱路径;返回 true 表示大小可接受(>=1KB) */
function copyUriToPath(srcUri: string, targetPath: string): boolean {
  const src = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
  const dst = fs.openSync(targetPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  let total = 0;
  try {
    const buf = new ArrayBuffer(1024 * 1024);
    while (true) {
      const len = fs.readSync(src.fd, buf);
      if (len <= 0) {
        break;
      }
      fs.writeSync(dst.fd, buf, { length: len });
      total += len;
    }
  } finally {
    fs.closeSync(src);
    fs.closeSync(dst);
  }
  return total >= 1024;
}
