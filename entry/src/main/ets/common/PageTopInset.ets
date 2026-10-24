import window from '@ohos.window';
import common from '@ohos.app.ability.common';

/**
 * router 二级页的顶部让位(2026-10-24 真机用户反馈:分流→新建规则 顶部控件被状态栏盖住)。
 *
 * 这些页面是独立 @Entry 窗口(layout-full-screen 下内容从 y=0 起画),
 * 固定 44vp 在部分设备/字体缩放下不够。aboutToAppear 里现查系统避让区
 * (AvoidAreaType.TYPE_SYSTEM 的 topRect)高度 px→vp,加 8vp 呼吸;失败回落 44。
 */
export async function statusBarTopVp(context: common.Context, fallbackVp: number = 44): Promise<number> {
  try {
    const win = await window.getLastWindow(context);
    const area: window.AvoidArea = await win.getAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const px = area.topRect.height;
    if (px <= 0) {
      return fallbackVp;
    }
    const ui = win.getUIContext();
    const vp = Math.ceil(ui.px2vp(px)) + 8;
    return vp > 0 && vp < 200 ? vp : fallbackVp;
  } catch (e) {
    return fallbackVp;
  }
}
