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
  static testProxy(tag: string, url: string, timeoutMs: number, expectStatus: string = '2xx'): Promise<string> {
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
}
