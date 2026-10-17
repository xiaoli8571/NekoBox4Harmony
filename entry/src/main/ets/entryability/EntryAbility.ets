import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import window from '@ohos.window';
import { UiSpec } from '../common/UiSpec';
import { handedness } from '../common/Handedness';
import common from '@ohos.app.ability.common';
import notificationManager from '@ohos.notificationManager';
import BusinessError from '@ohos.base';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { initStore, loadSettings, LogStore } from '../model/Store';
import { subscribeVpnEvents, unsubscribeVpnEvents, publishAppForeground } from '../core/VpnIpc';
import { VpnService } from '../core/VpnService';
import { needAutoUpdate, updateSubscription, markSubSuccess, markSubFailure, setAppContext } from '../core/Subscriptions';
import { subErrorText } from '../utils/Subscription';

/**
 * 窗口/系统栏底色的**显式**取值,与 `resources/{base,dark}/element/color.json` 的 `bg_page` 逐字一致。
 *
 * 为什么不直接读资源:`setColorMode()` 是异步生效的,而 `onWindowStageCreate` 里
 * `getMainWindow().then(...)` 完全可能**先于**它跑到 —— 那时 `getColorSync($r('app.color.*'))`
 * 读到的还是**上一个色彩模式**的值。于是夜间模式下会出现"内容已经是深色、状态栏与底部却是一块白色"
 * (真机截图实测:内容 #121318、状态栏与底部条 #F6F7FB)。所以底色按判定结果走常量,
 * 读到的资源色只用来**交叉验证**(不一致就记一条日志并继续用常量)。
 */
const WINDOW_BG_LIGHT: string = '#FAFAF9'; // = app.color.bg_page(base)
const WINDOW_BG_DARK: string = '#101318';  // = app.color.bg_page(dark)


export default class EntryAbility extends UIAbility {
  private backgroundUpdating: boolean = false;
  private mainWindow?: window.Window;
  /** 当前生效的深浅色判定结果(由 applyAppearance / onConfigurationUpdate 写入,供窗口/系统栏改色使用) */
  private darkTheme: boolean = false;
  /** 已经**下发过**的目标色彩模式(去重用的真源)。
   *  ⚠️ 不要拿 `this.context.config.colorMode` 当去重依据:那读的是"已解析"的档位
   *  (跟随系统时是 DARK/LIGHT,永远不等于 NOT_SET),用它比对会让 setColorMode 每次都下发 ⇒
   *  setColorMode → onConfigurationUpdate → applyAppearance → setColorMode …**自激死循环**
   *  (真机现象:卡在开屏页,第一帧永远画不出来)。 */
  private desiredColorMode: ConfigurationConstant.ColorMode | undefined = undefined;
  /** 缓存外观偏好('system' | 'light' | 'dark'),供配置回调同步判定用(不读存储、不做异步 IO) */
  private appearancePref: string = 'system';
  /** 防重入:applyAppearance 里有 await,配置回调与前台回调可能叠在一起 */
  private appearanceApplying: boolean = false;
  private readonly windowSizeListener = (size: window.Size): void => {
    this.publishBreakpoint(size.width);
  };

  private publishBreakpoint(width: number): void {
    const breakpoint = width < UiSpec.BREAKPOINT_MEDIUM
      ? 'compact'
      : (width < UiSpec.BREAKPOINT_LARGE ? 'medium' : 'large');
    AppStorage.setOrCreate('uiBreakpoint', breakpoint);
  }

  private async updateDueSubscriptionsInBackground(): Promise<void> {
    if (this.backgroundUpdating) {
      return;
    }
    this.backgroundUpdating = true;
    let backgroundRunning: boolean = false;
    try {
      await initStore(this.context);
      setAppContext(this.context);
      const settings = await loadSettings();
      if (!settings.autoUpdateSubs) {
        return;
      }
      const due = await needAutoUpdate();
      if (due.length === 0) {
        return;
      }
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: 'EntryAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1003,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent);
      backgroundRunning = true;
      for (const sub of due) {
        try {
          const result = await updateSubscription(sub.url);
          await markSubSuccess(sub.url);
          LogStore.addLog(`[app] 后台更新订阅 ${sub.name}:新增 ${result.added},移除 ${result.removed}`);
        } catch (e) {
          await markSubFailure(sub.url);
          LogStore.addLog(`[app] 后台更新订阅 ${sub.name} 失败: ${subErrorText(e as Object)}`);
        }
      }
    } catch (e) {
      LogStore.addLog(`[app] 后台订阅更新任务失败: ${e}`);
    } finally {
      if (backgroundRunning) {
        try {
          await backgroundTaskManager.stopBackgroundRunning(this.context);
        } catch (e) {
          LogStore.addLog(`[app] 释放后台订阅任务失败: ${e}`);
        }
      }
      this.backgroundUpdating = false;
    }
  }

  private rgbHex(color: number): string {
    const hex = (value: number): string => value.toString(16).padStart(2, '0').toUpperCase();
    return `#${hex((color >> 16) & 0xFF)}${hex((color >> 8) & 0xFF)}${hex(color & 0xFF)}`;
  }

  private isDarkColor(color: number): boolean {
    const red = (color >> 16) & 0xFF;
    const green = (color >> 8) & 0xFF;
    const blue = color & 0xFF;
    return (red * 299 + green * 587 + blue * 114) / 1000 < 128;
  }

  /**
   * 当前是否深色:外观偏好(强制档)优先,否则看**已经生效**的配置色模式(跟随系统)。
   * @param appearance     'system' | 'light' | 'dark'(由调用方给出,避免在这里读存储)
   * @param configColorMode 配置回调刚送来的那个色模式(比 `this.context.config` 更"新鲜",
   *        回调时刻 context 上那一份可能还没刷新 ⇒ 优先用它)。
   */
  private resolveDark(appearance: string, configColorMode?: ConfigurationConstant.ColorMode): boolean {
    if (appearance === 'dark') {
      return true;
    }
    if (appearance === 'light') {
      return false;
    }
    const mode: ConfigurationConstant.ColorMode | undefined = configColorMode ?? this.context.config.colorMode;
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      return true;
    }
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      return false;
    }
    // 跟随系统且配置里还没解析出具体档位 ⇒ 用当前生效的底色亮度兜底
    try {
      return this.isDarkColor(this.context.resourceManager.getColorSync($r('app.color.bg_page')));
    } catch (e) {
      return false;
    }
  }

  /** 同步窗口底色与系统栏颜色(状态栏 + 底部导航栏)。**幂等**,配置变化时会再调一次。 */
  private async syncWindowAppearance(win?: window.Window): Promise<void> {
    const target = win ?? this.mainWindow;
    if (target === undefined) {
      return;
    }
    try {
      const dark = this.darkTheme;
      let background = dark ? WINDOW_BG_DARK : WINDOW_BG_LIGHT;
      try {
        const resolved = this.context.resourceManager.getColorSync($r('app.color.bg_page'));
        if (this.isDarkColor(resolved) === dark) {
          background = this.rgbHex(resolved);
        } else {
          LogStore.addLog(`[app] 主题色与色彩模式不一致(资源=${this.rgbHex(resolved)}, dark=${dark}),按常量兜底`);
        }
      } catch (e) {
        // 读资源失败不影响:上面已有常量兜底
      }
      const contentColor = dark ? UiSpec.STATUS_BAR_CONTENT_DARK_BG : UiSpec.STATUS_BAR_CONTENT_LIGHT_BG;
      target.setWindowBackgroundColor(background);
      /* ★★★ 系统栏**必须透明**（用户 2026-10-17 的最终定论）：
         原来这里给 `statusBarColor` 写的是**不透明的页面底色** ⇒ 系统在窗口最上面画了一条死色的状态栏，
         任何画进状态栏区域的内容（HDS 标题栏材质、列表条目）都被它整条盖住。
         表现就是"状态栏像单独画了一条""后台卡片里能看到整块顶部、进 App 就没了"
         （后台卡片没有系统状态栏覆盖，所以顶部那一行完整可见）。
         ⇒ 透明（#00000000）之后，状态栏区域由页面自己绘制：HDS 标题栏的渐变模糊/沉浸光感铺进去，
            列表条目也能从时钟后面滚过。文字/图标颜色仍由 `statusBarContentColor` 按深浅色切换。 */
      /* 深色下状态栏用主题底色**实色**（真机 2026-10-17：透明 '#00000000' 在深色主题下
         状态栏仍渲染成白色 —— 要么系统把全透明当无效值回退白底，要么 HDS 沉浸光感材质
         在深色下渲染成浅色玻璃透出来），浅色保持透明（浅色下白条与页面底色同色不可见，
         且保留"内容从时钟后面滚过"的沉浸效果）。
         代价：深色下状态栏区域由系统实色绘制，内容不再钻入 —— 但深浅色跟随主题。 */
      target.setWindowSystemBarProperties({
        statusBarColor: dark ? background : '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      });
      LogStore.addLog(`[app] 窗口外观: bg=${background} dark=${dark}`);
    } catch (e) {
      LogStore.addLog(`[app] 同步窗口主题失败: ${e}`);
    }
  }

  private async applyAppearance(configColorMode?: ConfigurationConstant.ColorMode): Promise<void> {
    if (this.appearanceApplying) {
      return;
    }
    this.appearanceApplying = true;
    try {
      await initStore(this.context);
      const settings = await loadSettings();
      this.appearancePref = settings.appearance;
      const target = settings.appearance === 'dark'
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : (settings.appearance === 'light'
          ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
          : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      /* ★ 只在"目标档位真的变了"时下发(c.f. desiredColorMode 的注释:比 config.colorMode 会自激) */
      if (this.desiredColorMode !== target) {
        this.desiredColorMode = target;
        this.context.setColorMode(target);
      }
      this.darkTheme = this.resolveDark(settings.appearance, configColorMode);
      await this.syncWindowAppearance();
    } catch (e) {
      LogStore.addLog(`[app] 应用主题失败: ${e}`);
    } finally {
      this.appearanceApplying = false;
    }
  }

  private handleAction(want: Want): void {
    if (want.parameters === undefined || `${want.parameters['action']}` !== 'disconnect') {
      return;
    }
    VpnService.disconnect(this.context).catch((e: Object) => {
      LogStore.addLog(`[app] 通知栏断开失败: ${e}`);
    });
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogStore.addLog('[app] NekoBox 启动');
    this.handleAction(want);
    this.applyAppearance();
    /* ⚠️ 智感握姿**不在这里**启动:它要走 motion 系统服务(含一次同步调用),
       放在 onCreate 会占住启动关键路径(服务异常时表现为卡在开屏页)。
       改到首页 `Index.aboutToAppear` 里启动,见 common/Handedness.ets 的注释。 */
    this.updateDueSubscriptionsInBackground();
    // 请求通知权限(常驻通知用),用户拒绝也不影响功能
    try {
      notificationManager.requestEnableNotification(this.context, (err: BusinessError) => {
        if (err && err.code !== 0) {
          LogStore.addLog(`[app] 通知权限未授予: ${err.code}`);
        }
      });
    } catch (e) {
      // ignore
    }
    // 接收 :vpn 扩展进程发来的日志与状态
    subscribeVpnEvents((line: string) => {
      LogStore.appendRemote(line);
    }, (status: string, running: boolean, profileId: string) => {
      AppStorage.setOrCreate('vpnRunning', running);
      AppStorage.setOrCreate('vpnStatus', status);
      AppStorage.setOrCreate('vpnRunningProfileId', profileId);
    }, (upSpeed: number, downSpeed: number, totalUp: number, totalDown: number) => {
      AppStorage.setOrCreate('vpnUpSpeed', upSpeed);
      AppStorage.setOrCreate('vpnDownSpeed', downSpeed);
      AppStorage.setOrCreate('vpnTotalUp', totalUp);
      AppStorage.setOrCreate('vpnTotalDown', totalDown);

      // CommonEvent 是瞬时事件，connected 状态回调偶尔可能丢失；流量事件来自已启动的
      // VPN 内核，可作为数据面已连接的可靠证据，及时修复 UI 一直转圈的问题。
      const status: string = AppStorage.get<string>('vpnStatus') ?? '';
      if ((status === 'connecting' || status === 'switching') &&
        (upSpeed > 0 || downSpeed > 0 || totalUp > 0 || totalDown > 0)) {
        const profileId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
        AppStorage.setOrCreate('vpnRunning', true);
        AppStorage.setOrCreate('vpnStatus', 'connected:running');
        if (profileId.length === 0) {
          LogStore.addLog('[app] connected 状态回调缺失，已根据 VPN 流量恢复连接状态');
        }
      }
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogStore.addLog('[app] 收到新的 Want');
    this.handleAction(want);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        return;
      }
      windowStage.getMainWindow().then((win: window.Window) => {
        this.mainWindow = win;
        // ★ 窗口级 layout-full-screen：列表/内容才能真正钻进状态栏与手势条（用户要求"内容延伸进状态栏"）。
        // 代价：所有页面自己让出安全区（主壳用自校准 + 顶栏 overlay；4 个 router 子页已各加 44vp 顶部让位）。
        win.setWindowLayoutFullScreen(true).catch((e: BusinessError) => {
          LogStore.addLog(`[app] 开启全屏布局失败: ${e}`);
        });
        this.publishBreakpoint(win.getWindowProperties().windowRect.width);
        win.on('windowSizeChange', this.windowSizeListener);
        // 拿到窗口后重放一次主题:onCreate 里的那次调用只设了色彩模式(那时还没有窗口),
        // 而这里必须**等 setColorMode 真正生效**再取底色 —— 见 WINDOW_BG_* 的注释。
        this.applyAppearance();
      }).catch((e: Object) => {
        LogStore.addLog(`[ui] 初始化窗口断点失败: ${e}`);
      });
    });
  }

  /**
   * 色彩模式变化(系统深浅色切换 / setColorMode 生效)时重放窗口外观。
   * ★ 这条是"夜间模式状态栏与底部一块白色"的兜底修复:两条改色路径(资源读取、系统栏下发)
   *   以前只在启动时跑一次,谁先谁后就决定了最终颜色;现在配置一变就重算,自愈。
   */
  /**
   * 色彩模式变化时**只重放窗口/系统栏颜色**:不调 setColorMode(会自激成死循环,真机表现为卡开屏)、
   * 不读存储、不做异步 IO —— 这条回调在 UI 主线程上,必须是最轻的同步动作。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    this.darkTheme = this.resolveDark(this.appearancePref, newConfig.colorMode);
    this.syncWindowAppearance();
  }

  onWindowStageDestroy(): void {
    if (this.mainWindow !== undefined) {
      this.mainWindow.off('windowSizeChange', this.windowSizeListener);
      this.mainWindow = undefined;
    }
  }

  onDestroy(): void {
    handedness.stop();
    unsubscribeVpnEvents();
  }

  onForeground(): void {
    this.applyAppearance();
    this.updateDueSubscriptionsInBackground();
    // 通知 VPN 扩展:应用回到前台(扩展据此执行「唤醒后重置连接」,对齐安卓 wakeResetConnections)
    publishAppForeground();
  }

  onBackground(): void {
    this.updateDueSubscriptionsInBackground();
  }
}
