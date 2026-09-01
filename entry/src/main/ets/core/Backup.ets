import common from '@ohos.app.ability.common';
import { Profile, AppSettings } from '../model/Profile';
import { ProfileStorage } from '../common/storage/ProfileStorage';
import { SubInfo, listSubs, saveSubs } from './Subscriptions';

/** 配置备份/恢复:把节点 + 设置序列化为 JSON 文本(放剪贴板/文件均可)。 */

interface BackupPayload {
  version: number;
  exportedAt: number;
  settings: AppSettings;
  profiles: Array<Profile>;
  /** v2 payloads optionally carry subscription metadata. */
  subscriptions?: Array<SubInfo>;
}

/**
 * Export profiles/settings and, by default, subscription metadata.  The
 * optional flag keeps callers that only want node/settings data compatible
 * with the v1 behaviour while making the complete backup the normal path.
 */
export async function exportBackup(context: common.Context, includeSubscriptions: boolean = true): Promise<string> {
  await ProfileStorage.initialize(context);
  const payload: BackupPayload = {
    version: 2,
    exportedAt: Date.now(),
    settings: await ProfileStorage.settings(),
    profiles: await ProfileStorage.profiles()
  };
  if (includeSubscriptions) {
    payload.subscriptions = await listSubs();
  }
  return JSON.stringify(payload);
}

export async function importBackup(context: common.Context, text: string): Promise<string> {
  await ProfileStorage.initialize(context);
  let obj: BackupPayload;
  try {
    obj = JSON.parse(text) as BackupPayload;
  } catch (e) {
    throw new Error('备份内容不是有效 JSON');
  }
  if (obj === null || obj === undefined || !Array.isArray(obj.profiles)
    || obj.settings === undefined || obj.settings === null) {
    throw new Error('备份内容格式不正确');
  }
  await ProfileStorage.saveSettings(obj.settings);
  await ProfileStorage.saveProfiles(obj.profiles);
  // v1 backups do not contain subscriptions.  In that case leave the
  // existing subscription list untouched; this preserves old restore
  // semantics and avoids silently deleting metadata.  v2 only replaces the
  // list when an explicit array is present.
  if (obj.subscriptions !== undefined) {
    if (!Array.isArray(obj.subscriptions)) {
      throw new Error('备份中的订阅列表格式不正确');
    }
    const normalized: Array<SubInfo> = [];
    for (const source of obj.subscriptions) {
      if (source === undefined || source === null || typeof source !== 'object') {
        continue;
      }
      const item = new SubInfo();
      const typed = source as SubInfo;
      item.url = typed.url;
      item.name = typed.name;
      item.lastUpdate = typed.lastUpdate;
      item.upload = typed.upload;
      item.download = typed.download;
      item.total = typed.total;
      item.expire = typed.expire;
      item.updateIntervalMs = typed.updateIntervalMs;
      item.consecutiveFailures = typed.consecutiveFailures;
      item.paused = typed.paused;
      item.lastError = typed.lastError;
      if (item.url.trim().length > 0) {
        normalized.push(item);
      }
    }
    await saveSubs(normalized);
  }
  const subSuffix = obj.subscriptions === undefined ? '' : `、${obj.subscriptions.length} 个订阅`;
  return `已恢复 ${obj.profiles.length} 个节点和全部设置${subSuffix}`;
}
