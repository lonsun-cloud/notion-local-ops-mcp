# Windows 从零运行指南

适用于 Windows 10 / 11，使用系统自带的 **PowerShell 5.1** 或已安装的 **PowerShell 7**。
全部命令在 PowerShell 里执行，不需要 WSL、不需要 Git Bash。

如果你只想看最短路径：**第 1 → 6 步** 就能跑通 Quick Tunnel，把本地 MCP 服务暴露成一个临时公网 URL，并接到 Notion。
需要稳定域名请继续看 **第 7 步 · Named Tunnel**。

> 项目总览与可选进阶用法见根目录 [`README.md`](./README.md)。

---

## 第 1 步 · 安装前置工具

推荐用系统自带的 `winget` 一次装齐。**装完每个工具都要关闭当前终端、重新打开一个**，否则新工具不在 PATH 里。

```powershell
winget install -e --id Python.Python.3.11
winget install -e --id Git.Git
winget install --id Cloudflare.cloudflared
```

验证：

```powershell
py -3.11 --version
git --version
cloudflared --version
```

都有版本号输出即可。

可选替代：

- `cloudflared`：也可以用 Scoop (`scoop install cloudflared`)，或从 GitHub Releases 下载 `cloudflared-windows-amd64.exe`，改名为 `cloudflared.exe` 放到 PATH 中的任一目录。
- Python：如果你已有 Python 3.11+，直接用就行，后面命令里把 `py -3.11` 替换成你习惯的调用方式即可。

---

## 第 2 步 · 获取代码

```powershell
git clone https://github.com/<your-account>/notion-local-ops-mcp.git
cd notion-local-ops-mcp
```

---

## 第 3 步 · 准备 `.env`

复制模板：

```powershell
Copy-Item .env.example .env
```

用任意编辑器（记事本、VS Code）打开 `.env`，至少改这两项：

```text
NOTION_LOCAL_OPS_WORKSPACE_ROOT=C:/Users/<你的用户名>/code/notion-local-ops-mcp
NOTION_LOCAL_OPS_AUTH_TOKEN=<随机令牌>
```

注意：

- `WORKSPACE_ROOT` 是 MCP Agent 操作文件的根目录，所有相对路径都会在这个目录下解析。**此目录必须预先存在**，否则服务启动会报 `Workspace root does not exist`（见 `src\notion_local_ops_mcp\config.py`）。
- **`.env` 里反斜杠和正斜杠都能工作**。Python 的 `pathlib.Path` 在 Windows 上对两者一视同仁（实测 `C:\Users\x` 与 `C:/Users/x` 的 `is_dir()` 都为 True）。`.env` 文件本身只是按行读取后塞进环境变量，不走字面量转义。
- 只有一个**可选建议**：如果之后要把这条路径原样粘进 Python 源码 / JSON / 带双引号的 YAML 字符串里调试，反斜杠可能被这些语言的字面量解析器当作转义（例如 `\U`、`\n`）。只在这种场景下正斜杠 `C:/Users/xxx` 更省心；日常用 `.env` 就随便。
- 如果这一项留空，默认是你当前用户的 Home 目录（`C:\Users\<你>`），一般不建议，粒度太粗。
- `AUTH_TOKEN` 留空表示**不鉴权**，公网暴露时请务必设置。生成一个：

```powershell
[guid]::NewGuid().ToString("N")
```

把输出复制进 `.env`。

其他字段（端口、codex/claude CLI 等）全部可选，默认值见 `.env.example` 与 `README.md` 的环境变量表。

---

## 第 4 步 · 放开当前会话的执行策略

Windows 默认不允许运行未签名的 `.ps1` 脚本。只在当前终端进程里放开（关掉终端就恢复）：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

不想每次敲这一行，可以把它写进你的 PowerShell Profile；但新用户建议保持"按需放开"更安全。

---

## 第 5 步 · 一键启动（Quick Tunnel）

```powershell
.\scripts\dev-tunnel.ps1
```

首次运行会自动完成：

1. 找到 Python 3.11+，在项目下创建 `.venv`
2. 安装 `requirements.txt` + `pip install -e .`
3. 启动 `notion-local-ops-mcp` 本地服务
4. 启动 `cloudflared` 公网隧道

你应该看到类似输出：

```text
Starting notion-local-ops-mcp...
Starting notion-local-ops-mcp on 127.0.0.1:8766
workspace_root=C:\Users\<你>\code\notion-local-ops-mcp
state_dir=C:\Users\<你>\.notion-local-ops-mcp
transport=streamable-http
mcp_path=/mcp
MCP endpoint: http://127.0.0.1:8766/mcp
...
Your quick Tunnel has been created! Visit it at:
https://<随机字符串>.trycloudflare.com
```

把 `https://<随机字符串>.trycloudflare.com` 这一段记下来，下一步要用。
`Ctrl+C` 会同时停止服务器和隧道。

---

## 第 6 步 · 在 Notion 里配置 MCP Agent

打开 Notion，给 MCP Agent 新增一个自定义 MCP 连接：

- **URL**：`https://<随机字符串>.trycloudflare.com/mcp`（一定要有 `/mcp` 后缀）
- **Auth type**：`Bearer`
- **Token**：粘贴 `.env` 里 `NOTION_LOCAL_OPS_AUTH_TOKEN` 的值（逐字节一致，不要多空格）

MCP Agent 的 prompt 模板（短版 / 完整版）直接去 [`README.md`](./README.md) 的两个 `<details>` 折叠块复制即可，本文不再重复。

配置完成后，在 Notion 跟 MCP Agent 对话 "列出当前工作目录下的文件" 能返回结果就算通了。

> Quick Tunnel 的公网 URL 每次启动都会变；想要稳定域名继续看第 7 步。

---

## 第 7 步 · Named Tunnel（稳定域名，生产推荐）

前提：你在 Cloudflare 上有一个已托管 DNS 的域名。

### 7.1 登录 Cloudflare

```powershell
cloudflared tunnel login
```

浏览器会打开让你选域名并授权。证书会写到 `C:\Users\<你>\.cloudflared\cert.pem`。

### 7.2 创建 Tunnel

```powershell
cloudflared tunnel create notion-local-ops-mcp
```

输出里会给出两个关键信息：

- Tunnel UUID（形如 `3a7f...`）
- credentials JSON 路径（形如 `C:\Users\<你>\.cloudflared\<uuid>.json`）

### 7.3 准备本地配置

```powershell
Copy-Item cloudflared-example.yml cloudflared.local.yml
```

编辑 `cloudflared.local.yml`，填入真实值（路径推荐正斜杠）：

```yaml
tunnel: <上一步的 UUID>
credentials-file: C:/Users/<你>/.cloudflared/<uuid>.json

ingress:
  - hostname: mcp.example.com
    service: http://127.0.0.1:8766
  - service: http_status:404
```

`cloudflared.local.yml` 已在 `.gitignore` 中，不会被提交。

### 7.4 绑定 DNS

```powershell
cloudflared tunnel route dns notion-local-ops-mcp mcp.example.com
```

### 7.5 重新启动

```powershell
.\scripts\dev-tunnel.ps1
```

脚本探测到根目录存在 `cloudflared.local.yml`，会自动切到 Named Tunnel 模式（逻辑见 `scripts\dev-tunnel.ps1` 的 `Pick-CloudflaredConfig`）。

Notion 端把 URL 换成 `https://mcp.example.com/mcp`，以后都稳定。

---

## 附录 A · 手动启动（不用脚本）

想完全掌控每一步时使用。在仓库根目录执行：

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
pip install -e .
notion-local-ops-mcp
```

`pip install -e .` 会在 `.venv\Scripts\` 下生成 `notion-local-ops-mcp.exe`（由 `pyproject.toml` 的 `[project.scripts]` 注册）。服务起来后会打印与第 5 步相同的几行信息。

需要公网访问时再开一个 PowerShell 终端：

```powershell
cloudflared tunnel --url http://127.0.0.1:8766
```

或使用 Named Tunnel：

```powershell
cloudflared tunnel --config .\cloudflared.local.yml run
```

---

## 附录 B · 验证

跑单元测试：

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

本地端口探活（服务在听就会返回一个明确的 HTTP 状态而不是 ConnectionFailure）：

```powershell
Invoke-WebRequest http://127.0.0.1:8766/mcp `
  -Headers @{Authorization="Bearer <你的 token>"} `
  -Method Post
```

收到 405 / 415 / 200 都算正常：说明服务在跑、鉴权通过。

---

## 附录 C · 常见坑

| 现象 | 处理 |
|---|---|
| `无法加载文件 xxx.ps1，因为在此系统上禁止运行脚本` | 在当前终端重新执行 `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| `python` 或 `cloudflared` 提示"不是内部或外部命令" | 安装后没开新终端；关闭所有 PowerShell 重新打开，或用 `py -3.11` 替代 `python` |
| Notion 提示 401 Unauthorized | URL 漏了 `/mcp`；或 `Bearer` 拼写大小写不对；或 token 和 `.env` 不完全一致（逐字节对比，见 `src\notion_local_ops_mcp\server.py` 的 `BearerAuthMiddleware`） |
| 启动报 `Workspace root does not exist` | `.env` 里 `NOTION_LOCAL_OPS_WORKSPACE_ROOT` 指向的目录不存在，先 `mkdir` 出来，或改成已有目录 |
| 启动报端口被占 | 改 `.env` 里 `NOTION_LOCAL_OPS_PORT`，Named Tunnel 的 `cloudflared.local.yml` 里的 `service:` 端口也要同步改 |
| `.env` 里的路径打不开 | 确认目录已 `mkdir` 存在；反斜杠和正斜杠 Python 都能识别，所以不是斜杠方向的问题 |
| 想查 cloudflared 的某个参数 | 本地 `cloudflared --help` / `cloudflared tunnel --help` / `cloudflared tunnel run --help`；配置文件字段参考官方文档 <https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/cloudflared-parameters/> |

---

## 下一步

- 可选：把 `codex` / `claude` CLI 装上，`delegate_task` 就能把长任务丢到本地 agent 去跑（参考 [`README.md`](./README.md) 的"环境变量"表里 `NOTION_LOCAL_OPS_CODEX_COMMAND` / `NOTION_LOCAL_OPS_CLAUDE_COMMAND`）
- 进阶用例：[`docs\notion-use-case.zh-CN.md`](./docs/notion-use-case.zh-CN.md) 介绍 Notion AI 指令页与项目管理结合玩法
