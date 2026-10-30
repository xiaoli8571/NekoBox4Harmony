/**
 * 主题强调色(对齐 OwnBox ColorPickerPreference 的预设色板)。
 *
 * 边界:
 *  - 纯前端,不参与内核配置(改色不会触发重连);
 *  - HarmonyOS 的资源色(`$r('app.color.*')`)无法运行时替换,所以这里只覆盖
 *    **强调件**:首页电源键核心/光环、底栏选中项、面板/工具页主按钮。
 *    其余以资源色为准 —— 这是与 OwnBox「全局换色」的有意差异(见交付说明)。
 */
export class ThemeAccents {
  static readonly BLUE: string = 'blue';
  static readonly GREEN: string = 'green';
  static readonly PURPLE: string = 'purple';
  static readonly ORANGE: string = 'orange';
  static readonly RED: string = 'red';
  static readonly OPTIONS: Array<string> = ['blue', 'green', 'purple', 'orange', 'red'];
  static readonly DEFAULT_HEX: string = '#3B7DFF';
}

/** 预设名 → 十六进制色(未知值回落默认蓝,保证永远有合法颜色) */
export function accentHexFor(name: string): string {
  switch (name) {
    case ThemeAccents.GREEN: return '#2FBF71';
    case ThemeAccents.PURPLE: return '#8B5CF6';
    case ThemeAccents.ORANGE: return '#F59E0B';
    case ThemeAccents.RED: return '#EF4444';
    case ThemeAccents.BLUE: return ThemeAccents.DEFAULT_HEX;
    default: return ThemeAccents.DEFAULT_HEX;
  }
}

/** 归一化:任何脏值都收敛到预设集合内 */
export function normalizeAccent(name: string): string {
  return ThemeAccents.OPTIONS.indexOf(name) >= 0 ? name : ThemeAccents.BLUE;
}

/** 发布到 AppStorage(EntryAbility 启动与设置页保存时各调一次) */
export function publishAccent(name: string): void {
  /* 2026-10-26 用户决定下线强调色自定义:与 OwnBox 一致,主色固定并只随深浅色变化。
     旧设置/旧备份里的 purple|orange|red 等值一律收敛到默认蓝,避免"没有入口却还在生效"。 */
  const fixed: string = ThemeAccents.BLUE;
  AppStorage.setOrCreate('themeAccent', normalizeAccent(fixed));
  AppStorage.setOrCreate('themeAccentHex', accentHexFor(fixed));
}
