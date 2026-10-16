import { Profile } from '../model/Profile';
import { parseYaml, YamlNode } from './ClashYaml';
import { parseClashProxies, fetchTextUrl, ClashParseResult } from './Subscription';
import { parseShareText } from './LinkParser';

/**
 * Clash `proxy-providers`(远程节点集)解析。
 *
 * 背景:不少机场的 Clash 订阅是「provider 模式」——顶层只有 proxy-providers,
 * 真正的节点放在 provider 的 URL 里(每个 provider 自身又是一份 Clash YAML 或
 * base64 分享链接)。此前的实现只把这种订阅判为 clash_provider_only 然后报
 * 「本客户端暂不支持」,用户看到的就是「导入订阅解析不到节点」;而同一份 provider
 * 内容 v2rayN / Clash.Meta / Hiddify 都能直接导入。这是最主要的解析缺口。
 *
 * provider 形如:
 *   proxy-providers:
 *     airport:
 *       type: http
 *       url: https://example.com/clash/provider.yaml
 *       path: ./proxy-providers/airport.yaml
 *       interval: 3600
 *       override: { udp: true }      # 覆盖字段,本实现暂不套用
 *
 * 只跟随 type: http 的 provider(type: file 指向本地文件,沙箱内不存在,跳过)。
 * 节点名与内联 proxies 同规则:provider 内条目自带 name,直接采用;缺失则补
 * `<provider名>-<序号>`;跨 provider 重名再加 provider 后缀,保证列表可分辨。
 *
 * 单独成模块的原因:Subscription.ets 依赖本模块的 parseClashProxies,而
 * LinkParser.ets 又依赖 Subscription.ets;若把本函数放回 Subscription.ets,
 * 就会形成 Subscription -> LinkParser -> Subscription 的循环导入
 * (ArkTS 打包下循环依赖的初始化顺序不可靠)。独立模块让依赖保持单向:
 *   ClashProviders -> {Subscription, LinkParser, ClashYaml}
 */

function providerStr(node: YamlNode | null, key: string, dflt: string = ''): string {
  if (node === null || !node.isMap()) {
    return dflt;
  }
  const v = node.get(key);
  if (v === null || !v.isScalar()) {
    return dflt;
  }
  return v.scalar.length > 0 ? v.scalar : dflt;
}

export async function parseClashProxiesWithProviders(yaml: string, allowInsecure: boolean,
  userAgent: string): Promise<ClashParseResult> {
  const result: ClashParseResult = parseClashProxies(yaml);
  // 只有「provider-only」形态才需要跟进远程节点集。内联 proxies 已有节点时
  // 保持原行为(不额外拉取,避免多余的网络请求与导入耗时)。
  if (result.note !== 'clash_provider_only') {
    return result;
  }
  let root: YamlNode;
  try {
    root = parseYaml(yaml);
  } catch (e) {
    return result;
  }
  const providers = root.get('proxy-providers');
  if (providers === null || !providers.isMap()) {
    return result;
  }
  let fetched = 0;
  let failed = 0;
  const takenNames: Array<string> = [];
  for (const entry of providers.entries) {
    const providerName = entry.key;
    const providerNode = entry.value;
    if (providerNode === null || !providerNode.isMap()) {
      continue;
    }
    const ptype = providerStr(providerNode, 'type').toLowerCase();
    if (ptype.length > 0 && ptype !== 'http') {
      // file/embed 类型指向本地路径,沙箱里不存在,跳过。
      continue;
    }
    let url = providerStr(providerNode, 'url');
    if (url.length === 0) {
      url = providerStr(providerNode, 'subscription');
    }
    if (url.length === 0) {
      continue;
    }
    let body = '';
    try {
      body = await fetchTextUrl(url, allowInsecure, userAgent);
    } catch (e) {
      failed++;
      continue;
    }
    fetched++;
    // provider 内容既可能是 Clash YAML,也可能是 base64 分享链接列表。
    let sub = parseClashProxies(body);
    if (sub.profiles.length === 0) {
      sub = { profiles: parseShareText(body), skipped: 0, skippedNames: [], note: '' };
    }
    let added = 0;
    for (const p of sub.profiles) {
      if (p.name.trim().length === 0) {
        p.name = `${providerName}-${added + 1}`;
      }
      if (takenNames.indexOf(p.name) >= 0) {
        p.name = `${p.name}-${providerName}`;
      }
      takenNames.push(p.name);
      result.profiles.push(p as Profile);
      added++;
    }
    result.skipped += sub.skipped;
    for (const nm of sub.skippedNames) {
      if (result.skippedNames.length < 20) {
        result.skippedNames.push(nm);
      }
    }
  }
  if (result.profiles.length > 0) {
    // provider 节点已入库,清掉「不支持该格式」的提示。
    result.note = '';
    return result;
  }
  // 仍然为空:区分「下载失败」与「provider 内容为空」,让用户知道该查网络还是机场。
  if (fetched === 0 && failed > 0) {
    result.note = 'clash_provider_all_failed';
  } else if (failed > 0) {
    result.note = 'clash_provider_fetch_failed';
  } else {
    result.note = 'clash_provider_empty';
  }
  return result;
}

/**
 * 解析 Clash 的 `proxy-groups`(策略组),映射到本应用的 ProfileGroup。
 *
 * 背景:完整 Clash 配置的节点在 proxies 里,但分组结构在 proxy-groups。
 * 只取 proxies 会让订阅自带的分组全丢,用户只能手工重组 —— 而同一份订阅
 * 在 Clash/NekoBox Android 上是带分组的。model/ProfileGroup 的 isSelector /
 * autoSelect 正好对应 Clash 的 select / url-test 组。
 *
 * 只导入「有实际成员」的组:成员名是 DIRECT/REJECT/全局代理等特殊关键字时跳过
 * (本应用没有对应的组类型),否则会造出空组。组内成员名对应节点名,调用方
 * 通过 matchGroupMembers 用节点 id 回填成员。
 */
export interface ClashGroupDef {
  name: string;
  type: string;
  members: Array<string>;
}

export function parseClashGroups(yaml: string): Array<ClashGroupDef> {
  const out: Array<ClashGroupDef> = [];
  let root: YamlNode;
  try {
    root = parseYaml(yaml);
  } catch (e) {
    return out;
  }
  const groups = root.get('proxy-groups');
  if (groups === null || !groups.isSeq()) {
    return out;
  }
  const specials: Array<string> = [
    'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'GLOBAL'
  ];
  for (const g of groups.items) {
    if (g === null || !g.isMap()) {
      continue;
    }
    const name = providerStr(g, 'name').trim();
    if (name.length === 0) {
      continue;
    }
    const type = providerStr(g, 'type').trim().toLowerCase();
    // 只支持能映射到 ProfileGroup 的两类组;falload/relay 等语义不同,跳过。
    if (type !== 'select' && type !== 'url-test' && type !== 'urltest' && type !== 'selector') {
      continue;
    }
    const membersNode = g.get('proxies');
    if (membersNode === null || !membersNode.isSeq()) {
      continue;
    }
    const members: Array<string> = [];
    let hasReal = false;
    for (const m of membersNode.items) {
      // 序列里的成员就是裸标量节点(不是 map),必须直接读 .scalar。
      // 早先用 providerStr(m, '') 会去 m.get('') 取键,永远拿不到 → 所有成员被丢弃。
      if (!m.isScalar()) {
        continue;
      }
      const mn = m.scalar.trim();
      if (mn.length === 0) {
        continue;
      }
      const upper = mn.toUpperCase();
      if (specials.indexOf(upper) >= 0) {
        continue; // 特殊关键字不是节点,跳过
      }
      // 内置 provider 引用(#机场)也不是节点名
      if (mn.startsWith('#') || mn.startsWith('*')) {
        continue;
      }
      hasReal = true;
      members.push(mn);
    }
    if (!hasReal || members.length === 0) {
      continue;
    }
    out.push({ name, type, members });
  }
  return out;
}
