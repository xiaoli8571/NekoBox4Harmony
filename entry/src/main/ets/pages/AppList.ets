import common from '@ohos.app.ability.common';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { AppSettings } from '../model/Profile';
import { ProfileStorage } from '../common/storage/ProfileStorage';

/**
 * 分应用代理列表。
 * Harmony 普通应用没有 Android PackageManager 的完整枚举权限，因此采用
 * 包名搜索/多选编辑；VpnExtAbility 仍强制把自身包名加入 blockedApplications。
 */
@Entry
@Component
struct AppList {
  @State private packageNames: Array<string> = [];
  @State private query: string = '';
  @State private newPackage: string = '';
  @State private mode: string = 'off';
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    ProfileStorage.initialize(this.context).then(async () => {
      const settings: AppSettings = await ProfileStorage.settings();
      this.mode = settings.perAppMode === 'exclude' ? 'exclude' : 'off';
      this.packageNames = settings.perAppList.split(',')
        .map((v: string) => v.trim())
        .filter((v: string) => v.length > 0);
    });
  }

  private visiblePackages(): Array<string> {
    const q = this.query.trim().toLowerCase();
    if (q.length === 0) {
      return this.packageNames;
    }
    return this.packageNames.filter((name: string) => name.toLowerCase().includes(q));
  }

  private addPackage(): void {
    const value = this.newPackage.trim();
    if (value.length === 0 || this.packageNames.includes(value)) {
      return;
    }
    this.packageNames = [...this.packageNames, value];
    this.newPackage = '';
  }

  private async save(): Promise<void> {
    const settings: AppSettings = await ProfileStorage.settings();
    settings.perAppMode = this.mode;
    settings.perAppList = this.packageNames.join(',');
    await ProfileStorage.saveSettings(settings);
    promptAction.showToast({ message: '分应用代理设置已保存，重连 VPN 后生效' });
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text('分应用代理').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('保存').height(34).onClick(() => this.save())
      }.width('100%').padding(12)

      Column({ space: 12 }) {
        Text('选择不经过 VPN 的应用').fontSize(13).fontColor('#666').width('100%')
        Row({ space: 8 }) {
          Button(this.mode === 'exclude' ? '排除模式已开启' : '开启排除模式')
            .backgroundColor(this.mode === 'exclude' ? '#2E7D32' : '#F5F5F5')
            .fontColor(this.mode === 'exclude' ? '#FFFFFF' : '#333333')
            .onClick(() => { this.mode = this.mode === 'exclude' ? 'off' : 'exclude'; })
          Text('应用自身始终被排除以防止 VPN 回环').fontSize(11).fontColor('#999').layoutWeight(1)
        }.width('100%')
        TextInput({ text: this.newPackage, placeholder: '输入 BundleName，例如 com.example.app' })
          .width('100%').height(42).onChange((v: string) => { this.newPackage = v; })
        Button('添加应用').width('100%').height(40).onClick(() => this.addPackage())
        TextInput({ text: this.query, placeholder: '搜索已添加的应用' })
          .width('100%').height(40).onChange((v: string) => { this.query = v; })
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.visiblePackages(), (name: string) => {
              Row() {
                Text(name).fontSize(14).layoutWeight(1)
                Button('删除').height(30).onClick(() => {
                  this.packageNames = this.packageNames.filter((v: string) => v !== name);
                })
              }.width('100%').padding({ left: 10, right: 6, top: 8, bottom: 8 })
                .backgroundColor('#F7F8FA').borderRadius(8)
            }, (name: string) => name)
            if (this.packageNames.length === 0) {
              Text('暂无排除应用').fontSize(13).fontColor('#999').margin({ top: 20 })
            }
          }.width('100%')
        }.layoutWeight(1).width('100%')
      }.padding({ left: 16, right: 16, bottom: 16 }).layoutWeight(1)
    }.width('100%').height('100%')
  }
}
