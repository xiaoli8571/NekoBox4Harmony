import { LANGUAGE_EN_US, normalizeLanguage } from '../common/manager/AppearanceManager';

/** 轻量界面文案表。未迁移的旧页面仍保留中文硬编码，未知 key 会回退中文。 */
const ZH: Record<string, string> = {
  'settings': '设置',
  'appearance': '外观与语言',
  'theme': '主题',
  'language': '语言',
  'system': '跟随系统',
  'light': '浅色',
  'dark': '深色',
  'chinese': '中文',
  'english': 'English',
  'saved': '已保存',
  'applyAfterRestart': '外观/语言将在页面重建后完全生效',
  'tools': '工具',
  'traffic': '流量',
  'diagnostics': '诊断',
  'about': '关于',
  'logs': '日志',
  'connections': '连接',
  'appList': '分应用代理',
  'search': '搜索',
  'export': '导出',
  'clear': '清空',
  'exportSuccess': '日志已导出',
  'exportFailed': '导出失败',
  'exportFallbackCopied': '无法保存文件,已复制当前筛选日志到剪贴板',
  'back': '返回',
  'refresh': '刷新',
  'copySuccess': '已复制到剪贴板',
  'noData': '暂无数据'
};

const EN: Record<string, string> = {
  'settings': 'Settings',
  'appearance': 'Appearance & language',
  'theme': 'Theme',
  'language': 'Language',
  'system': 'System',
  'light': 'Light',
  'dark': 'Dark',
  'chinese': '中文',
  'english': 'English',
  'saved': 'Saved',
  'applyAfterRestart': 'The change is fully applied after the page is recreated',
  'tools': 'Tools',
  'traffic': 'Traffic',
  'diagnostics': 'Diagnostics',
  'about': 'About',
  'logs': 'Logs',
  'connections': 'Connections',
  'appList': 'Per-app proxy',
  'search': 'Search',
  'export': 'Export',
  'clear': 'Clear',
  'exportSuccess': 'Log exported',
  'exportFailed': 'Export failed',
  'exportFallbackCopied': 'Could not save file; filtered logs copied to clipboard',
  'back': 'Back',
  'refresh': 'Refresh',
  'copySuccess': 'Copied to clipboard',
  'noData': 'No data'
};

export function currentLanguage(): string {
  const value = AppStorage.get<string>('uiLanguage') ?? 'zh-CN';
  return normalizeLanguage(value);
}

export function isEnglish(language: string = currentLanguage()): boolean {
  return normalizeLanguage(language) === LANGUAGE_EN_US;
}

export function t(key: string, language: string = currentLanguage()): string {
  const table = isEnglish(language) ? EN : ZH;
  const value = table[key];
  if (value !== undefined) {
    return value;
  }
  return ZH[key] ?? key;
}
