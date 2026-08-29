import common from '@ohos.app.ability.common';
import { Profile, AppSettings } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadSettings, saveSettings } from '../model/Store';

/** 配置备份/恢复:把节点 + 设置序列化为 JSON 文本(放剪贴板/文件均可)。 */

interface BackupPayload {
  version: number;
  exportedAt: number;
  settings: AppSettings;
  profiles: Array<Profile>;
}

export async function exportBackup(context: common.Context): Promise<string> {
  await initStore(context);
  const payload: BackupPayload = {
    version: 1,
    exportedAt: Date.now(),
    settings: await loadSettings(),
    profiles: await loadProfiles()
  };
  return JSON.stringify(payload);
}

export async function importBackup(context: common.Context, text: string): Promise<string> {
  await initStore(context);
  const obj = JSON.parse(text) as BackupPayload;
  if (obj === null || obj.profiles === undefined || obj.settings === undefined) {
    throw new Error('备份内容格式不正确');
  }
  await saveSettings(obj.settings);
  await saveProfiles(obj.profiles);
  return `已恢复 ${obj.profiles.length} 个节点和全部设置`;
}
