# NekoBox for Harmony —— 当前交接(2026-10-24 / 全面改造 P0–P5 已完成)

> 接手 agent 先读这一节。下面「历史交接(G 阶段 → 1.6.0)」为旧内容,仅作存档,已被本节取代。
> **2026-10-28 版本 2.4.0**:远程规则集启动解耦(配置层零 type:remote)+ 会话资源固定 + 规则集页镜像字段修正;版本号统一 2.4.0/2400000;release 未签名产物见 dist/(AGC 签名待密码)。Node 43 套件全 PASS。权威方案 docs/REMOTE_RULESET_FINAL_REMEDIATION_SPEC.md。

> 权威方案:`docs/REDESIGN-PLAN-2026-10-23.md`(7 页 IA / 三模型分离 / 探测重构 / 配置快照 / 应用事务 / 阶段划分 W01–W22、REQ-01–REQ-24)。
> 进度真值:`docs/req-traceability.md`(24 条需求逐条状态 + 证据)。写任何"已完成"前必须先看它,不得凭印象。

## 1. 现在做到哪了(全部有主机证据,工作区 `C:\Worker\NekoBox4Harmony`)

| 阶段 | 状态 | 证据/报告 |
|---|---|---|
| P0 基线与技术验证 | ✅ | `docs/p0-baseline/` |
| P1 配置仓库/迁移/v4→v5/K1+K2 内核 | ✅ | `docs/p1-foundation/README.md`、`docs/p1-design/runtime-protocol.md` |
| P2 检测体系(ProbeResult/Coordinator/Runner/Store/Filters) | ✅ | `docs/p2-foundation/README.md`、`docs/p2-design/probe-system.md` |
| P3 七页导航 + 节点首页 + 订阅页 | ✅ | `docs/p3-foundation/README.md`、`docs/p3-design/navigation-and-home.md` |
| P4 分流与设置应用(W13/W14/W15/W16) | ✅ | `docs/p4-foundation/README.md`、`docs/p4-design/apply-transaction.md` |
| P5 订阅三层模型+诊断(W17–W20) | ✅ | `docs/p5-foundation/README.md` |
| P6 适配与回归(W21) | ✅ | `docs/p6-foundation/README.md` |
| P7 发布检查(W22) | ✅ 文档轮(真机项全部「待验」) | `docs/p7-release/README.md`、`docs/upgrade-notes-2.2.md` |

最近一次全量验证(2026-10-24 末,**真机反馈第三轮后**,仍为 2.3.0/2300000):Node 41 套件全 PASS、Go PASS、BUILD SUCCESSFUL(HAP 14,993,633 B,.so `9b05c0bf…`);真机已装并复核:系统页(工具+关于合并)渲染正常、VPN 可连且内核 0 ERROR、分流页顶距 33px、新建规则页不再被状态栏遮挡。此前轮:2.3.0 AGC 双层签名产物见 dist/。复审修复 4 项(连接页 startTimeText 模板串 [object Object] bug/单列点击不跳详情/详情视图让位/closeDetail 清理)后,`assembleHap`+`assembleApp` BUILD SUCCESSFUL;内层 HAP 2.3.0/release,包内 `libs/arm64-v8a/libsingbox.so` sha256 `9b05c0bf…`(**16 导出,冻结内核未动**);**Node 42 套件全 PASS**(`i18n-keys` 含新增占位符中英一致 122 键);`tests/hostprobe` Go PASS;资源键 base/en_US 各 835 对称。**AGC 双层签名完成**(两层 verify + 发布证书指纹断言):`dist/NekoBox-2.3.0-release-signed.hap`(SHA256 `1331FAE8…`)、`dist/NekoBox-2.3.0-release-signed.app`(`1C5E73BA…`)、`dist/NekoBox4Harmony-2.3.0-unsigned.hap`。真机安装/回归**全部待验**(本机 `hdc list targets` 为空,没有设备;release profile 含 udid 白名单,装不上先查白名单)。

## 2. 必读顺序(30 分钟内可掌握全貌)

1. 本节 → 2. `AGENTS.md`(架构/内核/构建/保活与权限口径)→ 3. `DEVPLAN.md`(任务与验收状态)→ 4. `docs/req-traceability.md`(需求矩阵)→ 5. 上一阶段的 `docs/pN-foundation/README.md`(降级项与遗留都写在那里)→ 6. `CHANGES.md`(按时间倒序的行为变更)→ 7. `docs/upgrade-notes-2.2.md`(用户可见行为变化,发布前必须同步)。

## 3. 剩余工作(按 P5 → P6 → P7 顺序,建议每阶段一轮、每轮留证据)

### P5 订阅与诊断(W17–W20)—— ✅ 已完成(2026-10-24,详见 `docs/p5-foundation/README.md`)
- 三层模型 `model/SubscriptionLayers.ets`(身份键=订阅URL+传输特征指纹,**显示名不参与**;两级合并:身份优先→名称锚点,歧义记冲突);原始层独立文件 `core/SubscriptionSourceStore.ets`(每订阅留 2 份,刻意不放 ConfigSnapshot——配置快照只留 3 个 revision 会 GC 掉历史);覆盖层唯一持久化位置=`ConfigSnapshot.content.userOverrides`,写入只经 `ConfigRepository.commit`。
- 更新事务 `core/SubscriptionRepository.ets`:锁外下载解析、提交前基线 revision 比对(漂移→按当前内容重算)、**304 只推进成功检查时间**、失败落 lastError/lastAttemptAt;`Subscriptions.updateSubscription` 保留原签名做委托。
- W18:订阅页「清空节点」/「查看节点/检测可用性」/逐订阅更新结果行;SubDetailPage 墓碑区+「转为手动节点」(原始层还原,找不到记录拒绝)。
- W19:ConnectionsPage 重写(搜索/分类筛选/开始时间/证据弹窗);rulePayload 未提供就显示「未提供」不伪造;规则名链接恒空留 K3。
- W20:日志清除记偏移+文件身份(`log_clear_marker`,跨页面重建旧日志不重现);导出默认脱敏可预览(「导出原文」红色次要);显示流量走基准偏移(`traffic_display_baseline`,修复清除被 1s 轮询写回;通知侧会话启动同步一次=已知降级);诊断包 `core/Diagnostics.ets`+工具页入口(不含密钥/订阅 URL,不自动上传)。
- 行为变更(升级说明需收录):远端改名不再 加+删(身份匹配保 id/收藏/排序);forceResolve+动态 DNS 场景服务器 IP 变会表现为加+删(与 Android 按名合并取舍不同)。

### P6 适配与回归(W21)—— ✅ 已完成,双栏按真机反馈撤回(2026-10-24,详见 `docs/p6-foundation/README.md`)
- 断点 600/840 双栏**曾交付后撤回**(真机用户明确不要侧边节点详情栏):ResponsiveLayout 模型/测试/接线/5 个 nodes_detail_* 键全部移除,节点页手机平板一律单列;`p6-ui-static` 第 5 组守"无侧栏"防回潮。状态卡「连接」主按钮同轮撤(走大电源键),检查连接/详情保留。
- i18n 收口:设置页 `SETTING_LABELS` 54/54 + `SECTION_LABELS` 9/9(`i18n-keys.cjs` 已收紧为强制对齐);订阅/连接/日志/订阅详情 P5 文案全部资源键化(模型 token 化,base/en_US 各 835 对称);`p6-ui-static.cjs` 静态守卫防中文兜底回潮。
- 44×44vp 热区(responseRegion)、顶栏图标无障碍名称+禁用原因(nav_action_*/nav_reason_*)、延迟/速率/流量等宽。
- 降级:Index 壳层 P3 状态卡中文(~200 处)与 HomeView 延迟 token 中文留下一轮;字体档位/读屏/键盘走查待真机。

### P7 发布检查(W22)—— ✅ 文档轮完成(2026-10-24,详见 `docs/p7-release/README.md`)
- `docs/upgrade-notes-2.2.md` 已收录 P5/P6 全部行为变更(订阅三层/远端改名不再加删/304 语义/流量清除改基准/导出默认脱敏/双栏)。
- §24.2 十条检查清单 + §24.3 交付物矩阵 + §22 设备验收矩阵在 `docs/p7-release/README.md`,逐项给证据与状态。**设备不到位,真机项全部标「待验」,未写通过。**

### P4 遗留(小项,半小时级)
1. 设置页 `SETTING_LABELS` 扩到 54 条(资源键已存在);
2. 分应用完整名单管理从设置页迁到分流页(现在分流页是摘要+入口);
3. 策略组切换 UI 仅覆盖运行图 `proxy` 组,多组稳定 tag 切换待接;
4. `runningGroupTags` 由壳层下发(目标选运行中分组时标"不可用",防出站自环);
5. 壳层待应用横幅暂不显示差异计数(`diffSettings` 已可用,接一下即可)。

## 4. 铁律(违反即返工)

1. **不做 git 写操作**:不 commit / 不 push / 不 reset / 不 checkout。工作树本来就带大量未提交改动,基线 HEAD 为 `de481f56`,P0 前快照在 git stash「P0-baseline 2026-10-24 redesigned snapshot」。
2. **`entry/libs/arm64-v8a/libsingbox.so` 是冻结成品(16 导出,sha256 `9b05c0bf…`)**:不加新 CGo 导出就不用重编;若必须加,**只准加 V2/V3 后缀 + dlsym 回退,绝不原地改老签名**(旧 NAPI + 新 .so 会野指针崩溃)。改 `core/**` 必须重编 .so **并**重新 assembleHap。
3. **不动 `module.json5` / `build-profile.json5` / `AppScope`**:`backgroundModes: ["dataTransfer"]` 与 `READ_PASTEBOARD` 必须保留(删了真机保活失败、AGC 退回);不申请 `KEEP_BACKGROUND_RUNNING_SYSTEM`/`USE_FRAUD_APP_PICKER`;VPN type 保持 `"vpn"`。改权限同步 `docs/PRIVACY-POLICY.md` 并跑 `node tests/permission-policy.cjs`。
4. **配置写入只走 `core/ConfigRepository.commit(mutation)`**:直接写 Preferences = 绕过快照/迁移/校验,视为返工。三段 revision(保存/请求/运行)语义见 `docs/p4-design/apply-transaction.md`。
5. **测试不许删断言换绿**:主机测试是唯一可交付证据;真机项一律标「待验」。新增模型要配 VM 转译测试(`tests/*.cjs`:DevEco SDK `typescript.js` + `vm.runInNewContext` + 桩 import),防漂移测试优先(读源码比对,如 `settings-schema`/`i18n-keys`)。
6. **ArkTS 严格模式**:禁 `any` / `delete` / `Function.call` / `Object.prototype.hasOwnProperty.call` / prototype 赋值;class 实例不能当 `Record`;改用 `Object.keys().indexOf()` 与"白名单拷贝"。
7. **UI 口径**:底部速率条半透明 + `.backdropBlur(20)`,不要 `backgroundBlurStyle(COMPONENT_*)`;延迟分档 `<150 绿 / 150–399 琥珀 / ≥400 红`。

## 5. 构建与验证命令(Windows,勿开 DevEco GUI)

```bash
cd C:/Worker/NekoBox4Harmony
# 构建(必须带 JBR,否则 PackageHap 报 spawn java ENOENT)
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' \
PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH" \
node hvigorw.js --mode module -p product=default -p buildMode=release assembleHap --no-daemon
# 产物 entry/build/default/outputs/default/entry-default-unsigned.hap

# 全仓测试(排除两个生成器脚本)
for t in tests/*.cjs; do n=$(basename $t); case "$n" in generate-dns-fixtures.cjs|geo-srs.cjs) continue;; esac; node "$t" || echo "FAIL $n"; done
cd tests/hostprobe && go test -count=1 ./...

# 包内 .so 核对
python -c "import zipfile,hashlib;z=zipfile.ZipFile('entry/build/default/outputs/default/entry-default-unsigned.hap');print(hashlib.sha256(z.read('libs/arm64-v8a/libsingbox.so')).hexdigest()[:16])"
```

## 6. 已知环境限制

- **无真机**:`hdc list targets` → `[Empty]`。TUN 实际转发、分应用真实流量、DNS 泄漏、后台保活、应用事务杀进程恢复、返回栈、浅深色视觉**全部只能「待验」**。
- `tests/geo-srs.cjs` 依赖 GitHub 匿名 API,本机出口 IP 会 403(环境问题,已从全量扫描排除,不要当回归)。
- 依赖安装/网络受限时不要改构建配置绕过,先如实报告。

---

# 历史交接(G 阶段 → 目标 1.6.0,已过时,仅存档)

# NekoBox for Harmony 交接指令(G 阶段 → 目标 1.6.0)

> 交接日期:2026-09-03。给接手开发 agent 的完整指令,自包含;各项详细方案与验收标准以同目录 `DEVPLAN.md` 为准,上一阶段实现记录见 `CHANGES.md`,架构见 `AGENTS.md`。

## 0. 角色分工与工作区(工作区在远程服务器)

- **你(开发 agent)通过 SSH 在服务器工作区实时修改代码**:
  - 连接:`ssh root@oc1.720820.xyz`(端口 22;FTP 同账号、PASV 模式,登录根目录即 `/worker`。**root 密码存 ZCode 持久记忆 `dev-credentials.md`,禁止写入本仓库任何文件**——本文件旧版曾含明文密码且仓库公开,该密码必须视为已泄露并轮换)
  - 工作目录:`/worker/NekoBox4Harmony`(完整 git 仓库,含冻结内核与构建脚本)
  - 你只改 `entry/src/main/ets/` 与 `entry/src/main/resources/` 下的文件
- **构建机(ZCode,Windows)** 负责:从服务器收走你的改动 → 编译未签名 HAP → 提交推送 GitHub → 把新基线同步回服务器。构建/打包/git 写操作都归它。
- 因此你在服务器上:**不做任何 git 写操作**(commit/push/reset/checkout 不做;`git status/diff/show/log` 只读可用),展示改动用 `git diff`;不启动构建/打包
- `core/` 内核、`entry/libs/arm64-v8a/libsingbox.so`、CGo 接口一律冻结;`AppScope/app.json5` 版本号与 `build-profile.json5` 签名配置由构建机管理
- 当前基线:**2.2.0(versionCode 2200000)** —— 版本号已于 2026-10-23 全仓统一(`AppScope/app.json5`、根/entry `oh-package.json5`、文档),历史基线为 1.5.8(versionCode 1001800,commit eb35129)。已交付:**F1~F7 全部**(深色主题、通知延迟+断开按钮、订阅后台更新、per-app 图形选择器、备份文件化、中英双语 264 键、鸿蒙原生观感)——F7 已真机验收,F2~F6 待日常复核,**一律勿重做**。开工前 `git log --oneline -3` 确认基线、`git status --porcelain` 为空

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
2. G6 已单独交付完毕;剩余 **G1 → G2 → G3 → G4 → G5 由你一次性全部开发完成后统一交付**(用户指定,不分阶段);开发顺序建议按上序,每完成一项仍须立即同步该项 DEVPLAN 状态行与 CHANGES.md 记录,全部做完一次性汇报"已完成 G1~G5,请构建"
3. 每完成一项:先按铁律第 6 条同步 `DEVPLAN.md` 状态行与 `CHANGES.md` 记录,**再**停下汇报"已完成 XX 项,请构建"
4. 构建机收走改动并编译(必要时预检 SDK d.ts),把编译输出原样反馈;你只改报错项,修完再次同步文档
5. 构建机每轮结束把新基线同步回本工作区;你开工前先 `git log --oneline -3` 确认基线,再继续下一项
6. 服务器不 push;git 写操作归构建机

## 5. 完成标准

- 引用/导入完整,与现有 model/pages 接口一致;无新增硬编码色值/硬编码中文;对照 `pages/Index.ets` 风格
- `CHANGES.md` 逐项:G 各节(状态、改动文件、已知限制);G3/G5 降级路径必须留记录
- `DEVPLAN.md` 各项"状态"行与实际一致
- 全部完成后构建机升 versionName 1.6.0 发 release;不构建、不 commit;等构建机编译反馈,有错误按反馈修复
