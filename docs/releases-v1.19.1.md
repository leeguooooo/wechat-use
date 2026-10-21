修复设置授权入口、初始化收尾，以及部分环境的适配获取失败。
发送自检准确区分待确认、未知和未提交；新增原请求只读核对。
未知结果不自动重发，强送达确认仍未开放。
升级：`curl -fsSL https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh | sh`
仍有问题时复制诊断信息反馈，保留原 request_id，不反复测试。
