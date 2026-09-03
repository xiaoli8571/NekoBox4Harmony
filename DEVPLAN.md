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
