import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import nativeCore from 'libentry.so';
import { LogStore } from '../model/Store';

/**
 * 内核管理(sing-box 以 c-shared 库随 HAP 安装,进程内调用,无 exec):
 *  - writeConfigFile: 写 sing-box 配置
 *  - resetLogFile / 日志文件: 内核日志走 log.output 文件,UI/扩展轮询读取
 *  - startCore / stopCore: dlopen 调用 libsingbox.so 的 CGo 导出
 */

const CORE_DIR = 'core';

export class CoreManager {
  static coreDir(context: common.Context): string {
    return `${context.filesDir}/${CORE_DIR}`;
  }

  static writeConfigFile(context: common.Context, configJson: string): string {
    const coreDir = CoreManager.coreDir(context);
    if (!fs.accessSync(coreDir)) {
      fs.mkdirSync(coreDir, true);
    }
    const configPath = `${coreDir}/config.json`;
    const file = fs.openSync(configPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, configJson);
    } finally {
      fs.closeSync(file);
    }
    return configPath;
  }

  static logFilePath(context: common.Context): string {
    return `${CoreManager.coreDir(context)}/singbox.log`;
  }

  /** 启动前清空内核日志文件,返回日志路径 */
  static resetLogFile(context: common.Context): string {
    const path = CoreManager.logFilePath(context);
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.closeSync(file);
    } catch (e) {
      // ignore
    }
    return path;
  }

  /** 进程内启动内核;onResult(err) err 为空串表示成功 */
  static startCore(configPath: string, tunFd: number, onResult: (err: string) => void): void {
    nativeCore.startCoreNative(configPath, tunFd, onResult);
  }

  static stopCore(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      nativeCore.stopCoreNative((err: string) => {
        if (err !== undefined && err.length > 0) {
          LogStore.addLog(`[app] 内核停止报错: ${err}`);
          reject(new Error(err));
          return;
        }
        resolve();
      });
    });
  }

  static isCoreRunning(): boolean {
    return nativeCore.isCoreRunning();
  }

  // ---- URL 测速(独立测试会话,跑在 UI 进程内,不影响 VPN 主实例) ----

  static writeTestConfigFile(context: common.Context, configJson: string): string {
    const coreDir = CoreManager.coreDir(context);
    if (!fs.accessSync(coreDir)) {
      fs.mkdirSync(coreDir, true);
    }
    const configPath = `${coreDir}/test.json`;
    const file = fs.openSync(configPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, configJson);
    } finally {
      fs.closeSync(file);
    }
    return configPath;
  }

  static testLogFilePath(context: common.Context): string {
    return `${CoreManager.coreDir(context)}/test.log`;
  }

  /**
   * 启动测速会话;resolve '' 成功,否则错误文本。
   * bindIfname 非空时测速出站绑定该物理网卡(SO_BINDTODEVICE),使测速
   * 流量绕开正在运行的隧道,直接测到节点本身。
   */
  static testStart(configPath: string, bindIfname: string = ''): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.testStartNative(configPath, bindIfname, (err: string) => {
        resolve(err);
      });
    });
  }

  /**
   * 对单个出站 tag 做真连接测试;resolve "ms" 或 "err:..."。
   * expectStatus: '2xx' = 仅 2xx 判定通过(默认,防"假绿");'any' = 任意响应码都算通。
   */
  static testProxy(tag: string, url: string, timeoutMs: number, expectStatus: string = 'any'): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.testProxyNative(tag, url, timeoutMs, expectStatus, (res: string) => {
        resolve(res);
      });
    });
  }

  static testStop(): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.testStopNative((err: string) => {
        resolve(err);
      });
    });
  }

  /**
   * 测速能力探测。libsingbox.so 是随仓库分发的冻结产物,测速导出有新旧两代签名:
   *   'v2'     —— 内核支持响应状态判定 + 测速绕过隧道;
   *   'legacy' —— 跑的是旧导出,这两项静默失效(调用方需如实告知用户)。
   * 空串表示 .so 尚未加载成功。
   */
  static testCaps(): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.testCapsNative((res: string) => {
        resolve(res);
      });
    });
  }

  // ---- K1 无副作用校验(内核只解析,不启动实例、不碰环境变量、不写文件) ----

  /**
   * 配置 schema 校验(内核层)。返回:
   *   ''            —— 通过
   *   'err:...'     —— 内核原文错误(如 server_port 类型错误)
   *   'unsupported' —— 当前 .so 没有 CGoCheckConfigV1(旧冻结内核),
   *                    调用方**不得**据此标"已验证"(docs/p0-baseline §2.2)
   */
  static checkConfig(configPath: string): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.checkConfigNative(configPath, (res: string) => {
        resolve(res);
      });
    });
  }

  /**
   * 本地 .srs 规则集内容校验(SRS 魔数 + 版本 + 完整规则解析)。
   * 返回值语义同 checkConfig('' 通过 / 'err:...' / 'unsupported')。
   */
  static validateSrs(path: string): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.validateSrsNative(path, (res: string) => {
        resolve(res);
      });
    });
  }

  // ---- K2 会话化测速(V3,带 sessionId:取消/迟到回调防护;内核无 V3 导出
  //      时以下方法一律回退 'unsupported',调用方不得当成成功) ----

  /**
   * 以 sessionId 建立独立测速会话。返回:
   *   ''                          —— 成功
   *   'session <id> already active' —— 同 id 已 active/starting
   *   'another test session <id> is active' —— 其他会话在跑(串行语义)
   *   'session <id> is stopping'  —— 有会话正在关闭
   *   'session <id> cancelled during start' —— 该 id 已被 stop 过(墓碑),
   *     或 stop 在创建期间到达(新实例已立即关闭)
   */
  static testStartV3(sessionId: string, configPath: string, bindIfname: string = ''): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.testStartNativeV3(sessionId, configPath, bindIfname, (res: string) => {
        resolve(res);
      });
    });
  }

  /**
   * 只在该 sessionId 会话内探测;resolve "ms" 或 "err:..."(与 V2 同构)。
   * 会话不存在/已关闭 → 'err:session <id> not found'。
   */
  static testProxyV3(sessionId: string, tag: string, url: string, timeoutMs: number,
    expectStatus: string = 'any'): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.testProxyNativeV3(sessionId, tag, url, timeoutMs, expectStatus, (res: string) => {
        resolve(res);
      });
    });
  }

  /**
   * 停止并关闭该会话;resolve '' 时实例必已关闭(确认语义)。
   * 未知/已停止的 sessionId 也 resolve ''(幂等)+ 内核侧记墓碑。
   */
  static testStopV3(sessionId: string): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.testStopNativeV3(sessionId, (res: string) => {
        resolve(res);
      });
    });
  }

  /**
   * 会话快照 JSON(resolve)或 '' = 未知会话;resolve 'unsupported' = 内核无 V3。
   * JSON 形状:{"sessionId","state":"starting|active|stopping|closed",
   * "startedAt":0,"probes":0,"lastTag":"","tombstone":true|false}
   */
  static testSessionInfoV3(sessionId: string): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.testSessionInfoNativeV3(sessionId, (res: string) => {
        resolve(res);
      });
    });
  }

  /**
   * 当前 active 的 sessionId(逗号分隔,串行语义下最多一个);'' = 无活动会话。
   */
  static testActiveSessions(): Promise<string> {
    return new Promise<string>((resolve) => {
      nativeCore.testActiveSessionsNative((res: string) => {
        resolve(res);
      });
    });
  }
}
