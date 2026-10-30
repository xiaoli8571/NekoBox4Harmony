/**
 * 服务可用性诊断 —— 对齐 OwnBox `ServiceDiagnosticsManager`(判定逻辑逐条搬过来,
 * 只把 libcore 的 HTTP 客户端换成 @ohos.net.http 的探测结果)。
 *
 * 纯模型:输入「某服务这次探测拿到的响应」,输出状态/地区/副标题,不做任何 I/O,
 * 因此能脱离设备在 Node 里跑(tests/service-diagnostics.cjs)。网络与超时在
 * utils/HttpProbe.ets,页面在 pages/DiagnosticsPage.ets。
 *
 * 与 OwnBox 的差异(有意为之):
 *  - OwnBox 每个服务返回后都把「出口 IP + 国旗」拼进副标题;鸿蒙侧 IP 只放顶部卡片,
 *    列表副标题只写地区/原因,避免 13 行重复同一个 IP。
 *  - 未连接时不发请求直接判 unavailable(与 OwnBox 相同的短路)。
 */

export const CAT_ALL: string = 'all';
export const CAT_AI: string = 'ai';
export const CAT_STREAMING: string = 'streaming';
export const CAT_COMMON: string = 'common';

export const STATE_IDLE: string = 'idle';
export const STATE_TESTING: string = 'testing';
export const STATE_AVAILABLE: string = 'available';
export const STATE_RESTRICTED: string = 'restricted';
export const STATE_UNAVAILABLE: string = 'unavailable';

/** 单次探测的结果(HTTP 层只负责填这几个字段) */
export class ProbeResult {
  url: string = '';
  ok: boolean = false;
  status: number = 0;
  body: string = '';
  error: string = '';

  static of(url: string, ok: boolean, status: number, body: string, error: string): ProbeResult {
    const r = new ProbeResult();
    r.url = url;
    r.ok = ok;
    r.status = status;
    r.body = body;
    r.error = error;
    return r;
  }
}

/** 一个服务的判定结果 */
export class ServiceOutcome {
  state: string = STATE_UNAVAILABLE;
  /** 服务侧认定的地区(两位大写);空串 = 没测出来 */
  region: string = '';
  /** 判定依据(只用于日志/调试,不直接展示) */
  reason: string = '';
}

export class ServiceDef {
  id: string = '';
  name: string = '';
  category: string = '';
  url: string = '';

  constructor(id: string, name: string, category: string, url: string) {
    this.id = id;
    this.name = name;
    this.category = category;
    this.url = url;
  }
}

/** 13 项服务(与 OwnBox createInitialList 同集合、同 URL、同分类) */
export function serviceDefs(): Array<ServiceDef> {
  return [
    new ServiceDef('google', 'Google', CAT_COMMON, 'https://www.google.com/generate_204'),
    new ServiceDef('github', 'GitHub', CAT_COMMON, 'https://github.com/'),
    new ServiceDef('tiktok', 'TikTok', CAT_COMMON, 'https://www.tiktok.com/'),
    new ServiceDef('discord', 'Discord', CAT_COMMON, 'https://discord.com/api/v9/auth/location-metadata'),
    new ServiceDef('chatgpt', 'ChatGPT', CAT_AI, 'https://ios.chat.openai.com/'),
    new ServiceDef('claude', 'Claude', CAT_AI, 'https://claude.ai/cdn-cgi/trace'),
    new ServiceDef('gemini', 'Gemini', CAT_AI, 'https://gemini.google.com/'),
    new ServiceDef('youtube', 'YouTube', CAT_STREAMING, 'https://www.youtube.com/premium?hl=en'),
    new ServiceDef('netflix', 'Netflix', CAT_STREAMING, 'https://www.netflix.com/title/81280792'),
    new ServiceDef('disney', 'Disney+', CAT_STREAMING, 'https://www.disneyplus.com/'),
    new ServiceDef('prime', 'Prime Video', CAT_STREAMING, 'https://www.primevideo.com'),
    new ServiceDef('spotify', 'Spotify', CAT_STREAMING,
      'https://www.spotify.com/api/content/v1/country-selector?platform=web&format=json'),
    new ServiceDef('bilibili', '哔哩哔哩', CAT_STREAMING,
      'https://api.bilibili.com/pgc/player/web/playurl?avid=82846771&qn=0&type=&otype=json' +
        '&ep_id=307247&fourk=1&fnver=0&fnval=16&module=bangumi')
  ];
}

/** claude 的地区黑名单(OwnBox 原样) */
const CLAUDE_BLOCKED: Array<string> = ['AF', 'BY', 'CN', 'CU', 'HK', 'IR', 'KP', 'MO', 'RU', 'SY'];
/** gemini 的地区黑名单(OwnBox 用三字母,这里统一成两字母比较) */
const GEMINI_BLOCKED: Array<string> = ['CN', 'RU', 'BY', 'CU', 'IR', 'KP', 'SY', 'HK', 'MO'];

const BILIBILI_HK_URL: string =
  'https://api.bilibili.com/pgc/player/web/playurl?avid=18281381&cid=29892777&qn=0&type=&otype=json' +
    '&ep_id=183799&fourk=1&fnver=0&fnval=16&module=bangumi';

/**
 * 该服务要请求哪几个 URL(对齐 OwnBox:多步校验的服务需要额外请求)。
 * 第一项永远是列表里的主 URL;返回顺序即探测顺序,失败会短路上报。
 */
export function probeUrlsFor(id: string): Array<string> {
  if (id === 'chatgpt') {
    return ['https://ios.chat.openai.com/', 'https://chat.openai.com/cdn-cgi/trace',
      'https://api.openai.com/compliance/cookie_requirements'];
  }
  if (id === 'netflix') {
    return ['https://www.netflix.com/title/81280792', 'https://www.netflix.com/title/70143836',
      'https://www.netflix.com/title/80018499'];
  }
  if (id === 'bilibili') {
    const defs = serviceDefs();
    const main = defs.find((d: ServiceDef) => d.id === id);
    return [main !== undefined ? main.url : '', BILIBILI_HK_URL];
  }
  const defs = serviceDefs();
  const def = defs.find((d: ServiceDef) => d.id === id);
  return [def !== undefined ? def.url : ''];
}

/** 取 cloudflare trace 风格的字段(一行 `key=value`) */
export function traceField(body: string, key: string): string {
  if (body.length === 0) {
    return '';
  }
  const lines = body.split('\n');
  const prefix = `${key}=`;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line.startsWith(prefix)) {
      return line.substring(prefix.length).trim();
    }
  }
  return '';
}

/** 地区码归一:三字母 → 两字母,UK → GB,统一大写 */
export function normalizeRegion(code: string): string {
  const up = code.trim().toUpperCase();
  if (up.length === 0) {
    return '';
  }
  if (up === 'CHN') {
    return 'CN';
  }
  if (up === 'RUS') {
    return 'RU';
  }
  if (up === 'BLR') {
    return 'BY';
  }
  if (up === 'CUB') {
    return 'CU';
  }
  if (up === 'IRN') {
    return 'IR';
  }
  if (up === 'PRK') {
    return 'KP';
  }
  if (up === 'SYR') {
    return 'SY';
  }
  if (up === 'HKG') {
    return 'HK';
  }
  if (up === 'MAC') {
    return 'MO';
  }
  if (up === 'UK') {
    return 'GB';
  }
  return up;
}

/** 两字母地区码 → 国旗 emoji(不合法的码回 🌐) */
export function countryFlag(code: string): string {
  const up = normalizeRegion(code);
  if (up.length !== 2) {
    return '🌐';
  }
  const base = 0x1F1E6;
  const a = up.charCodeAt(0);
  const b = up.charCodeAt(1);
  if (a < 65 || a > 90 || b < 65 || b > 90) {
    return '🌐';
  }
  return String.fromCodePoint(base + (a - 65)) + String.fromCodePoint(base + (b - 65));
}

/** IP 打码(详情页展示用:1.2.*.* / 2001:db8:****:****) */
export function maskIp(ip: string): string {
  if (ip.length === 0) {
    return '';
  }
  if (ip.indexOf(':') >= 0) {
    const parts = ip.split(':');
    if (parts.length >= 2) {
      return `${parts[0]}:${parts[1]}:****:****`;
    }
    return ip;
  }
  const parts = ip.split('.');
  if (parts.length === 4) {
    return `${parts[0]}.${parts[1]}.*.*`;
  }
  return ip;
}

function bodyOf(probes: Array<ProbeResult>, index: number): string {
  if (index < 0 || index >= probes.length) {
    return '';
  }
  const probe = probes[index];
  return probe.ok ? probe.body : '';
}

function probeAt(probes: Array<ProbeResult>, index: number): ProbeResult | null {
  if (index < 0 || index >= probes.length) {
    return null;
  }
  return probes[index];
}

function outcome(state: string, region: string, reason: string): ServiceOutcome {
  const o = new ServiceOutcome();
  o.state = state;
  o.region = region;
  o.reason = reason;
  return o;
}

function regexGroup(source: string, pattern: string, group: number): string {
  const re = new RegExp(pattern);
  const m = re.exec(source);
  if (m === null || m.length <= group) {
    return '';
  }
  return m[group];
}

/**
 * 按 OwnBox 的规则判定单个服务。probes 顺序必须与 probeUrlsFor 一致。
 * elapsedMs 仅用于日志,不参与判定。
 */
export function classify(id: string, probes: Array<ProbeResult>, elapsedMs: number): ServiceOutcome {
  const primary: ProbeResult | null = probeAt(probes, 0);
  const primaryOk: boolean = primary !== null && primary.ok;
  // Netflix 例外:三个 title 任一可达即算可用,主 URL 失败不能直接判死
  if (!primaryOk && id !== 'netflix') {
    return outcome(STATE_UNAVAILABLE, '', 'no_response');
  }
  const body: string = bodyOf(probes, 0);
  const lower: string = body.toLowerCase();

  if (id === 'google' || id === 'github' || id === 'disney') {
    return outcome(STATE_AVAILABLE, '', 'http_ok');
  }
  if (id === 'claude') {
    const loc: string = normalizeRegion(traceField(body, 'loc'));
    if (loc.length === 0) {
      return outcome(STATE_UNAVAILABLE, '', 'no_loc');
    }
    if (CLAUDE_BLOCKED.indexOf(loc) >= 0) {
      return outcome(STATE_RESTRICTED, loc, 'blocked_region');
    }
    return outcome(STATE_AVAILABLE, loc, 'ok');
  }
  if (id === 'chatgpt') {
    let state: string = STATE_AVAILABLE;
    let reason: string = 'ok';
    if (lower.indexOf('disallowed isp') >= 0) {
      state = STATE_RESTRICTED;
      reason = 'disallowed_isp';
    } else if (lower.indexOf('sorry, you have been blocked') >= 0) {
      state = STATE_UNAVAILABLE;
      reason = 'blocked';
    }
    const trace: string = bodyOf(probes, 1);
    const loc: string = normalizeRegion(traceField(trace, 'loc'));
    const compliance: string = bodyOf(probes, 2);
    if (compliance.indexOf('unsupported_country') >= 0) {
      state = STATE_RESTRICTED;
      reason = 'unsupported_country';
    }
    if (loc.length > 0 && CLAUDE_BLOCKED.indexOf(loc) >= 0 && state === STATE_AVAILABLE) {
      state = STATE_RESTRICTED;
      reason = 'blocked_region';
    }
    return outcome(state, loc, reason);
  }
  if (id === 'gemini') {
    const marker = ',2,1,200,"';
    const idx = body.indexOf(marker);
    let region: string = '';
    if (idx >= 0 && idx + marker.length + 3 <= body.length) {
      region = normalizeRegion(body.substring(idx + marker.length, idx + marker.length + 3));
    }
    if (region.length > 0 && GEMINI_BLOCKED.indexOf(region) >= 0) {
      return outcome(STATE_RESTRICTED, region, 'blocked_region');
    }
    return outcome(STATE_AVAILABLE, region, 'ok');
  }
  if (id === 'youtube') {
    let region = normalizeRegion(regexGroup(body, '"countryCode"\\s*:\\s*"([A-Za-z]{2})"', 1));
    if (region.length === 0) {
      // 兜底:页面里另一处 "GL":"XX"
      region = normalizeRegion(regexGroup(body, '"GL"\\s*:\\s*"([A-Za-z]{2})"', 1));
    }
    if (lower.indexOf('premium is not available in your country') >= 0 ||
      lower.indexOf('premium is not available in your region') >= 0) {
      return outcome(STATE_RESTRICTED, region, 'premium_unavailable');
    }
    return outcome(STATE_AVAILABLE, region, 'ok');
  }
  if (id === 'netflix') {
    // 三个 title 任一可访问即视为可用(与 OwnBox 相同的短路)
    for (let i = 0; i < probes.length; i++) {
      const p = probes[i];
      if (p.ok) {
        return outcome(STATE_AVAILABLE, '', 'title_reachable');
      }
    }
    return outcome(STATE_UNAVAILABLE, '', 'all_titles_failed');
  }
  if (id === 'prime') {
    if (body.indexOf('isServiceRestricted') >= 0) {
      return outcome(STATE_RESTRICTED, '', 'service_restricted');
    }
    return outcome(STATE_AVAILABLE, '', 'ok');
  }
  if (id === 'spotify') {
    if (body.indexOf('not available in your country') >= 0) {
      return outcome(STATE_RESTRICTED, '', 'country_blocked');
    }
    return outcome(STATE_AVAILABLE, '', 'ok');
  }
  if (id === 'tiktok') {
    if (lower.indexOf('access denied') >= 0 || lower.indexOf('not available in your region') >= 0) {
      return outcome(STATE_RESTRICTED, '', 'region_blocked');
    }
    const region = normalizeRegion(
      regexGroup(body, '"webapp\\.app-context"\\s*:\\s*\\{[^{}]*?"region"\\s*:\\s*"([^"]*)"', 1));
    return outcome(STATE_AVAILABLE, region, 'ok');
  }
  if (id === 'discord') {
    const region = normalizeRegion(regexGroup(body, '"country_code"\\s*:\\s*"([^"]+)"', 1));
    return outcome(STATE_AVAILABLE, region, 'ok');
  }
  if (id === 'bilibili') {
    if (body.indexOf('"code":0') >= 0) {
      return outcome(STATE_AVAILABLE, 'CN', 'main_ok');
    }
    if (body.indexOf('-10403') >= 0) {
      const hk: string = bodyOf(probes, 1);
      if (hk.indexOf('"code":0') >= 0) {
        return outcome(STATE_AVAILABLE, 'HK', 'hk_ok');
      }
      return outcome(STATE_RESTRICTED, '', 'area_limited');
    }
    return outcome(STATE_UNAVAILABLE, '', 'unexpected_body');
  }
  return outcome(STATE_AVAILABLE, '', 'http_ok');
}

/** 状态排序权重(全部检测时按「不可用 → 受限 → 可用」展示更利于排障) */
export function stateRank(state: string): number {
  if (state === STATE_UNAVAILABLE) {
    return 0;
  }
  if (state === STATE_RESTRICTED) {
    return 1;
  }
  if (state === STATE_AVAILABLE) {
    return 2;
  }
  return 3;
}

/** 分类过滤;CAT_ALL 返回全量 */
export function servicesOfCategory(category: string): Array<ServiceDef> {
  const all = serviceDefs();
  if (category === CAT_ALL) {
    return all;
  }
  return all.filter((d: ServiceDef) => d.category === category);
}

/** 汇总统计(顶部「可用 9 / 受限 2 / 不可用 2」) */
export class DiagnosticsSummary {
  available: number = 0;
  restricted: number = 0;
  unavailable: number = 0;
  testing: number = 0;
  idle: number = 0;
  total: number = 0;
}

export function summarize(states: Array<string>): DiagnosticsSummary {
  const s = new DiagnosticsSummary();
  s.total = states.length;
  for (let i = 0; i < states.length; i++) {
    const st = states[i];
    if (st === STATE_AVAILABLE) {
      s.available++;
    } else if (st === STATE_RESTRICTED) {
      s.restricted++;
    } else if (st === STATE_UNAVAILABLE) {
      s.unavailable++;
    } else if (st === STATE_TESTING) {
      s.testing++;
    } else {
      s.idle++;
    }
  }
  return s;
}
