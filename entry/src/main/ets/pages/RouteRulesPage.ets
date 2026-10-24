import promptAction from '@ohos.promptAction';
import { PerAppManager } from './PerAppManager';
import router from '@ohos.router';
import { UiSpec } from '../common/UiSpec';
import { Profile } from '../model/Profile';
import { loadProfiles, loadSettings, readPrefString, writePrefString, LogStore } from '../model/Store';
import { pressLightEffect } from '../common/Effects';
import {
  RemoteRuleSet, loadRemoteRuleSets, saveRemoteRuleSets
} from '../model/RouteRule';
import {
  RoutingRule, RuleIssue, RuleValidation, RuleManifest,
  RULE_DOMAIN, RULE_DOMAIN_SUFFIX, RULE_DOMAIN_KEYWORD, RULE_DOMAIN_REGEX, RULE_GEOSITE,
  RULE_IP_CIDR, RULE_GEOIP, RULE_PORT, RULE_PORT_RANGE, RULE_NETWORK, RULE_PROCESS,
  LEGACY_PACKAGE_TYPE, LEGACY_ADVANCED_TYPE, RULE_OUT_DIRECT, RULE_OUT_PROXY, RULE_OUT_BLOCK,
  ISSUE_OVERLAP, parseRules, toRawRows, compileManifest, validateRules, detectOverlap, newRuleId
} from '../model/RoutingRules';
import {
  RuleSetResource, ResourceAvailability, RuleSetRepository, sanitizeResourceId
} from '../core/RuleSetRepository';
import {
  LegacyRuleView, RuleTarget, availableTargets,
  ruleSummary, conditionCount, matchDescription, moveRule, legacyViews, applyLegacyAction,
  RuleForm, emptyForm, formToRule, validateForm, SEVERITY_ERROR
} from '../model/RuleEditor';
import {
  ClashApi, ClashApiConfig, ClashAvailability, ClashProxiesResult, ClashSelectResult, ClashProxy
} from '../core/ClashApi';
import {
  GroupTagMap, buildTagMap, GROUP_TYPE_SELECTOR, GROUP_TYPE_URLTEST,
  CLASH_TYPE_SELECTOR, CLASH_TYPE_URLTEST, MEMBER_UNKNOWN_LABEL,
  hotSwitchDecision, HotSwitchDecision, verifyNow, VerifyNowResult,
  actualMemberView, ActualMemberView
} from '../model/PolicyGroups';
import { ProfileGroup } from '../model/Profile';
import { loadGroups } from '../model/Store';
import { PerAppEntry, parseEntries, effectivePackages } from '../model/PerApp';

/** 存储键(与 model/RouteRule.ets 的 KEY_RULES 同键,行格式由 RoutingRules 解析/写回) */
const KEY_RULES: string = 'route_rules';

/** 子页签 id(NavMemory.setRoutingTab/getRoutingTab 记忆返回,§7.1) */
const TAB_PERAPP: string = 'perapp';
const TAB_RULES: string = 'rules';
const TAB_RULE_SETS: string = 'ruleSets';
const TAB_GROUPS: string = 'groups';

/** 规则集卡片的仓库侧信息(join 自 RuleSetRepository,展示真实时间戳) */
class RuleSetMeta {
  lastAttemptAt: number = 0;
  lastSuccessfulDownloadAt: number = 0;
  validatedAt: number = 0;
  lastError: string = '';
  available: boolean = false;
  blockedReason: string = '';
  capability: string = '';
  currentHash: string = '';
  versionCount: number = 0;
}

/** 列表行视图(编译顺序来自 compileManifest,不是名称排序) */
class RuleRowView {
  rule: RoutingRule = new RoutingRule();
  /** 稳定 ID / 启用 / 出站 的镜像(ForEach key 只读顶层镜像字段) */
  id: string = '';
  enabled: boolean = true;
  outbound: string = '';
  /** 1 起的内核编译序号;0 = 未参与编译(停用/平台不支持/无匹配条件) */
  compiledIndex: number = 0;
  /** 条件组数(不同字段 AND;同字段多值算一组) */
  conditionCount: number = 0;
  /** 匹配摘要(RuleEditor.ruleSummary) */
  matchSummary: string = '';
  /** 组合语义 'and' | 'or'(RuleEditor.matchDescription) */
  matchMode: string = 'or';
  /** 处理目标文案 */
  outboundLabel: string = '';
  /** 来源标注:自定义 / 内置(预设) */
  sourceLabel: string = '自定义';
  /** 是否被规则引用缺失等校验问题命中 */
  issueLevel: string = '';
}

/** 规则类型的界面文案(与 RoutingRules 的类型 token 一一对应) */
function typeLabel(type: string): string {
  if (type === RULE_DOMAIN) {
    return '域名';
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
    return '规则集';
  }
  if (type === RULE_IP_CIDR) {
    return '目的 IP';
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
  if (type === LEGACY_PACKAGE_TYPE) {
    return '旧·包名';
  }
  if (type === LEGACY_ADVANCED_TYPE) {
    return '旧·高级';
  }
  return type;
}

/**
 * 路由页(§7.1–§7.5):四子页签 = 分应用 / 域名·IP 规则 / 规则集 / 策略组。
 * 规则读写走 RoutingRules 的新模型(raw 行 ↔ RoutingRule),存储键与旧模型一致,
 * 旧行条件原样保留在 legacyRow 里,写回时合并回去(不丢 AND 条件)。
 */
@Component
export struct RouteRulesPanel {
  /** 壳层注入:与应用事务同口径的待应用批次计数 + 已保存修订(不另造第二套,§12.2) */
  pendingChanges: number = 0;
  savedRevision: number = 0;
  /** 使用中的配置修订(ConfigRepository.getActiveRevision()) */
  activeRevision: number = 0;
  /** §7.1 子页签记忆:由壳层(Index 的 NavMemory)传入/回收 —— 本组件切 tab 会被重建,自身存不住 */
  initialTab: string = TAB_RULES;
  onTabChange: (tab: string) => void = (_tab: string) => {};
  onOpenDrawer: () => void = () => {};
  /** 分应用完整名单管理仍在设置页,本页先给入口(§3.1 要求最终迁到分流页) */
  /** 分应用保存成功后触发应用事务(Index.commitAndApplySettings;2026-10-24 分应用整体迁入本页) */
  onApplyPerApp: () => void = () => {};

  @State profiles: Array<Profile> = [];
  @State rules: Array<RoutingRule> = [];
  /* 快速新建规则(2026-10-24 用户指示:新建不再跳页,当前页对话框完成;
     行内「编辑」仍走 RuleEditPage 高级表单) */
  @State quickName: string = '';
  @State quickPayload: string = '';
  @State quickTypeIdx: number = 0;
  @State quickOutIdx: number = 1;
  @State quickError: string = '';
  private quickDialog: CustomDialogController = new CustomDialogController({
    builder: QuickRuleDialog({
      name: $quickName,
      payload: $quickPayload,
      typeIdx: $quickTypeIdx,
      outIdx: $quickOutIdx,
      errorText: $quickError,
      onConfirm: () => { this.confirmQuickRule(); }
    }),
    autoCancel: true
  });
  @State remoteRuleSets: Array<RemoteRuleSet> = [];
  @State ruleSetMetas: Array<RuleSetMeta> = Array<RuleSetMeta>();
  @State manifests: RuleManifest = new RuleManifest();
  @State errors: Array<RuleIssue> = Array<RuleIssue>();
  @State warnings: Array<RuleIssue> = Array<RuleIssue>();
  @State legacyCount: number = 0;
  @State legacyRuleViews: Array<LegacyRuleView> = Array<LegacyRuleView>();
  /* 策略组子页(§9.1):控制器可用性 + 运行图 proxy 组事实 */
  @State clashAvailable: boolean = false;
  @State clashReason: string = '';
  @State proxyGroupType: string = '';
  @State proxyMemberCount: number = 0;
  @State proxyNowLabel: string = MEMBER_UNKNOWN_LABEL;
  @State proxyMembers: Array<string> = Array<string>();
  @State switchBusy: string = '';
  @State clashPort: number = 0;
  private clashSecret: string = '';
  @State proxiesOk: boolean = false;
  @State proxiesReason: string = '';
  @State localGroups: Array<ProfileGroup> = Array<ProfileGroup>();
  @State loading: boolean = true;
  @State loadError: string = '';
  @State routingTab: string = TAB_RULES;
  @State perAppEffective: number = 0;
  @State busyRuleSetId: string = '';
  @State litKey: string = '';
  @State ruleSetCapability: string = 'unknown';
  private persistTimer: number = -1;
  private persistRemoteTimer: number = -1;

  aboutToAppear(): void {
    /* §7.1:子页签记忆由壳层给(组件切 tab 会重建);首次进入默认「域名·IP 规则」 */
    const remembered = this.initialTab;
    if (remembered === TAB_PERAPP || remembered === TAB_RULES || remembered === TAB_RULE_SETS
      || remembered === TAB_GROUPS) {
      this.routingTab = remembered;
    } else {
      this.routingTab = TAB_RULES;
    }
    this.load();
  }

  /** 从编辑器返回后重载(编辑器直接写 route_rules 行) */
  onPageShow(): void {
    void this.load();
  }

  aboutToDisappear(): void {
    this.flushPersist();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    try {
      this.profiles = await loadProfiles();
      const raw = await readPrefString(KEY_RULES, '[]');
      let rows: Array<Record<string, Object>> = [];
      try {
        rows = JSON.parse(raw) as Array<Record<string, Object>>;
      } catch (e) {
        rows = [];
      }
      this.rules = parseRules(rows);
      this.remoteRuleSets = await loadRemoteRuleSets();
      this.refreshRuleSetMetas();
      this.refreshDerived();
      await this.loadPerAppSummary();
    } catch (e) {
      this.loadError = e instanceof Error ? e.message : `${e}`;
    } finally {
      this.loading = false;
    }
  }

  /** 分应用摘要:有效包名数量(完整名单管理留在设置页,本轮只给摘要 + 入口) */
  private async loadPerAppSummary(): Promise<void> {
    try {
      const settings = await loadSettings();
      const entries: Array<PerAppEntry> = parseEntries(settings.perAppEntries);
      this.perAppEffective = effectivePackages(entries).length;
    } catch (e) {
      this.perAppEffective = -1;
    }
  }

  /** 规则集仓库侧信息(真实时间戳:lastAttemptAt / lastSuccessfulDownloadAt / validatedAt) */
  private refreshRuleSetMetas(): void {
    const metas: Array<RuleSetMeta> = [];
    for (let i = 0; i < this.remoteRuleSets.length; i++) {
      const rs = this.remoteRuleSets[i];
      const sid = sanitizeResourceId(rs.id);
      const meta = new RuleSetMeta();
      meta.capability = RuleSetRepository.describeCapability();
      if (sid.length > 0) {
        const avail: ResourceAvailability = RuleSetRepository.getAvailability(sid);
        const entity: RuleSetResource | null = RuleSetRepository.get(sid);
        meta.available = avail.available;
        meta.blockedReason = avail.reason;
        if (entity !== null) {
          meta.lastAttemptAt = entity.lastAttemptAt;
          meta.lastSuccessfulDownloadAt = entity.lastSuccessfulDownloadAt;
          meta.validatedAt = entity.validatedAt;
          meta.lastError = entity.lastError;
          meta.currentHash = entity.currentHash;
          meta.versionCount = entity.versions.length;
        }
      }
      metas.push(meta);
    }
    this.ruleSetMetas = metas;
    this.ruleSetCapability = RuleSetRepository.describeCapability();
  }

  /** 重新编译 manifest + 校验 + 重叠检测(与内核同一份顺序依据,§7.4) */
  private refreshDerived(): void {
    this.manifests = compileManifest(this.rules);
    const known: Array<string> = [];
    for (let i = 0; i < this.remoteRuleSets.length; i++) {
      const sid = sanitizeResourceId(this.remoteRuleSets[i].id);
      if (sid.length > 0) {
        known.push(sid);
      }
    }
    const validation: RuleValidation = validateRules(this.rules, known);
    this.errors = validation.errors;
    this.warnings = validation.warnings;
    this.legacyCount = validation.legacyCount;
    this.legacyRuleViews = legacyViews(this.rules);
    const overlaps = detectOverlap(this.rules);
    for (let i = 0; i < overlaps.length; i++) {
      const issue = overlaps[i];
      if (issue.code === ISSUE_OVERLAP) {
        this.warnings.push(issue);
      }
    }
  }

  // ---------------------------------------------------------------- 规则写盘

  private persistRules(): void {
    if (this.persistTimer >= 0) {
      clearTimeout(this.persistTimer);
    }
    this.persistTimer = setTimeout(() => {
      this.persistTimer = -1;
      void this.flushPersist();
    }, 800);
  }

  private async flushPersist(): Promise<void> {
    if (this.persistTimer >= 0) {
      clearTimeout(this.persistTimer);
      this.persistTimer = -1;
    }
    if (this.persistRemoteTimer >= 0) {
      clearTimeout(this.persistRemoteTimer);
      this.persistRemoteTimer = -1;
      await saveRemoteRuleSets(this.remoteRuleSets);
    }
    try {
      /* toRawRows:新字段(payload/order/id/ruleSource) + legacyRow 原样合并回写 */
      await writePrefString(KEY_RULES, JSON.stringify(toRawRows(this.rules)));
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `规则保存失败: ${msg}` });
    }
  }

  private persistRemote(): void {
    if (this.persistRemoteTimer >= 0) {
      clearTimeout(this.persistRemoteTimer);
    }
    this.persistRemoteTimer = setTimeout(() => {
      this.persistRemoteTimer = -1;
      void saveRemoteRuleSets(this.remoteRuleSets);
    }, 800);
  }

  // ---------------------------------------------------------------- 规则行视图

  private outboundLabelOf(outbound: string): string {
    if (outbound === RULE_OUT_DIRECT) {
      return '直连';
    }
    if (outbound === RULE_OUT_BLOCK) {
      return '拒绝';
    }
    if (outbound === RULE_OUT_PROXY) {
      return '代理';
    }
    if (outbound.startsWith('profile:')) {
      const id = outbound.substring('profile:'.length);
      for (let i = 0; i < this.profiles.length; i++) {
        if (this.profiles[i].id === id) {
          return `节点：${this.profiles[i].name}`;
        }
      }
      return '节点：已删除';
    }
    return outbound;
  }

  /** 列表行视图:编译顺序来自 manifest.items(禁用/不支持的行 compiledIndex=0) */
  private rowViewOf(rule: RoutingRule): RuleRowView {
    const row = new RuleRowView();
    row.rule = rule;
    row.id = rule.id;
    row.enabled = rule.enabled;
    row.outbound = rule.outbound;
    let compiledIndex = 0;
    for (let i = 0; i < this.manifests.items.length; i++) {
      if (this.manifests.items[i].ruleId === rule.id) {
        compiledIndex = i + 1;
        break;
      }
    }
    row.compiledIndex = compiledIndex;
    row.conditionCount = conditionCount(rule);
    row.matchSummary = ruleSummary(rule);
    row.matchMode = matchDescription(rule);
    row.outboundLabel = this.outboundLabelOf(rule.outbound);
    row.sourceLabel = rule.source === 'preset' ? '内置' : '自定义';
    for (let i = 0; i < this.errors.length; i++) {
      if (this.errors[i].ruleId === rule.id) {
        row.issueLevel = 'error';
        break;
      }
    }
    if (row.issueLevel.length === 0) {
      for (let i = 0; i < this.warnings.length; i++) {
        if (this.warnings[i].ruleId === rule.id) {
          row.issueLevel = 'warning';
          break;
        }
      }
    }
    return row;
  }

  private ruleNameOf(ruleId: string): string {
    for (let i = 0; i < this.rules.length; i++) {
      const rule = this.rules[i];
      if (rule.id === ruleId) {
        const preview = rule.payload.length > 24 ? `${rule.payload.substring(0, 24)}…` : rule.payload;
        return `${typeLabel(rule.type)}：${preview}`;
      }
    }
    return ruleId;
  }

  // ---------------------------------------------------------------- 规则操作

  private toggleRule(ruleId: string, enabled: boolean): void {
    for (let i = 0; i < this.rules.length; i++) {
      if (this.rules[i].id === ruleId) {
        this.rules[i].enabled = enabled;
        break;
      }
    }
    this.rules = this.rules.slice();
    this.refreshDerived();
    this.persistRules();
  }

  /**
   * 上移/下移(可访问性替代拖拽,§7.2):保持 order 连续(0..n-1),边界不变。
   * ⚠️ `model/RuleEditor.moveRule` 落地后换装成它(语义:同字段 AND、order 连续)。
   */
  /** 上移/下移:直接调 RuleEditor.moveRule(返回新数组,order 归一 0..n-1,边界不变) */
  private moveRuleById(ruleId: string, delta: number): void {
    this.rules = moveRule(this.rules, ruleId, delta);
    this.refreshDerived();
    this.persistRules();
  }

  private duplicateRule(ruleId: string): void {
    for (let i = 0; i < this.rules.length; i++) {
      if (this.rules[i].id !== ruleId) {
        continue;
      }
      const copy = this.rules[i];
      const cloned = new RoutingRule();
      cloned.id = newRuleId(copy.type);
      cloned.type = copy.type;
      cloned.payload = copy.payload;
      cloned.outbound = copy.outbound;
      cloned.enabled = copy.enabled;
      cloned.source = copy.source;
      cloned.unsupportedOnPlatform = copy.unsupportedOnPlatform;
      cloned.unsupportedReason = copy.unsupportedReason;
      cloned.legacyRow = JSON.parse(JSON.stringify(copy.legacyRow)) as Record<string, Object>;
      const next = this.rules.slice();
      next.splice(i + 1, 0, cloned);
      for (let k = 0; k < next.length; k++) {
        next[k].order = k;
      }
      this.rules = next;
      this.refreshDerived();
      this.persistRules();
      promptAction.showToast({ message: '已复制规则(未启用修改)' });
      return;
    }
  }

  private confirmDeleteRule(ruleId: string): void {
    const name = this.ruleNameOf(ruleId);
    AlertDialog.show({
      message: `删除规则「${name}」？此操作只删除规则本身，不影响规则集与分组。`,
      autoCancel: true,
      primaryButton: { value: $r('app.string.cancel'), action: () => {} },
      secondaryButton: {
        value: $r('app.string.delete'),
        fontColor: $r('app.color.error'),
        action: () => {
          const next: Array<RoutingRule> = [];
          for (let i = 0; i < this.rules.length; i++) {
            if (this.rules[i].id !== ruleId) {
              next.push(this.rules[i]);
            }
          }
          for (let i = 0; i < next.length; i++) {
            next[i].order = i;
          }
          this.rules = next;
          this.refreshDerived();
          this.persistRules();
        }
      }
    });
  }

  /** 编辑器入口(§7.3 本体在 model/RuleEditor 落地后接入;先给明确提示,不静默无反应) */
  private openEditor(ruleId: string): void {
    const params: Record<string, Object> = {};
    params['ruleId'] = ruleId;
    router.pushUrl({ url: 'pages/RuleEditPage', params: params });
  }

  /** 新建规则 → 编辑器(空表单) */
  private newRule(): void {
    /* 2026-10-24 用户指示:新建规则在当前页完成,不再跳独立页面 */
    this.quickName = '';
    this.quickPayload = '';
    this.quickTypeIdx = 0;
    this.quickOutIdx = 1;
    this.quickError = '';
    this.quickDialog.open();
  }

  /** 快速新建确认:RuleEditor 同一套表单模型/校验,落同一条草稿管线 */
  private confirmQuickRule(): void {
    const types: Array<string> = [RULE_DOMAIN_SUFFIX, RULE_DOMAIN, RULE_DOMAIN_KEYWORD,
      RULE_DOMAIN_REGEX, RULE_IP_CIDR, RULE_PORT];
    const outs: Array<string> = [RULE_OUT_DIRECT, RULE_OUT_PROXY, RULE_OUT_BLOCK];
    const form = emptyForm();
    form.name = this.quickName.trim();
    form.type = types[this.quickTypeIdx];
    form.payload = this.quickPayload.trim();
    form.outbound = outs[this.quickOutIdx];
    const errors = validateForm(form, this.knownRuleSetIds(), []);
    for (let i = 0; i < errors.length; i++) {
      if (errors[i].severity === SEVERITY_ERROR) {
        this.quickError = errors[i].detail.length > 0 ? errors[i].detail : errors[i].code;
        return;
      }
    }
    const rule = formToRule(form, null);
    rule.order = this.rules.length > 0 ? this.rules[this.rules.length - 1].order + 1 : 0;
    this.rules.push(rule);
    this.quickDialog.close();
    this.refreshDerived();
    this.persistRules();
    promptAction.showToast({ message: form.name.length > 0 ? `已创建规则 ${form.name}` : '已创建规则' });
  }

  /** 快速新建的 rule_set 引用校验用(与 refreshDerived 同一来源) */
  private knownRuleSetIds(): Array<string> {
    const known: Array<string> = [];
    for (let i = 0; i < this.remoteRuleSets.length; i++) {
      const sid = sanitizeResourceId(this.remoteRuleSets[i].id);
      if (sid.length > 0) {
        known.push(sid);
      }
    }
    return known;
  }

  /** 旧规则「转换」→ 编辑器(带 convertFrom;必须用户显式改写后 applyLegacyAction 才放行) */
  private convertLegacy(ruleId: string): void {
    const params: Record<string, Object> = {};
    params['ruleId'] = '';
    params['convertFrom'] = ruleId;
    router.pushUrl({ url: 'pages/RuleEditPage', params: params });
  }

  /** 旧规则动作(§8.5):pause 直接禁用副本;delete 直接移除;convert 必须先编辑 */
  private applyLegacy(ruleId: string, action: string): void {
    if (action === 'convert') {
      this.convertLegacy(ruleId);
      return;
    }
    if (action === 'delete') {
      const next: Array<RoutingRule> = [];
      for (let k = 0; k < this.rules.length; k++) {
        if (this.rules[k].id !== ruleId) {
          next.push(this.rules[k]);
        }
      }
      for (let k = 0; k < next.length; k++) {
        next[k].order = k;
      }
      this.rules = next;
      this.refreshDerived();
      this.persistRules();
      return;
    }
    for (let i = 0; i < this.rules.length; i++) {
      if (this.rules[i].id !== ruleId) {
        continue;
      }
      const result = applyLegacyAction(this.rules[i], action, null);
      if (result === null) {
        promptAction.showToast({ message: '该动作被拒绝（旧规则需先显式转换）' });
        return;
      }
      this.rules[i] = result;
      this.rules = this.rules.slice();
      this.refreshDerived();
      this.persistRules();
      return;
    }
  }

  // ---------------------------------------------------------------- 规则集操作

  private addRemoteRuleSet(): void {
    const item = new RemoteRuleSet();
    item.id = `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    const next = this.remoteRuleSets.slice();
    next.push(item);
    this.remoteRuleSets = next;
    this.refreshRuleSetMetas();
    this.persistRemote();
  }

  private updateRemoteRuleSet(index: number, field: string, value: Object): void {
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
    this.persistRemote();
  }

  private removeRemoteRuleSet(index: number): void {
    const next = this.remoteRuleSets.slice();
    const removed = next[index];
    next.splice(index, 1);
    this.remoteRuleSets = next;
    this.refreshRuleSetMetas();
    this.persistRemote();
    if (removed !== undefined) {
      const sid = sanitizeResourceId(removed.id);
      if (sid.length > 0) {
        void RuleSetRepository.removeResource(sid).then((ok: boolean) => {
          this.refreshRuleSetMetas();
          LogStore.addLog(`[ruleset] 本地缓存已删除: ${sid}(ok=${ok})`);
        });
      }
    }
  }

  private moveRemoteRuleSet(index: number, delta: number): void {
    const target = index + delta;
    if (target < 0 || target >= this.remoteRuleSets.length) {
      return;
    }
    const next = this.remoteRuleSets.slice();
    const tmp = next[index];
    next[index] = next[target];
    next[target] = tmp;
    this.remoteRuleSets = next;
    this.refreshRuleSetMetas();
    this.persistRemote();
  }

  /** 下载/更新规则集:URL 先校验,再 ensureResource(下载→校验→落盘→提交清单) */
  private async downloadRuleSet(rs: RemoteRuleSet): Promise<void> {
    const sid = sanitizeResourceId(rs.id);
    if (sid.length === 0) {
      promptAction.showToast({ message: '规则集 ID 非法' });
      return;
    }
    const urlError = RuleSetRepository.validateUrl(rs.url);
    if (urlError.length > 0) {
      promptAction.showToast({ message: `下载地址无效：${urlError}` });
      return;
    }
    this.busyRuleSetId = sid;
    try {
      const avail: ResourceAvailability = await RuleSetRepository.ensureResource(sid, rs.url);
      this.refreshRuleSetMetas();
      if (avail.available) {
        promptAction.showToast({ message: '规则集已下载并校验通过' });
      } else {
        promptAction.showToast({ message: `规则集不可用：${avail.reason}` });
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : `${e}`;
      promptAction.showToast({ message: `规则集下载失败：${msg}` });
    } finally {
      this.busyRuleSetId = '';
    }
  }

  private toggleRuleSetPolicy(rs: RemoteRuleSet, blocked: boolean): void {
    const sid = sanitizeResourceId(rs.id);
    if (sid.length === 0) {
      return;
    }
    const policy = blocked ? 'allow-unverified' : 'block';
    void RuleSetRepository.setFailurePolicy(sid, policy).then((ok: boolean) => {
      this.refreshRuleSetMetas();
      promptAction.showToast({ message: ok ? '失败策略已更新' : '失败策略更新失败' });
    });
  }

  // ---------------------------------------------------------------- 顶部状态 + 页签

  private revisionText(): string {
    const active = this.activeRevision > 0 ? `r${this.activeRevision}` : '未建立快照';
    if (this.pendingChanges > 0) {
      return `使用中配置 ${active} · 待应用 ${this.pendingChanges} 项`;
    }
    return `使用中配置 ${active} · 无待应用修改`;
  }

  @Builder
  private headerStatus() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.revisionText())
          .fontSize(11)
          .fontColor($r('app.color.text_3'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.errors.length > 0 || this.warnings.length > 0) {
          Row({ space: 4 }) {
            Circle()
              .width(6)
              .height(6)
              .fill(this.errors.length > 0 ? $r('app.color.error') : $r('app.color.warning'))
            Text(`${this.errors.length} 错 / ${this.warnings.length} 警`)
              .fontSize(11)
              .fontColor(this.errors.length > 0 ? $r('app.color.error') : $r('app.color.warning'))
          }
        }
      }
      .width('100%')

      Row({ space: 6 }) {
        this.tabButton('分应用', TAB_PERAPP)
        this.tabButton('域名·IP 规则', TAB_RULES)
        this.tabButton('规则集', TAB_RULE_SETS)
        this.tabButton('策略组', TAB_GROUPS)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 6, bottom: 8 })
  }

  @Builder
  private tabButton(label: string, id: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.routingTab === id ? 700 : 400)
      .fontColor(this.routingTab === id ? $r('app.color.surface') : $r('app.color.text_2'))
      .textAlign(TextAlign.Center)
      .height(30)
      .layoutWeight(id === TAB_RULES ? 1.4 : 1)
      .borderRadius(8)
      .backgroundColor(this.routingTab === id ? $r('app.color.primary') : $r('app.color.surface'))
      .onClick(() => {
        this.routingTab = id;
        this.onTabChange(id);
        if (id === TAB_GROUPS) {
          void this.refreshGroups();
        }
      })
  }

  // ---------------------------------------------------------------- 规则子页

  @Builder
  private issuesBanner() {
    Column({ space: 6 }) {
      if (this.errors.length > 0) {
        this.issueGroup('错误', this.errors, $r('app.color.error'))
      }
      if (this.warnings.length > 0) {
        this.issueGroup('警告', this.warnings, $r('app.color.warning'))
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(10)
  }

  @Builder
  private issueGroup(title: string, issues: Array<RuleIssue>, color: ResourceColor) {
    Column({ space: 4 }) {
      Text(`${title} ${issues.length}`)
        .fontSize(11)
        .fontWeight(700)
        .fontColor(color)
        .width('100%')
      ForEach(issues.slice(0, 5), (issue: RuleIssue) => {
        Row({ space: 6 }) {
          Text(`· ${this.ruleNameOf(issue.ruleId)}`)
            .fontSize(11)
            .fontColor($r('app.color.text_2'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('详情')
            .fontSize(11)
            .fontColor($r('app.color.primary'))
        }
        .width('100%')
        .onClick(() => {
          AlertDialog.show({
            title: `${title}：${issue.code}`,
            message: `${this.ruleNameOf(issue.ruleId)}\n\n${issue.detail}`,
            autoCancel: true,
            primaryButton: { value: $r('app.string.ok'), action: () => {} }
          });
        })
      }, (issue: RuleIssue) => `${issue.ruleId}_${issue.code}_${issue.detail}`)
    }
    .width('100%')
  }

  @Builder
  private ruleCard(row: RuleRowView) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(row.compiledIndex > 0 ? `#${row.compiledIndex}` : '—')
          .fontSize(11)
          .fontWeight(700)
          .fontColor(row.compiledIndex > 0 ? $r('app.color.primary') : $r('app.color.text_3'))
          .width(30)
        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(row.matchSummary)
              .fontSize(13)
              .fontColor($r('app.color.text_1'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (row.issueLevel.length > 0) {
              Circle()
                .width(6)
                .height(6)
                .fill(row.issueLevel === 'error' ? $r('app.color.error') : $r('app.color.warning'))
            }
          }
          .width('100%')
          Text(row.conditionCount > 1
            ? `${row.outboundLabel} · ${row.sourceLabel} · 等 ${row.conditionCount} 个条件（同时满足）`
            : `${row.outboundLabel} · ${row.sourceLabel}`)
            .fontSize(11)
            .fontColor($r('app.color.text_3'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: row.rule.enabled })
          .onChange((on: boolean) => {
            this.toggleRule(row.rule.id, on);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (row.compiledIndex === 0) {
        Text(row.rule.enabled ? '未参与编译（缺少匹配条件或平台不支持）' : '已停用，不参与编译')
          .fontSize(10)
          .fontColor($r('app.color.text_3'))
          .width('100%')
      }

      Row({ space: 6 }) {
        this.rowAction('上移', `rule:up:${row.rule.id}`, () => {
          this.moveRuleById(row.rule.id, -1);
        })
        this.rowAction('下移', `rule:down:${row.rule.id}`, () => {
          this.moveRuleById(row.rule.id, 1);
        })
        this.rowAction('编辑', `rule:edit:${row.rule.id}`, () => {
          this.openEditor(row.rule.id);
        })
        this.rowAction('复制', `rule:copy:${row.rule.id}`, () => {
          this.duplicateRule(row.rule.id);
        })
        this.rowAction('删除', `rule:del:${row.rule.id}`, () => {
          this.confirmDeleteRule(row.rule.id);
        })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
  }

  private indexOfRule(ruleId: string): number {
    for (let i = 0; i < this.rules.length; i++) {
      if (this.rules[i].id === ruleId) {
        return i;
      }
    }
    return -1;
  }

  @Builder
  private rowAction(label: string, key: string, action: () => void) {
    Text(label)
      .fontSize(11)
      .fontColor($r('app.color.text_2'))
      .textAlign(TextAlign.Center)
      .height(26)
      .layoutWeight(1)
      .borderRadius(7)
      .backgroundColor($r('app.color.bg_page'))
      .visualEffect(pressLightEffect(this.litKey === key, false))
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.litKey = key;
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.litKey = '';
        }
      })
      .onClick(action)
  }

  @Builder
  private rulesTab() {
    if (this.loading) {
      LoadingProgress()
        .width(28)
        .height(28)
        .margin({ top: 24 })
    } else if (this.loadError.length > 0) {
      Text(`加载失败：${this.loadError}`)
        .fontSize(12)
        .fontColor($r('app.color.error'))
        .padding(12)
    } else {
      List({ space: 8 }) {
        if (this.errors.length > 0 || this.warnings.length > 0) {
          ListItem() {
            this.issuesBanner()
          }
        }
        if (this.legacyRuleViews.length > 0) {
          ListItem() {
            this.legacySection()
          }
        }
        ForEach(this.rules.map((rule: RoutingRule) => this.rowViewOf(rule)), (row: RuleRowView) => {
          ListItem() {
            this.ruleCard(row)
          }
        }, (row: RuleRowView, index: number) =>
          `${row.id}_${row.enabled}_${row.outbound}_${row.compiledIndex}_${index}`)
        ListItem() {
          Column({ space: 6 }) {
            Button('新建规则')
              .height(36)
              .width('100%')
              .backgroundColor($r('app.color.primary'))
              .fontColor($r('app.color.surface'))
              .onClick(() => this.newRule())
            Text('规则按上面的内核编译顺序生效（#1 最先匹配）；上移/下移即调整优先级，保存后在顶部「待应用」里统一应用。')
              .fontSize(10)
              .fontColor($r('app.color.text_3'))
              .width('100%')
              .padding({ left: 4, right: 4 })
          }
          .width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 12 })
    }
  }

  /**
   * 旧规则区(§8.5):旧包名 / 平台不支持规则逐条列出,三条动作全部显式:
   * 暂停(保留原文仅禁用) / 转换(必须进编辑器手动改写,applyLegacyAction 拒绝自动推导) / 删除。
   */
  @Builder
  private legacySection() {
    Column({ space: 8 }) {
      Text(`有 ${this.legacyRuleViews.length} 条旧规则需要处理`)
        .fontSize(12)
        .fontWeight(700)
        .fontColor($r('app.color.warning'))
        .width('100%')
      Text('旧包名规则在鸿蒙上无法执行；转换必须手动改写匹配条件（不自动推导）。')
        .fontSize(10)
        .fontColor($r('app.color.text_3'))
        .width('100%')
      ForEach(this.legacyRuleViews, (v: LegacyRuleView) => {
        Column({ space: 6 }) {
          Text(v.summary)
            .fontSize(12)
            .fontColor($r('app.color.text_1'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            this.rowAction('保留(暂停)', `legacy:pause:${v.rule.id}`, () => {
              this.applyLegacy(v.rule.id, 'pause');
            })
            this.rowAction('转换…', `legacy:convert:${v.rule.id}`, () => {
              this.applyLegacy(v.rule.id, 'convert');
            })
            this.rowAction('删除', `legacy:del:${v.rule.id}`, () => {
              this.applyLegacy(v.rule.id, 'delete');
            })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .backgroundColor($r('app.color.bg_page'))
        .borderRadius(8)
      }, (v: LegacyRuleView) => `${v.rule.id}_${v.rule.enabled}`)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(10)
  }

  // ---------------------------------------------------------------- 分应用子页

  @Builder
  private perAppTab() {
    /* 2026-10-24 用户指示:分应用完整管理从设置页迁到本页(PerAppManager 自包含,
     * 保存即回调 onApplyPerApp 走应用事务;有效数量/待应用行保留在摘要条)。
     * 不能套 Scroll:内容比视口矮时 Scroll 会把子组件垂直居中(真机实测内容
     * 顶距 +390px),PerAppManager 内部 List 已自带滚动,这里直接 Column 顶排。 */
    Column({ space: 10 }) {
      Column({ space: 4 }) {
        Text('分应用代理')
          .fontSize(14)
          .fontWeight(700)
          .fontColor($r('app.color.text_1'))
          .width('100%')
        Text(this.pendingChanges > 0 ? `待应用修改 ${this.pendingChanges} 项` : '无待应用修改')
          .fontSize(11)
          .fontColor(this.pendingChanges > 0 ? $r('app.color.warning') : $r('app.color.text_3'))
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.surface'))
      .borderRadius(12)

      PerAppManager({
        onApplyNow: () => {
          this.onApplyPerApp();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, top: 4 })
  }

  // ---------------------------------------------------------------- 规则集子页

  private formatTime(ms: number): string {
    if (ms <= 0) {
      return '—';
    }
    const d = new Date(ms);
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  private capabilityText(): string {
    if (this.ruleSetCapability === 'kernel-k1') {
      return '内核校验可用（下载后做 SRS 内容校验）';
    }
    if (this.ruleSetCapability === 'unsupported') {
      return '内核校验不可用（本机 .so 无校验导出）⇒ 下载结果不会标「已验证」';
    }
    return '内核校验能力未知';
  }

  @Builder
  private ruleSetCard(rs: RemoteRuleSet, meta: RuleSetMeta, index: number) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        TextInput({ text: rs.name, placeholder: '规则集名称' })
          .height(34)
          .layoutWeight(1)
          .fontSize(13)
          .onChange((v: string) => this.updateRemoteRuleSet(index, 'name', v))
        Toggle({ type: ToggleType.Switch, isOn: rs.enabled })
          .onChange((on: boolean) => this.updateRemoteRuleSet(index, 'enabled', on))
      }
      .width('100%')

      TextInput({ text: rs.url, placeholder: 'https://example.com/rule.srs' })
        .height(34)
        .fontSize(12)
        .width('100%')
        .onChange((v: string) => this.updateRemoteRuleSet(index, 'url', v))

      Row({ space: 6 }) {
        this.chip('域名规则', rs.type === 'site', () => this.updateRemoteRuleSet(index, 'type', 'site'))
        this.chip('IP 规则', rs.type === 'ip', () => this.updateRemoteRuleSet(index, 'type', 'ip'))
        this.chip('直连', rs.outbound === 'direct', () => this.updateRemoteRuleSet(index, 'outbound', 'direct'))
        this.chip('代理', rs.outbound === 'proxy', () => this.updateRemoteRuleSet(index, 'outbound', 'proxy'))
      }
      .width('100%')

      Column({ space: 2 }) {
        Text(`上次尝试：${this.formatTime(meta.lastAttemptAt)} · 上次成功下载：${this.formatTime(meta.lastSuccessfulDownloadAt)}`)
          .fontSize(10)
          .fontColor($r('app.color.text_3'))
          .width('100%')
        Text(meta.validatedAt > 0
          ? `已验证：${this.formatTime(meta.validatedAt)} · 版本 ${meta.versionCount} 个`
          : '未验证（不会被编译引用）')
          .fontSize(10)
          .fontColor(meta.validatedAt > 0 ? $r('app.color.mono') : $r('app.color.warning'))
          .width('100%')
        if (meta.lastError.length > 0) {
          Text(`上次错误：${meta.lastError}`)
            .fontSize(10)
            .fontColor($r('app.color.error'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Row({ space: 6 }) {
        this.rowAction(this.busyRuleSetId === sanitizeResourceId(rs.id) ? '下载中…' : '下载/更新',
          `rs:dl:${rs.id}`, () => {
            void this.downloadRuleSet(rs);
          })
        this.rowAction('下载失败时放行', `rs:pol:${rs.id}`, () => {
          this.toggleRuleSetPolicy(rs, meta.blockedReason.length > 0);
        })
        this.rowAction('上移', `rs:up:${rs.id}`, () => this.moveRemoteRuleSet(index, -1))
        this.rowAction('下移', `rs:down:${rs.id}`, () => this.moveRemoteRuleSet(index, 1))
        this.rowAction('删除', `rs:del:${rs.id}`, () => this.removeRemoteRuleSet(index))
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(12)
  }

  @Builder
  private chip(label: string, active: boolean, action: () => void) {
    Text(label)
      .fontSize(11)
      .fontColor(active ? $r('app.color.surface') : $r('app.color.text_2'))
      .textAlign(TextAlign.Center)
      .height(26)
      .layoutWeight(1)
      .borderRadius(7)
      .backgroundColor(active ? $r('app.color.primary') : $r('app.color.bg_page'))
      .onClick(action)
  }

  @Builder
  private ruleSetsTab() {
    List({ space: 8 }) {
      ListItem() {
        Column({ space: 4 }) {
          Text(this.capabilityText())
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
            .width('100%')
          Text('时间戳来自规则集仓库（editedAt 不冒充下载时间）。')
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
            .width('100%')
        }
        .width('100%')
        .padding({ left: 4, right: 4, top: 4 })
      }
      ForEach(this.remoteRuleSets, (item: RemoteRuleSet, index: number) => {
        ListItem() {
          this.ruleSetCard(item, this.metaAt(index), index)
        }
      }, (item: RemoteRuleSet, index: number) =>
        `${item.id}_${item.type}_${item.outbound}_${item.enabled}_${item.lastError}_${index}`)
      ListItem() {
        Button($r('app.string.add'))
          .height(36)
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.primary'))
          .onClick(() => this.addRemoteRuleSet())
      }
    }
    .width('100%')
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring)
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 12 })
  }

  private metaAt(index: number): RuleSetMeta {
    if (index >= 0 && index < this.ruleSetMetas.length) {
      return this.ruleSetMetas[index];
    }
    return new RuleSetMeta();
  }

  // ---------------------------------------------------------------- 策略组子页

  private clashConfig(): ClashApiConfig {
    const cfg = new ClashApiConfig();
    cfg.port = this.clashPort;
    cfg.secret = this.clashSecret;
    return cfg;
  }

  private clashReasonText(): string {
    if (this.clashPort <= 0) {
      return '控制器未启用（clashApiPort=0）';
    }
    if (this.clashReason.length === 0) {
      return '控制器不可用';
    }
    if (this.clashReason === 'refused') {
      return '连不上控制器（VPN 未运行或端口未监听）';
    }
    if (this.clashReason === 'timeout') {
      return '控制器响应超时';
    }
    if (this.clashReason === 'unauthorized') {
      return '控制器鉴权失败（密钥不匹配）';
    }
    return `控制器不可用：${this.clashReason}`;
  }

  /** §9.1 加载:checkAvailability → getProxies → 只渲染运行事实(actualMemberView,unknown 不猜) */
  private async refreshGroups(): Promise<void> {
    try {
      this.localGroups = await loadGroups();
      const settings = await loadSettings();
      this.clashPort = settings.clashApiPort;
      this.clashSecret = settings.clashApiSecret;
      const api = new ClashApi();
      const avail: ClashAvailability = await api.checkAvailability(this.clashConfig());
      this.clashAvailable = avail.available;
      this.clashReason = avail.reason;
      if (!avail.available) {
        this.proxiesOk = false;
        this.proxiesReason = avail.reason;
        this.proxyGroupType = '';
        this.proxyMemberCount = 0;
        this.proxyMembers = [];
        this.proxyNowLabel = MEMBER_UNKNOWN_LABEL;
        return;
      }
      const proxies: ClashProxiesResult = await api.getProxies(this.clashConfig());
      this.proxiesOk = proxies.ok;
      this.proxiesReason = proxies.reason;
      // 现网运行图里承接流量的组 tag 恒为 'proxy'(ConfigBuilder 只下发一个 wrapper;多组下发是 W15)
      const group: ClashProxy | undefined = proxies.proxies.get('proxy');
      if (group === undefined) {
        this.proxyGroupType = '';
        this.proxyMemberCount = 0;
        this.proxyMembers = [];
      } else {
        this.proxyGroupType = group.type === CLASH_TYPE_URLTEST ? GROUP_TYPE_URLTEST
          : (group.type === CLASH_TYPE_SELECTOR ? GROUP_TYPE_SELECTOR : group.type);
        this.proxyMemberCount = group.all.length;
        this.proxyMembers = group.all.slice(0, 40);
      }
      const view: ActualMemberView = actualMemberView('proxy', proxies);
      this.proxyNowLabel = view.state === 'known' ? view.label : MEMBER_UNKNOWN_LABEL;
    } catch (e) {
      this.clashAvailable = false;
      this.clashReason = e instanceof Error ? e.message : `${e}`;
    }
  }

  /** §9.2 切换:hotSwitchDecision → selectProxy → GET 核对 now(失败不提前打"正在使用") */
  private async switchMember(memberTag: string): Promise<void> {
    if (this.switchBusy.length > 0) {
      return;
    }
    this.switchBusy = memberTag;
    try {
      const api = new ClashApi();
      const before: ClashProxiesResult = await api.getProxies(this.clashConfig());
      const decision: HotSwitchDecision = hotSwitchDecision(this.proxyGroupType, memberTag, 'proxy', before);
      if (!decision.canSwitch) {
        promptAction.showToast({
          message: decision.needsRebuild
            ? '需要重建配置（统一重连）才能切换该组，请到首页重连后重试'
            : `当前不可切换：${decision.reason}`
        });
        return;
      }
      const selected: ClashSelectResult = await api.selectProxy(this.clashConfig(), 'proxy', memberTag);
      if (!selected.ok) {
        promptAction.showToast({ message: `切换请求被拒绝：${selected.reason}` });
        await this.refreshGroups();
        return;
      }
      const after: ClashProxiesResult = await api.getProxies(this.clashConfig());
      const verified: VerifyNowResult = verifyNow(before, after, 'proxy', memberTag);
      if (!verified.ok) {
        promptAction.showToast({ message: `切换未生效（核对失败：${verified.reason}）` });
      } else {
        promptAction.showToast({ message: `已切换到 ${memberTag}` });
      }
      await this.refreshGroups();
    } finally {
      this.switchBusy = '';
    }
  }

  @Builder
  private groupsTab() {
    List({ space: 8 }) {
      ListItem() {
        Column({ space: 4 }) {
          Text('策略组')
            .fontSize(14)
            .fontWeight(700)
            .fontColor($r('app.color.text_1'))
            .width('100%')
          Text(this.clashAvailable
            ? (this.proxiesOk ? '控制器可用，以下为运行图实际状态' : `控制器可用但读取失败：${this.proxiesReason}`)
            : this.clashReasonText())
            .fontSize(10)
            .fontColor(this.clashAvailable && this.proxiesOk ? $r('app.color.mono') : $r('app.color.warning'))
            .width('100%')
          Text(`本机策略组 ${this.localGroups.length} 个（手动分组；订阅分组在首页分组条）`)
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
      }

      ListItem() {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text('承流量的组（运行图 proxy）')
              .fontSize(12)
              .fontWeight(700)
              .fontColor($r('app.color.text_1'))
              .layoutWeight(1)
            Text(this.proxyGroupType.length > 0 ? this.proxyGroupType : '—')
              .fontSize(10)
              .fontColor($r('app.color.text_3'))
          }
          .width('100%')
          Text(`实际节点：${this.proxyNowLabel}`)
            .fontSize(12)
            .fontColor(this.proxyNowLabel === MEMBER_UNKNOWN_LABEL
              ? $r('app.color.warning') : $r('app.color.text_1'))
            .width('100%')
          Text(`成员 ${this.proxyMemberCount} 个${this.proxyGroupType === GROUP_TYPE_URLTEST ? ' · 内核自动选择（不可手动切换）' : ''}`)
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
            .width('100%')
          if (this.proxyGroupType === GROUP_TYPE_URLTEST) {
            Text('URLTest 组由内核按周期探测自动选成员（Clash PUT 会 400 "Must be a Selector"），本页不提供切换。')
              .fontSize(10)
              .fontColor($r('app.color.text_3'))
              .width('100%')
          }
          if (this.proxyGroupType === GROUP_TYPE_SELECTOR && this.proxyMembers.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.proxyMembers, (tag: string) => {
                Text(this.switchBusy === tag ? '切换中…' : tag)
                  .fontSize(10)
                  .fontColor(tag === this.proxyNowLabel ? $r('app.color.surface') : $r('app.color.text_2'))
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .margin({ right: 6, top: 4 })
                  .backgroundColor(tag === this.proxyNowLabel ? $r('app.color.primary') : $r('app.color.bg_page'))
                  .borderRadius(8)
                  .onClick(() => {
                    void this.switchMember(tag);
                  })
              }, (tag: string) => `${tag}_${this.switchBusy}`)
            }
            .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
      }

      ListItem() {
        Column({ space: 6 }) {
          Text('策略组列表（数据模型）')
            .fontSize(12)
            .fontWeight(700)
            .fontColor($r('app.color.text_1'))
            .width('100%')
          if (this.localGroups.length === 0) {
            Text('还没有手动分组')
              .fontSize(10)
              .fontColor($r('app.color.text_3'))
              .width('100%')
          }
          ForEach(this.localGroups, (g: ProfileGroup) => {
            Row({ space: 6 }) {
              Text(g.name.length > 0 ? g.name : g.id)
                .fontSize(12)
                .fontColor($r('app.color.text_1'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(g.autoSelect ? 'urltest' : (g.isSelector ? 'selector' : '普通'))
                .fontSize(10)
                .fontColor($r('app.color.text_3'))
            }
            .width('100%')
          }, (g: ProfileGroup) => `${g.id}_${g.name}_${g.isSelector}_${g.autoSelect}`)
          Text('多组稳定 tag 下发是 W15 的活；本批只对运行图中承接流量的 proxy 组提供切换，PR 后一律 GET 核对 now 才算成功。')
            .fontSize(10)
            .fontColor($r('app.color.text_3'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(12)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring)
    .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 12 })
  }

  build() {
    Column() {
      this.headerStatus()
      if (this.routingTab === TAB_RULES) {
        this.rulesTab()
      } else if (this.routingTab === TAB_RULE_SETS) {
        this.ruleSetsTab()
      } else if (this.routingTab === TAB_PERAPP) {
        this.perAppTab()
      } else {
        this.groupsTab()
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }
}


/**
 * 快速新建规则对话框(2026-10-24 用户指示:新建在当前页完成,不再跳页)。
 * 类型/载荷/出站三要素;高级条件(端口/网络/JSON)仍走行内「编辑」的完整表单页。
 * 校验与落库与 RuleEditPage 同一套 RuleEditor 模型。
 */
@CustomDialog
struct QuickRuleDialog {
  controller?: CustomDialogController;
  @Link name: string;
  @Link payload: string;
  @Link typeIdx: number;
  @Link outIdx: number;
  @Link errorText: string;
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Text('新建规则')
        .fontSize(17)
        .fontWeight(700)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      TextInput({ text: this.name, placeholder: '名称(可选,仅界面显示)' })
        .height(40)
        .maxLength(40)
        .onChange((v: string) => { this.name = v; })

      Column({ space: 4 }) {
        Text('类型').fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
        Select([
          { value: '域名后缀' } as SelectOption,
          { value: '域名' } as SelectOption,
          { value: '域名关键词' } as SelectOption,
          { value: '域名正则' } as SelectOption,
          { value: 'IP-CIDR' } as SelectOption,
          { value: '端口' } as SelectOption
        ])
          .selected(this.typeIdx)
          .value(['域名后缀', '域名', '域名关键词', '域名正则', 'IP-CIDR', '端口'][this.typeIdx])
          .onSelect((i: number) => { this.typeIdx = i; this.errorText = ''; })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column({ space: 4 }) {
        Text('条件(多个用逗号或换行分隔)').fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
        TextArea({ text: this.payload, placeholder: '例如: google.com, youtube.com 或 8.8.8.0/24' })
          .height(90)
          .onChange((v: string) => { this.payload = v; this.errorText = ''; })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column({ space: 4 }) {
        Text('出站').fontSize(11).fontColor($r('app.color.text_secondary')).width('100%')
        Select([
          { value: '直连' } as SelectOption,
          { value: '代理' } as SelectOption,
          { value: '拒绝' } as SelectOption
        ])
          .selected(this.outIdx)
          .value(['直连', '代理', '拒绝'][this.outIdx])
          .onSelect((i: number) => { this.outIdx = i; })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(11)
          .fontColor($r('app.color.error'))
          .width('100%')
      }

      Row({ space: 10 }) {
        Button($r('app.string.cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button($r('app.string.confirm'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.surface'))
          .onClick(() => this.onConfirm())
      }.width('100%')
    }
    .padding(20)
    .width('100%')
  }
}
