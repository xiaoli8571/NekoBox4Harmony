import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import promptAction from '@ohos.promptAction';
import { Profile, ProfileGroup } from '../model/Profile';
import { loadProfiles, loadGroups, readPrefString, writePrefString } from '../model/Store';
import {
  RoutingRule,
  RULE_DOMAIN, RULE_DOMAIN_SUFFIX, RULE_DOMAIN_KEYWORD, RULE_DOMAIN_REGEX, RULE_GEOSITE,
  RULE_IP_CIDR, RULE_GEOIP, RULE_PORT, RULE_PORT_RANGE, RULE_NETWORK, RULE_PROCESS,
  RULE_OUT_DIRECT, RULE_OUT_PROXY, RULE_OUT_BLOCK,
  parseRules, toRawRows
} from '../model/RoutingRules';
import {
  RuleForm, FieldError, RuleTarget, LegacyRuleView,
  emptyForm, formFromRule, formToRule, validateForm, availableTargets,
  resolveTargetIssue, suggestReplacement, toLogicalExpression,
  legacyViews, applyLegacyAction, SEVERITY_ERROR
} from '../model/RuleEditor';
import { RuleSetRepository, sanitizeResourceId } from '../core/RuleSetRepository';
import { statusBarTopVp } from '../common/PageTopInset';

/** 存储键与 model/RouteRule.ets / RouteRulesPage 一致 */
const KEY_RULES: string = 'route_rules';

/** 类型下拉选项(token + 界面文案;旧 package/advanced 不允许新建,仅在转换场景出现) */
const FORM_TYPES: Array<string> = [
  RULE_DOMAIN_SUFFIX, RULE_DOMAIN, RULE_DOMAIN_KEYWORD, RULE_DOMAIN_REGEX,
  RULE_GEOSITE, RULE_IP_CIDR, RULE_GEOIP, RULE_PORT, RULE_PORT_RANGE, RULE_NETWORK, RULE_PROCESS
];

function typeLabelOf(type: string): string {
  if (type === RULE_DOMAIN) {
    return '域名(精确)';
  }
  if (type === RULE_DOMAIN_SUFFIX) {
    return '域名后缀';
  }
  if (type === RULE_DOMAIN_KEYWORD) {
    return '域名关键词';
  }
  if (type === RULE_DOMAIN_REGEX) {
    return '域名正则';
  }
  if (type === RULE_GEOSITE) {
    return '规则集(geosite)';
  }
  if (type === RULE_IP_CIDR) {
    return '目的 IP 段';
  }
  if (type === RULE_GEOIP) {
    return 'GeoIP';
  }
  if (type === RULE_PORT) {
    return '目的端口';
  }
  if (type === RULE_PORT_RANGE) {
    return '端口段';
  }
  if (type === RULE_NETWORK) {
    return '网络类型';
  }
  if (type === RULE_PROCESS) {
    return '进程名';
  }
  return type;
}

function fieldLabelOf(field: string): string {
  if (field === 'payload') {
    return '匹配值';
  }
  if (field === 'type') {
    return '类型';
  }
  if (field === 'outbound') {
    return '处理目标';
  }
  if (field === 'destPort') {
    return '目的端口(高级)';
  }
  if (field === 'sourceIpCidr') {
    return '源 IP(高级)';
  }
  if (field === 'sourcePort') {
    return '源端口(高级)';
  }
  if (field === 'network') {
    return '网络类型(高级)';
  }
  if (field === 'protocol') {
    return '协议(高级)';
  }
  if (field === 'customJson') {
    return '自定义 JSON(高级)';
  }
  if (field === 'matchMode') {
    return '组合方式';
  }
  return field;
}

/**
 * 规则编辑器页(§7.3):基础字段 + 高级折叠区(显示已有条件数,避免隐藏约束被误删)。
 * 校验 → (error 才阻断) → formToRule 写草稿(Store route_rules 行) → 返回列表页。
 * 编辑过程不触碰运行配置;目标缺失只提示候选,绝不自动写回。
 */
@Entry
@Component
struct RuleEditPage {
  /** '' = 新建;否则编辑既有规则;convertFrom = 旧规则转换来源(§8.5,需用户显式改写) */
  @State ruleId: string = '';
  /** 顶部让位(状态栏高度,运行时查询;2026-10-24 真机反馈新建规则页顶控件被状态栏盖住) */
  @State topPadVp: number = 44;
  @State convertFrom: string = '';
  @State name: string = '';
  @State formType: string = RULE_DOMAIN_SUFFIX;
  @State payload: string = '';
  @State outbound: string = RULE_OUT_PROXY;
  @State ruleEnabled: boolean = true;
  @State advancedOpen: boolean = false;
  @State destPort: string = '';
  @State sourceIpCidr: string = '';
  @State sourcePort: string = '';
  @State network: string = '';
  @State protocol: string = '';
  @State customJson: string = '';
  @State matchMode: string = 'or';
  @State errors: Array<FieldError> = Array<FieldError>();
  @State targets: Array<RuleTarget> = Array<RuleTarget>();
  @State targetMissing: boolean = false;
  @State saving: boolean = false;
  @State loadError: string = '';
  private profiles: Array<Profile> = Array<Profile>();
  private groups: Array<ProfileGroup> = Array<ProfileGroup>();
  private baseRule: RoutingRule | null = null;
  private legacyRule: RoutingRule | null = null;
  private knownRuleSetIds: Array<string> = Array<string>();

  aboutToAppear(): void {
    void statusBarTopVp(getContext(this) as common.UIAbilityContext).then((v: number): void => {
      this.topPadVp = v;
    });
    const params = router.getParams() as Record<string, Object>;
    this.ruleId = typeof params['ruleId'] === 'string' ? params['ruleId'] as string : '';
    this.convertFrom = typeof params['convertFrom'] === 'string' ? params['convertFrom'] as string : '';
    void this.load();
  }

  private async load(): Promise<void> {
    try {
      this.profiles = await loadProfiles();
      this.groups = await loadGroups();
      this.targets = availableTargets(this.profiles, this.groups);
      const raw = await readPrefString(KEY_RULES, '[]');
      const rows = JSON.parse(raw) as Array<Record<string, Object>>;
      const rules = parseRules(rows);
      // 规则集 id 白名单(校验 geosite/rule_set 引用用):规则集仓库里实际存在的资源 id
      const listed = RuleSetRepository.list();
      for (let i = 0; i < listed.length; i++) {
        const sid = sanitizeResourceId(listed[i].id);
        if (sid.length > 0) {
          this.knownRuleSetIds.push(sid);
        }
      }
      if (this.convertFrom.length > 0) {
        this.loadLegacy(rules);
      } else if (this.ruleId.length > 0) {
        for (let i = 0; i < rules.length; i++) {
          if (rules[i].id === this.ruleId) {
            this.baseRule = rules[i];
            break;
          }
        }
        if (this.baseRule === null) {
          this.loadError = '规则不存在(可能已被删除)';
          return;
        }
        this.applyForm(formFromRule(this.baseRule));
      } else {
        this.applyForm(emptyForm());
      }
      if (this.baseRule !== null) {
        this.targetMissing = resolveTargetIssue(this.baseRule, this.targets) === 'target_missing';
      }
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    }
  }

  /** 旧规则转换:预填原值供改写(类型/匹配值必须用户显式改成可编译条件,applyLegacyAction 兜底拒绝) */
  private loadLegacy(rules: Array<RoutingRule>): void {
    const views: Array<LegacyRuleView> = legacyViews(rules);
    for (let i = 0; i < views.length; i++) {
      if (views[i].rule.id === this.convertFrom) {
        this.legacyRule = views[i].rule;
        break;
      }
    }
    if (this.legacyRule === null) {
      this.loadError = '旧规则不存在(可能已被处理)';
      return;
    }
    this.applyForm(formFromRule(this.legacyRule));
    this.name = `转换自：${this.legacySummary()}`;
  }

  private legacySummary(): string {
    if (this.legacyRule === null) {
      return '旧规则';
    }
    const reason = this.legacyRule.unsupportedReason;
    const type = typeLabelOf(this.legacyRule.type);
    return reason.length > 0 ? `${type}（${reason}）` : type;
  }

  private applyForm(f: RuleForm): void {
    this.name = f.name;
    this.formType = f.type;
    this.payload = f.payload;
    this.outbound = f.outbound;
    this.ruleEnabled = f.enabled;
    this.advancedOpen = f.advancedOpen;
    this.destPort = f.destPort;
    this.sourceIpCidr = f.sourceIpCidr;
    this.sourcePort = f.sourcePort;
    this.network = f.network;
    this.protocol = f.protocol;
    this.customJson = f.customJson;
    this.matchMode = f.matchMode;
  }

  private buildForm(): RuleForm {
    const f = new RuleForm();
    f.name = this.name;
    f.type = this.formType;
    f.payload = this.payload;
    f.outbound = this.outbound;
    f.enabled = this.ruleEnabled;
    f.advancedOpen = this.advancedOpen;
    f.destPort = this.destPort;
    f.sourceIpCidr = this.sourceIpCidr;
    f.sourcePort = this.sourcePort;
    f.network = this.network;
    f.protocol = this.protocol;
    f.customJson = this.customJson;
    f.matchMode = this.matchMode;
    return f;
  }

  /** 当前表单的"已有条件数"(高级折叠时也要可见,§7.3) */
  private liveConditionCount(): number {
    let count = this.payload.trim().length > 0 ? 1 : 0;
    if (this.destPort.trim().length > 0) {
      count++;
    }
    if (this.sourceIpCidr.trim().length > 0) {
      count++;
    }
    if (this.sourcePort.trim().length > 0) {
      count++;
    }
    if (this.network.trim().length > 0) {
      count++;
    }
    if (this.protocol.trim().length > 0) {
      count++;
    }
    if (this.customJson.trim().length > 0) {
      count++;
    }
    return count;
  }

  private typeIndex(): number {
    for (let i = 0; i < FORM_TYPES.length; i++) {
      if (FORM_TYPES[i] === this.formType) {
        return i;
      }
    }
    return 0;
  }

  private targetIndex(): number {
    for (let i = 0; i < this.targets.length; i++) {
      if (this.targets[i].id === this.outbound) {
        return i;
      }
    }
    return this.outbound === RULE_OUT_PROXY ? 1 : 0;
  }

  /** 保存链路:validateForm(error 阻断,warning 放行) → formToRule/applyLegacyAction → 草稿写回 → 返回 */
  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    const f = this.buildForm();
    const fieldErrors = validateForm(f, this.knownRuleSetIds, this.targets);
    const blocking: Array<FieldError> = [];
    for (let i = 0; i < fieldErrors.length; i++) {
      if (fieldErrors[i].severity === SEVERITY_ERROR) {
        blocking.push(fieldErrors[i]);
      }
    }
    this.errors = fieldErrors;
    if (blocking.length > 0) {
      promptAction.showToast({ message: `${fieldLabelOf(blocking[0].field)}：${blocking[0].detail}` });
      return;
    }
    this.saving = true;
    try {
      const raw = await readPrefString(KEY_RULES, '[]');
      const rows = JSON.parse(raw) as Array<Record<string, Object>>;
      const rules = parseRules(rows);
      if (this.convertFrom.length > 0 && this.legacyRule !== null) {
        // 转换必须用户显式改写:applyLegacyAction 内部再次校验 type/payload,不合格返回 null
        const converted = applyLegacyAction(this.legacyRule, 'convert', f);
        if (converted === null) {
          promptAction.showToast({ message: '转换被拒绝：类型必须是可编译类型且匹配值非空（不自动推导）' });
          this.saving = false;
          return;
        }
        for (let i = 0; i < rules.length; i++) {
          if (rules[i].id === this.legacyRule.id) {
            converted.order = rules[i].order;
            rules[i] = converted;
            break;
          }
        }
      } else if (this.ruleId.length > 0 && this.baseRule !== null) {
        const updated = formToRule(f, this.baseRule);
        for (let i = 0; i < rules.length; i++) {
          if (rules[i].id === this.ruleId) {
            updated.order = rules[i].order;
            rules[i] = updated;
            break;
          }
        }
      } else {
        const created = formToRule(f, null);
        created.order = rules.length; // 设到末尾,数组序即 order
        rules.push(created);
      }
      await writePrefString(KEY_RULES, JSON.stringify(toRawRows(rules)));
      promptAction.showToast({ message: '已保存（待应用,在分流页查看差异）' });
      router.back();
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `保存失败：${msg}` });
    } finally {
      this.saving = false;
    }
  }

  /** 目标已删除:给同类型候选,用户点选后写表单(绝不自动写回规则) */
  private replacementHint(): string {
    if (!this.targetMissing) {
      return '';
    }
    const kind = this.outbound.startsWith('profile:') ? 'profile'
      : (this.outbound.startsWith('group:') ? 'group' : '');
    const hint = kind.length > 0 ? suggestReplacement(this.targets, kind) : null;
    if (hint === null) {
      return '目标已删除,请选择替代(无同类型可用候选)';
    }
    return `目标已删除,可用替代：${hint.label}`;
  }

  private errorFor(field: string): string {
    let worst = '';
    for (let i = 0; i < this.errors.length; i++) {
      const e = this.errors[i];
      if (e.field !== field) {
        continue;
      }
      if (e.severity === SEVERITY_ERROR) {
        worst = e.detail;
        break;
      }
      if (worst.length === 0) {
        worst = e.detail;
      }
    }
    return worst;
  }

  /** and 组合的 logical 预览(§7.3):结构存行由 RoutingRules/ConfigBuilder 消费 */
  private logicalPreview(): string {
    if (this.matchMode !== 'and' || this.liveConditionCount() < 2) {
      return '';
    }
    const expr = toLogicalExpression(this.buildForm());
    if (expr === null) {
      return '';
    }
    return JSON.stringify(expr);
  }

  @Builder
  private fieldBlock(label: string, field: string, placeholder: ResourceStr, value: string,
    onChange: (v: string) => void, multiline: boolean = false) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      if (multiline) {
        TextArea({ text: value, placeholder: placeholder })
          .height(56)
          .fontSize(12)
          .onChange(onChange)
      } else {
        TextInput({ text: value, placeholder: placeholder })
          .height(38)
          .fontSize(12)
          .onChange(onChange)
      }
      if (this.errorFor(field).length > 0) {
        Text(this.errorFor(field))
          .fontSize(10)
          .fontColor($r('app.color.error'))
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 10 }) {
          Text(this.convertFrom.length > 0
            ? '转换旧规则(必须显式改写,不自动推导)'
            : (this.ruleId.length > 0 ? '编辑规则' : '新建规则'))
            .fontSize(16)
            .fontWeight(700)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          if (this.loadError.length > 0) {
            Text(this.loadError).fontSize(12).fontColor($r('app.color.error')).width('100%')
          }

          TextInput({ text: this.name, placeholder: '名称(仅界面显示,可不填)' })
            .height(38)
            .fontSize(12)
            .onChange((v: string) => {
              this.name = v;
            })

          Row({ space: 8 }) {
            Column({ space: 4 }) {
              Text('类型').fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              Select(FORM_TYPES.map((t: string): SelectOption => ({ value: typeLabelOf(t) } as SelectOption)))
                .selected(this.typeIndex())
                .value(typeLabelOf(this.formType))
                .onSelect((i: number) => {
                  this.formType = FORM_TYPES[i];
                })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')

          this.fieldBlock(`匹配值（${typeLabelOf(this.formType)}）`, 'payload', this.payloadPlaceholder(), this.payload, (v: string) => {
            this.payload = v;
          }, true)

          Row({ space: 8 }) {
            Column({ space: 4 }) {
              Text('处理目标').fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
              Select(this.targets.map((t: RuleTarget): SelectOption =>
                ({ value: t.available ? t.label : `${t.label}(不可用)` } as SelectOption)))
                .selected(this.targetIndex())
                .value(this.outboundLabel())
                .onSelect((i: number) => {
                  if (i >= 0 && i < this.targets.length) {
                    this.outbound = this.targets[i].id;
                  }
                })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            if (this.targetMissing) {
              Column({ space: 4 }) {
                Text('目标缺失').fontSize(11).fontColor($r('app.color.error')).width('100%')
                Text(this.replacementHint())
                  .fontSize(10)
                  .fontColor($r('app.color.warning'))
                  .width('100%')
                  .onClick(() => {
                    const kind = this.outbound.startsWith('profile:') ? 'profile'
                      : (this.outbound.startsWith('group:') ? 'group' : '');
                    const hint = kind.length > 0 ? suggestReplacement(this.targets, kind) : null;
                    if (hint !== null) {
                      this.outbound = hint.id;
                    }
                  })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
          }
          .width('100%')

          Row() {
            Text('启用').fontSize(12).fontColor($r('app.color.text_primary'))
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.ruleEnabled })
              .onChange((on: boolean) => {
                this.ruleEnabled = on;
              })
          }
          .width('100%')

          /* 高级折叠区:标题带"已有条件数",避免隐藏约束被误删(§7.3) */
          Column({ space: 8 }) {
            Row({ space: 6 }) {
              Text(this.advancedOpen ? '▾ 高级条件' : '▸ 高级条件')
                .fontSize(12)
                .fontWeight(700)
                .fontColor($r('app.color.text_primary'))
              Text(`已有 ${this.liveConditionCount()} 个条件`)
                .fontSize(10)
                .fontColor(this.liveConditionCount() > 0 ? $r('app.color.warning') : $r('app.color.text_3'))
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .backgroundColor($r('app.color.bg_page'))
                .borderRadius(6)
              Blank()
            }
            .width('100%')
            .onClick(() => {
              this.advancedOpen = !this.advancedOpen;
            })

            if (this.advancedOpen) {
              Row({ space: 8 }) {
                Column() {
                  this.fieldBlock('目的端口', 'destPort', '80,443 / 1000:2000', this.destPort, (v: string) => {
                    this.destPort = v;
                  })
                }
                .layoutWeight(1)

                Column() {
                  this.fieldBlock('源端口', 'sourcePort', '1234', this.sourcePort, (v: string) => {
                    this.sourcePort = v;
                  })
                }
                .layoutWeight(1)
              }
              .width('100%')
              this.fieldBlock('源 IP 段', 'sourceIpCidr', '192.168.0.0/16', this.sourceIpCidr, (v: string) => {
                this.sourceIpCidr = v;
              })
              Row({ space: 8 }) {
                Column() {
                  this.fieldBlock('网络类型', 'network', 'tcp / udp(留空=任意)', this.network, (v: string) => {
                    this.network = v;
                  })
                }
                .layoutWeight(1)

                Column() {
                  this.fieldBlock('协议', 'protocol', 'http, tls, quic', this.protocol, (v: string) => {
                    this.protocol = v;
                  })
                }
                .layoutWeight(1)
              }
              .width('100%')
              this.fieldBlock('自定义 JSON(浅合并到内核规则)', 'customJson', '{"domain_suffix":["x.com"]}',
                this.customJson, (v: string) => {
                  this.customJson = v;
                }, true)

              Row({ space: 8 }) {
                Text('组合方式').fontSize(11).fontColor($r('app.color.text_secondary'))
                Select([
                  { value: '同时满足(AND,不同字段)' } as SelectOption,
                  { value: '任一匹配(OR,平铺)' } as SelectOption
                ] as Array<SelectOption>)
                  .selected(this.matchMode === 'and' ? 0 : 1)
                  .value(this.matchMode === 'and' ? '同时满足(AND)' : '任一匹配(OR)')
                  .onSelect((i: number) => {
                    this.matchMode = i === 0 ? 'and' : 'or';
                  })
              }
              .width('100%')

              if (this.logicalPreview().length > 0) {
                Text(`将生成 logical/and 规则：${this.logicalPreview()}`)
                  .fontSize(10)
                  .fontColor($r('app.color.text_3'))
                  .width('100%')
              }
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(10)
          .backgroundColor($r('app.color.bg_page'))
          .borderRadius(10)

          Row({ space: 8 }) {
            Button('取消')
              .height(40)
              .layoutWeight(1)
              .backgroundColor($r('app.color.bg_page'))
              .fontColor($r('app.color.text_secondary'))
              .onClick(() => router.back())
            Button(this.saving ? '保存中…' : '保存')
              .height(40)
              .layoutWeight(1)
              .backgroundColor($r('app.color.primary'))
              .fontColor($r('app.color.surface'))
              .enabled(!this.saving)
              .onClick(() => {
                void this.save();
              })
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topPadVp })
    .backgroundColor($r('app.color.bg_page'))
  }

  private payloadPlaceholder(): string {
    const t = this.formType;
    if (t === RULE_DOMAIN_SUFFIX || t === RULE_DOMAIN) {
      return 'example.com, b.com';
    }
    if (t === RULE_DOMAIN_KEYWORD) {
      return 'google, openai';
    }
    if (t === RULE_DOMAIN_REGEX) {
      return '^ads?\\.';
    }
    if (t === RULE_GEOSITE) {
      return 'category-ads-all, cn';
    }
    if (t === RULE_IP_CIDR) {
      return '10.0.0.0/8, 2606:4700::/32';
    }
    if (t === RULE_GEOIP) {
      return 'cn, private';
    }
    if (t === RULE_PORT || t === RULE_PORT_RANGE) {
      return '80,443 / 1000:2000';
    }
    if (t === RULE_NETWORK) {
      return 'tcp 或 udp';
    }
    if (t === RULE_PROCESS) {
      return 'chrome.exe, curl';
    }
    return '';
  }

  private outboundLabel(): string {
    for (let i = 0; i < this.targets.length; i++) {
      if (this.targets[i].id === this.outbound) {
        return this.targets[i].available ? this.targets[i].label : `${this.targets[i].label}(不可用)`;
      }
    }
    return this.outbound;
  }
}
