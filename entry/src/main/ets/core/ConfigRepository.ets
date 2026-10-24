import common from '@ohos.app.ability.common';
import { SnapshotStore } from './SnapshotStore';
import {
  ConfigSnapshot, SnapshotContent, SnapshotParseResult, CONFIG_SCHEMA_VERSION,
  buildSnapshot, cloneContent, computeChecksum, contentToJson, parseSnapshot, serializeSnapshot
} from '../model/ConfigSnapshot';
import { LogStore } from '../model/Store';

/**
 * 配置仓库 —— REDESIGN-PLAN-2026-10-23.md §14.3 的唯一业务写入口(单写者)。
 *
 * 权威模型：
 *  - 版本化不可变快照文件 `config-snapshot-<revision>.json`(永不原地改写)；
 *  - 活动指针 = 双槽 manifest(`manifest-a.json`/`manifest-b.json` 按 revision 奇偶交替写)，
 *    这正是 §14.3-4 的「平台不能保证原子替换时改用双槽 manifest + 单调 revision + 校验恢复」；
 *  - 每次提交：写新快照(revision+1) → 读回复核 checksum → 写 manifest slot → 读回复核。
 *    任何一步失败都不推进 active，调用方保留草稿(§12.3 应用事务状态机的存储底座)。
 *  - init 加载顺序：两个 manifest 里合法且 revision 最大者 → 另一槽 → 直接扫描快照文件兜底。
 *    任一损坏都不影响回退到上一个已验证版本(MIG-02)。
 *
 * 本类不解析实体字段：content 保持 Preferences 的 JSON 原样，迁移与实体化由 MigrationV5/适配层负责。
 */

const MANIFEST_SLOT_A = 'manifest-a.json';
const MANIFEST_SLOT_B = 'manifest-b.json';
const SNAPSHOT_PREFIX = 'config-snapshot-';
const SNAPSHOT_SUFFIX = '.json';
/** 保留最近 N 个快照(活动 + 回滚点)。更旧的 GC 删除，但被引用的一律保留。 */
const KEEP_REVISIONS = 3;

class SlotManifest {
  schemaVersion: number = CONFIG_SCHEMA_VERSION;
  activeRevision: number = 0;
  snapshotFile: string = '';
  checksum: string = '';
  savedAt: number = 0;
  slot: string = '';
}

export class ConfigRepository {
  private static writerQueue: Promise<void> = Promise.resolve();
  private static active: ConfigSnapshot | null = null;
  private static dir: string = '';
  private static initError: string = '';

  /** 初始化：建立目录并恢复活动快照。无有效快照时 active=null，等待 migrateFromPreferences。 */
  static async init(context: common.Context): Promise<void> {
    ConfigRepository.dir = SnapshotStore.configDir(context);
    SnapshotStore.ensureDir(ConfigRepository.dir);
    ConfigRepository.initError = '';
    const recovered = ConfigRepository.recover();
    if (recovered !== null) {
      ConfigRepository.active = recovered;
      ConfigRepository.cleanupOrphans(recovered.revision);
      LogStore.addLog(`[config] 活动快照已加载: revision=${recovered.revision}, ` +
        `profiles=${recovered.content.profiles.length}, rules=${recovered.content.routeRules.length}`);
    } else {
      ConfigRepository.active = null;
      LogStore.addLog('[config] 未发现有效配置快照，等待迁移');
    }
  }

  /** 快照目录是否已初始化。 */
  static isInitialized(): boolean {
    return ConfigRepository.dir.length > 0;
  }

  /** 当前活动快照(只读用；调用方不得原地修改 content)。 */
  static getActive(): ConfigSnapshot | null {
    return ConfigRepository.active;
  }

  static getActiveRevision(): number {
    const active = ConfigRepository.active;
    return active === null ? 0 : active.revision;
  }

  static hasActive(): boolean {
    return ConfigRepository.active !== null;
  }

  static getInitError(): string {
    return ConfigRepository.initError;
  }

  /**
   * 首次落盘(迁移/建库)：仅在当前无活动快照时允许，写入 revision=1。
   * 幂等：已有活动快照时直接返回现有快照，不重写、不递增(F 迁移重复启动安全)。
   */
  static commitInitial(content: SnapshotContent): Promise<ConfigSnapshot> {
    return ConfigRepository.enqueue(async (): Promise<ConfigSnapshot> => {
      const existing = ConfigRepository.active;
      if (existing !== null) {
        return existing;
      }
      if (!ConfigRepository.isInitialized()) {
        throw new Error('config repository not initialized');
      }
      const snap = buildSnapshot(1, -1, content);
      ConfigRepository.persist(snap);
      ConfigRepository.active = snap;
      LogStore.addLog(`[config] 初始快照已写入: revision=1, checksum=${snap.checksum}`);
      return snap;
    });
  }

  /**
   * 提交一次变更：基于活动快照的深拷贝执行 mutation，写新 revision。
   * 失败抛出(活动指针不变)，调用方据此保留草稿并展示真实失败原因(§12.3)。
   */
  static commit(mutation: (content: SnapshotContent) => SnapshotContent,
    resourceManifestId: string = ''): Promise<ConfigSnapshot> {
    return ConfigRepository.enqueue(async (): Promise<ConfigSnapshot> => {
      const base = ConfigRepository.active;
      if (base === null) {
        throw new Error('config repository has no active snapshot');
      }
      const draft = cloneContent(base.content);
      const next = mutation(draft);
      const snap = buildSnapshot(base.revision + 1, base.revision, next,
        resourceManifestId.length > 0 ? resourceManifestId : base.resourceManifestId);
      ConfigRepository.persist(snap);
      ConfigRepository.active = snap;
      ConfigRepository.gc();
      LogStore.addLog(`[config] 快照提交成功: revision=${base.revision}→${snap.revision}`);
      return snap;
    });
  }

  /**
   * 回到历史快照(MIG-05)：把目标 revision 的内容作为**新 revision** 提交，
   * 不删除历史文件。目标不存在/损坏时抛出，原活动快照不变。
   */
  static rollbackTo(revision: number): Promise<ConfigSnapshot> {
    return ConfigRepository.enqueue(async (): Promise<ConfigSnapshot> => {
      const active = ConfigRepository.active;
      if (active === null) {
        throw new Error('config repository has no active snapshot');
      }
      if (revision === active.revision) {
        return active;
      }
      const file = ConfigRepository.snapshotPath(revision);
      if (!SnapshotStore.exists(file)) {
        throw new Error(`snapshot r${revision} not found`);
      }
      const parsed = parseSnapshot(SnapshotStore.readText(file));
      if (!parsed.ok || parsed.snapshot === null) {
        throw new Error(`snapshot r${revision} invalid: ${parsed.error}`);
      }
      const snap = buildSnapshot(active.revision + 1, active.revision,
        cloneContent(parsed.snapshot.content), parsed.snapshot.resourceManifestId);
      ConfigRepository.persist(snap);
      ConfigRepository.active = snap;
      ConfigRepository.gc();
      LogStore.addLog(`[config] 已回滚内容 r${revision} → 新修订 r${snap.revision}`);
      return snap;
    });
  }

  /** 读取历史快照内容(诊断/测试；不改变活动指针)。 */
  static loadSnapshot(revision: number): ConfigSnapshot | null {
    const parsed = parseSnapshot(SnapshotStore.readText(ConfigRepository.snapshotPath(revision)));
    if (!parsed.ok || parsed.snapshot === null) {
      return null;
    }
    return parsed.snapshot;
  }

  // ---- 内部实现 ----

  private static enqueue<T>(task: () => Promise<T>): Promise<T> {
    const previous = ConfigRepository.writerQueue;
    let release: () => void = () => {};
    ConfigRepository.writerQueue = new Promise<void>((resolve: () => void) => {
      release = resolve;
    });
    const run = async (): Promise<T> => {
      try {
        await previous;
      } catch (e) {
        // 前一次失败不阻断后一次提交
      }
      try {
        return await task();
      } finally {
        release();
      }
    };
    return run();
  }

  private static snapshotPath(revision: number): string {
    return `${ConfigRepository.dir}/${SNAPSHOT_PREFIX}${revision}${SNAPSHOT_SUFFIX}`;
  }

  private static snapshotFileName(revision: number): string {
    return `${SNAPSHOT_PREFIX}${revision}${SNAPSHOT_SUFFIX}`;
  }

  /** 写快照 + manifest，全部读回复核；失败抛错且不动 active(调用方负责)。 */
  private static persist(snap: ConfigSnapshot): void {
    const path = ConfigRepository.snapshotPath(snap.revision);
    SnapshotStore.writeTextAtomic(path, serializeSnapshot(snap));
    const readBack = parseSnapshot(SnapshotStore.readText(path));
    if (!readBack.ok || readBack.snapshot === null) {
      throw new Error(`snapshot write verify failed: ${readBack.error}`);
    }
    if (readBack.snapshot.checksum !== snap.checksum) {
      throw new Error('snapshot write verify failed: checksum mismatch');
    }
    ConfigRepository.writeManifest(snap);
  }

  private static writeManifest(snap: ConfigSnapshot): void {
    const slot = snap.revision % 2 === 0 ? MANIFEST_SLOT_A : MANIFEST_SLOT_B;
    const manifest = new SlotManifest();
    manifest.activeRevision = snap.revision;
    manifest.snapshotFile = ConfigRepository.snapshotFileName(snap.revision);
    manifest.checksum = snap.checksum;
    manifest.savedAt = Date.now();
    manifest.slot = slot;
    const path = `${ConfigRepository.dir}/${slot}`;
    SnapshotStore.writeTextAtomic(path, JSON.stringify(manifest));
    const back = ConfigRepository.readManifest(slot);
    if (back === null || back.activeRevision !== snap.revision) {
      throw new Error('manifest write verify failed');
    }
  }

  private static readManifest(slot: string): SlotManifest | null {
    const path = `${ConfigRepository.dir}/${slot}`;
    if (!SnapshotStore.exists(path)) {
      return null;
    }
    try {
      const raw = JSON.parse(SnapshotStore.readText(path)) as Record<string, Object>;
      const manifest = new SlotManifest();
      manifest.schemaVersion = Number(raw['schemaVersion'] ?? 0);
      manifest.activeRevision = Number(raw['activeRevision'] ?? 0);
      manifest.snapshotFile = `${raw['snapshotFile'] ?? ''}`;
      manifest.checksum = `${raw['checksum'] ?? ''}`;
      manifest.savedAt = Number(raw['savedAt'] ?? 0);
      manifest.slot = `${raw['slot'] ?? slot}`;
      if (!(manifest.activeRevision >= 1) || manifest.snapshotFile.length === 0 ||
        manifest.snapshotFile.indexOf(SNAPSHOT_PREFIX) !== 0) {
        return null;
      }
      return manifest;
    } catch (e) {
      return null;
    }
  }

  /**
   * 三级恢复：两个 manifest 中 revision 最大且快照校验通过者 → 另一槽 → 扫描快照文件。
   * 扫描范围以「可读 manifest 的最大 revision」为上限：失败提交可能留下已写快照但
   * manifest 未推进的孤儿文件(§12.3 提交失败不得推进保存状态)，不得被兜底采纳。
   * 仅当两个 manifest 都不可读(彻底损坏)时才全范围扫描，并在日志中显式说明。
   */
  private static recover(): ConfigSnapshot | null {
    const manifests: Array<SlotManifest> = [];
    const a = ConfigRepository.readManifest(MANIFEST_SLOT_A);
    if (a !== null) {
      manifests.push(a);
    }
    const b = ConfigRepository.readManifest(MANIFEST_SLOT_B);
    if (b !== null) {
      manifests.push(b);
    }
    let manifestCeiling = 0;
    manifests.sort((x: SlotManifest, y: SlotManifest) => y.activeRevision - x.activeRevision);
    for (let i = 0; i < manifests.length; i++) {
      if (manifests[i].activeRevision > manifestCeiling) {
        manifestCeiling = manifests[i].activeRevision;
      }
      const snap = ConfigRepository.verifySnapshotFile(manifests[i].activeRevision, manifests[i].checksum);
      if (snap !== null) {
        return snap;
      }
      LogStore.addLog(`[config] manifest slot ${manifests[i].slot} 指向的快照不可用，尝试回退`);
    }
    const revisions = ConfigRepository.listSnapshotRevisions();
    for (let i = 0; i < revisions.length; i++) {
      if (manifestCeiling > 0 && revisions[i] > manifestCeiling) {
        // 超出已提交上限:只可能是提交中断留下的孤儿，跳过
        continue;
      }
      const snap = ConfigRepository.verifySnapshotFile(revisions[i], '');
      if (snap !== null) {
        const via = manifestCeiling > 0 ? '快照文件上限内' : '双 manifest 损坏全扫描';
        LogStore.addLog(`[config] 由快照文件兜底恢复(${via}): revision=${revisions[i]}`);
        return snap;
      }
    }
    return null;
  }

  /** 删除 revision 大于活动修订的快照文件：它们只可能来自提交中断的孤儿，不得作为活动配置。 */
  private static cleanupOrphans(activeRevision: number): void {
    const revisions = ConfigRepository.listSnapshotRevisions();
    for (let i = 0; i < revisions.length; i++) {
      if (revisions[i] > activeRevision) {
        SnapshotStore.removeFile(ConfigRepository.snapshotPath(revisions[i]));
      }
    }
  }

  private static verifySnapshotFile(revision: number, expectedChecksum: string): ConfigSnapshot | null {
    const path = ConfigRepository.snapshotPath(revision);
    if (!SnapshotStore.exists(path)) {
      return null;
    }
    const parsed: SnapshotParseResult = parseSnapshot(SnapshotStore.readText(path));
    if (!parsed.ok || parsed.snapshot === null) {
      return null;
    }
    if (parsed.snapshot.revision !== revision) {
      return null;
    }
    if (expectedChecksum.length > 0 && parsed.snapshot.checksum !== expectedChecksum) {
      return null;
    }
    return parsed.snapshot;
  }

  /** 目录内快照文件的 revision 列表(降序)。 */
  private static listSnapshotRevisions(): Array<number> {
    const names = SnapshotStore.listFiles(ConfigRepository.dir, SNAPSHOT_PREFIX);
    const revisions: Array<number> = [];
    for (let i = 0; i < names.length; i++) {
      const n = names[i];
      if (!n.endsWith(SNAPSHOT_SUFFIX)) {
        continue;
      }
      const middle = n.substring(SNAPSHOT_PREFIX.length, n.length - SNAPSHOT_SUFFIX.length);
      const rev = Number(middle);
      if (Number.isInteger(rev) && rev >= 1) {
        revisions.push(rev);
      }
    }
    revisions.sort((x: number, y: number) => y - x);
    return revisions;
  }

  /** GC：保留活动及最近 KEEP_REVISIONS 个快照，清理更旧文件与 .tmp 残留。 */
  private static gc(): void {
    const active = ConfigRepository.active;
    if (active === null) {
      return;
    }
    const revisions = ConfigRepository.listSnapshotRevisions();
    const keepFrom = active.revision - (KEEP_REVISIONS - 1);
    for (let i = 0; i < revisions.length; i++) {
      const rev = revisions[i];
      if (rev > active.revision) {
        // 提交中断产生的孤儿(不在历史链上)
        SnapshotStore.removeFile(ConfigRepository.snapshotPath(rev));
        continue;
      }
      if (rev < keepFrom && rev !== active.revision) {
        SnapshotStore.removeFile(ConfigRepository.snapshotPath(rev));
      }
    }
    const tmpNames = SnapshotStore.listFiles(ConfigRepository.dir, SNAPSHOT_PREFIX);
    for (let i = 0; i < tmpNames.length; i++) {
      if (tmpNames[i].endsWith('.tmp')) {
        SnapshotStore.removeFile(`${ConfigRepository.dir}/${tmpNames[i]}`);
      }
    }
  }
}
