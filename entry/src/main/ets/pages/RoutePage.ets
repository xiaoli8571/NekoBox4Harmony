import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import common from '@ohos.app.ability.common';
import { RouteProfile, RouteRule, RuleSetMetadata, ROUTE_PRESETS, ROUTE_RULE_KINDS, ROUTE_RULE_ACTIONS, routePresetLabel, newRouteRule } from '../common/model/RouteProfile';
import { RouteStorage } from '../common/storage/RouteStorage';

@Entry
@Component
struct RoutePage {
  @State route: RouteProfile = new RouteProfile();
  @State loaded: boolean = false;
  @State saving: boolean = false;
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    RouteStorage.initialize(this.context).then(async () => {
      let active = await RouteStorage.active();
      if (active === null) {
        active = new RouteProfile();
        active.id = `route_${Date.now()}`;
        await RouteStorage.save([active]);
        await RouteStorage.setActiveId(active.id);
      }
      this.route = active;
      this.loaded = true;
    }).catch(() => {
      promptAction.showToast({ message: '路由配置读取失败' });
    });
  }

  cyclePreset(): void {
    const index = ROUTE_PRESETS.indexOf(this.route.preset);
    const next = ROUTE_PRESETS[(index + 1 + ROUTE_PRESETS.length) % ROUTE_PRESETS.length];
    this.route.preset = next;
    this.route.name = routePresetLabel(next);
    this.route = this.route;
  }

  addRule(): void {
    this.route.rules.push(newRouteRule());
    this.route = this.route;
  }

  removeRule(index: number): void {
    if (index >= 0 && index < this.route.rules.length) {
      this.route.rules.splice(index, 1);
      this.route = this.route;
    }
  }

  async save(): Promise<void> {
    if (this.saving || !this.loaded) return;
    this.saving = true;
    try {
      this.route.updatedAt = Date.now();
      const routes = await RouteStorage.list();
      let found = false;
      for (let i = 0; i < routes.length; i++) {
        if (routes[i].id === this.route.id) {
          routes[i] = this.route;
          found = true;
          break;
        }
      }
      if (!found) routes.push(this.route);
      await RouteStorage.save(routes);
      await RouteStorage.setActiveId(this.route.id);
      promptAction.showToast({ message: '路由配置已保存，重连 VPN 后生效' });
    } catch (e) {
      promptAction.showToast({ message: `保存失败: ${e instanceof Error ? e.message : `${e}`}` });
    } finally {
      this.saving = false;
    }
  }

  build() {
    Column() {
      Row() {
        Text('←').fontSize(22).onClick(() => router.back()).padding(8)
        Text('路由').fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Text(this.saving ? '保存中' : '保存').fontSize(14).fontColor('#1E88E5').padding(8).onClick(() => this.save())
      }.width('100%').padding(12)
      if (!this.loaded) {
        LoadingProgress().width(32).height(32).margin({ top: 40 })
      } else {
        Scroll() {
          Column({ space: 12 }) {
            Row() {
              Text('预设').fontSize(15).layoutWeight(1)
              Button(routePresetLabel(this.route.preset)).onClick(() => this.cyclePreset())
            }.width('100%')
            Text('预设循环：全局代理 → 绕过中国 → 全局直连 → 广告拦截 → 自定义')
              .fontSize(12).fontColor('#777777').width('100%')
            Row() {
              Text('规则').fontSize(16).fontWeight(FontWeight.Bold).layoutWeight(1)
              Button('添加').onClick(() => this.addRule())
            }.width('100%')
            ForEach(this.route.rules, (rule: RouteRule, index: number) => {
              Column({ space: 6 }) {
                Row() {
                  Text(`#${index + 1}`).fontSize(12).fontColor('#777777').layoutWeight(1)
                  Button('删除').fontSize(12).onClick(() => this.removeRule(index))
                }.width('100%')
                TextInput({ text: rule.kind, placeholder: '类型' }).onChange((value: string) => {
                  if (ROUTE_RULE_KINDS.includes(value)) rule.kind = value;
                }).width('100%')
                TextInput({ text: rule.value, placeholder: '匹配值（域名/IP/端口/进程/规则集）' }).onChange((value: string) => {
                  rule.value = value;
                }).width('100%')
                TextInput({ text: rule.action, placeholder: '动作 PROXY/DIRECT/REJECT' }).onChange((value: string) => {
                  if (ROUTE_RULE_ACTIONS.includes(value)) rule.action = value;
                }).width('100%')
              }.width('100%').padding(10).backgroundColor('#F6F7F9').borderRadius(8)
            }, (rule: RouteRule) => rule.id)
            Text('规则集 (.srs)').fontSize(16).fontWeight(FontWeight.Bold).width('100%')
            ForEach(this.route.ruleSets, (item: RuleSetMetadata) => {
              Row() {
                Text(`${item.tag} · ${item.path}`).fontSize(12).layoutWeight(1).maxLines(1)
                Text(item.updatedAt > 0 ? new Date(item.updatedAt).toLocaleDateString() : '未更新')
                  .fontSize(11).fontColor('#777777')
              }.width('100%')
            }, (item: RuleSetMetadata) => item.tag)
            Text(`GeoSite: ${this.route.geo.geositePath.length > 0 ? this.route.geo.geositePath : '未配置'}\nGeoIP: ${this.route.geo.geoipPath.length > 0 ? this.route.geo.geoipPath : '未配置'}`)
              .fontSize(12).fontColor('#777777').width('100%')
            Text('规则集与 Geo 元数据由存储层维护；无效规则在生成配置时单项跳过。')
              .fontSize(12).fontColor('#777777').width('100%')
          }.width('100%').padding({ left: 16, right: 16, bottom: 28 })
        }.layoutWeight(1)
      }
    }.width('100%').height('100%')
  }
}
