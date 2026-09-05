# 详细安装与授权

主 README 的「装一下（5 分钟）」是给已经知道自己在干嘛的开发者看的极简流程。这篇是完整版：每一步在干啥、出问题去哪查。

---

## 0. 前置

- macOS Apple Silicon
- 已关注频道 <https://t.me/wechatuse>（未关注 bot 拦截审核）
- 交流群（可选）：<https://t.me/Wechatuse_talk> — 用法交流 / 求助 / 反馈
- 不需要预装旧版微信；安装器会准备独立的 WeChat 4.1.9
- 终端有 `~/.local/bin` 在 `PATH`

---

## 1. 拿激活码

跟 [@WechatCliBot](https://t.me/WechatCliBot) 私聊：

1. 发 `/start`
2. 点「📝 申请激活码」按钮
3. 按提示回一行用途说明，例如：
   > 个人调研对话存档，希望让 Claude 自动同步给我每日待办
4. 等管理员审核（通常 1-24h）
5. 通过后机器人会私信你 `wechatuse_xxxxxx`

为什么人工审核 → [docs/why-activation.md](./why-activation.md)。

---

## 2. 装 CLI

```bash
curl -fsSL https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh | bash
```

`install.sh` 干的事：

1. 询问是否安装独立的微信 4.1.9，然后下载 CLI 到 `~/.local/bin/`
2. 优先复制本地支持的 4.1.9；没有时从腾讯官方下载固定安装包，验证 SHA-256 和签名
3. 创建 `~/Applications/WeChat-4.1.9-wechat-use.app`，独立 bundle id 和沙盒目录，默认绑定工具并关闭副本更新
   - 显示名统一为“微信 4.1.9（工具专用）”，图标带鼠标箭头和 4.1.9 标记。
   - 已有副本也会更新名称和图标；不会重启已登录的副本。运行中的 Dock 图标可能在副本下次启动后刷新。
4. 注册 `ai.wechat.bridge` LaunchAgent（开机自启 wechat-bridge）
5. 启动 LaunchAgent 跑 `/health` 探活

自动化安装用 `curl -fsSL https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh | WECHAT_USE_PREFER_419=yes bash`。设为 `no` 会取消安装。已有本地 4.1.9 时，可传 `WECHAT_419_SOURCE=/path/to/WeChat-4.1.9.app`。

打开新副本扫码登录，再运行 `wechat-use init`。以后直接运行工具即可，CLI 和后台服务都会使用该副本。副本未启动时会提示打开，不会改用主微信。设置保存在 `~/.wx-rs/managed-wechat.json`，旧账号配置保持原样。

确认 PATH：

- **fish**：`fish_add_path $HOME/.local/bin`
- **zsh / bash**：`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`

---

## 3. 授权「辅助功能」（TCC）<a id="tcc"></a>

**首次用 `wechat-use send` 前必须做一次，不做会静默失败。**

macOS Sonoma 起，跨进程合成键盘事件的发送方必须在「辅助功能」清单里，否则系统直接把事件丢掉，无错误码无日志。`wechat-bridge` / `wechatd` 走这个 API，必须授权。

打开下面两条，一条弹设置窗口、一条进入文件位置方便拖：

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open "$HOME/.local/bin"                    # Finder 打开，选中 wechat-bridge 拖进设置窗
```

然后：

1. 系统设置 → 隐私与安全 → **辅助功能**
2. 点 `+`，选 `$HOME/.local/bin/wechat-bridge`，加进清单
3. 打开右侧开关
4. 重启已经跑起来的 bridge，让它继承新权限：
   - LaunchAgent：`launchctl kickstart -k gui/$(id -u)/ai.wechat.bridge`
   - 手工启的：`pkill wechat-bridge; wechat-bridge &`

> `wechatd` 不用单独加，TCC 按 responsible-process 链继承 `wechat-bridge` 的授权。
> Input Monitoring / 输入监控 不参与 `wechat-use send` 路径，可以忽略。

确认授权到位：

```bash
wechat-use doctor --json | jq '.checks[] | select(.name=="ax_trusted")'
# → {"name":"ax_trusted","ok":true,"detail":"wechatd /Users/..../wechatd"}
```

---

## 4. 激活 + 初始化(顺序与 install.sh / README §3 对齐)

```bash
# step 1: 输入激活码
wechat-use auth activate wechatuse_xxxxxx
# ↑ 弹 macOS Keychain 授权框,点「Always Allow」

# step 2: 授权辅助功能(macOS Sonoma+ 强制)
# install.sh 已自动打开「系统设置 → 隐私与安全性 → 辅助功能」并定位到
# /Users/<you>/.local/bin/wechat-bridge,把它拖进列表勾上即可。
# 不做这一步,后面的 send 会静默失败(delivery_verify_timeout)。

# step 3: 体检(任何时候出问题先跑这个)
wechat-use doctor

# step 4: 抽 SQLCipher key(不同 WeChat 版本走不同的本地 key 抓取路径,
#   详情由 wechat-use init 自动选择)
wechat-use init
# ↑ 4.1.9 不再要求重启微信;4.1.7-8 第一次可能要 1 次 sudo 修 DevToolsSecurity。

# step 5: 自测发消息(filehelper = 微信「文件传输助手」,自测最佳目标)
#   首次会因为发送路径未就绪报 delivery_verify_timeout —— 这是预期。
#   按 send 错误信息里的 1-5 步操作(在 WeChat 里给文件传输助手手动发一条 hi)
#   再重跑即可。
wechat-use send "Hello" filehelper
```

完整 `wechat-use init` 内部细节 → [docs/why-init.md](./why-init.md)。

---

## 5. 验证

```bash
wechat-use send "Hello 🎉" filehelper      # 应该 < 1s 在文件传输助手收到
wechat-use sessions                        # 列出最近会话
wechat-use doctor                          # 全绿
```

任何一项失败 → [docs/troubleshooting.md](./troubleshooting.md)。

---

## 6. 多账号 / WeChat 多开 (`wechat-use clone`)

如果你要在同一台 Mac 上同时跑多个微信号(比如个人号 + 工作号 + bot 号),用 `wechat-use clone`:

```bash
# 装一个新的 clone bundle(创建 com.tencent.xinWeChat2 / xinWeChat3 / ... 的副本)
wechat-use clone install
wechat-use clone list

# 用 --bundle-id 指定 clone 跑命令
wechat --bundle-id com.tencent.xinWeChat2 init        # 给 clone 抽 key
wechat --bundle-id com.tencent.xinWeChat2 doctor
wechat --bundle-id com.tencent.xinWeChat2 send "..." filehelper
wechat --bundle-id com.tencent.xinWeChat2 sessions
```

每个 clone 拥有独立的:
- WeChat.app bundle (TCC 授权独立)
- `~/Library/Containers/com.tencent.xinWeChatN/...` 数据目录
- `~/.wx-rs/<suffix>/` 配置 + key + cursor (per-instance)

daemon 会为每个 bundle 起独立的 socket (`/tmp/wechatd-501-<suffix>.sock`),query / send 命令通过 `--bundle-id` 路由到对应 daemon。

⚠️ **辅助功能**:每个 clone 都需要单独授权 wechat-bridge 进辅助功能 —— 因为 clone 的二进制 cdhash 不同,macOS 视为新 app。第一次 send 失败先去授权。

---

## 7. 状态文件速查 (`~/.wx-rs/`)

排障 / 想清状态时知道每个文件干什么:

| 文件 | 用途 | 删除影响 |
|---|---|---|
| `keys.json` | 4.1.9 per-DB SQLCipher key (per-account 一份) | **删后所有查询命令立刻失效**;需重跑 `wechat-use init` 抓新 key |
| `key.hex` | 4.1.7/4.1.8 单 master key (legacy 路径) | 同上;`init` 自动按 WeChat 版本重抓 |
| `config.json` | 当前账号 db_storage 路径 + active wxid | 删后下次任意命令重新探测;无业务影响 |
| `auth.json` | 激活码绑定信息(machine_id / tier / expire_ts);跟 macOS Keychain 双备份 | 删了不丢激活,Keychain token 还在;下次自动从 Keychain 重 hydrate |
| `auth-cache.json` | profile API 网络应答缓存(6h TTL,避免反复打 wechat-profile.misonote.com) | 安全删,下次拉取重建 |
| `cursor.json` | `wechat-use new-messages` 增量游标 | 删后下次 `new-messages` 从"现在"起算,可能漏掉/重看一段消息 |
| `rva-cache.json` | 适配缓存(包含 cached raw_key 与按 WeChat build 校验过的内部偏移表) | 删后下次 `init` 重 calibrate(几秒钟);跨 WeChat 升级触发自动失效 |
| `wechatd.log` (v1.13.20+) | wechatd 启动失败时 stderr 落地处。每次重 spawn 截断重写,大小有界 | 安全删,纯日志 |
| `<bundle-id-suffix>/...` | clone 多账号场景 per-instance 子目录,镜像上面所有文件 | 单独删一个 clone 的子目录 = 重置那个 clone,主账号不受影响 |

**何时清整个 `~/.wx-rs/`** :换大版本 WeChat / 换账号 / 想完全 reset。清完跑 `wechat-use auth activate <code>` + `wechat-use init` 即可恢复(只要 Keychain token 还在,激活码不需要重新申请)。
