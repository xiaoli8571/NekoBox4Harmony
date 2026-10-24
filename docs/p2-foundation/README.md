# P2 检测重构交付报告（2026-10-24）

依据：`docs/REDESIGN-PLAN-2026-10-23.md` §6、§16.4、§20.1（W09/W10）。状态：**P2 开发项完成、主机验证全绿；真机项待 HDC 设备**。未 commit。

## 1. 交付清单

| 工作包 | 模块 | 测试 |
|---|---|---|
| W09 结果模型 | `model/ProbeResult.ets`（22 字段、复合键、`profileConfigHash`、旧结果迁移、兼容投影、新鲜度） | `tests/probe-coordinator.cjs`（14 组） |
| W09 协调器 | `core/ProbeCoordinator.ets`（冻结快照、runId/generation 守卫、二分隔离 2N−1、环境失败一次、取消、摘要、unsaved） | 同上 |
| W09 会话（K2） | `core/libsingbox14/main.go` +5 导出、`sessionstate` 纯模块、`napi_init.cpp` 五件套 + caps `v3`、`CoreManager` 5 包装 | `tests/hostprobe` K2 12 用例 + 全套 |
| W09 运行器 | `core/ProbeRunner.ets`（能力分档 v3/v2/legacy、串行分批、stop 确认后才下一批、逐节点 TCP 回退开关、落盘） | `tests/probe-runner.cjs`（13 组） |
| W09 集成 | `utils/LatencyTester.ets` 重构（`urlTestProfiles` 委托 ProbeRunner，旧签名/字段兼容，删除整批回退） | `tests/latency-parity.cjs`（19 组，含新语义 14/15 段） |
| W09 存储 | `core/ProbeStore.ets`（独立 `filesDir/probe/`、复合键、原子提交、latest 重建、unsaved、未来 schema 只读） | `tests/probe-store.cjs`（13 组） |
| W10 视图模型 | `model/ProbeFilters.ets`（仅看可用/最快/每节点最新/方法路径分组/合并/历史/重测/显示 token/新鲜度） | `tests/probe-filters.cjs`（16 组） |
| 启动接线 | `EntryAbility`：`ProbeStore.init` 与 ConfigRepository/Migration 同链（失败不阻断启动） | 构建通过 |

## 2. 退出条件核对（§20.1 P2）

| 退出条件 | 证据 | 结论 |
|---|---|---|
| 健康节点不被坏节点改成 TCP | probe-runner 组 2：批内含 1 坏节点 → 二分隔离，好节点仍 `http` + success，坏节点 `failed`+`batch_start_failed`+内核原文；整批回退逻辑已删除 | ✅ 主机 |
| 迟到回调不污染新一轮 | coordinator `runId` 守卫 + 已终结结果拒覆盖；probe-runner 组 10 注入迟到 proxy 回调被拒 | ✅ 主机 |
| 取消状态正确 | 未执行节点 `cancelled`+`participated=no`（保留持久化旧结果）；在飞完成照常接收；stop 一次且确认后才落盘 | ✅ 主机 |
| 写失败状态正确 | `saveRun=false` → `saved=false` + `state=unsaved` + `persistedAt=0`；不假装已保存 | ✅ 主机 |
| K2 能力可用 | 16 导出（旧 9 + K1 2 + V3 5）；hostprobe 12 用例含「迟到 start 被立即关闭」「墓碑阻断迟到 start」「stop 幂等」 | ✅ 主机；真机调用待验 |
| 方法/路径显示模型 | `methodLabelToken`/`freshnessToken`/`groupByMethodPath`（HTTP 2xx 与 any 分列、降级标注、未知不伪装） | ✅ 主机 |
| 环境级失败只报一次 | `precheckEnv` + `onEnvironmentFailure`：节点 `notApplicable`（非坏节点）+ `tcpingOption`「改用 TCPing」 | ✅ 主机 |
| 设备：真实探测/跨页取消/断电恢复 | 无 HDC 设备 | ⏳ 待验 |

## 3. 行为变更（§24.2-9 升级说明素材）

1. **C3 删除整批 TCPing 回退**：批量启动失败不再把整批改测 TCPing，改为二分隔离（坏节点单独失败）；TCP 回退只在**逐节点**显式开关下发生，且结果永久标 `degradedReason=http_fallback_tcping`。
2. **配置写盘失败 = 环境级失败**：整轮不启动、节点 `notApplicable`、提供「改用 TCPing」；不再静默整批降级。
3. **结果多字段**：`saved/unfinished/tcpingOption/methodActual/path/coreCapability` 供 P3 UI 使用；旧 `status/ping/error` 仍兼容。
4. **旧结果迁移**：`method=unknown`、`path=legacyUnknown`，不参与「仅看可用/最快节点」，不伪装 HTTP 通过。

## 4. 构建与产物

- `assembleHap` release **BUILD SUCCESSFUL in 15s**（33 tasks）。
- HAP 14,592,908 B，包内 `libsingbox.so` sha256 `9b05c0bfccad124faaf4b1d96100b4ec02d108a5e44ec1d49884a8fbf590e0e3`（16 导出）。
- 上一版 .so 备份：`/tmp/nb-backup/libsingbox.so.k1`（`fa0b67c4…`）。
- Node 27 套件全 PASS（新增 probe-coordinator/probe-runner/probe-store/probe-filters + 既有）；Go hostprobe 全 PASS。

## 5. 遗留/未接线

1. `pages/Index.ets` 仍消费旧 4 字段（兼容成立）；P3 接 `ProbeFilters`+`ProbeStore`：节点行、仅看可用、最快、重测失败、历史、全局进度入口。
2. `allowTcpFallbackPerNode` 设置开关（P4 设置页）默认关。
3. 自动组探测/运行实例检测（P4 W15/W19）：`source` 已留字段。
4. K2 真机：`testCaps=="v3"` 端到端、stop 中断时延、旧 .so 组合的 `"unsupported"` 回退（P6）。
