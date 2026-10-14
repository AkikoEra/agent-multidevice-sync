# 同步协议

## 设计目标

1. **不丢**：断网期间的消息在网络恢复后必须送达
2. **不重**：同一条消息重复投递只生效一次
3. **不越权**：只传输白名单内的字段
4. **不可伪造**：接收端能识别非本 tailnet 的伪造请求

## 消息格式

```json
{
  "device": "macbook-pro",
  "sequence": 1042,
  "timestamp": "2026-10-14T13:57:01+08:00",
  "schema_version": 1,
  "payload": {
    "sessions": [ ... ],
    "memories": [ ... ],
    "preferences": { ... }
  },
  "signature": "hmac-sha256-hex"
}
```

| 字段 | 说明 |
|---|---|
| `device` | 发送端标识，接收端据此区分来源 |
| `sequence` | **单调递增序列号**，去重的唯一依据 |
| `timestamp` | 发送时间，仅用于审计，**不参与去重判断** |
| `schema_version` | schema 版本，接收端据此校验结构 |
| `payload` | 已经过白名单过滤的数据 |
| `signature` | 对以上字段的 HMAC-SHA256 签名 |

## 签名算法

```text
signature = HMAC-SHA256(
    key = 共享密钥（两台设备各持一份，不经过网络传输）
    message = device || sequence || timestamp || schema_version || payload
)
```

**规则：**

- 签名失败**直接丢弃**，不落库、不报错给对端（避免信息泄露）
- 密钥为对称密钥，通过**带外方式**交换（手动复制 / 安全通道）
- 密钥不写入仓库，`.gitignore` 已屏蔽

## 序列号与去重

接收端维护每个 `device` 的最大已处理序列号：

```text
收到 sequence > 已知最大值  → 处理，更新最大值
收到 sequence <= 已知最大值 → 丢弃（重复/乱序）
```

**为什么不用 timestamp 去重**：

- 时钟可能不同步、可能回拨、可能重复
- 单调序列号由发送端本地递增，无此问题

**乱序场景**：若收到 `sequence=1044` 而本地最大为 `1042`，正常处理
（允许跳号，因为 `1043` 可能尚未到达或已被处理）。
若收到 `1043` 之后又收到 `1043`，第二次丢弃。

## 幂等性保证

由于去重以序列号为准，同一消息重发任意次都只生效一次。
这保证了：

- 断网重连后的补发不会造成重复
- 网络层重传不会造成重复
- 手动重跑采集不会造成重复

## 采集端 outbox

```text
采集 → schema 校验 → 快照入队(分配序列号) → 发送 → 确认 → 标记完成
                ↓
            schema 拒绝 → 不入队，记录日志
                                ↓
                           发送失败 → 留在队列，等待重试
```

**outbox 是本地持久化队列**，进程重启、机器重启都不丢。

## 投递语义

| 语义 | 实现 |
|---|---|
| At-least-once | 发送端至少投递一次（失败重试） |
| Exactly-once（效果） | 接收端去重，达到恰好一次的效果 |

不追求传输层 exactly-once，因为那需要分布式事务；用"至少一次 + 幂等去重"
在简单性和正确性之间取得平衡。

## Schema 漂移

Agent 升级后状态库结构可能变化。处理方式：

```text
schema_version 匹配   → 正常处理
schema_version 不匹配 → 拒绝，记录日志，不静默降级
```

**显式失败优于静默降级**：结构不一致时强行写入可能污染数据。

需要同步新增字段时，更新 `audited_schema` 并递增 `schema_version`。

## 请求头适配

接收端若位于 Agent 后端之后，可能需要转换请求头。
本项目的反向代理脚本 `scripts/linux/tailscale_proxy.py` 负责：

```text
收到客户端请求
  → 校验来源（仅接受 tailnet 地址）
  → 转换请求头（注入后端所需的认证头）
  → 转发到 127.0.0.1 后端
```

监听地址必须是 Tailscale 网卡地址，**不监听公网**。

## 传输通道

```text
Sender → Tailscale WireGuard → Receiver
```

- 端到端加密（WireGuard）
- 身份由 Tailscale 控制平面验证（ACL）
- 应用层再加 HMAC，**纵深防御**：即使 tailnet 内有异常设备，也无法伪造消息

返回 [文档目录](../README.md#文档)。
