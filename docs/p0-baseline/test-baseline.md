# P0 基线：测试基线与内核导出核验

对应方案：`docs/REDESIGN-PLAN-2026-10-23.md` 的 P0「基线与技术验证」。
对照基线：`docs/FUNCTIONAL-AUDIT-2026-10-23.md` §4 验证记录。
执行时间：2026-10-24 09:46—10:00（Asia/Shanghai）。
约束：本轮**未修改任何源文件**；工作区保留原有未提交修改；仓库唯一写入为本文件（`docs/p0-baseline/`）。

## 1. 执行环境

| 项目 | 值 |
|---|---|
| 工作目录 | `C:/Worker/NekoBox4Harmony` |
| 分支 / HEAD | `debug` / `de481f56`（最近提交 2026-10-17 21:35） |
| 未提交改动 | 80 个文件（与本轮开始前一致；构建前后 `git status --porcelain` diff 为 0） |
| 操作系统 | Windows 10 10.0.19045.7727，Git Bash（MINGW64） |
| Node | v24.20.0 |
| Go | go1.27.0 windows/amd64（`C:\Program Files\Go\bin\go.exe`） |
| DevEco SDK | `C:\Program Files\Huawei\DevEco Studio\sdk`（`default/openharmony`） |
| llvm-readelf | LLVM 15.0.4，实际路径 `sdk/default/openharmony/native/llvm/bin/llvm-readelf.exe` |
| 内核库 | `entry/libs/arm64-v8a/libsingbox.so`，35,688,144 字节，mtime 2026-09-26 19:10（未重编） |

路径更正：任务书给出的 `sdk/default/openharmony/toolchains/llvm/bin/llvm-readelf.exe` 不存在；该 SDK 的 readelf 实际在 `sdk/default/openharmony/native/llvm/bin/`（另有 `sdk/default/hms/native/BiSheng/bin/llvm-readelf.exe`，属 HMS 工具链，本轮未用）。

## 2. Node 套件基线

执行方式：仓库根目录 `node tests/<name>.cjs`，逐套件捕获 stdout/stderr 与退出码。

`tests/*.cjs` 共 20 个文件。其中 `generate-dns-fixtures.cjs` **不是测试而是生成器**（头部注释 "Generate DNS blocks from production ETS"；通过 DevEco SDK 的 typescript 转译生产 `ConfigBuilder.ets` 后写出 `tests/hostprobe/fixtures/production-dns.json`），按任务要求**未运行**。其余 19 个套件全部运行。

| 套件 | 结果 | 断言数 | 备注 |
|---|---|---|---|
| `functional-audit.cjs` | PASS | 4 | 2026-10-23 新增回归，锁定 §1 修复项：分应用保存失败保留 dirty 且不重启 VPN、测速保存按 ID 合并（新增/编辑/删除/未测保留）、测速存储失败必释放 testing 标志、TCPing 与网卡绑定回退提示可见 |
| `parity-config.cjs` | PASS | 40 | 本轮扩展回归；生产代码主机测试，非设备/UI 验收（套件自述） |
| `subscription-parse.cjs` | PASS | 41 | 订阅解析 |
| `per-app.cjs` | PASS | 21 | 分应用名单派生与扩展侧解析过滤 |
| `route-rules-ui.cjs` | PASS | 3 | 历史红灯套件，本轮已修复：remote rule-set key 覆盖 type/outbound/enabled/lastError/index、忽略 name/url/updatedAt，custom key 覆盖 outbound+index |
| `home-view.cjs` | PASS | 7 | 分组折叠状态序列化/迁移、订阅视图与手动视图互斥 |
| `clash-auth.cjs` | PASS | 9 | 本轮扩展回归；Bearer 鉴权、401 提示、delay 非负有限校验、selector/流量轮询 |
| `latency-parity.cjs` | PASS | 18 | 本轮扩展回归；测速判据、HEAD→GET 回退、取消/收尾/降级 |
| `ipv6-backup.cjs` | PASS | 7 | 备份导出/导入五模式 + 非法模式拒写 |
| `ipv6-modes.cjs` | PASS | 16 | 曾按实际 `SettingsPage`/`fabLayer` 修正过时断言的套件；四模式 × FakeIP 生成 |
| `ipv6-store.cjs` | PASS | 8 | 真实 Store/RouteRule 存取往返、legacy 布尔迁移 |
| `sub-etag.cjs` | PASS | 15 | ETag/304 |
| `sub-ua-fallback.cjs` | PASS | 17 | UA 回退 |
| `sub-parity-subscription.cjs` | PASS | 48 | 订阅 Android 对齐 |
| `notify-text.cjs` | PASS | 12（输出 1 行 PASS，套件自报 "12 组通过, 0 组失败"） | 通知文案，按组统计 |
| `outbound-graph.cjs` | PASS | 9 | 生产出站图（前置/落地/链/环检测）；套件自述不等于设备热切换验收 |
| `permission-policy.cjs` | PASS | 7 | 权限策略 |
| `keepalive-policy.cjs` | PASS | 19 | 保活/长时任务策略 |
| `geo-srs.cjs` | **FAIL（exit 1）** | 12 通过 / 2 失败 / 0 跳过 | **环境性失败，非代码回归**，详见下文 |
| `generate-dns-fixtures.cjs` | 未运行 | — | 生成器，非测试（见上） |

**汇总：19 个测试套件 → 18 PASS，1 FAIL（环境）。** 输出 `PASS` 断言行合计 **302** 条；按套件自报组数折算 **313** 条（`notify-text` 以 1 行代表 12 组）。`FAIL` 断言行 2 条，`SKIP` 行 0 条。

### 2.1 geo-srs.cjs 失败鉴定（环境，不是回归）

失败项：

```text
FAIL upstream sing-geosite/geosite-cn.srs exists — HTTP 403
FAIL upstream sing-geoip/geoip-cn.srs exists — HTTP 403
12 geo checks passed, 2 failed
```

复核证据：

- 直接请求 `https://api.github.com/repos/SagerNet/sing-geosite/contents/geosite-cn.srs?ref=rule-set` 返回 `403`，响应体为 `{"message":"API rate limit exceeded for 34.81.252.98. ..."}`。
- `GET https://api.github.com/rate_limit` 显示 `core: {"limit":60,"remaining":0,"used":60}`，重置时间 `2026-10-24T02:25:31Z`（本地 10:25）。即共享出口 IP 的**匿名 API 配额已耗尽**。
- 该套件只在网络不可达（`status === 0`）时打印 `SKIP`；HTTP 403 落入 `FAIL` 分支——所以这属于"外部依赖被限流"，不是仓库内容变化。
- 连续两次运行结果完全相同，可确定性复现。
- 该套件的 12 条离线断言（文件名常量 `.srs`、无遗留 `.db` URL、镜像数与首选源、4KB 门槛、SRS 魔数校验、`format=binary`）**全部通过**。
- 本轮反而比 §4 多获得一条真实的绿：`PASS primary source serves valid SRS (56468 bytes)`——2026-10-23 该检查因 ECONNRESET 被跳过，本次实际下载并校验了 SRS 魔数成功。

建议（不改测试，仅登记）：把 GitHub API 的 `403`/`429`（限流）与网络不可达同等视为 `SKIP`，否则该套件在共享出口 IP 环境下会长期假红；真正的可用性证据应以上述"首选源实际下载 + 魔数"检查为准。

### 2.2 关于"复现已知问题"性质的套件

19 个 Node 套件全部是**回归/锁定已修复行为**的正向套件，没有一个是"复现现存缺陷"的套件；`functional-audit.cjs` 是最直接的修复回归包（对应审计 §1）。"确认现存问题"的复现测试集中在 Go 侧（见 §3）。

## 3. Go 套件基线

命令：`cd tests/hostprobe && go test -v -count=1 ./...` → **exit 0，耗时 2.063s**。

| 包 | 结果 | 顶层测试 | 断言（含子测试） |
|---|---|---|---|
| `parityprobe` | PASS | 16 PASS / 0 FAIL / 0 SKIP | 49 个 RUN 行 = 16 顶层 + 33 子测试 |
| `parityprobe/genfixture` | `[no test files]` | — | — |

16 个顶层测试（全部通过）：

| # | 测试 | 覆盖 |
|---|---|---|
| 1 | `TestFakeIPStrategySchemaShape` | FakeIP 策略字段 schema 形状（含 server/rule 级 legacy strategy） |
| 2 | `TestAuditURLTestResponsePolicy` | 200/204/302/403/404/500 × any/2xx 两种判据 |
| 3 | `TestAuditURLTestHeadFallback` | 405/501 的 HEAD→GET 回退 |
| 4 | `TestAuditUncachedRemoteRuleFailureBlocksStart` | **确认现存问题**：远程 SRS 首次下载 503 阻止启动 |
| 5 | `TestAuditInvalidOutboundPreventsBatchStart` | **确认现存问题**：单个 schema 错误节点使整批启动失败 |
| 6 | `TestAuditDocumentedMulticastAndSemantics` | 组播拒绝规则实为"源 AND 目的"匹配 |
| 7 | `TestRealSRSGeoRuleSetsLoad` | 真实 geosite-cn / geoip-cn SRS 加载 |
| 8 | `TestLegacyDBGeoFileIsRejected` | 旧 `.db` 资产被拒 |
| 9 | `TestRuleSetReferenceWithoutDefinitionFails` | 悬空 rule_set 引用报错（`geosite:cn`） |
| 10 | `TestRuleSetReferenceWithDefinitionStarts` | 有定义时正常启动 |
| 11 | `TestUserDnsRulesAndFakeipFallbackAccepted` | 用户 DNS 规则 + FakeIP 回退 |
| 12 | `TestSniffOverrideDestinationAccepted` | sniff override 配置被接受 |
| 13 | `TestSniffOverrideRuntimeWiring` | sniff override 运行期接线 |
| 14 | `TestProductionOutboundGraphsStart` | 生产出站图（wrapped-rule-target / selector-target）启动 |
| 15 | `TestProductionDNSConfigurationsStart` | 4 种 IPv6 模式 × FakeIP 共 8 组生产 DNS 配置启动 |
| 16 | `TestSniffDestinationBehavior` | route/override 两档嗅探目的地行为 |

"确认现存问题"性质（透传断言 + `t.Logf` 明确标注，**通过=m问题仍按文档存在**）：

```text
functional_audit_test.go:100  CONFIRMED remaining issue: initialize rule-set[0]: initial rule-set: remote_audit: unexpected status: 503 Service Unavailable
functional_audit_test.go:116  CONFIRMED remaining batch-isolation issue: outbounds[1].server_port: json: cannot unmarshal string into Go struct field SOCKSOutboundOptions.ServerOptions.server_port of type uint16
```

另有两条非缺陷的"确认内核行为"日志（`fakeip_strategy_probe_test.go:69`：1.14 不支持 `dns.servers[].strategy`；`probe_test.go:87`：内核拒绝悬空 rule-set 引用）。这两条是断言内核契约，不是待修问题。

## 4. 内核 .so 导出核验

对象：`entry/libs/arm64-v8a/libsingbox.so`

```text
SHA256  9b2b983973281fb855d1993bf7895594d7eb40f2956a957160cc34d45b788d49
大小    35,688,144 字节
mtime   2026-09-26 19:10
```

同哈希副本存在 2 份构建中间产物（`entry/build/default/intermediates/libs/...`、`.../stripped_native_libs/...`），三者 SHA256 前缀一致，说明包内库与工作区库同源、未重编。

工具：`llvm-readelf --dyn-syms -W`（LLVM 15.0.4）。`.dynsym` 共 68 项；其中定义为 `FUNC GLOBAL` 的符号为 9 个 CGo 导出 + `_cgoexp_*` 跳板 + `crosscall2`。

| 期望导出 | 存在 | 地址 |
|---|---|---|
| `CGoStartSingBox` | ✅ | 0x0137a3e0 |
| `CGoStopSingBox` | ✅ | 0x0137a440 |
| `CGoSetTunFd` | ✅ | 0x0137a384 |
| `CGoSingBoxVersion` | ✅ | 0x0137a6c8 |
| `CGoTestStartSingBox`（legacy 单参） | ✅ | 0x0137a494 |
| `CGoTestStartSingBoxV2`（+bindIfname） | ✅ | 0x0137a4f4 |
| `CGoTestProxySingBox`（legacy 三参） | ✅ | 0x0137a568 |
| `CGoTestProxySingBoxV2`（+expectStatus） | ✅ | 0x0137a5e8 |
| `CGoTestStopSingBox` | ✅ | 0x0137a674 |

**9/9 全部存在，缺失项：无。** 与 `entry/libs/arm64-v8a/libsingbox.h` 的 `extern` 声明**完全一致**，无头文件声明了而库未导出的情况。

关于 `testCapsNative`：它**不是** `.so` 导出符号，而是 NAPI 层函数（`entry/src/main/cpp/napi_init.cpp:535` 注册），其能力判定依赖本表第 6、8 项：

```cpp
g_testStart = dlsym(handle, "CGoTestStartSingBoxV2");
g_testProxy = dlsym(handle, "CGoTestProxySingBoxV2");
g_testV2 = (g_testStart != nullptr) && (g_testProxy != nullptr);
...
message = g_testV2 ? "v2" : "legacy";
```

两个 V2 符号均存在 → 运行时 `testCapsNative` 将回报 `"v2"`（严格状态码判定 + 测速绕过隧道可用）。注意 `napi_init.cpp:193` 的注释"冻结 .so 仍是 legacy 签名"已过时：**当前冻结库的 V2 导出齐全**，legacy 分支只是回退路径、不会被选中。这与 §4 记录"已核对 legacy 和 V2 CGoTestStart/Proxy/Stop 导出存在"一致。

## 5. release 构建

命令（任务书给定）：

```bash
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' \
PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH" \
node hvigorw.js --mode module -p product=default -p buildMode=release assembleHap --no-daemon
```

结果：**BUILD SUCCESSFUL in 3 s 385 ms**（墙钟 4s，远低于 3 分钟窗口，无需跳过）。

```text
33 tasks in total: 13 executed, 20 up-to-date
```

- 增量构建：`CompileArkTS`、`PackageHap`、`SignHap`、`DoNativeStrip` 等均为 UP-TO-DATE，未重新打包。
- 无编译错误。仅 1 条常规警告：relese 构建未启用 obfuscation 的提示（`WARN: If obfuscation is needed...`）。
- 产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`：**14,428,915 字节**，SHA256 `60d962120379ce1816fbb4c1ff0df9d1d88247769228373b2b84d859a57e25fe`——与 §4 记录**逐字节一致**（未重打包，符合增量 up-to-date 预期）。
- 构建后 `git status --porcelain` 与构建前 diff 为 **0**，未引入新的未提交改动（`build/`、`*.hap` 均在 `.gitignore` 内）。

## 6. 与 FUNCTIONAL-AUDIT-2026-10-23.md §4 基线的差异

| 项目 | §4 基线（2026-10-23） | 本次（2026-10-24） | 判定 |
|---|---|---|---|
| Node 套件 | 19 套件 19 通过 | 19 套件 18 通过 + `geo-srs` 1 环境性失败 | **无代码回归**；差异为外部依赖（GitHub API 匿名配额耗尽 403），非仓库内容变化 |
| Node 断言 | 未记录总数 | 302 条 PASS 输出行 / 313 条按组折算 | 新增可量化基线 |
| Go 顶层测试 | 16 个通过 | 16 个通过（49 RUN 行含 33 子测试） | **完全一致** |
| Go 确认现存问题 | 远程 503、坏节点整批失败 | 同上两条 `CONFIRMED` 仍成立 | **一致**（问题未修复，符合预期） |
| 内核 .so SHA256 | `9b2b9839…88d49` | `9b2b9839…88d49` | **一致** |
| 内核导出 | legacy 与 V2 的 TestStart/Proxy/Stop 存在 | 9/9 全部存在 | **一致** |
| release 构建 | SUCCESSFUL，33 tasks，12.792s | SUCCESSFUL，33 tasks（13 executed / 20 up-to-date），3.385s | 一致（本次为增量，故更快） |
| unsigned HAP | 14,428,915 B，`60d96212…e25fe` | 同字节数、同 SHA256 | **一致** |
| geo-srs 外网检查 | ECONNRESET → SKIP（套件通过） | 实际下载成功（56,468 B，魔数校验通过），但 GitHub API 403 → 2 条 FAIL | 外部环境差异；本地证据反而更全 |

结论：

1. **无功能回归。** 19 个 Node 套件的全部离线断言、16 个 Go 顶层测试、内核 9 个 CGo 导出、release 构建与 HAP 哈希均与 2026-10-23 基线一致或更强。
2. **唯一差异**是 `geo-srs.cjs` 对 GitHub API 的依赖形态：审计当天网络不可达（SKIP），本次共享出口 IP 的匿名 API 配额耗尽（403 → FAIL）。该失败不计为产品回归，但提示该套件把"限流"误判为"资产不存在"，需要在后续测试治理中改为 SKIP（本轮按约束未改测试）。
3. **冻结内核未变**（哈希一致、未重编），V2 导出齐全，NAPI 侧会走 V2 路径，因此 P0 后续工作可以按"内核侧 V2 测速能力可用"这一前提设计。
4. 未验证/未声称：真机连通、包名到应用的真实选路、DNS 泄漏、待机保活、UI 视觉验收（与 §4 边界一致，当前无 HDC 设备）。
