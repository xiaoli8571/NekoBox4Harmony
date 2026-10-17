import { motion } from '@kit.MultimodalAwarenessKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 智感握姿(对齐 RzdSchool 的 RecordBall 做法,官方最佳实践 bpta-smart-reach):
 *  · `motion.on('operatingHandChanged')`(API15,交互手)**优先**;
 *  · `holdingHandChanged`(API20,握持手)与 `getRecentOperatingHandStatus()` 兜底
 *    (交互手未识别出来之前先按握持手摆);
 *  · 识别不出/系统能力缺失 ⇒ 永远保持右手侧(与改造前的布局完全一致,不做猜测)。
 *
 * 结果写进 AppStorage,页面用 `@StorageLink(HAND_SIDE_KEY)` 订阅后自己决定镜像:
 *  · 首页 FAB(连接/断开键)移到交互手那一侧;
 *  · 抽屉从交互手那一侧滑出;
 *  · 底栏/常驻按钮不再压在交互手拇指够不到的另一端。
 *
 * 权限:module.json5 里声明 `ohos.permission.DETECT_GESTURE`(system_grant / normal / since 20,装上即用无弹窗)。
 * 排查日志关键字:`NekoBox-Reach`(hdc shell hilog | grep NekoBox-Reach)。
 */
export const HAND_SIDE_KEY: string = 'uiHandSide';
export const HAND_SUPPORTED_KEY: string = 'uiHandSupported';
export const HAND_SIDE_RIGHT: string = 'right';
export const HAND_SIDE_LEFT: string = 'left';

const DOMAIN: number = 0x4E42;
const TAG: string = 'NekoBox-Reach';

class HandednessTracker {
  private started: boolean = false;
  private operatingKnown: boolean = false;
  private side: string = HAND_SIDE_RIGHT;

  private readonly handCb: Callback<motion.OperatingHandStatus> = (status: motion.OperatingHandStatus): void => {
    if (status === motion.OperatingHandStatus.LEFT_HAND_OPERATED) {
      this.operatingKnown = true;
      this.apply(HAND_SIDE_LEFT, 'operating');
    } else if (status === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) {
      this.operatingKnown = true;
      this.apply(HAND_SIDE_RIGHT, 'operating');
    }
  };

  private readonly holdCb: Callback<motion.HoldingHandStatus> = (status: motion.HoldingHandStatus): void => {
    if (this.operatingKnown) {
      return;
    }
    if (status === motion.HoldingHandStatus.LEFT_HAND_HELD) {
      this.apply(HAND_SIDE_LEFT, 'holding');
    } else if (status === motion.HoldingHandStatus.RIGHT_HAND_HELD) {
      this.apply(HAND_SIDE_RIGHT, 'holding');
    }
  };

  private apply(side: string, source: string): void {
    if (this.side === side) {
      return;
    }
    this.side = side;
    AppStorage.setOrCreate(HAND_SIDE_KEY, side);
    hilog.info(DOMAIN, TAG, 'hand side=%{public}s source=%{public}s', side, source);
  }

  /**
   * 幂等:只在第一次真正订阅,App 生命周期内只保留一份监听。
   *
   * ★ 为什么整段包在 `setTimeout(..., 0)` 里(真机踩过:卡开屏页):
   *   `getRecentOperatingHandStatus()` 是**同步**接口,`motion.on()` 也要走系统服务;
   *   放在启动关键路径(onCreate / 首帧构建)上,一旦该服务不可用/未就绪就会**阻塞主线程**,
   *   表现就是"永远停在开屏页、第一帧画不出来"。这里挪到事件队列末尾 —— 先让首页画出来,再识别握姿。
   */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    AppStorage.setOrCreate(HAND_SIDE_KEY, HAND_SIDE_RIGHT);
    setTimeout(() => {
      this.subscribe();
    }, 0);
  }

  private subscribe(): void {
    if (!canIUse('SystemCapability.MultimodalAwareness.Motion')) {
      AppStorage.setOrCreate(HAND_SUPPORTED_KEY, false);
      hilog.info(DOMAIN, TAG, 'motion syscap unavailable, keep right side');
      return;
    }
    AppStorage.setOrCreate(HAND_SUPPORTED_KEY, true);
    try {
      const recent: motion.OperatingHandStatus = motion.getRecentOperatingHandStatus();
      if (recent === motion.OperatingHandStatus.LEFT_HAND_OPERATED) {
        this.operatingKnown = true;
        this.apply(HAND_SIDE_LEFT, 'recent');
      } else if (recent === motion.OperatingHandStatus.RIGHT_HAND_OPERATED) {
        this.operatingKnown = true;
        this.apply(HAND_SIDE_RIGHT, 'recent');
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getRecentOperatingHandStatus failed: %{public}s', `${(e as Error).message}`);
    }
    try {
      motion.on('operatingHandChanged', this.handCb);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'on operatingHandChanged failed: %{public}s', `${(e as Error).message}`);
    }
    try {
      motion.on('holdingHandChanged', this.holdCb);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'on holdingHandChanged failed: %{public}s', `${(e as Error).message}`);
    }
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    try {
      motion.off('operatingHandChanged', this.handCb);
    } catch (e) {
      // 未订阅成功时 off 会抛,忽略
    }
    try {
      motion.off('holdingHandChanged', this.holdCb);
    } catch (e) {
      // 同上
    }
  }

  /** 当前侧(供非 UI 逻辑查询;UI 一律走 @StorageLink 订阅) */
  currentSide(): string {
    return this.side;
  }
}

export const handedness: HandednessTracker = new HandednessTracker();
