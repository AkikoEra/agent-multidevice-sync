# 安装与部署

## 目录

- [前置条件](#前置条件)
- [第一步：打通设备间通道](#第一步打通设备间通道)
- [第二步：接收端部署](#第二步接收端部署)
- [第三步：发送端部署](#第三步发送端部署)
- [第四步：验收](#第四步验收)
- [服务管理](#服务管理)
- [故障排查](#故障排查)

---

## 前置条件

| 项 | 要求 |
|---|---|
| 操作系统 | Linux（systemd）或 macOS（launchd） |
| Python | 3.10+ |
| Tailscale | 已安装并登录同一账号 |
| 网络 | 两台设备 `tailscale status` 互相 `online` |
| 权限 | 接收端需 sudo（systemd 服务）；发送端当前用户即可 |

检查：

```bash
python3 --version
tailscale version
tailscale status
```

## 第一步：打通设备间通道

```bash
# 两台设备分别执行
tailscale status
```

两端均显示对方 `online` 即可。

### 优化连接质量（可选但强烈推荐）

```bash
./scripts/tailscale/diagnose.sh
```

若输出显示走中继且延迟高，按 [Tailscale 直连方案](tailscale-direct.md) 优化。
本案例实测可从 300ms 降到 17ms。

## 第二步：接收端部署

在 Linux 端执行：

```bash
./scripts/linux/install-receiver.sh
```

脚本会依次完成：

1. 检查 Python 与 Tailscale
2. 创建服务目录与专用用户
3. 从 `examples/receiver.json.example` 生成配置（**不覆盖已有配置**）
4. 生成新的 HMAC 密钥（若不存在）
5. 注册 systemd 服务并启动
6. 打印验证命令

手动安装见 `scripts/linux/` 下的 systemd 单元文件。

### 配置要点

编辑 `receiver.json`：

```json
{
  "listen_host": "127.0.0.1",
  "listen_port": 9131,
  "key_file": "/etc/agent-sync/sync.key",
  "database": "/var/lib/agent-sync/state.db"
}
```

> **只监听 `127.0.0.1` 或 Tailscale 网卡地址，不要监听 `0.0.0.0`。**
> 若需通过 Tailscale 地址访问，改用 Tailscale 网卡地址即可，仍是私有网络。

## 第三步：发送端部署

在 macOS 端执行：

```bash
./scripts/macos/install-collector.sh
```

脚本会：

1. 检查依赖
2. 从 `examples/collector.json.example` 生成配置
3. 与接收端交换 HMAC 密钥（通过 Tailscale 通道，或手动复制）
4. 注册 launchd 服务
5. 手动触发一次采集并打印结果

### 配置要点

```json
{
  "url": "http://<接收端Tailscale地址>:9131/sync",
  "key_file": "~/.agent-sync/sync.key",
  "source": "<本机Agent状态库路径>",
  "device": "<本机设备名，用于接收端区分来源>",
  "interval_seconds": 300,
  "audited_schema": { "...": "字段白名单" }
}
```

- `device` 必须唯一，接收端据此区分来源
- `audited_schema` 是**安全边界**，只列需要同步的字段
- `interval_seconds` 采集周期，按需调整

字段白名单的构造方法见 [安全设计](security.md)。

## 第四步：验收

```bash
./scripts/verify.sh
```

逐项检查：

```text
[✓] Tailscale: 两端 online
[✓] 路径:      IPv6 直连 (17ms)
[✓] 接收端:    监听中
[✓] 签名:      HMAC 校验通过
[✓] 序列号:    单调递增，无重复
[✓] 投递:      测试消息已落库
```

手动验证：

```bash
# 查看连接状态
./scripts/tailscale/diagnose.sh

# 查看服务日志
journalctl --user -u agent-receiver -f     # Linux
log show --predicate 'process == "agent-collector" --last 5m'   # macOS

# 触发一次立即采集
./scripts/macos/trigger-sync.sh
```

## 服务管理

### Linux（systemd）

```bash
sudo systemctl status agent-receiver
sudo systemctl restart agent-receiver
journalctl --user -u agent-receiver -f
```

开机自启已由安装脚本配置，无需额外操作。

### macOS（launchd）

```bash
launchctl list | grep agent-collector
launchctl print gui/$(id -u)/com.agent.collector
```

重新加载：

```bash
launchctl bootout gui/$(id -u)/com.agent.collector 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.agent.collector.plist
```

## 故障排查

按症状索引见 [故障排查](troubleshooting.md)。高频问题：

### 服务启动失败

```bash
journalctl --user -u agent-receiver -n 50
```

常见原因：配置文件语法错误、端口被占用、密钥文件权限不正确。

### 验签失败

两端密钥不一致。重新同步密钥：

```bash
# 接收端导出
sudo cat /etc/agent-sync/sync.key

# 发送端导入
mkdir -p ~/.agent-sync
# 将密钥写入 ~/.agent-sync/sync.key
chmod 600 ~/.agent-sync/sync.key
```

### 采集端无数据

```bash
# 检查源库路径是否存在
# 检查 audited_schema 是否包含目标字段
# 查看采集日志中的 schema 拒绝记录
```

schema 拒绝是**预期行为**——未授权字段本就不该被读取。
需要同步新字段时，显式加入 `audited_schema`。

### 连接延迟高

```bash
./scripts/tailscale/diagnose.sh
```

按 [直连方案](tailscale-direct.md) 优化。中继状态下功能正常，仅延迟较高。

## 卸载

```bash
# Linux
sudo systemctl disable --now agent-receiver
sudo rm -f /etc/systemd/system/agent-receiver.service

# macOS
launchctl bootout gui/$(id -u)/com.agent.collector 2>/dev/null
rm -f ~/Library/LaunchAgents/com.agent.collector.plist
```

数据目录按需手动清理（含你的同步数据与密钥）。

返回 [文档目录](../README.md#文档)。
