# wechat-use

<p align="center">
  <img src="./assets/hero.png" alt="鼠标在老式画图程序里一像素一像素蹭出来的 wechat-use logo——绿色，烂，似像非像" width="540">
</p>

<p align="center"><sub><i>是的，logo 就长这样。鼠标在画图程序里蹭的，将就看。</i></sub></p>

把 macOS 上的微信变成给 AI agent / bot 用的**本地 API**。不上云、不上 iPad 协议、纯本地实现，数据只在你这台 Mac 上动。

> `wechat-use` 是 **`*-use` 系列**的一员——让 AI agent 直接操作你本地真实工具 / 设备：
> [`profile-use`](https://github.com/leeguooooo/profile-use)（本地个人资料填表）·
> [`iphone-use`](https://github.com/leeguooooo/iphone-use)（驱动真 iPhone）·
> [`chrome-use`](https://github.com/leeguooooo/chrome-use)（浏览器自动化）· **`wechat-use`**（macOS 微信）。
> 统一定位：**本地优先、不上云、用户完全掌控数据**。

<p align="center">
  <img src="./assets/family.png" alt="四个画得很丑的图标：profile / chrome / iphone / wechat" width="500">
</p>

<p align="center"><sub><i>一家四口，谁也别嫌谁画得丑。</i></sub></p>

> **专注支持微信 4.1.9**（build 268596 / 268602）。安装器**自动创建并绑定独立的 4.1.9 副本**，独立登录、独立保存聊天数据、关闭自动更新；你的主微信照常使用和升级，聊天数据不动。其他版本保留历史实现，不再承诺持续适配。
>
> **命令名**：主命令是 `wechat-use`；装好后 `wechat` 是等价别名（`wechat-use send …` ≡ `wechat send …`），老脚本无需改动。

## 亮点功能

- 💬 发消息（**后台零闪屏**）+ **@ 真红点**提醒
- 📜 读消息 / 历史 + 全文搜索（FTS）+ 导出
- 👥 联系人 / 群 / 会话（群名自动解析）
- 🟢 朋友圈（只读）· ⭐ 收藏 · 🖼 图片（heap 直读 + CDN 回源）
- 🎙 语音消息转文字（whisper 本地转写）
- ↩️ 撤回消息归档恢复
- 💻 **终端聊天 TUI**（`chat`，Claude Code 风，在终端里收发，屏幕上看不出在聊微信）
- 🥷 **摸鱼伪装**（`disguise` 把微信 App 伪装成 dev 工具 + 老板键 `⌃⌥Space` 一键隐藏）
- 🛰 daemon + `listen` 实时收消息 · 🔌 HTTP bridge（REST）· 🤖 Wechaty puppet gateway（gRPC）
- 🔀 多账号 / 多版本并存（`--bundle-id` 路由）

完整能力矩阵 → [docs/capabilities.md](./docs/capabilities.md)。

---

## 装一下（5 分钟）

**1. 拿激活码** — 跟 [@WechatCliBot](https://t.me/WechatCliBot) 私聊 → `/start` → 「📝 申请激活码」→ 写一行**个人用途**说明 → 通过后发你 `wechatuse_xxxxxx`。前置：关注频道 <https://t.me/wechatuse>（release / 适配公告）。审核 1-24h，[为什么走审核制](./docs/why-activation.md)。仅个人研究用途，商业 / 对外服务场景**不予发放**。交流求助：[wechat-use 交流群](https://t.me/Wechatuse_talk)（可选）。

**2. 装 CLI**

```bash
curl -fsSL https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh | bash
```

安装器自动准备并绑定独立微信 4.1.9 副本，本地已有支持版本就复用，否则从腾讯官方下载并校验。主微信保持原样。

**3. 在“微信工具设置”中完成剩余步骤（v1.18.6 起）**

窗口会复用已有激活、登录和有效权限，只显示还缺的步骤。首次使用时，在窗口粘贴激活码，按提示完成微信登录和 macOS 授权；系统列表缺项时，把窗口中的工具图标拖入即可。后台初始化和连接验证自动继续。

后续恢复也打开“应用程序”中的“微信工具设置”，无需输入诊断或修复命令。旧授权开关已开却不生效时，窗口先刷新后台检查，再提供对应工具的恢复说明。详见[设置指南](./docs/setup.html)。v1.18.5 及更早版本的终端流程见[旧版安装说明](./docs/install.md)。

v1.18.7 增加问题代码、“复制诊断信息”和系统确认入口，已发布为正式版。用 README 的安装命令升级即可获得；v1.18.6 用户可在错误页点一次“修复安装”。

[设置问题处理指南](./docs/setup-support.html)

---

## 命令行用法

```bash
# 发消息（recipient 可以是 wxid / 昵称 / 备注 / 群名，找不到会列候选，不静默）
wechat-use send "你好" 张三
wechat-use send "Hello 🎉" filehelper          # filehelper = 文件传输助手，自测最佳目标
wechat-use send "test" "李工" --dry-run         # 验证 fuzzy match 但不真发

# 查聊天
wechat-use sessions --brief -n 10              # 单行会话，带未读数
wechat-use contacts --brief -n 20             # 单行联系人（姓名 + wxid）
wechat-use unread -n 5                         # 有未读的
wechat-use history "张三" -n 50                # nickname / 群名也解析；--chat <id> 亦可
wechat-use search "会议" --in "项目讨论组"       # --in 同样解析昵称 / 群名

# 收消息流（agent 神器）
wechat-use listen --wxid filehelper
wechat-use listen --on-message ./reply.sh

# 语音转文字（v1.13.25+）
wechat-use audio setup                         # 一次性装齐 ffmpeg/whisper.cpp/silk-decoder/模型
wechat-use history "群名" -n 50                # 默认把语音转成 display_text，不再卡 [语音消息]

# 终端聊天 + 摸鱼伪装
wechat-use chat [张三]                          # 终端聊天 TUI（Claude Code 风），打字回车后台发出
wechat-use disguise apply console              # 微信 App 伪装成终端（Dock/Cmd-Tab 都不叫微信）
wechat-use disguise bosskey on                 # 老板键 ⌃⌥Space 一键隐藏/恢复；restore 变回绿色微信

# 自检
wechat-use doctor                              # 任何问题先跑这个
wechat-use auth status                         # 第一行直接告诉你「剩余 X 天」
```

---

## 接 AI agent / 平台

所有接入面共享同一个 daemon + 同一个激活码，**装一次全开**：

- **Claude Code / Codex / Cursor** — `npx skills add leeguooooo/wechat-use -y -g`，agent 读 [SKILL.md](./SKILL.md) 自动学会全部命令（先装 CLI 再装 skill）。
- **任意 [wechaty](https://github.com/wechaty/wechaty) bot（TS / Python / Go）** — `wechat-wechaty-gateway` 起 gRPC :18401（`puppet: 'wechaty-puppet-service'` + `endpoint: '127.0.0.1:18401'`）。**首个真号 wechaty macOS 协议**，bot 零改动跑在自己微信上。例子见 [`examples/`](./examples/)。
- **HTTP / SSE bridge（Hermes / n8n / Dify / LangChain）** — `wechat-bridge` 起 HTTP+SSE :18400，8 个稳定路由，加 `--shape hermes` 跟 Hermes WhatsApp-bridge 同 shape 零适配。
- **远程驱动（接自己 SaaS / CF Worker）** — `wechat-use orchestrate` 全 outbound poll，**不需公网 IP / 域名**（家用宽带 / 内网 / GFW 后都行，[协议](./docs/v1.12-orchestrate-protocol.md)）；或 `wechat-use tunnel` 走 Cloudflare Tunnel + JWT 同步调，适合 CF Worker 偶发触发（[文档](./docs/remote-gateway.md)）。

---

## 安全 / 平台 / 风险

<p align="center">
  <img src="./assets/local.png" alt="一台破旧电脑，头顶一朵被红叉划掉的云——意思是数据不上云、只在本机" width="380">
</p>

<p align="center"><sub><i>数据不上云。云被划掉了。就这台破电脑。</i></sub></p>

- **安全**：聊天 / 联系人 / key / wxid **永不出本机**，只向 profile API 上报当前 WeChat 指纹拉适配数据。`~/.wx-rs/` 下的 key 文件已 chmod 600，**绝不要**贴 git / pastebin / 群聊；激活码 token 进 macOS Keychain。**不动你的主微信**——只对工具专用的 4.1.9 副本 ad-hoc 加 `get-task-allow` entitlement。
- **平台**：macOS Apple Silicon，微信 **4.1.9**（build 268596 / 268602，以 `wechat-use doctor` 输出为准）。`wechat-use init` 自动按版本适配；WeChat 热更后通过 server-side profile 推送新版本适配数据，**无需重发 release**。
- **排错**：`wechat-use doctor` 看哪一项 ✗ → 整段输出 + 报错提 [issue](https://github.com/leeguooooo/wechat-use/issues/new)。详细 → [docs/troubleshooting.md](./docs/troubleshooting.md)。

**风险分级** —— 本工具操作的是**你自己的**账号，微信风控对异常行为会限制甚至封号，这跟工具无关，正常人做同样的事一样会被风控。

| 用法 | 风险 |
|---|---|
| 个人自用、人类频率、给自己 / 熟人 / 文件传输助手发消息 | 跟正常用微信一致 |
| daemon 24/7 监听消息流、偶发自动回复 | 低 |
| 高频加好友 / `searchcontact` 陌生人 | **高，会触发 24h 风控** |
| 群发 / 营销 / 自动 @ all / 跨号操作 | **极高，封号** |

- 个人自用、不做营销 → 放心用；**不要**拿去跑加好友 / 群发机器人、对外 SaaS 客服。
- 微信**大版本**升级（4.1.x → 4.2.x 这种，非 build 热更）后等本项目适配再用——本项目与微信官方无任何关联，出新版本我们也是事后才知道。
- 对副本 ad-hoc 重签改了签名，由使用者**自行承担**风险。详细法律 / 道德条款见 [DISCLAIMER](./DISCLAIMER.md)。

---

## 关于 fork / Notice to forks

**`github.com/leeguooooo/wechat-use` 的 `main` 分支是本项目唯一权威版本。** 任何 fork、镜像、归档快照里的 README / commit 历史 / release notes / issues 都**不代表本项目当前立场**——尤其早于 [`1497b15`](https://github.com/leeguooooo/wechat-use/commit/1497b15)（2026-05-19）的快照，其内容已被本仓主动 redact / 删除，以准确反映本项目作为**个人研究、永久免费、非商业**工具的定位。所有 fork、镜像、衍生作品**继续受 [LICENSE](./LICENSE) 与 [DISCLAIMER](./DISCLAIMER.md) 约束**，任何商业使用、转售、SaaS 集成、付费分发均**不被许可**。若你持有 fork，请从 upstream 同步到最新版本或删除副本。

**The `main` branch of `github.com/leeguooooo/wechat-use` is the sole authoritative version of this project.** README / commit history / release notes / issues in forks, mirrors, or third-party archives — especially snapshots predating [`1497b15`](https://github.com/leeguooooo/wechat-use/commit/1497b15) (2026-05-19) — do not represent this project's current position. Forks remain bound by [LICENSE](./LICENSE) and [DISCLAIMER](./DISCLAIMER.md). If you hold a fork, please sync it from upstream or delete it.

---

## 文档

- [docs/why-init.md](./docs/why-init.md) — init 在干嘛 · [docs/why-activation.md](./docs/why-activation.md) — 审核制理由
- [docs/capabilities.md](./docs/capabilities.md) — 完整能力矩阵 · [docs/install.md](./docs/install.md) — 详细安装 / TCC / 多账号 / LaunchAgent
- [docs/troubleshooting.md](./docs/troubleshooting.md) — 热更 / 签名 / 0 hits 等 · [docs/CHANGELOG.md](./docs/CHANGELOG.md) / [docs/ROADMAP.md](./docs/ROADMAP.md)
- 远程驱动两条路：[orchestrate](./docs/v1.12-orchestrate-protocol.md) / [remote-gateway](./docs/remote-gateway.md)

**深入原理**
- [让微信在后台替你发消息，我曾经把它的数据库搞坏 —— 从「挂调试器」到「零附着」](https://blog.leeguoo.com/zh/posts/wechat-macos-noattach-send/) — 后台 send 为什么会弹「数据库已损坏」，以及怎么把 LLDB 断点写内存换成 `mach_vm_write` 全程不附着。
- [上班摸鱼聊微信，把它搬进终端、还伪装成 dev 工具——以及背后的原理](https://blog.leeguoo.com/zh/posts/wechat-macos-moyu-terminal-disguise/) — `chat` 终端聊天、`disguise` 伪装 App、老板键 ⌃⌥Space 全局热键。

---

## License + 免责

[非商业自研协议](./LICENSE) + [DISCLAIMER](./DISCLAIMER.md)。**仅限**个人学习 / 研究 / 对本人账号的个人自动化。本工具基于 macOS 公开调试接口实现，与微信官方无任何关联，也**不提供任何形式的商业授权、批量分发、SaaS 合作、对外有偿服务**。**严禁**用于商业用途 / 群发营销 / 刷单 / 自动化非本人账号 / 爬取或监控他人数据。使用即表示用户**自行承担全部风险**（含账号被限制 / 封禁的可能）。

---

> Built by **leeguooooo** — field notes on AI agents, reverse engineering & Cloudflare Workers at **[blog.misonote.com](https://blog.misonote.com)** · follow on **[X @leeguooooo](https://x.com/leeguooooo)**

<!-- use-family -->
## The `*-use` family

Small, composable CLIs that give an AI agent hands on one real thing. Same shape
everywhere: `curl … install.sh | sh` to install, `npx skills add leeguooooo/<name>`
to teach your agent, JSON on stdout.

| Repo | Gives your agent |
|---|---|
| [chrome-use](https://github.com/leeguooooo/chrome-use) | A real browser — logged-in sessions, forms, scraping, screenshots |
| [mail-use](https://github.com/leeguooooo/mail-use) | Email — read, search, send, triage across Gmail / QQ / 163 / any IMAP |
| [iphone-use](https://github.com/leeguooooo/iphone-use) | A real iPhone — tap, type, screenshot, pull on-device data |
| [discord-use](https://github.com/leeguooooo/discord-use) | Discord — messages, channels, forums, webhooks (REST-only, Rust) |
| [cookie-use](https://github.com/leeguooooo/cookie-use) | Many logged-in accounts per site — capture, switch, apply sessions |
| [profile-use](https://github.com/leeguooooo/profile-use) | Your personal profile, safely — fill signup / KYC / checkout forms |
| [bitwarden-use](https://github.com/leeguooooo/bitwarden-use) | Bitwarden / Vaultwarden — headless passkey (FIDO2) login |
| [chatgpt-use](https://github.com/leeguooooo/chatgpt-use) | Your ChatGPT subscription as a coding-agent backend — no API key |
| [computer-use](https://github.com/leeguooooo/computer-use) | The macOS desktop itself |
| [pixcake-use](https://github.com/leeguooooo/pixcake-use) | Read-only PixCake probing — snapshot / diff / SQLite inspection |
