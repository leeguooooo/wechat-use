# 路线图

## 在做 / 即将做

- **发图片 / 文件**：`wechat send --image <path>` / `--file <path>`
- **非文本消息解析（listen 侧）**：当前 XML `appmsg` / 引用 / 图片消息出原始 XML，要二次解析提 title / url
<!-- 此条目已删除 (2026-05-19):本项目永久免费,作者不接受任何形式付款。详见 DISCLAIMER §7。 -->

## 已完成（最近）

- ✅ v1.12.0 `wechat orchestrate` —— SaaS outbox/webhook 接入（NAT-friendly，不需公网 IP / 域名）
- ✅ v1.11.1 远程 gateway via Cloudflare Tunnel + ES256 JWT（同步直连场景）
- ✅ v1.10.32 wechaty Puppet gRPC gateway —— 真号 wechaty macOS 协议
- ✅ v1.9.1 激活码 + 审核制 + 自动从服务端拉新版本 profile（Tencent 热更不用重发 release）
- ✅ v1.9.0 daemon-backed 发送（4× 提速）
- ✅ v1.8.13 init 自动 calibrate（Tencent 热更不用手动 `--force`）
- ✅ v1.8.10 真零闪屏（本地 keyboard event + 调试接口）

## 不打算做

- 群发 / 自动加好友 / 反向爬别人朋友圈
- Linux / Windows / Intel Mac
- 反调试 / 二进制混淆
- 公开版本适配实现细节（本项目不公开适配细节，由 profile API 服务端推送）

## 想看新版本？

关注 Telegram 频道：<https://t.me/+4PuAO3lB9R82ZTVh>
