---
name: bug 报告
about: 工具行为异常 / 命令报错 / 输出不对
title: "bug: "
labels: bug
---

<!--
🛑 提交前请阅读

1. **激活码永久免费**。任何收钱方都是冒名诈骗,见过请说,**别向陌生人付款**。
2. 别直接粘贴 `wechat-use init` stderr / `wechat-use doctor`(非 --json)输出 —— 会泄漏 build 号 / dylib SHA / 验证清单。
3. 跑 `wechat-use doctor --json` 的 redacted 输出再贴。
-->

## 现象

<!-- 哪个命令、做了什么、期待什么、实际什么。1-3 句话能讲清楚最好。 -->



## 复现步骤

```bash
# 1.
# 2.
# 3.
```

## redacted 环境

```
# wechat --version
# wechat-use doctor --json | jq -c '{ok, status}'
# macOS 版本(System Settings → 关于本机)
```

## 日志 / 错误输出

```
# 粘贴时把完整 SHA / build 号 / 0x... 地址抹掉
```
