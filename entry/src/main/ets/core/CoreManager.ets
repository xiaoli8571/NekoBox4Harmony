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

  static stopCore(onResult?: (err: string) => void): void {
    nativeCore.stopCoreNative((err: string) => {
      if (err !== undefined && err.length > 0) {
        LogStore.addLog(`[app] 内核停止报错: ${err}`);
      }
      if (onResult !== undefined) {
        onResult(err);
      }
    });
  }

  static isCoreRunning(): boolean {
    return nativeCore.isCoreRunning();
  }
}
