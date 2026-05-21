# 为什么 `wechat init` 要重启微信

微信在 macOS 本地存的所有数据（聊天记录、联系人、朋友圈缓存、收藏……）都是**加密**的。查询命令需要在初始化完成后才能解密读取本地数据库。

## init 在干什么

1. **重启 WeChat**：初始化需要在微信启动瞬间完成,所以 init 必须先把当前 WeChat 关掉再重新打开。
2. **一次性初始化**：仅在启动瞬间触发并立刻退出。**不会改 WeChat 二进制 / 不会写任何东西 / 不需要 sudo（除了 v1.8.16+ 的一次性系统前置）/ 不会对 WeChat 运行时组件重签名**（其他同类方案会改你的 WeChat.app，我们不改）。
3. **缓存到本地配置目录**：后续所有查询命令（`sessions` / `history` / `search` / ...）都从这里读，无需再 init。

只有微信**重启过**（机器重启、手动 quit、系统更新等）之后，本地缓存才会失效，这时再跑一次 `wechat init` 即可。

## 为什么第一次跑要 sudo 密码（一次性）

v1.8.16 起 init 自动检测 + 修复两项 macOS 系统前置：

1. **macOS Developer mode** — 关着本地调试接口连任何进程都不能使用。修复：`sudo DevToolsSecurity -enable`（系统级一次性开启）
2. **WeChat 主可执行文件本地签名属性** — 官方默认签名禁止本地调试。修复：`sudo codesign --force --sign - --entitlements <plist> /Applications/WeChat.app/Contents/MacOS/WeChat`（本地 ad-hoc 重签，**只动主可执行文件**，运行时组件 + 登录态 + 数据全不动）

每步执行前 init 会打印「是什么 / 为什么 / 执行 / 影响」四段说明，**不会偷偷跑 sudo**。如果你不想自动跑，按 Ctrl-C，自己手敲也一样。

WeChat 自动更新后第二项会被覆盖，下次 init 自动再修一次。

## v1.8.13+ 自动 calibrate

Tencent 热更可能在「自动升级」关闭的情况下仍然把 WeChat 运行时组件换成新版本（Sparkle / WeChat 内置更新路径），新版本里关键路径会偏移。

v1.8.13 起，init 默认带 `--calibrate`，自动在新运行时组件上重新适配并缓存。**每个新运行时 binary 指纹上自动校准。不再需要手动 `--force` 或换 dmg。**

## 失败怎么办

v1.8.15+ 起，init 失败时会把所有诊断信息（`================ 诊断信息 ================`）直接打印在终端里，**贴整段输出到 [@WechatCliBot](https://t.me/WechatCliBot) 即可**，不用再去 `/var/folders/.../wx-calibrate-NNN/` 翻 log。

常见排错见 [troubleshooting.md](./troubleshooting.md)。
