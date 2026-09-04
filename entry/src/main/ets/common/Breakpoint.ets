export type UiBreakpoint = 'compact' | 'medium' | 'large';

/** U6 responsive breakpoint based on the window's shortest side in vp. */
export function resolveUiBreakpoint(shortestSideVp: number): UiBreakpoint {
  if (shortestSideVp >= 840) {
    return 'large';
  }
  if (shortestSideVp >= 600) {
    return 'medium';
  }
  return 'compact';
}
