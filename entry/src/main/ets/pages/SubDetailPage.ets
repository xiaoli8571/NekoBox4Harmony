import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { initStore, loadProfiles, saveProfiles } from '../model/Store';
import { SubInfo, listSubs, removeSub, updateSubscription, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { formatBytes } from '../utils/TrafficStats';

@Entry
@Component
struct SubDetailPage {
  @State sub: SubInfo = new SubInfo();
  @State profileCount: number = 0;
  @State updating: boolean = false;
  @State loading: boolean = true;
  @State loadError: string = '';
  @State notFound: boolean = false;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    this.notFound = false;
    try {
      await initStore(this.context);
      const params = router.getParams() as Record<string, Object>;
      const url = params !== undefined && params['url'] !== undefined ? `${params['url']}` : '';
      if (url.length === 0) {
        this.notFound = true;
        return;
      }
      const subs = await listSubs();
      const found = subs.find((s: SubInfo) => s.url === url);
      if (found === undefined) {
        this.notFound = true;
        return;
      }
      this.sub = found;
      const profiles = await loadProfiles();
      this.profileCount = profiles.filter(p => p.subUrl === url).length;
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  async updateNow(): Promise<void> {
    if (this.updating || this.sub.url.length === 0) {
      return;
    }
    this.updating = true;
    try {
      const result = await updateSubscription(this.sub.url);
      await markSubSuccess(this.sub.url);
      promptAction.showToast({ message: `更新完成:新增 ${result.added},移除 ${result.removed}` });
    } catch (e) {
      await markSubFailure(this.sub.url);
      const message = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `更新失败: ${message}` });
    } finally {
      this.updating = false;
      await this.load();
    }
  }

  confirmDelete(): void {
    AlertDialog.show({
      message: `删除订阅“${this.sub.name}”及其 ${this.profileCount} 个节点?`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.error'),
        action: async () => {
          const profiles = await loadProfiles();
          await saveProfiles(profiles.filter(p => p.subUrl !== this.sub.url));
          await removeSub(this.sub.url);
          router.back();
        }
      }
    });
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).padding(8).onClick(() => router.back())
        Text('订阅详情').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
      }.width('100%').padding(12)

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.primary'))
          Text('正在加载订阅…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.loadError.length > 0) {
        Column({ space: 8 }) {
          Text('订阅加载失败')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.loadError)
            .fontSize(13)
            .fontColor($r('app.color.error'))
          Button('重新加载')
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => this.load())
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.notFound) {
        Column({ space: 8 }) {
          Text('订阅不存在')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('该订阅可能已被删除，请返回订阅列表。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
          Button('返回')
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => router.back())
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            Text(this.sub.name.length > 0 ? this.sub.name : '未命名订阅')
              .fontSize(20).fontWeight(FontWeight.Bold).width('100%')
            Text(this.sub.url).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
            Text(`节点数量: ${this.profileCount}`).width('100%')
            Text(`已用流量: ${formatBytes(this.sub.upload + this.sub.download)}`).width('100%')
            Text(`总流量: ${this.sub.total > 0 ? formatBytes(this.sub.total) : '未知'}`).width('100%')
            Text(`连续失败: ${Number(this.sub.failCount)} 次`)
              .fontColor(Number(this.sub.failCount) >= 3 ? $r('app.color.error') : $r('app.color.text_secondary')).width('100%')
            Button(this.updating ? '正在更新…' : '立即更新')
              .width('100%').enabled(!this.updating).onClick(() => this.updateNow())
            Button('删除订阅及节点')
              .width('100%').backgroundColor($r('app.color.error')).onClick(() => this.confirmDelete())
          }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.app_background'))
  }
}
