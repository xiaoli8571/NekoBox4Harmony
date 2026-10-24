# P1 基础层交付报告（2026-10-24）

依据：`docs/REDESIGN-PLAN-2026-10-23.md` §20.1（P1：工作包 W03/W04/W05/W06/W07/W08）。
状态：**P1 开发项完成、主机验证全绿；真机项待 HDC 设备**。未 commit。

## 1. 交付清单

| 工作包 | 模块 | 测试 | 结果 |
|---|---|---|---|
| W03 存储 | `model/ConfigSnapshot.ets`、`core/SnapshotStore.ets`、`core/ConfigRepository.ets` | `tests/config-repository.cjs` | 14/14 PASS |
| W04 迁移 | `model/MigrationV5.ets`、`EntryAbility` 初始化 | `tests/migration-v5.cjs` | 12/12 PASS |
| W05 K1 内核 | `core/libsingbox14/main.go`(+2 导出)、`cpp/napi_init.cpp`、`core/CoreManager.ets`、`build-libsingbox-ohos.sh`(+2 行白名单) | `tests/hostprobe`(含 19 项 K1) | Go 全 PASS |
| W06 运行协议 | `core/VpnIpc.ets`(信封/命令/回执)、`core/ApplyCoordinator.ets`、`VpnExtAbility` 信封+query、设计文档 `docs/p1-design/runtime-protocol.md` | `tests/runtime-protocol.cjs` | 8/8 PASS |
| W07 分应用门控 | `model/PerAppPolicy.ets`、`VpnService.connect`、`VpnExtAbility.startVpn` | `tests/per-app-policy.cjs` | 8/8 PASS |
| W08 规则集 | `core/ResourceValidator.ets`、`core/RuleSetRepository.ets` | `tests/ruleset-repository.cjs` | 17/17 PASS |

汇总：**Node 23 套件全 PASS**（新增 5 + 既有 18）、**Go hostprobe 全 PASS**、**release assembleHap BUILD SUCCESSFUL**。

## 2. 逐项验收（§20.1 退出条件）

| 退出条件 | 证据 | 结论 |
|---|---|---|
| 新数据层可保存/读取/恢复，写失败不推进状态 | config-repository 测试 3/5/6/7/8：并发串行、注入 manifest 写失败后 active 不变、孤儿快照在 init 清理、损坏回退、校验和篡改拒绝 | ✅ 主机 |
| 旧数据迁移幂等、可恢复、不破坏旧数据 | migration-v5 12 项：空库→r1、二次运行 revision 不变、恢复点写一次、损坏键中止且旧数据零改动、重读核对 | ✅ 主机 |
| 危险配置不应用（空名单/超限） | per-app-policy：include 空→block、64/65@API22、256/257@API23、两处调用点先于启动/TUN 的接线断言 | ✅ 主机 |
| 内核可做无副作用校验 | K1：`server_port:"invalid"` 拒绝、真实 geosite-cn.srs 通过、8 种损坏 SRS 拒绝、源码守卫无 `box.New`/环境变量/写文件 | ✅ 主机；真机调用待验 |
| 保存与应用修订可区分、迟到回执不覆盖 | runtime-protocol：saved/applied 分离、operationId 去重、跨会话/代次回执拒绝、一次有界恢复 | ✅ 主机 |
| 规则集下载失败策略与 GC | ruleset-repository 17 项（失败保留旧缓存、unsupported 不标已验证、32MiB/256MiB 上限、GC current+previous） | ✅ 主机；真实下载待 P4 接线 |
| 真机：迁移落盘、TUN、分应用真实流量、通知速率 | 无 HDC 设备（`hdc list targets` 空） | ⏳ 待验（不计通过） |

## 3. 关键实现决定（已固化）

1. **快照存储**：`filesDir/config/config-snapshot-<rev>.json` + 双槽 `manifest-a/b.json`（按 revision 奇偶写槽）+ FNV-1a 32 checksum + 单调 revision + 写后读回校验 + 三级恢复（manifest→另一槽→扫描，扫描受 manifest 最高 revision 天花板约束，防孤儿被采纳）+ GC 保留 3 版。
2. **迁移**：幂等门 = `ConfigRepository.hasActive()`；恢复点先写、成功后提交；全部改写基于解析副本，失败不改旧 Preferences；既有 ID 保留，冲突只记录不覆盖。
3. **K1**：新导出只做 `leanContext + UnmarshalExtendedContext` / `srs.Read`，绝不 `box.New`/`Start`；NAPI `dlsym` 缺失回退 `"unsupported"`，ArkTS 侧不得据此标「已验证」。
4. **运行协议**：信封字段 + `VPN_CMD`/`VPN_APPLIED` 通道；`appliedRevision` 在扩展读快照（P4 M5）前恒为 0（未知），不冒充已知；ApplyCoordinator 只认 operationId+generation+sessionId 全匹配的回执。
5. **分应用**：`PerAppPolicy` 保持平台无关纯函数；两个调用点各自读 `sdkApiVersion`（失败按 23）；blocked 时生效名单清空，杜绝 forgetful caller 应用超限名单。

## 4. 未接线/遗留（明确清单）

- `appliedRevision` 真实值：需 P4 让扩展读 `filesDir/config/` 指定 revision 快照（M5），当前恒 0。
- `RuleSetRepository` 消费方：ConfigBuilder 编译 rule_set 本地路径、路由页下载状态/重试按钮（P4）。
- `ApplyCoordinator` UI：全局待应用条 + 设置页/分流页接线（P3/P4）。
- `failurePolicy='allow-unverified'` 无 UI 入口（P4）。
- 测速重构（ProbeResult/批内隔离/K2 会话导出）= P2，未动。
- 页面 IA 重构、路由编辑、订阅流程、视觉适配 = P3~P7，未动。
- 真机验收（迁移、TUN、分应用、DNS、保活）= P6，需 HDC 设备。

## 5. 构建与产物

```
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH" \
  node hvigorw.js --mode module -p product=default -p buildMode=release assembleHap --no-daemon
```

- `entry/build/default/outputs/default/entry-default-unsigned.hap` 14,519,422 B（2026-10-24 11:00）
- 包内 `libs/arm64-v8a/libsingbox.so` sha256 `fa0b67c42853da97f36370126301a7acf8854eff531a579319bfb81ce5f24719`（11 导出，含 K1 两枚）
- 构建期间修掉的 ArkTS 严格模式错误：`ConfigSnapshot.ets` `isRecord(Object|undefined)`、`RuleSetRepository.ets` `delete` 运算符（arkts-no-delete，改重建对象）、`VpnIpc.ets` 误删既有发布函数（已恢复）、`VpnExtAbility.publishStatus` 缺省参数。

## 6. 环境修复（机器级，非仓库文件）

1. OHOS Go fork（`~/ohos-go-build/ohos_golang_go`，go1.24.5）缺 `sync.WaitGroup.Go` 回植 → 按 `core/patches/ohos-gofork-waitgroup-go.txt` 回植 `src/sync/waitgroup_go125api.go`（Go 1.24 起按需编译，无需重建工具链）。
2. C: 卷禁用 8.3 名称 → cgo 的 `CC` 路径在空格处被拆断 → `fsutil file setshortname "C:\Program Files\Huawei\DevEco Studio" DEVECO~1`（可逆）。

## 7. 工作区与提交状态

- 未 commit；`git stash` 保留改造前快照（`P0-baseline 2026-10-24 redesigned snapshot`）。
- `module.json5` / `build-profile.json5` / `AppScope` 的既有本地改动未触碰（签名配置不入库的既有约定）。
- 旧 .so 备份 `9b2b9839…` 在 `/tmp/nb-backup/libsingbox.so.old`。
