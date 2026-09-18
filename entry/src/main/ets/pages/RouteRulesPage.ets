import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { Profile } from '../model/Profile';
import { loadProfiles } from '../model/Store';
import { DrawerButton } from '../common/components/DrawerButton';
import { RouteRule, RemoteRuleSet, loadRouteRules, saveRouteRules, loadRemoteRuleSets, saveRemoteRuleSets } from '../model/RouteRule';

/** 路由规则面板(抽屉内嵌页签,对齐安卓 RouteFragment;不再是独立路由页) */
@Component
export struct RouteRulesPanel {
  @State profiles: Array<Profile> = [];
  @State rules: Array<RouteRule> = [];
  @State remoteRuleSets: Array<RemoteRuleSet> = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  onOpenDrawer: () => void = () => {};

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      this.profiles = await loadProfiles();
      this.rules = await loadRouteRules();
      this.remoteRuleSets = await loadRemoteRuleSets();
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  private persistTimer: number = -1;
  private persistRemoteTimer: number = -1;

  persist(): void {
    if (this.persistTimer >= 0) {
      clearTimeout(this.persistTimer);
    }
    this.persistTimer = setTimeout(() => {
      this.persistTimer = -1;
      saveRouteRules(this.rules);
    }, 1000);
  }

  persistRemoteRuleSets(): void {
    if (this.persistRemoteTimer >= 0) {
      clearTimeout(this.persistRemoteTimer);
    }
    this.persistRemoteTimer = setTimeout(() => {
      this.persistRemoteTimer = -1;
      saveRemoteRuleSets(this.remoteRuleSets);
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.persistTimer >= 0) {
      clearTimeout(this.persistTimer);
      this.persistTimer = -1;
      saveRouteRules(this.rules);
    }
    if (this.persistRemoteTimer >= 0) {
      clearTimeout(this.persistRemoteTimer);
      this.persistRemoteTimer = -1;
      saveRemoteRuleSets(this.remoteRuleSets);
    }
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

  /** 规则集上下移(对齐安卓 RouteFragment ItemTouchHelper 拖拽排序;鸿蒙用显式按钮) */
  moveRemoteRuleSet(index: number, delta: number): void {
    const target = index + delta;
    if (target < 0 || target >= this.remoteRuleSets.length) {
      return;
    }
    const next = this.remoteRuleSets.slice();
    const tmp = next[index];
    next[index] = next[target];
    next[target] = tmp;
    this.remoteRuleSets = next;
    this.persistRemoteRuleSets();
  }

  /** 自定义规则上下移(顺序即优先级) */
  moveRule(index: number, delta: number): void {
    const target = index + delta;
    if (target < 0 || target >= this.rules.length) {
      return;
    }
    const next = this.rules.slice();
    const tmp = next[index];
    next[index] = next[target];
    next[target] = tmp;
    this.rules = next;
    this.persist();
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

  /** 清空全部自定义路由规则(对齐安卓 action_reset_route) */
  resetRules(): void {
    if (this.rules.length === 0 && this.remoteRuleSets.length === 0) {
      promptAction.showToast({ message: $r('app.string.route_reset_empty') });
      return;
    }
    AlertDialog.show({
      message: $r('app.string.route_reset_confirm'),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: async () => {
          this.rules = [];
          this.remoteRuleSets = [];
          await saveRouteRules(this.rules);
          await saveRemoteRuleSets(this.remoteRuleSets);
          promptAction.showToast({ message: $r('app.string.route_reset_done') });
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
    } else if (field === 'domains') {
      rule.domains = value as string;
    } else if (field === 'ip') {
      rule.ip = value as string;
    } else if (field === 'port') {
      rule.port = value as string;
    } else if (field === 'source') {
      rule.source = value as string;
    } else if (field === 'sourcePort') {
      rule.sourcePort = value as string;
    } else if (field === 'network') {
      rule.network = value as string;
    } else if (field === 'protocol') {
      rule.protocol = value as string;
    } else if (field === 'packages') {
      rule.packages = value as string;
    } else if (field === 'config') {
      rule.config = value as string;
    }
    next[index] = rule;
    this.rules = next;
    this.persist();
  }

  /**
   * 多字段匹配表单(对齐安卓 RouteSettingsActivity 的字段集):
   * 域名(支持 full:/domain:/keyword:/regexp:/geosite: 前缀)、目的 IP、目的端口、
   * 源 IP、源端口、网络、协议、应用包名、自定义配置,字段间为 AND 关系。
   */
  @Builder
  ruleMatchSection(rule: RouteRule, index: number) {
    Column({ space: 6 }) {
      Column() {
        Text($r('app.string.route_rule_domains')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
        TextArea({ text: rule.domains, placeholder: $r('app.string.route_rule_domains_hint') })
          .height(64)
          .onChange((value: string) => this.updateRule(index, 'domains', value))
      }.alignItems(HorizontalAlign.Start).width('100%')

      Row({ space: 6 }) {
        Column() {
          Text($r('app.string.route_rule_ip')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: rule.ip, placeholder: '1.1.1.1/32, geoip:cn' })
            .fontSize(12).height(38)
            .onChange((value: string) => this.updateRule(index, 'ip', value))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column() {
          Text($r('app.string.route_rule_port')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: rule.port, placeholder: '80,443' })
            .fontSize(12).height(38)
            .onChange((value: string) => this.updateRule(index, 'port', value))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')

      Row({ space: 6 }) {
        Column() {
          Text($r('app.string.route_rule_source')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: rule.source, placeholder: '192.168.0.0/16' })
            .fontSize(12).height(38)
            .onChange((value: string) => this.updateRule(index, 'source', value))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column() {
          Text($r('app.string.route_rule_source_port')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: rule.sourcePort, placeholder: '1234' })
            .fontSize(12).height(38)
            .onChange((value: string) => this.updateRule(index, 'sourcePort', value))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')

      Row({ space: 6 }) {
        Column() {
          Text($r('app.string.route_rule_network')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          Select([
            { value: $r('app.string.route_rule_any') },
            { value: 'TCP' },
            { value: 'UDP' }
          ])
            .selected(rule.network === 'tcp' ? 1 : rule.network === 'udp' ? 2 : 0)
            .value(rule.network === 'tcp' ? 'TCP' : rule.network === 'udp' ? 'UDP' : $r('app.string.route_rule_any').toString())
            .onSelect((i: number) => {
              this.updateRule(index, 'network', i === 1 ? 'tcp' : i === 2 ? 'udp' : '');
            })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column() {
          Text($r('app.string.route_rule_protocol')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          TextArea({ text: rule.protocol, placeholder: 'http, tls, quic, dns' })
            .fontSize(12).height(48)
            .onChange((value: string) => this.updateRule(index, 'protocol', value))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')

      Column() {
        Text($r('app.string.route_rule_packages')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
        TextInput({ text: rule.packages, placeholder: 'com.example.app' })
          .fontSize(12).height(38)
          .onChange((value: string) => this.updateRule(index, 'packages', value))
      }.alignItems(HorizontalAlign.Start).width('100%')

      Column() {
        Text($r('app.string.route_rule_config')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
        TextArea({ text: rule.config, placeholder: $r('app.string.route_rule_config_hint') })
          .height(48)
          .onChange((value: string) => this.updateRule(index, 'config', value))
      }.alignItems(HorizontalAlign.Start).width('100%')

      Row({ space: 8 }) {
        ForEach(['proxy', 'direct', 'reject'], (outbound: string) => {
          Button(outbound === 'proxy' ? $r('app.string.proxy') : outbound === 'direct' ? $r('app.string.mode_direct') : $r('app.string.reject'))
            .layoutWeight(1)
            .backgroundColor(rule.outbound === outbound ? $r('app.color.primary') : $r('app.color.divider'))
            .fontColor(rule.outbound === outbound ? $r('app.color.surface') : $r('app.color.text_primary'))
            .onClick(() => this.updateRule(index, 'outbound', outbound))
        })
        // 指定节点出站(对齐安卓 OutboundPreference 选任意 profile;内核生成引用出站)
        Button(rule.outbound.startsWith('profile:') ? $r('app.string.route_outbound_profile_active') : $r('app.string.route_outbound_profile'))
          .layoutWeight(1)
          .backgroundColor(rule.outbound.startsWith('profile:') ? $r('app.color.primary') : $r('app.color.divider'))
          .fontColor(rule.outbound.startsWith('profile:') ? $r('app.color.surface') : $r('app.color.text_primary'))
          .onClick(() => {
            if (rule.outbound.startsWith('profile:')) {
              this.updateRule(index, 'outbound', 'proxy');
              return;
            }
            if (this.profiles.length === 0) {
              promptAction.showToast({ message: $r('app.string.route_no_profiles') });
              return;
            }
            this.updateRule(index, 'outbound', `profile:${this.profiles[0].id}`);
          })
      }.width('100%')

      if (rule.outbound.startsWith('profile:')) {
        Column({ space: 2 }) {
          Text($r('app.string.route_rule_profile_target')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          Select(this.profileOptions())
            .selected(this.profileTargetIndex(rule.outbound))
            .value(this.profileTargetLabel(rule.outbound))
            .onSelect((i: number) => {
              this.updateRule(index, 'outbound', i <= 0 ? 'proxy' : `profile:${this.profiles[i - 1].id}`);
            })
        }.alignItems(HorizontalAlign.Start).width('100%')
      }
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  /** 指定节点候选列表(首项「代理」= 取消指定) */
  private profileOptions(): Array<SelectOption> {
    const opts: Array<SelectOption> = [{ value: $r('app.string.proxy') } as SelectOption];
    for (const p of this.profiles) {
      opts.push({ value: `${p.name} (${p.server})` } as SelectOption);
    }
    return opts;
  }

  private profileTargetIndex(outbound: string): number {
    const id = outbound.substring('profile:'.length);
    const i = this.profiles.findIndex((p: Profile) => p.id === id);
    return i < 0 ? 0 : i + 1;
  }

  private profileTargetLabel(outbound: string): ResourceStr {
    const id = outbound.substring('profile:'.length);
    const p = this.profiles.find((x: Profile) => x.id === id);
    if (p === undefined) {
      return $r('app.string.route_rule_profile_missing');
    }
    return `${p.name} (${p.server})`;
  }

  build() {
    Column() {
    Column() {
      Row() {
        DrawerButton({ onOpen: () => this.onOpenDrawer() })
        Text($r('app.string.route_rules_title')).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button($r('app.string.add')).height(34).onClick(() => this.addRule())
        Button($r('app.string.route_reset')).height(34)
          .fontColor($r('app.color.error'))
          .onClick(() => this.resetRules())
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
              Text('↑').fontSize(14).padding({ left: 8, right: 4 })
                .fontColor(index === 0 ? $r('app.color.text_disabled') : $r('app.color.text_primary'))
                .onClick(() => this.moveRemoteRuleSet(index, -1))
              Text('↓').fontSize(14).padding({ left: 4, right: 8 })
                .fontColor(index === this.remoteRuleSets.length - 1 ? $r('app.color.text_disabled') : $r('app.color.text_primary'))
                .onClick(() => this.moveRemoteRuleSet(index, 1))
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
          .padding(UiSpec.GAP_MD)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(UiSpec.CARD_RADIUS)
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
                Text('↑').fontSize(14).padding({ left: 8, right: 4 })
                  .fontColor(index === 0 ? $r('app.color.text_disabled') : $r('app.color.text_primary'))
                  .onClick(() => this.moveRule(index, -1))
                Text('↓').fontSize(14).padding({ left: 4, right: 8 })
                  .fontColor(index === this.rules.length - 1 ? $r('app.color.text_disabled') : $r('app.color.text_primary'))
                  .onClick(() => this.moveRule(index, 1))
                Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
                  .onChange((value: boolean) => this.updateRule(index, 'enabled', value))
              }.width('100%')

              // 多字段匹配(对齐安卓 RuleEntity):域名/IP/端口/源IP/源端口/网络/协议/应用/出站
              this.ruleMatchSection(rule, index)

              Text($r('app.string.delete_rule')).fontSize(13).fontColor($r('app.color.error')).padding(6)
                .onClick(() => this.removeRule(index))
            }
            .width('100%')
            .padding(UiSpec.GAP_MD)
            .backgroundColor($r('app.color.surface'))
            .borderRadius(UiSpec.CARD_RADIUS)
          }
        }, (rule: RouteRule, index: number) => `${index}_${rule.remark}_${rule.type}`)
      }
        .edgeEffect(EdgeEffect.Spring)
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
