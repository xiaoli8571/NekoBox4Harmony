import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { RouteRule, loadRouteRules, saveRouteRules } from '../model/RouteRule';

@Entry
@Component
struct RouteRulesPage {
  @State rules: Array<RouteRule> = [];
  @State loading: boolean = true;
  @State loadError: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      this.rules = await loadRouteRules();
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  async persist(): Promise<void> {
    await saveRouteRules(this.rules);
  }

  addRule(): void {
    const next = this.rules.slice();
    next.push(new RouteRule());
    this.rules = next;
    this.persist();
  }

  removeRule(index: number): void {
    AlertDialog.show({
      message: '删除这条路由规则?',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: '#E53935',
        action: () => {
          const next = this.rules.slice();
          next.splice(index, 1);
          this.rules = next;
          this.persist();
        }
      }
    });
  }

  updateRule(index: number, field: string, value: Object): void {
    const next = this.rules.slice();
    const rule = next[index];
    if (field === 'remark') {
      rule.remark = value as string;
    } else if (field === 'enabled') {
      rule.enabled = value as boolean;
    } else if (field === 'type') {
      rule.type = value as string;
    } else if (field === 'value') {
      rule.value = value as string;
    } else if (field === 'outbound') {
      rule.outbound = value as string;
    }
    next[index] = rule;
    this.rules = next;
    this.persist();
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).padding(8).onClick(() => router.back())
        Text('自定义路由规则').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('添加').height(34).onClick(() => this.addRule())
      }.width('100%').padding(12)

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.primary'))
          Text('正在加载路由规则…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      } else if (this.loadError.length > 0) {
        Column({ space: 8 }) {
          Text('路由规则加载失败')
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
        .width('100%')
        .padding({ top: 28, bottom: 20 })
      } else if (this.rules.length === 0) {
        Column({ space: 8 }) {
          Text('暂无自定义路由规则')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text('点击右上角“添加”创建第一条规则。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      }

      List({ space: 10 }) {
        ForEach(this.rules, (rule: RouteRule, index: number) => {
          ListItem() {
            Column({ space: 8 }) {
              Row() {
                TextInput({ text: rule.remark, placeholder: '规则备注' })
                  .layoutWeight(1)
                  .onChange((value: string) => this.updateRule(index, 'remark', value))
                Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
                  .onChange((value: boolean) => this.updateRule(index, 'enabled', value))
              }.width('100%')

              Select([
                { value: '完整域名' },
                { value: '域名后缀' },
                { value: '域名关键字' },
                { value: 'IP CIDR' },
                { value: '端口' }
              ])
                .selected(['domain', 'domain_suffix', 'domain_keyword', 'ip_cidr', 'port'].indexOf(rule.type))
                .onSelect((indexValue: number) => {
                  const types: Array<string> = ['domain', 'domain_suffix', 'domain_keyword', 'ip_cidr', 'port'];
                  this.updateRule(index, 'type', types[indexValue]);
                })

              TextArea({ text: rule.value, placeholder: '多个值使用英文逗号分隔' })
                .height(80)
                .onChange((value: string) => this.updateRule(index, 'value', value))

              Row({ space: 8 }) {
                ForEach(['proxy', 'direct', 'reject'], (outbound: string) => {
                  Button(outbound === 'proxy' ? '代理' : outbound === 'direct' ? '直连' : '拒绝')
                    .layoutWeight(1)
                    .backgroundColor(rule.outbound === outbound ? '#1E88E5' : '#E0E0E0')
                    .fontColor(rule.outbound === outbound ? '#FFFFFF' : '#333333')
                    .onClick(() => this.updateRule(index, 'outbound', outbound))
                })
              }.width('100%')

              Text('删除规则').fontSize(13).fontColor('#E53935').padding(6)
                .onClick(() => this.removeRule(index))
            }
            .width('100%')
            .padding(12)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
          }
        }, (rule: RouteRule, index: number) => `${index}_${rule.remark}_${rule.type}`)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12 })

      Text('规则按列表顺序匹配，修改后重新连接 VPN 生效。')
        .fontSize(12).fontColor('#666666').padding(12)
    }
    .width('100%').height('100%').backgroundColor('#F2F4F7')
  }
}
