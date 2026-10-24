import util from '@ohos.util';
import { Profile, ProfileType } from '../model/Profile';
import { parseSingBoxConfig, parseSingleOutboundJson } from './Subscription';

/**
 * 分享链接 / 订阅解析 — 对齐 NekoBoxForAndroid 支持的常见格式:
 *   ss://  (SIP002 + 旧版整段 base64)
 *   vmess:// (base64 JSON)
 *   vless:// trojan:// hysteria:// tuic:// http(s):// socks://
 *   sing-box JSON(完整配置或单个出站对象,对齐安卓 RawUpdater.parseJSON)
 *   WireGuard .conf(对齐安卓 RawUpdater.parseWireGuard)
 * 整段 base64 的订阅内容也会被自动识别并逐行解析。
 */

/**
 * 分享链接解析的跳过项上报(可选 out 参数,保持既有调用点兼容)。
 * 用户报「解析不到节点」时,需要能区分「格式没认出来」与「认出来了但全被跳过」,
 * 后者必须告诉他到底跳过了哪些行(ssr:// 整份订阅是常见情形)。
 */
export interface ShareSkipReport {
  skipped: number;
  names: Array<string>;
}

/** 行摘要:取 scheme 与 name 片段,便于用户在提示里认出行类型 */
function shareLineHint(t: string): string {
  const scheme = t.indexOf('://');
  if (scheme <= 0) {
    return t.substring(0, 40);
  }
  const head = t.substring(0, scheme + 3);
  // 分享链接的节点名在 # 之后;没有就回退到整行前 40 字符
  const hash = t.indexOf('#');
  if (hash > 0 && hash < t.length - 1) {
    return `${head}…${t.substring(hash + 1, hash + 21)}`;
  }
  return `${head}${t.substring(scheme + 3, scheme + 23)}`;
}

export function parseShareText(text: string, report?: ShareSkipReport): Array<Profile> {
  const result: Array<Profile> = [];
  if (text === undefined || text === null) {
    return result;
  }
  const trimmed = text.trim();
  if (trimmed.length === 0) {
    return result;
  }
  let content = trimmed;
  if (!content.includes('://')) {
    // 先试 base64:订阅正文常常是「分享链接列表 / sing-box JSON / WireGuard .conf」
    // 整体 base64 后再发过来。判据不能只看解出后有没有 '://' —— 那样会把
    // base64 包裹的 WG .conf 与 sing-box JSON 解出来又丢掉(用户从面板复制
    // 「WG 导出(base64)」「sing-box 配置(base64)」时会导入 0 个节点)。
    const decoded = tryDecodeBase64Loose(content);
    if (decoded !== null) {
      // 解出来的可能是链接、JSON 或 .conf,统一交给下面同一套分派逻辑,
      // 避免第二份重复实现。
      content = decoded;
    }
  }
  if (!content.includes('://')) {
    // sing-box JSON:完整配置({outbounds/endpoints})或单个出站对象
    if (content.startsWith('{')) {
      const jsonProfiles = parseSingleOutboundJson(content).profiles;
      if (jsonProfiles.length > 0) {
        return jsonProfiles;
      }
    }
    // WireGuard .conf(含 [Interface]/[Peer] 段)
    if (content.includes('[Interface]')) {
      const wgProfiles = parseWireGuardConf(content);
      if (wgProfiles.length > 0) {
        return wgProfiles;
      }
    }
  }
  // ---- 双份解析 — 逐字对齐 Android `ktx/Formats.kt:107-108,230-239` ----
  //  Android 同时构造两份链接表:
  //    links       = text.split('\n').flatMap { it.trim().split(' ') }  // 行内再按空格切
  //    linksByLine = text.split('\n').map { it.trim() }                 // 只按行
  //  各自解析后 **返回数量多的那份**(相等时返回按行那份)。
  //  这样「一行里塞了多个链接」的订阅能全部导入,而「链接里带空格的名字」
  //  不会被切坏(按行那份数量不会更少)。
  const lines: Array<string> = [];
  for (const line of content.split(/[\r\n]+/)) {
    const t = line.trim();
    if (t.length > 0) {
      lines.push(t);
    }
  }
  const spaceTokens: Array<string> = [];
  for (const line of lines) {
    for (const token of line.split(' ')) {
      const t = token.trim();
      if (t.length > 0) {
        spaceTokens.push(t);
      }
    }
  }
  const bySpace = parseLinkBatch(spaceTokens);
  const byLine = parseLinkBatch(lines);
  const chosen = bySpace.profiles.length > byLine.profiles.length ? bySpace : byLine;
  if (report !== undefined) {
    report.skipped += chosen.skipped;
    for (const name of chosen.names) {
      if (report.names.length >= 20) {
        break;
      }
      report.names.push(name);
    }
  }
  return chosen.profiles;
}

interface ParseBatch {
  profiles: Array<Profile>;
  skipped: number;
  names: Array<string>;
}

/** 逐条解析一批链接;跳过项单独记账,由调用方按 Android 的「取数量多的那份」合并。 */
function parseLinkBatch(tokens: Array<string>): ParseBatch {
  const batch: ParseBatch = { profiles: [], skipped: 0, names: [] };
  for (const t of tokens) {
    try {
      const p = parseOne(t);
      if (p !== null) {
        batch.profiles.push(p);
      } else {
        // 认得 scheme 但内核不支持 / 参数不全 —— 记账,让「全被跳过」可诊断
        batch.skipped++;
        if (batch.names.length < 20) {
          batch.names.push(shareLineHint(t));
        }
      }
    } catch (e) {
      // 解析抛异常(缺字段/编码错误等)同样算跳过,否则用户只看到 0 节点
      batch.skipped++;
      if (batch.names.length < 20) {
        batch.names.push(shareLineHint(t));
      }
    }
  }
  return batch;
}

function parseOne(line: string): Profile | null {
  if (line.startsWith('ss://')) {
    return parseShadowsocks(line);
  }
  if (line.startsWith('vmess://')) {
    return parseVmess(line);
  }
  if (line.startsWith('vless://')) {
    return parseUserinfoLink(line, ProfileType.VLESS);
  }
  if (line.startsWith('trojan://')) {
    return parseUserinfoLink(line, ProfileType.TROJAN);
  }
  if (line.startsWith('trojan-go://')) {
    return parseTrojanGoLink(line);
  }
  if (line.startsWith('naive+')) {
    // naive 在 Android 由独立插件进程(naive-plugin)执行,见 BoxInstance.kt:70-73,108-140;
    // 鸿蒙内核(sing-box 1.14)无 naive 出站、沙箱也不允许 exec 插件 → 不可实现,
    // 返回 null 由调用方上报为「已跳过」(见 docs/PARITY-SUBSCRIPTION.md §15 U2)。
    return null;
  }
  if (line.startsWith('hysteria://')) {
    return parseUserinfoLink(line, ProfileType.HYSTERIA);
  }
  if (line.startsWith('hysteria2://') || line.startsWith('hy2://')) {
    return parseHysteria2(line);
  }
  if (line.startsWith('tuic://')) {
    return parseUserinfoLink(line, ProfileType.TUIC);
  }
  if (line.startsWith('anytls://')) {
    return parseUserinfoLink(line, ProfileType.ANYTLS);
  }
  if (line.startsWith('snell://')) {
    return parseUserinfoLink(line, ProfileType.SNELL);
  }
  if (line.startsWith('ssh://')) {
    return parseUserinfoLink(line, ProfileType.SSH);
  }
  if (line.startsWith('http://') || line.startsWith('https://')) {
    return parseUserinfoLink(line, ProfileType.HTTP);
  }
  if (line.startsWith('socks://') || line.startsWith('socks5://')
    || line.startsWith('socks4://') || line.startsWith('socks4a://')) {
    return parseUserinfoLink(line, ProfileType.SOCKS);
  }
  return null;
}

/**
 * 宽松 base64 解码:成功返回正文,不是 base64 返回 null。
 *
 * 与 base64Decode 的区别在于「先判是不是 base64」,而不是靠「解出来有没有 ://」。
 * 判据(全部满足才认为是 base64):
 *   1. 去掉空白后非空;
 *   2. 只含 base64 字母表(+ URL-safe 的 -_)与尾部 padding;
 *   3. 去掉 padding 后长度 % 4 != 1(base64 长度不可能余 1);
 *   4. 解码成功且不产生 U+FFFD 替换字符(说明是有效 UTF-8 文本,不是二进制垃圾)。
 * 只有判为 base64 才替换 content,否则保持原文(例如机场返回的纯文本提示)。
 */
function tryDecodeBase64Loose(input: string): string | null {
  const s = input.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
  if (s.length === 0) {
    return null;
  }
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(s)) {
    return null;
  }
  const body = s.replace(/=+$/, '');
  if (body.length === 0 || body.length % 4 === 1) {
    return null;
  }
  let decoded: string;
  try {
    decoded = base64Decode(s);
  } catch (e) {
    return null;
  }
  // 出现替换字符说明解出来的不是合法 UTF-8 文本,多半是把二进制当 base64 了。
  if (decoded.indexOf('\uFFFD') >= 0) {
    return null;
  }
  return decoded;
}

function base64Decode(input: string): string {
  // 机场的订阅正文经常被硬折行(每 60/76 字符插换行),或含空格/制表符/回车。
  // Base64Helper 对这些字符是严格解,含任一空白就整段解码失败 →
  // 表现为「订阅解析不到节点」。先去噪再补 padding。
  // 同时兼容 URL-safe 变体(-_ → +/)与无 padding 的裸 base64。
  let s = input.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
  if (s.length % 4 !== 0) {
    s += '='.repeat(4 - (s.length % 4));
  }
  const arr: Uint8Array = new util.Base64Helper().decodeSync(s);
  return util.TextDecoder.create('utf-8').decodeToString(arr);
}

function base64Encode(input: string): string {
  const encoder = new util.TextEncoder();
  const bytes: Uint8Array = encoder.encodeInto(input);
  return new util.Base64Helper().encodeToStringSync(bytes);
}

function newName(name: string, fallback: string): string {
  return name.length > 0 ? name : fallback;
}

function splitFragment(rest: string): [string, string] {
  const i = rest.indexOf('#');
  if (i < 0) {
    return [rest, ''];
  }
  let name = rest.substring(i + 1);
  // '+' 按 RFC 3986 是字面字符,不做 form 编码的空格替换(会破坏含 '+' 的节点名)
  name = decodeURIComponentSafe(name);
  return [rest.substring(0, i), name];
}

function parseQuery(q: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (q.startsWith('?')) {
    q = q.substring(1);
  }
  // 同时兼容 form 编码的分隔符(部分面板用 ';' 拼接)
  const parts = q.split(/[&;]/);
  for (const p of parts) {
    if (p.length === 0) {
      continue;
    }
    const i = p.indexOf('=');
    if (i < 0) {
      out[decodeURIComponentSafe(p)] = '';
    } else {
      const key = decodeURIComponentSafe(p.substring(0, i));
      const val = p.substring(i + 1);
      // RFC 3986:query 里的 '+' 是字面字符,不是空格(那是 HTML form 编码的规则)。
      // 此前先 replace(/\+/g,'%20') 会把含 '+' 的密码/短 ID 改成空格 → 握手失败。
      // 片段部分(splitFragment)同样处理。
      out[key] = decodeURIComponentSafe(val);
    }
  }
  return out;
}

function qstr(q: Record<string, string>, key: string, dflt: string = ''): string {
  const v = q[key];
  return v === undefined ? dflt : v;
}

function qbool(q: Record<string, string>, key: string): boolean {
  const v = q[key];
  if (v === undefined) {
    return false;
  }
  return v === '1' || v === 'true';
}

function hostPortOf(netloc: string, dfltPort: number): [string, number] {
  // 处理 [IPv6]:port
  let host = netloc;
  let port = dfltPort;
  if (netloc.startsWith('[')) {
    const end = netloc.indexOf(']');
    if (end > 0) {
      host = netloc.substring(1, end);
      const rest = netloc.substring(end + 1);
      if (rest.startsWith(':')) {
        port = parseInt(rest.substring(1));
      }
    }
  } else {
    const i = netloc.lastIndexOf(':');
    if (i > 0) {
      host = netloc.substring(0, i);
      const ps = netloc.substring(i + 1);
      const pn = parseInt(ps);
      if (!isNaN(pn)) {
        port = pn;
      }
    }
  }
  return [host, port];
}

function applyQueryTls(p: Profile, q: Record<string, string>): void {
  const security = qstr(q, 'security', qstr(q, 'tls', ''));
  if (security === 'tls' || security === 'reality' || security === '1' || security === 'true') {
    p.tls = true;
  }
  if (security === 'reality') {
    p.tls = true;
    p.realityPublicKey = qstr(q, 'pbk');
    p.realityShortId = qstr(q, 'sid');
  }
  p.sni = qstr(q, 'sni', qstr(q, 'peer', qstr(q, 'host')));
  p.allowInsecure = qbool(q, 'allowInsecure') || qbool(q, 'insecure');
  p.alpn = qstr(q, 'alpn');
  p.fingerprint = qstr(q, 'fp');
  p.flow = qstr(q, 'flow');
}

function applyTransport(p: Profile, q: Record<string, string>): void {
  const net = qstr(q, 'type', qstr(q, 'network', ''));
  p.transport = net;
  p.path = qstr(q, 'path');
  p.host = qstr(q, 'host', qstr(q, 'authority'));
  p.serviceName = qstr(q, 'serviceName');
  if (net === 'grpc' && p.serviceName === '') {
    p.serviceName = qstr(q, 'path');
  }
  const earlyData = qstr(q, 'ed', qstr(q, 'max_early_data', ''));
  if (earlyData.length > 0) {
    const value = parseInt(earlyData);
    if (!isNaN(value) && value > 0) {
      p.wsEarlyData = value;
    }
  }
  p.wsEarlyDataHeaderName = qstr(q, 'eh', qstr(q, 'early_data_header_name', ''));
}

// ---------------------------------------------------------------- ss://
function parseShadowsocks(link: string): Profile | null {
  const rest = splitFragment(link.substring(5))[0];
  let name = splitFragment(link.substring(5))[1];
  const p = new Profile();
  p.type = ProfileType.SHADOWSOCKS;

  const at = rest.lastIndexOf('@');
  if (at > 0) {
    // SIP002: ss://base64(method:password)@host:port?plugin=...
    let userinfo = rest.substring(0, at);
    const qi = rest.indexOf('?', at);
    const netloc = qi < 0 ? rest.substring(at + 1) : rest.substring(at + 1, qi);
    const q = parseQuery(qi < 0 ? '' : rest.substring(qi));
    let plainUserinfo = false;
    try {
      userinfo = base64Decode(userinfo);
    } catch (e) {
      // SIP002 也允许明文 userinfo；明文分段后需要 URI decode。
      plainUserinfo = true;
    }
    const ci = userinfo.indexOf(':');
    if (ci < 0) {
      return null;
    }
    if (plainUserinfo) {
      p.method = decodeURIComponentSafe(userinfo.substring(0, ci));
      p.password = decodeURIComponentSafe(userinfo.substring(ci + 1));
    } else {
      p.method = userinfo.substring(0, ci);
      p.password = userinfo.substring(ci + 1);
    }
    const hp = hostPortOf(netloc, 443);
    p.server = hp[0];
    p.serverPort = hp[1];
    const pluginValue = qstr(q, 'plugin');
    if (pluginValue.length > 0) {
      // SIP002 标准把插件名和选项合并在 plugin=name;opts 中；同时兼容旧 plugin-opts 参数。
      const separator = pluginValue.indexOf(';');
      if (separator >= 0) {
        p.ssPlugin = pluginValue.substring(0, separator);
        p.ssPluginOpts = pluginValue.substring(separator + 1);
      } else {
        p.ssPlugin = pluginValue;
        p.ssPluginOpts = qstr(q, 'plugin-opts');
      }
    }
  } else {
    // 旧版: ss://base64(method:password@host:port)
    const decoded = base64Decode(rest);
    const ci = decoded.indexOf(':');
    const at2 = decoded.lastIndexOf('@');
    if (ci < 0 || at2 < 0) {
      return null;
    }
    p.method = decoded.substring(0, ci);
    p.password = decoded.substring(ci + 1, at2);
    const hp = hostPortOf(decoded.substring(at2 + 1), 443);
    p.server = hp[0];
    p.serverPort = hp[1];
  }
  p.name = newName(name, `${p.server}:${p.serverPort}`);
  return p;
}

// ---------------------------------------------------------------- vmess://
function parseVmess(link: string): Profile | null {
  const body = splitFragment(link.substring(8))[0];
  const name = splitFragment(link.substring(8))[1];
  const json = JSON.parse(base64Decode(body)) as Record<string, Object>;
  const p = new Profile();
  p.type = ProfileType.VMESS;
  p.name = newName(strField(json, 'ps'), name.length > 0 ? name : strField(json, 'add'));
  p.server = strField(json, 'add');
  p.serverPort = numField(json, 'port');
  p.uuid = strField(json, 'id');
  p.alterId = numField(json, 'aid');
  p.security = strField(json, 'scy', 'auto');
  const net = strField(json, 'net', 'tcp');
  p.transport = net === 'tcp' ? '' : net;
  p.path = strField(json, 'path');
  p.host = strField(json, 'host');
  const tls = strField(json, 'tls');
  p.tls = tls === 'tls' || tls === 'reality';
  if (p.tls) {
    p.sni = strField(json, 'sni', p.host);
  }
  p.allowInsecure = strField(json, 'allowInsecure') === '1' || strField(json, 'verify_cert') === 'false';
  if (p.server.length === 0 || p.uuid.length === 0) {
    return null;
  }
  return p;
}

function strField(o: Record<string, Object>, key: string, dflt: string = ''): string {
  const v = o[key];
  if (v === undefined || v === null) {
    return dflt;
  }
  return `${v}`.length > 0 ? `${v}` : dflt;
}

function numField(o: Record<string, Object>, key: string): number {
  const v = o[key];
  if (v === undefined || v === null) {
    return 0;
  }
  const n = Number(`${v}`);
  return isNaN(n) ? 0 : n;
}

// ---------------------------------------------------------------- uuid@host 类
function parseHysteria2(link: string): Profile | null {
  const noScheme = link.substring(link.indexOf('://') + 3);
  const frag = splitFragment(noScheme);
  const name = frag[1];
  const qi = frag[0].indexOf('?');
  const netlocPart = qi < 0 ? frag[0] : frag[0].substring(0, qi);
  const q = parseQuery(qi < 0 ? '' : frag[0].substring(qi));
  let password = '';
  let netloc = netlocPart;
  const at = netlocPart.lastIndexOf('@');
  if (at >= 0) {
    password = decodeURIComponentSafe(netlocPart.substring(0, at));
    netloc = netlocPart.substring(at + 1);
  }
  const hp = hostPortOf(netloc, 443);
  const p = new Profile();
  p.type = ProfileType.HYSTERIA2;
  p.server = hp[0];
  p.serverPort = hp[1];
  p.name = newName(name, `${p.server}:${p.serverPort}`);
  p.password = password;
  p.tls = true;
  p.sni = qstr(q, 'sni');
  p.allowInsecure = qbool(q, 'insecure') || qbool(q, 'allowInsecure');
  p.obfs = qstr(q, 'obfs-password', qstr(q, 'obfspwd'));
  p.serverPorts = qstr(q, 'ports', qstr(q, 'server_ports', ''));
  const hopInterval = qstr(q, 'hop-interval', qstr(q, 'hop_interval', ''));
  if (hopInterval.length > 0) {
    const value = parseInt(hopInterval);
    if (!isNaN(value) && value > 0) {
      p.hopInterval = value;
    }
  }
  const up = qstr(q, 'upmbps', qstr(q, 'up', ''));
  const down = qstr(q, 'downmbps', qstr(q, 'down', ''));
  p.upMbps = up.length > 0 ? parseInt(up) : 0;
  p.downMbps = down.length > 0 ? parseInt(down) : 0;
  if (p.server.length === 0) {
    return null;
  }
  return p;
}

/**
 * `trojan-go://` 分享链接 — 对齐 Android `fmt/trojan_go/TrojanGoFmt.kt:12-44`:
 * 把 scheme 换成 https 后按 URL 解析 host / port / username(password) / sni /
 * type(+ws 的 host、path) / encryption / plugin / #name。
 *
 * 鸿蒙没有 trojan-go 出站(Android 用独立插件进程 `trojan-go-plugin` 执行,
 * 见 BoxInstance.kt:60-63,108-121),这里映射到 TROJAN:
 * 在「无 encryption、无 plugin」的原始形态下 trojan-go 与 trojan 协议完全一致,
 * ws 传输用 transport=ws 表达;encryption(SS 包裹)与 plugin(obfs)在 sing-box
 * 无对应字段,属已知偏差(见 docs/PARITY-SUBSCRIPTION.md §14/§15)。
 */
function parseTrojanGoLink(link: string): Profile | null {
  const asUrl = link.replace('trojan-go://', 'https://');
  const noScheme = asUrl.substring(asUrl.indexOf('://') + 3);
  const frag = splitFragment(noScheme);
  const name = frag[1];
  const qi = frag[0].indexOf('?');
  const netlocPart = qi < 0 ? frag[0] : frag[0].substring(0, qi);
  const q = parseQuery(qi < 0 ? '' : frag[0].substring(qi));

  let userinfo = '';
  let netloc = netlocPart;
  const at = netlocPart.lastIndexOf('@');
  if (at >= 0) {
    userinfo = netlocPart.substring(0, at);
    netloc = netlocPart.substring(at + 1);
  }
  const hp = hostPortOf(netloc, 443);
  if (hp[0].length === 0 || hp[1] <= 0) {
    return null;
  }
  const p = new Profile();
  p.type = ProfileType.TROJAN;
  p.server = hp[0];
  p.serverPort = hp[1];
  p.password = decodeURIComponentSafe(userinfo);
  p.name = newName(name, `${p.server}:${p.serverPort}`);
  p.tls = true;
  const sni = qstr(q, 'sni');
  if (sni.length > 0) {
    p.sni = sni;
  }
  // Android 只在有 type 时处理,且只有 ws 才读 host/path
  const goType = qstr(q, 'type');
  if (goType === 'ws') {
    p.transport = 'ws';
    const goHost = qstr(q, 'host');
    if (goHost.length > 0) {
      p.host = goHost;
    }
    const goPath = qstr(q, 'path');
    if (goPath.length > 0) {
      p.path = goPath;
    }
  }
  return p;
}

function parseUserinfoLink(link: string, type: string): Profile | null {
  const noScheme = link.substring(link.indexOf('://') + 3);
  const frag = splitFragment(noScheme);
  const name = frag[1];
  const qi = frag[0].indexOf('?');
  const netlocPart = qi < 0 ? frag[0] : frag[0].substring(0, qi);
  const q = parseQuery(qi < 0 ? '' : frag[0].substring(qi));

  let userinfo = '';
  let netloc = netlocPart;
  const at = netlocPart.lastIndexOf('@');
  if (at >= 0) {
    userinfo = netlocPart.substring(0, at);
    netloc = netlocPart.substring(at + 1);
  }

  const hp = hostPortOf(netloc, 443);
  const p = new Profile();
  p.type = type;
  p.server = hp[0];
  p.serverPort = hp[1];
  p.name = newName(name, `${p.server}:${p.serverPort}`);

  switch (type) {
    case ProfileType.VLESS:
      p.uuid = userinfo;
      p.security = qstr(q, 'encryption', 'auto');
      applyTransport(p, q);
      applyQueryTls(p, q);
      break;
    case ProfileType.TROJAN:
      p.password = decodeURIComponentSafe(userinfo);
      applyTransport(p, q);
      applyQueryTls(p, q);
      break;
    case ProfileType.HYSTERIA:
      p.password = qstr(q, 'auth', decodeURIComponentSafe(userinfo));
      p.upMbps = parseInt(qstr(q, 'upmbps', '100'));
      p.downMbps = parseInt(qstr(q, 'downmbps', '100'));
      p.obfs = qstr(q, 'obfs');
      p.tls = true;
      p.sni = qstr(q, 'peer', qstr(q, 'sni'));
      p.alpn = qstr(q, 'alpn', 'h3');
      p.allowInsecure = qbool(q, 'insecure');
      break;
    case ProfileType.TUIC: {
      const ci = userinfo.indexOf(':');
      if (ci > 0) {
        p.uuid = decodeURIComponentSafe(userinfo.substring(0, ci));
        p.password = decodeURIComponentSafe(userinfo.substring(ci + 1));
      } else {
        p.uuid = decodeURIComponentSafe(userinfo);
      }
      p.congestionControl = qstr(q, 'congestion_control', 'bbr');
      p.udpRelayMode = qstr(q, 'udp_relay_mode', 'native');
      p.reduceRtt = qbool(q, 'reduce_rtt');
      p.disableSni = qbool(q, 'disable_sni');
      p.tls = true;
      p.sni = qstr(q, 'sni');
      p.alpn = qstr(q, 'alpn', 'h3');
      p.allowInsecure = qbool(q, 'allow_insecure') || qbool(q, 'insecure');
      break;
    }
    case ProfileType.ANYTLS:
      p.password = decodeURIComponentSafe(userinfo);
      p.tls = true;
      p.sni = qstr(q, 'sni');
      p.alpn = qstr(q, 'alpn');
      p.allowInsecure = qbool(q, 'insecure') || qbool(q, 'allow_insecure');
      break;
    case ProfileType.SNELL:
      p.password = decodeURIComponentSafe(userinfo);
      p.tls = false;
      p.obfs = qstr(q, 'obfs');
      p.host = qstr(q, 'obfs-host', qstr(q, 'name'));
      break;
    case ProfileType.SSH: {
      const ci = userinfo.indexOf(':');
      if (ci >= 0) {
        p.username = decodeURIComponentSafe(userinfo.substring(0, ci));
        p.password = decodeURIComponentSafe(userinfo.substring(ci + 1));
        p.sshAuthType = p.password.length > 0 ? 'password' : 'none';
      } else {
        p.username = decodeURIComponentSafe(userinfo);
        p.sshAuthType = 'none';
      }
      p.tls = false;
      break;
    }
    case ProfileType.HTTP:
    case ProfileType.SOCKS: {
      const ci = userinfo.indexOf(':');
      if (ci >= 0) {
        p.username = decodeURIComponentSafe(userinfo.substring(0, ci));
        p.password = decodeURIComponentSafe(userinfo.substring(ci + 1));
      } else {
        p.username = decodeURIComponentSafe(userinfo);
      }
      p.tls = link.startsWith('https://');
      break;
    }
    default:
      break;
  }
  if (p.server.length === 0) {
    return null;
  }
  return p;
}

function decodeURIComponentSafe(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch (e) {
    return s;
  }
}

/** 供编辑页「粘贴节点链接」使用的单条链接解析。 */
export function parseSingleLink(link: string): Profile | null {
  return parseOne(link);
}

/**
 * WireGuard .conf 解析(对齐安卓 RawUpdater.parseWireGuard):
 * [Interface] 段取 PrivateKey/Address/MTU,每个 [Peer] 段取 Endpoint/PublicKey/PresharedKey 生成一个节点;
 * 缺 Endpoint/PublicKey/端口或端口非法的 Peer 跳过,与安卓一致。
 */
function parseWireGuardConf(conf: string): Array<Profile> {
  const lines = conf.split(/[\r\n]+/);
  let section = '';
  const iface: Record<string, string> = {};
  const peers: Array<Record<string, string>> = [];
  let current: Record<string, string> | null = null;
  for (const raw of lines) {
    const line = raw.trim();
    if (line.length === 0 || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.substring(1, line.length - 1).trim().toLowerCase();
      if (section === 'peer') {
        current = {};
        peers.push(current);
      }
      continue;
    }
    const i = line.indexOf('=');
    if (i < 0) {
      continue;
    }
    const key = line.substring(0, i).trim().toLowerCase();
    const val = line.substring(i + 1).trim();
    if (section === 'interface') {
      // Android ini4j 的 getAll("Address") 返回**多行**列表;这里按逗号累积,
      // 供下面的统一拆分/合并处理(多个 Address 行不会互相覆盖)。
      if (iface[key] !== undefined && key === 'address') {
        iface[key] = iface[key] + ',' + val;
      } else {
        iface[key] = val;
      }
    } else if (section === 'peer' && current !== null) {
      current[key] = val;
    }
  }
  const privateKey = iface['privatekey'] !== undefined ? iface['privatekey'] : '';
  // Android RawUpdater.kt:726-728:iface.getAll("Address") 取**多行**,逐行按 "," 拆
  // 后合并(鸿蒙以逗号分隔为内部形式,等价于安卓的 "\n" join)。
  let localAddress = '';
  for (const key of ['address']) {
    if (iface[key] === undefined) {
      continue;
    }
    for (const part of iface[key].split(',')) {
      const t = part.trim();
      if (t.length > 0) {
        localAddress = localAddress.length > 0 ? localAddress + ',' + t : t;
      }
    }
  }
  const mtuRaw = iface['mtu'] !== undefined ? iface['mtu'] : '';
  const mtu = parseInt(mtuRaw);
  const result: Array<Profile> = [];
  for (const peer of peers) {
    const endpoint = peer['endpoint'] !== undefined ? peer['endpoint'] : '';
    const lastColon = endpoint.lastIndexOf(':');
    if (lastColon <= 0) {
      continue;
    }
    let host = endpoint.substring(0, lastColon);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    const port = parseInt(endpoint.substring(lastColon + 1));
    const peerPublicKey = peer['publickey'] !== undefined ? peer['publickey'] : '';
    if (host.length === 0 || isNaN(port) || port <= 0 || peerPublicKey.length === 0) {
      continue;
    }
    const p = new Profile();
    p.type = ProfileType.WIREGUARD;
    p.server = host;
    p.serverPort = port;
    p.privateKey = privateKey;
    p.peerPublicKey = peerPublicKey;
    p.preSharedKey = peer['presharedkey'] !== undefined ? peer['presharedkey'] : '';
    p.localAddress = localAddress.length > 0 ? localAddress : '172.16.0.2/32';
    p.wgMtu = isNaN(mtu) ? 1420 : (mtu > 0 ? mtu : 1420);
    p.reserved = peer['reserved'] !== undefined ? peer['reserved'] : '';
    p.name = peer['name'] !== undefined ? peer['name'] : '';
    result.push(p);
  }
  return result;
}

export { base64Decode, base64Encode };
