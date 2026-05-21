# 完整能力矩阵

| 能力 | 状态 | 命令 | 说明 |
|------|------|------|------|
| 提取 SQLCipher key | ✅ v1.1 | `wechat init` | 一次性；WeChat 重启后重跑 |
| 抗 Tencent 热更（auto-calibrate） | ✅ v1.8.13 | `wechat init` 默认 | 新 dylib 自动适配，每个新 SHA 校准并缓存 |
| 后台发文本（零闪屏） | ✅ v1.0 / v1.8.10 真零闪 | `wechat send TEXT RECIPIENT` | 本地 keyboard event + 调试接口 |
| daemon-backed send（~700ms 热路径） | ✅ v1.9.0 | 默认走 daemon | 持久 send 会话；CLI 只 RPC |
| 不劫持用户手动发消息 | ✅ v1.9.1 | 默认 | 一次性 sentinel + 800ms 过期 |
| recipient 模糊解析（昵称 / 备注 / wxid） | ✅ v1.1.5 | 默认 | 多匹配返回候选清单 |
| 群发到群聊 | ✅ v1.1 | `wechat send "..." "群名"` | |
| `wechat doctor` 自检 | ✅ v1.1.3 | `wechat doctor` | lldb / 签名 / dylib 指纹 / daemon 一行看完 |
| Telegram 激活码 + 人工审核 | ✅ v1.9.1 | `wechat auth activate/status/renew` | machine_id 绑定，反滥用门槛 |
| Telegram 频道关注门槛 | ✅ v1.9.16 | 自动（bot 侧） | 申请前必须关注官方频道，否则 /request / 按钮一律被拦 |
| 审批时加备注 | ✅ v1.9.20 | admin 点 ✏️ 加备注 | `reviewer_note` 列，邀请来源长期可查 |
| token 进 macOS Keychain | ✅ v1.9.1 | 自动 | service `wechat-skill-profile-api` |
| AEAD 加密 profile API | ✅ v1.9.1 | 自动 | XChaCha20-Poly1305 + HKDF(token) + 6h TTL |
| send 冷启动预警 | ✅ v1.9.17 | `wechat doctor` + `wechat init` | doctor 三态 + init 完成打印 warm-up 指引 |
| send 失败自动诊断块 | ✅ v1.9.16 | `wechat send` | 失败时打印可复制诊断块，一行贴回就能定位问题 |
| history / search 跨分片合并 | ✅ v1.9.19 | `wechat history`、`search` | 跨分片自动合并 + 时间排序 |
| **本地 HTTP bridge（agent 集成）** | ✅ v1.10.0 | `wechat-bridge` | 127.0.0.1:18400 loopback only;9 路 HTTP + SSE(完整路由表见下方);可选 `WECHAT_BRIDGE_BEARER`;`--shape hermes` 切 Hermes WhatsApp-bridge wire shape |
| 权威 @-mention 列表（群） | ✅ v1.10.25 | SSE `mentionedIds` | daemon 端权威解析；之前是空数组 |
| Self-echo 防护 | ✅ v1.10.25 | SSE `fromSelf:bool` | bridge 记录自己 /send 过的行；客户 `fromSelf===true` 直接 drop，避免 agent 回自己 |
| 消息类型分类（Wechaty 对齐） | ✅ v1.10.26 | SSE `messageKind` | 16 enum 值，text/image/audio/video/url/mini_program/recalled/… |
| 结构化 URL 卡片 | ✅ v1.10.27 | SSE `urlLink` | `{title, description, url, thumbUrl}` |
| 结构化小程序 | ✅ v1.10.27 | SSE `miniProgram` | `{title, description, appId, username, pagePath, thumbUrl}` |
| 结构化引用回复 | ✅ v1.10.27 | SSE `refer` | `{svrId, fromUser, chatUser, displayName, content}` |
| 结构化撤回 | ✅ v1.10.27 | SSE `recall` | `{replacedMsgId, text}` |
| 结构化媒体元数据 | ✅ v1.10.27 | SSE `media` | `{aesKey, md5, cdnUrl, cdnThumbUrl, length, durationSeconds, localPath}` |
| SSE payload JSON schema 契约 | ✅ v1.10.26/27 | `wx/schema/sse-payload-v1.10.27.schema.json` | draft-07，additionalProperties:false，daemon 构建期跑契约单测 |
| 列最近会话 | ✅ v1.1 | `wechat sessions` | |
| 联系人列表 / 搜索 | ✅ v1.1 | `wechat contacts [--query]` | 昵称 / 备注 / wxid 模糊 |
| 查聊天记录 | ✅ v1.1 | `wechat history <chat> [-n] [--since/--until]` | |
| 全库消息搜索 | ✅ v1.1 | `wechat search <keyword> [--in <chat>]` | |
| 有未读的会话 | ✅ v1.2 | `wechat unread` | private/group/official 过滤 |
| 群成员 | ✅ v1.2 | `wechat members <group>` | |
| 收藏 | ✅ v1.2 | `wechat favorites` | text/image/article/card/video |
| 统计 | ✅ v1.2 | `wechat stats <chat>` | 活跃度 / 发言人 / 时段 |
| 收图（本地 + CDN fallback） | ✅ v1.13.11/12 | `wechat image get <messageId> --chat <id>` | 默认 `--from auto` 先走 daemon 内快路径（5–7 s 冷启），未命中再 fallback CDN replay。要求图先在 WeChat UI 里点开过一次 |
| 收语音（raw SILK_V3） | ✅ v1.13.21 | `wechat audio get <svr_id>` | 本地纯读，落 `~/.wechat/audio-cache/<svr_id>.silk` |
| 语音转文字（whisper.cpp + SILK pipeline） | ✅ v1.13.25 | `wechat audio setup` + `wechat audio transcribe <svr_id>` | `setup` 一次性装齐 ffmpeg / whisper-cpp / kn007 silk-decoder / 默认 medium 模型(1.5GB,中文准度好);`transcribe` 一条龙跑 silk → 16kHz wav → whisper。`--json` 默认 `transcriptRedacted: true` 不出文字防 agent log 外泄,`--include-transcript` 才出 |
| **history 自动转写语音** | ✅ v1.13.25-28 | `wechat history <chat>` (默认) | agent 看群历史时,语音消息自动转成文字塞进 `display_text` + `media.transcript`,**告别 `[语音消息]` 占位破上下文**。SHA-256 内容寻址 cache 二次访问 0.4s 全 hit(`pipeline_version` 进 cache key v1.13.26+,tool 升级自动 invalidate);`media.transcript_status` 字段诊断(`cached` / `transcribed` / `no_deps` / `failed` / `skipped_svr_id_zero` / `invalid_input`);`--no-transcribe` opt-out / `--transcribe-model small` 切小模型 / `--quiet` 静默 stderr(JSON 模式自动开)。`wechat doctor` 拆 `audio_transcribe_setup`(总 ok)+ `audio_transcribe_default_model`(ok 反映现实)两行 v1.13.27+ |
| display_name 解析（群名/备注/昵称） | ✅ v1.13.8/9 | `sessions` / `unread` / `contacts` / `history` | 自动把 `xxxx@chatroom` 映射成群名；history 同时给出 `chat_display_name`（agent 直接看懂） |
| 4.1.9 适配 | ✅ v1.13.7 | `wechat init` | 跟上 WeChat 4.1.9 本地存储变化；查询命令全部复活 |
| 导出（Markdown / JSON） | ✅ v1.2 | `wechat export <chat>` | |
| 朋友圈数据(只读 sns.db) | ✅ v1.14.0 | `wechat sns-feed / sns-notifications / sns-search` | 朋友圈时间线 / 谁点赞评论了我 / 关键词检索;只读,纯本地 |
| `wechat doctor --paths` | ✅ v1.14.0 | `wechat doctor --paths [--json]` | DB root + 3.x/4.x 路径 + WeChat 进程 + TCC 状态一行看完 |
| `wechat doctor --image` | ✅ v1.14.1/2 | `wechat doctor --image [--json]` | 图片解密路径自检,避免假绿 |
| `wechat init --literal-scan` | ✅ v1.14.0 | `wechat init --literal-scan` | 版本无关 fallback (WeChat 大版本升级 适配完成前临时跑) |
| history 引用 / 合并转发 / 文件 | ✅ v1.14.0 | `wechat history` 自动渲染 | 引用消息 → `[引用 X 「abc」] ↳ Y: txt`;合并转发消息出 `forwarded_messages` 数组;文件消息出 `media` 元数据 |
| `wechat history --brief --full` | ✅ v1.14.0 | `wechat history <chat> --brief --full` | brief 终端模式默认 100 char 截断,`--full` 关掉 |
| daemon 缓存自适应 | ✅ v1.14.0 | 自动 | 改群名 / 改备注 / WCDB 重建 DB 时 daemon 自动检测变化 reopen,不再返老数据 |
| 实时收消息 | ✅ v1.3 | `wechat listen [--wxid X] [--format json]` | 新消息 <500ms push;--wxid 接受昵称/群名(自动解析,不存在立即报错不 silent) |
| AI 回调触发 | ✅ v1.3 | `wechat listen --on-message CMD` | 每条消息 spawn CMD,env 变量传 payload(下一行) |
| `--on-message` env 变量表 | ✅ | — | `WECHAT_MSG_TEXT` (清洗后正文,自动剥群 sender 前缀) / `WECHAT_MSG_SENDER_WXID` (群消息;DM 为空) / `WECHAT_MSG_CREATE_TIME` (epoch s) / `WECHAT_MSG_LOCAL_ID` / `WECHAT_MSG_LOCAL_TYPE` / `WECHAT_MSG_TABLE` / `WECHAT_MSG_DB` / `WECHAT_MSG_SENDER_ID`(per-chat 序号字符串,几乎不用)。`WECHAT_MSG_*` 通过 env 传,免 shell 注入 |
| 后台 daemon | ✅ v1.2 / v1.7.5 自动 | `wechat daemon start` (可选) | 持久 SQLCipher 池；查询 <30ms |
| 全 Rust 二进制 | ✅ v1.5+ | `wechat` + `wechatd` | 比旧 Python 快 ~385× |
| dylib SHA-256 指纹校验 | ✅ v1.7.2 | `wechat doctor` | 漂移立即标红 |
| 发图片 / 文件 | ⏳ roadmap | — | 收图已 ship（v1.13.11+），发图分支适配中 |
| **wechaty Puppet gRPC gateway** | ✅ v1.10.32 | `wechat-wechaty-gateway` | 127.0.0.1:18401；任意 wechaty TS/Python/Go bot 零改动接真号 |
| **远程 gateway（Cloudflare Tunnel）** | ✅ v1.11.1 | `wechat tunnel setup --hostname=...` | 把本机 REST 桥（:18402）暴露公网，远程 fetch + ES256 JWT 同步调；同步直连场景 |
| **SaaS outbox/webhook 接入** | ✅ v1.12.0 | `wechat orchestrate setup` | NAT-friendly（不需公网/域名），Mac 全 outbound：poll SaaS outbox + push webhook，HMAC 签名 + 幂等键 + 持久化 ack |
| 群发 / 定时 | ❌ 不做 | — | 反滥用；LICENSE 禁止 |
| Linux / Windows / Intel Mac | ❌ | — | macOS arm64 only |
| 不在已验证 build 表里的 WeChat | ⚠️ profile API 推送中 | — | 通过 server-side profile，无需重发 release |

图例：✅ 生产可用 · ⏳ 开发中 · ❌ 不做 · ⚠️ 需配置

## 不打算做的

- **群发 / 自动加好友 / 反向爬别人朋友圈**：这是协议侧滥用，LICENSE 禁止
- **Linux / Windows / Intel Mac**：精力有限，本项目仅适配 macOS arm64
- **公开版本适配实现细节**：本项目不公开版本适配的实现细节，适配数据由 profile API 服务端推送

## 输出格式

所有查询命令默认输出 **YAML**（agent / 人都友好，省 token）。加 `--json` 切换 JSON：

```bash
wechat sessions --json | jq '.[] | select(.chat_type=="private")'
```

## 接 agent 平台（Hermes / n8n / Dify / LangChain）

两种方式都稳定、都走同一套激活码 gating，任选：

### CLI-subprocess 模式（zero setup）

```bash
# 入站流
wechat listen --format json | your-adapter.py

# 出站
wechat send --text "$BODY" --wxid "$TARGET" --json
```

### HTTP bridge 模式（v1.10.0+，适合 Hermes 这类 HTTP-native adapter）

```bash
wechat-bridge &          # 默认 127.0.0.1:18400 loopback only;install.sh 若有 plist 已自动起
curl http://127.0.0.1:18400/health
curl -X POST http://127.0.0.1:18400/send \
  -H 'Content-Type: application/json' \
  -d '{"wxid":"filehelper","text":"hello"}'

# ⚠️ SSE /messages/stream 默认 ?since=0 一连立刻 backfill **全部历史**(实测 1.3MB+)。
# 长流 / agent 场景务必传 ?since=<epoch> 限制起点。先取一个起点 ts:
SINCE=$(wechat new-messages -n 1 --json | python3 -c "import sys,json; print(json.load(sys.stdin)['rows'][0]['create_time'])")
curl -N "http://127.0.0.1:18400/messages/stream?since=$SINCE"
```

#### 路由完整列表 (native shape)

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | bridge + daemon 健康 + send_readiness 状态。永远公开,即使设了 BEARER |
| GET | `/chats?limit=N` | 最近会话(=`wechat sessions`) |
| GET | `/unread` | 有未读会话(=`wechat unread`) |
| GET | `/contacts?query=X&limit=N` | 联系人列表/查询(=`wechat contacts`) |
| GET | `/resolve?hint=X&limit=N` | 模糊解析 hint → wxid 候选(=`wechat send` 内部 resolver) |
| GET | `/chat/{wxid}` | 该会话最近 N 条消息 |
| GET | `/chat/{wxid}/history?since=&until=&limit=` | history 接口(=`wechat history`) |
| GET | `/messages/stream?since=<epoch>` | SSE 实时新消息推送。⚠️ 默认 since=0 = 全历史 |
| POST | `/send` JSON `{wxid, text, mention?}` | 发消息。返回 `{status, diagnostic, ...}` |
| POST | `/typing` (`hermes` shape only) | typing indicator,跟 Hermes WhatsApp-bridge 对齐 |

`/send` 返回 `{status: delivered / submitted_unconfirmed / status_unknown / failed, diagnostic, ...}`，正好对得上 Hermes / WhatsApp bridge 那种 contract。

**鉴权**:`WECHAT_BRIDGE_BEARER=<secret>` env 设了就要求 `Authorization: Bearer <secret>`(`/health` 不要)。loopback 默认信任,公网 / Tailscale 暴露场景才需要。

**激活码不会被绕**:bridge 只转发,wechatd 仍然做 AEAD + 服务端过期校验;未激活 / 已过期 → HTTP 401 / 402。
