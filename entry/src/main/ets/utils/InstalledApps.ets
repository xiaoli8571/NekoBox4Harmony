/**
 * 已安装应用枚举(对齐 OwnBox AppListActivity):
 *   OwnBox 的分应用页直接列出「已安装应用 + 图标 + 搜索框」,用户勾选即可;
 *   鸿蒙旧实现只有 12 个预置项 + 手输包名,普通用户不知道该填什么。
 *
 * 平台口径(API 26,已核对 SDK d.ts):
 *  - `bundleManager.getInstalledBundleList(GET_BUNDLE_INFO_WITH_APPLICATION)`
 *    权限为 `GET_BUNDLE_INFO_PRIVILEGED or GET_BUNDLE_INFO`;本应用已在 module.json5
 *    声明 `ohos.permission.GET_BUNDLE_INFO`(normal 级,安装即授予,无需弹窗)。
 *  - `ApplicationInfo.label` 是**已解析**的应用名(API 20 起未配置 label 才为空),
 *    对第三方应用同样可读;为空时回退包名,不显示空行。
 *  - 图标不做跨应用资源解析(iconId 属于对方资源表,本进程 resourceManager 解析不到),
 *    界面用首字母色块代替;这比 OwnBox 的图标列表弱一点,但比「手输包名」强得多。
 *
 * 任何失败(权限被收紧、系统裁剪接口)都只返回 error 文本,由界面提示并保留
 * 预置列表 + 手动输入通道,绝不因为枚举失败让分应用功能不可用。
 */

import bundleManager from '@ohos.bundle.bundleManager';

export class InstalledApp {
  bundleName: string = '';
  label: string = '';
  systemApp: boolean = false;

  constructor(bundleName: string, label: string, systemApp: boolean) {
    this.bundleName = bundleName;
    this.label = label;
    this.systemApp = systemApp;
  }
}

export class InstalledAppResult {
  apps: Array<InstalledApp> = [];
  error: string = '';
}

/** 枚举已安装应用;includeSystem=false 时过滤系统应用(默认只看用户应用,和 OwnBox 一致)。 */
export async function listInstalledApps(selfBundleName: string,
  includeSystem: boolean): Promise<InstalledAppResult> {
  const result = new InstalledAppResult();
  try {
    const flags: number = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
    const bundles: Array<bundleManager.BundleInfo> = await bundleManager.getInstalledBundleList(flags);
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < bundles.length; i++) {
      const info: bundleManager.BundleInfo = bundles[i];
      const bundleName: string = info.name === undefined ? '' : info.name;
      if (bundleName.length === 0 || bundleName === selfBundleName || seen.has(bundleName)) {
        continue;
      }
      seen.add(bundleName);
      const app: bundleManager.ApplicationInfo | undefined = info.appInfo;
      if (app === undefined || app.enabled === false) {
        continue;
      }
      const systemApp: boolean = app.systemApp === true;
      if (systemApp && !includeSystem) {
        continue;
      }
      const rawLabel: string = app.label === undefined ? '' : app.label.trim();
      const label: string = rawLabel.length > 0 ? rawLabel : bundleName;
      result.apps.push(new InstalledApp(bundleName, label, systemApp));
    }
    // 用户应用在前、系统应用在后;同组按名称本地化排序(中文按拼音)
    result.apps.sort((a: InstalledApp, b: InstalledApp): number => {
      if (a.systemApp !== b.systemApp) {
        return a.systemApp ? 1 : -1;
      }
      return a.label.localeCompare(b.label, 'zh-Hans');
    });
  } catch (e) {
    result.error = e instanceof Error ? e.message : `${e}`;
  }
  return result;
}

/** 搜索过滤(名称/包名,忽略大小写),给界面用;空查询返回原列表。 */
export function filterInstalledApps(list: Array<InstalledApp>, query: string): Array<InstalledApp> {
  const q: string = query.trim().toLowerCase();
  if (q.length === 0) {
    return list;
  }
  return list.filter((app: InstalledApp) =>
    app.label.toLowerCase().includes(q) || app.bundleName.toLowerCase().includes(q));
}
