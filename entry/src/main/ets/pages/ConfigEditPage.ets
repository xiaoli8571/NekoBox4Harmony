import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import pasteboard from '@ohos.pasteboard';
import promptAction from '@ohos.promptAction';
import { statusBarTopVp } from '../common/PageTopInset';
import { UiSpec } from '../common/UiSpec';
import { pressLightEffect } from '../common/Effects';
import {
  initStore, loadSettings, loadProfiles, loadGroups, readRawConfigOverride,
  writeRawConfigOverride, clearRawConfigOverride, LogStore
} from '../model/Store';
import { AppSettings, Profile, ProfileGroup, profileDisplayName } from '../model/Profile';
import { buildCoreConfig } from '../core/ConfigBuilder';
import { loadRouteRules } from '../model/RouteRule';
import { RouteRule } from '../model/RouteRule';

/**
 * 原始配置编辑(对齐 OwnBox ConfigEditActivity)。
 *
 * 语义:
 *  - 页面展示**当前节点生成出来的 sing-box 配置原文**,可直接改;
 *  - 「保存覆盖」把改动按节点 id 存下来,连接时优先用它(扩展侧只做 JSON 合法 +
 *    含 outbounds 的最低校验,不合法就回退生成配置并写日志 —— 不让你一键连不上);
 *  - 「清除覆盖」回到生成配置。
 *
 * 与 OwnBox 的差异:OwnBox 是编辑后直接文件落盘再让内核读;我们因为内核在 :vpn 进程
 * 且配置由 ConfigBuilder 生成,改成「按节点的覆盖存储 + 扩展侧优先消费」,功能等价、
 * 回退路径更安全。
 */
@Entry
@Component
struct ConfigEditPage {
  @State topPadVp: number = 44;
  @State loading: boolean = true;
  @State profiles: Array<Profile> = [];
  @State selectedIndex: number = 0;
  @State text: string = '';
  @State overrideOn: boolean = false;
  @State litKey: string = '';
  private groups: Array<ProfileGroup> = [];
  private settings: AppSettings = new AppSettings();
  private context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    void this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    this.topPadVp = await statusBarTopVp(this.context, 44);
    await initStore(this.context);
    try {
      this.settings = await loadSettings();
      this.profiles = await loadProfiles();
      this.groups = await loadGroups();
    } catch (e) {
      LogStore.addLog(`[cfg] 加载失败: ${e instanceof Error ? e.message : `${e}`}`);
    }
    this.loading = false;
    if (this.profiles.length > 0) {
      await this.selectProfile(0);
    }
  }

  private async selectProfile(index: number): Promise<void> {
    if (index < 0 || index >= this.profiles.length) {
      return;
    }
    this.selectedIndex = index;
    await this.generate();
  }

  private async generate(): Promise<void> {
    if (this.profiles.length === 0) {
      this.text = '';
      return;
    }
    const p = this.profiles[this.selectedIndex];
    try {
      const raw = await readRawConfigOverride(p.id);
      this.overrideOn = raw.trim().length > 0;
      if (this.overrideOn) {
        this.text = raw;
        return;
      }
      let rules: Array<RouteRule> = [];
      try {
        rules = await loadRouteRules();
      } catch (e) {
        rules = [];
      }
      this.text = prettyJson(buildCoreConfig(p, this.settings, '', '', '', '', rules, [], '',
        this.profiles, this.groups, ''));
    } catch (e) {
      this.text = `// 生成失败: ${e instanceof Error ? e.message : `${e}`}`;
    }
  }

  private saveOverride(): void {
    const p = this.profiles[this.selectedIndex];
    const trimmed = this.text.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: $r('app.string.cfg_edit_empty') });
      return;
    }
    try {
      const parsed = JSON.parse(trimmed) as Record<string, Object>;
      if (parsed === null || parsed === undefined || parsed['outbounds'] === undefined) {
        promptAction.showToast({ message: $r('app.string.cfg_edit_invalid') });
        return;
      }
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.cfg_edit_invalid') });
      return;
    }
    void (async (): Promise<void> => {
      await writeRawConfigOverride(p.id, trimmed);
      this.overrideOn = true;
      LogStore.addLog(`[cfg] 已保存原始配置覆盖: ${profileDisplayName(p)}`);
      promptAction.showToast({ message: $r('app.string.cfg_edit_saved') });
    })();
  }

  private clearOverride(): void {
    const p = this.profiles[this.selectedIndex];
    void (async (): Promise<void> => {
      await clearRawConfigOverride(p.id);
      this.overrideOn = false;
      LogStore.addLog(`[cfg] 已清除原始配置覆盖: ${profileDisplayName(p)}`);
      await this.generate();
      promptAction.showToast({ message: $r('app.string.cfg_edit_cleared') });
    })();
  }

  private copyConfig(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: $r('app.string.cfg_edit_copied') });
      });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.lan_copy_failed') });
    }
  }

  build() {
    Column() {
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(22).fontColor([$r('app.color.text_1')])
        }
        .width(44).height(44).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
        .visualEffect(pressLightEffect(this.litKey === 'back', false))
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.litKey = 'back';
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.litKey = '';
          }
        })
        .onClick(() => { void router.back(); })

        Text($r('app.string.cfg_edit_title'))
          .fontSize(17).fontWeight(700).fontColor($r('app.color.text_1')).layoutWeight(1)

        Text($r('app.string.cfg_edit_copy'))
          .fontSize(12).fontColor($r('app.color.primary'))
          .padding({ right: 4 })
          .onClick(() => { this.copyConfig(); })
      }
      .width('100%')
      .height(52)
      .padding({ left: 4, right: UiSpec.PAGE_PADDING })

      if (this.loading) {
        Column() {
          LoadingProgress().width(28).height(28).color($r('app.color.primary'))
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.profiles.length === 0) {
        Column() {
          Text($r('app.string.cfg_edit_no_profile'))
            .fontSize(13).fontColor($r('app.color.text_2'))
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 8 }) {
          Select(this.profiles.map((p: Profile) => {
            const option: SelectOption = { value: profileDisplayName(p) };
            return option;
          }))
            .selected(this.selectedIndex)
            .value(profileDisplayName(this.profiles[this.selectedIndex]))
            .width('100%')
            .onSelect((index: number) => { void this.selectProfile(index); })

          Row({ space: 10 }) {
            if (this.overrideOn) {
              Text($r('app.string.cfg_edit_override_on'))
                .fontSize(11.5).fontColor($r('app.color.warning')).layoutWeight(1)
            } else {
              Text($r('app.string.cfg_edit_generated'))
                .fontSize(11.5).fontColor($r('app.color.text_3')).layoutWeight(1)
            }
            Text($r('app.string.cfg_edit_clear'))
              .fontSize(12).fontColor($r('app.color.error'))
              .onClick(() => { this.clearOverride(); })
            Text($r('app.string.cfg_edit_save'))
              .fontSize(12).fontColor($r('app.color.primary'))
              .onClick(() => { this.saveOverride(); })
          }.width('100%')

          Text($r('app.string.cfg_edit_warning'))
            .fontSize(11).fontColor($r('app.color.text_3')).width('100%')

          TextArea({ text: this.text })
            .fontSize(11)
            .fontFamily('monospace')
            .width('100%')
            .layoutWeight(1)
            .onChange((v: string) => { this.text = v; })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: UiSpec.PAGE_PADDING, right: UiSpec.PAGE_PADDING, bottom: 12 })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.topPadVp })
    .backgroundColor($r('app.color.app_background'))
  }
}

/** 2 空格缩进重排(便于人读;失败原样返回) */
function prettyJson(text: string): string {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch (e) {
    return text;
  }
}
