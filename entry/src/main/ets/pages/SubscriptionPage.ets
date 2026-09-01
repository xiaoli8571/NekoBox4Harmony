import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { SubInfo, listSubs, updateSubscription, removeSub, setSubscriptionPaused, setSubscriptionInterval, setAppContext } from '../core/Subscriptions';
import { formatBytes } from '../utils/TrafficStats';

/** 订阅分组管理页：显示 Android NekoBox 同类的分组详情和更新状态。 */
@Entry
@Component
struct SubscriptionPage {
  @State subs: Array<SubInfo> = [];
  @State updatingUrl: string = '';
  @State intervalText: Record<string, string> = {};
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    setAppContext(this.context);
    this.reload();
  }

  async reload(): Promise<void> {
    this.subs = await listSubs();
    const next: Record<string, string> = {};
    for (const sub of this.subs) {
      next[sub.url] = `${Math.max(15, Math.floor(sub.updateIntervalMs / 60000))}`;
    }
    this.intervalText = next;
  }

  private async updateOne(sub: SubInfo): Promise<void> {
    if (this.updatingUrl.length > 0) {
      return;
    }
    this.updatingUrl = sub.url;
    try {
      const result = await updateSubscription(sub.url);
      promptAction.showToast({ message: `已更新 ${sub.name}: 新增 ${result.added}, 移除 ${result.removed}` });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `更新失败: ${msg}` });
    } finally {
      this.updatingUrl = '';
      await this.reload();
    }
  }

  private async togglePaused(sub: SubInfo): Promise<void> {
    await setSubscriptionPaused(sub.url, !sub.paused);
    await this.reload();
    promptAction.showToast({ message: sub.paused ? '已恢复自动更新' : '已暂停自动更新' });
  }

  private async saveInterval(sub: SubInfo, value: string): Promise<void> {
    const minutes = parseInt(value);
    if (isNaN(minutes)) {
      return;
    }
    await setSubscriptionInterval(sub.url, minutes * 60000);
    await this.reload();
  }

  private async deleteOne(sub: SubInfo): Promise<void> {
    await removeSub(sub.url);
    await this.reload();
    promptAction.showToast({ message: `已删除订阅 ${sub.name}` });
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text('订阅分组').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text('刷新').fontSize(14).fontColor('#1E88E5').padding(8).onClick(() => this.reload())
      }.width('100%').padding(12)

      if (this.subs.length === 0) {
        Text('暂无订阅。请在主页导入订阅 URL。').fontSize(13).fontColor('#888888').padding(18)
      }

      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.subs, (sub: SubInfo) => {
            Column({ space: 7 }) {
              Row() {
                Text(sub.name).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1)
                Text(sub.paused ? '已暂停' : '运行中')
                  .fontSize(11).fontColor(sub.paused ? '#E65100' : '#2E7D32')
              }.width('100%')
              Text(sub.url).fontSize(11).fontColor('#777777').maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
              Text(sub.total > 0
                ? `流量 ${formatBytes(sub.upload + sub.download)} / ${formatBytes(sub.total)}`
                : '流量：未提供配额')
                .fontSize(12).fontColor(sub.total > 0 && sub.upload + sub.download > sub.total ? '#E53935' : '#666666')
                .width('100%')
              Text(sub.expire > 0 ? `到期：${new Date(sub.expire * 1000).toLocaleDateString()}` : '到期：未提供')
                .fontSize(12).fontColor('#666666').width('100%')
              Text(sub.lastUpdate > 0 ? `上次更新：${new Date(sub.lastUpdate).toLocaleString()}` : '上次更新：从未更新')
                .fontSize(12).fontColor('#666666').width('100%')
              Text(`更新间隔：${Math.max(15, Math.floor(sub.updateIntervalMs / 60000))} 分钟；连续失败：${sub.consecutiveFailures} 次`)
                .fontSize(12).fontColor(sub.consecutiveFailures > 0 ? '#E65100' : '#666666').width('100%')
              if (sub.lastError.length > 0) {
                Text(`最近错误：${sub.lastError}`).fontSize(11).fontColor('#C62828').maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
              }
              Row({ space: 6 }) {
                Button(this.updatingUrl === sub.url ? '更新中…' : '立即更新')
                  .height(32).backgroundColor(this.updatingUrl === sub.url ? '#BBBBBB' : '#1E88E5')
                  .onClick(() => this.updateOne(sub))
                Button(sub.paused ? '恢复自动更新' : '暂停自动更新')
                  .height(32).backgroundColor('#F5F5F5').fontColor('#333333')
                  .onClick(() => this.togglePaused(sub))
                Text('删除').fontSize(13).fontColor('#E53935').padding(8)
                  .onClick(() => this.deleteOne(sub))
              }.width('100%')
              Row({ space: 6 }) {
                Text('间隔(分钟)').fontSize(12).fontColor('#666666')
                TextInput({ text: this.intervalText[sub.url] ?? '720', placeholder: '15' })
                  .type(InputType.Number).height(34).layoutWeight(1)
                  .onChange((value: string) => {
                    const next: Record<string, string> = {};
                    for (const key of Object.keys(this.intervalText)) {
                      next[key] = this.intervalText[key];
                    }
                    next[sub.url] = value;
                    this.intervalText = next;
                  })
                Button('保存').height(30).onClick(() => this.saveInterval(sub, this.intervalText[sub.url] ?? '720'))
              }.width('100%')
            }.alignItems(HorizontalAlign.Start).width('100%').padding(14).borderRadius(12).backgroundColor('#FFFFFF')
          }, (sub: SubInfo) => sub.url)
        }.width('100%').padding(12)
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#F2F4F7')
  }
}
