import { Profile } from '../model/Profile';
import { SnapshotContent, computeChecksum } from '../model/ConfigSnapshot';
import {
  UserOverride, SubscriptionSourceSnapshot, SourceNodeRecord, parseOverrideRecord, overrideToRecord,
  identityKeyOf, sourceNodeOf, profileFromSourceNode, mergeParsedIntoOwned, retainValidNodes
} from '../model/SubscriptionLayers';
import { SubInfo, SubUpdateResult, listSubs, saveSubs, subNameOf, stableProfileId,
  applyForceResolve, renameCollisions, dedupProfiles, parseSubscriptionBody,
  markGroupFromSubscription, markGroupSubUrl, applyClashGroups, resolveDialerProxies, applySubUserInfo,
  appContextOrNull, MIN_INTERVAL_MINUTES
} from './Subscriptions';
import { loadProfiles, saveProfiles, mutateProfiles, loadSettings, readPrefString,
  writePrefString, ensureGroupByName, LogStore } from '../model/Store';
import { fetchSubscriptionConditional, fetchTextUrl, subFailureText, ClashParseResult, SubFetchResult,
  looksLikeClashYaml, looksLikeSingBoxJson, SUB_UA, SUB_UA_FALLBACKS, decodeFilename
} from '../utils/Subscription';
import { parseClashGroups, ClashGroupDef } from '../utils/ClashProviders';
import { filterIsActive, filterNameIndexes } from '../model/NodeFilter';
import { ConfigRepository } from './ConfigRepository';
import { SubscriptionSourceStore } from './SubscriptionSourceStore';

/**
 * 订阅更新事务 —— REDESIGN-PLAN-2026-10-23.md §11.3/§11.4(P5/W17)。
 *
 * 流程:获取(锁外) → 解析+准备(锁外,含 UA 回退/改名/强制解析/去重等网络与 CPU 步骤)
 * → 串行提交段(锁内):重读当前态 → 身份合并(三层模型) → Preferences 兼容写 →
 * 原始层不可变文件 → ConfigRepository.commit(覆盖层唯一写入口)。
 *
 * 关键语义:
 *  - **基线 revision 比对**:fetch 前记录活动快照 revision;提交时若已推进,说明期间
 *    有其他提交(设置/规则/另一次更新),合并一律按**当前内容**重算(§11.3「提交前比较
 *    基线 revision 并重算合并」),并在日志中如实说明;
 *  - **304 只推进成功检查时间**:不清节点、不动用户覆盖,只更新 lastUpdate/
 *    nextUpdateAt/lastAttemptAt/lastError 与响应头里的流量信息;
 *  - 失败记录:本事务写 lastError/lastAttemptAt(failCount 仍由调用方 markSubFailure
 *    维护,避免双重计数);成功清 lastError。
 *
 * 兼容层说明:Preferences 仍是运行态读源(所有页面/扩展读它);快照 sections 在每次
 * 事务提交时从**活态**刷新(与 W16 设置事务同口径),配置快照的 revision 才是权威。
 */

/** 解析准备段产物(全部在写锁外完成)。 */
export class ParsedPreparation {
  /** 已完成 重命名冲突处理/强制解析/去重 的节点(身份合并的输入)。 */
  profiles: Array<Profile> = [];
  duplicateNames: Array<string> = [];
  skipped: number = 0;
  skippedNames: Array<string> = [];
  note: string = '';
  /** 命中的正文原文(原始层 contentHash 用)。 */
  content: string = '';
  format: string = 'unknown';
  etag: string = '';
  lastModified: string = '';
  userinfo: string = '';
  contentDisposition: string = '';
  clashGroups: Array<ClashGroupDef> = [];
}

/** 快照提交的段更新(只刷本事务涉及的段,其余段保留活动快照原值)。 */
class SectionUpdates {
  profiles: Array<Record<string, Object>> | null = null;
  subscriptions: Array<Record<string, Object>> | null = null;
  userOverrides: Array<Record<string, Object>> | null = null;
}

export class SubscriptionRepository {
  /** 订阅事务串行队列(更新/覆盖写入/304 推进互斥,§11.3「同一仓库串行提交」)。 */
  private static queue: Promise<Object | null> = Promise.resolve(null);

  /** W17 更新事务主入口(由 Subscriptions.updateSubscription 委托,initStore 已完成)。 */
  static async runUpdate(url: string): Promise<SubUpdateResult> {
    const baselineRevision = ConfigRepository.hasActive()
      ? ConfigRepository.getActiveRevision() : 0;
    try {
      const prep = await SubscriptionRepository.fetchAndParse(url, baselineRevision);
      if (prep === null) {
        // null = 304,advanceSuccessOnly 已在锁内处理完毕
        const totalNow = (await loadProfiles()).length;
        const res304: SubUpdateResult = {
          added: 0, removed: 0, total: totalNow, notModified: true,
          skipped: 0, skippedNames: [], note: '',
          changed: 0, addedNames: [], updatedNames: [], deletedNames: [], duplicateNames: []
        };
        return res304;
      }
      return await SubscriptionRepository.enqueue((): Promise<SubUpdateResult> =>
        SubscriptionRepository.commitUpdate(url, baselineRevision, prep));
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      await SubscriptionRepository.recordFailure(url, msg);
      throw e instanceof Error ? e : new Error(msg);
    }
  }

  // ---------------- 锁外:获取 + 解析 + 准备 ----------------

  private static async fetchAndParse(url: string,
    baselineRevision: number): Promise<ParsedPreparation | null> {
    const settings = await loadSettings();
    const subsForFlags = await listSubs();
    const subForFlags = subsForFlags.find((item: SubInfo) => item.url === url);
    const customUA = subForFlags !== undefined ? subForFlags.userAgent : '';
    const knownEtag = subForFlags !== undefined ? subForFlags.etag : '';
    const knownLastMod = subForFlags !== undefined ? subForFlags.lastModified : '';
    const existing = await loadProfiles();
    // 本订阅当前已入库的节点数:304 兜底判据(与原实现一致,防止校验器钉死在错误页)。
    const ownedBefore = existing.filter((p: Profile) => p.subUrl === url).length;
    let fetched: SubFetchResult = await fetchSubscriptionConditional(url, settings.subAllowInsecure,
      customUA, knownEtag, knownLastMod);
    if (fetched.notModified && ownedBefore === 0 &&
      (knownEtag.length > 0 || knownLastMod.length > 0)) {
      fetched = await fetchSubscriptionConditional(url, settings.subAllowInsecure,
        customUA, '', '');
    }
    if (fetched.notModified) {
      await SubscriptionRepository.enqueue((): Promise<Object | null> =>
        SubscriptionRepository.advanceSuccessOnly(url, fetched.userinfo, fetched.etag,
          fetched.lastModified));
      return null;
    }
    let content = fetched.content;
    // HTML 前置闸(错误页不该被当成 Clash YAML 误报「没有 proxies 节点列表」)
    if (/^\s*(<!DOCTYPE\s+html|<html[\s>])/i.test(content)) {
      throw new Error('订阅服务器返回了 HTML 页面而不是节点列表,请检查订阅地址是否正确、或该地址是否需要鉴权');
    }
    let r: ClashParseResult = await parseSubscriptionBody(content, settings.subAllowInsecure, customUA);
    let parsed = r.profiles;
    let skipped = r.skipped;
    let skippedNames = r.skippedNames;
    let note = r.note;
    let usedUa = customUA.trim().length > 0 ? customUA.trim() : SUB_UA;
    // UA 回退(每轮最多 2 次额外请求,只在「像订阅但解析不出节点」时触发)
    if (parsed.length === 0 && note !== 'clash_provider_only') {
      for (const ua of SUB_UA_FALLBACKS) {
        if (ua === usedUa) {
          continue;
        }
        let altContent = '';
        try {
          altContent = await fetchTextUrl(url, settings.subAllowInsecure, ua);
        } catch (e) {
          continue;
        }
        if (altContent.trim().length === 0 || altContent === content) {
          continue;
        }
        const alt: ClashParseResult = await parseSubscriptionBody(altContent, settings.subAllowInsecure, ua);
        if (alt.profiles.length > 0) {
          LogStore.addLog(`[sub] ${url} 用默认 User-Agent 解析不到节点,改用 ${ua} 后成功`);
          content = altContent;
          r = alt;
          parsed = alt.profiles;
          skipped = alt.skipped;
          skippedNames = alt.skippedNames;
          note = alt.note;
          usedUa = ua;
          break;
        }
      }
    }
    if (parsed.length === 0) {
      // 不落盘 ETag/Last-Modified(否则一次错误页把校验器钉死,304 兜底也救不回)
      const detail = note.length > 0 ? '' : `(已尝试的 User-Agent:${usedUa})`;
      throw new Error(subFailureText(note, content, skipped, skippedNames) + detail);
    }
    const prep = new ParsedPreparation();
    prep.content = content;
    prep.etag = fetched.etag;
    prep.lastModified = fetched.lastModified;
    prep.userinfo = fetched.userinfo;
    prep.contentDisposition = fetched.contentDisposition;
    prep.skipped = skipped;
    prep.skippedNames = skippedNames;
    prep.note = note;
    prep.format = detectFormat(content);
    // ---- 以下准备步骤逐字沿用 Android RawUpdater.doUpdate 顺序(锁外网络步骤) ----
    // 1) 重名改名
    renameCollisions(parsed);
    // 2) forceResolve(网络,先于去重)
    const ipv6First = settings.ipv6Mode === 'prefer' || settings.ipv6Mode === 'only';
    if (subForFlags !== undefined && subForFlags.forceResolve) {
      await applyForceResolve(parsed, ipv6First);
    }
    // 3) 去重(由 subscription.deduplication 门控)
    let effective = parsed;
    if (subForFlags !== undefined && subForFlags.deduplication) {
      const dedup = dedupProfiles(parsed);
      effective = dedup.profiles;
      prep.duplicateNames = dedup.duplicates;
    }
    // 4) 节点名过滤(对齐 OwnBox RawUpdater.kt:199-212;先过滤再入层,过滤器为空时原样返回)
    if (subForFlags !== undefined && filterIsActive(subForFlags.filterMode, subForFlags.filterRegex)) {
      const names: Array<string> = effective.map((p: Profile) => p.name);
      const indexes: Array<number> = filterNameIndexes(names, subForFlags.filterMode, subForFlags.filterRegex);
      if (indexes.length === 0) {
        // 不把用户现有的节点全删掉:过滤结果为空一律当作本次更新失败
        throw new Error('订阅过滤器排除了全部节点,已放弃本次更新(保留现有节点)');
      }
      const filtered: Array<Profile> = [];
      for (let i = 0; i < indexes.length; i++) {
        filtered.push(effective[indexes[i]]);
      }
      LogStore.addLog(`[sub] ${url} 节点过滤(${subForFlags.filterMode}/${subForFlags.filterRegex}) ` +
        `保留 ${filtered.length}/${effective.length}`);
      effective = filtered;
    }
    prep.profiles = effective;
    prep.clashGroups = looksLikeClashYaml(content) ? parseClashGroups(content) : [];
    return prep;
  }

  // ---------------- 锁内:提交 ----------------

  private static async commitUpdate(url: string, baselineRevision: number,
    prep: ParsedPreparation): Promise<SubUpdateResult> {
    const activeRev = ConfigRepository.hasActive() ? ConfigRepository.getActiveRevision() : 0;
    if (activeRev !== baselineRevision) {
      LogStore.addLog(`[subtx] ${url}: 基线 r${baselineRevision}→r${activeRev} 已推进,按当前内容重算合并`);
    }
    const subsAll = await listSubs();
    const sub = subsAll.find((item: SubInfo) => item.url === url);
    if (sub === undefined) {
      throw new Error('订阅已被删除,取消本次更新');
    }
    const existing = await loadProfiles();
    const overridesAll = SubscriptionRepository.loadOverrides();
    // 一订阅一分组(优先订阅分组名,其次订阅名,再次域名)
    let groupName = subNameOf(url);
    if (sub.group.trim().length > 0) {
      groupName = sub.group.trim();
    } else if (sub.name.trim().length > 0) {
      groupName = sub.name.trim();
    }
    const subGroupId = await ensureGroupByName(groupName);
    await markGroupFromSubscription(subGroupId);
    await markGroupSubUrl(subGroupId, url);
    const selectedId = await readPrefString('selected_profile_id', '');
    const owned = existing.filter((p: Profile) => p.subUrl === url);
    const now = Date.now();
    const merge = mergeParsedIntoOwned(prep.profiles, owned, overridesAll, url,
      subGroupId, stableProfileId, now);
    for (let i = 0; i < merge.conflicts.length; i++) {
      const c = merge.conflicts[i];
      LogStore.addLog(`[subtx] ${url} 覆盖冲突(${c.kind}): ${c.message}`);
    }
    // 保留有效节点(对齐 OwnBox retainValidNodes):只救「在用/测速可用/有流量」的远端已删节点
    if (sub.retainValidNodes === true) {
      const retained = retainValidNodes(merge, owned, url, selectedId, now);
      if (retained.retainedNames.length > 0) {
        LogStore.addLog(`[subtx] ${url} 保留有效节点 ${retained.retainedNames.length} 个: ` +
          retained.retainedNames.slice(0, 8).join(', '));
      }
    }
    const kept: Array<Profile> = existing.filter((p: Profile) => p.subUrl !== url);
    for (let i = 0; i < merge.kept.length; i++) {
      kept.push(merge.kept[i]);
    }
    if (merge.deletedNames.length > 0) {
      LogStore.addLog(`[subtx] ${url} 远端删除 ${merge.deletedNames.length} 个节点,覆盖已转墓碑(可恢复/转手动)`);
    }
    resolveDialerProxies(prep.profiles, kept);
    await saveProfiles(kept);
    if (prep.clashGroups.length > 0) {
      await applyClashGroups(prep.clashGroups, kept, url);
    }
    // 选中项失效:兜底指向本订阅第一个节点(与原实现一致)
    if (selectedId.length > 0 && !kept.some((item: Profile) => item.id === selectedId)) {
      const replacement = kept.find((item: Profile) => item.subUrl === url);
      await writePrefString('selected_profile_id', replacement === undefined ? '' : replacement.id);
    }
    // 订阅记录:成功时间/校验器/流量信息/content-disposition 改名
    sub.lastUpdate = now;
    sub.lastAttemptAt = now;
    sub.lastError = '';
    sub.nextUpdateAt = now + Math.max(MIN_INTERVAL_MINUTES, sub.updateIntervalMinutes) * 60 * 1000;
    sub.etag = prep.etag;
    sub.lastModified = prep.lastModified;
    if (sub.name.startsWith('Subscription #') && prep.contentDisposition.length > 0) {
      const remoteName = decodeFilename(prep.contentDisposition);
      if (remoteName.length > 0) {
        sub.name = remoteName;
        LogStore.addLog(`[subtx] ${url} 组名按 content-disposition 改为 ${remoteName}`);
      }
    }
    await saveSubs(subsAll);
    if (prep.userinfo.length > 0) {
      await applySubUserInfo(url, prep.userinfo);
    }
    // 原始层:写不可变文件(当前 + 上一份,永不原地覆盖)
    SubscriptionRepository.ensureSourceStore();
    SubscriptionRepository.saveSourceSnapshot(url, prep, now);
    // 覆盖层:其他订阅覆盖原样 + 本订阅 nextOverrides → commit(唯一写入口)
    const subsFinal = await listSubs();
    const otherOverrides = overridesAll.filter((o: UserOverride) => o.subscriptionUrl !== url);
    const allOverrides = otherOverrides.concat(merge.nextOverrides);
    const sections = new SectionUpdates();
    sections.profiles = serializeProfiles(kept);
    sections.subscriptions = serializeSubs(subsFinal);
    sections.userOverrides = serializeOverrides(allOverrides);
    await SubscriptionRepository.commitSections(sections, `订阅更新 ${url}`);
    const result: SubUpdateResult = {
      added: merge.addedNames.length,
      removed: merge.deletedNames.length,
      total: kept.length,
      notModified: false,
      skipped: prep.skipped,
      skippedNames: prep.skippedNames,
      note: prep.note,
      changed: merge.changed,
      addedNames: merge.addedNames,
      updatedNames: merge.updatedNames,
      deletedNames: merge.deletedNames,
      duplicateNames: prep.duplicateNames
    };
    LogStore.addLog(`[subtx] ${url} 更新完成: +${result.added} ~${result.updatedNames.length} ` +
      `-${result.removed}(原始层 ${merge.kept.length} 节点,覆盖 ${merge.nextOverrides.length} 条)`);
    return result;
  }

  /** 304:只推进成功检查时间(锁内;不动节点、不动覆盖,§11.3)。 */
  private static async advanceSuccessOnly(url: string, userinfo: string, etag: string,
    lastModified: string): Promise<Object | null> {
    const subsAll = await listSubs();
    const sub = subsAll.find((item: SubInfo) => item.url === url);
    if (sub === undefined) {
      throw new Error('订阅已被删除,取消本次更新');
    }
    const now = Date.now();
    sub.lastUpdate = now;
    sub.lastAttemptAt = now;
    sub.lastError = '';
    sub.nextUpdateAt = now + Math.max(MIN_INTERVAL_MINUTES, sub.updateIntervalMinutes) * 60 * 1000;
    if (etag.length > 0) {
      sub.etag = etag;
    }
    if (lastModified.length > 0) {
      sub.lastModified = lastModified;
    }
    await saveSubs(subsAll);
    if (userinfo.length > 0) {
      await applySubUserInfo(url, userinfo);
    }
    const subsFinal = await listSubs();
    const sections = new SectionUpdates();
    sections.subscriptions = serializeSubs(subsFinal);
    await SubscriptionRepository.commitSections(sections, `304 推进成功检查时间 ${url}`);
    LogStore.addLog(`[subtx] ${url}: 304 内容未变,仅推进成功检查时间(节点与用户覆盖不动)`);
    return null;
  }

  /** 失败记录:lastError/lastAttemptAt(failCount 由调用方 markSubFailure 维护)。 */
  private static async recordFailure(url: string, message: string): Promise<void> {
    try {
      await SubscriptionRepository.enqueue((): Promise<Object | null> =>
        SubscriptionRepository.recordFailureLocked(url, message));
    } catch (e) {
      LogStore.addLog(`[subtx] ${url} 失败信息落盘异常: ${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  private static async recordFailureLocked(url: string, message: string): Promise<Object | null> {
    const subsAll = await listSubs();
    const sub = subsAll.find((item: SubInfo) => item.url === url);
    if (sub === undefined) {
      return null;
    }
    sub.lastAttemptAt = Date.now();
    sub.lastError = message.length > 300 ? `${message.substring(0, 300)}…` : message;
    await saveSubs(subsAll);
    const sections = new SectionUpdates();
    sections.subscriptions = serializeSubs(subsAll);
    await SubscriptionRepository.commitSections(sections, `记录更新失败 ${url}`);
    return null;
  }

  // ---------------- 覆盖层读写(快照 content.userOverrides) ----------------

  static loadOverrides(): Array<UserOverride> {
    const active = ConfigRepository.getActive();
    if (active === null) {
      return [];
    }
    const out: Array<UserOverride> = [];
    const raw = active.content.userOverrides;
    for (let i = 0; i < raw.length; i++) {
      const parsed = parseOverrideRecord(raw[i]);
      if (parsed !== null) {
        out.push(parsed);
      }
    }
    return out;
  }

  /** W18 供 UI:某订阅的墓碑覆盖(远端已删除,可恢复/转手动)。 */
  static tombstonesOf(url: string): Array<UserOverride> {
    const out: Array<UserOverride> = [];
    const all = SubscriptionRepository.loadOverrides();
    for (let i = 0; i < all.length; i++) {
      if (all[i].subscriptionUrl === url && all[i].deletedAt > 0) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /**
   * W18:清空订阅节点(保留订阅记录与设置;危险操作,页面负责二次确认)。
   * 节点经 mutateProfiles 串行删除,快照段提交收口;原始层与墓碑保留(可再更新找回)。
   */
  static async clearSubscriptionNodes(url: string): Promise<number> {
    return await SubscriptionRepository.enqueue(async (): Promise<number> => {
      let removed = 0;
      const afterDelete = await mutateProfiles((profiles: Array<Profile>): Array<Profile> => {
        const kept: Array<Profile> = [];
        for (let i = 0; i < profiles.length; i++) {
          if (profiles[i].subUrl === url) {
            removed++;
            continue;
          }
          kept.push(profiles[i]);
        }
        return kept;
      });
      const sections = new SectionUpdates();
      sections.profiles = serializeProfiles(afterDelete);
      await SubscriptionRepository.commitSections(sections, `清空订阅节点 ${url}`);
      LogStore.addLog(`[subtx] ${url} 清空节点: 移除 ${removed} 个(订阅记录与原始层保留)`);
      return removed;
    });
  }

  /**
   * W18:删除订阅的配套清理(在 removeSub 之后调用):清原始层文件与覆盖层墓碑。
   * 快照 profiles/subscriptions 段由调用方 removeSub 后的活态刷新负责。
   */
  static async purgeSubscriptionArtifacts(url: string): Promise<void> {
    await SubscriptionRepository.enqueue(async (): Promise<Object | null> => {
      SubscriptionRepository.ensureSourceStore();
      SubscriptionSourceStore.removeAll(url);
      const overrides = SubscriptionRepository.loadOverrides()
        .filter((o: UserOverride) => o.subscriptionUrl !== url);
      const sections = new SectionUpdates();
      sections.userOverrides = serializeOverrides(overrides);
      await SubscriptionRepository.commitSections(sections, `删除订阅清理覆盖层 ${url}`);
      return null;
    });
  }

  /**
   * W18:墓碑「转为手动节点」—— 从最近一份原始层快照还原传输字段,落成 subUrl='' 的
   * 手动节点(不悄悄保留为订阅可用项,§11.4),覆盖(收藏/排序/展示分组)随迁,
   * 墓碑随即移除。找不到原始记录时抛错(不凭空造节点)。
   */
  static async convertTombstoneToManual(url: string, identityKey: string): Promise<string> {
    return await SubscriptionRepository.enqueue(async (): Promise<string> => {
      SubscriptionRepository.ensureSourceStore();
      if (!SubscriptionSourceStore.isInitialized()) {
        throw new Error('原始层存储未初始化');
      }
      const times = SubscriptionSourceStore.listFetchedAt(url);
      let node: SourceNodeRecord | null = null;
      for (let i = 0; i < times.length && node === null; i++) {
        const snap = SubscriptionSourceStore.readAt(url, times[i]);
        if (snap === null) {
          continue;
        }
        for (let j = 0; j < snap.nodes.length; j++) {
          if (snap.nodes[j].identityKey === identityKey) {
            node = snap.nodes[j];
            break;
          }
        }
      }
      if (node === null) {
        throw new Error('原始层中找不到该节点的传输记录(可能已被新快照滚动清理)');
      }
      const overrides = SubscriptionRepository.loadOverrides();
      const tombstone = overrides.find((o: UserOverride) =>
        o.subscriptionUrl === url && o.identityKey === identityKey && o.deletedAt > 0);
      const manual = profileFromSourceNode(node);
      manual.id = stableProfileId(manual, 'manual');
      manual.subUrl = '';
      if (tombstone !== undefined) {
        manual.pinned = tombstone.pinned;
        manual.groupId = tombstone.displayGroupId;
        if (tombstone.sortOrder > 0) {
          manual.sortOrder = tombstone.sortOrder;
        }
      }
      manual.updatedAt = Date.now();
      const afterAdd = await mutateProfiles((profiles: Array<Profile>): Array<Profile> => {
        profiles.push(manual);
        return profiles;
      });
      const remaining = overrides.filter((o: UserOverride) =>
        !(o.subscriptionUrl === url && o.identityKey === identityKey));
      const sections = new SectionUpdates();
      sections.profiles = serializeProfiles(afterAdd);
      sections.userOverrides = serializeOverrides(remaining);
      await SubscriptionRepository.commitSections(sections, `墓碑转手动节点 ${identityKey}`);
      LogStore.addLog(`[subtx] 墓碑转手动节点: ${manual.name}(订阅 ${url} 的覆盖已随迁)`);
      return manual.name;
    });
  }

  // ---------------- 内部工具 ----------------

  private static enqueue<T>(task: () => Promise<T>): Promise<T> {
    const previous = SubscriptionRepository.queue;
    let release: () => void = () => {};
    SubscriptionRepository.queue = new Promise<Object | null>(
      (resolve: (v: Object | null) => void) => {
        release = () => {
          resolve(null);
        };
      });
    const run = async (): Promise<T> => {
      try {
        await previous;
      } catch (e) {
        // 前一次失败不阻断后一次
      }
      try {
        return await task();
      } finally {
        release();
      }
    };
    return run();
  }

  /**
   * 快照段提交(只覆盖本事务涉及的段,其余保留活动快照)。
   * 快照未初始化:如实记日志跳过(与 W16 同口径);提交失败:数据已在 Preferences,
   * 日志留痕,不伪造 revision。
   */
  private static async commitSections(sections: SectionUpdates, reason: string): Promise<void> {
    if (!ConfigRepository.hasActive()) {
      LogStore.addLog(`[subtx] ${reason}: 配置快照未初始化,本次仅保存 Preferences`);
      return;
    }
    try {
      const snap = await ConfigRepository.commit((draft: SnapshotContent): SnapshotContent => {
        if (sections.profiles !== null) {
          draft.profiles = sections.profiles;
        }
        if (sections.subscriptions !== null) {
          draft.subscriptions = sections.subscriptions;
        }
        if (sections.userOverrides !== null) {
          draft.userOverrides = sections.userOverrides;
        }
        return draft;
      });
      LogStore.addLog(`[subtx] ${reason}: 快照提交 r${snap.revision}`);
    } catch (e) {
      LogStore.addLog(`[subtx] ${reason}: 快照提交失败(数据已存 Preferences,下次事务自愈): ` +
        `${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  private static ensureSourceStore(): void {
    if (SubscriptionSourceStore.isInitialized()) {
      return;
    }
    const ctx = appContextOrNull();
    if (ctx !== null) {
      SubscriptionSourceStore.init(ctx);
    }
  }

  private static saveSourceSnapshot(url: string, prep: ParsedPreparation, fetchedAt: number): void {
    if (!SubscriptionSourceStore.isInitialized()) {
      LogStore.addLog(`[subtx] ${url}: 原始层存储未初始化,本次不落原始快照`);
      return;
    }
    const snap = new SubscriptionSourceSnapshot();
    snap.url = url;
    snap.fetchedAt = fetchedAt;
    snap.format = prep.format;
    snap.etag = prep.etag;
    snap.lastModified = prep.lastModified;
    snap.contentHash = computeChecksum(prep.content);
    for (let i = 0; i < prep.profiles.length; i++) {
      const p = prep.profiles[i];
      const node = sourceNodeOf(p);
      node.identityKey = identityKeyOf(url, p);
      snap.nodes.push(node);
    }
    snap.nodeCount = snap.nodes.length;
    SubscriptionSourceStore.save(snap);
  }
}

/** 正文格式识别(原始层标注用)。 */
function detectFormat(content: string): string {
  if (looksLikeClashYaml(content)) {
    return 'clash-yaml';
  }
  const t = content.trim();
  if (looksLikeSingBoxJson(content) || t.startsWith('{') || t.startsWith('[')) {
    return 'singbox-json';
  }
  return 'share-links';
}

function serializeProfiles(list: Array<Profile>): Array<Record<string, Object>> {
  return JSON.parse(JSON.stringify(list)) as Array<Record<string, Object>>;
}

function serializeSubs(list: Array<SubInfo>): Array<Record<string, Object>> {
  return JSON.parse(JSON.stringify(list)) as Array<Record<string, Object>>;
}

function serializeOverrides(list: Array<UserOverride>): Array<Record<string, Object>> {
  const out: Array<Record<string, Object>> = [];
  for (let i = 0; i < list.length; i++) {
    out.push(overrideToRecord(list[i]));
  }
  return out;
}
