import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { Profile, AppSettings, profileTypeLabel } from '../model/Profile';
import { ProfileStorage } from '../common/storage/ProfileStorage';
import { ConnectionStateManager } from '../common/manager/ConnectionStateManager';
import { fetchTrafficTotals } from '../utils/TrafficStats';
import { geoReady } from '../utils/GeoAssets';
import { CoreManager } from '../core/CoreManager';
import { setClipboardText } from '../utils/ClipboardHelper';
import promptAction from '@ohos.promptAction';
import { currentLanguage, isEnglish, t } from '../utils/I18n';

interface DiagnosticItem {
  title: string;
  detail: string;
  ok: boolean;
}

/**
 * A safe, read-only diagnostic report.  It deliberately does not mutate VPN
 * state or restart the core; users can run it while connected or disconnected.
 */
@Entry
@Component
struct DiagnosticsPage {
  @State checks: Array<DiagnosticItem> = [];
  @State running: boolean = false;
  @State busy: boolean = false;
  @State generatedAt: number = 0;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.runDiagnostics();
  }

  private async runDiagnostics(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const lang = currentLanguage();
    const english = isEnglish(lang);
    const result: Array<DiagnosticItem> = [];
    try {
      const vpnRunning = AppStorage.get<boolean>('vpnRunning') ?? false;
      const vpnStatus = AppStorage.get<string>('vpnStatus') ?? (english ? 'Disconnected' : '未连接');
      const state = ConnectionStateManager.current();
      this.running = vpnRunning;
      result.push({
        title: english ? 'VPN state' : 'VPN 状态',
        detail: `${vpnRunning ? (english ? 'Connected' : '已连接') : (english ? 'Disconnected' : '未连接')} · ${state} · ${vpnStatus}`,
        ok: vpnRunning
      });

      await ProfileStorage.initialize(this.context);
      const profiles = await ProfileStorage.profiles();
      const runningId = AppStorage.get<string>('vpnRunningProfileId') ?? '';
      const runningProfile = profiles.find((p: Profile) => p.id === runningId);
      result.push({
        title: english ? 'Profiles' : '节点',
        detail: runningProfile === undefined
          ? `${profiles.length} ${english ? 'available' : '个可用'}`
          : `${profiles.length} ${english ? 'available' : '个可用'} · ${runningProfile.name} (${profileTypeLabel(runningProfile.type)})`,
        ok: profiles.length > 0
      });

      const settings: AppSettings = await ProfileStorage.settings();
      const dnsOk = settings.remoteDns.trim().length > 0 && settings.directDns.trim().length > 0;
      result.push({
        title: english ? 'DNS settings' : 'DNS 设置',
        detail: `remote=${settings.remoteDns || '-'} · direct=${settings.directDns || '-'}`,
        ok: dnsOk
      });
      result.push({
        title: english ? 'Routing mode' : '路由模式',
        detail: settings.mode,
        ok: settings.mode === 'rule' || settings.mode === 'global' || settings.mode === 'direct'
      });

      const totals = vpnRunning ? await fetchTrafficTotals() : null;
      result.push({
        title: english ? 'Clash API' : '内核接口',
        detail: totals === null
          ? (english ? 'Unavailable (VPN may be stopped)' : '暂不可用（VPN 可能未运行）')
          : (english ? 'Reachable · traffic counters are live' : '可访问 · 流量计数正常'),
        ok: totals !== null || !vpnRunning
      });

      const geoOk = geoReady(this.context);
      result.push({
        title: english ? 'Geo resources' : 'Geo 资源',
        detail: geoOk
          ? (english ? 'Ready' : '已就绪')
          : (english ? 'Not downloaded; rule mode still works for custom rules' : '未下载；规则模式仍可使用自定义规则'),
        ok: geoOk || settings.mode !== 'rule'
      });

      let logDetail = english ? 'Log file not created yet' : '日志文件尚未创建';
      let logOk = false;
      try {
        const path = CoreManager.logFilePath(this.context);
        if (fs.accessSync(path)) {
          const stat = fs.statSync(path);
          logDetail = `${stat.size} bytes`;
          logOk = true;
        }
      } catch (e) {
        // Keep the diagnostic report usable even if the file is absent.
      }
      result.push({ title: english ? 'Core log' : '内核日志', detail: logDetail, ok: logOk || !vpnRunning });
      this.checks = result;
      this.generatedAt = Date.now();
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      result.push({
        title: english ? 'Diagnostic error' : '诊断异常',
        detail: message,
        ok: false
      });
      this.checks = result;
      this.generatedAt = Date.now();
    } finally {
      this.busy = false;
    }
  }

  private reportText(): string {
    const lang = currentLanguage();
    const title = isEnglish(lang) ? 'NekoBox diagnostics' : 'NekoBox 诊断报告';
    const lines: Array<string> = [title, new Date(this.generatedAt > 0 ? this.generatedAt : Date.now()).toISOString()];
    for (const item of this.checks) {
      lines.push(`${item.ok ? '[OK]' : '[WARN]'} ${item.title}: ${item.detail}`);
    }
    return lines.join('\n');
  }

  private async exportReport(): Promise<void> {
    try {
      await setClipboardText(this.reportText());
      const lang = currentLanguage();
      promptAction.showToast({ message: isEnglish(lang) ? 'Diagnostic report copied' : '诊断报告已复制到剪贴板' });
    } catch (e) {
      promptAction.showToast({ message: isEnglish(currentLanguage()) ? 'Export failed' : '导出失败' });
    }
  }

  // build() 顶层只允许组件树(不允许变量声明),语言状态用方法取。
  private en(): boolean {
    return isEnglish(currentLanguage());
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text(t('diagnostics')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button(this.busy ? (this.en() ? 'Running…' : '检测中…') : t('refresh'))
          .height(32).onClick(() => this.runDiagnostics())
      }.width('100%').padding(12)

      Scroll() {
        Column({ space: 8 }) {
          if (this.checks.length === 0) {
            Text(this.en() ? 'No report yet' : '尚未生成报告').fontSize(13).fontColor('#888888').width('100%')
          }
          ForEach(this.checks, (item: DiagnosticItem, index: number) => {
            Row({ space: 8 }) {
              Text(item.ok ? '✓' : '!').fontSize(17).fontColor(item.ok ? '#2E7D32' : '#F57C00')
              Column({ space: 3 }) {
                Text(item.title).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
                Text(item.detail).fontSize(12).fontColor('#666666').width('100%').maxLines(4)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            }.width('100%').padding(12).borderRadius(10).backgroundColor('#FFFFFF')
          }, (item: DiagnosticItem, index: number) => `${index}_${item.title}`)
          if (this.generatedAt > 0) {
            Text(`${this.en() ? 'Generated' : '生成于'} ${new Date(this.generatedAt).toLocaleString()}`)
              .fontSize(11).fontColor('#999999').width('100%').textAlign(TextAlign.Center)
          }
          Button(this.en() ? 'Copy report' : '复制报告').width('100%').onClick(() => this.exportReport())
        }.width('100%').padding(12)
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#F2F4F7')
  }
}
