/**
 * LazyForEach 数据源(通用):包装 Array 并按需通知增量变更。
 *
 * 为什么需要:ForEech 每次状态变化都会 diff 全部子项并重建整棵列表子树,
 * 日志页每秒追加多行、连接页每秒全量刷新时开销尤其大。LazyForEach 只
 * 创建可视区 + cachedCount 个节点,配合本数据源的增量通知,只重绘变化的行。
 */
export class ArrayDataSource<T> implements IDataSource {
  private items: Array<T> = [];
  private listeners: Array<DataChangeListener> = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private notify(method: (l: DataChangeListener) => void): void {
    for (const l of this.listeners) {
      try {
        method(l);
      } catch (e) {
        // 单个监听器异常不影响其他监听器
      }
    }
  }

  /** 整体替换(过滤条件变化 / 全量刷新时用) */
  reset(next: Array<T>): void {
    this.items = next;
    this.notify((l) => l.onDataReloaded());
  }

  /** 追加一行(日志场景,只通知新行,不重建整表) */
  push(item: T): void {
    this.items.push(item);
    const index = this.items.length - 1;
    this.notify((l) => l.onDataAdd(index));
  }

  /** 从头部删除 n 行(日志超过上限时滚动淘汰) */
  trimHead(max: number): number {
    const overflow = this.items.length - max;
    if (overflow <= 0) {
      return 0;
    }
    this.items.splice(0, overflow);
    this.notify((l) => l.onDataDelete(0));
    return overflow;
  }

  /** 批量追加 + 淘汰,一次通知(每秒多条日志时避免逐行重建) */
  pushBatch(batch: Array<T>, max: number): void {
    if (batch.length === 0) {
      return;
    }
    const start = this.items.length;
    this.items.push(...batch);
    if (this.items.length > max) {
      const overflow = this.items.length - max;
      this.items.splice(0, overflow);
      this.notify((l) => l.onDataReloaded());
      return;
    }
    this.notify((l) => l.onDataAdd(start));
  }

  clear(): void {
    this.items = [];
    this.notify((l) => l.onDataReloaded());
  }

  /** 快照(导出等只读场景) */
  snapshot(): Array<T> {
    return this.items.slice();
  }

  isEmpty(): boolean {
    return this.items.length === 0;
  }
}
