import common from '@ohos.app.ability.common';
import { SnapshotStore } from './SnapshotStore';
import {
  SubscriptionSourceSnapshot, parseSourceSnapshot, sourceSnapshotToJson, urlKeyOf
} from '../model/SubscriptionLayers';

/**
 * 订阅原始层存储 —— REDESIGN-PLAN-2026-10-23.md §11.4(P5/W17)。
 *
 * 每次成功获取写一份不可变快照文件(filesDir/config/subscription-sources/<urlKey>/
 * snapshot-<fetchedAt>.json),编辑器/更新事务绝不原地覆盖;每个订阅保留最近
 * KEEP_PER_SUB 份(当前 + 上一份,支撑「远端删除节点的恢复/转为手动」),更旧 GC。
 *
 * 刻意**不**放进 ConfigSnapshot:配置快照只保留 3 个 revision(KEEP_REVISIONS),
 * 原始层若随配置快照存放会在 GC 中丢历史,违背「原始层永不覆盖」。
 * 原始层体积也大(整份节点),混入会让每次设置提交都携带双份节点数据。
 */

const DIR_NAME = 'subscription-sources';
const SNAP_PREFIX = 'snapshot-';
const SNAP_SUFFIX = '.json';
/** 每订阅保留的原始快照份数(当前 + 上一份可恢复)。 */
const KEEP_PER_SUB = 2;

export class SubscriptionSourceStore {
  private static baseDir: string = '';

  static init(context: common.Context): void {
    SubscriptionSourceStore.baseDir = `${SnapshotStore.configDir(context)}/${DIR_NAME}`;
  }

  static isInitialized(): boolean {
    return SubscriptionSourceStore.baseDir.length > 0;
  }

  static sourcesDirOf(url: string): string {
    return `${SubscriptionSourceStore.baseDir}/${urlKeyOf(url)}`;
  }

  /** 写入一份新原始快照(不可变文件名=fetchedAt),随后 GC 只留最近 KEEP_PER_SUB 份。 */
  static save(snap: SubscriptionSourceSnapshot): void {
    if (!SubscriptionSourceStore.isInitialized() || snap.url.length === 0 ||
      !(snap.fetchedAt > 0)) {
      return;
    }
    const dir = SubscriptionSourceStore.sourcesDirOf(snap.url);
    SnapshotStore.ensureDir(dir);
    const path = `${dir}/${SNAP_PREFIX}${snap.fetchedAt}${SNAP_SUFFIX}`;
    SnapshotStore.writeTextAtomic(path, sourceSnapshotToJson(snap));
    SubscriptionSourceStore.gc(snap.url);
  }

  /** 最近一份原始快照(无则 null)。 */
  static latest(url: string): SubscriptionSourceSnapshot | null {
    const times = SubscriptionSourceStore.listFetchedAt(url);
    if (times.length === 0) {
      return null;
    }
    return SubscriptionSourceStore.readAt(url, times[0]);
  }

  /** 读取指定 fetchedAt 的原始快照(转手动节点/恢复用)。 */
  static readAt(url: string, fetchedAt: number): SubscriptionSourceSnapshot | null {
    const dir = SubscriptionSourceStore.sourcesDirOf(url);
    const path = `${dir}/${SNAP_PREFIX}${fetchedAt}${SNAP_SUFFIX}`;
    if (!SnapshotStore.exists(path)) {
      return null;
    }
    return parseSourceSnapshot(SnapshotStore.readText(path));
  }

  /** 订阅删除时清理其全部原始快照。 */
  static removeAll(url: string): void {
    const dir = SubscriptionSourceStore.sourcesDirOf(url);
    const names = SnapshotStore.listFiles(dir, SNAP_PREFIX);
    for (let i = 0; i < names.length; i++) {
      SnapshotStore.removeFile(`${dir}/${names[i]}`);
    }
  }

  /** 该订阅现存的原始快照 fetchedAt 列表(降序)。 */
  static listFetchedAt(url: string): Array<number> {
    const dir = SubscriptionSourceStore.sourcesDirOf(url);
    const names = SnapshotStore.listFiles(dir, SNAP_PREFIX);
    const times: Array<number> = [];
    for (let i = 0; i < names.length; i++) {
      const n = names[i];
      if (!n.endsWith(SNAP_SUFFIX) || n.endsWith('.tmp')) {
        continue;
      }
      const middle = n.substring(SNAP_PREFIX.length, n.length - SNAP_SUFFIX.length);
      const t = Number(middle);
      if (Number.isInteger(t) && t > 0) {
        times.push(t);
      }
    }
    times.sort((a: number, b: number) => b - a);
    return times;
  }

  private static gc(url: string): void {
    const times = SubscriptionSourceStore.listFetchedAt(url);
    const dir = SubscriptionSourceStore.sourcesDirOf(url);
    for (let i = KEEP_PER_SUB; i < times.length; i++) {
      SnapshotStore.removeFile(`${dir}/${SNAP_PREFIX}${times[i]}${SNAP_SUFFIX}`);
    }
  }
}
