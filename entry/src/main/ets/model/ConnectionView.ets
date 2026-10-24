/**
 * 连接列表与「为什么走这条线路」视图模型 —— REDESIGN-PLAN-2026-10-23.md §10.1/§10.2(P5/W19)。
 *
 * 只用**真实连接证据**(内核 clash API /connections 的原始字段):
 *  - 目标:metadata.host 为空时显示 destinationIP;两者都空显示「未提供」;
 *  - 规则:内核 `rule` 表达式原样展示;`rulePayload` 为空就显示「未提供」,**不伪造结构化 payload**
 *    (当前内核 rule 文本无法与本地编译 manifest 建立可证明的唯一对应,按方案 §10.2 展示原文,
 *    不错误定位编辑器;唯一规则 ID 属 K3 可选内核元数据扩展);
 *  - 策略组链:chains 逆序(入口在左);最终节点 = chains[0];
 *  - 运行 revision 与采集时间随证据展示;取不到的字段如实标「未知/未提供」。
 *
 * 纯函数/纯数据:不做 I/O;主机测试见 tests/connection-view.cjs。
 */

/** 链路分类 token(仅按实际采集到的 chains/rule 判定,不推测)。 */
export const CHAIN_DIRECT: string = 'direct';
export const CHAIN_PROXY: string = 'proxy';
export const CHAIN_REJECT: string = 'reject';
export const CHAIN_UNKNOWN: string = 'unknown';

/** 单条连接(页面只渲染它)。 */
export class ClashConnItem {
  id: string = '';
  /** 目标(域名 > IP > 未提供) */
  host: string = '';
  /** 原始域名(空 = 未提供) */
  rawHost: string = '';
  /** 原始目标 IP(空 = 未提供) */
  destinationIp: string = '';
  network: string = '';
  /** 入口 → ... → 最终节点(chains 逆序) */
  chains: Array<string> = [];
  /** 最终节点(chains[0];空 = 未提供) */
  finalNode: string = '';
  /** 内核规则表达式原文(如 geoip(cn));空 = 未提供 */
  rule: string = '';
  /** 内核 rulePayload 原文;空 = 未提供(不伪造) */
  rulePayload: string = '';
  up: number = 0;
  down: number = 0;
  /** 开始时间(unix 毫秒;0 = 未提供) */
  start: number = 0;
  /** 进程/应用归属(内核不给就不填,不显示推测应用名) */
  process: string = '';
  /** CHAIN_* */
  chainClass: string = CHAIN_UNKNOWN;
}

/**
 * 「为什么走这条线路」证据视图(§10.2)。P6/W21 起**空字段保留空串**,
 * 「未提供/未知」由页面用资源键兜底(模型不再产出用户语言);不伪造是本模型的底线。
 */
export class RouteEvidence {
  /** 目标(域名 > IP;空 = 页面显示 connection_not_provided) */
  target: string = '';
  /** 网络(空 = 未提供) */
  network: string = '';
  /** 内核规则表达式原文(空 = 未提供) */
  ruleText: string = '';
  /** rulePayload 是否由内核提供(否 = 显示「未提供」,不伪造) */
  rulePayloadProvided: boolean = false;
  rulePayloadText: string = '';
  /** 策略组链(入口在左;空 = 未提供) */
  chainList: Array<string> = [];
  /** 最终节点(空 = 未提供) */
  finalNode: string = '';
  /** 运行 revision(appliedRevision;0 = 未知) */
  runningRevision: number = 0;
  /** 采集时间(unix 毫秒) */
  collectedAtMs: number = 0;
  /** 本地规则名:仅当与编译 manifest 唯一对应才有值;当前内核无法证明唯一对应 → 恒空(K3 扩展) */
  localRuleName: string = '';
}

function str(v: Object | undefined): string {
  if (v === undefined || v === null) {
    return '';
  }
  const s = `${v}`;
  return s === 'undefined' || s === 'null' ? '' : s;
}

/** 由内核 /connections 原始 JSON 解析连接列表(坏输入返回空数组,不抛)。 */
export function parseConnections(raw: string): Array<ClashConnItem> {
  const out: Array<ClashConnItem> = [];
  let parsed: Record<string, Object> | null = null;
  try {
    const value: Object = JSON.parse(raw);
    if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
      parsed = value as Record<string, Object>;
    }
  } catch (e) {
    return out;
  }
  if (parsed === null) {
    return out;
  }
  const conns = parsed['connections'];
  if (!Array.isArray(conns)) {
    return out;
  }
  const arr = conns as Array<Object>;
  for (let i = 0; i < arr.length; i++) {
    const c = arr[i] as Record<string, Object>;
    const meta = c['metadata'] as Record<string, Object> | undefined;
    const metaRec: Record<string, Object> = meta === undefined || meta === null ? {} : meta;
    const chainsRaw = c['chains'];
    const chains: Array<string> = [];
    if (Array.isArray(chainsRaw)) {
      const chainArr = chainsRaw as Array<Object>;
      for (let j = 0; j < chainArr.length; j++) {
        const link = str(chainArr[j]);
        if (link.length > 0) {
          chains.push(link);
        }
      }
    }
    const item = new ClashConnItem();
    item.id = str(c['id']);
    item.rawHost = str(metaRec['host']);
    item.destinationIp = str(metaRec['destinationIP']);
    item.host = item.rawHost.length > 0 ? item.rawHost : item.destinationIp;
    item.network = str(metaRec['network']);
    item.chains = chains.slice().reverse();
    item.finalNode = chains.length > 0 ? chains[0] : '';
    item.rule = str(c['rule']);
    item.rulePayload = str(c['rulePayload']);
    item.up = Number(c['upload'] ?? 0);
    item.down = Number(c['download'] ?? 0);
    const startRaw = str(c['start']);
    const startMs = Date.parse(startRaw);
    item.start = Number.isFinite(startMs) ? startMs : 0;
    item.process = str(metaRec['process']);
    item.chainClass = classifyChain(item.rule, chains);
    if (item.id.length > 0) {
      out.push(item);
    }
  }
  return out;
}

/**
 * 链路分类:仅按实际采集到的证据 ——
 *  - chains 含 direct 或 rule 含 direct → direct;
 *  - chains/rule 含 block/reject → reject;
 *  - chains 有真实代理节点 → proxy;
 *  - 其余(空 chains、规则缺失)→ unknown,不猜测。
 */
export function classifyChain(rule: string, chains: Array<string>): string {
  const ruleLower = rule.toLowerCase();
  const hasDirectChain = chains.indexOf('direct') >= 0;
  const hasBlock = ruleLower.indexOf('block') >= 0 || ruleLower.indexOf('reject') >= 0 ||
    chains.indexOf('block') >= 0;
  if (hasBlock) {
    return CHAIN_REJECT;
  }
  if (hasDirectChain || ruleLower.indexOf('direct') >= 0) {
    return CHAIN_DIRECT;
  }
  const namedChains: Array<string> = [];
  for (let i = 0; i < chains.length; i++) {
    if (chains[i].length > 0) {
      namedChains.push(chains[i]);
    }
  }
  if (namedChains.length > 0) {
    return CHAIN_PROXY;
  }
  return CHAIN_UNKNOWN;
}

/** 过滤:mode = '' | direct | proxy | reject | unknown(仅实际存在的分类;查询匹配 host/finalNode/rule)。 */
export function filterConnections(items: Array<ClashConnItem>, mode: string,
  query: string): Array<ClashConnItem> {
  const q = query.trim().toLowerCase();
  const out: Array<ClashConnItem> = [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (mode.length > 0 && item.chainClass !== mode) {
      continue;
    }
    if (q.length > 0 && item.host.toLowerCase().indexOf(q) < 0 &&
      item.finalNode.toLowerCase().indexOf(q) < 0 &&
      item.rule.toLowerCase().indexOf(q) < 0) {
      continue;
    }
    out.push(item);
  }
  return out;
}

/**
 * 构建单条连接的「为什么走这条线路」证据视图。
 * @param runningRevision 运行 revision(vpnAppliedRevision;0/负数 → 0=未知)
 * @param collectedAtMs 本批连接的采集时间
 */
export function buildRouteEvidence(item: ClashConnItem, runningRevision: number,
  collectedAtMs: number): RouteEvidence {
  const evidence = new RouteEvidence();
  evidence.target = item.host;
  evidence.network = item.network;
  evidence.ruleText = item.rule;
  evidence.rulePayloadProvided = item.rulePayload.length > 0;
  evidence.rulePayloadText = item.rulePayload;
  evidence.chainList = item.chains.slice();
  evidence.finalNode = item.finalNode;
  evidence.runningRevision = runningRevision > 0 ? runningRevision : 0;
  evidence.collectedAtMs = collectedAtMs;
  /* localRuleName 恒空:内核 rule 文本与本地 manifest 的唯一对应当前无法证明(K3),不伪造 */
  return evidence;
}

/** 证据摘要一行(详情弹窗标题下方的速览);空字段跳过,不拼占位。 */
export function evidenceSummaryLine(evidence: RouteEvidence): string {
  const parts: Array<string> = [];
  if (evidence.target.length > 0) {
    parts.push(evidence.target);
  }
  if (evidence.ruleText.length > 0) {
    parts.push(evidence.ruleText);
  }
  if (evidence.chainList.length > 0) {
    parts.push(evidence.chainList.join(' → '));
  }
  return parts.join(' · ');
}
