## 2026-09-27 Geo 资产 404 与订阅解析不到节点(真机用户反馈,2.0.3)

> 两个用户可感知的问题,均已定位到根因并修复。核心结论:**Geo 下载 404 不是网络问题**,
> 而是上游已不再发布该格式;**订阅解析不到节点有 10 个独立根因**,其中 1 个会造成
> 「一次失败后永远失败且不报错」的静默锁死。

### 一、GeoSite/GeoIP 库下载 HTTP 404

1. **根因(两层叠加)**:
   - 上游 `SagerNet/sing-geosite` / `sing-geoip` 的 `rule-set` 分支**只发布 `.srs` 二进制**,
     早已不再提供 `.db`。原代码 8 个候选 URL 全部指向 `.db` → 全部 404(curl 逐个验证)。
   - 即使换成 `.srs` 仍会再失败:旧体积门槛是 **>100KB**,而真实
     `geosite-cn.srs` 仅 **56,190 字节**、`geoip-cn.srs` **34,185 字节**,会被判「文件过小」。
2. **修复**(`utils/GeoAssets.ets`):
   - `GEO_SITE_FILE/GEO_IP_FILE` → `.srs`。与内核 `option/rule_set.go:124-135` 按扩展名
     推断 `binary` 的行为一致,无需改 `ConfigBuilder` 的 `format:'binary'`。
   - 体积门槛 100KB → **4KB**,并新增 **`SR` 魔数校验**(真实魔数 `SRS\x01`)。
     必须加魔数:实测 jsdelivr 对已删除路径返回 **HTTP 200 + 纯文本错误页**,
     只看状态码会把垃圾写进沙箱并让 `geoReady` 误判为可用。
   - 下载源把 `raw.githubusercontent.com` 提为首选(jsdelivr 缓存陈旧),保留 6 个镜像兜底。
   - 「从文件导入」改为只接受 `.srs`(`.db` 已下线),文案与双语资源同步更新。
3. **验证**:
   - `tests/geo-srs.cjs` 16 项(文件名、URL、门槛、魔数、上游文件存在性、
     ConfigBuilder format 匹配、首选源实取 56,190 字节且魔数正确)。
   - `tests/hostprobe/geo_srs_test.go` 用**本项目真实的 sing-box 1.14 内核**加载真实
     `.srs` 通过;另有一条测试确认旧的 `.db` 路径**确实被内核拒绝** ——
     证明这不是碰巧。该路径此前在生产上从未成功执行过。

### 二、订阅导入解析不到节点(10 个根因)

阻断级:

1. **B3 ETag 锁死(最隐蔽)**: `updateSubscription` 曾在**解析之前**落盘 ETag/Last-Modified。
   一次「机场返回错误页/限流」的响应就把校验器钉死,此后每次更新带 If-None-Match 拿到 304
   → 永远 0 节点、**UI 仍显示「更新成功」**。修复:校验器改为解析成功后才落盘;
   304 分支增加「本订阅 0 节点则强制脱掉校验器重下」兜底。
   测试 `tests/sub-etag.cjs` 15 项,含一条红测试对照证明旧顺序确实会锁死。
2. **B1 proxy-providers 从不下载**:provider-only 的 Clash 订阅(顶层只有 `proxy-providers`,
   节点在 provider 的 URL 里)此前直接判为「不支持」→ 0 节点,而 v2rayN/Clash/Hiddify 都能导。
   新增 `utils/ClashProviders.ets`:拉取 `type: http` 的 provider 并递归解析
   (内容既可能是 Clash YAML 也可能是 base64 链接),provider 名为节点名兜底,跨 provider 重名加后缀。
3. **B4 base64 硬折行**:机场订阅常按 76 列折行,`@ohos.util` 的 `Base64Helper` 默认
   `Type.BASIC` 不接受 CR/LF → 整段解析为 0。修复:解码前 `replace(/\s+/g,'')`。
4. **B5 解出内容不含 `://` 被丢弃**:base64 包裹的 **WireGuard `.conf`** 与
   **sing-box JSON** 解出来又扔掉 → 面板「WG 导出(base64)」导入 0 节点。
   新增 `tryDecodeBase64Loose`:先用「是否 base64」判据(字母表 + 长度%4≠1 + 解出无 U+FFFD)
   而非「解出有没有 `://`」,解出后交回同一套分派逻辑。
5. **B2 手动导入路径不一致**:`Index.ets` 的「导入订阅」入口既不跟进 provider、
   也完全丢弃 `note`/`skippedNames`,用户只看到「无可导入节点,跳过 0 条」。
   现与自动更新路径统一,并把 `subFailureText` 提到 `utils/Subscription.ets` 供两处复用。

降级级:

6. **D1 sing-box JSON 丢 transport/multiplex/packet_encoding**:转换站导出的节点全部退化成
   裸 TCP + 默认 TLS → 「节点存在但一个都连不上」。新增 `sbApplyTransport`,
   同时兼容 legacy 1.8 的 `network`/`ws_path`/`grpc_service_name`。
7. **D2 trojan/hysteria2/tuic/anytls/shadowtls 缺 `tls=true`**:JSON 省略 `tls` 块时
   这些必须 TLS 的协议变成明文 → 握手直接失败。已与 Clash 分支对齐
   (`sbApplyTls` 仍保留「显式 `enabled:false` 可关」)。
8. **D3 hysteria2 `ports` 为 YAML 序列时整段丢失**(用了只读标量的 `yStr`)。
9. **D4 hysteria v1 带宽带单位被吞**(`Number("30 Mbps")` = NaN → 0),改用 `parseBandwidth`。
10. **D6 Clash `proxy-groups` 完全丢弃**:订阅自带的分组结构全丢。新增 `parseClashGroups`
    + `applyClashGroups`,Clash `select` → `isSelector`、`url-test` → `autoSelect`;
    保守处理:成员名匹配不到节点的组直接跳过,不造空组、不乱搬节点。

边缘级:

11. **E1 `%YAML 1.2` 指令行**让整份文档在开头被截断(`preprocess` 误置 `started`)。
12. **E4/E5 query 的 `+` 被当空格**:按 RFC 3986 `+` 是字面字符,含 `+` 的密码/短 ID 会被破坏;
    顺带修 key 未解码、`;` 分隔符、订阅容器 URL 的同一问题。
13. **E6 HTML 错误页前置闸**:正文以 `<html`/`<!DOCTYPE` 开头时给明确报错,
    避免被 `hasTopLevelKey` 误判成 Clash YAML 而报「没有 proxies 节点列表」。
14. **E7 User-Agent 回退**:机场按 UA 分流不同格式。新增 4 个备用 UA,
    仅在「解析出 0 节点且非 provider-only」时触发,跳过已用 UA、跳过空/相同正文,
    失败文案带上试过的 UA。失败路径最多 5 次请求(1 + 4)。

### 三、诊断能力(「解析不到节点」从此可定位)

- 分享链接分支现在上报 `skipped`/`skippedNames`,并给出「scheme + 名字」摘要。
- 错误文案区分「格式没认出来」与「认出来了但全是内核不支持的协议」,
  后者直接点名跳过了哪几条(整份 `ssr://` 订阅是常见情形)。
- `clash_provider_*` 四个新 note 区分「全部下载失败 / 部分失败 / 内容为空」。

### 四、未做(附取证)

- **E3 naive 协议**:子代理指出内核 `include/registry.go` 支持 naive,但本项目
  `core/libsingbox14/lean_context.go` **未注册** naive(实测 0 处)。App 层加类型只会生成
  冻结 `.so` 拒绝的配置。要支持必须先往 lean_context 注册并**重编 `.so`**(动内核),
  不属本轮范围。mieru/juicity/hysteria3 在 1.14 已移除,跳过是正确的。

### 五、验证

- 新增测试 5 个文件:`tests/geo-srs.cjs`(16)、`tests/subscription-parse.cjs`(38)、
  `tests/sub-etag.cjs`(15)、`tests/sub-ua-fallback.cjs`(17)、
  `tests/hostprobe/geo_srs_test.go`(内核级)。
- 既有套件全绿:`parity-config` 38、`outbound-graph` 9、`ipv6-*`、
  Go `tests/hostprobe` 全套。
- `hvigor clean assembleHap` **BUILD SUCCESSFUL**;
  双语资源键 **614=614** 双向零差异。
- 过程中修掉自己引入的三个真实缺陷:
  ① provider 逻辑写回 `Subscription.ets` 会造成 **Subscription ↔ LinkParser 循环导入**
  → 拆出独立 `ClashProviders.ets`;
  ② 批量插入 `p.tls = true` 的脚本把语句放到了 `break` 之后(不可达)与花括号块外
  (作用域错误)→ 逐处核对修正;
  ③ `parseClashGroups` 里 `providerStr(m, '')` 对裸标量节点取键取不到值,导致成员全被
  丢弃 → 改为直接读 `.scalar`。
- **未做真机验证**(签名密码不在环境变量,按项目约定从不落盘)。
  真机重点回归:① Geo 库下载后规则模式分流是否生效(该路径以前从未真正跑通);
  ② 导入一个 provider-only 订阅;③ 导入一个带 proxy-groups 的完整 Clash 配置。

改动文件:`entry/src/main/ets/utils/GeoAssets.ets`、`utils/ClashProviders.ets`(新)、
`utils/Subscription.ets`、`utils/LinkParser.ets`、`utils/ClashYaml.ets`、
`core/Subscriptions.ets`、`pages/Index.ets`、`pages/SettingsPage.ets`、
`resources/base 与 en_US/element/string.json`、`tests/`(4 个新测试 + 1 个 Go 测试)
