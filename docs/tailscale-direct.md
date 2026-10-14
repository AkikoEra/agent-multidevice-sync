# Tailscale 直连方案

> 从 300ms DERP 中继优化到 17ms 点对点直连的完整排查与修复记录。
> 所有 IP 地址均已脱敏，实测数值为真实观测结果。

## 目录

- [问题现象](#问题现象)
- [背景知识](#背景知识)
- [诊断流程](#诊断流程)
- [判定：为什么端口转发救不了](#判定为什么端口转发救不了)
- [修复：启用 IPv6](#修复启用-ipv6)
- [实测结果](#实测结果)
- [可复制的排查清单](#可复制的排查清单)
- [常见误区](#常见误区)

---

## 问题现象

两台设备（macOS 与 Linux）通过 Tailscale 互通，但所有流量都走中继：

```text
$ tailscale ping <peer>
pong from peer (100.x.x.x) via DERP(hkg) in 320ms
pong from peer (100.x.x.x) via DERP(hkg) in 314ms
direct connection not established
```

表现为：SSH 有明显按键延迟、文件传输慢、同步投递耗时长。

## 背景知识

### Tailscale 的三种连接路径

| 路径 | 说明 | 延迟特征 |
|---|---|---|
| **直连** | 两端直接 UDP 通信 | 最低，同城通常 10–30ms |
| **DERP 中继** | 经 Tailscale 的中继节点转发 | 取决于节点位置，通常 100–400ms |
| **不可用** | 前两者都失败 | 连接断开 |

Tailscale 会优先尝试直连，失败则回退中继。**中继是保底，不是故障。**

### NAT 类型与可穿透性

直连的本质是 UDP 打洞，能否成功取决于两侧 NAT 类型：

| NAT 类型 | 特征 | 可否打洞 |
|---|---|---|
| 完全锥型 / 可复用 | `MappingVariesByDestIP=false` | ✅ 可以 |
| 对称型 | `MappingVariesByDestIP=true` | ❌ 极难 |
| CGNAT（运营商大内网） | WAN 口非公网地址 | ❌ 不可以 |

**关键：只要有一侧是对称型或 CGNAT，IPv4 打洞就失败。**

## 诊断流程

按顺序执行，每一步都能独立排除一类原因。

### 第 1 步：确认基本连通

```bash
tailscale status
```

对端显示 `online` 即连通。若为 `offline`，是入网问题，与点对点无关。

### 第 2 步：确认当前路径

```bash
tailscale ping -c 5 <peer-tailscale-ip>
```

判读：

```text
via DERP(hkg) in 320ms          ← 走中继，需优化
via 203.x.x.x:41641 in 20ms     ← 已直连，无需处理
direct connection not established ← 打洞失败
```

### 第 3 步：读取 NAT 关键指标

```bash
tailscale netcheck
```

重点看五个字段：

| 字段 | 健康值 | 含义 |
|---|---|---|
| `UDP` | `true` | 出站 UDP 可用 |
| `IPv4` | `yes` | IPv4 路径可用 |
| `IPv6` | `yes` | IPv6 路径可用 |
| `MappingVariesByDestIP` | `false` | `true` = 对称型 NAT，IPv4 打洞基本失败 |
| `PortMapping` | `UPnP` / `NAT-PMP` / `PCP` | 本层 NAT 的端口映射能力 |

实测（修复前）：

```text
UDP: true
IPv4: yes
IPv6: no, but OS has support
MappingVariesByDestIP: true
PortMapping: UPnP
```

注意 `IPv6: no, but OS has support` —— 系统支持 IPv6，但网络没给地址，
这是突破口。

### 第 4 步：判定是否处于 CGNAT

查路由器自身拿到的 WAN 地址。通过 UPnP 描述可读到：

```bash
python3 scripts/tailscale/probe_router.py <gateway-ip>
```

或在路由器管理页的 WAN 状态中查看。

若 WAN 地址属于以下任一段，即为**运营商级 NAT**：

```text
100.64.0.0/10    运营商级 NAT 保留段
10.0.0.0/8       私有地址
172.16.0.0/12    私有地址
192.168.0.0/16   私有地址
```

**本案例的转折点**：两台路由器的 WAN 地址都落在运营商保留段，
说明 IPv4 层面无论怎么配置端口转发都无法让外部主动连进来。

## 判定：为什么端口转发救不了

很多人（包括本案的最初排查）会尝试在路由器上加 UDP 端口转发。
**本案例确实配置成功了**，通过 UPnP 能读到规则确实生效：

```text
UDP 41641 -> 192.168.x.x:41641  enabled=1
```

但依然无法直连。原因是：

```text
Mac  → 运营商网关 CGNAT → 路由器(端口转发生效) → 你的机器
      ↑
      流量在这里就被丢弃，根本到不了你的路由器
```

**UPnP 只能映射自己这一层 NAT，管不了上层运营商的 CGNAT。**

### 结论

```text
端口转发：     已配置且生效 ✅
本层 NAT：     正常 ✅
运营商 CGNAT： 阻塞 ❌ ← 无法绕过
IPv4 打洞：    无解
```

此时唯一出路是 **IPv6**。

## 修复：启用 IPv6

IPv6 的逻辑不是"穿透 NAT"，而是**根本不存在 NAT**——全局地址直达。

### 为什么有效

```text
IPv4:  对称 NAT → 打洞失败 → 只能中继 → 300ms
IPv6:  全局地址 → 无需 NAT → 两端直达 → 17ms
```

### 操作步骤

#### 1. 确认系统是否已具备全局地址

Linux：

```bash
ip -6 addr show scope global
```

macOS：

```bash
ifconfig | grep inet6 | grep -v fe80
```

看到 `2408:` 等非 `fe80::` 开头的地址即为全局地址。
只有 `fe80::` 说明路由器没下发，需进入第 2 步。

#### 2. 在路由器开启 IPv6

**TP-LINK（Archer / 易展系列）**

```text
高级设置 → 网络参数 → IPv6
  → 启用 IPv6
  → 连接类型：自动检测
  → 前缀委派（Prefix Delegation）：开启
  → 地址自动配置：开启
  → 应用
```

**小米 / Redmi（MiWiFi）**

```text
常用设置 → 上网设置 → 协议：IPv4 + IPv6 双栈 → 保存
```

部分固件在 `高级设置 → 上网设置 → IPv6 设置 → 开启`。

**光猫桥接 + 自有路由器**：两层设备都要开，且确认前缀能下发到路由器。

#### 3. 验证 IPv6 连通性

```bash
ping -6 -c 3 2400:3200::1     # 阿里公共 DNS IPv6
```

能通说明 IPv6 出口正常。

#### 4. 重启 Tailscale 刷新状态

```bash
sudo systemctl restart tailscaled                       # Linux
sudo launchctl kickstart -k system/com.tailscale.tailscaled   # macOS
```

然后复查：

```bash
tailscale netcheck | grep -E "IPv6:|MappingVariesByDestIP:"
```

## 实测结果

### 指标变化

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 路径 | `DERP(hkg)` 香港中继 | IPv6 点对点直连 |
| 延迟 | 274–340 ms | **17 ms** |
| `IPv6` | `no` | `yes` |
| `MappingVariesByDestIP`（macOS） | `true` | `false` |
| 提升幅度 | — | **约 18 倍** |

### 修复前

```text
pong from peer (100.x.x.x) via DERP(hkg) in 320ms
pong from peer (100.x.x.x) via DERP(hkg) in 314ms
pong from peer (100.x.x.x) via DERP(hkg) in 303ms
direct connection not established
```

### 修复后

```text
pong from peer (100.x.x.x) via [IPv6 地址]:63502 in 17ms
```

`via` 后面是 IPv6 地址且不出现 `DERP`，即为直连成功。

### 两端 netcheck 对比

Linux 端：

```text
UDP: true
IPv4: yes
IPv6: yes
MappingVariesByDestIP: true
PortMapping: UPnP, NAT-PMP, PCP
```

macOS 端：

```text
UDP: true
IPv4: yes
IPv6: yes
MappingVariesByDestIP: false     ← 关键变化
PortMapping: UPnP
```

> `MappingVariesByDestIP` 的变化不代表 NAT 类型变了，而是 Tailscale 检测到
> IPv6 路径可用后重新评估了整体可达性。

## 可复制的排查清单

直连未建立时按序勾选：

- [ ] 两端 `tailscale status` 均 `online`
- [ ] `tailscale netcheck` 中 `UDP: true`
- [ ] 两端 `IPv6: yes`
- [ ] 两端有全局 IPv6 地址（非 `fe80::`）
- [ ] `ping -6 2400:3200::1` 能通
- [ ] 路由器 IPv6 防火墙未拦截入站（部分路由器默认拦截）
- [ ] 已重启 tailscaled 刷新状态
- [ ] `tailscale ping` 显示 `via [IPv6]:port` 且无 `DERP`

**还是走中继？** 检查是否一侧运营商 IPv6 未开放。此时接受中继即可——
中继是保底机制，SSH 与同步都能正常工作。

## 常见误区

| 现象 | 错误结论 | 实际情况 |
|---|---|---|
| 加了端口转发仍不直连 | 配置写错了 | 映射生效，但 CGNAT 阻断了入站 |
| UPnP 显示可用 | 应该能直连 | UPnP 只映射本层 NAT，管不了上层 |
| 浏览器能打开网站 | DNS 没问题 | 浏览器可能独立启用 DoH，绕过了系统 DNS |
| 两台机器同城 | 延迟应该低 | 中继节点可能在境外，物理距离无关 |
| 两端都在同一城市 | 应该直连 | 直连取决于 NAT 类型，不取决于距离 |
| 开了 IPv6 就一定直连 | 一次成功 | 需两端 IPv6 都可用，且已重启 tailscaled |

## 相关脚本

| 脚本 | 用途 |
|---|---|
| `scripts/tailscale/diagnose.sh` | 一键输出路径、延迟、NAT、IPv6 与建议 |
| `scripts/tailscale/benchmark.sh` | 对比中继与直连的延迟、带宽 |
| `scripts/tailscale/probe_router.py` | 通过 UPnP 读取路由器 WAN 地址与端口映射 |
| `scripts/tailscale/watch-path.sh` | 持续监控连接路径，检测回落中继 |

返回 [文档目录](../README.md#文档)。
