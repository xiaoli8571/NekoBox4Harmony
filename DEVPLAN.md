# NekoBox for Harmony 开发计划(G 阶段,目标版本 1.6.0)

## 严格1:1重新审计（2026-09-17）—— 状态：进行中，首批修复通过主机测试与构建

- 当前任务以用户要求的非Android独有功能/UI严格复刻为准；下方旧阶段结论仅作历史，不是本次验收。
- 首批：showBottomBar基本跨页/连接门控与持久化、端口范围输出、DNS auto归一化、resolve执行顺序。
- 最新验证：CORE-04 已交叉编译 .so 并重新 assembleHap（exit 0）；主机回环实连接区分 route/override。HDC 当前有设备，但尚无本轮设备行为或视觉验收。
- CORE-03：仍未完整验收。Backup 字符串校验已修；server auto 固定 prefer_ipv4、resolve 按模式、平台 ONLY 保留 IPv4、FakeDNS 两段地址已实施。Store 新增实际保存/重载测试，非法 ipv6Mode 写入前归一化；core 地址前缀、平台 bypass/DNS 地址和设备行为仍待核对。
- DNS 启动回归：生产生成的四模式 × FakeDNS 开关八组 DNS 块（仅隔离传输 detour）复现 FakeDNS 开启时全部失败；删除新增 query_type 混用，按 Android 原入站规则将 ipv4_only/disable_cache 写到 fake 选择规则后八组通过。1.14 兼容模式保留 legacy strategy，不是“该语义无法表达”；1.16 迁移仍待办。主机 Go 全套连续三次通过，之前一次回环重置未复现，仍记录稳定性风险。
- CORE-05 部分：协议列表按 Android ConfigBuilder.kt:543-544 逗号/换行拆分，保留同条规则其它 AND 字段；RuleRule 加载不再丢弃非 DNS 协议，页面改为多行输入。生产配置测试从 undefined 红灯到协议数组通过，真实 Store/RouteRule 保存重载通过。
- CORE-07：深合并已实施（Android Util.kt:129-158 语义）。新增 deepMerge 导出函数（对象递归、+key 前插、key+ 后插、其余覆盖）+ parseUserJson（非法/非对象输入返回 null 调用方忽略），替换节点 extra、规则 config、全局 globalCustomConfig 三处浅合并；buildOutbound 导出供测试。生产测试红→绿：规则深合并+列表操作、extra 与生成 mux 块嵌套合并（协议字段保留+覆盖+新增同验）、全局合并保留生成子字段。36 项配置测试及其余主机测试通过；首轮 assembleHap 因 parseUserJson 隐式 any 失败，现补显式类型，正在重新编译。此前提前记 exit 0 已纠正。
- CORE-08：内置路由顺序已对齐安卓 ConfigBuilder.kt:600,697-708。用户/自定义/geo/远程规则先入，私网绕过改用内核 ip_is_private 判定（随 bypassLan），组播 224.0.0.0/3+ff00::/8 目的/源独立 reject（不随开关/模式），均追加在用户规则后。红→绿：findIndex 断言 user < lan < multicast、组播字段逐项一致、bypassLan=false 仍拒绝组播。38 项配置断言与全部主机套件通过。
- 源码证据、已知缺口及后续任务见 `docs/PARITY-REAUDIT.md`。分组分页、滚动防遮挡、主题/节点卡、完整 DNS/VPN 行为、任意节点出站及组级代理仍需完成。


> 当前基线:1.5.8(versionCode 1001800,2026-09-03,commit eb35129)。**F 阶段 F1~F7 已全部交付(F7 已真机验收;F2~F6 待日常复核,勿重做)**;本阶段开发 G1~G6,目标版本 1.6.0。建议顺序:**G6 → G1 → G2 → G3 → G4 → G5**(G5 风险最高放最后)。**交付模式(用户 2026-09-03 指定):G6 已单独交付;剩余 G1~G5 由开发 agent 一次性全部开发完成后再统一交付构建,不分阶段**——但每完成一项仍须立即同步该项 DEVPLAN 状态行与 CHANGES.md 记录,全部完成后一次性汇报"已完成 G1~G5,请构建"。
> 详细架构见 `AGENTS.md`,上一阶段实现记录见 `CHANGES.md`,先读这两个文件与下方铁律/踩坑。

## 铁律(违反即返工)

1. **内核冻结**:不改 `core/`、不改 `entry/libs/arm64-v8a/libsingbox.so` 与 CGo 接口(CGoStartSingBox / CGoStopSingBox / CGoSetTunFd / CGoSingBoxVersion)。所有功能只写在 `entry/src/main/ets/` 与资源层
2. `module.json5` 的 `"type": "vpn"` **永远不动**;**G 阶段不允许任何 module.json5 改动**(G4 远程规则集、G5 clash_api 均无需新权限:INTERNET 已有,clash_api 只监听 127.0.0.1)
3. `build-profile.json5` 的 `signingConfigs` 保持 `[]`;`AppScope/app.json5` 版本号由构建机管理,不改
4. 不碰 `entry/build/`、`dist/`、`.hvigor/`;**不执行任何 git 写操作**(`git status/diff/show/log` 只读可用);不启动构建/打包
5. 行尾保持 LF;`hvigorw.js` 的 `__ohosCmdPatch` 补丁勿覆盖
6. **文档同步义务(硬性)**:每完成/部分完成/降级一项,必须立即 ①更新本文件该项"状态"行,②在 `CHANGES.md` 末尾按既有格式追加(日期、功能、改动文件列表、已知限制)。**文档未同步视为该项未完成**

## 踩坑记录(前人踩过,先读)

1. **禁止把 `$r()` 写进模板串**(`${$r(...)}` 运行时渲染为 [object Object]):动态整句进 string.json 用 `%1$s`/`%1$d` 占位符,代码 `$r('app.string.x', args)`;返回可能为资源的函数声明 `ResourceStr`/`ResourceColor` 而非 `string`;`$r` 键名编译期校验,拼错直接编译失败
2. `AppStorage('vpnStatus')` **只存机器状态键**(connecting/disconnected/switching/awaiting_auth/start_timeout/`connected:<节点>`/`start_failed:<详情>`/`connect_failed:<详情>`),显示由 `Index.statusDisplay()` 映射;不要写用户可读文案进 vpnStatus
3. 函数参数不能声明 `unknown`(arkts-no-any-unknown);`catch (e)` 传辅助函数前先转字符串
4. `Row`/`Column` 没有 `.stateEffect()`;按压反馈用 `.hoverEffect()`+`.scale()`+animateTo;并排按钮行一律 layoutWeight(1) 等分(F7 真机验证过的防溢出写法);日志页固定终端配色是刻意设计,不要改
5. API 24 的 `@ohos.bundle.bundleManager` 无 `getAllBundleInfo`,枚举已装应用用旧模块 `@ohos.bundle`(`GET_BUNDLE_DEFAULT`)
6. 布局限定宽高用 constraintSize 时,**内层包装 Column 必须同时有 `.width('100%').height('100%')`**,否则内容测量超宽(F7 真机踩过)
7. OHOS 拿不到 netlink 默认网卡:内核 route/network.go 已有 openharmony 早退分支,出站绑定走 net.InterfaceByName——内核冻结,勿动
8. `hvigorw.js` 的 `__ohosCmdPatch` 勿覆盖;构建前必须把 DevEco JBR 加入 PATH(`export PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"`),否则 PackageHap 报 00308018
9. `entry/libs/arm64-v8a/libsingbox.so` 是冻结内核成品,严禁删改;丢失会构建出 2MB 无内核坏包
10. 新 API 不确定是否存在于本机 SDK 时,先写降级路径并在 CHANGES.md 注明;构建机编译前会用本机 d.ts 预检

## G6 通知栏文案资源化(小项,先做)—— 状态:✅ 已完成(2026-09-03,versionCode 1001801,编译通过;通知字段在本机 SDK 为 string 类型,经 resourceManager.getStringSync 现取本地化字符串)

- `vpnext/VpnExtAbility.ets` 的通知文案(当前节点·延迟、断开中、等待授权、channel 名称等)仍硬编码中文;全部改 `string.json` 资源($r 在同模块 extension 内可用),base/en_US 双份
- 约束:经 CommonEvent 传递的状态键保持机器键;通知 layout/按钮行为不变
- 改动:`vpnext/VpnExtAbility.ets`、`resources/base|en_US/element/string.json`
- 验收:系统切英文后通知栏(标题/文本/按钮/channel)全英文;中文环境无回归

## G1 节点手动排序(置顶已有,补排序)—— 状态:已完成,待统一构建验证

- 现状:`pinned` 置顶已存在;本项补**手动排序**——节点长按菜单加"上移/下移",写回 `Profile.sortOrder`;`sortedProfiles()` 优先级改为 置顶 → 手动顺序 → 现有延迟兜底
- 排序模式切换(手动 / 按延迟 / 按名称)放设置页"外观与交互"或首页顶栏,偏好入 `AppSettings`(model/Profile.ets + Store.ets,含默认值与备份兼容)
- 改动:`pages/Index.ets`、`model/Profile.ets`、`model/Store.ets`、`pages/SettingsPage.ets`、`core/Backup.ets`(如涉字段)、`resources`
- 验收:手动排序重启/重进保持;三种模式切换即时生效;不同分组内排序互不干扰

## G2 分组测速汇总 —— 状态:已完成,待统一构建验证

- 分组头显示组内**最低延迟徽标**(如"最低 86ms";全超时显示"超时";有未测节点显示"n 未测")+ "测速本组"按钮(只测组内节点,复用 utils/LatencyTester,防并发与全局测速互斥)
- 徽标随测速回调实时刷新;折叠状态下组头同样可见
- 改动:`pages/Index.ets`、`utils/LatencyTester.ets`(按组过滤)、`resources`
- 验收:测速本组只影响组内节点;徽标数字与节点行一致;折叠/展开均正常显示

## G3 节点分享二维码 —— 状态:已完成（纯文本 URI + 复制降级）,待统一构建验证

- 节点长按菜单加"分享二维码":优先用 `@kit.ScanKit` 的 generateBarcode 生成分享 URI(`utils/exportProfileLink` 已有)二维码弹窗展示;**构建机预检本机 SDK d.ts,若不可用则降级为纯文本 URI 弹窗 + 复制按钮**,降级必须在 CHANGES.md 记录
- 订阅详情页(SubDetailPage)加"分享订阅链接"入口(同方案)
- 二维码弹窗用 CustomDialog,深浅色底色确保可扫(白底黑码固定)
- 改动:`pages/Index.ets`(或新 ShareDialog 组件)、`pages/SubDetailPage.ets`、`resources`
- 验收:弹出的二维码能被系统扫一扫识别出正确 URI;降级路径可用;分享不落盘、关闭即释放

## G4 远程规则集订阅 —— 状态:已完成,待统一构建验证

- 规则页新增"远程规则集"管理区块:名称 + URL(.srs)+ 类型(site/ip)+ 出站(直连/代理)+ 启用开关;数据入 `model/RouteRule.ets` 扩展(或独立 model,保持备份 schema 兼容——版本号递增并兼容读 v3)
- `core/ConfigBuilder.ets` 输出 sing-box 1.11 `route.rule_set`(remote)定义与 `route.rules[].rule_set` 引用;设置合理下载超时与 `download_detour`;内核拉取失败时跳过该集合并写内核日志,不影响启动
- UI 显示每个规则集最近更新时间/最近错误;开关即时生效(重连后生效提示沿用现有文案)
- 改动:`pages/RouteRulesPage.ets`、`model/RouteRule.ets`、`core/ConfigBuilder.ets`、`core/Store.ets`、`core/Backup.ets`、`resources`
- 验收(真机):添加规则集 → 连接后分流按 .srs 生效;断网时连接不因规则集失败而失败;备份/恢复包含规则集
- 注意:sing-box 1.11 的 rule_set 为 1.8+ 特性,内核支持确认无误;**不得为它改内核**

## G5 连接统计(clash_api,风险项,最后做)—— 状态:已完成,待统一构建验证

- `core/ConfigBuilder.ets` 打开 `experimental.clash_api`(external_controller `127.0.0.1:9090`,随机 secret 存设置)+ `experimental.cache_file`;端口与开关进设置页,默认开启
- `pages/ConnectionsPage.ets` 改造:VPN 运行时每 1s 轮询 `http://127.0.0.1:9090/connections`(带 Authorization: Bearer secret),展示实时上下行速率、总流量、活跃连接列表(目标域名/规则链/上下行字节数),支持单条连接关闭(DELETE /connections/:id);未运行显示现有空态
- 轮询计时器必须在页面隐藏/VPN 断开时停止(onPageHide/状态监听),防泄漏
- 改动:`core/ConfigBuilder.ets`、`pages/ConnectionsPage.ets`、`model/Profile.ets`(设置项)、`model/Store.ets`、`resources`
- 验收(真机,风险项):c-shared 模式下 clash_api 可访问且需鉴权;速率与系统统计量级一致;关闭连接生效
- **降级路径必须实现**:clash_api 不可用时保留现有 TUN 总速率展示,CHANGES.md 记录原因与内核日志摘录

## G7 VPN 重连稳定性与模式即时生效 —— 状态:已完成开发,待构建与真机验证

- 修复节点切换竞态:不再执行“停止扩展 + 固定等待 1.5 秒 + 重新启动”,改为把最新节点请求交给现有 VPN 扩展实例串行处理。
- 扩展启动期间收到的新节点或模式重启请求不再丢弃,而是合并为最新请求并在当前操作结束后继续处理。
- 60 秒看门狗不再自动断开可能已正常工作的 VPN;控制面状态丢失时保留数据面并记录诊断日志。
- 规则、全局、直连模式点击后立即持久化;VPN 正在运行时自动使用当前节点重启并加载新配置。
- 全局模式仅保留 DNS 劫持规则,不加载私网直连、自定义路由、Geo 分流或远程规则集,普通流量统一走 `proxy`。
- 改动:`core/VpnService.ets`、`vpnext/VpnExtAbility.ets`、`pages/SettingsPage.ets`、`core/ConfigBuilder.ets`。
- 验收:运行中连续切换节点不永久停在 `connecting`;断开后换节点可正常启动;模式切换自动重启并生效;全局模式生成配置中无普通流量直连规则;状态广播丢失时看门狗不得误断正常数据面。

## F 阶段交付一览(已完成,勿重做)

- F1 深色主题/外观即时生效;F2 通知延迟+断开按钮;F3 订阅后台更新;F4 per-app 图形选择器(legacy @ohos.bundle);F5 备份文件化;F6 中英双语 264 键(含 `${$r}` 混用全仓清理、vpnStatus 机器键协议、Backup 机器错误键);F7 鸿蒙原生观感(UiSpec 规格、色值令牌 21 项、等分分段按钮、全宽 + 16vp 页边距、状态栏跟随主题)——细节见 `CHANGES.md` 与 Notion 开发文档

## 完成标准与交付

1. 每项自查:引用/导入完整、与现有 model/pages 接口一致、对照 `pages/Index.ets` 风格;无新增硬编码色值/硬编码中文(F6 惯例)
2. `CHANGES.md` 逐项追加;`DEVPLAN.md` 状态行同步;G3/G5 的降级路径必须有记录
3. 全部完成后构建机升 versionName 1.6.0、打 GitHub release;G4/G5 真机风险点写入 release notes
4. 不构建、不 commit;等构建机编译反馈,有错误按反馈修复

> 通知栏占位符修复（2026-09-03）：本机 SDK 的 `resourceManager.getStringSync` 未展开带参数资源，真机原样显示 `%1$s.%2$s`。通知副标题现改为代码直接拼接 `${nodeName} · ${latencyText}`，避免占位符泄漏；待构建与真机验证。

## U1 首页重构 —— 状态：B 方案已完成静态交付，待构建机验证

- 已完成方案 A 鸿蒙原生卡片流首页改造，新增 `BigPowerButton`、`MiniStatCard`、`ToggleRow`，并复用既有 `AppStorage('vpnStatus')`、`Index.statusDisplay()`、`AppSettings` 与 `saveSettings()` 状态链路。
- 保留节点选择、VPN 启停、导入、新增与编辑、测速、分组测速、折叠、手动排序、置顶、分享、per-app 入口，以及连接、日志和设置入口。
- 已完成 JSON 语法、base/en_US 文案键一致性及 `git diff --check` 静态检查；未构建、未打包、未执行 Git 写操作。
- 连接中旋转 loading、状态点呼吸动效及后续导航结构统一留待 U4 与后续里程碑校核。

## 1.6.1 UI 全局统一与订阅入口重构 —— 状态：已完成开发，待构建机验证

- **统一添加入口**：首页底部「+」改为打开 `AddEntryDialog`，提供「导入订阅」(主)与「新建节点」两个入口；移除原底部「导入 / 启动 VPN / 新建」三连按钮，VPN 启停仅由 HeroCard 内 `BigPowerButton` 承担。
- **订阅命名与分组**：`upsertSub(url, userinfo, requestedName)` 支持可选订阅名；非空时写入 `SubInfo.name` 与 `SubInfo.group`，为空时保持域名推断名称且未分组；已有订阅仅在提供非空名时更新，不清空既有分组。`Index.doImport` 透传名称。
- **最近分组偏好**：新增 Preference 键 `recent_subscription_group`。导入订阅(非空名)与设置页改组(非空名)时写回；导入弹窗打开时默认带入；`ProfileEdit` 新建节点时按名称匹配 `loadGroups()` 命中则设 `Profile.groupId`，未命中保持未分组；编辑已有节点不覆盖原分组。
- **设置页订阅区强化**：分组头对命名组与未分组均显示「名称 · 数量」；每条订阅卡片化(`UiSpec.CARD_RADIUS`/`GAP_MD`/`surface`)，更新/分组/删除三按钮 `layoutWeight(1)` 等分。
- **五页面统一**：`ConnectionsPage` 连接项、`RouteRulesPage` 本地规则与远程规则集、`SubDetailPage` 信息卡与主/次/危险按钮、`ProfileEdit` 粘贴解析区与内容边距，统一到 `UiSpec` 令牌；日志页终端配色保持不变。
- **文案**：「导入链接」全局改为「导入订阅」(import_link_subscription / subscription_link_use_home / settings_subs_empty)；删除已无引用的 `import_link` 键；新增 `subscription_name_optional`、`sub_group_none_count`、`sub_group_value`；删除死资源 `sub_group_none`。
- **静态检查**：4 个资源 JSON 语法通过；base/en_US 字符串键 311=311 无缺失；base/dark 色值键 24=24 无缺失；`git diff --check` 干净；无 `$r()` 进模板串；十六进制色值仅存于日志页(刻意保留)；改动全部位于 `entry/src/main/ets` 与 `entry/src/main/resources` 白名单，未触碰内核 `core/`、`.so`、`module.json5`、`build-profile.json5`、`AppScope`。
- 未构建、未打包、未执行 Git 写操作；等待构建机编译与真机验证。

## U2 订阅管理与节点操作 —— 状态：B 方案已完成静态交付，待构建机验证

- 订阅管理作为第二导航目的地，集中展示订阅纯行、所有节点分组、搜索、订阅详情、分组编辑、更新、删除及节点上下文操作。

## U3 设置导航与既有能力保留 —— 状态：B 方案已完成静态交付，待构建机验证

## U4 响应式导航与连接状态 —— 状态：B 方案已完成静态交付，待构建机验证

## U5 桌面服务卡片方案 —— 状态：方案文档已完成，未修改 module.json5

## U6 B 方案纯行视觉与资源化 —— 状态：已完成静态交付，待构建机验证

## U7 静态验收与交付记录 —— 状态：B 方案静态验收已完成，待构建机验证

- AppStorage UI 键统一为 `uiBreakpoint`、`uiUptime`、`uiUptimeStart`；构建与真机验证按本轮约束留给构建机执行。


## B 方案第二轮（2026-09-05，静态交付）

- [x] SettingsPage 作为 Index 设置 Tab 原位内容。
- [x] navLayout 底部菜单栏/侧边栏持久化与白名单校验。
- [x] 首页移除测速入口，订阅管理保留测速能力。
- [x] active_config_url 订阅选中、过滤及导入后自动选中；切换订阅时同步选中该订阅首个节点，避免引用已过滤的旧节点。
- [x] base/en_US 文案同步。
- [x] 仅静态审查，不构建、不提交、不远程操作。


## B 方案第三轮（2026-09-05，静态交付）

- [x] 常驻通知两行展示节点/延迟与上下行实时速度、累计流量，新增通知流量标签完成 base/en_US 对称资源化。
- [x] 通知轮询在 onDestroy、断开、启动失败、异常回滚、无待启动目标及统一 teardown 路径停止，并同步取消通知。
- [x] SettingsPage 七组默认展开可折叠，持久控件统一 dirty 保存语义；switchMode 保留即时保存，外观即时应用后标脏，成功保存/恢复清 dirty。
- [x] 仅执行静态审查；本轮未运行构建、打包或真机测试。


## P 轮:对齐安卓 NekoBox for Android(main 分支)—— 状态:✅ 已完成开发并本机编译通过(2026-09-06,versionCode 1001917)

- 基准:MatsuriDayo/NekoBoxForAndroid main 分支源码(本机 nekobox-android/ 目录);视觉沿用 UiSpec 鸿蒙原生观感,信息架构/功能/交互对齐安卓。
- 已交付:协议 14 种(新增 SSH/ShadowTLS/自定义出站/链式代理及全部 TLS/Mux/端口跳跃等字段)、设置页四大新组(常规/路由/DNS/入站)、抽屉导航 + StatsBar + FAB、分组管理页(GroupFragment 对齐)、工具页(STUN + 恢复出厂)、关于页(检查更新/内核版本)、yacd Dashboard(内置 yacd.zip + external_ui)、链接解析扩展(ssh/socks4/SS 插件)。
- 真机风险项:FakeDNS、yacd 面板加载、链式代理真实连接、STUN 探测、mixedPort 局域网访问。
- 内核限制(冻结 sing-box 1.11.9):anytls/mieru/naive/trojan-go 不支持,未导入以避免死节点。


## 真机反馈修复轮(1.7.1,versionCode 1001918)—— 状态:✅ 已完成开发并本机编译通过(2026-09-06)

- ① 抽屉各驻留页(分组/设置/工具/关于/面板)头部接入共用 DrawerButton,新增 onOpenDrawer 回调,消除无返回入口死胡同。
- ② FAB 改容器式圆形按钮(64vp、半透明 fab_bg/fab_running 令牌、阴影跟随圆角),消除 Circle 阴影方形光晕。
- ③ 闲置后无法启动三重修复:扩展忽略分支重播 connected 状态(UI 回收重建后自动同步);120s 启动终态判定(不再无限 connecting);doTeardown stopCore/destroy 超时兜底(防 starting 卡死);Index.onPageShow clash API 前台探测(扩展已死则重置断开态)。
- 真机验证点:闲置 30 分钟+后回到 App 直接点启动应能恢复已连接状态或正常重连;FAB 深浅色下均无方形底;五个驻留页左上 ≡ 均可打开抽屉。


## 真机反馈修复轮 2(1.7.2,versionCode 1001919)—— 状态:✅ 已完成开发并本机编译通过(2026-09-06)

- 设置页去重:路由入口/关于版本移除,备份迁至工具页;面板功能整体删除(含 yacd 资源与 external_ui);配置页节点列表卡片化,抽屉头部加图标+版本,菜单项带图标。
- 页签终态:0 配置 / 1 分组 / 2 路由 / 3 设置 / 4 日志 / 5 工具 / 6 关于,全部原地切换,均可随时再开抽屉。


## 对审修复轮(1.7.3,versionCode 1001920)—— 状态:✅ 已完成开发并本机编译通过(2026-09-06)

- Clash 订阅 hysteria2/tuic/grpc/ws 早期数据/h2 解析补全;subAllowInsecure(http remoteValidation=skip)、resolveDestination(规则模式 resolve 兜底)、notificationGroup(通知前缀)全部接线;设置页补解析目标地址开关与全局自定义配置 JSON 输入。
- 真机验证点:含 hy2/tuic 的 Clash 订阅导入不再跳过;自签证书订阅可下载;通知显示 [分组名];解析目标地址开启后 IP 规则生效。


## 备份恢复可靠性整改(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 文件恢复与剪贴板恢复统一进入 `ToolsPage.restoreText()` 安全入口，共享恢复互斥、运行中 VPN 停止等待、事务回滚和结果汇总。
- `Backup.ets` 保持严格格式校验并改用显式 `Array<Object>` 遍历，恢复摘要完整统计节点、分组、设置、订阅、路由规则和远程规则集。
- base/en_US 新增恢复繁忙、VPN 停止超时、已完整回滚、回滚不完整及停止 VPN 后恢复成功等对称资源；双语字符串键 481=481，双向差异为 0。
- 验证：hvigor assembleHap `BUILD SUCCESSFUL`，未签名 HAP 已重新生成；构建仅保留项目既存弃用 API、可能抛异常和无签名配置警告。
- 真机验证点：VPN 运行时从文件和剪贴板恢复均应先可靠断开；构造恢复写入失败时原数据应完整回滚；并发点击恢复应显示繁忙提示且不得交叉写入。


## 订阅容器 Scheme 支持(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `Formats.parseProxies` 的 `SubscriptionFoundException` 与 `MainActivity.importSubscription`：主页「导入订阅」现在先解包 `clash://install-config?url=<订阅地址>&name=<名称>`，取真实订阅地址与名称走既有订阅下载、分组、`upsertSub` 与选中流程。
- 节点编辑页「粘贴解析」识别 clash 容器后引导回主页导入；`sn://subscription` 为 SagerNet 私有 Kryo 序列化容器，鸿蒙无对应序列化能力，识别后给出明确本地化提示并写日志，不再静默失败。
- 新增对称资源 `subscription_container_unsupported`；base/en_US 字符串键 482=482，双向差异为 0。
- 验证：hvigor assembleHap `BUILD SUCCESSFUL`；解包算法用 10 组输入用例独立验证全部通过(含 URL 编码、缺 url、空文本、大小写、sn 容器识别)；未签名 HAP 已重新生成。
- 已知限制：未在 `module.json5` 注册外部 Scheme（受 VPN type 与阶段约束），仅覆盖应用内粘贴/导入入口；外部链接拉起需后续单独评估。


## 启动自动连接 + 设置页文案资源化(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `global_preferences.xml` 的 `isAutoConnect`:`AppSettings.autoConnect`(默认关) + 设置页常规组开关;`Index.aboutToAppear` 在刷新节点与设置后,开启且未运行且有选中节点时调用 `VpnService.connect`,失败仅写日志不弹错。
- 备份校验白名单同步加入 `autoConnect`,恢复 containing 旧备份时缺字段保持默认值。
- 资源化设置页三处硬编码长文案:`latency_test_mode`/`latency_test_mode_desc`/`settings_test_url_desc`,深浅色与中英文一致。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 字符串键 487=487,双向差异为 0;未签名 HAP 已重新生成。
- 已知限制:常规组的测速方式下拉选项标签(`URL Test(真连接)`/`TCPing(仅握手)`)与 `TUN MTU` 标签为既有硬编码,本轮未改,避免重构数据数组;`autoConnect` 在系统拒绝 VPN 授权时的行为与手动启动一致(失败状态写入 `vpnStatus`)。


## 复杂节点导入闭环 + 设置页文案清零(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `RawUpdater.parseRaw` 的解析派发顺序:JSON → base64 → 分享链接。`parseShareText` 现在先识别 sing-box JSON 与 WireGuard `.conf`。
- `utils/Subscription.ets` 新增 `parseSingleOutboundJson`:完整配置直接走 `parseSingBoxConfig`,单个出站对象包成 `{outbounds:[obj]}` 再解析,使「导出 sing-box 配置」复制出来的 JSON 可原路导回。
- `utils/LinkParser.ets` 新增 `parseWireGuardConf`:`[Interface]` 取 PrivateKey/Address/MTU,每个 `[Peer]` 按 Endpoint/PublicKey 生成一个 WireGuard 节点;IPv6 方括号地址、注释行、缺 Endpoint/PublicKey/非法端口的 Peer 与安卓一致跳过。
- 设置页剩余两处硬编码(`TUN MTU`、测速方式下拉标签)资源化:`settings_tun_mtu`、`latency_test_url`、`latency_test_tcp`;`LATENCY_TEST_LABELS` 改为 `Array<Resource>`。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;WireGuard conf 解析 4 组用例(标准 conf、IPv6 Endpoint、缺 Endpoint、多 Peer)与 JSON 解析 4 组用例(裸出站、完整配置、非法 JSON、非代理出站跳过)全部通过;base/en_US 490=490 双向差异 0;SettingsPage 已无硬编码字面量;未签名 HAP 已重新生成。
- 真机验证点:复制 WireGuard `.conf` 文本与单个出站 JSON 到首页「导入订阅」/编辑页「粘贴解析」应能生成正确节点;`.conf` 导入的节点可连接。


## 首页菜单与节点导出补全(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `menu/add_profile_menu.xml` 的 misc 菜单:首页 ⋮ 新增「更新当前订阅」(选中节点 subUrl,无订阅明确提示)与「清除流量统计」(重置 `vpnTotalUp/Down` 与速率基准)。
- 对齐安卓 `menu/profile_share_menu.xml` 的 `action_config_export_file`:节点长按菜单新增「导出配置到文件」,`DocumentViewPicker.save` 写入 `<节点名>.json`。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 496=496 双向差异 0;未签名 HAP 已重新生成。
- 已知限制:「更新当前订阅」不重启 VPN,仅更新节点数据;文件导出需真机回归一次系统文件选择器与写入权限。


## 分组页导出补全(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `menu/group_action_menu.xml` 的 `action_export_file`:订阅卡片操作行新增「导出节点到文件」,`DocumentViewPicker.save` 写入 `<订阅名>.txt`;剪贴板与文件两条路径共用 `exportableLinks()`。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 498=498 双向差异 0;未签名 HAP 已重新生成。
- 已知限制:仅覆盖可生成分享链接的协议;WireGuard/自定义出站仍走单节点「导出配置到文件」。


## 日志页双语化 + 路由重置 + 分应用选择操作(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `menu/logcat_menu.xml`/`menu/add_route_menu.xml`/`menu/per_app_proxy_menu.xml`。
- 日志页标题/导出/清空/搜索/全部提示双语化(终端配色不动);路由页新增「重置路由」(双确认 + 清空规则与远程规则集);分应用代理新增「反选」「清除选择」,均复用 `persistPerAppList`(保存 + 运行中自动重启)。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 509=509 双向差异 0;`entry/src/main/ets` 已无中文字面量;未签名 HAP 已重新生成。
- 真机验证点:英文环境下日志页全英文;重置路由后重连 VPN 生效;反选/清除后 VPN 自动重启且分应用名单正确。


## 抽屉新增「使用文档」(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `main_drawer_menu.xml` 的 `nav_faq`:抽屉在「日志」与「工具」之间新增「使用文档」,打开应用内 `DocPage`(`Web` 组件加载项目文档)。
- 新页面注册入 `main_pages.json`;不占用既有 0~6 页签索引。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 510=510 双向差异 0;未签名 HAP 已重新生成。
- 已知限制:需联网;弱网/无网下的 Web 表现与返回手势待真机回归。


## 订阅级设置 + 关于页交流群入口(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `group_preferences.xml` 的 subscriptionUpdate 分类与 AboutFragment 的 Telegram 项。
- `SubInfo` 新增 `userAgent`/`autoUpdate`/`updateWhenConnectedOnly`;`needAutoUpdate` 增加两道过滤;`touchSub` 写回 `nextUpdateAt`;`SubDetailPage` 新增订阅设置卡(自动更新/间隔/仅连接时更新/自定义 UA)。
- 关于页新增「加入交流群」,与项目主页共用 `openLink`。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;9 组逻辑用 Node 独立脚本全部通过(并修掉负数间隔回落为 1 的缺陷);base/en_US 519=519 双向差异 0;未签名 HAP 已重新生成。
- 真机验证点:自定义 UA 请求头;断开态下后台更新任务确实跳过;交流群链接打开或降级复制。


## 链式代理循环引用防护(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `ChainSettingsActivity` 的 `testProfileContains`/`testProfileAllowed` 与 `circular_reference` 提示。
- `ProfileEdit` 新增 `chainContains` 递归检测(visited 兜底自引用链)+ `chainSelectionAllowed` 双向环路判定;链列表不可选项置灰并强制勾选时提示;`validationError` 保存前复核。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;9 组环路检测用 Node 独立脚本全部通过;base/en_US 520=520 双向差异 0;未签名 HAP 已重新生成。
- 真机验证点:多级嵌套链的勾选/拖拽组合不应出现无限递归或死循环渲染。


## 导入前确认对话框(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `MainActivity.importSubscription`/`importProfile` 的确认步骤。
- `Index.confirmImport` 双按钮异步确认;订阅导入在下载前确认(含 IP 泄漏安全提示),分享链接解析后确认;取消即中止。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 523=523 双向差异 0;未签名 HAP 已重新生成。
- 真机验证点:确认/取消两条路径(取消不得落盘任何节点)。


## 网络变化重置连接(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `global_preferences.xml` 的 `networkChangeResetConnections`(默认 true)。
- `AppSettings` 加字段并进 Backup 白名单;`VpnExtAbility` 用 `createNetConnection()` + `register/unregister` 监听 `netAvailable`/`netLost`/`netCapabilitiesChange`,generation 防抖 1.5s,重连复用既有串行启动队列;设置页外观分组加开关。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 525=525 双向差异 0;未签名 HAP 已重新生成。
- 真机验证点:Wi-Fi ↔ 移动数据切换后自动重连成功;关闭开关后切换网络不重连。


## 系统返回键行为(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17)，待真机回归

- 对齐安卓 `onBackPressedDispatcher`:抽屉 → 收;非配置页 → 回配置页;配置页 → `moveAbilityToBackground()` 退桌面(VPN 不断)。
- 踩坑记录:`onBackPress` 只能作 @Entry 生命周期方法,不能挂组件属性链;`inputConsumer.keyPressed` 仅音量/媒体键,不能订阅返回键。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 525=525 双向差异 0;未签名 HAP 已重新生成。
- 真机验证点:连接 VPN 后按返回退到桌面,通知仍显示已连接;非配置页按返回回配置页。


## 导入自定义 Geo 数据文件(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17),待真机回归

- 对齐安卓 `AssetsActivity.action_import_file`:DocumentViewPicker 选 .db → 校验文件名 geoip.db/geosite.db → 覆盖沙箱 cn 库 → 版本标记 Custom。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 529=529 双向差异 0;Node 脚本 14 项判定逻辑检查全部通过。
- 真机验证点:导入 geoip.db 后重连,cn 分流仍生效;取消选择不弹错误提示。


## 回到前台时重置连接(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17),待真机回归

- 对齐安卓 `wakeResetConnections`:UI 进程 onForeground 发 CommonEvent → 扩展进程重连(teardown+tryStart),默认关闭。
- 平台差异说明:鸿蒙无屏幕亮灭事件订阅,用「应用回到前台」近似安卓「退出 Doze」。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 531=531 双向差异 0;未签名 HAP 已重新生成。
- 真机验证点:开启开关后切到后台再回前台触发一次重连;关闭开关后回前台不重连。


## 通知刷新间隔可设置(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17),待真机回归

- 对齐安卓 `speedInterval`:`speedIntervalMs` 默认 1000,钳制 [500,10000],通知轮询定时器按设置刷新。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 533=533 双向差异 0;Node 脚本 10 项钳制检查全部通过。
- 真机验证点:填 500 / 10000 / 越界值(如 0、99999)后重连,通知刷新频率正确且不狂刷。


## 每节点流量统计与持久化(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17),待真机回归

- 对齐安卓 `profileTrafficStatistics`:会话结束(切节点/断开)时把会话流量累加到 Profile.rx/tx 并落盘;节点卡显示 `↓rx ↑tx`。
- 平台差异:鸿蒙无 libcore 按出站统计,用「单出站会话总量 = 当前节点流量」近似。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 535=535 双向差异 0;Node 脚本 9 项检查全部通过。
- 真机验证点:产生流量后断开,节点卡出现累计;再连再断数字只增不减;关闭开关后断开不累加。


## 代理服务器域名解析策略(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17),待真机回归

- 对齐安卓 `domain_strategy_for_server`:`serverDnsStrategy` 写入 `route.default_domain_resolver.strategy`。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 537=537 双向差异 0;未签名 HAP 已重新生成。
- 真机验证点:设为 ipv4_only 后 IPv6-only 服务器解析失败符合预期;默认(空)行为不变。


## 路由规则升级为多字段 AND 模型(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17),待真机回归

- 对齐安卓 `RuleEntity`:规则支持 domains/ip/port/source/sourcePort/network/protocol/packages/config 多字段 AND 组合。
- 域名前缀语义与安卓完全一致(geosite:/full:/domain:/keyword:/regexp:/裸值);旧单类型规则自动迁移。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 549=549 双向差异 0;Node 脚本 18 项检查全部通过(前缀解析/端口解析/旧规则迁移)。
- 真机验证点:旧规则升级后行为不变;新建「域名+端口」组合规则生效;自定义配置 JSON 非法时不影响其他规则。


## 订阅更新去重开关(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17),待真机回归

- 对齐安卓 `subscriptionDeduplication`:默认关闭(保留全部节点);此前鸿蒙始终去重,行为与安卓不一致,已修正。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 551=551 双向差异 0;未签名 HAP 已重新生成。
- 真机验证点:含重复节点的订阅,开关关闭时全部保留;开启时重复节点被跳过。


## 交付物:功能/UI 对照清单 —— 状态:✅ 已完成(2026-09-17)

- `PARITY.md` 已生成:全局设置 39 项、分组设置 13 项、路由规则 12 项、13 种协议、15 个页面/交互的完整对照 + 排除项理由 + 真机回归清单。
- 本轮移植 9 项全部 BUILD SUCCESSFUL,字符串键 551=551 双向差异 0,未签名 HAP 已重新生成。


## 扫码导入 + 分享二维码 + 订阅强制解析(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-17),待真机回归

- 关键纠正:本 SDK 的 HMS `@kit.ScanKit` 完整存在(`scanBarcode`/`generateBarcode`/`detectBarcode`),此前「SDK 无 generateBarcode」为误判。扫码导入与二维码分享均为 1:1 实现。
- 扫码:系统扫描 UI 免相机权限,仅 QR 码(对齐 zxing QRCodeAnalyzer),结果复用 doImport;取消静默。
- 分享:节点/订阅两处弹窗真实渲染二维码,失败回退文本+复制。
- 强制解析:`forceResolve` 默认关闭;`getAddressesByName` 5 并发,IPv4 优先,TLS 原域名回填 sni;失败保留域名。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US 556=556 双向差异 0;UI 硬编码文案扫描 0;Node 脚本 15 项强制解析检查全通过;未签名 HAP 15,150,535 字节。
- 真机验证点:扫订阅码/节点码导入;分享弹窗出码可被其他设备识别;强制解析开关开/关更新结果。


## 二轮深度排查:文件导入/WG zip、规则排序、分应用剪贴板、移动到分组、geo 单库管理(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-18),待真机回归

- 逐项复查安卓全部 menu XML 与 RouteFragment/AppListActivity/AssetsActivity/ProfileSettingsActivity 后补齐 5 个缺口 + sn:// 识别扩展。
- 文件导入:`importFromFile()` 任意文件→doImport;`.zip` 解压逐 entry(WG 导出包),entry 名作节点名,单次确认批量入库。
- 规则排序:`moveRule/moveRemoteRuleSet` ↑↓(ItemTouchHelper 等价),边界置灰。
- 分应用剪贴板:`false\n<包名>` 格式与安卓一致,导出/导入(校验+整体替换+自动重启)。
- 移动分组:节点长按菜单「移动到分组」弹窗 + ProfileEdit 分组 Select(对齐 ProfileSettings 分组 Preference)。
- geo 单库:每库大小/版本 + 单库更新 + 删除二次确认(对齐 AssetsActivity 列表;删除无撤销为已记录差异)。
- 验证:hvigor assembleHap `BUILD SUCCESSFUL`;base/en_US **586=586** 双向差异 0;UI 硬编码扫描 0;Node 25 项检查全通过;未签名 HAP 15,262,692 字节。
- 权威待办(见 `docs/PARITY-REAUDIT.md`,内核已可重编):CORE-05 任意 profileId 规则出站、CORE-06 组级 selector/frontProxy/landingProxy(需 lean_context 注册 protocol/group + 重编 .so)、CORE-07 自定义 JSON 递归合并与 +key 列表操作、DEF-01/02 默认值、UI-01~06 版式对齐。


## CORE-05/06 UI 闭环 + DEF-01 默认值对齐(2.0)—— 状态:✅ 已完成开发并本机编译通过(2026-09-18),待真机回归

- CORE-05 收尾:路由规则出站行加「指定节点」按钮 + 目标 Select(`profile:<id>` 后端早已支持,补 UI 入口);再点按钮/选「代理」取消。
- CORE-06 收尾:GroupPage 分组卡「分组设置」内联面板(selector 开关 + 前/落地代理 Select + 保存即重载);内核 `group.RegisterSelector` 与 selector/前后置出站图此前已就绪(`.so` 09-18 06:35 重编)。
- DEF-01:mtu 9000(钳制上限同步)、mixedPort 2080、bypassLan false,对齐安卓 DataStore;仅新装默认生效。DEF-02 的 DoH/fakeDns 默认按 reaudit 平台能力口径保留并注释。
- 验证:assembleHap `BUILD SUCCESSFUL`;双语键 598=598 差异 0;生产测试 parity-config 38 + outbound-graph 9 + ipv6 全套全绿;硬编码扫描 0。
- 真机验证点:selector 组内核配置合法且组内切换可连通;前/落地代理流量路径正确;新装 MTU9000 + mixed2080 连接稳定;规则指定节点出站命中转该节点。
- 剩余开放项(UI-01~06 版式对齐、selector 免重载热切换经 Clash API、sniff 设备端行为)记录于 `docs/PARITY-REAUDIT.md`,需真机/下批处理。


## 版本 2.0.1 + 带签名 .app 打包(2026-09-18)—— 状态:✅ 完成并校验

- `AppScope/app.json5`:versionName 2.0 → **2.0.1**、versionCode 2000000 → **2000001**;全仓库无其它版本字面量(关于页动态读 bundleManager)。
- 构建:`assembleHap` + `assembleApp` 均 BUILD SUCCESSFUL(2.0.1 反映在 pack.info:code 2000001/name 2.0.1)。
- 签名:项目 `签名材料/` 发布密钥(别名 nekobox,SHA256withECDSA,release p7b)经 SDK `hap-sign-tool` 双层签名(内层 entry-default.hap → 重打包 → .app 外壳);口令仅经命令行使用,未写入 build-profile/脚本/仓库任何文件,临时目录已清理。
- 校验:`verify-app` 对签名后内层 HAP「Verify success」(Signing Block v3);profile 解出 type=release、bundle-name=com.nekobox.app.jynxen——与 1.9.x 正式签名同身份,真机可覆盖升级。
- 交付:`dist/NekoBox-2.0.1-signed.app`(13,608,082 字节,SHA256 A2DDC21ABD74F7A13FC7FC6A1C235F66476E7184E5F08C3AAD70FA946CEDF265)。
- 真机注意:release profile 仍含 udid 白名单(与 1.9.x 相同设备清单);安装即覆盖升级此前 release 签名版本。
