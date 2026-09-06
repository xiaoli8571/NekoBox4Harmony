import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { Profile, ProfileGroup } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, saveGroups, LogStore } from '../model/Store';
import { SubInfo, listSubs, saveSubs, removeSub, updateSubscription, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { exportProfileLink } from '../utils/LinkExporter';
import { setClipboardText } from '../utils/ClipboardHelper';

/**
 * 分组管理页(对齐 NekoBoxForAndroid GroupFragment):
 * 订阅分组 + 手动分组统一列表,含流量徽标、更新全部、分享/导出/清空/删除。
 */
@Component
export struct GroupPage {
  @State profiles: Array<Profile> = [];
  @State groups: Array<ProfileGroup> = [];
  @State subscriptions: Array<SubInfo> = [];
  @State updatingUrl: string = '';
  @State updatingAll: boolean = false;
  @State newGroupName: string = '';
  @State renameGroupId: string = '';
  @State renameDraft: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onDataChanged: () => void = () => {};

  aboutToAppear(): void {
    this.refresh();
  }

  async refresh(): Promise<void> {
    try {
      await initStore(this.context);
      this.profiles = await loadProfiles();
      this.groups = await loadGroups();
      this.subscriptions = await listSubs();
    } catch (e) {
      LogStore.addLog(`[ui] 分组页加载失败: ${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  private nodeCountOfSub(url: string): number {
    return this.profiles.filter((p: Profile) => p.subUrl === url).length;
  }

  private nodeCountOfGroup(groupId: string): number {
    return this.profiles.filter((p: Profile) => p.groupId === groupId).length;
  }

  private subscriptionTrafficText(sub: SubInfo): ResourceStr {
    if (sub.total <= 0) {
      return '';
    }
    const used = sub.upload + sub.download;
    const remain = Math.max(0, sub.total - used);
    if (remain > 0) {
      return $r('app.string.sub_traffic_used_remain', formatBytesShort(used), formatBytesShort(remain));
    }
    return $r('app.string.sub_traffic_used', formatBytesShort(used));
  }

  private lastUpdateText(sub: SubInfo): ResourceStr {
    if (sub.lastUpdate <= 0) {
      return $r('app.string.sub_not_updated');
    }
    const d = new Date(sub.lastUpdate);
    const pad = (v: number): string => v < 10 ? `0${v}` : `${v}`;
    return $r('app.string.sub_last_update', `${d.getMonth() + 1}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`);
  }

  async updateOne(sub: SubInfo): Promise<void> {
    if (this.updatingUrl.length > 0 || this.updatingAll) {
      return;
    }
    this.updatingUrl = sub.url;
    try {
      const r = await updateSubscription(sub.url);
      await markSubSuccess(sub.url);
      promptAction.showToast({ message: $r('app.string.sub_update_result', r.added, r.removed) });
      await this.refresh();
      this.onDataChanged();
    } catch (e) {
      await markSubFailure(sub.url);
      promptAction.showToast({ message: $r('app.string.update_failed_reason', e instanceof Error ? e.message : `${e}`) });
      await this.refresh();
    } finally {
      this.updatingUrl = '';
    }
  }

  async updateAll(): Promise<void> {
    if (this.updatingAll || this.updatingUrl.length > 0 || this.subscriptions.length === 0) {
      return;
    }
    this.updatingAll = true;
    let added = 0;
    let removed = 0;
    let failed = 0;
    try {
      for (const sub of this.subscriptions) {
        try {
          const r = await updateSubscription(sub.url);
          await markSubSuccess(sub.url);
          added += r.added;
          removed += r.removed;
        } catch (e) {
          await markSubFailure(sub.url);
          failed++;
        }
      }
      promptAction.showToast({ message: $r('app.string.sub_update_result', added, removed) });
      if (failed > 0) {
        LogStore.addLog(`[app] 更新全部订阅:${failed} 个失败`);
      }
      await this.refresh();
      this.onDataChanged();
    } finally {
      this.updatingAll = false;
    }
  }

  async shareSubLink(sub: SubInfo): Promise<void> {
    await setClipboardText(sub.url);
    promptAction.showToast({ message: $r('app.string.sub_link_copied') });
  }

  async exportAllNodes(sub: SubInfo): Promise<void> {
    const lines: Array<string> = [];
    for (const p of this.profiles.filter((x: Profile) => x.subUrl === sub.url)) {
      const link = exportProfileLink(p);
      if (link.length > 0) {
        lines.push(link);
      }
    }
    if (lines.length === 0) {
      promptAction.showToast({ message: $r('app.string.export_all_empty') });
      return;
    }
    await setClipboardText(lines.join('\n'));
    promptAction.showToast({ message: $r('app.string.export_all_done', lines.length) });
  }

  clearGroupProfiles(groupId: string): void {
    const count = this.nodeCountOfGroup(groupId);
    AlertDialog.show({
      message: $r('app.string.confirm_clear_group', count),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          this.profiles = this.profiles.filter((p: Profile) => p.groupId !== groupId);
          await saveProfiles(this.profiles);
          await this.refresh();
          this.onDataChanged();
        }
      }
    });
  }

  clearSubProfiles(sub: SubInfo): void {
    const count = this.nodeCountOfSub(sub.url);
    AlertDialog.show({
      message: $r('app.string.confirm_clear_group', count),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          this.profiles = this.profiles.filter((p: Profile) => p.subUrl !== sub.url);
          await saveProfiles(this.profiles);
          await this.refresh();
          this.onDataChanged();
        }
      }
    });
  }

  deleteSub(sub: SubInfo): void {
    const count = this.nodeCountOfSub(sub.url);
    AlertDialog.show({
      message: $r('app.string.confirm_delete_sub_name', sub.name, count),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          await removeSub(sub.url);
          this.profiles = this.profiles.filter((p: Profile) => p.subUrl !== sub.url);
          await saveProfiles(this.profiles);
          await this.refresh();
          this.onDataChanged();
        }
      }
    });
  }

  async createGroup(): Promise<void> {
    const name = this.newGroupName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: $r('app.string.group_name_required') });
      return;
    }
    const group = new ProfileGroup();
    group.id = `grp_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    group.name = name;
    group.sortOrder = this.groups.length;
    group.createdAt = Date.now();
    group.updatedAt = Date.now();
    const next = this.groups.slice();
    next.push(group);
    this.groups = next;
    await saveGroups(this.groups);
    this.newGroupName = '';
    await this.refresh();
  }

  deleteGroup(group: ProfileGroup): void {
    AlertDialog.show({
      message: $r('app.string.confirm_delete_group', group.name),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          // 组内节点移到未分组,不删除节点本身
          for (const p of this.profiles) {
            if (p.groupId === group.id) {
              p.groupId = '';
            }
          }
          await saveProfiles(this.profiles);
          this.groups = this.groups.filter((g: ProfileGroup) => g.id !== group.id);
          await saveGroups(this.groups);
          await this.refresh();
          this.onDataChanged();
        }
      }
    });
  }

  async renameGroup(): Promise<void> {
    const name = this.renameDraft.trim();
    const group = this.groups.find((g: ProfileGroup) => g.id === this.renameGroupId);
    if (group === undefined || name.length === 0) {
      return;
    }
    group.name = name;
    group.updatedAt = Date.now();
    await saveGroups(this.groups);
    this.renameGroupId = '';
    await this.refresh();
  }

  @Builder
  private groupActionsSub(sub: SubInfo) {
    Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
      Text(this.updatingUrl === sub.url ? $r('app.string.updating') : $r('app.string.update_action'))
        .fontSize(12.5).fontWeight(600).fontColor($r('app.color.mono'))
        .padding({ left: 6, top: 8, bottom: 8 })
        .onClick(() => this.updateOne(sub))
      Text($r('app.string.share_sub_link'))
        .fontSize(12.5).fontWeight(600).fontColor($r('app.color.text_2'))
        .padding({ left: 6, top: 8, bottom: 8 })
        .onClick(() => this.shareSubLink(sub))
      Text($r('app.string.export_all_nodes'))
        .fontSize(12.5).fontWeight(600).fontColor($r('app.color.text_2'))
        .padding({ left: 6, top: 8, bottom: 8 })
        .onClick(() => this.exportAllNodes(sub))
      Text($r('app.string.clear_group'))
        .fontSize(12.5).fontWeight(600).fontColor($r('app.color.warning'))
        .padding({ left: 6, top: 8, bottom: 8 })
        .onClick(() => this.clearSubProfiles(sub))
      Text($r('app.string.delete'))
        .fontSize(12.5).fontWeight(600).fontColor($r('app.color.error'))
        .padding({ left: 6, top: 8, bottom: 8 })
        .onClick(() => this.deleteSub(sub))
    }
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.nav_groups'))
          .fontSize(16).fontWeight(800).fontColor($r('app.color.text_1')).layoutWeight(1)
        Text(this.updatingAll ? $r('app.string.updating') : $r('app.string.update_all_subs'))
          .fontSize(13.5).fontWeight(600).fontColor($r('app.color.mono'))
          .padding(8)
          .onClick(() => this.updateAll())
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 26 })

      Row({ space: 8 }) {
        TextInput({ text: this.newGroupName, placeholder: $r('app.string.new_group_hint') })
          .layoutWeight(1).height(UiSpec.ROW_HEIGHT)
          .backgroundColor(Color.Transparent)
          .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
          .onChange((v: string) => { this.newGroupName = v; })
        Button($r('app.string.add_group'))
          .height(UiSpec.BTN_HEIGHT)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.surface'))
          .onClick(() => this.createGroup())
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 4 })

      List() {
        // 订阅分组
        ForEach(this.subscriptions, (sub: SubInfo) => {
          ListItem() {
            Column({ space: 4 }) {
              Row({ space: 8 }) {
                Text(sub.name)
                  .fontSize(14.5).fontWeight(700).fontColor($r('app.color.text_1'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text($r('app.string.group_node_count', this.nodeCountOfSub(sub.url)))
                  .fontSize(11.5).fontColor($r('app.color.text_3'))
              }.width('100%')
              Text(sub.url)
                .fontSize(11).fontColor($r('app.color.text_3'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Row({ space: 10 }) {
                Text(this.lastUpdateText(sub))
                  .fontSize(11).fontColor($r('app.color.text_3'))
                if (sub.total > 0) {
                  Text(this.subscriptionTrafficText(sub))
                    .fontSize(11).fontWeight(600).fontColor($r('app.color.mono'))
                }
                if (sub.expire > 0) {
                  Text($r('app.string.subscription_days_remaining', Math.max(0, Math.ceil((sub.expire * 1000 - Date.now()) / 86400000))))
                    .fontSize(11).fontColor($r('app.color.text_2'))
                }
              }.width('100%')
              this.groupActionsSub(sub)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
          }
        }, (sub: SubInfo) => sub.url)

        // 手动分组
        ForEach(this.groups, (group: ProfileGroup) => {
          ListItem() {
            Column({ space: 4 }) {
              Row({ space: 8 }) {
                Text(group.name)
                  .fontSize(14.5).fontWeight(700).fontColor($r('app.color.text_1'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text($r('app.string.group_node_count', this.nodeCountOfGroup(group.id)))
                  .fontSize(11.5).fontColor($r('app.color.text_3'))
              }.width('100%')
              Row({ space: 6 }) {
                Text($r('app.string.clear_group'))
                  .fontSize(12.5).fontWeight(600).fontColor($r('app.color.warning'))
                  .padding({ left: 6, top: 8, bottom: 8 })
                  .onClick(() => this.clearGroupProfiles(group.id))
                Text($r('app.string.delete'))
                  .fontSize(12.5).fontWeight(600).fontColor($r('app.color.error'))
                  .padding({ left: 6, top: 8, bottom: 8 })
                  .onClick(() => this.deleteGroup(group))
              }.width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
          }
        }, (group: ProfileGroup) => group.id)

        if (this.subscriptions.length === 0 && this.groups.length === 0) {
          ListItem() {
            Text($r('app.string.groups_empty'))
              .fontSize(13).fontColor($r('app.color.text_3'))
              .width('100%')
              .padding({ top: 30, bottom: 30 })
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })
    }
    .width('100%')
    .height('100%')
  }
}

function formatBytesShort(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes}B`;
  }
  const units: Array<string> = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes;
  let unitIndex = -1;
  do {
    value /= 1024;
    unitIndex++;
  } while (value >= 1024 && unitIndex < units.length - 1);
  return `${value.toFixed(value >= 100 ? 0 : 1)}${units[unitIndex]}`;
}
