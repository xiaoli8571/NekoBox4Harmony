/**
 * 日志清除标记与脱敏 —— REDESIGN-PLAN-2026-10-23.md §10.4(P5/W20)。
 *
 * 「清空当前日志视图」语义:
 *  - 记录清除时的**文件偏移 + 文件身份**(大小+mtime 指纹);下次 tail 从该偏移继续 →
 *    新日志仍可见、旧日志不重现;
 *  - 文件轮转/截断(身份变化)→ 按新文件处理(从 0 开始重读);
 *  - UI 内存缓冲照常清空(当前视图立即干净)。
 *
 * 导出脱敏(默认开启,导出前可预览):
 *  - URL 凭据(user:pass@ → ***@);
 *  - 订阅 token/密钥类查询参数值打码(token/key/secret/password/uuid 等);
 *  - 分享链接中的 base64 载荷与密码字段(ss://…:password@、vmess://…、password="…")。
 *
 * 纯函数/纯数据:主机测试见 tests/log-view.cjs。
 */

/** 一条清除标记(Preferences 持久化;JSON 序列化)。 */
export class LogClearMarker {
  /** 清除的内核日志文件路径标识(路径变化 = 新文件) */
  filePath: string = '';
  /** 清除时的文件身份指纹(`<size>:<mtimeMs>`) */
  fileId: string = '';
  /** 清除时的字节偏移(下次 tail 从这里继续) */
  offset: number = 0;
  clearedAt: number = 0;
}

export function fileIdentityOf(path: string, size: number, _mtimeMs: number): string {
  // 身份刻意不含 mtime:内核日志是 append-only,mtime 每秒都在变,掺进身份会把
  // 正常追加误判成「新文件」→ 从 0 重读 → 旧日志重现。轮转/截断由「size 回退到
  // 标记偏移以下」识别(tailStartOffset 里处理)。
  return `${path}|${Math.max(0, Math.floor(size))}`;
}

export function markerToJson(marker: LogClearMarker): string {
  const parts: Array<string> = [];
  parts.push(`"filePath":${JSON.stringify(marker.filePath)}`);
  parts.push(`"fileId":${JSON.stringify(marker.fileId)}`);
  parts.push(`"offset":${marker.offset}`);
  parts.push(`"clearedAt":${marker.clearedAt}`);
  return `{${parts.join(',')}}`;
}

export function parseMarker(text: string): LogClearMarker | null {
  try {
    const raw = JSON.parse(text) as Record<string, Object>;
    const marker = new LogClearMarker();
    marker.filePath = `${raw['filePath'] ?? ''}`;
    marker.fileId = `${raw['fileId'] ?? ''}`;
    marker.offset = Number(raw['offset'] ?? 0);
    marker.clearedAt = Number(raw['clearedAt'] ?? 0);
    if (marker.filePath.length === 0 || marker.fileId.length === 0 || !(marker.offset >= 0)) {
      return null;
    }
    return marker;
  } catch (e) {
    return null;
  }
}

/**
 * 计算 tail 起始偏移:
 *  - 无标记/换路径 → 0;
 *  - 当前大小 ≥ 标记偏移 → 从标记偏移继续(append 场景:旧日志不重现,新日志可见);
 *  - 当前大小 < 标记偏移 → 文件被轮转/截断 → 0(按新文件处理)。
 * mtime 不参与判定:append 每秒都改 mtime,掺进判据会把追加误判成新文件。
 */
export function tailStartOffset(marker: LogClearMarker | null, path: string, size: number,
  _mtimeMs: number): number {
  if (marker === null || marker.filePath !== path) {
    return 0;
  }
  if (size < marker.offset) {
    return 0;
  }
  return marker.offset;
}

/** 生成「现在清除」的标记(调用方传入当前文件身份与偏移)。 */
export function buildClearMarker(path: string, size: number, mtimeMs: number,
  offset: number, nowMs: number): LogClearMarker {
  const marker = new LogClearMarker();
  marker.filePath = path;
  marker.fileId = fileIdentityOf(path, size, mtimeMs);
  marker.offset = Math.max(0, Math.floor(offset));
  marker.clearedAt = nowMs;
  return marker;
}

// ---------------- 导出脱敏 ----------------

const SENSITIVE_PARAM_KEYS: Array<string> = [
  'token', 'key', 'secret', 'password', 'passwd', 'pwd', 'uuid', 'auth', 'credential', 'access_key'
];

function maskValue(value: string): string {
  if (value.length <= 4) {
    return '****';
  }
  return `${value.substring(0, 2)}****${value.substring(value.length - 2)}`;
}

/** 单条 URL:凭据与敏感查询参数打码。 */
function redactUrl(url: string): string {
  let out = url;
  // URL 内嵌凭据 scheme://user:pass@host
  out = out.replace(/([a-z][a-z0-9+.-]*:\/\/)([^\/@:?\s]+):([^\/@?\s]+)@/gi,
    (_all: string, scheme: string, user: string, _pass: string) => `${scheme}${user}:****@`);
  // 敏感查询参数 ?token=xxx / &key=yyy(含 URL 编码值)
  out = out.replace(/([?&])([a-z0-9_-]+)=([^&\s]+)/gi,
    (all: string, lead: string, key: string, value: string) => {
      const lower = key.toLowerCase();
      for (let i = 0; i < SENSITIVE_PARAM_KEYS.length; i++) {
        if (lower === SENSITIVE_PARAM_KEYS[i] || lower.endsWith(`_${SENSITIVE_PARAM_KEYS[i]}`)) {
          return `${lead}${key}=${maskValue(value)}`;
        }
      }
      return all;
    });
  return out;
}

/**
 * 日志文本脱敏(逐行):
 *  - 任何 http(s)/ss/trojan/vmess/vless/hysteria URL → redactUrl;
 *  - 分享链接的 base64 载荷(vmess://<base64> / ss://<base64>@)→ 打码;
 *  - password="…"/"password": "…" 字段值 → 打码。
 * 不改动日志时间戳/等级/正文其余部分,保证脱敏后仍可排障。
 */
export function redactLogText(text: string): string {
  const lines = text.split('\n');
  const out: Array<string> = [];
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    line = line.replace(/[a-z][a-z0-9+.-]*:\/\/[^\s"'<>)]+/gi, (url: string) => redactUrl(url));
    line = line.replace(/\b(vmess|vless|trojan|ss|ssr|hysteria2?|tuic):\/\/[A-Za-z0-9+/=]{16,}/gi,
      (all: string, scheme: string) => `${scheme}://<redacted:${all.length - scheme.length - 3}>`);
    line = line.replace(/(password"?\s*[:=]\s*")([^"]{1,})(")/gi,
      (all: string, head: string, value: string, tail: string) => `${head}${maskValue(value)}${tail}`);
    out.push(line);
  }
  return out.join('\n');
}

/** 脱敏预览结果(P6/W21:尾注 token 化,页面映射 $r)。 */
export class RedactPreview {
  /** 前 N 行(或全部)的脱敏文本 */
  text: string = '';
  /** 脱敏后的总行数 */
  totalLines: number = 0;
  /** 是否发生截断(false = 全量都在 text 里,页面不渲染尾注) */
  truncated: boolean = false;
}

/** 脱敏预览:前 N 行 + 总行数(导出前预览用,§10.4;尾注由页面用 log_redact_preview_tail 渲染)。 */
export function redactPreview(text: string, maxLines: number): RedactPreview {
  const view = new RedactPreview();
  const redacted = redactLogText(text);
  const lines = redacted.split('\n');
  view.totalLines = lines.length;
  if (lines.length <= maxLines) {
    view.text = redacted;
    view.truncated = false;
    return view;
  }
  view.text = lines.slice(0, maxLines).join('\n');
  view.truncated = true;
  return view;
}
