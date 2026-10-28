# nekobox-pack — NekoBox for Harmony 打包 MCP

一个**零依赖**的 stdio MCP server(手写 JSON-RPC 2.0,换行分隔),把本项目「编译 → AGC 双层签名 → 安装 → 测试 → 产物核对」封装成工具,避免每次重复手敲长命令、忘带 `-p buildMode=release`、或签完不验签。

## 工具

| 工具 | 作用 |
| --- | --- |
| `pack_env` | 只读体检:SDK/JBR/hdc 是否存在、设备列表、签名材料清单、口令来源、当前版本、dist 产物数 |
| `pack_store_password` | 把 AGC 口令写到 **仓库外** 的 `~/.nekobox-pack/secret.json`(后续签名免手输) |
| `pack_set_version` | 统一改版本:`AppScope/app.json5`(versionName+versionCode)+ 根/entry `oh-package.json5` |
| `pack_build` | `assembleHap`(module)或 `assembleApp`(project),`mode=debug\|release`,回读包内 `module.json` 与内核 sha256 |
| `pack_sign` | 跑 `scripts/sign-release-agc.ps1`:AGC 双层签名 + 双层验签 + 发布证书链指纹断言,产物落 `dist/` |
| `pack_release` | 一条龙:改版本(可选)→ assembleHap → assembleApp → 签名 → 汇总 dist 与校验值 |
| `pack_install` | `hdc install -r`,source 支持 `debug`/`unsigned`/`release-signed-hap`/`release-signed-app`/任意 dist 文件名 |
| `pack_test` | 跑 `tests/*.cjs`(`all` 或单个套件),返回失败套件与末尾日志 |
| `pack_artifacts` | 列出 `dist/` 产物(size/sha256/mtime) |

## 注册(pi)

`~/.pi/agent/mcp.json`:

```json
{
  "mcpServers": {
    "nekobox-pack": {
      "command": "node",
      "args": ["C:/Worker/NekoBox4Harmony/tools/nekobox-pack-mcp/server.mjs"],
      "env": { "NEKBOX_REPO": "C:/Worker/NekoBox4Harmony" }
    }
  }
}
```

环境变量可覆盖:`NEKBOX_REPO`、`DEVECO_SDK_HOME`、`JAVA_HOME`、`HDC`、`AGC_CERT_DIR`。

## 口令(重要)

- 解析顺序:**调用参数** → `AGC_KEY_PASSWORD` → `~/.nekobox-pack/secret.json`。
- 仓库内**永不**出现口令;`pack_store_password` 只写用户目录并尝试 `0600`。
- `scripts/sign-release-agc.ps1` 只从 `AGC_KEY_PASSWORD` 读,不落盘。

## 典型流程

```
pack_env                              # 先确认设备/材料/版本
pack_set_version  versionName=2.4.0   # 需要升版本时
pack_release                          # 编译+签名,拿 sha256
pack_install      source=debug        # 真机自测用 debug 包
pack_test                             # 全部 Node 套件
```

## 手测(不经过 pi)

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"pack_env","arguments":{}}}' \
  | node tools/nekobox-pack-mcp/server.mjs
```
