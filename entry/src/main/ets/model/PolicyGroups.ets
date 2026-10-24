import { Profile, ProfileGroup } from './Profile';
// 仅类型依赖(core→model 是运行时方向；这里用 import type 保持 model 纯、测试不需要 http 桩)
import type { ClashProxiesResult } from '../core/ClashApi';

/**
 * 策略组纯模型 —— P4/W15(方案 §9.1 组管理 / §9.2 手动选择与热切换 /
 * §9.3 自动优选 / §9.4 校验)。无 I/O，主机测试 tests/policy-groups.cjs。
 *
 * ---- 组实体与编译口径事实(2026-10-24 逐行核对) ----
 * 1) `ProfileGroup`(model/Profile.ets:153-171)：id/name/sortOrder/isSelector/autoSelect/
 *    frontProxy/landingProxy/fromSubscription。**没有成员列表** —— 成员是
 *    `Profile.groupId === group.id` 的节点(Profile.ets:125-126)，所以本模型里
 *    需要成员的函数都带 `profiles` 参数（可选；不给就不猜）。
 * 2) 内核口径(ConfigBuilder.ets:850-880)：只有"当前选中组"会被包成一个 wrapper，
 *    tag 恒为 `'proxy'`；isSelector → selector(+default)，autoSelect → urltest
 *    (url=testUrl 兜底 http://www.gstatic.com/generate_204、interval='10m'、
 *    idle_timeout='30m'、tolerance=50、interrupt_exist_connections=false)。
 *    两者互斥且 autoSelect 优先(:849-861)。
 * 3) 节点出站 tag 规则：`profileRootTag(id) = profile-<encodeURIComponent(id)>`
 *    (ConfigBuilder.ets:795-797)。本模型用同一公式生成成员 tag，策略组自身用
 *    `group-<encodeURIComponent(id)>`(同前缀约定，避免与节点 tag 撞名)；
 *    **tag 全部由稳定 id 派生，绝不用显示名**(§9.2-2)。
 * 4) clash API 组字段证据见 core/ClashApi.ets 文件头(proxies.go:30-40/78-84)；
 *    组的运行类型是展示名 "Selector"/"URLTest"(constant/proxy.go:115-117)。
 */

export const GROUP_TYPE_SELECTOR: string = 'selector';
export const GROUP_TYPE_URLTEST: string = 'urltest';
/** clash API 展示名(constant/proxy.go:115-117)，用于核对运行图类型 */
export const CLASH_TYPE_SELECTOR: string = 'Selector';
export const CLASH_TYPE_URLTEST: string = 'URLTest';

// reason 词表(hotSwitchDecision / verifyNow / actualMemberView)
export const GROUP_REASON_PROXIES_FAILED: string = 'proxies_failed';
export const GROUP_REASON_GROUP_MISSING: string = 'group_missing';
export const GROUP_REASON_NOT_SELECTOR: string = 'not_selector';
export const GROUP_REASON_TYPE_MISMATCH: string = 'type_mismatch';
export const GROUP_REASON_MEMBER_MISSING: string = 'member_missing';
export const GROUP_REASON_GET_FAILED: string = 'get_failed';
export const GROUP_REASON_NOW_MISMATCH: string = 'now_mismatch';
export const MEMBER_UNKNOWN_LABEL: string = '实际节点未知';

// ---------------------------------------------------------------------------
// tag 映射(§9.2-2：稳定 ID→tag，显示名不能当标识)
// ---------------------------------------------------------------------------

/** 节点出站 tag(与 ConfigBuilder.profileRootTag 完全一致，ConfigBuilder.ets:795-797)。 */
export function profileTagFor(id: string): string {
  return `profile-${encodeURIComponent(id)}`;
}

/** 策略组稳定 tag(同前缀约定；id 是组实体主键，改名不换 tag)。 */
export function groupTagFor(id: string): string {
  return `group-${encodeURIComponent(id)}`;
}

export class GroupTagMap {
  byId: Map<string, string> = new Map<string, string>();
  byTag: Map<string, string> = new Map<string, string>();
  /** 重复的 tag(如同一组 id 出现两次)；只列 tag 字符串，由调用方定位实体 */
  duplicates: Array<string> = [];
}

export function buildTagMap(groups: Array<ProfileGroup>): GroupTagMap {
  const out = new GroupTagMap();
  for (let i = 0; i < groups.length; i++) {
    const group = groups[i];
    if (group.id.length === 0) {
      continue;
    }
    const tag = groupTagFor(group.id);
    if (out.byId.has(group.id)) {
      // 同一 id 出现两次 → tag 必然重复，如实列出(数据问题，不静默吞)
      if (out.duplicates.indexOf(tag) < 0) {
        out.duplicates.push(tag);
      }
      continue;
    }
    out.byId.set(group.id, tag);
    out.byTag.set(tag, group.id);
  }
  return out;
}

// ---------------------------------------------------------------------------
// §9.4 校验：空组 / 引用缺失 / 组引用组成环(含自引用) / 重复 tag / 失效前置落地
// ---------------------------------------------------------------------------

export class MissingRef {
  groupId: string = '';
  /** 'frontProxy' | 'landingProxy' */
  field: string = '';
  ref: string = '';
}

export class GroupValidation {
  /** 没有任何成员的组 id(仅在提供 profiles 时判定；不给成员信息就不猜) */
  emptyGroups: Array<string> = [];
  /** 引用缺失(frontProxy/landingProxy 指向不存在的 id) */
  missingRefs: Array<MissingRef> = [];
  /** 组引用组的环(含自引用)，路径首尾相同，如 ['a','b','a'] */
  cycles: Array<Array<string>> = [];
  duplicateTags: Array<string> = [];
  /** 前置/落地代理失效的组 id(自引用/缺失/成环任一) */
  invalidPredecessors: Array<string> = [];
}

function pushUnique(list: Array<string>, value: string): void {
  if (list.indexOf(value) < 0) {
    list.push(value);
  }
}

/** DFS 找组引用环；返回去重后的环路径(首尾相同)。 */
function detectGroupCycles(groups: Array<ProfileGroup>): Array<Array<string>> {
  const edges = new Map<string, Array<string>>();
  const groupIds = new Set<string>();
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i];
    if (g.id.length === 0) {
      continue;
    }
    groupIds.add(g.id);
  }
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i];
    if (g.id.length === 0) {
      continue;
    }
    const refs: Array<string> = [];
    // 自引用也建边：DFS 会把它识别成 ['g','g'] 的环(§9.4 含自引用)
    if (g.frontProxy.length > 0 && groupIds.has(g.frontProxy)) {
      refs.push(g.frontProxy);
    }
    if (g.landingProxy.length > 0 && groupIds.has(g.landingProxy)) {
      refs.push(g.landingProxy);
    }
    edges.set(g.id, refs);
  }
  const color = new Map<string, number>(); // 0=未访问 1=在栈 2=完成
  const stack: Array<string> = [];
  const cycles: Array<Array<string>> = [];
  const seen = new Set<string>();
  const visit = (id: string): void => {
    color.set(id, 1);
    stack.push(id);
    const refs = edges.get(id);
    if (refs !== undefined) {
      for (let i = 0; i < refs.length; i++) {
        const next = refs[i];
        const state = color.get(next);
        if (state === undefined || state === 0) {
          visit(next);
        } else if (state === 1) {
          // 回边：从栈里 next 的位置截出环
          const start = stack.indexOf(next);
          if (start >= 0) {
            const cycle = stack.slice(start);
            cycle.push(next); // 首尾相同
            // 规范化：最小 id 转到开头，便于去重
            let minIdx = 0;
            for (let k = 1; k < cycle.length - 1; k++) {
              if (cycle[k] < cycle[minIdx]) {
                minIdx = k;
              }
            }
            const rotated: Array<string> = [];
            for (let k = minIdx; k < cycle.length - 1; k++) {
              rotated.push(cycle[k]);
            }
            for (let k = 0; k < minIdx; k++) {
              rotated.push(cycle[k]);
            }
            rotated.push(rotated[0]);
            const key = rotated.join('>');
            if (!seen.has(key)) {
              seen.add(key);
              cycles.push(rotated);
            }
          }
        }
      }
    }
    stack.pop();
    color.set(id, 2);
  };
  const ids: Array<string> = [];
  groupIds.forEach((id) => {
    ids.push(id);
  });
  for (let i = 0; i < ids.length; i++) {
    const state = color.get(ids[i]);
    if (state === undefined || state === 0) {
      visit(ids[i]);
    }
  }
  return cycles;
}

export function validateGroups(groups: Array<ProfileGroup>, profileIds: Array<string>,
  profiles: Array<Profile> = []): GroupValidation {
  const out = new GroupValidation();
  const tagMap = buildTagMap(groups);
  out.duplicateTags = tagMap.duplicates;
  const groupIds = new Set<string>();
  for (let i = 0; i < groups.length; i++) {
    if (groups[i].id.length > 0) {
      groupIds.add(groups[i].id);
    }
  }
  // 成员统计(仅当调用方给了 profiles；ProfileGroup 本身没有成员字段)
  if (profiles.length > 0) {
    const memberCount = new Map<string, number>();
    for (let i = 0; i < profiles.length; i++) {
      const gid = profiles[i].groupId;
      if (gid.length === 0) {
        continue;
      }
      const prev = memberCount.get(gid);
      memberCount.set(gid, (prev === undefined ? 0 : prev) + 1);
    }
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      if (g.id.length > 0 && (memberCount.get(g.id) === undefined)) {
        out.emptyGroups.push(g.id);
      }
    }
  }
  // 前置/落地代理引用
  for (let i = 0; i < groups.length; i++) {
    const g = groups[i];
    const fields: Array<string> = ['frontProxy', 'landingProxy'];
    for (let f = 0; f < fields.length; f++) {
      const ref = f === 0 ? g.frontProxy : g.landingProxy;
      if (ref.length === 0) {
        continue;
      }
      if (ref === g.id) {
        // 自引用：组不能把自己当前置/落地(§9.4)
        const missing = new MissingRef();
        missing.groupId = g.id;
        missing.field = fields[f];
        missing.ref = ref;
        out.missingRefs.push(missing);
        pushUnique(out.invalidPredecessors, g.id);
        continue;
      }
      if (groupIds.has(ref)) {
        continue; // 组引用组：合法性由环检测判定
      }
      if (profileIds.indexOf(ref) < 0) {
        const missing = new MissingRef();
        missing.groupId = g.id;
        missing.field = fields[f];
        missing.ref = ref;
        out.missingRefs.push(missing);
        pushUnique(out.invalidPredecessors, g.id);
      }
    }
  }
  out.cycles = detectGroupCycles(groups);
  for (let c = 0; c < out.cycles.length; c++) {
    const cycle = out.cycles[c];
    for (let k = 0; k < cycle.length - 1; k++) {
      pushUnique(out.invalidPredecessors, cycle[k]);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// §9.1 编译(供 ConfigBuilder 消费；成员已解析为出站 tag)
// ---------------------------------------------------------------------------

export class GroupCompileEntry {
  tag: string = '';
  /** 'selector' | 'urltest' */
  type: string = '';
  members: Array<string> = [];
  /** 仅 urltest：探测地址 */
  url: string = '';
  /** 仅 urltest：间隔秒(600=10m；ConfigBuilder 序列化为 duration) */
  interval: number = 0;
  /** 仅 urltest：容差 ms(ConfigBuilder.ets:870 tolerance=50) */
  tolerance: number = 0;
  /** urltest 的 interrupt_exist_connections(ConfigBuilder.ets:871，默认 false=不中断现有连接) */
  interruptExisting: boolean = false;
}

export function autoSelectDefaults(): AutoSelectDefaults {
  const out = new AutoSelectDefaults();
  return out;
}

/** §9.3 默认值(与 ConfigBuilder.ets:863-871 现行生成一致；内核不支持的可选参数由调用方按能力显示)。 */
export class AutoSelectDefaults {
  url: string = 'http://www.gstatic.com/generate_204';
  intervalSec: number = 600;
  toleranceMs: number = 50;
  interruptExisting: boolean = false;
}

/**
 * 组 → 编译条目。仅 isSelector/autoSelect 的组会生成 wrapper(ConfigBuilder.ets:850)；
 * autoSelect 优先(:849-861)。成员取 groupId 匹配的 Profile，tag 用 profileTagFor。
 * selector 条目的 `default` 由调用方按当前选中节点补(ConfigBuilder.ets:877)。
 */
export function compileGroups(groups: Array<ProfileGroup>, tagMap: GroupTagMap,
  profiles: Array<Profile> = [], probeUrl: string = ''): Array<GroupCompileEntry> {
  const out: Array<GroupCompileEntry> = [];
  for (let i = 0; i < groups.length; i++) {
    const group = groups[i];
    const tag = tagMap.byId.get(group.id);
    if (tag === undefined) {
      continue;
    }
    if (!group.isSelector && !group.autoSelect) {
      continue; // 无 wrapper 的普通分组不进内核
    }
    const entry = new GroupCompileEntry();
    entry.tag = tag;
    const members: Array<string> = [];
    for (let p = 0; p < profiles.length; p++) {
      if (profiles[p].groupId === group.id) {
        members.push(profileTagFor(profiles[p].id));
      }
    }
    entry.members = members;
    if (group.autoSelect) {
      entry.type = GROUP_TYPE_URLTEST;
      const defaults = autoSelectDefaults();
      entry.url = probeUrl.trim().length > 0 ? probeUrl.trim() : defaults.url;
      entry.interval = defaults.intervalSec;
      entry.tolerance = defaults.toleranceMs;
      entry.interruptExisting = defaults.interruptExisting;
    } else {
      entry.type = GROUP_TYPE_SELECTOR;
    }
    out.push(entry);
  }
  return out;
}

// ---------------------------------------------------------------------------
// §9.2 热切换决策 / 核对 / 实际成员
// ---------------------------------------------------------------------------

export class HotSwitchDecision {
  canSwitch: boolean = false;
  reason: string = '';
  /** true = 需要重建配置走统一应用流程(§9.2-5)，不能把失败当成无感成功 */
  needsRebuild: boolean = false;
}

/**
 * 热切换前置判定(§9.2-1/5)：
 * - 运行图里必须有该组且类型是 Selector(展示名)；
 * - 目标成员必须在组的 all 列表里；
 * - 调用方声明的组类型与运行图冲突(如模型说是 urltest) → needsRebuild 对账；
 * - 任何失败都 needsRebuild=true，如实说明，不得假装可切。
 */
export function hotSwitchDecision(groupType: string, memberTag: string,
  groupTag: string, proxies: ClashProxiesResult): HotSwitchDecision {
  const out = new HotSwitchDecision();
  if (!proxies.ok) {
    out.reason = GROUP_REASON_PROXIES_FAILED;
    out.needsRebuild = true;
    return out;
  }
  const group = proxies.proxies.get(groupTag);
  if (group === undefined) {
    out.reason = GROUP_REASON_GROUP_MISSING;
    out.needsRebuild = true;
    return out;
  }
  if (group.type !== CLASH_TYPE_SELECTOR) {
    out.reason = GROUP_REASON_NOT_SELECTOR;
    out.needsRebuild = true;
    return out;
  }
  if (groupType.length > 0 && groupType !== GROUP_TYPE_SELECTOR) {
    // 模型与运行图不一致：以"需要重建"对账，不能按任一侧盲切
    out.reason = GROUP_REASON_TYPE_MISMATCH;
    out.needsRebuild = true;
    return out;
  }
  if (group.all.indexOf(memberTag) < 0) {
    out.reason = GROUP_REASON_MEMBER_MISSING;
    out.needsRebuild = true;
    return out;
  }
  out.canSwitch = true;
  out.reason = '';
  return out;
}

/**
 * PUT 成功后的 GET 核对(§9.2-3)：核对 after 的 now；失败不提前打"正在使用"。
 * before 仅留作基线记录，判定只信 after。
 */
export function verifyNow(before: ClashProxiesResult, after: ClashProxiesResult,
  groupTag: string, memberTag: string): VerifyNowResult {
  const out = new VerifyNowResult();
  if (!after.ok) {
    out.reason = GROUP_REASON_GET_FAILED;
    return out;
  }
  const group = after.proxies.get(groupTag);
  if (group === undefined) {
    out.reason = GROUP_REASON_GROUP_MISSING;
    return out;
  }
  if (group.now !== memberTag) {
    out.reason = GROUP_REASON_NOW_MISMATCH;
    return out;
  }
  out.ok = true;
  return out;
}

export class VerifyNowResult {
  ok: boolean = false;
  reason: string = '';
}

export class ActualMemberView {
  tag: string = '';
  /** 'known' | 'unknown'；unknown = 拿不到运行事实，绝不推断 */
  state: string = 'unknown';
  /** known → 组 now 指向的成员 tag；unknown → 固定文案(§9.2 末段) */
  label: string = MEMBER_UNKNOWN_LABEL;
}

/**
 * 组的实际成员视图：GET 失败/组不存在/now 为空 → unknown("实际节点未知")。
 * 绝不用最低历史延迟或历史选择推断(§9.2 末段)。
 */
export function actualMemberView(groupTag: string,
  proxies: ClashProxiesResult): ActualMemberView {
  const out = new ActualMemberView();
  out.tag = groupTag;
  if (!proxies.ok) {
    return out;
  }
  const group = proxies.proxies.get(groupTag);
  if (group === undefined || group.now.length === 0) {
    return out;
  }
  out.state = 'known';
  out.label = group.now;
  return out;
}
