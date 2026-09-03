import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
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
      message: $r('app.string.confirm_delete_route_rule'),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
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
    Column() {
      Row() {
        Text('←').fontSize(22).padding(8).onClick(() => router.back())
        Text($r('app.string.route_rules_title')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button($r('app.string.add')).height(34).onClick(() => this.addRule())
      }.width('100%').padding(12)

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(32)
            .height(32)
            .color($r('app.color.primary'))
          Text($r('app.string.loading_route_rules'))
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .padding({ top: 36, bottom: 20 })
      } else if (this.loadError.length > 0) {
        Column({ space: 8 }) {
          Text($r('app.string.route_rules_load_failed'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.loadError)
            .fontSize(13)
            .fontColor($r('app.color.error'))
          Button($r('app.string.reload'))
            .height(36)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => this.load())
        }
        .width('100%')
        .padding({ top: 28, bottom: 20 })
      } else if (this.rules.length === 0) {
        Column({ space: 8 }) {
          Text($r('app.string.no_route_rules'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text($r('app.string.route_rule_empty_hint'))
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
                TextInput({ text: rule.remark, placeholder: $r('app.string.route_rule_remark') })
                  .layoutWeight(1)
                  .onChange((value: string) => this.updateRule(index, 'remark', value))
                Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
                  .onChange((value: boolean) => this.updateRule(index, 'enabled', value))
              }.width('100%')

              Select([
                { value: $r('app.string.domain') },
                { value: $r('app.string.domain_suffix') },
                { value: $r('app.string.domain_keyword') },
                { value: 'IP CIDR' },
                { value: $r('app.string.port') }
              ])
                .selected(['domain', 'domain_suffix', 'domain_keyword', 'ip_cidr', 'port'].indexOf(rule.type))
                .onSelect((indexValue: number) => {
                  const types: Array<string> = ['domain', 'domain_suffix', 'domain_keyword', 'ip_cidr', 'port'];
                  this.updateRule(index, 'type', types[indexValue]);
                })

              TextArea({ text: rule.value, placeholder: $r('app.string.comma_separated_values') })
                .height(80)
                .onChange((value: string) => this.updateRule(index, 'value', value))

              Row({ space: 8 }) {
                ForEach(['proxy', 'direct', 'reject'], (outbound: string) => {
                  Button(outbound === 'proxy' ? $r('app.string.proxy') : outbound === 'direct' ? $r('app.string.mode_direct') : $r('app.string.reject'))
                    .layoutWeight(1)
                    .backgroundColor(rule.outbound === outbound ? $r('app.color.primary') : $r('app.color.divider'))
                    .fontColor(rule.outbound === outbound ? $r('app.color.surface') : $r('app.color.text_primary'))
                    .onClick(() => this.updateRule(index, 'outbound', outbound))
                })
              }.width('100%')

              Text($r('app.string.delete_rule')).fontSize(13).fontColor($r('app.color.error')).padding(6)
                .onClick(() => this.removeRule(index))
            }
            .width('100%')
            .padding(12)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(12)
          }
        }, (rule: RouteRule, index: number) => `${index}_${rule.remark}_${rule.type}`)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING })

      Text($r('app.string.route_rule_order_hint'))
        .fontSize(12).fontColor($r('app.color.text_secondary')).padding(12)
    }
    .width('100%')
    .height('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('app.color.app_background'))
    .width('100%').height('100%').backgroundColor($r('app.color.app_background'))
  }
}
