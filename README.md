# CPA Stack — ModelScope Studio

在 ModelScope 国际站（魔塔社区）Docker 创空间里运行的 **CLIProxyAPI 推理网关 + Oh My CPA 控制台**，单容器三进程，全部使用官方预编译二进制（本仓库不编译任何东西）。

配置与凭据克隆自线上实例 `cpa.007666.xyz`（DeluxHost 141.11.100.232），功能完全对齐。

## 架构

```
互联网 ──▶ ms.fun 边缘 ──▶ 容器 :7860 (Caddy 唯一入口)
                              │
        ┌─────────────────────┼──────────────────────┐
        │                     │                      │
   /v1* /v0/management*   /omc*                  /healthz
        │                     │                      │
        ▼                     ▼                      ▼
  CLIProxyAPI           Oh My CPA              CLIProxyAPI
  127.0.0.1:8317        127.0.0.1:8080          健康检查
  推理网关 + 管理 API    控制台 (base path /omc)
```

容器内还运行 **CodexComp**（CLIProxyAPI 插件），修复 `gpt-5.5` 等模型的
reasoning truncation（518n−2 模式）。

## 组件与版本

| 组件 | 版本 | 来源 |
|---|---|---|
| CLIProxyAPI | v8.0.24 | [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI/releases/tag/v8.0.24) |
| Oh My CPA | v0.2.6 | [WizisCool/oh-my-cpa](https://github.com/WizisCool/oh-my-cpa/releases/tag/v0.2.6) |
| CodexComp | v0.1.7 | [uf-hy/cpa-plugin-codexcomp](https://github.com/uf-hy/cpa-plugin-codexcomp/releases/tag/v0.1.7) |
| Caddy | Debian bookworm 官方源 | 反向代理 / 请求头净化 |

所有产物在构建时用官方 `sha256` 校验，值记录在 `Dockerfile` 的 ARG 中。

## 入口

部署后（示例域名）：

- 模型 API：`https://<studio-host>/v1/chat/completions`
- 管理接口：`https://<studio-host>/v0/management/*`
- 控制台：`https://<studio-host>/omc/`

### 客户端鉴权（重要）

ModelScope 国际版边缘会向容器**注入/替换 `Authorization` 头**，因此经 ms.fun
调用时 `Bearer` 不可靠。本部署的 Caddy 会主动删除 `Authorization`，客户端必须使用：

- **模型 API**：`X-Api-Key: <key>`（原生支持），或 `?key=<key>` / `?auth_token=<key>`
- **管理接口**：`X-Management-Key: <key>`（原生支持）

CLIProxyAPI v8 的 access provider 原生匹配 `X-Api-Key` / `X-Goog-Api-Key` /
`?key=` / `?auth_token=`，删除 `Authorization` 不影响这些路径。

### 控制台登录

打开 `/omc/`，用 **CPA 管理密钥**登录（与 `X-Management-Key` 同一把）。
OMC 使用会话 Cookie，不接受请求头凭据，因此 `Authorization` 对其无影响。

## Studio Secrets

运行前必须在创空间配置以下 4 个 Secret（镜像内零凭据）：

| Secret | 内容 |
|---|---|
| `CPA_MANAGEMENT_KEY` | CPA 管理密钥明文。**一把钥匙两用**：管理接口 `X-Management-Key` + 控制台登录密码 |
| `CPA_CONFIG_B64` | `config.yaml` 的 base64（含 api-keys、上游密钥、bcrypt 管理口令） |
| `CPA_AUTHS_B64` | 33 个 OAuth 凭据文件的 `tar.gz` 再 base64 |
| `OMCPA_MASTER_KEY` | OMC 静态加密主钥，`openssl rand -hex 32` 的输出。**丢失则库不可读** |

`start.sh` 在首次启动时把前两个解码落盘到持久盘（`config.yaml` 权限 0600）。

## 持久化

持久盘 `/mnt/workspace/cpa-stack`（跨重启保留）：

```
cpa/config.yaml          配置（首次由 Secret 解码）
cpa/auth/*.json          OAuth 凭据（首次由 Secret 解包）
cpa/plugins/linux/amd64/ 插件 .so（首次从镜像复制，CPA 在此目录写 state）
omc/data.snapshot.sqlite OMC 库的持久快照
```

OMC 的活动 SQLite 运行在容器本地 `/tmp`（ModelScope 持久盘是 OSSFS，
SQLite WAL 长期直接跑在上面会页级损坏），每 60 秒做一次 `quick_check`
校验的快照落持久盘，启动时按校验结果恢复。

## 可用模型

33 个，包括：

- `gpt-5.5` / `gpt-5.6-luna` / `gpt-5.6-terra` / `gpt-6-luna` / `codex-auto-review`（Codex OAuth 账号池）
- `gpt-image-*`（图片生成）
- `grok-*`（xAI OAuth 账号池 + grok2api 上游）
- `hermes` / `hermes2`（workbuddy2api 上游）

OAuth 凭据与线上实例共用，个别渠道可能存在配额争抢或 refresh token 互踢。

## 本地构建

```bash
docker build -t cpa-ms-studio .
```

镜像通过 GitHub Actions 构建并推送到 `ghcr.io/ishansiy/cpa-ms-studio:latest`，
创空间的 `Dockerfile` 只引用该镜像（两行）。

## 许可

MIT。上游组件遵循各自许可。
