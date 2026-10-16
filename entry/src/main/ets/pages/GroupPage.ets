import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import { UiSpec } from '../common/UiSpec';
import { DrawerButton } from '../common/components/DrawerButton';
import { Profile } from '../model/Profile';
import { initStore, loadProfiles, saveProfiles, LogStore } from '../model/Store';
import { SubInfo, listSubs, upsertSub, removeSub, updateSubscription, markSubSuccess, markSubFailure } from '../core/Subscriptions';
import { subErrorText } from '../utils/Subscription';
import { exportProfileLink } from '../utils/LinkExporter';
import { setClipboardText } from '../utils/ClipboardHelper';

/**
 * 分组管理页(用户 m02296 重新设计:一个订阅就是一个分组)。
 * 本页只管理订阅分组 —— 导入(新建分组)/ 更新(单个或全部)/ 订阅详情 / 导出 / 清空 / 删除;
 * 订阅内部的内核分组(自动选择等)不再混进本页,而是按订阅在首页底部切换后展示。
 * 手动导入的节点不属于任何订阅,在首页底部「手动」视图里查看与管理。
 */
@Component
export struct GroupPage {
  @State profiles: Array<Profile> = [];
  @State subscriptions: Array<SubInfo> = [];
  @State updatingUrl: string = '';
  @State updatingAll: boolean = false;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onDataChanged: () => void = () => {};
  onOpenDrawer: () => void = () => {};

  private createDialog: CustomDialogController = new CustomDialogController({
    builder: CreateGroupDialog({
      onCreateSubscription: (name: string, url: string, fetchNow: boolean) => {
        this.createSubscriptionGroup(name, url, fetchNow);
      }
    }),
    autoCancel: true
  });

  aboutToAppear(): void {
    this.refresh();
  }

  async refresh(): Promise<void> {
    try {
      await initStore(this.context);
      this.profiles = await loadProfiles();
      this.subscriptions = await listSubs();
    } catch (e) {
      LogStore.addLog(`[ui] 分组页加载失败: ${e instanceof Error ? e.message : `${e}`}`);
    }
  }

  // ---------------------------------------------------------------- 计数与文案

  private subProfiles(url: string): Array<Profile> {
    return this.profiles.filter((p: Profile) => p.subUrl === url);
  }

  private nodeCountOfSub(url: string): number {
    return this.subProfiles(url).length;
  }

  /** 该订阅在首页会显示几个分组(订阅自带的内核分组,如「自动选择」) */
  private groupCountOfSub(url: string): number {
    const ids = new Set<string>();
    for (const p of this.subProfiles(url)) {
      if (p.groupId.length > 0) {
        ids.add(p.groupId);
      }
    }
    return ids.size;
  }

  /** 分组状态:空 / N 个节点(对齐安卓 groupStatus) */
  private countText(count: number): ResourceStr {
    if (count === 0) {
      return $r('app.string.group_status_empty');
    }
    return $r('app.string.group_node_count', count);
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

  private expireText(sub: SubInfo): ResourceStr {
    const days = Math.max(0, Math.ceil((sub.expire * 1000 - Date.now()) / 86400000));
    return $r('app.string.subscription_days_remaining', days);
  }

  // ---------------------------------------------------------------- 更新

  async updateOne(sub: SubInfo): Promise<void> {
    if (this.updatingUrl.length > 0 || this.updatingAll) {
      return;
    }
    this.updatingUrl = sub.url;
    try {
      const r = await updateSubscription(sub.url);
      await markSubSuccess(sub.url);
      if (r.notModified) {
        promptAction.showToast({ message: $r('app.string.sub_update_not_modified') });
      } else {
        promptAction.showToast({ message: $r('app.string.sub_update_result', r.added, r.removed) });
      }
      if (r.skipped > 0) {
        LogStore.addLog(`[sub] 跳过 ${r.skipped} 个节点(内核不支持): ${r.skippedNames.join(', ')}`);
      }
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

  // ---------------------------------------------------------------- 新建分组(仅订阅)

  /** 新建订阅分组:登记订阅(upsertSub)并按需立即拉取一次节点 */
  async createSubscriptionGroup(rawName: string, url: string, fetchNow: boolean): Promise<void> {
    try {
      await initStore(this.context);
      await upsertSub(url, '', rawName.trim());
      if (fetchNow) {
        this.updatingUrl = url;
        try {
          const r = await updateSubscription(url);
          await markSubSuccess(url);
          promptAction.showToast({ message: $r('app.string.sub_update_result', r.added, r.removed) });
        } catch (e) {
          await markSubFailure(url);
          promptAction.showToast({ message: $r('app.string.update_failed_reason', subErrorText(e as Object)) });
        } finally {
          this.updatingUrl = '';
        }
      } else {
        promptAction.showToast({ message: $r('app.string.group_subscription_created') });
      }
      await this.refresh();
      this.onDataChanged();
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.update_failed_reason', subErrorText(e as Object)) });
    }
  }

  // ---------------------------------------------------------------- 分享 / 导出

  async shareSubLink(sub: SubInfo): Promise<void> {
    await setClipboardText(sub.url);
    promptAction.showToast({ message: $r('app.string.sub_link_copied') });
  }

  private exportLinks(profiles: Array<Profile>): Array<string> {
    const lines: Array<string> = [];
    for (const p of profiles) {
      const link = exportProfileLink(p);
      if (link.length > 0) {
        lines.push(link);
      }
    }
    return lines;
  }

  async copyLinksToClipboard(profiles: Array<Profile>): Promise<void> {
    const lines = this.exportLinks(profiles);
    if (lines.length === 0) {
      promptAction.showToast({ message: $r('app.string.export_all_empty') });
      return;
    }
    await setClipboardText(lines.join('\n'));
    promptAction.showToast({ message: $r('app.string.export_all_done', lines.length) });
  }

  /** 把节点链接写入用户选择的文件(对齐安卓 action_export_file) */
  async writeLinksToFile(fileName: string, profiles: Array<Profile>): Promise<void> {
    const lines = this.exportLinks(profiles);
    if (lines.length === 0) {
      promptAction.showToast({ message: $r('app.string.export_all_empty') });
      return;
    }
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const safeName = fileName.replace(/[\\/:*?"<>|]/g, '_');
      const uris = await documentPicker.save({
        newFileNames: [`${safeName.length > 0 ? safeName : 'nodes'}.txt`],
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

  // ---------------------------------------------------------------- 清空 / 删除

  clearProfilesConfirm(profiles: Array<Profile>, done: () => Promise<void>): void {
    AlertDialog.show({
      message: $r('app.string.confirm_clear_group', profiles.length),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: () => {
          void done();
        }
      }
    });
  }

  /** 清空订阅节点但保留订阅本身(下次更新即可拉回) */
  clearSubProfiles(sub: SubInfo): void {
    this.clearProfilesConfirm(this.subProfiles(sub.url), async () => {
      this.profiles = this.profiles.filter((p: Profile) => p.subUrl !== sub.url);
      await saveProfiles(this.profiles);
      await this.refresh();
      this.onDataChanged();
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

  // ---------------------------------------------------------------- 卡片与菜单

  /** 订阅分组卡:组名 + N 个节点 / M 个分组 / 上次更新 / 流量 / 到期 + 更新 / 详情 / ⋮ */
  @Builder
  private subCard(sub: SubInfo) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(sub.name)
          .fontSize(14.5).fontWeight(700).fontColor($r('app.color.text_1'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text($r('app.string.group_type_subscription'))
          .fontSize(10.5).fontColor($r('app.color.mono'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor($r('app.color.app_background'))
        Text(this.countText(this.nodeCountOfSub(sub.url)))
          .fontSize(11.5).fontColor($r('app.color.text_3'))
      }.width('100%')

      Row({ space: 10 }) {
        Text($r('app.string.group_sub_group_count', this.groupCountOfSub(sub.url)))
          .fontSize(11).fontColor($r('app.color.text_3'))
        Text(this.lastUpdateText(sub))
          .fontSize(11).fontColor($r('app.color.text_3'))
        if (sub.total > 0) {
          Text(this.subscriptionTrafficText(sub))
            .fontSize(11).fontWeight(600).fontColor($r('app.color.mono'))
        }
        if (sub.expire > 0) {
          Text(this.expireText(sub))
            .fontSize(11).fontColor($r('app.color.text_2'))
        }
      }.width('100%')

      if (this.updatingUrl === sub.url) {
        Row({ space: 6 }) {
          LoadingProgress().width(14).height(14).color($r('app.color.mono'))
          Text($r('app.string.updating')).fontSize(11).fontColor($r('app.color.text_3'))
        }.width('100%')
      }

      Row({ space: 4 }) {
        Text($r('app.string.update_action'))
          .fontSize(12.5).fontWeight(600).fontColor($r('app.color.mono'))
          .padding({ left: 6, right: 6, top: 8, bottom: 8 })
          .onClick(() => this.updateOne(sub))
        Text($r('app.string.subscription_detail_title'))
          .fontSize(12.5).fontWeight(600).fontColor($r('app.color.text_2'))
          .padding({ left: 6, right: 6, top: 8, bottom: 8 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/SubDetailPage', params: { url: sub.url } });
          })
        Blank()
        Text('⋮')
          .fontSize(16).fontWeight(700).fontColor($r('app.color.text_2'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .bindMenu(this.subOverflowMenu(sub))
      }.width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .border({ width: { bottom: UiSpec.HAIRLINE_WIDTH }, color: $r('app.color.hairline') })
  }

  @Builder
  private subOverflowMenu(sub: SubInfo) {
    Menu() {
      MenuItem({ content: $r('app.string.share_sub_link') })
        .onClick(() => this.shareSubLink(sub))
      MenuItem({ content: $r('app.string.export_all_nodes') })
        .onClick(() => this.copyLinksToClipboard(this.subProfiles(sub.url)))
      MenuItem({ content: $r('app.string.export_all_nodes_file') })
        .onClick(() => this.writeLinksToFile(sub.name, this.subProfiles(sub.url)))
      MenuItem({ content: $r('app.string.clear_group') })
        .onClick(() => this.clearSubProfiles(sub))
      MenuItem({ content: $r('app.string.delete'), labelInfo: $r('app.string.irreversible') })
        .onClick(() => this.deleteSub(sub))
    }
  }

  build() {
    Column() {
      // 顶栏:抽屉 + 标题 + 新建分组 + 更新全部(对齐安卓 toolbar_menu:new_group / update_all)
      Row({ space: 4 }) {
        DrawerButton({ onOpen: () => this.onOpenDrawer() })
        Text($r('app.string.nav_groups'))
          .fontSize(16).fontWeight(800).fontColor($r('app.color.text_1')).layoutWeight(1)
        Text($r('app.string.add_group'))
          .fontSize(13.5).fontWeight(600).fontColor($r('app.color.primary'))
          .padding(8)
          .onClick(() => this.createDialog.open())
        Text(this.updatingAll ? $r('app.string.updating') : $r('app.string.update_all_subs'))
          .fontSize(13.5).fontWeight(600).fontColor($r('app.color.mono'))
          .padding(8)
          .onClick(() => this.updateAll())
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING - 10, right: UiSpec.PAGE_PADDING - 10, top: 26 })

      List() {
        ForEach(this.subscriptions, (sub: SubInfo) => {
          ListItem() {
            this.subCard(sub)
          }
        }, (sub: SubInfo) => `sub_${sub.url}`)

        if (this.subscriptions.length === 0) {
          ListItem() {
            Column({ space: 6 }) {
              Text($r('app.string.groups_empty'))
                .fontSize(13).fontColor($r('app.color.text_3'))
                .width('100%')
                .textAlign(TextAlign.Center)
              Text($r('app.string.group_sub_note'))
                .fontSize(11).fontColor($r('app.color.text_3'))
                .width('100%')
                .textAlign(TextAlign.Center)
            }
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

/** 新建分组弹窗(用户 m02296:只保留订阅分组):名称 + 订阅链接 + 是否立即拉取 */
@CustomDialog
struct CreateGroupDialog {
  controller?: CustomDialogController;
  @State name: string = '';
  @State url: string = '';
  @State fetchNow: boolean = true;
  @State errorKey: string = '';
  onCreateSubscription: (name: string, url: string, fetchNow: boolean) => void = (name: string, url: string, fetchNow: boolean) => {};

  build() {
    Column({ space: 10 }) {
      Text($r('app.string.add_group'))
        .fontSize(16).fontWeight(700).width('100%')
      Text($r('app.string.group_sub_note'))
        .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')

      TextInput({ text: this.name, placeholder: $r('app.string.new_group_hint') })
        .height(UiSpec.BTN_HEIGHT)
        .onChange((v: string) => {
          this.name = v;
          this.errorKey = '';
        })

      TextInput({ text: this.url, placeholder: $r('app.string.group_sub_link_hint') })
        .height(UiSpec.BTN_HEIGHT)
        .onChange((v: string) => {
          this.url = v;
          this.errorKey = '';
        })

      Row() {
        Text($r('app.string.group_sub_fetch_now'))
          .fontSize(13).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.fetchNow })
          .onChange((on: boolean) => { this.fetchNow = on; })
      }.width('100%')

      if (this.errorKey === 'url') {
        Text($r('app.string.group_sub_url_required'))
          .fontSize(12).fontColor($r('app.color.error')).width('100%')
      }

      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button($r('app.string.save'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => this.submit())
      }.width('100%')
    }
    .padding(16)
    .width('100%')
  }

  private submit(): void {
    const url = this.url.trim();
    if (!(url.startsWith('http://') || url.startsWith('https://'))) {
      this.errorKey = 'url';
      return;
    }
    if (this.controller !== undefined) {
      this.controller.close();
    }
    this.onCreateSubscription(this.name.trim(), url, this.fetchNow);
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
