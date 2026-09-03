# NekoBox for Harmony 交接指令(G 阶段 → 目标 1.6.0)

> 交接日期:2026-09-03。给接手开发 agent 的完整指令,自包含;各项详细方案与验收标准以同目录 `DEVPLAN.md` 为准,上一阶段实现记录见 `CHANGES.md`,架构见 `AGENTS.md`。

## 0. 角色分工与工作区(工作区在远程服务器)

- **你(开发 agent)通过 SSH 在服务器工作区实时修改代码**:
  - 连接:`ssh root@oc1.720820.xyz`(密码 `Lijx.820115`,端口 22;FTP 同账号同密码、PASV 模式,登录根目录即 `/worker`)
  - 工作目录:`/worker/NekoBox4Harmony`(完整 git 仓库,含冻结内核与构建脚本)
  - 你只改 `entry/src/main/ets/` 与 `entry/src/main/resources/` 下的文件
- **构建机(ZCode,Windows)** 负责:从服务器收走你的改动 → 编译未签名 HAP → 提交推送 GitHub → 把新基线同步回服务器。构建/打包/git 写操作都归它。
- 因此你在服务器上:**不做任何 git 写操作**(commit/push/reset/checkout 不做;`git status/diff/show/log` 只读可用),展示改动用 `git diff`;不启动构建/打包
- `core/` 内核、`entry/libs/arm64-v8a/libsingbox.so`、CGo 接口一律冻结;`AppScope/app.json5` 版本号与 `build-profile.json5` 签名配置由构建机管理
- 当前基线:**1.5.8(versionCode 1001800,commit eb35129)**。已交付:**F1~F7 全部**(深色主题、通知延迟+断开按钮、订阅后台更新、per-app 图形选择器、备份文件化、中英双语 264 键、鸿蒙原生观感)——F7 已真机验收,F2~F6 待日常复核,**一律勿重做**。开工前 `git log --oneline -3` 确认基线、`git status --porcelain` 为空

## 1. 本阶段任务(G6 → G1 → G2 → G3 → G4 → G5,详细方案与验收见 `DEVPLAN.md`)

| 项 | 内容 | 限制 |
|---|---|---|
| G6 | 通知栏文案资源化(VpnExtAbility 硬编码中文 → string.json 双份;状态键保持机器键) | 纯应用层 |
| G1 | 节点手动排序(长按上移/下移写 sortOrder;排序模式 手动/按延迟/按名称 入设置) | 纯应用层 |
| G2 | 分组测速汇总(组头最低延迟徽标 + n 未测 + "测速本组"按钮) | 纯应用层 |
| G3 | 节点/订阅分享二维码(@kit.ScanKit generateBarcode;不可用降级纯文本+复制并记录) | 纯应用层;降级路径必须实现 |
| G4 | 远程规则集订阅(规则页管理 .srs 源;ConfigBuilder 输出 sing-box 1.11 route.rule_set;失败跳过不影响启动) | 纯应用层;备份 schema 需兼容 v3 |
| G5 | 连接统计(ConfigBuilder 开 clash_api 127.0.0.1:9090+随机 secret;连接页轮询 /connections,速率/列表/关闭单条) | 纯应用层;真机风险项,降级路径必须实现 |

- **G 阶段不允许任何 module.json5 改动**(G4/G5 均无需新权限)

## 2. 铁律(违反即返工;全文见 `DEVPLAN.md` "铁律"节)

1. 内核冻结:不改 `core/`、不改任何 .so 与 CGo 接口(CGoStartSingBox / CGoStopSingBox / CGoSetTunFd / CGoSingBoxVersion)
2. `module.json5` 的 `"type": "vpn"` 永远不动;本阶段整文件一字不动
3. `build-profile.json5`(含 signingConfigs)、`AppScope/app.json5`(版本号)一律不碰
4. 不碰 `entry/build/`、`dist/`、`.hvigor/`;**不做任何 git 写操作**;不启动构建/打包
5. 行尾保持 LF;`hvigorw.js` 的 `__ohosCmdPatch` 补丁勿覆盖
6. **文档同步义务(硬性)**:每完成/部分完成/降级一项,必须立即 ①更新 `DEVPLAN.md` 该项"状态"行,②在 `CHANGES.md` 末尾按既有格式追加(日期、功能、改动文件列表、已知限制)。**开发文档未同步 = 该项未完成。**

## 3. 踩坑必读(完整 10 条见 `DEVPLAN.md`)

- **禁止把 `$r()` 写进模板串**:动态整句进 string.json 用 `%1$s`/`%1$d` 占位符,代码 `$r('app.string.x', args)`;返回可能为资源的函数声明 `ResourceStr`;`$r` 键名编译期校验
- **`AppStorage('vpnStatus')` 只存机器键**(connecting/disconnected/switching/awaiting_auth/start_timeout/`connected:<节点>`/`start_failed:<详情>`/`connect_failed:<详情>`),显示走 `Index.statusDisplay()`
- 函数参数不能声明 `unknown`;`catch (e)` 传辅助函数前先转字符串
- `Row`/`Column` 无 `.stateEffect()`;并排按钮行一律 `layoutWeight(1)` 等分(F7 真机验证的防溢出写法);日志页终端配色不要动
- constraintSize 限宽时**内层包装 Column 必须带 `.width('100%').height('100%')`**,否则测量超宽(F7 真机踩过)
- API 24 枚举应用用旧模块 `@ohos.bundle`;新 API 不确定先写降级路径,构建机会用本机 d.ts 预检
- `libsingbox.so` 冻结成品严禁删改;签名证书配置永不入库

## 4. 工作流程(双端循环)

1. 先读:`DEVPLAN.md`(铁律/踩坑/G1~G6 方案与验收)、`CHANGES.md`(F 阶段实现记录与 API 限制)、`AGENTS.md`(架构)
2. 按 **G6 → G1 → G2 → G3 → G4 → G5** 顺序开发(G5 风险最高最后做);每项独立可交付,允许逐项交付
3. 每完成一项:先按铁律第 6 条同步 `DEVPLAN.md` 状态行与 `CHANGES.md` 记录,**再**停下汇报"已完成 XX 项,请构建"
4. 构建机收走改动并编译(必要时预检 SDK d.ts),把编译输出原样反馈;你只改报错项,修完再次同步文档
5. 构建机每轮结束把新基线同步回本工作区;你开工前先 `git log --oneline -3` 确认基线,再继续下一项
6. 服务器不 push;git 写操作归构建机

## 5. 完成标准

- 引用/导入完整,与现有 model/pages 接口一致;无新增硬编码色值/硬编码中文;对照 `pages/Index.ets` 风格
- `CHANGES.md` 逐项:G 各节(状态、改动文件、已知限制);G3/G5 降级路径必须留记录
- `DEVPLAN.md` 各项"状态"行与实际一致
- 全部完成后构建机升 versionName 1.6.0 发 release;不构建、不 commit;等构建机编译反馈,有错误按反馈修复
