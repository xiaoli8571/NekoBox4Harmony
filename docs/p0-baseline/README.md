# P0 基线与技术验证——完成报告

日期：2026-10-24。依据：docs/REDESIGN-PLAN-2026-10-23.md §20 P0 阶段与 §25.2 施工前检查。状态：**P0 完成**（设备级验证项明确保留为待验，不冒充通过）。

## 1. 交付物索引

| §20 P0 交付项 | 交付物 | 状态 |
|---|---|---|
| 工作区来源清单 + 恢复快照（§25.2-1） | `uncommitted-files.txt`（47 文件清单）、`uncommitted-tracked.patch`（6,350 行）、git stash `P0-baseline 2026-10-24…` | ✅ 非破坏性；工作区修改原样保留 |
| 完整入口去向表（W01） | `entry-inventory.md`（488 行）：195 个可点入口，保留 121 / 迁移 42 / 合并 26 / 移除 6；D1~D15 死路清单 | ✅ |
| 旧数据夹具（§25.2 计划部分） | `data-model-survey.md` §5：现有夹具盘点 + schema1/2/3/5/未知版本/单项损坏/整体截断缺口清单 | ✅ 计划完成，夹具落地在 P1/W04 |
| 实际内核能力清单（K1/K2，§25.2-5/6） | `kernel-capabilities.md`：9 个现有导出、K1 两层设计方案、K2 最小会话导出方案；`test-baseline.md` llvm-readelf 实测 9/9 导出在位 | ✅ |
| 存储替换/取消机制验证（§25.2-7） | `data-model-survey.md` §6：全树零 rename/fsync 先例（仅 TRUNC 原地覆盖）；结论：按 §14.3-4 回退**双槽 manifest + 单调 revision + checksum 校验**，不依赖 rename 原子性 | ✅ 设计决定；真机掉电验证留 P6 故障注入 |
| 新方案冲突文档清单（§25.2） | `conflict-docs.md`：14 项行为冲突（C1~C14）+ 4 项过时表述（S1~S4）+ 6 项一致项 | ✅ |
| 测试基线（§25.2-3） | `test-baseline.md`：Node 18/19 PASS（唯一 FAIL = geo-srs GitHub 403 限额，环境性）、Go 16/16 PASS、release BUILD SUCCESSFUL、HAP 哈希与 2026-10-23 基线逐字节一致 | ✅ |
| 真机验收设备与证据路径（§25.2-10） | `hdc list targets` = `[Empty]`；本机当前无设备 | ⚠️ 待验，P6/P7 依赖设备证据 |

## 2. 关键结论（施工依据）

### 2.1 K1：新增两个无副作用导出（P1 实施）

- `box.New` **不是**无副作用的（router.Initialize 触发规则集下载/初始化、创建日志文件等），不能拿它做 check；
- 方案：`CGoCheckConfigV1(configPath)`（仅 `json.UnmarshalExtendedContext`，不 box.New/不 Start/不碰环境变量）+ `CGoValidateSRSFileV1(path)`（`common/srs.Read` 纯解析）+ ArkTS 静态引用校验，两层；能力缺失时不得标「已验证」；
- 逐节点 `CGoCheckConfigV1` 正是 REQ-10 坏节点隔离的静态校验基础（功能审计中的 `server_port:"invalid"` 坏节点在这一层就能单独拒掉）。

### 2.2 K2：最小会话导出必须实施（P2 实施，P1 设计冻结）

- 现状：`testInstance` 包级单例 + 导出不带 sessionId + `startTestBox` 对已有会话「直接复用」——违反 §6.5「迟到创建成功的实例必须立即关闭，不能被下一轮误复用」；
- 方案：`CGoTestStartSingBoxV3(confPath,bind,sessionId)` / `CGoTestProxySingBoxV3(...,sessionId)` / `CGoTestStopSingBoxV3(sessionId)`，Go 侧 sessionId 比对，迟到 start 立即 Close；NAPI 回调携带 sessionId；
- 不承诺 Go 永久阻塞时强制回收（§16.4 边界）。

### 2.3 数据层（P1 设计输入）

- 29 个 Preferences 触点 100% 集中在 `model/Store.ets`——适配层边界已存在，ConfigRepository 在其上收口即可，无需先扫页面；
- **所有实体都没有稳定 ID**（Profile 三套体系、组身份=name、订阅身份=URL、RouteRule 无 id）→ v5 迁移主要工作量 = 稳定 ID 分配 + 映射表；
- 跨进程双写无互斥（`:vpn` 经 mutateProfiles 写流量 × UI 21 处全量回写）→ ConfigRepository 必须单写者；扩展只读指定 revision；
- Backup v4：9 顶层键恒全写（schemaVersion+version 双写=4），导入接受 1..4，6 键顺序写无事务；
- 文件原子写零先例 → 双槽 manifest + 单调 revision + checksum 校验 + 中断注入测试。

### 2.4 入口现状（P3 设计输入）

- 195 个入口中 62.1% 可直接保留；21.5% 需迁移（设置页分应用块 15 项 → 分流页）；
- 冲突最重：顶栏动作簇（＋/连接/⋮/搜索）全局挂载于全部 7 页（Index.ets:2320-2355），⋮ 作用域仍是节点页残留 `selectedGroupId`（2492-2505）→ §3.3 页面专属顶栏；
- D2/D3「假清除」需扩展进程配合（会话基准偏移/日志文件身份），非纯 UI，卡 REQ-20；
- 二级页上下文参数化（sessionId/configRevision）全缺。

### 2.5 测试基线数字（回归对照）

- Node 19 套件 → 18 PASS；唯一 FAIL `geo-srs.cjs` = GitHub 匿名 API 配额耗尽（403，环境性，12 条离线断言全过；10-23 为 ECONNRESET SKIP）；
- Go `tests/hostprobe` 16/16 PASS；两个「CONFIRMED remaining issue」测试仍是**待修缺陷的复现**（503 / 坏节点整批）——修复后必须改写断言，不能以删断言收尾；
- release 构建 33 tasks BUILD SUCCESSFUL；未签名 HAP 14,428,915 B / `60d96212…e25fe`，与 10-23 逐字节一致；
- 冻结 .so SHA256 `9b2b9839…88d49`，9/9 导出在位（含 V2）。

## 3. P0 遗留与对 P1 的输入

| 遗留 | 影响 | P1 处理 |
|---|---|---|
| 真机掉电/中断注入验证 | §14.3 存储方案 | 双槽 manifest 设计规避 rename 原子性依赖；掉电演练 P6 |
| K1/K2 导出未实现 | REQ-10/REQ-19 判据来源 | P1 末实现 CGoCheckConfigV1/CGoValidateSRSFileV1 + 重编 .so；K2 随 P2 |
| schema1/2/3/5 夹具缺失 | W04 迁移测试 | W04 内补齐 |
| geo-srs 403 判定 | 测试稳定性 | 建议把 403/429 视同 SKIP（属测试维护，不改变功能断言） |
| napi_init.cpp:193 注释过时（称冻结 .so 仍 legacy，实际 V2 齐全） | 误导 | P2 修订注释 |

## 4. P1 施工顺序（已冻结的设计决定）

1. **W03**：`model/ConfigSnapshot.ets` + `model/ConfigRepository.ets` + `core/SnapshotStore.ets`（文件层：双槽 manifest、checksum、单调 revision、临时文件 + 尽力 rename、GC 保留活动/回滚引用）——单写者队列；`Store.ets` 保留为兼容读层（旧调用不破坏）。
2. **W04**：`model/MigrationV5.ets`——schema 4→5、稳定 ID 分配 + 映射表、幂等、隔离坏记录、恢复点；派生自 Backup v4 结构。
3. **W07**：`model/PerAppPolicy.ets` 纯策略函数（include 空名单阻止；上限按系统 API 64/256）+ `VpnService`/`VpnExtAbility` 双侧校验——同一纯函数。
4. **W08**：`core/RuleSetRepository.ets`（URL 校验→临时文件→大小/格式→CGoValidateSRSFileV1→hash→版本化目录→manifest 提交→GC）；无 K1 能力时降级为「结构校验」并如实标注未验证。
5. **W06**：ApplyCoordinator 骨架 + 运行状态协议设计（基于 `core/VpnIpc.ets` 现状：CommonEvent、无信封字段；新增 protocolVersion/sessionId/generation/sequence/operationId/appliedRevision）。
6. 每步先写主机行为测试（tests/*.cjs 转译生产 ETS 的既有模式），再改调用方；`assembleHap` 必须保持通过。

## 5. 纪律声明

- 本报告不声称任何真机行为通过；所有设备项（TUN、分应用真实流量、DNS 泄漏、待机保活、UI 视觉）维持「待验」。
- 工作区原有未提交修改未被覆盖、未被提交；P0 只新增 `docs/p0-baseline/` 文档与 1 个 git stash 快照。
