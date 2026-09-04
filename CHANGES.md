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

## 2026-09-03 release 1.5.8(F 阶段收官)

- versionName 1.5.8 / versionCode 1001800;F1~F7 全部交付:深色主题、通知栏延迟+断开按钮、订阅后台更新、per-app 图形选择器、备份文件化、中英双语(264 键)、HarmonyOS 原生观感适配(UiSpec 令牌/色值清零/600vp 限宽/状态栏跟随主题)。
- 产物 dist/NekoBox4Harmony-1.5.8-unsigned.hap(24,913,367 字节,sha256 4655bb8f4974678ab8276f8e8149b0f48007f67f3f84972dc67e182fd61a13c7),签名由用户在 DevEco 完成。
- 待真机验证清单:F2 通知延迟/断开按钮、F3 熄屏订阅更新、F4 应用列表枚举、F5 文件备份导出导入、F6 系统切英文、F7 观感与状态栏。

## 2026-09-03 F7 真机验收修复轮(versionCode 1001718/1001719,已真机验证通过)

- 修复 F7 限宽包装缺陷:内层包装 Column 缺少 width/height('100%')导致内容列测量超宽、右侧元素被推出屏幕(真机截图确认);六页面统一补齐。
- 设置页出站模式/外观/分应用三组并排按钮改 layoutWeight(1) 等分铺满,剪贴板备份两按钮等分并统一 40vp 高,机制上杜绝按钮行溢出。
- 按真机用户反馈移除 600vp 内容限宽(F7d 调整为全宽 + 16vp 页边距)。
- 改动文件:六个 pages、ets/common/UiSpec.ets、AppScope/app.json5


## 2026-09-03 release 1.5.8(F 阶段收官)

- versionName 1.5.8 / versionCode 1001800(基于 1001719 真机验收通过版本,仅版本号差异)。
- F1~F7 全部交付:深色主题、通知栏延迟+断开按钮、订阅后台更新、per-app 图形选择器、备份文件化、中英双语(264 键)、HarmonyOS 原生观感(全宽 + 16vp 页边距、色值令牌清零、深浅色自适应状态栏)。
- 产物 dist/NekoBox4Harmony-1.5.8-unsigned.hap,签名由用户在 DevEco 完成。
- F2~F6 功能项仍建议按 CHANGES.md 清单在真机逐项复核。

## 2026-09-03 G6 通知栏文案资源化（已完成，待构建验证）

- 将 `VpnExtAbility.ets` 常驻 VPN 通知的标题、节点与延迟组合文本、应用名及“断开”操作按钮改为字符串资源引用，通知布局和按钮行为保持不变。
- 在 base 与 en_US 资源中同步新增通知文案；英文系统下显示 “VPN connected” 和 “Disconnect”。
- CommonEvent 与 `vpnStatus` 状态协议未改动，继续使用机器键。
- 改动文件：`entry/src/main/ets/vpnext/VpnExtAbility.ets`、`entry/src/main/resources/base/element/string.json`、`entry/src/main/resources/en_US/element/string.json`、`DEVPLAN.md`、`CHANGES.md`。
- 未构建、未打包、未执行 Git 写操作；等待构建机验证。

> 构建机注(2026-09-03,G6 轮):本机 SDK(API 24)的 notificationManager 通知字段(title/text/additionalText/actionButtons[].title)为 string 类型,不接受 Resource(编译报 Type 'Resource' is not assignable to type 'string' ×4);构建机改为 this.context.resourceManager.getStringSync($r(...), args) 构建时现取本地化字符串(resourceManager 跟随系统语言,en_US 下自动生效)。后续涉及系统 API 文案时优先确认 d.ts 字段类型。

## 2026-09-03 G1 节点手动排序（已完成，待统一构建验证）

- 在 `AppSettings` 新增持久化排序偏好 `profileSortMode`，支持 `manual`、`latency`、`name` 三种模式；旧设置或非法值兼容回退为手动排序，备份中的设置对象自动包含该字段。
- 首页节点排序继续保持置顶优先；手动模式按同一分组内的 `Profile.sortOrder` 排序，并以现有延迟顺序兜底；延迟和名称模式分别按测速结果与节点名称�排序。
- 节点长按菜单在手动模式下新增“上移/下移”，仅在同一分组、相同置顶层级内交换顺序并立即写回持久化数据，不影响其他分组。
- 设置页“外观与交互”新增三等分排序模式按钮，切换后立即保存；base 与 en_US 字符串资源已同步补齐。
- 改动文件：`entry/src/main/ets/model/Profile.ets`、`entry/src/main/ets/model/Store.ets`、`entry/src/main/ets/pages/Index.ets`、`entry/src/main/ets/pages/SettingsPage.ets`、`entry/src/main/resources/base/element/string.json`、`entry/src/main/resources/en_US/element/string.json`、`DEVPLAN.md`、`CHANGES.md`。
- `Backup.ets` 无需修改：其备份载荷已直接序列化完整 `AppSettings` 与 `Profile` 数组，新字段会自动导出与恢复。
- 已执行只读 `git diff --check` 与改动范围检查；未构建、未打包、未执行 Git 写操作，等待 G1 至 G5 统一构建验证。

## 2026-09-03 G2 分组测速汇总（已完成，待统一构建验证）

- 首页节点列表按现有分组元数据展示分组头；分组折叠后仍保留名称、延迟汇总徽标和“测速本组”操作。
- 分组延迟徽标随测速回调实时刷新：存在未测节点时显示未测数量，全部完成且有成功结果时显示最低延迟，全部失败时显示超时。
- 新增分组测速入口并复用 `testProfiles`；只传入当前分组节点，与全局测速�共用 `testing` 互斥状态，避免并发测速。
- 分组测速只更新本组节点的延迟结果，保留其他分组已测数据；测速结束后统一持久化节点延迟元数据。
- base 与 en_US 字符串资源已同步新增分组测速及汇总文案。
- 改动文件：`entry/src/main/ets/pages/Index.ets`、`entry/src/main/resources/base/element/string.json`、`entry/src/main/resources/en_US/element/string.json`、`DEVPLAN.md`、`CHANGES.md`。`LatencyTester.ets` 的现有列表参数�已支持按组过滤，因此无需修改。
- 已执行只读 `git diff --check` 与改动范围检查；未构建、未打包、未执行 Git 写操作，等待 G1 至 G5 统一构建验证。

## 2026-09-03 G3 节点分享二维码（已完成，采用纯文本 URI + 复制降级，待统一构建验证）

- 预检当前项目与可见 SDK 声明后未发现 `@kit.ScanKit` 的 `generateBarcode` 能力，因此按计划启用安全降级路径，不引入未经确认的新 API。
- 节点长按菜单新增“分享节点”入口，使用现有 `exportProfileLink` 生成分享 URI，并通过 `CustomDialog` 展示完整文本及复制按钮；不写入磁盘，关闭弹窗即释放��界面状态。
- 订阅详情页新增“分享订阅链接”入口，同样通过 `CustomDialog` 展示订阅 URL 并支持复制。
- 节点协议不支持导出时沿用现有提示；复制成功后显示本地化提示。
- base 与 en_US 字符串资源已同步新增节点分享、订阅分享、弹窗标题及复制成功文案。
- 降级说明：当前实现不生成二维码，原因是本机可见 SDK d.ts 中未发现 `ScanKit.generateBarcode`；纯文本 URI 可直接选择或复制，完整保留分享功能。
- 改动文件：`entry/src/main/ets/pages/Index.ets`、`entry/src/main/ets/pages/SubDetailPage.ets`、`entry/src/main/resources/base/element/string.json`、`entry/src/main/resources/en_US/element/string.json`、`DEVPLAN.md`、`CHANGES.md`。
- 已执行只读 `git diff --check` 与改动范围检查；未构建、未打包、未执行 Git 写操作，等待 G1 至 G5 统一构建验证。

## 2026-09-03 G4 远程规则集订阅（已完成，待统一构建验证）

- 新增 `RemoteRuleSet` 数据模型与独立持久化，支持名称、SRS URL、域名/IP 类型、直连/代理出站、启用状态、更新时间和最近错误字段。
- 路由规则页新增远程规则集管理区块，支持添加、编辑、启停、类型和出站切换及删除；开关和字段更改即时保存，重连后生效。
- `ConfigBuilder.ets` 为启用且 URL 有效的项目生成 sing-box 1.11 `route.rule_set` 远程二进制定义及对应 `route.rules[].rule_set` 引用，使用 `direct` 下载分流和 24 小时更新间隔。
- 启用 `experimental.cache_file`，使成功下载的远程规则集可由内核缓存并在后续连接中复用；内核日志会记录后台更新错误。
- `VpnExtAbility.ets` 在连接时加载并注入远程规则集，读取持久化配置失败时记录日志并忽略本次注入。
- 备份 schema 从 v3 升至 v4，新增 `remoteRuleSets` 字段；恢复逻辑继续兼容 v3，缺少该字段时按空列表处理。
- base 与 en_US 字符串资源已同步新增远程规则集管理文案。
- 改动文件：`entry/src/main/ets/model/RouteRule.ets`、`entry/src/main/ets/core/ConfigBuilder.ets`、`entry/src/main/ets/vpnext/VpnExtAbility.ets`、`entry/src/main/ets/pages/RouteRulesPage.ets`、`entry/src/main/ets/core/Backup.ets`、`entry/src/main/resources/base/element/string.json`、`entry/src/main/resources/en_US/element/string.json`、`DEVPLAN.md`、`CHANGES.md`。
- 已执行只读 `git diff --check`、两份字符串 JSON 解析和集成引用检查；未构建、未打包、未执行 Git 写操作，等待 G1 至 G5 统一构建验证。

## 2026-09-03 G5 连接统计（已完成，待统一构建验证）

- 在 `AppSettings` 新增 `clashApiEnabled`、`clashApiPort` 和 `clashApiSecret`，默认启用、端口 9090；旧设置首次加载时自动生成并持久化随机访问密钥，端口限制在 1024 至 65535。
- `ConfigBuilder.ets` 按开关生成 `experimental.clash_api`，仅监听 `127.0.0.1`，配置自定义端口与 secret；同时保留 G4 所需的 `experimental.cache_file`。
- 设置页新增连接统计 API 开关、监听端口和访问密钥编辑项，修改后提示重新连接 VPN 生效；base 与 en_US 文案已同步。
- `ConnectionsPage.ets` 在 VPN 运行且 API 开启时每秒轮询 `/connections`，请求携带 `Authorization: Bearer <secret>`，展示实时上下行速率、累计流量及活动连接的目标、网络、规则链和上下行字节数。
- 支持通过 `DELETE /connections/:id` 关闭单条连接，并检查 HTTP 状态码；连接 ID 在请求路径中进行 URL 编码。
- 轮询在页面消失、VPN 断开或 API 关闭时停止，VPN 运行状态变化时自动重建或停止计时器，避免后台泄漏。
- 降级路径：clash API 请求失败时继续显示首页通过现有 TUN 统计链路写入 AppStorage 的总速率与累计流量，不因 API 不可用而丢失基础统计；连接列表显示本地化不可用提示。真机需结合 sing-box 日志复核 c-shared 模式下控制器监听、鉴权和连接关闭行为。
- 改动文件：`entry/src/main/ets/model/Profile.ets`、`entry/src/main/ets/model/Store.ets`、`entry/src/main/ets/core/ConfigBuilder.ets`、`entry/src/main/ets/pages/SettingsPage.ets`、`entry/src/main/ets/pages/ConnectionsPage.ets`、`entry/src/main/resources/base/element/string.json`、`entry/src/main/resources/en_US/element/string.json`、`DEVPLAN.md`、`CHANGES.md`。
- 已执行只读 `git diff --check`、两份字符串 JSON 解析及配置、鉴权、生命周期和降级引用检查；未构建、未打包、未执行 Git 写操作，等待 G1 至 G5 统一构建验证。


> 构建机注(2026-09-03,G1~G5 统一轮):首次编译仅 1 处错误 —— ConnectionsPage.ets:147 向 string 状态塞 Resource(G6 同款)。构建机修复:80 行改声明为 ResourceStr(空串默认值),198 行判空改不等比较,147 行保持资源赋值;重编译通过(versionCode 1001802)。G4 的 download_detour=direct 与 G5 的 clash_api 运行时行为仍为真机风险点。


> 构建机修复(2026-09-03,真机日志:内核启动失败 initialize cache-file: open cache.db: permission denied):G5 开启的 experimental.cache_file 未设路径,内核回退相对路径且 CWD 不可写导致启动必败。修复:cache_file.path 指向应用沙箱 files/core/cache.db(与 singbox.log/config.json 同目录,已验证可写),路径缺失时禁用 cache_file 而非阻塞启动。versionCode 1001803。


## G7 VPN 重连稳定性与模式即时生效（2026-09-03）

- 真机日志确认：出现“正在建立 VPN”超过 60 秒时，TUN、DNS 与代理数据面可能已经正常工作。原看门狗会因 CommonEvent 状态未同步而误断连接，现改为仅记录控制面超时并保留 VPN。
- 节点切换取消“停止扩展 + 固定等待 1.5 秒 + 重新启动”的竞态路径，改为通过 Want 携带目标节点，由现有 VPN 扩展实例串行重启。
- VPN 扩展启动期间收到的新请求不再丢弃，改为记录最新节点与强制重启标记，并在当前操作结束后继续处理。
- 设置页的规则、全局、直连模式点击后立即保存；VPN 运行中时自动使用当前节点强制串行重启，使新模式立即生效。
- 修正全局模式：仅保留 DNS 劫持规则，不加载私网直连、自定义规则、Geo 分流或远程规则集，普通流量统一由 `final: proxy` 处理。
- 改动文件：`entry/src/main/ets/core/VpnService.ets`、`entry/src/main/ets/vpnext/VpnExtAbility.ets`、`entry/src/main/ets/pages/SettingsPage.ets`、`entry/src/main/ets/core/ConfigBuilder.ets`、`DEVPLAN.md`、`CHANGES.md`。
- 本轮不构建、不打包、不执行 Git 写操作；待构建机编译及真机验证。


> 构建机注(2026-09-03,G7 轮):一次编译通过(versionCode 1001804)。铁律核查:module.json5/内核/AppScope 零改动,${$r( 模板混用 0;restartReason 仅入 LogStore,机器键协议未破坏。真机验证点以 Codex 建议为准:连续切换节点、断开换节点启动、运行中切换模式、全局模式国内地址走 proxy。

> 通知栏修复（2026-09-03）：真机通知副标题原样显示 `%1$s.%2$s`，确认当前 SDK 的 `getStringSync` 调用未展开参数化字符串。`VpnExtAbility.ets` 已改为直接拼接节点名与延迟：`${nodeName} · ${latencyText}`。未构建、未提交或推送，待构建机验证。


> 构建机注(2026-09-03,通知显示修复轮):真机实证本机 SDK 的 resourceManager.getStringSync(resource, args) 不展开 %1$s 占位符(原样输出);通知副标题改为纯字符串模板拼接(`${nodeName} · ${latencyText}`,未测速为 `节点名 · --`)。规则更新:系统 API 动态文案 = getStringSync 取静态资源 + 代码拼接动态值;占位符资源仅在 ArkUI 组件 $r() 内使用。versionCode 1001805。


## 2026-09-03 release 1.6.0(G 阶段收官)

- versionName 1.6.0 / versionCode 1001900(与 1001805 真机验证版内容一致,仅版本号差异)。
- G1~G7 全部交付:G1 节点手动排序+排序模式、G2 分组测速汇总徽标、G3 分享二维码(降级纯文本)、G4 远程规则集订阅(route.rule_set)、G5 连接统计(clash_api)、G6 通知文案资源化、G7 切换可靠性与模式语义(forceRestart 串行重启;global=全走代理)。
- 真机验证:通知两态显示、VPN 启动、cache_file 修复均已通过;G4(SRS 下载)与 G5(clash_api)运行时行为为已知风险点,详见 release notes。
- 产物 dist/NekoBox4Harmony-1.6.0-unsigned.hap,签名由用户在 DevEco 完成。

## 2026-09-04 U1 首页重构（方案 C 玻璃拟态霓虹）：已完成开发，待构建机验证

- 将既有 F1 深色皮肤替换为方案 C「玻璃拟态霓虹」，浅色主题继续保持 F1 外观；C 主题 token 并入既有 `UiSpec.ets` 和 base/dark 颜色资源，未建立平行 token 系统。
- 首页 Hero、连接能量球、统计卡和节点容器采用玻璃描边、霓虹强调及选中辉光；节点行使用实底玻璃降级，未逐行添加 blur，为 U3 的 `uiFxLevel` full/lite 切换保留统一接入路径。
- 连接状态继续只读 `AppStorage('vpnStatus')` 并通过 `Index.statusDisplay()` 显示，未改变机器键、Store、Profile 或 VPN 核心链路。
- 保留节点选择、VPN 启停、订阅导入、节点新增与编辑、测速、分组测速、分组折叠、手动排序、置顶、分享、per-app 设置入口，以及连接、日志和设置页面入口。
- 改动文件：`entry/src/main/ets/common/UiSpec.ets`、`entry/src/main/ets/common/components/BigPowerButton.ets`、`entry/src/main/ets/common/components/MiniStatCard.ets`、`entry/src/main/ets/pages/Index.ets`、`entry/src/main/resources/base/element/color.json`、`entry/src/main/resources/dark/element/color.json`、`DEVPLAN.md`、`CHANGES.md`。
- 静态检查：base/dark 颜色资源均为 48 键，集合一致且无重复；新增 ArkTS 无十六进制色值、无 `.stateEffect()`；`git diff --check` 通过。未新增文案，base/en_US 文案键数不受影响。
- 已知限制：构建状态为“待构建机验证”；连接中旋转 loading、状态点呼吸动效及完整 blur/full-lite 动态切换留待 U3/U4 按既定顺序实现和审计；未构建、未打包、未执行 Git 写操作。


> 构建机注(2026-09-03,UI 重构 + 订阅分组的):打包前检查确认无订阅分组功能,构建机已实现 —— SubInfo 新增 group 字段(Preferences JSON 与备份 schema 天然向后兼容,旧数据默认未分组);设置页订阅区按分组分节渲染(未分组在最前,组头显示数量),每条订阅新增"分组"操作(SubGroupDialog 弹窗改组);新增 4 组中英文案。另修复 Codex 重构组件在本机 SDK 的两个编译错误:MiniStatCard 移除 fontVariant(FontVariant 本机不存在)、ToggleRow 成员 enabled 为保留名改 controlEnabled。订阅分组实现:ets/core/Subscriptions.ets、ets/pages/SettingsPage.ets、resources 双份 string.json。versionCode 1001901。


## 2026-09-04 U2 节点列表（方案 C 玻璃拟态霓虹）：已完成开发，待构建机验证

- 节点列表沿用 U1 的单层玻璃容器，节点行使用实底玻璃降级，选中项以青色描边与辉光区分，未对列表逐行应用 blur。
- 新增 64vp 延迟能量条，按 `latency / 250` 限幅显示，并复用既有测速结果及成功、警告、错误颜色语义；未测或失败时不绘制有效长度。
- 保留 G1 手动排序及名称/延迟排序、置顶优先级、分组测速与折叠、二维码不可用时的纯文本分享降级、复制链接和订阅详情入口，未改变 `Profile`、`Store` 或排序持久化契约。
- U2 代码改动集中于 `entry/src/main/ets/pages/Index.ets`；同步更新 `DEVPLAN.md` 与 `CHANGES.md`。
- 静态检查已核对资源 JSON、功能引用、新增 ArkTS 十六进制色值、`.stateEffect()` 和 `git diff --check`；未构建、未打包、未执行 Git 写操作。构建状态：待构建机验证。

## 2026-09-04 U5 桌面服务卡片 2×2 / 2×4（条件任务）：方案已完成，待用户解除 module.json5 冻结

- 已按默认条件任务新增 `docs/U5-桌面服务卡片方案.md`，覆盖 2×2/2×4 视觉、`form_config.json` 草案、`VpnFormAbility`、快照契约、Preferences 冷启动兜底、10 秒节流发布及 `postCardAction` 回传链路。
- 方案规定两张卡片的 `defaultColor` 均为 `#0B0F1A`，卡片进程内不开 blur，不 import 主应用 Store、VPN Service 或 core 模块。
- 已定义 `toggle`、`select`、`open` 从卡片到 `EntryAbility` 并复用既有业务方法的完整设计，包含输入校验、一次性动作消费和错误降级。
- 严格保持 `entry/src/main/module.json5` 冻结，未新增 FormExtensionAbility、FormWidget 或运行时代码。只有用户明确解除冻结后才进入实现。
- 未构建、未打包、未执行 Git 写操作。U5 按交接要求完成方案阶段，运行时实现及真机验收待授权。

## 2026-09-04 U4 token 审计、性能护栏与动效收口（方案 C）：已完成开发，待构建机验证

- 完成 `entry/src/main/ets` 全目录色值审计：存量十六进制色值仅位于 `UiSpec.ets` 状态栏黑白常量和 `LogPage.ets` 既有固定色，本轮新增代码 0 命中，未改动存量项。
- base/dark 颜色资源均为 48 个唯一键且集合一致；base/en_US 文案资源均为 315 个唯一键且集合一致，U4 未新增文案键。
- 当前改造页面显式 blur 节点为 0，符合每屏不超过 6 个的预算；滚动列表未逐行添加 blur。
- 首页新增 `aboutToDisappear()` 清理，离开页面时停止速率轮询并清除定时器，避免后台空转；连接状态变化时的原有启停逻辑保持不变。
- `uiFxLevel` 继续使用 `full`/`lite` 二选一并默认 `full`；设置页切换即时更新。当前实现无显式 blur，lite 模式不存在透明底残影风险。
- 已确认无新增 `.stateEffect()`，效果按钮使用 `layoutWeight(1)`；UI 白名单和冻结路径检查无异常。
- 浅色 token 保持 F1 现有实色语义；深色对比度、快速滚动帧率与静置功耗标记为待构建机和 MatePad mini 真机复核。
- 已完成资源 JSON、NUL、功能引用和 `git diff --check` 只读审计；未构建、未打包、未执行 Git 写操作。构建状态：待构建机验证。

## 2026-09-04 U7 整体验收与收口（方案 C）：静态验收已完成，待构建机与真机验证

- 已对 U1–U7 全量变更执行只读静态审计：`git diff --check` 通过；资源 JSON 可解析且无重复键；base/dark 颜色键 48=48，base/en_US 文案键 315=315；UI 白名单内未发现 TODO/FIXME、`$r()` 模板串混用、新增 `.stateEffect()` 或显式 blur。
- 已逐项核对 `git diff --stat` 与未跟踪文件：运行时代码全部位于 UI 白名单，文档改动仅涉及 `CHANGES.md`、`DEVPLAN.md` 及 U5 条件任务方案；未触碰 `module.json5`、内核、`vpnext`、`utils`、`model`、`entry/libs`、`build-profile.json5` 或 `AppScope`。
- 存量 ArkTS 十六进制色值仅位于 `LogPage.ets` 的刻意保留终端配色，以及 `UiSpec.ets` 的状态栏黑白内容色；本轮新增页面代码未增加硬编码色值。
- U1–U4 已完成方案 C 首页、节点列表、订阅/设置页及 token/性能护栏改造；U5 因 `module.json5` 冻结仅完成设计方案；U6 已完成 compact/medium/large 响应式结构。
- 静态功能链路核对覆盖节点选择/测速/排序/分享、订阅更新/导入/分享、规则页、连接页、日志页、设置页、深浅色、full/lite 与响应式分支；未移除既有入口或改变 Store/AppStorage 业务状态契约。
- 严格遵守禁止构建要求，未执行 HAP 构建、打包或 Git 写操作。六种主题与断点组合视觉走查、全流程九步回归、断网/断连态、进程重启恢复、窗口旋转缩放、性能功耗及 HarmonyOS API 类型仍待构建机和真机验证。
- U5 待确认：只有用户明确解除 `entry/src/main/module.json5` 冻结后，才能按 `docs/U5-桌面服务卡片方案.md` 实现 2×2/2×4 服务卡片及 FormExtensionAbility 注册。
- 接真实数据源新增 TODO：无。当前 UI 所需数据继续复用既有 Store/AppStorage，未提出或写入新的内核、model 或 utils 接口。

## 2026-09-04 U6 平板响应式布局（方案 C）：已完成开发，待构建机验证

- 新增 `AppStorage('uiBreakpoint')`，由 `EntryAbility` 根据窗口短边 vp 划分 `compact`（<600vp）、`medium`（600–839vp）和 `large`（>=840vp）；窗口创建时初始化，注册 `windowSizeChange`，并在窗口舞台销毁时注销监听。
- medium/large 布局新增方案 C 玻璃霓虹侧栏，宽度分别为 150vp/180vp，提供首页、代理、订阅、规则和设置入口；页面切换继续复用现有 Store、AppStorage 与业务页面，不重置 VPN、节点或订阅状态。
- 节点列表在 compact/medium/large 下分别采用 1/2/3 列；medium/large Hero 电源按钮调整为 64vp，compact 保留既有尺寸和单栏布局。
- 新增 `entry/src/main/ets/common/Breakpoint.ets` 和 `entry/src/main/ets/common/components/Sidebar.ets`；仅在白名单允许的 `EntryAbility.ets` 中增加最小化的窗口尺寸初始化及监听生命周期代码。
- 未触碰 `module.json5`、内核及其他冻结路径；未构建、未打包、未执行 Git 写操作。
- 已知限制：本机未找到可核对的 HarmonyOS SDK 声明，`window.Size`、`windowSizeChange` 及 px/vp 密度换算仍需构建机编译确认；响应式观感和旋转/窗口缩放行为尚未通过预览器或真机验证。

## 2026-09-04 U3 订阅页与设置页（方案 C 玻璃拟态霓虹）：已完成开发，待构建机验证

- 设置页订阅卡与订阅详情信息卡改为方案 C 玻璃描边样式；滚动列表内订阅卡使用实底玻璃降级，避免逐项 blur。
- 设置页新增“视觉效果”完整/轻量二选一，使用新增 UI 专用 `AppStorage('uiFxLevel')`，默认 `full`，点击后即时更新当前页状态；现有主题三选一机制及 `AppSettings` 持久化契约保持不变。
- 保留订阅更新、分组、删除、分享及详情入口，并保留出站模式、路由、Geo、自动更新、网络参数、排序、触感、连接统计、分应用代理、备份恢复和不安全 TLS 等既有设置链路。
- 新增中英文资源键 `ui_fx_level`、`ui_fx_full`、`ui_fx_lite` 各 3 个，base/en_US 键集合一致；未新增 ArkTS 十六进制色值或 `.stateEffect()`。
- U3 改动涉及 `entry/src/main/ets/pages/SettingsPage.ets`、`entry/src/main/ets/pages/SubDetailPage.ets`、base/en_US `string.json`、`DEVPLAN.md` 与 `CHANGES.md`。
- 已完成资源 JSON、功能引用及 `git diff --check` 静态核对；未构建、未打包、未执行 Git 写操作。构建状态：待构建机验证。

## 2026-09-04 1.6.1 UI 全局统一与订阅入口重构：已完成开发，待构建机验证

- **统一添加入口**：首页底部「+」按钮改为打开新增 `AddEntryDialog`，提供「导入订阅」(主按钮)与「新建节点」两个入口；移除原底部「导入 / 启动 VPN / 新建」三连按钮，VPN 启停仅由 HeroCard 内 `BigPowerButton` 承担。
- **订阅命名与分组**：`upsertSub(url, userinfo, requestedName)` 新增可选订阅名参数；非空时写入 `SubInfo.name` 与 `SubInfo.group`，为空时保持域名推断名称且未分组；已有订阅仅在提供非空名时更新，不清空既有分组；`Index.doImport` 透传名称。分享文本(非 URL)导入不创建订阅、不写分组。
- **最近分组偏好**：新增 Preference 键 `recent_subscription_group`。导入订阅(非空名)与设置页改组(非空名)时写回；导入弹窗打开时默认带入；`ProfileEdit` 新建节点时按名称匹配 `loadGroups()`，命中则设 `Profile.groupId`，未命中保持未分组；编辑已有节点不覆盖原分组。
- **设置页订阅区强化**：分组头对命名组与未分组均显示「名称 · 数量」(新增 `sub_group_none_count`)；每条订阅卡片化(`UiSpec.CARD_RADIUS`/`GAP_MD`/`surface`)，更新/分组/删除三按钮 `layoutWeight(1)` 等分；`saveSubGroup` 写回最近分组。
- **五页面统一**：`ConnectionsPage` 连接项、`RouteRulesPage` 本地规则与远程规则集、`SubDetailPage` 信息卡(新增分组显示)与主/次/危险按钮、`ProfileEdit` 粘贴解析区与内容边距，统一到 `UiSpec` 令牌；日志页终端配色保持不变。
- **文案**：「导入链接」全局改为「导入订阅」(import_link_subscription / subscription_link_use_home / settings_subs_empty)；删除已无引用的 `import_link` 键；新增 `subscription_name_optional`、`sub_group_none_count`、`sub_group_value`；删除死资源 `sub_group_none`。
- 改动文件：`entry/src/main/ets/core/Subscriptions.ets`、`entry/src/main/ets/pages/Index.ets`、`entry/src/main/ets/pages/ProfileEdit.ets`、`entry/src/main/ets/pages/SettingsPage.ets`、`entry/src/main/ets/pages/ConnectionsPage.ets`、`entry/src/main/ets/pages/RouteRulesPage.ets`、`entry/src/main/ets/pages/SubDetailPage.ets`、`entry/src/main/resources/base/element/string.json`、`entry/src/main/resources/en_US/element/string.json`、`DEVPLAN.md`、`CHANGES.md`。
- 静态检查：4 个资源 JSON 语法通过；base/en_US 字符串键 311=311 无缺失；base/dark 色值键 24=24 无缺失；`git diff --check` 干净；无 `$r()` 进模板串；十六进制色值仅存于日志页(刻意保留)；改动全部位于 `entry/src/main/ets` 与 `entry/src/main/resources` 白名单，未触碰内核 `core/`、`.so`、`module.json5`、`build-profile.json5`、`AppScope`。
- 已知限制：构建状态为“待构建机验证”，未构建、未打包、未执行 Git 写操作；`ProfileEdit` 新建节点默认分组依赖存在同名 `ProfileGroup`(仅按名称匹配，不自动创建分组)；`AddEntryDialog` 与订阅卡片三按钮的窄屏实际观感、导入命名后设置页分组分节显示，均待真机验证。


> 构建机注(2026-09-04,1.6.1 轮):一次编译通过(versionCode 1001902)。铁律核查:module.json5/内核/AppScope/签名配置零改动,${$r( 模板混用 0。真机验证点:首页单一添加入口(导入订阅/新建节点)、导入订阅命名即订阅分组、设置页订阅分组分节显示、五页面新风格与深浅色。


> 构建机注(2026-09-04,底部菜单栏轮):本交付 SettingsPage.ets 文件末尾带 7 个 NUL(0x00)字节,ArkTS 编译器报 Invalid character ×8(构建机已清除)。原因指向开发端的编辑器/传输管道——提交前请确保文件以干净换行结束、无 NUL/乱码尾。底部菜单栏单一「添加」入口与快捷开关卡移除均已合入,versionCode 1001903(构建机确认并沿用开发端自升的版本号)。


> 构建机注(2026-09-04,U1~U7 方案 C 合入轮):一次修复后编译通过(1001904)。修复四处:①EntryAbility 的 windowSizeChange 误挂在 WindowStage 上(该对象仅支持 windowStageEvent),改为 getMainWindow 后在 Window 实例上挂/卸监听;②BigPowerButton 成员 size 为基类保留名,改 orbSize;③Sidebar 成员 width 为基类保留名,改 panelWidth(调用点同步);④Index 根容器现为 Row(适配 medium/large 侧边栏),尾部 alignItems 误用 HorizontalAlign 改 VerticalAlign,并清理重复修饰符。另:开发端以 tar 全量覆盖工作区会产生行尾幻影 diff,构建机以 git add 归一化后按真实改动 16 文件收编。

## 2026-09-04 2.0 首轮真机反馈修复：6 项已完成开发，待构建机与真机验证

1. **底部四 Tab**：compact、medium、large 三种断点统一改为底部悬浮玻璃导航，固定为「首页 / 代理 / 订阅 / 我的」；删除旧 `Sidebar` 组件及全部引用。订阅 Tab 在 `Index` 内展示订阅配置，我的 Tab 进入既有设置页。
2. **首页仅显示当前节点**：首页保留连接 Hero、电源按钮、模式切换和实时统计，只显示当前运行或当前选中的节点卡；点击节点卡进入代理 Tab，全量节点列表不再占据首页。
3. **代理按当前配置与地区筛选**：代理页仅显示当前订阅或本地配置下的节点，按节点名前缀生成「全部 / HK / JP / SG…」地区筛选；保留选择、编辑、长按菜单、延迟能量条和选中辉光，并提供仅测试当前配置节点的延迟测试入口。
4. **配置按 `SubInfo.group` 分节**：订阅配置直接依据 `SubInfo.group` 分节，未分组独立显示；订阅卡展示流量、到期、最近更新时间和当前配置高亮，保留更新、分享、改组、删除操作。
5. **导入命名即时归组**：非空导入名称继续通过 `upsertSub` 写入 `SubInfo.name` 与 `SubInfo.group`；导入成功后立即刷新订阅和节点状态，使订阅页即时归入对应分节，代理页同步读取新配置。
6. **固定 2×2 统计卡**：Hero 的四张统计卡固定为两行两列，内容为实时上传、实时下载、累计上传、累计下载，复用现有 AppStorage 流量状态链路。

改动文件：
- `entry/src/main/ets/pages/Index.ets`
- 删除 `entry/src/main/ets/common/components/Sidebar.ets`
- `entry/src/main/resources/base/element/string.json`
- `entry/src/main/resources/en_US/element/string.json`
- `DEVPLAN.md`
- `CHANGES.md`

约束与验证状态：
- 未修改 `core/`、`model/`、`utils/`、`vpnext/`、`module.json5`、`AppScope/`、`build-profile.json5`、版本号、`.so` 或构建产物。
- 未构建、未打包、未执行 Git 写操作。
- ArkTS 类型检查、三断点布局、悬浮导航与 FAB 避让、地区识别、导入即时刷新以及 full/lite 深浅色观感待构建机和真机验证。


> 构建机注(2026-09-04,六项修复轮):两次小修后编译通过(1001905)。①Index.ets 的 type MainDestination 声明插在 import 语句之间(arkts-no-misplaced-imports ×10),已移至 import 块之后;②代码使用 saveSettings 但 import 缺失,已补。真机验证点:三断点底部悬浮玻璃四 Tab、FAB 避让、地区前缀识别、导入即时归组、full/lite 深浅色。
