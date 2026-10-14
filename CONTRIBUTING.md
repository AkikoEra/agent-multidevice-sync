# 贡献指南

感谢你对本项目的关注。

## 开发环境

```bash
git clone https://github.com/AkikoEra/agent-multidevice-sync.git
cd agent-multidevice-sync
```

无需第三方依赖，Python 3.10+ 标准库即可运行。

## 提交前检查

**必跑**（会拦截敏感信息）：

```bash
./scripts/pre-commit-check.sh
```

**必跑**（端到端验收）：

```bash
./scripts/verify.sh
```

两者都通过才能提交。

### 敏感信息红线

**绝对不能提交：**

- 真实 IP 地址（公网、内网、Tailscale、IPv6）
- 真实主机名、用户名、域名
- 密钥、Token、密码、私钥
- 会话数据、数据库文件、日志
- 任何 `deployment/`、`*.db`、`*.key`、`*.env`

`.gitignore` 已屏蔽大部分，但**提交前务必跑一次扫描**。

## 项目结构

```text
README.md              主文档（中文）
README_en.md           英文文档
docs/                  详细文档
scripts/
  verify.sh            端到端验收
  pre-commit-check.sh  敏感信息扫描
  tailscale/           网络诊断与优化
  linux/               接收端 + systemd
  macos/               采集端 + launchd
examples/              配置模板（无真实值）
```

## 修改代码

### 同步协议

修改签名算法、序列号、消息格式会影响收发两端兼容性。需要：

1. 递增 `schema_version`
2. 同时更新 [docs/sync-protocol.md](docs/sync-protocol.md)
3. 补充 `--selftest` 覆盖新逻辑
4. 确认 `verify.sh` 通过

### 新增字段白名单

修改 `examples/collector.json.example` 的 `audited_schema` 时，
**新增字段前先问自己：这个字段属于"该同步"还是"凭据"？**

凭据类字段一律进 `excluded`，见 [docs/security.md](docs/security.md)。

### 新增脚本

- 使用 `set -euo pipefail`
- 中文注释，说明**为什么**而不只是**做什么**
- 提供 `--selftest` 或可验证的输出
- 实测通过再提交

## 提交信息

```text
<类型>: <简述>

类型: feat / fix / docs / refactor / test / chore
```

示例：

```text
fix: 修复 pipefail 下 grep -q 提前退出导致的误判
docs: 补充 CGNAT 判定流程
```

## 提 Issue / PR

**Issue** 请附：

- 操作系统与版本
- 复现步骤
- 相关日志（**先脱敏，删除所有 IP 与主机名**）

```bash
# 脱敏示例
tailscale status | sed -E 's/[0-9a-f]{0,4}:[0-9a-f:]+/<IPV6>/g; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<IPV4>/g'
```

**PR** 请确认：

- [ ] `./scripts/pre-commit-check.sh` 通过
- [ ] `./scripts/verify.sh` 通过
- [ ] 文档已同步更新
- [ ] 未包含任何敏感信息

## 行为准则

友好、具体、就事论事。技术分歧请用论据说话。
