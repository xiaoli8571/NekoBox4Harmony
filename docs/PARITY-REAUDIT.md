# Android → Harmony 严格复刻重新审计

## 验收口径（2026-09-17，进行中）

用户要求非 Android 独有功能与 UI 1:1。本轮以本地 NekoBoxForAndroid 为基准，不采用旧 PARITY.md 的勾选作为证据。内核尚未支持、UI设计不同、历史阶段冻结、地区规则不同，都不是 Android 独有的充分理由。

当前并未完成全量移植。以下是首轮源码审计与小批修复，不是完整功能覆盖率报告。工作区启动时已有31个修改文件及未跟踪文件，本轮保留这些修改；未提交、推送、改签名或版本号。

路径缩写：A = NekoBoxForAndroid/app/src/main；H = 本项目 entry/src/main。行号以本轮初读快照为定位辅助，后续修改会移动。

## 首批已修复（代码级，尚无真机验收）

| 项目 | Android 依据 | 本轮改动 | 验证边界 |
|---|---|---|---|
| showBottomBar 基本门控 | A/java/io/nekohasekai/sagernet/ui/MainActivity.kt:316-324；widget/StatsBar.kt:83-108 | AppSettings默认false；Settings开关；Backup布尔校验；配置页或开关开启显示FAB，连接且允许该页面时显示StatsBar | 尚缺滚动隐藏/末端防遮挡/Material外观，不标完整1:1 |
| 目的/源端口范围 | A/java/io/nekohasekai/sagernet/fmt/ConfigBuilder.kt:515-534 | ConfigBuilder分别生成port/port_range和source_port/source_port_range，支持逗号/换行及开放范围，避免parseInt截断 | 非法token仍采用忽略策略，错误提示的安卓等同性待审；非端口多行字段待修 |
| DNS auto归一化 | A/java/moe/matsuri/nb4a/SingBoxOptionsUtil.kt:8-24；fmt/ConfigBuilder.kt:183-194 | remote/direct自动策略按现有ipv6布尔推导ipv4_only/prefer_ipv4；server自动策略prefer_ipv4；保留显式选择 | 四档IPv6尚未移植，不标完整IPv6一致 |
| 解析目标地址顺序 | Android入站domain_strategy；本地core/sing-box-1.14/route/route.go顺序扫描 | resolve放在DNS劫持之后、IP匹配之前，显式策略；不再放在规则尾部 | 仅生成配置顺序验证，真实DNS/VPN链路待设备测试 |

改动文件：H/ets/model/Profile.ets、core/Backup.ets、core/ConfigBuilder.ets、pages/Index.ets、pages/SettingsPage.ets、resources/base与en_US/element/string.json。

## 第二批实现与复核（2026-09-17 续；不是完整验收）

CORE-01/02（规则集定义、用户 DNS 分流+FakeIP 限定）、CORE-04（sniff override 内核补丁+实连接验证）、CORE-05 协议多值、CORE-03 大部分（四档模型/设置/备份/Store/平台 VPN 保留 IPv4/FakeDNS 形状/resolve 策略）均已红→绿修复并有内核级或真实持久化验证；仍待：任意 profileId 出站与组级代理（CORE-05/06 剩余）、JSON 深合并与 LAN/组播优先级（CORE-07/08）、UI-01~06、DEF-01/02、真机整包验收。

| ID | 内容 | 证据/实现 | 验证 |
|---|---|---|---|
| CORE-01 | 自定义 geosite:/geoip: 引用必须有同名 rule_set 定义 | 内核级 Go 探针复现失败(`rule-set not found`)；ConfigBuilder 登记 collectReferencedRuleSets，按资产映射 geosite:cn/geoip:cn 同名定义，非 cn 引用抛错不生成悬空配置 | tests/parity-config.cjs 5 项 + tests/hostprobe 2 项内核探针 |
| CORE-02 | 用户规则参与 DNS 分流(direct→local / proxy→remote / reject→predefined rcode=3)；FakeIP 兜底限 tun-in 且排在用户规则后 | 对齐安卓 userDNSRuleList + enableDnsRouting + dns-fake inbound=tun-in；1.14 无 rcode server，reject 用 predefined 动作(strict schema 校验过) | 6 项 DNS 测试 + 内核探针 TestUserDnsRulesAndFakeipFallbackAccepted |
| CORE-03 | IPv6 四档(disable/enable/prefer/only)全链路 | 模型 ipv6Mode(''=旧布尔推导)+设置页四档下拉+base/en_US 资源+Backup 校验+ConfigBuilder TUN/DNS/resolver 策略+VpnExtAbility addresses/routes/isIPv4/isIPv6Accepted | tests/ipv6-modes.cjs 9 项 |
| CORE-04 | sniff route/override 两档区分 + mixed 入站嗅探 | 内核 option/rule_action.go 恢复 override_destination JSON(运行时字段本就存在但从未接线)；route/rule/rule_action.go 构造接线；ConfigBuilder 按 sniffMode 生成，tun+mixed 双入站 | 内核探针 TestSniffOverrideDestinationAccepted + 3 项生产测试；内核补丁已同步 vendor 树，libsingbox.so 重编待做 |

> 更新：CORE-04 已用主机 Go 1.26.5（`GO126=/c/Program Files/Go/bin/go`）和本机 OHOS fork 交叉编译成功，生成 35,659,280 字节 `.so`，并重新 assembleHap。旧“go126 缺失”的结论错误。构建脚本补充幂等 sniff schema/接线及成品标记校验，取消构建中的 git config 写操作。新增 `TestSniffOverrideRuntimeWiring` 验证 true/false 传入运行时；`TestSniffDestinationBehavior` 以两台本地回环 HTTP 服务和本地 DNS 验证 route 保留原始 IP、override 到达 Host 对应 IP，两项子测试通过。尚未做设备端相同行为测试或未签名 HAP 安装。
>
> **撤回 CORE-03 完成结论**：只读复核发现 Backup 把字符串 ipv6Mode 放入布尔字段，现已以真实 exportBackup/importBackup 红色测试复现，移到字符串字段后六个字符串（含 legacy 空串、兼容 auto）往返成功，非字符串在任何写入前被拒绝。此测试不宣称 auto 为有效四档模式。其余待修：server auto 应固定 prefer_ipv4（A/SingBoxOptionsUtil.kt:8-24）；Android core ONLY 为 v6，但平台 VPN 仍保留 IPv4 地址/DNS/路由（A/bg/VpnService.kt:100-124）；core IPv4 前缀 /28 与平台 /30 有别；FakeDNS 仍读旧布尔；resolve 应只从模式推导。既有 ipv6-modes 测试在这些点上存在错误预期或仅源码词匹配，绿灯不能验收。

## 已发现的待办（不是Android独有）

| ID | 差异与源码证据 | 后续验收 |
|---|---|---|
| UI-01 | Android res/layout/layout_group_list.xml:15-34 + ConfigurationFragment:201-217为TabLayout/ViewPager2；H Index:1531起仍全组折叠列表 | 顶部可滚动分组Tabs、分页、选中组持久化、普通空组、按组搜索/批量操作 |
| UI-02 | Android layout_profile.xml左4dp选择条和行内编辑/分享/删除；H Index nodeCard整圈描边、长按菜单 | 复刻三层信息/操作，运行节点编辑删除保护，拖动/撤销删除 |
| UI-03 | Android StatsBar纵向三行、测速结果写状态；H横向44高、结果Toast | 三行布局、禁重复测试、结果状态、FAB矢量/动画、无障碍、滚动防遮挡 |
| UI-04 | Android main_drawer_menu.xml分组顺序、条件仪表盘、外部文档；H有自增头尾、缺仪表盘 | 恢复次序/分隔/条件项与跳转；推广是产品条目不能当平台排除 |
| UI-05 | Android菜单支持独立TCP/URL测试和子菜单，批处理限当前组；H多处__all__ | 菜单层级、单选状态、分组作用域、可取消测试与进度 |
| UI-06 | H主题/颜色/字体/图标体系不同；成功延迟按150/400阈值变色，Android成功统一可用色 | 主题选择、状态/错误模型、同视口截图逐页对比 |
| CORE-01 | 自定义geosite:cn/geoip:cn生成冒号标签，但定义只有geosite_cn/geoip_cn和remote_*；本地内核rule_item_rule_set.go查不到即报错 | 统一标签与资产定义，覆盖非CN规则和地区provider |
| CORE-02 | H DNS只处理内置CN，没有把customRules用于DNS分流；FakeDNS兜底在直连规则之前且不限tun | 用户direct/proxy/reject DNS规则、优先级、FakeDNS入站限定 |
| CORE-03 | Android IPv6Mode四档；H只有ipv6布尔，VPN始终接受v4 | 模型/迁移/设置/DNS/TUN/VPN/备份端到端四档 |
| CORE-04 | route/override均action:sniff且只tun；本地内核覆写目的地址需额外语义 | 核实1.14迁移实现，不能用同一配置冒充两档 |
| CORE-05 | 协议多值已修复(2026-09-17)：ConfigBuilder 按 Android ConfigBuilder.kt:543-544 逗号/换行拆分为 protocol 数组并保留同条规则其它 AND 字段；RouteRule 持久化不再丢弃非 DNS 值；编辑页改 TextArea 多值输入。仍缺任意 profileId 出站与组级代理 | 生产配置断言 undefined→数组通过；真实 Store/RouteRule 保存重载通过 |
| CORE-06 | H ProfileGroup无selector/frontProxy/landingProxy；Android ProxyGroup.kt:22-24及ConfigBuilder组级出站图 | 组设置、引用完整性、注册内核能力及重编验证，不能用节点链替代 |
| CORE-07 | H根/节点自定义JSON浅覆盖；Android utils/Util.kt:129-158递归合并且支持+key/key+列表操作 | 保留生成DNS/路由子字段，前插/后插/递归用例 |
| CORE-08 | H LAN规则先于用户规则且包含组播直连；Android用户规则优先并单独拒组播 | 用户规则优先级、LAN与VPN层绕过区分、组播行为 |
| DEF-01 | Android DataStore MTU9000、mixedPort2080（不是旧表1080）、bypassLan默认false；H1400并Store钳到1500、mixedPort0、bypassLan true | 默认值与合法范围逐项核实，不强制覆盖既有用户设置 |
| DEF-02 | Android远程/直连DNS为DoH、FakeDNS默认true、测试URL为cloudflare；H默认不同且Store自动改写测试URL | 结合内核/平台能力恢复默认值，避免未经验证切断现有连接 |

## 真正的平台排除判定

Android权限、组件名或Binder调用本身可以替换为鸿蒙机制；它们承载的用户功能不因此排除。setMetered、Doze、Android插件进程等需逐项查SDK与内核能力，分别记“平台替代”“尚未实现”“已证实平台不可用”，不作一揽子排除。尚未对全部协议、所有设置页、插件、导入/导出完成审计。

## 本轮验证

- `node tests/parity-config.cjs`：13项通过，直接转译并执行生产ETS模型/ConfigBuilder，不复制被测算法。包括5组端口、DNS默认/显式、resolve次序、底栏接线/默认/备份白名单、双语键一致性。
- ArkTS/资源/原生打包：最终assembleHap exit 0，日志 `parity-build-final.log`。既有弃用API/异常处理/无签名警告仍在，不视为零警告。
- `git diff --check`对本轮应用文件通过。
- `hdc list targets`为空：无本轮真机连接、网络测试、截图或像素验收；未安装覆盖用户应用。
- HAP：`entry/build/default/outputs/default/entry-default-unsigned.hap`。只作为本轮可编译产物，不作为完整复刻交付。

## 下一步

先处理UI-01分组分页/选中组模型与操作作用域，再推进节点卡、StatsBar/FAB和抽屉；每批保持测试与构建。核心按CORE-01/02/03优先继续。需要真机阶段再连接hdc并对齐安卓基准主题、语言、字体比例、视口及状态截图；没有这些证据不能宣称UI 1:1。

## 2026-09-18 批次：CORE-05/06 UI 闭环 + DEF-01 默认值 + 二轮菜单排查

- **CORE-05（任意 profileId 规则出站）**：ConfigBuilder 的 `profile:<id>` 解析与引用出站图已存在，但 UI 无入口。本轮在路由规则出站行加「指定节点」按钮 + 目标节点 Select（首项代理=取消；节点被删显示"节点已删除"，构建时引用解析失败跳过该规则，与既有行为一致）。
- **CORE-06（组级 selector/前置/落地代理）**：模型字段、Backup 校验、`buildProfileGraph` 前后置插入、selector 出站与内核 `group.RegisterSelector`（lean_context.go + 已重编 `.so` 2026-09-18 06:35，35,674,736 字节）均已就绪，缺配置 UI。本轮在分组页每组卡加「分组设置」内联面板：use_selector 开关 + front_proxy/landing_proxy 节点 Select（首项「无」）+ 保存；运行节点属该组时经 `VpnService.switchTo` 自动重载配置。
- **DEF-01 默认值对齐安卓源码**：mtu 1400→**9000**（DataStore.kt:105），Store 钳制上限 1500→9000；mixedPort 0→**2080**（DataStore.kt:129 getLocalPort 基值）；bypassLan true→**false**（DataStore.kt:107 无默认=SharedPreferences false）。仅影响新装默认，既有用户设置原样保留。
- **DEF-02 部分保留**：remoteDns/directDns 维持 tcp/IP 直连与 fakeDns=false——system 栈 DoH/FakeIP 无真机验证前不改连通性默认，属 reaudit 自己给出的「结合内核/平台能力恢复默认值，避免未经验证切断现有连接」判断；testUrl 维持 gstatic（AGENTS.md 记载的产品决策，cloudflare 自动迁移逻辑保留）。
- **同轮补全（菜单排查）**：从文件导入含 WG zip（action_import_file）、路由 ↑↓ 排序（ItemTouchHelper 等价）、分应用剪贴板导出/导入（`false\n<pkgs>`）、移动到分组（ProfileSettings 分组 Preference 等价）、geo 资产单库更新/删除与版本显示（AssetsActivity 列表）、sn:// 任意子类型识别拒绝、扫码导入/二维码分享/订阅强制解析（本文件此前"SDK 无 ScanKit"误判已在 PARITY.md 纠正）、每节点流量持久化、通知刷新间隔、回前台重置、服务器 DNS 策略、返回键行为、订阅去重开关。
- 验证：`tests/parity-config.cjs` 38 项、`outbound-graph.cjs` 9 项、`ipv6-modes/backups/store.cjs` 全绿（含 selector 生产注册断言）；assembleHap exit 0；双语键 598=598 双向差异 0；`entry/src/main/ets` 硬编码 UI 文案扫描 0。
- 仍开放：UI-01~06（分组分页 TabLayout 复刻、节点卡行内按钮、StatsBar 三行式、抽屉次序细节、TCP/URL 分测与组作用域、主题/颜色对照）——需真机与基准主题逐屏对比后实施，当前保持「信息架构+交互对齐」口径；CORE-04 的设备端 sniff 行为验证。

