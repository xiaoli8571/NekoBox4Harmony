import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import { UiSpec } from '../common/UiSpec';
import { DrawerButton } from '../common/components/DrawerButton';
import { Profile, ProfileGroup } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, loadGroups, saveGroups, LogStore } from '../model/Store';
import { SubInfo, listSubs, saveSubs, removeSub, updateSubscription, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { VpnService } from '../core/VpnService';
import { subErrorText } from '../utils/Subscription';
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
  // 分组设置(对齐安卓 GroupSettingsActivity:use_selector / front_proxy / landing_proxy)
  @State settingsGroupId: string = '';
  @State settingsSelector: boolean = false;
  @State settingsFront: string = '';
  @State settingsLanding: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onDataChanged: () => void = () => {};
  onOpenDrawer: () => void = () => {};

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
      promptAction.showToast({ message: $r('app.string.update_failed_reason', subErrorText(e as Object)) });
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
    const lines = this.exportableLinks(sub);
    if (lines.length === 0) {
      promptAction.showToast({ message: $r('app.string.export_all_empty') });
      return;
    }
    await setClipboardText(lines.join('\n'));
    promptAction.showToast({ message: $r('app.string.export_all_done', lines.length) });
  }

  /** 把订阅内可导出的节点链接写入用户选择的文件(对齐安卓 action_export_file) */
  async exportAllNodesToFile(sub: SubInfo): Promise<void> {
    const lines = this.exportableLinks(sub);
    if (lines.length === 0) {
      promptAction.showToast({ message: $r('app.string.export_all_empty') });
      return;
    }
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const safeName = sub.name.replace(/[\\/:*?"<>|]/g, '_');
      const uris = await documentPicker.save({
        newFileNames: [`${safeName.length > 0 ? safeName : 'subscription'}.txt`],
        fileSuffixChoices: ['TXT|.txt']
      });
      if (uris.length === 0) {
        promptAction.showToast({ message: $r('app.string.backup_export_cancelled') });
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, lines.join('\n'));
      } finally {
        fs.closeSync(file);
      }
      promptAction.showToast({ message: $r('app.string.export_all_file_done', lines.length) });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.export_failed_generic', e instanceof Error ? e.message : `${e}`) });
    }
  }

  private exportableLinks(sub: SubInfo): Array<string> {
    const lines: Array<string> = [];
    for (const p of this.profiles.filter((x: Profile) => x.subUrl === sub.url)) {
      const link = exportProfileLink(p);
      if (link.length > 0) {
        lines.push(link);
      }
    }
    return lines;
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

  openGroupSettings(group: ProfileGroup): void {
    if (this.settingsGroupId === group.id) {
      this.settingsGroupId = '';
      return;
    }
    this.settingsGroupId = group.id;
    this.settingsSelector = group.isSelector;
    this.settingsFront = group.frontProxy;
    this.settingsLanding = group.landingProxy;
  }

  /** 保存分组设置;运行中节点属于该组时自动重载配置(对齐安卓组设置变更即 reload) */
  async saveGroupSettings(): Promise<void> {
    const group = this.groups.find((g: ProfileGroup) => g.id === this.settingsGroupId);
    if (group === undefined) {
      return;
    }
    group.isSelector = this.settingsSelector;
    group.frontProxy = this.settingsFront;
    group.landingProxy = this.settingsLanding;
    group.updatedAt = Date.now();
    await saveGroups(this.groups);
    this.settingsGroupId = '';
    promptAction.showToast({ message: $r('app.string.group_settings_saved') });
    const runningId: string = AppStorage.get<string>('vpnRunningProfileId') ?? '';
    const running: boolean = AppStorage.get<boolean>('vpnRunning') ?? false;
    if (running && runningId.length > 0) {
      const runningProfile = this.profiles.find((p: Profile) => p.id === runningId);
      if (runningProfile !== undefined && runningProfile.groupId === group.id) {
        try {
          LogStore.addLog(`[ui] 分组设置变更,重载 VPN 配置: ${group.name}`);
          await VpnService.switchTo(this.context, runningId);
        } catch (e) {
          LogStore.addLog(`[ui] 分组设置自动重载失败: ${e instanceof Error ? e.message : `${e}`}`);
        }
      }
    }
    await this.refresh();
  }

  /** 代理候选:「无」+ 全部非链式节点(链/被引用户进链会放大复杂度,链作前后置安卓同样允许但此处从简) */
  private proxyOptions(): Array<SelectOption> {
    const opts: Array<SelectOption> = [{ value: $r('app.string.option_none') } as SelectOption];
    for (const p of this.profiles) {
      opts.push({ value: `${p.name} (${p.server})` } as SelectOption);
    }
    return opts;
  }

  private proxyIndexOf(id: string): number {
    if (id.length === 0) {
      return 0;
    }
    const i = this.profiles.findIndex((p: Profile) => p.id === id);
    return i < 0 ? 0 : i + 1;
  }

  private proxyIdAt(index: number): string {
    return index <= 0 ? '' : this.profiles[index - 1].id;
  }

  private proxyOptionLabel(index: number): ResourceStr {
    if (index <= 0) {
      return $r('app.string.option_none');
    }
    const p = this.profiles[index - 1];
    return p === undefined ? $r('app.string.option_none') : `${p.name} (${p.server})`;
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
      Text($r('app.string.export_all_nodes_file'))
        .fontSize(12.5).fontWeight(600).fontColor($r('app.color.text_2'))
        .padding({ left: 6, top: 8, bottom: 8 })
        .onClick(() => this.exportAllNodesToFile(sub))
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
        DrawerButton({ onOpen: () => this.onOpenDrawer() })
        Text($r('app.string.nav_groups'))
          .fontSize(16).fontWeight(800).fontColor($r('app.color.text_1')).layoutWeight(1)
        Text(this.updatingAll ? $r('app.string.updating') : $r('app.string.update_all_subs'))
          .fontSize(13.5).fontWeight(600).fontColor($r('app.color.mono'))
          .padding(8)
          .onClick(() => this.updateAll())
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING - 10, top: 26 })

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
                Text($r('app.string.group_settings'))
                  .fontSize(12.5).fontWeight(600).fontColor($r('app.color.mono'))
                  .padding({ left: 6, top: 8, bottom: 8 })
                  .onClick(() => this.openGroupSettings(group))
                Text($r('app.string.clear_group'))
                  .fontSize(12.5).fontWeight(600).fontColor($r('app.color.warning'))
                  .padding({ left: 6, top: 8, bottom: 8 })
                  .onClick(() => this.clearGroupProfiles(group.id))
                Text($r('app.string.delete'))
                  .fontSize(12.5).fontWeight(600).fontColor($r('app.color.error'))
                  .padding({ left: 6, top: 8, bottom: 8 })
                  .onClick(() => this.deleteGroup(group))
              }.width('100%')

              if (this.settingsGroupId === group.id) {
                Column({ space: 8 }) {
                  Row() {
                    Column({ space: 2 }) {
                      Text($r('app.string.use_selector')).fontSize(13.5).fontColor($r('app.color.text_primary')).width('100%')
                      Text($r('app.string.use_selector_sum'))
                        .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                    Toggle({ type: ToggleType.Switch, isOn: this.settingsSelector })
                      .onChange((on: boolean) => { this.settingsSelector = on; })
                  }.width('100%')

                  Column({ space: 2 }) {
                    Text($r('app.string.front_proxy')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
                    Select(this.proxyOptions())
                      .selected(this.proxyIndexOf(this.settingsFront))
                      .value(this.proxyOptionLabel(this.proxyIndexOf(this.settingsFront)))
                      .onSelect((index: number) => { this.settingsFront = this.proxyIdAt(index); })
                  }.alignItems(HorizontalAlign.Start).width('100%')

                  Column({ space: 2 }) {
                    Text($r('app.string.landing_proxy')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
                    Select(this.proxyOptions())
                      .selected(this.proxyIndexOf(this.settingsLanding))
                      .value(this.proxyOptionLabel(this.proxyIndexOf(this.settingsLanding)))
                      .onSelect((index: number) => { this.settingsLanding = this.proxyIdAt(index); })
                  }.alignItems(HorizontalAlign.Start).width('100%')

                  Row({ space: 8 }) {
                    Button($r('app.string.cancel'))
                      .layoutWeight(1)
                      .backgroundColor($r('app.color.surface'))
                      .fontColor($r('app.color.text_primary'))
                      .onClick(() => { this.settingsGroupId = ''; })
                    Button($r('app.string.save'))
                      .layoutWeight(1)
                      .backgroundColor($r('app.color.primary'))
                      .fontColor($r('app.color.surface'))
                      .onClick(() => { void this.saveGroupSettings(); })
                  }.width('100%')
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding({ top: 6 })
              }
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
        .edgeEffect(EdgeEffect.Spring)
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
