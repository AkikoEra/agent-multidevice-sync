# 密钥生成与交换说明
#
# 本目录不包含任何真实密钥。请自己生成：
#
#   openssl rand -hex 32 > sync.key
#   chmod 600 sync.key
#
# 两台设备必须使用**完全相同**的密钥。
# 交换方式必须是带外的（不经过同步通道本身）：
#
#   手动复制（U盘 / 手动键入）
#   或通过已建立信任的 Tailscale SSH：
#     scp sync.key <peer>:~/.agent-sync/sync.key
#
# 严禁：邮件、聊天工具、公开仓库
#
# 接收端密钥路径: /etc/agent-sync/sync.key  (建议 600, 属主为服务用户)
# 发送端密钥路径: ~/.agent-sync/sync.key
#
# 轮换：两端同时生成新密钥并交换，重启服务。
#       轮换期间旧密钥签发的消息会被拒收。
