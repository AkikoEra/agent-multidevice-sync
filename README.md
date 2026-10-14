<div align="center">

**中文** · [English](README_en.md)

# Agent 多端同步

### 让同一个 AI Agent 在多台设备之间保持一致状态的完整方案。

**设备换着用，Agent 不失忆；两台机器各上各的网，却能直连通信。**

[![Tailscale direct](https://img.shields.io/badge/Tailscale-%E7%9B%B4%E8%BF%9E-0096D6?style=flat-square&logo=tailscale&logoColor=white)](docs/tailscale-direct.md)
[![IPv6](https://img.shields.io/badge/%E8%BF%9E%E6%8E%A5-IPv6%E7%9B%B4%E8%BF%9E-2F80ED?style=flat-square)](docs/tailscale-direct.md)
[![latency](https://img.shields.io/badge/%E5%BB%B6%E8%BF%9F-300ms%20%E2%86%92%2017ms-brightgreen?style=flat-square)](docs/tailscale-direct.md#%E5%AE%9E%E6%B5%8B%E7%BB%93%E6%9E%9C)
[![Hermes](https://img.shields.io/badge/Runtime-Hermes%20Agent-8A2BE2?style=flat-square)](docs/architecture.md)
[![MIT license](https://img.shields.io/badge/license-MIT-f4c430?style=flat-square)](LICENSE)

**[快速开始](#快速开始) · [工作原理](#工作原理) · [同步什么](#同步什么) · [实战案例](#实战案例) · [常见问题](#常见问题) · [文档](#文档)**

```bash
git clone https://github.com/AkikoEra/agent-multidevice-sync.git
cd agent-multidevice-sync && ./scripts/tailscale/diagnose.sh
```

</div>

> [!IMPORTANT]
> 本项目通过 [Tailscale](https://tailscale.com/) 建立设备间通道，**不向公网暴露任何端口**。
> 同步内容包含 Agent 的会话状态与配置，部署时请使用本文提供的
> `examples/*.example` 模板生成自己的密钥，**不要复用仓库中的任何示例值**。

---

<div align="center">

[快速开始](#快速开始) · [工作原理](#工作原理) · [同步什么](#同步什么) · [实战案例](#实战案例) · [常见问题](#常见问题) · [文档](#文档)

</div>

## 快速开始

分三步：打通网络 → 部署同步 → 验证结果。

### 第一步：确认两台设备能互通

```bash
tailscale status
```

两端都显示 `online` 即可。若尚未安装，先在两台设备上分别安装
[Tailscale](https://tailscale.com/download)，登录同一个账号。

### 第二步：诊断当前连接质量

```bash
./scripts/tailscale/diagnose.sh
```

脚本会输出当前路径（中继还是直连）、延迟、NAT 类型和 IPv6 可用性，并给出
下一步建议。

典型输出：

```text
当前路径:      DERP(hkg) 中继
延迟:          318 ms
NAT 类型:      对称型 (MappingVariesByDestIP=true)
IPv6:          可用
建议:          启用 IPv6 可建立点对点直连
```

> 如果已经显示 `IPv6 直连` 且延迟低于 50ms，说明网络层已就绪，
> 可以直接进入第三步。

详细判定标准见 [网络诊断指南](docs/tailscale-direct.md)。

### 第三步：部署同步服务

```bash
# Linux 端（接收端）
./scripts/linux/install-receiver.sh

# macOS 端（发送端）
./scripts/macos/install-collector.sh
```

两个脚本都会：

- 检查依赖与网络前置条件
- 从 `examples/` 生成你的私有配置（不会覆盖已有配置）
- 注册开机自启服务
- 打印验证命令

部署完成后运行验收：

```bash
./scripts/verify.sh
```

具体参数、systemd / launchd 配置和故障排查见
[安装与部署](docs/installation.md)。

## 工作原理

三段式架构：**采集 → 传输 → 应用**。

```text
┌──────────────┐        Tailscale WireGuard        ┌──────────────┐
│  macOS 端    │ ────────────────────────────────► │  Linux 端    │
│  (Collector) │   点对点直连 / DERP 中继兜底       │  (Receiver)  │
│              │   无公网端口暴露                   │              │
│  读取本地    │                                   │  校验签名    │
│  Agent 状态  │  HMAC 签名 + 序列号                │  落库去重    │
│  → outbox    │  断网重试 / 幂等投递               │  → 应用状态  │
└──────────────┘                                   └──────────────┘
```

1. **采集**：Collector 定时读取本机 Agent 的状态库，按 schema 白名单抽取字段，
   生成不可变快照写入 outbox。schema 未授权的字段直接拒绝，避免越权收集。
2. **传输**：快照经 Tailscale 隧道发送到对端。每条消息带 HMAC 签名与单调序列号，
   对端验签失败即丢弃，序列号重复即去重。断网时本地排队，恢复后自动补发。
3. **应用**：Receiver 校验通过后落库，Agent 下次启动读取统一状态。

Tailscale 层的细节（为何默认走中继、如何升级为直连）见
[Tailscale 直连方案](docs/tailscale-direct.md)；完整数据契约见
[同步协议](docs/sync-protocol.md)。

## 同步什么

| 类别 | 内容 | 默认 |
|---|---|---|
| 会话元数据 | 会话 ID、标题、时间戳、设备归属 | ✅ |
| 消息历史 | 已归档的对话记录 | ✅ |
| Agent 配置 | 模型偏好、技能列表、工具开关 | ✅ |
| 长期记忆 | 记忆条目与来源 | ✅ |
| 凭据与密钥 | API Key、Token、Cookie | ❌ 永不同步 |
| 本机路径与环境 | 绝对路径、环境变量 | ❌ 永不同步 |

**凭据永不同步**：采集端只读取白名单内的字段，密钥类字段在 schema 层就被拒绝，
即使配置文件中存在也不会被读取或发送。相关约定见
[安全设计](docs/security.md)。

未同步但希望保留的内容（如大文件、模型权重），使用
[混合策略](docs/mixed-strategy.md) 通过 Git + Tailscale 单独管理。

## 实战案例

### 案例一：跨设备会话漫游

两台设备分属不同局域网，各自有独立出口。开启同步后，在其中一台上进行的
Agent 对话会在下一轮采集周期内同步到另一台，换设备继续对话时不丢失上下文。

**结果**：会话状态在两台设备间一致，切换设备无需手动迁移。

### 案例二：从 300ms 中继优化到 17ms 直连

初始状态下 Tailscale 走香港 DERP 中继，SSH 与同步均延迟约 300ms。排查发现
两端都处于运营商 CGNAT（无公网 IPv4），IPv4 打洞必然失败。

开启两台路由器的 IPv6 后，Tailscale 自动改用 IPv6 全局地址直连：

```text
修复前:  pong ... via DERP(hkg) in 320ms   ← 中继
修复后:  pong ... via [IPv6]:63502 in 17ms ← 直连
```

**延迟降低约 18 倍。** 完整排查过程与每一步的判定依据见
[Tailscale 直连方案](docs/tailscale-direct.md)。

### 案例三：断网 7 小时后自动补发

收集端离线约 7 小时后恢复，期间累积的快照按原序列号顺序补发，接收端全部
去重成功，无重复也无丢失。

**结果**：投递过程幂等，网络抖动不影响数据完整性。

## 常见问题

<details>
<summary><strong>需要公网 IP 吗？</strong></summary>

不需要。设备间通道全部走 Tailscale 的 WireGuard 隧道，所有服务只监听内网地址，
不向公网暴露任何端口。处于 CGNAT、多层 NAT、严格防火墙之后时会自动回退到
DERP 中继，连接依然可用，只是延迟更高。

</details>

<details>
<summary><strong>中继和直连有什么区别？选哪个？</strong></summary>

直连是设备之间直接通信，延迟低、带宽高；中继是流量经 Tailscale 的节点转发，
延迟取决于节点物理位置。Tailscale 会自动选择最优路径，无需手动指定。
你希望降低延迟时，按 [直连方案](docs/tailscale-direct.md) 操作即可，失败时
自动回退中继，不影响可用性。

</details>

<details>
<summary><strong>为什么开了 UPnP 还是走中继？</strong></summary>

UPnP 只能映射**自己这一层**的 NAT，管不了上层运营商的 CGNAT。判定方法：
若路由器 WAN 口地址落在 `100.64.0.0/10` 或其他私有地址段，说明有运营商层 NAT，
端口转发无论怎么配都无法让外部主动连进来。此时 IPv6 是唯一出路。

</details>

<details>
<summary><strong>同步会泄露我的密钥吗？</strong></summary>

不会。采集端按 schema 白名单读取字段，密钥类字段在 schema 层就被拒绝；传输层
还有 HMAC 签名校验。完整约定见 [安全设计](docs/security.md)。
本仓库的 `.gitignore` 也已屏蔽配置文件、密钥与数据库。

</details>

<details>
<summary><strong>断网了怎么办？</strong></summary>

采集端把快照写入本地 outbox 队列排队，网络恢复后按序列号补发，接收端幂等去重。
不会丢失，也不会重复。

</details>

<details>
<summary><strong>支持哪些平台？</strong></summary>

发送端与接收端均支持 Linux 和 macOS，架构无关。Windows 端可复用 Linux 脚本，
但未在本项目中实测，欢迎补充。

</details>

<details>
<summary><strong>我的 Agent 不是 Hermes 能用吗？</strong></summary>

能。同步层只依赖"存在一个本地状态库"这一前提，通过 `collector.json` 中的
schema 配置适配任意 Agent 的状态格式。Hermes Agent 是参考实现。

</details>

## 文档

| 文档 | 内容 |
|---|---|
| [安装与部署](docs/installation.md) | 前置条件、两端部署、systemd / launchd、验收 |
| [架构设计](docs/architecture.md) | 组件划分、数据流、失败模式、扩展点 |
| [Tailscale 直连方案](docs/tailscale-direct.md) | 诊断流程、CGNAT 判定、IPv6 直连、实测数据 |
| [同步协议](docs/sync-protocol.md) | 消息格式、签名算法、序列号与去重规则 |
| [安全设计](docs/security.md) | 信任边界、密钥管理、字段白名单、威胁模型 |
| [混合策略](docs/mixed-strategy.md) | 同步 / Git / 手动三类内容的划分原则 |
| [故障排查](docs/troubleshooting.md) | 按症状索引的排查路径 |
| [实测记录](docs/evidence.md) | 原始观测数据与验证步骤 |
| [贡献指南](CONTRIBUTING.md) | 开发环境与提交规范 |
| [安全披露](SECURITY.md) | 漏洞报告方式 |

## Star history

如果这个项目帮到了你，欢迎点个 ⭐ Star，让更多人看到。

<a href="https://www.star-history.com/?repos=AkikoEra%2Fagent-multidevice-sync&amp;type=date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=AkikoEra/agent-multidevice-sync&amp;type=date&amp;theme=dark&amp;legend=top-left" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=AkikoEra/agent-multidevice-sync&amp;type=date&amp;legend=top-left" />
    <img alt="Star history" src="https://api.star-history.com/chart?repos=AkikoEra/agent-multidevice-sync&amp;type=date&amp;legend=top-left" />
  </picture>
</a>

## 免责声明

请在遵守当地法律法规、并获得相应网络环境管理方授权的前提下使用本项目。

本项目用于个人多设备协同、学习与研究目的。使用者需自行确保同步内容的合法性
与授权状态，包括所同步的会话数据、配置与第三方素材。

本项目不提供任何绕过网络监管、规避访问控制或未经授权接入他人系统的能力。
Tailscale 是第三方服务，其使用受其自身条款约束。

## 贡献

欢迎提 [Issue](https://github.com/AkikoEra/agent-multidevice-sync/issues)
报告问题或建议功能，也欢迎
[Pull Request](https://github.com/AkikoEra/agent-multidevice-sync/pulls)
完善代码与文档。

开发环境与检查项见 [CONTRIBUTING.md](CONTRIBUTING.md)。

提交前请确认：**不要提交任何真实 IP 地址、密钥、端点或会话数据。**

## License

[MIT](LICENSE)
