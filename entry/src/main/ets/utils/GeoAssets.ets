import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
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
