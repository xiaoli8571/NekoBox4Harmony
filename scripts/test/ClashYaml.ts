/**
 * Clash YAML 子集解析器(无三方依赖)。
 *
 * 替换此前 Subscription.ets 里的逐行解析器 —— 那版有三个会静默丢配置的缺陷:
 *  1. 不剥离行内注释:`port: 443 # 主用` → Number("443 # 主用")=NaN → 0 → 整条节点被丢弃;
 *  2. 不支持锚点/别名:`ws-opts: &ws {...}` + `ws-opts: *ws` 的公共配置写法静默失效;
 *  3. 不支持合并键:`<<: *base` 被当成普通键 "<<" 存下,合并语义完全丢失。
 *
 * 这里实现的子集覆盖 Clash 订阅的实际用法:注释、锚点/别名、合并键(<<)、
 * 流式集合({} / [])、块标量(| 与 >)与多文档分隔(只取第一份)。
 * 标量一律以字符串返回,由上层的 yStr/yNum/yBool 负责类型转换,
 * 这样不必区分 int/float/bool/null,也不会把 "443" 之类的端口号丢精度。
 */

const KIND_EMPTY: number = 0;
const KIND_SCALAR: number = 1;
const KIND_MAP: number = 2;
const KIND_SEQ: number = 3;

export class YamlNode {
  kind: number = KIND_EMPTY;
  scalar: string = '';
  entries: Array<YamlEntry> = [];
  items: Array<YamlNode> = [];

  isMap(): boolean {
    return this.kind === KIND_MAP;
  }

  isSeq(): boolean {
    return this.kind === KIND_SEQ;
  }

  isScalar(): boolean {
    return this.kind === KIND_SCALAR;
  }

  get(key: string): YamlNode | null {
    for (const e of this.entries) {
      if (e.key === key) {
        return e.value;
      }
    }
    return null;
  }

  has(key: string): boolean {
    for (const e of this.entries) {
      if (e.key === key) {
        return true;
      }
    }
    return false;
  }

  put(key: string, value: YamlNode): void {
    for (const e of this.entries) {
      if (e.key === key) {
        e.value = value;
        return;
      }
    }
    const e = new YamlEntry();
    e.key = key;
    e.value = value;
    this.entries.push(e);
  }

  /** 合并键(<<)语义:并入对方已有的键,但不覆盖本映射已定义的键。 */
  mergeFrom(other: YamlNode): void {
    if (other.kind !== KIND_MAP) {
      return;
    }
    for (const e of other.entries) {
      if (!this.has(e.key)) {
        const c = new YamlEntry();
        c.key = e.key;
        c.value = e.value;
        this.entries.push(c);
      }
    }
  }
}

class YamlEntry {
  key: string = '';
  value: YamlNode = new YamlNode();
}

class YamlAnchor {
  name: string = '';
  node: YamlNode = new YamlNode();
}

/** 预处理后的行。literal=true 表示该行是块标量体(不做注释剥离)。 */
class YLine {
  indent: number = 0;
  text: string = '';
  isSeq: boolean = false;
  literal: boolean = false;
}

class PRes {
  node: YamlNode = new YamlNode();
  next: number = 0;
}

class FRes {
  node: YamlNode = new YamlNode();
  pos: number = 0;
}

export function yamlScalar(v: string): YamlNode {
  const n = new YamlNode();
  n.kind = KIND_SCALAR;
  n.scalar = v;
  return n;
}

function indentOf(l: string): number {
  let n = 0;
  while (n < l.length && (l.charAt(n) === ' ' || l.charAt(n) === '\t')) {
    n++;
  }
  return n;
}

function isSeqEntry(content: string): boolean {
  return content === '-' || (content.charAt(0) === '-' && content.charAt(1) === ' ');
}

/**
 * 剥离行内注释。`#` 只有在行首或前面是空白时才是注释起点,
 * 且引号内的 `#` 不算 —— 密码里含 `#` 的节点不会被误伤。
 */
function stripComment(line: string): string {
  let out = '';
  let quote = '';
  for (let i = 0; i < line.length; i++) {
    const c = line.charAt(i);
    if (quote.length > 0) {
      out += c;
      if (c === '\\' && quote === '"' && i + 1 < line.length) {
        out += line.charAt(i + 1);
        i++;
        continue;
      }
      if (c === quote) {
        quote = '';
      }
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      out += c;
      continue;
    }
    if (c === '#' && (i === 0 || line.charAt(i - 1) === ' ' || line.charAt(i - 1) === '\t')) {
      break;
    }
    out += c;
  }
  return out;
}

/** 找顶层键值分隔冒号:不在引号/括号内,且其后是空白或行尾。 */
function findKeyColon(s: string): number {
  let quote = '';
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i);
    if (quote.length > 0) {
      if (c === '\\' && quote === '"') {
        i++;
        continue;
      }
      if (c === quote) {
        quote = '';
      }
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      continue;
    }
    if (c === '[' || c === '{') {
      depth++;
      continue;
    }
    if (c === ']' || c === '}') {
      depth--;
      continue;
    }
    if (c === ':' && depth === 0) {
      if (i + 1 >= s.length || s.charAt(i + 1) === ' ' || s.charAt(i + 1) === '\t') {
        return i;
      }
    }
  }
  return -1;
}

function unescapeChar(c: string): string {
  if (c === 'n') {
    return '\n';
  }
  if (c === 't') {
    return '\t';
  }
  if (c === 'r') {
    return '\r';
  }
  if (c === '0') {
    return '\u0000';
  }
  return c;
}

function unescapeAll(s: string): string {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i);
    if (c === '\\' && i + 1 < s.length) {
      out += unescapeChar(s.charAt(i + 1));
      i++;
      continue;
    }
    out += c;
  }
  return out;
}

function unquote(s: string): string {
  const t = s.trim();
  if (t.length >= 2) {
    if (t.charAt(0) === '"' && t.charAt(t.length - 1) === '"') {
      return unescapeAll(t.substring(1, t.length - 1));
    }
    if (t.charAt(0) === "'" && t.charAt(t.length - 1) === "'") {
      return t.substring(1, t.length - 1).split('\'\'').join('\'');
    }
  }
  return t;
}

// ------------------------------------------------------------------ 流式集合

function skipFlowWs(s: string, p: number): number {
  let i = p;
  while (i < s.length && (s.charAt(i) === ' ' || s.charAt(i) === '\t')) {
    i++;
  }
  return i;
}

function parseFlowNode(s: string, p: number): FRes {
  const res = new FRes();
  let i = skipFlowWs(s, p);
  if (i >= s.length) {
    return res;
  }
  const c = s.charAt(i);
  if (c === '{') {
    const map = new YamlNode();
    map.kind = KIND_MAP;
    i = skipFlowWs(s, i + 1);
    if (i < s.length && s.charAt(i) === '}') {
      res.node = map;
      res.pos = i + 1;
      return res;
    }
    while (i < s.length) {
      const kr = parseFlowScalar(s, i, true);
      let key = kr.node.scalar;
      i = skipFlowWs(s, kr.pos);
      if (i < s.length && s.charAt(i) === ':') {
        i++;
      }
      const vr = parseFlowNode(s, i);
      const e = new YamlEntry();
      e.key = key;
      e.value = vr.node;
      map.entries.push(e);
      i = skipFlowWs(s, vr.pos);
      if (i < s.length && s.charAt(i) === ',') {
        i = skipFlowWs(s, i + 1);
        continue;
      }
      if (i < s.length && s.charAt(i) === '}') {
        i++;
      }
      break;
    }
    res.node = map;
    res.pos = i;
    return res;
  }
  if (c === '[') {
    const seq = new YamlNode();
    seq.kind = KIND_SEQ;
    i = skipFlowWs(s, i + 1);
    if (i < s.length && s.charAt(i) === ']') {
      res.node = seq;
      res.pos = i + 1;
      return res;
    }
    while (i < s.length) {
      const vr = parseFlowNode(s, i);
      seq.items.push(vr.node);
      i = skipFlowWs(s, vr.pos);
      if (i < s.length && s.charAt(i) === ',') {
        i = skipFlowWs(s, i + 1);
        continue;
      }
      if (i < s.length && s.charAt(i) === ']') {
        i++;
      }
      break;
    }
    res.node = seq;
    res.pos = i;
    return res;
  }
  const sr = parseFlowScalar(s, i, false);
  res.node = sr.node;
  res.pos = sr.pos;
  return res;
}

function parseFlowScalar(s: string, p: number, isKey: boolean): FRes {
  const res = new FRes();
  let i = skipFlowWs(s, p);
  if (i >= s.length) {
    res.node = yamlScalar('');
    return res;
  }
  let out = '';
  const q = s.charAt(i);
  if (q === '"' || q === "'") {
    i++;
    while (i < s.length) {
      const c = s.charAt(i);
      if (q === '"' && c === '\\' && i + 1 < s.length) {
        out += unescapeChar(s.charAt(i + 1));
        i += 2;
        continue;
      }
      if (c === q) {
        i++;
        break;
      }
      out += c;
      i++;
    }
  } else {
    while (i < s.length) {
      const c = s.charAt(i);
      if (c === ',' || c === '}' || c === ']') {
        break;
      }
      if (isKey && c === ':') {
        break;
      }
      out += c;
      i++;
    }
  }
  res.node = yamlScalar(out.trim());
  res.pos = i;
  return res;
}

function parseFlow(text: string): YamlNode {
  return parseFlowNode(text, 0).node;
}

// ------------------------------------------------------------------ 预处理

function blockStyleOf(content: string): string {
  let rest = content;
  if (isSeqEntry(content)) {
    rest = content.length > 1 ? content.substring(2).trim() : '';
  }
  const ci = findKeyColon(rest);
  if (ci >= 0) {
    rest = rest.substring(ci + 1).trim();
  }
  if (rest === '|' || rest === '|-' || rest === '|+' || rest === '>' || rest === '>-' || rest === '>+') {
    return rest;
  }
  return '';
}

/**
 * 逐行预处理:剥注释(块标量体内不剥)、标记序列行与块体、只取第一份文档。
 * 块体靠 contiguous 的 literal 标记识别,解析时整段消费。
 */
function preprocess(rawLines: Array<string>): Array<YLine> {
  const out: Array<YLine> = [];
  let blockIndent = -1;
  let started = false;
  for (let i = 0; i < rawLines.length; i++) {
    const raw = rawLines[i].replace(/\r+$/, '');
    const plain = raw.trim();
    if (blockIndent < 0) {
      if (plain === '---' || plain.startsWith('--- ')) {
        if (started) {
          break;
        }
        continue;
      }
      if (plain === '...') {
        break;
      }
    }
    const stripped = stripComment(raw);
    const content = stripped.trim();
    if (content.length === 0) {
      continue;
    }
    const indent = indentOf(stripped);
    if (blockIndent >= 0 && indent > blockIndent) {
      const l = new YLine();
      l.indent = indent;
      l.text = plain;
      l.literal = true;
      out.push(l);
      continue;
    }
    blockIndent = -1;
    const l = new YLine();
    l.indent = indent;
    l.isSeq = isSeqEntry(content);
    l.text = content;
    out.push(l);
    started = true;
    if (blockStyleOf(content).length > 0) {
      blockIndent = indent;
    }
  }
  return out;
}

// ------------------------------------------------------------------ 解析器

class YParser {
  private lines: Array<YLine> = [];
  private anchors: Array<YamlAnchor> = [];

  constructor(lines: Array<YLine>) {
    this.lines = lines;
  }

  parseDocument(): YamlNode {
    if (this.lines.length === 0) {
      return new YamlNode();
    }
    return this.parseNode(0, this.lines[0].indent).node;
  }

  private isSeqAt(i: number): boolean {
    return this.lines[i].isSeq;
  }

  private literalAt(i: number): boolean {
    return this.lines[i].literal;
  }

  private parseNode(i: number, indent: number): PRes {
    if (i >= this.lines.length) {
      const r = new PRes();
      r.next = i;
      return r;
    }
    if (this.lines[i].isSeq) {
      return this.parseSeq(i, indent);
    }
    return this.parseMap(i, indent);
  }

  private parseSeq(i: number, indent: number): PRes {
    const seq = new YamlNode();
    seq.kind = KIND_SEQ;
    while (i < this.lines.length) {
      if (!this.isSeqAt(i) || this.lines[i].indent !== indent) {
        break;
      }
      const content = this.lines[i].text;
      const rest = content === '-' ? '' : content.substring(2).trim();
      i++;
      let child: YamlNode;
      if (rest.length === 0) {
        if (i < this.lines.length && !this.literalAt(i) && this.lines[i].indent > indent) {
          const r = this.parseNode(i, this.lines[i].indent);
          child = r.node;
          i = r.next;
        } else {
          child = new YamlNode();
        }
      } else if (findKeyColon(rest) > 0) {
        // "- name: x" 的首个键内联在序列标记之后,后续同缩进的行属于同一个映射。
        // 这里必须同时消费首键与后续行,否则会漏掉 type/server/port 等同级键。
        const r = this.parseInlineItem(rest, i, indent);
        child = r.node;
        i = r.next;
      } else {
        const r = this.parseValue(rest, i, indent);
        child = r.node;
        i = r.next;
      }
      seq.items.push(child);
    }
    const res = new PRes();
    res.node = seq;
    res.next = i;
    return res;
  }

  private parseMap(i: number, indent: number): PRes {
    const map = new YamlNode();
    map.kind = KIND_MAP;
    while (i < this.lines.length) {
      if (this.literalAt(i)) {
        break;
      }
      const ind = this.lines[i].indent;
      if (ind !== indent) {
        break;
      }
      if (this.isSeqAt(i)) {
        break;
      }
      const text = this.lines[i].text;
      if (text.length === 0) {
        i++;
        continue;
      }
      if (text === '---' || text === '...') {
        break;
      }
      const ci = findKeyColon(text);
      if (ci <= 0) {
        i++;
        continue;
      }
      const key = unquote(text.substring(0, ci).trim());
      const rest = text.substring(ci + 1).trim();
      i++;
      let value: YamlNode;
      if (rest.length === 0) {
        if (i < this.lines.length && !this.literalAt(i) && this.lines[i].indent > indent) {
          const r = this.parseNode(i, this.lines[i].indent);
          value = r.node;
          // 必须把 i 推进到 r.next。只更新 next 的话,i 仍停在嵌套块的第一行,
          // 下一轮循环会因缩进不匹配而 break,整个映射提前结束 ——
          // 表现为"带 ws-opts/grpc-opts 的节点会吞掉它后面的所有节点",
          // 整份 Clash 订阅只导入第一个节点。
          i = r.next;
        } else if (i < this.lines.length && !this.literalAt(i)
          && this.lines[i].indent === indent && this.isSeqAt(i)) {
          const r = this.parseSeq(i, indent);
          value = r.node;
          i = r.next;
        } else {
          value = new YamlNode();
        }
      } else {
        const r = this.parseValue(rest, i, indent);
        value = r.node;
        i = r.next;
      }
      if (key === '<<') {
        if (value.kind === KIND_MAP) {
          map.mergeFrom(value);
        } else if (value.kind === KIND_SEQ) {
          for (const item of value.items) {
            map.mergeFrom(item);
          }
        }
      } else {
        map.put(key, value);
      }
    }
    const res = new PRes();
    res.node = map;
    res.next = i;
    return res;
  }

  /**
   * 解析一个"值"。text 是冒号右侧或 "- " 之后的文本。
   * next 返回值之后的行号:流式集合与标量不额外消费行。
   */
  private parseValue(text: string, i: number, indent: number): PRes {
    const res = new PRes();
    let s = text;
    let anchorName = '';
    if (s.charAt(0) === '&') {
      const sp = s.indexOf(' ');
      if (sp < 0) {
        anchorName = s.substring(1);
        s = '';
      } else {
        anchorName = s.substring(1, sp);
        s = s.substring(sp + 1).trim();
      }
    }
    let node: YamlNode;
    let next = i;
    if (s.charAt(0) === '*') {
      node = this.lookupAlias(s.substring(1).trim());
    } else if (s.length === 0) {
      if (i < this.lines.length && !this.literalAt(i) && this.lines[i].indent > indent) {
        const r = this.parseNode(i, this.lines[i].indent);
        node = r.node;
        next = r.next;
      } else {
        node = new YamlNode();
      }
    } else if (s.charAt(0) === '|' || s.charAt(0) === '>') {
      const b = this.collectBlockBody(i, s);
      node = yamlScalar(b.node.scalar);
      next = b.next;
    } else if (s.charAt(0) === '{' || s.charAt(0) === '[') {
      node = parseFlow(s);
    } else {
      // 注意:这里刻意不处理"含 ': ' 的标量"。映射只由 parseMap / parseInlineItem
      // 负责,否则 `name: HK: 01` 这类值会被误当成一个嵌套映射,节点名直接变空。
      node = yamlScalar(unquote(s));
    }
    if (anchorName.length > 0) {
      this.setAnchor(anchorName, node);
    }
    res.node = node;
    res.next = next;
    return res;
  }

  /**
   * 序列项内联首个键:"- name: x"。
   * 首键单独解析成"种子",随后把同缩进的后续行接上 —— 两者都必须消费。
   * 早期版本用"临时覆盖某一行"的方式实现,结果把被覆盖的那条真实行
   * (通常是 `- name:` 之后的第一条同级键,也就是 type/server/port)吃掉了,
   * 整份 Clash 订阅会导入 0 个节点。
   * 这样实现是 O(1) 的,不需要往 lines 里插行(插行在几千节点的订阅上是 O(n^2))。
   */
  private parseInlineItem(first: string, i: number, seqIndent: number): PRes {
    const res = new PRes();
    const ci = findKeyColon(first);
    if (ci <= 0) {
      const v = this.parseValue(first, i, seqIndent);
      res.node = v.node;
      res.next = v.next;
      return res;
    }
    let childIndent = seqIndent + 2;
    if (i < this.lines.length && !this.literalAt(i) && this.lines[i].indent > seqIndent) {
      childIndent = this.lines[i].indent;
    }
    const map = new YamlNode();
    map.kind = KIND_MAP;
    const key = unquote(first.substring(0, ci).trim());
    const rest = first.substring(ci + 1).trim();
    let next = i;
    let value: YamlNode;
    if (rest.length === 0) {
      if (i < this.lines.length && !this.literalAt(i) && this.lines[i].indent > childIndent) {
        const r = this.parseNode(i, this.lines[i].indent);
        value = r.node;
        next = r.next;
      } else {
        value = new YamlNode();
      }
    } else {
      const r = this.parseValue(rest, i, childIndent);
      value = r.node;
      next = r.next;
    }
    // 合并键(<<)必须走 mergeFrom,不能当普通键 put 进去 ——
    // "- <<: *base" 这种把合并键写在序列项首位的写法并不罕见。
    if (key === '<<') {
      if (value.kind === KIND_MAP) {
        map.mergeFrom(value);
      } else if (value.kind === KIND_SEQ) {
        for (const item of value.items) {
          map.mergeFrom(item);
        }
      }
    } else {
      map.put(key, value);
    }
    // 续上后续同缩进的键
    if (next < this.lines.length && !this.literalAt(next)
      && !this.isSeqAt(next) && this.lines[next].indent === childIndent) {
      const cont = this.parseMap(next, childIndent);
      for (const e of cont.node.entries) {
        if (e.key === '<<') {
          if (e.value.kind === KIND_MAP) {
            map.mergeFrom(e.value);
          } else if (e.value.kind === KIND_SEQ) {
            for (const item of e.value.items) {
              map.mergeFrom(item);
            }
          }
        } else {
          map.put(e.key, e.value);
        }
      }
      next = cont.next;
    }
    res.node = map;
    res.next = next;
    return res;
  }

  private collectBlockBody(i: number, style: string): PRes {
    const parts: Array<string> = [];
    let j = i;
    while (j < this.lines.length && this.lines[j].literal) {
      parts.push(this.lines[j].text);
      j++;
    }
    const text = style.charAt(0) === '>' ? parts.join(' ') : parts.join('\n');
    const res = new PRes();
    res.node = yamlScalar(text.replace(/\n+$/, ''));
    res.next = j;
    return res;
  }

  private setAnchor(name: string, node: YamlNode): void {
    for (const a of this.anchors) {
      if (a.name === name) {
        a.node = node;
        return;
      }
    }
    const a = new YamlAnchor();
    a.name = name;
    a.node = node;
    this.anchors.push(a);
  }

  private lookupAlias(name: string): YamlNode {
    for (const a of this.anchors) {
      if (a.name === name) {
        return a.node;
      }
    }
    // 指向未定义锚点:按 YAML 语义当作空节点,不要让整份订阅解析失败
    return new YamlNode();
  }
}

// ------------------------------------------------------------------ 对外 API

/** 解析整份 YAML 文档(只取第一份)。顶层通常是一个映射。 */
export function parseYaml(text: string): YamlNode {
  const lines = preprocess(text.split(/\r?\n/));
  return new YParser(lines).parseDocument();
}

/**
 * 该键是否出现在任何一行的行首(用于区分 proxies / proxy-providers 两种 Clash 订阅)。
 * 注意:允许任意缩进,所以嵌套的 `  proxies:` 也会命中 —— 这是刻意的宽松,
 * 误判的后果只是多走一次 Clash 分支并返回 clash_no_proxies_key 之类的可读提示,
 * 比漏判要好。用 [ \t] 而不是 \s:后者能跨行匹配,会让 base64 正文里偶然出现的
 * "proxies:" 被误判成 Clash YAML。
 */
export function hasTopLevelKey(text: string, key: string): boolean {
  const re = new RegExp('^[ \\t]*' + key + '[ \\t]*:', 'm');
  return re.test(text);
}
