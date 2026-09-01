import common from '@ohos.app.ability.common';
import { Profile, AppSettings } from '../../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadSettings, saveSettings } from '../../model/Store';

/** 节点与设置持久化门面；保持原 Preferences 格式，兼容旧版本数据。 */
export class ProfileStorage {
  static async initialize(context: common.Context): Promise<void> {
    await initStore(context);
  }

  static async profiles(): Promise<Array<Profile>> {
    const list = await loadProfiles();
    // 旧版本只有 subUrl；在门面层补齐分组元数据，避免迁移时改写
    // Preferences 格式或要求用户重新导入节点。
    for (const p of list) {
      normalizeGroup(p);
    }
    return list;
  }

  static async saveProfiles(profiles: Array<Profile>): Promise<void> {
    for (const p of profiles) {
      normalizeGroup(p);
    }
    await saveProfiles(profiles);
  }

  static async settings(): Promise<AppSettings> {
    return loadSettings();
  }

  static async saveSettings(settings: AppSettings): Promise<void> {
    await saveSettings(settings);
  }
}

function normalizeGroup(p: Profile): void {
  const source = p.subUrl.trim();
  if (source.length === 0) {
    if (p.groupId.length === 0) {
      p.groupId = 'manual';
    }
    if (p.groupName.length === 0) {
      p.groupName = '手动配置';
    }
    return;
  }
  if (p.groupId.length === 0) {
    p.groupId = `subscription:${source}`;
  }
  if (p.groupName.length === 0) {
    let host = source;
    const scheme = host.indexOf('://');
    if (scheme >= 0) {
      host = host.substring(scheme + 3);
    }
    const slash = host.indexOf('/');
    if (slash >= 0) {
      host = host.substring(0, slash);
    }
    p.groupName = host.length > 0 ? host : '订阅';
  }
}
