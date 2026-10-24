/**
 * 应用事务协调器 —— REDESIGN-PLAN-2026-10-23.md §12.3 / §14.3 的 saved/applied 修订分离。
 *
 * 纯状态机(无 I/O、无平台依赖)，便于主机测试；UI 侧持有一份实例。
 * 与 ConfigRepository 的关系:
 *   - `markSaved` 由 commit 成功驱动(磁盘快照前进 savedRevision);
 *   - `beginApply/acceptAck/onFailure` 由 VPN 命令通道与扩展回执驱动;
 *   - **保存成功绝不推进 applied**(§14.3 指针命名区分)。
 * 规则(§12.3):
 *   - 只有 operationId + generation + sessionId 全匹配的回执能结束事务，迟到回执拒绝并记诊断;
 *   - 应用失败允许**一次**有界回滚尝试(§12.3-7)，用掉后显示真实失败，不无限重试;
 *   - 同一 operationId 重复 beginApply 不重复启动(§16.1)。
 */

/** idle | saved | applying | applied | failed */
export class ApplyState {
  phase: string = 'idle';
  savedRevision: number = 0;
  requestedRevision: number = 0;
  appliedRevision: number = 0;
  operationId: string = '';
  lastError: string = '';
  /** 一次有界回滚是否已用掉(§12.3-7:回滚只尝试一次) */
  recoveryAttempted: boolean = false;
  /** 待应用变更计数(全局待应用条展示，§12.2) */
  pendingChanges: number = 0;
  updatedAt: number = 0;
}

export class ApplyCoordinator {
  private state: ApplyState = new ApplyState();

  getSnapshot(): ApplyState {
    const copy = new ApplyState();
    copy.phase = this.state.phase;
    copy.savedRevision = this.state.savedRevision;
    copy.requestedRevision = this.state.requestedRevision;
    copy.appliedRevision = this.state.appliedRevision;
    copy.operationId = this.state.operationId;
    copy.lastError = this.state.lastError;
    copy.recoveryAttempted = this.state.recoveryAttempted;
    copy.pendingChanges = this.state.pendingChanges;
    copy.updatedAt = this.state.updatedAt;
    return copy;
  }

  /** 保存成功(配置进磁盘快照):推进 savedRevision 与待应用计数;不改变 applied。 */
  markSaved(revision: number): void {
    if (revision <= this.state.savedRevision) {
      return;
    }
    this.state.savedRevision = revision;
    this.state.pendingChanges = this.state.pendingChanges + 1;
    if (this.state.phase !== 'applying') {
      this.state.phase = 'saved';
    }
    this.state.updatedAt = Date.now();
  }

  /** 放弃草稿(用户选择「放弃」):待应用清零，回到 applied/idle。 */
  discardDraft(): void {
    this.state.pendingChanges = 0;
    this.state.requestedRevision = 0;
    this.state.phase = this.state.appliedRevision > 0 ? 'applied' : 'idle';
    this.state.updatedAt = Date.now();
  }

  /**
   * 连接成功即全量生效:扩展启动时加载磁盘快照,所有已保存修订随本次连接落地。
   * 2026-10-24 真机:VPN 未运行时保存(标记"下次连接生效")后用户连接,
   * pendingChanges 未清 ⇒ 横幅在连接后冒出来谎称"点应用立即生效"。
   * 回执在途(phase=applying)时不抢裁决,交给 acceptAck/超时路径。
   */
  markAllAppliedOnConnect(): void {
    if (this.state.phase === 'applying') {
      return;
    }
    if (this.state.savedRevision > this.state.appliedRevision) {
      this.state.appliedRevision = this.state.savedRevision;
    }
    this.state.pendingChanges = 0;
    this.state.requestedRevision = 0;
    this.state.phase = this.state.appliedRevision > 0 ? 'applied' : 'idle';
    this.state.lastError = '';
    this.state.updatedAt = Date.now();
  }

  /**
   * 开始应用。同一 operationId 重试返回 false(不重复启动，§16.1);
   * 否则登记 requestedRevision 进入 applying;连续切换合并为最终目标(§12.2)。
   */
  beginApply(operationId: string, revision: number): boolean {
    if (this.state.phase === 'applying' && this.state.operationId === operationId) {
      return false;
    }
    this.state.operationId = operationId;
    this.state.requestedRevision = revision;
    this.state.phase = 'applying';
    this.state.lastError = '';
    this.state.updatedAt = Date.now();
    return true;
  }

  /**
   * 收到应用回执。仅当 operationId/generation/sessionId 全匹配时接受;
   * 迟到或跨会话回执返回 false，调用方记录诊断但不改状态(§12.3-6)。
   */
  acceptAck(operationId: string, generation: number, sessionId: string,
    appliedRevision: number, expectedGeneration: number, expectedSessionId: string): boolean {
    if (this.state.phase !== 'applying') {
      return false;
    }
    if (operationId !== this.state.operationId) {
      return false;
    }
    if (generation !== expectedGeneration) {
      return false;
    }
    if (expectedSessionId.length > 0 && sessionId !== expectedSessionId) {
      return false;
    }
    this.state.appliedRevision = appliedRevision;
    this.state.phase = 'applied';
    if (appliedRevision >= this.state.savedRevision) {
      this.state.pendingChanges = 0;
    }
    this.state.lastError = '';
    this.state.updatedAt = Date.now();
    return true;
  }

  /**
   * 应用失败。返回 true 表示允许一次有界恢复尝试(§12.3-7);
   * 已用掉恢复机会时返回 false，调用方显示真实失败状态，不得无限重试。
   */
  onFailure(operationId: string, reason: string): boolean {
    if (this.state.phase === 'applying' && operationId !== this.state.operationId) {
      // 迟到失败事件:不改变现状
      return false;
    }
    this.state.phase = 'failed';
    this.state.lastError = reason;
    this.state.updatedAt = Date.now();
    if (!this.state.recoveryAttempted) {
      this.state.recoveryAttempted = true;
      return true;
    }
    return false;
  }

  /** 扩展会话变化/断开:清空 applying 上下文，保留依据真实回执的 appliedRevision。 */
  reset(): void {
    this.state.phase = this.state.appliedRevision > 0 ? 'applied' : 'idle';
    this.state.operationId = '';
    this.state.requestedRevision = 0;
    this.state.lastError = '';
    this.state.updatedAt = Date.now();
  }
}
