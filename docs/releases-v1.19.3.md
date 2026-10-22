修复设置已就绪却自检报错，以及升级时旧后台残留阻塞的问题。
故障诊断区分当前环境和历史记录；发送未知时沿用原 request_id 核对，不自动重发。
升级：`curl -fsSL https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh | sh`
