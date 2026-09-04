# NekoBox for Harmony 开发计划(G 阶段,目标版本 1.6.0)

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

## U1 首页重构（方案 C 玻璃拟态霓虹）—— 状态：已完成开发，待构建机验证

- 已将既有 F1 深色主题替换为方案 C 玻璃拟态霓虹视觉，浅色主题继续保持 F1 外观；C 主题 token 并入既有 `UiSpec.ets` 与 base/dark 颜色资源，没有建立平行 token 系统。
- 首页 Hero、连接能量球、统计卡和节点容器已切换为玻璃描边、霓虹强调与选中辉光样式；列表行使用实底玻璃降级，避免逐行 blur，并保持后续 `uiFxLevel` full/lite 接入路径。
- 继续复用 `AppStorage('vpnStatus')`、`Index.statusDisplay()` 与现有 VPN/Store/Profile 数据链路，保留节点选择、VPN 启停、订阅导入、节点新增与编辑、测速、分组测速、折叠、手动排序、置顶、分享、per-app 入口，以及连接、日志和设置入口。
- base/dark 颜色资源均为 48 键且集合一致，无重复键；新增 ArkTS 代码无十六进制色值、无 `.stateEffect()`，`git diff --check` 通过。未构建、未打包、未执行 Git 写操作。
- 连接中旋转 loading、状态点呼吸动效及完整 blur/full-lite 动态切换留待 U3/U4 按计划统一实现与审计。

## U2 节点列表（方案 C 玻璃拟态霓虹）—— 状态：已完成开发，待构建机验证

- 节点列表沿用 U1 的单层玻璃容器，节点行使用实底玻璃降级，选中项以青色描边与辉光区分，避免对每一行应用 blur。
- 新增 64vp 延迟能量条，按 `latency / 250` 限幅显示，继续复用既有测速结果与成功、警告、错误颜色语义；未测或失败时不绘制有效长度。
- 保留 G1 手动排序及名称/延迟排序、置顶优先级、分组测速与折叠、文本/二维码不可用时的分享降级、复制链接和订阅详情入口，未改变 `Profile`、`Store` 或排序持久化契约。
- 已完成资源 JSON、功能引用、ArkTS 新增色值、`.stateEffect()` 与 `git diff --check` 静态核对；未构建、未打包、未执行 Git 写操作。

## U7 整体验收与收口（方案 C）—— 状态：静态验收已完成，待构建机与真机验证

- 已按 U1–U7 全量变更执行只读静态审计：`git diff --check` 通过，资源 JSON 可解析且无重复键，base/dark 颜色键 48=48，base/en_US 文案键 315=315，未发现 `$r()` 模板串混用、新增 `.stateEffect()`、显式 blur 或 UI 白名单内 TODO/FIXME。
- 全量改动与未跟踪文件均已逐项核对：运行时代码仅位于 UI 白名单内，文档改动为 `CHANGES.md`、`DEVPLAN.md` 及 U5 条件任务方案；未触碰 `module.json5`、内核、`vpnext`、`utils`、`model`、`entry/libs`、`build-profile.json5` 或 `AppScope`。
- 存量 ArkTS 十六进制色值仅位于 `LogPage.ets` 的刻意保留终端配色，以及 `UiSpec.ets` 的状态栏黑白内容色；本轮新增页面代码未增加硬编码色值。
- U1–U4 已完成方案 C 首页、节点列表、订阅/设置页及 token/性能护栏改造；U5 已完成设计方案但因 `module.json5` 冻结未实现运行时；U6 已完成 compact/medium/large 响应式结构。
- 静态功能链路核对覆盖节点选择/测速/排序/分享、订阅更新/导入/分享、规则页、连接页、日志页、设置页、深浅色、full/lite 与响应式分支；未因 U1–U6 改造移除既有入口或改变 Store/AppStorage 业务状态契约。
- 严格遵守禁止构建要求，未执行 HAP 构建、打包或 Git 写操作。因此六种主题与断点组合的视觉走查、全流程九步回归、断网/断连态、进程重启恢复、窗口旋转缩放、性能功耗及 HarmonyOS API 类型均保留为构建机和真机验收项，不能标记为已验证。
- U5 待确认事项：只有用户明确解除 `entry/src/main/module.json5` 冻结后，才能按 `docs/U5-桌面服务卡片方案.md` 实现 2×2/2×4 服务卡片及 FormExtensionAbility 注册。
- 接真实数据源新增 TODO：无。当前 UI 所需数据均继续复用既有 Store/AppStorage；未提出或写入新的内核、model、utils 接口。

## U6 平板响应式布局（方案 C）—— 状态：已完成开发，待构建机验证

- 新增 `AppStorage('uiBreakpoint')`，由 `EntryAbility` 按窗口短边 vp 计算 `compact`（<600vp）、`medium`（600–839vp）与 `large`（>=840vp）；窗口创建时初始化，并注册 `windowSizeChange`，销毁时注销监听。
- 中屏与大屏启用方案 C 玻璃霓虹侧栏，宽度分别为 150vp 与 180vp；保留首页、代理、订阅、规则和设置入口，并复用现有页面与业务状态，不迁移或重置 Store/AppStorage 数据。
- 节点列表按 compact/medium/large 分别使用 1/2/3 列；中屏和大屏 Hero 电源按钮为 64vp，compact 继续沿用原尺寸与原布局，避免窄屏回归。
- 新增 `common/Breakpoint.ets` 与 `common/components/Sidebar.ets`，并仅在白名单允许的 `EntryAbility.ets` 中加入最小窗口尺寸初始化和监听生命周期代码；未触碰 `module.json5`、内核及其他冻结路径。
- 已完成结构标记、定界符、NUL、冻结路径及 `git diff --check` 只读审计；未构建、未打包、未执行 Git 写操作。
- 已知限制：本机未找到可核对的 HarmonyOS SDK 声明，`window.Size`、`windowSizeChange` 和 px/vp 密度换算仍需构建机编译确认；响应式观感与旋转/窗口缩放行为未在预览器或真机验证。

## U5 桌面服务卡片 2×2 / 2×4（条件任务）—— 状态：方案已完成，待用户解除 module.json5 冻结

- 已按默认条件任务产出 `docs/U5-桌面服务卡片方案.md`，覆盖 2×2/2×4 视觉、`form_config.json` 草案、`VpnFormAbility`、快照契约、Preferences 冷启动兜底、10 秒节流发布及 `postCardAction` 回传链路。
- 方案明确两张卡片的 `defaultColor` 均为 `#0B0F1A`，卡片进程内不开 blur，并禁止 import 主应用 Store、VPN Service 或 core 模块。
- 已定义 `toggle`、`select`、`open` 从卡片到 `EntryAbility` 再复用既有业务方法的端到端设计，以及输入校验、一次性消费和错误降级要求。
- 严格保持 `entry/src/main/module.json5` 冻结，未新增 FormExtensionAbility、FormWidget 或运行时代码；只有用户明确解除冻结后才进入实现。
- 未构建、未打包、未执行 Git 写操作。U5 当前按交接要求完成方案阶段，运行时实现与真机验收待授权。

## U4 token 审计、性能护栏与动效收口（方案 C）—— 状态：已完成开发，待构建机验证

- 已完成 `entry/src/main/ets` 全目录十六进制色值检查：存量命中仅为 `UiSpec.ets` 状态栏黑白色与 `LogPage.ets` 既有固定色；本轮新增代码命中为 0，未改动存量项。
- base/dark 颜色资源均为 48 个唯一键且键集合一致；base/en_US 文案资源均为 315 个唯一键且键集合一致，U4 未新增文案键。
- 当前改造页面显式 blur 节点为 0，低于每屏 6 个预算；滚动列表继续采用容器玻璃或实底玻璃行，未逐行增加 blur。
- 已补充首页 `aboutToDisappear()` 生命周期清理，页面离开时停止速率轮询并清除定时器，避免后台空转；现有连接状态变化时的启停逻辑保持不变。
- `uiFxLevel` 保持 `full`/`lite` 二选一与默认 `full`，设置页切换即时更新；当前视觉实现不使用显式 blur，因此 lite 模式不存在透明底残影风险。
- 已核对无新增 `.stateEffect()`，并排效果按钮继续使用 `layoutWeight(1)`；UI 白名单与冻结路径检查无异常。
- 浅色主题 token 保持 F1 现有实色语义；深色对比度、快速滚动帧率与静置功耗仍需构建机及 MatePad mini 真机复核。
- 已完成资源 JSON、NUL、功能引用及 `git diff --check` 只读审计；未构建、未打包、未执行 Git 写操作。

## U3 订阅页与设置页（方案 C 玻璃拟态霓虹）—— 状态：已完成开发，待构建机验证

- 设置页订阅卡与订阅详情信息卡已改为方案 C 玻璃描边样式，列表内订阅卡采用实底玻璃降级，避免滚动区域逐项 blur；更新、分组、删除、分享及订阅详情等既有入口保持可触达。
- 设置页新增“视觉效果”完整/轻量二选一，使用新增 UI 专用 `AppStorage('uiFxLevel')`，默认 `full`，点击后即时更新当前页视觉状态；未改变现有主题三选一机制或 `AppSettings` 持久化契约。
- 保留出站模式、路由、Geo 数据、订阅更新与分组、自动更新、网络参数、外观、排序、触感、连接统计、分应用代理、备份恢复和不安全 TLS 等现有设置链路。
- 新增中英文资源键 `ui_fx_level`、`ui_fx_full`、`ui_fx_lite` 各 3 个，两侧资源键集合一致；未新增 ArkTS 十六进制色值或 `.stateEffect()`。
- 已完成资源 JSON、功能引用与 `git diff --check` 静态核对；未构建、未打包、未执行 Git 写操作。

## 1.6.1 UI 全局统一与订阅入口重构 —— 状态：已完成开发，待构建机验证

- **统一添加入口**：首页底部「+」改为打开 `AddEntryDialog`，提供「导入订阅」(主)与「新建节点」两个入口；移除原底部「导入 / 启动 VPN / 新建」三连按钮，VPN 启停仅由 HeroCard 内 `BigPowerButton` 承担。
- **订阅命名与分组**：`upsertSub(url, userinfo, requestedName)` 支持可选订阅名；非空时写入 `SubInfo.name` 与 `SubInfo.group`，为空时保持域名推断名称且未分组；已有订阅仅在提供非空名时更新，不清空既有分组。`Index.doImport` 透传名称。
- **最近分组偏好**：新增 Preference 键 `recent_subscription_group`。导入订阅(非空名)与设置页改组(非空名)时写回；导入弹窗打开时默认带入；`ProfileEdit` 新建节点时按名称匹配 `loadGroups()` 命中则设 `Profile.groupId`，未命中保持未分组；编辑已有节点不覆盖原分组。
- **设置页订阅区强化**：分组头对命名组与未分组均显示「名称 · 数量」；每条订阅卡片化(`UiSpec.CARD_RADIUS`/`GAP_MD`/`surface`)，更新/分组/删除三按钮 `layoutWeight(1)` 等分。
- **五页面统一**：`ConnectionsPage` 连接项、`RouteRulesPage` 本地规则与远程规则集、`SubDetailPage` 信息卡与主/次/危险按钮、`ProfileEdit` 粘贴解析区与内容边距，统一到 `UiSpec` 令牌；日志页终端配色保持不变。
- **文案**：「导入链接」全局改为「导入订阅」(import_link_subscription / subscription_link_use_home / settings_subs_empty)；删除已无引用的 `import_link` 键；新增 `subscription_name_optional`、`sub_group_none_count`、`sub_group_value`；删除死资源 `sub_group_none`。
- **静态检查**：4 个资源 JSON 语法通过；base/en_US 字符串键 311=311 无缺失；base/dark 色值键 24=24 无缺失；`git diff --check` 干净；无 `$r()` 进模板串；十六进制色值仅存于日志页(刻意保留)；改动全部位于 `entry/src/main/ets` 与 `entry/src/main/resources` 白名单，未触碰内核 `core/`、`.so`、`module.json5`、`build-profile.json5`、`AppScope`。
- 未构建、未打包、未执行 Git 写操作；等待构建机编译与真机验证。
