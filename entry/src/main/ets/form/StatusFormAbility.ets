import FormExtensionAbility from '@ohos.app.form.FormExtensionAbility';
import formBindingData from '@ohos.app.form.formBindingData';
import formInfo from '@ohos.app.form.formInfo';
import Want from '@ohos.app.ability.Want';
import { LogStore } from '../model/Store';

/**
 * 桌面服务卡片(静态卡)。
 *
 * 为什么是"静态":
 *  - 卡片跑在**卡片宿主进程**,拿不到 :vpn 进程里 VpnExtAbility 的内存状态,
 *    要显示真实连接状态得靠 formProvider.updateForm 从主进程推送,而主进程可能没活着;
 *  - 退一步用定时刷新 + 只展示"点开查看",既不会给出过期的假状态,也不需要常驻进程。
 * 需要真实状态时由 UI 侧调用 updateForm 推送(见 forms/FormBridge.ets 的 updateAll)。
 */
export default class StatusFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    LogStore.addLog('[form] 添加桌面卡片');
    return formBindingData.createFormBindingData({
      'title': 'NekoBox',
      'status': '已就绪',
      'hint': '点击打开查看连接状态'
    });
  }

  onUpdateForm(formId: string): void {
    // 静态卡:内容不依赖进程内状态,定时刷新时原样回写即可。
    // 真要做动态值,在这里用 formProvider.updateForm(formId, data) 推送。
    LogStore.addLog(`[form] 刷新卡片 ${formId}`);
  }

  onFormEvent(formId: string, message: string): void {
    LogStore.addLog(`[form] 卡片事件 ${formId}: ${message}`);
  }

  onRemoveForm(formId: string): void {
    LogStore.addLog(`[form] 移除卡片 ${formId}`);
  }
}
