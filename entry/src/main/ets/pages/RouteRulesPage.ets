import promptAction from '@ohos.promptAction';
import { UiSpec } from '../common/UiSpec';
import { Profile, AppSettings } from '../model/Profile';
import { initStore, loadProfiles, loadSettings, saveSettings, LogStore } from '../model/Store';
import { DrawerButton } from '../common/components/DrawerButton';
import { RouteRule, RemoteRuleSet, loadRouteRules, saveRouteRules, loadRemoteRuleSets, saveRemoteRuleSets } from '../model/RouteRule';
import { geoReady, downloadGeoAssets, importGeoAssetFromFile, geoAssetInfos, downloadGeoAsset, deleteGeoAsset, GeoAssetInfo, GEO_SITE_FILE, GEO_IP_FILE } from '../utils/GeoAssets';
import { formatBytes } from '../utils/TrafficStats';
import { common } from '@kit.AbilityKit';

// 从设置页「路由」区块搬过来的可选项(2.1.7 起路由相关只在本页出现)
const STACKS: Array<string> = ['system'];
const SNIFF_MODES: Array<string> = ['off', 'route', 'override'];
const SNIFF_LABELS: Array<Resource> = [$r('app.string.sniff_off'), $r('app.string.sniff_route'), $r('app.string.sniff_override')];
// Android IPv6Mode 四档(values/arrays.xml ipv6_mode)
const IPV6_MODES: Array<string> = ['disable', 'enable', 'prefer', 'only'];
const IPV6_MODE_LABELS: Array<Resource> = [$r('app.string.ipv6_mode_disable'), $r('app.string.ipv6_mode_enable'), $r('app.string.ipv6_mode_prefer'), $r('app.string.ipv6_mode_only')];

/** 路由规则面板(抽屉内嵌页签,对齐安卓 RouteFragment;不再是独立路由页) */
@Component
export struct RouteRulesPanel {
  @State profiles: Array<Profile> = [];
  @State rules: Array<RouteRule> = [];
  @State remoteRuleSets: Array<RemoteRuleSet> = [];
  @State loading: boolean = true;
  @State loadError: string = '';
  @State s: AppSettings = new AppSettings();
  @State settingsExpanded: boolean = false;
  @State geoOk: boolean = false;
  @State geoLoading: boolean = false;
  @State geoInfos: Array<GeoAssetInfo> = [];
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
  onOpenDrawer: () => void = () => {};
  onSettingsChanged: (settings: AppSettings) => void = (_settings: AppSettings) => {};

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      await initStore(this.context);
      this.profiles = await loadProfiles();
      this.rules = await loadRouteRules();
      this.remoteRuleSets = await loadRemoteRuleSets();
      this.s = await loadSettings();
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
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
    if (this.settingsTimer >= 0) {
      clearTimeout(this.settingsTimer);
      this.settingsTimer = -1;
      void this.saveSettingsNow();
    }
  }

  // ------------------------------------------------- 路由设置(自设置页搬入)

  private settingsTimer: number = -1;

  /** 防抖落盘:与规则列表同为「改完即存」,重连 VPN 后生效 */
  persistSettings(): void {
    if (this.settingsTimer >= 0) {
      clearTimeout(this.settingsTimer);
    }
    this.settingsTimer = setTimeout(() => {
      this.settingsTimer = -1;
      void this.saveSettingsNow();
    }, 600);
  }

  private async saveSettingsNow(): Promise<void> {
    try {
      await saveSettings(this.s);
      this.onSettingsChanged(this.s);
    } catch (e) {
      const message = e instanceof Error ? e.message : `${e}`;
      LogStore.addLog(`[ui] 路由设置保存失败: ${message}`);
      promptAction.showToast({ message: $r('app.string.save_failed_reason', message) });
    }
  }

  private refreshGeoInfos(): void {
    this.geoInfos = geoAssetInfos(this.context);
  }

  async downloadGeo(): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    promptAction.showToast({ message: $r('app.string.geo_downloading') });
    try {
      await downloadGeoAssets(this.context);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({ message: $r('app.string.geo_download_complete') });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.download_failed_reason', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  /** 单库更新(对齐安卓资产列表点击单库更新) */
  async downloadSingleGeo(kind: string): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    try {
      await downloadGeoAsset(this.context, kind);
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({
        message: $r('app.string.settings_geo_updated', kind === 'site' ? GEO_SITE_FILE : GEO_IP_FILE)
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.download_failed_reason', msg) });
    } finally {
      this.geoLoading = false;
    }
  }

  /** 删除单库(对齐安卓资产左滑删除;二次确认) */
  confirmDeleteGeo(info: GeoAssetInfo): void {
    AlertDialog.show({
      message: $r('app.string.settings_geo_delete_confirm', info.fileName),
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: () => {
          try {
            deleteGeoAsset(this.context, info.kind);
            this.geoOk = geoReady(this.context);
            this.refreshGeoInfos();
            promptAction.showToast({ message: $r('app.string.settings_geo_deleted', info.fileName) });
          } catch (e) {
            const msg = e instanceof Error ? e.message : `${e}`;
            promptAction.showToast({ message: $r('app.string.settings_geo_delete_failed', msg) });
          }
        }
      }
    });
  }

  /** 导入用户自选的 geo .db(对齐安卓 AssetsActivity 的 action_import_file) */
  async importGeo(): Promise<void> {
    if (this.geoLoading) {
      return;
    }
    this.geoLoading = true;
    try {
      const path = await importGeoAssetFromFile(this.context);
      if (path === null) {
        // 用户取消选择,不报错
        return;
      }
      this.geoOk = geoReady(this.context);
      this.refreshGeoInfos();
      promptAction.showToast({ message: $r('app.string.geo_import_complete', path) });
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: $r('app.string.geo_import_failed', msg) });
    } finally {
      this.geoLoading = false;
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
    } else if (field === 'appLabel') {
      rule.appLabel = value as string;
    } else if (field === 'packagesEnabled') {
      rule.packagesEnabled = value as boolean;
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

      // 应用名(仅备注) + 包名(勾选「生效」才参与匹配)
      Row({ space: 6 }) {
        Column() {
          Text($r('app.string.route_rule_app_name')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: rule.appLabel, placeholder: $r('app.string.route_rule_app_name_hint') })
            .fontSize(12).height(38)
            .onChange((value: string) => this.updateRule(index, 'appLabel', value))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Column() {
          Text($r('app.string.route_rule_packages')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
          Row({ space: 6 }) {
            TextInput({ text: rule.packages, placeholder: 'com.example.app' })
              .fontSize(12).height(38).layoutWeight(1)
              .onChange((value: string) => this.updateRule(index, 'packages', value))
            Toggle({ type: ToggleType.Checkbox, isOn: rule.packagesEnabled })
              .onChange((value: boolean) => this.updateRule(index, 'packagesEnabled', value))
            Text($r('app.string.route_rule_packages_effective')).fontSize(11).fontColor($r('app.color.text_secondary'))
          }.width('100%').alignItems(VerticalAlign.Center)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
      Text($r('app.string.route_rule_packages_note')).fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')

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

  /**
   * 路由设置卡(2.1.7:自设置页「路由」区块整体搬入本页,路由相关只此一处)。
   * 直连域名/IP 段是内置直连规则,geo 资产是内置 cn 分流所依赖的 rule_set 资源,
   * 其余为嗅探/解析/IPv6/TUN 等分流全局参数;改动即存,重连 VPN 后生效。
   */
  @Builder
  routeSettingsCard() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text(this.geoOk ? '✓' : '⚠').fontSize(14)
          .fontColor(this.geoOk ? $r('app.color.success') : $r('app.color.text_secondary'))
        Text($r('app.string.route_settings_title')).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1)
        Text(this.settingsExpanded ? '⌃' : '⌄').fontSize(14).fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .onClick(() => {
        this.settingsExpanded = !this.settingsExpanded;
      })

      if (this.settingsExpanded) {
        Text($r('app.string.route_settings_hint'))
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')

        if (this.s.mode === 'rule') {
          Column() {
            Text($r('app.string.settings_direct_domain_suffix')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
            TextInput({ text: this.s.directDomains, placeholder: 'baidu.com,qq.com,163.com' })
              .width('100%').height(40)
              .onChange((v: string) => {
                this.s.directDomains = v;
                this.persistSettings();
              })
            Text($r('app.string.settings_direct_cidr')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
              .margin({ top: 6 })
            TextInput({ text: this.s.directIpCidrs, placeholder: '114.114.114.114/32' })
              .width('100%').height(40)
              .onChange((v: string) => {
                this.s.directIpCidrs = v;
                this.persistSettings();
              })
            Row({ space: 8 }) {
              Text(this.geoOk ? $r('app.string.settings_geo_ready')
                : $r('app.string.settings_geo_missing'))
                .fontSize(12).fontColor(this.geoOk ? $r('app.color.success') : $r('app.color.text_secondary')).layoutWeight(1)
              Button(this.geoLoading ? $r('app.string.settings_geo_downloading') : (this.geoOk ? $r('app.string.settings_geo_redownload') : $r('app.string.settings_geo_download')))
                .height(30)
                .backgroundColor(this.geoLoading ? $r('app.color.control_disabled') : $r('app.color.primary'))
                .onClick(() => { void this.downloadGeo(); })
            }.width('100%').margin({ top: 6 })
            Row({ space: 8 }) {
              Text($r('app.string.settings_geo_import_hint'))
                .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
              Button($r('app.string.settings_geo_import'))
                .height(30)
                .backgroundColor($r('app.color.surface'))
                .fontColor($r('app.color.text_primary'))
                .enabled(!this.geoLoading)
                .onClick(() => { void this.importGeo(); })
            }.width('100%').margin({ top: 4 })

            // 资产列表(对齐安卓 AssetsActivity:每库名称/大小/版本 + 单库更新/删除)
            ForEach(this.geoInfos, (info: GeoAssetInfo) => {
              Row({ space: 8 }) {
                Text(info.kind === 'site' ? $r('app.string.settings_geo_site') : $r('app.string.settings_geo_ip'))
                  .fontSize(12).fontColor($r('app.color.text_primary'))
                Text(info.size > 0
                  ? $r('app.string.geo_asset_status', formatBytes(info.size), info.version)
                  : $r('app.string.geo_asset_absent'))
                  .fontSize(11).fontColor($r('app.color.text_secondary')).layoutWeight(1)
                Button(this.geoLoading ? $r('app.string.settings_geo_downloading') : $r('app.string.settings_geo_update_one'))
                  .height(28)
                  .fontSize(12)
                  .backgroundColor(this.geoLoading ? $r('app.color.control_disabled') : $r('app.color.primary'))
                  .enabled(!this.geoLoading)
                  .onClick(() => { void this.downloadSingleGeo(info.kind); })
                if (info.size > 0) {
                  Button($r('app.string.settings_geo_delete'))
                    .height(28)
                    .fontSize(12)
                    .backgroundColor($r('app.color.surface'))
                    .fontColor($r('app.color.error'))
                    .enabled(!this.geoLoading)
                    .onClick(() => this.confirmDeleteGeo(info))
                }
              }.width('100%').margin({ top: 4 })
            }, (info: GeoAssetInfo) => `${info.kind}_${info.size}_${info.version}`)
          }.alignItems(HorizontalAlign.Start).width('100%')
        }

        Column() {
          Text($r('app.string.settings_tun_mtu')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          TextInput({ text: `${this.s.mtu}`, placeholder: '1400' })
            .type(InputType.Number).width('100%').height(40)
            .onChange((v: string) => {
              const n = parseInt(v);
              this.s.mtu = isNaN(n) ? 1400 : n;
              this.persistSettings();
            })
        }.alignItems(HorizontalAlign.Start).width('100%')

        Column() {
          Text($r('app.string.settings_tun_stack')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          Select(STACKS.map((t: string) => ({ value: t } as SelectOption)))
            .selected(STACKS.indexOf(this.s.stack) < 0 ? 0 : STACKS.indexOf(this.s.stack))
            .value(this.s.stack)
            .onSelect((index: number) => {
              this.s.stack = STACKS[index];
              this.persistSettings();
            })
        }.alignItems(HorizontalAlign.Start).width('100%')

        Column() {
          Text($r('app.string.settings_enable_ipv6')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          Select(IPV6_MODES.map((t: string, i: number) => ({ value: IPV6_MODE_LABELS[i] } as SelectOption)))
            .selected(IPV6_MODES.indexOf(this.s.ipv6Mode) < 0 ? (this.s.ipv6 ? 1 : 0) : IPV6_MODES.indexOf(this.s.ipv6Mode))
            .value(IPV6_MODE_LABELS[(IPV6_MODES.indexOf(this.s.ipv6Mode) < 0 ? (this.s.ipv6 ? 1 : 0) : IPV6_MODES.indexOf(this.s.ipv6Mode))])
            .onSelect((index: number) => {
              this.s.ipv6Mode = IPV6_MODES[index];
              this.persistSettings();
            })
        }.alignItems(HorizontalAlign.Start).width('100%')

        Row() {
          Column() {
            Text($r('app.string.settings_bypass_lan')).fontSize(14)
            Text($r('app.string.settings_bypass_lan_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.s.bypassLan })
            .onChange((v: boolean) => {
              this.s.bypassLan = v;
              this.persistSettings();
            })
        }.width('100%')

        Column() {
          Text($r('app.string.settings_sniff')).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          Row({ space: 8 }) {
            ForEach(SNIFF_MODES, (m: string, idx: number) => {
              Button(SNIFF_LABELS[idx])
                .layoutWeight(1)
                .height(34)
                .backgroundColor(this.s.sniffMode === m ? $r('app.color.primary') : $r('app.color.surface'))
                .fontColor(this.s.sniffMode === m ? $r('app.color.surface') : $r('app.color.text_primary'))
                .onClick(() => {
                  this.s.sniffMode = m;
                  this.persistSettings();
                })
            }, (m: string) => m)
          }.width('100%')
        }.alignItems(HorizontalAlign.Start).width('100%')

        Row() {
          Column() {
            Text($r('app.string.settings_resolve_destination')).fontSize(14)
            Text($r('app.string.settings_resolve_destination_desc')).fontSize(11).fontColor($r('app.color.text_secondary'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.s.resolveDestination })
            .onChange((v: boolean) => {
              this.s.resolveDestination = v;
              this.persistSettings();
            })
        }.width('100%')
      }

      if (!this.settingsExpanded) {
        Text(this.geoOk ? $r('app.string.route_builtin_geo_ready') : $r('app.string.route_builtin_geo_missing'))
          .fontSize(12).fontColor($r('app.color.text_primary')).width('100%')
        Text($r('app.string.route_builtin_geo_desc'))
          .fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(UiSpec.GAP_MD)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(UiSpec.CARD_RADIUS)
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

      // 路由设置(2.1.7 合并:内置 cn 分流、直连域名/IP、geo 资产、嗅探/解析/IPv6/TUN 全在此)
      this.routeSettingsCard()

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
        // key 必须覆盖所有会被就地修改、且影响本卡片绘制的字段:ForEach 依据 key 判断子项是否
        // 变化,旧 key 只有 id,updateRemoteRuleSet 就地改 item 后 key 不变,子组件不重建,
        // 「域名规则/IP 规则」与「直连/代理」的高亮卡在初始值上(同下方 rules 列表的同类问题)。
        // index 进 key:↑↓ 换序后保证卡片位置索引与 onClick 闭包捕获的 index 一致。
        // name/url/updatedAt 故意不进 key:三者每次按键都会变,进 key 会把整张卡(含输入框)
        // 反复重建,导致打字丢焦点/光标跳动;卡片只在这些按钮、开关操作时重建时顺带刷新。
        }, (item: RemoteRuleSet, index: number) =>
          `${index}_${item.id}_${item.type}_${item.outbound}_${item.enabled}_${item.lastError}`)
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
        // key 必须覆盖所有会被就地修改的字段:ForEach 依据 key 判断子项是否变化,
        // 旧 key 缺少 outbound,导致「代理/直连/拒绝/指定节点」按钮点击后不重绘、高亮卡住。
        }, (rule: RouteRule, index: number) => `${index}_${rule.remark}_${rule.type}_${rule.outbound}_${rule.enabled}_${rule.network}_${rule.packagesEnabled}_${rule.packages}_${rule.appLabel}`)
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
