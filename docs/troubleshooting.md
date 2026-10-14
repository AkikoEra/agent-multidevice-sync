# 故障排查

按症状索引。先跑一遍快速诊断：

```bash
./scripts/tailscale/diagnose.sh
```

---

## 连接类

### 两端 `tailscale status` 显示 offline

**原因**：一端未运行、未登录、或不在同一 tailnet。

```bash
tailscale status
tailscale netcheck
```

确认两端登录同一账号。仍不通则检查 `tailscale up` 输出。

### SSH 能通但同步失败

**原因**：同步服务未启动或端口不通。

```bash
# Linux
sudo systemctl status agent-receiver
ss -ltnp | grep <监听端口>

# macOS
launchctl list | grep agent-collector
```

### 连接延迟高（300ms 左右）

**原因**：走了 DERP 中继，通常是 CGNAT 或对称 NAT 导致 IPv4 打洞失败。

```bash
./scripts/tailscale/diagnose.sh
```

看 `MappingVariesByDestIP` 和 `IPv6` 两项，按
[Tailscale 直连方案](tailscale-direct.md) 处理。

**中继是保底机制，功能正常，仅延迟高。**

### 开了端口转发还是走中继

**原因**：上层运营商 CGNAT，端口转发只能作用于本层 NAT。

判定：路由器 WAN 地址若为 `100.64.0.0/10` 或私有地址段，即为 CGNAT。

```bash
python3 scripts/tailscale/probe_router.py <gateway-ip>
```

**此情况 IPv4 无解**，启用 IPv6。

### 启用了 IPv6 仍走中继

按序检查：

```bash
ip -6 addr show scope global          # Linux：有非 fe80 地址吗
ifconfig | grep inet6 | grep -v fe80  # macOS
ping -6 -c 3 2400:3200::1             # IPv6 出口通吗
sudo systemctl restart tailscaled     # 改完必须重启
```

路由器 IPv6 防火墙可能默认拦截入站，检查路由器设置。

---

## 同步类

### 验签失败（signature mismatch）

**原因**：两端 HMAC 密钥不一致。

```bash
# 接收端
sudo cat /etc/agent-sync/sync.key

# 发送端
cat ~/.agent-sync/sync.key
```

两边一致即可。不一致则重新交换密钥（**通过安全的带外方式**），
见 [安装与部署](installation.md#第三步发送端部署)。

### 消息重复

**原因**：序列号未正常递增，或接收端去重逻辑异常。

检查发送端日志中的 `sequence` 是否单调递增；检查接收端是否正常记录
最大序列号。

序列号去重规则见 [同步协议](sync-protocol.md#序列号与去重)。

### schema 拒绝（字段未授权）

**这是预期行为，不是故障。**

未出现在 `audited_schema` 中的字段本就不该被读取——这是安全边界。

需要同步新字段时，显式加入白名单：

```json
"audited_schema": {
  "fields": ["id", "title", "新字段名"],
  "excluded": ["api_key", "token", "path"]
}
```

改完需重启采集服务。

### 采集端无数据 / 不投递

```bash
# 1. 源库路径存在吗
ls -la <source 路径>

# 2. 日志里的 schema 拒绝记录
log show --predicate 'process == "agent-collector"' --last 10m

# 3. 手动触发一次
./scripts/macos/trigger-sync.sh

# 4. outbox 是否有积压
```

### 服务启动失败

```bash
# Linux
journalctl --user -u agent-receiver -n 50

# macOS
log show --predicate 'process == "agent-collector"' --last 5m
```

常见原因：

| 症状 | 原因 |
|---|---|
| 配置解析错误 | JSON 语法错误，注意尾逗号 |
| 地址已被占用 | 端口冲突，改 `listen_port` |
| 权限拒绝 | 密钥文件权限，应为 `600` |
| 找不到文件 | 路径错误，用绝对路径 |

### 连接被拒绝（connection refused）

接收端没起，或监听地址不对。

```bash
ss -ltnp | grep <端口>
```

确认监听的是 `127.0.0.1` 或 Tailscale 网卡地址，不是 `0.0.0.0`。
若发送端通过 Tailscale 地址连接，接收端必须监听该地址。

---

## 数据类

### 数据不一致

```bash
# 查看两端序列号
grep sequence <日志>
```

序列号应单调递增。若发送端序列号更高但接收端没更新，检查投递日志。

### 源库被占用

**原因**：Agent 正在写入。

采集端以只读模式打开并自动重试。若持续失败，错开采集周期
（调整 `interval_seconds`）。

---

## 环境类

### 系统 DNS 被接管导致的假象

浏览器能打开、命令行不通，往往是浏览器独立启用了 DoH。

```bash
# 查看系统实际使用的 DNS
cat /etc/resolv.conf                 # Linux
scutil --dns                         # macOS
```

若域名被解析到明显错误的地址（如社交网站 IP 出现在无关域名上），说明
DNS 被污染或代理接管。

### Tailscale 版本不匹配

```text
Warning: client version != tailscaled server version
```

仅警告，功能正常。升级方式：

```bash
sudo apt upgrade tailscale      # Debian/Ubuntu
sudo pacman -Syu tailscale       # Arch
brew upgrade --cask tailscale    # macOS
```

---

## 收集诊断信息

提 Issue 时请附上（**先脱敏，删除所有 IP 与主机名**）：

```bash
./scripts/tailscale/diagnose.sh > /tmp/diag.txt
tailscale status | sed -E 's/[0-9a-f]{0,4}:[0-9a-f:]+/<IPV6>/g; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<IPV4>/g'
```

**切勿直接粘贴含真实 IP 的输出。**

返回 [文档目录](../README.md#文档)。
