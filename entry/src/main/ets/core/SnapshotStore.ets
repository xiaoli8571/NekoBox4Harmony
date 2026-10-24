import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';

/**
 * 配置快照的文件层(REDESIGN-PLAN-2026-10-23.md §14.3)。
 *
 * 平台现状(P0 调查)：全树没有 rename/fsync 的既有用法，只有 TRUNC 原地覆盖写。
 * 因此这里采用「临时文件 + fsync + 尽力 rename」：
 *  - rename 可用时接近原子替换；
 *  - rename 不可用(返回异常)时退化为原地覆盖，**调用方必须重读并复核 checksum**
 *    (§14.3-4 允许回退双槽 manifest+单调 revision，不允许把普通覆盖写冒充原子)。
 * 本类只做文件操作，不做业务判断，便于主机测试注入内存 FS。
 */

export class SnapshotStore {
  /** 应用私有目录下的配置快照目录(与 :vpn 扩展进程共享同一 filesDir)。 */
  static configDir(context: common.Context): string {
    return `${context.filesDir}/config`;
  }

  static ensureDir(dir: string): void {
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      // 已存在或并发创建:后续写入会暴露真实错误
    }
  }

  static exists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  static readText(path: string): string {
    return fs.readTextSync(path);
  }

  static removeFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      // 清理失败不阻断主流程(GC 尽力而为)
    }
  }

  /** 列出目录下以 prefix 开头的文件名(不含路径)。 */
  static listFiles(dir: string, prefix: string): Array<string> {
    const out: Array<string> = [];
    try {
      const names: Array<string> = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        if (names[i].startsWith(prefix)) {
          out.push(names[i]);
        }
      }
    } catch (e) {
      // 目录不存在等:返回空列表
    }
    return out;
  }

  /**
   * 原子尽力写文本：写临时文件 → fsync → rename；rename 失败退化为覆盖写。
   * 不在此处做读回校验(校验包含 checksum 语义，属 Repository 层职责)。
   */
  static writeTextAtomic(path: string, text: string): void {
    const tmp = `${path}.tmp`;
    let file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
      try {
        fs.fsyncSync(file.fd);
      } catch (e) {
        // 某些平台/文件系统不支持 fsync：继续，读回校验兜底
      }
    } finally {
      fs.closeSync(file);
    }
    let renamed = true;
    try {
      fs.renameSync(tmp, path);
    } catch (e) {
      renamed = false;
    }
    if (!renamed) {
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
        try {
          fs.fsyncSync(file.fd);
        } catch (e) {
          // 同上：读回校验兜底
        }
      } finally {
        fs.closeSync(file);
      }
      SnapshotStore.removeFile(tmp);
    }
  }
}
