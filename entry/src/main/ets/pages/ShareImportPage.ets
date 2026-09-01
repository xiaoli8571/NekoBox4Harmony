import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { importShareText, ShareImportResult } from '../utils/ShareImport';
import { getClipboardText } from '../utils/ClipboardHelper';
import { currentLanguage, isEnglish, t } from '../utils/I18n';

/** UI for text/plain shares.  EntryAbility places incoming text in
 * AppStorage('pendingShareText'); the page consumes it exactly once. */
@Entry
@Component
struct ShareImportPage {
  @State text: string = '';
  @State busy: boolean = false;
  @State resultText: string = '';
  @StorageLink('pendingShareText') pendingText: string = '';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.consumePendingText();
  }

  onPageShow(): void {
    this.consumePendingText();
  }

  private consumePendingText(): void {
    if (this.pendingText.trim().length === 0) {
      return;
    }
    this.text = this.pendingText;
    AppStorage.setOrCreate('pendingShareText', '');
    this.importNow();
  }

  private async paste(): Promise<void> {
    const value = await getClipboardText();
    if (value.trim().length === 0) {
      promptAction.showToast({ message: isEnglish(currentLanguage()) ? 'Clipboard is empty' : '剪贴板为空' });
      return;
    }
    this.text = value;
  }

  private async importNow(): Promise<void> {
    if (this.busy) {
      return;
    }
    const raw = this.text.trim();
    if (raw.length === 0) {
      promptAction.showToast({ message: isEnglish(currentLanguage()) ? 'Paste share text first' : '请先粘贴分享内容' });
      return;
    }
    this.busy = true;
    try {
      const result: ShareImportResult = await importShareText(this.context, raw);
      const lang = currentLanguage();
      const english = isEnglish(lang);
      this.resultText = result.subscriptionUrl.length > 0
        ? `${english ? 'Imported' : '已导入'} ${result.imported} ${english ? 'profiles from' : '个节点，订阅'} ${result.subscriptionName}`
        : `${english ? 'Imported' : '已导入'} ${result.imported} ${english ? 'profiles' : '个节点'}`;
      if (result.skipped > 0) {
        this.resultText += ` · ${english ? 'skipped' : '跳过'} ${result.skipped}`;
      }
      promptAction.showToast({ message: this.resultText });
      this.text = '';
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      this.resultText = message;
      promptAction.showToast({ message: `${isEnglish(currentLanguage()) ? 'Import failed' : '导入失败'}: ${message}` });
    } finally {
      this.busy = false;
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
        Text(this.en() ? 'Import share' : '导入分享').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
      }.width('100%').padding(12)
      Scroll() {
        Column({ space: 10 }) {
          Text(this.en()
            ? 'Share a text/plain node link or subscription. Base64 lists and Clash YAML are supported.'
            : '接收 text/plain 节点链接或订阅，支持 Base64 列表和 Clash YAML。')
            .fontSize(13).fontColor('#666666').width('100%')
          TextArea({
            text: this.text,
            placeholder: this.en() ? 'vless://, vmess://, ss://, https://…' : 'vless://、vmess://、ss://、https://…'
          })
            .height(180).width('100%')
            .onChange((value: string) => { this.text = value; })
          Row({ space: 8 }) {
            Button(this.en() ? 'Paste clipboard' : '读取剪贴板').layoutWeight(1).onClick(() => this.paste())
            Button(this.busy ? (this.en() ? 'Importing…' : '导入中…') : (this.en() ? 'Import' : '导入'))
              .layoutWeight(1).backgroundColor(this.busy ? '#AAAAAA' : '#1E88E5')
              .onClick(() => this.importNow())
          }.width('100%')
          if (this.resultText.length > 0) {
            Text(this.resultText).fontSize(13).fontColor('#555555').width('100%').maxLines(4)
          }
          Text(this.en()
            ? 'HTTP(S) addresses are downloaded as subscriptions first; if that fails, a valid HTTP proxy link is used as a fallback.'
            : 'HTTP(S) 地址优先按订阅下载；下载失败时，只有合法 HTTP 代理链接才会回退为单节点。')
            .fontSize(11).fontColor('#999999').width('100%')
        }.width('100%').padding(12)
      }.layoutWeight(1)
    }.width('100%').height('100%').backgroundColor('#F2F4F7')
  }
}

