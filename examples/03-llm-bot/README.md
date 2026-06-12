# 03-llm-bot

接 LLM API（默认 OpenAI 兼容端点，包括 OpenAI / Claude proxy / 本地 ollama）的
微信对话 bot：DM 全回，群里被 @ 时回，每会话独立 5-轮上下文窗口。

## 跑

```bash
npm install
export OPENAI_API_KEY=sk-...
export OPENAI_MODEL=gpt-4o-mini       # 或 claude-3-5-sonnet 走 anthropic proxy
# OPENAI_BASE_URL 可选；默认走 OpenAI
node bot.js
```

bot 起来之后给自己（filehelper）私发任意问题，应在 1-3s 内拿到 LLM 答复。

## 用 Claude / 本地 ollama

```bash
# Claude (via openrouter / anthropic-openai-proxy)
export OPENAI_BASE_URL=https://openrouter.ai/api/v1
export OPENAI_API_KEY=sk-or-...
export OPENAI_MODEL=anthropic/claude-sonnet-4

# 本地 ollama
export OPENAI_BASE_URL=http://localhost:11434/v1
export OPENAI_API_KEY=ollama
export OPENAI_MODEL=llama3.2
```

## 代码要点

完整逻辑在 [`bot.js`](./bot.js)。

### 1. 会话窗口 (per-talker LRU)

每个对话方独立维护最近 5 轮 `{role, content}`，避免单 context 串话。

### 2. 简单 rate-limit

每会话每 3 秒至多 1 条消息；超频默回 "处理中…请稍等"。LLM 一旦慢，群机器人最容易
被 spam 触发风暴。

### 3. 错误兜底

LLM 调用失败时回友好提示而不是 500 stack trace。

### 4. /reset 指令

用户发 `/reset` 清空当前会话上下文，方便切换话题。

## 生产警告

- **绝不**在群里把 LLM API key 通过 bot 暴露出来——示例已经避免了，但你扩展时小心
- LLM 回复可能很长（>2000 字）：微信 4096 字符上限，长内容自己分段
- 国内用户 OpenAI 直连受墙；推荐 openrouter / 本地 ollama
- 收费 model 注意预算；OpenAI usage / 本地 ollama free
