import { Profile } from '../model/Profile';

/**
 * 订阅「更新后处理」纯模型 —— 对齐安卓 GroupManager.onUpdateSuccess 之后的
 * 自动测试 / 删除无效 / 按延迟排序三步(逐订阅开关,存 SubInfo)。
 *
 * 这里只做无 I/O 的数组运算,便于主机测试直接跑生产代码;
 * 真正的测速由 LatencyTester.urlTestProfiles 完成,结果通过 SubTestOutcome 传进来。
 */

/** 节点状态:0 = 未测,1 = 可用,>=2 = 失败(TestError)。 */
export const SUB_STATUS_OK: number = 1;

export class SubTestOutcome {
  id: string = '';
  status: number = 0;
  ping: number = 0;
  error: string = '';
}

/** 把一次测速的结果写回节点(只动被测定过的节点)。返回实际更新条数。 */
export function applyOutcomes(nodes: Array<Profile>, outcomes: Map<string, SubTestOutcome>): number {
  let changed = 0;
  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i];
    const r = outcomes.get(node.id);
    if (r === undefined) {
      continue;
    }
    node.status = r.status;
    node.ping = r.ping;
    node.error = r.error;
    node.latencyMs = r.status === SUB_STATUS_OK ? r.ping : -1;
    node.latencyTestedAt = Date.now();
    changed++;
  }
  return changed;
}

/** 测速失败(status >= 2)的节点:只有真的测过才删,未测(0)不动。 */
export function invalidNodes(nodes: Array<Profile>): Array<Profile> {
  return nodes.filter((p: Profile) => p.status >= 2);
}

/** 稳定排序:可用按延迟升序,失败/未测按原顺序排在后面。 */
export function sortByLatency(nodes: Array<Profile>): Array<Profile> {
  const ok: Array<Profile> = [];
  const rest: Array<Profile> = [];
  for (let i = 0; i < nodes.length; i++) {
    if (nodes[i].status === SUB_STATUS_OK) {
      ok.push(nodes[i]);
    } else {
      rest.push(nodes[i]);
    }
  }
  ok.sort((a: Profile, b: Profile) => {
    const la = a.latencyMs > 0 ? a.latencyMs : a.ping;
    const lb = b.latencyMs > 0 ? b.latencyMs : b.ping;
    if (la === lb) {
      return 0; // Array.prototype.sort 稳定:同延迟保持原顺序
    }
    return la < lb ? -1 : 1;
  });
  return ok.concat(rest);
}

/**
 * 把某个订阅更新后的节点数组放回全局列表的**原位置**(不改变其他订阅/手动分组的相对顺序)。
 * 返回新数组(调用方负责落盘)。
 */
export function spliceSubscription(all: Array<Profile>, url: string, next: Array<Profile>): Array<Profile> {
  const out: Array<Profile> = [];
  let cursor = 0;
  for (let i = 0; i < all.length; i++) {
    if (all[i].subUrl === url) {
      if (cursor < next.length) {
        out.push(next[cursor]);
        cursor++;
      }
      continue;
    }
    out.push(all[i]);
  }
  // 订阅新增的节点(理论上不会,兜底)追加到末尾,绝不静默丢节点。
  while (cursor < next.length) {
    out.push(next[cursor]);
    cursor++;
  }
  return out;
}
