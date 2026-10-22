修复设置已就绪时，环境自检仍误报“需要发送验证”的问题。
环境自检不再要求重复发送测试消息；发送结果未知时，仍按原 request_id 核对回执。
强送达确认仍未开放，不会将“接口可提交”冒充“消息已送达”。
升级：`curl -fsSL https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh | sh`
