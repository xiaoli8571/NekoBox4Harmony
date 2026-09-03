import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { RouteRule, RemoteRuleSet, loadRouteRules, saveRouteRules, loadRemoteRuleSets, saveRemoteRuleSets } from '../model/RouteRule';

@Entry
@Component
struct RouteRulesPage {
  @State rules: Array<RouteRule> = [];
  @State remoteRuleSets: Array<RemoteRuleSet> = [];
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
      this.remoteRuleSets = await loadRemoteRuleSets();
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  async persist(): Promise<void> {
    await saveRouteRules(this.rules);
  }

  async persistRemoteRuleSets(): Promise<void> {
    await saveRemoteRuleSets(this.remoteRuleSets);
  }

  addRemoteRuleSet(): void {
    const item = new RemoteRuleSet();
    item.id = `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    const next = this.remoteRuleSets.slice();
    next.push(item);
    this.remoteRuleSets = next;
    this.persistRemoteRuleSets();
  }

  updateRemoteRuleSet(index: number, field: string, value: Object): void {
    const next = this.remoteRuleSets.slice();
    const item = next[index];
    if (field === 'name') {
      item.name = value as string;
    } else if (field === 'url') {
      item.url = value as string;
    } else if (field === 'type') {
      item.type = value as string;
    } else if (field === 'outbound') {
      item.outbound = value as string;
    } else if (field === 'enabled') {
      item.enabled = value as boolean;
    }
    item.updatedAt = Date.now();
    item.lastError = '';
    next[index] = item;
    this.remoteRuleSets = next;
    this.persistRemoteRuleSets();
  }

  removeRemoteRuleSet(index: number): void {
    const next = this.remoteRuleSets.slice();
    next.splice(index, 1);
    this.remoteRuleSets = next;
    this.persistRemoteRuleSets();
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

      Column({ space: 10 }) {
        Row() {
          Text($r('app.string.remote_rule_sets'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
          Button($r('app.string.add_remote_rule_set'))
            .height(34)
            .onClick(() => this.addRemoteRuleSet())
        }
        .width('100%')

        ForEach(this.remoteRuleSets, (item: RemoteRuleSet, index: number) => {
          Column({ space: 8 }) {
            Row() {
              TextInput({ text: item.name, placeholder: $r('app.string.remote_rule_set_name') })
                .layoutWeight(1)
                .onChange((value: string) => this.updateRemoteRuleSet(index, 'name', value))
              Toggle({ type: ToggleType.Switch, isOn: item.enabled })
                .onChange((value: boolean) => this.updateRemoteRuleSet(index, 'enabled', value))
            }
            .width('100%')

            TextInput({ text: item.url, placeholder: $r('app.string.remote_rule_set_url') })
              .width('100%')
              .onChange((value: string) => this.updateRemoteRuleSet(index, 'url', value))

            Row({ space: 8 }) {
              Button($r('app.string.rule_set_site'))
                .layoutWeight(1)
                .backgroundColor(item.type === 'site' ? $r('app.color.primary') : $r('app.color.divider'))
                .fontColor(item.type === 'site' ? $r('app.color.surface') : $r('app.color.text_primary'))
                .onClick(() => this.updateRemoteRuleSet(index, 'type', 'site'))
              Button($r('app.string.rule_set_ip'))
                .layoutWeight(1)
                .backgroundColor(item.type === 'ip' ? $r('app.color.primary') : $r('app.color.divider'))
                .fontColor(item.type === 'ip' ? $r('app.color.surface') : $r('app.color.text_primary'))
                .onClick(() => this.updateRemoteRuleSet(index, 'type', 'ip'))
            }
            .width('100%')

            Row({ space: 8 }) {
              Button($r('app.string.mode_direct'))
                .layoutWeight(1)
                .backgroundColor(item.outbound === 'direct' ? $r('app.color.primary') : $r('app.color.divider'))
                .fontColor(item.outbound === 'direct' ? $r('app.color.surface') : $r('app.color.text_primary'))
                .onClick(() => this.updateRemoteRuleSet(index, 'outbound', 'direct'))
              Button($r('app.string.proxy'))
                .layoutWeight(1)
                .backgroundColor(item.outbound === 'proxy' ? $r('app.color.primary') : $r('app.color.divider'))
                .fontColor(item.outbound === 'proxy' ? $r('app.color.surface') : $r('app.color.text_primary'))
                .onClick(() => this.updateRemoteRuleSet(index, 'outbound', 'proxy'))
            }
            .width('100%')

            if (item.updatedAt > 0) {
              Text($r('app.string.remote_rule_set_updated', new Date(item.updatedAt).toLocaleString()))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
            if (item.lastError.length > 0) {
              Text($r('app.string.remote_rule_set_error', item.lastError))
                .fontSize(11)
                .fontColor($r('app.color.error'))
                .width('100%')
            }
            Text($r('app.string.delete_rule'))
              .fontSize(13)
              .fontColor($r('app.color.error'))
              .padding(6)
              .onClick(() => this.removeRemoteRuleSet(index))
          }
          .width('100%')
          .padding(12)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(12)
        }, (item: RemoteRuleSet) => item.id)
      }
      .width('100%')
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 12 })

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
