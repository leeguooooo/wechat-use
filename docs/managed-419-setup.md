# 准备专用微信4.1.9

1.19的SDK安装器保留微信App，不再在升级工具时复制、重签或重启微信。已有`WeChat-4.1.9-wechat-use.app`及默认绑定的用户跳过本页，运行`wechat-use setup`。

首次安装需要一份官方4.1.9。固定下载地址：
[WeChatMac_4.1.9.dmg](https://dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac_4.1.9.dmg)。
此版本安装包的SHA-256应为`0e8510d1a004fe6373aa0ad1806d73d4bcf9a32f0c62284d8eb82cefe2b78d06`。校验不符就停止，不改用最新版或跳过校验。

挂载校验后的安装包，把下列`/path/to/WeChat.app`替换为安装包内App的实际路径：

```bash
wechat-use clone install \
  --source /path/to/WeChat.app \
  --target "$HOME/Applications/WeChat-4.1.9-wechat-use.app" \
  --name '微信4.1.9（工具专用）' \
  --bundle-id com.tencent.xinWeChat419WechatUse \
  --make-default
```

该命令创建副本，不能把目标改成主微信。已有同名目标时不会覆盖。之后打开副本完成微信登录，运行`wechat-use setup`，按设置窗口提示完成实际所需的系统组件和授权。1.19 public 原生后台路径不使用辅助功能；已有环境以当前 `setup` 结果为准。

初始化使用有限被动内存读取和受验证的私有数据库快照。缺失、歧义或超时保留旧配置；不会自动重启微信或退回断点取钥。

## 分片读取锁未就绪

`WXS-I-SOURCE-LOCK` 或 `not_expected_shared_dms_holder` 表示分片当前未通过专用微信的锁归属检查。先正常结束工具任务，再正常退出并重新打开工具专用微信；登录后重新检查读取。不要手动删除或截断数据库、`-shm`、`-wal`，也不要通过放宽锁校验继续采集。

如果正常重启后仍失败，复制诊断摘要反馈；完整报告保存在本机。这个错误本身不能证明数据库已损坏。
