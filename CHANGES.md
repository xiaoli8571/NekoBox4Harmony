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

## 2026-09-03 U1 首页重构：已完成开发，待构建机验证

- 按方案 A「鸿蒙原生卡片流」重构首页视觉层级，连接状态继续只读 `AppStorage('vpnStatus')` 并通过 `Index.statusDisplay()` 显示映射，未改变既有机器键语义。
- 新增并接入 `BigPowerButton`、`MiniStatCard`、`ToggleRow` 组件：主连接按钮直径 118vp，支持断开、连接中、已连接三态及 200ms 按压缩放；实时速率、流量和节点数量采用 2×2 小卡布局并使用等宽数字。
- 首页快捷开关复用既有 `AppSettings` 与 `saveSettings()`，未新建状态层或 AppStorage 业务键。
- 保留既有节点选择、VPN 启停、订阅导入、节点新增与编辑、测速、分组测速、分组折叠、手动排序、置顶、分享、per-app 设置入口，以及连接、日志、设置页面入口。
- 扩展既有 `UiSpec` 与 base/dark 颜色资源，新增按钮 ring、glow 和图标颜色 token；新增中英文文案各 3 键，两侧资源键集合一致。
- 改动文件：`entry/src/main/ets/common/UiSpec.ets`、`entry/src/main/ets/common/components/BigPowerButton.ets`、`entry/src/main/ets/common/components/MiniStatCard.ets`、`entry/src/main/ets/common/components/ToggleRow.ets`、`entry/src/main/ets/pages/Index.ets`、`entry/src/main/resources/base/element/color.json`、`entry/src/main/resources/dark/element/color.json`、`entry/src/main/resources/base/element/string.json`、`entry/src/main/resources/en_US/element/string.json`、`DEVPLAN.md`、`CHANGES.md`。
- 已执行 JSON 语法校验、base/en_US 文案键一致性核对与 `git diff --check`；按约束未启动构建、打包或任何 Git 写操作。
- 已知限制：构建状态为“待构建机验证”；连接时按钮当前以省略号表达 loading，旋转 loading 动效与呼吸状态点留待 U4 统一校核；首页仍保持现有单页节点管理结构，底部导航与完整页面拆分将在后续 U 阶段按既定顺序处理。


> 构建机注(2026-09-03,UI 重构 + 订阅分组的):打包前检查确认无订阅分组功能,构建机已实现 —— SubInfo 新增 group 字段(Preferences JSON 与备份 schema 天然向后兼容,旧数据默认未分组);设置页订阅区按分组分节渲染(未分组在最前,组头显示数量),每条订阅新增"分组"操作(SubGroupDialog 弹窗改组);新增 4 组中英文案。另修复 Codex 重构组件在本机 SDK 的两个编译错误:MiniStatCard 移除 fontVariant(FontVariant 本机不存在)、ToggleRow 成员 enabled 为保留名改 controlEnabled。订阅分组实现:ets/core/Subscriptions.ets、ets/pages/SettingsPage.ets、resources 双份 string.json。versionCode 1001901。


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

## 2026-09-05 B 方案 U1-U7 静态交付

- 底部与宽屏导航统一为首页、订阅管理、设置三个目的地；首页保留测速、连接、日志文字入口。
- 订阅管理页以纯行和 hairline 组织订阅、节点分组及节点操作，支持搜索、详情、分组编辑、更新与删除；删除订阅时仅在 UI 层通过既有存储能力同步过滤 `subUrl` 关联节点，未修改 `core` 或 `model`。
- 新增订阅名称与分组编辑 `CustomDialog`，保存 `SubInfo.name`、`SubInfo.group` 并复用 `recent_subscription_group`。
- 节点分组标题支持折叠和展开；本组测速保留独立点击行为。
- URL Test 菜单与结果迁移到 base/en_US 字符串资源；新增导航、搜索和空态文案同步资源化。
- 响应式 UI 状态键统一为 `uiBreakpoint`、`uiUptime`、`uiUptimeStart`：`uiBreakpoint` 保存 compact/medium/large 窗口断点，`uiUptimeStart` 保存当前连接起点毫秒时间戳，`uiUptime` 保存展示用累计秒数，断开时后两者归零。
- `PowerButton` 保持 150vp 外环、116vp 核心、42vp 图标、180ms 动画与运行细环，按压比例调整为 0.94。
- 设置页移除重复订阅区，保留订阅区以外既有设置能力；B 方案采用纯行、hairline、无卡片阴影和无渐变视觉。
- 新增 `docs/U5-desktop-service-card.md`，仅记录桌面服务卡片方案，未修改 `module.json5`。
- 新增 `BottomNavText.ets` 与 `StatsRow.ets` 组件；EntryAbility 仅增加窗口断点初始化和监听。
- 本轮按约束不构建、不打包、不执行 commit/add/reset/checkout 等 Git 写操作。


## 2026-09-05 B 方案第二轮静态交付

- 设置页改为首页设置 Tab 原位渲染，保留原有设置业务与保存链路；页面采用纯行、hairline、无卡片阴影与无 blur。
- AppSettings 新增 navLayout(bottom/side)，Store.loadSettings 将非 side 值钳制为 bottom，导航可选择底部菜单栏或侧边栏。
- 首页移除测速入口；订阅管理保留全量测速、分组测速与节点菜单测速。
- 新增 active_config_url 偏好：点击订阅即选中并持久化，仅显示该订阅节点；导入订阅后自动选中。
- 复核补齐订阅切换一致性：点击订阅后同步选中该订阅的首个节点，避免首页仍引用被过滤的旧节点。
- Index 与 SettingsPage 本轮涉及的 fontWeight 全部使用数字。
- 中英文资源同步新增导航布局文案。
- 静态审查通过：改动文件无 NUL、统一 LF，base/en_US 文案键各 324 个且完全一致；未修改冻结内核、module.json5、build-profile.json5、AppScope 或依赖清单。
- 任务 8 待补日志：本机 `/root/bkui` 未发现可用的应用日志、hilog 或崩溃日志，暂不能开展应用层归因；收到复现时段的 hilog/崩溃栈后继续排查。


## 2026-09-05 B 方案第三轮静态交付

- VPN 常驻通知固定为两行正文：第一行显示当前节点与最近延迟，第二行显示上下行实时速度及上下行累计流量；新增流量标签均由 base/en_US 字符串资源提供。
- 通知流量轮询仅在 VPN 已运行且 Clash API 已启用时启动；断开、onDestroy、启动失败、异常回滚、无待启动节点和统一 teardown 均停止轮询并取消通知，异步轮询通过 generation 防止停止后回写。
- 设置页七组默认展开且可折叠；统一保存按钮仅 dirty 时可用。除 switchMode 继续即时持久化外，所有持久设置控件仅 markDirty；外观切换先即时 applyAppearance 再 markDirty；保存成功及恢复成功后清除 dirty。
- 本轮仅进行静态验证，未运行构建、打包或真机测试。


## 2026-09-06 P 轮:对齐 NekoBoxForAndroid(main 分支)功能与信息架构

> 本轮以安卓版 NekoBox for Android(仓库 main 分支 tarball)为基准做 1:1 功能对齐;视觉沿用已真机验收的鸿蒙原生观感令牌(UiSpec),信息架构与交互对齐安卓。**已在本机 DevEco SDK 编译通过(versionCode 1001917,构建环境:C:\PROGRA~1 短路径 + HVIGOR_USER_HOME=C:\hvigor-home + %USERPROFILE%\.npmrc)**。

### 协议与数据模型
- ProfileType 新增 ssh / shadowtls / custom(自定义出站 JSON)/ chain(链式代理);Profile 新增字段:ssPlugin/ssPluginOpts、packetEncoding、wsEarlyData/wsEarlyDataHeaderName、certificates、ech/echConfig、muxProtocol/muxMaxStreams/muxPadding、hysteria2 serverPorts/hopInterval、tuic reduceRtt/disableSni、WireGuard wgMtu/reserved、SSH sshAuthType/privateKeyPassphrase/hostKey、shadowtlsVersion、customOutbound、chainIds。
- ConfigBuilder:新增 SSH/ShadowTLS/自定义出站/链式代理(detour 前置→落地)生成;消费新设置(嗅探三态 sniff/sniff_override_destination、bypassLan 开关、dnsRouting 开关、FakeDNS(fakeip server + dns rule)、远程/直连 DNS 域名策略、mixedPort 混合入站 + allowAccess 监听 0.0.0.0、logLevel、globalCustomConfig 根级浅合并、clash_api external_ui 挂载 yacd);VMess/VLESS packetEncoding、WS 早期数据、TLS 证书数组与 ECH、Mux protocol/max_streams/padding、hysteria2 server_ports/hop_interval、TUIC reduce_rtt/disable_sni、SS plugin/plugin_opts、WireGuard mtu/reserved。导出 buildOutboundJson 供分享菜单「导出配置」。
- 链接解析:新增 ssh:// scheme、socks4/socks4a;SS 分享链接 plugin 参数不再丢弃(obfs-local/v2ray-plugin 直写内核);导出新增 ssh://。

### 设置页(对齐安卓 global_preferences 分组)
- 新分组:常规(日志级别/连接测试 URL/测速并发/始终显示地址/通知显示分组名/全局与订阅放行不安全 TLS)、路由(原网络组 + bypassLan/嗅探三选/mixedPort/allowAccess)、DNS(远程/直连 DNS + 域名策略/dnsRouting/FakeDNS)、入站(mixedPort/allowAccess)。
- Store.loadSettings 对新字段做枚举与数值钳制;移除设置页「导航布局」(抽屉导航替代,AppSettings.navLayout 保留兼容旧备份)。

### 信息架构(对齐安卓 MainActivity 抽屉)
- Index 重构:自绘抽屉导航(配置/分组/路由/设置/日志/面板/工具/关于)+ 底部 StatsBar(上下行速率 + 状态,点击 URL Test 当前节点)+ 右下 FAB(连接/断开/进度,替代 BigPowerButton 大按钮,组件保留未删)。
- 配置页:分组 Tabs(Scrollable,≥2 组显示)+ 顶栏(抽屉/连接页/搜索/添加/分组菜单:测速本组/清除测试结果/去重/删除不可用/排序三选)+ 节点卡(置顶标记/类型/地址可开关/延迟色/选中高亮)+ 长按菜单新增「导出 sing-box 配置」。
- 分组页 GroupPage(新增,对齐 GroupFragment):订阅卡(节点数/最近更新/流量徽标 已用·剩余/到期)+ 手动分组卡;更新全部订阅(汇总 added/removed);单项操作:更新/分享订阅链接/导出全部节点链接/清空分组/删除;新建/删除手动分组(删除组内节点移至未分组)。
- 工具页 ToolsPage(新增):STUN NAT 行为发现(RFC5389 Binding,公网映射地址/耗时/两次探测映射稳定性启发)+ 恢复出厂(双确认,Store.resetAllData)。
- 关于页 AboutPage(新增):版本/内核版本/检查更新(GitHub releases API)/项目主页 openLink/开源许可。
- Dashboard DashboardPage(新增):Web 组件加载 clash_api /ui;yacd 资源由安卓版 assets/yacd.zip(749KB)内置到 resources/rawfile,VpnExtAbility 启动前经 @ohos.zlib 解压到 cacheDir 并把路径传入 external_ui(失败降级提示,不影响连接)。
- ClashApi:fetchCurrentProxyDelay 支持自定义端口与测试 URL(消费 settings.testUrl)。

### 资源
- base/en_US string.json 各 +133 键(抽屉/分组/工具/关于/设置新组/新协议表单/错误提示),双语 463=463 对称;tools/check_keys.js 静态扫描 0 缺失。
- 移除设置页 navLayout UI;BigPowerButton/StatsRow/BottomNavText 组件保留但 Index 不再引用。

### 已知限制
- 内核冻结(sing-box 1.11.9):anytls/mieru/naive/trojan-go 无法支持(需 1.12/插件 exe);链式代理、自定义出站、SSH、ShadowTLS 均为内核原生能力。
- FakeDNS 与 resolveDestination 前者为真机验证项,后者仅存档不参与配置生成;通知显示分组名设置存档待 VpnExtAbility 消费。
- 二维码扫码/生成维持既有降级(纯文本+复制);仅代理服务模式、开机自启、Quick Tile、TV 为安卓平台能力,鸿蒙无对应机制(桌面卡片方案见 docs/U5)。
- 真机验证点:抽屉导航与 FAB 全断点无溢出、分组 Tabs 切换、STUN 真机探测、yacd 面板加载(/ui + secret)、链式/SSH/ShadowTLS/自定义出站真实连接、FakeDNS 开关、mixedPort 局域网访问。


## 2026-09-06 真机反馈修复轮(1.7.1,versionCode 1001918)

> 来源:真机试用反馈三项。全部改动位于 entry/src/main/ets 与 resources,已在本机 DevEco 编译通过。

### 1. 抽屉各驻留页无返回入口
- 新增共用组件 common/components/DrawerButton.ets(≡ 按钮);GroupPage/SettingsPage/ToolsPage/AboutPage/DashboardPage 头部全部接入,新增 onOpenDrawer 回调由 Index 打开抽屉。
- 此前 ≡ 只在配置页顶栏,切到分组/工具/关于等页后没有任何返回导航的路径。

### 2. FAB 启动按钮白色方形底
- 原实现 Stack+Circle 的 shadow 按组件矩形边界渲染,产生方形光晕。
- 改为容器式圆形按钮:borderRadius(32) + clip + 阴影跟随圆角;新增半透明色值令牌 fab_bg/fab_running(base #CC3478F6/#CC12A150,dark #CC6EA1FF/#CC4CCB7F);按钮放大到 64vp。

### 3. 长时间闲置后 VPN 无法启动
- 根因:UI 进程闲置被系统回收重建后(AppStorage 重置为未连接),:vpn 扩展实例仍在运行;再次点启动时扩展走「已在运行且节点未变化,忽略重复触发」分支且不广播状态,UI 永远停在「连接中」。
- 修复:① 扩展两个忽略分支现在都会重播 connected:<节点> 状态(publishVpnStatus),回到前台的 UI 立即同步为已连接;② VpnService 启动看门狗升级:60s 数据面证据恢复逻辑保留,新增 120s 终态判定——仍停留在 connecting 则置 connect_failed(启动超时,可重试),不再无限转圈;③ doTeardown 的 stopCore/destroy 加 8s/5s 超时兜底,防止内核挂起时 teardown 永不结束卡死 starting 标记(之后所有启动请求会被队列吞掉);④ Index.onPageShow 增加前台状态核对:UI 认为「已连接」而 clash API 探测不可达(扩展实际已死)时,重置为断开态。

### 其他
- Index FAB 相关:fab 颜色令牌入 base/dark color.json 对称(检查脚本通过)。
- 文档:本条;DEVPLAN 增补修复轮状态行。


## 2026-09-06 真机反馈修复轮 2(1.7.2,versionCode 1001919)

> 反馈:①设置页与侧边栏内容重复;②面板无用要求删除;③UI 仍是旧观感,要求对齐安卓。已在本机 DevEco 编译通过。

### 1. 设置页去重(对齐安卓设置只保留 global_preferences 内容)
- 移除「自定义路由入口」行(路由已在抽屉);移除「其他/关于」分组(版本在抽屉-关于页);「备份与恢复」整组迁至工具页(安卓 Tools = 网络/备份两个 Tab 的布局)。
- SettingsPage 相应清理 router/picker/fs/util/pasteboard/Backup 导入与 backup 助手方法、appVersion/backupFileBusy/backupExpanded/otherExpanded 状态。

### 2. 面板(Dashboard/yacd)功能整体删除
- 抽屉移除「面板」项;删除 DashboardPage.ets、utils/WebUiAssets.ets、resources/rawfile/yacd.zip;ConfigBuilder 移除 external_ui 生成与参数;VpnExtAbility 移除 yacd 解压逻辑。clash_api 本体保留(连接统计依赖)。

### 3. UI 对齐安卓观感
- 配置页节点列表改为安卓卡片式:圆角 14 卡片、surface 底色、阴影、选中主色描边、协议类型徽标。
- 抽屉头部对齐安卓:应用图标 + 名称 + 版本号;菜单项加图标字形。
- 路由/日志改为抽屉内嵌页签(上一轮已做),本轮索引重排:0 配置/1 分组/2 路由/3 设置/4 日志/5 工具/6 关于。


## 2026-09-06 对审修复轮(1.7.3,versionCode 1001920)

> 对审发现的失效项全部修复;已在本机 DevEco 编译通过。

1. Clash 订阅解析补全:hysteria2/hy2(password/sni/skip-cert-verify/obfs-password/up/down/ports 端口跳跃)与 tuic(uuid/password/congestion-controller/udp-relay-mode/reduce-rtt/disable-sni/alpn)映射到对应出站;此前这两类节点被跳过。
2. Clash 传输解析修复:grpc-opts 读 grpc-service-name(此前读错键名导致 serviceName 丢失);ws-opts 增加 max-early-data/early-data-header-name;network h2 映射为 sing-box http 传输;兼容顶层 service-name。
3. 「订阅请求放行不安全 TLS」(subAllowInsecure)接线:订阅下载经 http.remoteValidation='skip'(API 18+),生效于手动/自动/后台全部订阅更新路径与首页导入。
4. 「解析目标地址」(resolveDestination)接线:规则模式下注入 resolve 兜底规则,IP 类规则(geoip 等)可匹配域名连接。
5. 「通知中显示分组名」(notificationGroup)接线:连接时解析节点分组,通知副标题显示 [组名] 节点 · 延迟。
6. 设置页补 UI:「解析目标地址」开关(路由组)、「全局自定义配置 JSON」输入(常规组,浅合并入 sing-box 根配置)。

## 2026-09-16 华为 UX 合规整改轮(2.0,versionCode 2000000)

> 客户反馈六项整改 + 对比度达标 + 未签名 HAP 重新打包。

1. **对比度整改(浅色)**:primary #3478F6→#2364D8(正文用法 3.79→5.04:1,白字按钮 4.4→5.4:1)、primary_pressed→#1B53B8、fab_bg 同步、dot_live #22C55E→#16A34A(状态点 2.11→3.07:1,过 3:1 图形线)。实测:正文类令牌全部 ≥4.5:1,图形类 ≥3:1。
2. **对比度整改(深色)**:dark text_3 #7B828E→#8B929E(卡片上 4.23→5.36:1);其余深色令牌实测 ≥4.5:1。
3. **日志页主题统一**:LogPage 已随全局主题(app_background/surface,ERROR/WARN/DEBUG 语义色),修正遗留"固定深底"注释。
4. **分应用代理**:链路复核(perAppList→VpnConfig.trusted/blockedApplications→create 前写入,模式/名单变更自动保存+重启 VPN),代码层无缺陷;真机生效性待客户回归(内核补丁注释已提示 blockedApplications 拦不住内核线程出站,属系统框架行为)。
5. **批量导入单节点**:首页导入与 ProfileEdit 粘贴解析均支持多行协议链接批量入库(单条填表单,多条直接保存)。
6. **自定义路由卡顿**:persist 防抖 300ms→1000ms,减少 JSON 序列化+Preferences 写盘频率。
7. **桌面图标放大**:foreground.png 主体 587/1024(57%)→799/1024(78%),entry 与 AppScope 双份同步;打包工具自动降采样至 512 画布,主体占比保持 78%,圆角安全区不触碰。
8. **重打包**:hvigor assembleHap(BUILD SUCCESSFUL)产出 entry-default-unsigned.hap(14.87MB,versionName 2.0/versionCode 2000000,已验证 HAP 内新图标比例),复制为 dist/NekoBox4Harmony-2.0-unsigned.hap。

改动文件:resources/base/element/color.json、resources/dark/element/color.json、entry+AppScope resources/base/media/foreground.png、pages/LogPage.ets、pages/RouteRulesPage.ets、AppScope/app.json5(2.0/2000000)、CHANGES.md

## 2026-09-16 首页分组折叠展示(2.0,客户新需求)

> 用户反馈:导入多个订阅后分组页有多组,但首页所有节点混在一起,希望按分组展示、点开分组再看节点(对齐安卓 NekoBox 分组列表)。

1. 首页配置页从「分组 Tabs 页签」改为**统一可折叠分组列表**:每组渲染分组头(组名 + 节点数 + 组内最优延迟徽标 + 展开箭头),点按头折叠/展开;组内节点沿用原卡片样式与全部交互(点选/热切换/长按菜单)。
2. 折叠状态持久化 `home_collapsed_groups`('|' 分隔,保留空串=未分组组);首次使用默认全部折叠、当前选中节点所在组自动展开;搜索关键字时命中组强制展开、无命中组隐藏。
3. 组头长按菜单:测速本组/清除本组结果/本组去重/删除本组不可用(原「当前组」语义迁移到组头)。
4. 顶部 ⋮ 菜单改为全局操作:测速全部节点(新键 test_all_nodes)/清除测试结果/移除重复节点/删除不可用节点 + 三种排序;clearTestResults/dedupGroup/deleteUnavailable/runGroupSpeedTest 支持 '__all__' 通配。
5. 顺手修复:base string.json 缺 app_name(en_US 已有),补齐后双语键 473=473 对齐。
6. 移除 Tabs/groupTabIndex/activeGroupId/nodeListFor 死代码。

验证:hvigor assembleHap BUILD SUCCESSFUL;双语键 diff=0;无残留引用;产物已更新 dist/NekoBox4Harmony-2.0-unsigned.hap(14.89MB)。

改动文件:pages/Index.ets、resources/base+en_US/element/string.json、CHANGES.md

## 2026-09-16 一订阅一分组 + 订阅改组移节点(2.0,客户新需求)

> 用户反馈:导入两个订阅后,自建分组无法把订阅节点归进去,首页节点混在一起;希望一个订阅自动一个分组。根因:导入/更新只写 subUrl 从不写 groupId,订阅 group 字段只影响分组页展示。

1. Store 新增 `ensureGroupByName(name)`:按名称查找 ProfileGroup,不存在自动创建,返回组 id(空名='')。
2. **导入订阅自动分组**(Index.doImport):订阅路径以「订阅名(用户命名优先,否则域名)」ensureGroupByName 并把本批节点 groupId 归组;单节点导入不受影响。
3. **更新订阅自动分组**(Subscriptions.updateSubscription):新增节点按 SubInfo.group→name→域名 归组;并迁移该订阅遗留的未分组节点(用户手动分过组的不覆盖)。
4. **订阅详情页「分组」按钮**(SubDetailPage):SubGroupDialog 输入组名或点选已有分组 chips,保存同步 SubInfo.group + 移动该订阅全部节点到目标组(留空=移回未分组);新键 sub_group_apply_hint/sub_group_applied/sub_group_applied_none。

验证:hvigor assembleHap BUILD SUCCESSFUL;双语键 476=476 diff=0;产物已更新 dist/NekoBox4Harmony-2.0-unsigned.hap(14.91MB)。

改动文件:model/Store.ets、core/Subscriptions.ets、pages/Index.ets、pages/SubDetailPage.ets、resources/base+en_US/element/string.json、CHANGES.md

## 2026-09-17 备份恢复可靠性整改(2.0)

> 对备份导入链路进行一致性与故障安全复核，统一文件恢复和剪贴板恢复行为，并补齐远程规则集统计与中英文反馈。

1. `Backup.ets` 的数组校验改为显式 `Array<Object>` 遍历，消除 ArkTS 对收窄后集合迭代与逐项断言的兼容隐患；备份格式校验仍保持 fail-closed。
2. `ToolsPage.ets` 的剪贴板恢复改为复用 `restoreText()`，与文件恢复共享恢复互斥、VPN 停止等待、事务回滚与结果汇总流程，不再绕过安全恢复入口。
3. 恢复成功摘要补充远程规则集数量，并新增已停止 VPN、恢复任务繁忙、VPN 停止超时、完整回滚及回滚不完整等中英文反馈。
4. 验证：hvigor assembleHap `BUILD SUCCESSFUL`；base/en_US 字符串键均为 481，双向差异为 0；未签名 HAP 已重新生成于 `entry/build/default/outputs/default/entry-default-unsigned.hap`。
5. 已知限制：构建仍有项目既存的弃用 API、可能抛异常及无签名配置警告，本轮未新增编译错误；真机上的运行中 VPN 自动停止、故障注入回滚和剪贴板恢复仍需回归验证。

改动文件:entry/src/main/ets/core/Backup.ets、entry/src/main/ets/pages/ToolsPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 订阅容器 Scheme 支持(2.0)

> 对齐安卓 `ktx/Formats.kt` 的 `SubscriptionFoundException` 与 `ui/MainActivity.kt` 的 `importSubscription`，补齐 Clash 系分享链接的导入路径。

1. `utils/Subscription.ets` 新增 `unwrapSubscriptionLink(text)`:识别 `clash://install-config?url=...&name=...`，解码查询参数并返回真实订阅地址与名称;新增 `isSagerNetSubscriptionContainer(text)` 识别 `sn://subscription` 私有容器。
2. `pages/Index.ets` 的 `doImport` 在订阅判定前先解包容器 Scheme：真实地址进入既有下载/Clash YAML/sing-box JSON 解析、一订阅一分组、`upsertSub` 与选中流程;容器自带名称优先于调用方名称。`sn://subscription` 给出本地化提示并写日志，不再静默失败。
3. `pages/ProfileEdit.ets` 的 `applyPasted` 对 clash 容器引导回主页导入，对 sn 容器给出不支持提示。
4. 新增中英文资源 `subscription_container_unsupported`;错误文本不含密码、UUID 或完整认证 URL。
5. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 482=482，双向差异为 0;解包算法以 10 组输入用例独立验证全部通过(含 URL 编码、缺 url 参数、空文本、大小写、sn 容器识别);未签名 HAP 已重新生成。
6. 已知限制:未在 `module.json5` 注册外部 Scheme(VPN type 与阶段约束)，仅覆盖应用内粘贴与导入入口;`sn://subscription` 的 Kryo 私有序列化无法移植，采用明确提示而非静默丢弃。

改动文件:entry/src/main/ets/utils/Subscription.ets、entry/src/main/ets/pages/Index.ets、entry/src/main/ets/pages/ProfileEdit.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 启动自动连接 + 设置页文案资源化(2.0)

> 对齐安卓 `res/xml/global_preferences.xml` 的 `isAutoConnect`,并清理设置页常规组三处硬编码长文案。

1. `model/Profile.ets` 的 `AppSettings` 新增 `autoConnect`(默认 false);`core/Backup.ets` 的设置校验白名单同步加入该布尔字段,旧备份缺字段时保持默认值。
2. `pages/SettingsPage.ets` 常规组首项新增「启动时自动连接」开关与说明,沿用既有 `markDirty` 保存语义;测速方式与连接测试 URL 的说明文案改用资源键。
3. `pages/Index.ets` 新增 `autoConnect()`:`aboutToAppear` 刷新后,仅当开关开、VPN 未运行且有选中节点时调用 `VpnService.connect`;失败仅写日志,不弹错误。
4. 新增中英文资源 `settings_auto_connect`、`settings_auto_connect_desc`、`latency_test_mode`、`latency_test_mode_desc`、`settings_test_url_desc`。
5. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 487=487,双向差异为 0;未签名 HAP 已重新生成。
6. 已知限制:常规组测速方式下拉的选项标签与 `TUN MTU` 标签为既有硬编码,本轮未重构;自动连接在系统未授予 VPN 授权时与手动启动行为一致(`start_failed` 状态),真机需回归一次。

改动文件:entry/src/main/ets/model/Profile.ets、entry/src/main/ets/core/Backup.ets、entry/src/main/ets/pages/SettingsPage.ets、entry/src/main/ets/pages/Index.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 复杂节点导入闭环 + 设置页文案清零(2.0)

> 对齐安卓 `group/RawUpdater.kt` 的解析派发(JSON → base64 → 分享链接),补齐 WireGuard/自定义出站等无法用分享链接表达类型的导入路径;并清理设置页最后两处硬编码文案。

1. `utils/Subscription.ets` 新增 `parseSingleOutboundJson(text)`:JSON 为完整配置时直接走既有 `parseSingBoxConfig`,否则包成 `{outbounds:[obj]}` 再解析,「导出 sing-box 配置」复制的 JSON 可原路导回。
2. `utils/LinkParser.ets` 的 `parseShareText` 在 base64 回退前增加两类识别:sing-box JSON( `{` 开头)与 WireGuard `.conf`(`[Interface]`);新增 `parseWireGuardConf`,逐段解析 INI,每个合法 `[Peer]` 生成一个 WireGuard 节点,IPv6 方括号地址、注释行、缺字段 Peer 与安卓一致跳过。
3. `pages/SettingsPage.ets`:`TUN MTU` 标签与测速方式下拉标签资源化,`LATENCY_TEST_LABELS` 改为 `Array<Resource>`;Select 的 map 回调签名同步调整。
4. 新增中英文资源 `settings_tun_mtu`、`latency_test_url`、`latency_test_tcp`。
5. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;WireGuard conf 解析 4 组用例与单出站 JSON 解析 4 组用例独立验证全部通过;base/en_US 字符串键 490=490,双向差异 0;SettingsPage 已无硬编码字面量;未签名 HAP 已重新生成。
6. 已知限制:`.conf` 多 Peer 场景按安卓语义生成多个独立节点,不保留原始 AllowedIPs(配置生成侧统一为 `0.0.0.0/0,::/0`);导入的 WireGuard 节点真机连接待回归。

改动文件:entry/src/main/ets/utils/Subscription.ets、entry/src/main/ets/utils/LinkParser.ets、entry/src/main/ets/pages/SettingsPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 首页菜单与节点导出补全(2.0)

> 对齐安卓 `menu/add_profile_menu.xml` 的 misc 菜单与 `menu/profile_share_menu.xml` 的配置导出。

1. 首页 ⋮ 菜单新增「更新当前订阅」(取选中节点的 subUrl,无订阅时明确提示)与「清除流量统计」(重置累计上下行与速率基准),复用既有 `updateSubscription` 与 AppStorage 流量键。
2. 节点长按菜单新增「导出配置到文件」:`DocumentViewPicker.save` 写入 `<节点名>.json`,与已有的「导出配置」(剪贴板)并列;取消选择、写入失败均有本地化反馈。
3. 新增中英文资源 `update_current_subscription`、`current_subscription_missing`、`clear_traffic_statistics`、`traffic_stats_cleared`、`export_outbound_config_file`、`outbound_config_exported`。
4. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 496=496,双向差异 0;未签名 HAP 已重新生成。
5. 已知限制:「更新当前订阅」为纯应用层,不重启 VPN;真机需回归一次文件导出与订阅更新路径。

改动文件:entry/src/main/ets/pages/Index.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 分组页导出补全(2.0)

> 对齐安卓 `menu/group_action_menu.xml` 的 `action_export_file`。

1. `pages/GroupPage.ets` 订阅卡片操作行新增「导出节点到文件」:`DocumentViewPicker.save` 写入 `<订阅名>.txt`,文件名做非法字符替换;提取 `exportableLinks()` 供剪贴板与文件两条路径复用,空结果与取消选择均有本地化反馈。
2. 新增中英文资源 `export_all_nodes_file`、`export_all_file_done`。
3. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 498=498,双向差异 0;未签名 HAP 已重新生成。
4. 已知限制:仅导出可生成分享链接的协议(WireGuard/自定义出站等仍需走单节点「导出配置到文件」);真机需回归一次系统文件选择器写入。

改动文件:entry/src/main/ets/pages/GroupPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 日志页双语化 + 路由重置 + 分应用选择操作(2.0)

> 对齐安卓 `menu/logcat_menu.xml`、`menu/add_route_menu.xml`、`menu/per_app_proxy_menu.xml`;同时补齐日志页英文环境下的中文残留。

1. `pages/LogPage.ets`:标题、导出、清空、搜索占位、导出空/成功/失败提示全部改 `$r` 资源(新增 `log_export`/`log_clear`/`log_search_hint`/`log_export_empty`/`log_exported`);终端配色保持不变。
2. `pages/RouteRulesPage.ets`:头部新增「重置路由」按钮,双确认后清空自定义规则与远程规则集并落盘(对齐 `action_reset_route`);空规则时提示而非弹确认框。
3. `pages/SettingsPage.ets` 分应用代理:新增「反选」「清除选择」按钮(对齐 `action_invert_selections`/`action_clear_selections`),均走 `persistPerAppList`——标记脏、保存、运行中自动 `switchTo` 重启 VPN;按钮在无列表/无已选时禁用。
4. 全局扫描:`entry/src/main/ets` 下已无 `Text/Button/placeholder/message/label` 的中文字面量。
5. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 509=509,双向差异 0;未签名 HAP 已重新生成。
6. 已知限制:反选只作用于已加载的应用列表(与安卓一致);重置路由与分应用变更均需真机回归一次重启生效路径。

改动文件:entry/src/main/ets/pages/LogPage.ets、entry/src/main/ets/pages/RouteRulesPage.ets、entry/src/main/ets/pages/SettingsPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 抽屉新增「使用文档」(2.0)

> 对齐安卓 `main_drawer_menu.xml` 的 `nav_faq`(launchCustomTab 打开文档站点);鸿蒙端用应用内 Web 视图,无需系统浏览器。

1. 新增 `pages/DocPage.ets`:`Web` 组件加载项目文档地址,顶部返回按钮 + 加载指示器,页面注册入 `main_pages.json`。
2. 抽屉导航在「日志」与「工具」之间新增「使用文档」项(图标 ✎),选中即 `router.pushUrl` 打开文档页;不占用页签索引,既有 0~6 页签编号不变。
3. 新增中英文资源 `nav_docs`。
4. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 510=510,双向差异 0;未签名 HAP 已重新生成。
5. 已知限制:文档页需要网络(INTERNET 权限已有);页面加载失败时保留加载态,真机需回归一次弱网/无网表现与返回手势。

改动文件:entry/src/main/ets/pages/DocPage.ets(新增)、entry/src/main/ets/pages/Index.ets、entry/src/main/resources/base/profile/main_pages.json、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 订阅级设置 + 关于页交流群入口(2.0)

> 对齐安卓 `group_preferences.xml` 的 subscriptionUpdate 分类(`subscriptionAutoUpdate`/`subscriptionAutoUpdateDelay`/`subscriptionUpdateWhenConnectedOnly`/`subscriptionUserAgent`)与 AboutFragment 的 Telegram 项。

1. `SubInfo` 新增 `userAgent`/`autoUpdate`/`updateWhenConnectedOnly` 三个订阅级字段,`listSubs` 装载时对老备份缺字段回落默认值(自动更新默认开、UA 默认空),`updateIntervalHours` 约束统一为「非正数/非数字 → 12,上限 720」。
2. `utils/Subscription.ets` 的 `fetchSubscription`/`fetchSubscriptionWithInfo` 增加可选 `userAgent` 参数,空/空白回退默认 `clash.meta/1.19.0`;`updateSubscription` 取订阅自身 UA 发请求(一次 listSubs 复用,不额外读盘)。
3. `needAutoUpdate` 增加 `autoUpdate === false` 与「仅连接时更新且未连接」两道过滤;`touchSub` 成功后写回 `nextUpdateAt`(间隔判定不再只靠回退计算)。
4. 新增 `saveSubSettings(url, changes)`,显式字段写入(ArkTS 不支持动态属性赋值),供订阅详情页即时保存。
5. `pages/SubDetailPage.ets` 操作区下方新增「订阅设置」卡:自动更新开关(关 → 隐藏间隔与仅连接项)、更新间隔输入、仅在 VPN 已连接时更新开关、自定义 UA 输入;`onSubmit` 按 SDK 无参签名取已绑定草稿。
6. `pages/AboutPage.ets` 新增「加入交流群」按钮(对齐安卓 Telegram 项),与项目主页共用 `openLink` 打开系统链接、失败时展示链接供复制。
7. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;9 组订阅设置逻辑(默认值/老备份兼容/UA 回退/间隔边界/自动更新过滤/失败冻结)用 Node 独立脚本验证全部通过,并据此修掉负数间隔回落为 1 的缺陷;base/en_US 字符串键 519=519,双向差异 0;未签名 HAP 已重新生成。
8. 已知限制:自定义 UA 与「仅连接时更新」真机需回归一次(前者验证请求头,后者验证后台任务在断开态确实跳过);交流群链接需真机确认系统有可处理 https/t.me 的能力,否则降级为复制链接提示。

改动文件:entry/src/main/ets/core/Subscriptions.ets、entry/src/main/ets/utils/Subscription.ets、entry/src/main/ets/pages/SubDetailPage.ets、entry/src/main/ets/pages/AboutPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 链式代理循环引用防护(2.0)

> 对齐安卓 `ChainSettingsActivity.testProfileContains/testProfileAllowed` 与 `circular_reference` 提示;此前鸿蒙端可把链节点加入链而形成无限递归。

1. `pages/ProfileEdit.ets` 新增 `chainContains(profile, targetId, visited)` 递归检测:沿 `chainIds` 向下找,`visited` 兜底防止自引用链无限递归。
2. 新增 `chainSelectionAllowed(candidate)`:自身禁选;已选中成员允许取消;「候选包含编辑节点」与「已选成员包含候选」双向都拒绝,比安卓多覆盖一层。
3. 链成员列表:不可选节点置灰(Toggle `.enabled(false)`),强制勾选时弹本地化提示;`validationError()` 保存前再核一遍,防御外部修改 `chainIds` 的场景。
4. 新增中英文资源 `error_circular_reference`。
5. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;9 组环路检测用例(自身/直接环/深层环/已选取消/双向/自引用兜底/菱形依赖不误报)Node 独立脚本全部通过;base/en_US 字符串键 520=520,双向差异 0;未签名 HAP 已重新生成。
6. 已知限制:检测基于内存中的 `allProfiles`,保存前的多级嵌套链在真机需回归一次拖拽与勾选组合。

改动文件:entry/src/main/ets/pages/ProfileEdit.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 导入前确认对话框(2.0)

> 对齐安卓 `MainActivity.importSubscription`/`importProfile` 的 MaterialAlertDialog 确认步骤;此前鸿蒙端粘贴链接即落盘,缺安全提示环节。

1. `pages/Index.ets` 新增 `confirmImport(isSubscription, name): Promise<boolean>`,用 `AlertDialog.show` 的双按钮异步等待用户选择;取消即中止导入。
2. `doImport`:订阅链接在「正在获取订阅」toast 之前弹确认(含来源不可信会泄漏 IP 与网络行为的安全提示,文案与安卓一致);分享链接先解析,解析成功后按单节点名弹确认;取消均直接 return。
3. 新增中英文资源 `import_confirm`、`subscription_import_message`(1 参数)、`profile_import_message`(1 参数)。
4. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 523=523,双向差异 0;未签名 HAP 已重新生成。
5. 已知限制:确认对话框为应用层弹窗,外部 Scheme 唤起(需 module.json5 注册)仍未在本阶段处理;真机需回归一次取消路径确保不落盘。

改动文件:entry/src/main/ets/pages/Index.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 网络变化重置连接(2.0)

> 对齐安卓 `global_preferences.xml` 的 `networkChangeResetConnections`(默认 true)与 `wakeResetConnections`;此前鸿蒙端 Wi-Fi/移动数据切换后旧 socket 全部失效却不重连。

1. `AppSettings` 新增 `networkChangeResetConnections: boolean = true`,并加入 `Backup` 校验白名单(导入备份时允许该字段)。
2. `vpnext/VpnExtAbility.ets` 新增 `registerNetworkChange`/`unregisterNetworkChange`:在 `hookLifecycle` 注册、`onDisconnect`/`onDestroy` 注销。本 SDK 的回调挂在 `NetConnection` 对象上(经 `createNetConnection()` + `register()`),不是自由函数 `on/off`——已按 d.ts 实际签名实现。
3. 事件处理:`netAvailable`/`netLost`/`netCapabilitiesChange` 三类事件统一进 `handleNetworkChange`,`netChangeGeneration` + 1.5s 防抖,连续切换只在最后一次重连一次;重连前重读设置,开关关闭则跳过;`teardown(true)` 后 `tryStart()` 复用既有串行启动队列(防重入与重启嵌套)。
4. `pages/SettingsPage.ets` 外观分组新增开关(带说明)。
5. 新增中英文资源 `network_change_reset_connections`(+sum)。
6. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 525=525,双向差异 0;未签名 HAP 已重新生成。
7. 已知限制:防抖窗口 1.5s 固定(未做设置化);扩展进程被系统回收后监听随之消失,下次启动重建;真机需回归一次切换 Wi-Fi/数据时的自动重连与关闭开关后不重连。

改动文件:entry/src/main/ets/model/Profile.ets、entry/src/main/ets/core/Backup.ets、entry/src/main/ets/vpnext/VpnExtAbility.ets、entry/src/main/ets/pages/SettingsPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 系统返回键行为(2.0)

> 对齐安卓 `MainActivity.onBackPressedDispatcher`:抽屉打开 → 收抽屉;非配置页 → 回配置页;配置页 → 退到桌面(VPN 继续运行)。此前鸿蒙端按返回直接退出应用,VPN 随之断开。

1. `pages/Index.ets` 的 @Entry 结构体新增 `onBackPress(): boolean` 生命周期方法(本 SDK 下该回调**只对 @Entry 组件生效**,不能作为容器属性链使用;`inputConsumer` 的 `keyPressed` 仅支持音量/媒体键,不可用于返回键,已验证 d.ts 后弃用该方案)。
2. 行为:抽屉打开先收抽屉;否则非配置页回配置页;配置页 `context.moveAbilityToBackground()` 退到桌面。
3. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 525=525,双向差异 0;未签名 HAP 已重新生成。
4. 已知限制:仅平板/带返回键设备可触发;手势导航设备由系统直接处理;真机需回归一次「返回 → 退桌面但 VPN 不断」。

改动文件:entry/src/main/ets/pages/Index.ets、entry/src/main/ets/entryability/EntryAbility.ets、CHANGES.md、DEVPLAN.md

## 2026-09-17 导入自定义 Geo 数据文件(2.0)

> 对齐安卓 `AssetsActivity` + `import_asset_menu` 的 `action_import_file`:此前鸿蒙端只能下载内置 cn 库,无法导入用户自备的 geoip.db / geosite.db(内核按名查找的完整库)。

1. `utils/GeoAssets.ets` 新增 `importGeoAssetFromFile(context)`:DocumentViewPicker(`fileSuffixFilters:['.db']`,`maxSelectNumber:1`)选文件 → URI 末段解码取文件名 → 仅接受 `geoip.db`/`geosite.db`(其他名拒绝)→ 流式复制到沙箱 geo 目录覆盖 `geoip-cn.db`/`geosite-cn.db` → 累计 < 1KB 判可疑删除 → 写 `.version.txt = 'Custom'`。用户取消返回 `null`(不报错)。
2. `pages/SettingsPage.ets` geo 卡片新增「导入文件」按钮与提示行,`importGeo()` 成功 toast `geo_import_complete`(含目标路径)、失败 toast `geo_import_failed`(含原因),下载中禁用。
3. 新增资源键 `geo_import_complete`、`geo_import_failed`、`settings_geo_import`、`settings_geo_import_hint`(base+en_US 双写)。
4. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 键 529=529,双向差异 0;未签名 HAP 已重新生成(15,055,240 字节);导入判定逻辑经 Node 脚本 14 项检查全部通过(文件名映射/大小阈值/URI 解码/取消语义)。
5. 已知限制:覆盖的是 cn 命名库;导入完整库后规则模式仍按 geosite:cn/geoip:cn 匹配(内核在完整库中查 cn 分类,行为与安卓一致)。真机需回归一次导入 → 重连 → cn 分流仍生效。

改动文件:entry/src/main/ets/utils/GeoAssets.ets、entry/src/main/ets/pages/SettingsPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 回到前台时重置连接(2.0)

> 对齐安卓 `wakeResetConnections`(设备退出 Doze 闲置模式时 `Libcore.resetAllConnections(true)`)。此前鸿蒙端无此功能。

1. `core/VpnIpc.ets` 新增 `VPN_EVENT_APP_FOREGROUND` 事件与 `publishAppForeground()`(UI → 扩展进程)。
2. `vpnext/VpnExtAbility.ets` 新增 `subscribeForegroundEvents()`(在 `hookLifecycle` 注册,onDisconnect/onDestroy 注销)与 `resetConnectionsAfterWake()`:读设置 → 开关关闭则跳过 → `setPendingProfileId` + `forceRestartRequested = true` + `teardown(true)` + `tryStart()`(复用网络变化重连的同一路径)。
3. `entryability/EntryAbility.ets` 的 `onForeground()` 发布前台事件。
4. `model/Profile.ets` 新增 `wakeResetConnections: boolean = false`(与安卓默认值一致);`core/Backup.ets` 校验白名单已收录。
5. `pages/SettingsPage.ets` 网络重置开关下方新增「回到前台时重置连接」开关 + 说明;新增资源键 `wake_reset_connections`、`wake_reset_connections_sum`(base+en_US 双写)。
6. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 键 531=531,双向差异 0;未签名 HAP 已重新生成(15,064,497 字节)。
7. 已知限制:鸿蒙 SDK 无屏幕亮灭事件订阅(`@ohos.screen` 不存在,`@ohos.power` 仅 `isScreenOn` 查询),用「应用回到前台」近似安卓的「退出 Doze」;默认关闭,需用户手动开启。真机需回归:开启后切应用到后台再回前台应触发一次重连。

改动文件:entry/src/main/ets/core/VpnIpc.ets、entry/src/main/ets/vpnext/VpnExtAbility.ets、entry/src/main/ets/entryability/EntryAbility.ets、entry/src/main/ets/model/Profile.ets、entry/src/main/ets/core/Backup.ets、entry/src/main/ets/pages/SettingsPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 通知刷新间隔可设置(2.0)

> 对齐安卓 `speedInterval`(通知中速率/流量刷新频率,SimpleMenuPreference,默认 1000ms)。此前鸿蒙端固定 1500ms 硬编码。

1. `model/Profile.ets` 新增 `speedIntervalMs: number = 1000`(与安卓默认值一致);`core/Backup.ets` 数值校验白名单已收录。
2. `vpnext/VpnExtAbility.ets` 通知轮询定时器改用 `settings.speedIntervalMs`,并钳制有效范围 `[500, 10000]`,越界/非数回退 1000(防止用户填极端值导致通知狂刷或内核 Clash API 被打爆)。
3. `pages/SettingsPage.ets` 通知分组开关下方新增「通知刷新间隔(毫秒)」数字输入框 + 说明;新增资源键 `settings_speed_interval`、`settings_speed_interval_sum`(base+en_US 双写)。
4. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 键 533=533,双向差异 0;未签名 HAP 已重新生成(15,068,966 字节);钳制逻辑经 Node 脚本 10 项检查全部通过。
5. 已知限制:修改后需重连生效(定时器在启动时读取设置);真机需回归填 500/10000/越界值后通知刷新频率正确。

改动文件:entry/src/main/ets/vpnext/VpnExtAbility.ets、entry/src/main/ets/model/Profile.ets、entry/src/main/ets/core/Backup.ets、entry/src/main/ets/pages/SettingsPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 每节点流量统计与持久化(2.0)

> 对齐安卓 `profileTrafficStatistics`(默认 true):`TrafficLooper.stop` 时把按出站统计的 rx/tx 写回 Profile 数据库,节点卡显示历史累计。此前鸿蒙端只有会话内总量,不落盘、不区分节点。

1. `model/Profile.ets` Profile 新增 `rx`/`tx`(历史累计,默认 0);AppSettings 新增 `profileTrafficStatistics: boolean = true`(与安卓默认值一致)。`core/Backup.ets` 布尔校验白名单已收录。
2. `vpnext/VpnExtAbility.ets` 的 `stopNotificationTrafficPoller()` 在清零前调用新增的 `persistSessionTraffic()`:开关关闭/空 profile/零流量跳过 → `mutateProfiles` 原子读改写把会话下行累加到 `rx`、上行累加到 `tx`(旧负值先归零)→ 发布流量事件通知 UI。
3. `pages/Index.ets` 节点卡第二行新增历史流量文本 `↓rx ↑tx`(用 `formatBytes`),仅在开关开启且累计 > 0 时显示;`import` 补 `formatBytes`。
4. `pages/SettingsPage.ets` 新增「节点流量统计」开关 + 说明;新增资源键 `profile_traffic_statistics`、`profile_traffic_statistics_sum`(base+en_US 双写)。
5. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 键 535=535,双向差异 0;未签名 HAP 已重新生成(15,078,390 字节);累加与显示条件经 Node 脚本 9 项检查全部通过(双向累加/负值归零/零会话跳过/GB 级精度/显示门控)。
6. 已知限制:鸿蒙无内核级按出站统计(libcore `setV2rayStats` 机制),单出站场景下会话总量即当前节点流量;切节点/断开时才落盘,中途查看的是上一会话累计。真机需回归:连接产生流量后断开,节点卡出现累计;再连再断,数字只增不减。

改动文件:entry/src/main/ets/model/Profile.ets、entry/src/main/ets/vpnext/VpnExtAbility.ets、entry/src/main/ets/pages/Index.ets、entry/src/main/ets/pages/SettingsPage.ets、entry/src/main/ets/core/Backup.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 代理服务器域名解析策略(2.0)

> 对齐安卓 `domain_strategy_for_server`(SimpleMenuPreference,默认 auto):解析代理服务器自身域名时的 IP 优先级。此前鸿蒙端的 `route.default_domain_resolver` 固定用 local 服务器且不写 strategy。

1. `model/Profile.ets` 新增 `serverDnsStrategy: string = ''`(空=内核默认,与既有两个 strategy 同一取值域);`model/Store.ets` 的 `sanitizeSettings` 增加该字段白名单兜底,非法值回退 `''`;`core/Backup.ets` 字符串校验白名单已收录。
2. `core/ConfigBuilder.ets` 的 `route.default_domain_resolver` 用 `setIf` 写入 `strategy`(空值不写,等价内核默认)。
3. `pages/SettingsPage.ets` DNS 组在「直连 DNS 域名策略」下方新增第三个 Select(与既有两个共享 `STRATEGIES`/`STRATEGY_LABELS`)+ 说明;新增资源键 `settings_server_dns_strategy`、`settings_server_dns_strategy_hint`(base+en_US 双写)。
4. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 键 537=537,双向差异 0;未签名 HAP 已重新生成(15,083,282 字节)。
5. 已知限制:仅影响代理服务器域名的解析;直连/远程域名策略不受影响。真机需回归:设为 ipv4_only 后,IPv6-only 节点服务器应解析失败(符合预期)。

改动文件:entry/src/main/ets/model/Profile.ets、entry/src/main/ets/model/Store.ets、entry/src/main/ets/core/ConfigBuilder.ets、entry/src/main/ets/core/Backup.ets、entry/src/main/ets/pages/SettingsPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 路由规则升级为多字段 AND 模型(2.0)

> 对齐安卓 `RuleEntity` + `SingBoxOptionsUtil.makeSingBoxRule`。此前鸿蒙每条规则只能单类型匹配(type+value),无法表达「域名 X 且端口 Y」这类组合条件;安卓每条规则有 domains/ip/port/source/sourcePort/network/protocol/packages 字段,AND 组合。

1. `model/RouteRule.ets` RouteRule 扩展为多字段:`domains`/`ip`/`port`/`source`/`sourcePort`/`network`/`protocol`/`packages`/`config`(对齐安卓 RuleEntity 字段名);保留 `type`/`value` 供旧数据迁移。
2. 新增 `migrateLegacyRule()`:仅在旧字段有值而新字段全空时执行 —— domain→`full:` 前缀(旧 type=domain 是精确匹配)、domain_suffix→裸值、domain_keyword→`keyword:`、ip_cidr→ip 裸值、port→port 裸值、geoip→`geoip:` 前缀、geosite→`geosite:` 前缀;`loadRouteRules` 加载时自动迁移并持久化。新增导出 `splitCsv`。
3. `core/ConfigBuilder.ets` 的 `buildCustomRule` 重写为多字段 AND 生成:域名按前缀分发到 `domain`/`domain_suffix`/`domain_regex`/`domain_keyword`/`rule_set`(与安卓完全一致的前缀语义:full:/domain:/keyword:/regexp:/geosite:);IP 的 `geoip:private`→`ip_is_private`、`geoip:x`→合并进 `rule_set`、其他→`ip_cidr`;端口/源端口解析为升序去重数字数组;`network`/`protocol`/`process_name` 按需写入;`config` 为 JSON 浅合并(非法 JSON 忽略,不污染规则);至少一个匹配字段才输出。
4. `pages/RouteRulesPage.ets` 规则卡片的单类型 Select+TextArea 替换为 `ruleMatchSection` 多字段表单:域名 TextArea(含前缀语法提示)、目的IP/目的端口、源IP/源端口、网络/协议 Select、应用包名、自定义配置 JSON、出站三按钮;`updateRule` 扩展 9 个新字段。
5. 新增资源键 12 个(route_rule_domains/hint、ip、port、source、source_port、network、protocol、any、packages、config/hint;base+en_US 双写)。
6. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 键 549=549,双向差异 0;未签名 HAP 已重新生成(15,121,816 字节);域名前缀解析、端口解析、旧规则迁移经 Node 脚本 18 项检查全部通过。
7. 已知限制:`process_name` 匹配需要内核启用 per-app 才能区分进程(当前 per-app 模式下生效);`config` 浅合并不做 schema 校验,用户填错会导致该条规则被内核忽略(已 try/catch 兜底)。真机需回归:旧规则自动迁移且行为不变;新建「域名+端口」组合规则生效。

改动文件:entry/src/main/ets/model/RouteRule.ets、entry/src/main/ets/core/ConfigBuilder.ets、entry/src/main/ets/pages/RouteRulesPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 订阅更新去重开关(2.0)

> 对齐安卓 `subscriptionDeduplication`(SwitchPreference,默认关闭)。此前鸿蒙端**始终**按「类型+服务器+端口+UUID」跳过重复节点,与安卓默认保留全部节点的行为不一致。

1. `core/Subscriptions.ets` 的 `SubInfo` 新增 `deduplication: boolean = false`(与安卓默认值一致);`listSubs` 回填 tolerant 读取;`saveSubSettings` 支持该字段显式写入。
2. `updateSubscription` 的去重逻辑改为 `if (dedupEnabled)` 门控:仅在订阅开启去重时跳过重复节点,关闭时保留订阅返回的全部节点(含重复)。
3. `pages/SubDetailPage.ets` 订阅设置卡片在「仅连接时更新」下方新增「更新时去重」开关 + 说明。
4. 新增资源键 `deduplication`、`deduplication_sum`(base+en_US 双写)。
5. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 键 551=551,双向差异 0;未签名 HAP 已重新生成(15,126,063 字节)。
6. 已知限制:去重键为「类型+服务器+端口+UUID」四元组,与安卓一致;UI 级去重(同名节点)不做。真机需回归:含重复节点的订阅在开/关两种状态下更新结果数量符合预期。

改动文件:entry/src/main/ets/core/Subscriptions.ets、entry/src/main/ets/pages/SubDetailPage.ets、entry/src/main/resources/base+en_US/element/string.json、CHANGES.md、DEVPLAN.md

## 2026-09-17 扫码导入 + 分享二维码 + 订阅强制解析(2.0)

> 收尾三项「曾判为受限」的功能。审计发现本 SDK 的 HMS `@kit.ScanKit` **完整存在**(scanBarcode 系统扫描 UI、generateBarcode 二维码生成),此前「SDK 无 generateBarcode」为误判,一并纠正。

1. **扫码导入**(对齐安卓 `ScannerActivity` + zxing `QRCodeAnalyzer`):
   - `pages/Index.ets` 新增 `scanImport()`:`scanBarcode.startScanForResult(context, {scanTypes:[QR_CODE], enableAlbum:true})` → 结果 `originalValue` 复用现有 `doImport` 管道(容器 Scheme/订阅/分享链接 + 导入确认对话框全部继承)。系统扫描 UI 无需相机权限声明(`module.json5` 未动)。
   - `AddEntryDialog` 在「导入订阅」与「剪贴板导入」之间新增「扫码添加」入口(与安卓 add 菜单同序)。
   - 用户取消(错误码 1000500002 SCAN_SERVICE_CANCELED / 12900010)静默返回;其他失败 toast 提示改用粘贴导入。
2. **分享二维码**(对齐安卓 `QRCodeDialog` zxing 生成):
   - 节点分享:`openProfileShare()` 改 async,`generateBarcode.createBarcode(link, {scanType:QR_CODE,width:440,height:440})` → PixelMap,`ShareTextDialog` 顶部渲染 220×220 二维码(下方保留 URI 文本 + 复制);生成失败自动回退纯文本弹窗。
   - 订阅分享:`SubDetailPage.openSubscriptionShare()` 同样升级(对齐安卓 `GroupFragment.action_universal_qr`),`SubscriptionShareDialog` 增加二维码区。
3. **订阅强制解析**(对齐安卓 `GroupUpdater.forceResolve` + `rewriteAddress`):
   - `core/Subscriptions.ets`:`SubInfo.forceResolve`(默认 false,与安卓一致)+ `listSubs` 回填 + `saveSubSettings` 分支 + `applyForceResolve()`(5 并发批次,镜像安卓线程池):`connection.getAddressesByName` 解析,IPv4 优先、无 IPv4 用 IPv6;TLS 节点原域名回填 `sni` 防断裂;已是 IP/解析失败保留域名并记日志。
   - 插入点:`updateSubscription` 解析订阅内容之后、生成节点 id 之前(与安卓「先 forceResolve 再入库」同序)。
   - `pages/SubDetailPage.ets` 订阅设置卡新增「强制解析」开关 + 说明(位于「更新时去重」下方)。
4. 新增资源键 5 个:`add_profile_methods_scan_qr_code`、`scan_no_content`、`scan_failed_use_paste`、`force_resolve`、`force_resolve_sum`(base+en_US 双写;键名沿用安卓 strings.xml)。
5. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 键 556=556,双向差异 0;未签名 HAP 已重新生成(15,150,535 字节);强制解析判定逻辑经 Node 脚本 15 项检查全部通过(IP 判定/IPv4 优先/SNI 回填门控);UI 硬编码文案扫描 TOTAL_HITS=0。
6. 已知限制:扫码用系统扫描 UI 而非自定义相机页(鸿蒙无对应开源 zxing 相机管线,系统 UI 为官方推荐且免相机权限);`enableAlbum` 允许相册识码(安卓仅相机,此处为超集);selector/urltest 分组经实证确认被 `.so` 冻结阻挡(`lean_context.go` 未注册 `protocol/group`),不在本轮范围。真机需回归:扫订阅码/节点码导入、两处分享弹窗出码、强制解析开/关的更新结果。

改动文件:entry/src/main/ets/pages/Index.ets、entry/src/main/ets/pages/SubDetailPage.ets、entry/src/main/ets/core/Subscriptions.ets、entry/src/main/resources/base+en_US/element/string.json、PARITY.md、CHANGES.md、DEVPLAN.md

## 2026-09-17 功能/UI 对照清单(交付物)

> 新增 `PARITY.md`:Android 与鸿蒙逐项对照清单,含全局设置 39 项、分组设置 13 项、路由规则 12 项、13 种协议编辑页、15 个页面/交互的完整对照,以及明确排除项理由和真机回归清单。

改动文件:PARITY.md、CHANGES.md

## 2026-09-17 严格复刻首批修复（整体任务仍进行中）

- showBottomBar：新增默认false的设置/备份校验，StatsBar按连接和页面门控，FAB可按开关跨页保留；滚动防遮挡和外观尚未复刻。
- ConfigBuilder：目的/源端口范围不再被parseInt截断；DNS auto归一化；resolve移至IP规则前。
- 验证：生产ETS测试13项通过；另以同一服务器DNS断言对内存还原的旧语句验证预期失败，对当前代码验证通过（auto→prefer_ipv4）；最终assembleHap exit 0。未连接hdc设备，未做真机/像素验证。
- 文件：entry/src/main/ets/model/Profile.ets、core/Backup.ets、core/ConfigBuilder.ets、pages/Index.ets、pages/SettingsPage.ets（后四路径同属ets）；resources/base与en_US/element/string.json；tests/parity-config.cjs；docs/PARITY-REAUDIT.md；PARITY.md、DEVPLAN.md、CHANGES.md。
- 未更改签名/版本/内核成品，保留既有未提交修改。已知剩余差异见重新审计清单，不再把历史勾选视为1:1验收。

## 2026-09-17 CORE-04 内核重编与 CORE-03 备份回归修正

- CORE-04：使用已有 Go 1.26.5 主机工具链和 OHOS fork 成功重编 libsingbox.so（35,659,280 字节），重新打包；构建脚本固化 sniff override 字段/接线校验，取消 git config 写操作。保留既有 CGo 契约，不改签名/版本。
- 新增主机回环实连接测试：相同 HTTP 请求下 route 命中原始 IP，override 命中 Host 对应 IP；另测试 JSON 字段 true/false 到运行时接线。尚无设备端或 HAP 安装验收。
- CORE-03：撤回“全链路完成”。Backup 的 ipv6Mode 错列布尔字段造成正常导出后不能恢复；真实 export/import 红色测试复现后移至字符串字段，六个字符串往返通过，非字符串拒绝且没有持久化写入；空串/旧布尔备份兼容。auto 仅作为兼容字符串保留，不是新增四档选项。
- 文件：core/scripts/build-libsingbox-ohos.sh、entry/libs/arm64-v8a/libsingbox.so（含流水线生成的 header/vendor）；tests/hostprobe/probe_test.go、sniff_behavior_test.go；entry/src/main/ets/core/Backup.ets；tests/ipv6-backup.cjs、ipv6-modes.cjs；docs/PARITY-REAUDIT.md、DEVPLAN.md。
- 剩余：服务器 auto、ONLY 平台 IPv4 路由、core 地址前缀、FakeDNS 旧布尔、resolve 策略仍需修正；相关已有测试的错误预期不能作为验收。

## 2026-09-17 生产 DNS 启动组合与 Store 保存校验

- 生产生成器输出四模式 × FakeDNS 开关八组 DNS 配置，仅移除测试传输 detour，其余 DNS 字段原样交给 1.14。修复前 FakeDNS 四组全部因 strategy/query_type 跨规则混用而启动失败；修复后八组通过。删除 FakeDNS 兜底新增 query_type，恢复 Android 原 inbound 条件，并将 fake 的 ipv4_only/disable_cache 放到选择规则。保留 1.14 兼容模式，不冒称“旧策略语义无法实现”；1.16 迁移另列待办。
- Store 实际 saveSettings/loadSettings 测试先复现非法模式 bogus 原样落盘，再以单一 helper 在读/写处归一化；保存副本避免修改 UI 入参，保留旧布尔与合法模式。不重构其它设置校验。
- 验证：32 项生产配置断言、9 项 IPv6 检查（平台部分仍是接线检查）、备份往返及实际 Store 测试通过；Go 全套连续三轮通过，期间一次回环连接重置单独复跑未复现，仍记录稳定性风险。assembleHap exit 0；未签名、无设备/UI 完整验收。
- 文件：entry/src/main/ets/core/ConfigBuilder.ets、model/Store.ets；tests/ipv6-store.cjs、generate-dns-fixtures.cjs、hostprobe/production_dns_test.go、hostprobe/fixtures/production-dns.json；DEVPLAN.md、CHANGES.md。

## 2026-09-17 路由规则协议多值（CORE-05 部分）

- Android ConfigBuilder.kt:543-544 的 protocol 是 listByLineOrComma 数组并保留同条规则其它 AND 字段；此前鸿蒙只接受 'dns' 单值。现 ConfigBuilder 用 splitRuleList 生成 protocol 数组，RouteRule 加载不再把非 DNS 值清空（注释同步更新），规则页协议从 DNS-only 下拉改为多值 TextArea（占位 http, tls, quic, dns）。
- 验证：生产配置断言先复现 protocol 字段缺失（undefined），修复后 `http, tls\r\ndns` + port 443 输出 protocol:['http','tls','dns'] 与 port:[443] 同条规则；tests/ipv6-store.cjs 扩展真实 saveRouteRules/loadRouteRules 往返，协议与端口均保留。33 项配置测试、Store/备份/IPv6 测试与 assembleHap（exit 0）通过；无设备/UI 完整验收。
- 文件：entry/src/main/ets/core/ConfigBuilder.ets、model/RouteRule.ets、pages/RouteRulesPage.ets；tests/parity-config.cjs、tests/ipv6-store.cjs；DEVPLAN.md、docs/PARITY-REAUDIT.md、CHANGES.md。
- 剩余（CORE-05/06）：任意 profileId 出站、ProfileGroup selector/frontProxy/landingProxy 组级代理。

## 2026-09-17 路由内置规则顺序与组播（CORE-08）

- 安卓 ConfigBuilder.kt:600 用户规则先入 route.rules，:697-702 私网绕过（ip_is_private=true，内核内置判定）与 :704-708 组播独立 reject（ip_cidr+source_ip_cidr 同置 224.0.0.0/3、ff00::/8）在其后追加，且不随模式限定。鸿蒙此前把 12 段 CIDR 私网清单（含组播段）作为 direct 规则放在用户规则之前且仅 rule 模式。现改为：用户/自定义/geo/远程规则之后追加内置 ip_is_private direct（随 bypassLan 开关）与组播 reject（独立于开关）。
- 验证：红测试先复现私网 direct 排在用户规则前且无组播拒绝，修复后 findIndex 顺序 user < lan < multicast、组播字段与安卓逐字段一致；bypassLan=false 仍有组播拒绝。38 项配置断言 + 生成器 DNS fixtures 重新生成 + modes/store/backup/kernel 全绿。

## 2026-09-18 二轮深度排查：文件导入/WG zip、规则排序、分应用剪贴板、移动到分组、geo 单库管理（2.0）

> 对安卓全部 `menu/*.xml`（add_profile / per_app_proxy / app_list / group_action / profile_share / import_asset / scanner / add_route）与 `RouteFragment`、`AppListActivity`、`AssetsActivity`、`ProfileSettingsActivity` 逐项复查后补齐的五个缺口。

1. **从文件导入（含 WireGuard zip）**——对齐 `ConfigurationFragment.action_import_file` + `parseRaw` zip 分支：`Index.importFromFile()` 用 DocumentViewPicker（任意文件，同安卓 `*/*`）→ 复制缓存 → 文本直接复用 `doImport` 全管道（base64 订阅/分享链接/sing-box JSON/.conf + 导入确认）；`.zip` 用 `zlib.decompressFile` 解压后逐 entry `parseShareText`，entry 文件名（剥 `.conf/.txt/.json`，大小写不敏感）作节点名，单次「导入 N 个节点」确认批量入库；空结果 `no_proxies_found_in_file`、异常 `import_file_failed`。`AddEntryDialog` 按钮顺序对齐安卓 add_profile_menu（订阅/扫码/剪贴板/文件/手动）。
2. **路由规则优先级调整**——对齐 `RouteFragment` ItemTouchHelper 拖拽：`RouteRulesPage.moveRule/moveRemoteRuleSet`（swap + 边界守卫），两张列表首行 ↑↓，首/末位 `text_disabled` 置灰。
3. **分应用列表剪贴板导出/导入**——对齐 `AppListActivity`：payload 完全一致 `false\n<包名列表>`；导入无换行/空内容报 `action_import_err`，成功整体替换并走 `persistPerAppList` 自动重启链路；反选/清除下方新增同排两按钮。
4. **节点归属分组管理**——节点长按菜单「移动到分组」`MoveToGroupDialog`（未分组 + 全部分组、当前组高亮、即选即存）+ `ProfileEdit` 基础区分组 Select（`groupOptions/groupSelectedIndex/groupCurrentValue`，分组被删回显未分组）。
5. **geo 资产单库管理**——对齐 `AssetsActivity` 列表：`GeoAssets.geoAssetInfos()/downloadGeoAsset(kind)/deleteGeoAsset(kind)`；设置页 geo 卡片渲染每库「名称 + 大小·版本 / 未下载」+ 单库「更新」+ 单库「删除」（二次确认）。差异：删除无撤销 Snackbar，以确认对话框代替。
6. **sn:// 私有格式识别扩展**——`isSagerNetSubscriptionContainer` 从 `sn://subscription?` 放宽到任意 `sn://` 前缀（含 universal link `sn://<type>?...`，Kryo 序列化不可解包），导入时明确拒绝提示。
7. 新增资源键 16（base+en_US 双写）：action_import_file、no_proxies_found_in_file、import_file_message/failed、export/import_selections_clipboard、action_export_msg/err、action_import_msg/err、move_to_group(_title/_done)、profile_group、settings_geo_site/ip、geo_asset_status/absent、settings_geo_update_one/updated/delete/_confirm/_deleted/_delete_failed。
8. 验证：hvigor assembleHap `BUILD SUCCESSFUL`；base/en_US 键 **586=586** 双向差异 0；未签名 HAP 重新生成（15,262,692 字节）；Node 脚本 25 项逻辑检查全部通过（swap 边界/entry 名剥离/sn:// 前缀识别/剪贴板格式）；UI 硬编码文案扫描 TOTAL_HITS=0。
9. 已知限制：zip 导入假设平铺 entry（WG 官方导出即平铺）；单库删除不通知运行中内核（重连后生效，缺库时内核自动跳过 cn 分流）。
10. 本记录同时确认前夜批次（ipv6Mode 四档、showBottomBar、CORE-01~05/07/08、内核重编）见上文各节；`docs/PARITY-REAUDIT.md` 为当前权威缺口清单（CORE-05 任意 profileId 出站、CORE-06 组级 selector/前后置、CORE-07 JSON 深合并、DEF-01/02、UI-01~06 待办）。

改动文件：entry/src/main/ets/pages/Index.ets、pages/RouteRulesPage.ets、pages/SettingsPage.ets、pages/ProfileEdit.ets、utils/GeoAssets.ets、utils/Subscription.ets、resources/base 与 en_US/element/string.json、PARITY.md、CHANGES.md、DEVPLAN.md

## 2026-09-18 CORE-05/06 UI 闭环与 DEF-01 默认值对齐（2.0）

> 按 `docs/PARITY-REAUDIT.md` 待办处理:两项「后端已就绪但无 UI 入口」的功能补齐配置界面,一组默认值对齐安卓源码。

1. **路由规则「指定节点」出站**(CORE-05 剩余):`pages/RouteRulesPage.ets` 出站行加第四按钮「指定节点」——首次点击选中首个节点生成 `profile:<id>`,再点回 `proxy`;profile: 态下显示「目标节点」Select(首项代理=取消;节点被删显示「节点已删除」)。ConfigBuilder 的 `profile:` 解析、引用出站图构建、活跃节点别名 `proxy` 均已存在,未改。
2. **分组设置**(CORE-06 剩余):`pages/GroupPage.ets` 手动分组卡加「分组设置」内联展开——use_selector 开关、front_proxy/landing_proxy 节点 Select(「无」+ 全部节点,格式 `名称 (服务器)`)、保存/取消;保存后若运行节点属该组,`VpnService.switchTo(runningId)` 自动重载配置(对齐安卓组设置变更即 reload)。ProfileGroup 三字段、ConfigBuilder selector 出站/前后置图、内核 `group.RegisterSelector`(lean_context.go,`.so` 已重编)此前已就绪。
3. **DEF-01 默认值**:`model/Profile.ets` AppSettings——mtu 1400→9000、mixedPort 0→2080、bypassLan true→false(分别对齐安卓 `DataStore.kt:105/129/107`);`model/Store.ets` MTU 钳制上限 1500→9000。仅影响新装默认,既有设置不迁移。
4. DEF-02 中 remoteDns/directDns(DoH)、fakeDns=true 维持现状:system 栈 DoH/FakeIP 未经真机验证,按 reaudit 自身口径「结合内核/平台能力恢复默认值,避免未经验证切断现有连接」保留,注释中注明依据。testUrl 维持 gstatic(AGENTS.md 产品决策)。
5. 新增资源键 16(键名沿用安卓 strings.xml):group_settings、group_settings_saved、use_selector(_sum)、front_proxy、landing_proxy、option_none、route_outbound_profile(_active)、route_rule_profile_target/missing、route_no_profiles(base+en_US 双写)。
6. 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 键 **598=598** 双向差异 0;既有生产代码测试全绿——`tests/parity-config.cjs` 38 项、`tests/outbound-graph.cjs` 9 项(含 selector 生产注册断言)、`ipv6-modes/backup/store.cjs` 全部;未签名 HAP 重新打包。
7. 已知限制:selector 热切换仍走配置重建(安卓经 Clash API select 免重载),差异已记 reaudit;真机回归:开启 selector 后组内核含 selector 出站、切换组成员重连正常;设置前/落地代理后流量路径正确;新装 MTU=9000/mixed=2080 下连接稳定。

改动文件:entry/src/main/ets/pages/GroupPage.ets、pages/RouteRulesPage.ets、model/Profile.ets、model/Store.ets、resources/base 与 en_US/element/string.json、docs/PARITY-REAUDIT.md、CHANGES.md、DEVPLAN.md

## 2026-09-18 版本统一 2.0.1 与带签名 .app 打包(2.0)

1. 版本:`AppScope/app.json5` versionName **2.0 → 2.0.1**、versionCode **2000000 → 2000001**(关于页/版本显示均动态读取 bundleManager,无其它版本字面量残留;`assembleApp` 产物 `pack.info` 复核 bundleName=com.nekobox.app.jynxen、version 2.0.1/2000001)。
2. 构建:`assembleHap` + `--mode project assembleApp` 均 `BUILD SUCCESSFUL`;未签名 app 为 `build/outputs/default/NekoBox4Harmony-publish-1.9.1-default-unsigned.app`(13,586,265 字节)。
3. 签名:经项目 `签名材料`(NekoBox.p12 别名 nekobox + NekoBox.cer + NekoBoxRelease.p7b)用 SDK `hap-sign-tool sign-app`(SHA256withECDSA,compatibleVersion 24)完成双层签名——先签内层 `entry-default.hap`(14,288,233 字节,重打包后壳再签)。口令仅用于命令行进程,未写入 `build-profile.json5`、脚本或仓库任何文件,签名后临时目录已清理。
4. 校验:`hap-sign-tool verify-app` 对内层 HAP **Verify success**(Hap Signing Block v3,3 blocks);签名 profile 解出 **type=release、bundle-name=com.nekobox.app.jynxen**,与此前 1.9.x 正式签名同一身份,可覆盖升级。
5. 产物:**`dist/NekoBox-2.0.1-signed.app`**(13,608,082 字节,SHA256 `A2DDC21ABD74F7A13FC7FC6A1C235F66476E7184E5F08C3AAD70FA946CEDF265`),含本轮全部 1:1 移植(CORE-05/06 UI 闭环、DEF-01 默认值、扫码/二维码/强制解析、文件导入、geo 单库管理等)。
6. 已知限制:release profile 含 udid 白名单(设备需已注册进 AGC 调试/发布设备列表,与此前 1.9.x 一致);`.hvigor`/IDE 无残留签名配置。

改动文件:AppScope/app.json5、dist/NekoBox-2.0.1-signed.app(新产物)、CHANGES.md、DEVPLAN.md、PARITY.md

## 2026-09-18 共存修复 2.0.2(与 SSRVPN 等 Clash/mihomo 系应用同机共存)

真机事故:设备同时装 NekoBox 2.0.1 与 SSRVPN 时,SSRVPN 启动 VPN 必然失败(9090 控制器端口互踩 + 唯一 VPN 会话槽位被抢,2.0.1 新增的网络变化强制重连把双方拖进互踢环)。本版在 ArkTS 层修复,不动内核与 module.json5:

1. `networkChangeResetConnections` 默认 **true→false**(Profile.ets):鸿蒙的 netAvailable/netCapabilitiesChange 也会被其它 VPN 应用建/拆隧道触发,强制重连=抢会话槽位;物理网络切换的连通性恢复本就由内核路由与 protectProcessNet 承担。另在 resetConnectionsAfterNetworkChange 加 15s 最小间隔,即便用户在设置页显式开启,也不会被连环事件拉进重连风暴。
2. `clashApiPort` 默认 **9090→19290**(Profile.ets,对齐 TrafficStats 既有常量,落在 mihomo 系候选端口带 9090/19090/29090 之外):两应用共存时控制器端口互踩是 SSRVPN「内核已启动但 API 探测失败」的直接根因。
3. Store.loadSettings 新增一次性迁移(coexistFix202609Applied 标记落盘,不重复执行):存量 9090→19290;2.0.1 默认写入的 networkChangeResetConnections=true 回滚一次为 false;用户此后在设置页的显式选择永久保留。
4. 通知发布失败退避(VpnExtAbility):通知被系统关闭时不再以 speedInterval(1s) 无限重试与刷日志,连续 5 次失败停用周期通知(流量事件与节点统计不受影响),新会话重新启用。
5. 版本:2.0.1/2000001 → **2.0.2/2000002**;产物 `dist/NekoBox4Harmony-2.0.2-unsigned.hap`(按 AGENTS 约定签名由用户自理)。

改动文件:entry/src/main/ets/model/Profile.ets、entry/src/main/ets/model/Store.ets、entry/src/main/ets/vpnext/VpnExtAbility.ets、AppScope/app.json5、CHANGES.md

