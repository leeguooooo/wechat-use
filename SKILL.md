---
name: wechat-use
description: "Use WeChat on macOS Apple Silicon or Windows x64: query sessions, contacts and history, listen for messages, and send authorized text. Select the host-specific backend first. Windows has a standalone experimental CLI/MCP package with no system Python requirement; macOS uses the managed WeChat 4.1.9 clone and supports HTTP Bridge/Wechaty."
metadata:
  author: leeguooooo
  version: "1.19.13"
  platform: macOS-arm64, Windows-x64-experimental
---

# WechatUse — select the host platform first

This skill supports **macOS Apple Silicon and experimental Windows x64**. Never tell a Windows user that WechatUse has no Windows version. Plugin/skill version 1.19.13 is metadata; the runtime releases are independently versioned (macOS v1.19.13, Windows windows-v0.1.0).

macOS v1.19.7 fixes custom icon changes with retained older task records. Close the dedicated WeChat normally before changing or restoring its icon; specific refusal reasons are preserved.

- **Windows:** follow only the Windows section below. Do not apply macOS requirements, activation/setup commands, LLDB, Accessibility, shell installer or managed 4.1.9 instructions.
- **macOS:** skip the Windows section and follow the macOS section.
- Linux and Intel macOS do not have a supported native runtime.

## Windows x64 (experimental)

A standalone package is published at https://github.com/leeguooooo/wechat-use/releases/tag/windows-v0.1.0 . It includes its runtime; **do not install or invoke system Python** to use that package. The tested WeChat build is 4.0.6.17, with limited login compatibility; not every Windows WeChat build is supported. No media, background send, automatic chat selection, HTTP Bridge or Wechaty support is provided.

### Find the installed runtime before reinstalling

In PowerShell, first check `Get-Command wechat-use -ErrorAction SilentlyContinue`, then the default launcher:

```powershell
& "$env:LOCALAPPDATA\Programs\wechat-use\wechat-use.cmd" doctor
```

For custom installations, read the installed skill's `runtime.json`: `$CODEX_HOME\skills\wechat-use\runtime.json`, or `$env:USERPROFILE\.codex\skills\wechat-use\runtime.json` if CODEX_HOME is unset. The standalone installer writes `executable`, `args` and `mcp_args`; invoke that exact executable with PowerShell's `&` operator. Older source installations may instead record `python` and `script`; use those recorded absolute paths with `-X utf8`, never a guessed `python` command. The Claude plugin supplies instructions; installing/updating it alone does not install the runtime.

If no runtime exists, download and run the official Windows installer:

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/leeguooooo/wechat-use/windows-v0.1.0/install-windows.ps1 -OutFile install-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
```

The installer checks download hashes, installs a user-local CLI and Codex skill, and sends no messages. It does not require system Python. The package is not Authenticode-signed. See https://github.com/leeguooooo/wechat-use/blob/main/docs/windows.md for the supported scope.

### Read, listen and send

`doctor` checks local readiness, not delivery or current login acceptance. Discover the current process/account; never reuse a remembered PID or switch an initialized state directory to another account.

```powershell
wechat-use accounts
wechat-use init --db-dir 'D:\WeChat\xwechat_files\ACCOUNT\db_storage' --pid 1234
wechat-use sessions -n 20
wechat-use contacts --query 'name'
wechat-use history 'exact_username' -n 20
wechat-use listen --once
# Preflight only: open the intended chat in WeChat first
wechat-use send filehelper 'specific text' --pid 1234
# Only after recipient/content authorization; never blindly retry
wechat-use send filehelper 'specific text' --pid 1234 --commit
```

History/search require exact usernames. Output is JSON (JSONL for listen); the first listener establishes a baseline unless `--from-start` is requested. Deduplicate by event_id and do not run concurrent listeners against one state directory. Keys are current-user DPAPI encrypted; never print or upload them.

Foreground send requires the already-open unambiguous chat and an empty draft; it raises the selected WeChat window. Honor existing send authorization, but do not send unsolicited test messages. On uncertain submission, inspect history before any further action; a server-backed row is not a read receipt.

For MCP use `runtime.json`'s `executable` and `mcp_args` (`["mcp"]`). A source installation instead uses its recorded `python` with `-X utf8 <script> mcp`. This supports wechat_sessions, wechat_contacts, wechat_history and experimental wechat_send; commit defaults to false.

The old WeChat build can reject login. `compat-version --pid ...` only inspects by default; apply the explicit experimental `--apply` only when the user requests fixing that restriction. It is fingerprint-gated, changes one temporary field and saves a rollback journal; no promise of future login acceptance. The user performs QR/login confirmation.

### Claude hook errors

This plugin defines **no UserPromptSubmit hook**. A Python-not-found hook error belongs to a separately configured hook, not to the standalone WeChat runtime. Inspect the named hook in Claude settings before changing it; preserve unrelated hooks and do not disable all hooks or reinstall WeChat. A non-blocking hook error does not establish that the CLI is unavailable. If this platform section is absent from the loaded skill, update the marketplace/plugin and reload Claude.

**End of Windows instructions. On Windows, do not execute the macOS section below.**

# macOS only: stable CLI

# wechat-use

## 诊断和读取组件

1.19.8 起，发送失败的窗口提示和复制诊断保留固定错误码、失败步骤及系统读写错误类别；状态未知时不自动重发。旧版已经省略的错误无法补回。

`wechat-use diagnostics --copy` 复制适合群聊的诊断摘要，完整报告保存在本机；`--copy --full` 明确复制完整报告。摘要不会包含聊天正文或密钥。

`wechat-use runtime-custody --json` 只检查 Python 文件及祖先目录。设置窗口可明确修复当前用户拥有的 `/opt/homebrew`、`/opt/homebrew/Cellar` 的组写权限，并保存修复记录；命令行需显式运行 `runtime-custody --repair --json`。未知归属、可写解释器或其他路径需要修复 Python 安装，不要放宽校验。

出现 `WXS-I-SOURCE-LOCK` 或 `not_expected_shared_dms_holder` 时，先正常结束工具任务，再正常退出并重新打开工具专用微信，登录后重试读取。不要手动删除或截断数据库、`-shm` 或 `-wal`；读取仍须通过原来的锁和文件校验。

1.19.9 提供窗口内“发送准备检查”。遇到 `wechat_in_foreground` 或 `background_navigation_unavailable`，使用返回的 `remediation_command`（`wechat-use setup --prepare-send`）打开引导，让用户在工具窗口完成界面确认；不要只口头转述操作步骤。确认只重新检查当前条件，不发送消息、不重放原请求；未知原请求只核对原回执。测试消息需要单独点击并确认。

会话、未读和联系人使用独立快照；这些查询成功不代表历史消息完整。工具专用微信在前台时，发送会返回明确的 `wechat_in_foreground`，原请求不会自动重发。

`doctor` 的 `read_pending` 表示快照正在更新或等待读取锁，读取暂未就绪。稍后复查；不要因此重新初始化、重启微信或发送测试消息。真实采集、校验或权限失败仍按故障诊断处理。

## 安装检查

先运行 `wechat-use --version`。缺少程序时使用GitHub Release安装器：

```bash
curl -fsSL https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh | sh
```

不要通过npm分发二进制，也不要逐件覆盖八件套。安装被未知任务拒绝时保留原状态，不强杀调试器或清理意图。新机器还需先准备并登录独立4.1.9副本；不能改用主微信。

## Triggers

- 发消息 / 发微信 / send WeChat
- 查聊天记录 / 微信历史 / 搜索消息
- 微信联系人 / 群成员 / 未读消息
- 收新消息 / 实时监听 / on-message 回调
- macOS 1.19.13 起默认不持续监听。`wechat-use listen` 或 daemon 消息订阅启动后才监听，最后一个订阅结束后停止；订阅成功前会先校验基线。`--wxid` 只过滤发给订阅者的事件，后台采集和撤回归档仍覆盖当前账号的消息库。HTTP 消息流在连接期间按需读取，不启动后台撤回归档。
- `search` 按需更新索引，提示索引更新时稍后重试。`recalled` 的后台归档只覆盖 daemon 消息订阅期间，未监听时已撤回的原文不能保证找回；微信设置中的原生防撤回功能独立。`wechat-use setup --validate-read` 可主动验证一次读取，不开启持续监听。
- 导出聊天 / 数据库统计 / 收藏
- MCP 查询微信历史 / 联系人 / 朋友圈；朋友圈能力以已安装运行时版本为准，见下方说明。
- 对接 Hermes / n8n / Dify / LangChain 本地 agent
- WeChat bot framework / Wechaty-like puppet

## 语音读取与转文字（macOS）

用户要求查看聊天内容或理解语音时，主动读取可用的语音转写，不要只返回“[语音消息]”或让用户手工抄写。

- 优先运行 `wechat-use history '聊天名或精确会话ID' -n 20 --json`。CLI 默认自动转写本机可用的语音，文字在 `display_text` 和 `media.transcript`，结果状态见 `media.transcript_status`；`--no-transcribe` 会关闭此行为。
- MCP 的 `wechat_get_history` 目前不会自动转写，也没有独立语音转写工具。遇到语音占位时，使用 CLI `history`，或取准确的消息 `server_id` 后运行 `wechat-use audio transcribe <server_id> --json --include-transcript`。消息 ID 保持十进制字符串，不经 JS Number 转换。
- 独立 `audio transcribe --json` 默认隐藏正文；AI 需要理解内容时必须加 `--include-transcript`。转写文字属于私聊内容，不复制到公开诊断、日志或公告。
- 缺少模型或依赖时，运行 `wechat-use audio setup` 完成一次性准备。仅转写当前账号本机可用的语音；未下载、未缓存或读取失败时说明状态，不猜内容，不发送测试消息，也不自动重试未知操作。

## 朋友圈读取（macOS 1.19.10）

先检查已安装运行时版本。1.19.10 支持 `wechat-use sns-feed --refresh -n 20 --json`：通过专用微信请求刷新后读取本机快照，首次使用可能打开工具内授权或手动确认窗口。照片、视频使用返回的朋友圈媒体引用；不要伪造聊天消息引用。刷新动作、本机落盘与服务器回执是不同证据，不能承诺远端历史完整。旧版返回 `db_scope_unsupported` 时，不为此重复初始化。已安装的候选版与公开发行版状态分别核对。

## 图片读取（统一入口，普通图与HD原图已实机验收）

聊天图片使用统一的精确消息取图接口。不要要求用户先在微信里点图，也不要把加密 CDN 地址、DAT 或 WXGF 原始字节直接交给识图模型。

- `history`、`digest`、`search`、`sent`、`recalled`、`new-messages` 主动读取时，每批最多自动解析两张图。结果在 `media.local_path` / `media.image` 中；图片可用时 `local_path_status=ready`。
- `media.image_ref` 是取图引用：`chatId`、`localId`、`serverId`、`md5`。localId/serverId 保持十进制字符串，不经 JS Number 转换；chatId 使用精确会话 ID。`deferred` 表示未开始该图，读取任务确实需要时可用该引用继续取图。
- MCP 的 `wechat_get_history` / `wechat_search_messages` 会直接附上已可用的 image content block，模型能看见图片。其余图调用 `wechat_get_image`，arguments 原样使用 `media.image_ref` 对象；`wechat_self_messages` 为保护账号信息返回不透明的 `image_ref` 字符串，传 `{"imageRef": token}`。这三个读取工具可设 `include_images:false` 只读元数据。
- HTTP：现有 bridge 的 `GET /image` 和 gateway REST 的 `GET /v1/image` 使用同一组引用字段作查询参数，返回校验后的 PNG/JPEG/GIF/WebP 字节；继续使用原有认证。Hermes `media.imageRef` / `media.downloadUrl` 给出相同引用和相对于 bridge 的取图地址。旧 CDN 元数据不是已解密图片。
- Wechaty `MessageImage` 和图片类 `MessageFile` 返回解密、必要时转换后的 FileBox，不再将缓存 DAT 当作可显示图片。
- 搜索 HTML 报告、归档导出和聊天窗口 `/img` 共用同一取图服务；查看用图片与经 XML MD5 验证的原始载荷分开。
- 元数据查询、发送 ACK 检查、后台事件流只附图片引用，不偷偷启动下载。用户主动读图才调用取图接口。`--no-images` 可跳过主动读取的自动取图；`search --no-media` 也不会暗中下载。
- `unavailable` / 已有 pending / unknown 不自动重试，不清旧 claim/pending。保留文字和引用，明确报告图片当前不可用；不猜 URL、密钥或资源版本。

前台 history/search 若有消息分片不可安全读取，`meta.status=possibly_stale_unavailable_shards` 且 `historical_completeness_verified=false`。只能说明已返回的内容，不能据此断言没有其他消息；部分范围没有命中时返回不可用。后台接收和游标仍要求完整范围。已有环境不要因图片暂不可用而重新 init、重启微信或清理 claim/pending。

原生下载仍受签名适配、目标账号/进程、owner 生命周期和发布执行门约束。1.19起提供统一图片接口；可用范围以消息元数据、签名适配和实际取图结果为准。TP/HTTP图片资源未认证时明确返回不可用，不猜参数下载。诊断型 `image inspect`、会话未读计数不启动下载。朋友圈、收藏或转发子消息中的独立业务资源，不伪造聊天消息引用去下载。

## 初始化与升级

- `init` 面向已登录的专用4.1.9，只读取有限内存候选，并用首页认证和完整私有DB/WAL快照验证。不直接用SQLite打开原库，也不自动重启或安装断点。`--force` 重新被动扫描；正常调用可先认证同账号缓存，但仍验证私有快照。
- `initialization_scope.snapshot_validated_databases`列出经过完整私有快照验证的核心范围；其他可用密钥只做首页认证，`full_account_integrity_verified=false`。核心范围全部验证及原采集进程释放确认后，才原子切换配置。核心密钥空、缺失、歧义或超时保留旧配置；旧claim/pending不清理。
- 后续导入新分片若提示需要初始化，可重新执行被动`init`。已发布的初始化密钥集合不由旧分片刷新器修改。
- 1.19.7 起普通 `wechat-use upgrade` 先验证当前完整 SDK，已是最新版直接结束，不暂停服务。有新版本才受控暂停并恢复服务；占用时正常退出专用微信和设置窗口，`init` 不会解除占用。
- 升级以GitHub Release八件套为一个原子版本。服务更新先核验原owner，再正常退出旧服务；未知owner会拒绝更新，不强杀调试器。
- `doctor --paths`的`page_authenticated`仅证明密钥匹配，`logical_integrity_verified=false`；它不证明全库、历史消息或接收端已验证。

## 日常操作

专用微信须已经登录；缺少副本时先按 [准备指南](docs/managed-419-setup.md) 创建。默认绑定保存在 `~/.wx-rs/managed-wechat.json`。副本关闭或账号未就绪时明确报告，不切到主微信。

```bash
wechat-use setup
wechat-use doctor --json
wechat-use sessions -n 20 --json
wechat-use contacts --query '名字' --json
wechat-use history '群名或精确ID' -n 50 --json
wechat-use search '关键词' --in '群名' --json
wechat-use history '精确会话ID' -n 50 --json --no-images
```

优先使用精确会话 ID。昵称或群名有歧义时查看候选，不自行选人。查询失败、覆盖不足或超时不能解释成“没有消息”；保留结构化状态。

发送必须有用户明确的收件人和内容授权。只读检查不发送测试消息，也不要求用户先手动发一条消息。

```bash
wechat-use send '具体内容' '收件人' --json
wechat-use send --file /absolute/path/report.txt --recipient '收件人' --json
wechat-use send --image /absolute/path/image.png --recipient '收件人' --json
```

发送前确认接收者；正常操作不激活、抬起或切换微信窗口。`submitted_unconfirmed` / `status_unknown` 不是失败，也不是送达。保留原 request ID，先查询原回执和精确历史，不换 ID 重发；发送者服务器记录不等于对方已读或接收文件字节一致。

1.19.1 可在设置窗口点击“核对原请求（不重发）”，或运行 `wechat-use send-receipt --request-id ORIGINAL_ID --expected-account ORIGINAL_ACCOUNT --json`。必须沿用原请求保存的精确账号；只连接已有后台，查询失败也不启动后台或重发。

1.19.4 起，`doctor --json` 的 `submission_ready` 表示当前接口可提交；`send_ready` 和 `send_delivery_verified` 不因此变为已验证。强送达未验证不会单独阻断环境自检，也不要据此重发未知请求。

设置提示缺少系统授权时，点击“授权并继续”，由本人确认 macOS 管理员弹窗，无需运行终端命令。取消后可以稍后继续；不要反复修复安装。

## 接入 agent

- 只读 MCP 使用 `wechat-mcp` stdio server。历史、搜索、图片工具走同一读取服务；图片可用时返回图片 content block。MCP 发送由独立的 `wechat-send-mcp` 提供，仅在用户需要发送能力时配置。
- HTTP Bridge 默认监听本机 `127.0.0.1:18400`。`/health` 检查当前 daemon、接收和发送就绪状态；不能只看 HTTP 200。接收状态 `inactive` 表示当前没有 daemon 消息订阅，不代表后台故障，也不代表读取已验证。
- Hermes 使用 `wechat-bridge --shape hermes`。群里是否 @ 当前账号以 bridge 的 `isMentioned` 为准；用 `fromSelf` 排除自发消息，不能只比较 senderId。
- `/messages/stream?since=<epoch>` 使用明确起点，避免无意回放全部历史。事件流只带媒体引用；主动需要图片时调用 `/image`，不要把加密 CDN 地址直接交给识图模型。
- Wechaty 使用 `wechat-wechaty-gateway`；图片返回可显示的 FileBox。CLI、MCP、Bridge、gateway 的细节以各自 `--help` 和 [能力说明](docs/capabilities.md) 为准。

程序分别为 CLI `wechat`、后台 `wechatd`、HTTP `wechat-bridge`、只读 `wechat-mcp`、发送 `wechat-send-mcp`、`wechat-wechaty-gateway` 及两个内部校验/任务组件。内部组件不接收聊天内容或由调用方提供的任意代码；不要逐件替换版本。

## 恢复与数据保护

`wechat-use setup` 复用已有登录、激活和有效权限。权限步骤以 `setup --json` 的 `service.accessibility_required` 为准；1.19 public 原生后台路径为 false，使用系统调试接口，不转入旧版辅助功能拖图标流程。日常读取复用已验证的密钥，不要求重启微信或点开图片。

密钥、配置、源消息 XML、账号标识和私有诊断只保存在用户自己的机器；不打印、上传或提交到仓库。不要用 SQLite 直接打开微信原库，不覆盖原库，不清理未知任务的 claim、pending 或输出。
