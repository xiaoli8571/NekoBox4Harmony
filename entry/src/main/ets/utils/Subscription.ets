import http from '@ohos.net.http';
import { Profile, ProfileType } from '../model/Profile';

/**
 * 订阅链接支持:
 *  - 下载订阅(HTTP GET,UA 伪装 v2rayNG,服务商通常回 base64 的分享链接列表)
 *  - 若服务商返回 Clash YAML(proxies:),用内置的轻量解析器提取节点
 */

const SUB_UA = 'v2rayNG/1.9.16';

export async function fetchSubscription(url: string): Promise<string> {
  const client = http.createHttp();
  try {
    const headers: Record<string, string> = { 'User-Agent': SUB_UA };
    const opts: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 30000
    };
    const resp = await client.request(url, opts);
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      throw new Error(`订阅服务器返回 HTTP ${resp.responseCode}`);
    }
    const body: string | Object | ArrayBuffer = resp.result;
    if (typeof body === 'string') {
      return body;
    }
    return `${body}`;
  } finally {
    client.destroy();
  }
}

export interface ClashParseResult {
  profiles: Array<Profile>;
  skipped: number;
}

export function looksLikeClashYaml(text: string): boolean {
  return /(^|\n)\s*proxies\s*:/.test(text);
}

// ---------------------------------------------------------------- Clash YAML

export function parseClashProxies(yaml: string): ClashParseResult {
  const result: ClashParseResult = { profiles: [], skipped: 0 };
  const lines = yaml.split(/\r?\n/);
  let inProxies = false;
  let current: Array<string> | null = null;
  const items: Array<Array<string>> = [];
  for (const line of lines) {
    if (!inProxies) {
      if (/^proxies\s*:/.test(line)) {
        inProxies = true;
      }
      continue;
    }
    if (/^\S/.test(line)) {
      break; // 下一个顶层 key,列表结束
    }
    if (/^\s*-\s+/.test(line)) {
      if (current !== null) {
        items.push(current);
      }
      const l: Array<string> = [line.replace(/^\s*-\s+/, '')];
      current = l;
    } else if (current !== null && line.trim().length > 0) {
      current.push(line.trim());
    }
  }
  if (current !== null) {
    items.push(current);
  }
  for (const item of items) {
    const p = profileFromClash(parseClashItem(item));
    if (p === null) {
      result.skipped++;
    } else {
      result.profiles.push(p);
    }
  }
  return result;
}

function parseClashItem(rawLines: Array<string>): Record<string, Object> {
  const first = rawLines[0].trim();
  if (first.startsWith('{')) {
    const joined = rawLines.join('');
    const m = parseFlowMap(joined.trim());
    if (m !== null) {
      return m;
    }
  }
  return parseBlockItem(rawLines);
}

function indentOf(l: string): number {
  let n = 0;
  while (n < l.length && (l.charAt(n) === ' ' || l.charAt(n) === '\t')) {
    n++;
  }
  return n;
}

function parseBlockItem(rawLines: Array<string>): Record<string, Object> {
  const out: Record<string, Object> = {};
  const maps: Array<Record<string, Object>> = [out];
  const indents: Array<number> = [-1];
  for (const l of rawLines) {
    const ind = indentOf(l);
    const t = l.trim();
    const i = t.indexOf(':');
    if (i <= 0) {
      continue;
    }
    while (indents.length > 1 && ind <= indents[indents.length - 1]) {
      indents.pop();
      maps.pop();
    }
    const current = maps[maps.length - 1];
    const k = t.substring(0, i).trim();
    const v = t.substring(i + 1).trim();
    if (v.length === 0) {
      const child: Record<string, Object> = {};
      current[k] = child;
      maps.push(child);
      indents.push(ind);
    } else {
      current[k] = parseScalar(v);
    }
  }
  return out;
}

function parseScalar(raw: string): Object {
  const v = raw.trim();
  if (v.startsWith('{')) {
    const m = parseFlowMap(v);
    if (m !== null) {
      return m;
    }
  }
  if (v.startsWith('[') && v.endsWith(']')) {
    const inner = v.substring(1, v.length - 1);
    const parts = splitTopLevel(inner, ',');
    const arr: Array<Object> = [];
    for (const p of parts) {
      if (p.trim().length > 0) {
        arr.push(parseScalar(p));
      }
    }
    return arr;
  }
  if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) {
    return v.substring(1, v.length - 1);
  }
  if (v === 'true') {
    return true;
  }
  if (v === 'false') {
    return false;
  }
  if (v.length > 0) {
    const n = Number(v);
    if (!isNaN(n)) {
      return n;
    }
  }
  return v;
}

function splitTopLevel(s: string, sep: string): Array<string> {
  const parts: Array<string> = [];
  let depth = 0;
  let quote = '';
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i);
    if (quote !== '') {
      if (c === quote) {
        quote = '';
      }
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
    } else if (c === '{' || c === '[') {
      depth++;
    } else if (c === '}' || c === ']') {
      depth--;
    } else if (c === sep && depth === 0) {
      parts.push(s.substring(start, i));
      start = i + 1;
    }
  }
  parts.push(s.substring(start));
  return parts;
}

function parseFlowMap(s: string): Record<string, Object> | null {
  const v = s.trim();
  if (!v.startsWith('{') || !v.endsWith('}')) {
    return null;
  }
  const inner = v.substring(1, v.length - 1);
  const out: Record<string, Object> = {};
  for (const part of splitTopLevel(inner, ',')) {
    const t = part.trim();
    if (t.length === 0) {
      continue;
    }
    const i = t.indexOf(':');
    if (i <= 0) {
      continue;
    }
    const key = parseScalar(t.substring(0, i)) as string;
    out[key] = parseScalar(t.substring(i + 1));
  }
  return out;
}

function mStr(m: Record<string, Object>, k: string, dflt: string = ''): string {
  const v = m[k];
  if (v === undefined || v === null) {
    return dflt;
  }
  return `${v}`;
}

function mNum(m: Record<string, Object>, k: string): number {
  const v = m[k];
  if (typeof v === 'number') {
    return v;
  }
  const x = Number(`${v}`);
  return isNaN(x) ? 0 : x;
}

function mBool(m: Record<string, Object>, k: string): boolean {
  const v = m[k];
  return v === true || `${v}` === 'true';
}

function applyClashTransport(p: Profile, m: Record<string, Object>): void {
  const net = mStr(m, 'network');
  p.transport = net === 'tcp' ? '' : net;
  const wsKey = `${net}-opts`;
  const wo = m[wsKey];
  if (wo !== undefined && wo !== null) {
    const w = wo as Record<string, Object>;
    p.path = mStr(w, 'path');
    p.serviceName = mStr(w, 'serviceName');
    const hh = w['headers'];
    if (hh !== undefined && hh !== null) {
      const h = hh as Record<string, Object>;
      p.host = mStr(h, 'Host');
    }
  }
}

function profileFromClash(m: Record<string, Object> | null): Profile | null {
  if (m === null) {
    return null;
  }
  const type = mStr(m, 'type');
  const p = new Profile();
  p.name = mStr(m, 'name');
  p.server = mStr(m, 'server');
  p.serverPort = mNum(m, 'port');
  if (p.server.length === 0 || p.serverPort <= 0) {
    return null;
  }
  switch (type) {
    case 'ss':
      p.type = ProfileType.SHADOWSOCKS;
      p.method = mStr(m, 'cipher');
      p.password = mStr(m, 'password');
      break;
    case 'vmess':
      p.type = ProfileType.VMESS;
      p.uuid = mStr(m, 'uuid');
      p.alterId = mNum(m, 'alterId');
      p.security = mStr(m, 'cipher', 'auto');
      p.tls = mBool(m, 'tls');
      p.sni = mStr(m, 'servername');
      applyClashTransport(p, m);
      break;
    case 'vless':
      p.type = ProfileType.VLESS;
      p.uuid = mStr(m, 'uuid');
      p.flow = mStr(m, 'flow');
      p.tls = mBool(m, 'tls') || mStr(m, 'servername').length > 0;
      p.sni = mStr(m, 'servername');
      p.allowInsecure = mBool(m, 'skip-cert-verify');
      const reality = m['reality-opts'];
      if (reality !== undefined && reality !== null) {
        const r = reality as Record<string, Object>;
        p.realityPublicKey = mStr(r, 'public-key');
        p.realityShortId = mStr(r, 'short-id');
        p.tls = true;
      }
      applyClashTransport(p, m);
      break;
    case 'trojan':
      p.type = ProfileType.TROJAN;
      p.password = mStr(m, 'password');
      p.sni = mStr(m, 'servername');
      p.allowInsecure = mBool(m, 'skip-cert-verify');
      applyClashTransport(p, m);
      break;
    case 'hysteria':
      p.type = ProfileType.HYSTERIA;
      p.password = mStr(m, 'auth-str', mStr(m, 'auth_str'));
      p.upMbps = mNum(m, 'up');
      p.downMbps = mNum(m, 'down');
      p.obfs = mStr(m, 'obfs');
      p.sni = mStr(m, 'sni');
      p.tls = true;
      break;
    default:
      // hysteria2 / tuic / ssr 等内核 1.4 不支持或暂未映射
      return null;
  }
  return p;
}
