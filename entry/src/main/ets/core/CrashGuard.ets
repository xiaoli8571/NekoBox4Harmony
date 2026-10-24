import hiAppEvent from '@ohos.hiviewdfx.hiAppEvent';
import common from '@ohos.app.ability.common';
import { initStore, readPrefString, writePrefString, LogStore } from '../model/Store';
import { encodeKillState, decodeKillState, killRecoveryAction } from './KeepAlivePolicy';

/**
 * CrashGuard.ets — 被杀自愈(2026-10-23,FlClash 同款思路,零权限,依据 docs/REA-FLCLASH-KEEPALIVE.md)。
 *
 * FlClash 的对应机制(逆向结论):`AppCrashWatcher` watch hiAppEvent 的 APP_KILLED / JsError /
 * CppCrash + GlobalState 持久化 run_state,启动时检测"上次异常退出"并自动重连。
 *
 * 本实现:
 *  1. VPN 启动时落盘 `1|profileId|ts`,显式断开时落盘 `0|…`——进程被杀后 Preferences 仍在;
 *  2. 启动时读回:若上次是"带着开着的 VPN 被杀"(alive=1)→ 消费标记,按设置直接重连或询问;
 *  3. 注册 hiAppEvent watcher(OS 域的 APP_KILLED / JS_ERROR / CPP_CRASH)仅用于日志取证,
 *     不参与决策(决策靠落盘标记,不依赖 watcher 是否送达)。
 */
const STATE_KEY: string = 'crash_guard_state_v1';

/** 恢复决策结果(ArkTS 不允许匿名对象类型,用显式类)。 */
export class RecoveryDecision {
  /** 'none' | 'reconnect' | 'prompt'(语义见 KeepAlivePolicy.killRecoveryAction) */
  action: string = 'none';
  profileId: string = '';

  constructor(action: string, profileId: string) {
    this.action = action;
    this.profileId = profileId;
  }
}

export class CrashGuard {
  private static loaded: boolean = false;
  /** init 的 Promise:页面(Index.aboutToAppear)可能在 init 的 await 链完成前就来取决策,
   *  没有它会出现"上次被杀却判定 none"的竞态(真机首启即可能命中)。 */
  private static initPromise: Promise<void> | null = null;
  private static killedLastRun: boolean = false;
  private static lastProfileId: string = '';
  private static watcherRegistered: boolean = false;

  /** EntryAbility.onCreate 调用;幂等(重复调用复用同一个 Promise)。 */
  static init(context: common.UIAbilityContext): Promise<void> {
    if (CrashGuard.initPromise === null) {
      CrashGuard.initPromise = CrashGuard.doInit(context);
    }
    return CrashGuard.initPromise;
  }

  private static async doInit(context: common.UIAbilityContext): Promise<void> {
    try {
      await initStore(context);
      const raw = await readPrefString(STATE_KEY, '');
      const state = decodeKillState(raw);
      CrashGuard.killedLastRun = state.alive;
      CrashGuard.lastProfileId = state.profileId;
      if (state.alive) {
        // 立即消费标记:无论本次启动后用户是否重连,下次启动都不应再判"被杀"
        await writePrefString(STATE_KEY, encodeKillState(false, state.profileId, Date.now()));
        LogStore.addLog(`[app] 检测到上次运行被系统回收(VPN 开着,profile=${state.profileId})`);
      }
      CrashGuard.loaded = true;
    } catch (e) {
      LogStore.addLog(`[app] 被杀自愈初始化失败(忽略): ${e}`);
    }
    CrashGuard.registerWatcher();
  }

  /** VPN 启动成功后调用:落盘"活着"。 */
  static async markVpnStarted(profileId: string): Promise<void> {
    if (profileId.length === 0) {
      return;
    }
    try {
      await writePrefString(STATE_KEY, encodeKillState(true, profileId, Date.now()));
    } catch (e) {
      LogStore.addLog(`[app] 写入被杀标记失败(忽略): ${e}`);
    }
  }

  /** 显式断开时调用:落盘"干净退出"。 */
  static async markVpnStopped(): Promise<void> {
    try {
      await writePrefString(STATE_KEY, encodeKillState(false, CrashGuard.lastProfileId, Date.now()));
    } catch (e) {
      LogStore.addLog(`[app] 写入干净退出标记失败(忽略): ${e}`);
    }
  }

  /** Index.aboutToAppear 用:等 init 真正完成再取决策(否则可能读到未加载的旧值)。 */
  static async ensureLoaded(): Promise<void> {
    if (CrashGuard.initPromise !== null) {
      try {
        await CrashGuard.initPromise;
      } catch (e) {
        // init 内部已记日志,这里只保证顺序
      }
    }
  }

  /**
   * 恢复决策(一次性):
   * 上次被杀 && 现在没连 && 有 profileId ⇒ 按"启动自动连接"设置直接重连或询问。
   */
  static recoveryDecision(vpnRunningNow: boolean, autoReconnect: boolean): RecoveryDecision {
    const action = killRecoveryAction(
      CrashGuard.killedLastRun, vpnRunningNow, CrashGuard.lastProfileId, autoReconnect);
    // 决策只做一次:无论走哪条,标记都已消费
    const profileId = CrashGuard.lastProfileId;
    CrashGuard.killedLastRun = false;
    return new RecoveryDecision(action, profileId);
  }

  /** 仅日志取证:系统杀进程/崩溃事件送达时记一条(FlClash 的 AppCrashWatcher 同款事件集)。 */
  private static registerWatcher(): void {
    if (CrashGuard.watcherRegistered) {
      return;
    }
    try {
      hiAppEvent.addWatcher({
        name: 'NekoBoxCrashWatcher',
        appEventFilters: [{
          domain: hiAppEvent.domain.OS,
          names: [hiAppEvent.event.APP_KILLED, hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE]
        }],
        onReceive: (domain: string, appEventGroups: Array<hiAppEvent.AppEventGroup>) => {
          for (const group of appEventGroups) {
            for (const info of group.appEventInfos) {
              LogStore.addLog(`[app] 系统事件 ${domain}/${info.name}(type=${info.eventType})`);
            }
          }
        }
      });
      CrashGuard.watcherRegistered = true;
      LogStore.addLog('[app] 崩溃/被杀事件 watcher 已注册(APP_KILLED/APP_CRASH/APP_FREEZE)');
    } catch (e) {
      // watcher 注册失败不影响自愈(决策靠落盘标记),仅记录
      LogStore.addLog(`[app] 崩溃事件 watcher 注册失败(忽略): ${e}`);
    }
  }
}
