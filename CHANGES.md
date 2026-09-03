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
