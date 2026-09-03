# NekoBox for Harmony 交接指令(F 阶段 → 目标 1.5.8)

> 交接日期:2026-09-03。给接手开发 agent 的完整指令,自包含;各项详细方案与验收标准以同目录 `DEVPLAN.md` 为准,上一轮实现记录见 `CHANGES.md`,架构见 `AGENTS.md`。

## 0. 角色分工与工作区(工作区在远程服务器)

- **你(开发 agent)通过 SSH 在服务器工作区实时修改代码**:
  - 连接:`ssh root@oc1.720820.xyz`(密码 `Lijx.820115`,端口 22;FTP 同账号同密码、PASV 模式,登录根目录即 `/worker`,可用来浏览/取文件)
  - 工作目录:`/worker/NekoBox4Harmony`(完整 git 仓库,含冻结内核与构建脚本)
  - 你只改 `entry/src/main/ets/` 与 `entry/src/main/resources/` 下的文件
- **构建机(ZCode,Windows)** 负责:从服务器收走你的改动 → 编译未签名 HAP → 放 `dist\` → 提交推送 GitHub → 把新基线同步回服务器。构建/打包/git 写操作都归它。
- 因此你在服务器上:**不做任何 git 写操作**(commit/push/reset/checkout 不做;`git status/diff/show/log` 只读可用),展示改动用 `git diff`;不启动构建/打包
- `core/` 内核、`entry/libs/arm64-v8a/libsingbox.so`、CGo 接口一律冻结;`AppScope/app.json5` 版本号与 `build-profile.json5` 签名配置由构建机管理
- 当前基线:**1.5.7(versionCode 1001714)**。已交付:A~D 功能(节点分组、编辑实时校验、测速集成、自定义分流规则、订阅调度、备份 v3)+ **F1 深色主题、F2 通知栏增强、F3 订阅后台更新、F4 per-app 选择器(F2~F4 已交付,待真机验证,勿重做)**

## 1. 本阶段任务(F5~F7 待开发;详细方案与验收标准见 `DEVPLAN.md` 对应小节)

| 项 | 内容 | 限制 |
|---|---|---|
| F2 | ✅已交付(待真机验证) 通知栏增强:测速延迟经 CommonEvent 同步到 VPN 扩展进程更新常驻通知;通知加"断开/连接"按钮(wantAgent + onNewWant) | 纯应用层 |
| F3 | ✅已交付(待真机验证) 订阅后台定时更新(backgroundTaskManager 连续任务;真机受限降级 transientTask 并记录) | 仅本项允许改 module.json5 两处:KEEP_BACKGROUND_RUNNING 权限 + backgroundModes |
| F4 | ✅已交付(待真机验证) per-app 图形选择器(legacy @ohos.bundle 枚举已装应用;失败自动降级现有手输包名 UI) | 仅本项允许加 GET_BUNDLE_INFO 权限 |
| F5 | 备份文件化(DocumentViewPicker 导出/导入 schema v3 备份) | 纯应用层 |
| F6 | 中英多语言收尾(base=中文,en_US=英文,全量抽取硬编码字符串) | 纯应用层 |
| F7 | UI 适配鸿蒙:布局/间距/圆角统一、控件对齐系统风格、硬编码色值清零、状态栏/安全区、大屏横屏适配 | 纯应用层;日志页终端配色不动 |

## 2. 铁律(违反即返工;全文见 `DEVPLAN.md` "铁律"节)

1. 内核冻结:不改 `core/`、不改任何 .so 与 CGo 接口(CGoStartSingBox / CGoStopSingBox / CGoSetTunFd / CGoSingBoxVersion)
2. `module.json5` 的 `"type": "vpn"` 永远不动;整文件仅允许 F3/F4 各自声明的权限与 backgroundModes 改动,其余一字不动
3. `build-profile.json5`(含 signingConfigs)、`AppScope/app.json5`(版本号)一律不碰
4. 不碰 `entry/build/`、`dist/`、`.hvigor/`;**不做任何 git 写操作**;不启动构建/打包
5. 行尾保持 LF;页面风格、主题色对齐 `pages/Index.ets` 现有写法
6. **文档同步义务(硬性)**:每完成/部分完成/降级一项,必须立即 ①更新 `DEVPLAN.md` 该项的"状态"行,②在 `CHANGES.md` 末尾按既有格式追加(日期、功能、改动文件列表、已知限制)。**开发文档未同步 = 该项未完成。**

## 3. 踩坑必读(完整列表见 `DEVPLAN.md`)

- ArkTS:`Row`/`Column` **没有** `.stateEffect()`;`$r()` 返回 `Resource`,**声明返回 `string` 的函数不能返回 `$r()`,颜色值统一用 `ResourceColor`**(上一轮 Index.ets 的 latencyColor 就因此编译失败,已修,别再犯)
- 深色配色一律用 `$r('app.color.xxx')`(base + dark 两套资源已就绪),不要写死十六进制色值
- 日志页的固定终端配色(深底浅字)是刻意设计,不要"修"成跟随主题
- `hvigorw.js` 的 `__ohosCmdPatch` 补丁(Node ≥18.20 的 .cmd 子进程 EINVAL 修复)勿覆盖
- `entry/libs/arm64-v8a/libsingbox.so` 是冻结内核成品,严禁删改;丢失会构建出无内核的坏包

## 4. 工作流程(双端循环)

1. 先读:`DEVPLAN.md`(铁律/踩坑/F2~F7 方案与验收)、`CHANGES.md`(上一轮实现与 API 限制)、`AGENTS.md`(架构)
2. 剩余任务按 F5 → F6 → F7 顺序开发(F7 UI 适配放最后,功能落地后一次收尾);每项独立可交付,允许逐项交付
3. 每完成一项:先按铁律第 6 条同步 `DEVPLAN.md` 状态行与 `CHANGES.md` 记录,**再**停下汇报"已完成 XX 项,请构建"
4. 构建机收走改动并编译,把编译报错原样反馈;你只改报错项,修完再次同步文档
5. 构建机每轮结束会把新基线同步回本工作区;你开工前先 `git log --oneline -3` 确认基线,再继续下一项
6. 服务器到 GitHub 的网络时好时坏,但 git 写操作归构建机,你不要 push

## 5. 完成标准

- 引用/导入完整,与现有 model/pages 接口一致;F 范围内无新增硬编码色值;对照 Index.ets 风格
- `CHANGES.md` 逐项:F2~F7 各节(状态:完成/部分完成+原因、改动文件、已知限制)
- `DEVPLAN.md` 各项"状态"行与实际一致
- 不构建、不 commit;等构建机编译反馈,有错误按反馈修复
