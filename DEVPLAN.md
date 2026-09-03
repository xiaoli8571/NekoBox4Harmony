# NekoBox for Harmony 开发计划(F 阶段,目标版本 1.5.8)

> 当前基线:1.5.7(versionCode 1001714,2026-09-03)。**F1~F6 已完成(F2~F6 待真机验证,勿重做)**;剩余 F7(UI 适配鸿蒙),目标版本 1.5.8。
> 详细项目架构见仓库根 `AGENTS.md`,上一轮实现说明见 `CHANGES.md`,先读这两个文件。

## 铁律(违反即返工)

1. **内核冻结在 1.5.6v**:不改 `core/sing-box-1.11/`、`core/libsingbox14/`、`entry/libs/arm64-v8a/libsingbox.so`、CGo 接口(CGoStartSingBox / CGoStopSingBox / CGoSetTunFd / CGoSingBoxVersion)。所有功能只写在 `entry/src/main/ets/` 与资源层
2. `module.json5` 的 `"type": "vpn"` **永远不动**。本阶段允许的唯一 module.json5 改动:F3 的后台任务声明与 F4 的 `GET_BUNDLE_INFO` 权限声明(见各项说明);若构建机反馈不允许,则回退该项改动
3. `build-profile.json5` 的 `signingConfigs` 保持 `[]` 不动;`AppScope/app.json5` 的 versionCode/versionName 由构建机管理,不改
4. 不碰 `entry/build/`、`dist/`、`.hvigor/`;**不执行任何 git 写操作**(commit/reset/checkout/clean/push 不做),`git status/diff/show/log` 只读可用
5. 不启动构建/打包(构建机负责);每完成一项在 `CHANGES.md` 末尾追加:日期、功能、改动文件列表、已知限制
6. 直接在当前工作区编辑,保持 LF 行尾;页面风格、主题色对齐 `pages/Index.ets` 现有写法
7. **文档同步义务(硬性)**:每完成/部分完成/降级一项,必须立即 ①更新本文件该项的"状态"行,②在 `CHANGES.md` 末尾按既有格式追加(日期、功能、改动文件列表、已知限制)。开发文档与代码同属交付物,**文档未同步视为该项未完成**

## 踩坑记录(前人踩过,先读)

1. ArkTS 的 `Row`/`Column` **没有** `.stateEffect()`(仅 Button 等按压态组件有);`.useEffect()` 是液态玻璃效果模板开关,与按压态无关。按压反馈用 `.hoverEffect()`/`.scale()`+animateTo,只在受支持组件上用
2. `hvigorw.js` 带 `__ohosCmdPatch` 补丁(Node ≥18.20 的 `.cmd` 子进程 EINVAL 修复),勿覆盖
3. `entry/libs/arm64-v8a/libsingbox.so` 是冻结内核成品,严禁删改;丢失会构建出 2MB 无内核的坏包
4. 签名证书配置永不入库
5. 外观偏好(系统/浅色/深色、触感、液态玻璃)已存在于 `model/Profile.ets` + `model/Store.ets`,设置 UI 在 `pages/SettingsPage.ets`,F1 在其基础上做
6. 延迟测试器在 `utils/LatencyTester.ets`,链接解析在 `utils/LinkParser.ets`,剪贴板助手在 `utils/ClipboardHelper.ets`,规则页 `pages/RouteRulesPage.ets`,备份 `core/Backup.ets`(schema v3),订阅 `core/Subscriptions.ets`——先读懂再改
7. **禁止把 `$r()` 写进模板串**(如 `` `${$r('app.string.x')}` ``):运行时渲染为 [object Object]。动态整句一律进 string.json 用 `%1$s`/`%1$d` 占位符,代码用 `$r('app.string.x', args)`;返回可能为资源的函数声明 `ResourceStr` 而非 `string`。`$r` 键名编译期校验,拼错键直接编译失败
8. `AppStorage('vpnStatus')` 只存机器状态键(connecting/disconnected/switching/awaiting_auth/start_timeout/`connected:<节点>`/`start_failed:<详情>`/`connect_failed:<详情>`),显示由 `Index.statusDisplay()` 映射资源;**不要向 vpnStatus 写用户可读文案**(VpnService 与 VpnExtAbility 的 publishVpnStatus 均已机器键化)。另:`catch (e)` 的 e 传辅助函数前先转字符串,函数参数不能声明为 `unknown`(arkts-no-any-unknown)

## F1 主题即时生效(纯应用层)—— 状态:✅ 已完成(2026-09-03,versionCode 1001711,勿重做)

- 已交付:新增 `resources/dark/element/color.json`(18 个深色令牌,深色模式自动覆盖基础配色);EntryAbility 启动时按外观偏好应用 colorMode;首页/编辑/设置/连接/规则/订阅详情页主题细节修正;外观偏好(系统/浅色/深色、触感、液态玻璃)设置 UI 此前已就绪
- 残留:若真机验收发现个别页面切主题仍需重进才刷新,按下方原方案补漏
- 原方案(备查):`ApplicationContext.setColorMode()`(公开 API)设置全局色彩模式;外观状态入 AppStorage,页面用 `@StorageProp` 绑定或监听变更即时刷新;自绘固定色替换为主题资源色
- 验收:切深色/浅色/跟随系统,所有页面立即生效,无需重启或重进

## F2 通知栏增强(纯应用层)—— 状态:已完成，待构建机编译与真机验证

- F2a 延迟显示:UI 进程测速完成(`utils/LatencyTester.ets` 回调处)通过 CommonEvent(如事件名 `NB_EVENT_LATENCY`,携带节点名+延迟)发给 VPN 扩展进程;`vpnext/VpnExtAbility.ets` 订阅后更新常驻通知文本,显示"当前节点 · 123ms";断连/测速失败显示 "--"
- F2b 通知按钮:通知加"断开"按钮,`wantAgent` 拉起 EntryAbility 并带参数(如 `action=disconnect`),`onNewWant` 里识别后调用现有停止 VPN 流程;连接状态反之显示"连接"按钮同理
- 改动:`vpnext/VpnExtAbility.ets`、`entryability/EntryAbility.ets`、`utils/LatencyTester.ets`、通知构建处
- 验收:通知栏能看到当前节点延迟;点"断开"能停止 VPN(拉起应用自动断开也算达标)

## F3 订阅后台定时更新(需要改 module.json5,仅限本项)—— 状态:已完成，待构建机编译与真机验证

- `module.json5`:requestPermissions 增加 `ohos.permission.KEEP_BACKGROUND_RUNNING`;EntryAbility 增加 `"backgroundModes": ["dataTransfer"]`。**除这两处外 module.json5 一个字都不许动**
- 方案:到期订阅在应用回前台/启动时更新(已有)之外,退后台后用 `@ohos.resourceschedule.backgroundTaskManager` 申请连续任务(dataTransfer)→ 更新到期订阅 → `stopContinuousTask` 释放;单次更新控制在最短必要时间。若真机验证连续任务受限,降级为 transientTask(短时任务)并在 CHANGES.md 注明
- 改动:`core/Subscriptions.ets`、`entryability/EntryAbility.ets`、`module.json5`(仅上述两处)
- 验收:应用退到后台/熄屏,到期订阅仍能自动更新(真机验证项,代码按 API 正确性交付)

## F4 per-app 应用列表(需要改 module.json5,仅限本项)—— 状态:已完成，待构建机编译与真机验证

- `module.json5`:requestPermissions 增加 `ohos.permission.GET_BUNDLE_INFO`,此外不许动
- 方案:用 `@ohos.bundle.bundleManager` 枚举已装应用(名称+包名+图标,图标可省略),做图形化选择器:列表+搜索+勾选,写回现有 per-app include/exclude 模式字段;**若真机报 201 权限拒绝或枚举失败,自动降级保留现有手输包名 UI**,并在 CHANGES.md 记录
- 改动:`pages/SettingsPage.ets`(或新建 per-app 选择页)、`model/Profile.ets`/`model/Store.ets` 按需、`module.json5`(仅权限)
- 验收:能从列表勾选应用;失败时手输兜底仍可用

## F5 备份文件化(纯应用层)—— 状态:已完成，待构建机编译与真机验证

- 用 `@ohos.file.picker` 的 DocumentViewPicker(公开 API,无需权限):导出——把现有 schema v3 备份 JSON 保存为用户选择路径的 `.json` 文件;导入——选择文件恢复。剪贴板方式保留为快捷入口
- 改动:`core/Backup.ets`、`pages/SettingsPage.ets`
- 验收:能导出备份文件、能从文件恢复,错误(坏文件/版本不兼容)有提示

## F6 中英多语言收尾(纯应用层)—— 状态:已完成,待真机验证

- 构建机补完(2026-09-03):SettingsPage 剩余 35 处文案与 Backup.ets 4 处(错误/摘要)资源化;全仓清除 43 处 `${$r(...)}` 模板串混用(运行时会渲染为 [object Object]),整句迁移为 string.json 占位符(%1$s/%1$d),相关函数返回类型改 ResourceStr;Backup 改抛机器错误键、UI 侧 backupErrorText 映射;LogStore 调试日志行保留中文(非 UI 文案,惯例一致)

- 全量抽取硬编码中文进 `resources/base/element/string.json`(base=中文),新建 `resources/en_US/element/string.json` 英文对照,代码改用 `$r('app.string.xxx')`;覆盖 Index、ProfileEdit、SettingsPage、SubDetailPage、RouteRulesPage、弹窗/按钮/Toast
- 验收:系统切英文后主要页面全英文,无漏翻(允许极个别动态拼接处注明)

## F7 UI 适配鸿蒙(纯应用层)—— 状态:待开发

- 目标:整体观感对齐 HarmonyOS NEXT 系统原生应用(以系统"设置"应用的卡片/列表/控件为基准),消除移植感。只动 `entry/src/main/ets/` 页面与 `resources/`,不动内核与 module.json5
- F7a 布局与间距统一:全页面统一页面左右边距 16vp、卡片圆角 16vp、卡片内边距 12~16vp、元素纵向间距 8/12/16 档位、列表行高 ≥44vp;圆角/边距/间距常量集中定义(如 common/UiSpec.ets 或资源 dimen),避免各页散落魔法数;覆盖 Index、ProfileEdit、SettingsPage、ConnectionsPage、RouteRulesPage、SubDetailPage
- F7b 控件对齐系统风格:主操作按钮用 ButtonType.Capsule、高度 40vp,破坏性操作用 error 色区分;列表/卡片按压反馈统一 `.hoverEffect()` + `.scale(0.98)` + animateTo(踩坑 1:Row/Column 无 stateEffect);弹窗统一系统 AlertDialog 风格(确认按钮在右);Toggle/TextInput/Select 等保持系统默认形态,不自绘
- F7c 颜色收敛鸿蒙化:全仓 grep 十六进制色值清零(含 Index.ets latencyColor 的 #2E7D32/#F9A825 等),全部替换为 `$r('app.color.xxx')` 语义令牌并保证 base/dark 双份(延迟良好/中等/超时等状态色保留语义命名,深色下核对对比度);EntryAbility 里 setWindowSystemBarProperties 让状态栏前景色跟随深浅色;页面内容正确避让安全区,不滥用 expandSafeArea
- F7d 大屏/横屏适配(真机为 MatePad mini):单列表页在宽屏下限制最大内容宽度(如 600vp 居中),横屏不得溢出、截断、遮挡;**日志页固定终端配色是刻意设计,本项不得改动**
- 验收:真机与系统设置应用并排对比,圆角/间距/按钮/列表观感一致;深浅色切换即时生效;横竖屏无破版;F7 范围内无新增硬编码色值

## 后续阶段(本轮不做,仅预告)

- G1 节点置顶/收藏/手动排序;G2 分组测速汇总(组卡片显示最低延迟);G3 节点分享 URI/二维码生成;G4 远程规则集订阅(sing-box 1.11 rule_set,配置层接入);G5 连接统计(速率/流量/连接列表,计划经 clash_api 查询,真机验证可行性)

## 完成标准与交付

1. 全部完成后自查:引用/导入完整、与现有 model/pages 接口一致、无硬编码色值残留(F1 范围内)、对照 Index.ets 风格
2. `CHANGES.md` 逐项追加:F1~F7 各节(状态:完成/部分完成+原因、改动文件、限制)
3. 最后输出总结:各功能完成情况、改动文件分组清单、标注的风险点(尤其是 F3/F4 真机才能验证的部分)
4. 不构建、不 commit;等构建机编译反馈,有错误按反馈修复
