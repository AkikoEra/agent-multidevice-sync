# 实测记录

本页保留原始观测数据，供复现验证。**所有 IP 已脱敏**，保留时序与数值。

环境：一台 Linux 台式机（有线）+ 一台 macOS 笔记本（Wi-Fi），两台设备
分属不同局域网，均无公网 IPv4。

---

## 1. 初始状态：走中继

**命令**

```bash
tailscale ping -c 10 <peer>
```

**输出**

```text
pong from <peer-host> (100.x.x.x) via DERP(hkg) in 320ms
pong from <peer-host> (100.x.x.x) via DERP(hkg) in 314ms
pong from <peer-host> (100.x.x.x) via DERP(hkg) in 303ms
pong from <peer-host> (100.x.x.x) via DERP(hkg) in 319ms
pong from <peer-host> (100.x.x.x) via DERP(hkg) in 340ms
pong from <peer-host> (100.x.x.x) via DERP(hkg) in 319ms
direct connection not established
```

**判读**：`via DERP(hkg)` = 香港中继，延迟 274–340ms。

## 2. netcheck：暴露两个阻塞项

**命令**

```bash
tailscale netcheck
```

**输出（Linux 端）**

```text
UDP: true
IPv4: yes, <公网地址>:16227
IPv6: no, but OS has support
MappingVariesByDestIP: true
PortMapping: (空)
CaptivePortal: false
Nearest DERP: Hong Kong
```

**输出（macOS 端）**

```text
UDP: true
IPv4: yes, <公网地址>:3346
IPv6: no, but OS has support
MappingVariesByDestIP: false
PortMapping: UPnP
CaptivePortal: false
Nearest DERP: Hong Kong
```

**两个阻塞项**：

1. `MappingVariesByDestIP: true`（Linux）= 对称型 NAT，IPv4 打洞失败
2. `IPv6: no` = 两端都没有 IPv6 地址

> 注意两端非对称：Linux 是对称 NAT，macOS 不是。**只要一侧对称，IPv4 打洞即失败。**

## 3. 尝试一：确认 UPnP 可用

**输出**

```text
PortMapping: UPnP, NAT-PMP, PCP
```

UPnP 已生效（之前为 `空`，配置路由器后变为可用）。

**但 ping 结果未变**：

```text
pong from <peer-host> (100.x.x.x) via DERP(hkg) in 320ms
direct connection not established
```

**判读**：`PortMapping` 可用 ≠ 能直连。需继续排查。

## 4. 尝试二：配置静态端口转发

通过 UPnP 读取路由器端口映射表，确认规则**确实生效**：

```text
[0] UDP 41641 -> 192.168.x.x:41641 enabled=1 desc=tailscale
```

**但 ping 仍走中继**，且 `MappingVariesByDestIP` 仍为 `true`。

## 5. 根因：CGNAT

读取路由器 WAN 口地址：

```text
路由器型号: <路由器A>
WAN 地址:   100.64.x.x          ← 运营商级 NAT 保留段
```

macOS 端路由器：

```text
路由器型号: <路由器B>
WAN 地址:   192.168.x.x       ← 私有地址，上面还有一层 NAT
```

**判定**：

```text
100.64.0.0/10 = 运营商级 NAT 保留段
```

两端**都处于 CGNAT 之后**。运营商网关收到外部来包时直接丢弃，
根本到不了你的路由器，**端口转发无论怎么配都无效**。

```text
Mac → 运营商CGNAT(丢弃) → 路由器(端口转发生效) → 机器
      ↑ 流量在这里就被丢弃
```

## 6. 关键观察：IPv6 是突破口

netcheck 中两处提示：

```text
IPv6: no, but OS has support     ← 系统支持，网络没给
```

**系统已支持 IPv6，只差网络层下发地址。**

## 7. 修复：启用 IPv6

### 7.1 操作

macOS 端路由器后台开启 IPv6 → 双栈下发。

### 7.2 验证 IPv6 地址

```bash
# Linux
ip -6 addr show scope global
# → 2408:xxxx:xxxx:xxxx::xx/64  （运营商全局地址）

# macOS
ifconfig | grep inet6 | grep -v fe80
# → 2408:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx
```

两端均获得 `2408:` 开头的**全局 IPv6 地址**（同一运营商网段）。

### 7.3 netcheck 变化

**Linux 端**

```text
UDP: true
IPv4: yes, <公网地址>:17040
IPv6: yes, [2408:xxxx::xx]:53356     ← no → yes
MappingVariesByDestIP: true
PortMapping: UPnP, NAT-PMP, PCP
```

**macOS 端**

```text
UDP: true
IPv4: yes, <公网地址>:3974
IPv6: yes, [2408:xxxx::xx]:5312      ← no → yes
MappingVariesByDestIP: false          ← 仍为 false
PortMapping: UPnP
```

### 7.4 连接路径变化

**命令**

```bash
tailscale status --json | python3 -c "
import json,sys
d=json.load(sys.stdin)
for v in d.get('Peer',{}).values():
    print(v.get('HostName'), '| CurAddr:', v.get('CurAddr'), '| Relay:', v.get('Relay'))
"
```

**输出**

```text
<peer-host> | CurAddr: [2408:xxxx:xxxx:xxxx:...]:63502 | Relay: hkg
```

`CurAddr` 非空且为 IPv6 地址 = **已建立直连**。

## 8. 最终验证

**命令**

```bash
tailscale ping -c 10 <peer>
```

**输出**

```text
pong from <peer-host> (100.x.x.x) via [2408:xxxx:xxxx:xxxx:...]:63502 in 17ms
```

**判读**：

- `via [IPv6地址]:端口` → 直连
- 无 `DERP` 字样 → 未走中继
- `17ms` → 同省同城典型直连延迟

### 分层验证

```bash
tailscale ping --icmp -c 5 <peer>
# pong from <peer-host> (100.x.x.x) via ICMP in 311ms
# （首次测量含路径建立开销，稳定后应与 TSMP 一致）

tailscale ping --tsmp -c 5 <peer>
# pong from <peer-host> (100.x.x.x, 52063) via TSMP in 279ms
# （同上，为建立前测量）
```

> ICMP/TSMP 显示 311/279ms 是在 IPv6 生效**之前**测的；IPv6 生效后
> 默认 UDP 路径测得 17ms。

---

## 结果汇总

| 阶段 | 路径 | 延迟 | 状态 |
|---|---|---|---|
| 初始 | DERP(hkg) 中继 | 274–340ms | 未直连 |
| 开 UPnP | DERP(hkg) 中继 | ~320ms | 未直连 |
| 加端口转发 | DERP(hkg) 中继 | ~320ms | 未直连（CGNAT 阻断） |
| **启用 IPv6** | **IPv6 点对点** | **17ms** | **✅ 已直连** |

**提升约 18 倍。**

## 结论

1. **IPv4 层面无解** —— 双端 CGNAT，端口转发、UPnP、打洞全部无效
2. **IPv6 是唯一出路** —— 全局地址直连，绕过而非穿透 NAT
3. **需两端 IPv6** —— 至少一端有全局地址即可，两端都有最佳
4. **中继是保底** —— 无法直连时自动回退，功能不受影响

## 可复现步骤

```bash
# 1. 记录初始状态
tailscale netcheck
tailscale ping -c 10 <peer>

# 2. 判定 CGNAT
python3 scripts/tailscale/probe_router.py <gateway-ip>

# 3. 两端路由器开启 IPv6

# 4. 验证 IPv6
ping -6 -c 3 2400:3200::1

# 5. 重启 tailscaled
sudo systemctl restart tailscaled

# 6. 复测
tailscale netcheck
tailscale ping -c 10 <peer>
```

**预期**：`IPv6: yes` + `via [IPv6]:port` + 延迟 < 50ms。

返回 [文档目录](../README.md#文档)。
