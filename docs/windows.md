# WechatUse Windows x64 实验版 0.1.0

解压整个安装包，在 PowerShell 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

自带运行时，无需 Python、WSL 或 Rust。安装到当前用户目录，并安装 Codex 的 `wechat-use` skill；重开终端后运行 `wechat-use doctor`。自定义路径：`-InstallDir 'D:\Tools\wechat-use' -SkillDir 'D:\Skills\wechat-use'`。

已支持账号发现、数据库初始化、联系人/会话/历史查询、文本搜索、增量监听、stdio MCP，以及当前已打开聊天的前台文本发送。发送默认仅预检，实际发送须加 `--commit`。安装过程不发送消息、不修改微信。

目前仅在 Windows 微信 4.0.6.17 上有人工验收记录。该旧版曾被服务端拒绝登录；显式 `compat-version` 实验在一次人工登录中有效，不能保证后续登录可用。仅已登录、兼容的账号才能使用读取功能。不要把本实验版当作稳定版或 macOS 的完整替代。暂不支持媒体、后台发送、自动切换聊天、HTTP Bridge 和 Wechaty。MCP 实际发送及重新扫码登录的可重复性尚未独立验收。

```powershell
wechat-use accounts
wechat-use init --db-dir 'D:\WeChat\xwechat_files\ACCOUNT\db_storage' --pid 1234
wechat-use sessions -n 20
wechat-use contacts --query 'name'
wechat-use history 'exact_username' -n 20
wechat-use listen --once
```

MCP 使用安装后 skill 目录 `runtime.json` 中的 `executable`，参数为 `["mcp"]`。密钥由当前用户 DPAPI 加密保存在 `%USERPROFILE%\.wx-rs\windows`，不上传账号数据。安装包包含依赖软件，授权文本在 `THIRD_PARTY_LICENSES` 中。

本包未经 Windows Authenticode 签名。请仅从官方 GitHub Release 下载并对照 `.sha256` 校验；安装器还会校验包内文件。报告问题时不要上传密钥、数据库或私人聊天正文。

发布页：https://github.com/leeguooooo/wechat-use/releases/tag/windows-v0.1.0

也可下载官方安装脚本后执行（PowerShell）：

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install-windows.ps1 -OutFile install-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
```

脚本固定选择 Windows 实验版标签，先校验 ZIP 的 SHA-256，再执行包内安装器，不会下载 macOS 的 latest 包。
