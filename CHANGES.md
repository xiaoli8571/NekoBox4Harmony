# Phase A-D Implementation Status

## Scope and constraints

Implementation was limited to `entry/src/main/ets/`, `entry/src/main/resources/`, and this root `CHANGES.md`. No build, package, signing, version, permission, module declaration, frozen core, CGo, binary, generated-output, or Git write operation was performed.

## Phase A

### A1 Grouped node management: Completed

- Added `ProfileGroup` and group/sort metadata to profiles.
- Added compatible persistence for groups and legacy profiles.
- Added grouped display and node movement/group management flows on the home page.

Files:
- `entry/src/main/ets/model/Profile.ets`
- `entry/src/main/ets/model/Store.ets`
- `entry/src/main/ets/pages/Index.ets`

### A2 Live ProfileEdit validation: Completed

- Added reusable validation for server, port range, UUID, protocol credentials, REALITY public key/short ID, and optional JSON.
- Invalid profiles are blocked from saving and validation feedback is shown while editing.

Files:
- `entry/src/main/ets/pages/ProfileEdit.ets`

### A3 Appearance settings: Completed with API limitation

- Added persisted system/light/dark preference, haptic-feedback preference, and liquid-glass preference.
- Added settings controls for these options.
- Current SDK/project APIs do not provide a safe, already-declared path to force every page and process to change color mode immediately. Some pages may require re-entry to refresh, and liquid-glass/haptic preferences are retained for compatible UI interactions rather than relying on protected APIs or permissions.

Files:
- `entry/src/main/ets/model/Profile.ets`
- `entry/src/main/ets/model/Store.ets`
- `entry/src/main/ets/pages/SettingsPage.ets`

## Phase B

### B1 Latency testing and per-app selection: Completed with API limitation

- Existing latency tester is integrated with the home node list and supports batch testing/status display.
- Per-app include/exclude/off modes are persisted and passed to the VPN configuration through the existing trusted/blocked application APIs.
- Installed-application enumeration is not implemented because the current project does not expose a suitable permission-free bundle-query API. The selector therefore accepts application bundle names manually.

Files:
- `entry/src/main/ets/model/Profile.ets`
- `entry/src/main/ets/pages/Index.ets`
- `entry/src/main/ets/pages/SettingsPage.ets`
- Existing integration verified in `entry/src/main/ets/utils/LatencyTester.ets`
- Existing VPN integration verified in `entry/src/main/ets/vpnext/VpnExtAbility.ets`

### B2 Custom routing and ConfigBuilder integration: Completed

- Custom domain, IP/CIDR, GeoIP, and GeoSite rules are persisted and editable through the existing route-rules page.
- Enabled rules are converted to sing-box route rules and inserted with stable priority after DNS/private safety rules and before legacy direct lists/final routing.
- VPN startup loads the persisted rules and supplies them to the existing ConfigBuilder API.

Files:
- `entry/src/main/ets/model/RouteRule.ets`
- Existing UI verified in `entry/src/main/ets/pages/RouteRulesPage.ets`
- Existing builder integration verified in `entry/src/main/ets/core/ConfigBuilder.ets`
- Existing startup integration verified in `entry/src/main/ets/vpnext/VpnExtAbility.ets`

## Phase C

### C1 Subscription scheduling and metadata: Completed with API limitation

- Added per-subscription update interval, next-update time, last-attempt time, and last-error metadata with legacy-data defaults.
- Existing traffic quota and expiry metadata remain preserved and displayed.
- Due subscriptions are checked when the application starts or returns to its active flow.
- Exact background scheduling is not available without adding protected configuration, permissions, or a background task declaration, so updates are not guaranteed while the application is terminated.

Files:
- `entry/src/main/ets/core/Subscriptions.ets`
- `entry/src/main/ets/pages/Index.ets`
- Existing subscription UI verified in `entry/src/main/ets/pages/SettingsPage.ets`
- Existing detail UI verified in `entry/src/main/ets/pages/SubDetailPage.ets`

### C2 Share-link import and backup/restore: Completed with API limitation

- Clipboard import uses the existing pasteboard helper.
- Six required protocols are supported by the existing parser: `ss://`, `vmess://`, `vless://`, `trojan://`, `hysteria2://`, and `tuic://`.
- Import flow handles parsed profiles and duplicate/error feedback through the current home-page workflow.
- Backup schema was advanced to version 3 and now includes settings, profiles, groups, subscriptions, and custom routing rules while accepting older backups with missing optional fields.
- Clipboard backup/restore UI is available. File-picker backup/restore was not added because no suitable existing file-selection API is present and adding new declarations or permissions was prohibited.

Files:
- `entry/src/main/ets/core/Backup.ets`
- `entry/src/main/ets/pages/Index.ets`
- `entry/src/main/ets/pages/SettingsPage.ets`
- Existing parser verified in `entry/src/main/ets/utils/LinkParser.ets`
- Existing clipboard helper verified in `entry/src/main/ets/utils/ClipboardHelper.ets`

## Phase D

### D1 Localization and dark-mode polish: Partially completed

- New appearance controls and backup descriptions were added and affected pages continue to use existing theme resources where already available.
- Full extraction of all legacy hard-coded strings and a complete English resource set was not safely completed in this pass. Several existing pages still contain Chinese literals and fixed colors. This remains a localization and dark-mode consistency risk.

Files:
- `entry/src/main/ets/pages/SettingsPage.ets`
- Existing resources reviewed in `entry/src/main/resources/base/element/color.json`
- Existing resources reviewed in `entry/src/main/resources/base/element/string.json`

### D2 Notification enhancement and desktop card: API-limited

- Existing ongoing VPN notification already displays connected state and the current node name.
- A reliable live-latency value is UI-process state and is not currently shared with the VPN extension process, so latency was not added to the notification without changing cross-process interfaces.
- A notification VPN toggle was not added because no safe existing action-agent/want-agent flow was available in the current project APIs without broadening system integration.
- Desktop service card was skipped because it requires module/form declarations in protected configuration such as `module.json5` and additional resources.

Existing notification files reviewed:
- `entry/src/main/ets/entryability/EntryAbility.ets`
- `entry/src/main/ets/vpnext/VpnExtAbility.ets`

## Exact modified file list

- `entry/src/main/ets/core/Backup.ets`
- `entry/src/main/ets/core/Subscriptions.ets`
- `entry/src/main/ets/model/Profile.ets`
- `entry/src/main/ets/model/RouteRule.ets`
- `entry/src/main/ets/model/Store.ets`
- `entry/src/main/ets/pages/Index.ets`
- `entry/src/main/ets/pages/ProfileEdit.ets`
- `entry/src/main/ets/pages/SettingsPage.ets`
- `CHANGES.md`

## Static verification

- `git diff --check` completed without whitespace errors before final documentation.
- Read-only `git status --short`, `git diff --name-only`, source searches, and API consistency inspection were used.
- No build, package, Hvigor, HAP, kernel, or signing command was run.
- No commit, checkout, reset, add, stash, merge, rebase, or push operation was run.

## Pre-existing repository state and risks

- `core/sing-box-1.13.12` was already reported modified at inspection time and was not touched by this implementation.
- Pre-existing untracked `.zcode/`, crash dumps, and `nul` were not modified.
- Build/type verification remains outstanding because the request explicitly prohibited building.
- Full localization, immediate global theme application, installed-app enumeration, exact terminated-state subscription scheduling, file-picker backup/restore, live notification latency/toggle actions, and the desktop card remain limited by current APIs or protected configuration constraints.

## 2026-09-03 F2 通知栏增强：已完成，待构建机编译与真机验证

- 新增 UI 进程到 VPN 扩展进程的测速 CommonEvent，仅在当前运行节点测速完成后发送节点名称与延迟。
- VPN 常驻通知现在显示“当前节点 · 延迟”，尚未测速或测速失败时显示 `--`。
- 常驻通知新增“断开”按钮，通过 WantAgent 拉起 EntryAbility 并携带 `action=disconnect`。
- EntryAbility 在 `onCreate()` 与 `onNewWant()` 中处理通知动作，调用现有 `VpnService.disconnect()`，覆盖应用未运行及已运行场景。

改动文件：
- `entry/src/main/ets/core/VpnIpc.ets`
- `entry/src/main/ets/pages/Index.ets`
- `entry/src/main/ets/vpnext/VpnExtAbility.ets`
- `entry/src/main/ets/entryability/EntryAbility.ets`
- `DEVPLAN.md`
- `CHANGES.md`

静态检查与限制：
- `git diff --check` 已通过，无空白错误。
- 已核对测速事件发布、扩展进程订阅、通知按钮及 `onNewWant()` 处理链路。
- 按约束未执行构建、打包或任何 Git 写操作。
- Notification ActionButton、WantAgent 拉起行为及跨进程 CommonEvent 仍需构建机编译和真机验证。

## 2026-09-03 F3 订阅后台定时更新：已完成，待构建机编译与真机验证

- EntryAbility 在应用启动、回前台及退后台时检查已到期订阅，并通过重入保护避免并发重复更新。
- 检测到到期订阅后申请 `dataTransfer` 连续任务，依次执行订阅更新，并在最短必要时间内释放后台任务。
- 自动更新继续沿用现有连续失败计数机制：成功时清零，失败时递增，连续失败达到阈值后跳过自动更新。
- `module.json5` 仅新增 EntryAbility 的 `"backgroundModes": ["dataTransfer"]`；`ohos.permission.KEEP_BACKGROUND_RUNNING` 已存在于新基线，未重复修改。

改动文件：
- `entry/src/main/ets/entryability/EntryAbility.ets`
- `entry/src/main/module.json5`
- `DEVPLAN.md`
- `CHANGES.md`

静态检查与限制：
- `git diff --check` 已通过，无空白错误。
- 已核对只读 `git status` 和差异，未修改冻结内核、版本号、签名配置、构建输出或�其他受限文件。
- 按约束未执行构建、打包或任何 Git 写操作。
- `backgroundTaskManager.startBackgroundRunning()`、熄屏期间执行能力及系统连续任务限制仍需构建机编译和真机验证；若真机拒绝连续任务，再按计划降级为 transientTask。

## 2026-09-03 F4 per-app 应用列表：已完成，待构建机编译与真机验证

- 设置页新增已安装应用读取入口，支持按应用名称或包名搜索，并通过复选框选择分应用代理名单。
- 勾选结果写回现有 `perAppList` 字段，兼容原有 include/exclude 模式，并在变更后静默保存。
- 应用枚举失败、权限被拒绝或返回空列表时显示明确提示，同时完整保留下方手动包名输入框作为降级路径。
- `module.json5` 仅按 F4 许可新增 `ohos.permission.GET_BUNDLE_INFO` 权限声明。

改动文件：
- `entry/src/main/ets/pages/SettingsPage.ets`
- `entry/src/main/module.json5`
- `DEVPLAN.md`
- `CHANGES.md`

静态检查与限制：
- `git diff --check` 已通过，无空白错误。
- 已核对应用枚举、搜索、勾选、持久化和手动输入降级链路。
- 按约束未执行构建、打包或任何 Git 写操作。
- `bundleManager.getAllBundleInfo()` 的编译兼容性、权限授权及真机应用列表可见范围仍需构建机和真机验证；若系统拒绝枚举，手动输入功能仍可正常使用。

> 构建机注(2026-09-03,F4 轮):本机 SDK(API 24)的 `@ohos.bundle.bundleManager` 无 `getAllBundleInfo`,枚举改用旧模块 `@ohos.bundle` 的 `getAllBundleInfo(bundle.BundleFlag.GET_BUNDLE_DEFAULT)`(since 7 / deprecated since 9,仅弃用警告,编译通过);`BundleInfo.appInfo.label` 字段名两代一致,label 为空时已有回退包名,真机需核对应用名显示效果。

## 2026-09-03 F5 备份文件化：已完成，待构建机编译与真机验证

- 设置页新增 DocumentViewPicker 文件导出与导入入口，继续使用现有 schema v3 备份内容。
- 导出时生成带时间戳的 `.json` 文件名，并将备份 JSON 写入用户选择的位置。
- 导入时仅选择 `.json` 文件，读取完整内容后调用现有恢复流程，并刷新设置与订阅状态。
- 保留原有剪贴板备份和恢复入口作为快捷方式。
- 文件读取增加空文件、读取不完整和超过 20 MiB 的检查；Backup 导入增加无效 JSON 的明确错误提示，未来 schema 版本仍沿用现有不兼容提示。

改动文件：
- `entry/src/main/ets/core/Backup.ets`
- `entry/src/main/ets/pages/SettingsPage.ets`
- `DEVPLAN.md`
- `CHANGES.md`

静态检查与限制：
- `git diff --check` 已通过，无空白错误。
- 已核对 DocumentViewPicker 导出、文件写入、文件选择、完整读取、schema v3 恢复和剪贴板降级链路。
- 按约束未执行构建、打包或任何 Git 写操作。
- DocumentViewPicker 的文件 URI 读写、取消选择行为及恢复后的实际数据完整性仍需构建机编译和真机验证。

## 2026-09-03 F6 中英多语言收尾:已完成,待真机验证

- Codex(服务器工作区):建立 base/en_US 双份 string.json,Index/ProfileEdit/SubDetailPage/RouteRulesPage 四页文案资源化,SettingsPage 大部分文案资源化。
- 构建机补完:SettingsPage 剩余 35 处(出站模式说明、Geo 状态、订阅流量/到期、DNS/IPv6/主题、per-app 提示、剪贴板备份/恢复、不安全 TLS、重连提示)与 Backup.ets 4 处(无效 JSON/格式错误/版本不支持/恢复摘要)全部资源化。
- 修复全仓 43 处 `${$r('app.string.x')}` 模板串插值(运行时会渲染为 [object Object]):整句迁移为占位符句式(%1$s/%1$d),validationError/latencyText/groupName/sourceHost/importBackup 返回类型改 ResourceStr;新增 backupErrorText 将 Backup 机器错误键(backup_invalid_json 等)映射为资源文案;appListError 状态改 ResourceStr。
- 改动文件:pages/Index.ets、pages/ProfileEdit.ets、pages/SettingsPage.ets、pages/SubDetailPage.ets、core/Backup.ets、resources/base/element/string.json、resources/en_US/element/string.json、DEVPLAN.md、CHANGES.md、AppScope/app.json5(versionCode 1001716)、core/VpnService.ets、vpnext/VpnExtAbility.ets
- 已知限制/例外:LogStore.addLog 调试日志行与代码注释保留中文(非用户可见 UI,与既有惯例一致);运行时系统错误(网络/文件系统)原文经占位符句式包装透传;纯 ASCII 动态串(如 `URL Test: 123ms`)保留。
- 状态链路资源化(构建机):vpnStatus 状态由 VpnService(6 处)与 VpnExtAbility 扩展进程(5 处)以硬编码中文写入 AppStorage,
  首页状态卡无法跟随语言 —— 改为机器状态键(connecting/disconnected/switching/awaiting_auth/start_timeout/connected:<节点>/start_failed:<详情>/connect_failed:<详情>),
  Index 新增 statusDisplay() 映射为资源文案,VpnService 看门狗比较同步改为机器键;通知栏文案在 :vpn 扩展进程内,不在 F6 声明范围,保留中文待后续处理。
- 审计:五页面 + Backup 用户可见中文残留 0;`${$r(` 模板混用残留 0;base/en_US 各 264 键、键集合一致、无重复、引用无缺失(编译器逐键校验通过)。

## 2026-09-03 F7 UI 适配鸿蒙:已完成,待真机验证(构建机直接实现)

- 新增 `ets/common/UiSpec.ets`:PAGE_PADDING=16、CARD_RADIUS=16、间距档 8/12/16、BTN_HEIGHT=40、CONTENT_MAX_WIDTH=600。
- F7c 颜色收敛:六页面十六进制色值全部清零(审计 0 残留),新增 `text_disabled`/`control_disabled`/`shadow_color` 令牌(base+dark,共 21 令牌);latencyColor 改 success/warning;状态卡/Geo/订阅流量/禁用按钮/影子等全部语义令牌化。
- F7a/F7b:首页边距与卡片圆角统一 16、节点行 hoverEffect(HoverEffect.Scale);SettingsPage 备份按钮、SubDetailPage 更新/删除主按钮高度 40;SettingsPage 滚动区/各列表页边距统一 PAGE_PADDING。
- F7d:六个页面 build 根部包一层内容 Column,constraintSize maxWidth 600vp,外层 alignItems 居中(平板/横屏不拉伸破版)。
- F7c 状态栏:EntryAbility.applyStatusBarStyle() 在 loadContent 后设置 setWindowSystemBarProperties;外观偏好=跟随系统时,用 resourceManager.getColorSync(text_primary) 亮度判定当前生效深浅色(随系统/应用 colorMode 自动正确)。
- 改动文件:ets/common/UiSpec.ets(新)、pages/Index.ets、pages/ProfileEdit.ets、pages/SettingsPage.ets、pages/ConnectionsPage.ets、pages/RouteRulesPage.ets、pages/SubDetailPage.ets、entryability/EntryAbility.ets、resources/base+dark/element/color.json、AppScope/app.json5(1001717)、DEVPLAN.md、CHANGES.md
- 已知限制:状态栏样式在启动/回前台时设置,运行中切换系统深浅色需回前台刷新;日志页终端配色刻意保留。
