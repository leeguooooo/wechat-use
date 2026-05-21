---
name: 新 build 适配请求
about: WeChat 升级到新 dylib 指纹,wechat send 不可用
title: "适配请求: WeChat <版本> "
labels: adaptation
---

<!--
🛑 提交前请阅读

1. 不要直接粘贴 `wechat init` stderr 或 `wechat doctor`(非 --json)输出。
   它们包含完整 dylib SHA-256 + build 号 + 验证清单,这些是 sanitization 政策红线。
   贴出后我们要花时间 redact,issue 历史也会留底。

2. 不要贴的内容:
   - 完整 dylib SHA-256(40+ 字符 hex)
   - WeChat build 号(纯数字 5-6 位)
   - 已验证 builds / versions 清单
   - 任何 0x... 地址 / RVA / 函数名 / DB 表名

3. 跑这个命令拿到 redacted 输出:
   ```bash
   wechat doctor --json | jq -c '{ok, status, version: .checks[] | select(.name == "wechat_dylib_fingerprint") | .detail}'
   ```
   仅贴它的输出。完整诊断走 Telegram bot 私聊。

4. 激活码永久免费,任何收钱方是冒名诈骗。**别向陌生人付款** —— 见过请在下方 "已付款被骗?" 区域告诉我。
-->

## 现象

<!-- 简述哪个命令报什么错。例:`wechat send` 报 "dylib 指纹不在已验证清单中";`wechat history` 正常。 -->



## redacted doctor 输出

```
# 粘贴 `wechat doctor --json | jq ...` 的输出(只 8 字符指纹前缀)
```

## 已尝试

- [ ] 重装 WeChat 官方 dmg(关闭自动更新)
- [ ] `wechat init` key 提取成功
- [ ] 通过 Telegram @WechatCliBot 提交了详细 doctor JSON

## 已付款被骗?(可选)

<!--
本项目永久免费。如果你为本项目付过钱,你是被冒名者诈骗了。
告诉我:
- 对方在哪个平台联系你 (TG / 微信 / 闲鱼 / 等)
- 对方账号 / 昵称
- 汇款渠道 / 金额(可选,不强求)
私下 DM bot 也行,我会配合追踪 + 频道公告举报指南。
-->


