import { httpGet, ProbeResponse, PROBE_UA } from './HttpProbe';
import { countryFlag, normalizeRegion } from '../core/ServiceDiagnostics';

/**
 * 落地 IP(对齐 OwnBox LandingIpManager 的业务含义:当前出口的 IP + 归属地)。
 *
 * 数据源顺序:
 *  1) `www.cloudflare.com/cdn-cgi/trace` —— 纯文本 key=value,不受 JSON 结构变动影响,
 *     能同时拿到 ip 与 loc(地区码);
 *  2) `api.ip.sb/geoip` —— 补城市/ISP 与中文可读国家名,JSON。
 *
 * 注意:请求走的是**应用自己的网络路径**。全局模式下应用流量同样进 TUN,所以看到的就是
 * 节点的出口 IP;分应用模式若没把自己列进去,这里显示的是本机直连 IP(页面上会提示)。
 *
 * 缓存 60s(与 OwnBox 的 CACHE_TTL_MS 一致):13 项服务检测共用一次结果,不重复打接口。
 */

const CACHE_TTL_MS: number = 60 * 1000;
const TRACE_URL: string = 'https://www.cloudflare.com/cdn-cgi/trace';
const GEO_URL: string = 'https://api.ip.sb/geoip';

export class LandingIpInfo {
  ip: string = '';
  country: string = '';
  countryCode: string = '';
  city: string = '';
  isp: string = '';
  /** HTTP 往返耗时(毫秒) */
  durationMs: number = 0;
  source: string = '';
  atMs: number = 0;

  flag(): string {
    return this.countryCode.length > 0 ? countryFlag(this.countryCode) : '🌐';
  }
}

let cache: LandingIpInfo | null = null;
let querying: Promise<LandingIpInfo> | null = null;

function parseTrace(body: string): LandingIpInfo {
  const info = new LandingIpInfo();
  const lines = body.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    const eq = line.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const key = line.substring(0, eq);
    const value = line.substring(eq + 1).trim();
    if (key === 'ip') {
      info.ip = value;
    } else if (key === 'loc') {
      info.countryCode = normalizeRegion(value);
    }
  }
  info.source = 'cloudflare';
  return info;
}

/** 只在缺字段时用来补城市/ISP;解析失败一律忽略 */
function fillFromGeoJson(body: string, info: LandingIpInfo): void {
  if (body.length === 0 || body.charAt(0) !== '{') {
    return;
  }
  try {
    const obj = JSON.parse(body) as Record<string, Object>;
    const ip = obj['ip'];
    if (info.ip.length === 0 && typeof ip === 'string') {
      info.ip = ip;
    }
    const cc = obj['country_code'];
    if (info.countryCode.length === 0 && typeof cc === 'string') {
      info.countryCode = normalizeRegion(cc);
    }
    const country = obj['country'];
    if (typeof country === 'string') {
      info.country = country;
    }
    const city = obj['city'];
    if (typeof city === 'string') {
      info.city = city;
    }
    const isp = obj['isp'];
    const org = obj['organization'];
    if (typeof isp === 'string' && isp.length > 0) {
      info.isp = isp;
    } else if (typeof org === 'string') {
      info.isp = org;
    }
    if (info.source === 'cloudflare') {
      info.source = 'cloudflare+ip.sb';
    }
  } catch (e) {
    // JSON 结构不符预期:保留已有字段
  }
}

async function doQuery(timeoutMs: number): Promise<LandingIpInfo> {
  const started = Date.now();
  const trace: ProbeResponse = await httpGet(TRACE_URL, timeoutMs, PROBE_UA, 4096);
  let info: LandingIpInfo;
  if (trace.ok) {
    info = parseTrace(trace.body);
  } else {
    info = new LandingIpInfo();
    info.source = 'ip.sb';
  }
  if (info.ip.length === 0) {
    return info; // 两个来源都拿不到就直接失败,不把空结果写缓存
  }
  // 只有 trace 成功才补城市(省一次请求);缺 ip 的情况上面已经返回
  if (info.country.length === 0) {
    const geo: ProbeResponse = await httpGet(GEO_URL, timeoutMs, PROBE_UA, 8192);
    if (geo.ok) {
      fillFromGeoJson(geo.body, info);
    }
  }
  info.durationMs = trace.ok ? trace.ms : Date.now() - started;
  info.atMs = Date.now();
  return info;
}

/** 是否命中新鲜缓存(页面用来决定按钮文案:刷新 vs 查询) */
export function landingIpIsFresh(): boolean {
  return cache !== null && Date.now() - cache.atMs < CACHE_TTL_MS;
}

export function cachedLandingIp(): LandingIpInfo | null {
  return cache;
}

export function clearLandingIpCache(): void {
  cache = null;
}

/**
 * 查询落地 IP。force=false 且缓存新鲜时直接返回缓存;
 * 并发调用共用一个在途请求(避免「全部检测」同时打 13 个 trace)。
 */
export async function queryLandingIp(force: boolean, timeoutMs: number): Promise<LandingIpInfo> {
  if (!force && cache !== null && Date.now() - cache.atMs < CACHE_TTL_MS) {
    return cache;
  }
  if (querying !== null) {
    return querying;
  }
  const task: Promise<LandingIpInfo> = doQuery(timeoutMs);
  querying = task;
  try {
    const result = await task;
    if (result.ip.length > 0) {
      cache = result;
    }
    return result;
  } finally {
    querying = null;
  }
}
