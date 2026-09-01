import common from '@ohos.app.ability.common';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { AppSettings } from '../../model/Profile';

/**
 * 应用级外观偏好。系统 API 负责真正切换资源色彩/语言；AppStorage 只保存
 * 当前选择，供页面在重建时快速读取。所有调用都容错，低版本设备即使不
 * 支持某一项也不会影响 VPN 生命周期。
 */
export const THEME_SYSTEM: string = 'system';
export const THEME_LIGHT: string = 'light';
export const THEME_DARK: string = 'dark';

export const LANGUAGE_ZH_CN: string = 'zh-CN';
export const LANGUAGE_EN_US: string = 'en-US';

export function normalizeTheme(value: string): string {
  if (value === THEME_LIGHT || value === THEME_DARK) {
    return value;
  }
  return THEME_SYSTEM;
}

export function normalizeLanguage(value: string): string {
  return value === LANGUAGE_EN_US ? LANGUAGE_EN_US : LANGUAGE_ZH_CN;
}

/** 在窗口已创建后调用，以便 UIAbilityContext 的优先级规则生效。 */
export function applyAppearance(context: common.UIAbilityContext, settings: AppSettings): void {
  const theme = normalizeTheme(settings.theme);
  const language = normalizeLanguage(settings.language);
  settings.theme = theme;
  settings.language = language;
  AppStorage.setOrCreate('uiTheme', theme);
  AppStorage.setOrCreate('uiLanguage', language);
  try {
    let mode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (theme === THEME_LIGHT) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (theme === THEME_DARK) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    context.setColorMode(mode);
  } catch (e) {
    // 外观能力不可用时保留偏好，下一次窗口创建再尝试。
  }
  try {
    // setLanguage 属于 ApplicationContext，必须在主线程调用。
    context.getApplicationContext().setLanguage(language);
  } catch (e) {
    // 语言资源切换失败不影响当前页面或 VPN。
  }
}

export function themeLabel(theme: string, english: boolean = false): string {
  const value = normalizeTheme(theme);
  if (english) {
    if (value === THEME_LIGHT) return 'Light';
    if (value === THEME_DARK) return 'Dark';
    return 'System';
  }
  if (value === THEME_LIGHT) return '浅色';
  if (value === THEME_DARK) return '深色';
  return '跟随系统';
}

export function languageLabel(language: string): string {
  return normalizeLanguage(language) === LANGUAGE_EN_US ? 'English' : '中文';
}
