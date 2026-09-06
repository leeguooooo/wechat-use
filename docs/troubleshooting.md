# 排错手册

> **第一招**：跑 `wechat-use doctor` 看哪一行 ✗，然后照 hint 提示做。
> **第二招**：把 `wechat-use doctor` 整段输出 + 你的报错 DM 给 [@WechatCliBot](https://t.me/WechatCliBot)。

## init 相关

| 现象 | 原因 | 自救 |
|---|---|---|
| `Not allowed to attach to process` | DevToolsSecurity 没开 / WeChat 没 get-task-allow | v1.8.16+ init 自动修；老版本手动跑诊断信息里的命令 |
| `观察到 0 次触发` | 用户已登录但 init 错过了 key 写入时刻 | v1.8.13+ race fix 已修；如还 0 hits 贴诊断 |
| `运行时指纹不一致` 警告 | Tencent 热更过运行时组件 | calibrate 自动重新适配；如失败贴诊断 |
| init 超时 | 未登录、使用旧客户端或读取缓存尚不可用 | 确认工具专用微信 4.1.9 已登录并升级工具；默认 init 扫描现有进程，不需要重启微信 |

v1.8.15+ 起，init 失败时**会在终端 inline dump 完整诊断**（`================ 诊断信息 ================`）—— 贴整段就够。

## send 相关

| 现象 | 原因 | 自救 |
|---|---|---|
| `请先 wechat-use auth activate` | 还没激活 | DM bot 申请激活码 → `wechat-use auth activate <code>` |
| `激活码已过期` | 过期了 | `wechat-use auth renew` 看如何重新申请 |
| `unsupported WeChat build` | 当前 dylib 指纹还没在 profile API 注册 | 把 `wechat-use doctor` 输出贴给 bot，几小时内会推 |
| 首次发送较慢 | 后台准备聊天或等待送达核验 | 等待当前请求结束；保留诊断，不要并行重发 |
| 消息结果未确认 | 可能仍在处理，或服务端确认尚未写入 | 先查看目标聊天记录；不要直接重发 |
| 用户手动给别人发消息被路由错 | v1.9.0 早期 bug | v1.9.1 已修；升级到最新版本 |

### warmup

v1.18.3 的工具专用微信 4.1.9 路径会自动准备聊天，无需手动选择文件传输助手或预热发送。升级和工具重启后也不要求重新做手动预热。

新账号的图片发送另有发送者校准要求：文件助手中至少需要 3 条已有记录；不足时返回 `self_sender_uncalibrated`，图片尚未提交。这项限制仍在改进。

若微信暂停且没有其他正在执行的发送任务，可运行 `wechat-use unfreeze` 恢复当前专用微信。它不退出登录；恢复后先核对原消息是否已送达。

## auth / 激活

| 现象 | 原因 | 自救 |
|---|---|---|
| `该设备已领取过试用` | 同 machine_id 一次试用 | DM bot 重新申请 |
| `auth status` 显示 expired | token 过期 | `wechat-use auth renew` |
| Keychain 弹框反复弹 | 没点「Always Allow」 | 第一次激活时点 Always Allow 即可永久 |
| 没有 macOS Keychain（headless SSH） | 服务器场景 | `WECHAT_AUTH_TOKEN_ENV=wxp_tok_xxx wechat ...`（token 走环境变量不落盘） |

## daemon / 性能

| 现象 | 原因 | 自救 |
|---|---|---|
| 第一次 send 慢 5-7s | 冷启 daemon send 会话 | 后续 send 都是 ~700ms，正常 |
| daemon 莫名退出 | WeChat 自身 quit / 系统 sleep 唤醒 | 任意 query 命令会 lazy-spawn 新 daemon，无感 |
| `daemon ping` 失败 | wechatd 没起来或 socket 坏了 | `wechat-use daemon stop && wechat-use daemon start` |

## 语音转写(`audio` / `history` 自动转)

| 现象 | 原因 | 自救 |
|---|---|---|
| `[history] 语音转写依赖缺 (...)` | 还没跑过 `wechat-use audio setup` | 跑 `wechat-use audio setup`(2-3 分钟下载 ~1.5GB medium 模型 + 本地 build silk-decoder)|
| `wechat-use doctor` 显示 `audio_transcribe_default_model ✗` 但 status 还是 ok | 装了 small 没装 medium(history 默认用 medium) | `wechat-use audio setup --model medium` 补齐,或 `wechat-use history --transcribe-model small` 切已装的 |
| `whisper-cli failed (exit ...)` 模型损坏 | 下载中断 | `wechat-use audio setup --force-reinstall --model <X>` 重下 |
| transcribe 出来的文字不准 / 同音字错 | 用了 small 模型 | 升级到 medium / large 模型,小模型对中文同音字识别一般 |
| 转写很慢 | 冷启 cache 全 miss | 第一次跑会 ~1-3s/条;后续相同语音命中 SHA-256 cache 0.4s 内完成 |
| `[语音消息]` 占位仍然出现 | `--no-transcribe` 被加上了 / svr_id=0(草稿) | 看 `media.transcript_status` 字段诊断 |
| brew 没装,`audio setup` 报错 | 我们不自动装 brew(动 `/opt/homebrew` 整目录 + 要 sudo) | 去 https://brew.sh 装,然后重跑 setup |

## Tencent 热更后

WeChat 可能在「自动升级」关闭的情况下仍然换运行时组件（Sparkle / WeChat 自带更新）。

- **抓 key (`wechat-use init`)**：v1.8.13+ 默认 `--calibrate`，每个新运行时 binary 指纹自动校准并缓存。**不需要手动 `--force` / 换 dmg。**
- **发消息 (`wechat-use send`)**：v1.9.1 起从 server-side profile API 拉适配数据，新版本由我们后端推送，**客户端不用升级**。如果 profile API 上没有当前 binary 指纹，会报 `unsupported WeChat build` —— 把 doctor 输出贴给 bot 我们登记。

## 我没看到我的问题

DM [@WechatCliBot](https://t.me/WechatCliBot)，附上：

1. `wechat-use doctor` 整段输出
2. 报错命令 + 完整错误信息
3. （如果是 init / send 问题）`================ 诊断信息 ================` 整段
4. WeChat 版本：System Settings → Apps → WeChat → 看 build 号

通常 1-12h 回复。
