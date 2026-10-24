// SubUpdateFeedback.ets — 订阅更新结果反馈(Android GroupInterfaceAdapter.kt:29-82 的可见效果)
//
// Android 行为(逐项):
//  - changed==0 且 duplicate 为空 → snackbar「%s: No difference」(group_no_difference)
//  - 否则 → snackbar「%s: Updated %d proxies」(group_updated),1 秒后弹「Diff (%s)」对话框:
//    Added / Updated(old => new) / Deleted / Duplicate 四段,段内 \n join、段间空行;
//    空段整段省略;正文 trim 后显示(GroupInterfaceAdapter.kt:47-68,:75-77)
//  - 失败 → snackbar 原文(:84-88)
//
// UI 接线由 Lead 完成(不要动 Index.ets);本文件只提供对话框组件与纯函数视图。
// 文案键由 Lead 统一补进 string.json(test-parity 本轮独占该文件)。

import { SubUpdateResult, subUpdateDiffBodies, subUpdateHasChanges, SubDiffBodies } from '../core/Subscriptions';

/**
 * Diff 对话框(Android「Diff (%s)」)。
 * @CustomDialog 由宿主页面传入 controller;四段中空段整段省略。
 */
@CustomDialog
export struct SubDiffDialog {
  controller?: CustomDialogController;
  // 用 @Prop(而非 @Link):对话框每次按当次结果新建,内容是快照,不需要回写父组件状态。
  @Prop groupName: string = '';
  @Prop res: SubUpdateResult = {
    added: 0, removed: 0, total: 0, notModified: false, skipped: 0, skippedNames: [], note: '',
    changed: 0, addedNames: [], updatedNames: [], deletedNames: [], duplicateNames: []
  };

  build() {
    Column({ space: 8 }) {
      Text($r('app.string.group_diff_title', this.groupName))
        .fontSize(16).fontWeight(700).fontColor($r('app.color.text_primary'))
        .width('100%')
      if (this.res.addedNames.length > 0) {
        Text($r('app.string.group_diff_added', subUpdateDiffBodies(this.res.addedNames,
          this.res.updatedNames, this.res.deletedNames, this.res.duplicateNames).added))
          .fontSize(13).fontColor($r('app.color.text_primary')).width('100%')
      }
      if (this.res.updatedNames.length > 0) {
        Text($r('app.string.group_diff_updated', subUpdateDiffBodies(this.res.addedNames,
          this.res.updatedNames, this.res.deletedNames, this.res.duplicateNames).updated))
          .fontSize(13).fontColor($r('app.color.text_primary')).width('100%')
      }
      if (this.res.deletedNames.length > 0) {
        Text($r('app.string.group_diff_deleted', subUpdateDiffBodies(this.res.addedNames,
          this.res.updatedNames, this.res.deletedNames, this.res.duplicateNames).deleted))
          .fontSize(13).fontColor($r('app.color.text_primary')).width('100%')
      }
      if (this.res.duplicateNames.length > 0) {
        Text($r('app.string.group_diff_duplicate', subUpdateDiffBodies(this.res.addedNames,
          this.res.updatedNames, this.res.deletedNames, this.res.duplicateNames).duplicate))
          .fontSize(13).fontColor($r('app.color.text_2')).width('100%')
      }
      Blank().height(4)
      Button($r('app.string.ok'))
        .width('100%').height(40)
        .onClick(() => { this.controller?.close(); })
    }.padding(16).alignItems(HorizontalAlign.Start)
  }
}

/**
 * 更新成功后的提示语义(供页面侧组装 snackbar 文案):
 *  - 无变化:group_no_difference(格式化参数 = 组名)
 *  - 有变化:group_updated(格式化参数 = 组名 + changed 数)
 * 这里只做**判定**,返回文案键名,避免组件内散落分支。
 */
export function subUpdateToastKind(res: SubUpdateResult): string {
  return subUpdateHasChanges(res) ? 'group_updated' : 'group_no_difference';
}

/** Diff 四段(空段保留为空串),供页面把四段渲染成 Android 的布局并自行 trim。 */
export function subDiffSections(res: SubUpdateResult): SubDiffBodies {
  return subUpdateDiffBodies(res.addedNames, res.updatedNames, res.deletedNames, res.duplicateNames);
}
